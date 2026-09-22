#import <CoreGraphics/CoreGraphics.h>
#import <objc/objc.h>

#ifdef __cplusplus
extern "C" {
#endif

// Walks SpringBoard's own windows and returns the frame of a visible
// UIKeyboard, or CGRectNull when none is on the display. Does not unhide
// windows or call private selectors on unrelated ones.
CGRect DSVisibleKeyboardFrameOnScreen(void);

// Moves every keyboard window onto the stage's scene and holds it above the
// card. Does not create a window or assign the keyboard UI host.
BOOL DSRaiseKeyboardWindowAboveStage(void);
// YES while every keyboard window must stay above the stage. UIKit keeps
// making a second one on SystemAperture at level 10; that one is clipped.
BOOL DSKeyboardWindowShouldStayAboveStage(id window);
CGFloat DSKeyboardWindowLevelAboveStage(void);
// While a staged keyboard is up, any scene other than the stage's own scene
// is replaced with that scene. Level alone cannot cross scenes.
id DSReplacementSceneForKeyboardWindow(id window, id proposedScene);
void DSRestoreRemoteKeyboardPlacement(void);

// SpringBoard-process keyboard windows only. The hosted app's own keyboard
// is not in this list; it is painted inside the hosted scene.
NSString *DSKeyboardWindowCensus(void);

// Reads the filter plists and the in-app constructor breadcrumb. Does not
// write TweakInject.
void DSLogStagedAppInjection(NSString *why);

// YES after a real keyboard window was placed above the stage. Touches
// outside the keys must fall through that window onto the card.
BOOL DSExternalKeyboardCoversStage(void);

// Puts keyboard windows back where UIKit had them.
void DSHidePresentedArbiterKeyboard(void);

// Hands the keyboard UI host back after a staged session so Spotlight and
// other apps are not stuck drawing through SpringBoard.
void DSReleaseStagedKeyboardHost(void);

// What the last present call did to SpringBoard's keyboard window.
NSString *DSPresentedKeyboardWindowStatus(void);

#ifdef __cplusplus
}
#endif
