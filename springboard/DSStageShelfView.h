#import <UIKit/UIKit.h>

// A small tab on the right edge. Tapping it shows two squares, top and bottom.
// An empty square starts a stage on that half. A staged app fills its square.
@interface DSStageShelfView : UIView

@property (nonatomic, assign) BOOL darkMode;
@property (nonatomic, assign, readonly) BOOL open;

// half is 1 for the top of the screen and 0 for the bottom.
@property (nonatomic, copy) void (^halfHandler)(NSInteger half);
@property (nonatomic, copy) void (^willOpenHandler)(void);

- (void)reloadTopBundleIdentifier:(NSString *)top bottomBundleIdentifier:(NSString *)bottom;
- (void)setOpen:(BOOL)open animated:(BOOL)animated;

// Window coordinates. YES only for the tab, and for the squares while they are open.
- (BOOL)claimsPoint:(CGPoint)point;

@end
