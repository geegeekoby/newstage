**4.5.678**
- Aimed at the first-tap bug that 4.5.676/677 did not fix: in Beeper, tapping the message field scrolled the message bar out of sight until the first key. The 4.5.675 log (Fixer.txt) shows the cause: Beeper's keyboard comes up, and Beeper lays out for it, while its scene is still the card's 420x458 (keys674's layer question at 01:59:51.508, arbiter on=1 at .511, "keyboard up ... scene frame={{0, 0}, {420, 458}}" at .516). The phone-size scene only lands at .607, and even the 676 early switch on arbiter on=1 comes after the app already has its keyboard. Beeper keeps that layout until its next text change. The keyboard frame itself does not change on the first key (no arbiter status at all while typing, already 288/346 before the switch), so it is Beeper's own relayout that fixes it, not a new keyboard size.
- A (phonesize678 width nudge, replaces the 676 height nudge): once the phone-size scene reads back, its WIDTH goes 430 -> 428 for 0.12 s and back (height and safe area unchanged), and again 0.5 s later after the keyboard animation. The app's own keyboard changes width, so UIKit re-posts its keyboard frame, and every view, the composer included, lays out again at the final size (the 676 nudge changed neither). Same guarded geometry-only writes. Off: /var/mobile/.dynamicstage-phonesize678-width-off (back to the 676 height nudge); /var/mobile/.dynamicstage-phonesize676-nudge-off still turns every nudge off.
- B (phonesize678 pre-grow, on): a single touch in the bottom 76 pt of an allowlisted app's card (inside the rim, not a bottom corner, no drag, no keyboard yet) grows the scene to the phone size at touch-down, before the keyboard exists, so the keyboard then shows in the final 430x931 scene. The touch is only watched: a plain gesture recognizer that never recognises, cancels, delays or prevents anything (no hooks). While the finger is down the mapping is "tap-safe" (app top on the card top, so the touched point moves at most ~10 pt inside the app and the tap still lands) with the card's picture held over it. When the finger lifts it is bottom-anchored (the app's bottom above the home inset on the card's bottom edge, so the composer sits where it was). When the keyboard comes it moves to the 4.5.675 keyboard mapping (y 117..586), plus one A nudge 0.6 s later as a safety net. Undone (back to card size) if the touch moves over 12 pt, or if no keyboard comes within 1.5 s of the finger lifting (4 s cap). Off: /var/mobile/.dynamicstage-phonesize678-pregrow-off. Bottom-anchored right at touch-down (no tap-safe phase, no picture hold): /var/mobile/.dynamicstage-phonesize678-anchor-at-down.
- C (opt-in, off by default): /var/mobile/.dynamicstage-phonesize678-always keeps allowlisted apps phone-size the whole time they are staged (from 2.5 s after the card hosts the app, or the first touch), bottom-anchored while the keyboard is down, the keyboard mapping while it is up.
- Log lines start "phonesize678": touch-down t+0ms ..., pre-grown t+..ms: mapping ..., mapping A -> B (finger lifted), finger lifted ... waiting for the keyboard, keyboard arrived in the pre-grown phone-size scene t+..ms, pre-grown scene landed ... no nudge, width nudge #1/#2 sent / restored, pre-grow undone: ..., touch-down ...: no pre-grow, <why>, always: ...
- Unchanged: the 4.5.675 band fix, the 677 crash fix (no focus hook, no new SpringBoard hooks at all in 678), the arbiter on=1 early switch (-phonesize677-early-off), the 675 off/apps/pinoffset files, keys674, the 4.5.673 Messages camera, the crash guards, zero app-switcher hooks, the stage card size (only content scales).

**4.5.677**
- SpringBoard crash fixed (4.5.676 SIGSEGV, safe mode, Logger.txt): symbolicated with the 4.5.676 debug symbols, the crash is on the main thread at startup, in two system-library frames (most likely the objc runtime's method lookup) directly under an objc_msgSend call in -[DSPreferences resolvedPath:] (DSPreferences.m:38), reached through the first +[DSPreferences sharedPreferences] from -[DSStageManager activate] (DSStageManager.m:792, publishStageState). That code is unchanged since before 4.5.675 and ran cleanly there. The only new step between the 4.5.675 start and that crash is the 4.5.676 focus hook (a manual MSHookMessageEx on -[_UIKeyboardArbiter handlerRequestedFocus:shouldStealKeyboard:]), whose "hooked" log line is the last one before the crash. That hook is removed. It only logged by default.
- The arbiter on=1 early switch (inside the long-standing updateKeyboardStatus hook, not on the crash stack) stays but is defensive: only already-copied values leave the arbiter queue (string type checked, height checked finite), everything else runs on the main queue behind respondsToSelector, type checks and @try. Off (back to the 4.5.675 keyboard-note trigger plus the nudge): /var/mobile/.dynamicstage-phonesize677-early-off. The -focus-on file no longer exists.
- Dynamic Island: nothing of ours hides, fades or re-levels SBSystemApertureWindow (it only shows up as the "other" key window in takeKey lines, the same as in clean 4.5.675 sessions), and on the start after the crash DynamicStage installed no hooks at all. The missing island was SpringBoard's state after the crash / safe mode; a normal respring brings it back.
- Unchanged: the 4.5.675 band fix, the 4.5.676 relayout nudge (and its -nudge-off file) and opt-in hold, the 675 off file, allowlist and pinoffset, keys674, the 4.5.673 Messages camera, the crash guards, zero app-switcher hooks, the stage card size.

**4.5.676**
- Aimed at the 4.5.675 first-tap glitch: Beeper's message bar shrank or slid off the card on the first tap into the field and snapped back on the first key (the 4.5.675 band fix stays; not yet confirmed on the device). 4.5.675 grew Beeper's scene to the phone size 60 ms after the stage's first keyboard note, after Beeper had already laid out for its keyboard in the 420x458 window; Beeper only lays out again on its next keyboard or text change, so the bar stayed wrong until a key was typed.
- Switch earlier (phonesize676): the scene is now grown on the arbiter's first "on=1" keyboard status from the app, the earliest SpringBoard-side signal that its keyboard is coming up (it arrives before SpringBoard's own keyboard change and the stage's note), with a provisional keyboard top (the app's last one, or the arbiter height + 58) that the first note corrects (layout only). The arbiter's keyboard-focus request (handlerRequestedFocus:shouldStealKeyboard:) is hooked too and its time logged; it only switches with /var/mobile/.dynamicstage-phonesize676-focus-on. No keyboard note within 1.5 s of an early switch: back to card size.
- Relayout nudge: once the scene reads back 430x931, it is sent 430x930 with a 1 pt larger bottom safe area, then the exact 430x931 / {59,0,34,0} again 0.12 s later; once more 0.5 s after that. Two real size + safe-area changes make UIKit move the keyboard's placement in Beeper's window and lay Beeper out again, as a typed key did. Geometry writes only (no orientation, lifecycle or transaction), deferred while a write would trap or a card drag settles, and each restarts the 1 s app-view hold. Off: /var/mobile/.dynamicstage-phonesize676-nudge-off.
- Optional picture hold: /var/mobile/.dynamicstage-phonesize676-hold-on keeps a snapshot of the card over the switch until the first nudge is back (max 0.8 s). Off by default.
- Log lines "phonesize676 ...": focus requested, early switch on "arbiter on=1" with t+ms, first keyboard note t+ms, scene read back t+ms (landed / NOT landed yet), relayout nudge #1/#2 sent / restored / after-nudge read back, picture hold ON/OFF. The 675 lines now carry t+ms too.
- Unchanged: the 675 off file, allowlist and pinoffset; keys674; the 4.5.673 Messages camera; the crash guards; zero app-switcher hooks; the stage card size.

**4.5.675**
- TEST BUILD (risky, on by default for Beeper only): phonesize675. While Beeper (com.beeper.chat.ios) has the keyboard up on a visible card, its scene is given the phone's own size (430x931 on a 430x932 phone: full width, 1 pt short of the bottom edge, origin 0, the screen's safe area {59,0,34,0}) instead of the card's 420x458. The card shows that phone-size picture scaled to the card's width (x0.977 for a 420pt card) with the keyboard's top edge (the stage's real keys, y=586 with the quick bar, 631 without) on the card's bottom edge, so the card shows the app's y 117..586 (the conversation and the composer sitting on the keys) and clips the rest. Beeper's own keyboard math now runs exactly as full screen (window bottom = screen bottom, keys at the same screen y), which is the case where it shows no band. When the keyboard goes away (the stage's own release, not the 631/932 hide flicker) the scene goes back to the card size: the exact 4.5.674 geometry. The card frame on screen never changes; only the content is scaled.
- Consistent everywhere: the scene frame, the app view's content reference size, the override every later SpringBoard settings update for that scene is rewritten to (so home668 sees the phone frame as the stage's own) and the safe area all say phone size together; geometry writes only (no scene transaction), deferred while a write would trap; SpringBoard's own app-view updates are held for 1 s after each switch (appview670 "phonesize675 scene size change"), as after a card drag. Touches go through the host view's scale like the existing content-scale setting (the window server maps them; nothing inside the app is moved).
- Off (back to exactly 4.5.674): create /var/mobile/.dynamicstage-phonesize675-off. Apps: /var/mobile/.dynamicstage-phonesize675-apps, one bundle id per line, replaces the default (Beeper); apps with the DynamicStage app dylib (Messages, Phone) are always skipped. Test knob: /var/mobile/.dynamicstage-phonesize675-pinoffset (points added to the keyboard top put on the card bottom, default 0).
- Skipped (logged why) while minimized, rotated, with the search card open, with the camera layout on, or before the app view exists. Log lines all start "phonesize675": build/on-off status and apps, ON with scene size / scale / card / keyboard top / visible part / card-to-app touch mapping, "scene size sent", "read back 0.5 s later", "keyboard while typing", "keyboard top A -> B", OFF with the reason, skipped with the reason.
- Unchanged: keys674, the 4.5.673 Messages camera, the 665/668/670/674 crash guards, presence670/674, the stage card size, zero app-switcher hooks. Messages, Phone, Messenger and Signal are untouched unless allowlisted.

**4.5.674**
- SpringBoard crash (SIGTRAP) fixed: both 4.5.673 crashes (Crashsnstuff.txt, 23:09:10 and 23:46:53 NZDT), mapped with the 4.5.673 debug symbols (kept from now on), stop in the same place: SpringBoard's own app-view settings handler called from the stage's hook (Tweak.xm:764). Both came right after Beeper's card was put back into the display layout (after a corner pull / coming back from minimized) as role=6 level=1050: the stage had copied that role from a full-screen system element SpringBoard published earlier (template=1). Every earlier log, and every 4.5.673 session without that template, used role=1 level=1 and never crashed there. With the wrong role SpringBoard re-describes the card's scene (status-bar overrides, event-deferring targets) and its handler traps. The stage now only learns the template from an ordinary app element (role 1, level 0-10) and logs "presence674 ignored ..." otherwise; every publish (not only moves) also starts the 1 s app-view hold.
- Beeper keyboard band (apps without the DynamicStage app dylib): new keys674. The card's scene host (UIKit's _UISceneLayerHostContainerView) is told it cannot show the staged app's keyboard layer (-_canShowKeyboardLayer answers NO), so no keyboard layer is drawn inside the card; the keys stay in SpringBoard's keyboard host at the bottom of the phone. Apps with the dylib (Messages, Phone, injected Messenger / Signal) keep the 4.5.664 handling. Off: /var/mobile/.dynamicstage-keys674-off. For every staged app: /var/mobile/.dynamicstage-keys674-all. Log lines "keys674 ...".
- Clearer log text: relay668 no longer says the SpringBoard-side camera layout covers a non-injected app (it is opt-in); camera658 says an app is in the dylib filter instead of "injected".
- Unchanged: the 4.5.673 Messages camera split fill, the 4.5.664 keyboard fix, 4.5.666 taps, the dial pad, the 665/668/670 crash guards, presence670, zero app-switcher hooks, the stage card size.

**4.5.673**
- Messages camera on a card now FILLS the card by default and Apple's top bar is on it too. Apple's camera extension always lays out phone-shaped (430x932, 4.5.666 showed it ignores the card size), so at the card's width it is 910pt tall in a 458pt card. Instead of cropping the top (4.5.668) the card now leaves out the MIDDLE of the preview: card y 0..107 shows Apple's top bar (close X, flash, Live and, after a shot, the review screen's top controls), the rest of the card shows the bottom of the camera (lower preview, mode row, shutter, flip, zoom). Same scale everywhere, nothing stretched, no black bars.
- Why one band is a mirror: the camera is drawn by Apple's extension in its own process and the window server hands a touch to whichever process owns the layer under the finger at touch-down; Messages cannot pass a touch on, and one extension layer can only be in one place. So one band is the real camera and the other is a live copy of it (_UIPortalView, same pixels, same place). The shutter band is real when the camera opens. Touching the top band makes the top band real (the real camera slides under it so Apple's buttons are exactly where they were drawn; the picture does not change, the band blinks once) and the next tap there is Apple's own button; touching the bottom band switches back. Every button shown is Apple's own and works; a mirrored band needs one touch first.
- No stage Done and no Fit/Fill pill while the split view is up (Apple's own close / Retake is reachable). If the live copy cannot be made on this iOS (_UIPortalView missing) the camera falls back to the 4.5.668 fill with the stage Done and the Fit pill. FIT can still be forced with the defaults key DynamicStage673MessagesCameraFit in Messages.
- Log lines: "layout673 ... FILL split ..." (geometry, which band is real), "layout673 ... band touched ..." (each switch), "layout673 ... no live mirror ..." (fallback).
- Unchanged: the 4.5.664 keyboard fix, 4.5.666 tap routing, the Phone dial pad, the 4.5.665/668/670 crash guards, presence670, the 4.5.672 keys revert, zero app-switcher hooks, the stage card size.

**4.5.672**
- 4.5.671's card-position change for apps without the DynamicStage app dylib is off again; the keyboard moves are exactly 4.5.670's (top card drops onto the keys, bottom card lifts until it clears them). The 4.5.671 test showed the empty band under Beeper's message bar does not depend on where the card is. The code stays in for testing only: create /var/mobile/.dynamicstage-keys671-on to turn it back on.
- Beeper's band under the message bar while typing, found: nothing SpringBoard sends Beeper changes when the keyboard shows. Its scene keeps frame {{0,0},{420,458}}, the card's safe area and portrait orientation (the scene override rewrites only those, and only to the card values); the "scene extension for the keyboard" is a no-op; the keyboard overlap inset (stageSafeAreaInsets) only exists with two stacked cards; no keyboard frame, intersection or bottom inset is written into any staged app. "kept quick bar 346pt" only decides how far SpringBoard moves the card; it is never sent to the app. The band is Beeper's own keyboard avoidance: Beeper owns its keyboard (the keys are drawn by Beeper and only displayed by SpringBoard at the bottom of the phone), so UIKit inside Beeper posts Beeper's own keyboard notes and Beeper pads its composer for them. In Messages, Messenger and Signal the app dylib swallows those notes inside the app, which is why they show no band; the dylib is not running in Beeper ("relay668 ... NOT running in this app"), although Beeper is in its filter. Those notes are made inside Beeper's process, so SpringBoard cannot edit them.
- New "keys672 <app> keyboard up ..." line, once per keyboard session of a staged app: the keyboard frame, the card, the app's current scene frame / safe area / orientation, whether the app has the dylib, and what that means. Diagnostics only, nothing is written.

**4.5.671**
- Beeper's quick bar / composer no longer rides up inside its card when the keyboard shows. The 4.5.670 log (Quickbar.txt) and screenshots show why: DynamicStage's app dylib is not running in Beeper ("relay668 ... NOT running in this app"), so nothing inside Beeper swallows its keyboard notes and Beeper slides its own composer for the keyboard, while the stage also moved the card onto the keys (single top card dropped 95pt to y=100, bottom 558 = keyboard top 586 - 28; a bottom-half card lifted 369pt to the same place). With the card sitting on the keys the composer came up ~82pt and left an empty band under it (card y 376-458). Measured band = card bottom on screen minus (screen height - card height) = 558 - 474 = 84. The keyboard frames themselves are normal (Messages gets the same 586/346), the scene stays 420x458 at origin 0, and no overlap inset is set for a single card.
- Fix (SpringBoard only, every app without the DynamicStage app dylib, not just Beeper): the stage no longer brings such a card down onto the keys. A single card on the top half stays where it rests while the keyboard is up; a single card on the bottom half rises to the top half's resting place (bottom 463) instead of stopping on the keys. The card size never changes. Apps with the dylib (Messages, Phone, injected Messenger / Signal / Beeper) keep the 4.5.670 keyboard moves, as do picker search, split and the third stage. New "keys671 ..." log lines say when this applies and what 4.5.670 would have done; "top drop ... keys671selfAvoid=1" / "stack slot ... keys671selfAvoid=1" mark it on the lift lines. Opt out (back to the 4.5.670 moves): create /var/mobile/.dynamicstage-keys671-off.
- Everything from 4.5.670 is kept: presence670 publisher, drag-settle holds, appview670, sbcam opt-in, Messages camera Fit / Fill, all crash guards. No app-switcher hooks.

**4.5.670**
- SpringBoard crash (SIGTRAP) after dragging a card: the 4.5.669 crash (log 222.txt, 18:36:57), symbolized against the 4.5.669 debug symbols, is the same frame as 4.5.667: SpringBoard's own -[SBAppViewController sceneHandle:didUpdateSettingsWithDiff:previousSettings:] called from the stage's hook (Tweak.xm:714). The lines before it: Messages' scene got deactivation reasons 0x20, then a card drag took Messages out of the display layout ("card moved") and put it back at a fractional mid-drag frame ({{-11.67, 36}}), and SpringBoard's next app-view update trapped. Now a card's display-layout element is never taken out and put back during a drag: it stays where it is until the drag has settled (1.2 s), then moves once, at whole points, with the new element added before the old one is removed (at most every 2 s). While Live, the app view no longer receives SpringBoard's updates during a card drag, within 1 s of the stage moving / removing a layout element, or while the scene has deactivation reasons (held like the home-gesture and call holds; the scene itself still updates). The 4.5.668 fix stays.
- Beeper camera black: not the 4.5.669 phone-size layout (no "sbcam669 ON" line in the log). After the respring at 18:37:28 the display layout publisher was never known ("camera658 com.beeper.chat.ios wants the camera but the display layout publisher is not known yet" every 2 s), so the stage could not put Beeper's card into the display layout and the camera server refused it. The stage only learnt the publisher from SpringBoard's own addElement calls, and after a respring it is loaded after SpringBoard made them. It now asks SpringBoard directly (SBIconController's main window scene / the main SBWindowScene's displayLayoutPublisher, or its scene context), at start, on the first staged card, and every few seconds until found: "presence670 display layout publisher acquired via ..." line.
- The SpringBoard-side phone-size camera layout (sbcam668/669) is off by default; opt in with the file /var/mobile/.dynamicstage-sbcam-on. The green-dot reader keeps logging ("sensor ..." lines).
- Messages camera on a card: Apple's camera extension always lays out phone-shaped (the 4.5.666 log showed a card-sized view leaves its shutter row below the card), so it cannot both fill the card and show every button. Default is now the whole camera UI on the card, every button visible and tappable (only the empty status-bar and home-indicator strips are cropped), Apple's own close / Retake used, no stage Done. A small "Fill" pill switches to the 4.5.668 width fill (with the stage's Done), "Fit" switches back; the choice is remembered. Log lines: "layout670 ...".
- Unchanged: the 4.5.664 keyboard fix, the 4.5.665 home-swipe fix, the Phone dial pad, the boot / call / home-swipe guards, zero app-switcher hooks, and the stage card size.

**4.5.669**
- Beeper camera on a card: SpringBoard now actually sees which app is using the camera. The 4.5.668 log showed why it never did: the green-dot data SpringBoard receives on iOS 16 (STUIDataAccessStatusDomainData) prints its list as "attributions", but has no method by that name. Its real accessors are -activeAttributionData, -dataAccessAttributions and -attributionListData (an STListData whose items are -objects), so every read found nothing ("items=0") and the 4.5.668 phone-size camera layout for Beeper never switched on. The reader now uses those real accessors (checked against iOS 16 class dumps): the camera is the attribution's cameraCaptureAttribution (or dataAccessType 1), the app is attributedEntity.bundleIdentifier, "recently used" dots are ignored. Fallbacks: any list-like object (accessors, fast enumeration, ivars), and finally the data's own text ("type = camera ... bundleIdentifier = ...").
- A second, independent camera signal: SpringBoard's own green-dot model, -[SBSensorActivityDataProvider setActiveSensorActivityAttributions:] / -activeSensorActivityAttributions (sensor 0 = camera), read when it changes and once a second while a card is up.
- New log lines: "sensor <bundle> camera on via <source> ..." / "sensor <bundle> camera off ...", "sbcam669 <bundle> phone-size camera layout ON/OFF ...", and once per SpringBoard launch "sensor669 domain shape: ..." with the data's classes, ivars and full text, plus "sensor669 SpringBoard attribution shape ...".
- Unchanged: the 4.5.668 crash fix and Messages camera fill, the 4.5.664 keyboard fix, the 4.5.665 home-swipe fix, the Phone dial pad, the boot / call / home-swipe guards, zero app-switcher hooks, and the stage card size.

**4.5.668**
- SpringBoard crash (SIGTRAP) when dragging a card around a camera: the 4.5.667 crash log, symbolized against this build's debug symbols, stops inside SpringBoard's own app-view settings handler (-[SBAppViewController sceneHandle:didUpdateSettingsWithDiff:previousSettings:]) called from the stage's hook (the same frame as the 4.5.662 and 4.5.663 safe-mode logs). It is not the 661/667 display-layout republish or the camera fit. Every one of these crashes followed "kept the open stage inside its card while another app opened": the last place the stage still answered SpringBoard's phone-size update of a hosted app as "done" without applying it, which leaves SpringBoard's bookkeeping out of step with the scene, so its next settings diff for that app view traps. That update now always lands at card size (card frame written over the phone frame, committed foreground kept, then the card refit), as 4.5.659 / 4.5.665 already did in narrower cases ("home668 ..." log line). The app view's foreground hold now also checks the real foreground flag, and the last app-view updates are kept in the crash log's recent lines ("appview668 ...").
- Beeper camera on a card: the shutter now shows. No Beeper line has ever reached a log (no ctor, no hello, no trace file in its container), so DynamicStage's app dylib is not running inside Beeper at all, and the 4.5.667 camera fit inside the app never ran. The fix no longer needs anything inside the app: while the green dot says a staged app with no DynamicStage app dylib in it (Beeper, Messenger, Signal) is using the camera, SpringBoard gives that app the phone's full size and shows it at the card's width, bottom-aligned ("sbcam668 ... phone-size camera layout ON/OFF" lines), so the app lays its camera out exactly as full screen and its shutter row lands on the card; it goes back to the card size when the camera stops, a keyboard comes up, the card is hidden / parked / minimized, the phone locks or a call comes in. Also: the green-dot reader could not read iOS 16's attribution list (every 667 log said "items=0"), so a staged app's camera was never attributed; fixed.
- Beeper / Messenger / Signal diagnostics: the app dylib now drops "mapped" and "ctor" markers in the app's own container, and SpringBoard reports them ("relay668 <bundle> app dylib marker: ..." or "... DynamicStageApp.dylib is NOT running in this app ..."), so the next log says for certain whether the dylib loads there.
- Messages camera on a card: fills the card's width now (4.5.667 fitted the whole phone layout into a ~50% column). The extension still lays out at the phone's size, shown at the card width and bottom-aligned, so the shutter row, mode row, flip and zoom stay on the card and the top of the preview is cropped. The extension's own close button is in that cropped band, so the stage puts a "Done" button at the top right of the card that closes the camera.
- Unchanged: the 4.5.664 keyboard fix, the 4.5.665 home-swipe crash fix, the 4.5.666 tap routing, the Phone dial pad, the boot / call / home-swipe guards, zero app-switcher hooks, and the stage card size.

**4.5.667**
- Beeper camera on a card: the shutter row now shows. The 4.5.666 log ("Buttonnot") has Beeper's camera running on the card (green dot "type = camera; state = active" at 16:13:16) but no camera layout at all: no layout664 line, no camera event from Beeper. The 4.5.664 rule only switched the camera layout on when the stage had seen the app start a capture session or a screen with a camera-like name, and Beeper's React Native camera is neither, so its phone-tall camera screen stayed cut off at the card's bottom. Now a live camera preview that covers at least 30% of one of the app's normal windows counts as "camera open" on its own (never a keyboard or text-effects window, never while a keyboard is up), checked on camera events, on layout passes and once a second while the app is staged. Camera screens presented modally (React Native modals, full-screen modals, image pickers) get the same FILL + bottom-align as the root.
- Messages camera on a card: the buttons now work. Every tap reached Apple's camera extension (tap666 "... hit=_UIRemoteView vc=_MSMessageExtensionRemoteViewController remote=1"), and the close X at the top worked, but taps on the lower card did nothing: the extension lays its camera out for the phone's full height inside a card-sized view, so the shutter row sat below the card. While that camera is up (no keyboard), the view holding it now gets the phone's size, so the extension lays out exactly as on the phone, and is scaled to fit the card whole (close X at the top, shutter row at the bottom).
- Logs: Beeper, Messenger and Signal could never write the shared log from their sandbox, so none of their app lines ever appeared. Their lines now go to the app's own tmp folder and SpringBoard copies them into the log ("relay667 ..." lines, then the app's own "camera658 / layout664 / layout667 / tap666" lines). New "layout667 <bundle> camera layout ENGAGED ..." and "... camera layout geometry ..." lines prove the camera layout engaged (Beeper included), and "layout667 com.apple.MobileSMS remote camera fit ON / off ..." for the Messages camera.
- Unchanged: the 4.5.666 tap routing and tap666 lines, the 4.5.665 home-swipe crash fix, the 4.5.664 keyboard fix, camera presence, the Phone dial pad, the boot / call / home-swipe guards, zero app-switcher hooks, and the stage card size.

**4.5.666**
- Camera buttons on a stage card. The 4.5.665 log shows Messages on a card with its camera open (15:55:54 to 15:56:02): that camera is Apple's Camera extension shown inside Messages (CKFunCameraViewController, MSMessageExtensionBrowserViewController, _MSMessageExtensionRemoteViewController). Its preview and its shutter, flip, flash and close buttons belong to the extension's own process. No capture session ran in Messages itself and no 4.5.663/664 camera layout line was logged, so the camera layout scaling was not involved, and no rim651 line was logged during the camera, so the stage's rim did not take the taps. What sat over the camera was Messages' own keyboard windows, which the stage keeps card-sized on top ("app left UIRemoteKeyboardWindow at {{0, 0}, {420, 458}}" as the camera opened), plus the stage's keyboard hit filters that pass a touch down to the window below. That works for Messages' own views but a touch Messages takes is never handed on to the extension, so the buttons did nothing.
- Now, while a camera screen is up on a card and no keyboard is up, card-sized keyboard / text-effects windows that hold neither the camera nor a remote view are taken out of the touch path (hidden) and put back the moment the camera screen goes or a keyboard comes up; the stage's keyboard hit filters step aside and plain UIKit hit testing is used. Applies to every staged app with a camera screen (Messages, Beeper, Signal, Messenger), not to the Phone dial pad.
- New log lines: "tap666 <bundle> camera screen up/gone; windows: ...", "tap666 <bundle> camera up: <window> taken out of the touch path", "tap666 <bundle> put n keyboard window(s) back (...)", and one line per window per tap: "tap666 <bundle> point=x,y window=<class> lvl=… hit=<class> vc=<owner> remote=0/1 path=…". No tap666 line for a tap means the touch went straight to the camera extension (or to SpringBoard).
- Unchanged: the 4.5.665 home-swipe crash fix, the 4.5.664 keyboard fix and camera layout, camera presence, the Phone dial pad, the boot / call / home-swipe guards, zero app-switcher hooks, and the stage card size.

**4.5.665**
- Fixes the SpringBoard safe-mode crash (SIGTRAP) after a home swipe with an app on the stage followed quickly by a pull from the stage corner (the 4.5.662 and 4.5.663 safe-mode logs: "corner pull picked up from the system gesture", "parked apps stopped following the home transition", "kept the open stage inside its card while another app opened", then the crash). The corner pull is taken over from SpringBoard's own system gesture, and SpringBoard's home / hand-back transition was still finishing for that app. Its phone-sized scene update was treated as "another app opened" and refused (marked done without being applied), leaving SpringBoard's transaction half applied. 4.5.659 fixed the same kind of refusal, but only for the stage's own activation of the app.
- Now, while a corner pull adopted from the system gesture runs (and 1.5 s after), for 3 s after the parked apps are handed back, and for 4 s after a home gesture ends, that update is never refused: it lands at card size (the card frame is written over the phone frame and the app's committed foreground is kept, like 4.5.659), then the card is refit. New "home665 let SpringBoard's update of … land at card size (<reason>), not refused" log line. Outside that window, opening another app still keeps the stage inside its card as before. No card refit runs while that corner pull is in progress.
- Unchanged: 4.5.664 keyboard fix, camera presence and layout, the Phone dial pad, the boot / call / home-swipe guards, zero app-switcher hooks, and the stage card size.

**4.5.664**
- Fixes the keyboard not coming up in any staged app (and the stage picker search). The keyboard log showed every keyboard raise as "video=1" and the stage window never once taking the key window: the stage believed a video was playing in a full-screen app under it, so it deliberately stood back (no key window, keyboard window never raised or docked, picker search "editing over video"). That check answered yes for any audio playing while no full-screen app was open (music or a podcast on the home screen) and for media in the staged app itself. It now only answers yes when the full-screen front app is the one playing and it is not on a stage card. A new "keyboard664 video-on-screen=…" log line gives the reason, and each "raise keyboard" line carries it too.
- The 4.5.662/4.5.663 camera layout in staged apps no longer runs on guesses. 4.5.663 treated a camera-like screen name alone (including Messages' app strip and photo screens) as "camera open", kept a counter that could stay stuck, and re-checked by walking every window's layers on every screen-size read. A false "open" handed the app the real phone screen and scaled its windows. Now the camera layout is on only while a video capture session is running, or a live camera preview is on screen; it is decided when camera events happen (not per screen read), it steps aside while a keyboard is up, and it never touches keyboard, text-effects, input or above-status-bar windows. New "layout664 camera layout on/off: <reason>" lines.
- Unchanged: 4.5.663 FILL + bottom-align shutter fix while the camera is really open, 4.5.661 camera presence, the Phone dial pad, the boot / call / home-swipe guards, zero app-switcher hooks, and the stage card size.

**4.5.663**
- Fixes the take-picture / shutter button still missing in most staged camera UIs after 4.5.662. That build scaled the camera screen with FIT (letterbox) and centered it, and only on the key window — so Beeper, Signal, Messenger and similar still lost the bottom capture control (often hosted in a secondary window, or clipped once UIKit cleared the transform).
- Now uses the same approach as the Phone dial pad: FILL scale into the card and bottom-align so the shutter end of a phone-tall layout stays on the card (top chrome may clip a little). Every non-keyboard window in the staged app is scaled, not only the key window. A live camera preview layer also counts as "camera open" even when the view-controller name does not say Camera. Bottom safe-area inset is capped while the camera is open so the home indicator does not push the shutter off the card.
- Stage card size still does not grow. Phone dial pad, 4.5.661 camera presence / arbiter, and all guards are unchanged.

**4.5.662**
- Fixes incomplete camera UI on stage cards (missing shutter / flip / gallery buttons), especially in Beeper. After 4.5.661 the preview often came back, but camera chrome designed for a full phone was still being forced into the short card (~420×458): the app dylib clamped any phone-tall root back to the card height and set clipsToBounds, so the bottom controls were cut off. Other apps were "mostly OK" for the same reason — partial chrome, not a full layout.
- While a staged app's camera is open (camera screen appears, or a capture session is running), that app keeps real phone metrics (same idea as the Phone dial pad) and its root is scaled to FIT inside the card so every control stays visible. The stage card size does not grow. When the camera closes, layout returns to the normal card metrics.
- Covers Beeper, Signal, Messenger and Messages (injected apps). Phone is unchanged (it already had its own fill path). All 4.5.661 camera presence / arbiter / logging, call / boot / home guards, and the switcher no-op are kept.

**4.5.661**
- A real attempt at the black camera in staged apps. Until now the stage only put a card into iOS's "what is on screen" list (the display layout the camera server reads) after the app inside it reported that its camera started. The 4.5.660 log showed that report never comes: Messages' camera runs in a separate Messages extension process that DynamicStage isn't in, so the card was never listed and iOS treated the camera's owner as not on screen.
- Now every visible stage card (open, not parked in a corner, not minimized) is listed as an on-screen app straight away, camera or not, using the same mechanism as 4.5.652. It comes out when the card hides, parks, minimizes or closes, when the phone locks, as soon as the staged Phone's call key is tapped and for the whole call, and while the home / app switcher gesture has the screen (it comes back the next time you use the stage). It never takes keyboard focus and writes nothing to the app's scene; the status bar and notch are not touched.
- If the full-screen app behind the stage is itself using the camera (the green dot names it), cards are not listed, so that app's camera isn't cut off as "multiple apps on screen".
- Camera extensions: if the green dot shows a process using the camera that is neither on a card nor the full-screen app (for example the Messages camera extension) while a card is visible, that process is listed too, at its host card's frame.
- New "camera661" log lines: "sensor <app> camera on / off" (which process iOS's green dot says is using the camera), and "presence <app> in / out of the display layout" with the reason. Every camera660 line now also carries the app's camera permission (auth=authorized / denied / not-determined / restricted).
- If this causes problems with full-screen apps, create the empty file /var/mobile/.dynamicstage-no-camera-presence (e.g. with Filza) to switch the listing off without reinstalling.
- Unchanged: the boot guard, the call guard, 4.5.656's call-screen hiding, the 4.5.657 switcher no-op, 4.5.659's home / wake fix and all 4.5.660 logging.

**4.5.660**
- Diagnostic build for the black camera inside staged apps. Nothing about how the stage or the camera works has changed; this build only gets the camera events into the DynamicStage log, as new "camera660" lines.
- The 4.5.659 log had no camera lines at all, for two reasons. An app that was already running before you put it on a card never told SpringBoard its camera hooks were there: it only says so 1.5 s after it launches, and SpringBoard ignores that from an app that isn't on a card yet. And Signal, Beeper and Messenger can't write the log file from inside their sandbox, so their own camera lines never reached it (only SpringBoard and Messages lines did).
- Now SpringBoard asks an app for its camera hook state 1.5 s after putting it on a card, and the app also reports by itself once it sees it is staged (never during the home or app switcher gesture). Every camera event inside the app (hooks installed, startRunning called and returned, running state, interrupted with iOS's reason code, interruption ended, runtime error code, multitasking camera access on or refused, retry, stop, app going to the background) is sent to SpringBoard through a small per-app Darwin notify channel, and SpringBoard writes it to the log. Each line also says whether a camera preview layer is attached, is in the view tree, has a size and is visible, so "running but black" can be told apart from "never started".
- On each start or interruption SpringBoard also writes its status line (published to the display layout, in the layout, how many apps the layout holds, the card's scene foreground / occluded state) and RunningBoard's "visible" line, now as camera660. Everything is rate limited, and nothing new runs during the home gesture or while the switcher has the screen (those events are read afterwards).
- Unchanged: the boot guard, the call guard, 4.5.656's call-screen hiding, the 4.5.657 switcher no-op and 4.5.659's home / wake fix.

**4.5.659**
- Fixes the SpringBoard crash (safe mode) when you pull a minimized stage back from its corner right after swiping home with two stages. With two stages, the app on the parked card is handed to iOS's own home transition while you swipe home, and handed back shortly after. Pulling that card back from the corner woke the app straight away: the stage switched its app view back to live and activated it while iOS was still finishing that hand-back. iOS answered with a full-screen update for the app, the stage refused it as "another app opening", and SpringBoard crashed (4.5.657 log: "org.whispersystems.signal had been put in the background off the stage and was woken", then "kept the open stage inside its card while another app opened", then SIGTRAP).
- Now the stage waits until that hand-back has settled (up to 3 s after the card stopped following the home transition) before waking the app. Until then the card shows its last picture. Every stage path that asks for the wake at the same time is merged into one. Once the app view is already live after a hand-back, its mode is not set again; it is only activated.
- iOS's answer to that activation is no longer refused. It lands with the card's size written over the full-screen frame. The "kept inside its card" refusal still applies when a different app opens.
- New "home659" log lines: wake held / woken after the hand-back settled / wake dropped, activation-only, and "let the stage's own activation update land". All of 4.5.658's camera658 logging is kept. The 4.5.657 switcher no-op, the call guard, the boot guard and 4.5.656's call-screen hiding are unchanged.

**4.5.658**
- Diagnostic build for "camera still not working in staged apps". Nothing about how the stage or the camera works has changed; this build only writes better "camera658" lines to the DynamicStage log, so the next test shows exactly where the camera stops.
- The camera handling from 4.5.652 only exists inside Messages, Messenger, Signal, Beeper and Phone (the apps DynamicStage is injected into). Any other app on a card (Instagram, WhatsApp, Snapchat, Safari, a photo picker shown by such an app) gets no camera handling at all, and until now left nothing in the log. Now every app that goes onto a card gets a line saying whether it is one of the injected apps.
- An injected app now says "camera hook loaded" once its camera hooks are in, and reports what startRunning itself returned (running / interrupted).
- On every camera event (start, interrupted with reason, interruption ended, error) and every 12 s while a staged camera runs, one status line: whether the card was put in the display layout and is actually in it, how many apps the layout holds, which card hosts the app, the stage's foreground flag, the running assertion, the scene's foreground / occluded / backgrounded state, SpringBoard's process state, and a second line with RunningBoard's task state and whether it counts the app as visible.
- The camera lines from inside an injected app (hooks installed, startRunning, interrupted with reason) now also appear in the copied DynamicStage log, not only in Console.
- From the 4.5.657 camera log: opening Messages' camera on a card never reached the 4.5.652 camera handling at all (no start event, so the card was never put in the display layout). Messages' camera appears to run in a separate Messages extension process that DynamicStage isn't in. The new lines will confirm it.
- Heartbeat lines now carry the real running / multitask state (they always said running=0 before). Nothing new runs during the home gesture or app switcher; the 4.5.657 switcher no-op, the call guard and the boot guard are unchanged.

**4.5.657**
- DynamicStage stays out of the iOS app switcher. Swiping an app away used to run the stage's "app closed" handling inside the swipe (picker, shelf, corner icon, tearing down the hosted app), and a few hooks asked SpringBoard's switcher controller whether it was open: from every card's home pill and on a 0.3 s timer for as long as the switcher stayed up. All of that is gone. The switcher is never asked anything, and the hooks SpringBoard runs for every switcher card (home pill, status bar, scene views, scene updates, display layout, gesture checks) now return on a plain flag read unless a stage card is actually on screen.
- An app you swipe away in the switcher that was on the stage is handled the next time you use the stage (open it, pull a card out, pick an app, tap a card), not during the swipe. Until then the stage treats it as gone, so opening that app again full screen works normally and it is never woken or relaunched by the stage. Its corner icon stays until you next touch the stage, then the picker comes back as before. If a stage card is on screen when an app dies (a crash), it is handled right away.
- The picker's "recent apps" order is updated on the next stage use instead of every time the front app changes (that also ran as the switcher closed).
- Kept: the boot guard, the call guard and 4.5.656's call screen, and the home-swipe crash protection (the start of a swipe off the bottom edge still raises it, now only when the stage holds an app or is on screen).

**4.5.656**
- The call screen shows again when you call from the staged Phone app. The stage window sits above iOS's call screen (InCallService is the main full-screen app, far below the stage), so an open card covered it and took its touches, and since 4.5.653 the crash guard also held the staged Phone's updates from the moment the call key was tapped, right through iOS's switch to the call screen. Now, as soon as the staged Phone starts a call (or any full-screen call screen comes to the front while the stage is open), the stage and its edge notch are hidden. Nothing is minimized, moved or resized, and no scene is touched, so the call screen appears full screen as normal with its status bar, home bar and gestures. When the call screen goes away (call ended, or you swipe it away to keep talking in the background), the stage comes back exactly as it was. If the call screen does not come to the front within 10 s, the stage comes back on its own.
- The 4.5.653 crash guard is narrower. Staged app updates are let through for the first 1.5 s after the call key (iOS switching to the call screen, which never crashed), and are held once the call screen is in front, until 4 s after it goes. The 4.5.652 crash came 2 s after the call screen was already up, so that update is still held. Calls placed in the stage card stay off.
- New rate-limited "call656" log lines: call started, stage hidden, call screen in front / left, number of held updates, stage back.

**4.5.655**
- Less lag in the normal iOS app switcher, with or without a stage on screen. Several SpringBoard hooks that run for every switcher card on every frame of the swipe (the home pill on each card, every status bar, scene updates, window frame changes) first checked the on-disk kill switch with three file-system calls each time. That check is now cached for 1 s, and the home pill hooks leave right away when no stage is visible or the switcher is moving.
- The stage no longer touches status bars it did not hide. Every status bar in SpringBoard that laid out (Home Screen, switcher, Control Center) used to be forced back to fully visible, which fought SpringBoard's own fades during the switcher transition, and each of their windows got an extra tap recognizer. Now only a bar the stage hid while a card covers the top is shown again, and the tap is only added to a bar that is actually hidden.
- Removed SpringBoard hooks that did nothing but call the original method (UIView alpha and hidden, UIWindow hidden and frame, keyboard frame). The window frame hook also asked the stage manager on every frame change.
- Staged-capable apps (Messages, Messenger, Signal, Beeper, Phone) no longer read the stage state file every 0.35 s while not staged when the notification state already answers, and window frame changes no longer rewrite an unchanged corner radius and transform.

**4.5.654**
- Less lag in staged apps, most of all with two stages open (Beeper especially). Each staged app asked iOS's notification server (notifyd) for its card size on almost every layout question: every screen or window size lookup and most view frame changes made 2 blocking round trips to notifyd, or 3 for the app in the second stage, and with two stages both apps did it at the same time. The card size is now remembered and read again only when SpringBoard announces a change, when the app's scene is resized, or at most every 0.25 s.
- A card size change from SpringBoard now re-lays out each staged app once instead of twice. SpringBoard sends its two stage notifications as a pair, and each one used to trigger its own full layout pass of every window.

**4.5.653**
- Fixed SpringBoard going into safe mode when you call from the staged Phone app. As the call screen came up, SpringBoard re-described the Phone scene hosted in the card, and its own app-view handler asserted (SIGTRAP) on that update. While a call screen is coming up or is on screen, staged app views now hold those updates, the same way they already did during the home swipe. The app keeps running in the card and updates again about 4 s after the call screen closes. The staged camera's display-layout entry also stays out while a call is up.
- The call screen no longer tries to go into the stage card. On iOS 16 it is the main full-screen app (InCallService in SpringBoard's main app layout), so there is no window that can safely be scaled into the card. 4.5.650 to 4.5.652 never managed it either; their log only said "cannot contain it". The call screen shows full screen as normal.
- The stage and its edge notch no longer vanish after a crash. A crash within 15 s of a respring used to leave the boot guard raised, and every later SpringBoard start then skipped DynamicStage completely (no stage, no notch, no log) until a reinstall. The guard now clears after 8 s, and a start it does skip re-arms it, so the next respring brings DynamicStage back. Installing this build also clears it.

**4.5.652**
- The camera works in staged apps (the app's own camera, the photo picker's camera, QR/document scanners). iOS's camera server only streams to an app that SpringBoard's published display layout shows on screen, and a stage card lives inside SpringBoard's own window, so the staged app was treated as "in background" and its capture session was interrupted before the first frame: a black preview. Now, while a staged app's camera session is running, its visible card is published into that display layout with the card's frame (and its scene is kept unoccluded with no deactivation reasons), and the staged app asks for iOS's multitasking camera access, starting an interrupted session once more after the layout update. It all goes back as soon as the camera stops, the card is minimized, parked, hidden or closed, the app goes to the background, or the phone locks. The green camera dot and the camera permission prompt work as usual. Only one app can use the camera at a time: while a staged app has it, the full-screen app's camera pauses and resumes on its own when the staged camera closes. Covered: the apps the in-app part of DynamicStage loads into (Messages, Messenger, Signal, Beeper, Phone). Rate-limited "camera652" log lines show the interruption reason, the scene's foreground state and the path taken.

**4.5.651**
- The drag rim around a stage card is easy to grab again over any app. A touch is sent to an app or to SpringBoard by the window server before SpringBoard can say "that's the rim": the rim band was see-through, so a grab there went to the full-screen app behind the stage (or, just inside the card edge, to the app in the card) and only a touch right on the thin outline line moved the card. The rim now has invisible "solid" strips 16pt outside and 14pt inside the card edge that always win the touch for the stage drag, whatever app is in front or in the card (games and Metal apps included). Rim drags also take priority over the picker's scrolling and taps that started on the rim, and system edge gestures that start on the rim are held. The home bar, the very top edge (Notification / Control Center), the bottom edge (home, switcher, corner pull), the keyboard and the + button keep working. A call screen shown in the card now leaves the rim band free.

**4.5.650**
- Staged Phone dial pad is the same every time. The fit used to depend on when it ran: the drawn key circle was measured before Phone had laid the keys out (so some opens used the taller button box and got different key sizes and row gaps), relayouts that did not touch the app root (typing the first digit, back to the Keypad tab, resume) never re-ran the fit or refreshed the tap list, and passes could run before the card size was final. Now one coalesced, idempotent pass re-runs after any Phone relayout, waits for the card to settle, keeps the measured key shape, always places call and delete, and rebuilds the tap list every pass. Same 4.5.649 look. Each pass logs to /var/tmp/com.recreated.dynamicstage.phone-fit.
- A call started from the staged Phone app now shows its call screen inside the stage card (scaled into the card; the card size never changes). Incoming calls and calls started outside the stage stay full screen. The call screen goes back to normal when the call ends, the card is minimized or closed, or you swipe home.
- Less lag swiping up from the home bar into the app switcher: the stage no longer re-applies minimized cards, clips switcher cards, pins keyboard hosts or re-reads the Phone log on every frame of the swipe, and staged apps hold their own relayout until the swipe ends.
- The search bar in the stage app picker brings the keyboard up on every tap: a stuck "card still opening" flag no longer blocks editing, a tap on the magnifier or padding focuses the field, and tapping a field whose keyboard was taken away asks for it again.

**4.5.649**
- Staged Phone: 7, 8, 9, *, 0 and # tap again. Those keys were moved but still sat inside the number pad's own box, so iOS asked the pad which button was hit and it answered with a different key than the one drawn under your finger; the 4.5.648 tap fix trusted that answer. Now a touch on any drawn dial key (all 12 digits, call, delete) always goes to that key. The pad is also packed like the reference shot: rows sit close together (gap about 10% of the visible key, measured on the drawn circle instead of the taller button box), columns spaced like the reference, keys slightly wide (at most 1.3:1) so the pad fills the width without big black gaps, call under 0, delete under #, all above the tab bar. Stage card size unchanged.

**4.5.648**
- Staged Phone: dial keys work again. The keys were moved one by one outside their number-pad/dialer containers, and iOS only passes a tap down to a view if it lands inside the parent's box, so the keys were drawn but every tap was dropped. Taps on a visible, moved key now go straight to that key (the hit area matches the drawn circle). The pad is also packed tighter: rows use a tight Phone-like gap instead of stretching to fill the height, keys are as large as the stage allows (still round), the columns still spread across the card but the gap between keys is capped so small keys no longer float far apart, call sits under 0 and delete under #, and the typed number sits just above 1-2-3. Stage card size unchanged.

**4.5.647**
- Staged Phone: dial pad lifted to fill the stage. 4.5.646 kept a tall status strip plus the full number-field height above the keys, so a big empty black band sat over 1-2-3. Now only a small corner pad and a modest typed-number strip stay at the top, and the 1–# grid plus the call row spread down to just above the tab bar. Call always sits under 0 and delete under # in their own row (never floating over the 7). Same side-to-side width, keys stay round, stage card size unchanged.

**4.5.646**
- Staged Phone: the whole dial pad (1–9, *0#, call/delete) now fits inside the stage above the tab bar. 4.5.645 sized the pad for the full phone height, but the card only shows the bottom part, so the keys came out huge and only 7–call showed. The pad is now sized to the part the card really shows. Keys keep one scale on both axes so they stay round, the columns keep the 4.5.645 side-to-side spread, the rows close up to fit, and the typed number sits just above the pad.

**4.5.644**
- Phone stage fit: stop wiping the root fill transform on every layout (that top-aligned the dialer and hid 7–call/tabs). Uniform device-aspect scale + bottom-align only; dial-grid lift skipped so keypad 1–call + tabs stay on-card like the reference shot; keys stay circular.

**4.5.643**
- Staged Phone keys are round again (no horizontal oval stretch). The Phone window matches the card so SpringBoard cannot stretch the scene, and the UI is scaled with one factor on both axes. Call and delete stay on-card above the quick bar.

**4.5.642**
- Staged Phone dial pad sits lower again so the green call button and delete stay on the card above the quick bar. The lift still uses one transform per key (circles stay round). The typed-number nudge is a modest 16pt.

**4.5.641**
- Staged Phone dial keys are round again. The keypad is scaled as one piece instead of shrinking every part of each key, which cut the circles. It stays lifted above the quick bar so 7, 8 and 9 are clear. The typed number is lifted once instead of creeping up on every layout pass.

**4.5.636**
- Staged Phone lays out at the full display, then one width-fit scale is applied to the root after layout. The keypad stays round. The root is centered on the card so the extra height is cropped evenly. Other apps are not scaled.

**4.5.635**
- Restored the 4.5.616 Phone layout from about 2:40pm. Staged Phone matches the card height, the width is 5% wider than that fit, and the scale is applied again after layout. Messages and the other apps are not scaled.

**4.5.634**
- Staged Phone uses one width-fit scale, so the keypad stays round. The picture fills the card width and the card crops the extra height. Other apps are not scaled.

**4.5.633**
- Staged Phone still fills the height of the card, with the header, keypad, and tabs in view. The width stretch is half of 4.5.613, so the keys are less wide. Other apps are not scaled.

**4.5.632**
- Restored the 4.5.613 Phone layout. Staged Phone is stretched to fill the card on both width and height. Messages and the other apps are not scaled.

**4.5.613**
- Staged Phone is stretched to fill the card on both width and height. The header, keypad, and tabs meet the edges of the stage. Messages and the other apps are not scaled.

**4.5.612**
- Messages and the other staged apps use the card size again. The full-screen metrics were leaking out of the Phone-only path.

**4.5.611**
- Staged Phone is laid out at the full screen size and the whole root view is scaled to fit the card. The header, keypad, and tabs stay in proportion. Other apps are not moved.

**4.5.610**
- Staged Phone lays out inside the card. The root view is set to the card size before the header, keypad, and tab bar are positioned, so Add Number is not drawn in the full-screen area above the stage. Other apps are not moved.

**4.5.609**
- Staged Phone's root view is fitted to the card before the dial pad is scaled, so Add Number and the top of the app stay inside the stage. The dial buttons are still scaled to fit. Other apps are not moved.

**4.5.608**
- Staged Phone's dial buttons are scaled down with their spacing, so the whole grid fits inside the card instead of being clipped at full-screen size. Other apps are not moved.

**4.5.607**
- Staged Phone's dial pad is drawn at 82% so the buttons fit in the card. The grid stays centered, 12pt above the bottom of the card. Other apps are not moved.

**4.5.606**
- Staged Phone is clipped to the card, and the dial pad is shifted up so it sits inside that card. Other apps are not moved.

**4.5.605**
- Back on the 4.5.599 stage. The later shared changes are gone.
- Staged Phone is fitted to the card and clipped there. The whole app is sized to the stage, and it does not draw outside the card. Other apps are left alone.

**4.5.599**
- A phone call no longer drops the stage keyboard. The call was deactivating the staged app, and that resign took the keys down.

**4.5.598**
- Phone is laid out at the card size and clipped to that card. The keypad was still the full screen, so it drew on the Home Screen outside the stage. A minimized Phone stays off screen instead of keeping the open card’s size.

**4.5.597**
- Phone’s number keys are pinned to the top of the stage. They were being fitted inside the keypad’s own box, which already sits in the lower half, so the rows never came up.

**4.5.596**
- Phone’s keypad sits higher in the stage, and the number keys are spread further apart. They were held low in a short band, so the gaps collapsed.

**4.5.595**
- Phone’s keys keep their normal spacing. They were being shrunk twice, so the pad turned into a tight cluster. They now move up under the number and only shrink a little.

**4.5.594**
- Phone’s keypad is scaled again after Phone finishes laying it out, and the key size itself is the card size. The lower rows stay above the tab bar.

**4.5.593**
- Phone’s round keys move up under the number and shrink just enough to clear the tab bar. 7-8-9 and the bottom row were hidden under that bar.

**4.5.592**
- Phone’s keypad sits a little higher in the stage and a little smaller, so the rows under 4-5-6 are on the card. The number at the top stays where it was.

**4.5.591**
- Phone’s keypad keeps its normal shape inside the stage. The keys were squeezed into a short screen, so the pad came out small and uneven.

**4.5.590**
- Phone’s dial pad fits inside the stage. The keys were still the size of the whole phone, so the bottom rows were cut off.

**4.5.589**
- A stage on the top half comes down onto the keyboard and goes back when the keys close. A leftover measurement from the bottom half was leaving it almost where it was, and picker search on the top stage was not moving that card at all.
- Phone’s dial pad fits inside the stage. The keypad was still the size of the whole phone, so the bottom rows were cut off.

**4.5.588**
- The top stage moves once to sit above the keyboard. It was dropping for the short keyboard, then bouncing back up when the full keyboard arrived, and a note from the other stage was throwing it off the top first.

**4.5.587**
- Typing in the top stage lowers that card until it sits above the keyboard, then puts it back when the keyboard closes. The other stage still slides aside.
- With one stage minimized, the stage on screen can sit on the top or the bottom. Bringing the minimized stage back puts it on the half that is free.

**4.5.586**
- Swapping the two stages while the keyboard is up was keeping the sideways slide, so a stage stayed off the left edge and its outline stayed off the card after the keys went away. Swapping now drops that slide before the cards move, and the keyboard parks the card that should leave.
- Dragging starts from the card you see, not the resting spot under the keys. Letting go puts the keyboard slide back on the card that should be out of the way.

**4.5.585**
- Closing Split and leaving the top app full screen lays that app out on the phone. It was still using the split size, so the reply bar sat in the middle until the app was force closed.

**4.5.584**
- Typing in the top stage of two stacked stages slides the bottom stage off the side. The top card was being shifted down onto the bottom one instead.

**4.5.583**
- Typing in one stage no longer slides that stage off the screen as well. A keyboard note from another stage was parking every card, and the card being typed in was left there.
- When the keyboard closes, the stages come straight back. The return was waiting on a slide, and the card that had been typing was skipped.

**4.5.582**
- Typing in the third stage slides the top split off the left and the bottom split off the right. The third stage stays and rises above the keyboard.

**4.5.581**
- Typing in the bottom split slides the top stage off the left and the third stage off the right, the same way typing in the top split clears the other two. The bottom card still rises above the keyboard.

**4.5.580**
- Typing in the top split no longer lifts the bottom stage and the third stage up over it. The bottom stage leaves to the left and the third stage leaves to the right until the keyboard is dismissed.

**4.5.579**
- In split screen with a third stage open, typing in the bottom split slides that third stage off the side of the screen. It comes back when the keyboard is dismissed.

**4.5.578**
- Beeper on the bottom split or the third stage stays above the keyboard when its quick bar expands. A shorter key report was replacing that taller bar and dropping the card back onto it.

**4.5.577**
- Picker search on the bottom stage lifts that card above the keyboard. It was ignored on purpose.
- The third stage’s keyboard is no longer dropped while another app is staged, so that card rises in the middle and in the lower position.
- A short keyboard report is treated as the full keyboard, and a hide that arrives while the keys are still on screen no longer drops the card back onto them.

**4.5.576**
- Copy Logs now keeps the keyboard path. Every UIKit keyboard note, every app focus, every app keyboard frame, and every lift decision is written into the log you copy. The trace from the staged app is included too.
- A keyboard frame reported by the staged app lifts the lower card. A tall keyboard SpringBoard sees while a card is up does the same, instead of being dropped because nobody had claimed it yet.

**4.5.575**
- The lower stage was measured as the top half, so a card at the bottom of the screen was treated as already above the keyboard and never moved. That card now lifts until its bottom clears the keyboard. Beeper no longer skips that lift.

**4.5.574**
- `[LIFT]` records why the lower stage did or did not move for the keyboard: which card, its bottom, the keyboard top, the lift it has, the lift it needs, and whether a scene update swallowed the show. A show that arrives during a scene update is tried again instead of being dropped.

**4.5.573**
- The third stage and the bottom stage were thrown off the screen when the keyboard came up, then snapped back on top of the keys. Both now rise until the whole card sits above the keyboard, and that lift stays. The keyboard still shows.

**4.5.572**
- The keyboard stopped appearing on the third stage and the bottom split. The keyboard changes from 4.5.569 and 4.5.570 are reverted. The keyboard path is the one from 4.5.568 again. The third stage stays the slightly larger size from 4.5.571.

**4.5.571**
- The third stage was 8 points inside the card behind it on every edge, so it looked small. It now sits 4 points inside, 8 points wider and taller.

**4.5.570**
- The keyboard on the third stage left that card where it was, so the keys covered the bottom of it. The third stage now rises until it sits above the keyboard, the same way the other stages do, and that lift stays when the card is laid out again.

**4.5.569**
- Tapping Cancel on the Messages search bar asked the keyboard to go down, then SpringBoard ignored that hide. The stand-in was still the editor for the duration of the resign, and the keys were still on screen until the animation finished. That hide is now accepted, and a keyboard show in the same moment does not put the keys back.

**4.5.568**
- Tapping Cancel on the Messages search bar resigned the field and the keyboard stayed up. That resign was treated as Messages dropping the field on its own. Cancel now asks the keyboard to go down, and a hide that arrives during a scene update is tried again instead of being forgotten.
- `[KEYS]` lines in the stage log record each keyboard request, whether it was ignored, and why.

**4.5.567**
- Dismissing the keyboard on the top card was ignored, so that card stayed shifted and the keys stayed up. A keyboard-down from the top app, the third stage, or SpringBoard now drops every card back.
- Opening a split under the top app was simulating the Home button while the staged scene was still being resized. That is the SIGTRAP into safe mode. The Home transition waits until that resize has finished, and the app no longer sets its window frame from inside the scene update.

**4.5.566**
- The scene and the host were already the full height, and the app was still laid out at the original half. That half is the only part that scrolled; the rest of the card was empty. The tall size is now the size the app itself uses, so the window and its contents grow into the card and the new area scrolls.

**4.5.565**
- The tall size never reached the app. A scene update that tall was treated as the whole phone and thrown away, so Messages stayed drawn at the half height while the host grew. That update is now the one the stage asked for, and the picture grows to it. The card uncovers the full layout.

**4.5.564**
- Dragging the bottom split card was resizing the top card while Messages stayed drawn at the old half height, so the new area was black. The top app is laid out once, at the tallest size that drag can reach. The card uncovers that layout. The scene is not resized on the way down.

**4.5.563**
- The top card and its host were growing together, and the picture inside the host stayed at the old half height. That picture is the blank band. The app is now told the card's real height as the finger moves.
- `[SCENE]` logs the height the app was told, the height the scene believes, the host, and the picture inside the host.

**4.5.562**
- Dragging the bottom split card now tells the top app to redraw at the new height in the same pass. The new area was staying blank because that view was left at the old size.
- Opening split seats each app in its own card. A third stage that was sitting inside the top card is moved back onto the third stage.

**4.5.561**
- A split card whose app view was not in the window logged `topHost` as `{{0,0},{0,0}}` and drew nothing. Both apps are put back in their cards and sized to those cards.
- The lower split card is moved back under the upper one when the two overlap and a finger is not dragging.
- A third stage that has slipped off the screen is brought back on, in front of the split and under the notch.
- `[GEOM-DBG]` now includes the shell, both hosts, the float card, the front card, and the float layer.

**4.5.560**
- Growing the top split card was fitting the hosted view, then a layout pass put the app back at the old half height. That half-height scene is the black band. The top app now keeps the grown size.
- `[TOP-FIX]` logs `card`, `topHost`, `outline`, `host`, and which of those is the app on the top half.

**4.5.559**
- The top split’s app is the primary card’s host. That host and its rim are fitted to the card before the geometry line is written, so the log no longer shows a short host under a taller card.
- The other split card is not used as the content size. Its own host stays on that card.
- The growing card’s height stops at 20 points short of the screen.

**4.5.558**
- Dragging the bottom split card down keeps the top card’s rim and hosted view the same size as that card, and lays the app out once at the tall size so the new area is the app.
- Once that card reaches 80 points from the bottom of the screen, the split closes and the top app opens full screen.
- Each placement logs `[GEOM-DBG]` with the card, outline, host, top card, and top host. A rim that leaves its card is pulled back onto it.

**4.5.557**
- While the bottom split card is dragged down, the top card’s rim and hosted view grow with the card. They were staying at the old half height, so the new area was black.

**4.5.556**
- The right-edge notch stays above the cards. Growing the top split card was leaving that card in front of the notch, so the notch disappeared under it.

**4.5.555**
- The rim around a split card could sit a full screen above the card. It now stays on the card, and it cannot hang off the top of the screen while that card is still visible.

**4.5.554**
- Dragging the bottom split card toward terminate grows the top card again. The app is told that tall size once, after the finger callback returns. The scene view is not resized by hand, which was the safe mode crash.

**4.5.553**
- Dragging the bottom split card no longer resizes the top app. That resize was the safe mode crash, and the extra area stayed black. The top card stays at its half size. Releasing the bottom card into terminate still opens the top app full screen.

**4.5.552**
- The grown top card kept the app's old picture at the top and black underneath. The scene view is resized to that card once, so the rest of the list draws into the space that was black.

**4.5.551**
- Dragging the bottom split card toward terminate was stretching the top card while the app inside kept its old height, so the new area was black. The app is told that tall size once, at the start of the drag, and the card uncovers it.

**4.5.550**
- Staged Messages keeps its keyboard and quick bar. A short strip no longer tears the keyboard down, and growing the top card no longer starts a scene transaction.
- Dragging the bottom split card toward terminate lays the top app out once, at the tallest size that drag can reach. The card uncovers that layout, so the rest of the app shows as the card grows. Letting go without terminating puts the app back at the half height.

**4.5.549**
- Dragging the bottom split card down tells the top app its new height on every move, so the rest of that app draws into the space as the card grows. The writes are one at a time, so they do not stack into a safe mode.

**4.5.548**
- The keyboard shift no longer lays out the hosted scene. That layout during the shift was the SIGTRAP.
- When the keyboard goes down, the other cards come back immediately. A leftover quick bar does not keep them off screen.
- Dragging the bottom split card down tells the top app its new height, so the extra area shows content.
- Dragging the front stage into the terminate band closes that stage. The two split cards stay.

**4.5.547**
- Pulling a minimized stage out of the corner no longer changes the app's display mode inside SpringBoard's gesture. That change was the SIGTRAP that dropped SpringBoard into safe mode.
- A scene transaction is held while SpringBoard is already updating that scene, and a corner-sized frame is never written as the app's size.

**4.5.546**
- In split, the card being typed in rises until it clears the keyboard. The other cards leave the screen and come back when the keyboard does.
- After a swap, that follows the card that owns the keyboard. The old third-stage view is no longer shoved off the bottom.

**4.5.545**
- Growing the top card no longer writes scene settings on every finger move. That write was the SIGTRAP.
- The third stage is a few points larger, every card is a bit rounder, and its rim is wider after a swap.
- In split, the bottom card only moves toward terminate. It does not head for a corner.

**4.5.544**
- Dragging the bottom split card down grows the top card with it, including toward a corner. The app inside the top card lays out into the new height while the finger is still moving.

**4.5.543**
- The card that comes to the front after a swap keeps the smaller front size. Dragging the bottom card down grows the top split card, and that top app opens full screen. The front card and the bottom card close.

**4.5.542**
- Swapping the card above the two with a split half keeps that split card on its half, in front. The card that was in front becomes that split half.

**4.5.541**
- The card a sideways swap trades with becomes the card in front. The old front card moves into that split half.

**4.5.532**
- While Beeper's keyboard is up, a `_UIContextLayerHostView` that grows past the first keyboard is put back to that height. It has to be a full-width strip on the bottom edge. A card-sized or full-screen host is left alone.

**4.5.531**
- Copy Logs is gone from the app picker. Nothing is written for it to copy.

**4.5.530**
- Debug logging no longer runs. Keyboard updates do not format log lines, and they do not walk SpringBoard's windows to describe the keyboard.

**4.5.529**
- A single Beeper card can be dropped on the bottom half. Letting go no longer sends it back to the top.

**4.5.528**
- Back to the 4.5.525 stage behavior. Debug logging is off, so keyboard frames no longer build log lines or walk SpringBoard's windows.

**4.5.525**
- A Beeper keyboard was writing the screen position into the card's position inside the rim shell. The card jumped up and the outline stayed put. That write now moves the shell, and only when the card is not already there. Keyboard lines include the screen frame, the shell, the rim, and the hosted view.

**4.5.524**
- The reset that runs when a hosted app leaves rebuilds the card mask, the blur, the picker corner, and the rim from the card. The stage window stays the full screen and is moved back onto the foreground scene. The rim uses the same continuous corner as the card.

**4.5.523**
- The card keeps its corner while a keyboard is up. The fill and the blur clip to that corner, so the picker after Beeper is no longer a square with the rounded outline left outside it.

**4.5.522**
- Closing a staged app, and opening a stage after it, puts the card's corner, mask, and blur fill back and clears the lift and resting frame that app left behind. The outline is drawn again from the card. Beeper's baseline stays the top half, so a quick bar cannot lift it. The stage window stays the full screen.

**4.5.521**
- A resting frame past the bottom of the screen is rejected, so a 2008pt baseline cannot lift the card. The picker fill uses the same corner radius as the card outline.

**4.5.520**
- The picker is two layouts. Recent apps are a sideways strip of icons. App Library is a list of short rows, a small icon and the name. A drag still scrolls, and a tap still opens the app.

**4.5.519**
- The app picker is a four-column grid. Each app is a 30pt icon with its name underneath, in both Recently Opened and App Library. The search field is a shorter capsule. A drag on an icon still scrolls, and a tap still opens the app.

**4.5.518**
- App rows are 45pt again. The icon is 28pt, sitting in that row beside the name. A drag on a row still scrolls, and a tap still opens the app.

**4.5.517**
- A drag that starts on an app row scrolls the picker. A tap still opens the app. Each row shows that app's icon, and the rows are taller so the icon and name sit in one plate.

**4.5.516**
- The card keeps its corner radius after layout. The grab rim is 18pt instead of 64pt, so it no longer covers the inside of the card. A vertical drag on the app picker stays a scroll.

**4.5.515**
- Copy Logs is the only log button. Keyboard, lift, resting-frame, touch, and stage lines all go into that one buffer. The stage log, keyboard log, freeze trace, and Beeper detail file are no longer written.

**4.5.514**
- Beeper's resting frame stays on the top half. A touch can no longer replace it with the bottom half (restMaxY about 927), and the keyboard lift uses that top-half bottom. The frozen keyboard and the picker-search ignore are unchanged.

**4.5.513**
- The picker search keyboard does not lift the stage. Beeper freezes the first bottom keyboard and later quick-bar frames stay on that height. A strip does not lift. The card origin is not written below y=0, and none of this runs while a scene update is in progress.

**4.5.512**
- 4.5.509 through 4.5.511 crashed SpringBoard and dropped the jailbreak into safe mode. Those keyboard changes are out. This build is the 4.5.508 stage again, which is the last one that stayed up. The launch guard is still raised before any hook is installed.

**4.5.511**
- While Beeper is on a card, SpringBoard and remote-keyboard frames are ignored. They no longer replace the frozen bottom keyboard and they no longer clear it. The lift cannot push that card above y=0, and there is no companion lift.

**4.5.510**
- Beeper keeps the first bottom keyboard for as long as that card is on the stage. A later frame at 301pt or 346pt is the quick bar, and it no longer replaces the frozen keyboard, even when SpringBoard reports that keyboard as not from a staged app. The picker search ignore is unchanged.

**4.5.509**
- The app picker search keyboard no longer lifts the stage. Spotlight, PreBoard, App List, and system aperture keyboards are ignored the same way.
- Beeper freezes the first keyboard that actually sits in the lower half of the screen. A top strip, a dock strip, and an accessory bar cannot become that frame, and they cannot lift the card. Closing the keyboard clears the freeze. The card is not written to a negative origin.

**4.5.508**
- SpringBoard was still crash-looping, which drops this jailbreak into safe mode. The keyboard and quick-bar code added after 4.5.495 is out of this build. That was the last SpringBoard path that stayed up. The launch guard is now written, and flushed, before any hook or crash handler is installed. If this build still dies, the next SpringBoard start loads nothing from Dynamic Stage and the phone stays up. Installing the package clears that guard so this build can try once.

**4.5.507**
- SpringBoard was respringing in a loop. The launch guard was cleared the moment the stage window came up, so the next launch installed the same hooks and crashed again. The guard now stays raised until SpringBoard has stayed up for 15 seconds, and it is also written under /var/jb/tmp so a rootless reboot can see it. The boot log no longer walks every window. Installing this build no longer killalls Beeper or the other staged apps, which was leaving respring unable to finish.

**4.5.506**
- SpringBoard was safe-moding because every quick-bar height change walked the keyboard windows. That walk is gone. A staged top-half card still ignores predictive, emoji, accessory, and collapse strips, using only the height change to recognize them.

**4.5.505**
- Predictive, emoji, accessory, and collapse strips no longer change the keyboard height for a staged card that is already above the keys. Those frames are logged and ignored. A top-half Beeper card stays on its baseline.

**4.5.504**
- A strip anchored at the top of the screen (keysY 0, about 45pt) is no longer treated as a keyboard overlapping the card. That was lifting the card to cardY -411. Only a keyboard in the lower half of the screen can lift, and a top strip cannot become the frozen keyboard frame.

**4.5.503**
- Copy Logs now records which keyboard report won, when the owner changes, the frame Dynamic Stage actually used, why a freeze happened, why a dock strip was ignored, a stability score, and the last five keyboard frames. The lift is unchanged, and the stage window is not walked while a scene is created.

**4.5.502**
- SpringBoard was safe-moding while Beeper's scene was created, which tripped the boot guard and left the tweak out of the next launch. The debug button is no longer added to the stage window, and that window is no longer walked while the scene is coming up. Installing this build clears the boot guard.

**4.5.501**
- Copy Logs now names which keyboard window reported the frame, whether that window is remote, SpringBoard, Medusa, or Aperture, what triggered the quick-bar delta, whether the card was eligible to lift, whether the 463 baseline was kept, and why a short dock strip was ignored. The lift is unchanged.

**4.5.500**
- Copy Logs now includes the keyboard window stack, the UIKit and SpringBoard event that delivered the frame, why the quick bar height changed, why the lift stayed where it is, and why restMaxY is 463 or 927. The lift itself is unchanged.

**4.5.499**
- Opening Beeper no longer walks a debug button that was already on the stage window. That button is removed before the app view is created and put back only after the app is on the card. An invalid slot cannot land on slot 0, and a keyboard that is not from the staged app does not run the lift.

**4.5.498**
- The first keyboard lift is kept until the keyboard closes. A quick bar that changes the height from 243 to 301 to 346 no longer lifts the card again. Closing the keyboard still restores the stored resting frame and clears that frozen keyboard.

**4.5.497**
- Opening Beeper no longer safe-modes SpringBoard. The debug button was being added to the stage view while that view was still being built, and Beeper's scene setup crashed on it. The button is added to the stage window only after the stage is on screen, and the log overlay is created only when D is tapped. The quick-bar lift is unchanged.

**4.5.496**
- A quick-bar change is a new keyboard height. The lift is recomputed from the stored resting frame on every keyboard frame, instead of staying on the first 301pt frame. cardY and cardH stay put, a negative cardY is still rejected, and the keyboard-close path still restores that frame. The stage picker has one Copy Logs button, and a D button on the stage shows the same log.

**4.5.495**
- A single card dragged to the bottom stays the primary card, and the keyboard lifts that card from where it actually sits. Measuring it as the top half used restMaxY 463 against a keyboard at y=631, which is overlap -168 and a lift of 0. The resting frame, the keyboard path, and the rule against saving a negative cardY are unchanged.

**4.5.494**
- One card stays the primary card after it is dragged to the bottom. That drag no longer marks it as the lower card of a two-card stack, so the keyboard still lifts it. The resting frame is taken from where the card was left.

**4.5.493**
- A single Beeper card is classified as the primary card, half 1, not the bottom of a two-card stack. The resting frame, the lift, and the restore from 4.5.492 are unchanged.

**4.5.492**
- Beeper's keyboard goes through `keyboardOnScreen:frame:source:` into `handleKeyboardForBundle:slot:on:frame:`. The lift is applied from the stored resting frame. Closing the keyboard writes that frame back. The lifted origin is not written into the card.

**4.5.491**
- Beeper stores its resting card once, before the keyboard lift, and the keyboard-close path writes that frame back. The lifted origin is not saved. A single Beeper card is the primary card. Dock strips under 150pt and other apps' keyboards do not move it.

**4.5.490**
- Beeper's resting frame is stored once, before the keyboard lift (cardY 62, cardH 458). When that keyboard closes, the card is put back on that frame. The lifted position (cardY -244) is never saved and never restored.

**4.5.489**
- The card remembers its resting frame before the keyboard lift. When that app's keyboard closes, the card goes back to that frame instead of staying at the lifted position. A dock strip under 150pt does not move the card, and another app's keyboard does not either.

**4.5.488**
- Beeper's card keeps the frame and the lift SpringBoard applies. Dynamic Stage no longer replaces that window's frame, bounds, or transform. The keyboard lift stays at the 306 points SpringBoard calculated.

**4.5.487**
- The stage stays above the keyboard. It was lifting, then the next measurement used that lifted position and dropped the card back onto the keys. A drag is no longer snapped back to a half while the finger is still down.

**4.5.486**
- The bottom stage lifts until it sits above the keyboard. The top stage stays where it is, because it is already clear of the keys. When the keyboard goes away, the bottom stage drops back.

**4.5.485**
- Other apps' keyboards are raised above the stage again, the way 4.5.416 did it. 4.5.465 stopped that raise, so the keys stayed at level 10 under the card. The window's frame and scene are not moved, and nothing is lowered. Messages is unchanged.

**4.5.484**
- Every staged app installs its keyboard in the card the same way Messages does. SpringBoard was dropping that view for every app except Messages, which left the keys on the remote-keyboard scene under the stage. Messenger, Signal, and Beeper no longer swap their keyboard for that remote window or hide the one in the card. Messages is unchanged.

**4.5.483**
- Beeper is back on the Messenger and Signal keyboard path. There is no separate Beeper tweak. The same app dylib hosts its keyboard in SpringBoard. Install still quits Beeper so that dylib loads.

**4.5.482**
- The window path is the one that was specified. Beeper keyboard windows are returned immediately. A Beeper card window keeps an identity transform. Messages keyboard windows are not moved. The stage window stays at 998, and install still quits Beeper.

**4.5.481**
- Beeper's keyboard windows are left alone. Its card window keeps the frame it was given and is not scaled. The stage window stays at 998. Install still quits Beeper so this code actually loads into that process.

**4.5.480**
- Installing now quits Beeper. A respring reloads SpringBoard and leaves Beeper's old process running, which is why every keyboard and quick-bar change was ignored. The log stayed at appDylib=no because that process never loaded the tweak.

**4.5.479**
- Beeper still fills the card. The views inside that card are no longer clamped or scaled. Beeper's own window is not given a new frame, transform, alpha, or level while it is the staged card. The stage window cannot be raised above 998.

**4.5.478**
- Beeper's scene is fitted to the card again. Leaving it at the phone size, 430×932, is why the app no longer filled the stage. The keyboard is still not hosted or raised for Beeper, and the stage window stays at level 998.

**4.5.477**
- Beeper's card scene is no longer resized. The fit that rewrote it from the phone size to 420×458 is skipped, and so are the host-view frame, transform, and clamp. The stage window stays at level 998. SpringBoard's card placement is the one that remains.

**4.5.476**
- Beeper is no longer a staged keyboard. SpringBoard does not host it, does not raise it, and does not ignore its dock strip. The card is not lifted for that keyboard. Beeper keeps the keyboard and quick bar it laid out itself.

**4.5.475**
- Beeper's own keyboard was hidden, then shown again, on every layout. That is the flicker. Beeper is no longer told to use a remote keyboard, its keyboard window is not forced hidden, and its key views are not stripped. UIKit keeps the keyboard it attached to the field.

**4.5.474**
- The detail log showed SpringBoard's keyboard host already at level 1000, above the stage at 999, until this tweak raised it to 9999999. That raise is gone. The stage window stays at 998, under the host. Beeper keeps the screen, the keyboard frames, and the keyboard notes SpringBoard already applied. Its card is not given a second layout.

**4.5.473**
- The detail log showed the keys on the remote-keyboard window at y=631, left at level 10 under the stage, while the SpringBoard window was the one raised. That remote window is raised too. Its frame is not moved. Beeper's quick bar was still free to slide up. While the keyboard is up, that bar keeps the frame it had, and Beeper's keyboard guide stays on the bottom of the card. Force-quit Beeper after installing. The detail log's `APP ctor` line is the proof that the app side loaded. `SB ctor-file missing` means it did not.

**4.5.472**
- Beeper's keyboard and quick bar are written to a separate log, `/var/tmp/com.recreated.dynamicstage.beeper-detail.log`. Copy that file. It lists every keyboard window, its level, whether the stage covers it, why the raise skipped it, and the view chain of anything in the lower half that moves up. The short stage log only points at this file.

**4.5.471**
- Beeper's keyboard was on the phone at y=631 and left under the stage, so it never appeared. That one window is raised above the stage. Its frame is not moved. Beeper is not told the keyboard height, so the quick bar does not lift for it. Force-quit Beeper once after installing so the app side loads.

**4.5.470**
- Staged Beeper keeps the keyboard UIKit attached to the field. The blank input view, the hidden keyboard window, and the swallowed keyboard notes are gone. The card layout is still SpringBoard's. Beeper's own frames, safe area, and keyboard guide are not rewritten.

**4.5.469**
- Beeper's window is no longer given the card size. SpringBoard already hosts that app in the card. Fitting the window again was the second layout, and the quick bar lifted.

**4.5.468**
- Beeper's card already sits above the keyboard. The quick bar was lifted a second time inside the app. While that keyboard is up, the bar stays where it is and the stage does not fit Beeper's frames again.

**4.5.467**
- The keyboard color and the keyboard-window snapshot are gone. While Beeper is on the stage, each time the quick bar moves up during typing is written to the stage log as "Beeper bar:".

**4.5.466**
- Messages slides the input bar and the app strip just off the bottom of the phone while it opens a chat or the app strip. A layout pass was rewriting that frame and leaving the bar there. That pass waits until the bar is back on screen.

**4.5.465**
- The keyboard windows were being moved and raised to level 9999999. UIKit treated that as the keyboard going away and built a new one, which is the flicker and the frozen tap. Those windows are left alone.

**4.5.464**
- The keyboard on screen is SpringBoard's. Putting a different window back left that one off the bottom, so taps hit nothing. Only SpringBoard's keyboard is put back, and the color is painted on the keys themselves.

**4.5.463**
- Each keyboard window is a different color, with its name on it. Green is SpringBoard's keys. Red is the remote keyboard. Blue is System Aperture. Orange is the high aperture. Purple is Medusa. The one you can see is the one on top.

**4.5.462**
- A letter landed, then three seconds later the keyboard slid off the bottom of the phone while the stand-in was still the editor. That slide is put back, and the window is not dropped for it.

**4.5.461**
- Each letter made the message field the editor, which resigned the stand-in and dismissed the keyboard, then the stand-in took the keyboard back. That gap is the flicker. The stand-in stays the editor for the whole session and the letter is written into the message field without moving the keyboard. A keyboard that is already on screen is not raised again. Whenever the keyboard picture changes, every keyboard window is written to the keyboard log: class, scene, frame, hidden, level, who is editing, and the key rect.

**4.5.460**
- Messages types on the live keyboard again, the one from 4.5.429. The message field stays the editor, the keys inside the card are hidden while typing, and a tap on the lower half of SpringBoard's keyboard stays on the keys. The app picker search keyboard is not included.

**4.5.459**
- 4.5.458 brought the keyboard back every time UIKit hid it. That loop never let SpringBoard finish launching, so the jailbreak could not complete. That path is removed. Installing this build also clears the boot guard.

**4.5.458**
- The keyboard was dismissed while the message field was still editing, so the next tap did nothing until the box was tapped again. That dismiss no longer drops the keyboard, and UIKit's hide brings the same keyboard back. The message box resigning is not treated as the user leaving.

**4.5.457**
- Two SpringBoard text-effects windows were both raised over the keys, so a tap hit the empty one. Only the window that actually has the on-screen keyboard stays up. The other is lowered. A tiny blob is no longer treated as the keyboard.

**4.5.456**
- Key taps were hitting a second keyboard. The remote keyboard was moved onto System Aperture and raised over the keys, and a 243-point keyboard parked at y=932 was treated as the real one. Those covers are lowered while Messages is typing, and a parked host is not treated as the keyboard on screen.

**4.5.455**
- The message box was on the card at y=377, then Messages parked it at y=4377. That jump was skipped because it was more than 2500 points. A park of a few thousand points is put back on the spot the box just had.

**4.5.454**
- The message box was riding the keyboard host to the bottom of the phone, so it was not on the card to tap. That host is no longer docked while Messages is typing, and the box is slid up to sit on top of the keyboard. The focus line records where the box was and where it moved.

**4.5.453**
- The conversation search field resigned itself after one letter and that resign hid the keyboard while the keys were still on screen. That resign no longer hides it. Going home puts the staged keyboard away so it is not still sitting there when the stage comes back.

**4.5.452**
- After one key the keyboard host was parked just off the bottom of the phone, at y=932. Tapping the message box pulled it back to y=631, which is the flicker, and that pull is what made the next key work. While the staged field is still editing, that park is refused and the host stays where the keys already are. A hide now records which field resigned, whether the stand-in was still editing, and who hid the keyboard.

**4.5.451**
- Tapping the message box and then a key typed one letter, and the next key did nothing until the box was tapped again. That letter was kept in the offscreen field, so the caret moved and the following tap missed the keys. The letter is not stored there. A tap inside the keyboard that is on screen stays on the keys. When the keyboard is dismissed, its window is allowed to leave instead of being forced back on.

**4.5.450**
- The system app switcher hitches because every card's home pill was being pulled to the bottom of the phone on each frame, and every app's scene settings were being copied on each update. The pill is only moved while the stage is on screen and the system switcher is not. Scene settings are left alone unless that scene is on the stage. Key taps are unchanged.

**4.5.449**
- A key tap on staged Messages was passed through the keyboard window after the first letter. That is the same miss the app picker had. While Messages is using SpringBoard's keyboard, a tap in the keyboard band stays on the keys. The app picker search path is not changed.

**4.5.448**
- Staged Messages has one keyboard, SpringBoard's. Messages' own keyboard is not shown, and Messages is not allowed to dismiss SpringBoard's while it is up. Key taps are forwarded into the search field and the message field without those fields taking the keyboard back. A tap on a key is no longer thrown away.

**4.5.447**
- The keyboard is 4.5.433 again. That is the build where staged Messages used the app picker keyboard and the key taps were not frozen. Every keyboard change after that build is removed.

**4.5.446**
- A tap on the staged Messages keyboard was thrown away after the first letter. The log said the touch passed through the keyboard window. That window now keeps the tap when it lands on a key. The app picker search keyboard is unchanged.

**4.5.445**
- Staged Messages no longer shows its own keyboard. SpringBoard's keyboard stays up, the same way it does for the app picker, and the key taps are forwarded into the message field. Messages is not allowed to dismiss that keyboard while it is wanted.

**4.5.444**
- Staged Messages keeps the SpringBoard keyboard the way the app picker does. Once that keyboard is on the bottom of the phone, later letters do not move it. A tap on those keys was being reported at the top of the screen and thrown away. That tap stays on the keys.

**4.5.443**
- Staged Messages uses the app picker keyboard and nothing else. The SpringBoard field stays the editor, so UIKit is not told to move the keyboard. The Messages keyboard window is not resized. Letters are still written into the message field.

**4.5.442**
- The staged Messages conversation search uses the same keyboard as the app picker search. The message-box keyboard was taking that field, and the second tap missed. The search field keeps its own keyboard, and that window is left the size UIKit gave it. The prediction-bar and parking changes from 4.5.439 through 4.5.441 are removed.

**4.5.441**
- A staged Messages conversation no longer shows the prediction bar, the quick-reply bar, or the app strip. Those bars were part of the keyboard moving on every letter. Search keeps its own keyboard.

**4.5.440**
- The keyboard host is no longer parked off the bottom of the phone. That park, and the pull back onto the screen, was the flicker on every letter. A frame below the phone is not applied while the staged Messages keyboard is up. Search still uses the frame UIKit gives it.

**4.5.439**
- The staged Messages keyboard host stays on the bottom of the phone. Each letter was parking that host just off the screen and pulling it back, which is the flicker. A park while the keyboard is already up is ignored. Search is left where UIKit put it.

**4.5.438**
- Full restore of 4.5.433. The keyboard changes after that build are gone. Staged Messages, Messages search, and the app search picker are the 4.5.433 code again.

**4.5.437**
- Search inside staged Messages keeps the 4.5.433 keyboard. 4.5.436 skipped a keyboard redraw for every Messages field, and the search field froze after one letter. That skip is only for the message box now. Search is unchanged from the build that accepted more than one letter.

**4.5.436**
- Staged Messages still uses the app search keyboard, and letters still go through the message field the way they did in 4.5.433. That window was being raised again on every letter, which flashed the keys and the app strip. Once it is already above the stage, it is left alone. 4.5.434 had stopped focusing the message field, and that is what froze the next tap. The field is focused again.

**4.5.435**
- Staged Messages is back on the keyboard that was accepting letters. 4.5.434 stopped giving the message field focus on each key, and the next tap missed the keys. That change is reverted. Messages uses the same SpringBoard keyboard as the app search picker again.

**4.5.434**
- Staged Messages keeps one keyboard on screen while typing. Each letter was resigning SpringBoard's field and raising the keyboard window again, so the keys and the app strip flashed. The app strip stays under the input field instead of riding the predictive bar. The picker search keyboard, and Messenger, Signal, and Beeper, are unchanged.

**4.5.433**
- Staged Messages uses the same keyboard as the picker search. SpringBoard shows it where UIKit puts the search keyboard, and the 243-point host is no longer moved. That move was what made a tap miss the keys.

**4.5.432**
- The picker search keyboard accepts more than one tap again. 4.5.429 kept every touch in the bottom half of the phone, which froze the keys after the first letter. That is reverted. The keyboard window is left the size UIKit gave it, for search and for staged Messages.

**4.5.431**
- Beeper's keyboard is raised after the scene update finishes. It was reported up at the bottom of the phone, then left at level-held under the card, and it dropped two seconds later.

**4.5.430**
- Messenger, Signal, and Beeper have their keyboard back. The remote-keyboard window was being skipped for every staged app. That skip now applies only while Messages is typing.

**4.5.429**
- The keyboard inside the staged Messages card is hidden while typing. SpringBoard draws the phone keyboard. A tap in the bottom half of the phone stays on that keyboard instead of passing through.

**4.5.428**
- Taps on the staged Messages keyboard stay on the keys. The key host was only 243 points tall, so a tap on the letters was passed through the keyboard window. SpringBoard's keyboard window is now the full phone, and the hosted app's second text-effects window is no longer raised on top of it.

**4.5.427**
- The full Messages keyboard is back on the bottom edge of the phone. Lowering every SpringBoard keyboard window had left only the dictation control inside the card. The remote-keyboard window and the empty hosted keyboard stay down. Dictation that is still inside the card is hidden while typing. The globe and dictation that belong to the keyboard move with the keys.

**4.5.426**
- Taps on the staged Messages keyboard reach the keys. SpringBoard had four keyboard windows, including the remote-keyboard one, raised on top of the keys. Those covers come down while Messages is typing. The globe and the microphone stay on the keyboard instead of sitting under it and inside the card.

**4.5.425**
- The quick bar stays inside the card. The keyboard window grows to the phone, and the keys sit on the bottom edge, only while the message field is being typed in. Until then the bar is left where Messages put it.

**4.5.424**
- The Messages keyboard sits outside the card again, on the bottom edge of the phone, the way StageDuo sizes that keyboard window to the phone. The app strip stays under the input field. System Aperture is not raised over the keys. The key views are not moved on their own, so the globe and dictation row stay on the grid.

**4.5.423**
- Key taps on the staged Messages keyboard reach the keys. System Aperture was being raised to the same level as the keyboard, so it took the taps. The globe and dictation row stay on the key grid: the keyboard's own frame is no longer moved. Spotlight dismissing its keyboard no longer drops the Messages keys. Messages still uses its own keyboard.

**4.5.422**
- The Messages keyboard was up and then clipped away, so nothing showed. The card no longer clips it, and the keyboard window is raised to level 9999999 and docked on the bottom edge of the phone. Messages still uses its own keyboard. Messenger, Signal, and Beeper are unchanged.

**4.5.421**
- Staged Messages uses its own keyboard again. That keyboard sits on the bottom edge of the phone, full width, at its own height, and its window is raised to level 9999999 so taps land on the keys. The reply bar and the app strip stay on the bottom of the card. SpringBoard does not put a keyboard window over Messages. Messenger, Signal, and Beeper are unchanged.

**4.5.420**
- The reply bar stays on the card when the message field is tapped. Messages was being told the phone keyboard height, and it laid the bar down off the stage. Those notes are dropped. The keyboard window is taken from the stage window's own scene, which is why it stayed in the remote-keyboard scene under the card. A keyboard-down report from Messages no longer puts that window back under the card.

**4.5.419**
- The full keyboard is back. Stretching the 243-point keyboard into a 301-point frame pushed the letter rows off the glass and left the dictation row. The keyboard keeps its own height and sits on the bottom edge. Its window is moved in front of the card before the keys are measured, which is why only that bottom row was showing.

**4.5.418**
- The Messages keyboard was at the bottom of the phone, but only the emoji and dictation row showed. The window was still in the remote-keyboard scene, under the card, at level 6000. That window is moved onto the foreground scene once and raised to level 1000000, so the full keyboard sits in front of the stage.

**4.5.417**
- The Messages keyboard stays at the bottom of the phone after it appears. It was docked at {{0, 631}, {430, 301}}, then a few seconds later the host was parked off the bottom of the screen and the keyboard was reported down. That park is left alone when the keyboard is already on the bottom edge. The keyboard note no longer tells Messages the keyboard height is 0.

**4.5.416**
- The Messages reply bar is back on the bottom of the card. Stretching the keyboard window to the phone had carried that bar off the card, so there was nothing to tap and no keyboard came up. The keys are SpringBoard's again, on the bottom edge of the phone. The bar stays where Messages put it.

**4.5.415**
- The staged Messages keyboard is the full keyboard, in the same place as the other staged apps: the bottom edge of the phone, full width, 301 points tall. A 243-point host was only the lower part of that keyboard, and it was left over the card. The app strip stays on the bottom of the card.

**4.5.414**
- Taps on the staged Messages keyboard land on the keys. The hit test was using a 75pt strip at the bottom of the phone, so the letters above it were passed through. The keyboard that is actually on screen is the taller one docked to the bottom edge. The app strip is no longer pulled up over the messages.

**4.5.413**
- Staged Messages keeps its own keyboard. That keyboard is moved to the bottom edge of the phone, full width, the same place the other staged keyboards sit. Its height stays the height the keyboard already had. The card's position is not used.

**4.5.412**
- Staged Messages uses its own keyboard, the same way StageDuo 1.2 does. The app strip under the field stays with that keyboard. The stand-in field, the blank input view, and the hidden in-card keys are not used for Messages. Messenger, Signal, and Beeper are unchanged.

**4.5.411**
- Staged Messages keeps accepting keys after the first one. The field that owns the keyboard is wide enough for the caret, the keyboard window is no longer stretched over the phone, and a tap on the visible keys is not passed through.

**4.5.410**
- SpringBoard no longer moves a keyboard window onto another scene or rewrites its frame while Messages is typing. That move was the SIGTRAP after a letter.

**4.5.409**
- After the first letter, Messages reports the keyboard down while the keys are still on screen. Those windows stay put, and a keyboard host parked off the bottom of the phone is no longer pulled up over them.

**4.5.408**
- Typing one letter in staged Messages no longer clears the field a second later. The message field stays while that keyboard is up, so the next keys still go into it.

**4.5.407**
- The staged keyboard keeps taking letters after the first one. The off-screen field no longer holds that letter, and a tap on the visible keys is no longer treated as a tap above them.

**4.5.406**
- Staged Messages keeps the keyboard after it is already docked at the bottom of the phone. A second keyboard host parked at the bottom edge was being pulled up, that dismissed the keys, and Messages then sent hide.

**4.5.405**
- Staged Messages uses the same keyboard as the other apps, docked at the bottom of the phone. The old path raised an empty hosted keyboard window and then hid the keys.

**4.5.404**
- The “copy keyboard log” line sat in the card’s drag rim, so the tap never reached it. Those lines now sit inside the card, and that tap copies the keyboard log and the stage log together.

**4.5.403**
- 4.5.402 is reverted. Its UIKit filter loaded the app dylib into SpringBoard, which already loads the SpringBoard tweak, so the same classes were registered twice and the jailbreak could not finish. The app dylib is back to Messages, Messenger, Signal, and Beeper. Nothing in this package kills an app.

**4.5.401**
- Back to 4.5.335. That build fits the staged scene to the card and leaves the scene in front, so the card does not go black. The keyboard changes after it are not in this package. Install removes the daemon copies. Nothing in this package kills Beeper.

**4.5.335**
- Beeper's scene is fitted to the card again. 4.5.334 was throwing away the update that shrinks the scene from the phone to the card, so the chat stayed phone-sized and the card cut off the bottom. The card size is applied, and the scene's foreground is left as it already was so the card does not go black.

**4.5.334**
- The black card was a scene update with foreground off (`fg=0`) while the app view was Live. That update is dropped, and the live view ignores a foreground change so it does not blank. A minimized stage can still go to the background.

**4.5.333**
- A staged app no longer turns black when another app opens. Those opens were marking the staged scene as backgrounded, and a backgrounded scene draws black. The card keeps the scene in front. A minimized stage is still allowed to go to the background.

**4.5.332**
- The stage rim is easier to grab. The band inside the card edge is 64pt and the band outside it is wider, so a drag can start on the edge instead of in the app. The outline is drawn thicker so that edge is visible.

**4.5.331**
- Beeper's chat no longer shortens itself for the keyboard. The keys stay at the bottom of the phone and the card stays where it is. SpringBoard does not kill the app.

**4.5.330**
- 4.5.329 is gone. It killed a staged app while SpringBoard still had that app's scene, and that sent the phone to safe mode. The card still stays put for the keyboard.

**4.5.329**
- Beeper's keyboard hooks load again when the app was already running. The trace from 4.5.328 showed the card staying put (lift 0, top half, keyboard at y=631) while Beeper itself had never loaded the stage dylib, so Beeper could still move its own layout. That app is opened once more so the hooks map.

**4.5.328**
- A staged app's keyboard no longer lifts the card. The top card and the lower card both stay on their half. The keys stay at the bottom of the phone. Picker search can still move its card.

**4.5.327**
- Beeper writes a keyboard trace. It names which card was measured, whether that card is the top one, why a lift was kept or skipped, and which Beeper view moved inside the card. Open Beeper, tap the field, then on the stage picker tap "Tap to copy freeze trace" and paste that trace back.

**4.5.326**
- Beeper keeps its own layout and the whole card lifts above the keyboard. A short dock-strip report no longer drops that lift. Moving the bottom of the chat is Messages only.

**4.5.325**
- Letting go of a stage puts it fully on a half. A card left hanging off the screen, or left smaller than a normal half, is not kept there.

**4.5.324**
- Opening a normal app no longer stretches the open stage to the whole phone or turns its scene off. The card stays the same size, with the app inside it.

**4.5.323**
- Restored 4.5.316. The builds after that one are gone.

**4.5.316**
- Beeper loads the stage keyboard hooks, so it stops shrinking its own chat above the keys. The whole card is what moves. Restoring a minimized stage after a call fits the scene back to the real card and wakes it, instead of leaving the black tile from the call.

**4.5.315**
- A staged app such as Beeper no longer shrinks its own content above the keyboard. If the card overlaps the keys, the whole stage lifts until the card sits above them. With two stages, the upper card still leaves off the top while the lower one clears the keyboard.

**4.5.314**
- Home-bar minimize no longer hands the app to SpringBoard's icon animation, so the corner icon does not keep sliding after the card is parked. With two stages, typing in the lower one pushes the upper stage off the top of the screen and lifts the lower stage until it sits fully above the keyboard.

**4.5.313**
- The lower stage lifts above the keyboard again after layout passes that were clearing the lift. Terminating a stage also removes its outline, which was staying on screen after the card was gone.

**4.5.312**
- The stage rim is easier to catch. The grabbable edge is 44pt instead of 22pt, so a hosted app no longer covers the only place a drag can start.

**4.5.311**
- Home-bar minimize puts each corner icon in place immediately. The stage fades out instead of dragging the icon along behind it.

**4.5.310**
- A corner pull restores a minimized app even while the other stage is already open, and that card comes in front of the one that was on screen.

**4.5.309**
- With both stages open, the home swipe animates the top card to the bottom-left corner and the bottom card to the bottom-right. They no longer jump together to the right with no motion.

**4.5.308**
- Recently Opened in the app picker shows apps you actually opened, newest first. The four default pinned apps were filling that grid, so a new launch never appeared. Opening an app from the Home Screen is recorded too.

**4.5.307**
- Opening an app from the Home Screen while other apps are minimized no longer rewrites those parked scenes. That rewrite was the SpringBoard trap (safe mode).

**4.5.306**
- The first New Stage tap lands the card on the top half. The off-screen entrance position was being kept as the card's resting frame, so the stage existed but stayed above the screen until a second tap added another stage and both appeared.

**4.5.305**
- Pulling a minimised stage out of one corner restores only that app. The other minimised stage stays in its corner.

**4.5.304**
- With two stages up, typing in the lower card lifts that card above the keyboard and brings it in front. A single stage still stays put. The gap between the cards no longer belongs to the upper card's rim, and a drag of the lower card stays above the other one so it can move into the top half.

**4.5.303**
- Staged Messages keeps SpringBoard's keyboard when the arbiter blips off but the docked key strip is still on screen; home swipe parks a hosted app even if stage state was stale. New Stage places the top card on the top half immediately instead of animating from off-screen. Touch hit-testing uses the staged key frame so taps above the card are not mistaken for pass-through.

**4.5.302**
- New Stage from the shelf shows the second card on the first tap (top stack sits above the primary drag shell instead of behind it). A second tap when two stages are already open relayouts instead of silently doing nothing. Messages keyboard watch treats docked InputSetHost strips as visible keys so "keys never appeared" no longer fires while typing. Tapping the reply field after a home minimize restores the card for the keyboard instead of refusing with stage state 4.

**4.5.301**
- Staged Messages typing no longer loses SpringBoard's keyboard when Spotlight or another process dismisses its own keyboard (UIKit hide and arbiter restore were putting keys back under the card).

**4.5.300**
- Overlay cards keep a dragged floating frame instead of snapping back to a half on every layout pass. While SpringBoard's keyboard is up for staged chat apps, the card no longer re-enables clipping that hid the keys. Messages, Messenger, and Signal ask SpringBoard to raise the real keyboard on the hosted text field instead of the invisible picker proxy field.

**4.5.299**
- Rebuilt from source on Linux (Theos) and republished the Sileo repo index and deb so the package version matches what Sileo serves after refresh.

**4.5.298**
- Overlay keyboard fix is enforced in the SpringBoard dylib: staged apps cannot lift the card, layout no longer restores a stale keyboard lift, in-card keyboard frames are ignored until full-width keys are on the phone, and keyboard safe-area overlap is not pushed into the hosted scene when keys draw outside the card. Staged Messages, Messenger, and Signal drop UIKit keyboard notifications while on the stage so the conversation does not slide away; all three request SpringBoard's keyboard on focus. Build this version with Theos (`make package FINALPACKAGE=1`) or the GitHub Actions workflow — repacked older dylibs will still show the old lift behavior.

**4.5.297**
- Merges overlay keyboard fixes with mainline keyboard docking. The overlay card no longer lifts when a keyboard appears; the input bar and layout stay in the visible stage. Staged Messages asks SpringBoard for the phone-width keyboard on focus, in-app keyboard frame notifications are ignored while remote, and the repo package index matches the published deb version.

**4.5.296**
- Repository package index version matches the built package so Sileo shows the update after refresh.

**4.5.295**
- Staged Messages' keyboard is measured on the phone. The window holding the keys was already at y=932, so the keys looked like they were at the top of that window and the dock pushed them further off the screen. That window is brought onto the phone and the keys sit on the bottom edge. A keyboard parked there still counts as typing, so the stage leaves the key window alone and the field stays the editor.
- The overlay card no longer lifts when a keyboard appears; the input bar and layout stay in the visible stage. Staged Messages again asks SpringBoard for the phone-width keyboard on focus, and in-app keyboard frame notifications are ignored so the conversation does not slide away. Keyboard debug logging from the app is off.

**4.5.294**
- Staged Messages keeps SpringBoard's keyboard on the screen. The keys were parked at y=932, on the bottom edge of a 932pt display, inside a parent that was already off screen, so docking the view against its parent did nothing. The keyboard, or that parent, is moved up to the bottom of the phone. Taking the stage's key window while those keys are up was dismissing them two seconds later and putting a keyboard back inside the card. That key change is left alone while a staged app is typing, and the field stays the editor.

**4.5.293**
- The reply bar stays where the card already put it. Shifting it on focus had moved it to y=-156 inside a 458pt card, which is the lift. The keyboard inside Messages is the card-sized remote window (420 by 458), so that window stays hidden. SpringBoard's keyboard was parked at y=932, just off a 932pt display. That view is docked to the bottom of the phone, full width, the same place the search keyboard uses. Loading the remote hooks no longer invents a keyboard and lifts the card before the field is tapped.

**4.5.292**
- The reply bar stays on the card when the field is focused. It lives in the phone-sized text-effects window, which the card fit leaves alone, so focusing the field docks the bar below the card. Only that bar is shifted back to the spot it had on the card. The gray piece under it is not moved. The plain remote keyboard window is allowed to show, and its keyboard view is installed. The copy of the keys inside the card stays hidden.

**4.5.291**
- Messages uses the same keyboard as the other staged apps. The field is no longer slid, held, or hidden, and SpringBoard no longer has a separate Messages keyboard watch or lift. The card layout that keeps the bottom of the conversation in the view is unchanged.

**4.5.290**
- The gray piece under the Messages field stays under it. Sliding the field's parent, or pinning a tall view's bottom to the card, was lifting that slab up over the field when the field was tapped, and the keyboard still never appeared. Only the field itself can move, and a view taller than the field is left where UIKit put it. The trace now names the view, its frame, the views above and below it, and why a keyboard frame was accepted or rejected.

**4.5.289**
- Opening a staged Messages conversation stays on that conversation. The reply bar was being slid during the push, so the chat came up and the list came straight back, and neither the bar nor the keyboard was on screen. The bar moves onto the card after the chat has appeared. The keys inside the card stay until SpringBoard is drawing the full keyboard at the bottom of the screen, then that copy is hidden.

**4.5.288**
- Opening a staged Messages conversation no longer freezes. Hiding the in-card keys from a keyboard notification posted that same notification again, and the main thread never came back. Those notifications are only logged now.

**4.5.287**
- Staged Messages uses SpringBoard's keyboard again, the same remote keyboard as the other staged apps. The field that was tapped stays the editor. The input window is left the size of the phone, so the keys are drawn full width at the bottom of the screen, outside the card. The reply bar is slid onto the card. The picker stand-in is not used, and the input shells are not resized.

**4.5.286**
- Staged Messages keeps SpringBoard's keyboard up. It was shown at the bottom of the screen, then the field resigned and asked for it to be hidden, so nothing stayed on screen. That resign is ignored while the conversation is open.

**4.5.285**
- Staged Messages no longer resigns the field to build a new keyboard. That hid the keys and SpringBoard never drew any, and the reply bar was pinned off the card. SpringBoard shows the same keyboard the picker uses, at the bottom of the screen. The in-card keys stay until that keyboard is actually on screen, then they are hidden. The reply bar is not moved.

**4.5.284**
- Staged Messages still opens with its own keyboard. That keyboard cannot be drawn outside the card. Once the conversation is open it is released, and the field is focused again so SpringBoard's keyboard is created the same way as the other staged apps. The reply bar stays on the card.

**4.5.283**
- Staged Messages uses SpringBoard's keyboard, the same one as the other staged apps. The keyboard inside the card cannot be drawn outside it, because the scene only paints the card. After the conversation has opened, the field resigns and focuses again so UIKit creates that keyboard. The in-card keys stay until then. The reply bar stays on the card. An empty keyboard window is not pulled over the card.

**4.5.282**
- Staged Messages keeps the keyboard inside the card. Handing it to SpringBoard hid those keys, and SpringBoard never drew any. Tapping the field no longer slides the reply bar off the card.

**4.5.281**
- The Messages reply bar stays on the card after the keyboard handoff. It was being unpinned, and an empty keyboard window was covering the card. The card does not lift until SpringBoard is drawing full-width keys. A short dock strip is not that keyboard.

**4.5.280**
- Staged Messages keeps the keyboard that takes taps while the conversation opens. Once that scene update has returned, SpringBoard draws the keys full width at the bottom of the screen, outside the card. The message field stays the editor. The reply bar stays on the card. The stand-in field is not used.

**4.5.279**
- Staged Messages keeps the keyboard that takes taps inside the card. That keyboard is drawn again at the bottom of the screen, above the stage, and the card stops above the keys.

**4.5.278**
- Staged Messages draws its own keyboard inside the card again, the one that was on screen once the reply bar stayed on the stage. Taps land on those keys. SpringBoard no longer pulls that keyboard out of the card, and the stand-in field is not used.

**4.5.277**
- Staged Messages is back on SpringBoard’s keyboard, the one that was up when the reply bar was showing. The shared remote keyboard hung SpringBoard as a conversation opened, so the conversation never appeared and no keyboard came up.

**4.5.276**
- Staged Messages no longer uses the stand-in keyboard. That keyboard never held the key window, Messages’ own keys were hidden, and the reply bar was disconnected from both, so the keys and the bar froze and the bar shifted. Messages now uses the same keyboard as the other staged apps, typing straight into the message field.

**4.5.275**
- The keyboard and the reply overlay were frozen together. The keyboard window was held at a half-off frame, so that layout never finished, and the reply bar shifted down against it. The window is allowed to settle, and the key views are no longer locked to the frame they had mid-layout.

**4.5.274**
- The reply bar slid down after a few keys and the next layout put it back. Changing its frame to pull it up was thrown away, and that change ran inside the bar’s own layout, which is what stalled typing. The bar is now held with a shift that layout does not reset.
- The SpringBoard keyboard was already up and the letters were already arriving. The stall was the bar moving, not the keys failing to show.

**4.5.273**
- Tapping the reply field was pinning the transcript at the top of a long conversation. That jump to the latest message is what stalled typing. It goes through now.
- The hold was attached to the text box inside the reply bar, so the bar itself still dropped. The bar is what stays put.

**4.5.272**
- Typing one letter in staged Messages was inserting the letters still queued from earlier launches, and each one laid the reply bar out again. That replay was the hitch. Only the new letter is applied.
- The reply bar keeps the height and position it had when the field was tapped. The keyboard inset was growing the bar downward.

**4.5.271**
- Typing in a staged Messages conversation no longer stalls. The transcript was being pinned on every frame, and each key was posting keyboard notifications that moved the reply bar.
- The reply bar stays where it was. Small shifts were still walking it down the card.

**4.5.270**
- Tapping the reply field in staged Messages starts SpringBoard’s keyboard even when the stage window is not the only key window. That check was skipping the field, so the keys never came up.
- Leaving a conversation lets the composer move off the card immediately. It was being held in place, so the bar stayed on the conversation list.

**4.5.269**
- The SpringBoard keyboard was coming up, but Messages was still sliding its text window from its shifted position back to the origin, which pushed the conversation off the card. That window now stays where it was, and the in-card key views stay hidden.

**4.5.268**
- Tapping the reply field in staged Messages asks SpringBoard for its keyboard and keeps that request from being cancelled by the stage taking the key window.
- Messages no longer slides the conversation down to make room for its own keyboard. The trace records the keyboard request, whether SpringBoard showed keys, and any view that still tried to move.

**4.5.267**
- Tapping the reply field in a staged Messages conversation brings up SpringBoard’s keyboard, the same one the other staged apps use, and leaves the conversation where it is. The field no longer slides the conversation off the card.

**4.5.266**
- A staged Messages conversation uses SpringBoard’s keyboard, the same as every other staged app. The keys are no longer drawn inside the card. The reply field stays where it is.

**4.5.265**
- Opening a staged Messages conversation no longer freezes the phone. The reply field was measured after it had already moved, so every layout slid it back and posted another keyboard show. The slide now settles, and those keyboard notifications no longer move the field.

**4.5.264**
- A staged Messages conversation still freezes the phone. This build writes a trace from the moment the stage opens until the main thread stops, and keeps that file across the respring. On the stage picker, tap Copy freeze trace and paste it back.

**4.5.263**
- Opening a staged Messages conversation no longer freezes the phone. The push was rewriting the scene presentation while that update was still running, and the reply field was changing the input window from inside the same layout. Both of those waits are gone.

**4.5.262**
- Opening a staged Messages conversation no longer freezes the phone. The push was refusing to leave the text field, laying the transcript out again from inside its own layout, and reading the card size on every bubble.

**4.5.261**
- A staged Messages conversation never loaded the in-app tweak. The package and the install script were still writing a filter that only named Messenger and Signal, so every change inside Messages was skipped. Messages is on that filter again.

**4.5.260**
- The Messages reply field is a child of the input host, and that host stays the height of the phone. The field is slid onto the bottom of the card with a transform after the host lays out, which is the adjustment that survives the host's constraints.

**4.5.259**
- The Messages reply field is pinned to the phone by the input window's constraints, so moving frames never stayed. Those constraints are now given the card's size, and the field stays on the bottom of the card.

**4.5.258**
- Staged Messages leaves the reply field where it already sits and moves the conversation down to that field. The thread and the other views then fill the band just above it. The card shows that lower band instead of the top of the phone.

**4.5.257**
- Messages' input controller is parented to the staged conversation's root and pinned to that root's bottom edge. The stage window is not in the Messages process, so the field is moved from the text-effects window onto the view the card already shows. The keyboard blur no longer adds a safe-area inset, and resizing the card lays the field out again.

**4.5.256**
- Messages' reply field is removed from the system text-effects window and parented to the staged conversation. The input controller was staying under those system layers, so the card never received it. UIKit putting it back is overridden, and the field is pinned to the bottom of the card.

**4.5.255**
- The reply field under Messages' input host was still hanging below the three views that fit the card. That field, its plain wrapper, and the blur layers are now sat on the bottom of those views.

**4.5.254**
- A staged Messages conversation keeps the reply field, and its blur, on the bottom of the card. That bar is parented to the conversation, the home-indicator inset no longer pushes it off, and the invisible editing overlay no longer takes taps inside the card. Resizing or turning the card moves the field with it.

**4.5.253**
- Messages' input controller is moved into the staged conversation and anchored to the bottom of the card. The reply field is no longer left inside the phone-height input window.

**4.5.252**
- The Messages reply field, its blur, and the input chrome are moved up into the visible part of the text-effects window. Those three parent views stay phone-height, and the field sits on the bottom of the stage.

**4.5.251**
- Messages' text-effects window, input container, and input host are clipped to the card. Those three were still the full height of the phone, so the reply field and its blur sat below the stage.

**4.5.250**
- Messages' input window, input container, and editing overlay use the card's size. The reply field and its blur sit on the bottom of the stage.

**4.5.249**
- A staged Messages conversation keeps its reply field and the latest messages on the card. The thread ends at that field, so the bottom of the conversation is on screen.

**4.5.248**
- Messages lays its own interface out at the card's size. The thread, the bubbles, the navigation bar, and the reply field follow the stage the same way every other staged app already does.

**4.5.247**
- A staged Messages conversation lays out inside the card. The thread and the reply bar both fit the stage, and the home bar stays on the phone.

**4.5.246**
- Minimizing the bottom half of Split leaves Split completely. That minimized app is an ordinary stage, and a third stage only exists while Split is on screen.
- The home bar stays at the bottom of the phone. It no longer sticks to a stage, and the Home Screen no longer gets left inside the stage.
- An open Messages conversation keeps its reply bar on the bottom edge of the card.
- Dragging a stage to the middle of the bottom edge terminates it again.

**4.5.245**
- An open Messages conversation keeps its reply bar inside the stage, on a single card and in Split.
- After Split sends an app full screen, the minimized stage's rim drags again. A new stage dragged open beside it uses that same rim, not the whole card.

**4.5.244**
- Touching the inside of a stage uses the app. Dragging the card is the rim around it, so a stage sitting on the bottom half is no longer one big drag surface.
- A staged app that was still laid out for the full screen is fitted to the card. Messages' reply box and the rest of the message stay inside the stage.
- Swiping home and then opening Spotlight no longer safe-modes. Ending that swipe no longer changes the minimized app's scene mode.

**4.5.243**
- Opening a minimized app right after swiping home no longer safe-modes. The app stays a still until that swipe has finished.
- A staged app is created at the card's size, so its own bottom bar stays inside the card. Messages' reply box was being laid out for the full screen and clipped off.

**4.5.242**
- Restoring a minimized app after Split no longer also opens a picker stage. That card was the empty half left behind when the other app became full screen, and a minimized picker is closed.
- Swiping home while a stage is still open no longer safe-modes. The open cards park first, and the minimized app's scene is left alone through the home transition.

**4.5.241**
- Going home after Split sends an app fullscreen no longer safe-modes while another app stays minimized. That minimized app follows the home transition, and the fullscreen launch waits until SpringBoard is finished with the previous one.

**4.5.240**
- Minimizing out of Split into the real full-screen app, then swiping home, no longer safe-modes. That swipe was writing the stage's scene settings in the middle of SpringBoard's own home transition.

**4.5.239**
- Opening a stage over a YouTube short or a fullscreen video no longer steals the key window, which was the flash. Tapping a field still brings the keyboard up above the stage, without moving that window.

**4.5.238**
- While a stage is swiped quickly toward a corner, the app picture stays on the card instead of easing along behind it.

**4.5.237**
- A fast swipe into a minimize corner parks the stage immediately. The corner icon no longer trails in after the card has already stopped.

**4.5.236**
- With two stages up, typing in the lower one moves the stage above it up off the screen, so the one being typed in is visible. It comes back when the keyboard closes.

**4.5.235**
- The black box in Split only showed up when Messages was the top app. That was Messages' full-screen scene presentation left behind outside the card, and it is hidden while that card has the app.

**4.5.234**
- The black box in Split was the scene presentation view sitting at the screen's frame instead of the card. The split app is laid out at the card's size, and the third stage sits 6 points inside the card on every side.

**4.5.233**
- A safe mode writes `/var/mobile/Library/Preferences/com.recreated.dynamicstage.crash.log` and leaves it there across resprings. Installing a new build deletes that file, so the last crash is not still waiting.

**4.5.232**
- The black box outside a split card was the scene presentation view. It is cleared and pinned to the card. The third stage always lands on a half, the same way the other cards do, and it is only a tiny bit smaller.

**4.5.231**
- Opening Safari in a stage while a video or short is playing no longer safe-modes the phone, and the keyboard can come up without fighting that video. The third stage matches the other cards and sticks onto the half it is over.

**4.5.230**
- The stage that floats over Split is only a little smaller than the other two cards.

**4.5.229**
- The right-edge notch is visible again. It keeps a solid fill, and stage cards no longer sit on top of it.

**4.5.228**
- A minimized app stays running. It is no longer suspended when its card leaves the screen, and its view keeps its real size instead of being crushed into the corner.

**4.5.227**
- A minimized stage no longer blocks dragging New Stage into Split Screen. An app that is already staged, including one sitting in a corner, is dimmed in the app picker and cannot be opened again. The split app follows the card’s rounded corners instead of sticking out as a square.

**4.5.226**
- The split app is sized to the card, so the black piece outside the top stage is gone and the Home Screen shows behind it. Notifications and calls stay visible. Minimizing or closing the bottom card grows the top app out of the stage into the real full screen.

**4.5.225**
- Split View fits the app inside the card. Dragging the bottom card down grows the top card with it and shows more of that app. Minimizing or terminating the bottom card makes the top one full screen. While split, New Stage can add one card that floats above the others and takes the drag from whatever it covers.

**4.5.224**
- Dragging New Stage grows the new card out from the finger. Over the lower half the outline says Stage. In the terminate spot it says Split Screen, Terminate stays hidden, and the app that was on screen opens in its own stage on the top half.

**4.5.223**
- The rim is the full card outline again. While two stages swap, the bottom half of the upper card's rim and the top half of the lower card's rim pulse. The New Stage button follows a drag, and letting go still opens a stage on top.

**4.5.222**
- The swap outline is gone. The normal rim is only the bottom of the top card and the top of the lower card. The red glow is back in front while the finger is over the terminate area.

**4.5.221**
- The swap hint follows the card rim around the lower half of the upper stage and the upper half of the lower stage. Corners ease in instead of grabbing. The home-bar glow is bright enough to see while you hover it.

**4.5.220**
- The home-bar glow is a darker red. Corners start a little further out and hold a bit more. The swap hint is a faint pulsing glass line on the bottom of the upper card and the top of the lower card, only while those edges cross slowly.

**4.5.219**
- Settling no longer bounces. Corners and Terminate only start when the finger is much closer, corners win, and Terminate sits lower. The red glow fades out around its edges.

**4.5.218**
- The screen edge is a soft bounce, not a wall. A stage only tugs lightly at each half, and a move toward a corner or the home bar from the top skips that and can leave the screen. Swapping shows two faint glass strips that slide toward each other between the cards.

**4.5.217**
- The notch and New Stage are separate again, in the same material. Opening it no longer closes when you touch elsewhere. Terminate is only a faint red glow at the home bar when a stage is right against it. Corners stick only when the card is much closer to them. Swapping shows a faint wavy outline of each stage. Half ghosts are gone, and a drag stays on screen with a little give unless it is heading for a corner or the home bar.

**4.5.216**
- The notch and New Stage are one capsule. Touching anywhere else while it is open closes it.

**4.5.215**
- The swap hint is two faint waves running past each other between the stages. It appears as soon as the cards move toward one another, and letting go there swaps them.

**4.5.214**
- Terminate sticks in a smaller area, lower on the screen. Corners only stick once the card is much closer to them. A drag on the top card starts immediately, and a quick swipe toward a corner minimizes there.

**4.5.213**
- Pulling a minimized stage back in keeps the app picture on the card until it is open again, so the drag is not black. The edge notch is a slimmer blurred capsule. Dragging two stages toward each other shows faint moving outlines, and letting go swaps them.

**4.5.212**
- A corner only sticks, and the stage only shrinks, once most of the card has crossed into that corner. The corner line starts further in. Grabbing the rim of a stage that sits over another app takes the touch before the app behind it.

**4.5.211**
- Corners stick before Terminate. The stage shrinks as it sticks and grows again as it lets go. The ghost sits on the half under the finger, then on the corner or Terminate once that point is sticky. Minimized icons are smaller and closer to the corners.

**4.5.210**
- Dragging a stage toward a corner shows that corner ghost again. Terminate no longer takes over the whole lower half. A stage pulled out of a corner still opens on the half under the finger.

**4.5.209**
- Dragging a stage toward a corner shrinks it the way it did before 4.5.206. Pulling a minimized stage out lands on the half under your finger, and the ghost follows that half.

**4.5.208**
- Pulling a stage out of a corner grows it as it follows the finger, and a ghost shows the half it is heading for. Dragging the app picker keeps the picker visible.

**4.5.207**
- A dragged stage shows the app again. Pulling one out of a corner keeps it under the finger, blurred while it is close and clearer the further it comes out.

**4.5.206**
- The diagonal swipe back to the picker is easier to start. While a stage is dragged, including out of a minimized corner, it is a small blank box in the picker colour and it stays under the finger.

**4.5.205**
- The swipe that leaves an app and returns to the picker starts on the stage card’s bottom corners, not on the phone corners where a stage is minimized.

**4.5.204**
- Pulling diagonally out of a minimized corner shows the app while the finger is still moving. The same swipe from either bottom corner, while an app is on the stage, leaves that app and returns to the picker.

**4.5.203**
- A stage dragged from the top can reach a corner or Terminate without stopping on the lower half first. The card stays full size until it is actually down by a corner or pushed into the small bottom-centre zone.

**4.5.202**
- Moving a stage from the top down to the lower half stays full size. Corners take priority, and terminate is only a small area at the bottom centre once the card is already low.

**4.5.201**
- Terminate sticks partway as the card nears the bottom centre, with a faint outline of that spot and a faint red glow from the bottom. A phone call keeps a still on the open stage so the card does not go black. A minimized app keeps running until it is terminated.

**4.5.200**
- Dragging toward a corner shrinks the stage itself into that corner. The outline left behind is the half it returns to. Terminate is faint text with a faint red glow from the bottom, and the outline pill is gone.

**4.5.199**
- No outline sits under the home bar when no stage is open. Dragging a card no longer presses what is inside it. Corners stick and shrink, with a hint only at the corner they are heading for. Terminate starts lower, with no red, and the rim is a faint outline.

**4.5.198**
- Restored the 4.5.192 drag. The card sticks toward a corner or Terminate, the ghost outline follows it, and the terminate zone shrinks the card and turns the outline faint red.

**4.5.197**
- The rim, corner outlines, Close stage zone, and Stage here hint match the 4.5.112 bezel. The card shrinks as it is thrown into a corner and sits at 92% in the close zone.

**4.5.196**
- Drag is the 4.5.112 bezel again. The outside rim is what you grab, and the outline moves to Stage here, a bottom corner, or Close stage.

**4.5.195**
- The rim is not a drag target. The ghost outline, the Terminate hint, and the bottom-centre terminate control are gone. Dragging a card moves it at full size again, and letting go low and to either side still minimises into that corner.

**4.5.194**
- The flying drop-zone outline is gone. The rim is the faint ghost of the outside grab band again, and that band is what you drag.

**4.5.193**
- The ghost outline travels toward the corner or the Terminate area as the card is dragged that way, instead of staying wrapped around the card.

**4.5.192**
- Dragging toward a corner or Terminate sticks, and a ghost outline follows the card. In the terminate zone the card shrinks a little and the outline turns faint red. Minimising into a corner eases off instead of bouncing. The corner that brings a stage back is smaller.

**4.5.191**
- The bottom-centre hint says Terminate. It appears when a stage is dragged from the top down to the bottom of the screen, not only when the middle of the card is already at the bottom.

**4.5.190**
- The minimized app icon sits in the corner it was dragged to. A diagonal drag from that corner brings the stage back without having to be a steep pull. A stage that is still on screen wakes when touched, and a minimized app is no longer closed out from under its icon.

**4.5.189**
- Minimising sends the card off the corner it was dragged toward, not off the bottom middle. An app picker dragged to a corner leaves that way and then closes. Opening another stage leaves the minimized app in the background, so SpringBoard no longer safe-modes.

**4.5.188**
- Dragging a stage into the lower half no longer shrinks it. It shrinks only as it moves into a bottom corner, and that corner is where it minimises. Dragging it to the bottom centre shows Release to close, and letting go there removes the stage instead of parking it off the bottom middle.

**4.5.187**
- The strip inside the card edge no longer starts a drag. The grab stays outside the card.

**4.5.186**
- A minimized stage is fully off the screen. The card, its shadow, and the rim are hidden, so the corner no longer stays visible.

**4.5.185**
- A minimized stage leaves the screen completely. Its icon sits inside the corner, not under the rounded edge. The card shrinks as it is dragged into a corner and grows again when pulled back. Dragging it to the bottom centre shows Release to close. The corners still take priority over that close area.

**4.5.184**
- The rim is a blurred ghost outline. A thin strip inside the card edge can start a drag. Swiping a stage that is still the app picker into a corner closes that stage.

**4.5.183**
- The rim is a faint glow around the card edge. There is no outline stroke.

**4.5.182**
- The stage rim is a thin faint glow just outside the card, not a wide filled band.

**4.5.181**
- A minimized card stays in the corner it was dragged to. It does not park off the bottom middle. A diagonal drag inward from that corner brings it back, including the lower-left corner. The rim around a stage is wider and drawn as a ghost outline you can grab.

**4.5.180**
- A home swipe no longer turns an open stage black, and it does not bring a minimized stage back or take that app out of the background.

**4.5.179**
- Swiping the home bar with one stage minimized and another still open no longer safe-modes the device. The stage no longer tells a hosted app it is still in front during that swipe.

**4.5.178**
- The home bar works while a stage is minimized. Swiping home while a stage is on screen no longer turns the card black.

**4.5.177**
- A stage on the top or the bottom moves up to sit above the keyboard, and drops back when the keyboard is dismissed.

**4.5.176**
- Choosing an app after the picker has been dragged to the bottom no longer hosts the keyboard inside the card. The scene stays on the top half, the same as choosing the app first and dragging it down afterwards. The picker’s keyboard is not handed to the new app.

**4.5.175**
- The first stage slides in from the top of the screen. Swiping the home bar no longer turns a visible stage black. A card follows the finger and minimises into the lower-left or lower-right corner. It does not park straight off the bottom.

**4.5.174**
- A left swipe from the phone’s right corner does nothing to a stage. The top pills are gone. Drag a card down into the corner to minimise it. New Stage, while one is already open, pushes that card down and brings the new one in from the top.

**4.5.173**
- Pulling up from the bottom-right corner no longer opens a stage. Drag the card down into that corner to minimise it. A diagonal swipe from the corner, or from just to its left, puts that card back on the half it was on.

**4.5.172**
- Swiping left along the bottom from the bottom-right corner is not a stage gesture. The stage does not take that swipe.

**4.5.171**
- Tapping New Stage again opens another stage. The first one stays on top. The next one takes the other half.

**4.5.170**
- The shelf control is a New Stage button. It opens on the top half of the screen first.

**4.5.169**
- A card is never parked below the screen. The right-edge swipe and the bottom-right inward swipe are gone.

**4.5.168**
- Split View is gone. Pulling the corner, dragging the grabber up, and the walkthrough no longer resize the app behind the card. The stage only floats. Dragging the card between the top and bottom halves is unchanged.

**4.5.167**
- The top card can be dragged down and snapped onto the lower half again. That is the same card and the same keyboard path. There is still no separate bottom stage, no Bottom shelf square, and no second stage.

**4.5.166**
- The bottom stage is gone. The card cannot snap or be dragged onto the lower half. Split View keeps the card on the top half. The shelf has no Bottom square. Adding a second stage does nothing. Opening a stage always uses the top half.

**4.5.165**
- The lower card was still accepting key taps because the in-stage keyboard had been forced visible and interactive. That is undone. Every staged card, top or bottom, now uses the top card’s keyboard path: the in-stage keyboard does not show, does not take taps, and does not activate. SpringBoard’s keyboard is the one that remains.

**4.5.164**
- Removed every bottom-half keyboard branch. A card on the bottom half runs the same keyboard code as a card on the top half: remote keyboard, keyboard windows left at screen size, same SpringBoard raise. No bottom-half bit, no separate bounds, no separate hosted-keyboard path.

**4.5.163**
- Keyboard windows were deliberately left at full-screen size, so on a bottom card the keys were laid out below the cropped scene and never appeared inside it. A bottom-half card now gives those windows the card’s bounds.

**4.5.162**
- 4.5.161 never ran on a real bottom card. The app’s windows start at y=0 inside the scene, so the “bottom half” test always failed and the remote-keyboard path stayed on. SpringBoard now sets a bottom-half bit on the stage notification, and the app trusts that bit.

**4.5.161**
- A card on the bottom half no longer claims a remote keyboard, so UIKit keeps the hosted keyboard inside that scene. The top half still uses SpringBoard’s keyboard. Alpha was already 1; the bottom card had nothing to draw because the hosted keyboard view was refused.

**4.5.160**
- The in-stage keyboard is no longer forced to alpha 0 / layer opacity 0. Those views stay at full opacity. Dragging the top card to the bottom half already showed that zeroing opacity was not what made the top keyboard visible.

**4.5.159**
- Stopped moving staged-app keyboard windows, views, and layers off-screen (`y = 10000`). They stay where UIKit put them. SpringBoard still pins its own keyboard to the screen above the stage.

**4.5.158**
- The bottom card covers the same screen region the keyboard uses. The top card does not, which is why only the bottom card hid SpringBoard’s keys and showed an in-scene keyboard. SpringBoard now pins its keyboard window to the full screen, above the stage. The staged app parks its own keyboard windows off-screen so they cannot paint inside the card.

**4.5.157**
- Single-card keyboard is **the same on top and bottom half**: no card lift, no keyboard safe-area inset, no bottom-only assumed-frame lift. SpringBoard only raises its keyboard window above the card (same as top half always did).

**4.5.156**
- **Bottom stage only:** SpringBoard no longer lifts from UIKit keyboard notifications while the hosted app’s in-scene keyboard is animating (remote path). Card lift uses an assumed frame; the card stays clipped until SpringBoard’s keys are on screen.
- Staged app banishes local keyboard **before** first responder, on every keyboard will-show/frame notification, and on an earlier run-loop pass — reduces the in-card flash top stage never showed.

**4.5.155**
- Stops the **in-card keyboard flicker**: local keys are banished again (4.5.153 path) instead of reveal fighting remote mode. **UIKeyboardRemoteControlView** is a nearly invisible bottom band only, not a full-card cover.
- SpringBoard raises and unhides the real keyboard as soon as the app reports remote, lifts the bottom stage even before key views register, and no longer requires keys at x≈0 to count as on-screen.

**4.5.154**
- Staged apps **reveal** every keyboard window and subview on each pass (no banish, no off-screen moves, no stripping **UIKeyboardLayerHostView**). Hooks undo `hidden` / low `alpha` on keyboard chrome.
- SpringBoard does the same while the staged keyboard is raised: all keyboard windows and ghost layers stay visible; `setHidden` / `setAlpha` on keyboard views are reverted.

**4.5.153**
- **UIKeyboardRemoteControlView** is no longer banished with other in-app keyboard chrome. While staged it is laid out to match the hosted app window on screen (full stage container cover) on every keyboard pass and in `UITextEffectsWindow` layout.

**4.5.152**
- Codebase restored to **4.5.133** (top-stage keyboard unchanged). Staged apps strip **UIKeyboardLayerHostView** on creation, when added to the hierarchy, and on every keyboard banish pass so it never stays in the hosted scene.

**4.5.133**
- Keyboard code is the top stage's code again. Nothing in that path was rewritten. The second card is only a copy of the top card placed on the bottom half.

**4.5.132**
- A card on the bottom half uses the same keyboard path as the one card after it is dragged down. The two-card keyboard branch is not used.

**4.5.131**
- Opening an app from the second stage keeps that app on the second card. It no longer collapses the second stage and replaces the first card's app.

**4.5.130**
- Second stage is another copy of the top stage, placed on the other half (the bottom half when the first card is on top). It uses that card's keyboard path. The old bottom-slot companion lift is not used.

**4.5.129**
- Restored the 4.5.78 outer-rim snap between top and bottom. That drag only moves the same card; it does not use a separate bottom-stage keyboard path.

**4.5.128**
- Back to the 4.5.78 tree. Overlay stage stays on the top half (no snap to the bottom half). Removed the bottom-half keyboard stall that returned before the card moved while keys were still inside the app scene, and the companion lift that treated the single card as a bottom stack slot.

**4.5.78**
- Stage reposition matches stock Dynamic Stage: grab the **outer bezel** around the card (22pt band, subtle ring), drag **vertically only**, snap sticky to **top or bottom half**; in-app touches stay on the app
- Removed free X/Y in-card edge dragging from 4.5.77

**4.5.77**
- Drag the overlay stage anywhere on screen: bottom grabber pill (like the top one) or a drag starting on the card edges; top grabber still puts the card away / split as before
- Hosted scene geometry follows a freely moved card in overlay mode
- Documented that dual-stack SpringBoard code is dead while `kDSMaxStackSlots` is 1 (no bottom stage is created at runtime)

**4.5.76**
- Removed hosted-scene keyboard extension (the 288pt taller scene that was resizing Messenger's card on every key up/down). Keyboard handling is clip-band only again, with a guard so brief keyboard-down events do not tear down while keys are still on screen
- Still single top stage only (4.5.75); keyboard log in Settings and the stage picker; no SpringBoard debug overlay

**4.5.75**
- Back to single top-half stage only (4.5.68 / pre–dual-stack behavior): no bottom edge stage, no second stack slot, no Below shelf square
- SpringBoard debug overlay removed; keyboard log is in Settings › Diagnostics (footer) and in the stage picker (“Tap to copy keyboard log”)
- `kDSMaxStackSlots` is 1; opening a stage always uses the top-half path that worked before dual stack

**4.5.74**
- Removed the SpringBoard keyboard debug overlay at the top of the screen (keyboard-stage.log file is unchanged)
- Restored bottom-half keyboard lift in dual stack; only the top card keeps the lone-top scene-extension path
- Fixed keyboard targeting when the same app is on both stacks (e.g. two Messengers) so typing on one card does not move the other

**4.5.73**
- Reverted the 4.5.71 keyboard experiments that broke lone top-stage resize and pushed the bottom stage back to an in-app keyboard
- Dual stack now uses the same rule as a lone top-half stage: scene extension plus SpringBoard keys, not lifting the card over in-scene keys
- Keyboard hide only clears scene extension on the app that owned the keyboard, not both stacks
- The keyboard-stage.log file from 4.5.72 is unchanged

**4.5.72**
- Dual-stage keyboard debug is written to a dedicated file: `/var/mobile/Library/Preferences/com.recreated.dynamicstage.keyboard-stage.log` (also shown on the on-screen debug overlay as `keyboard-stage.log`). The file is replaced on every respring when SpringBoard starts; reproduce the bug, then copy that whole file

**4.5.71**
- Dual-stage keyboard debug overlay: whenever the stack migrates or an app attaches, the on-screen log shows stack slots, keyboard extension heights, dylib/remote flags, and which bundle owns keyboard notifications
- Fixed inverted keyboard-slot attribution when only one of the two stack slots is hosting (UIKit notifications were lifting the wrong card)
- `keyboardDrawnOutside` is tracked per app bundle so the top stage no longer blocks the bottom app's remote-keyboard and scene-extension path
- After migrate and bottom attach, both hosted apps are re-published to geometry/peer notifications

**4.5.70**
- Adding a stage from the notch Below square no longer puts the new app in stack slot 1. That was the old broken path and it brought back the invisible keyboard. The app already on stage moves to the top slot; the new app is hosted in slot 0 on the bottom half, the same stack slot as a lone top stage

**4.5.69**
- After the first stage is on screen from the notch, tapping the notch again opens the shelf with your staged app on top and a Below square to add a second stage under it. The second stage uses the same picker and host path as the first, on the bottom half. The corner swipe still only opens the first top stage. The card + button stays off

**4.5.68**
- One stage only, always the same as the top notch square: single card on the top half, stack slot 0, no second host. The bottom notch option, the corner swipe that opened a bottom picker, and the + dual-stack control are removed. Opening from the notch, the corner, or programmatically collapses any old dual-stack state and uses the top-half path

**4.5.67**
- With two stages open, UIKit's keyboard notifications were always blamed on stack slot 0. The bottom card never got the same lift and scene extension as the top one, so only the bottom stage kept an in-scene keyboard region that ate touches. The active slot is now the one typing, the one already lifted, or the card on the bottom half. Slot 1 gets the same keyboard refresh on attach as slot 0. Swapping halves re-publishes geometry and re-applies the extension for whichever app owns the keyboard

**4.5.66**
- The in-app dylib filter no longer names UIKit, only the app bundle ids (Messenger and Signal). That UIKit entry did not load the tweak into Messenger and made `ctor=[missing]` look like suppression was missing
- While an app is on the stage, its own keyboard host view is killed on every layout pass: hidden, no touches, opacity zero, subviews the same. App keyboard windows are forced hidden and non-interactive. `UIKeyboardImpl` does not spawn a local keyboard while staged; SpringBoard's keys stay the only visible one
- The debug line `uiHost=` is SpringBoard's keyboard UI client bundle, not whether the app hook ran. `appDylib=yes` means the in-app side reported in. `mapped=` in diagnostics means dyld mapped the app dylib even if the ctor file is stale

**4.5.65**
- The code is 4.5.55 again. Everything from 4.5.56 to 4.5.64 is out
- The keyboard inside the card was never a view SpringBoard could reach. The app keeps a keyboard region at the bottom of its own scene, and the system routes any touch in that region to the keys, even though the keys are drawn by SpringBoard at the bottom of the screen. That region was the bottom 301pt of the card. While SpringBoard is drawing the keys, the app's scene is now made taller than the card by the keyboard's height. The app puts its keyboard region in that extra band, which is below the card and clipped away, and lays its content out in the part that is the card. A tap or a scroll anywhere on the card reaches the app. The scene goes back to the card's size when the keyboard goes down
- A card that had been minimized for a while came back black because the app had been put in the background and never asked to run again. Showing the card now checks the scene and wakes the app

**4.5.64**
- The GitHub uploads are not in this build. The staged app's own keyboard host view is now switched off at the source inside that app: hidden, no touches, opacity zero, and its subviews the same, every time UIKit puts it in a window or lays it out. The app's keyboard windows take no touches while staged. SpringBoard's keyboard is the only one left. Nothing is done to SpringBoard's own windows
- On SpringBoard's side, a touch on the full-screen keyboard window is a key only on the strip the keys occupy, not on the keyboard view that sits above it. The in-app filter names UIKit only

**4.5.63**
- The card view from the GitHub upload is in this build. The keyboard file in that upload stopped mid-function, and the scene host and in-app stage context were different classes than the rest of the tweak calls, so those three stay the implementations that already place the keys and host the app

**4.5.62**
- Messenger still had not loaded the in-app tweak, so its own keyboard stayed inside the card. The restart looked for a process id and found none. It now quits the hosted app the same way the stage already can, then puts that app back on the card so the in-app tweak loads and that second keyboard is gone

**4.5.61**
- The keyboard SpringBoard draws is already at y=631. The other one is inside the staged app, and Beeper never loaded the in-app tweak (`ctor` missing), so that copy kept taking taps. Beeper is named in the filter. A staged app that still has not loaded the tweak is restarted once so its keyboard is the remote one, not a second keyboard inside the card

**4.5.60**
- 4.5.59 moved the keyboard window to y=1262, past the bottom of the screen, so the keys never drew and the card lift dropped to 0. The window frame is not changed again. The keys stay on the stage scene at level 6000, and a touch above that strip still does not count as a key

**4.5.59**
- The keyboard window was still the full screen, so a touch on the bottom card was inside that window even though the keys start at y=631. Its frame is now the key strip, and the other keyboard windows use that same frame. A touch above the keys is outside the window. The keys stay on the stage scene at level 6000, and the original frame is put back when the keyboard closes

**4.5.58**
- Several keyboard windows were all taking touches at level 6000, so a scroll on the staged app pressed keys on a second keyboard stacked just above the visible one. Only the lowest key strip stays interactive. Medusa and the aperture windows ignore every touch. Nothing is hidden, and the windows stay on the stage scene at level 6000

**4.5.57**
- The keyboard window is the full screen, so a touch on the card was still a keyboard touch. `UITextEffectsWindow` now accepts a touch only when it lands inside the keyboard view itself. A touch above the keys goes to the staged app. The windows stay where 4.5.50 put them

**4.5.56**
- 4.5.55 let the touch through the keyboard window, and the log shows that, but the keyboard still watches every event in the process and starts a key from a scroll on the card. That tracker now ignores a touch unless it is on the key strip. The staged app's own tracker does the same. The keyboard windows stay where 4.5.50 put them

**4.5.55**
- A tap or a scroll on the staged app was still pressing a key. The keyboard windows override the hit test 4.5.54 hooked, and the app keeps its own invisible keyboard over the card. Touches above the keys now pass through both, so the app gets the scroll. The card also sits a little higher above the keyboard. The keyboard windows stay where 4.5.50 put them

**4.5.54**
- A tap on the bottom card was hitting a keyboard key. The keyboard windows are full screen and sit above the stage, so they were taking every touch. They now accept a touch only inside the key band. A tap on the app reaches the app. The windows stay where 4.5.50 put them

**4.5.53**
- The keyboard windows are still placed the same way as 4.5.50. The card was the part that sometimes stayed down: it waited for the app to report a remote keyboard, and Signal's keys were already on screen before that report. The bottom card now lifts as soon as those keys are on the display, and again a moment later if the key view was not ready on the first event. While it is up, the top card leaves the screen. Both snap back the moment the keyboard goes down. The old routine that shortened the hosted scene is gone. The in-app keyboard hooks are unchanged

**4.5.52**
- 4.5.51 is reverted. The keyboard is back to the 4.5.50 behavior that was drawing it in the right place: every keyboard window on the stage scene at level 6000, the card lifting only after the app says the keyboard is remote, and the top card staying on screen

**4.5.51**
- The bottom card lifts as soon as SpringBoard is drawing the keys, including when the app's remote-keyboard signal shows up late. That was the lift that sometimes never ran. While the bottom card is up, the top card leaves the screen, and both come back the moment the field resigns. Leaving a field no longer waits out the one-second hold. The old scene-clipping band and the SpringBoard proxy field that took the key are gone

**4.5.50**
- The log showed five keyboard windows, the remote-keyboard one left on its own scene, and `SBMedusaHostedKeyboardWindow` on SpringBoard at level 20, under the stage at 999. Every keyboard window is now moved onto the stage's scene and held at the status bar plus 5000, including Medusa and the remote-keyboard window, and UIKit cannot put the level or the scene back. The card does not clip. Letters, deletes, and `insertText:` from SpringBoard's keyboard are written through to the staged field. Keyboard classes are not removed and the keyboard UI host is not assigned; both of those sent the phone to safe mode

**4.5.49**
- The level-6000 window was one window. UIKit left a second keyboard window on SystemAperture at level 10, and that is the one the stage clipped. Every visible keyboard window is now held at the status bar plus 5000, and any window UIKit puts on an aperture scene is moved onto the same scene as the stage. The remote-keyboard window stays on its own scene, because moving that one off it stopped the keys painting. The card's layer does not mask while those windows are up. Letters typed on SpringBoard's keyboard are written through to the field the staged app already has. The keyboard UI host is not assigned and no keyboard class is removed

**4.5.48**
- The keyboard window SpringBoard already has was sitting on SystemAperture at level 10, and every keyboard event put it back there, under the stage at level 999. While a staged app's keyboard is up, that window is returned to the remote-keyboard scene and its level is held at the status bar plus 5000. The card no longer clips past its own edge. The text field stays the editor. The window is put back when the keyboard goes down

**4.5.47**
- The keys in the new screenshots start at the card's 5pt inset, so they are Messenger's scene, not a window sitting under the stage. The search keyboard is already visible in the gap at level 10, so raising that window does not pull scene pixels out. iOS 16 does not call `isUsingRemoteKeyboard`, which is why the app never said the keyboard was remote. A staged app now uses the plain remote keyboard window on its own scene, and it does not take the hosted keyboard view into the card. The bottom card lifts only once SpringBoard itself is drawing full-width keys. The scene is not clipped and that window is not moved

**4.5.46**
- 4.5.45 cut the hosted scene down until the content view was 120pt tall, so the bottom card went blank, and it left the top card alone because that card does not cover the screen keyboard. The scene is not clipped. The bottom card lifts only after the app says the keyboard is remote, which is when SpringBoard is drawing the keys. The in-app filter names UIKit, which is what this ElleKit uses to inject into an app, and system processes return before any hook

**4.5.45**
- The 296pt mask on the card never clipped Messenger's scene, so the keys stayed inside the bottom card. The hosted view is clipped by its superview's bounds, not by a mask path. When SpringBoard already has a system keyboard on screen, the content view is shortened to that overlap and the app view stays the full card height, so the app does not relayout the keys up into the opening. The keyboard window stays in the remote-keyboard scene. A top card that does not cover the keyboard is left alone. The in-app dylib no longer links CydiaSubstrate, which a sandboxed app cannot resolve, and its filter is the same OpenStep form SpringBoard's tweak already uses

**4.5.44**
- Moving the keyboard window onto the stage scene took it out of the only scene that actually draws it, so the keys had a frame and nothing on screen. The top card then showed no keyboard, and the bottom card still showed Messenger's own keys. That window stays in the remote-keyboard scene. The card cuts off the bottom band where the hosted app paints its keyboard, and touches there fall through to the system keyboard

**4.5.43**
- The keys stayed inside the card because the system keyboard window is in the remote-keyboard scene at level 10, and the stage is a different scene at level 999. Raising the window level cannot cross scenes. While a staged app has the keyboard up, that existing window is moved onto the stage's scene and set just above the stage. The card is not lifted. The window goes back to its own scene when the keyboard goes down

**4.5.42**
- 4.5.41 reported the keyboard as outside the card and lifted slot 0 by 306pt. That window was SpringBoard's own text-effects window, and Messenger never ran the in-app dylib, so the keys the user saw stayed in the card and moved with it. The card now stays put until Messenger reports that UIKit is using the remote keyboard. The in-app filter is XML and lists only the Messenger bundle, which is what ElleKit matches. The log prints that filter, whether the dylib image mapped, and the constructor's reason if it returned early

**4.5.41**
- Opening the bottom of the card cannot move the keys. They are painted inside Messenger's scene, and that scene is the card. While Messenger is staged it now tells UIKit the keyboard is remote, which is what makes SpringBoard draw the keys in its own window. That window is lifted just above the stage, and the card lifts only after those keys are actually there. Touches outside the keys fall through to the app. Nothing creates a keyboard window, assigns the arbiter host, or hides keyboard views

**4.5.40**
- The keys stayed inside the card because UIKit in SpringBoard posted `UIKeyboardWillChangeFrame` for Messenger's keyboard. That was treated as SpringBoard's own keyboard and lifted the card 306pt, dragging the keys up inside the chrome a moment after the bottom of the card had been opened. A hosted app's keyboard no longer lifts the card. Those keys stay in the system keyboard band under the chrome

**4.5.39**
- The phone went to safe mode after staging an app because Messenger was forced onto UIKit's remote keyboard and SpringBoard stole the keyboard UI host. That path is off. SpringBoard no longer overwrites TweakInject (the failed copy was deleting the filter). A staged app draws its own keys; the bottom of the card opens so those keys sit in the system keyboard band instead of inside the rounded chrome. Picker search still lifts the card over SpringBoard's own keyboard

**4.5.38**
- The keys were still inside the card because DynamicStageApp.dylib was missing on the device (`libs=0`), so Messenger never banished its own keyboard, and SpringBoard created an empty full-screen remote keyboard window (`bind=0`) that covered nothing useful. The package now embeds that dylib under Application Support and restores it into DynamicLibraries and TweakInject on install and on boot, then restarts Messenger. Empty remote windows are no longer created; only a real keyboard with keys is raised above the stage

**4.5.37**
- Typing stayed in Messenger, but the keys were still drawn inside the card because the remote keyboard window sat under the stage. That window is now lifted to status-bar level only (never alert), and the arbiter scene layer is bound into it. The keyboard UI host is handed back when the keys go down or the stage is minimized, so Spotlight and Filza are not stuck. The in-app dylib is copied into TweakInject again on boot if it is missing

**4.5.36**
- The caret left the tapped field because SpringBoard's proxy field took the key. That path is gone for staged apps. SpringBoard becomes the keyboard UI host so the keys sit outside the card, and Messenger keeps the message field as the editor. The in-app filter is Messenger only (ElleKit ignored Exclude and never loaded a UIKit-wide filter into Messenger). Picker search is unchanged. Keyboard windows are not raised

**4.5.35**
- Continues from 4.5.29. The picker keyboard still sits outside the card. Letters stayed in SpringBoard because ElleKit never loaded the in-app side into Messenger: that dylib lived only under DynamicLibraries, and TweakInject is a separate directory on this jailbreak. Installing now copies it there and restarts Messenger. Keystrokes are also written under /var/tmp so the app can read them. The post-4.5.29 keyboard host and Foundation-filter experiments are not brought back

**4.5.29**
- Messenger never ran the in-app side. The log has the picker keyboard and the letters, and no line from Messenger, because an already-open app was only checked at launch. The half-screen card is noticed after that, and the message box is hooked then. The picker keyboard is unchanged

**4.5.28**
- The blue line appeared in Messenger and then left, because hiding Messenger's own keyboard resigned the message box and the stage window's field became the editor. That hide no longer resigns the message box. The picker keyboard is unchanged

**4.5.27**
- The letters were still only recorded in SpringBoard. Messenger never answered, because it was listening on a notification center that does not receive this post. It now listens the same way it learns that it is on the stage. The picker keyboard is unchanged

**4.5.26**
- The letters were leaving the picker keyboard. Five of them were recorded, and none of them arrived in Messenger. Each letter is now written into the message field, and Messenger's own keyboard stays hidden. SpringBoard records `app: key insert` with `changed=1` when the message field took the letter

**4.5.25**
- The staged keyboard appeared, then the home screen took the key and the letters went somewhere else. The field was also refusing the letter, so the keyboard left it after one character. The same field keeps the keyboard while that stage is open. Minimizing still hides it

**4.5.24**
- Letters typed on the staged keyboard never left SpringBoard. Delete did, because that key hits the field directly, and a letter goes through the field editor instead. Those letters are now forwarded into the staged app. A 346pt shortcut-bar frame no longer lifts the card past the 301pt picker keyboard

**4.5.23**
- 4.5.22 kept the staged keyboard up after the app was minimized, and the shortcut bar came back with it. A staged app uses the picker keyboard again. That keyboard goes away when the stage is minimized or the app is left. The app's own keyboard stays hidden

**4.5.22**
- Typing in a staged app showed the right keyboard and then dropped the letters, because the home screen took the key back while the field was still open. The stage keeps that key until the field actually closes, and the letters go into the field that was tapped. The log records each key as a length, not the text

**4.5.21**
- The picker keyboard for a staged app stayed up after the text field closed, because that close happened in the same moment the stage window took the key. A real close still hides it. Messenger keeps the message box as the field the keys type into, so the same keyboard can actually enter text

**4.5.20**
- A staged app on the top or the bottom was still allowed to start its own keyboard and the arbiter's keyboard. Both are blocked. Tapping a text field uses the picker search keyboard: the stage window takes the real key, a SpringBoard text field edits, and that keyboard is shown again until it is on screen

**4.5.19**
- The search keyboard still did not appear: another window kept the real key, on one of the three foreground scenes, and the log was saving only its newest line. The stage window moves onto that window's scene, takes the key, and then asks for the same search keyboard. The log keeps the whole boot again

**4.5.18**
- After a respring the stage window still said it was key after SpringBoard had taken the real key window back. The search field edited, and UIKit never asked for a keyboard. That stale key state is resigned and the same search keyboard is requested again once this window is actually key

**4.5.17**
- The diagnostics log is replaced every time SpringBoard starts, so a report after a respring is only that boot. Each picker search attempt records whether the stage window is key, which scene it is on, whether the search field is editing, and the keyboard frame. The same line is on the stage

**4.5.16**
- After a respring the stage window was sometimes left on a scene that was not on screen, so the picker search field took the tap and the keyboard never appeared. The window is moved to the foreground scene, and the same search keyboard is requested again until it is on screen

**4.5.15**
- A staged app on the top or the bottom uses the picker search keyboard. The app no longer draws its own keys, and SpringBoard no longer swaps in a different keyboard scene. Tapping a text field makes the stage window key and brings up that same keyboard, and the card lifts the same way

**4.5.14**
- The corner pull, the right-edge squares, and the + button all open a stage the same way: fixed half size, opaque picker, then the same spring. A second card no longer fades in from invisible, so a cancelled animation cannot leave that half black
- Every picker search uses the same keyboard as the first picker. The stage window becomes key only while a search field is editing, and it is handed back when that edit ends if an app is still staged. Opening a picker beside an app does not lift the new card
- Laying out a card clears its keyboard lift before writing the frame, so the card cannot be thrown off screen

**4.5.13**
- Searching in the picker already shows the normal keyboard and lifts the card. A staged app was covering that with a full-screen keyboard scene. That scene is no longer placed on screen, so a staged app gets the same keyboard as the search field, and the card still lifts

**4.5.12**
- 4.5.11 hid SpringBoard's keyboard window whenever any keyboard went down, so no keyboard could come back, and it pulled the new bottom card up as soon as that half opened. Both of those are undone. Keyboards show again, and the bottom stage stays on the bottom half

**4.5.11**
- Searching in the second stage's picker was ignored while the other stage had an app, so that picker stayed under the keyboard. That search keyboard now lifts the picker card
- The keyboard window was left on screen after the keys went down. It is hidden when the keyboard goes down

**4.5.10**
- The keyboard stays SpringBoard's. Only the card that the keys cover slides up, and the other card stays on its half. The top stage is no longer pushed off the screen while typing in the bottom one
- SpringBoard's keyboard window is left at the size SpringBoard gave it, instead of being stretched over both cards

**4.5.9**
- The log said SpringBoard's keyboard scene was up, but that window was hidden again because it had no key view inside it, so no keys were on screen. The window stays up
- Two stages had no room to lift the bottom card, so a keyboard at the bottom of the screen sat on that card. Both cards now slide up together and keep their size

**4.5.8**
- The second staged app was missing the signal that it is on the stage, so it kept drawing its own keyboard. That signal is delivered again
- A debug line on the stage says whether each app is staged, whether its keyboard views were removed, and whether SpringBoard actually has a keyboard to draw

**4.5.7**
- The staged app's own keyboard is removed from the card. The keyboard window is not part of the app's normal window list, so the previous hide never saw it, and UIKit put the keys back. Those views are now forced out of the card whenever they are laid out

**4.5.6**
- A staged app no longer draws its own keyboard. SpringBoard is forced to be the keyboard UI host, and the keys are SpringBoard's, full width, outside the card
- There is no fallback that puts the app's keyboard back inside the stage

**4.5.5**
- A staged app's keyboard is hosted in SpringBoard's keyboard window, full width, outside the card. The previous build fell back to the keyboard inside the app
- Both stages are told they are staged, so the second app hosts its keyboard the same way

**4.5.4**
- Hold a filled square in the right-edge notch to send that stage back to the app picker. An empty square does not. A short tap still opens or shows that half
- Scene updates that were still resizing a hosted app, and moving an app's view between cards, are gone so those paths cannot blank the stage
- A staged app uses SpringBoard's keyboard. If that keyboard never appears, the app draws its own keys at the bottom of the card

**4.5.3**
- The app in a stage is pinned to the card, so the bottom stage shows the whole app instead of a clipped full-screen scene
- Swipe inward from the right side of a staged app to return to the app picker

**4.5.2**
- Minimize slides a card away and leaves its app running. It no longer tears the app down
- Staged apps keep an opaque card, including Safari, instead of showing the wallpaper through the stage
- A stage is told its size once, so the bottom card does not flicker through a string of scene updates while it loads

**4.5.1**
- The right-edge notch shows two squares, top and bottom. An empty square starts a stage on that half, and a staged app fills its square

**4.5.0**
- A small notch on the right edge of the screen lists apps on the stage and recently staged apps, and tapping one puts it on a stage
- The notch stays available while the stage cards are closed

**4.4.5**
- Two stages still fill the two halves, with a few points of wallpaper around each card and rounded corners

**4.4.4**
- Two stages fill the screen: top card is the top half, bottom card is the bottom half, edge to edge, same size

**4.4.3**
- Every stage is one fixed size from the screen (top half and bottom half match). Opening a second stage, Split View, and the keyboard do not resize a card
- Scene resize transactions are not repeated when the card only moves

**4.4.2**
- Second stage is a real picker card (blur plus fallback fill), and the moved app is told its new size again so the card does not stay black
- Minimize button on the top left of each stage; minimizing one leaves the other as a normal stage

**4.4.1**
- + moves the existing stage card to the top half (app stays in that card) and opens a new picker stage on the bottom
- Drag a stage's grabber to swap which card is on the top half and which is on the bottom

**4.4.0**
- + pushes the current hosted app into the top stage and opens a fresh bottom stage (full picker, like first open)
- + only appears while an app is on the stage; no second picker on top / black top slot

**4.3.2**
- Top stack slot: force app picker (clear stale host layers that showed black)
- Thin inset gap around each stacked stage; bottom slot alone lifts for its keyboard

**4.3.1**
- Two stages: equal top/bottom halves of the display (not two small cards in the bottom half)
- Top slot shows the app picker until an app is loaded; + control stays above the grabber

**4.3.0**
- Stack stages: + control on the top-right of the card (overlay mode) opens a second stage above the first
- Each slot can host its own app; split view collapses back to one slot

**4.0.2**
- Staged app keyboard: merge arbiter frame with on-screen UIKeyboard; sync lift + scene geometry every time
- Bottom safe-area inset while the keyboard still overlaps the lifted card (Messenger-style layouts)
- Log when the card lifts for a hosted app keyboard

**4.0.1**
- Keyboard: card keeps overlay/split size and lifts above keys (picker and staged apps)
- Removed 4.0 card expansion that resized the stage and caused black gaps
- Staged app attach keeps blur until launch placeholder fades; re-applies lift if keys are up

**4.0.0**
- Ground-up engine pass: one app hosting path (SpringBoard SBAppViewController only)
- Staged-app keyboard: card expands full width to the display bottom (no layer steal, no display mask)
- Picker search: simple key-window handoff, no retry storm
- Pure layout module (DSStageLayout) for overlay, split and typing geometry
- Boot path unchanged: home screen wait, launch guard, no KeyboardArbiter dlopen
- Crash log scanning removed from the picker (less work at SpringBoard launch)

**3.0.0**
- Removed DSKeyboardHost; boot-safe delayed hooks; picker vs app key-window split
