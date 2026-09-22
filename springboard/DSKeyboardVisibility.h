#import <CoreGraphics/CoreGraphics.h>
#import <objc/objc.h>

#ifdef __cplusplus
extern "C" {
#endif

// Walks every on-screen UIWindow (window scenes first, then UIApplication.windows)
// and returns the frame of a visible UIKeyboard in screen coordinates, or
// CGRectNull when none is on the display.
CGRect DSVisibleKeyboardFrameOnScreen(void);

// Unhides SpringBoard's own keyboard window when it actually contains keys, and
// lifts it just above the stage (status-bar level, never alert). Returns YES
// when a keyboard is on the display.
BOOL DSRevealSpringBoardKeyboard(void);

// Places the arbiter's keyboard scene layer in SpringBoard's remote keyboard
// window, above the stage. Pass nil to put that window away. Does not stretch
// the window to the full display and does not use alert level.
void DSPresentArbiterKeyboardLayer(id sceneLayer);

// Convenience: bind the scene layer when present, otherwise reveal an existing
// SpringBoard keyboard window above the stage.
BOOL DSShowArbiterKeyboardAboveStage(id sceneLayer);

// Puts the presented remote keyboard window away.
void DSHidePresentedArbiterKeyboard(void);

// Hands the keyboard UI host back after a staged session so Spotlight and
// other apps are not stuck drawing through SpringBoard.
void DSReleaseStagedKeyboardHost(void);

// What the last present call did to SpringBoard's keyboard window.
NSString *DSPresentedKeyboardWindowStatus(void);

#ifdef __cplusplus
}
#endif
