#import "DSStageWindow.h"
#import "DSPrivate.h"

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

@implementation DSStageWindow

+ (instancetype)stageWindow {
    DSStageWindow *window = nil;
    UIWindowScene *scene = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
            if ([candidate isKindOfClass:UIWindowScene.class]) {
                scene = (UIWindowScene *)candidate;
                break;
            }
        }
    }
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
