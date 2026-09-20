#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, DSIntroDemo) {
    DSIntroDemoNone = 0,
    DSIntroDemoPull,
    DSIntroDemoPick,
    DSIntroDemoSplit,
    DSIntroDemoFullscreen,
    DSIntroDemoPutAway,
};

// A looping miniature of the device that acts out whichever gesture the current
// walkthrough page is describing.
@interface DSIntroDemoView : UIView

- (void)playDemo:(DSIntroDemo)demo;
- (void)stop;

@end
