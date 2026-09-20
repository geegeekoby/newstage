#import <UIKit/UIKit.h>

// Per-process view of the stage, shared by every hook in this dylib.
//
// SpringBoard resizes our scene and records which app it is hosting; the geometry
// hooks then answer with the stage rectangle instead of the display rectangle so
// layout code that reaches for UIScreen keeps working.
@interface DSStageContext : NSObject

+ (instancetype)sharedContext;

// The real display, in points, derived from nativeBounds so it survives every
// hook in this file.
@property (nonatomic, readonly) CGRect deviceBounds;

// YES while this process is the app on the stage.
@property (nonatomic, readonly) BOOL staged;
// Stage rectangle in the app's own coordinates, origin always zero.
@property (nonatomic, readonly) CGRect stageBounds;
// Report the iPad idiom so apps reflow into the short, wide stage instead of
// showing a stretched phone layout.
@property (nonatomic, readonly) BOOL padMode;
// Quarter turns requested from SpringBoard: 0, 1 (right) or 3 (left).
@property (nonatomic, readonly) NSInteger quarterTurns;

- (void)startObserving;
- (void)refresh;

@end
