#import <UIKit/UIKit.h>
#import "DSAppLibrary.h"

// One app plate: icon, name, and the animated waveform shown next to whichever
// app currently owns audio. Used for both the two column grid and the list, so
// the two only differ in width.
@interface DSAppCellContentView : UIControl

@property (nonatomic, strong) DSAppEntry *entry;
@property (nonatomic, assign) BOOL darkMode;
@property (nonatomic, assign) BOOL showsNowPlaying;

// 0 ... 1 fill drawn from the leading edge while the plate is held down; at 1
// the hold has committed and the app opens fullscreen instead of on the stage.
@property (nonatomic, assign) CGFloat holdProgress;

- (void)setHoldProgress:(CGFloat)holdProgress animated:(BOOL)animated duration:(NSTimeInterval)duration;

@end
