#import <UIKit/UIKit.h>

// Per-process view of the stage, shared by every hook in this dylib.
//
// SpringBoard resizes our scene and records which app it is hosting; the geometry
// hooks then answer with the stage rectangle instead of the display rectangle so
// layout code that reaches for UIScreen keeps working.
@interface DSStageContext : NSObject

+ (instancetype)sharedContext;

// Whether this process is on the stage right now, answered without building
// anything or registering for anything. An app the stage launched has to know
// this inside its constructor; every other app can find out later.
+ (BOOL)processIsStagedNow;

// The real display, in points, derived from nativeBounds so it survives every
// hook in this file.
@property (nonatomic, readonly) CGRect deviceBounds;

// YES while this process is the app on the stage.
@property (nonatomic, readonly) BOOL staged;
// Stage rectangle in the app's own coordinates, origin always zero. Read from the
// scene as it is now, not from the last refresh: SpringBoard makes this window taller
// than the card the moment a keyboard goes up in it, and an answer from before that
// puts the keyboard back inside the card.
@property (nonatomic, readonly) CGRect stageBounds;
// Where this app's keyboard belongs, in the app's own window coordinates: the band
// SpringBoard opens below the card, starting at the card's bottom edge and as tall as
// the keyboard this app has raised. Null when there is no keyboard up, or when
// SpringBoard has not said how tall the card is.
//
// Nothing about this depends on the window having been made tall enough to hold the
// band. That is asked for, and it is better when it happens, but the keyboard is put
// here either way - which is the only way it can be certain never to be in the card.
@property (nonatomic, readonly) CGRect keyboardBand;

// Report the iPad idiom so apps reflow into the short, wide stage instead of
// showing a stretched phone layout.
@property (nonatomic, readonly) BOOL padMode;
// Quarter turns requested from SpringBoard: 0, 1 (right) or 3 (left).
@property (nonatomic, readonly) NSInteger quarterTurns;

// Called the first time this process becomes the app on the stage, which is when
// the geometry hooks are worth installing.
@property (nonatomic, copy) void (^stagedHandler)(void);

- (void)startObserving;
- (void)refresh;

@end
