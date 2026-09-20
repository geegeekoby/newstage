#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Identity -------------------------------------------------------------------

#define kDSPackageIdentifier @"com.recreated.dynamicstage"
#define kDSPreferenceDomain @"com.recreated.dynamicstage.prefs"
#define kDSRequester @"DynamicStage"

// Darwin notifications shared between the preference bundle, SpringBoard and
// the per-application dylib.
#define kDSPreferencesChangedNotification "com.recreated.dynamicstage.prefs.reload"
#define kDSAppInfoChangedNotification "com.recreated.dynamicstage.appinfo.reload"
#define kDSResetIntroNotification "com.recreated.dynamicstage.intro.reset"
#define kDSCloseStageNotification "com.recreated.dynamicstage.stage.close"

// Rotating the app on the stage without rotating the device. Suffixed with
// .left, .right or .reset.
#define kDSRotateNotificationPrefix @"com.recreated.dynamicstage.rotate"

// Written by SpringBoard, read by the injected application dylib so it knows it
// is being hosted before its first frame.
#define kDSStageGeometryNotification "com.recreated.dynamicstage.geometry"

// Written by SpringBoard, read by the injected application dylib: tells an
// application which geometry the stage wants it to use before its first frame.
#define kDSSharedStatePath @"/var/mobile/Library/Preferences/com.recreated.dynamicstage.state.plist"

// Dropping this file disables every hook on the next respring. Documented in
// the README as the escape hatch if the tweak ever misbehaves on a new build.
#define kDSKillSwitchPath @"/var/mobile/.dynamicstage-disabled"

// Preference keys ------------------------------------------------------------

#define kDSPrefEnabled @"enabled"
#define kDSPrefShowOpenAppIcon @"showOpenAppIcon"
#define kDSPrefDisableOnHomeScreen @"disableOnHomeScreen"
#define kDSPrefAppearance @"appearance"
#define kDSPrefUseModernGesture @"useModernGesture"
#define kDSPrefPinnedApplications @"pinnedApplications"
#define kDSPrefPinnedRows @"pinCount"
#define kDSPrefScale @"scale"
#define kDSPrefAutoKill @"autoKill"
#define kDSPrefIntroShown @"introShown"

// Per-application keys, stored under the app's bundle identifier.
#define kDSAppPrefDisabled @"disabled"
#define kDSAppPrefLaunchType @"type"
#define kDSAppPrefDisableLandscape @"disable_ipad_landscape"
#define kDSAppPrefBackgroundOnMinimize @"background_on_minimize"

typedef NS_ENUM(NSInteger, DSAppearance) {
    DSAppearanceLight = 0,
    DSAppearanceDark = 1,
    DSAppearanceAuto = 2,
};

typedef NS_ENUM(NSInteger, DSGestureMode) {
    DSGestureModePan = 0,     // legacy edge pan recogniser owned by the tweak
    DSGestureModeSystem = 1,  // rides the system home gesture stream
};

// "iPad" apps are told they run on a pad so they reflow instead of relaunching.
typedef NS_ENUM(NSInteger, DSLaunchType) {
    DSLaunchTypePad = 0,
    DSLaunchTypePhone = 1,
};

typedef NS_ENUM(NSInteger, DSAutoKill) {
    DSAutoKillOnClose = 0,
    DSAutoKillFiveMinutes = 1,
    DSAutoKillTenMinutes = 2,
    DSAutoKillNever = 3,
};

typedef NS_ENUM(NSInteger, DSStageState) {
    DSStageStateClosed = 0,
    DSStageStateTracking,   // finger down, stage following the drag
    DSStageStateOverlay,    // stage floating above an untouched full screen app
    DSStageStateSplit,      // host app resized to the top half
    DSStageStateMinimized,  // stage dismissed, stage app still alive
};

// Layout ---------------------------------------------------------------------
// Measured off the stock tweak's own 60fps walkthrough recordings, which were
// captured on a 430x932pt device (iPhone 14 Pro Max, same as the target). Every
// number below came out of a pixel trace of those frames:
//
//   * the stage card is full width and flush with the bottom of the display in
//     every state, so only its top edge moves;
//   * resting overlay top edge: 622/1218 video px -> 475.9pt, i.e. 0.5107 of the
//     display height, a touch lower than the Split View divider;
//   * Split View divider: a single black row at exactly half the display height,
//     with the stage starting 1pt under it;
//   * all four stage corners trace the same profile as the display mask (the
//     traced outline matches the display's own bottom corner within a pixel), so
//     the radius is _displayCornerRadius rather than a hand-picked number;
//   * the app behind scales to 0.872 about the screen centre while the corner is
//     being pulled, over black, then either springs back (overlay) or resizes
//     into the top half (split);
//   * picker content is inset 10pt from each side of the card.

static const CGFloat kDSOverlayTopRatio = 0.5107;
static const CGFloat kDSSplitRatio = 0.5;
static const CGFloat kDSSplitDividerGap = 1.0;
static const CGFloat kDSFallbackDisplayCornerRadius = 55.0;
static const CGFloat kDSContentInset = 10.0;
static const CGFloat kDSHostShrinkScale = 0.872;

// The hot corner that pulls the stage up, and the matching zone inside the
// stage that pushes it back down.
static const CGFloat kDSTriggerWidth = 112.0;
static const CGFloat kDSTriggerHeight = 28.0;

// Card that lifts out of the corner and follows the finger before the stage
// takes its resting shape.
static const CGFloat kDSPeekWidth = 200.0;
static const CGFloat kDSPeekHeight = 150.0;
static const CGFloat kDSPeekCornerRadius = 26.0;

// Spring used by every stage transition: ~0.42s response with a single small
// overshoot, which is what the recordings settle to.
static const CGFloat kDSSpringDamping = 0.82;
static const CGFloat kDSSpringResponse = 0.42;

// Picker metrics.
static const CGFloat kDSSearchFieldTop = 26.0;
static const CGFloat kDSSearchFieldHeight = 38.0;
static const CGFloat kDSSearchFieldRadius = 13.0;
static const CGFloat kDSSectionHeaderHeight = 26.0;
static const CGFloat kDSCellHeight = 38.0;
static const CGFloat kDSCellRadius = 12.0;
static const CGFloat kDSCellGap = 8.0;
static const CGFloat kDSCellIconSide = 26.0;
