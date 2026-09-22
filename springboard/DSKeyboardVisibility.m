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

    // SpringBoard sometimes hosts the keys in a window whose class name does not mention
    // keyboard at all; fall back to hunting the UIKeyboard view in every window.
    DSVisitApplicationWindows(^(UIWindow *candidate) {
        if (!CGRectIsNull(keyboard)) return;
        if (candidate.hidden || candidate.alpha < 0.01) return;
        CGRect keys = DSKeyboardViewFrameInView(candidate);
        if (!DSKeyboardFrameIsOnScreen(keys, screen)) return;
        keyboard = keys;
    });
    return keyboard;
}

BOOL DSRevealSpringBoardKeyboard(void) {
    CGRect screen = UIScreen.mainScreen.bounds;
    __block BOOL revealed = NO;
    DSVisitApplicationWindows(^(UIWindow *window) {
        if (!DSWindowMightContainKeyboard(window)) return;
        BOOL wasHidden = window.hidden;
        CGFloat wasAlpha = window.alpha;
        if (wasHidden) window.hidden = NO;
        if (window.alpha < 0.01) window.alpha = 1.0;
        CGRect keys = DSKeyboardViewFrameInView(window);
        if (!DSKeyboardFrameIsOnScreen(keys, screen)) {
            window.hidden = wasHidden;
            window.alpha = wasAlpha;
            return;
        }
        // The stage sits just under the status bar. A keyboard window that is
        // lower than that is covered by the card, so lift only those.
        if (window.windowLevel < UIWindowLevelStatusBar) {
            window.windowLevel = UIWindowLevelAlert;
        }
        revealed = YES;
    });
    if (revealed) return YES;
    return DSKeyboardFrameIsOnScreen(DSVisibleKeyboardFrameOnScreen(), screen);
}

static id DSRemoteContext(unsigned int contextID) {
    Class contextClass = objc_getClass("CAContext");
    SEL remote = @selector(remoteContextWithOptions:);
    if (![contextClass respondsToSelector:remote]) return nil;
    for (NSString *key in @[ @"CAContextId", @"kCAContextId", @"contextId" ]) {
        @try {
            id context = ((id (*)(id, SEL, id))objc_msgSend)(contextClass, remote, @{ key : @(contextID) });
            if (context) return context;
        } @catch (NSException *exception) {
        }
    }
    return nil;
}

void DSHostKeyboardContext(unsigned int contextID) {
    static UIWindow *hostedWindow = nil;
    static unsigned int boundContext = 0;

    if (contextID == 0) {
        boundContext = 0;
        if (hostedWindow) hostedWindow.hidden = YES;
        return;
    }
    if (contextID == boundContext && hostedWindow && !hostedWindow.hidden) return;

    Class windowClass = objc_getClass("UIRemoteKeyboardWindow");
    SEL create = @selector(remoteKeyboardWindowForScreen:create:);
    UIWindow *window = nil;
    if ([windowClass respondsToSelector:create]) {
        @try {
            window = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(windowClass, create, UIScreen.mainScreen, YES);
        } @catch (NSException *exception) {
            window = nil;
        }
    }
    if (!window) return;

    id remote = DSRemoteContext(contextID);
    SEL bind = NSSelectorFromString(@"_setBoundContext:");
    if (remote && [window respondsToSelector:bind]) {
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(window, bind, remote);
        } @catch (NSException *exception) {
        }
    }
    for (NSString *name in @[ @"attachBindable", @"resetScene" ]) {
        SEL selector = NSSelectorFromString(name);
        if (![window respondsToSelector:selector]) continue;
        @try {
            ((void (*)(id, SEL))objc_msgSend)(window, selector);
        } @catch (NSException *exception) {
        }
    }

    window.backgroundColor = UIColor.clearColor;
    window.opaque = NO;
    window.hidden = NO;
    if (window.windowLevel < UIWindowLevelStatusBar) {
        window.windowLevel = UIWindowLevelStatusBar + 1.0;
    }
    hostedWindow = window;
    boundContext = contextID;
}
