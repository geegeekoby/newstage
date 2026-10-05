#import <CoreGraphics/CoreGraphics.h>
#import <objc/objc.h>

#ifdef __cplusplus
extern "C" {
#endif

// Walks SpringBoard's own windows and returns the frame of a visible
// UIKeyboard, or CGRectNull when none is on the display. Does not unhide
// windows or call private selectors on unrelated ones.
CGRect DSVisibleKeyboardFrameOnScreen(void);

// A real key strip: at least 160pt tall and nearly the width of the display.
// A dock strip and an in-card keyboard do not match. CGRectNull when none.
CGRect DSVisibleFullKeyboardFrameOnScreen(void);

// Hosted chat apps hide UIKeyboard inside the card and dock InputSetHost on
// SpringBoard. Accepts a full keyboard, a visible key window strip, or a
// plausible key strip collected from keyboard windows.
CGRect DSVisibleStagedKeyboardFrameOnScreen(void);

// A full-width keyboard parked at or below the bottom of the phone is the
// one the log shows at y=932 on a 932pt display. The window that holds it is
// brought onto the phone, and the keys go on the bottom edge, the same place
// SpringBoard's own search keyboard uses. Any other frame is returned unchanged.
CGRect DSFrameDockingKeyboardToScreenBottom(id view, CGRect proposed);
// While the staged field is editing, a frame at y=932 is the host leaving
// the screen. Returning the view's current frame leaves the keys where they
// are. Any other frame is unchanged.
CGRect DSFrameKeepingKeyboardHostOnScreen(id view, CGRect proposed);
// The stand-in is still editing and UIKit just reported the keyboard at
// y=932. Put SpringBoard's own keyboard back. The other keyboard windows
// stay where they are. YES when that keyboard is on screen.
BOOL DSReturnParkedKeyboardHost(CGRect endFrame);
// YES for a view inside the SpringBoard text-effects window that actually
// draws the keys. The remote, aperture, and Medusa windows are not it.
BOOL DSViewBelongsToLiveSpringBoardKeyboard(id view);

// Full-width keys that are on the phone, parked at or below the bottom, or
// reported at the top. Window coordinates hide a keyboard whose window is
// already at y=932. CGRectNull when nothing is up.
CGRect DSTypingKeyboardFrame(void);

// The window DSFrameDockingKeyboardToScreenBottom just put on the phone.
// Its level stays above the stage, and taps above the keys fall through.
BOOL DSKeyboardWindowIsDocked(id window);

// Why the full-width keyboard test found nothing. Names the window and the
// frame check that failed, so a missing keyboard can be told from a short one.
NSString *DSWhyFullKeyboardMissed(void);

// The key strip in this window's coordinates, or CGRectNull. A host view
// that fills the window is the invisible cover, not the keys.
CGRect DSKeyboardKeysInWindow(id window);

// If SpringBoard already has a window that contains keys, lift that window
// just above the stage. Does not create windows.
BOOL DSRevealSpringBoardKeyboard(void);

// Unhide every keyboard-related window and subview in SpringBoard (ghost layers too).
void DSRevealAllKeyboardWindowsOnSpringBoard(void);
void DSReassertKeyboardViewVisibility(id viewObject);

// The system keyboard already lives in the remote-keyboard scene, under the
// stage. Window level does not cross scenes, so this moves that existing
// window onto the stage's scene and sets it just above the stage. It does
// not create a window, hide a view, or assign the keyboard UI host.
// `stageWindow` is the stage's UIWindow.
BOOL DSPlaceRemoteKeyboardAboveStage(id stageWindow);

// YES when the front app itself is playing a video or short. Background
// music does not count. Hosting another app or rewriting the keyboard
// window in that state safe-modes SpringBoard.
BOOL DSVideoIsPlayingOnScreen(void);
NSString *DSNowPlayingBundleIdentifier(void);

// Raises the keyboard window SpringBoard is already showing so it sits above
// the stage. A window left on SystemAperture is moved back to the
// remote-keyboard scene, which is the scene that paints the keys. The stage
// scene is left alone. Does not create a window or hide a view.
BOOL DSRaiseKeyboardWindowAboveStage(void);
// Level only, and only the SpringBoard window that already has the keys.
// Does not move a frame, change a scene, or lower any other window.
void DSRaiseVisibleKeyboardAboveStage(void);
// Writes every keyboard window, what covers it, and why the level raise
// skipped it. Goes to the Beeper detail log, not the short stage log.
#define DSBeeperDetailDumpKeyboard(reason) ((void)0)
// Messages' reply bar lives in the text-effects window. Raising that window
// pulls the bar off the card. While this is set, only the key window moves.
void DSLeaveTextEffectsWindowWithTheCard(BOOL leave);
// YES while every keyboard window must stay above the stage. UIKit keeps
// making a second one on SystemAperture at level 10; that one is clipped.
// This one also rewrites the window's frame. It stays off while a video is
// playing, because moving that window safe-modes the phone.
BOOL DSKeyboardWindowShouldStayAboveStage(id window);
// Level only. Safe while a video is playing: the keyboard stays above the
// stage, and the window's frame and scene are left where UIKit put them.
BOOL DSKeyboardWindowShouldPinLevel(id window);
// Arm that level pin without unhiding windows or moving them.
void DSHoldKeyboardLevelAboveStage(void);
void DSReleaseKeyboardLevelHold(void);
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
// The arbiter said the keyboard is going away. Clear the raise before UIKit
// hides the window, or the hide is undone and a dead keyboard stays up.
void DSAllowKeyboardToDismiss(void);
// An in-call banner or the call UI is on screen. That deactivation must not
// take the staged keyboard down.
BOOL DSPhoneCallIsActive(void);

// Messages draws its own keyboard. SpringBoard's text-effects windows were
// sitting on top of those keys at the same level, so the taps never arrived.
void DSLowerStagedKeyboardCovers(void);

// Messages-only keyboard rules. Other staged apps keep the remote keyboard.
void DSSetMessagesKeyboardIsUp(BOOL up);
BOOL DSIsMessagesKeyboardUp(void);
// YES only while a keyboard window is actually taking taps. Hit testing
// must not walk the view tree when this is off.
BOOL DSKeyboardTouchPassthroughArmed(void);

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
// Writes a full picture of every keyboard window to the keyboard log when
// that picture changes: class, scene, frame, hidden, alpha, level, who is
// editing, and the key rect. Returns a short line for the prefs log.
NSString *DSKeyboardDebugSnapshot(void);

#ifdef __cplusplus
}
#endif
