#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

// One gate for window transforms. Keyboard windows are never staged.
// Beeper's card keeps the frame, bounds, and transform SpringBoard applied.
void DSProcessWindow(UIWindow *window);
BOOL DSShouldSkipDynamicStageForBeeper(UIWindow *window);

#ifdef __cplusplus
}
#endif
