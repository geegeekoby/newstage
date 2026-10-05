#import <UIKit/UIKit.h>

// A small tab on the right edge. Tapping it shows a New Stage button.
// That button opens a stage on the top half of the screen. Dragging the
// button and letting go opens a stage the same way.
@interface DSStageShelfView : UIView

@property (nonatomic, assign) BOOL darkMode;
@property (nonatomic, assign, readonly) BOOL open;

// half is 1 for the top of the screen and 0 for the bottom.
@property (nonatomic, copy) void (^halfHandler)(NSInteger half);
// A drag of the New Stage button. point is in screen coordinates.
// Ended means the finger let go after a real drag. Cancelled means put it back.
@property (nonatomic, copy) void (^slotDragHandler)(UIGestureRecognizerState state, CGPoint point);
// Fired only after a hold on a square that currently shows an app.
@property (nonatomic, copy) void (^halfHoldHandler)(NSInteger half);
@property (nonatomic, copy) void (^willOpenHandler)(void);

- (void)reloadTopBundleIdentifier:(NSString *)top bottomBundleIdentifier:(NSString *)bottom;
- (void)setOpen:(BOOL)open animated:(BOOL)animated;

// Window coordinates. YES only for the tab, and for the squares while they are open.
- (BOOL)claimsPoint:(CGPoint)point;

@end
