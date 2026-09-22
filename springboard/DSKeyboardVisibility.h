#import <CoreGraphics/CoreGraphics.h>
#import <objc/objc.h>

#ifdef __cplusplus
extern "C" {
#endif

// Walks SpringBoard's own windows and returns the frame of a visible
// UIKeyboard, or CGRectNull when none is on the display. Does not unhide
// windows or call private selectors on unrelated ones.
CGRect DSVisibleKeyboardFrameOnScreen(void);

// If SpringBoard already has a window that contains keys, lift that window
// just above the stage. Does not create windows and does not unhide empty ones.
// Call this only after the staged app has reported a remote keyboard. A
// text-effects window that already exists in SpringBoard is not that keyboard.
BOOL DSRevealSpringBoardKeyboard(void);

// SpringBoard-process keyboard windows only. The hosted app's own keyboard
// is not in this list; it is painted inside the hosted scene.
NSString *DSKeyboardWindowCensus(void);

// Reads the filter plists and the in-app constructor breadcrumb. Does not
// write TweakInject.
void DSLogStagedAppInjection(NSString *why);

// YES after a real keyboard window was placed above the stage. Touches
// outside the keys must fall through that window onto the card.
BOOL DSExternalKeyboardCoversStage(void);

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
