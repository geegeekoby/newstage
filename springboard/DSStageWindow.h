#import <UIKit/UIKit.h>

// Full screen window that only claims the touches the stage actually needs, so
// everything else still reaches the app underneath.
@interface DSStageWindow : UIWindow

@property (nonatomic, copy) BOOL (^touchTest)(CGPoint point);

+ (instancetype)stageWindow;

@end

@interface DSStageRootViewController : UIViewController
@end
