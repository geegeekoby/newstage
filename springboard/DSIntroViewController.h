#import <UIKit/UIKit.h>

// First-launch walkthrough. Presented once in its own window above SpringBoard,
// then never again unless the preference bundle resets the flag.
@interface DSIntroViewController : UIViewController

+ (void)presentIntro;
+ (BOOL)isPresenting;

@end
