#import <UIKit/UIKit.h>

// 4.5.650: in-call UI inside the stage card.
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
// YES for a touch outside the card on the window that holds the contained
// call UI, so the stage and Home Screen under it keep working.
BOOL DSInCallWindowPassesTouch(UIView *view, CGPoint point);
#ifdef __cplusplus
}
#endif
