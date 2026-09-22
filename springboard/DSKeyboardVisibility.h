#import <CoreGraphics/CoreGraphics.h>

#ifdef __cplusplus
extern "C" {
#endif

// Walks every on-screen UIWindow (window scenes first, then UIApplication.windows)
// and returns the frame of a visible UIKeyboard in screen coordinates, or
// CGRectNull when none is on the display.
CGRect DSVisibleKeyboardFrameOnScreen(void);

// Unhides SpringBoard's own keyboard window when it actually contains keys, and
// keeps it above the stage. Returns YES when a keyboard is on the display.
BOOL DSRevealSpringBoardKeyboard(void);

// Places the arbiter's keyboard scene layer in SpringBoard's remote keyboard
// window, above the stage. Pass nil to put that window away.
void DSPresentArbiterKeyboardLayer(id sceneLayer);

// What the last present call did to SpringBoard's keyboard window.
NSString *DSPresentedKeyboardWindowStatus(void);

#ifdef __cplusplus
}
#endif
