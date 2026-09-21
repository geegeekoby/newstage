#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// SpringBoard after a reboot-then-jailbreak is still assembling the home screen
// when applicationDidFinishLaunching returns. Installing scene and gesture hooks
// in that window is what boot-looped earlier builds. These wait until the icon
// controller exists and a window is on screen, then call back on the main queue.
void DSWhenHomeScreenIsReady(void (^ready)(void));

#ifdef __cplusplus
}
#endif
