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
// scene as it is now rather than from the last refresh, so an app resized on the stage
// is never laid out to the size it had a moment ago.
@property (nonatomic, readonly) CGRect stageBounds;
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

// Set while deviceBounds is reading the real panel. Screen hooks must not
// answer that read with the card, or the phone size and the card size collapse
// into each other.
#ifdef __cplusplus
extern "C" {
#endif
BOOL DSIsReadingHardwareDisplay(void);
// The card changed size. Messages keeps its reply field in a separate input
// controller, so that view has to lay out again or it stays on the old bottom.
void DSRelayoutStagedMessageInput(void);
// Split closed and this process is the front app again. Views fitted to the
// card have to fill the phone, or the reply bar stays in the middle.
void DSRestoreAfterLeavingStage(void);
#ifdef __cplusplus
}
#endif
