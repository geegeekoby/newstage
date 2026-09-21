**3.0.0**
- Fresh rebuild of the SpringBoard engine for iOS 16.5.1 / NathanLR: hooks wait until the home screen exists
- Keyboard done the way this firmware actually works: never steal layers, never refuse the keyboard, never open KeyboardArbiter
- Picker search uses SpringBoard's own keyboard and lifts the card; a staged app keeps the card still and shows keys on the display below it
- Stage window is only key while the picker is up, so typing in Messenger (and search after an app) both work
- App dylib no longer lies about hosted keyboards; keyboard windows still see the real display size
- Same overlay, Split View, picker, grabber and inward-swipe-to-picker behaviour
