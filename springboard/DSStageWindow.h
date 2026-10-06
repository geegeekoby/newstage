#import <UIKit/UIKit.h>

// isKeyWindow can stay YES after SpringBoard has made a different window key.
// The keyboard follows that other window. YES only when this window is the one
// UIApplication will actually deliver text to.
BOOL DSWindowIsApplicationKey(UIWindow *window);
// The window UIKit will actually type into, when it is not `window`.
UIWindow *DSCompetingKeyWindow(UIWindow *window);

// Full screen window that only claims the touches the stage actually needs, so
// everything else still reaches the app underneath.
@interface DSStageWindow : UIWindow

@property (nonatomic, copy) BOOL (^touchTest)(CGPoint point);

+ (instancetype)stageWindow;
// After a respring the first connected scene is not always the one on screen.
// Returns YES when the window had to move onto the foreground scene.
- (BOOL)attachToForegroundSceneIfNeeded;

// 4.5.656: a call screen is coming up or is in front. Every stage window is
// hidden (and claims no touch), so iOS's call screen (InCallService, main app
// layout, level 5) is seen and used. Nothing is moved, minimized or written to
// a scene. NO shows the window again if the stage wanted it shown.
+ (void)setCallAside:(BOOL)aside;
+ (BOOL)callAside;

@end

@interface DSStageRootViewController : UIViewController
@end
