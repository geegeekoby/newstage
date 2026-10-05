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

// Opens the stage without the gesture, from the button on the Misc page. Useful
// on its own, and it separates "the stage does not work" from "the pull is not
// being picked up" without needing a log.
#define kDSOpenStageNotification "com.recreated.dynamicstage.stage.open"

// Second hosted app. The geometry notification only carries one bundle hash, and
// two stages are allowed, so the other app is published here.
#define kDSStagePeerNotification "com.recreated.dynamicstage.geometry.peer"

// The staged app writes a packed status here so SpringBoard can show it.
// Low 32 bits are the bundle hash. Bit 32 is staged, bit 33 means a keyboard
// window was found, bits 40-47 are how many keyboard views were forced out.
#define kDSKeyboardDebugNotification "com.recreated.dynamicstage.keyboard.debug"

// A staged app asks SpringBoard to show the picker search keyboard. The low 32
// bits are the bundle hash. Bit 32 set means the keyboard should come up.
#define kDSKeyboardRequestNotification "com.recreated.dynamicstage.keyboard.request"

// SpringBoard tells Messages its keyboard view is actually on the screen.
// Low 32 bits are the bundle hash. Bit 32 set means the keys are up.
#define kDSKeyboardShownNotification "com.recreated.dynamicstage.keyboard.shown"

// Keystrokes from that keyboard, written by SpringBoard and applied in the app.
// /var/tmp is readable from a sandboxed app. Preferences is not.
#define kDSKeyboardInputPath @"/var/tmp/com.recreated.dynamicstage.keyboard.input.plist"
#define kDSKeyboardInputNotification "com.recreated.dynamicstage.keyboard.input"

// The staged app tells SpringBoard whether that letter changed the field.
// The app cannot append the shared log from inside its sandbox, so this is
// the line that shows up in the preferences log.
// Low 32 bits: bundle hash. Bit 32 changed, 33 had a field, 34 first
// responder, 35 window, 36 delete, 37 the process was not staged,
// 38 the process is listening for keys, 39 the in-app constructor ran.
// Bits 40-47: 0 none, 1 field, 2 text view, 3 other.
// Bit 48: UIKit was told the keyboard is remote. Bit 49: the dylib image
// mapped. Bit 50: a keyboard hook ran while the app was not staged.
// Bit 51: the remote-keyboard hooks were installed. Bits 52-55: which
// hook (1 window class, 2 unassociated scene, 3 clear scene, 4 skip
// hosted view, 6 input set, 8 legacy impl, 15 class missing).
// Bits 56-59: constructor reason (0 ok, 1 kill, 2 bundle, 3 excluded,
// 4 not a user app, 5 prefs off, 6 exception).
#define kDSKeyboardApplyNotification "com.recreated.dynamicstage.keyboard.apply"

// Rotating the app on the stage without rotating the device. Suffixed with
// .left, .right or .reset.
#define kDSRotateNotificationPrefix @"com.recreated.dynamicstage.rotate"

// Written by SpringBoard, read by the injected application dylib so it knows it
// is being hosted before its first frame.
#define kDSStageGeometryNotification "com.recreated.dynamicstage.geometry"

// Card size for the app named by the geometry notification, then the peer.
// Low 32 bits are the width in points, high 32 bits the height. A sandboxed
// app can read this when it cannot read the preferences plist.
#define kDSStageCardSizeNotification "com.recreated.dynamicstage.cardsize"
#define kDSStageCardSizePeerNotification "com.recreated.dynamicstage.cardsize.peer"
#define kDSStageCardPath @"/var/tmp/com.recreated.dynamicstage.card.plist"

// Written by SpringBoard, read by the injected application dylib: tells an
// application which geometry the stage wants it to use before its first frame.
#define kDSSharedStatePath @"/var/mobile/Library/Preferences/com.recreated.dynamicstage.state.plist"

// The same answer is also published as the notification's own 64-bit state, so an
// application can tell whether it is the one on the stage using nothing but the
// notify API. Reading the file above depends on the sandbox allowing it, and an
// app that cannot tell would install hooks it does not need.
#define kDSStageStateActiveBit (1ULL << 32)

// FNV-1a over the bundle identifier, which is what the low half of that state
// carries. A collision would only mean an app is handed stage geometry it did
// not ask for, and the file is consulted first wherever it can be read.
static inline uint32_t DSIdentifierHash(NSString *identifier) {
    if (identifier.length == 0) return 0;
    uint32_t hash = 2166136261u;
    const char *bytes = identifier.UTF8String;
    for (; bytes && *bytes; bytes++) {
        hash ^= (uint32_t)(unsigned char)*bytes;
        hash *= 16777619u;
    }
    return hash;
}

// SpringBoard counts its own launches here while the tweak is starting up and
// clears the count once it is safely up. Two launches that never got that far
// mean the tweak is implicated in a boot loop, and it stays out of the next one
// rather than leaving the device only usable in safe mode.
#define kDSLaunchGuardPath @"/var/mobile/Library/Preferences/com.recreated.dynamicstage.launchguard"
#define kDSLaunchGuardTmpPath @"/var/tmp/com.recreated.dynamicstage.launchguard"
// One failed full install disables the tweak on the next SpringBoard start.
// The count is only incremented when Stage hooks are about to be installed,
// never in %ctor, so a jailbreak that restarts SpringBoard twice while the
// UI is still coming up does not trip it.
#define kDSMaxUncleanLaunches 1

// Dropping this file disables every hook on the next respring. Documented in
// the README as the escape hatch if the tweak ever misbehaves on a new build.
#define kDSKillSwitchPath @"/var/mobile/.dynamicstage-disabled"

// SpringBoard writes what it did here and the Settings pane reads it back, which
// is the only way to see inside the tweak on a device that cannot hand over a
// crash log. Both processes run as mobile, so both can reach this.
#define kDSDiagnosticsPath @"/var/mobile/Library/Preferences/com.recreated.dynamicstage.log"
// Written at every SpringBoard start. Later lines from either process are kept
// only when the log still contains this id, so a respring does not keep the
// previous boot's keyboard notes.
#define kDSDiagnosticsSessionPath @"/var/mobile/Library/Preferences/com.recreated.dynamicstage.session"

// Stage keyboard snapshots (attach, keys up/down). Replaced on every SpringBoard start.
#define kDSKeyboardStageLogPath @"/var/mobile/Library/Preferences/com.recreated.dynamicstage.keyboard-stage.log"

// Beeper keyboard and quick-bar detail. Both SpringBoard and the Beeper
// process append it. The stage log is capped at a few hundred characters a
// line, so the window list and the bar's superview chain live here instead.
#define kDSBeeperDetailLogPath @"/var/tmp/com.recreated.dynamicstage.beeper-detail.log"

// Kept across resprings. postinst deletes it, so a crash from the build that
// was just replaced is not still sitting there after the next install.
#define kDSBuildVersionString "4.5.640"

// One line from the staged app, copied into the stage log. The app and
// SpringBoard do not share that log, so a blocked keyboard hide was invisible.
#define kDSKeyboardTraceNotification "com.recreated.dynamicstage.keyboard.trace"
#define kDSKeyboardTracePath @"/var/tmp/com.recreated.dynamicstage.keyboard-trace"
#define kDSCrashLogPath @"/var/mobile/Library/Preferences/com.recreated.dynamicstage.crash.log"

// Single stage at runtime. Legacy dual-stack helpers in SpringBoard remain compiled
// but are unreachable while this is 1 (no second card is ever created).

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
    DSStageStateSplit,      // retired; nothing enters this state
    DSStageStateMinimized,  // stage dismissed, stage app still alive
};

// Layout ---------------------------------------------------------------------
// Measured off the stock tweak's own 60fps walkthrough recordings, which were
// captured on a 430x932pt device (iPhone 14 Pro Max, same as the target). Every
// number below came out of a pixel trace of those frames:
//
//   * the stage is a floating card. The app behind stays full screen;
//   * the card's corners are concentric with the display mask;
//   * the app behind scales to 0.872 about the screen centre while the corner is
//     being pulled, over black, then springs back to full screen.

// Below this, what is on the bottom edge of the display is an accessory bar or a
// keyboard on its way out rather than a keyboard the card has to stay clear of.
static const CGFloat kDSKeyboardPresentHeight = 60.0;

// The card is never pushed closer than this to the top of the display, however tall
// the keyboard under it turns out to be.
static const CGFloat kDSStageKeyboardHeadroom = 20.0;

// How much of a staged app stays visible above its own keyboard. The app draws that
// keyboard inside the card, so the card has to be this much taller than the keys.
static const CGFloat kDSStageTypingHeadroom = 250.0;

static const CGFloat kDSSplitRatio = 0.5;
static const CGFloat kDSStageInset = 10.0;
// The inset alone left the lifted card sitting on the keys. This is the
// extra gap above the keyboard.
static const CGFloat kDSKeyboardLiftGap = 36.0;
static const CGFloat kDSStackSlotGap = 6.0;
static const CGFloat kDSStackCardInset = 5.0;
// Grab band outside the card, and the thicker band inside the edge that a
// finger can still catch. The inside band is what you actually hit.
static const CGFloat kDSStageOuterDragBand = 18.0;
// The grab band is only the edge of the card. 64pt reached into the app
// picker and stole its scroll.
static const CGFloat kDSStageRimGrabBand = 18.0;
static const NSInteger kDSMaxStackSlots = 2;
static const CGFloat kDSOffscreenCardGap = 12.0;
static const CGFloat kDSFallbackDisplayCornerRadius = 55.0;
static const CGFloat kDSHostShrinkScale = 0.872;

// The hot corner that pulls the stage up, and the matching zone inside the
// stage that pushes it back down.
static const CGFloat kDSTriggerWidth = 112.0;
static const CGFloat kDSTriggerHeight = 28.0;

// Card that lifts out of the corner and follows the finger before the stage
// takes its resting shape. It tracks the drag at roughly a fifth of the stage's
// size, growing as the finger travels.
static const CGFloat kDSPeekWidth = 160.0;
static const CGFloat kDSPeekHeight = 135.0;
static const CGFloat kDSPeekCornerRadius = 26.0;

// Spring used by every stage transition: ~0.42s response with a single small
// overshoot, which is what the recordings settle to.
static const CGFloat kDSSpringDamping = 0.82;
static const CGFloat kDSSpringResponse = 0.42;

// Picker metrics, all traced off the same frames. Content sits 27pt inside the
// card on both sides; the search field is 56pt tall with a 16pt radius, section
// headers occupy a 52pt band with the text centred in it, and the plates are
// 45pt tall with 10pt between them and the same 16pt radius as the field.
static const CGFloat kDSContentInset = 16.0;
static const CGFloat kDSSearchFieldTop = 28.0;
static const CGFloat kDSSearchFieldHeight = 40.0;
static const CGFloat kDSSearchFieldRadius = 14.0;
static const CGFloat kDSSearchGlyphInset = 12.0;
static const CGFloat kDSSectionHeaderHeight = 22.0;
static const CGFloat kDSCellHeight = 48.0;
static const CGFloat kDSCellRadius = 14.0;
static const CGFloat kDSCellGap = 8.0;
static const CGFloat kDSCellIconSide = 26.0;
static const CGFloat kDSCellIconInset = 10.0;
static const CGFloat kDSCellTitleGap = 10.0;
static const CGFloat kDSRecentChipWidth = 72.0;
static const CGFloat kDSRecentStripHeight = 76.0;

// Type sizes, derived from the ink height of the same frames.
static const CGFloat kDSTitleFontSize = 20.0;
static const CGFloat kDSHeaderFontSize = 15.0;
