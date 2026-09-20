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
// How far the hosted app's window reaches below the card, which is where that app
// draws its own keyboard. The card stops clipping over that band so the keyboard
// comes out below the card, full size, at the bottom of the display.
@property (nonatomic, readonly) CGFloat keyboardSpill;

// Hidden while a live app is hosted, since the app paints its own background.
- (void)setBackdropHidden:(BOOL)hidden;

// Top strip that drags the whole card, and the bottom strip that stands in for
// the home bar the tweak hides while an app is on the stage.
- (CGRect)dragAffordanceRect;
- (CGRect)homeAffordanceRect;
// The corner the card is dragged back into to put it away.
- (CGRect)cornerGripRect;

- (void)setLiftOffset:(CGFloat)offset;
- (void)setKeyboardSpill:(CGFloat)spill;

@end
