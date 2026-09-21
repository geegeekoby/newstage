#import <UIKit/UIKit.h>

// The stage card. The recordings show no chrome of any kind: whatever is on the
// stage runs edge to edge and is simply clipped to the display's corner
// profile, so this is a material backdrop plus a clipped content view.
@interface DSStageContainerView : UIView

@property (nonatomic, readonly) UIView *contentView;   // picker view or hosted app
@property (nonatomic, assign) BOOL darkMode;
@property (nonatomic, assign) CGFloat cornerRadius;
// How far the card is being held up out of the keyboard's way.
@property (nonatomic, readonly) CGFloat liftOffset;

// Hidden while a live app is hosted, since the app paints its own background.
- (void)setBackdropHidden:(BOOL)hidden;

// An app is on the stage rather than the app grid. The card grows its own home
// indicator, and the two strips below take the touches that land on them instead of
// letting them through to the app: a touch the app receives is one no gesture on this
// side of the fence ever hears about, which is what left an app on the stage with no
// way out of it.
@property (nonatomic, assign) BOOL hostingApp;

// Top strip that drags the whole card, and the bottom strip that stands in for
// the home bar the tweak hides while an app is on the stage.
- (CGRect)dragAffordanceRect;
- (CGRect)homeAffordanceRect;
// The corner the card is dragged back into to put it away.
- (CGRect)cornerGripRect;

- (void)setLiftOffset:(CGFloat)offset;

@end
