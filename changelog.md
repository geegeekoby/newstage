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
