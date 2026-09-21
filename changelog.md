**4.0.0**
- Ground-up engine pass: one app hosting path (SpringBoard SBAppViewController only)
- Staged-app keyboard: card expands full width to the display bottom (no layer steal, no display mask)
- Picker search: simple key-window handoff, no retry storm
- Pure layout module (DSStageLayout) for overlay, split and typing geometry
- Boot path unchanged: home screen wait, launch guard, no KeyboardArbiter dlopen
- Crash log scanning removed from the picker (less work at SpringBoard launch)

**3.0.0**
- Removed DSKeyboardHost; boot-safe delayed hooks; picker vs app key-window split
