#import "DSStageWindow.h"
#import "DSPrivate.h"
#import <objc/message.h>

@implementation DSStageRootViewController

- (BOOL)prefersStatusBarHidden {
    return YES;
}

// The stage is portrait only, exactly like the stock tweak.
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskPortrait;
}

- (BOOL)shouldAutorotate {
    return NO;
}

@end

BOOL DSWindowIsApplicationKey(UIWindow *window) {
    if (!window.isKeyWindow) return NO;
    for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
        if (!candidate.isKeyWindow) continue;
        return candidate == window;
    }
    if ([window.windowScene respondsToSelector:@selector(keyWindow)]) {
        UIWindow *sceneKey = ((UIWindow *(*)(id, SEL))objc_msgSend)(window.windowScene, @selector(keyWindow));
        return sceneKey == nil || sceneKey == window;
    }
    return YES;
}

UIWindow *DSCompetingKeyWindow(UIWindow *window) {
    for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
        if (candidate != window && candidate.isKeyWindow) return candidate;
    }
    UIWindow *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *candidate in windowScene.windows) {
            if (candidate == window || !candidate.isKeyWindow) continue;
            BOOL main = !windowScene.screen || windowScene.screen == UIScreen.mainScreen;
            if (main && windowScene.activationState == UISceneActivationStateForegroundActive) return candidate;
            if (!fallback) fallback = candidate;
        }
    }
    return fallback;
}

static UIWindowScene *DSForegroundWindowScene(void) {
    if (@available(iOS 13.0, *)) {
        UIWindowScene *fallback = nil;
        for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
            if (![candidate isKindOfClass:UIWindowScene.class]) continue;
            UIWindowScene *scene = (UIWindowScene *)candidate;
            if (scene.screen && scene.screen != UIScreen.mainScreen) continue;
            if (!fallback) fallback = scene;
            if (scene.activationState == UISceneActivationStateForegroundActive) return scene;
        }
        return fallback;
    }
    return nil;
}

// 4.5.656 call step-aside state (main thread only).
static BOOL DSStageWindowsAside = NO;

static NSHashTable *DSStageWindowRegistry(void) {
    static NSHashTable *windows;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        windows = [NSHashTable weakObjectsHashTable];
    });
    return windows;
}

@implementation DSStageWindow {
    // Whether the stage wants this window shown once the call screen has gone.
    BOOL _shownBeforeCall;
}

+ (BOOL)callAside {
    return DSStageWindowsAside;
}

+ (void)setCallAside:(BOOL)aside {
    if (DSStageWindowsAside == aside) return;
    DSStageWindowsAside = aside;
    for (DSStageWindow *window in DSStageWindowRegistry().allObjects) {
        [window ds_applyCallAside:aside];
    }
}

// Hidden, not moved: a hidden window is neither drawn nor hit by the window
// server, so the card, its rim strips and the hosted app cannot cover or take
// a touch from the call screen. Hiding a hosted app view is what minimize and
// the home swipe already do; no scene settings are written here.
- (void)ds_applyCallAside:(BOOL)aside {
    if (aside) {
        _shownBeforeCall = ![super isHidden];
        if (_shownBeforeCall) [super setHidden:YES];
    } else if (_shownBeforeCall) {
        [super setHidden:NO];
    }
}

// While the call screen is up, a request to show the stage is remembered for
// later instead of putting the window back over the call.
- (void)setHidden:(BOOL)hidden {
    if (DSStageWindowsAside) {
        _shownBeforeCall = !hidden;
        if (hidden && ![super isHidden]) [super setHidden:YES];
        return;
    }
    [super setHidden:hidden];
}

- (void)makeKeyAndVisible {
    if (DSStageWindowsAside) {
        _shownBeforeCall = YES;
        return;
    }
    [super makeKeyAndVisible];
}

+ (instancetype)stageWindow {
    DSStageWindow *window = nil;
    UIWindowScene *scene = DSForegroundWindowScene();
    if (scene) {
        window = [[DSStageWindow alloc] initWithWindowScene:scene];
        window.frame = UIScreen.mainScreen.bounds;
    } else {
        window = [[DSStageWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    }

    window.rootViewController = [[DSStageRootViewController alloc] init];
    window.backgroundColor = UIColor.clearColor;
    window.opaque = NO;
    // Below the SpringBoard keyboard host. That host sits at level 1000.
    // 999 was close enough that raising the host, or a later level change,
    // put this window on top of the keys.
    window.windowLevel = 998.0;
    window.hidden = YES;
    [DSStageWindowRegistry() addObject:window];
    if (DSStageWindowsAside) [window ds_applyCallAside:YES];
    return window;
}

- (void)setWindowLevel:(CGFloat)level {
    if (level > 998.0) level = 998.0;
    [super setWindowLevel:level];
}

- (BOOL)attachToForegroundSceneIfNeeded {
    // Already the window UIKit will type into. Leave it on this scene.
    if (DSWindowIsApplicationKey(self)) return NO;
    // After a respring several scenes are foreground at once. The keyboard
    // follows whichever of them holds the real key window, not the first scene.
    UIWindow *other = DSCompetingKeyWindow(self);
    UIWindowScene *scene = other.windowScene;
    if (scene.screen && scene.screen != UIScreen.mainScreen) scene = nil;
    if (!scene) scene = DSForegroundWindowScene();
    if (!scene || self.windowScene == scene) return NO;
    self.windowScene = scene;
    CGRect bounds = scene.coordinateSpace.bounds;
    if (!CGRectEqualToRect(self.bounds, bounds)) {
        self.frame = bounds;
    }
    return YES;
}

// This window covers the display whenever the stage is on screen, so anything it
// does not deliberately claim has to fall through to whatever is behind it. With
// no test installed it claims nothing at all: a window that swallowed touches it
// had no owner for would leave the device looking frozen, and the stage simply
// not receiving a touch is the far cheaper failure.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (DSStageWindowsAside) return nil; // 4.5.656: the call screen gets every touch
    if (!self.touchTest || !self.touchTest(point)) return nil;
    return [super hitTest:point withEvent:event];
}

@end
