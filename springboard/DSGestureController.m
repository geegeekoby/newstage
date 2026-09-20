#import "DSGestureController.h"
#import "DSConstants.h"
#import "DSPreferences.h"
#import "DSPrivate.h"

// Pan recogniser that refuses to be delayed by the system gestures living in
// the same corner, so the stage starts moving on the first frame of the drag.
@interface DSPullGestureRecognizer : UIPanGestureRecognizer
@end

@implementation DSPullGestureRecognizer

- (BOOL)_delaysTouchesForSystemGestures {
    return NO;
}

@end

@interface DSTriggerWindow : UIWindow
@property (nonatomic, copy) BOOL (^touchTest)(CGPoint point);
@end

@implementation DSTriggerWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // Only the hot corner belongs to us; everything else falls through to the
    // app and to SpringBoard's own gestures. The corner itself falls through too
    // whenever the stage would not open from it - on an app the user has turned
    // the stage off for, for instance - so the tweak is not quietly holding on to
    // a strip of the screen it has no use for.
    CGPoint screenPoint = [self convertPoint:point toWindow:nil];
    if (![DSGestureController isPointInTriggerRect:screenPoint]) return nil;
    if (self.touchTest && !self.touchTest(screenPoint)) return nil;
    return [super hitTest:point withEvent:event];
}

@end

@implementation DSGestureController {
    DSTriggerWindow *_window;
    DSPullGestureRecognizer *_pan;
    BOOL _began;
}

+ (CGRect)triggerRect {
    CGRect bounds = UIScreen.mainScreen.bounds;
    return CGRectMake(CGRectGetWidth(bounds) - kDSTriggerWidth,
                      CGRectGetHeight(bounds) - kDSTriggerHeight,
                      kDSTriggerWidth,
                      kDSTriggerHeight);
}

+ (BOOL)isPointInTriggerRect:(CGPoint)point {
    return CGRectContainsPoint([self triggerRect], point);
}

- (void)install {
    if (_window) return;

    CGRect rect = [DSGestureController triggerRect];
    UIWindowScene *scene = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
            if ([candidate isKindOfClass:UIWindowScene.class]) {
                scene = (UIWindowScene *)candidate;
                break;
            }
        }
    }
    _window = scene ? [[DSTriggerWindow alloc] initWithWindowScene:scene] : [[DSTriggerWindow alloc] initWithFrame:rect];
    _window.frame = rect;
    _window.backgroundColor = UIColor.clearColor;
    _window.opaque = NO;
    _window.userInteractionEnabled = YES;
    _window.windowLevel = UIWindowLevelStatusBar - 2.0;
    _window.rootViewController = [[UIViewController alloc] init];
    _window.rootViewController.view.backgroundColor = UIColor.clearColor;

    __weak __typeof(self) weakSelf = self;
    _window.touchTest = ^BOOL(CGPoint point) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return NO;
        return [strongSelf.delegate gestureControllerShouldBegin:strongSelf atPoint:point];
    };

    _pan = [[DSPullGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    _pan.maximumNumberOfTouches = 1;
    _pan.cancelsTouchesInView = NO;
    _pan.delaysTouchesBegan = NO;
    _pan.delaysTouchesEnded = NO;
    [_window.rootViewController.view addGestureRecognizer:_pan];

    _window.hidden = NO;
}

- (void)invalidate {
    _window.hidden = YES;
    _window = nil;
    _pan = nil;
}

- (void)reloadPreferences {
    CGRect rect = [DSGestureController triggerRect];
    if (_window && !CGRectEqualToRect(_window.frame, rect)) _window.frame = rect;
}

- (BOOL)isTracking {
    return _began;
}

#pragma mark - Recognition

- (void)handlePan:(UIPanGestureRecognizer *)recognizer {
    CGPoint translation = [recognizer translationInView:nil];
    CGPoint velocity = [recognizer velocityInView:nil];

    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan: {
            CGPoint start = [recognizer locationInView:nil];
            // Only an upward pull out of the corner counts.
            BOOL upward = velocity.y < -80.0 || translation.y < -6.0;
            BOOL allowed = [self.delegate gestureControllerShouldBegin:self atPoint:start];
            if (!upward || !allowed) {
                recognizer.enabled = NO;
                recognizer.enabled = YES;
                return;
            }
            _began = YES;
            [self.delegate gestureControllerDidBegin:self];
            break;
        }
        case UIGestureRecognizerStateChanged:
            if (_began) [self.delegate gestureController:self didUpdateTranslation:translation];
            break;
        case UIGestureRecognizerStateEnded:
            if (_began) {
                _began = NO;
                [self.delegate gestureController:self didEndWithTranslation:translation velocity:velocity];
            }
            break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            if (_began) {
                _began = NO;
                [self.delegate gestureControllerDidCancel:self];
            }
            break;
        default:
            break;
    }
}

@end
