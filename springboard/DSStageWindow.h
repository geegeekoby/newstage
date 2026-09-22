#import <UIKit/UIKit.h>

// Full screen window that only claims the touches the stage actually needs, so
// everything else still reaches the app underneath.
@interface DSStageWindow : UIWindow

@property (nonatomic, copy) BOOL (^touchTest)(CGPoint point);

+ (instancetype)stageWindow;
// After a respring the first connected scene is not always the one on screen.
// Returns YES when the window had to move onto the foreground scene.
- (BOOL)attachToForegroundSceneIfNeeded;

@end

@interface DSStageRootViewController : UIViewController
@end
