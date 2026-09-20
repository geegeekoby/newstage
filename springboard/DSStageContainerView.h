#import <UIKit/UIKit.h>

// The stage card. The recordings show no chrome of any kind: whatever is on the
// stage runs edge to edge and is simply clipped to the display's corner
// profile, so this is a material backdrop plus a clipped content view.
@interface DSStageContainerView : UIView

@property (nonatomic, readonly) UIView *contentView;   // picker view or hosted app
@property (nonatomic, assign) BOOL darkMode;
@property (nonatomic, assign) CGFloat cornerRadius;

// Hidden while a live app is hosted, since the app paints its own background.
- (void)setBackdropHidden:(BOOL)hidden;

// Top strip that drags the whole card, and the bottom strip that stands in for
// the home bar the tweak hides while an app is on the stage.
- (CGRect)dragAffordanceRect;
- (CGRect)homeAffordanceRect;

@end
