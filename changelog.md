**4.5.30**
- Each staged app has its own SpringBoard keyboard, separate from the picker search field, still outside the card. Letters from that keyboard go only to the app that is typing. The app reports `app: loaded` as soon as it is on a card, and `app: is listening` once the message box can take those letters. Picker search is unchanged

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
