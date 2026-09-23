#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DSStageContainerView : UIView

@property (nonatomic) CGFloat cornerRadius;
@property (nonatomic) BOOL darkMode;
@property (nonatomic) BOOL showsStackAddButton;
@property (nonatomic) BOOL showsMinimizeButton;
@property (nonatomic) BOOL passThroughToHost;
@property (nonatomic) BOOL hostingApp;
@property (nonatomic) BOOL clipsContents;
@property (nonatomic) CGFloat keyboardBandHeight;
@property (nonatomic) CGFloat liftOffset;

@property (nonatomic, copy, nullable) void (^stackAddHandler)(void);
@property (nonatomic, copy, nullable) void (^minimizeHandler)(void);
@property (nonatomic, copy, nullable) void (^keyboardBandLayoutHandler)(void);

- (UIView *)contentView;
- (CGRect)stackAddButtonRect;
- (CGRect)dragAffordanceRect;
- (CGRect)cornerGripRect;
- (CGRect)edgeGripRect;

@end

NS_ASSUME_NONNULL_END

// This header defines the public interface for the stage container view.
// The implementation lives in DSStageContainerView.m and handles:
//
// - card clipping behavior
// - keyboard band layout
// - shadow rendering
// - drag affordance
// - corner/edge grip hit‑testing
// - hosting app content inside the card
//
// No private UIKit headers are used here.
// All properties are safe for external use by the stage controller.

