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
// captured on a 430x932pt device (iPhone 14 Pro Max, same as the target):
//
//   * the stage card is full width, flush with the bottom of the display and
//     its top edge sits at exactly half the screen height in every state;
//   * all four of its corners trace the same profile as the display mask, so
//     the radius is _displayCornerRadius rather than a hand-picked number;
//   * in Split View the app behind keeps the top half minus a ~3pt black gap;
//   * picker content is inset 10pt from each side of the card.

static const CGFloat kDSStageHeightRatio = 0.5;
static const CGFloat kDSSplitRatio = 0.5;
static const CGFloat kDSSplitDividerGap = 3.0;
static const CGFloat kDSFallbackDisplayCornerRadius = 55.0;
static const CGFloat kDSContentInset = 10.0;

// The hot corner that pulls the stage up, and the matching zone inside the
// stage that pushes it back down.
static const CGFloat kDSTriggerWidth = 112.0;
static const CGFloat kDSTriggerHeight = 28.0;

// Card that lifts out of the corner and follows the finger before the stage
// takes its resting shape.
static const CGFloat kDSPeekWidth = 168.0;
static const CGFloat kDSPeekHeight = 168.0;
static const CGFloat kDSPeekCornerRadius = 32.0;

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
