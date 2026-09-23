#import <CoreGraphics/CoreGraphics.h>
#import <objc/objc.h>

#ifdef __cplusplus
extern "C" {
#endif

// Walks SpringBoard's own windows and returns the frame of a visible
// UIKeyboard, or CGRectNull when none is on the display. Does not unhide
// windows or call private selectors on unrelated ones.
CGRect DSVisibleKeyboardFrameOnScreen(void);

// The key strip in this window's coordinates, or CGRectNull. A host view
// that fills the window is the invisible cover, not the keys.
CGRect DSKeyboardKeysInWindow(id window);

// If SpringBoard already has a window that contains keys, lift that window
// just above the stage. Does not create windows and does not unhide empty ones.
BOOL DSRevealSpringBoardKeyboard(void);

// The system keyboard already lives in the remote-keyboard scene, under the
// stage. Window level does not cross scenes, so this moves that existing
// window onto the stage's scene and sets it just above the stage. It does
// not create a window, hide a view, or assign the keyboard UI host.
// `stageWindow` is the stage's UIWindow.
BOOL DSPlaceRemoteKeyboardAboveStage(id stageWindow);

// Raises the keyboard window SpringBoard is already showing so it sits above
// the stage. A window left on SystemAperture is moved back to the
// remote-keyboard scene, which is the scene that paints the keys. The stage
// scene is left alone. Does not create a window or hide a view.
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

// While that keyboard is up, only one keyboard window takes a touch. Medusa,
// any window that came from an aperture scene, and every other keyboard
// window return NO. Those windows are not hidden and their level stays put.
BOOL DSKeyboardWindowIsInteractive(id window);

// The key strip of that one window, in screen coordinates, or CGRectNull.
CGRect DSInteractiveKeyboardFrameOnScreen(void);

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
