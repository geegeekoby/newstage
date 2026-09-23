#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DSStageContext : NSObject

@property (nonatomic, readonly) UIWindow *stageWindow;
@property (nonatomic, readonly) UIViewController *hostedViewController;
@property (nonatomic, readonly) BOOL hostingApp;
@property (nonatomic) BOOL passThroughTouches;
@property (nonatomic) BOOL suppressLocalKeyboard;
@property (nonatomic) BOOL keyboardBandActive;
@property (nonatomic) CGFloat keyboardBandHeight;

// Called when the hosted app should be attached to the stage
- (void)attachHostedApp:(UIViewController *)viewController;

// Called when the hosted app should be removed from the stage
- (void)detachHostedApp;

// Called when the stage should update its layout due to keyboard changes
- (void)updateKeyboardBand;

// Called when the stage should apply a lift offset (keyboard raised)
- (void)setLiftOffset:(CGFloat)offset;

// Called when the stage should reset lift offset (keyboard lowered)
- (void)resetLiftOffset;

// Returns YES if the stage is currently hosting an app
- (BOOL)isHostingApp;

// Returns the view that contains the hosted app’s content
- (UIView *)hostedContentView;

@end

NS_ASSUME_NONNULL_END

// This header defines the public interface for the stage context controller.
// The implementation in DSStageContext.m handles:
//
// - attaching/detaching hosted apps
// - suppressing the app’s own keyboard
// - forwarding keyboard state to the stage container
// - managing keyboard band height
// - coordinating lift offset with DSStageContainerView
// - ensuring SpringBoard’s keyboard is the only active keyboard
//
// No private UIKit APIs are declared here.
// All methods are safe for external use by the stage controller and host app.
