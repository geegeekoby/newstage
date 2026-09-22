#import <CoreGraphics/CoreGraphics.h>
#import <objc/objc.h>

#ifdef __cplusplus
extern "C" {
#endif

// Walks SpringBoard's own windows and returns the frame of a visible
// UIKeyboard, or CGRectNull when none is on the display. Does not unhide
// windows or call private selectors on unrelated ones.
CGRect DSVisibleKeyboardFrameOnScreen(void);

// Reports whether a keyboard is already visible. Does not create, unhide,
// restack, or bind keyboard windows.
BOOL DSRevealSpringBoardKeyboard(void);

// No-ops kept for existing callers. Creating or binding a remote keyboard
// window crashed SpringBoard on this phone.
void DSPresentArbiterKeyboardLayer(id sceneLayer);
BOOL DSShowArbiterKeyboardAboveStage(id sceneLayer);
void DSHidePresentedArbiterKeyboard(void);

// Hands the keyboard UI host back after a staged session so Spotlight and
// other apps are not stuck drawing through SpringBoard.
void DSReleaseStagedKeyboardHost(void);

// What the last present call did to SpringBoard's keyboard window.
NSString *DSPresentedKeyboardWindowStatus(void);

#ifdef __cplusplus
}
#endif
