#import <UIKit/UIKit.h>

// A small tab on the right edge of the display. Tapping it opens a list of the
// apps currently on a stage, plus the ones recently staged, so one of them can
// be put on screen without digging through the picker.
@interface DSStageShelfView : UIView

@property (nonatomic, assign) BOOL darkMode;
@property (nonatomic, assign, readonly) BOOL open;

@property (nonatomic, copy) void (^selectionHandler)(NSString *bundleIdentifier);
// Asked just before the list is shown, so the caller can refresh who is staged.
@property (nonatomic, copy) void (^willOpenHandler)(void);

- (void)reloadStagedIdentifiers:(NSArray<NSString *> *)staged
              recentIdentifiers:(NSArray<NSString *> *)recent;
- (void)setOpen:(BOOL)open animated:(BOOL)animated;

// Window coordinates. YES only for the tab, and for the list while it is open.
- (BOOL)claimsPoint:(CGPoint)point;

@end
