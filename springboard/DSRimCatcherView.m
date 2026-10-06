#import "DSRimCatcherView.h"
#import "DSDiagnostics.h"
#import <objc/message.h>

void DSRimLog(NSString *text) {
    if (text.length == 0) return;
    static CFAbsoluteTime windowStart = 0;
    static NSInteger count = 0;
    static NSString *last = nil;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - windowStart > 2.0) {
        windowStart = now;
        count = 0;
    }
    if ([text isEqualToString:last] && count > 0) return;
    if (++count > 4) return; // at most 4 lines every 2s
    last = [text copy];
    DSDiagnosticsRecordFormat(@"SpringBoard: rim651 %@", text);
}

static void DSMakeSolidForWindowServer(UIView *view) {
    // Invisible (1.1% black), but a filled layer: the window server routes a
    // touch on it to SpringBoard instead of the app drawn below.
    view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.011];
    view.opaque = NO;
    CALayer *layer = view.layer;
    SEL opaqueHit = NSSelectorFromString(@"setHitTestsAsOpaque:");
    if ([layer respondsToSelector:opaqueHit]) {
        @try {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(layer, opaqueHit, YES);
        } @catch (NSException *exception) {
        }
    }
}

@implementation DSRimCatcherView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        DSMakeSolidForWindowServer(self);
        self.userInteractionEnabled = YES;
        self.hidden = YES;
        self.isAccessibilityElement = NO;
    }
    return self;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || !self.userInteractionEnabled || self.alpha < 0.01) return nil;
    if (![self pointInside:point withEvent:event]) return nil;
    NSString *path = nil;
    UIView *result = nil;
    @try {
        UIView *controls = self.controlsView;
        if (controls && controls.window) {
            for (UIView *subview in controls.subviews.reverseObjectEnumerator) {
                if (![subview isKindOfClass:UIControl.class] || subview.hidden || subview.alpha < 0.01 ||
                    !subview.userInteractionEnabled) {
                    continue;
                }
                CGPoint local = [self convertPoint:point toView:subview];
                UIView *hit = [subview hitTest:local withEvent:event];
                if (hit) {
                    result = hit;
                    path = @"card-control";
                    break;
                }
            }
        }
    } @catch (NSException *exception) {
        result = nil;
    }
    if (!result) {
        UIView *owner = self.touchOwner;
        result = (owner && owner.window && !owner.hidden) ? owner : self;
        path = owner ? NSStringFromClass(owner.class) : @"catcher";
    }
    // hitTest runs more than once per touch; log once per touch-down time.
    static NSTimeInterval lastEvent = -1;
    if (event && event.timestamp != lastEvent) {
        lastEvent = event.timestamp;
        CGPoint screen = [self convertPoint:point toView:nil];
        DSRimLog([NSString stringWithFormat:@"hit %@ at %.0f,%.0f -> %@", self.catcherName ?: @"?", screen.x, screen.y, path]);
    }
    return result;
}

@end

NSArray<DSRimCatcherView *> *DSMakeRimCatchers(UIView *parent, NSString *name, UIView *owner) {
    NSMutableArray<DSRimCatcherView *> *strips = [NSMutableArray arrayWithCapacity:4];
    static NSString *sides[] = { @"top", @"bottom", @"left", @"right" };
    for (int i = 0; i < 4; i++) {
        DSRimCatcherView *strip = [[DSRimCatcherView alloc] initWithFrame:CGRectZero];
        strip.touchOwner = owner;
        strip.catcherName = [NSString stringWithFormat:@"%@-%@", name, sides[i]];
        [parent addSubview:strip];
        [strips addObject:strip];
    }
    return strips;
}

static CGRect DSClipStrip(CGRect strip, CGFloat cutBottomY, CGRect homeBar) {
    if (CGRectGetMaxY(strip) > cutBottomY) {
        strip.size.height = MAX(0.0, cutBottomY - CGRectGetMinY(strip));
    }
    // The home bar stays the system's (the stage window does not claim it):
    // cut the strip above it rather than make SpringBoard swallow that touch.
    if (!CGRectIsNull(homeBar) && CGRectIntersectsRect(strip, homeBar)) {
        strip.size.height = MAX(0.0, CGRectGetMinY(homeBar) - CGRectGetMinY(strip));
    }
    return strip;
}

// Largest piece of `strip` left after removing `avoid`.
static CGRect DSStripMinus(CGRect strip, CGRect avoid) {
    if (CGRectIsNull(avoid) || CGRectIsEmpty(avoid) || !CGRectIntersectsRect(strip, avoid)) return strip;
    CGRect pieces[4] = {
        CGRectMake(CGRectGetMinX(strip), CGRectGetMinY(strip), CGRectGetWidth(strip), MAX(0.0, CGRectGetMinY(avoid) - CGRectGetMinY(strip))),
        CGRectMake(CGRectGetMinX(strip), CGRectGetMaxY(avoid), CGRectGetWidth(strip), MAX(0.0, CGRectGetMaxY(strip) - CGRectGetMaxY(avoid))),
        CGRectMake(CGRectGetMinX(strip), CGRectGetMinY(strip), MAX(0.0, CGRectGetMinX(avoid) - CGRectGetMinX(strip)), CGRectGetHeight(strip)),
        CGRectMake(CGRectGetMaxX(avoid), CGRectGetMinY(strip), MAX(0.0, CGRectGetMaxX(strip) - CGRectGetMaxX(avoid)), CGRectGetHeight(strip)),
    };
    CGRect best = CGRectZero;
    CGFloat bestArea = 0.0;
    for (int i = 0; i < 4; i++) {
        CGFloat area = CGRectGetWidth(pieces[i]) * CGRectGetHeight(pieces[i]);
        if (area > bestArea) {
            bestArea = area;
            best = pieces[i];
        }
    }
    return best;
}

void DSLayoutRimCatchers(NSArray<DSRimCatcherView *> *strips, UIView *parent, CGRect outerRect, CGRect innerRect, CGFloat cutBottomY, BOOL enabled) {
    DSLayoutRimCatchersAvoiding(strips, parent, outerRect, innerRect, cutBottomY, enabled, CGRectNull);
}

void DSLayoutRimCatchersAvoiding(NSArray<DSRimCatcherView *> *strips, UIView *parent, CGRect outerRect, CGRect innerRect, CGFloat cutBottomY, BOOL enabled, CGRect avoidWindowRect) {
    if (strips.count != 4 || !parent) return;
    BOOL usable = enabled && !CGRectIsEmpty(outerRect) && CGRectGetWidth(innerRect) > 20.0 && CGRectGetHeight(innerRect) > 20.0 &&
                  CGRectContainsRect(outerRect, innerRect);
    CGRect frames[4] = { CGRectZero, CGRectZero, CGRectZero, CGRectZero };
    if (usable) {
        CGFloat ox = CGRectGetMinX(outerRect), oy = CGRectGetMinY(outerRect);
        CGFloat ow = CGRectGetWidth(outerRect), oMaxY = CGRectGetMaxY(outerRect), oMaxX = CGRectGetMaxX(outerRect);
        CGFloat iy = CGRectGetMinY(innerRect), iMaxY = CGRectGetMaxY(innerRect);
        CGFloat ix = CGRectGetMinX(innerRect), iMaxX = CGRectGetMaxX(innerRect);
        frames[0] = CGRectMake(ox, oy, ow, iy - oy);                 // top
        frames[1] = CGRectMake(ox, iMaxY, ow, oMaxY - iMaxY);        // bottom
        frames[2] = CGRectMake(ox, iy, ix - ox, iMaxY - iy);         // left
        frames[3] = CGRectMake(iMaxX, iy, oMaxX - iMaxX, iMaxY - iy); // right
        CGRect homeBar = CGRectNull;
        if (parent.window) {
            CGRect screen = UIScreen.mainScreen.bounds;
            CGRect bar = CGRectMake(56.0, CGRectGetHeight(screen) - 28.0, CGRectGetWidth(screen) - 112.0, 28.0);
            homeBar = [parent convertRect:bar fromView:nil];
        }
        CGRect avoid = CGRectNull;
        if (!CGRectIsNull(avoidWindowRect) && parent.window) avoid = [parent convertRect:avoidWindowRect fromView:nil];
        for (int i = 0; i < 4; i++) frames[i] = DSStripMinus(DSClipStrip(frames[i], cutBottomY, homeBar), avoid);
    }
    BOOL animationsWereEnabled = UIView.areAnimationsEnabled;
    [UIView setAnimationsEnabled:NO];
    {
        for (NSUInteger i = 0; i < 4; i++) {
            DSRimCatcherView *strip = strips[i];
            CGRect frame = CGRectIntegral(frames[i]);
            BOOL show = usable && CGRectGetWidth(frame) >= 1.0 && CGRectGetHeight(frame) >= 1.0;
            if (show && !CGRectEqualToRect(strip.frame, frame)) strip.frame = frame;
            if (strip.hidden == show) strip.hidden = !show;
        }
        // Keep the strips on top of the parent's other subviews (the card's
        // hosted app view, grips, buttons), reordering only when needed.
        NSArray<UIView *> *subviews = parent.subviews;
        BOOL onTop = subviews.count >= 4;
        for (NSUInteger i = 0; onTop && i < 4; i++) {
            if (subviews[subviews.count - 4 + i] != strips[i]) onTop = NO;
        }
        if (!onTop) {
            for (DSRimCatcherView *strip in strips) {
                if (strip.superview == parent) [parent bringSubviewToFront:strip];
            }
        }
    }
    [UIView setAnimationsEnabled:animationsWereEnabled];
}
