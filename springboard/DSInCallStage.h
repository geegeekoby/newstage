#import <UIKit/UIKit.h>

// 4.5.650: in-call UI inside the stage card.
// 4.5.653: containment is switched OFF (kDSInCallContainmentEnabled). On
// iOS 16 the call screen is InCallService in SpringBoard's main app layout
// (SBMainSwitcherWindow, level 5), so there was never a window it could
// safely scale; it only ever logged "cannot contain it". The call signal is
// now used for the call guard below, which keeps SpringBoard alive while the
// call screen comes up over a staged Phone.
//
// Only for a call started from the staged Phone app: the app posts
// com.recreated.dynamicstage.phone.outgoing (source 1 = staged call key,
// 2 = new outgoing TUCall while the staged Phone was the last thing touched).
// SpringBoard then looks for the full-screen InCallService scene for a few
// seconds and shows it scaled into the Phone card's rect (the card itself is
// never resized). Incoming calls and calls started anywhere else are never
// touched. Everything is restored when the call UI goes away, the card goes
// away / is minimized, or the home / switcher gesture starts.
#ifdef __cplusplus
extern "C" {
#endif
void DSInCallStageInstall(void);
// 4.5.653 call guard. YES while a phone call is up (InCallService on screen
// or frontmost), for 4 s after that changes, and for 25 s after the staged
// Phone app reports that it started a call. Cheap: the window walk behind it
// is cached for half a second.
BOOL DSCallGuardActive(void);
// The front app changed (SpringBoard's frontDisplayDidChange): re-read the
// call state on the next ask.
void DSCallGuardNoteFrontChange(void);
// YES for a touch outside the card on the window that holds the contained
// call UI, so the stage and Home Screen under it keep working.
BOOL DSInCallWindowPassesTouch(UIView *view, CGPoint point);
#ifdef __cplusplus
}
#endif
