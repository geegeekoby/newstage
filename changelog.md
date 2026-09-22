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
