#import <UIKit/UIKit.h>
#import "DSAppLibrary.h"

// One app plate: icon, name, and the animated waveform shown next to whichever
// app currently owns audio. Used for both the two column grid and the list, so
// the two only differ in width.
@interface DSAppCellContentView : UIControl

// Chip is the recent-apps strip: icon over the name. Row is the library list.
@property (nonatomic, assign) BOOL chipStyle;
// 4.5.823 style823: larger tile (chip) / roomier row with Dynamic Type. NO = the 822 look.
@property (nonatomic, assign) BOOL style823;
@property (nonatomic, strong) DSAppEntry *entry;
@property (nonatomic, assign) BOOL darkMode;
@property (nonatomic, assign) BOOL showsNowPlaying;
// Already on a stage. The plate is dimmed and does not open the app again.
@property (nonatomic, assign) BOOL unavailable;

// 0 ... 1 emphasis the plate takes on while it is held down; at 1 the hold has
// committed and the app opens fullscreen instead of on the stage.
@property (nonatomic, assign) CGFloat holdProgress;

- (void)setHoldProgress:(CGFloat)holdProgress animated:(BOOL)animated duration:(NSTimeInterval)duration;

@end
