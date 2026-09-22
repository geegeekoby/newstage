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

// Older builds bound the arbiter scene into a newly created
// UIRemoteKeyboardWindow (create:YES). That produced an empty full-screen
// window (bind=0) and left the keys inside the card. Pass nil to mark the
// keyboard hidden; a non-nil layer is ignored.
void DSPresentArbiterKeyboardLayer(id sceneLayer);

// Reveals an existing SpringBoard keyboard that already contains keys and
// lifts it above the stage. Never creates an empty remote keyboard window.
BOOL DSShowArbiterKeyboardAboveStage(id sceneLayer);

// Marks the presented keyboard as hidden. Does not create windows.
void DSHidePresentedArbiterKeyboard(void);

// Hands the keyboard UI host back after a staged session so Spotlight and
// other apps are not stuck drawing through SpringBoard.
void DSReleaseStagedKeyboardHost(void);

// What the last present call did to SpringBoard's keyboard window.
NSString *DSPresentedKeyboardWindowStatus(void);

#ifdef __cplusplus
}
#endif
