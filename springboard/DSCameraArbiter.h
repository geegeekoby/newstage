#import <Foundation/Foundation.h>

// 4.5.652: the camera inside a staged app.
//
// The camera server streams only to an app that the display layout published
// by SpringBoard shows on screen. A stage card lives in SpringBoard's own
// window and is not part of that layout, so a staged app's capture session
// was interrupted as "in background" and its preview stayed black.
//
// While a staged app's capture session wants the camera (the app dylib says
// so over kDSCameraNotification), its visible card is published into the main
// display layout as an application element with the card's frame. The
// element goes away when the session stops, the app stops answering, the card
// is minimized, parked, hidden or closed, or the phone locks.
@interface DSCameraArbiter : NSObject

// Main thread, once the stage is active.
+ (void)start;
// Re-check soon (coalesced). Main thread.
+ (void)refreshSoon;
// Thread safe. YES while the scene's app holds the camera from a visible card.
+ (BOOL)sceneIdentifierHoldsCamera:(NSString *)identifier;
// Rate limited log of a hosted scene's foreground state, from the FBScene hook.
+ (void)noteHostedSceneSettings:(id)settings identifier:(NSString *)identifier;

@end
