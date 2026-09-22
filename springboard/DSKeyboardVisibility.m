#import "DSKeyboardVisibility.h"
#import "DSConstants.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static BOOL DSWindowRespondsYes(id object, SEL selector) {
    if (![object respondsToSelector:selector]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static CGRect DSKeyboardViewFrameInView(UIView *view) {
    NSString *name = NSStringFromClass(view.class);
    BOOL isKeyboard = [name rangeOfString:@"UIKeyboard"].location == 0 ||
                      [name rangeOfString:@"InputSetHostView"].location != NSNotFound;
    if (isKeyboard && !view.hidden && view.alpha > 0.01 && !CGRectIsEmpty(view.bounds)) {
        UIWindow *window = view.window;
        return window ? [view convertRect:view.bounds toView:nil] : view.frame;
    }
    if (view.hidden || view.alpha < 0.01) return CGRectNull;
    for (UIView *child in view.subviews) {
        CGRect found = DSKeyboardViewFrameInView(child);
        if (!CGRectIsNull(found)) return found;
    }
    return CGRectNull;
}

static BOOL DSWindowMightContainKeyboard(UIWindow *window) {
    NSString *name = NSStringFromClass(window.class);
    if ([name rangeOfString:@"Keyboard"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"TextEffects"].location != NSNotFound) return YES;
    if (DSWindowRespondsYes(window, @selector(_isTextEffectsWindow))) return YES;
    if (DSWindowRespondsYes(window, @selector(_isRemoteKeyboardWindow))) return YES;
    return NO;
}

static void DSVisitApplicationWindows(void (^visitor)(UIWindow *window)) {
    NSMutableSet *seen = [NSMutableSet set];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (!window || [seen containsObject:window]) continue;
                [seen addObject:window];
                visitor(window);
            }
        }
    }
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (!window || [seen containsObject:window]) continue;
        [seen addObject:window];
        visitor(window);
    }
}

static BOOL DSKeyboardFrameIsOnScreen(CGRect keys, CGRect screen) {
    if (CGRectIsNull(keys)) return NO;
    if (CGRectGetMinY(keys) >= CGRectGetMaxY(screen) - 1.0) return NO;
    if (CGRectGetHeight(keys) < kDSKeyboardPresentHeight) return NO;
    return YES;
}

CGRect DSVisibleKeyboardFrameOnScreen(void) {
    __block CGRect keyboard = CGRectNull;
    CGRect screen = UIScreen.mainScreen.bounds;
    DSVisitApplicationWindows(^(UIWindow *candidate) {
        if (!CGRectIsNull(keyboard)) return;
        if (candidate.hidden || candidate.alpha < 0.01) return;
        if (!DSWindowMightContainKeyboard(candidate)) return;
        CGRect keys = DSKeyboardViewFrameInView(candidate);
        if (!DSKeyboardFrameIsOnScreen(keys, screen)) return;
        keyboard = keys;
    });
    if (!CGRectIsNull(keyboard)) return keyboard;

    DSVisitApplicationWindows(^(UIWindow *candidate) {
        if (!CGRectIsNull(keyboard)) return;
        if (candidate.hidden || candidate.alpha < 0.01) return;
        CGRect keys = DSKeyboardViewFrameInView(candidate);
        if (!DSKeyboardFrameIsOnScreen(keys, screen)) return;
        keyboard = keys;
    });
    return keyboard;
}

static NSString *DSClaimedKeyboardStatus = @"win=none";

// The stage sits at StatusBar - 1. Put a real keyboard window just above that.
// Never alert level. Never create an empty full-screen remote keyboard window.
static void DSRaiseKeyboardWindowAboveStage(UIWindow *window) {
    window.backgroundColor = UIColor.clearColor;
    window.opaque = NO;
    window.alpha = 1.0;
    window.hidden = NO;
    if (window.windowLevel < UIWindowLevelStatusBar) {
        window.windowLevel = UIWindowLevelStatusBar;
    }
}

BOOL DSRevealSpringBoardKeyboard(void) {
    CGRect screen = UIScreen.mainScreen.bounds;
    __block BOOL revealed = NO;
    __block CGRect shown = CGRectNull;
    __block CGFloat level = 0;
    DSVisitApplicationWindows(^(UIWindow *window) {
        if (revealed) return;
        if (!DSWindowMightContainKeyboard(window)) return;
        BOOL wasHidden = window.hidden;
        CGFloat wasAlpha = window.alpha;
        if (wasHidden) window.hidden = NO;
        if (window.alpha < 0.01) window.alpha = 1.0;
        CGRect keys = DSKeyboardViewFrameInView(window);
        // An empty remote keyboard window is full-screen with no UIKeyboard
        // inside it. Leave those alone - they cover the wallpaper and do not
        // draw keys outside the card.
        if (!DSKeyboardFrameIsOnScreen(keys, screen)) {
            window.hidden = wasHidden;
            window.alpha = wasAlpha;
            return;
        }
        if (CGRectGetHeight(window.frame) >= CGRectGetHeight(screen) - 1.0 &&
            CGRectGetWidth(window.frame) >= CGRectGetWidth(screen) - 1.0 &&
            CGRectGetHeight(keys) < CGRectGetHeight(screen) * 0.55) {
            // Keep the window's size. Stretching it was already rejected.
        }
        DSRaiseKeyboardWindowAboveStage(window);
        revealed = YES;
        shown = keys;
        level = window.windowLevel;
    });
    if (revealed) {
        DSClaimedKeyboardStatus = [NSString stringWithFormat:@"win=shown lvl=%.0f keys=%@",
                                   level, NSStringFromCGRect(shown)];
        return YES;
    }
    DSClaimedKeyboardStatus = @"win=none";
    return NO;
}

// Kept for callers that used to bind a scene layer. Creating an empty
// UIRemoteKeyboardWindow produced a full-screen bind=0 window and put the keys
// back inside the card. These now only hide / no-op.
void DSPresentArbiterKeyboardLayer(id sceneLayer) {
    if (!sceneLayer) {
        DSClaimedKeyboardStatus = @"win=hidden";
    }
}

void DSHidePresentedArbiterKeyboard(void) {
    DSClaimedKeyboardStatus = @"win=hidden";
}

BOOL DSShowArbiterKeyboardAboveStage(id sceneLayer) {
    (void)sceneLayer;
    return DSRevealSpringBoardKeyboard();
}

NSString *DSPresentedKeyboardWindowStatus(void) {
    return DSClaimedKeyboardStatus ?: @"win=none";
}
