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

@implementation DSStageWindow

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
    // Above the running application, below the status bar and system alerts.
    window.windowLevel = UIWindowLevelStatusBar - 1.0;
    window.hidden = YES;
    return window;
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
    if (!self.touchTest || !self.touchTest(point)) return nil;
    return [super hitTest:point withEvent:event];
}

@end
