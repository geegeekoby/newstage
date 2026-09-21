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

// An app is on the stage rather than the app grid, so the grips take the touches that
// land on them instead of letting them through to the app: a touch the app receives is
// one no gesture on this side of the fence ever hears about, which is what left an app
// on the stage with no way out of it.
@property (nonatomic, assign) BOOL hostingApp;

// The hosted app is sitting behind the card rather than in it, so everything
// except the grabber and the exit grips has to fall through.
@property (nonatomic, assign) BOOL passThroughToHost;

// Whether the content is clipped to the card. Off while an app is typing, so the
// keyboard that is drawn at the bottom of the app's window can sit on the display
// below the card rather than being clipped inside it.
- (void)setClipsContents:(BOOL)clips;

// Top strip that drags the whole card.
- (CGRect)dragAffordanceRect;
// The bottom-right corner, and a strip up the right-hand edge well clear of the home
// gesture. Either one starts the same drag: inward leaves the app, down puts the card
// away. The edge exists because the corner sits in the home gesture's own territory
// and the phone takes those drags away mid-gesture.
- (CGRect)cornerGripRect;
- (CGRect)edgeGripRect;

- (void)setLiftOffset:(CGFloat)offset;

// Top-right control to add another stage card above this one (overlay mode only).
@property (nonatomic, assign) BOOL showsStackAddButton;
@property (nonatomic, copy) void (^stackAddHandler)(void);
- (CGRect)stackAddButtonRect;

@end
