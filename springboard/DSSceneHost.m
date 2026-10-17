#import "DSCameraArbiter.h"
#import "DSSceneHost.h"
#import "DSInCallStage.h"
#import "DSConstants.h"
#import "DSPreferences.h"
#import "DSDiagnostics.h"
#import "DSKeyboardVisibility.h"
#import "DSStageDebug.h"
#import "DSStageManager.h"
#import "DSStageContainerView.h"
#import "DSCrashLog.h"

#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <os/lock.h>
#import <pthread.h>

// Local declaration only. SpringBoard already has the class; linking
// AssertionServices is not required, and a normal message keeps ARC correct.
@interface DSRunningAssertion : NSObject
- (instancetype)initWithPID:(NSInteger)pid flags:(NSUInteger)flags reason:(NSUInteger)reason name:(NSString *)name withHandler:(id)handler;
- (instancetype)initWithBundleIdentifier:(NSString *)identifier flags:(NSUInteger)flags reason:(NSUInteger)reason name:(NSString *)name withHandler:(id)handler;
- (BOOL)valid;
- (void)invalidate;
@end

// Scene identifier -> geometry the stage insists on. Read from the FBScene hook
// on whatever thread SpringBoard happens to update settings on.
static NSMutableDictionary<NSString *, NSDictionary *> *DSSceneOverrides(void) {
    static NSMutableDictionary *overrides;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        overrides = [NSMutableDictionary dictionary];
    });
    return overrides;
}

// Every scene SpringBoard has told to update its settings, which in practice is
// every scene there is. Weak values: this is a way of finding a scene, never a
// reason for one to stay alive.
static NSMapTable<NSString *, FBScene *> *DSLiveScenes(void) {
    static NSMapTable *scenes;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        scenes = [NSMapTable strongToWeakObjectsMapTable];
    });
    return scenes;
}

// The app view controllers the stage made, so the hook that contains their asserts
// can tell them from SpringBoard's own. Weak: this is a way of recognising them,
// never a reason for one to stay alive.
static NSHashTable *DSOwnedAppViewControllers(void) {
    static NSHashTable *controllers;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        controllers = [NSHashTable weakObjectsHashTable];
    });
    return controllers;
}

static id DSIvar(id object, NSString *name) {
    if (!object || name.length == 0) return nil;
    Ivar ivar = class_getInstanceVariable([object class], name.UTF8String);
    if (!ivar) return nil;
    @try {
        return object_getIvar(object, ivar);
    } @catch (NSException *exception) {
        return nil;
    }
}

static BOOL DSHomeGestureActive = NO;
static CFAbsoluteTime DSHomeGestureQuietUntil = 0;
static NSString *DSHandedOffBundle = nil;
static CFAbsoluteTime DSHandedOffUntil = 0;

static NSInteger DSSystemPullDepth = 0;
// 4.5.659: the app the stage itself is activating after a home-transition
// hand-back, and until when. Its activation's own scene update is not
// refused by the "kept inside its card" path (see Tweak.xm).
static NSString *DSActivatingBundle = nil;
static CFAbsoluteTime DSActivatingUntil = 0;
// 4.5.716 blackout716: the app the stage just woke (the card-tap wake used by
// blackout696 / blackout699 / a tap or drag on the card), and until when.
static NSString *DSWake716Bundle = nil;
static CFAbsoluteTime DSWake716Until = 0;
// 4.5.665: SpringBoard's own transition is still finishing for a while after
// the home gesture ends, after the parked apps are handed back, and while /
// just after a corner pull adopted from the system gesture runs. A phone-sized
// update of a hosted scene inside that window is part of SpringBoard's
// transaction; completing it without applying it is the SIGTRAP.
static CFAbsoluteTime DSHomeGestureEndedAt = 0;
static CFAbsoluteTime DSHomeHandBackAt = 0;
static BOOL DSSystemEdgePullActive = NO;
static CFAbsoluteTime DSSystemEdgePullStartedAt = 0;
static CFAbsoluteTime DSSystemEdgePullEndedAt = 0;
// How many FBScene settings updates are on the stack. A presentation frame
// written from inside one waits on the update that is waiting on the frame.
static NSInteger DSSceneSettingsUpdateDepth = 0;

static BOOL DSAvoidSceneLifecycle(void) {
    if (DSHomeGestureActive || DSSystemPullDepth > 0) return YES;
    return CFAbsoluteTimeGetCurrent() < DSHomeGestureQuietUntil;
}

// Starting a transaction, or changing an app view's mode, while SpringBoard is
// already inside one of those is the SIGTRAP that drops SpringBoard into safe
// mode. @try does not catch it.
static BOOL DSSceneWriteWouldTrap(void) {
    return DSAvoidSceneLifecycle() || DSSceneSettingsUpdateDepth > 0;
}

// ---- 4.5.675 phonesize675 switches ------------------------------------------
// When the stage last switched a scene between card size and phone size. The
// app-view hook in Tweak.xm holds SpringBoard's own app-view updates for the
// staged app for a moment after it, the same as after a card drag (670).
static CFTimeInterval DSPhoneSize675ChangedAt = 0;

BOOL DSPhoneSize675ChangedRecently(double window) {
    return DSPhoneSize675ChangedAt > 0 && CACurrentMediaTime() - DSPhoneSize675ChangedAt < window;
}

static NSString *DSPhoneSize675Path(NSString *name) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *plain = [@"/var/mobile/" stringByAppendingString:name];
    if ([fm fileExistsAtPath:plain]) return plain;
    NSString *jb = [@"/var/jb/var/mobile/" stringByAppendingString:name];
    if ([fm fileExistsAtPath:jb]) return jb;
    return nil;
}

BOOL DSPhoneSize675Disabled(void) {
    static CFAbsoluteTime at = 0;
    static BOOL value = NO;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - at > 2.0 || now < at) {
        value = DSPhoneSize675Path(@".dynamicstage-phonesize675-off") != nil ||
                (DS796CoreOn() && DSPhoneSize675Path(@".dynamicstage-phonesize-off") != nil);   // 4.5.796 group file
        at = now;
    }
    return value;
}

// The allowlist file replaces the default list (Beeper). One bundle id per
// line; blank lines and lines starting with # are ignored. An empty file
// allows nothing.
static NSSet<NSString *> *DSPhoneSize675AllowlistSet(BOOL *fromFile) {
    static CFAbsoluteTime at = 0;
    static NSSet<NSString *> *value = nil;
    static BOOL valueFromFile = NO;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!value || now - at > 2.0 || now < at) {
        at = now;
        NSString *path = DSPhoneSize675Path(@".dynamicstage-phonesize675-apps");
        NSString *text = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] : nil;
        if (path) {
            NSMutableSet *set = [NSMutableSet set];
            for (NSString *raw in [text ?: @"" componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
                NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (line.length == 0 || [line hasPrefix:@"#"]) continue;
                [set addObject:line];
            }
            value = [set copy];
            valueFromFile = YES;
        } else {
            value = [NSSet setWithObject:@"com.beeper.chat.ios"];
            valueFromFile = NO;
        }
    }
    if (fromFile) *fromFile = valueFromFile;
    return value;
}

BOOL DSPhoneSize675Allowed(NSString *bundleIdentifier) {
    if (bundleIdentifier.length == 0) return NO;
    return [DSPhoneSize675AllowlistSet(NULL) containsObject:bundleIdentifier];
}

NSString *DSPhoneSize675AllowlistSummary(void) {
    BOOL fromFile = NO;
    NSSet *set = DSPhoneSize675AllowlistSet(&fromFile);
    NSArray *sorted = [[set allObjects] sortedArrayUsingSelector:@selector(compare:)];
    return [NSString stringWithFormat:@"%@ (%@)", sorted.count ? [sorted componentsJoinedByString:@","] : @"nobody",
            fromFile ? @"from .dynamicstage-phonesize675-apps" : @"default"];
}

// ---- 4.5.676 phonesize676 ----------------------------------------------------
static double DSPhoneSize676SessionAt = 0;

void DSPhoneSize676StartSession(double mediaTime) {
    DSPhoneSize676SessionAt = mediaTime > 0 ? mediaTime : CACurrentMediaTime();
}

double DSPhoneSize676MsAt(double mediaTime) {
    if (DSPhoneSize676SessionAt <= 0) return -1.0;
    return (mediaTime - DSPhoneSize676SessionAt) * 1000.0;
}

double DSPhoneSize676Ms(void) {
    return DSPhoneSize676MsAt(CACurrentMediaTime());
}

static BOOL DSPhoneSize676File(NSString *name, CFAbsoluteTime *at, BOOL *value) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - *at > 2.0 || now < *at) {
        DSPerfNoteFileStat();
        *value = DSPhoneSize675Path(name) != nil;
        *at = now;
    }
    return *value;
}

// 4.5.677: the focus hook is gone (see Tweak.xm). This file turns off the
// arbiter on=1 early switch too, leaving the 4.5.675 keyboard-note trigger
// plus the relayout nudge. Read on the main queue only.
BOOL DSPhoneSize677EarlyDisabled(void) {
    static CFAbsoluteTime at = 0;
    static BOOL value = NO;
    return DSPhoneSize676File(@".dynamicstage-phonesize677-early-off", &at, &value);
}

// ---- 4.5.678 phonesize678 ----------------------------------------------------
// A: the relayout nudge changes the scene's WIDTH (430 -> 428 -> 430), so the
//    app's own keyboard changes size and UIKit re-posts its keyboard frame.
//    Off: the 4.5.676 height nudge.
BOOL DSPhoneSize678WidthDisabled(void) {
    static CFAbsoluteTime at = 0;
    static BOOL value = NO;
    return DSPhoneSize676File(@".dynamicstage-phonesize678-width-off", &at, &value);
}

// B: grow before the keyboard exists, on a touch in the card's composer zone.
BOOL DSPhoneSize678PreGrowDisabled(void) {
    static CFAbsoluteTime at = 0;
    static BOOL value = NO;
    return DSPhoneSize676File(@".dynamicstage-phonesize678-pregrow-off", &at, &value);
}

// B variant: bottom-anchored right at touch-down (no tap-safe phase, no hold).
BOOL DSPhoneSize678AnchorAtDown(void) {
    static CFAbsoluteTime at = 0;
    static BOOL value = NO;
    return DSPhoneSize676File(@".dynamicstage-phonesize678-anchor-at-down", &at, &value);
}

// ---- 4.5.680 phonesize680: always full screen, the message bar never moves ----
BOOL DSPhoneSize680Off(void) {
    static CFAbsoluteTime at = 0;
    static BOOL value = NO;
    return DSPhoneSize676File(@".dynamicstage-phonesize680-off", &at, &value);
}

BOOL DSPhoneSize680NoAnim(void) {
    static CFAbsoluteTime at = 0;
    static BOOL value = NO;
    return DSPhoneSize676File(@".dynamicstage-phonesize680-noanim", &at, &value);
}

// ON unless the 680 off file or the 675 master off file is present.
BOOL DSPhoneSize680Enabled(void) {
    BOOL on = !DSPhoneSize680Off() && !DSPhoneSize675Disabled();
    static int logged = -1;
    if (logged != (int)on) {
        logged = (int)on;
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize680 build %s is %@", kDSBuildVersionString,
                                  on ? @"ON: allowlisted apps always full screen (430x931 scaled to the card), message bar kept in place, no scene writes on tap or keyboard"
                                     : (DSPhoneSize675Disabled() ? @"OFF (phonesize675 master off file)"
                                                                 : @"OFF (/var/mobile/.dynamicstage-phonesize680-off): exact 4.5.679 behaviour"));
    }
    return on;
}

// ---- 4.5.683 phonesize683: the app's own keyboard inside the card -------------
BOOL DSPhoneSize683Off(void) {
    static CFAbsoluteTime at = 0;
    static BOOL value = NO;
    return DSPhoneSize676File(@".dynamicstage-phonesize683-off", &at, &value);
}

// Test switch: keep SpringBoard's bottom-of-phone copy of the app's keys visible.
BOOL DSPhoneSize683KeepHost(void) {
    static CFAbsoluteTime at = 0;
    static BOOL value = NO;
    return DSPhoneSize676File(@".dynamicstage-phonesize683-keephost", &at, &value);
}

// 4.5.684: 683 is opt-in (the user reported it did not work).
BOOL DSPhoneSize683On(void) {
    static CFAbsoluteTime at = 0;
    static BOOL value = NO;
    return DSPhoneSize676File(@".dynamicstage-phonesize683-on", &at, &value);
}

BOOL DSPhoneSize683Enabled(void) {
    BOOL on = DSPhoneSize683On() && !DSPhoneSize683Off() && DSPhoneSize680Enabled();
    static int logged = -1;
    if (logged != (int)on) {
        logged = (int)on;
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize683 build %s is %@", kDSBuildVersionString,
                                  on ? @"ON (opt-in /var/mobile/.dynamicstage-phonesize683-on): allowlisted apps without the app dylib use their OWN keyboard inside the card (keys674 keeps UIKit's YES), "
                                       @"the card shows the bottom of the 430x931 scene (bar + keyboard), the stage leaves that keyboard alone, "
                                       @"SpringBoard's bottom-of-phone copy of the keys is hidden while it is up, no window moves on keyboard show/hide"
                                     : (!DSPhoneSize683On() ? @"OFF (opt-in since 4.5.684: /var/mobile/.dynamicstage-phonesize683-on)"
                                        : DSPhoneSize683Off() ? @"OFF (/var/mobile/.dynamicstage-phonesize683-off): 4.5.682 behaviour"
                                                              : @"OFF (phonesize680/675 off file): 4.5.682 rules for that file"));
    }
    return on;
}

// ---- 4.5.684 phonesize684: safe area = keyboard, the bar never moves ----------
// The always-full-screen 430x931 scene gets safe area {T, 0, K, 0}: K is the
// app's keyboard height inside the scene (931 - 586 = 345), so the app's bar
// sits at 931 - K with the keyboard down AND up (its keyboard top is the same
// y). T puts the app's top on the card's top edge. The card's window onto the
// scene is fixed at app y T..(931-K). keys674 answers NO, so the keys stay in
// SpringBoard's keyboard host at the bottom of the phone. Nothing on
// SpringBoard's side moves when the keyboard shows or hides.
BOOL DSPhoneSize684Off(void) {
    static CFAbsoluteTime at = 0;
    static BOOL value = NO;
    return DSPhoneSize676File(@".dynamicstage-phonesize684-off", &at, &value);
}

BOOL DSPhoneSize684Enabled(void) {
    BOOL on = !DSPhoneSize684Off() && DSPhoneSize680Enabled() && !DSPhoneSize683Enabled();
    static int logged = -1;
    if (logged != (int)on) {
        logged = (int)on;
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize684 build %s is %@", kDSBuildVersionString,
                                  on ? @"ON: allowlisted apps without the app dylib get safe area = keyboard in the 430x931 scene (bar fixed), "
                                       @"the card's window is fixed (no 680-682 chasing), keys at the phone bottom (keys674 NO)"
                                     : (DSPhoneSize684Off() ? @"OFF (/var/mobile/.dynamicstage-phonesize684-off): exact 4.5.682 behaviour"
                                        : DSPhoneSize683Enabled() ? @"OFF (683 opt-in file present: 683 mode instead)"
                                                                  : @"OFF (phonesize680/675 off file)"));
    }
    return on;
}

// /var/mobile/.dynamicstage-phonesize684-tune, key=value lines, re-read every
// 2 s. Applied at the next card open or 1 s after the keyboard goes down.
DSPhoneSize684Tune DSPhoneSize684CurrentTune(void) {
    static DSPhoneSize684Tune cached;
    static BOOL initialised = NO;
    if (initialised) return cached;   // 4.5.766: tune files removed; built-in constants, computed once
    initialised = YES;
    NSString *text = nil;
    DSPhoneSize684Tune t;
    t.bottom = 0.0;
    t.top = -1.0;
    t.shortMode = NO;
    // 4.5.705: the tune parse loop is gone (text is always nil since 4.5.702).
    cached = t;
    DSDiagnosticsRecordFormat(@"SpringBoard: phonesize684 tune %@ | in use: bottom=%@ top=%@ mode=%@ (applies at the next card open or 1 s after the keyboard goes down)",
                              text ? @"file /var/mobile/.dynamicstage-phonesize684-tune read" : @"no tune file (4.5.702: tune files are no longer read), built-in values",
                              t.bottom > 0.0 ? [NSString stringWithFormat:@"%.0f", t.bottom] : @"auto (learned, default 345)",
                              t.top >= 0.0 ? [NSString stringWithFormat:@"%.0f", t.top] : @"auto (card top)",
                              t.shortMode ? @"short" : @"safe");
    return t;
}

// ---- 4.5.686 phonesize685: the card shows the app's top bar and bottom bar ---
// Photo + log (uploads685, on 684): Beeper's main screen has a top bar that
// ends at app y ~127 (its buttons sit above, at the phone's own 59 pt top), so
// with the card showing app y 117..586 only the bar's bottom 10 pt shows; its
// bottom sheet (search field) is laid out above the 345 pt bottom inset and ends
// at ~588, flush with / 2 pt past the card bottom (586), under the corners.
// 686 keeps 684's scene exactly at the bottom (430x931, bottom inset 345, bar
// line 586: the chat bar and keys are unchanged) and only changes what the card
// shows: app y 59..600 (view..bar line + margin 14) at x0.847 instead of
// 117..586 at x0.977 (narrow black/white bars at the sides), with top inset 59.
// The first 4.5.685 (scene cut to 620, bottom inset 34) is only a tune now
// (slack=): it moved nothing on the main screen (the sheet sits on the safe
// bottom either way) and breaks the 684 identity for apps that pad by
// keyboard height minus the bottom inset.
// (old 685 notes follow)
// 684 worked in chats (bar still, keys at the phone bottom) but its 931 pt
// scene needed a 345 pt bottom safe inset, which Beeper's main-screen bottom bar
// grows into (a bar extends by the bottom inset), so it fell off the card.
// 685 keeps the same bar line (scene y 586 = keyboard top) and the same card
// window (app y 117..586) but ends the scene 34 pt below the bar: scene
// 430x620, safe area {117, 0, 34, 0}. Bar at rest: 620 - 34 = 586. Keys up:
// the keyboard (screen y 586) overlaps the window by 620 - 586 = 34 = the inset,
// so the bar stays at 586. Same zero-movement rule as 684, normal-size inset.
BOOL DSPhoneSize685Off(void) {
    static CFAbsoluteTime at = 0;
    static BOOL value = NO;
    return DSPhoneSize676File(@".dynamicstage-phonesize685-off", &at, &value);
}

static BOOL DSPhoneSize686On(void) {
    static CFAbsoluteTime at = 0;
    static BOOL value = NO;
    return DSPhoneSize676File(@".dynamicstage-phonesize686-on", &at, &value);
}

BOOL DSPhoneSize685Enabled(void) {
    // 4.5.687: 686's shrunken picture is opt-in (/var/mobile/.dynamicstage-phonesize686-on).
    BOOL on = !DSPhoneSize685Off() && DSPhoneSize686On() && DSPhoneSize684Enabled();
    static int logged = -1;
    if (logged != (int)on) {
        logged = (int)on;
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize685 build %s is %@", kDSBuildVersionString,
                                  on ? @"ON: 684 scene and bar line kept; the card shows app y view(59)..bar line+margin(14) at a smaller scale, top inset = view; "
                                       @"the app's top bar and bottom bar both on the card"
                                     : (DSPhoneSize685Off() ? @"OFF (/var/mobile/.dynamicstage-phonesize685-off)"
                                                            : (!DSPhoneSize686On() ? @"OFF (4.5.687: 686's picture is opt-in, /var/mobile/.dynamicstage-phonesize686-on)"
                                                                                   : @"OFF (684 is off)")));
    }
    return on;
}

// /var/mobile/.dynamicstage-phonesize685-tune, key=value lines, re-read every 2 s.
DSPhoneSize685Tune DSPhoneSize685CurrentTune(void) {
    static DSPhoneSize685Tune cached;
    static BOOL initialised = NO;
    if (initialised) return cached;   // 4.5.766: tune files removed; built-in constants, computed once
    initialised = YES;
    NSString *text = nil;
    DSPhoneSize685Tune t;
    t.view = -1.0;
    t.margin = 14.0;
    t.slack = -1.0;
    t.top = -1.0;
    t.keyTop = 0.0;
    // 4.5.705: the tune parse loop is gone (text is always nil since 4.5.702).
    cached = t;
    DSDiagnosticsRecordFormat(@"SpringBoard: phonesize685 tune %@ | in use: view=%@ margin=%.0f slack=%@ top=%@ keytop=%@ (applies at the next card open or 1.2 s after the keyboard goes down)",
                              text ? @"file /var/mobile/.dynamicstage-phonesize685-tune read" : @"no tune file (4.5.702: tune files are no longer read), built-in values",
                              t.view >= 0.0 ? [NSString stringWithFormat:@"%.0f", t.view] : @"auto (phone top inset, 59)", t.margin,
                              t.slack >= 0.0 ? [NSString stringWithFormat:@"%.0f (scene cut to bar line + slack)", t.slack] : @"off (684 scene)",
                              t.top >= 0.0 ? [NSString stringWithFormat:@"%.0f", t.top] : @"auto (= app y on the card top)",
                              t.keyTop > 0.0 ? [NSString stringWithFormat:@"%.0f", t.keyTop] : @"auto (learned keyboard top, default 586)");
    return t;
}

// ---- 4.5.687 phonesize687: top bar on the card at 684's fill -------------------
// 684: scene 430x931, bottom inset 345, bar line 586 = keyboard top, card shows
// app y 117..586 at x0.977. Beeper's main-screen top bar sits at app y 59..127
// (it does not follow the top inset), so it was above the card.
// The keys are SpringBoard's, at the phone bottom (screen 586..932), apart from
// the card (screen 5..463): the bar does not have to sit on the keyboard line,
// it only has to stay still. It stays still while the bottom inset B is at
// least the keyboard height (346, 301) and the keyboard overlap (931 - 586 =
// 345): both the inset rule and an app's own "keyboard height - inset" math
// then leave the bar where it rests. So 687 keeps 931 and x0.977 and raises the
// bar line: card shows app y 59..528 (view .. view + 458/0.977), bar rests at
// 528 - 8 = 520, B = 931 - 520 = 411, top inset 59. 411 >= 346: no movement.
BOOL DSPhoneSize687Off(void) {
    static CFAbsoluteTime at = 0;
    static BOOL value = NO;
    return DSPhoneSize676File(@".dynamicstage-phonesize687-off", &at, &value);
}

static BOOL DSPhoneSize687On(void) {
    static CFAbsoluteTime at = 0;
    static BOOL value = NO;
    return DSPhoneSize676File(@".dynamicstage-phonesize687-on", &at, &value);
}

BOOL DSPhoneSize687Enabled(void) {
    // 4.5.688: 687 (raised bar line) moved the chat bar off the card with the keys up; opt-in only.
    BOOL on = DSPhoneSize687On() && !DSPhoneSize687Off() && DSPhoneSize684Enabled() && !DSPhoneSize685Enabled();
    static int logged = -1;
    if (logged != (int)on) {
        logged = (int)on;
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize687 build %s is %@", kDSBuildVersionString,
                                  on ? @"ON: 684 scene 430x931 and fill x0.977 kept; card shows app y 59..528 (the app's top bar on the card top), "
                                       @"bar rests 8 pt above the card bottom, bottom inset 931 - bar (>= keyboard height, the bar never moves), top inset 59"
                                     : (!DSPhoneSize687On() ? @"OFF (4.5.688: opt-in only, /var/mobile/.dynamicstage-phonesize687-on)" :
                                        DSPhoneSize687Off() ? @"OFF (/var/mobile/.dynamicstage-phonesize687-off): exact 4.5.684 behaviour"
                                                            : (DSPhoneSize685Enabled() ? @"OFF (686 picture opted in with /var/mobile/.dynamicstage-phonesize686-on)"
                                                                                       : @"OFF (684 is off)")));
    }
    return on;
}

// /var/mobile/.dynamicstage-phonesize687-tune, key=value lines, re-read every 2 s.
DSPhoneSize687Tune DSPhoneSize687CurrentTune(void) {
    static DSPhoneSize687Tune cached;
    static BOOL initialised = NO;
    if (initialised) return cached;   // 4.5.766: tune files removed; built-in constants, computed once
    initialised = YES;
    NSString *text = nil;
    DSPhoneSize687Tune t;
    t.view = -1.0;
    t.margin = 8.0;
    t.top = -1.0;
    // 4.5.705: the tune parse loop is gone (text is always nil since 4.5.702).
    cached = t;
    DSDiagnosticsRecordFormat(@"SpringBoard: phonesize687 tune %@ | in use: view=%@ margin=%.0f top=%@ (applies at the next card open or 1.2 s after the keyboard goes down)",
                              text ? @"file /var/mobile/.dynamicstage-phonesize687-tune read" : @"no tune file (4.5.702: tune files are no longer read), built-in values",
                              t.view >= 0.0 ? [NSString stringWithFormat:@"%.0f", t.view] : @"auto (phone top inset, 59)", t.margin,
                              t.top >= 0.0 ? [NSString stringWithFormat:@"%.0f", t.top] : @"auto (= view)");
    return t;
}

// ---- 4.5.688 phonesize688 -------------------------------------------------------
// 687 showed the app puts its bar on the keyboard top (in its window) with the
// keys up, whatever the bottom inset: the card bottom must be the keyboard top as
// the app sees it and the bar must rest there (684). 688 keeps that and moves the
// main screen's top bar (laid out at 59..127, not following the 117 top inset)
// onto the card - see DSSceneHost.h for the modes.
BOOL DSPhoneSize688Off(void) {
    static CFAbsoluteTime at = 0;
    static BOOL value = NO;
    return DSPhoneSize676File(@".dynamicstage-phonesize688-off", &at, &value);
}

static BOOL DSPhoneSize689Off(void) {
    static CFAbsoluteTime at = 0;
    static BOOL value = NO;
    return DSPhoneSize676File(@".dynamicstage-phonesize689-off", &at, &value);
}

BOOL DSPhoneSize688Enabled(void) {
    // 4.5.689: .dynamicstage-phonesize689-off does the same as -688-off (exact 684,
    // which is also the default mode now).
    BOOL on = !DSPhoneSize688Off() && !DSPhoneSize689Off() && DSPhoneSize684Enabled() && !DSPhoneSize685Enabled() && !DSPhoneSize687Enabled();
    static int logged = -1;
    if (logged != (int)on) {
        logged = (int)on;
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize688 build %s is %@", kDSBuildVersionString,
                                  on ? @"ON: 684 chat geometry; default mode=684 (exact 684); opt-in modes in /var/mobile/.dynamicstage-phonesize688-tune: mode=offset|short|statusbar"
                                     : ((DSPhoneSize688Off() || DSPhoneSize689Off()) ? @"OFF (/var/mobile/.dynamicstage-phonesize688-off or -689-off): exact 4.5.684 behaviour"
                                                            : @"OFF (684 off, or 686/687 opted in)"));
    }
    return on;
}

static NSString *DSPhoneSize688ModeName(NSInteger mode) {
    switch (mode) {
        case DSPhoneSize688ModeOffset: return @"offset";
        case DSPhoneSize688ModeShort: return @"short";
        case DSPhoneSize688Mode684: return @"684";
        default: return @"statusbar";
    }
}

// /var/mobile/.dynamicstage-phonesize688-tune, key=value lines, re-read every 2 s.
DSPhoneSize688Tune DSPhoneSize688CurrentTune(void) {
    static DSPhoneSize688Tune cached;
    static BOOL initialised = NO;
    if (initialised) return cached;   // 4.5.766: tune files removed; built-in constants, computed once
    initialised = YES;
    NSString *text = nil;
    DSPhoneSize688Tune t;
    t.mode = DSPhoneSize688Mode684;   // 4.5.689: default is exact 684
    t.view = -1.0;
    t.offset = -1.0;
    t.shift = -1000.0;
    t.statusBar = -1.0;
    // 4.5.705: the tune parse loop is gone (text is always nil since 4.5.702).
    cached = t;
    DSDiagnosticsRecordFormat(@"SpringBoard: phonesize688 tune %@ | in use: mode=%@ view=%@ offset=%@ shift=%@ statusbar=%@ (applies at the next card open or 1.2 s after the keyboard goes down)",
                              text ? @"file /var/mobile/.dynamicstage-phonesize688-tune read" : @"no tune file (4.5.702: tune files are no longer read), built-in values",
                              DSPhoneSize688ModeName(t.mode),
                              t.view >= 0.0 ? [NSString stringWithFormat:@"%.0f", t.view] : @"auto (57)",
                              t.offset >= 0.0 ? [NSString stringWithFormat:@"%.0f", t.offset] : @"auto",
                              t.shift > -500.0 ? [NSString stringWithFormat:@"%.0f", t.shift] : @"auto (measured)",
                              t.statusBar >= 0.0 ? [NSString stringWithFormat:@"%.0f", t.statusBar] : @"auto (= top inset)");
    return t;
}

// The scene's default portrait status bar height (UIApplicationSceneSettings).
// 4.5.689: 4.5.688 crashed SpringBoard into safe mode on staging Beeper with
// this write on by default (mode=statusbar); it is opt-in now and fenced:
// main thread only, the selector's real signature checked (void, double, long
// long / double, long long), values 20..200 only, a crash latch (a file written
// before the first raise and removed 15 s later; if SpringBoard comes back with
// it still there, statusbar mode is switched off for good and logged), and
// nothing at all is touched unless a raise was asked for or is being undone.
static NSMutableDictionary<NSString *, NSNumber *> *DSPhoneSize688StatusBarOriginals(void) {
    static NSMutableDictionary *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ map = [NSMutableDictionary dictionary]; });
    return map;
}

static BOOL DSPhoneSize688HasStatusBarOriginal(NSString *identifier) {
    if (identifier.length == 0) return NO;
    NSMutableDictionary *map = DSPhoneSize688StatusBarOriginals();
    @synchronized(map) {
        return map[identifier] != nil;
    }
}

static NSString *const DSPhoneSize689TryingPath = @"/var/mobile/.dynamicstage-phonesize689-statusbar-trying";
static NSString *const DSPhoneSize689CrashedPath = @"/var/mobile/.dynamicstage-phonesize689-statusbar-crashed";

// YES when statusbar mode must not run: latched after a SpringBoard that died
// with a raise in flight. Main thread only.
static BOOL DSPhoneSize689StatusBarLatched(void) {
    static int checked = 0;
    static BOOL latched = NO;
    if (!checked) {
        checked = 1;
        @try {
            NSFileManager *fm = [NSFileManager defaultManager];
            if ([fm fileExistsAtPath:DSPhoneSize689TryingPath]) {
                [fm removeItemAtPath:DSPhoneSize689TryingPath error:NULL];
                [fm createFileAtPath:DSPhoneSize689CrashedPath contents:[NSData data] attributes:nil];
                DSDiagnosticsRecordFormat(@"SpringBoard: phonesize689 statusbar mode LATCHED OFF: SpringBoard went down while a status bar height raise was in flight "
                                          @"(%@ found). Delete %@ to allow it again.", DSPhoneSize689TryingPath, DSPhoneSize689CrashedPath);
            }
            latched = [fm fileExistsAtPath:DSPhoneSize689CrashedPath] ||
                      [fm fileExistsAtPath:@"/var/jb/var/mobile/.dynamicstage-phonesize689-statusbar-crashed"];
        } @catch (NSException *exception) {
            latched = YES;
        }
    }
    return latched;
}

static void DSPhoneSize689MarkStatusBarTrying(void) {
    static BOOL marked = NO;
    if (marked) return;
    marked = YES;
    @try {
        [[NSFileManager defaultManager] createFileAtPath:DSPhoneSize689TryingPath contents:[NSData data] attributes:nil];
    } @catch (NSException *exception) {
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            [[NSFileManager defaultManager] removeItemAtPath:DSPhoneSize689TryingPath error:NULL];
        } @catch (NSException *exception) {
        }
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize689 statusbar raise survived 15 s; crash latch cleared");
    });
}

static BOOL DSPhoneSize689SignatureIs(NSMethodSignature *sig, const char *ret, const char *arg0, const char *arg1) {
    if (!sig || sig.numberOfArguments != 4) return NO;
    const char *r = sig.methodReturnType;
    const char *a0 = [sig getArgumentTypeAtIndex:2];
    const char *a1 = [sig getArgumentTypeAtIndex:3];
    if (!r || !a0 || !a1) return NO;
    // Skip type qualifiers (r, n, N, o, O, R, V) before comparing.
    while (*r && strchr("rnNoORV", *r)) r++;
    while (*a0 && strchr("rnNoORV", *a0)) a0++;
    while (*a1 && strchr("rnNoORV", *a1)) a1++;
    BOOL longOk = (a1[0] == arg1[0]) || (arg1[0] == 'q' && (a1[0] == 'l' || a1[0] == 'q'));
    return r[0] == ret[0] && a0[0] == arg0[0] && longOk;
}

static void DSPhoneSize688ApplyStatusBar(FBSMutableSceneSettings *settings, NSString *identifier, CGFloat wanted) {
    if (!settings || identifier.length == 0 || !isfinite(wanted)) return;
    BOOL undo = wanted <= 0.0;
    // Nothing to do: never look at the settings object at all.
    if (undo && !DSPhoneSize688HasStatusBarOriginal(identifier)) return;
    if (![NSThread isMainThread]) return;
    if (!undo && (wanted < 20.0 || wanted > 200.0 || DSPhoneSize689StatusBarLatched())) return;
    static int loggedSupport = -1;
    SEL setter = NSSelectorFromString(@"setDefaultStatusBarHeight:forOrientation:");
    SEL getter = NSSelectorFromString(@"defaultStatusBarHeightForOrientation:");
    @try {
        BOOL ok = [settings respondsToSelector:setter] && [settings respondsToSelector:getter] &&
                  DSPhoneSize689SignatureIs([settings methodSignatureForSelector:setter], "v", "d", "q") &&
                  [settings methodSignatureForSelector:getter].numberOfArguments == 3;
        if (ok) {
            NSMethodSignature *g = [settings methodSignatureForSelector:getter];
            const char *r = g.methodReturnType;
            const char *a0 = [g getArgumentTypeAtIndex:2];
            ok = r && a0 && r[0] == 'd' && (a0[0] == 'q' || a0[0] == 'l');
        }
        if (!undo && loggedSupport != (int)ok) {
            loggedSupport = (int)ok;
            DSDiagnosticsRecordFormat(@"SpringBoard: phonesize689 status bar height %@", ok
                                      ? @"setting found with the expected signature: mode=statusbar can raise it"
                                      : @"setting NOT found / unexpected signature on this iOS: mode=statusbar does nothing (exact 684)");
        }
        if (!ok) return;
        NSMutableDictionary *originals = DSPhoneSize688StatusBarOriginals();
        NSNumber *original = nil;
        @synchronized(originals) {
            original = originals[identifier];
        }
        if (!undo) {
            double now = ((double (*)(id, SEL, long long))objc_msgSend)(settings, getter, (long long)UIInterfaceOrientationPortrait);
            if (!isfinite(now) || now < 0.0 || now > 200.0) return;
            if (!original) {
                @synchronized(originals) {
                    originals[identifier] = @(now);
                }
            }
            if (fabs(now - wanted) > 0.25) {
                DSPhoneSize689MarkStatusBarTrying();
                ((void (*)(id, SEL, double, long long))objc_msgSend)(settings, setter, (double)wanted, (long long)UIInterfaceOrientationPortrait);
            }
        } else if (original) {
            double back = original.doubleValue;
            if (isfinite(back) && back >= 0.0 && back <= 200.0) {
                ((void (*)(id, SEL, double, long long))objc_msgSend)(settings, setter, back, (long long)UIInterfaceOrientationPortrait);
            }
            @synchronized(originals) {
                [originals removeObjectForKey:identifier];
            }
        }
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize689 status bar height write threw %@", exception.reason ?: exception.name ?: @"?");
    }
}

// ---- 4.5.681 phonesize681 tune file ------------------------------------------
// /var/mobile/.dynamicstage-phonesize681-tune, key=value lines, re-read every 2 s.
static NSString *DSPS681CurveName(NSInteger curve) {
    switch (curve) {
        case DSPS681CurveKeyboard: return @"keyboard";
        case DSPS681CurveEaseInOut: return @"easeinout";
        case DSPS681CurveEaseOut: return @"easeout";
        case DSPS681CurveLinear: return @"linear";
        case DSPS681CurveSpring: return @"spring";
    }
    return @"?";
}

static DSPhoneSize681Tune DSPS681Defaults(void) {
    DSPhoneSize681Tune t;
    t.duration = 500.0;      // UIKit's keyboard spring really runs 0.5 s
    t.delay = 0.0;
    t.curve = DSPS681CurveKeyboard;
    t.springDamping = 1.0;
    t.springVelocity = 0.0;
    t.targetFinal = YES;
    t.offset = 0.0;
    t.hideDuration = 500.0;
    t.hideCurve = DSPS681CurveKeyboard;
    t.showInstant = YES;     // 4.5.682: Beeper moves its bar at once; so does the card's window
    return t;
}

static NSString *DSPS681Summary(DSPhoneSize681Tune t) {
    return [NSString stringWithFormat:@"show=%@ duration=%.0f delay=%+.0f curve=%@ spring_damping=%.2f spring_velocity=%.2f target=%@ offset=%+.1f hide_duration=%.0f hide_curve=%@ (duration/delay/curve/spring_* only apply with show=animate)",
            t.showInstant ? @"instant" : @"animate", t.duration, t.delay, DSPS681CurveName(t.curve), t.springDamping, t.springVelocity, t.targetFinal ? @"final" : @"stepwise",
            t.offset, t.hideDuration, DSPS681CurveName(t.hideCurve)];
}

DSPhoneSize681Tune DSPhoneSize681CurrentTune(void) {
    static DSPhoneSize681Tune cached;
    static BOOL initialised = NO;
    if (initialised) return cached;   // 4.5.766: tune files removed; built-in constants, computed once
    initialised = YES;
    NSString *text = nil;
    DSPhoneSize681Tune t = DSPS681Defaults();
    // 4.5.705: the tune parse loop is gone (text is always nil since 4.5.702).
    cached = t;
    DSDiagnosticsRecordFormat(@"SpringBoard: phonesize682 tune %@ | in use: %@",
                              text ? @"file /var/mobile/.dynamicstage-phonesize681-tune read" : @"no tune file (4.5.702: tune files are no longer read), built-in values",
                              DSPS681Summary(t));
    return t;
}

// C (opt-in): allowlisted apps stay phone-size the whole time they are staged.
// 4.5.680: always on while phonesize680 is on.
BOOL DSPhoneSize678Always(void) {
    static CFAbsoluteTime at = 0;
    static BOOL value = NO;
    return DSPhoneSize676File(@".dynamicstage-phonesize678-always", &at, &value) || DSPhoneSize680Enabled();
}

// ---- 4.5.679 phonesize679: scale -----------------------------------------------
// Default: the phone-size scene is as wide as the card and shown at scale 1.0
// (no shrink, no side crop). /var/mobile/.dynamicstage-phonesize679-scale
// (re-read every 2 s): "phone" = the 4.5.678 behaviour (phone width scaled to
// the card's width), or a scale 0.80-1.00 (scene width = card width / scale).
CGFloat DSPhoneSize679Scale(BOOL *phoneMode) {
    static CFAbsoluteTime at = 0;
    static CGFloat scale = 1.0;
    static BOOL phone = NO;
    static NSString *lastDesc = nil;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - at > 2.0 || now < at) {
        at = now;
        NSString *path = DSPhoneSize675Path(@".dynamicstage-phonesize679-scale");
        NSString *text = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] : nil;
        NSString *t = [[text ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
        if (t.length > 32) t = [t substringToIndex:32];
        BOOL p = NO;
        CGFloat s = 1.0;
        NSString *desc = nil;
        if (!path) {
            desc = @"default: scene as wide as the card, scale 1.0 (no /var/mobile/.dynamicstage-phonesize679-scale)";
        } else if ([t isEqualToString:@"phone"]) {
            p = YES;
            desc = @"file says \"phone\": 4.5.678 behaviour, phone-width scene scaled to the card's width";
        } else {
            double v = t.length ? t.doubleValue : NAN;
            if (isfinite(v) && v >= 0.80 && v <= 1.00) {
                s = (CGFloat)v;
                desc = [NSString stringWithFormat:@"file says scale %.3f: scene width = card width / %.3f", v, v];
            } else {
                desc = [NSString stringWithFormat:@"file content \"%@\" not understood (use phone or 0.80-1.00): default, scale 1.0", t];
            }
        }
        phone = p;
        scale = s;
        if (![desc isEqualToString:lastDesc]) {
            lastDesc = desc;
            DSDiagnosticsRecordFormat(@"SpringBoard: phonesize679 scale mode: %@", desc);
        }
    }
    if (phoneMode) *phoneMode = phone;
    return scale;
}

BOOL DSPhoneSize676NudgeDisabled(void) {
    static CFAbsoluteTime at = 0;
    static BOOL value = NO;
    return DSPhoneSize676File(@".dynamicstage-phonesize676-nudge-off", &at, &value);
}

BOOL DSPhoneSize676HoldEnabled(void) {
    static CFAbsoluteTime at = 0;
    static BOOL value = NO;
    return DSPhoneSize676File(@".dynamicstage-phonesize676-hold-on", &at, &value);
}

// Test knob: points added to the keyboard top that is put on the card's bottom
// edge (positive shows less of the app above the keys). Default 0.
CGFloat DSPhoneSize675PinOffset(void) {
    static CFAbsoluteTime at = 0;
    static CGFloat value = 0.0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - at > 2.0 || now < at) {
        at = now;
        NSString *path = DSPhoneSize675Path(@".dynamicstage-phonesize675-pinoffset");
        NSString *text = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] : nil;
        double v = text.length ? [[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] doubleValue] : 0.0;
        if (!isfinite(v)) v = 0.0;
        value = (CGFloat)MAX(-200.0, MIN(200.0, v));
    }
    return value;
}

static NSLock *DSSceneOverridesLock(void) {
    static NSLock *lock;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        lock = [[NSLock alloc] init];
    });
    return lock;
}

// ---- 4.5.657: switcher-free kill handling and system-transition state -------
// Updated under DSSceneOverridesLock wherever the overrides change.
static volatile NSInteger DSSceneOverrideCountValue = 0;

NSInteger DSSceneHostOverrideCount(void) {
    return DSSceneOverrideCountValue;
}

static os_unfair_lock DSDiedLock = OS_UNFAIR_LOCK_INIT;
static NSMutableOrderedSet<NSString *> *DSDiedBundles = nil;
static volatile NSInteger DSDiedCount = 0;

void DSSceneHostMarkBundleDied(NSString *bundleIdentifier) {
    if (bundleIdentifier.length == 0) return;
    NSString *bundle = [bundleIdentifier copy];
    os_unfair_lock_lock(&DSDiedLock);
    if (!DSDiedBundles) DSDiedBundles = [NSMutableOrderedSet orderedSet];
    [DSDiedBundles addObject:bundle];
    DSDiedCount = (NSInteger)DSDiedBundles.count;
    os_unfair_lock_unlock(&DSDiedLock);
    // Data only. The dead scene's stage geometry goes now, so the same app
    // relaunched full screen (switcher, Home Screen) never gets the card frame.
    [DSSceneOverridesLock() lock];
    NSMutableDictionary *overrides = DSSceneOverrides();
    if (overrides.count > 0) {
        for (NSString *identifier in [overrides.allKeys copy]) {
            if ([identifier rangeOfString:bundle].location != NSNotFound) [overrides removeObjectForKey:identifier];
        }
    }
    DSSceneOverrideCountValue = (NSInteger)overrides.count;
    [DSSceneOverridesLock() unlock];
}

BOOL DSSceneHostBundleDiedPending(NSString *bundleIdentifier) {
    if (DSDiedCount == 0 || bundleIdentifier.length == 0) return NO;
    os_unfair_lock_lock(&DSDiedLock);
    BOOL died = [DSDiedBundles containsObject:bundleIdentifier];
    os_unfair_lock_unlock(&DSDiedLock);
    return died;
}

BOOL DSSceneHostAnyDiedPending(void) {
    return DSDiedCount > 0;
}

NSArray<NSString *> *DSSceneHostTakeDiedBundles(void) {
    if (DSDiedCount == 0) return @[];
    os_unfair_lock_lock(&DSDiedLock);
    NSArray<NSString *> *bundles = DSDiedBundles.array.copy ?: @[];
    [DSDiedBundles removeAllObjects];
    DSDiedCount = 0;
    os_unfair_lock_unlock(&DSDiedLock);
    return bundles;
}

void DSSceneHostClearDied(NSString *bundleIdentifier) {
    if (DSDiedCount == 0 || bundleIdentifier.length == 0) return;
    os_unfair_lock_lock(&DSDiedLock);
    [DSDiedBundles removeObject:bundleIdentifier];
    DSDiedCount = (NSInteger)DSDiedBundles.count;
    os_unfair_lock_unlock(&DSDiedLock);
}

// Set when a home / switcher swipe begins with a stage app around, cleared
// when the stage is next used. Replaces asking the switcher controller.
static BOOL DSSystemOwnsScreen = NO;
static NSMutableArray<dispatch_block_t> *DSAfterTransitionBlocks = nil;

// Shared settings writer: prefers the block based API and falls back to the
// mutable-copy + transition context form used on older builds.
static void DSUpdateSceneSettings(FBScene *scene, void (^block)(FBSMutableSceneSettings *settings)) {
    if (!scene || !block || DSSceneWriteWouldTrap()) return;
    DSPerfCount(DSPerfCounterSceneWrites);
    if (DSPerfLogOn() && DSStageDragSettlingFast(0.0)) {
        static CFAbsoluteTime loggedAt = 0;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - loggedAt > 2.0 || now < loggedAt) {
            loggedAt = now;
            DSDiagnosticsRecordFormat(@"SpringBoard: perf697 scene settings write during a card drag (%@)",
                                      [scene respondsToSelector:@selector(identifier)] ? scene.identifier : @"?");
        }
    }
    @try {
        if ([scene respondsToSelector:@selector(updateSettingsWithBlock:)]) {
            [scene updateSettingsWithBlock:block];
            return;
        }
        FBSSceneSettings *current = [scene respondsToSelector:@selector(settings)] ? scene.settings : nil;
        if (![current respondsToSelector:@selector(mutableCopy)]) return;
        FBSMutableSceneSettings *settings = [current mutableCopy];
        block(settings);

        Class contextClass = objc_getClass("FBSSceneTransitionContext");
        id context = contextClass ? [[contextClass alloc] init] : nil;
        if ([scene respondsToSelector:@selector(updateSettings:withTransitionContext:completion:)]) {
            [scene updateSettings:settings withTransitionContext:context completion:nil];
        }
    } @catch (NSException *exception) {
    }
}

// FBSSystemService lives in FrontBoardServices and is not linked here, so the
// singleton is fetched dynamically.
static id DSSystemService(void) {
    Class serviceClass = objc_getClass("FBSSystemService");
    if (!serviceClass) return nil;
    SEL selector = @selector(sharedService);
    if (![serviceClass respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(serviceClass, selector);
}

// The scene view clears clipsToBounds whenever it lays out, so the app stays a
// square past the card's continuous corner. Marking the view and reapplying at
// the end of its own layout is what keeps the curve.
static const void *DSRoundInfoKey = &DSRoundInfoKey;
static const void *DSRoundHookKey = &DSRoundHookKey;
static const void *DSPresentationKey = &DSPresentationKey;
static const void *DSContainingKey = &DSContainingKey;
static const void *DSCardHostKey = &DSCardHostKey;

@interface DSSceneHost (RealKb814)
- (void)layoutHostView;
@end
static __weak DSSceneHost *DSRK814Host = nil;
static CGRect DSRK814AppKeys;
static CGRect DSRK814MgrKeys;

static void DSRK814Log(NSString *key, NSString *line) {
    static NSMutableDictionary<NSString *, NSString *> *last = nil;
    if (!last) last = [NSMutableDictionary dictionary];
    if (!key || !line || [last[key] isEqualToString:line]) return;
    if (last.count > 40) [last removeAllObjects];
    last[key] = line;
    DSDiagnosticsRecordFormat(@"SpringBoard: realkb814 %@", line);
}

static void DSRK814Publish(uint32_t value, NSString *why) {
    static int token = NOTIFY_TOKEN_INVALID;
    static uint64_t last = UINT64_MAX;
    if (token == NOTIFY_TOKEN_INVALID) notify_register_check(kDSRealKb814PhoneNotify, &token);
    if (token == NOTIFY_TOKEN_INVALID || last == value) return;
    last = value;
    notify_set_state(token, value);
    notify_post(kDSRealKb814PhoneNotify);
    DSRK814Log(@"publish", [NSString stringWithFormat:@"told Messages %@ (%@)", value ? @"phone-size + real keyboard (unstaged hooks)" : @"staged again (stand-in path)", why ?: @"?"]);
}

// notifyd keeps the state across a respring: a still-running Messages must
// not stay unstaged for a SpringBoard that has no phone-size scene.
__attribute__((constructor)) static void DSRK814Boot(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ DSRK814Publish(0, @"SpringBoard started"); });
}

static void DSRK814EnsureRelay(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static int token = NOTIFY_TOKEN_INVALID;
        notify_register_dispatch(kDSRealKb814KbNotify, &token, dispatch_get_main_queue(), ^(int t) {
            uint64_t state = 0;
            notify_get_state(t, &state);
            CGRect keys = CGRectZero;
            if (state) {
                CGFloat y = (CGFloat)(state >> 32) / 2.0, h = (CGFloat)(state & 0xffffffffULL) / 2.0;
                CGFloat w = CGRectGetWidth(UIScreen.mainScreen.bounds);
                if (h > 1.0 && w > 100.0) keys = CGRectMake(0.0, y, w, h);
            }
            DSRK814AppKeys = keys;
            DSRK814Log(@"appkeys", [NSString stringWithFormat:@"Messages keyboard (relayed) %@", CGRectIsEmpty(keys) ? @"gone" : NSStringFromCGRect(keys)]);
            DSSceneHost *host = DSRK814Host;
            if (host) [host layoutHostView];
        });
    });
}

void DSRealKb814ManagerNote(CGRect frame, NSString *source) {
    if (![source isKindOfClass:NSString.class] || ![source isEqualToString:@"com.apple.MobileSMS"]) return;
    DSSceneHost *host = DSRK814Host;
    if (!host) return;
    DSRK814MgrKeys = frame;
    DSRK814Log(@"mgrkeys", [NSString stringWithFormat:@"stage keyboard note from Messages %@", CGRectIsEmpty(frame) ? @"gone" : NSStringFromCGRect(frame)]);
    [host layoutHostView];
}


// 4.5.710 bisect step 1 (beeper707 alone on 4.5.706): every 707 drawing change,
// including the change-only round / chrome writes that 4.5.707 ran with no
// switch, sits behind /var/mobile/.dynamicstage-beeper707-off and its crash
// latch. Marked "trying" at first use (main thread, once).
static BOOL DSBeeper710WritesOn(void) {
    if (!DSFeature699On("beeper707")) return NO;
    static BOOL marked = NO;
    if (!marked) {
        marked = YES;
        DSFeature699MarkTrying("beeper707");
    }
    return YES;
}

static void DSApplyRoundInfo(UIView *view) {
    NSDictionary *info = objc_getAssociatedObject(view, DSRoundInfoKey);
    if (!info) return;
    CGFloat radius = [info[@"r"] doubleValue];
    if (radius < 1.0) return;
    CACornerMask corners = (CACornerMask)[info[@"c"] unsignedIntegerValue];
    CALayer *layer = view.layer;
    // 4.5.710: the 707 change-only writes are part of beeper707 (off file +
    // crash latch); switched off = exactly the 4.5.706 writes.
    if (!DSBeeper710WritesOn()) {
        view.clipsToBounds = YES;
        layer.masksToBounds = YES;
        layer.cornerRadius = radius;
        if (@available(iOS 13.0, *)) {
            layer.cornerCurve = kCACornerCurveContinuous;
            layer.maskedCorners = corners;
        }
        return;
    }
    // 4.5.707: change-only (the scene re-lays out many times a second while an
    // app like Beeper scrolls or types).
    if (!layer.masksToBounds) {
        view.clipsToBounds = YES;
        layer.masksToBounds = YES;
    }
    if (fabs(layer.cornerRadius - radius) > 0.01) layer.cornerRadius = radius;
    if (@available(iOS 13.0, *)) {
        if (![layer.cornerCurve isEqualToString:kCACornerCurveContinuous]) layer.cornerCurve = kCACornerCurveContinuous;
        if (layer.maskedCorners != corners) layer.maskedCorners = corners;
    }
}

// 4.5.707 beeper707: drop the rounded clips this tweak put inside a phone-size
// host. The card's content view already clips with the same continuous corner;
// a second (and third) rounded masksToBounds under the host's non-uniform
// squash is an extra offscreen pass per frame and is never seen.
static NSInteger DSBeeper707Flatten(UIView *view, NSInteger depth) {
    if (!view || depth > 14) return 0;
    NSInteger count = 0;
    if (objc_getAssociatedObject(view, DSRoundInfoKey)) {
        objc_setAssociatedObject(view, DSRoundInfoKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (view.layer.cornerRadius > 0.0) view.layer.cornerRadius = 0.0;
        count += 1;
    }
    for (UIView *subview in view.subviews) count += DSBeeper707Flatten(subview, depth + 1);
    return count;
}

static BOOL DSClassImplementsSelector(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *list = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(list[index]) == sel) {
            found = YES;
            break;
        }
    }
    free(list);
    return found;
}

static BOOL DSViewIsScenePresentation(UIView *view) {
    if (![view isKindOfClass:UIView.class]) return NO;
    NSString *name = NSStringFromClass(object_getClass(view));
    return [name rangeOfString:@"ScenePresentation"].location != NSNotFound;
}

static UIView *DSCardHostForView(UIView *view) {
    UIView *host = view.superview;
    while (host && !objc_getAssociatedObject(host, DSCardHostKey)) host = host.superview;
    return host;
}

static NSHashTable *DSHiddenStrayPresentations(void) {
    static NSHashTable *views;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        views = [NSHashTable weakObjectsHashTable];
    });
    return views;
}

static void DSRestoreStrayPresentations(void) {
    for (UIView *view in DSHiddenStrayPresentations().allObjects) {
        view.hidden = NO;
        view.alpha = 1.0;
        view.userInteractionEnabled = YES;
    }
    [DSHiddenStrayPresentations() removeAllObjects];
}

static void DSHideStrayPresentation(UIView *view) {
    if (!view) return;
    view.hidden = YES;
    view.alpha = 0.0;
    view.userInteractionEnabled = NO;
    [DSHiddenStrayPresentations() addObject:view];
}

static void DSClearSceneChrome(UIView *view) {
    CALayer *layer = view.layer;
    if (!DSBeeper710WritesOn()) {   // 4.5.710: off = the 4.5.706 writes
        view.backgroundColor = UIColor.clearColor;
        view.opaque = NO;
        layer.backgroundColor = UIColor.clearColor.CGColor;
        view.clipsToBounds = YES;
        layer.masksToBounds = YES;
        return;
    }
    // 4.5.707: this runs after every layout of every scene presentation; only
    // write what differs (each write dirties the layer for the next commit).
    if (layer.backgroundColor && CGColorGetAlpha(layer.backgroundColor) > 0.0) {
        view.backgroundColor = UIColor.clearColor;
        layer.backgroundColor = UIColor.clearColor.CGColor;
    }
    if (view.opaque) view.opaque = NO;
    if (!layer.masksToBounds) {
        view.clipsToBounds = YES;
        layer.masksToBounds = YES;
    }
}

static void DSContainScenePresentation(UIView *view) {
    if (!view || !objc_getAssociatedObject(view, DSPresentationKey)) return;
    if (DSSceneSettingsUpdateDepth > 0) return;
    // Corner only. setFrame: on a scene presentation starts another scene
    // update, and the one already running is the conversation push.
    DSClearSceneChrome(view);
    DSApplyRoundInfo(view);
}

static void DSAfterHostedLayout(id view) {
    if (!DSBeeper710WritesOn()) {   // 4.5.710: off = the 4.5.706 double apply
        DSApplyRoundInfo(view);
        DSContainScenePresentation(view);
        return;
    }
    // 4.5.707: one apply. DSContainScenePresentation already ends in
    // DSApplyRoundInfo, so a presentation was rounded twice per layout.
    if (objc_getAssociatedObject(view, DSPresentationKey) && DSSceneSettingsUpdateDepth <= 0) {
        DSContainScenePresentation(view);
    } else {
        DSApplyRoundInfo(view);
    }
}

static void DSInstallRoundHook(Class cls) {
    if (!cls || objc_getAssociatedObject(cls, DSRoundHookKey)) return;
    SEL sel = @selector(layoutSubviews);
    if (DSClassImplementsSelector(cls, sel)) {
        Method method = class_getInstanceMethod(cls, sel);
        IMP original = method_getImplementation(method);
        id block = ^(id self) {
            ((void (*)(id, SEL))original)(self, sel);
            DSAfterHostedLayout(self);
        };
        method_setImplementation(method, imp_implementationWithBlock(block));
    } else {
        Class hooked = cls;
        id block = ^(id self) {
            struct objc_super sup;
            sup.receiver = self;
            sup.super_class = class_getSuperclass(hooked);
            ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, sel);
            DSAfterHostedLayout(self);
        };
        class_addMethod(cls, sel, imp_implementationWithBlock(block), "v@:");
    }
    objc_setAssociatedObject(cls, DSRoundHookKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// 4.5.705 perf705: the same round info is not re-allocated on every host layout.
static BOOL DSRoundInfoAlready(UIView *view, CGFloat radius, CACornerMask corners) {
    if (!DSPerf705On()) return NO;
    NSDictionary *info = objc_getAssociatedObject(view, DSRoundInfoKey);
    if (!info) return NO;
    return fabs([info[@"r"] doubleValue] - radius) < 0.01 && (CACornerMask)[info[@"c"] unsignedIntegerValue] == corners;
}

static void DSMarkPresentationsUnder(UIView *view, CGFloat radius, CACornerMask corners, NSInteger depth) {
    if (!view || depth > 14) return;
    if (DSViewIsScenePresentation(view)) {
        objc_setAssociatedObject(view, DSPresentationKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (radius > 1.0 && !DSRoundInfoAlready(view, radius, corners)) {
            objc_setAssociatedObject(view, DSRoundInfoKey,
                                     @{ @"r" : @(radius), @"c" : @(corners) },
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        DSInstallRoundHook(object_getClass(view));
        DSContainScenePresentation(view);
    }
    for (UIView *subview in view.subviews) {
        DSMarkPresentationsUnder(subview, radius, corners, depth + 1);
    }
}

static BOOL DSViewIsMediaSurface(UIView *view) {
    if (![view isKindOfClass:UIView.class]) return NO;
    NSString *name = NSStringFromClass(object_getClass(view));
    return [name rangeOfString:@"AVPlayer"].location != NSNotFound ||
           [name rangeOfString:@"AVSample"].location != NSNotFound ||
           [name rangeOfString:@"WKComposit"].location != NSNotFound ||
           [name rangeOfString:@"WKContent"].location != NSNotFound ||
           [name rangeOfString:@"WKWeb"].location != NSNotFound ||
           [name rangeOfString:@"WebKit"].location != NSNotFound ||
           [name rangeOfString:@"PictureInPicture"].location != NSNotFound ||
           [name rangeOfString:@"PGHosted"].location != NSNotFound;
}

static void DSMarkRounded(UIView *view, CGFloat radius, CACornerMask corners) {
    if (!view || radius < 1.0 || DSViewIsMediaSurface(view)) return;
    if (!DSRoundInfoAlready(view, radius, corners)) {
        objc_setAssociatedObject(view, DSRoundInfoKey,
                                 @{ @"r" : @(radius), @"c" : @(corners) },
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    DSInstallRoundHook(object_getClass(view));
    DSApplyRoundInfo(view);
}

static BOOL DSGeometryValueOK(CGFloat v, CGFloat lo, CGFloat hi) {
    return isfinite(v) && v >= lo && v <= hi;
}

static void DSApplyGeometry(FBSMutableSceneSettings *settings, CGRect frame, UIEdgeInsets insets) {
    if (!settings) return;
    // 4.5.689: only sane values reach FrontBoard (finite, positive size, origin
    // within a few screens, insets 0..2000); a bad field is skipped, not written.
    BOOL frameOK = DSGeometryValueOK(frame.origin.x, -2000.0, 4000.0) && DSGeometryValueOK(frame.origin.y, -2000.0, 4000.0) &&
                   DSGeometryValueOK(frame.size.width, 1.0, 4000.0) && DSGeometryValueOK(frame.size.height, 1.0, 4000.0);
    BOOL insetsOK = DSGeometryValueOK(insets.top, 0.0, 2000.0) && DSGeometryValueOK(insets.left, 0.0, 2000.0) &&
                    DSGeometryValueOK(insets.bottom, 0.0, 2000.0) && DSGeometryValueOK(insets.right, 0.0, 2000.0);
    @try {
        if (frameOK && [settings respondsToSelector:@selector(setFrame:)]) settings.frame = frame;
        if (insetsOK && [settings respondsToSelector:@selector(setSafeAreaInsetsPortrait:)]) {
            settings.safeAreaInsetsPortrait = insets;
        }
        if ([settings respondsToSelector:@selector(setInterfaceOrientation:)]) {
            settings.interfaceOrientation = UIInterfaceOrientationPortrait;
        }
    } @catch (NSException *exception) {
    }
}

// ---- 4.5.690 phonesize690: Beeper's top bar recreated on top of the card ----
// 689 = 684 geometry (card shows app y 117..586 at x0.977), which the user wants
// kept byte for byte. Beeper's top bar sits at app y 59..127, above the card.
// 690 adds, in SpringBoard only, a strip view at the card top holding a
// _UIPortalView of the card's own host view (the same live pixels, the way the
// 4.5.673 camera mirrors Apple's top bar), clipped to app y 59..127 and drawn at
// the same x0.977 over the first ~66 pt of the card. Nothing is written to the
// app's scene; the host view, the keyboard path and keys674 are untouched.
// Touches (tune touch=): forward (default) turns on the portal's own hit testing
// (CAPortalLayer allowsHitTesting) so the window server can route a tap on the
// strip through the portal to the app's real top bar; if it does not, the strip
// (a filled SpringBoard view) keeps the touch, so it never lands on the chat
// under the strip; every touch SpringBoard gets there is logged. block: the
// strip always keeps touches (buttons drawn, not tappable). pass: picture
// only, touches go to whatever is under the strip.
// Crash latch like 689: a file is written before the first strip of a
// SpringBoard run and removed 15 s later; found at the next run = strip off for
// good (/var/mobile/.dynamicstage-phonesize690-crashed, delete to allow again).
// ---- 4.5.691 phonesize691: content below the recreated top bar ----------------
// 690's strip covers card y 0..~67 = app y ~118..186 of the real content. 691
// raises ONLY the top safe-area inset of the 684 scene to the strip's bottom
// edge in app coordinates (118 -> 186 by default), through the same validated
// 684 geometry write (keys down, card at rest) that already writes {118,0,345,0}.
// Frame 430x931, bottom inset 345, bar line 586, keys674, the card mapping and
// the x0.977 fill are unchanged: the bar's position comes from the keyboard top
// (keys up) or the bottom inset (keys down), never from the top inset. Views
// that respect the safe area (scroll views with automatic insets, safe-area
// padding) then start below the strip; Beeper's top bar ignores the top inset
// (it stayed at 59..127 with 118), so it does not move and the strip still fits.
// Tune /var/mobile/.dynamicstage-phonesize691-tune: top_inset=auto|off|N
// (auto = strip bottom: 684 auto top + place_y/fit + strip_height), plus the 690
// strip keys (strip_top, strip_height, place_y, on, touch, strip=slim|full),
// which override /var/mobile/.dynamicstage-phonesize690-tune.
// Off: /var/mobile/.dynamicstage-phonesize691-off = exact 4.5.690 (the 691 tune
// file is ignored, top inset back to 684 auto).
// Crash latch: -phonesize691-trying before the first raised-inset write of a
// SpringBoard run, removed 15 s later; found at the next run -> -crashed, off.
// ---- 4.5.694 phonesize694: the real Beeper top bar, card squashed vertically ----
// The user rejected the copied (fake) bar of 690-693: "remove it show the original
// just resize it", and approved a non-uniform stretch. 694 (default) shows the
// real app from app y 59 (the top of Beeper's own top bar) to the bar line 586
// (527 pt) in the 458 pt card: x scale = card width / 430 (0.977, full width as
// 684), y scale = 458 / 527 (0.869). The bottom (app y 586) stays exactly on the
// card bottom, so the chat bar and keyboard behave as in 684. Scene and keyboard
// geometry are 684's: 430x931, safe area {118,0,345,0} (691's 186 raise is off),
// keys674 NO. Only the host view's transform/centre on the card change (a
// mapping, no scene write). The copied strip (690), the 692 patch and the 693
// cog copy are not made (they come back with mode=691 or the 694 off file).
// Touches: the scene is shown through the host view's layer transform; the
// window server maps touches into the app through the inverse of that whole
// (affine) transform, uniform or not, as it already did for 684's x0.977.
// Tune /var/mobile/.dynamicstage-phonesize694-tune: mode=squash|691, view_top=
// (59), sy= (vertical scale override). Off: /var/mobile/.dynamicstage-
// phonesize694-off = exact 4.5.691. Crash latch: -phonesize694-trying/-crashed.
typedef struct {
    BOOL squash;      // mode=squash (default) / 691
    CGFloat viewTop;  // app y on the card's top edge (59)
    CGFloat sy;       // < 0 = auto (card height / (bar line - view_top))
} DSPhoneSize694Tune;

static BOOL DSPhoneSize694Off(void) {
    static CFAbsoluteTime at = 0;
    static BOOL value = NO;
    return DSPhoneSize676File(@".dynamicstage-phonesize694-off", &at, &value);
}

static DSPhoneSize694Tune DSPhoneSize694CurrentTune(void) {
    static DSPhoneSize694Tune cached;
    static BOOL initialised = NO;
    if (initialised) return cached;   // 4.5.766: tune files removed; built-in constants, computed once
    initialised = YES;
    NSString *text = nil;
    DSPhoneSize694Tune t;
    t.squash = YES;
    t.viewTop = 59.0;
    t.sy = -1.0;
    // 4.5.705: the tune parse loop is gone (text is always nil since 4.5.702).
    cached = t;
    DSDiagnosticsRecordFormat(@"SpringBoard: phonesize694 tune %@ | in use: mode=%@ view_top=%.0f sy=%@",
                              text ? @"file /var/mobile/.dynamicstage-phonesize694-tune read" : @"no tune file (4.5.702: tune files are no longer read), built-in values",
                              t.squash ? @"squash" : @"691", t.viewTop, t.sy < 0.0 ? @"auto" : [NSString stringWithFormat:@"%.4f", t.sy]);
    return t;
}

static NSString *const DSPhoneSize694TryingPath = @"/var/mobile/.dynamicstage-phonesize694-trying";
static NSString *const DSPhoneSize694CrashedPath = @"/var/mobile/.dynamicstage-phonesize694-crashed";

static BOOL DSPhoneSize694Latched(void) {
    static int checked = 0;
    static BOOL latched = NO;
    if (!checked) {
        checked = 1;
        @try {
            NSFileManager *fm = [NSFileManager defaultManager];
            if ([fm fileExistsAtPath:DSPhoneSize694TryingPath]) {
                [fm removeItemAtPath:DSPhoneSize694TryingPath error:NULL];
                [fm createFileAtPath:DSPhoneSize694CrashedPath contents:[NSData data] attributes:nil];
                DSDiagnosticsRecordFormat(@"SpringBoard: phonesize694 squash LATCHED OFF (back to 691): SpringBoard went down within 15 s of the first squash "
                                          @"(%@ found). Delete %@ to allow it again.", DSPhoneSize694TryingPath, DSPhoneSize694CrashedPath);
            }
            latched = [fm fileExistsAtPath:DSPhoneSize694CrashedPath] ||
                      [fm fileExistsAtPath:@"/var/jb/var/mobile/.dynamicstage-phonesize694-crashed"];
        } @catch (NSException *exception) {
            latched = YES;
        }
    }
    return latched;
}

static void DSPhoneSize694MarkTrying(void) {
    static BOOL marked = NO;
    if (marked) return;
    marked = YES;
    @try {
        [[NSFileManager defaultManager] createFileAtPath:DSPhoneSize694TryingPath contents:[NSData data] attributes:nil];
    } @catch (NSException *exception) {
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            [[NSFileManager defaultManager] removeItemAtPath:DSPhoneSize694TryingPath error:NULL];
        } @catch (NSException *exception) {
        }
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize694 squash survived 15 s; crash latch cleared");
    });
}

// 694 on: squash instead of the 690-693 layers.
static BOOL DSPhoneSize694Squash(void) {
    if (DSPhoneSize694Off()) return NO;
    if (!DSPhoneSize694CurrentTune().squash) return NO;
    return !DSPhoneSize694Latched();
}

// ---- 4.5.698 phonesize698: Beeper a little bigger on the card -----------------
// User on 697: "make the bottom quickbar in beeper a little bigger as its really
// small or even just make everything a little bit bigger". 694 shows app y 59..586
// (527 pt) in the 458 pt card at x0.9767 / y0.8691. The 586 bar line must stay on
// the card bottom (keyboard / chat bar, 684), and Beeper's top bar is fixed at app
// y 59..127 (it follows the status bar, not the inset), so the only way to make
// the picture bigger with one live (touchable) view is to show a little less:
// a few pt of the top bar's empty top band and a few pt at each side.
// The user: if it can't be bigger while everything still fits, don't change it.
// It can't (any gain cuts something), so the DEFAULT IS 697's PICTURE (view_top
// 59, side_crop 0 -> "tune gives 697's picture", nothing applied). Opt-in only:
// e.g. view_top=72 + side_crop=5 -> x1.0000 / y0.8911 (~2.5% bigger, crops app y
// 59..72 and 5 pt each side); zoom= multiplies 697's x and y scale (crops more of
// the top bar: zoom=1.10 shows app y ~107..586).
// Mapping only (host view transform/centre in layoutHostView, same branch as 694),
// no scene write, no new hook. Only when 694 is actually squashing.
// Tune /var/mobile/.dynamicstage-phonesize698-tune (key=value, re-read every 2 s):
//   view_top=59..200 (59), side_crop=0..40 (0), zoom=off|1.0..1.4 (off),
//   sx=auto|0.9..1.4, sy=auto|0.5..1.4, x_shift=-40..40 (0; + shows more of the left).
// Off: /var/mobile/.dynamicstage-phonesize698-off = exact 4.5.697.
// Crash latch: -phonesize698-trying (15 s after the first use) / -phonesize698-crashed.
typedef struct {
    CGFloat viewTop;   // app y on the card top
    CGFloat sideCrop;  // app pt cut off each side
    CGFloat zoom;      // <= 0 = off; else multiplies 697's sx and sy
    CGFloat sx;        // <= 0 = auto
    CGFloat sy;        // <= 0 = auto
    CGFloat xShift;    // app pt, + = picture moves right (more of the left side)
} DSPhoneSize698Tune;

static BOOL DSPhoneSize698Off(void) {
    static CFAbsoluteTime at = 0;
    static BOOL value = NO;
    return DSPhoneSize676File(@".dynamicstage-phonesize698-off", &at, &value);
}

static DSPhoneSize698Tune DSPhoneSize698CurrentTune(void) {
    static DSPhoneSize698Tune cached;
    static BOOL initialised = NO;
    if (initialised) return cached;   // 4.5.766: tune files removed; built-in constants, computed once
    initialised = YES;
    NSString *text = nil;
    DSPhoneSize698Tune t;
    t.viewTop = 59.0;   // 4.5.698 default = 697's picture (opt-in only, see above)
    t.sideCrop = 0.0;
    t.zoom = -1.0;
    t.sx = -1.0;
    t.sy = -1.0;
    t.xShift = 0.0;
    // 4.5.705: the tune parse loop is gone (text is always nil since 4.5.702).
    cached = t;
    DSDiagnosticsRecordFormat(@"SpringBoard: phonesize698 tune %@ | in use: view_top=%.0f side_crop=%.1f zoom=%@ sx=%@ sy=%@ x_shift=%.0f",
                              text ? @"file /var/mobile/.dynamicstage-phonesize698-tune read" : @"no tune file (4.5.702: tune files are no longer read), built-in values",
                              t.viewTop, t.sideCrop,
                              t.zoom > 0.0 ? [NSString stringWithFormat:@"%.3f", t.zoom] : @"off",
                              t.sx > 0.0 ? [NSString stringWithFormat:@"%.4f", t.sx] : @"auto",
                              t.sy > 0.0 ? [NSString stringWithFormat:@"%.4f", t.sy] : @"auto", t.xShift);
    return t;
}

static NSString *const DSPhoneSize698TryingPath = @"/var/mobile/.dynamicstage-phonesize698-trying";
static NSString *const DSPhoneSize698CrashedPath = @"/var/mobile/.dynamicstage-phonesize698-crashed";

static BOOL DSPhoneSize698Latched(void) {
    static int checked = 0;
    static BOOL latched = NO;
    if (!checked) {
        checked = 1;
        @try {
            NSFileManager *fm = [NSFileManager defaultManager];
            if ([fm fileExistsAtPath:DSPhoneSize698TryingPath]) {
                [fm removeItemAtPath:DSPhoneSize698TryingPath error:NULL];
                [fm createFileAtPath:DSPhoneSize698CrashedPath contents:[NSData data] attributes:nil];
                DSDiagnosticsRecordFormat(@"SpringBoard: phonesize698 bigger picture LATCHED OFF (back to 697): SpringBoard went down within 15 s of the first use "
                                          @"(%@ found). Delete %@ to allow it again.", DSPhoneSize698TryingPath, DSPhoneSize698CrashedPath);
            }
            latched = [fm fileExistsAtPath:DSPhoneSize698CrashedPath] ||
                      [fm fileExistsAtPath:@"/var/jb/var/mobile/.dynamicstage-phonesize698-crashed"];
        } @catch (NSException *exception) {
            latched = YES;
        }
    }
    return latched;
}

static void DSPhoneSize698MarkTrying(void) {
    static BOOL marked = NO;
    if (marked) return;
    marked = YES;
    @try {
        [[NSFileManager defaultManager] createFileAtPath:DSPhoneSize698TryingPath contents:[NSData data] attributes:nil];
    } @catch (NSException *exception) {
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            [[NSFileManager defaultManager] removeItemAtPath:DSPhoneSize698TryingPath error:NULL];
        } @catch (NSException *exception) {
        }
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize698 bigger picture survived 15 s; crash latch cleared");
    });
}

// ---- 4.5.695 phonesize695 -----------------------------------------------------
// A 684-mode phone-size card keeps its 430x931 scene and its safe area while it
// is minimised or off screen, so restore needs no resize and no relayout (693
// log: every minimise/restore shrank Beeper to 420x458 {0,0,0,0} and grew it
// back ~320 ms after the card was visible again). No new writes: the shrink is
// just not asked for. Off file /var/mobile/.dynamicstage-phonesize695-off =
// exact 694. Crash latch: -phonesize695-trying / -phonesize695-crashed.
static BOOL DSPhoneSize695Off(void) {
    static CFAbsoluteTime at = 0;
    static BOOL value = NO;
    return DSPhoneSize676File(@".dynamicstage-phonesize695-off", &at, &value);
}

static NSString *const DSPhoneSize695TryingPath = @"/var/mobile/.dynamicstage-phonesize695-trying";
static NSString *const DSPhoneSize695CrashedPath = @"/var/mobile/.dynamicstage-phonesize695-crashed";

static BOOL DSPhoneSize695Latched(void) {
    static int checked = 0;
    static BOOL latched = NO;
    if (!checked) {
        checked = 1;
        @try {
            NSFileManager *fm = [NSFileManager defaultManager];
            // 4.5.701 rearm701: this latch tripped once, on 4.5.697 at 14:36:28
            // NZDT (Blackoutagain): that SIGTRAP was the SBAppViewController
            // settings handler (a Live update of a backgrounded scene), which
            // 4.5.699 crash699 now holds - not the 695 keep. With it latched,
            // every minimise shrinks Beeper to 420x458 and every restore grows
            // it back (Beeper bar log: "phonesize675 OFF (keyboard down) ...
            // back to card size"). Cleared once (marker file); the latch itself
            // works as before if the keep is ever followed by a crash again.
            // Off: /var/mobile/.dynamicstage-rearm701-off.
            if (![fm fileExistsAtPath:DSPhoneSize695TryingPath] && [fm fileExistsAtPath:DSPhoneSize695CrashedPath] &&
                ![fm fileExistsAtPath:@"/var/mobile/.dynamicstage-rearm701-done"] &&
                ![fm fileExistsAtPath:@"/var/mobile/.dynamicstage-rearm701-off"] &&
                ![fm fileExistsAtPath:@"/var/jb/var/mobile/.dynamicstage-rearm701-off"]) {
                [fm createFileAtPath:@"/var/mobile/.dynamicstage-rearm701-done" contents:[NSData data] attributes:nil];
                [fm removeItemAtPath:DSPhoneSize695CrashedPath error:NULL];
                DSDiagnosticsRecord(@"SpringBoard: rearm701 phonesize695 keep-while-minimised allowed again once (its latch came from the 4.5.697 app-view trap that crash699 holds now); "
                                    @"the latch still trips if SpringBoard goes down within 15 s of a keep");
            }
            if ([fm fileExistsAtPath:DSPhoneSize695TryingPath]) {
                [fm removeItemAtPath:DSPhoneSize695TryingPath error:NULL];
                [fm createFileAtPath:DSPhoneSize695CrashedPath contents:[NSData data] attributes:nil];
                DSDiagnosticsRecordFormat(@"SpringBoard: phonesize695 keep-while-minimised LATCHED OFF (back to 694): SpringBoard went down within 15 s of the first keep "
                                          @"(%@ found). Delete %@ to allow it again.", DSPhoneSize695TryingPath, DSPhoneSize695CrashedPath);
            }
            latched = [fm fileExistsAtPath:DSPhoneSize695CrashedPath] ||
                      [fm fileExistsAtPath:@"/var/jb/var/mobile/.dynamicstage-phonesize695-crashed"];
        } @catch (NSException *exception) {
            latched = YES;
        }
    }
    return latched;
}

static void DSPhoneSize695MarkTrying(void) {
    static BOOL marked = NO;
    if (marked) return;
    marked = YES;
    @try {
        [[NSFileManager defaultManager] createFileAtPath:DSPhoneSize695TryingPath contents:[NSData data] attributes:nil];
    } @catch (NSException *exception) {
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            [[NSFileManager defaultManager] removeItemAtPath:DSPhoneSize695TryingPath error:NULL];
        } @catch (NSException *exception) {
        }
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize695 keep-while-minimised survived 15 s; crash latch cleared");
    });
}

static BOOL DSPhoneSize695Enabled(void) {
    if (DSPhoneSize695Off()) return NO;
    return !DSPhoneSize695Latched();
}

// ---- 4.5.696 phonesize696 -----------------------------------------------------
// Three fixes, each with its own off file and crash latch:
//   0 blackout: no Live app-view update while the phone is locked (the "out from
//     underneath us" exception that left the card black after unlock), and a
//     watchdog that wakes / reattaches a visible card that is backgrounded,
//     detached or hidden.
//   1 keys: SpringBoard's systemAnimation deactivation (0x20) is cleared on a
//     visible phone-size card's scene (as camera658 does for camera apps), so
//     the app is already active at the first tap.
//   2 fit: a phone-size card in the lower slot rises exactly onto the keys (no
//     28 pt gap, constant 586), and a stale stored resting frame no longer sends
//     it to the top slot after typing.
// Off: /var/mobile/.dynamicstage-phonesize696-<blackout|keys|fit>-off.
static NSString *DSPS696Name(NSInteger fix) {
    if (fix == 0) return @"blackout";
    if (fix == 1) return @"keys";
    return @"fit";
}

static BOOL DSPS696OffFile(NSInteger fix) {
    static CFAbsoluteTime at[3] = {0, 0, 0};
    static BOOL value[3] = {NO, NO, NO};
    NSInteger i = MAX(0, MIN(2, fix));
    return DSPhoneSize676File([NSString stringWithFormat:@".dynamicstage-phonesize696-%@-off", DSPS696Name(i)], &at[i], &value[i]);
}

static NSString *DSPS696LatchPath(NSInteger fix, NSString *kind) {
    return [NSString stringWithFormat:@"/var/mobile/.dynamicstage-phonesize696-%@-%@", DSPS696Name(fix), kind];
}

static BOOL DSPS696Latched(NSInteger fix) {
    static int checked[3] = {0, 0, 0};
    static BOOL latched[3] = {NO, NO, NO};
    NSInteger i = MAX(0, MIN(2, fix));
    if (!checked[i]) {
        checked[i] = 1;
        @try {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *trying = DSPS696LatchPath(i, @"trying");
            NSString *crashed = DSPS696LatchPath(i, @"crashed");
            if ([fm fileExistsAtPath:trying]) {
                [fm removeItemAtPath:trying error:NULL];
                [fm createFileAtPath:crashed contents:[NSData data] attributes:nil];
                DSDiagnosticsRecordFormat(@"SpringBoard: phonesize696 %@ LATCHED OFF (back to 695): SpringBoard went down within 15 s of its first use "
                                          @"(%@ found). Delete %@ to allow it again.", DSPS696Name(i), trying, crashed);
            }
            latched[i] = [fm fileExistsAtPath:crashed] ||
                         [fm fileExistsAtPath:[@"/var/jb" stringByAppendingString:crashed]];
        } @catch (NSException *exception) {
            latched[i] = YES;
        }
    }
    return latched[i];
}

void DSPS696MarkTrying(NSInteger fix) {
    static BOOL marked[3] = {NO, NO, NO};
    NSInteger i = MAX(0, MIN(2, fix));
    if (marked[i]) return;
    marked[i] = YES;
    NSString *trying = DSPS696LatchPath(i, @"trying");
    @try {
        [[NSFileManager defaultManager] createFileAtPath:trying contents:[NSData data] attributes:nil];
    } @catch (NSException *exception) {
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            [[NSFileManager defaultManager] removeItemAtPath:trying error:NULL];
        } @catch (NSException *exception) {
        }
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize696 %@ survived 15 s; crash latch cleared", DSPS696Name(i));
    });
}

BOOL DSPS696Enabled(NSInteger fix) {
    if (DSPS696OffFile(fix)) return NO;
    return !DSPS696Latched(fix);
}

BOOL DSPS696DeviceLocked(void) {
    @try {
        Class cls = objc_getClass("SBLockScreenManager");
        id manager = [cls respondsToSelector:@selector(sharedInstance)] ? [cls performSelector:@selector(sharedInstance)] : nil;
        if ([manager respondsToSelector:@selector(isUILocked)]) {
            return ((BOOL (*)(id, SEL))objc_msgSend)(manager, @selector(isUILocked));
        }
    } @catch (NSException *exception) {
    }
    return NO;
}

// Scene identifiers of visible phone-size (684) cards (fix 1). Guarded by the
// scene-overrides lock, read from applyOverridesToSettings.
static NSMutableSet<NSString *> *DSPS696KeysScenes(void) {
    static NSMutableSet<NSString *> *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSMutableSet set];
    });
    return set;
}

static BOOL DSPS696IsKeysScene(NSString *identifier) {
    if (identifier.length == 0) return NO;
    [DSSceneOverridesLock() lock];
    BOOL yes = [DSPS696KeysScenes() containsObject:identifier];
    [DSSceneOverridesLock() unlock];
    return yes;
}

typedef struct {
    NSInteger mode;   // 0 off, 1 auto, 2 fixed
    CGFloat value;    // fixed top inset
} DSPhoneSize691Tune;

static BOOL DSPhoneSize691Off(void) {
    static CFAbsoluteTime at = 0;
    static BOOL value = NO;
    return DSPhoneSize676File(@".dynamicstage-phonesize691-off", &at, &value);
}

static DSPhoneSize691Tune DSPhoneSize691CurrentTune(void) {
    static DSPhoneSize691Tune cached;
    static BOOL initialised = NO;
    if (initialised) return cached;   // 4.5.766: tune files removed; built-in constants, computed once
    initialised = YES;
    NSString *text = nil;
    DSPhoneSize691Tune t;
    t.mode = 1;
    t.value = 0.0;
    NSString *note = @"top_inset not set (auto)";
    // 4.5.705: the tune parse loop is gone (text is always nil since 4.5.702).
    cached = t;
    DSDiagnosticsRecordFormat(@"SpringBoard: phonesize691 tune %@: %@ | in use: top_inset=%@",
                              text ? @"file /var/mobile/.dynamicstage-phonesize691-tune read" : @"no tune file (4.5.702: tune files are no longer read), built-in values", note,
                              t.mode == 0 ? @"off" : (t.mode == 1 ? @"auto (strip bottom)" : [NSString stringWithFormat:@"%.0f", t.value]));
    return t;
}

static NSString *const DSPhoneSize691TryingPath = @"/var/mobile/.dynamicstage-phonesize691-trying";
static NSString *const DSPhoneSize691CrashedPath = @"/var/mobile/.dynamicstage-phonesize691-crashed";

static BOOL DSPhoneSize691Latched(void) {
    static int checked = 0;
    static BOOL latched = NO;
    if (!checked) {
        checked = 1;
        @try {
            NSFileManager *fm = [NSFileManager defaultManager];
            if ([fm fileExistsAtPath:DSPhoneSize691TryingPath]) {
                [fm removeItemAtPath:DSPhoneSize691TryingPath error:NULL];
                [fm createFileAtPath:DSPhoneSize691CrashedPath contents:[NSData data] attributes:nil];
                DSDiagnosticsRecordFormat(@"SpringBoard: phonesize691 raised top inset LATCHED OFF: SpringBoard went down within 15 s of the first raised-inset write "
                                          @"(%@ found). Delete %@ to allow it again.", DSPhoneSize691TryingPath, DSPhoneSize691CrashedPath);
            }
            latched = [fm fileExistsAtPath:DSPhoneSize691CrashedPath] ||
                      [fm fileExistsAtPath:@"/var/jb/var/mobile/.dynamicstage-phonesize691-crashed"];
        } @catch (NSException *exception) {
            latched = YES;
        }
    }
    return latched;
}

static void DSPhoneSize691MarkTrying(void) {
    static BOOL marked = NO;
    if (marked) return;
    marked = YES;
    @try {
        [[NSFileManager defaultManager] createFileAtPath:DSPhoneSize691TryingPath contents:[NSData data] attributes:nil];
    } @catch (NSException *exception) {
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            [[NSFileManager defaultManager] removeItemAtPath:DSPhoneSize691TryingPath error:NULL];
        } @catch (NSException *exception) {
        }
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize691 raised top inset survived 15 s; crash latch cleared");
    });
}

typedef struct {
    BOOL on;
    CGFloat stripTop;     // app y where the strip starts (59)
    CGFloat stripHeight;  // app pt (68)
    CGFloat placeY;       // card y of the strip's top (0)
    NSInteger touch;      // 0 forward, 1 block, 2 pass
} DSPhoneSize690Tune;

static BOOL DSPhoneSize690Off(void) {
    static CFAbsoluteTime at = 0;
    static BOOL value = NO;
    return DSPhoneSize676File(@".dynamicstage-phonesize690-off", &at, &value);
}

static NSString *DSPhoneSize690TouchName(NSInteger touch) {
    return touch == 1 ? @"block" : (touch == 2 ? @"pass" : @"forward");
}

static DSPhoneSize690Tune DSPhoneSize690CurrentTune(void) {
    static DSPhoneSize690Tune cached;
    static BOOL initialised = NO;
    if (initialised) return cached;   // 4.5.766: tune files removed; built-in constants, computed once
    initialised = YES;
    DSPhoneSize690Tune t;
    t.on = YES;
    t.stripTop = 59.0;
    t.stripHeight = 68.0;
    t.placeY = 0.0;
    t.touch = 0;
    // 4.5.705: the tune parse loop is gone (text is always nil since 4.5.702).
    cached = t;
    DSDiagnosticsRecordFormat(@"SpringBoard: phonesize690 tune %@ | in use: on=%d strip_top=%.0f strip_height=%.0f place_y=%.0f touch=%@",
                              @"built-in defaults",
                              (int)t.on, t.stripTop, t.stripHeight, t.placeY, DSPhoneSize690TouchName(t.touch));
    return t;
}

static NSString *const DSPhoneSize690TryingPath = @"/var/mobile/.dynamicstage-phonesize690-trying";
static NSString *const DSPhoneSize690CrashedPath = @"/var/mobile/.dynamicstage-phonesize690-crashed";

static BOOL DSPhoneSize690Latched(void) {
    static int checked = 0;
    static BOOL latched = NO;
    if (!checked) {
        checked = 1;
        @try {
            NSFileManager *fm = [NSFileManager defaultManager];
            if ([fm fileExistsAtPath:DSPhoneSize690TryingPath]) {
                [fm removeItemAtPath:DSPhoneSize690TryingPath error:NULL];
                [fm createFileAtPath:DSPhoneSize690CrashedPath contents:[NSData data] attributes:nil];
                DSDiagnosticsRecordFormat(@"SpringBoard: phonesize690 top-bar strip LATCHED OFF: SpringBoard went down within 15 s of the strip being made "
                                          @"(%@ found). Delete %@ to allow it again.", DSPhoneSize690TryingPath, DSPhoneSize690CrashedPath);
            }
            latched = [fm fileExistsAtPath:DSPhoneSize690CrashedPath] ||
                      [fm fileExistsAtPath:@"/var/jb/var/mobile/.dynamicstage-phonesize690-crashed"];
        } @catch (NSException *exception) {
            latched = YES;
        }
    }
    return latched;
}

static void DSPhoneSize690MarkTrying(void) {
    static BOOL marked = NO;
    if (marked) return;
    marked = YES;
    @try {
        [[NSFileManager defaultManager] createFileAtPath:DSPhoneSize690TryingPath contents:[NSData data] attributes:nil];
    } @catch (NSException *exception) {
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            [[NSFileManager defaultManager] removeItemAtPath:DSPhoneSize690TryingPath error:NULL];
        } @catch (NSException *exception) {
        }
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize690 top-bar strip survived 15 s; crash latch cleared");
    });
}

static void DSPhoneSize690SetBool(id object, NSString *setter, BOOL value) {
    SEL sel = NSSelectorFromString(setter);
    @try {
        if (object && [object respondsToSelector:sel]) ((void (*)(id, SEL, BOOL))objc_msgSend)(object, sel, value);
    } @catch (NSException *exception) {
    }
}


@interface DSPhoneSize690StripView : UIView
@property (nonatomic, assign) NSInteger touchMode;
@property (nonatomic, copy) NSString *bundle;
@property (nonatomic, assign) CGFloat stripTop;
@property (nonatomic, assign) CGFloat fit;
@end

@implementation DSPhoneSize690StripView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha < 0.01 || !self.userInteractionEnabled || self.touchMode == 2) return nil;
    // Keep the touch (forward mode: only touches the portal did not route to
    // the app reach SpringBoard at all), so it never falls on the app under it.
    return [self pointInside:point withEvent:event] ? self : nil;
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    CGPoint p = touch ? [touch locationInView:self] : CGPointZero;
    CGFloat fit = self.fit > 0.01 ? self.fit : 1.0;
    DSDiagnosticsRecordFormat(@"SpringBoard: phonesize690 %@ touch on the recreated top bar reached SpringBoard at strip %.0f,%.0f (app %.0f,%.0f), touch=%@: %@",
                              self.bundle ?: @"?", p.x, p.y, p.x / fit, self.stripTop + p.y / fit, DSPhoneSize690TouchName(self.touchMode),
                              self.touchMode == 0 ? @"the window server did NOT route it through the portal to the app (kept by the strip, nothing under it got it)"
                                                  : @"kept by the strip (block mode)");
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
}
@end

// Returns YES when the app is already on the stage and no further way in is
// needed; NO means "asked, now wait and see".
typedef BOOL (^DSSceneHostAttempt)(void);

void DSGest770NoteEvent(NSString *why);
@implementation DSSceneHost {
    FBScene *_scene;
    UIView *_hostView;
    // SpringBoard's own app view, when it could be had.
    SBAppViewController *_appViewController;
    SBDeviceApplicationSceneEntity *_entity;
    // 4.5.799 reg799: scene handle we passed to addSceneUpdateContributer:.
    id _reg799Handle;
    BOOL _reg799DelegateSet;
    BOOL _reg799LoggedMissingHandle;
    // Only set when the stage had to create the scene itself, which makes the
    // stage responsible for taking it down again.
    UIScenePresenter *_presenter;
    NSString *_ownSceneIdentifier;
    BOOL _nudgedThisLaunch;
    BOOL _deliveredOnce;
    BOOL _deferredSizeDelivery;
    BOOL _cardFitPending;
    BOOL _revealingTallContent;
    // 4.5.668 sbcam668: a staged app with no app dylib in it (Beeper) is
    // using the camera. Its scene is the phone's size, shown scaled to the
    // card width and bottom-aligned, so its own shutter row lands on the card.
    BOOL _cameraTall;
    BOOL _cameraTallParentClipped;
    BOOL _cameraTallParentWasClipping;
    NSInteger _cameraTallGeneration;
    // 4.5.675 phonesize675: the scene is the phone's size while the app's
    // keyboard is up; the host shows it at the card width with scene y =
    // _phoneSizeKeyTop on the card's bottom edge.
    BOOL _phoneSize;
    // 4.5.814 realkb814
    BOOL _rk814, _rk814Failed, _rk814Confirmed, _rk814Pending, _rk814InsetsPending;
    NSString *_rk814FailWhy;
    NSInteger _rk814Layouts;
    UIEdgeInsets _rk814Insets;
    CAShapeLayer *_rk814Mask;
    CGRect _rk814MaskCard, _rk814MaskKeys;
    CGFloat _phoneSizeKeyTop;
    NSInteger _phoneSizeGeneration;
    BOOL _phoneSizeParentClipped;
    BOOL _phoneSizeParentWasClipping;
    BOOL _phoneSizeDeferNoted;
    UIEdgeInsets _phoneSizeInsets;
    // 4.5.676: the 1 pt relayout nudge (scene 1 pt shorter, safe-area bottom
    // 1 pt larger) is being sent, and the optional held snapshot.
    BOOL _phoneSizeNudging;
    UIView *_phoneSizeHoldView;
    // 4.5.678 phonesize678
    BOOL _phoneSizeNudgeWidth;      // the running nudge changes the width (A), not the height
    BOOL _phoneSizePreGrown;        // phone-size before any keyboard (B/C): mapping is an anchor, not a keyboard top
    BOOL _phoneSizePreGrowCall;     // set only around the switch phoneSize678PreGrow makes
    // 4.5.679 phonesize679
    CGFloat _phoneSizeWidth;        // scene width chosen at the switch (card width / scale, or the phone's)
    CGFloat _ps679LoggedWidth;
    CGFloat _ps679LoggedFit;
    CGFloat _ps679LoggedPin;
    BOOL _beeper707Flat;     // 4.5.707 beeper707: phone-size host drawn without nested rounded clips
    BOOL _beeper707Logged;
    // 4.5.680 phonesize680
    CFAbsoluteTime _ps680GrowAskAt;
    int _ps683Logged;
    // 4.5.684 phonesize684 (fixed at the switch / at a rest-time apply)
    BOOL _ps684Active;              // this phone-size session uses safe area = keyboard
    BOOL _ps684Short;               // mode=short: scene ends at the keyboard top
    CGFloat _ps684K;                // bottom inset = the keyboard's height in the scene
    CGFloat _ps684TopFixed;         // tune top (<0 = auto)
    NSString *_ps684KSource;
    BOOL _ps684KeysUp;              // the app's keyboard is up (arbiter / note)
    BOOL _ps755Owned;               // 4.5.755 k755: the keyboard system named this app as the owner
    NSInteger _ps684ApplyToken;
    CGFloat _ps684CurTop;           // keyboard top (screen y) now, for learning
    double _ps684CurSince;
    NSMutableDictionary<NSNumber *, NSNumber *> *_ps684Durations;
    CGFloat _ps684LoggedTop;
    double _ps684LoggedArbiterH;
    CFAbsoluteTime _ps684SkipLogAt;
    // 4.5.685 phonesize685 (fixed with the 684 state)
    BOOL _ps685Active;
    CGFloat _ps685Slack;
    CGFloat _ps685View;
    CGFloat _ps685Margin;
    CGFloat _ps685TopFixed;
    CGFloat _ps685KeyTop;
    // 4.5.687 phonesize687 (fixed with the 684 state)
    BOOL _ps687Active;
    CGFloat _ps687View;
    CGFloat _ps687Margin;
    CGFloat _ps687TopFixed;
    // 4.5.688 phonesize688 (fixed with the 684 state)
    BOOL _ps688Active;
    NSInteger _ps688Mode;
    CGFloat _ps688View;
    CGFloat _ps688Offset;
    CGFloat _ps688Shift;
    CGFloat _ps688StatusBar;
    CGFloat _ps688LoggedShift;
    // 4.5.691 raised top inset (applied state)
    NSInteger _ps691Mode;           // 0 off, 1 auto (strip bottom), 2 fixed
    CGFloat _ps691Value;
    CGFloat _ps691StripH;
    CGFloat _ps691PlaceY;
    // 4.5.690 top-bar strip
    DSPhoneSize690StripView *_ps690Strip;
    NSString *_ps690LoggedState;
    NSString *_ps694LoggedState;
    NSString *_ps698LoggedState;    // 4.5.698: last logged bigger-picture state
    NSString *_ps696KeysSceneID;    // 4.5.696: scene id in DSPS696KeysScenes, or nil
    CFAbsoluteTime _ps696WakeAt;    // 4.5.696: last blackout wake
    NSInteger _ps696BadTicks;       // 4.5.696: consecutive watchdog ticks it looked black
    BOOL _revealSizeSent;
    BOOL _revealWriteQueued;
    CGFloat _growSentHeight;
    NSInteger _revealGeneration;
    BOOL _cardFitNoted;
    NSInteger _cardFitAttempts;
    NSInteger _cardFitWaits;
    CGFloat _cardFitWidth;
    CGFloat _cardFitHeight;
    CGFloat _deliveredWidth;
    CGFloat _deliveredHeight;
    CGRect _stageFrame;
    UIEdgeInsets _safeAreaInsets;
    BOOL _foreground;
    BOOL _staysBackgrounded;
    BOOL _followsSystemHome;
    // 4.5.659: when this app view stopped following the system home
    // transition. Its lifecycle is still SpringBoard's until this has settled.
    CFAbsoluteTime _systemHomeSettleUntil;
    BOOL _wakeRetryScheduled;
    NSInteger _wakeSettleAttempts;
    BOOL _registeredOverride;
    // Keeps RunningBoard from suspending a hosted app once its card is off screen.
    id _runningAssertion;
    pid_t _runningAssertionPid;
    // 4.5.719 bg719 (main thread only).
    id _bg719Assertion;
    pid_t _bg719Pid;
    pid_t _bg719TriedPid;
    NSUInteger _bg719Gen;
    BOOL _bg719Busy;
    BOOL _bg719RetakeAllowed;
    NSInteger _runningAssertionAttempts;
    BOOL _runningAssertionRetry;
    NSInteger _mediaActivateAttempts;
    NSInteger _cardSizeGeneration;
    BOOL _straySweepScheduled;
    NSHashTable *_hiddenStrays;
    NSTimeInterval _straySweepLast;
    BOOL _strayHideNoted;
    BOOL _matchCardFrame;
    BOOL _clampingHost;
    NSString *_sceneSource;
    CGFloat _keyboardClipHeight;
    BOOL _messagesKeyboardVisible;
}

- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier {
    if ((self = [super init])) {
        _bundleIdentifier = [bundleIdentifier copy];
        // 4.5.657: a new host for this app is a fresh launch onto the stage.
        DSSceneHostClearDied(_bundleIdentifier);
        _foreground = YES;
        _contentScale = [DSPreferences sharedPreferences].scale;
    }
    return self;
}

- (void)dealloc {
    [self restoreOwnedStrayPresentations];
    [self bg719Release:@"card gone"];
    [self releaseRunningAssertion];
    [self removeOverride];
}

#pragma mark - Application lookup

- (SBApplication *)application {
    Class controllerClass = objc_getClass("SBApplicationController");
    if (!controllerClass) return nil;
    return [[controllerClass sharedInstance] applicationWithBundleIdentifier:_bundleIdentifier];
}

// An app's scene has been reached several different ways over the years, and the
// one this used - SBApplication's own mainScene - is the oldest of them. On a
// build where it has gone, every launch ended the same way: the app started, no
// scene was ever found, and the stage gave up and went back to the picker. So
// each known shape is tried in turn, ending with asking FrontBoard for every
// scene it has and picking out the one belonging to this app, which needs nothing
// from SBApplication at all. Which one answered is written down once.
- (FBScene *)resolveScene {
    FBScene *scene = [self sceneFromBaseIdentifier];
    if (scene) return scene;
    scene = [self sceneFromApplication];
    if (scene) return scene;
    return [self sceneFromSceneManager];
}

// The replacement for mainScene since iOS 13: the application knows the identifier
// of the scene it would use, and FrontBoard hands over the scene itself if one
// exists under that name.
- (FBScene *)sceneFromBaseIdentifier {
    SBApplication *application = [self application];
    SEL identifierSelector = NSSelectorFromString(@"_baseSceneIdentifier");
    if (![application respondsToSelector:identifierSelector]) return nil;

    NSString *identifier = ((NSString * (*)(id, SEL))objc_msgSend)(application, identifierSelector);
    if (identifier.length == 0) return nil;

    Class managerClass = objc_getClass("FBSceneManager");
    if (![managerClass respondsToSelector:@selector(sharedInstance)]) return nil;
    id manager = ((id (*)(id, SEL))objc_msgSend)(managerClass, @selector(sharedInstance));

    SEL lookup = NSSelectorFromString(@"sceneWithIdentifier:");
    if (![manager respondsToSelector:lookup]) return nil;

    FBScene *scene = ((FBScene * (*)(id, SEL, id))objc_msgSend)(manager, lookup, identifier);
    if (scene) [self noteSceneSource:@"the app's base scene identifier"];
    return scene;
}

- (void)noteSceneSource:(NSString *)source {
    if ([_sceneSource isEqualToString:source]) return;
    _sceneSource = [source copy];
    DSDiagnosticsRecordFormat(@"SpringBoard: %@'s scene came from %@", _bundleIdentifier, source);
}

- (FBScene *)sceneFromApplication {
    SBApplication *application = [self application];
    if (!application) return nil;

    // iOS 13 and later: the app keeps scene handles, and a handle holds the scene -
    // asking a handle for its scene rather than for the one it already has is also
    // what brings a scene into being for an app that has none yet.
    for (NSString *name in @[ @"sceneHandles", @"allSceneHandles" ]) {
        SEL selector = NSSelectorFromString(name);
        if (![application respondsToSelector:selector]) continue;
        NSArray *handles = ((NSArray * (*)(id, SEL))objc_msgSend)(application, selector);
        FBScene *scene = [self sceneFromHandles:handles named:name];
        if (scene) return scene;
    }

    for (NSString *name in @[ @"mainSceneHandle", @"defaultSceneHandle", @"primarySceneHandle" ]) {
        SEL selector = NSSelectorFromString(name);
        if (![application respondsToSelector:selector]) continue;
        id handle = ((id (*)(id, SEL))objc_msgSend)(application, selector);
        FBScene *scene = [self sceneFromHandles:handle ? @[ handle ] : @[] named:name];
        if (scene) return scene;
    }

    if ([application respondsToSelector:@selector(mainScene)]) {
        FBScene *scene = application.mainScene;
        if (scene) {
            [self noteSceneSource:@"mainScene"];
            return scene;
        }
    }

    for (NSString *name in @[ @"allScenes", @"scenes" ]) {
        SEL selector = NSSelectorFromString(name);
        if (![application respondsToSelector:selector]) continue;
        NSArray *scenes = ((NSArray * (*)(id, SEL))objc_msgSend)(application, selector);
        if (scenes.count > 0) {
            [self noteSceneSource:name];
            return scenes.firstObject;
        }
    }
    return nil;
}

// A scene handle is SpringBoard's standing claim on an app's scene, and it answers
// two different questions: the scene it already has, and the scene it should have.
// The second one makes a scene where there was none, which is the difference
// between an app that can be put on the stage and an app that is merely running.
- (FBScene *)sceneFromHandles:(NSArray *)handles named:(NSString *)name {
    for (id handle in handles) {
        for (NSString *accessor in @[ @"sceneIfExists", @"scene" ]) {
            SEL selector = NSSelectorFromString(accessor);
            if (![handle respondsToSelector:selector]) continue;
            FBScene *scene = nil;
            @try {
                scene = ((FBScene * (*)(id, SEL))objc_msgSend)(handle, selector);
            } @catch (NSException *exception) {
                DSDiagnosticsRecordFormat(@"SpringBoard: %@ %@ threw %@",
                                          name, accessor, exception.name ?: @"?");
                continue;
            }
            if (scene) {
                [self noteSceneSource:[NSString stringWithFormat:@"%@ + %@", name, accessor]];
                return scene;
            }
        }
    }
    return nil;
}

- (FBScene *)sceneFromSceneManager {
    Class managerClass = objc_getClass("FBSceneManager");
    if ([managerClass respondsToSelector:@selector(sharedInstance)]) {
        id manager = ((id (*)(id, SEL))objc_msgSend)(managerClass, @selector(sharedInstance));
        for (NSString *name in @[ @"scenes", @"allScenes" ]) {
            SEL selector = NSSelectorFromString(name);
            if (![manager respondsToSelector:selector]) continue;
            NSArray *scenes = ((NSArray * (*)(id, SEL))objc_msgSend)(manager, selector);
            FBScene *match = [self sceneMatchingBundleIdentifierIn:scenes];
            if (match) {
                [self noteSceneSource:[NSString stringWithFormat:@"FBSceneManager %@", name]];
                return match;
            }
        }
    }

    // Last resort, and the one that needs nothing from anybody: every scene in
    // SpringBoard pushes settings through the hooks in Tweak.xm, so they are all
    // known here by the time they matter.
    FBScene *seen = [DSSceneHost liveSceneForBundleIdentifier:_bundleIdentifier];
    if (seen) [self noteSceneSource:@"scenes seen going past the settings hook"];
    return seen;
}

- (FBScene *)sceneMatchingBundleIdentifierIn:(NSArray *)scenes {
    for (FBScene *scene in scenes) {
        if (![scene respondsToSelector:@selector(identifier)]) continue;
        // Scene identifiers carry the bundle identifier of whoever owns them, as
        // in "sceneID:com.apple.Maps-default".
        if ([scene.identifier rangeOfString:_bundleIdentifier].location == NSNotFound) continue;
        return scene;
    }
    return nil;
}

#pragma mark - SpringBoard's own app view

// The way the app switcher and iPad multitasking put a live app in a view. Handing
// the job to SpringBoard is the difference between the stage assembling a scene out
// of parts - launching the app, finding the scene, hosting its layers, forcing its
// size, and hoping keyboard focus follows - and simply asking for an app view. It
// launches the app itself, so nothing needs to be started first.

#pragma mark - 4.5.799 reg799 (cover-sheet / in-call hosting registration)

// Off: reg799-off or core799-off. Crash latch via DSFeature699MarkTrying("reg799").
static BOOL DSReg799On(void) {
    if (!DS799On("reg799")) return NO;
    static BOOL marked = NO;
    if (!marked) {
        marked = YES;
        DSFeature699MarkTrying("reg799");
    }
    return YES;
}

// The app-view identifier SpringBoard asserts on (SBAppViewController._identifier).
// We pass the bundle id to initWithIdentifier:andApplicationSceneEntity:, so that
// is the string that must appear in ignoreOcclusionReasons.
- (NSString *)reg799Identifier {
    SBAppViewController *controller = _appViewController;
    if (!controller) return _bundleIdentifier;
    @try {
        Ivar iv = class_getInstanceVariable(object_getClass(controller), "_identifier");
        id ident = iv ? object_getIvar(controller, iv) : nil;
        if ([ident isKindOfClass:[NSString class]] && [(NSString *)ident length] > 0) return ident;
    } @catch (NSException *e) {}
    return _bundleIdentifier;
}

- (id)reg799SceneHandle {
    SBAppViewController *controller = _appViewController;
    if (!controller) return nil;
    @try {
        id handle = DSIvar(controller, @"_sceneHandle");
        if (!handle && [controller respondsToSelector:@selector(sceneHandle)]) {
            handle = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(sceneHandle));
        }
        return handle;
    } @catch (NSException *e) {
        return nil;
    }
}

// Verify selector exists and has the expected arity (self + _cmd + N args).
static BOOL DSReg799Has(id obj, SEL sel, unsigned expectedArgs, NSString **why) {
    if (!obj) { if (why) *why = @"nil target"; return NO; }
    if (![obj respondsToSelector:sel]) { if (why) *why = [NSString stringWithFormat:@"no %@", NSStringFromSelector(sel)]; return NO; }
    Method m = class_getInstanceMethod(object_getClass(obj), sel);
    if (!m) { if (why) *why = [NSString stringWithFormat:@"no Method for %@", NSStringFromSelector(sel)]; return NO; }
    unsigned n = method_getNumberOfArguments(m);
    // method_getNumberOfArguments counts self + _cmd.
    if (n != expectedArgs + 2) {
        if (why) *why = [NSString stringWithFormat:@"%@ arity %u (want %u)", NSStringFromSelector(sel), n - 2, expectedArgs];
        return NO;
    }
    return YES;
}

// Add our identifier to a mutable settings' ignoreOcclusionReasons set.
// Same call SpringBoard's contributor path uses (FBSMutableSceneSettings
// ignoreOcclusionReasons returns a lazy NSMutableSet).
+ (BOOL)reg799AppendReason:(NSString *)ident toSettings:(id)settings log:(BOOL)log {
    if (ident.length == 0 || !settings) return NO;
    @try {
        if (![settings respondsToSelector:@selector(ignoreOcclusionReasons)]) return NO;
        id reasons = ((id (*)(id, SEL))objc_msgSend)(settings, @selector(ignoreOcclusionReasons));
        if (![reasons respondsToSelector:@selector(addObject:)]) return NO;
        BOOL already = [reasons respondsToSelector:@selector(containsObject:)] && [reasons containsObject:ident];
        if (!already) [reasons addObject:ident];
        if (log) {
            DSDiagnosticsRecordFormat(@"SpringBoard: reg799: contributor appended reason %@ (already=%d, set=%@)",
                                      ident, already ? 1 : 0,
                                      [[reasons description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "]);
        }
        return YES;
    } @catch (NSException *e) {
        return NO;
    }
}

// SBApplicationSceneHandleUpdateContributing — called by
// -[SBApplicationSceneHandle _createApplicationSceneSettingsFromContext:entity:]
// on every settings rebuild through the scene handle (cover-sheet / in-call pattern).
- (void)applicationSceneHandle:(id)handle
        appendToSceneSettings:(id)settings
          fromRequestContext:(id)context
                      entity:(id)entity {
    if (!DSReg799On()) return;
    NSString *ident = [self reg799Identifier];
    [DSSceneHost reg799AppendReason:ident toSettings:settings log:YES];
    DSCrash793Crumb([[NSString stringWithFormat:@"reg799 append reason %@ handle=%p", ident ?: @"?", handle] UTF8String]);
}

// Optional transition-context companion on the same protocol (no-op; present so
// we match the real hosts' conformance surface).
- (void)applicationSceneHandle:(id)handle
     appendToTransitionContext:(id)ctx
           fromRequestContext:(id)context
                       entity:(id)entity {
    (void)handle; (void)ctx; (void)context; (void)entity;
}

#pragma mark - SBAppViewControllerDelegate (reg799)

- (void)appViewControllerWillActivateApplication:(id)controller {
    if (!DSReg799On()) return;
    // 4.5.800: rate-limit — a Live/foreground fight used to spam this ~15x.
    static CFAbsoluteTime last = 0;
    static NSInteger suppressed = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - last < 1.0) { suppressed++; return; }
    NSInteger skipped = suppressed;
    suppressed = 0;
    last = now;
    if (skipped > 0) {
        DSDiagnosticsRecordFormat(@"SpringBoard: reg799: appViewControllerWillActivateApplication %@ (suppressed %ld repeats)", _bundleIdentifier ?: @"?", (long)skipped);
    } else {
        DSDiagnosticsRecordFormat(@"SpringBoard: reg799: appViewControllerWillActivateApplication %@", _bundleIdentifier ?: @"?");
    }
}

- (void)appViewControllerDidDeactivateApplication:(id)controller {
    if (!DSReg799On()) return;
    DSDiagnosticsRecordFormat(@"SpringBoard: reg799: appViewControllerDidDeactivateApplication %@", _bundleIdentifier ?: @"?");
}

- (void)appViewControllerDidFailToActivateApplication:(id)controller {
    if (!DSReg799On()) return;
    DSDiagnosticsRecordFormat(@"SpringBoard: reg799: appViewControllerDidFailToActivateApplication %@", _bundleIdentifier ?: @"?");
}

- (BOOL)appViewControllerShouldBackgroundApplicationOnDeactivate:(id)controller {
    // Cover-sheet / in-call answer NO while the host wants the app to stay live.
    // Minimised cards still run (ignoresOcclusions); only tear-down should allow
    // backgrounding, and by then we have unregistered.
    if (!DSReg799On()) return YES;
    return NO;
}

- (BOOL)appViewControllerShouldReactivateApplicationOnDestruction:(id)controller {
    if (!DSReg799On()) return NO;
    return YES;
}

- (void)appViewController:(id)controller didTransitionFromMode:(NSInteger)from toMode:(NSInteger)to {
    if (!DSReg799On()) return;
    DSDiagnosticsRecordFormat(@"SpringBoard: reg799: mode %ld -> %ld for %@", (long)from, (long)to, _bundleIdentifier ?: @"?");
}

- (void)reg799TryRegister {
    if (!DSReg799On()) return;
    SBAppViewController *controller = _appViewController;
    if (!controller) return;

    // 1. Delegate (SBAppViewController.setDelegate:)
    if (!_reg799DelegateSet) {
        NSString *why = nil;
        if (DSReg799Has(controller, @selector(setDelegate:), 1, &why)) {
            ((void (*)(id, SEL, id))objc_msgSend)(controller, @selector(setDelegate:), self);
            _reg799DelegateSet = YES;
            DSDiagnosticsRecordFormat(@"SpringBoard: reg799: setDelegate on %@ ctrl=%p", _bundleIdentifier ?: @"?", controller);
        } else {
            DSDiagnosticsRecordFormat(@"SpringBoard: reg799: skip setDelegate on %@: %@", _bundleIdentifier ?: @"?", why ?: @"?");
        }
    }

    // 2. Scene-update contributor on the scene handle.
    id handle = [self reg799SceneHandle];
    if (!handle) {
        if (!_reg799LoggedMissingHandle) {
            _reg799LoggedMissingHandle = YES;
            DSDiagnosticsRecordFormat(@"SpringBoard: reg799: no sceneHandle yet for %@ (will retry)", _bundleIdentifier ?: @"?");
        }
        return;
    }
    if (_reg799Handle == handle) return; // already registered on this handle
    if (_reg799Handle && _reg799Handle != handle) {
        [self reg799Unregister]; // move to the new handle
    }

    NSString *whyAdd = nil;
    // addSceneUpdateContributer: — note Apple's spelling (one 'o').
    SEL addSel = @selector(addSceneUpdateContributer:);
    if (!DSReg799Has(handle, addSel, 1, &whyAdd)) {
        DSDiagnosticsRecordFormat(@"SpringBoard: reg799: cannot add contributor on %@: %@", _bundleIdentifier ?: @"?", whyAdd ?: @"?");
        return;
    }
    // Confirm the protocol method we implement has the right arity on our class.
    NSString *whyAppend = nil;
    SEL appendSel = @selector(applicationSceneHandle:appendToSceneSettings:fromRequestContext:entity:);
    if (!DSReg799Has(self, appendSel, 4, &whyAppend)) {
        DSDiagnosticsRecordFormat(@"SpringBoard: reg799: our append method bad: %@", whyAppend ?: @"?");
        return;
    }

    ((void (*)(id, SEL, id))objc_msgSend)(handle, addSel, self);
    _reg799Handle = handle;
    NSString *ident = [self reg799Identifier];
    DSDiagnosticsRecordFormat(@"SpringBoard: reg799: registered contributor on %@ handle=%p ident=%@ (addSceneUpdateContributer:)",
                              _bundleIdentifier ?: @"?", handle, ident ?: @"?");
    DSCrash793Crumb([[NSString stringWithFormat:@"reg799 registered %@ handle=%p", _bundleIdentifier ?: @"?", handle] UTF8String]);

}

- (void)reg799Unregister {
    id handle = _reg799Handle;
    _reg799Handle = nil;
    _reg799LoggedMissingHandle = NO;
    if (!handle) return;
    NSString *why = nil;
    SEL remSel = @selector(removeSceneUpdateContributer:);
    if (DSReg799Has(handle, remSel, 1, &why)) {
        ((void (*)(id, SEL, id))objc_msgSend)(handle, remSel, self);
        DSDiagnosticsRecordFormat(@"SpringBoard: reg799: removed contributor from %@ handle=%p", _bundleIdentifier ?: @"?", handle);
        DSCrash793Crumb([[NSString stringWithFormat:@"reg799 removed %@ handle=%p", _bundleIdentifier ?: @"?", handle] UTF8String]);
    } else {
        DSDiagnosticsRecordFormat(@"SpringBoard: reg799: could not remove contributor: %@", why ?: @"?");
    }
    // Clear delegate if we set it.
    SBAppViewController *controller = _appViewController;
    if (_reg799DelegateSet && controller && [controller respondsToSelector:@selector(setDelegate:)]) {
        @try {
            id cur = [controller respondsToSelector:@selector(delegate)] ? ((id (*)(id, SEL))objc_msgSend)(controller, @selector(delegate)) : nil;
            if (cur == self) ((void (*)(id, SEL, id))objc_msgSend)(controller, @selector(setDelegate:), nil);
        } @catch (NSException *e) {}
    }
    _reg799DelegateSet = NO;
}

#pragma mark - 4.5.800 reason800 / fg800

// Off: reason800-off or core800-off. Crash latch via DSFeature699MarkTrying("reason800").
static BOOL DSReason800On(void) {
    if (!DS800On("reason800")) return NO;
    static BOOL marked = NO;
    if (!marked) {
        marked = YES;
        DSFeature699MarkTrying("reason800");
    }
    return YES;
}

static BOOL DSFg800On(void) {
    if (!DS800On("fg800")) return NO;
    static BOOL marked = NO;
    if (!marked) {
        marked = YES;
        DSFeature699MarkTrying("fg800");
    }
    return YES;
}

static const void *kDSFg800ParkedKey = &kDSFg800ParkedKey;

+ (NSString *)reason800IdentifierForAppViewController:(id)controller {
    if (!controller) return nil;
    @try {
        Ivar iv = class_getInstanceVariable(object_getClass(controller), "_identifier");
        id ident = iv ? object_getIvar(controller, iv) : nil;
        if ([ident isKindOfClass:[NSString class]] && [(NSString *)ident length] > 0) return ident;
    } @catch (NSException *e) {}
    return nil;
}

// Re-append our app-view identifier onto a mutable settings' ignoreOcclusionReasons.
// Uses the verified FBSMutableSceneSettings API (lazy NSMutableSet). When the
// live scene.settings object is immutable (home/layout already committed an
// empty set), fall back to FBScene updateSettingsWithBlock:.
+ (BOOL)reason800EnsureReasonOnSettings:(id)settings forAppViewController:(id)controller {
    if (!DSReason800On() || !settings || !controller) return NO;
    NSString *ident = [self reason800IdentifierForAppViewController:controller];
    if (ident.length == 0) return NO;
    static NSInteger depth = 0;
    if (depth > 0) return NO;
    @try {
        id reasons = [settings respondsToSelector:@selector(ignoreOcclusionReasons)]
            ? ((id (*)(id, SEL))objc_msgSend)(settings, @selector(ignoreOcclusionReasons)) : nil;
        BOOL has = ident && [reasons respondsToSelector:@selector(containsObject:)] && [reasons containsObject:ident];
        if (has) return NO; // already present; nothing to do
        BOOL ok = [self reg799AppendReason:ident toSettings:settings log:NO];
        const char *how = "in-place";
        if (!ok) {
            // Immutable settings: push a block update onto the scene.
            id handle = DSIvar(controller, @"_sceneHandle");
            if (!handle && [controller respondsToSelector:@selector(sceneHandle)]) {
                handle = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(sceneHandle));
            }
            id scene = (handle && [handle respondsToSelector:@selector(scene)])
                ? ((id (*)(id, SEL))objc_msgSend)(handle, @selector(scene)) : nil;
            if (scene) {
                depth++;
                @try {
                    DSUpdateSceneSettings((FBScene *)scene, ^(FBSMutableSceneSettings *mutable) {
                        [DSSceneHost reg799AppendReason:ident toSettings:mutable log:NO];
                    });
                    ok = YES;
                    how = "updateSettingsWithBlock";
                } @finally {
                    depth--;
                }
            }
        }
        if (ok) {
            static CFAbsoluteTime last = 0;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - last > 0.5) {
                last = now;
                NSString *line = [NSString stringWithFormat:@"reason800: re-appended %@ via %s (was missing; home/layout path bypassed contributor) ctrl=%p",
                                  ident, how, controller];
                DSDiagnosticsRecordFormat(@"SpringBoard: %@", line);
                DSCrash793Crumb(line.UTF8String);
            }
        }
        return ok;
    } @catch (NSException *e) {
        return NO;
    }
}

// For FBScene update paths: find the owned app view for this scene and append.
+ (BOOL)reason800EnsureReasonOnScene:(id)scene settings:(id)settings {
    if (!DSReason800On() || !scene || !settings) return NO;
    @try {
        id match = nil;
        for (id ctrl in DSOwnedAppViewControllers()) {
            id handle = nil;
            @try {
                handle = DSIvar(ctrl, @"_sceneHandle");
                if (!handle && [ctrl respondsToSelector:@selector(sceneHandle)]) {
                    handle = ((id (*)(id, SEL))objc_msgSend)(ctrl, @selector(sceneHandle));
                }
            } @catch (NSException *e) { handle = nil; }
            id sc = (handle && [handle respondsToSelector:@selector(scene)])
                ? ((id (*)(id, SEL))objc_msgSend)(handle, @selector(scene)) : nil;
            if (sc == scene) { match = ctrl; break; }
        }
        if (!match) {
            // Fallback: scene identifier often embeds the bundle id we used as _identifier.
            NSString *sid = [scene respondsToSelector:@selector(identifier)] ? ((id (*)(id, SEL))objc_msgSend)(scene, @selector(identifier)) : nil;
            if (![sid isKindOfClass:[NSString class]] || sid.length == 0) return NO;
            for (id ctrl in DSOwnedAppViewControllers()) {
                NSString *ident = [self reason800IdentifierForAppViewController:ctrl];
                if (ident.length && [sid rangeOfString:ident].location != NSNotFound) { match = ctrl; break; }
            }
        }
        if (!match) return NO;
        return [self reason800EnsureReasonOnSettings:settings forAppViewController:match];
    } @catch (NSException *e) {
        return NO;
    }
}

// Leave Live (SBAppViewControllerMode = 2) for Static (1) before SpringBoard
// applies a foreground=NO update. Cover-sheet / in-call hosts leave Live via
// setRequestedMode: when the scene is backgrounded. With automatesLifecycle NO,
// setRequestedMode: alone only stores _requestedMode — 800 also drove
// _setCurrentMode:1, which stopped the Live assertion but SpringBoard still
// soft-asserted with "current mode: Static". 4.5.801 fg801 briefly flips
// automatesLifecycle YES around setRequestedMode: so _deactivateHostedApp runs
// the same ordered path as DashBoard / in-call (mode transition owns the
// foreground change). Restore with fg800RestoreLiveIfNeeded (fg801 also puts
// displayMode 4 + _activateApp back so layerHosts are not empty).
static BOOL DSFg801On(void) {
    if (!DS801On("fg801")) return NO;
    static BOOL marked = NO;
    if (!marked) {
        marked = YES;
        DSFeature699MarkTrying("fg801");
    }
    return YES;
}

+ (void)fg800LeaveLiveIfBackgrounded:(id)controller handle:(id)handle previousSettings:(id)previousSettings {
    if (!DSFg800On() || !controller) return;
    @try {
        NSInteger mode = -1;
        if ([controller respondsToSelector:@selector(currentMode)]) {
            mode = ((NSInteger (*)(id, SEL))objc_msgSend)(controller, @selector(currentMode));
        }
        // SBAppViewControllerMode: 0 None, 1 Static, 2 Live
        if (mode != 2) return;

        id scene = nil;
        if (handle && [handle respondsToSelector:@selector(scene)]) {
            scene = ((id (*)(id, SEL))objc_msgSend)(handle, @selector(scene));
        }
        id settings = (scene && [scene respondsToSelector:@selector(settings)])
            ? ((id (*)(id, SEL))objc_msgSend)(scene, @selector(settings)) : nil;
        BOOL knownNow = NO, knownBefore = NO;
        BOOL after = settings ? [self readForegroundFlag:settings known:&knownNow] : NO;
        BOOL before = previousSettings ? [self readForegroundFlag:previousSettings known:&knownBefore] : YES;
        BOOL backgrounded = knownNow && !after;
        BOOL flippingOff = knownBefore && knownNow && before && !after;
        if (!backgrounded && !flippingOff) return;

        objc_setAssociatedObject(controller, kDSFg800ParkedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        BOOL fg801 = DSFg801On();
        BOOL wasAuto = NO;
        if (fg801 && [controller respondsToSelector:@selector(automatesLifecycle)]) {
            wasAuto = ((BOOL (*)(id, SEL))objc_msgSend)(controller, @selector(automatesLifecycle));
            if (!wasAuto && [controller respondsToSelector:@selector(setAutomatesLifecycle:)]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setAutomatesLifecycle:), YES);
            }
        }
        if ([controller respondsToSelector:@selector(setRequestedMode:)]) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(controller, @selector(setRequestedMode:), (NSInteger)1);
        }
        // Fallback / 800 path: with automatesLifecycle still NO, setRequestedMode
        // alone is not enough.
        if (!fg801 || wasAuto) {
            if ([controller respondsToSelector:@selector(_setCurrentMode:)]) {
                ((void (*)(id, SEL, NSInteger))objc_msgSend)(controller, @selector(_setCurrentMode:), (NSInteger)1);
            }
        } else if ([controller respondsToSelector:@selector(currentMode)]) {
            NSInteger now = ((NSInteger (*)(id, SEL))objc_msgSend)(controller, @selector(currentMode));
            if (now != 1 && [controller respondsToSelector:@selector(_setCurrentMode:)]) {
                ((void (*)(id, SEL, NSInteger))objc_msgSend)(controller, @selector(_setCurrentMode:), (NSInteger)1);
            }
        }
        if (fg801 && !wasAuto && [controller respondsToSelector:@selector(setAutomatesLifecycle:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setAutomatesLifecycle:), NO);
        }
        NSString *line = [NSString stringWithFormat:@"%@: Live -> Static (scene backgrounded fg=%d flip=%d auto=%d) ctrl=%p",
                          fg801 ? @"fg801" : @"fg800", after ? 1 : 0, flippingOff ? 1 : 0, fg801 ? 1 : 0, controller];
        DSDiagnosticsRecordFormat(@"SpringBoard: %@", line);
        DSCrash793Crumb(line.UTF8String);
    } @catch (NSException *e) {}
}

+ (void)fg800RestoreLiveIfNeeded:(id)controller {
    if (!DSFg800On() || !controller) return;
    @try {
        NSNumber *parked = objc_getAssociatedObject(controller, kDSFg800ParkedKey);
        if (!parked.boolValue) return;
        NSInteger mode = -1;
        if ([controller respondsToSelector:@selector(currentMode)]) {
            mode = ((NSInteger (*)(id, SEL))objc_msgSend)(controller, @selector(currentMode));
        }
        BOOL fg801 = DSFg801On();
        if (mode == 2) {
            // Already Live — still ensure displayMode 4 so layerHosts come back
            // after a deep-background Static park (Hdidbdh 00:20:55 mode=2 hosts=[]).
            if (fg801 && [controller respondsToSelector:@selector(setDisplayMode:animationFactory:completion:)]) {
                NSInteger dm = -1;
                if ([controller respondsToSelector:@selector(displayMode)]) {
                    dm = ((NSInteger (*)(id, SEL))objc_msgSend)(controller, @selector(displayMode));
                }
                if (dm != 4) {
                    ((void (*)(id, SEL, NSInteger, id, id))objc_msgSend)(controller, @selector(setDisplayMode:animationFactory:completion:), (NSInteger)4, nil, nil);
                    SEL activate = NSSelectorFromString(@"_activateApp");
                    if ([controller respondsToSelector:activate]) {
                        ((void (*)(id, SEL))objc_msgSend)(controller, activate);
                    }
                    NSString *line = [NSString stringWithFormat:@"fg801: Live hosts refresh displayMode %ld -> 4 ctrl=%p", (long)dm, controller];
                    DSDiagnosticsRecordFormat(@"SpringBoard: %@", line);
                    DSCrash793Crumb(line.UTF8String);
                }
            }
            objc_setAssociatedObject(controller, kDSFg800ParkedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
        BOOL wasAuto = NO;
        if (fg801 && [controller respondsToSelector:@selector(automatesLifecycle)]) {
            wasAuto = ((BOOL (*)(id, SEL))objc_msgSend)(controller, @selector(automatesLifecycle));
            if (!wasAuto && [controller respondsToSelector:@selector(setAutomatesLifecycle:)]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setAutomatesLifecycle:), YES);
            }
        }
        if ([controller respondsToSelector:@selector(setRequestedMode:)]) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(controller, @selector(setRequestedMode:), (NSInteger)2);
        }
        if ([controller respondsToSelector:@selector(_setCurrentMode:)]) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(controller, @selector(_setCurrentMode:), (NSInteger)2);
        }
        if (fg801 && [controller respondsToSelector:@selector(setDisplayMode:animationFactory:completion:)]) {
            ((void (*)(id, SEL, NSInteger, id, id))objc_msgSend)(controller, @selector(setDisplayMode:animationFactory:completion:), (NSInteger)4, nil, nil);
            SEL activate = NSSelectorFromString(@"_activateApp");
            if ([controller respondsToSelector:activate]) {
                ((void (*)(id, SEL))objc_msgSend)(controller, activate);
            }
        }
        if (fg801 && !wasAuto && [controller respondsToSelector:@selector(setAutomatesLifecycle:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setAutomatesLifecycle:), NO);
        }
        objc_setAssociatedObject(controller, kDSFg800ParkedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSString *line = [NSString stringWithFormat:@"%@: Static -> Live (restore) ctrl=%p wasMode=%ld hosts=%d",
                          fg801 ? @"fg801" : @"fg800", controller, (long)mode, fg801 ? 1 : 0];
        DSDiagnosticsRecordFormat(@"SpringBoard: %@", line);
        DSCrash793Crumb(line.UTF8String);
    } @catch (NSException *e) {}
}

// 4.5.801: YES when fg801 just parked this controller and the upcoming
// foreground=NO update should not run through SpringBoard's Live/Static check
// (cover-sheet ordering already owned the transition).
+ (BOOL)fg801ShouldSkipForegroundAssertionOrig:(id)controller previousSettings:(id)previousSettings handle:(id)handle {
    if (!DSFg801On() || !controller) return NO;
    @try {
        NSNumber *parked = objc_getAssociatedObject(controller, kDSFg800ParkedKey);
        // Parked flag is cleared on restore; right after Leave it is YES. Also
        // accept currentMode already Static with a foreground flip off.
        NSInteger mode = -1;
        if ([controller respondsToSelector:@selector(currentMode)]) {
            mode = ((NSInteger (*)(id, SEL))objc_msgSend)(controller, @selector(currentMode));
        }
        id scene = (handle && [handle respondsToSelector:@selector(scene)])
            ? ((id (*)(id, SEL))objc_msgSend)(handle, @selector(scene)) : nil;
        id settings = (scene && [scene respondsToSelector:@selector(settings)])
            ? ((id (*)(id, SEL))objc_msgSend)(scene, @selector(settings)) : nil;
        BOOL knownNow = NO, knownBefore = NO;
        BOOL after = settings ? [self readForegroundFlag:settings known:&knownNow] : YES;
        BOOL before = previousSettings ? [self readForegroundFlag:previousSettings known:&knownBefore] : YES;
        BOOL flippingOff = knownBefore && knownNow && before && !after;
        if (!flippingOff) return NO;
        if (mode == 1) return YES; // already Static — our leave owned it
        if (parked.boolValue) return YES;
    } @catch (NSException *e) {}
    return NO;
}

- (BOOL)hostThroughAppViewController {
    if (_appViewController) return YES;

    SBApplication *application = [self application];
    UIViewController *parent = self.parentViewController;
    if (!application || !parent) return NO;

    Class entityClass = objc_getClass("SBDeviceApplicationSceneEntity");
    Class viewControllerClass = objc_getClass("SBAppViewController");
    if (!entityClass || !viewControllerClass) {
        DSDiagnosticsRecord(@"SpringBoard: no app view controller on this build, falling back to raw hosting");
        return NO;
    }

    @try {
        id sceneManager = [self mainDisplaySceneManager];
        id displayIdentity = [sceneManager respondsToSelector:@selector(displayIdentity)]
            ? ((id (*)(id, SEL))objc_msgSend)(sceneManager, @selector(displayIdentity))
            : nil;

        // Which of these a build has changes with the iOS version, and the later ones
        // are not simply newer names for the earlier: the "generating new primary
        // scene" one is the only one that promises a scene for an app that has none,
        // which is the case the stage exists for.
        SBDeviceApplicationSceneEntity *entity = nil;
        NSString *entityRoute = nil;

        SEL withProvider = NSSelectorFromString(@"defaultEntityWithApplication:sceneHandleProvider:displayIdentity:");
        if (!entity && sceneManager && displayIdentity && [entityClass respondsToSelector:withProvider]) {
            entity = ((id (*)(id, SEL, id, id, id))objc_msgSend)(entityClass, withProvider,
                                                                 application, sceneManager, displayIdentity);
            entityRoute = @"default entity with a scene handle provider";
        }

        SEL generating = NSSelectorFromString(@"initWithApplicationForMainDisplay:generatingNewPrimarySceneIfRequired:");
        if (!entity && [entityClass instancesRespondToSelector:generating]) {
            entity = ((id (*)(id, SEL, id, BOOL))objc_msgSend)([entityClass alloc], generating, application, YES);
            entityRoute = @"entity that makes a scene if the app has none";
        }

        SEL defaultForMainDisplay = NSSelectorFromString(@"defaultEntityWithApplicationForMainDisplay:");
        if (!entity && [entityClass respondsToSelector:defaultForMainDisplay]) {
            entity = ((id (*)(id, SEL, id))objc_msgSend)(entityClass, defaultForMainDisplay, application);
            entityRoute = @"default entity for the main display";
        }

        if (!entity && [entityClass instancesRespondToSelector:@selector(initWithApplicationForMainDisplay:)]) {
            entity = [[entityClass alloc] initWithApplicationForMainDisplay:application];
            entityRoute = @"plain entity for the main display";
        }

        if (!entity) {
            DSDiagnosticsRecordFormat(@"SpringBoard: no scene entity for %@ - none of the ways of asking exist here",
                                      _bundleIdentifier);
            return NO;
        }
        DSDiagnosticsRecordFormat(@"SpringBoard: %@ got its %@", _bundleIdentifier, entityRoute);
        DSDiagnosticsRecordFormat(@"SpringBoard: creating app view for %@", _bundleIdentifier);

        SBAppViewController *controller =
            [[viewControllerClass alloc] initWithIdentifier:_bundleIdentifier andApplicationSceneEntity:entity];
        DSDiagnosticsRecordFormat(@"SpringBoard: created app view for %@", _bundleIdentifier);
        if (!controller) {
            DSDiagnosticsRecordFormat(@"SpringBoard: no app view controller for %@", _bundleIdentifier);
            return NO;
        }

        _entity = entity;
        _appViewController = controller;
        [DSOwnedAppViewControllers() addObject:controller];

        [parent addChildViewController:controller];
        // Occlusion and appearance must not suspend the app. Minimizing slides the
        // card off screen; if the app view treated that as "gone", Safari and others
        // tore their scene down and the card came back empty or see-through.
        if ([controller respondsToSelector:@selector(setIgnoresOcclusions:)]) {
            [controller setIgnoresOcclusions:YES];
        }
        if ([controller respondsToSelector:@selector(setAutomatesLifecycle:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setAutomatesLifecycle:), NO);
        }
        // Mode 2 is the live one. Anything else and the view shows a snapshot.
        if ([controller respondsToSelector:@selector(_setCurrentMode:)]) [controller _setCurrentMode:2];

        // Told before the app starts, so it launches at the card's size instead of
        // launching full screen and being cut down afterwards.
        [self setContentReferenceSizeOnAppView];

        // Activation settings left over from however the app was last opened decide
        // things like orientation and whether it animates; cleared so the stage's
        // own settings are the only ones in play.
        id activationSettings = DSIvar(controller, @"_activationSettings");
        if ([activationSettings respondsToSelector:@selector(clearActivationSettings)]) {
            ((void (*)(id, SEL))objc_msgSend)(activationSettings, @selector(clearActivationSettings));
        }

        [self beginSceneTransactionDeliveringActions:YES];

        if ([controller respondsToSelector:@selector(_createSceneViewController)]) {
            [controller _createSceneViewController];
        }
        // 4 is live content: the app's own render rather than a still of it.
        if ([controller respondsToSelector:@selector(setDisplayMode:animationFactory:completion:)]) {
            [controller setDisplayMode:4 animationFactory:nil completion:nil];
        }
        // Activating while another app is playing a video asserts. The scene
        // transaction above already starts the app; activation waits.
        [self activateHostedAppWhenMediaAllows];

        UIView *view = controller.view;
        if (!view) {
            DSDiagnosticsRecordFormat(@"SpringBoard: %@'s app view controller has no view", _bundleIdentifier);
            [self tearDownAppViewController];
            return NO;
        }
        // Clear lets the wallpaper show through until the app paints, and some
        // apps (Safari) never paint an opaque root view of their own.
        view.opaque = YES;
        if (@available(iOS 13.0, *)) {
            view.backgroundColor = UIColor.systemBackgroundColor;
        } else {
            view.backgroundColor = UIColor.whiteColor;
        }
        view.clipsToBounds = YES;
        _hostView = view;

        [self noteSceneSource:@"SpringBoard's own app view"];
        [self holdRunningAssertion];
        [self reportHostingOutcome];
        // 4.5.658: camera coverage, written once per app going on a card.
        @try {
            [DSCameraArbiter noteStagedBundle:_bundleIdentifier];
        } @catch (NSException *exception) {
        }
        // 4.5.799: register as cover-sheet / in-call hosts do. Scene handle may
        // not exist yet; reportHostingOutcome retries.
        [self reg799TryRegister];
        return YES;
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: asking for an app view for %@ threw %@ - %@",
                                  _bundleIdentifier, exception.name ?: @"?", exception.reason ?: @"?");
        [self tearDownAppViewController];
        return NO;
    }
}

// "It showed the logo and went back to the picker" and "the app is there but has
// not drawn yet" look identical from outside, so the app view is asked once it has
// had time to start, and the answer is written down.
- (void)reportHostingOutcome {
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        SBAppViewController *controller = strongSelf ? strongSelf->_appViewController : nil;
        if (!controller) return;
        @try {
            SEL hosting = NSSelectorFromString(@"isHostingAnApp");
            BOOL isHosting = [controller respondsToSelector:hosting]
                ? ((BOOL (*)(id, SEL))objc_msgSend)(controller, hosting)
                : NO;
            FBScene *scene = [strongSelf appViewScene];
            DSDiagnosticsRecordFormat(@"SpringBoard: %@ after two seconds - %@, %@, view %@",
                                      strongSelf->_bundleIdentifier,
                                      isHosting ? @"hosting the app" : @"not hosting anything",
                                      scene ? @"scene present" : @"no scene",
                                      controller.view.superview ? @"in the card" : @"not in the card");
            // 4.5.678 C (opt-in): an allowlisted app goes phone-size as soon as
            // its card is hosting it.
            if (isHosting && scene && controller.view.superview && DSPhoneSize678Always()) {
                DSStageManager *manager = [DSStageManager sharedManager];
                if ([manager respondsToSelector:@selector(phoneSize678HostReady:)]) [manager phoneSize678HostReady:strongSelf];
            }
            // 4.5.799: scene handle is usually present by now.
            [strongSelf reg799TryRegister];
        } @catch (NSException *exception) {
        }
    });
}

- (id)mainDisplaySceneManager {
    return [DSSceneHost mainDisplaySceneManager];
}

+ (id)mainDisplaySceneManager {
    Class coordinator = objc_getClass("SBSceneManagerCoordinator");
    if (!coordinator) return nil;
    if ([coordinator respondsToSelector:@selector(mainDisplaySceneManager)]) {
        return ((id (*)(id, SEL))objc_msgSend)(coordinator, @selector(mainDisplaySceneManager));
    }
    if ([coordinator respondsToSelector:@selector(sharedInstance)]) {
        id shared = ((id (*)(id, SEL))objc_msgSend)(coordinator, @selector(sharedInstance));
        if ([shared respondsToSelector:@selector(mainDisplaySceneManager)]) {
            return ((id (*)(id, SEL))objc_msgSend)(shared, @selector(mainDisplaySceneManager));
        }
    }
    return nil;
}

// Every size change has to go through one of these or the app keeps drawing for
// whatever size it was given last. Actions are delivered only on the first one,
// which is what launches the app.
- (void)beginSceneTransactionDeliveringActions:(BOOL)deliveringActions {
    DSTraceFormat(@"scene transaction %@ actions=%d", _bundleIdentifier ?: @"?", deliveringActions);
    if (DSSceneWriteWouldTrap()) return;
    SBAppViewController *controller = _appViewController;
    if (![controller respondsToSelector:@selector(_createSceneUpdateTransactionForApplicationSceneEntity:deliveringActions:)]) {
        return;
    }
    @try {
        id transaction = [controller _createSceneUpdateTransactionForApplicationSceneEntity:_entity
                                                                        deliveringActions:deliveringActions];
        if (!transaction) return;
        id transactions = DSIvar(controller, @"_activeTransitions");
        if ([transactions respondsToSelector:@selector(addObject:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(transactions, @selector(addObject:), transaction);
        }
        if ([transaction respondsToSelector:@selector(begin)]) {
            ((void (*)(id, SEL))objc_msgSend)(transaction, @selector(begin));
        }
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: resizing %@ threw %@", _bundleIdentifier, exception.name ?: @"?");
    }
}

// The app view controller re-pins the scene to the whole display on every
// transaction, so the stage's size has to be written after it - last write wins.
// A cold-launching app is not ready to be told for the first second or two either,
// which is why this is repeated: without it the card stays black until something
// else happens to resize it.
- (BOOL)appViewIsShowingContent {
    SBAppViewController *controller = _appViewController;
    if (!controller) return NO;
    SEL hosting = NSSelectorFromString(@"isHostingAnApp");
    if ([controller respondsToSelector:hosting]) {
        @try {
            return ((BOOL (*)(id, SEL))objc_msgSend)(controller, hosting);
        } @catch (NSException *exception) {
        }
    }
    return [self appViewScene] != nil;
}

// 4.5.754 log754: true when this trace line differs from the last one of its
// kind or 2 s have passed (repeats are dropped, not counted).
static BOOL DSTrace754Fresh(NSString *line, int kind) {
    static NSString *last[2] = { nil, nil };
    static CFAbsoluteTime at[2] = { 0, 0 };
    if (!(DSFeature699On("core754") && DSFeature699On("log754"))) return YES;
    CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
    if ([line isEqualToString:last[kind]] && t - at[kind] < 2.0 && t >= at[kind]) return NO;
    last[kind] = [line copy];
    at[kind] = t;
    return YES;
}

// 4.5.754 host754: the same three facts the "after two seconds" line reports,
// asked directly: the app view hosts the app, its scene exists, and the app view
// is in the card. Read only (no scene writes).
- (BOOL)host754Ready {
    if (!self.isHosting) return NO;
    SBAppViewController *controller = _appViewController;
    if (!controller || !controller.view.superview || !controller.view.window) return NO;
    return [self appViewIsShowingContent] && [self appViewScene] != nil;
}

// Repeating this after the app is already on screen is what flickers the card:
// each transaction re-pins the scene and the view goes blank until it draws again.
- (void)deliverStageSizeToApp {
    // A second transaction while the card is uncovering a tall layout pins the
    // app back to the half height. That half height is the black band.
    if (_revealingTallContent) return;
    if (DSSceneWriteWouldTrap()) {
        if (_deferredSizeDelivery) return;
        _deferredSizeDelivery = YES;
        __weak __typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_deferredSizeDelivery = NO;
            [strongSelf deliverStageSizeToApp];
        });
        return;
    }
    if (!_appViewController) return;
    CGSize size = [self logicalFrame].size;
    if (CGSizeEqualToSize(size, CGSizeZero)) return;
    BOOL sameSize = _deliveredOnce &&
                    fabs(size.width - _deliveredWidth) < 0.5 &&
                    fabs(size.height - _deliveredHeight) < 0.5;
    if (sameSize && [self appViewIsShowingContent]) {
        // The number we handed over matches the card, but the app view can
        // still have pinned the scene back to the whole display. Fit that
        // without another transaction.
        if ([self sceneFrameIsLargerThanStage]) [self scheduleCardSizeFit];
        return;
    }

    _deliveredOnce = YES;
    _deliveredWidth = size.width;
    _deliveredHeight = size.height;
    // The transaction re-pins the scene to the whole display. The stage size has
    // to be the last thing written, or the card clips a full-screen app.
    [self beginSceneTransactionDeliveringActions:NO];
    [self setContentReferenceSizeOnAppView];
    [self forceSceneGeometry];
    [self layoutHostView];
    [self scheduleSizeCorrection];
}

- (void)refitPresentedScene {
    // Geometry only. deliverStageSizeToApp starts a scene transaction, and the
    // app view answers that by pinning itself to the whole display again.
    [self layoutHostView];
    if ([self sceneFrameIsLargerThanStage]) [self scheduleCardSizeFit];
}

- (void)scheduleSettledCardSizeDelivery {
    if (!_appViewController) return;
    _cardSizeGeneration += 1;
    NSInteger generation = _cardSizeGeneration;
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.22 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_cardSizeGeneration != generation) return;
        if (!strongSelf->_appViewController || !strongSelf->_matchCardFrame) return;
        if (strongSelf->_revealingTallContent) return;
        // One transaction after the size settles. A transaction on every
        // layout is what blanked the card and stacked into a safe mode.
        strongSelf->_deliveredOnce = NO;
        [strongSelf deliverStageSizeToApp];
        [strongSelf layoutHostView];
    });
}

- (void)applyCardFrameQuietly:(CGRect)frame {
    if (_revealingTallContent) {
        [self layoutHostView];
        return;
    }
    if (CGRectIsEmpty(frame)) return;
    // A corner tile is not a scene size. Writing it is what blacks the app
    // when the card is pulled back out.
    if (CGRectGetWidth(frame) < 80.0 || CGRectGetHeight(frame) < 80.0) return;
    _contentScale = [DSPreferences sharedPreferences].scale;
    [self rememberCardFitSize:frame];
    BOOL sizeChanged = fabs(CGRectGetWidth(_stageFrame) - CGRectGetWidth(frame)) > 1.0 ||
                       fabs(CGRectGetHeight(_stageFrame) - CGRectGetHeight(frame)) > 1.0 ||
                       CGRectIsEmpty(_stageFrame);
    _stageFrame = frame;
    _matchCardFrame = YES;
    if (DSSceneWriteWouldTrap()) {
        [self layoutHostView];
        if (sizeChanged) [self scheduleSettledCardSizeDelivery];
        return;
    }
    if (_appViewController) {
        [self setContentReferenceSizeOnAppView];
        [self forceSceneGeometry];
    } else if (_scene) {
        [self registerOverride];
        [self pushSettings];
    }
    [self layoutHostView];
    if (sizeChanged) [self scheduleSettledCardSizeDelivery];
}

- (void)clampOversizedSubviewsOf:(UIView *)view depth:(NSInteger)depth {
    if (!view || depth > 6) return;
    CGRect bounds = view.bounds;
    if (CGRectIsEmpty(bounds)) return;
    for (UIView *subview in view.subviews) {
        // A video layer is larger than the card on purpose. Forcing its frame
        // while it is playing is what safe-modes SpringBoard, Safari included.
        if (DSViewIsMediaSurface(subview)) continue;
        // The scene presentation's setFrame: waits on the client. Clamping it
        // while a conversation is pushing never returns.
        if (DSViewIsScenePresentation(subview)) continue;
        BOOL oversized = CGRectGetWidth(subview.bounds) > CGRectGetWidth(bounds) + 2.0 ||
                         CGRectGetHeight(subview.bounds) > CGRectGetHeight(bounds) + 2.0;
        BOOL hanging = CGRectGetMaxX(subview.frame) > CGRectGetWidth(bounds) + 2.0 ||
                       CGRectGetMaxY(subview.frame) > CGRectGetHeight(bounds) + 2.0 ||
                       subview.frame.origin.x < -2.0 || subview.frame.origin.y < -2.0;
        NSString *subName = NSStringFromClass(object_getClass(subview));
        BOOL keyboardPiece = [subName rangeOfString:@"Keyboard"].location != NSNotFound ||
                             [subName rangeOfString:@"TextEffects"].location != NSNotFound ||
                             [subName rangeOfString:@"InputSet"].location != NSNotFound;
        if (keyboardPiece) {
            subview.clipsToBounds = NO;
            subview.layer.masksToBounds = NO;
            [self clampOversizedSubviewsOf:subview depth:depth + 1];
            continue;
        }
        if (oversized || hanging) {
            subview.transform = CGAffineTransformIdentity;
            subview.frame = bounds;
            subview.clipsToBounds = YES;
            subview.layer.masksToBounds = YES;
        }
        [self clampOversizedSubviewsOf:subview depth:depth + 1];
    }
}

- (BOOL)sceneFrameIsLargerThanStage {
    FBScene *scene = [self appViewScene];
    if (!scene || ![scene respondsToSelector:@selector(settings)]) return NO;
    FBSSceneSettings *settings = scene.settings;
    if (!settings) return NO;
    CGRect got = settings.frame;
    CGRect want = [self frameForScene];
    if (CGRectIsEmpty(got) || CGRectIsEmpty(want)) return NO;
    return CGRectGetWidth(got) > CGRectGetWidth(want) + 24.0 ||
           CGRectGetHeight(got) > CGRectGetHeight(want) + 24.0;
}

// The launch transaction finishes after we return and puts the full display back.
// Correct that once it has landed. Do not start another transaction: that is the flicker.
// One write at a time. A write on every layout is what blanked the card.
- (void)scheduleCardSizeFit {
    if (_cardFitPending || _cardFitAttempts >= 4) return;
    _cardFitPending = YES;
    NSTimeInterval delay = (_cardFitAttempts == 0 && _cardFitWaits == 0) ? 0.05 : 0.35;
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_cardFitPending = NO;
        if (!strongSelf->_appViewController) {
            if (strongSelf->_cardFitWaits < 12) {
                strongSelf->_cardFitWaits += 1;
                [strongSelf scheduleCardSizeFit];
            }
            return;
        }
        // The home swipe is still a scene transition. Retry after it, and do
        // not count those waits as failed fits.
        if (DSAvoidSceneLifecycle()) {
            if (strongSelf->_cardFitWaits < 12) {
                strongSelf->_cardFitWaits += 1;
                [strongSelf scheduleCardSizeFit];
            }
            return;
        }
        // No scene yet, or the launch transaction has not re-pinned the full
        // display yet. Look again. Once a fit has landed, a card-sized scene
        // stops this.
        if (![strongSelf sceneFrameIsLargerThanStage]) {
            if (strongSelf->_cardFitAttempts == 0 && strongSelf->_cardFitWaits < 4) {
                strongSelf->_cardFitWaits += 1;
                [strongSelf scheduleCardSizeFit];
            }
            return;
        }
        if (strongSelf->_cardFitAttempts >= 4) return;
        strongSelf->_cardFitAttempts += 1;
        strongSelf->_cardFitWaits = 0;
        if (!strongSelf->_cardFitNoted) {
            strongSelf->_cardFitNoted = YES;
            DSDiagnosticsRecordFormat(@"SpringBoard: fitting %@'s scene to the card",
                                      strongSelf->_bundleIdentifier);
        }
        [strongSelf setContentReferenceSizeOnAppView];
        [strongSelf forceSceneGeometry];
        [strongSelf layoutHostView];
        if ([strongSelf sceneFrameIsLargerThanStage]) [strongSelf scheduleCardSizeFit];
    });
}

- (void)rememberCardFitSize:(CGRect)frame {
    CGFloat width = CGRectGetWidth(frame);
    CGFloat height = CGRectGetHeight(frame);
    if (fabs(width - _cardFitWidth) < 24.0 && fabs(height - _cardFitHeight) < 24.0) return;
    _cardFitWidth = width;
    _cardFitHeight = height;
    _cardFitAttempts = 0;
    _cardFitWaits = 0;
    _cardFitNoted = NO;
}

- (void)scheduleSizeCorrection {
    [self scheduleCardSizeFit];
}

// The app view's own idea of how big the app is. It is the size the app view then
// puts into the scene, so it has to be set before each transaction rather than
// corrected after one.
- (void)setContentReferenceSizeOnAppView {
    if (DSSceneWriteWouldTrap()) return;
    SBAppViewController *controller = _appViewController;
    CGRect frame = [self logicalFrame];
    if (CGRectIsEmpty(frame) || !controller) return;
    @try {
        // 4.5.805: the two-argument form does not exist on 16.5.1 (arch799); only the real three-argument selector.
        SEL both = NSSelectorFromString(@"setContentReferenceSize:withContentOrientation:andContainerOrientation:");
        if ([controller respondsToSelector:both]) {
            ((void (*)(id, SEL, CGSize, long long, long long))objc_msgSend)(controller, both, frame.size,
                                                                            (long long)UIInterfaceOrientationPortrait,
                                                                            (long long)UIInterfaceOrientationPortrait);
        }
    } @catch (NSException *exception) {
    }
}

- (void)forceSceneGeometry {
    DSTraceFormat(@"force geometry %@ depth=%ld frame=%@",
                  _bundleIdentifier ?: @"?",
                  (long)DSSceneSettingsUpdateDepth,
                  NSStringFromCGRect([self frameForScene]));
    if (DSAvoidSceneLifecycle() || DSSceneSettingsUpdateDepth > 0) return;
    FBScene *scene = [self appViewScene];
    if (!scene) return;
    _scene = scene;
    [self registerGeometryOnlyOverride];

    CGRect frame = [self frameForScene];
    UIEdgeInsets insets = [self insetsForScene];
    CGFloat statusBar = _phoneSize ? [self phoneSize688StatusBarHeight] : 0.0;
    NSString *sceneIdentifier = [scene respondsToSelector:@selector(identifier)] ? scene.identifier : nil;
    BOOL statusBarTouched = statusBar > 0.0 || DSPhoneSize688HasStatusBarOriginal(sceneIdentifier);
    // 4.5.748 geo748: the hosted scene's geometry is written only when it
    // changes. Every write is a scene update round trip, and each one landing
    // during a card move was what the appview670 / hold740 holds had to catch.
    // Skipped only when the scene already has this exact frame and the last
    // write from here had the same frame, insets and status bar. Messages is
    // exempt (unchanged). Off: geo748-off / core748-off (crash latch geo748).
    @try {
        if (DSFeature699On("core748") && DSFeature699On("geo748") && sceneIdentifier.length &&
            [sceneIdentifier rangeOfString:@"MobileSMS"].location == NSNotFound) {
            static NSMutableDictionary<NSString *, NSString *> *last748 = nil;
            if (!last748) last748 = [NSMutableDictionary dictionary];
            NSString *want = [NSString stringWithFormat:@"%@|%@|%.1f", NSStringFromCGRect(frame), NSStringFromUIEdgeInsets(insets), statusBar];
            CGRect have = CGRectNull;
            id settings = [scene respondsToSelector:@selector(settings)] ? scene.settings : nil;
            id value = settings ? [settings valueForKey:@"frame"] : nil;
            if ([value isKindOfClass:NSValue.class]) have = [value CGRectValue];
            if ([last748[sceneIdentifier] isEqualToString:want] && !CGRectIsNull(have) && CGRectEqualToRect(have, frame)) {
                DSFeature719MarkAction("geo748");
                static CFAbsoluteTime saidAt = 0;
                CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
                if (t - saidAt > 5.0 || t < saidAt) {
                    saidAt = t;
                    DSDiagnosticsRecordFormat(@"SpringBoard: geo748 %@ geometry unchanged %@: no scene write", _bundleIdentifier ?: @"?", NSStringFromCGRect(frame));
                }
                return;
            }
            last748[sceneIdentifier] = want;
        }
    } @catch (NSException *exception) {
    }
    DSUpdateSceneSettings(scene, ^(FBSMutableSceneSettings *settings) {
        DSApplyGeometry(settings, frame, insets);
        // 4.5.688 mode=statusbar (or putting the original height back).
        if (statusBarTouched) DSPhoneSize688ApplyStatusBar(settings, sceneIdentifier, statusBar);
    });
}

// 4.5.757 msgfit757: the app reported phone-size geometry while the scene
// says card size. Re-send the frame with a 1 pt nudge then the real frame so
// the client receives a diff. At most once per 3 s, 3 times per card fit size.
- (void)msgfit757Nudge {
    static CFAbsoluteTime at = 0;
    static NSInteger count = 0;
    static NSString *lastFor = nil;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - at < 3.0 && now >= at) return;
    if (![lastFor isEqualToString:_bundleIdentifier ?: @""]) { lastFor = [_bundleIdentifier ?: @"" copy]; count = 0; }
    if (count >= 3) return;
    if (DSAvoidSceneLifecycle() || DSSceneSettingsUpdateDepth > 0) return;
    FBScene *scene = [self appViewScene];
    if (!scene) return;
    CGRect frame = [self frameForScene];
    if (CGRectGetWidth(frame) < 50.0 || CGRectGetHeight(frame) < 50.0) return;
    if (_phoneSize || CGRectGetWidth(frame) >= CGRectGetWidth(UIScreen.mainScreen.bounds) - 1.0) return; // phone-size scenes are meant to be
    at = now; count += 1;
    UIEdgeInsets insets = [self insetsForScene];
    CGRect nudge = frame; nudge.size.height -= 1.0;
    DSDiagnosticsRecordFormat(@"SpringBoard: msgfit757 %@ reports phone-size keyboard geometry but its scene is %@: re-sending the card frame (%ld)",
                              _bundleIdentifier ?: @"?", NSStringFromCGRect(frame), (long)count);
    DSUpdateSceneSettings(scene, ^(FBSMutableSceneSettings *settings) { DSApplyGeometry(settings, nudge, insets); });
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || DSSceneSettingsUpdateDepth > 0) return;
        FBScene *sc = [strongSelf appViewScene];
        if (!sc) return;
        CGRect f = [strongSelf frameForScene];
        UIEdgeInsets in = [strongSelf insetsForScene];
        DSUpdateSceneSettings(sc, ^(FBSMutableSceneSettings *settings) { DSApplyGeometry(settings, f, in); });
    });
}

- (FBScene *)appViewScene {
    SBAppViewController *controller = _appViewController;
    if (!controller) return nil;
    @try {
        id handle = DSIvar(controller, @"_sceneHandle");
        if (!handle && [controller respondsToSelector:@selector(sceneHandle)]) handle = controller.sceneHandle;
        // 4.5.799: register as soon as the handle first appears.
        if (handle && DSReg799On() && _reg799Handle != handle) [self reg799TryRegister];
        if ([handle respondsToSelector:@selector(scene)]) {
            return ((FBScene * (*)(id, SEL))objc_msgSend)(handle, @selector(scene));
        }
    } @catch (NSException *exception) {
    }
    return nil;
}

// Geometry only, never lifecycle: an app view controller of the stage's own making
// is outside SpringBoard's scene layout, and telling its scene it is foreground
// behind SpringBoard's back is what makes it assert.
- (void)registerGeometryOnlyOverride {
    // 4.5.657: an app killed from the switcher gets no geometry back.
    if (DSSceneHostBundleDiedPending(_bundleIdentifier)) return;
    NSString *identifier = [_scene respondsToSelector:@selector(identifier)] ? _scene.identifier : nil;
    if (identifier.length == 0) return;
    [DSSceneOverridesLock() lock];
    NSMutableDictionary *override = [@{
        @"frame" : [NSValue valueWithCGRect:[self frameForScene]],
        @"insets" : [NSValue valueWithUIEdgeInsets:[self insetsForScene]],
        @"geometryOnly" : @YES,
    } mutableCopy];
    CGFloat statusBar = _phoneSize ? [self phoneSize688StatusBarHeight] : 0.0;
    if (statusBar > 0.0) override[@"statusBar"] = @(statusBar);
    if (_staysBackgrounded) override[@"staysBackgrounded"] = @YES;
    // 4.5.799: so applyOverrides can re-add the occlusion reason.
    if (DSReg799On()) {
        NSString *r = [self reg799Identifier];
        if (r.length) override[@"reg799Reason"] = r;
    }
    DSSceneOverrides()[identifier] = override;
    DSSceneOverrideCountValue = (NSInteger)DSSceneOverrides().count;
    [DSSceneOverridesLock() unlock];
    _registeredOverride = YES;
}

// The app view controller asserts in dealloc if it is released while still showing
// a live app, so it is stood down in order first.
- (void)tearDownAppViewController {
    if (_rk814) {
        // 4.5.814: the app view goes; Messages is told it is not phone-size.
        _rk814 = NO;
        _phoneSize = NO;
        if (_rk814Mask && _hostView.layer.mask == _rk814Mask) _hostView.layer.mask = nil;
        _rk814Mask = nil;
        UIView *p814 = _hostView.superview;
        if ([p814.superview isKindOfClass:DSStageContainerView.class]) ((DSStageContainerView *)p814.superview).realKb814Unclipped = NO;
        if (DSRK814Host == self) DSRK814Host = nil;
        DSRK814Publish(0, @"app view torn down");
    }
    _rk814Failed = NO;
    _rk814FailWhy = nil;
    [self reg799Unregister];
    [self phoneSize690RemoveStrip:@"app view torn down"];
    DSClose741Note(_bundleIdentifier);
    [self phoneSize696SetKeysSceneID:nil];
    [self restoreOwnedStrayPresentations];
    _straySweepScheduled = NO;
    [self bg719Release:@"left the stage"];
    [self releaseRunningAssertion];
    SBAppViewController *controller = _appViewController;
    _appViewController = nil;
    _entity = nil;
    _deliveredOnce = NO;
    // 4.5.675: a new app view starts at the card size.
    if (_phoneSize) {
        _phoneSize = NO;
        _phoneSizeGeneration += 1;
        _phoneSizeParentClipped = NO;
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize675 %@ OFF (app view torn down)", _bundleIdentifier ?: @"?");
    }
    _phoneSizeNudging = NO;
    [self phoneSize676ReleaseHold:@"app view torn down" animated:NO];
    _cardFitPending = NO;
    _cardFitNoted = NO;
    _cardFitAttempts = 0;
    _cardFitWaits = 0;
    _deliveredWidth = 0;
    _deliveredHeight = 0;
    if (!controller) return;

    [DSOwnedAppViewControllers() removeObject:controller];
    _followsSystemHome = NO;
    @try {
        if ([controller respondsToSelector:@selector(_setCurrentMode:)]) [controller _setCurrentMode:0];
        if ([controller respondsToSelector:@selector(invalidate)]) [controller invalidate];
        [controller willMoveToParentViewController:nil];
        [controller.view removeFromSuperview];
        [controller removeFromParentViewController];
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: putting %@'s app view away threw %@",
                                  _bundleIdentifier, exception.name ?: @"?");
    }
}

#pragma mark - Launching

- (void)prepareWithCompletion:(DSSceneHostReadyBlock)completion {
    if (![self application]) {
        DSDiagnosticsRecordFormat(@"SpringBoard: SpringBoard has no application called %@", _bundleIdentifier);
        if (completion) completion(NO);
        return;
    }

    // 4.0: one path only — SpringBoard's SBAppViewController, the same mechanism
    // the app switcher uses. Raw FBScene hosting and "make your own scene" paths
    // were removed: they fought keyboard focus, duplicated lifecycle, and failed
    // on cold launches in different ways every time.
    if ([self hostThroughAppViewController]) {
        if (completion) completion(YES);
        return;
    }

    [self launchThroughUIApplication];
    [self waitForAppViewWithAttemptsRemaining:50 completion:completion];
}

- (void)waitForAppViewWithAttemptsRemaining:(NSInteger)attempts
                                 completion:(DSSceneHostReadyBlock)completion {
    if ([self hostThroughAppViewController]) {
        if (completion) completion(YES);
        return;
    }
    if (attempts <= 0) {
        DSDiagnosticsRecordFormat(@"SpringBoard: %@ never got an app view (process %@)",
                                  _bundleIdentifier,
                                  self.isProcessAlive ? @"running" : @"not running");
        if (completion) completion(NO);
        return;
    }
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf waitForAppViewWithAttemptsRemaining:attempts - 1 completion:completion];
    });
}

// Each attempt either finishes the job on the spot or gives the app another two
// seconds to show up with a scene before the next one is tried.
- (void)runLaunchAttempts:(NSMutableArray<DSSceneHostAttempt> *)attempts
               completion:(DSSceneHostReadyBlock)completion {
    if (attempts.count == 0) {
        // Whether the app is running decides which half of this failed, so it is
        // worth one line: a process that is alive but sceneless is a different
        // problem from one that never started. What SpringBoard was willing to say
        // about the app goes with it, because on a device that cannot hand over a
        // crash log this is the only way to learn which door was the locked one.
        DSDiagnosticsRecordFormat(@"SpringBoard: %@ never produced a scene to put on the stage (process %@)",
                                  _bundleIdentifier,
                                  self.isProcessAlive ? @"is running" : @"is not running");
        [self recordSceneLookupInventory];
        if (completion) completion(NO);
        return;
    }

    DSSceneHostAttempt attempt = attempts.firstObject;
    [attempts removeObjectAtIndex:0];
    BOOL finished = NO;
    @try {
        finished = attempt();
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: launching %@ threw %@", _bundleIdentifier, exception.name ?: @"?");
    }
    if (finished) {
        if (completion) completion(self.isHosting);
        return;
    }

    __weak __typeof(self) weakSelf = self;
    [self waitForSceneWithAttemptsRemaining:40 then:^{
        [weakSelf runLaunchAttempts:attempts completion:completion];
    } completion:completion];
}

- (void)launchThroughUIApplication {
    SpringBoard *springBoard = (SpringBoard *)UIApplication.sharedApplication;
    if (![springBoard respondsToSelector:@selector(launchApplicationWithIdentifier:suspended:)]) {
        DSDiagnosticsRecord(@"SpringBoard: this build has no launchApplicationWithIdentifier:suspended:");
        return;
    }
    // Suspended, so SpringBoard does not run a front-app transition; the scene is
    // forced foreground once it exists.
    [springBoard launchApplicationWithIdentifier:_bundleIdentifier suspended:YES];
}



#pragma mark - A scene of the stage's own


// Written down only when every way in has failed, and the point of it is the next
// build: it names what this version of SpringBoard has to offer for this app, so
// the path that was missing can be taken rather than guessed at.
- (void)recordSceneLookupInventory {
    NSMutableArray<NSString *> *notes = [NSMutableArray array];
    @try {
        SBApplication *application = [self application];
        SEL base = NSSelectorFromString(@"_baseSceneIdentifier");
        if ([application respondsToSelector:base]) {
            NSString *identifier = ((NSString * (*)(id, SEL))objc_msgSend)(application, base);
            [notes addObject:[NSString stringWithFormat:@"base scene id %@", identifier.length > 0 ? identifier : @"(empty)"]];
        } else {
            [notes addObject:@"no _baseSceneIdentifier"];
        }

        unsigned int count = 0;
        Method *methods = class_copyMethodList([application class], &count);
        NSMutableArray<NSString *> *sceneMethods = [NSMutableArray array];
        for (unsigned int i = 0; i < count && sceneMethods.count < 14; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            if ([name rangeOfString:@"cene"].location == NSNotFound) continue;
            if ([name rangeOfString:@":"].location != NSNotFound) continue;
            [sceneMethods addObject:name];
        }
        free(methods);
        [notes addObject:[NSString stringWithFormat:@"app offers %@",
                          sceneMethods.count > 0 ? [sceneMethods componentsJoinedByString:@" "] : @"nothing scene shaped"]];

        NSArray *live = DSLiveScenes().keyEnumerator.allObjects;
        [notes addObject:[NSString stringWithFormat:@"%lu scenes seen, ending %@",
                          (unsigned long)live.count,
                          live.count > 0 ? [live subarrayWithRange:NSMakeRange(live.count - MIN(live.count, (NSUInteger)3), MIN(live.count, (NSUInteger)3))] : @[]]];
    } @catch (NSException *exception) {
        [notes addObject:[NSString stringWithFormat:@"inventory threw %@", exception.name ?: @"?"]];
    }

    NSString *line = [notes componentsJoinedByString:@"; "];
    if (line.length > 700) line = [line substringToIndex:700];
    DSDiagnosticsRecordFormat(@"SpringBoard: %@", line);
}

- (void)waitForSceneWithAttemptsRemaining:(NSInteger)attempts
                                     then:(void (^)(void))next
                               completion:(DSSceneHostReadyBlock)completion {
    FBScene *scene = [self resolveScene];
    if (scene) {
        _scene = scene;
        [self beginHosting];
        if (completion) completion(self.isHosting);
        return;
    }

    if (attempts <= 0) {
        if (next) next();
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self waitForSceneWithAttemptsRemaining:attempts - 1 then:next completion:completion];
    });
}

#pragma mark - Hosting

- (void)beginHosting {
    // 4.5.809: FBScene hostManagerForRequester: / hostViewForRequester:enableAndOrderFront:
    // do not exist on 20F75, so this path only ever logged and returned. The
    // app-view path does the hosting.
    if (!_scene || _hostView) return;
    DSDiagnosticsRecord(@"SpringBoard: this build's scenes cannot be hosted by a requester");
}

- (BOOL)isHosting {
    return _hostView != nil;
}

- (void)noteHostViewAttached {
    SBAppViewController *controller = _appViewController;
    if (!controller || !self.parentViewController) return;
    @try {
        [controller didMoveToParentViewController:self.parentViewController];
    } @catch (NSException *exception) {
    }
}

// 4.5.741 close741: the app whose card was just torn down (and its phone-size
// mode switched off), so the kept-card guard does not refit another card when
// that closing app sends its last scene update.
static NSString *DSClose741Bundle = nil;
static CFAbsoluteTime DSClose741At = 0;
void DSClose741Note(NSString *bundle) {
    if (bundle.length == 0) return;
    DSClose741Bundle = [bundle copy];
    DSClose741At = CFAbsoluteTimeGetCurrent();
}
BOOL DSClose741Recent(NSString *sceneIdentifier) {
    if (!DSFeature699On("close741") || !DSClose741Bundle || sceneIdentifier.length == 0) return NO;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - DSClose741At > 1.2 || now < DSClose741At) return NO;
    return [sceneIdentifier rangeOfString:DSClose741Bundle].location != NSNotFound;
}

// 4.5.740 kbguard740: the hosted scene's deactivation reasons (-1 unknown).
- (long long)sceneDeactivationReasons740 {
    @try {
        id scene = [self hostedScene];
        id settings = [scene respondsToSelector:@selector(settings)] ? ((id (*)(id, SEL))objc_msgSend)(scene, @selector(settings)) : nil;
        if ([settings respondsToSelector:@selector(deactivationReasons)]) {
            return ((long long (*)(id, SEL))objc_msgSend)(settings, @selector(deactivationReasons));
        }
    } @catch (NSException *exception) {
    }
    return -1;
}

- (FBScene *)hostedScene {
    if (_appViewController) {
        FBScene *scene = [self appViewScene];
        if (scene) return scene;
    }
    return _scene;
}

#pragma mark - Geometry

// The size the app is created at. Set before the app view exists, so Messages
// and the rest lay out for the card instead of the whole screen.
- (void)noteLaunchFrame:(CGRect)frame {
    if (CGRectIsEmpty(frame)) return;
    _contentScale = [DSPreferences sharedPreferences].scale;
    _stageFrame = frame;
    [self rememberCardFitSize:frame];
    // The app view's launch transaction puts the full display back after this
    // returns. The card size has to be written again once that scene exists.
    [self scheduleCardSizeFit];
}

- (void)setStageFrame:(CGRect)frame safeAreaInsets:(UIEdgeInsets)insets {
    if (_revealingTallContent) {
        [self layoutHostView];
        return;
    }
    _contentScale = [DSPreferences sharedPreferences].scale;
    [self rememberCardFitSize:frame];
    _stageFrame = frame;
    _safeAreaInsets = insets;
    [self layoutHostView];

    if (_appViewController) {
        [self deliverStageSizeToApp];
        [self nudgeStageSizeWhileAppStarts];
        return;
    }

    [self registerOverride];
    [self pushSettings];
}

// One follow-up, and only while the app has not drawn yet. A stream of scene
// transactions after that is the flicker on the way in.
- (void)nudgeStageSizeWhileAppStarts {
    if (_nudgedThisLaunch) return;
    _nudgedThisLaunch = YES;

    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->_appViewController) return;
        if ([strongSelf appViewIsShowingContent]) return;
        [strongSelf.hostView setNeedsLayout];
        [strongSelf.hostView layoutIfNeeded];
        strongSelf->_deliveredOnce = NO;
        [strongSelf deliverStageSizeToApp];
    });
}

- (CGSize)cameraTallSize {
    CGSize screen = UIScreen.mainScreen.bounds.size;
    CGFloat width = MIN(screen.width, screen.height);
    CGFloat height = MAX(screen.width, screen.height);
    if (width < 200.0 || height < 300.0) return CGSizeMake(430.0, 932.0);
    return CGSizeMake(width, height);
}

- (BOOL)isCameraTall {
    return _cameraTall;
}

// 4.5.668 sbcam668. On: the scene gets the phone's size and the host view
// shows it at the card's width, bottom-aligned (the card clips the top), the
// way the app's own camera is laid out full screen. Off: back to the card.
// Geometry only (the same writes as a card resize); never lifecycle.
- (void)setCameraTall:(BOOL)tall why:(NSString *)why {
    if (tall == _cameraTall) return;
    if (tall && (_revealingTallContent || !_appViewController || !_hostView.superview)) return;
    UIView *parent = _hostView.superview;
    if (tall && (parent.tag == 9158 || CGRectGetWidth(parent.bounds) < 80.0 || CGRectGetHeight(parent.bounds) < 80.0)) return;
    // 4.5.675: the camera layout wins over phonesize675. Drop the phone-size
    // state here (no write of its own); the camera write below replaces it.
    if (tall && _phoneSize) {
        _phoneSize = NO;
        _phoneSizeGeneration += 1;
        if (_phoneSizeParentClipped) {
            _phoneSizeParentClipped = NO;
            if (!_phoneSizeParentWasClipping && ![_bundleIdentifier isEqualToString:@"com.apple.mobilephone"]) {
                parent.clipsToBounds = NO;
                parent.layer.masksToBounds = NO;
            }
        }
        DSPhoneSize675ChangedAt = CACurrentMediaTime();
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize675 %@ OFF (camera layout takes over)", _bundleIdentifier ?: @"?");
    }
    _cameraTall = tall;
    _cameraTallGeneration += 1;
    CGSize phone = [self cameraTallSize];
    CGFloat cardWidth = CGRectGetWidth(parent.bounds);
    CGFloat cardHeight = CGRectGetHeight(parent.bounds);
    CGFloat scale = phone.width > 0 ? cardWidth / phone.width : 1.0;
    if (tall) {
        _cameraTallParentWasClipping = parent.clipsToBounds;
        _cameraTallParentClipped = YES;
        parent.clipsToBounds = YES;
        parent.layer.masksToBounds = YES;
    } else if (_cameraTallParentClipped) {
        _cameraTallParentClipped = NO;
        if (parent && !_cameraTallParentWasClipping && ![_bundleIdentifier isEqualToString:@"com.apple.mobilephone"]) {
            parent.clipsToBounds = NO;
            parent.layer.masksToBounds = NO;
        }
    }
    DSDiagnosticsRecordFormat(@"SpringBoard: sbcam669 %@ phone-size camera layout %@ (%@): scene %.0fx%.0f shown at x%.3f, "
                              @"card %.0fx%.0f, visible part y=%.0f..%.0f of the app",
                              _bundleIdentifier ?: @"?", tall ? @"ON" : @"OFF", why ?: @"?",
                              tall ? phone.width : CGRectGetWidth([self logicalFrame]),
                              tall ? phone.height : CGRectGetHeight([self logicalFrame]),
                              tall ? scale : 1.0, cardWidth, cardHeight,
                              tall ? MAX(0.0, phone.height - cardHeight / MAX(scale, 0.01)) : 0.0,
                              tall ? phone.height : cardHeight);
    [self layoutHostView];
    // The size goes to the app the same way a card resize does: one
    // transaction, then the geometry write. Deferred while a write would trap.
    _deliveredOnce = NO;
    [self deliverStageSizeToApp];
    [self layoutHostView];
}

- (CGRect)logicalFrame {
    if (_cameraTall) {
        CGSize phone = [self cameraTallSize];
        return CGRectMake(CGRectGetMinX(_stageFrame), CGRectGetMinY(_stageFrame), phone.width, phone.height);
    }
    if (_phoneSize) {
        CGSize phone = [self phoneSize675SceneSize];
        CGFloat width = phone.width - ((_phoneSizeNudging && _phoneSizeNudgeWidth) ? 2.0 : 0.0);
        CGFloat height = phone.height - ((_phoneSizeNudging && !_phoneSizeNudgeWidth) ? 1.0 : 0.0);
        return CGRectMake(CGRectGetMinX(_stageFrame), CGRectGetMinY(_stageFrame), width, height);
    }
    CGFloat scale = _contentScale > 0 ? _contentScale : 1.0;
    return CGRectMake(CGRectGetMinX(_stageFrame),
                      CGRectGetMinY(_stageFrame),
                      CGRectGetWidth(_stageFrame) * scale,
                      CGRectGetHeight(_stageFrame) * scale);
}

// ---- 4.5.675 phonesize675 --------------------------------------------------
// The phone's portrait size, one point short of the bottom edge. A scene that
// reaches the screen's bottom edge is one iOS may host the keyboard inside
// (see frameForScene); 1 pt changes nothing the app can see in its layout.
- (CGSize)phoneSize675SceneSize {
    CGSize phone = [self cameraTallSize];
    CGFloat height = phone.height - 1.0;
    // 4.5.684 mode=short: the scene ends at the keyboard top (931 - K).
    // 4.5.685: the scene ends slack pt below the bar line (620 = 586 + 34).
    // 4.5.688 offset/short: the scene is o pt shorter (931 - o).
    if (_phoneSize && _ps684Active && _ps688Active && !_ps685Active && !_cameraTall &&
        (_ps688Mode == DSPhoneSize688ModeOffset || _ps688Mode == DSPhoneSize688ModeShort)) height = phone.height - 1.0 - [self phoneSize688O];
    else if (_phoneSize && _ps684Active && _ps685Active && _ps685Slack >= 0.0 && !_cameraTall) height = [self phoneSize684Pin] + _ps685Slack;
    else if (_phoneSize && _ps684Active && _ps684Short && !_cameraTall) height = [self phoneSize684Pin];
    // 4.5.679: the width is fixed at the switch; before it, what a switch now would use.
    if (_phoneSize && _phoneSizeWidth >= 100.0) return CGSizeMake(_phoneSizeWidth, height);
    return CGSizeMake([self phoneSize679WidthForNow:NULL], height);
}

// 4.5.679: the scene width for a switch made now.
- (CGFloat)phoneSize679WidthForNow:(NSString **)mode {
    CGSize phone = [self cameraTallSize];
    if (DSPhoneSize680Enabled()) {
        if (mode) *mode = @"phone width, scaled to the card (4.5.680 always full screen; the 679 scale file is ignored)";
        return phone.width;
    }
    BOOL phoneMode = NO;
    CGFloat scale = DSPhoneSize679Scale(&phoneMode);
    if (phoneMode) {
        if (mode) *mode = @"phone width, scaled to the card (file: phone)";
        return phone.width;
    }
    CGFloat cardW = CGRectGetWidth(_hostView.superview.bounds);
    if (!isfinite(cardW) || cardW < 80.0) cardW = CGRectGetWidth(_stageFrame);
    if (!isfinite(cardW) || cardW < 80.0) {
        if (mode) *mode = @"no card width yet: phone width";
        return phone.width;
    }
    if (!isfinite(scale) || scale < 0.80 || scale > 1.00) scale = 1.0;
    CGFloat width = round(cardW / scale);
    width = MAX(200.0, MIN(phone.width / 0.80, width));
    if (mode) *mode = fabs(scale - 1.0) < 0.0005 ? @"card width, scale 1.0 (default)"
                                                 : [NSString stringWithFormat:@"card width / %.3f (file)", scale];
    return width;
}

- (BOOL)isPhoneSize675 {
    if (_rk814) return NO;   // 4.5.814: realkb814's phone size is not a 675 session (the stage leaves it alone)
    return _phoneSize;
}

// The safe area the scene is given: the screen's own while phone-size (what
// the app gets full screen), otherwise the card's (the 4.5.674 value).
- (UIEdgeInsets)insetsForScene {
    if (_rk814 && _phoneSize) return _rk814Insets;   // 4.5.814 realkb814
    if (!_phoneSize) return _safeAreaInsets;
    if ([self isPhoneSize684]) return [self phoneSize684Insets];
    UIEdgeInsets insets = _phoneSizeInsets;
    if (_phoneSizeNudging && !_phoneSizeNudgeWidth) insets.bottom += 1.0;
    return insets;
}

- (UIEdgeInsets)phoneSize675ScreenInsets {
    UIEdgeInsets insets = UIEdgeInsetsZero;
    @try {
        UIWindow *window = UIApplication.sharedApplication.windows.firstObject;
        if (window) insets = window.safeAreaInsets;
    } @catch (NSException *exception) {
    }
    // The SpringBoard window can answer before it is laid out. A notch or
    // island phone of this size has a top inset; never hand the app zero.
    if (insets.top < 1.0 && insets.bottom < 1.0) {
        CGSize phone = [self cameraTallSize];
        if (phone.height >= 800.0) insets = UIEdgeInsetsMake(59.0, 0.0, 34.0, 0.0);
    }
    insets.left = 0.0;
    insets.right = 0.0;
    return insets;
}

// Scene y that sits on the card's bottom edge: the keyboard's top (plus the
// test offset), kept where the host still covers the whole card.
- (CGFloat)phoneSize675PinForCardHeight:(CGFloat)cardHeight fit:(CGFloat)fit {
    CGSize phone = [self phoneSize675SceneSize];
    CGFloat pin = _phoneSizeKeyTop + DSPhoneSize675PinOffset();
    // 4.5.683: the card always shows the bottom of the scene (the app's bar
    // and, while it is up, its own keyboard). Nothing moves for the keyboard.
    BOOL ps683 = [self isPhoneSize683];
    if (ps683) pin = phone.height;
    // 4.5.684: fixed, keyboard up or down: the app's bar bottom (931 - K).
    if ([self isPhoneSize684]) pin = [self phoneSize684Pin];
    // 4.5.686: the card bottom shows margin pt below the bar line.
    if ([self isPhoneSize685]) pin = [self phoneSize684Pin] + MAX(0.0, _ps685Margin);
    // 4.5.687: the card bottom is margin pt under the raised bar line.
    if ([self isPhoneSize687]) pin = [self phoneSize687Bar] + MAX(0.0, _ps687Margin);
    // 4.5.688 offset/short: host y of the keyboard line (window 586 - o, plus where
    // the picture sits in the host when the scene origin moves it).
    if ([self isPhoneSize688Geo]) pin = [self phoneSize688Line] + [self phoneSize688Shift];
    if (_ps683Logged != (ps683 ? 1 : 2)) {
        _ps683Logged = ps683 ? 1 : 2;
        if (ps683 || _phoneSize) {
            CGFloat lo = fit > 0.01 ? cardHeight / fit : phone.height;
            DSDiagnosticsRecordFormat(@"SpringBoard: phonesize683 %@ %@", _bundleIdentifier ?: @"?",
                                      ps683 ? [NSString stringWithFormat:@"window pinned to the scene bottom: card shows app y %.0f..%.0f of %.0fx%.0f at x%.4f, always (keyboard up or down); the app's own keyboard rises inside the card",
                                               phone.height - lo, phone.height, phone.width, phone.height, fit]
                                           : @"not in 683 mode (off file, camera, dylib or not allowlisted): 4.5.682 window rules");
        }
    }
    CGFloat lowest = fit > 0.01 ? cardHeight / fit : phone.height;
    if (pin < lowest) pin = lowest;
    if (pin > phone.height) pin = phone.height;
    return pin;
}

- (NSString *)phoneSize675PlacementSummary {
    UIView *parent = _hostView.superview;
    CGSize phone = [self phoneSize675SceneSize];
    CGFloat width = CGRectGetWidth(parent.bounds);
    CGFloat height = CGRectGetHeight(parent.bounds);
    CGFloat fit = [self phoneSize675FitForWidth:width height:height];
    CGFloat pin = [self phoneSize675PinForCardHeight:height fit:fit];
    CGRect cardOnScreen = parent ? [parent convertRect:parent.bounds toView:nil] : CGRectZero;
    return [NSString stringWithFormat:@"scene %.0fx%.0f safeArea %@ shown at x%.4f in card %@ (screen %@); "
            @"keyboard top y=%.0f%@ -> visible part of the app y=%.0f..%.0f; card point (x,y) = app point (x/%.4f, %.0f + y/%.4f)",
            phone.width, phone.height, NSStringFromUIEdgeInsets(_phoneSizeInsets), fit,
            NSStringFromCGSize(CGSizeMake(width, height)), NSStringFromCGRect(cardOnScreen),
            _phoneSizeKeyTop,
            fabs(DSPhoneSize675PinOffset()) > 0.1 ? [NSString stringWithFormat:@" (pin offset %+.0f)", DSPhoneSize675PinOffset()] : @"",
            pin - height / MAX(fit, 0.01), pin, fit, pin - height / MAX(fit, 0.01), fit];
}

- (void)setPhoneSize675:(BOOL)on keyboardTop:(CGFloat)keyTop why:(NSString *)why {
    // 4.5.814 realkb814 owns this scene's phone size: keyboard tops are not
    // mapped (the scene is screen-aligned); an off becomes the realkb814 stop.
    if (_rk814) {
        if (!on) [self realKb814Stop:why ?: @"phone size off"];
        return;
    }
    NSString *bundle = _bundleIdentifier ?: @"?";
    UIView *parent = _hostView.superview;
    if (on) {
        NSString *skip = nil;
        if (_cameraTall) skip = @"camera layout is on";
        else if (_revealingTallContent) skip = @"card is uncovering a tall layout";
        else if (!_appViewController) skip = @"no app view yet";
        else if (!parent) skip = @"not in a card";
        else if (parent.tag == 9158 || CGRectGetWidth(parent.bounds) < 80.0 || CGRectGetHeight(parent.bounds) < 80.0) skip = @"card minimized";
        if (skip) {
            if (_phoneSize) [self setPhoneSize675:NO keyboardTop:0.0 why:skip];
            static NSString *lastSkip = nil;
            static CFAbsoluteTime lastSkipAt = 0;
            NSString *key = [NSString stringWithFormat:@"%@|%@", bundle, skip];
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (![key isEqualToString:lastSkip] || now - lastSkipAt > 5.0 || now < lastSkipAt) {
                lastSkip = key;
                lastSkipAt = now;
                DSDiagnosticsRecordFormat(@"SpringBoard: phonesize675 %@ skipped (%@), scene stays card-size", bundle, skip);
            }
            return;
        }
        if (_phoneSize && [self isPhoneSize684]) {
            // 4.5.684: the window is fixed; the keyboard top is only learned.
            [self phoneSize684NoteKeyTop:keyTop why:why];
            return;
        }
        if (_phoneSize && [self isPhoneSize683]) {
            static CFAbsoluteTime skipLogAt = 0;
            CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
            if (t - skipLogAt > 5.0 || t < skipLogAt) {
                skipLogAt = t;
                DSDiagnosticsRecordFormat(@"SpringBoard: phonesize683 %@ keyboard top %.0f (%@) ignored: the app's own keyboard is inside the card, the window stays at the scene bottom",
                                          _bundleIdentifier ?: @"?", keyTop, why ?: @"?");
            }
            return;
        }
        if (_phoneSize && DSPhoneSize680Enabled()) {
            // 4.5.680: the scene never changes for the keyboard; the card's
            // window follows the bar (min(anchor, keyboard top in the scene)).
            CGFloat sceneKeyTop = keyTop - MAX(0.0, [self cameraTallSize].height - [self phoneSize675SceneSize].height);
            CGFloat bar = MIN([self phoneSize678BottomAnchor], sceneKeyTop);
            [self phoneSize680MoveBarBottomTo:bar duration:0.2 curve:7 lag:0.0 why:why ?: @"keyboard note"];
            return;
        }
        if (_phoneSize) {
            // 4.5.678: every call here comes from the keyboard (note or early
            // switch). On a pre-grown scene the app already laid out for its
            // keyboard at the phone size; only the mapping moves.
            if (_phoneSizePreGrown) {
                _phoneSizePreGrown = NO;
                CGFloat was = _phoneSizeKeyTop;
                _phoneSizeKeyTop = keyTop;
                [self layoutHostView];
                [self phoneSize676ReleaseHold:@"keyboard arrived" animated:YES];
                DSDiagnosticsRecordFormat(@"SpringBoard: phonesize678 %@ keyboard arrived in the pre-grown phone-size scene t+%.0fms (%@): "
                                          @"the app laid out for it at %.0fx%.0f; mapping %.0f -> keyboard top %.0f: %@",
                                          bundle, DSPhoneSize676Ms(), why ?: @"?", [self phoneSize675SceneSize].width,
                                          [self phoneSize675SceneSize].height, was, keyTop, [self phoneSize675PlacementSummary]);
                // A, as a safety net: one keyboard-frame re-post once the
                // keyboard's own show animation is over.
                NSInteger generation = _phoneSizeGeneration;
                __weak __typeof(self) weakSelf = self;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [weakSelf phoneSize676Nudge:1 generation:generation attempt:0 why:@"keyboard showed in the pre-grown scene (safety)"];
                });
                return;
            }
            if (fabs(keyTop - _phoneSizeKeyTop) > 0.5) {
                CGFloat was = _phoneSizeKeyTop;
                _phoneSizeKeyTop = keyTop;
                [self layoutHostView];
                DSDiagnosticsRecordFormat(@"SpringBoard: phonesize675 %@ keyboard top %.0f -> %.0f (%@): %@",
                                          bundle, was, keyTop, why ?: @"?", [self phoneSize675PlacementSummary]);
            }
            return;
        }
    } else if (!_phoneSize) {
        return;
    } else if ([self phoneSize695KeepsAway:why]) {
        // 4.5.695: minimised / off screen; the scene stays the phone size.
        // A keyboard-down reason still closes the 684 keys-up bookkeeping
        // (what the 678 rest does for a visible 684 card in 694).
        if (_ps684KeysUp && ([why hasPrefix:@"keyboard down"] || [why hasPrefix:@"keyboard now belongs to"])) {
            [self phoneSize684KeysDown:why];
        }
        return;
    }

    NSString *ps679Mode = nil;
    _phoneSizeWidth = on ? [self phoneSize679WidthForNow:&ps679Mode] : 0.0;
    _ps679LoggedWidth = 0.0;
    _ps679LoggedFit = 0.0;
    _ps679LoggedPin = 0.0;
    _phoneSize = on;
    // 4.5.684: the session's mode, K and tune are fixed here (and at a rest-time apply).
    if (on) [self phoneSize684Configure];
    else _ps684Active = NO;
    _phoneSizeGeneration += 1;
    _phoneSizeDeferNoted = NO;
    _phoneSizeNudging = NO;
    _phoneSizePreGrown = on && _phoneSizePreGrowCall;
    if (on) {
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize679 %@ switching to %.0fx%.0f (%@)", bundle, _phoneSizeWidth,
                                  [self phoneSize675SceneSize].height, ps679Mode ?: @"?");
    } else {
        CGRect cardNow = parent ? parent.bounds : CGRectZero;
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize679 %@ back to card size %.0fx%.0f at scale 1.0 (whole card)",
                                  bundle, CGRectGetWidth(cardNow), CGRectGetHeight(cardNow));
    }
    DSPhoneSize675ChangedAt = CACurrentMediaTime();
    if (on && !_phoneSizePreGrown) [self phoneSize676HoldPicture];
    else [self phoneSize676ReleaseHold:@"switched off" animated:NO];
    if (on) {
        _phoneSizeKeyTop = keyTop;
        _phoneSizeInsets = [self phoneSize675ScreenInsets];
        if (!_phoneSizeParentClipped) {
            _phoneSizeParentWasClipping = parent.clipsToBounds;
            _phoneSizeParentClipped = YES;
        }
        BOOL realKeys684 = !_phoneSizePreGrowCall && keyTop > 250.0 && keyTop < [self phoneSize684PhoneHeight] - 100.0;
        if ([self isPhoneSize684]) _phoneSizeKeyTop = [self phoneSize684Pin];
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize675 %@ ON (%@) t+%.0fms: %@", bundle, why ?: @"keyboard up",
                                  DSPhoneSize676Ms(), [self phoneSize675PlacementSummary]);
        if ([self isPhoneSize684]) {
            DSDiagnosticsRecordFormat(@"SpringBoard: phonesize684 %@ %@", bundle, [self phoneSize684Summary]);
            if (realKeys684) [self phoneSize684NoteKeyTop:keyTop why:why ?: @"keyboard up at the switch"];
        }
    } else {
        if (_phoneSizeParentClipped) {
            _phoneSizeParentClipped = NO;
            if (parent && !_phoneSizeParentWasClipping && !_cameraTall &&
                ![_bundleIdentifier isEqualToString:@"com.apple.mobilephone"]) {
                parent.clipsToBounds = NO;
                parent.layer.masksToBounds = NO;
            }
        }
        CGRect card = [self logicalFrame];
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize675 %@ OFF (%@) t+%.0fms: scene back to card size %.0fx%.0f safeArea %@ (4.5.674 geometry)",
                                  bundle, why ?: @"?", DSPhoneSize676Ms(), CGRectGetWidth(card), CGRectGetHeight(card),
                                  NSStringFromUIEdgeInsets(_safeAreaInsets));
    }
    [self phoneSize675WriteGeometry:_phoneSizeGeneration attempt:0];
}

// Geometry only, the same writes as a corner resize (applyCardFrameQuietly):
// the app view's content reference size, the override every later SpringBoard
// settings update for this scene is rewritten to, and the scene's frame and
// safe area. No transaction. Deferred while a write would trap (670).
- (void)phoneSize675WriteGeometry:(NSInteger)generation attempt:(NSInteger)attempt {
    if (generation != _phoneSizeGeneration) return;
    NSString *bundle = _bundleIdentifier ?: @"?";
    if (!_appViewController || DSSceneHostBundleDiedPending(_bundleIdentifier)) {
        if (_phoneSize) {
            _phoneSize = NO;
            _phoneSizeGeneration += 1;
            DSDiagnosticsRecordFormat(@"SpringBoard: phonesize675 %@ OFF (app view gone before the size was written)", bundle);
        }
        [self layoutHostView];
        return;
    }
    if (DSSceneWriteWouldTrap()) {
        if (attempt >= 15) {
            DSDiagnosticsRecordFormat(@"SpringBoard: phonesize675 %@ scene write never became safe (depth=%ld)%@",
                                      bundle, (long)DSSceneSettingsUpdateDepth, _phoneSize ? @", back to card size" : @"");
            if (_phoneSize) {
                // Nothing was written: undo the host layout and the override.
                _phoneSize = NO;
                _phoneSizeGeneration += 1;
                if (_scene) [self registerGeometryOnlyOverride];
            }
            [self layoutHostView];
            return;
        }
        if (!_phoneSizeDeferNoted) {
            _phoneSizeDeferNoted = YES;
            DSDiagnosticsRecordFormat(@"SpringBoard: phonesize675 %@ scene write deferred (scene update in progress depth=%ld)",
                                      bundle, (long)DSSceneSettingsUpdateDepth);
        }
        __weak __typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf phoneSize675WriteGeometry:generation attempt:attempt + 1];
        });
        return;
    }
    FBScene *scene = [self appViewScene];
    if (!scene) {
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize675 %@ has no scene to write%@", bundle, _phoneSize ? @", back to card size" : @"");
        if (_phoneSize) {
            _phoneSize = NO;
            _phoneSizeGeneration += 1;
        }
        [self layoutHostView];
        return;
    }
    _scene = scene;
    // Host first, so the picture is already where the new size lands.
    [self layoutHostView];
    [self setContentReferenceSizeOnAppView];
    [self forceSceneGeometry];
    CGSize size = [self logicalFrame].size;
    _deliveredOnce = YES;
    _deliveredWidth = size.width;
    _deliveredHeight = size.height;
    [self layoutHostView];
    DSDiagnosticsRecordFormat(@"SpringBoard: phonesize675 %@ scene size sent t+%.0fms: frame %@ safeArea %@ (%@)",
                              bundle, DSPhoneSize676Ms(), NSStringFromCGRect([self frameForScene]),
                              NSStringFromUIEdgeInsets([self insetsForScene]), _phoneSize ? @"phone size" : @"card size");
    // 4.5.676: read the scene back once the write has landed; when it is the
    // phone size, nudge the app into laying out again (phoneSize676Nudge).
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf phoneSize676ReadBack:generation attempt:0];
    });
}

- (NSString *)phoneSize676SceneSummary:(CGRect *)frameOut {
    FBScene *now = [self appViewScene];
    NSString *got = @"no scene";
    @try {
        FBSSceneSettings *settings = [now respondsToSelector:@selector(settings)] ? now.settings : nil;
        if (settings) {
            NSString *insets = @"?";
            if ([settings respondsToSelector:@selector(safeAreaInsetsPortrait)]) {
                UIEdgeInsets value = ((UIEdgeInsets (*)(id, SEL))objc_msgSend)(settings, @selector(safeAreaInsetsPortrait));
                insets = NSStringFromUIEdgeInsets(value);
            }
            if (frameOut) *frameOut = settings.frame;
            got = [NSString stringWithFormat:@"frame %@ safeArea %@", NSStringFromCGRect(settings.frame), insets];
        }
    } @catch (NSException *exception) {
    }
    return got;
}

- (void)phoneSize676ReadBack:(NSInteger)generation attempt:(NSInteger)attempt {
    if (generation != _phoneSizeGeneration) return;
    // 4.5.688 offset/short: the picture's place in the host can change once the
    // new frame lands; lay the host out again now and once more a second later.
    if ([self isPhoneSize688Geo] && attempt == 0) {
        [self layoutHostView];
        __weak __typeof(self) weakSelf688 = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong __typeof(weakSelf688) strongSelf = weakSelf688;
            if (strongSelf && generation == strongSelf->_phoneSizeGeneration && [strongSelf isPhoneSize688Geo]) [strongSelf layoutHostView];
        });
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize688 %@ %@", _bundleIdentifier ?: @"?", [self phoneSize684Summary]);
    }
    CGRect frame = CGRectZero;
    NSString *got = [self phoneSize676SceneSummary:&frame];
    UIView *host = _hostView;
    CGSize phone = [self phoneSize675SceneSize];
    BOOL landed = _phoneSize ? (fabs(CGRectGetHeight(frame) - phone.height) < 0.5 && fabs(CGRectGetWidth(frame) - phone.width) < 0.5)
                             : (fabs(CGRectGetHeight(frame) - CGRectGetHeight([self frameForScene])) < 0.5);
    DSDiagnosticsRecordFormat(@"SpringBoard: phonesize676 %@ scene read back t+%.0fms: %@; wanted %@ (%@); host bounds %@ x%.4f center %@ in card %@",
                              _bundleIdentifier ?: @"?", DSPhoneSize676Ms(), got, NSStringFromCGRect([self frameForScene]),
                              landed ? @"landed" : @"NOT landed yet",
                              NSStringFromCGRect(host.bounds), host.transform.a, NSStringFromCGPoint(host.center),
                              NSStringFromCGRect(host.superview.bounds));
    if (!_phoneSize) return;
    if (_phoneSizePreGrown) {
        // 4.5.678: grown before the keyboard; nothing stale to shake loose yet.
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize678 %@ pre-grown scene %@ t+%.0fms, no keyboard yet: no nudge",
                                  _bundleIdentifier ?: @"?", landed ? @"landed" : @"not confirmed", DSPhoneSize676Ms());
        return;
    }
    if (!landed && attempt < 3) {
        __weak __typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf phoneSize676ReadBack:generation attempt:attempt + 1];
        });
        return;
    }
    [self phoneSize676Nudge:1 generation:generation attempt:0 why:landed ? @"phone size confirmed" : @"not confirmed after 4 reads, nudging anyway"];
}

// 4.5.676: the app laid out for the keyboard while its window was still the
// card's 458pt, and only lays out again on its next keyboard or text change.
// Make one: the same geometry write as a resize, 1 pt shorter with a 1 pt
// larger bottom safe area, then the exact phone size again 0.12 s later. Two
// real size + safe-area changes (the keyboard's placement in the window moves
// by 1 pt and back), nothing else: no orientation, no lifecycle, no
// transaction. The 1 s app-view hold is restarted with each write.
- (void)phoneSize676Nudge:(NSInteger)number generation:(NSInteger)generation attempt:(NSInteger)attempt why:(NSString *)why {
    if (generation != _phoneSizeGeneration || !_phoneSize) return;
    NSString *bundle = _bundleIdentifier ?: @"?";
    if (DSPhoneSize680Enabled()) {
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize680 %@ nudge #%ld skipped: always full screen, no scene writes for the keyboard (%@)",
                                  bundle, (long)number, why ?: @"?");
        return;
    }
    if (DSPhoneSize676NudgeDisabled()) {
        if (number == 1) DSDiagnosticsRecordFormat(@"SpringBoard: phonesize676 %@ relayout nudge skipped: /var/mobile/.dynamicstage-phonesize676-nudge-off", bundle);
        [self phoneSize676ReleaseHold:@"nudge off" animated:YES];
        return;
    }
    NSString *wait = nil;
    if (DSSceneWriteWouldTrap()) wait = @"scene update in progress";
    else if (DSStageDragSettlingFast(1.2)) wait = @"card drag settling";
    else if (!_appViewController || ![self appViewScene]) wait = @"no app view scene";
    if (wait) {
        if (attempt < 15) {
            __weak __typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf phoneSize676Nudge:number generation:generation attempt:attempt + 1 why:why];
            });
        } else {
            DSDiagnosticsRecordFormat(@"SpringBoard: phonesize676 %@ relayout nudge #%ld given up (%@)", bundle, (long)number, wait);
            [self phoneSize676ReleaseHold:@"nudge given up" animated:YES];
        }
        return;
    }
    _phoneSizeNudgeWidth = !DSPhoneSize678WidthDisabled();
    _phoneSizeNudging = YES;
    DSPhoneSize675ChangedAt = CACurrentMediaTime();
    [self setContentReferenceSizeOnAppView];
    [self forceSceneGeometry];
    if (_phoneSizeNudgeWidth) {
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize678 %@ width nudge #%ld sent t+%.0fms (%@%@): scene %@ safeArea %@ "
                                  @"(the app's keyboard changes width, so UIKit re-posts its keyboard frame), restoring in 0.12 s",
                                  bundle, (long)number, DSPhoneSize676Ms(), why ?: @"?",
                                  attempt > 0 ? [NSString stringWithFormat:@", waited %ld", (long)attempt] : @"",
                                  NSStringFromCGRect([self frameForScene]), NSStringFromUIEdgeInsets([self insetsForScene]));
    } else {
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize676 %@ relayout nudge #%ld sent t+%.0fms (%@%@): scene %@ safeArea %@, restoring in 0.12 s "
                                  @"(height nudge: /var/mobile/.dynamicstage-phonesize678-width-off)",
                                  bundle, (long)number, DSPhoneSize676Ms(), why ?: @"?",
                                  attempt > 0 ? [NSString stringWithFormat:@", waited %ld", (long)attempt] : @"",
                                  NSStringFromCGRect([self frameForScene]), NSStringFromUIEdgeInsets([self insetsForScene]));
    }
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf phoneSize676Restore:number generation:generation attempt:0];
    });
}

- (void)phoneSize676Restore:(NSInteger)number generation:(NSInteger)generation attempt:(NSInteger)attempt {
    if (generation != _phoneSizeGeneration || !_phoneSize) {
        // A switch in between wrote its own size and cleared the nudge.
        return;
    }
    NSString *bundle = _bundleIdentifier ?: @"?";
    if (DSSceneWriteWouldTrap() && attempt < 30) {
        __weak __typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf phoneSize676Restore:number generation:generation attempt:attempt + 1];
        });
        return;
    }
    _phoneSizeNudging = NO;
    if (DSSceneWriteWouldTrap()) {
        // Never safe for 1.5 s: leave the exact size in the override, which
        // rewrites SpringBoard's next update for the scene anyway.
        if (_scene) [self registerGeometryOnlyOverride];
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize676 %@ relayout nudge #%ld restore deferred to the override (scene update in progress)", bundle, (long)number);
    } else {
        DSPhoneSize675ChangedAt = CACurrentMediaTime();
        [self setContentReferenceSizeOnAppView];
        [self forceSceneGeometry];
    }
    [self layoutHostView];
    DSDiagnosticsRecordFormat(@"SpringBoard: %@ %@ %@ nudge #%ld restored t+%.0fms: scene %@ safeArea %@",
                              _phoneSizeNudgeWidth ? @"phonesize678" : @"phonesize676", bundle,
                              _phoneSizeNudgeWidth ? @"width" : @"relayout",
                              (long)number, DSPhoneSize676Ms(), NSStringFromCGRect([self frameForScene]),
                              NSStringFromUIEdgeInsets([self insetsForScene]));
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf phoneSize676ReleaseHold:@"relayout nudge done" animated:YES];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_phoneSizeGeneration != generation || !strongSelf->_phoneSize) return;
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize676 %@ after nudge #%ld read back t+%.0fms: %@",
                                  strongSelf->_bundleIdentifier ?: @"?", (long)number, DSPhoneSize676Ms(),
                                  [strongSelf phoneSize676SceneSummary:NULL]);
    });
    // One more, after the keyboard's own show animation has certainly ended.
    if (number == 1) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf phoneSize676Nudge:2 generation:generation attempt:0 why:@"second nudge, after the keyboard animation"];
        });
    }
}

// Optional (hold-on file): the card's current picture held over the switch
// until the first nudge is back (at most 0.8 s), so the relayout is not seen.
- (void)phoneSize676HoldPicture {
    if (!DSPhoneSize676HoldEnabled() || _phoneSizeHoldView) return;
    UIView *parent = _hostView.superview;
    if (!parent || CGRectIsEmpty(parent.bounds)) return;
    UIView *snapshot = nil;
    @try {
        snapshot = [parent snapshotViewAfterScreenUpdates:NO];
    } @catch (NSException *exception) {
        snapshot = nil;
    }
    if (!snapshot) {
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize676 %@ picture hold: no snapshot, nothing held", _bundleIdentifier ?: @"?");
        return;
    }
    snapshot.frame = parent.bounds;
    snapshot.userInteractionEnabled = NO;
    [parent addSubview:snapshot];
    _phoneSizeHoldView = snapshot;
    DSDiagnosticsRecordFormat(@"SpringBoard: phonesize676 %@ picture hold ON t+%.0fms (card snapshot over the switch, max 0.8 s)",
                              _bundleIdentifier ?: @"?", DSPhoneSize676Ms());
    __weak __typeof(self) weakSelf = self;
    __weak UIView *weakSnapshot = snapshot;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf && strongSelf->_phoneSizeHoldView == weakSnapshot) [strongSelf phoneSize676ReleaseHold:@"0.8 s limit" animated:YES];
    });
}

// ---- 4.5.678 phonesize678: grow before the keyboard (B), stay grown (C) -----
- (BOOL)isPhoneSize678PreGrown {
    return _phoneSize && _phoneSizePreGrown;
}

// Scene y put on the card's bottom edge while no keyboard is up: the app's
// bottom above the home-indicator inset, where its composer sits.
- (CGFloat)phoneSize678BottomAnchor {
    // 4.5.684: the bar rests above the K inset (no 120 pt clamp).
    if ([self isPhoneSize688Geo]) return [self phoneSize688Line];
    if ([self isPhoneSize687]) return [self phoneSize687Bar];
    if ([self isPhoneSize684]) return [self phoneSize684Pin];
    CGSize phone = [self phoneSize675SceneSize];
    UIEdgeInsets insets = _phoneSize ? _phoneSizeInsets : [self phoneSize675ScreenInsets];
    CGFloat bottom = isfinite(insets.bottom) ? MAX(0.0, MIN(120.0, insets.bottom)) : 0.0;
    return phone.height - bottom;
}

- (NSString *)phoneSize678MappingName:(BOOL)tapSafe {
    return tapSafe ? @"tap-safe (app top on the card top, so the touched point stays put inside the app while the finger is down)"
                   : @"bottom-anchored (the app's bottom above the home inset on the card's bottom edge)";
}

// The card's current picture over the switch while the finger is down, so the
// tap-safe phase is not seen. Taken before the write. The touch already
// belongs to the app (it went there at touch-down); the picture takes no touches.
- (void)phoneSize678HoldForTouch {
    if (_phoneSizeHoldView) return;
    UIView *parent = _hostView.superview;
    if (!parent || CGRectIsEmpty(parent.bounds)) return;
    UIView *snapshot = nil;
    @try {
        snapshot = [parent snapshotViewAfterScreenUpdates:NO];
    } @catch (NSException *exception) {
        snapshot = nil;
    }
    if (!snapshot) {
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize678 %@ touch hold: no snapshot, the tap-safe phase is visible", _bundleIdentifier ?: @"?");
        return;
    }
    snapshot.frame = parent.bounds;
    snapshot.userInteractionEnabled = NO;
    [parent addSubview:snapshot];
    _phoneSizeHoldView = snapshot;
    __weak __typeof(self) weakSelf = self;
    __weak UIView *weakSnapshot = snapshot;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf && strongSelf->_phoneSizeHoldView == weakSnapshot) [strongSelf phoneSize676ReleaseHold:@"touch hold 1.2 s limit" animated:YES];
    });
}

// B / C: phone size now, before any keyboard. NO when it did not switch
// (already phone-size for a keyboard, or one of setPhoneSize675's skips).
- (BOOL)phoneSize678PreGrow:(BOOL)tapSafe why:(NSString *)why {
    if (_phoneSize) {
        if (!_phoneSizePreGrown) return NO;
        if (!tapSafe) [self phoneSize678AnchorBottom:why];
        return YES;
    }
    BOOL hold = tapSafe && _hostView.superview != nil;
    if (hold) [self phoneSize678HoldForTouch];
    _phoneSizePreGrowCall = YES;
    @try {
        [self setPhoneSize675:YES keyboardTop:(tapSafe ? 0.0 : [self phoneSize678BottomAnchor]) why:why];
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize678 %@ pre-grow threw %@", _bundleIdentifier ?: @"?", exception.reason ?: exception.name ?: @"?");
    }
    _phoneSizePreGrowCall = NO;
    if (!_phoneSize) {
        _phoneSizePreGrown = NO;
        [self phoneSize676ReleaseHold:@"pre-grow did not switch" animated:NO];
        return NO;
    }
    DSDiagnosticsRecordFormat(@"SpringBoard: phonesize678 %@ pre-grown t+%.0fms: mapping %@%@",
                              _bundleIdentifier ?: @"?", DSPhoneSize676Ms(), [self phoneSize678MappingName:tapSafe],
                              hold ? (_phoneSizeHoldView ? @"; card picture held until the finger lifts" : @"") : @"");
    return YES;
}

// Tap-safe -> bottom-anchored (the finger lifted). Mapping only, no scene write.
- (void)phoneSize678AnchorBottom:(NSString *)why {
    if (!_phoneSize || !_phoneSizePreGrown) return;
    CGFloat anchor = [self phoneSize678BottomAnchor];
    if (fabs(anchor - _phoneSizeKeyTop) > 0.5) {
        CGFloat was = _phoneSizeKeyTop;
        _phoneSizeKeyTop = anchor;
        [self layoutHostView];
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize678 %@ mapping %.0f -> %.0f t+%.0fms (%@): %@",
                                  _bundleIdentifier ?: @"?", was, anchor, DSPhoneSize676Ms(), why ?: @"?",
                                  [self phoneSize678MappingName:NO]);
    }
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf phoneSize676ReleaseHold:@"finger lifted, bottom-anchored" animated:YES];
    });
}

// C: the keyboard went down; stay phone-size, bottom-anchored.
- (void)phoneSize678RestWhy:(NSString *)why {
    if (_phoneSize && [self isPhoneSize684]) {
        [self phoneSize684KeysDown:why ?: @"keyboard down"];
        return;
    }
    // 4.5.684: a keys-down moment; 684 may need switching on (off file removed).
    if (_phoneSize && !_cameraTall) [self phoneSize684ScheduleApply:why ?: @"keyboard down"];
    if (_phoneSize && DSPhoneSize680Enabled()) {
        [self phoneSize680MoveBarBottomTo:[self phoneSize678BottomAnchor] duration:0.25 curve:7 lag:0.0 why:why ?: @"keyboard down"];
        return;
    }
    if (_phoneSize && !_phoneSizePreGrown) {
        _phoneSizePreGrown = YES;
        CGFloat was = _phoneSizeKeyTop;
        _phoneSizeKeyTop = [self phoneSize678BottomAnchor];
        [self layoutHostView];
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize678 %@ always: %@; stays phone-size, mapping %.0f -> %.0f, %@",
                                  _bundleIdentifier ?: @"?", why ?: @"?", was, _phoneSizeKeyTop, [self phoneSize678MappingName:NO]);
        return;
    }
    if (!_phoneSize) [self phoneSize678PreGrow:NO why:[NSString stringWithFormat:@"phonesize678 always: %@", why ?: @"?"]];
}

// ---- 4.5.683 phonesize683 -----------------------------------------------------
- (BOOL)isPhoneSize683 {
    if (!_phoneSize || _cameraTall || !DSPhoneSize683Enabled()) return NO;
    NSString *bundle = _bundleIdentifier;
    if (bundle.length == 0 || !DSPhoneSize675Allowed(bundle)) return NO;
    @try {
        DSStageManager *manager = [DSStageManager sharedManager];
        if ([manager respondsToSelector:@selector(keys671AppHasDylib:)] && [manager keys671AppHasDylib:bundle]) return NO;
    } @catch (NSException *exception) {
        return NO;
    }
    return YES;
}

static void DSPS683CensusView(UIView *view, UIView *root, NSInteger depth, NSMutableArray<NSString *> *out) {
    if (!view || depth > 6 || out.count >= 28) return;
    CGRect frame = root ? [view convertRect:view.bounds toView:root] : view.frame;
    [out addObject:[NSString stringWithFormat:@"%@%@ %@%@%@", [@"" stringByPaddingToLength:(NSUInteger)depth withString:@"." startingAtIndex:0],
                    NSStringFromClass(view.class), NSStringFromCGRect(frame), view.hidden ? @" HIDDEN" : @"",
                    view.alpha < 0.99 ? [NSString stringWithFormat:@" a=%.2f", view.alpha] : @""]];
    for (UIView *child in view.subviews) DSPS683CensusView(child, root, depth + 1, out);
}

- (NSString *)phoneSize683HostCensus {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    @try {
        DSPS683CensusView(_hostView, _hostView, 0, lines);
    } @catch (NSException *exception) {
        [lines addObject:@"(census threw)"];
    }
    return [lines componentsJoinedByString:@" | "];
}

// ---- 4.5.684 phonesize684 -----------------------------------------------------
static NSMutableDictionary<NSString *, NSNumber *> *DSPS684Learned = nil;
static NSMutableDictionary<NSString *, NSNumber *> *DSPS701PendingK;   // 4.5.701 keys701 // bundle -> K (this SpringBoard run)

- (BOOL)isPhoneSize684 {
    return _phoneSize && _ps684Active && !_cameraTall;
}

- (BOOL)isPhoneSize685 {
    return [self isPhoneSize684] && _ps685Active;
}

// 4.5.694: the card's vertical scale (= fit when 694 is not squashing).
- (CGFloat)phoneSize694ScaleYForWidth:(CGFloat)width height:(CGFloat)height fit:(CGFloat)fit keyTop:(CGFloat)keyTop {
    CGFloat sy = fit;
    NSString *why = nil;
    @try {
        if (!DSPhoneSize694Squash()) why = DSPhoneSize694Off() ? @"694 off file (691)" : (DSPhoneSize694Latched() ? @"crash latch (691)" : @"mode=691");
        else if (![self isPhoneSize684] || _ps685Active || _ps687Active || [self isPhoneSize688Geo]) why = @"not the 684 geometry";
        else if (!isfinite(fit) || fit < 0.3 || !isfinite(height) || height < 80.0 || !isfinite(keyTop)) why = @"odd card";
        else {
            DSPhoneSize694Tune tune = DSPhoneSize694CurrentTune();
            CGFloat span = keyTop - tune.viewTop;
            CGFloat want = tune.sy > 0.0 ? tune.sy : (span > 100.0 ? height / span : fit);
            if (!isfinite(want)) want = fit;
            want = MAX(0.5, MIN(1.2, want));
            if (tune.sy <= 0.0 && want >= fit - 0.0005) {
                why = @"the card already shows view_top at the uniform scale";
            } else {
                sy = want;
                DSPhoneSize694MarkTrying();
            }
        }
    } @catch (NSException *exception) {
        sy = fit;
        why = @"threw";
    }
    NSString *state = why ? [@"off:" stringByAppendingString:why] : [NSString stringWithFormat:@"on:%.4f:%.4f:%.0f:%.0f", fit, sy, keyTop, height];
    if (![state isEqualToString:_ps694LoggedState]) {
        _ps694LoggedState = state;
        if (why) {
            DSDiagnosticsRecordFormat(@"SpringBoard: phonesize694 %@ no squash (%@): uniform x%.4f", _bundleIdentifier ?: @"?", why, fit);
        } else {
            DSDiagnosticsRecordFormat(@"SpringBoard: phonesize694 %@ squash: card %.0fx%.0f shows the real app y %.0f..%.0f at x%.4f (full width) / y%.4f; "
                                      @"app y %.0f on the card bottom (bar line, as 684); top inset %.0f, scene/keyboard 684",
                                      _bundleIdentifier ?: @"?", width, height, keyTop - height / MAX(sy, 0.01), keyTop, fit, sy, keyTop,
                                      [self phoneSize684Insets].top);
        }
    }
    return sy;
}

// 4.5.698: a little bigger than 694's squash (see DSPhoneSize698Tune). In: 694's
// sx (fit) / sy. Out: the scales and the host centre x. App y keyTop stays on the
// card bottom (the caller's centre y formula uses the returned sy). Never smaller
// than 694 and never narrower than the card (no margins).
- (void)phoneSize698ForWidth:(CGFloat)width height:(CGFloat)height phone:(CGSize)phone fit:(CGFloat)fit keyTop:(CGFloat)keyTop
                          sx:(CGFloat *)sxInOut sy:(CGFloat *)syInOut cx:(CGFloat *)cxOut {
    CGFloat sx0 = *sxInOut, sy0 = *syInOut;
    CGFloat sx = sx0, sy = sy0, shift = 0.0;
    NSString *why = nil;
    @try {
        if (DSPhoneSize698Off()) why = @"698 off file (697)";
        else if (DSPhoneSize698Latched()) why = @"crash latch (697)";
        else if (![_ps694LoggedState hasPrefix:@"on:"]) why = @"694 squash not in use";
        else if ([_bundleIdentifier isEqualToString:@"com.apple.MobileSMS"]) why = @"Messages";
        else if (!isfinite(fit) || fit < 0.3 || !isfinite(sy0) || sy0 < 0.3 || !isfinite(height) || height < 80.0 ||
                 !isfinite(width) || width < 80.0 || !isfinite(keyTop) || phone.width < 100.0) why = @"odd card";
        else {
            DSPhoneSize698Tune tune = DSPhoneSize698CurrentTune();
            if (tune.zoom > 0.0) {
                sx = sx0 * tune.zoom;
                sy = sy0 * tune.zoom;
            } else {
                CGFloat span = keyTop - tune.viewTop;
                sy = span > 100.0 ? height / span : sy0;
                CGFloat shown = phone.width - 2.0 * tune.sideCrop;
                sx = shown > 100.0 ? width / shown : sx0;
            }
            if (tune.sx > 0.0) sx = tune.sx;
            if (tune.sy > 0.0) sy = tune.sy;
            if (!isfinite(sx)) sx = sx0;
            if (!isfinite(sy)) sy = sy0;
            sx = MAX(sx0, MIN(1.4, sx));
            sy = MAX(sy0, MIN(1.4, sy));
            CGFloat maxShift = MAX(0.0, (phone.width * sx - width) / (2.0 * sx));
            shift = MAX(-maxShift, MIN(maxShift, tune.xShift));
            if (fabs(sx - sx0) < 0.0005 && fabs(sy - sy0) < 0.0005 && fabs(shift) < 0.05) {
                why = @"tune gives 697's picture";
                sx = sx0; sy = sy0; shift = 0.0;
            } else {
                DSPhoneSize698MarkTrying();
            }
        }
    } @catch (NSException *exception) {
        sx = sx0; sy = sy0; shift = 0.0;
        why = @"threw";
    }
    *sxInOut = sx;
    *syInOut = sy;
    *cxOut = width / 2.0 + shift * sx;
    NSString *state = why ? [@"off:" stringByAppendingString:why]
                          : [NSString stringWithFormat:@"on:%.4f:%.4f:%.1f:%.0f:%.0f:%.0f", sx, sy, shift, keyTop, width, height];
    if (![state isEqualToString:_ps698LoggedState]) {
        _ps698LoggedState = state;
        if (why) {
            DSDiagnosticsRecordFormat(@"SpringBoard: phonesize698 %@ not bigger (%@): 697 picture x%.4f / y%.4f", _bundleIdentifier ?: @"?", why, sx0, sy0);
        } else {
            CGFloat halfW = width / (2.0 * sx);
            CGFloat midX = phone.width / 2.0 - shift;
            DSDiagnosticsRecordFormat(@"SpringBoard: phonesize698 %@ bigger: card %.0fx%.0f shows app y %.0f..%.0f, x %.1f..%.1f at x%.4f / y%.4f "
                                      @"(697: y %.0f..%.0f, x 0..%.0f at x%.4f / y%.4f -> %+.1f%% wide, %+.1f%% tall); app y %.0f on the card bottom (bar line), scene/keyboard unchanged",
                                      _bundleIdentifier ?: @"?", width, height, keyTop - height / sy, keyTop, midX - halfW, midX + halfW, sx, sy,
                                      keyTop - height / sy0, keyTop, phone.width, sx0, sy0,
                                      (sx / sx0 - 1.0) * 100.0, (sy / sy0 - 1.0) * 100.0, keyTop);
        }
    }
}

// 4.5.695: is this host a 684-geometry phone-size card (the 694 squash path)?
- (BOOL)phoneSize695Geometry {
    if (!_phoneSize || _cameraTall || !_appViewController) return NO;
    if (DSSceneHostBundleDiedPending(_bundleIdentifier)) return NO;
    if (![self isPhoneSize684] || _ps685Active || _ps687Active || [self isPhoneSize688Geo]) return NO;
    return YES;
}

// 4.5.695: YES = do not shrink the scene back to card size for this reason;
// the card is only minimised / off screen. Everything else shrinks as in 694.
- (BOOL)phoneSize695KeepsAway:(NSString *)why {
    BOOL keep = NO;
    BOOL away = NO;
    @try {
        if (![self phoneSize695Geometry] || !DSPhoneSize695Enabled()) return NO;
        UIView *parent = _hostView.superview;
        away = parent && (parent.tag == 9158 ||
                          (CGRectGetWidth(parent.bounds) < 80.0 && CGRectGetHeight(parent.bounds) < 80.0));
        if ([why isEqualToString:@"card minimized"] || [why isEqualToString:@"card not on screen"]) keep = YES;
        else if (away && ([why hasPrefix:@"keyboard now belongs to"] || [why hasPrefix:@"keyboard down"])) keep = YES;
        if (keep) DSPhoneSize695MarkTrying();
    } @catch (NSException *exception) {
        keep = NO;
    }
    if (keep) {
        NSString *key = [NSString stringWithFormat:@"%@|%@|%d", _bundleIdentifier ?: @"?", why ?: @"?", away];
        // 4.5.706 perf706: the same "kept" line came every ~6 s for as long as another
        // app typed (85 lines in one log). Same key: once a minute.
        CFAbsoluteTime quietFor = DSFeature699On("perf706") ? 60.0 : 5.0;
        if (DSLogGate(@"phonesize695-kept", key, quietFor, NULL)) {
            CGSize phone = [self phoneSize675SceneSize];
            DSDiagnosticsRecordFormat(@"SpringBoard: phonesize695 %@ kept %.0fx%.0f safeArea %@ while %@ (%@): no shrink, no scene write; restore needs no relayout",
                                      _bundleIdentifier ?: @"?", phone.width, phone.height, NSStringFromUIEdgeInsets([self insetsForScene]),
                                      away ? @"minimised" : @"off screen", why ?: @"?");
        }
    }
    return keep;
}

// 4.5.695: the live view is back on its card (restore). The scene is still the
// phone size, so place it with the 694 squash now, before the next frame (the
// stage manager's return put it there at identity).
- (void)phoneSize695ReturnedToCard {
    @try {
        if (!_hostView.superview || ![self phoneSize695Geometry] || !DSPhoneSize695Enabled()) return;
        [self layoutHostView];
        static CFAbsoluteTime loggedAt = 0;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - loggedAt > 2.0 || now < loggedAt) {
            loggedAt = now;
            CGSize phone = [self phoneSize675SceneSize];
            DSDiagnosticsRecordFormat(@"SpringBoard: phonesize695 %@ restored: scene still %.0fx%.0f safeArea %@, squash placed on the first frame (card %.0fx%.0f), no resize",
                                      _bundleIdentifier ?: @"?", phone.width, phone.height, NSStringFromUIEdgeInsets([self insetsForScene]),
                                      CGRectGetWidth(_hostView.superview.bounds), CGRectGetHeight(_hostView.superview.bounds));
        }
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize695 restore layout threw %@", exception.reason ?: exception.name ?: @"?");
    }
}

// ---- 4.5.696 ------------------------------------------------------------------
- (void)phoneSize696SetKeysSceneID:(NSString *)identifier {
    if ((identifier == nil && _ps696KeysSceneID == nil) || [identifier isEqualToString:_ps696KeysSceneID]) return;
    [DSSceneOverridesLock() lock];
    if (_ps696KeysSceneID) [DSPS696KeysScenes() removeObject:_ps696KeysSceneID];
    if (identifier) [DSPS696KeysScenes() addObject:identifier];
    [DSSceneOverridesLock() unlock];
    _ps696KeysSceneID = [identifier copy];
}

// Fix 1: the scene counts as a visible phone-size card while the host view
// sits in a real card (not the hidden holder, not the corner bubble).
- (void)phoneSize696UpdateKeysSceneForParent:(UIView *)parent {
    BOOL tiny = CGRectGetWidth(parent.bounds) < 80.0 && CGRectGetHeight(parent.bounds) < 80.0;
    BOOL want = parent && parent.tag != 9158 && !tiny && !CGRectIsEmpty(parent.bounds) && !_staysBackgrounded &&
                [self phoneSize695Geometry];
    NSString *identifier = nil;
    if (want) {
        FBScene *scene = _scene ?: [self appViewScene];
        identifier = [scene respondsToSelector:@selector(identifier)] ? scene.identifier : nil;
    }
    [self phoneSize696SetKeysSceneID:identifier.length ? identifier : nil];
}

// Fix 2: a 684-geometry phone-size card (the lift uses its keys top).
- (BOOL)phoneSize696FitGeometry {
    return [self phoneSize695Geometry];
}

- (CGFloat)phoneSize696KeysTop {
    return [self phoneSize684Pin];
}

// Fix 0: a visible card that is backgrounded, not showing its app, hidden or
// scaled to nothing is put right (the same wake a tap on the card does).
// Returns what it did, or nil.
- (NSString *)blackout696Tick {
    if (!_appViewController || !_hostView) return nil;
    if (DSSceneHostBundleDiedPending(_bundleIdentifier) || DSSceneWriteWouldTrap() || _revealingTallContent) return nil;
    UIView *parent = _hostView.superview;
    if (!parent || parent.tag == 9158 || (CGRectGetWidth(parent.bounds) < 80.0 && CGRectGetHeight(parent.bounds) < 80.0)) return nil;
    CGAffineTransform t = _hostView.transform;
    BOOL hiddenView = _hostView.hidden || _hostView.alpha < 0.01 || fabs(t.a) < 0.01 || fabs(t.d) < 0.01;
    BOOL foreground = YES;
    BOOL known = NO;
    @try {
        FBScene *scene = [self appViewScene];
        id settings = [scene respondsToSelector:@selector(settings)] ? scene.settings : nil;
        foreground = settings ? [DSSceneHost readForegroundFlag:settings known:&known] : YES;
    } @catch (NSException *exception) {
    }
    BOOL showing = [self appViewIsShowingContent];
    if (!hiddenView && !(known && !foreground) && showing) {
        _ps696BadTicks = 0;
        return nil;
    }
    // Seen on two ticks in a row (about 3 s), so an app that is still opening
    // or a transition in progress is left alone.
    if (++_ps696BadTicks < 2) return nil;
    NSMutableArray<NSString *> *did = [NSMutableArray array];
    if (hiddenView) {
        _hostView.hidden = NO;
        _hostView.alpha = 1.0;
        [self layoutHostView];
        [did addObject:@"host view was hidden / scaled to nothing: shown and laid out again"];
    }
    if ((known && !foreground) || !showing) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - _ps696WakeAt >= 4.0 || now < _ps696WakeAt) {
            _ps696WakeAt = now;
            [self wakeIfBackgrounded];
            [did addObject:[NSString stringWithFormat:@"scene %@%@: woken (the card-tap wake)",
                            (known && !foreground) ? @"backgrounded" : @"foreground", showing ? @"" : @", app view not showing the app"]];
        }
    }
    if (did.count == 0) return nil;
    DSPS696MarkTrying(0);
    return [did componentsJoinedByString:@"; "];
}

- (NSString *)blackout699WakeIfBackgrounded {
    if (!_appViewController || !_hostView) return nil;
    if (DSSceneHostBundleDiedPending(_bundleIdentifier) || DSSceneWriteWouldTrap() || _revealingTallContent) return nil;
    UIView *parent = _hostView.superview;
    if (!parent || parent.tag == 9158) return nil;
    BOOL foreground = YES;
    BOOL known = NO;
    @try {
        FBScene *scene = [self appViewScene];
        id settings = [scene respondsToSelector:@selector(settings)] ? scene.settings : nil;
        foreground = settings ? [DSSceneHost readForegroundFlag:settings known:&known] : YES;
    } @catch (NSException *exception) {
    }
    if (!(known && !foreground)) return nil;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - _ps696WakeAt < 1.0 && now >= _ps696WakeAt) return nil;
    _ps696WakeAt = now;
    _ps696BadTicks = 0;
    [self wakeIfBackgrounded];
    return @"scene was in the background on a visible card: woken (the card-tap wake)";
}

// ---- 4.5.690 top-bar strip (see the notes above DSPhoneSize690StripView) ----
- (void)phoneSize690RemoveStrip:(NSString *)why {
    DSPhoneSize690StripView *strip = _ps690Strip;
    if (!strip) return;
    _ps690Strip = nil;
    @try {
        [strip removeFromSuperview];
    } @catch (NSException *exception) {
    }
    _ps690LoggedState = nil;
    DSDiagnosticsRecordFormat(@"SpringBoard: phonesize690 %@ top-bar strip removed (%@)", _bundleIdentifier ?: @"?", why ?: @"?");
}

- (void)phoneSize690UpdateStripInParent:(UIView *)parent width:(CGFloat)width height:(CGFloat)height fit:(CGFloat)fit cardBottomY:(CGFloat)bottomY {
    if (![NSThread isMainThread]) return;
    DSPhoneSize690Tune tune = DSPhoneSize690CurrentTune();
    UIView *source = _hostView;
    CGFloat visibleTop = bottomY - height / MAX(fit, 0.01);
    NSString *skip = nil;
    if (!tune.on) skip = @"tune on=0";
    else if (DSPhoneSize694Squash()) skip = @"694 squash: the real top bar is shown (copied bar only with 694 mode=691 or the 694 off file)";
    else if (DSPhoneSize690Off()) skip = @"/var/mobile/.dynamicstage-phonesize690-off";
    else if (![self isPhoneSize684] || _ps685Active || _ps687Active || [self isPhoneSize688Geo]) skip = @"not the 684/689 geometry";
    else if (!parent || !source || source.superview != parent || source.hidden) skip = @"no card";
    else if (!isfinite(fit) || fit < 0.3 || fit > 2.0 || !isfinite(width) || width < 80.0 || !isfinite(height) || height < 80.0) skip = @"odd card size";
    else if (tune.stripTop >= visibleTop - 0.5) skip = @"strip already on the card";
    else if (DSPhoneSize690Latched()) skip = @"crash latch (/var/mobile/.dynamicstage-phonesize690-crashed)";
    if (skip) {
        if (_ps690Strip) [self phoneSize690RemoveStrip:skip];
        NSString *state = [@"skip:" stringByAppendingString:skip];
        if (![state isEqualToString:_ps690LoggedState]) {
            _ps690LoggedState = state;
            DSDiagnosticsRecordFormat(@"SpringBoard: phonesize690 %@ no top-bar strip (%@)", _bundleIdentifier ?: @"?", skip);
        }
        return;
    }
    Class portalClass = NSClassFromString(@"_UIPortalView");
    if (!portalClass || ![portalClass instancesRespondToSelector:NSSelectorFromString(@"setSourceView:")]) {
        NSString *state = @"skip:no _UIPortalView";
        if (![state isEqualToString:_ps690LoggedState]) {
            _ps690LoggedState = state;
            DSDiagnosticsRecordFormat(@"SpringBoard: phonesize690 %@ no top-bar strip: _UIPortalView (setSourceView:) missing on this iOS", _bundleIdentifier ?: @"?");
        }
        return;
    }
    DSPhoneSize690StripView *strip = _ps690Strip;
    if (strip && strip.superview != parent) {
        [self phoneSize690RemoveStrip:@"card changed"];
        strip = nil;
    }
    UIView *portal = nil;
    for (UIView *sub in strip.subviews) {
        if ([NSStringFromClass(object_getClass(sub)) containsString:@"Portal"]) portal = sub;
    }
    BOOL made = NO;
    if (!strip || !portal) {
        if (strip) [self phoneSize690RemoveStrip:@"portal lost"];
        DSPhoneSize690MarkTrying();
        strip = [[DSPhoneSize690StripView alloc] initWithFrame:CGRectZero];
        strip.clipsToBounds = YES;
        strip.layer.masksToBounds = YES;
        strip.autoresizingMask = UIViewAutoresizingNone;
        strip.isAccessibilityElement = NO;
        @try {
            portal = [[portalClass alloc] initWithFrame:CGRectZero];
        } @catch (NSException *exception) {
            portal = nil;
        }
        if (!portal) {
            DSDiagnosticsRecordFormat(@"SpringBoard: phonesize690 %@ _UIPortalView could not be made; no strip", _bundleIdentifier ?: @"?");
            return;
        }
        portal.userInteractionEnabled = NO;
        portal.autoresizingMask = UIViewAutoresizingNone;
        DSPhoneSize690SetBool(portal, @"setMatchesPosition:", NO);
        DSPhoneSize690SetBool(portal, @"setMatchesTransform:", NO);
        DSPhoneSize690SetBool(portal, @"setMatchesAlpha:", NO);
        DSPhoneSize690SetBool(portal, @"setHidesSourceView:", NO);
        DSPhoneSize690SetBool(portal, @"setForwardsClientHitTestingToSourceView:", NO);
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(portal, NSSelectorFromString(@"setSourceView:"), source);
        } @catch (NSException *exception) {
            DSDiagnosticsRecordFormat(@"SpringBoard: phonesize690 %@ setSourceView threw %@; no strip", _bundleIdentifier ?: @"?", exception.reason ?: @"?");
            return;
        }
        [strip addSubview:portal];
        [parent insertSubview:strip aboveSubview:source];
        _ps690Strip = strip;
        made = YES;
    } else {
        SEL getter = NSSelectorFromString(@"sourceView");
        id current = [portal respondsToSelector:getter] ? ((id (*)(id, SEL))objc_msgSend)(portal, getter) : nil;
        if (current != source) ((void (*)(id, SEL, id))objc_msgSend)(portal, NSSelectorFromString(@"setSourceView:"), source);
        if (parent.subviews.lastObject != strip) {
            NSUInteger si = [parent.subviews indexOfObject:source];
            NSUInteger ti = [parent.subviews indexOfObject:strip];
            if (si != NSNotFound && ti != NSNotFound && ti < si) [parent insertSubview:strip aboveSubview:source];
        }
    }
    // Touch mode: the portal's own (window server) hit testing only in forward.
    if (strip.touchMode != tune.touch || made) {
        strip.touchMode = tune.touch;
        DSPhoneSize690SetBool(portal, @"setAllowsHitTesting:", tune.touch == 0);
        strip.userInteractionEnabled = tune.touch != 2;
        // A filled view is what the window server gives to SpringBoard; pass
        // mode is picture only, so its own layer stays out of hit testing.
        strip.backgroundColor = tune.touch == 2 ? UIColor.clearColor : (parent.backgroundColor ?: UIColor.blackColor);
    }
    strip.bundle = _bundleIdentifier;
    strip.stripTop = tune.stripTop;
    strip.fit = fit;
    // Geometry: strip at card y place_y, card width, strip_height at the card's
    // scale; the portal shows the host view (scene coordinates) so that app y
    // strip_top lands on the strip's top edge, at the same x as the card.
    CGSize scene = source.bounds.size;
    CGRect frame = CGRectMake(0.0, tune.placeY, width, ceil(tune.stripHeight * fit));
    if (!CGRectEqualToRect(strip.frame, frame)) strip.frame = frame;
    if (strip.hidden) strip.hidden = NO;
    CGRect bounds = CGRectMake(0.0, 0.0, scene.width, scene.height);
    if (!CGRectEqualToRect(portal.bounds, bounds)) {
        portal.transform = CGAffineTransformIdentity;
        portal.bounds = bounds;
    }
    CGFloat left = (width - scene.width * fit) / 2.0;
    CGPoint center = CGPointMake(left + scene.width * fit / 2.0, (scene.height / 2.0 - tune.stripTop) * fit);
    if (fabs(portal.center.x - center.x) > 0.25 || fabs(portal.center.y - center.y) > 0.25) portal.center = center;
    CGAffineTransform t = portal.transform;
    if (fabs(t.a - fit) > 0.0005 || fabs(t.d - fit) > 0.0005) portal.transform = CGAffineTransformMakeScale(fit, fit);
    NSString *state = [NSString stringWithFormat:@"on:%.0f:%.0f:%.0f:%.4f:%ld:%.0f", tune.stripTop, tune.stripHeight, tune.placeY, fit, (long)tune.touch, width];
    if (made || ![state isEqualToString:_ps690LoggedState]) {
        _ps690LoggedState = state;
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize690 %@ top-bar strip %@: app y %.0f..%.0f shown at card y %.0f..%.0f (x%.4f, card %.0fx%.0f; the card itself still shows app y %.0f..%.0f, unchanged), touch=%@",
                                  _bundleIdentifier ?: @"?", made ? @"made" : @"updated", tune.stripTop, tune.stripTop + tune.stripHeight,
                                  tune.placeY, tune.placeY + CGRectGetHeight(frame), fit, width, height, visibleTop, bottomY,
                                  DSPhoneSize690TouchName(tune.touch));
    }
}


- (BOOL)isPhoneSize688Geo {
    return [self isPhoneSize684] && _ps688Active && !_ps685Active && !_ps687Active &&
           (_ps688Mode == DSPhoneSize688ModeOffset || _ps688Mode == DSPhoneSize688ModeShort);
}

// 4.5.688 offset/short: how far the keyboard line moves up in the window (o):
// card shows window view..view + cardH/fit with the 684 fill; line = 586 - o.
- (CGFloat)phoneSize688O {
    if (_ps688Offset >= 0.0) return MIN(150.0, _ps688Offset);
    UIView *parent = _hostView.superview;
    CGFloat w = CGRectGetWidth(parent.bounds);
    CGFloat h = CGRectGetHeight(parent.bounds);
    if (!isfinite(w) || w < 80.0 || !isfinite(h) || h < 80.0) {
        w = CGRectGetWidth(_stageFrame);
        h = CGRectGetHeight(_stageFrame);
    }
    CGFloat phoneW = [self cameraTallSize].width;
    if (!(phoneW > 1.0) || !isfinite(w) || w < 80.0 || !isfinite(h) || h < 80.0) return 0.0;
    CGFloat view = _ps688View >= 0.0 ? _ps688View : 57.0;
    CGFloat o = floor([self phoneSize684Pin] - h / (w / phoneW) - view + 0.01);
    return MAX(0.0, MIN(150.0, o));
}

- (CGFloat)phoneSize688Line {
    return [self phoneSize684Pin] - [self phoneSize688O];
}

// Where the app's picture starts inside the host view (the scene origin can be
// copied into the presentation view's frame). Measured; tune shift= overrides.
- (CGFloat)phoneSize688Shift {
    if (_ps688Shift > -500.0) return _ps688Shift;
    UIView *host = _hostView;
    if (!host) return 0.0;
    CGFloat found = 0.0;
    NSString *foundName = @"none";
    @try {
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithArray:host.subviews];
        UIView *fallback = nil;
        NSInteger visited = 0;
        UIView *hit = nil;
        while (queue.count > 0 && visited < 300) {
            UIView *view = queue.firstObject;
            [queue removeObjectAtIndex:0];
            visited += 1;
            NSString *name = NSStringFromClass(object_getClass(view));
            if ([name rangeOfString:@"ScenePresentation"].location != NSNotFound) {
                hit = view;
                break;
            }
            if (!fallback && [name rangeOfString:@"SceneLayerHost"].location != NSNotFound) fallback = view;
            [queue addObjectsFromArray:view.subviews];
        }
        if (!hit) hit = fallback;
        if (hit) {
            CGPoint origin = [hit convertPoint:CGPointZero toView:host];
            if (isfinite(origin.y) && origin.y > -20.0 && origin.y < 160.0) {
                found = origin.y;
                foundName = NSStringFromClass(object_getClass(hit));
            }
        }
    } @catch (NSException *exception) {
        found = 0.0;
    }
    found = round(found * 2.0) / 2.0;
    if (fabs(found - _ps688LoggedShift) > 0.25) {
        _ps688LoggedShift = found;
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize688 %@ picture starts at host y %.1f (%@); card bottom = host y %.0f = window y %.0f (keyboard line)",
                                  _bundleIdentifier ?: @"?", found, foundName, [self phoneSize688Line] + found, [self phoneSize688Line]);
    }
    return found;
}

// 4.5.688 mode=statusbar: the status bar height to give the scene (0 = leave it).
- (CGFloat)phoneSize688StatusBarHeight {
    if (![self isPhoneSize684] || !_ps688Active || _ps685Active || _ps687Active || _ps688Mode != DSPhoneSize688ModeStatusBar) return 0.0;
    if (_ps688StatusBar >= 0.0) return _ps688StatusBar;
    CGFloat top = [self phoneSize684Insets].top;
    return (isfinite(top) && top > 1.0) ? top : 0.0;
}

- (BOOL)isPhoneSize687 {
    return [self isPhoneSize684] && _ps687Active && !_ps685Active;
}

// 4.5.687: app y on the card's top edge (the phone's own top inset by default).
- (CGFloat)phoneSize687ViewTop {
    CGFloat view = _ps687View;
    if (view < 0.0) {
        view = [self phoneSize675ScreenInsets].top;
        if (!isfinite(view) || view < 1.0 || view > 117.0) view = 59.0;
    }
    return view;
}

// 4.5.687: where the app's bar rests (scene y): the card shows app y
// view..view + cardH/fit at the 684 fill, the bar sits margin pt above the card
// bottom. Never below the keyboard top (684's line), so the bottom inset stays at
// least the keyboard height.
- (CGFloat)phoneSize687Bar {
    CGSize phone = [self phoneSize675SceneSize];
    UIView *parent = _hostView.superview;
    CGFloat w = CGRectGetWidth(parent.bounds);
    CGFloat h = CGRectGetHeight(parent.bounds);
    if (!isfinite(w) || w < 80.0 || !isfinite(h) || h < 80.0) {
        w = CGRectGetWidth(_stageFrame);
        h = CGRectGetHeight(_stageFrame);
    }
    CGFloat line = [self phoneSize684Pin];
    if (!(phone.width > 1.0) || !isfinite(w) || w < 80.0 || !isfinite(h) || h < 80.0) return line;
    CGFloat fit = w / phone.width;
    CGFloat bar = floor([self phoneSize687ViewTop] + h / fit - MAX(0.0, _ps687Margin) + 0.01);
    return MAX(300.0, MIN(line, bar));
}

// 4.5.686: app y on the card's top edge (the phone's own top inset by default).
- (CGFloat)phoneSize685ViewTop {
    CGFloat view = _ps685View;
    if (view < 0.0) {
        view = [self phoneSize675ScreenInsets].top;
        if (!isfinite(view) || view < 1.0 || view > 120.0) view = 59.0;
    }
    return view;
}

// Scale of the app on the card. Normally the card width over the scene width.
// 4.5.686 (685 on): small enough that app y view..(bar line + margin) fits the
// card height; the app is centred, the card's own background fills the sides.
- (CGFloat)phoneSize675FitForWidth:(CGFloat)width height:(CGFloat)height {
    CGSize phone = [self phoneSize675SceneSize];
    CGFloat fit = phone.width > 0.0 && width > 0.0 ? width / phone.width : 1.0;
    if ([self isPhoneSize685] && isfinite(width) && isfinite(height) && width >= 80.0 && height >= 80.0) {
        CGFloat bottom = MIN(phone.height, [self phoneSize684Pin] + MAX(0.0, _ps685Margin));
        CGFloat view = MAX(0.0, MIN(bottom - 200.0, [self phoneSize685ViewTop]));
        CGFloat span = bottom - view;
        if (span > 1.0 && height / span < fit) fit = height / span;
        fit = MAX(0.5, fit);
    }
    return fit;
}

// The phone-size scene's full height (931 on a 932 pt phone).
- (CGFloat)phoneSize684PhoneHeight {
    return [self cameraTallSize].height - 1.0;
}

// Scene y of the app's bar bottom = the keyboard top in the scene.
- (CGFloat)phoneSize684Pin {
    CGFloat phoneH = [self phoneSize684PhoneHeight];
    if (_ps685Active && _ps685KeyTop >= 450.0 && _ps685KeyTop <= phoneH - 100.0) return _ps685KeyTop;
    CGFloat k = (_ps684K >= 100.0 && _ps684K <= 600.0) ? _ps684K : 345.0;
    return phoneH - k;
}

- (BOOL)phoneSize684Eligible {
    if (_cameraTall || !DSPhoneSize684Enabled()) return NO;
    NSString *bundle = _bundleIdentifier;
    if (bundle.length == 0 || !DSPhoneSize675Allowed(bundle)) return NO;
    @try {
        DSStageManager *manager = [DSStageManager sharedManager];
        if ([manager respondsToSelector:@selector(keys671AppHasDylib:)] && [manager keys671AppHasDylib:bundle]) return NO;
    } @catch (NSException *exception) {
        return NO;
    }
    return YES;
}

// K: the tune file, else what this app's keyboard settled at, else the
// default: the 346 pt keyboard at the screen bottom (top 586) = 931 - 586 = 345.
- (CGFloat)phoneSize684WantedK:(NSString **)source {
    DSPhoneSize684Tune tune = DSPhoneSize684CurrentTune();
    if (tune.bottom >= 100.0) {
        if (source) *source = @"tune file bottom=";
        return tune.bottom;
    }
    NSNumber *learned = _bundleIdentifier ? DSPS684Learned[_bundleIdentifier] : nil;
    if (learned) {
        if (source) *source = @"learned from this app's settled keyboard";
        return (CGFloat)[learned doubleValue];
    }
    CGFloat screenH = [self cameraTallSize].height;
    if (source) *source = @"default (346 pt keyboard, top 586)";
    return [self phoneSize684PhoneHeight] - (screenH - 346.0);
}

- (void)phoneSize684Configure {
    _ps684Active = [self phoneSize684Eligible];
    _ps684KeysUp = NO;
    _ps684CurTop = 0.0;
    _ps684Durations = nil;
    _ps684LoggedTop = 0.0;
    _ps684LoggedArbiterH = -1.0;
    _ps685Active = NO;
    _ps687Active = NO;
    _ps688Active = NO;
    _ps691Mode = 0;
    if (!_ps684Active) return;
    NSString *source = nil;
    _ps684K = [self phoneSize684WantedK:&source];
    _ps684KSource = source;
    DSPhoneSize684Tune tune = DSPhoneSize684CurrentTune();
    _ps684Short = tune.shortMode;
    _ps684TopFixed = tune.top;
    _ps685Active = DSPhoneSize685Enabled();
    DSPhoneSize685Tune t5 = DSPhoneSize685CurrentTune();
    _ps685Slack = t5.slack;
    _ps685View = t5.view;
    _ps685Margin = t5.margin;
    _ps685TopFixed = t5.top;
    _ps685KeyTop = t5.keyTop;
    _ps687Active = !_ps685Active && DSPhoneSize687Enabled();
    DSPhoneSize687Tune t7 = DSPhoneSize687CurrentTune();
    _ps687View = t7.view;
    _ps687Margin = t7.margin;
    _ps687TopFixed = t7.top;
    _ps688Active = !_ps685Active && !_ps687Active && DSPhoneSize688Enabled();
    DSPhoneSize688Tune t8 = DSPhoneSize688CurrentTune();
    _ps688Mode = t8.mode;
    _ps688View = t8.view;
    _ps688Offset = t8.offset;
    _ps688Shift = t8.shift;
    _ps688StatusBar = t8.statusBar;
    _ps688LoggedShift = -9999.0;
    BOOL geo691 = !_ps685Active && !_ps687Active &&
                  !(_ps688Active && (_ps688Mode == DSPhoneSize688ModeOffset || _ps688Mode == DSPhoneSize688ModeShort));
    [self phoneSize691Want:geo691 topTuneAuto:tune.top < 0.0 mode:&_ps691Mode value:&_ps691Value stripH:&_ps691StripH placeY:&_ps691PlaceY];
    if (_ps691Mode != 0) DSPhoneSize691MarkTrying();
}

// 4.5.691: what the top inset should be (see DSPhoneSize691Tune).
- (void)phoneSize691Want:(BOOL)geoOK topTuneAuto:(BOOL)topAuto mode:(NSInteger *)mode value:(CGFloat *)value stripH:(CGFloat *)stripH placeY:(CGFloat *)placeY {
    NSInteger m = 0;
    CGFloat v = 0.0, h = 0.0, y = 0.0;
    @try {
        if (geoOK && topAuto && !DSPhoneSize691Off() && !DSPhoneSize691Latched() && !DSPhoneSize694Squash()) {
            DSPhoneSize691Tune t91 = DSPhoneSize691CurrentTune();
            if (t91.mode == 2) {
                m = 2;
                v = t91.value;
            } else if (t91.mode == 1) {
                DSPhoneSize690Tune t90 = DSPhoneSize690CurrentTune();
                if (t90.on && !DSPhoneSize690Off() && !DSPhoneSize690Latched()) {
                    m = 1;
                    h = t90.stripHeight;
                    y = t90.placeY;
                }
            }
        }
    } @catch (NSException *exception) {
        m = 0;
    }
    if (mode) *mode = m;
    if (value) *value = v;
    if (stripH) *stripH = h;
    if (placeY) *placeY = y;
}

// {T, 0, K, 0}; T = the scene y on the card's top edge (the app starts there).
- (UIEdgeInsets)phoneSize684Insets {
    CGFloat pin = [self phoneSize684Pin];
    CGFloat top = 0.0;
    CGFloat topFixed = _ps685Active ? _ps685TopFixed : _ps684TopFixed;
    if (topFixed >= 0.0) {
        top = topFixed;
    } else {
        UIView *parent = _hostView.superview;
        CGFloat w = CGRectGetWidth(parent.bounds);
        CGFloat h = CGRectGetHeight(parent.bounds);
        // 4.5.695: while minimised the view sits in the full-screen hidden
        // holder (tag 9158); the top inset is still the card's (118), not 0.
        BOOL held695 = parent.tag == 9158 && DSPhoneSize695Enabled();
        if (held695 || !isfinite(w) || w < 80.0 || !isfinite(h) || h < 80.0) {
            w = CGRectGetWidth(_stageFrame);
            h = CGRectGetHeight(_stageFrame);
        }
        CGFloat sceneW = [self phoneSize675SceneSize].width;
        CGFloat fit = (sceneW > 1.0 && isfinite(w) && w >= 80.0) ? w / sceneW : 0.0;
        // 4.5.686: the app y on the card's top edge for the 685 scale (59 by default).
        CGFloat cardBottom = pin;
        if (_ps685Active && fit > 0.01 && isfinite(h) && h >= 80.0) {
            fit = [self phoneSize675FitForWidth:w height:h];
            cardBottom = MIN([self phoneSize675SceneSize].height, pin + MAX(0.0, _ps685Margin));
        }
        if (fit > 0.01 && isfinite(h) && h >= 80.0) top = ceil(cardBottom - h / fit - 0.01);
        else top = pin - 469.0;
    }
    // 4.5.738: top737 removed. The band in IMG_4476 was the 690 copied top-bar
    // strip, shown only because the 734/735 relay crashes had latched the 694
    // squash off (Slide log: "phonesize694 squash LATCHED OFF"); with the squash
    // the real Beeper bar is shown and there is no strip. top737's lower inset
    // would have put Beeper's content under its real bar.
    top = MAX(0.0, MIN(pin - 100.0, top));
    CGFloat bottom = (_ps685Active && _ps685Slack >= 0.0) ? _ps685Slack : (_ps684Short ? 0.0 : [self phoneSize684PhoneHeight] - pin);
    if ([self isPhoneSize688Geo]) {
        // 4.5.688 offset/short: {card top window y, 0, K, 0}: bar rests at
        // (931 - o) - K = 586 - o, the keyboard top in the window.
        CGFloat line = [self phoneSize688Line];
        CGFloat w = CGRectGetWidth(_hostView.superview.bounds);
        CGFloat h = CGRectGetHeight(_hostView.superview.bounds);
        if (!isfinite(w) || w < 80.0 || !isfinite(h) || h < 80.0) {
            w = CGRectGetWidth(_stageFrame);
            h = CGRectGetHeight(_stageFrame);
        }
        CGFloat phoneW = [self cameraTallSize].width;
        CGFloat t = (phoneW > 1.0 && isfinite(w) && w >= 80.0 && isfinite(h) && h >= 80.0) ? ceil(line - h / (w / phoneW) - 0.01) : 59.0;
        bottom = [self phoneSize684PhoneHeight] - pin;
        top = MAX(0.0, MIN(line - 100.0, t));
    }
    if (_ps687Active && !_ps685Active) {
        // 4.5.687: bar raised to phoneSize687Bar, inset below it; top = the card's top app y.
        CGFloat bar = [self phoneSize687Bar];
        bottom = [self phoneSize684PhoneHeight] - bar;
        top = _ps687TopFixed >= 0.0 ? _ps687TopFixed : [self phoneSize687ViewTop];
        top = MAX(0.0, MIN(bar - 100.0, top));
    }
    if (_ps691Mode != 0 && topFixed < 0.0 && !_ps685Active && !_ps687Active && ![self isPhoneSize688Geo]) {
        // 4.5.691: only the top inset moves, to the strip's bottom edge in app y.
        CGFloat t691 = top;
        if (_ps691Mode == 2) {
            t691 = _ps691Value;
        } else {
            CGFloat w = CGRectGetWidth(_hostView.superview.bounds);
            if (!isfinite(w) || w < 80.0) w = CGRectGetWidth(_stageFrame);
            CGFloat sceneW = [self phoneSize675SceneSize].width;
            CGFloat fit = (sceneW > 1.0 && isfinite(w) && w >= 80.0) ? w / sceneW : 0.9767;
            if (!isfinite(fit) || fit < 0.3) fit = 0.9767;
            t691 = ceil(top + _ps691PlaceY / fit + _ps691StripH - 0.01);
        }
        if (isfinite(t691)) top = MAX(0.0, MIN(pin - 100.0, t691));
    }
    return UIEdgeInsetsMake(top, 0.0, bottom, 0.0);
}

- (NSString *)phoneSize684Summary {
    CGSize phone = [self phoneSize675SceneSize];
    UIView *parent = _hostView.superview;
    CGFloat w = CGRectGetWidth(parent.bounds);
    CGFloat fit = phone.width > 0 && w > 1.0 ? [self phoneSize675FitForWidth:w height:CGRectGetHeight(parent.bounds)] : 0.0;
    NSString *extra = @"";
    if (_ps685Active) {
        extra = [NSString stringWithFormat:@", 685: card shows app y %.0f..bar line %.0f + margin %.0f (scaled to fit, sides filled)%@%@",
                 [self phoneSize685ViewTop], [self phoneSize684Pin], _ps685Margin,
                 _ps685Slack >= 0.0 ? [NSString stringWithFormat:@", scene cut %.0f pt below the bar (slack tune)", _ps685Slack] : @"",
                 _ps685KeyTop > 0.0 ? @" (keytop from the 685 tune)" : @""];
    } else if (_ps687Active) {
        extra = [NSString stringWithFormat:@", 687: bar raised to %.0f (keyboard top %.0f), bottom inset %.0f, card shows app y %.0f..%.0f at the 684 fill",
                 [self phoneSize687Bar], [self phoneSize684Pin], [self phoneSize684PhoneHeight] - [self phoneSize687Bar],
                 [self phoneSize687ViewTop], [self phoneSize687Bar] + _ps687Margin];
    } else if ([self isPhoneSize688Geo]) {
        extra = [NSString stringWithFormat:@", 688 mode=%@: scene frame %@, keyboard line = resting bar = card bottom at window y %.0f (586 - o %.0f), bottom inset %.0f, top inset %.0f",
                 DSPhoneSize688ModeName(_ps688Mode), NSStringFromCGRect([self frameForScene]), [self phoneSize688Line], [self phoneSize688O],
                 [self phoneSize684PhoneHeight] - [self phoneSize684Pin], [self phoneSize684Insets].top];
    } else if (_ps688Active && _ps688Mode == DSPhoneSize688ModeStatusBar) {
        extra = [NSString stringWithFormat:@", 688 mode=statusbar: 684 geometry + scene status bar height %.0f", [self phoneSize688StatusBarHeight]];
    } else if (_ps688Active) {
        extra = @", 688 mode=684 (exact 684)";
    } else if (_ps684Short) {
        extra = @", mode=short (scene ends at the keyboard top)";
    }
    if (_ps691Mode != 0) {
        extra = [extra stringByAppendingFormat:@", 691: top inset raised to %.0f (%@) so safe-area content starts below the recreated top bar; frame, bottom inset and bar line as 684",
                 [self phoneSize684Insets].top, _ps691Mode == 1 ? [NSString stringWithFormat:@"strip bottom: auto + %.0f", _ps691StripH] : @"top_inset tune"];
    }
    return [NSString stringWithFormat:@"scene %.0fx%.0f safeArea %@: card shows %@ at x%.4f, fixed (keyboard up or down); K=%.0f (%@)%@; "
            @"keys stay at the phone bottom (keys674 NO); no 680-682 window moves",
            phone.width, phone.height, NSStringFromUIEdgeInsets([self phoneSize684Insets]),
            [self phoneSize680Region:([self isPhoneSize688Geo] ? [self phoneSize688Line] + [self phoneSize688Shift] : [self phoneSize684Pin])], fit,
            _ps684K, _ps684KSource ?: @"?", extra];
}

- (void)phoneSize684Accumulate:(double)now {
    if (_ps684CurTop <= 0.0 || _ps684CurSince <= 0.0) return;
    double dt = now - _ps684CurSince;
    if (!isfinite(dt) || dt < 0.0 || dt > 600.0) dt = 0.0;
    if (!_ps684Durations) _ps684Durations = [NSMutableDictionary dictionary];
    NSNumber *key = @(_ps684CurTop);
    _ps684Durations[key] = @([_ps684Durations[key] doubleValue] + dt);
    _ps684CurSince = now;
}

- (void)phoneSize684StartKeys {
    if (_ps684KeysUp) return;
    _ps684KeysUp = YES;
    _ps684ApplyToken += 1; // no apply while typing
    _ps684Durations = [NSMutableDictionary dictionary];
    _ps684CurTop = 0.0;
    _ps684CurSince = 0.0;
}

// Keyboard note (stage keys top, screen y = scene y at origin 0): learned only.
- (void)phoneSize684NoteKeyTop:(CGFloat)keyTop why:(NSString *)why {
    CGFloat phoneH = [self phoneSize684PhoneHeight];
    if (!isfinite(keyTop) || keyTop <= 250.0 || keyTop >= phoneH - 100.0) return;
    if (!_ps755Owned && DSK755On()) {
        DSFeature719MarkAction("k755");
        return;   // another app's keyboard: not this app's K
    }
    double now = CACurrentMediaTime();
    [self phoneSize684StartKeys];
    [self phoneSize684Accumulate:now];
    _ps684CurTop = round(keyTop);
    _ps684CurSince = now;
    if (fabs(_ps684LoggedTop - keyTop) > 0.5) {
        _ps684LoggedTop = keyTop;
        CGFloat pin = [self phoneSize684Pin];
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize684 %@ keyboard top %.0f (%@): window fixed at %@, no move; %@",
                                  _bundleIdentifier ?: @"?", keyTop, why ?: @"?", [self phoneSize680Region:pin],
                                  fabs(keyTop - pin) < 1.5 ? [NSString stringWithFormat:@"matches the bar bottom %.0f (K=%.0f): the app's bar should not move", pin, _ps684K]
                                                           : [NSString stringWithFormat:@"differs from the bar bottom %.0f by %+.0f pt (K=%.0f): the app's bar may move by that much this time; K is re-learned when the keys go down",
                                                              pin, keyTop - pin, _ps684K]);
    }
}

// 4.5.755 k755: K is learned only from this app's own keyboard. The 754 log
// learned Beeper's K 300 from Messages' keyboard (16:09:45.347) and moved its
// bar 45 pt down. The keyboard system calling this method (it names this app
// as the owner) is now the only thing that starts a keyboard session here;
// notes from another app's keyboard are not counted.
// Off: k755-off / core755-off (crash latch k755).
static BOOL DSK755On(void) {
    return DSFeature699On("core755") && DSFeature699On("k755");
}

- (void)phoneSize684ArbiterOn:(BOOL)on height:(CGFloat)height at:(double)mediaTime {
    if (![self isPhoneSize684]) return;
    if (on) _ps755Owned = YES;
    if (on) {
        BOOL fresh = !_ps684KeysUp;
        [self phoneSize684StartKeys];
        if (fresh || fabs(_ps684LoggedArbiterH - height) > 0.5) {
            _ps684LoggedArbiterH = height;
            DSDiagnosticsRecordFormat(@"SpringBoard: phonesize684 %@ arbiter on=1 height %.0f at %.3f: window fixed at %@, no move (684)%@",
                                      _bundleIdentifier ?: @"?", height, mediaTime, [self phoneSize680Region:[self phoneSize684Pin]],
                                      fresh ? @"; keys at the phone bottom (keys674 NO)" : @" (height change)");
        }
    } else {
        _ps684LoggedArbiterH = -1.0;
        [self phoneSize684KeysDown:[NSString stringWithFormat:@"arbiter on=0 at %.3f", mediaTime]];
    }
}

- (void)phoneSize684KeysDown:(NSString *)why {
    if (_ps684KeysUp) {
        double now = CACurrentMediaTime();
        [self phoneSize684Accumulate:now];
        _ps684KeysUp = NO;
        _ps684CurTop = 0.0;
        _ps684LoggedTop = 0.0;
        CGFloat settled = 0.0;
        double best = -1.0;
        double total = 0.0;
        for (NSNumber *top in _ps684Durations) {
            double d = [_ps684Durations[top] doubleValue];
            total += d;
            if (d > best) {
                best = d;
                settled = (CGFloat)[top doubleValue];
            }
        }
        NSString *learnedNote = @"no keyboard top seen (no note): K unchanged";
        if (settled > 0.0 && best >= 0.15) {
            CGFloat k = round([self phoneSize684PhoneHeight] - settled);
            k = MAX(200.0, MIN(500.0, k));
            if (!DSPS684Learned) DSPS684Learned = [NSMutableDictionary dictionary];
            NSNumber *old = _bundleIdentifier ? DSPS684Learned[_bundleIdentifier] : nil;
            // 4.5.701 keys701 (Beeper bar log, 15:23:24-15:23:47): one keyboard
            // that was taller for part of its time (288 -> 337 high, top 586 ->
            // 537, 1935 of 2897 ms) re-learned K 345 -> 394 at once; the next
            // keys-down moved the whole picture (bar line 537, card shows app y
            // 68..537) and every normal keyboard (top 586) then covered the
            // message bar by 49 pt until two more keyboards learned 345 back.
            // A K that differs from the one in use by more than 4 pt is now
            // only taken when the next keyboard settles at the same K; within
            // 4 pt the K in use is kept (no 1-4 pt churn).
            // Off: /var/mobile/.dynamicstage-keys701-off.
            CGFloat base = old ? (CGFloat)[old doubleValue] : (_ps684K > 0.0 ? _ps684K : 0.0);
            NSString *held701 = nil;
            if (_bundleIdentifier && base > 0.0 && DSFeature699On("keys701")) {
                if (!DSPS701PendingK) DSPS701PendingK = [NSMutableDictionary dictionary];
                NSNumber *pending = DSPS701PendingK[_bundleIdentifier];
                if (fabs(k - base) <= 4.0) {
                    [DSPS701PendingK removeObjectForKey:_bundleIdentifier];
                    if (fabs(k - base) > 0.5) held701 = [NSString stringWithFormat:@"keys701: within 4 pt of %.0f, kept", base];
                    k = base;
                } else if (pending && fabs([pending doubleValue] - k) <= 4.0) {
                    [DSPS701PendingK removeObjectForKey:_bundleIdentifier];
                    held701 = @"keys701: confirmed by a second keyboard";
                } else {
                    DSPS701PendingK[_bundleIdentifier] = @(k);
                    DSFeature699MarkTrying("keys701");
                    held701 = [NSString stringWithFormat:@"keys701: K %.0f seen once, K %.0f kept until a second keyboard settles there too", k, base];
                    k = base;
                }
            }
            if (_bundleIdentifier) DSPS684Learned[_bundleIdentifier] = @(k);
            learnedNote = [NSString stringWithFormat:@"settled keyboard top %.0f (%.0f of %.0f ms, %lu value%@) -> learned K %.0f (was %@; in use %.0f)%@%@",
                           settled, best * 1000.0, total * 1000.0, (unsigned long)_ps684Durations.count, _ps684Durations.count == 1 ? @"" : @"s",
                           k, old ? [NSString stringWithFormat:@"%.0f", [old doubleValue]] : @"none", _ps684K,
                           held701 ? @"; " : @"", held701 ?: @""];
        } else if (settled > 0.0) {
            learnedNote = [NSString stringWithFormat:@"keyboard top %.0f held only %.0f ms: not learned", settled, best * 1000.0];
        }
        _ps684Durations = nil;
        _ps755Owned = NO;
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize684 %@ keyboard down (%@): window fixed, no move; %@",
                                  _bundleIdentifier ?: @"?", why ?: @"?", learnedNote);
    }
    [self phoneSize684ScheduleApply:why];
}

// A changed K / tune / off file is written only with the keys down for 1.2 s.
- (void)phoneSize684ScheduleApply:(NSString *)why {
    [self phoneSize684ScheduleApply:why attempt:0];
}

- (void)phoneSize684ScheduleApply:(NSString *)why attempt:(NSInteger)attempt {
    NSInteger token = ++_ps684ApplyToken;
    __weak __typeof(self) weakSelf = self;
    NSString *reason = [why copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || token != strongSelf->_ps684ApplyToken) return;
        @try {
            [strongSelf phoneSize684ApplyIfNeeded:reason attempt:attempt];
        } @catch (NSException *exception) {
            DSDiagnosticsRecordFormat(@"SpringBoard: phonesize684 apply threw %@", exception.reason ?: exception.name ?: @"?");
        }
    });
}

- (void)phoneSize684ApplyIfNeeded:(NSString *)why attempt:(NSInteger)attempt {
    if (!_phoneSize || _cameraTall || !_appViewController || _ps684KeysUp) return;
    BOOL stageKeys = NO;
    @try {
        DSStageManager *manager = [DSStageManager sharedManager];
        stageKeys = [manager respondsToSelector:@selector(stagedKeyboardIsUp)] && [manager stagedKeyboardIsUp];
    } @catch (NSException *exception) {
        stageKeys = NO;
    }
    if (stageKeys || DSSceneWriteWouldTrap() || DSStageDragSettlingFast(0.6)) {
        // Never while some keyboard is up, a scene update runs or a card is dragged.
        if (attempt < 12) [self phoneSize684ScheduleApply:why attempt:attempt + 1];
        return;
    }
    if (!_ps684Active && [self phoneSize680BarBottom] < [self phoneSize678BottomAnchor] - 0.5) return; // 682 window not at rest
    BOOL want = [self phoneSize684Eligible];
    NSString *source = nil;
    CGFloat k = want ? [self phoneSize684WantedK:&source] : 0.0;
    DSPhoneSize684Tune tune = DSPhoneSize684CurrentTune();
    BOOL want685 = want && DSPhoneSize685Enabled();
    DSPhoneSize685Tune t5 = DSPhoneSize685CurrentTune();
    BOOL want687 = want && !want685 && DSPhoneSize687Enabled();
    DSPhoneSize687Tune t7 = DSPhoneSize687CurrentTune();
    BOOL want688 = want && !want685 && !want687 && DSPhoneSize688Enabled();
    DSPhoneSize688Tune t8 = DSPhoneSize688CurrentTune();
    NSInteger m691 = 0;
    CGFloat v691 = 0.0, h691 = 0.0, y691 = 0.0;
    if (want) {
        BOOL geo691 = !want685 && !want687 && !(want688 && (t8.mode == DSPhoneSize688ModeOffset || t8.mode == DSPhoneSize688ModeShort));
        [self phoneSize691Want:geo691 topTuneAuto:tune.top < 0.0 mode:&m691 value:&v691 stripH:&h691 placeY:&y691];
    }
    BOOL changed691 = want && (m691 != _ps691Mode || fabs(v691 - _ps691Value) > 0.5 || fabs(h691 - _ps691StripH) > 0.5 || fabs(y691 - _ps691PlaceY) > 0.5);
    BOOL changed = changed691 || want != _ps684Active ||
                   (want && (fabs(k - _ps684K) > 0.5 || tune.shortMode != _ps684Short || fabs(tune.top - _ps684TopFixed) > 0.5)) ||
                   (want && (want685 != _ps685Active ||
                             (want685 && (fabs(t5.slack - _ps685Slack) > 0.5 || fabs(t5.view - _ps685View) > 0.5 || fabs(t5.margin - _ps685Margin) > 0.5 || fabs(t5.top - _ps685TopFixed) > 0.5 || fabs(t5.keyTop - _ps685KeyTop) > 0.5)))) ||
                   (want && (want687 != _ps687Active ||
                             (want687 && (fabs(t7.view - _ps687View) > 0.5 || fabs(t7.margin - _ps687Margin) > 0.5 || fabs(t7.top - _ps687TopFixed) > 0.5)))) ||
                   (want && (want688 != _ps688Active ||
                             (want688 && (t8.mode != _ps688Mode || fabs(t8.view - _ps688View) > 0.5 || fabs(t8.offset - _ps688Offset) > 0.5 ||
                                          fabs(t8.shift - _ps688Shift) > 0.5 || fabs(t8.statusBar - _ps688StatusBar) > 0.5))));
    if (!changed) return;
    NSString *before = _ps684Active ? [NSString stringWithFormat:@"684 K=%.0f%@ top=%@%@", _ps684K, _ps684Short ? @" short" : @"",
                                       _ps684TopFixed >= 0.0 ? [NSString stringWithFormat:@"%.0f", _ps684TopFixed] : @"auto",
                                       _ps685Active ? [NSString stringWithFormat:@" + 685 view=%.0f margin=%.0f slack=%.0f top=%@ keytop=%@", _ps685View, _ps685Margin, _ps685Slack,
                                                       _ps685TopFixed >= 0.0 ? [NSString stringWithFormat:@"%.0f", _ps685TopFixed] : @"auto",
                                                       _ps685KeyTop > 0.0 ? [NSString stringWithFormat:@"%.0f", _ps685KeyTop] : @"auto"] : @""]
                                    : @"682 rules";
    _ps684Active = want;
    if (want) {
        _ps684K = k;
        _ps684KSource = source;
        _ps684Short = tune.shortMode;
        _ps684TopFixed = tune.top;
        _ps685Active = want685;
        _ps685Slack = t5.slack;
        _ps685View = t5.view;
        _ps685Margin = t5.margin;
        _ps685TopFixed = t5.top;
        _ps685KeyTop = t5.keyTop;
        _ps687Active = want687;
        _ps687View = t7.view;
        _ps687Margin = t7.margin;
        _ps687TopFixed = t7.top;
        _ps688Active = want688;
        _ps688Mode = t8.mode;
        _ps688View = t8.view;
        _ps688Offset = t8.offset;
        _ps688Shift = t8.shift;
        _ps688StatusBar = t8.statusBar;
        _ps688LoggedShift = -9999.0;
        if (changed691) {
            DSDiagnosticsRecordFormat(@"SpringBoard: phonesize691 %@ top inset %@ -> %@ (only the top inset; frame, bottom inset, bar line unchanged)",
                                      _bundleIdentifier ?: @"?",
                                      _ps691Mode == 0 ? @"684 auto" : (_ps691Mode == 1 ? [NSString stringWithFormat:@"auto+strip %.0f", _ps691StripH] : [NSString stringWithFormat:@"%.0f", _ps691Value]),
                                      m691 == 0 ? @"684 auto" : (m691 == 1 ? [NSString stringWithFormat:@"auto+strip %.0f", h691] : [NSString stringWithFormat:@"%.0f", v691]));
        }
        _ps691Mode = m691;
        _ps691Value = v691;
        _ps691StripH = h691;
        _ps691PlaceY = y691;
        if (_ps691Mode != 0) DSPhoneSize691MarkTrying();
        _phoneSizeKeyTop = [self phoneSize684Pin];
    } else {
        _ps685Active = NO;
        _ps687Active = NO;
        _ps688Active = NO;
        _ps691Mode = 0;
        _phoneSizeKeyTop = [self phoneSize678BottomAnchor];
        _phoneSizePreGrown = YES;
    }
    _phoneSizeGeneration += 1;
    _phoneSizeDeferNoted = NO;
    DSPhoneSize675ChangedAt = CACurrentMediaTime();
    DSDiagnosticsRecordFormat(@"SpringBoard: phonesize684 %@ geometry change with the keys down (%@): %@ -> %@",
                              _bundleIdentifier ?: @"?", why ?: @"?", before,
                              want ? [self phoneSize684Summary] : @"682 rules (684 off / not eligible): safe area {59,0,34,0}, window follows the bar");
    [self phoneSize675WriteGeometry:_phoneSizeGeneration attempt:0];
}

// ---- 4.5.680 phonesize680 -----------------------------------------------------
- (void)phoneSize680GrowSoon {
    if (!DSPhoneSize680Enabled() || !DSPhoneSize675Allowed(_bundleIdentifier)) return;
    if (!_appViewController || DSSceneHostBundleDiedPending(_bundleIdentifier)) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - _ps680GrowAskAt < 1.0 && now >= _ps680GrowAskAt) return;
    _ps680GrowAskAt = now;
    __weak __typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_phoneSize) return;
        @try {
            DSStageManager *manager = [DSStageManager sharedManager];
            if ([manager respondsToSelector:@selector(phoneSize678HostReady:)]) [manager phoneSize678HostReady:strongSelf];
        } @catch (NSException *exception) {
            DSDiagnosticsRecordFormat(@"SpringBoard: phonesize680 grow threw %@", exception.reason ?: exception.name ?: @"?");
        }
    });
}

- (CGFloat)phoneSize680BarBottom {
    return _phoneSize ? MIN(_phoneSizeKeyTop, [self phoneSize675SceneSize].height) : 0.0;
}

- (NSString *)phoneSize680Region:(CGFloat)pin {
    UIView *parent = _hostView.superview;
    CGSize phone = [self phoneSize675SceneSize];
    CGFloat width = CGRectGetWidth(parent.bounds);
    CGFloat height = CGRectGetHeight(parent.bounds);
    CGFloat fit = phone.width > 0 ? [self phoneSize675FitForWidth:width height:height] : 1.0;
    CGFloat lowest = fit > 0.01 ? height / fit : phone.height;
    if ([self isPhoneSize685] && fabs(pin - [self phoneSize684Pin]) < 0.5) pin += MAX(0.0, _ps685Margin);
    if ([self isPhoneSize687] && fabs(pin - [self phoneSize684Pin]) < 0.5) pin = [self phoneSize687Bar] + MAX(0.0, _ps687Margin);
    CGFloat p = MAX(lowest, MIN(phone.height, pin));
    return [NSString stringWithFormat:@"app y %.0f..%.0f", p - height / MAX(fit, 0.01), p];
}

// The card's window onto the app ends at the bar's bottom: the bar stays on
// the card's bottom edge while the app moves it. Mapping only (the host view's
// position); never a scene write.
// 4.5.681: one explicit additive Core Animation animation of our own (key
// "ps681"), tuned by /var/mobile/.dynamicstage-phonesize681-tune. The 680 path
// (UIKit's curve-7 animation copied and re-added with a shifted beginTime) is gone.
- (void)phoneSize680MoveBarBottomTo:(CGFloat)bar duration:(NSTimeInterval)duration curve:(NSInteger)curve lag:(double)lag why:(NSString *)why {
    (void)duration;
    (void)curve;
    double now = CACurrentMediaTime();
    [self phoneSize681MoveBarBottomTo:bar hide:(bar >= [self phoneSize678BottomAnchor] - 0.5) signalAt:now - MAX(0.0, MIN(0.12, isfinite(lag) ? lag : 0.0)) offset:YES why:why];
}

- (void)phoneSize681MoveBarBottomTo:(CGFloat)bar hide:(BOOL)hide signalAt:(double)signalAt offset:(BOOL)applyOffset why:(NSString *)why {
    [self phoneSize682MoveBarBottomTo:bar hide:hide signalAt:signalAt offset:applyOffset instant:NO why:why];
}

- (void)phoneSize682MoveBarBottomTo:(CGFloat)bar hide:(BOOL)hide signalAt:(double)signalAt offset:(BOOL)applyOffset instant:(BOOL)forceInstant why:(NSString *)why {
    if (!_phoneSize || !_hostView) return;
    if ([self isPhoneSize684]) {
        // 4.5.684: the window is fixed; no 680-682 chasing.
        CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
        if (t - _ps684SkipLogAt > 5.0 || t < _ps684SkipLogAt) {
            _ps684SkipLogAt = t;
            DSDiagnosticsRecordFormat(@"SpringBoard: phonesize684 %@ 680/681/682 move to bar %.0f (%@) skipped (684 fixed window at app y %@)",
                                      _bundleIdentifier ?: @"?", bar, why ?: @"?", [self phoneSize680Region:[self phoneSize684Pin]]);
        }
        return;
    }
    if ([self isPhoneSize683]) {
        // 4.5.683: no region chasing; the pin is the scene bottom.
        if (fabs(_phoneSizeKeyTop - bar) >= 0.5) {
            DSDiagnosticsRecordFormat(@"SpringBoard: phonesize683 %@ 680-682 window move %.0f -> %.0f (%@) skipped: 683 keeps the window at the scene bottom",
                                      _bundleIdentifier ?: @"?", _phoneSizeKeyTop, bar, why ?: @"?");
        }
        _phoneSizeKeyTop = bar;
        return;
    }
    NSString *bundle = _bundleIdentifier ?: @"?";
    CGSize phone = [self phoneSize675SceneSize];
    if (!isfinite(bar)) return;
    DSPhoneSize681Tune tune = DSPhoneSize681CurrentTune();
    CGFloat anchor = [self phoneSize678BottomAnchor];
    // The offset only applies to the keyboard-up position (the rest position is the app's own bottom).
    CGFloat applied = (applyOffset && !hide && bar < anchor - 0.5) ? tune.offset : 0.0;
    bar = MAX(0.0, MIN(phone.height, bar - applied));
    CGFloat was = _phoneSizeKeyTop;
    BOOL atAnchor = bar >= anchor - 0.5;
    if (fabs(bar - was) < 0.5) {
        _phoneSizePreGrown = atAnchor;
        return;
    }
    double now = CACurrentMediaTime();
    if (!isfinite(signalAt) || signalAt > now || now - signalAt > 1.0) signalAt = now;
    NSString *before = [self phoneSize680Region:was];
    CALayer *layer = _hostView.layer;
    CALayer *shown = layer.presentationLayer ?: layer;
    CGPoint from = shown.position;
    // 4.5.682: no implicit actions for any of it; an instant change lands in
    // this frame's commit.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [layer removeAnimationForKey:@"ps681"];
    _phoneSizeKeyTop = bar;
    _phoneSizePreGrown = atAnchor;
    [self layoutHostView];
    CGPoint to = layer.position;
    BOOL showInstant = !hide && tune.showInstant;
    BOOL noAnim = DSPhoneSize680NoAnim() || forceInstant || showInstant;
    double ms = hide ? tune.hideDuration : tune.duration;
    NSInteger kind = hide ? tune.hideCurve : tune.curve;
    double delay = tune.delay / 1000.0;
    double begin = signalAt + delay;
    if (begin < now - 0.4) begin = now - 0.4;
    NSString *how = nil;
    CGFloat dy = from.y - to.y;
    if (noAnim || ms < 10.0 || fabs(dy) < 0.5) {
        how = forceInstant ? @"INSTANT (revert)"
            : showInstant ? @"INSTANT (show=instant, CATransaction actions off, lands in this frame)"
            : noAnim ? @"instant (/var/mobile/.dynamicstage-phonesize680-noanim)" : (ms < 10.0 ? @"instant (duration 0)" : @"instant (no distance)");
    } else {
        @try {
            CABasicAnimation *animation = nil;
            NSString *shape = nil;
            if (kind == DSPS681CurveKeyboard || kind == DSPS681CurveSpring) {
                CASpringAnimation *spring = [CASpringAnimation animationWithKeyPath:@"position"];
                if (kind == DSPS681CurveKeyboard) {
                    // Exactly what UIKit builds for UIViewAnimationCurve 7 (the
                    // keyboard): this spring with duration 0.5, ignoring the 0.25
                    // in the notification. Another duration plays it faster/slower.
                    spring.mass = 3.0;
                    spring.stiffness = 1000.0;
                    spring.damping = 500.0;
                    spring.initialVelocity = 0.0;
                    spring.duration = 0.5;
                    spring.speed = (float)(500.0 / ms);
                    shape = [NSString stringWithFormat:@"CASpringAnimation mass 3 stiffness 1000 damping 500 velocity 0, duration 0.5 x speed %.3f = %.0f ms (UIKit's curve-7 keyboard spring)",
                             spring.speed, ms];
                } else {
                    double t = ms / 1000.0;
                    double zeta = tune.springDamping;
                    spring.mass = 1.0;
                    spring.stiffness = pow(2.0 * M_PI / t, 2.0);
                    spring.damping = 4.0 * M_PI * zeta / t;
                    spring.initialVelocity = tune.springVelocity;
                    double settle = spring.settlingDuration;
                    spring.duration = (isfinite(settle) && settle > 0.05) ? MIN(settle, 3.0) : t;
                    shape = [NSString stringWithFormat:@"CASpringAnimation mass 1 stiffness %.1f damping %.2f (ratio %.2f) velocity %.2f, duration %.0f ms (settling %.0f ms; response %.0f ms)",
                             spring.stiffness, spring.damping, zeta, spring.initialVelocity, spring.duration * 1000.0, settle * 1000.0, ms];
                }
                spring.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
                animation = spring;
            } else {
                CABasicAnimation *basic = [CABasicAnimation animationWithKeyPath:@"position"];
                NSString *name = kCAMediaTimingFunctionEaseInEaseOut;
                if (kind == DSPS681CurveEaseOut) name = kCAMediaTimingFunctionEaseOut;
                else if (kind == DSPS681CurveLinear) name = kCAMediaTimingFunctionLinear;
                basic.timingFunction = [CAMediaTimingFunction functionWithName:name];
                basic.duration = ms / 1000.0;
                float c[4] = {0, 0, 0, 0};
                [basic.timingFunction getControlPointAtIndex:1 values:&c[0]];
                [basic.timingFunction getControlPointAtIndex:2 values:&c[2]];
                shape = [NSString stringWithFormat:@"CABasicAnimation %@ bezier (%.2f, %.2f, %.2f, %.2f), duration %.0f ms", name, c[0], c[1], c[2], c[3], ms];
                animation = basic;
            }
            // Additive: an offset from the model position that runs to zero, so
            // any other layout of the host view during it still lands right.
            animation.additive = YES;
            animation.fromValue = [NSValue valueWithCGPoint:CGPointMake(from.x - to.x, dy)];
            animation.toValue = [NSValue valueWithCGPoint:CGPointZero];
            animation.fillMode = kCAFillModeBackwards;
            animation.removedOnCompletion = YES;
            animation.beginTime = [layer convertTime:begin fromLayer:nil];
            [layer addAnimation:animation forKey:@"ps681"];
            how = [NSString stringWithFormat:@"%@; starts %+.0f ms from the signal (signal at %.3f, delay %+.0f ms, added %.0f ms after the signal)",
                   shape, (begin - signalAt) * 1000.0, signalAt, tune.delay, (now - signalAt) * 1000.0];
        } @catch (NSException *exception) {
            [layer removeAnimationForKey:@"ps681"];
            how = [NSString stringWithFormat:@"instant (animation threw %@)", exception.reason ?: exception.name ?: @"?"];
        }
    }
    [CATransaction commit];
    DSDiagnosticsRecordFormat(@"SpringBoard: phonesize682 %@ bar bottom %.0f -> %.0f (%@%@) t+%.0fms: card shows %@ -> %@ (%@); %@; host moves %.0f pt on the card",
                              bundle, was, bar, why ?: @"?", applied != 0.0 ? [NSString stringWithFormat:@", offset %+.1f", applied] : @"",
                              DSPhoneSize676Ms(), before, [self phoneSize680Region:bar],
                              atAnchor ? @"keyboard down, anchored above the home inset" : @"bar on the keyboard", how ?: @"?", to.y - from.y);
}

- (void)phoneSize676ReleaseHold:(NSString *)why animated:(BOOL)animated {
    UIView *snapshot = _phoneSizeHoldView;
    if (!snapshot) return;
    _phoneSizeHoldView = nil;
    DSDiagnosticsRecordFormat(@"SpringBoard: phonesize676 %@ picture hold OFF t+%.0fms (%@)", _bundleIdentifier ?: @"?", DSPhoneSize676Ms(), why ?: @"?");
    if (!animated) {
        [snapshot removeFromSuperview];
        return;
    }
    [UIView animateWithDuration:0.1 animations:^{
        snapshot.alpha = 0.0;
    } completion:^(__unused BOOL finished) {
        [snapshot removeFromSuperview];
    }];
}

// 4.5.659: an app view handed to the system home transition (a parked card
// while home is swiped) is driven by SpringBoard's own lifecycle until that
// hand-back has settled. Changing its mode or activating it inside that
// window, while SpringBoard is still finishing the transition, is the SIGTRAP
// of the 4.5.657 crash log (two stages, corner restore, "was woken").
- (BOOL)systemHomeLifecycleSettling {
    if (_followsSystemHome) return YES;
    return CFAbsoluteTimeGetCurrent() < _systemHomeSettleUntil;
}

- (void)activateHostedAppWhenMediaAllows {
    // 4.5.657: killed from the switcher; never wake or relaunch it from here.
    if (DSSceneHostBundleDiedPending(_bundleIdentifier)) return;
    // 4.5.659: still SpringBoard's lifecycle (home hand-back settling). Wait,
    // once, coalesced: several stage paths ask for the same wake at once.
    if ([self systemHomeLifecycleSettling]) {
        if (_wakeRetryScheduled) return;
        // About 5 s of following home plus the settle window, then give up;
        // tapping the card wakes it again.
        if (_wakeSettleAttempts >= 20) {
            _wakeSettleAttempts = 0;
            DSDiagnosticsRecordFormat(@"SpringBoard: home659 %@ wake dropped, its home-transition hand-back did not settle", _bundleIdentifier);
            return;
        }
        _wakeSettleAttempts += 1;
        _wakeRetryScheduled = YES;
        static CFAbsoluteTime DSLastSettleLog = 0;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - DSLastSettleLog > 1.0) {
            DSLastSettleLog = now;
            DSDiagnosticsRecordFormat(@"SpringBoard: home659 held the wake of %@ until its home-transition hand-back settles (following=%d, %.2fs left)",
                                      _bundleIdentifier, _followsSystemHome,
                                      _followsSystemHome ? -1.0 : MAX(0.0, _systemHomeSettleUntil - now));
        }
        CFAbsoluteTime wait = _followsSystemHome ? 0.4 : MAX(0.1, _systemHomeSettleUntil - now + 0.05);
        __weak __typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_wakeRetryScheduled = NO;
            if (!strongSelf->_appViewController || DSSceneHostBundleDiedPending(strongSelf->_bundleIdentifier)) return;
            BOOL settled = ![strongSelf systemHomeLifecycleSettling];
            [strongSelf activateHostedAppWhenMediaAllows];
            if (settled) {
                [strongSelf layoutHostView];
                DSDiagnosticsRecordFormat(@"SpringBoard: home659 %@ woken after its home-transition hand-back settled",
                                          strongSelf->_bundleIdentifier);
            }
        });
        return;
    }
    _wakeSettleAttempts = 0;
    if (DSSystemPullDepth > 0 || DSSceneSettingsUpdateDepth > 0) {
        if (_mediaActivateAttempts >= 8) return;
        _mediaActivateAttempts += 1;
        __weak __typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf activateHostedAppWhenMediaAllows];
        });
        return;
    }
    if (DSAvoidSceneLifecycle()) return;
    SBAppViewController *controller = _appViewController;
    if (!controller) return;
    NSString *playing = DSNowPlayingBundleIdentifier();
    BOOL otherVideo = DSVideoIsPlayingOnScreen() &&
                      playing.length > 0 &&
                      ![playing isEqualToString:_bundleIdentifier];
    if (otherVideo) {
        if (_mediaActivateAttempts >= 6) return;
        _mediaActivateAttempts += 1;
        __weak __typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf activateHostedAppWhenMediaAllows];
        });
        return;
    }
    _mediaActivateAttempts = 0;
    @try {
        // 4.5.800 fg800: if we parked Live->Static while SpringBoard backgrounded
        // the scene, put Live back before activation.
        [DSSceneHost fg800RestoreLiveIfNeeded:controller];
        // 4.5.659: right after a home-transition hand-back, an app view that
        // is already Live keeps its mode. Setting the mode again then is a
        // mode change SpringBoard asserts on if its transition is still
        // finishing; only the activation itself is needed. Every other wake
        // is unchanged.
        NSInteger currentMode = -1;
        if ([controller respondsToSelector:@selector(displayMode)]) {
            currentMode = ((NSInteger (*)(id, SEL))objc_msgSend)(controller, @selector(displayMode));
        }
        BOOL recentHandBack = _systemHomeSettleUntil > 0 && CFAbsoluteTimeGetCurrent() < _systemHomeSettleUntil + 4.0;
        if (!(recentHandBack && currentMode == 4)) {
            if ([controller respondsToSelector:@selector(_setCurrentMode:)]) [controller _setCurrentMode:2];
            if ([controller respondsToSelector:@selector(setDisplayMode:animationFactory:completion:)]) {
                [controller setDisplayMode:4 animationFactory:nil completion:nil];
            }
            if (recentHandBack) {
                DSDiagnosticsRecordFormat(@"SpringBoard: home659 %@ app view mode %ld -> live after the home hand-back", _bundleIdentifier, (long)currentMode);
            }
        } else {
            DSDiagnosticsRecordFormat(@"SpringBoard: home659 %@ already live after the home hand-back, activation only (no mode change)", _bundleIdentifier);
        }
        SEL activate = NSSelectorFromString(@"_activateApp");
        if ([controller respondsToSelector:activate]) {
            // 4.5.716 blackout716: this activation's foreground update may land
            // (see keepCommittedForegroundOfScene:onSettings:). Not Messages.
            if (_bundleIdentifier.length > 0 && ![_bundleIdentifier isEqualToString:@"com.apple.MobileSMS"]) {
                DSWake716Bundle = [_bundleIdentifier copy];
                DSWake716Until = CFAbsoluteTimeGetCurrent() + 2.0;
            }
            if (recentHandBack) {
                DSActivatingBundle = [_bundleIdentifier copy];
                DSActivatingUntil = CFAbsoluteTimeGetCurrent() + 1.5;
            }
            ((void (*)(id, SEL))objc_msgSend)(controller, activate);
        }
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: waking %@ threw %@", _bundleIdentifier, exception.name ?: @"?");
    }
}

- (void)wakeIfBackgrounded {
    // 4.5.657: killed from the switcher; never wake or relaunch it from here.
    if (DSSceneHostBundleDiedPending(_bundleIdentifier)) return;
    if (DSAvoidSceneLifecycle()) return;
    SBAppViewController *controller = _appViewController;
    if (!controller) return;
    // 4.5.801 fg801: restore Live + displayMode 4 / layerHosts immediately on
    // corner restore / blackout wake (do not wait for the next settings diff).
    [DSSceneHost fg800RestoreLiveIfNeeded:controller];
    BOOL foreground = YES;
    @try {
        FBScene *scene = [self appViewScene];
        FBSSceneSettings *settings = [scene respondsToSelector:@selector(settings)] ? scene.settings : nil;
        SEL isForeground = NSSelectorFromString(@"isForeground");
        if ([settings respondsToSelector:isForeground]) {
            foreground = ((BOOL (*)(id, SEL))objc_msgSend)(settings, isForeground);
        } else if ([settings respondsToSelector:@selector(foreground)]) {
            foreground = settings.foreground;
        }
    } @catch (NSException *exception) {
    }
    if (foreground && [self appViewIsShowingContent]) return;
    // 4.5.659: the wake waits for the home hand-back (see above); say so
    // instead of logging a wake that has not happened yet.
    if ([self systemHomeLifecycleSettling]) {
        [self activateHostedAppWhenMediaAllows];
        return;
    }
    [self activateHostedAppWhenMediaAllows];
    [self layoutHostView];
    DSDiagnosticsRecordFormat(@"SpringBoard: %@ had been put in the background off the stage and was woken",
                              _bundleIdentifier);
}

// Where on the screen the app should believe it is. A scene borrowed from
// SpringBoard is still positioned on the display, so it keeps the stage's own
// origin; a scene the stage created is presented inside the card and has no
// business anywhere but the card's own corner.
- (CGRect)frameForScene {
    CGRect logical = [self logicalFrame];
    CGFloat width = CGRectGetWidth(logical);
    CGFloat height = CGRectGetHeight(logical);
    if (width < 1.0 || height < 1.0) return logical;
    // The app view already lives inside the card. A screen origin, including
    // the old y=5 rewrite for a bottom card, is what UIScenePresentationView
    // copies into its own frame, so the picture leaves the rim.
    if (_hostView.superview || _ownSceneIdentifier || _matchCardFrame) {
        // 4.5.688 mode=offset: the scene starts o pt down the screen, so the
        // keyboard top (screen 586) is at window y 586 - o, the resting bar.
        if ([self isPhoneSize688Geo] && _ps688Mode == DSPhoneSize688ModeOffset) return CGRectMake(0.0, [self phoneSize688O], width, height);
        return CGRectMake(0.0, 0.0, width, height);
    }
    // Not in a card yet. Keep the scene off the bottom edge so iOS does not
    // host the keyboard inside it.
    CGRect screen = UIScreen.mainScreen.bounds;
    if (CGRectGetMaxY(logical) > CGRectGetHeight(screen) * 0.55) {
        logical.origin.x = 5.0;
        logical.origin.y = 5.0;
    }
    return logical;
}

- (void)fitHostViewToCard {
    [self layoutHostView];
}

- (void)markHostNeedsLiveRedraw {
    if (_revealingTallContent) return;
    UIView *host = _hostView;
    if (!host) return;
    host.contentMode = UIViewContentModeRedraw;
    host.layer.needsDisplayOnBoundsChange = YES;
    if (!_messagesKeyboardVisible) {
        host.clipsToBounds = YES;
        host.layer.masksToBounds = YES;
    }
    [host setNeedsLayout];
    [host layoutIfNeeded];
    [host.layer setNeedsDisplay];
}

- (void)sendRevealFrame:(CGRect)frame
             generation:(NSInteger)generation
              revealing:(BOOL)revealing
                attempt:(NSInteger)attempt {
    __weak __typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        DSSceneHost *host = weakSelf;
        if (!host || host->_revealGeneration != generation) return;
        if (host->_revealingTallContent != revealing) return;
        if (DSSceneWriteWouldTrap()) {
            if (attempt >= 8) {
                host->_revealWriteQueued = NO;
                return;
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                DSSceneHost *again = weakSelf;
                if (!again || again->_revealGeneration != generation) return;
                if (again->_revealingTallContent != revealing) return;
                [again sendRevealFrame:frame generation:generation revealing:revealing attempt:attempt + 1];
            });
            return;
        }
        CGRect use = frame;
        if (revealing && CGRectGetHeight(host->_stageFrame) > CGRectGetHeight(frame) + 12.0) {
            use = host->_stageFrame;
        }
        host->_contentScale = [DSPreferences sharedPreferences].scale;
        host->_stageFrame = use;
        host->_matchCardFrame = YES;
        // The picture has to be the tall size before the scene is told, or
        // the app lays out into the old half and the new area stays empty.
        // One update, after the finger callback has returned. Repeating this
        // on every move blanks the card.
        [host layoutHostView];
        [host setContentReferenceSizeOnAppView];
        [host beginSceneTransactionDeliveringActions:NO];
        [host setContentReferenceSizeOnAppView];
        [host forceSceneGeometry];
        if (revealing) host->_revealSizeSent = YES;
        host->_growSentHeight = CGRectGetHeight(use);
        host->_revealWriteQueued = NO;
        [host layoutHostView];
        if (revealing) {
            DSLogAppend([host growingContentDebugLine]);
        }
        if (revealing && CGRectGetHeight(host->_stageFrame) > CGRectGetHeight(use) + 28.0) {
            CGRect latest = host->_stageFrame;
            host->_revealWriteQueued = YES;
            host->_growSentHeight = CGRectGetHeight(latest);
            [host sendRevealFrame:latest generation:generation revealing:YES attempt:0];
        }
        if (!revealing) return;
        // The transaction finishes after we return and pins the scene back to
        // the full display. Put the tall card size back without another
        // transaction, or the new area stays black.
        for (NSNumber *delay in @[ @0.12, @0.35, @0.6 ]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                DSSceneHost *again = weakSelf;
                if (!again || again->_revealGeneration != generation) return;
                if (!again->_revealingTallContent || !again->_revealSizeSent) return;
                if (DSSceneWriteWouldTrap()) return;
                // A newer drag step already stored a taller size. Do not
                // put the old one back over it.
                if (CGRectGetHeight(again->_stageFrame) > CGRectGetHeight(frame) + 12.0) return;
                again->_stageFrame = frame;
                again->_matchCardFrame = YES;
                [again setContentReferenceSizeOnAppView];
                [again forceSceneGeometry];
                [again layoutHostView];
            });
        }
    });
}

// The picture was following the card. A taller card then showed empty space
// under the old picture. The picture stays at the tall size and the card
// uncovers it, so later card growth must not resize that picture.
- (void)keepPictureFromTrackingHostFrom:(UIView *)view depth:(NSInteger)depth {
    if (!view || depth > 8) return;
    for (UIView *subview in view.subviews) {
        NSString *name = NSStringFromClass(object_getClass(subview));
        BOOL keyboard = [name rangeOfString:@"Keyboard"].location != NSNotFound ||
                        [name rangeOfString:@"TextEffects"].location != NSNotFound ||
                        [name rangeOfString:@"InputSet"].location != NSNotFound;
        if (keyboard) {
            [self keepPictureFromTrackingHostFrom:subview depth:depth + 1];
            continue;
        }
        UIViewAutoresizing mask = subview.autoresizingMask;
        mask &= ~(UIViewAutoresizingFlexibleHeight |
                  UIViewAutoresizingFlexibleTopMargin |
                  UIViewAutoresizingFlexibleBottomMargin);
        if (subview.autoresizingMask != mask) subview.autoresizingMask = mask;
        [self keepPictureFromTrackingHostFrom:subview depth:depth + 1];
    }
}


- (void)restorePictureTrackingFrom:(UIView *)view depth:(NSInteger)depth {
    if (!view || depth > 8) return;
    for (UIView *subview in view.subviews) {
        NSString *name = NSStringFromClass(object_getClass(subview));
        BOOL keyboard = [name rangeOfString:@"Keyboard"].location != NSNotFound ||
                        [name rangeOfString:@"TextEffects"].location != NSNotFound ||
                        [name rangeOfString:@"InputSet"].location != NSNotFound;
        if (!keyboard && !DSViewIsScenePresentation(subview)) {
            subview.autoresizingMask |= UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        }
        [self restorePictureTrackingFrom:subview depth:depth + 1];
    }
}

- (void)restorePictureTracking {
    if (_hostView) _hostView.autoresizesSubviews = YES;
    [self restorePictureTrackingFrom:_hostView depth:0];
}

// The card is growing under the finger. The app was told the tall size once,
// at the start. Changing that size on the way down is what left the new area black.
- (void)adoptGrowingCardFrame:(CGRect)frame {
    (void)frame;
    if (!_revealingTallContent) return;
    [self layoutHostView];
}

- (BOOL)beginRevealingTallContent:(CGRect)fullFrame {
    if (CGRectGetWidth(fullFrame) < 80.0 || CGRectGetHeight(fullFrame) < 80.0) return NO;
    _contentScale = [DSPreferences sharedPreferences].scale;
    _stageFrame = fullFrame;
    _matchCardFrame = YES;
    _revealingTallContent = YES;
    [self layoutHostView];
    if (_revealSizeSent || _revealWriteQueued) return YES;
    _revealWriteQueued = YES;
    [self sendRevealFrame:fullFrame generation:_revealGeneration revealing:YES attempt:0];
    return YES;
}

- (void)endRevealingTallContent:(CGRect)cardFrame {
    [self restorePictureTracking];
    _revealingTallContent = NO;
    _revealSizeSent = NO;
    _revealWriteQueued = NO;
    _growSentHeight = 0.0;
    _revealGeneration += 1;
    if (CGRectGetWidth(cardFrame) < 80.0 || CGRectGetHeight(cardFrame) < 80.0) {
        [self layoutHostView];
        return;
    }
    _contentScale = [DSPreferences sharedPreferences].scale;
    _stageFrame = cardFrame;
    _matchCardFrame = YES;
    [self layoutHostView];
    NSInteger generation = _revealGeneration;
    _revealWriteQueued = YES;
    [self sendRevealFrame:cardFrame generation:generation revealing:NO attempt:0];
}

- (void)stopRevealingTallContent {
    [self restorePictureTracking];
    _revealingTallContent = NO;
    _revealSizeSent = NO;
    _revealWriteQueued = NO;
    _growSentHeight = 0.0;
    _revealGeneration += 1;
}

- (void)writeFullScreenFrameAttempt:(NSInteger)attempt {
    CGRect screen = UIScreen.mainScreen.bounds;
    if (CGRectGetWidth(screen) < 80.0 || CGRectGetHeight(screen) < 80.0) return;
    _contentScale = 1.0;
    _matchCardFrame = YES;
    _stageFrame = CGRectMake(0.0, 0.0, CGRectGetWidth(screen), CGRectGetHeight(screen));
    UIEdgeInsets insets = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) {
        UIWindow *window = UIApplication.sharedApplication.windows.firstObject;
        insets = window.safeAreaInsets;
    }
    _safeAreaInsets = insets;
    [self registerGeometryOnlyOverride];
    if (DSSceneWriteWouldTrap()) {
        if (attempt >= 8 || !_appViewController) return;
        __weak __typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            DSSceneHost *host = weakSelf;
            if (!host || !host->_appViewController) return;
            [host writeFullScreenFrameAttempt:attempt + 1];
        });
        return;
    }
    _deliveredOnce = NO;
    _deliveredWidth = 0.0;
    _deliveredHeight = 0.0;
    [self setContentReferenceSizeOnAppView];
    [self forceSceneGeometry];
    [self layoutHostView];
    DSLogAppend([NSString stringWithFormat:@"[SCENE] full screen handoff %@ frame=%@",
                                           _bundleIdentifier ?: @"?",
                                           NSStringFromCGRect([self frameForScene])]);
}

- (void)handOffAtFullScreen {
    [self stopRevealingTallContent];
    // Set before the scene write. A phone-sized update is otherwise refused
    // while this host is still on the stage, and the scene stays the split.
    if (_bundleIdentifier.length > 0) {
        DSHandedOffBundle = [_bundleIdentifier copy];
        DSHandedOffUntil = CFAbsoluteTimeGetCurrent() + 3.0;
    }
    [self writeFullScreenFrameAttempt:0];
}

static id DSIvarInHierarchy(id object, NSString *name) {
    Class cls = [object class];
    while (cls) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (ivar) {
            @try {
                return object_getIvar(object, ivar);
            } @catch (NSException *exception) {
                return nil;
            }
        }
        cls = class_getSuperclass(cls);
    }
    return nil;
}

static void DSCollectPresentations(UIView *view, NSMutableArray<UIView *> *found, NSInteger depth) {
    if (!view || depth > 22) return;
    if (DSViewIsScenePresentation(view)) [found addObject:view];
    for (UIView *subview in view.subviews) {
        DSCollectPresentations(subview, found, depth + 1);
    }
}

- (NSString *)growingContentDebugLine {
    CGRect hostBounds = _hostView ? _hostView.bounds : CGRectZero;
    CGRect sceneFrame = CGRectZero;
    @try {
        FBScene *scene = [self appViewScene] ?: _scene;
        FBSSceneSettings *settings = [scene respondsToSelector:@selector(settings)] ? scene.settings : nil;
        if (settings) sceneFrame = settings.frame;
    } @catch (NSException *exception) {
    }
    CGRect picture = CGRectZero;
    NSInteger count = 0;
    if (_hostView) {
        NSMutableArray<UIView *> *found = [NSMutableArray array];
        DSCollectPresentations(_hostView, found, 0);
        count = found.count;
        UIView *pictureView = found.firstObject;
        if (pictureView) picture = pictureView.bounds;
    }
    return [NSString stringWithFormat:
            @"[SCENE] %@ stageH=%.0f sceneH=%.0f host={{%.0f,%.0f}} picture={{%.0f,%.0f}} n=%ld sent=%d queued=%d",
            _bundleIdentifier ?: @"?",
            CGRectGetHeight(_stageFrame),
            CGRectGetHeight(sceneFrame),
            CGRectGetWidth(hostBounds), CGRectGetHeight(hostBounds),
            CGRectGetWidth(picture), CGRectGetHeight(picture),
            (long)count, _revealSizeSent, _revealWriteQueued];
}

static BOOL DSNameContains(NSString *name, NSArray<NSString *> *parts) {
    for (NSString *part in parts) {
        if ([name rangeOfString:part].location != NSNotFound) return YES;
    }
    return NO;
}

static BOOL DSWindowIsKeyboard(UIWindow *window) {
    NSString *name = NSStringFromClass(object_getClass(window));
    return DSNameContains(name, @[ @"Keyboard", @"TextEffects" ]);
}

// Notifications, calls, and the keyboard have to stay on screen during Split.
// Their windows are not Messages' leftover scene.
static BOOL DSWindowShouldBeLeftAlone(UIWindow *window) {
    if (DSWindowIsKeyboard(window)) return YES;
    NSString *name = NSStringFromClass(object_getClass(window));
    return DSNameContains(name, @[ @"Banner", @"Notification", @"Call", @"InCall", @"CoverSheet" ]);
}

static BOOL DSViewIsSystemChrome(UIView *view) {
    NSString *name = NSStringFromClass(object_getClass(view));
    return DSNameContains(name, @[
        @"HomeScreen", @"FloatingDock", @"Wallpaper", @"Icon", @"StatusBar",
        @"Banner", @"Notification", @"Keyboard", @"TextEffects", @"CoverSheet",
        @"CallScreen", @"Dock",
    ]);
}

// 4.5.809: the 1-arg allWindowsIncludingInternalWindows: never existed on 20F75,
// so this always fell through to the app's windows; that is all it does now.
static NSArray<UIWindow *> *DSAllWindows(void) {
    return UIApplication.sharedApplication.windows ?: @[];
}

static NSString *DSIdentifierFromObject(id object) {
    if (!object || [object isKindOfClass:NSString.class]) return nil;
    @try {
        if ([object respondsToSelector:@selector(identifier)]) {
            id identifier = [object identifier];
            if ([identifier isKindOfClass:NSString.class] && [identifier length] > 0) return identifier;
        }
    } @catch (NSException *exception) {
    }
    return nil;
}

// The presentation view rarely is the scene. The scene sits on an ivar a level
// or two down, and that is the only way to know the view is Messages'.
static NSString *DSIdentifierOnPresentation(UIView *view) {
    NSArray<NSString *> *names = @[
        @"_scene", @"scene", @"_fbScene", @"_uiScene", @"_presenter", @"presenter",
        @"_scenePresenter", @"_presentation", @"_hostingController",
    ];
    for (NSString *name in names) {
        id object = DSIvarInHierarchy(view, name);
        NSString *identifier = DSIdentifierFromObject(object);
        if (identifier.length > 0) return identifier;
        if (!object) continue;
        for (NSString *nested in @[ @"_scene", @"scene", @"_fbScene" ]) {
            identifier = DSIdentifierFromObject(DSIvarInHierarchy(object, nested));
            if (identifier.length > 0) return identifier;
        }
        if ([object respondsToSelector:@selector(scene)]) {
            @try {
                identifier = DSIdentifierFromObject([object scene]);
            } @catch (NSException *exception) {
                identifier = nil;
            }
            if (identifier.length > 0) return identifier;
        }
    }
    return nil;
}

static NSString *DSBundleIdentifierNear(id start) {
    id responder = start;
    for (NSInteger hop = 0; responder && hop < 14; hop++) {
        @try {
            if ([responder respondsToSelector:@selector(bundleIdentifier)]) {
                id value = [responder bundleIdentifier];
                if ([value isKindOfClass:NSString.class] && [value length] > 0) return value;
            }
            for (NSString *ivarName in @[ @"_application", @"application" ]) {
                id app = DSIvarInHierarchy(responder, ivarName);
                if ([app respondsToSelector:@selector(bundleIdentifier)]) {
                    id value = [app bundleIdentifier];
                    if ([value isKindOfClass:NSString.class] && [value length] > 0) return value;
                }
            }
        } @catch (NSException *exception) {
        }
        if ([responder isKindOfClass:UIView.class]) {
            responder = [(UIView *)responder nextResponder];
        } else if ([responder respondsToSelector:@selector(parentViewController)]) {
            responder = [responder parentViewController];
        } else if ([responder respondsToSelector:@selector(nextResponder)]) {
            responder = [responder nextResponder];
        } else {
            break;
        }
    }
    return nil;
}

// Hide the black wrapper around the stray presentation, and stop before a view
// that also holds the Home Screen or this card.
static UIView *DSContainerToHide(UIView *presentation, UIView *cardHost) {
    UIView *target = presentation;
    UIView *current = presentation;
    while (current.superview && ![current.superview isKindOfClass:UIWindow.class]) {
        UIView *parent = current.superview;
        if (DSViewIsSystemChrome(parent)) break;
        if (objc_getAssociatedObject(parent, DSCardHostKey)) break;
        if (cardHost && (parent == cardHost || [cardHost isDescendantOfView:parent])) break;
        target = parent;
        current = parent;
    }
    return target;
}

// Messages, as the app Split just took off the full screen, keeps a second
// UIScenePresentationView at the screen size. It is black and it sits outside
// the top card. The one inside the card stays. Other apps do not leave this
// view behind, so the walk only runs for Messages.
- (void)hideStrayPresentationsOutsideCard {
    if (_revealingTallContent && !_revealSizeSent) return;
    if (!_matchCardFrame || !_hostView) return;
    if (![_bundleIdentifier isEqualToString:@"com.apple.MobileSMS"]) return;
    // 4.5.754 log754: the same trace line again within 2 s is not repeated
    // (753 log: 125 hideStray lines). Off: log754-off / core754-off.
    {
        NSString *line754 = [NSString stringWithFormat:@"hideStray split=%d depth=%ld",
                             DSStageManager.sharedManager.isSplitMode, (long)DSSceneSettingsUpdateDepth];
        if (DSTrace754Fresh(line754, 0)) DSTraceFormat(@"%@", line754);
    }
    // A single staged card has one presentation, and the conversation push
    // resizes it. Hiding that view stalls the push until SpringBoard resprings.
    // The black full-screen leftover only exists once Split has taken Messages
    // off the full screen.
    if (!DSStageManager.sharedManager.isSplitMode) return;
    // Home gesture / nested scene update: walking presentations here can start
    // work that updates scenes and SIGTRAPs SpringBoard.
    if (DSSceneWriteWouldTrap()) return;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (_straySweepLast > 0.0 && now - _straySweepLast < 0.15) return;
    _straySweepLast = now;

    UIView *host = _hostView;
    CGRect card = [host convertRect:host.bounds toView:nil];
    if (CGRectGetWidth(card) < 40.0 || CGRectGetHeight(card) < 40.0) return;
    FBScene *scene = [self appViewScene] ?: _scene;
    NSString *sceneIdentifier = [scene respondsToSelector:@selector(identifier)] ? scene.identifier : nil;
    NSString *bundle = _bundleIdentifier;

    for (UIWindow *window in DSAllWindows()) {
        if (DSWindowShouldBeLeftAlone(window)) continue;
        NSMutableArray<UIView *> *found = [NSMutableArray array];
        DSCollectPresentations(window, found, 0);
        for (UIView *view in found) {
            UIView *owner = DSCardHostForView(view);
            if ([view isDescendantOfView:host] || owner == host) {
                CGRect frame = [view convertRect:view.bounds toView:nil];
                BOOL hanging = CGRectGetWidth(frame) > CGRectGetWidth(card) + 24.0 ||
                               CGRectGetHeight(frame) > CGRectGetHeight(card) + 24.0;
                if (hanging) {
                    objc_setAssociatedObject(view, DSPresentationKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    DSContainScenePresentation(view);
                }
                continue;
            }
            if (owner) continue;
            CGRect frame = [view convertRect:view.bounds toView:nil];
            BOOL outside = CGRectGetWidth(frame) > CGRectGetWidth(card) + 24.0 ||
                           CGRectGetHeight(frame) > CGRectGetHeight(card) + 24.0 ||
                           CGRectGetMinY(frame) < CGRectGetMinY(card) - 24.0 ||
                           CGRectGetMaxY(frame) > CGRectGetMaxY(card) + 24.0 ||
                           CGRectGetMinX(frame) < CGRectGetMinX(card) - 24.0 ||
                           CGRectGetMaxX(frame) > CGRectGetMaxX(card) + 24.0;
            if (!outside || DSViewIsSystemChrome(view)) continue;
            NSString *identifier = DSIdentifierOnPresentation(view);
            NSString *near = DSBundleIdentifierNear(view);
            BOOL ours = (sceneIdentifier.length > 0 && [identifier isEqualToString:sceneIdentifier]) ||
                        (identifier.length > 0 &&
                         [identifier rangeOfString:bundle].location != NSNotFound) ||
                        [near isEqualToString:bundle];
            if (near.length > 0 && ![near isEqualToString:bundle]) continue;
            if (!ours && identifier.length > 0 &&
                [identifier rangeOfString:@"springboard" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                continue;
            }
            BOOL underChrome = NO;
            for (UIView *walk = view.superview; walk && ![walk isKindOfClass:UIWindow.class]; walk = walk.superview) {
                if (DSViewIsSystemChrome(walk)) {
                    underChrome = YES;
                    break;
                }
            }
            CGRect screen = UIScreen.mainScreen.bounds;
            BOOL screenSized = CGRectGetWidth(frame) > CGRectGetWidth(screen) - 80.0 &&
                               CGRectGetHeight(frame) > CGRectGetHeight(screen) * 0.70;
            // No identifier on it, and it is not inside Home Screen chrome.
            // A screen-sized presentation then is the full-screen Messages view.
            if (!ours && !underChrome && identifier.length == 0 && near.length == 0 && screenSized) ours = YES;
            if (!ours) continue;
            UIView *target = DSContainerToHide(view, host);
            if (!target || target == host || [host isDescendantOfView:target]) continue;
            if ([target isDescendantOfView:host] || DSViewIsSystemChrome(target)) continue;
            [self hideOwnedStrayPresentation:target];
        }
    }
}

- (void)hideOwnedStrayPresentation:(UIView *)view {
    if (!view) return;
    // Already hidden by somebody else. Leave it, so a later restore does not
    // uncover a view SpringBoard meant to keep off screen.
    if (view.hidden && ![DSHiddenStrayPresentations() containsObject:view]) return;
    DSHideStrayPresentation(view);
    if (!_hiddenStrays) _hiddenStrays = [NSHashTable weakObjectsHashTable];
    [_hiddenStrays addObject:view];
    if (_strayHideNoted) return;
    _strayHideNoted = YES;
    DSDiagnosticsRecord(@"SpringBoard: hid Messages' full-screen scene presentation outside the split card");
}

- (void)restoreOwnedStrayPresentations {
    for (UIView *view in _hiddenStrays.allObjects) {
        view.hidden = NO;
        view.alpha = 1.0;
        view.userInteractionEnabled = YES;
        [DSHiddenStrayPresentations() removeObject:view];
    }
    [_hiddenStrays removeAllObjects];
    if ([_bundleIdentifier isEqualToString:@"com.apple.MobileSMS"]) DSRestoreStrayPresentations();
}

- (void)scheduleStrayPresentationSweep {
    if (_straySweepScheduled || !_matchCardFrame) return;
    if (![_bundleIdentifier isEqualToString:@"com.apple.MobileSMS"]) return;
    _straySweepScheduled = YES;
    __weak __typeof(self) weakSelf = self;
    // Home is pressed at 0.45s and the scene is woken at about 1.05s. That wake
    // is when Messages puts the full-screen presentation back.
    for (NSNumber *delay in @[ @0.25, @0.7, @1.2, @2.0 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (DSSceneWriteWouldTrap()) return;
            [weakSelf hideStrayPresentationsOutsideCard];
        });
    }
}

- (CGFloat)keyboardClipHeight {
    return _keyboardClipHeight;
}

- (void)setMessagesKeyboardVisible:(BOOL)visible {
    _messagesKeyboardVisible = visible;
    if (!_hostView) return;
    _hostView.clipsToBounds = !visible;
    _hostView.layer.masksToBounds = !visible;
}

- (void)setKeyboardClipHeight:(CGFloat)height {
    _keyboardClipHeight = MAX(height, 0.0);
    [self layoutHostView];
}

- (void)roundFilledSubviewsOf:(UIView *)view
                       radius:(CGFloat)radius
                      corners:(CACornerMask)corners
                        depth:(NSInteger)depth {
    if (!view || depth > 5) return;
    CGRect bounds = view.bounds;
    if (CGRectIsEmpty(bounds)) return;
    for (UIView *subview in view.subviews) {
        BOOL fills = CGRectGetWidth(subview.bounds) >= CGRectGetWidth(bounds) - 2.0 &&
                     CGRectGetHeight(subview.bounds) >= CGRectGetHeight(bounds) - 2.0;
        if (!fills) continue;
        DSMarkRounded(subview, radius, corners);
        [self roundFilledSubviewsOf:subview radius:radius corners:corners depth:depth + 1];
    }
}

// Ancestor clips do not contain a hosted scene. The scene view itself has to
// wear the card's continuous corner, and it has to put that corner back after
// its own layout clears it.
- (void)roundHostedSceneToCard {
    UIView *host = _hostView;
    if (!host) return;
    if (_beeper707Flat) return;   // 4.5.707 beeper707: the card clips a phone-size host
    if (_rk814) return;           // 4.5.814 realkb814: the host's mask carries the card corners
    DSPerfCount(DSPerfCounterRoundPasses);
    UIView *source = host.superview;
    CGFloat radius = 0.0;
    CACornerMask corners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    while (source) {
        if (source.layer.cornerRadius > 1.0) {
            radius = source.layer.cornerRadius;
            if (@available(iOS 11.0, *)) corners = source.layer.maskedCorners;
            break;
        }
        // The card's layer radius is 0 while it is unclipped for a keyboard.
        // The property is still the real corner. Without it the scene stays a
        // square and the outline is the only rounded piece.
        if ([source isKindOfClass:DSStageContainerView.class]) {
            CGFloat cardRadius = ((DSStageContainerView *)source).cornerRadius;
            if (cardRadius > 1.0) {
                radius = cardRadius;
                break;
            }
        }
        source = source.superview;
    }
    DSMarkPresentationsUnder(host, radius, corners, 0);
    if (radius < 1.0) return;
    DSMarkRounded(host, radius, corners);
    [self roundFilledSubviewsOf:host radius:radius corners:corners depth:0];
}

// The scene view can be taller than the card. masksToBounds on the host is
// what keeps that picture inside the card. This does not set the scene
// presentation's frame. That call waits on the app.
- (void)clipHostContentsToCard {
    if (![_bundleIdentifier isEqualToString:@"com.apple.mobilephone"]) return;
    UIView *host = _hostView;
    if (!host || _messagesKeyboardVisible) return;
    host.clipsToBounds = YES;
    host.layer.masksToBounds = YES;
    CGRect bounds = host.bounds;
    if (CGRectGetWidth(bounds) < 40.0 || CGRectGetHeight(bounds) < 40.0) return;
    CALayer *mask = host.layer.mask;
    if (!mask) {
        mask = [CALayer layer];
        mask.backgroundColor = UIColor.blackColor.CGColor;
        host.layer.mask = mask;
    }
    if (!CGRectEqualToRect(mask.frame, bounds)) mask.frame = bounds;
    // Mask frame is fine mid-update. The window walk that hides presentations
    // is not: that is a SIGTRAP during home / nested scene writes.
    if (DSSceneWriteWouldTrap() || !_matchCardFrame) return;
    CGRect card = [host convertRect:bounds toView:nil];
    if (CGRectGetWidth(card) < 80.0 || CGRectGetHeight(card) < 80.0) return;
    for (UIWindow *window in DSAllWindows()) {
        if (DSWindowShouldBeLeftAlone(window)) continue;
        NSMutableArray<UIView *> *found = [NSMutableArray array];
        DSCollectPresentations(window, found, 0);
        for (UIView *view in found) {
            if ([view isDescendantOfView:host] || DSCardHostForView(view) == host) continue;
            NSString *identifier = DSIdentifierOnPresentation(view);
            NSString *near = DSBundleIdentifierNear(view);
            BOOL ours = (identifier.length > 0 &&
                         [identifier rangeOfString:@"mobilephone" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                        [near isEqualToString:@"com.apple.mobilephone"];
            if (!ours) continue;
            CGRect frame = [view convertRect:view.bounds toView:nil];
            BOOL outside = CGRectGetWidth(frame) > CGRectGetWidth(card) + 24.0 ||
                           CGRectGetHeight(frame) > CGRectGetHeight(card) + 24.0 ||
                           CGRectGetMinY(frame) < CGRectGetMinY(card) - 24.0 ||
                           CGRectGetMaxY(frame) > CGRectGetMaxY(card) + 24.0;
            if (!outside) continue;
            UIView *target = DSContainerToHide(view, host);
            if (!target || target == host || [host isDescendantOfView:target]) continue;
            if ([target isDescendantOfView:host] || DSViewIsSystemChrome(target)) continue;
            DSHideStrayPresentation(target);
        }
    }
}

// ---- 4.5.814 realkb814 ---------------------------------------------------------
// Staged Messages keeps its own real keyboard. Its scene is the phone's size,
// screen-aligned (scene point = screen point), so UIKit draws the keys and the
// input bar/app strip exactly where SpringBoard's keyboard sits. The card and
// its content view stop clipping; the host carries a mask = the card's rounded
// rect + Messages' live keyboard rect (relayed by the app, or the stage
// manager's note from Messages). Safe area top/bottom = the card's edges, so
// the chat stays in the card. Any failed check (no scene, no phone-size
// read-back, mask not taken, write never safe) hands the card back to the
// preserved stand-in (state 0 -> the app is staged again) and says why.
// Off: realkb814-off / core814-off. Latch: realkb814.
- (BOOL)isRealKb814 {
    return _rk814;
}

- (BOOL)realKb814Wanted:(NSString **)why {
    NSString *no = nil;
    UIView *parent = _hostView.superview;
    if (!DSRealKb814On()) no = @"realkb814 off (realkb814-off / core814-off / latched)";
    else if (_rk814Failed) no = [NSString stringWithFormat:@"fell back earlier on this card: %@", _rk814FailWhy ?: @"?"];
    else if (_cameraTall) no = @"camera layout on";
    else if (_revealingTallContent) no = @"card uncovering a tall layout";
    else if (!_appViewController) no = @"no app view yet";
    else if (!parent || !parent.window) no = @"not in a card";
    else if (parent.tag == 9158 || CGRectGetWidth(parent.bounds) < 80.0 || CGRectGetHeight(parent.bounds) < 80.0) no = @"card minimized";
    else if (![parent.superview isKindOfClass:DSStageContainerView.class]) no = @"card container not found";
    if (why) *why = no;
    return no == nil;
}

- (UIEdgeInsets)realKb814InsetsForCard:(CGRect)card {
    CGFloat h = [self phoneSize675SceneSize].height;
    UIEdgeInsets in = UIEdgeInsetsZero;
    in.top = round(MAX(0.0, CGRectGetMinY(card)));
    in.bottom = round(MAX(0.0, h - CGRectGetMaxY(card)));
    return in;
}

- (void)realKb814Start {
    NSString *why = nil;
    if (_rk814 || _phoneSize) return;
    if (![self realKb814Wanted:&why]) { DSRK814Log(@"skip", [NSString stringWithFormat:@"not started: %@", why]); return; }
    if (DSSceneWriteWouldTrap()) { DSRK814Log(@"skip", @"not started yet: scene update in progress (next layout tries again)"); return; }
    if (![self appViewScene]) { [self realKb814Fail:@"no scene to make phone-size"]; return; }
    UIView *parent = _hostView.superview;
    DSStageContainerView *card = (DSStageContainerView *)parent.superview;
    CGRect cardRect = [parent convertRect:parent.bounds toView:nil];
    DSRK814EnsureRelay();
    DSRK814Host = self;
    DSRK814AppKeys = CGRectZero;
    DSRK814MgrKeys = CGRectZero;
    // Tell the app first, so it is unstaged before the phone size lands.
    DSRK814Publish(DSIdentifierHash(_bundleIdentifier), @"card shown");
    _rk814 = YES;
    _rk814Confirmed = NO;
    _rk814Layouts = 0;
    _rk814MaskCard = CGRectNull;
    _rk814MaskKeys = CGRectNull;
    _phoneSizeWidth = [self cameraTallSize].width;
    _phoneSize = YES;
    _phoneSizePreGrown = NO;
    _rk814Insets = [self realKb814InsetsForCard:cardRect];
    card.realKb814Unclipped = YES;
    DSFeature699MarkTrying("realkb814");
    CGSize phone = [self phoneSize675SceneSize];
    DSRK814Log(@"start", [NSString stringWithFormat:@"ON for Messages: scene %.0fx%.0f screen-aligned, card %@, safe area %@ (chat in the card), card clip off, host masked to card + keyboard",
                          phone.width, phone.height, NSStringFromCGRect(cardRect), NSStringFromUIEdgeInsets(_rk814Insets)]);
    _phoneSizeGeneration += 1;
    [self phoneSize675WriteGeometry:_phoneSizeGeneration attempt:0];
}

- (void)realKb814Fail:(NSString *)why {
    _rk814Failed = YES;
    _rk814FailWhy = [why copy];
    DSRK814Log(@"fail", [NSString stringWithFormat:@"FALLBACK to the stand-in keyboard for this card: %@", why ?: @"?"]);
    if (_rk814) [self realKb814Stop:why];
    else DSRK814Publish(0, why);
}

- (void)realKb814Stop:(NSString *)why {
    if (!_rk814) return;
    _rk814 = NO;
    _phoneSize = NO;
    _phoneSizeWidth = 0.0;
    if (DSRK814Host == self) DSRK814Host = nil;
    DSRK814Publish(0, why);
    if (_rk814Mask && _hostView.layer.mask == _rk814Mask) _hostView.layer.mask = nil;
    _rk814Mask = nil;
    UIView *parent = _hostView.superview;
    if ([parent.superview isKindOfClass:DSStageContainerView.class]) ((DSStageContainerView *)parent.superview).realKb814Unclipped = NO;
    if (parent) {
        parent.clipsToBounds = YES;
        parent.layer.masksToBounds = YES;
    }
    DSRK814Log(@"start", [NSString stringWithFormat:@"OFF (%@): scene back to card size, card clips again", why ?: @"?"]);
    _phoneSizeGeneration += 1;
    if (_appViewController) [self phoneSize675WriteGeometry:_phoneSizeGeneration attempt:0];
    else [self layoutHostView];
}

// The layout for a realkb814 host. NO = not handled (normal layout runs).
- (BOOL)realKb814LayoutInParent:(UIView *)parent {
    NSString *why = nil;
    if (![self realKb814Wanted:&why]) {
        __weak __typeof(self) weakSelf = self;
        NSString *reason = why ?: @"?";
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf realKb814Stop:reason]; });
        return NO;
    }
    CGSize phone = [self phoneSize675SceneSize];
    UIView *host = _hostView;
    if (host.autoresizingMask != UIViewAutoresizingNone) host.autoresizingMask = UIViewAutoresizingNone;
    if (!host.autoresizesSubviews) host.autoresizesSubviews = YES;
    if (!CGAffineTransformIsIdentity(host.transform)) host.transform = CGAffineTransformIdentity;
    CGRect phoneBounds = CGRectMake(0.0, 0.0, phone.width, phone.height);
    if (!CGRectEqualToRect(host.bounds, phoneBounds)) host.bounds = phoneBounds;
    // Screen-aligned: host (0,0) on the screen's (0,0).
    CGPoint origin = [parent convertPoint:CGPointZero fromView:nil];
    CGPoint center = CGPointMake(origin.x + phone.width / 2.0, origin.y + phone.height / 2.0);
    if (fabs(host.center.x - center.x) > 0.01 || fabs(host.center.y - center.y) > 0.01) host.center = center;
    objc_setAssociatedObject(host, DSCardHostKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (host.hidden) host.hidden = NO;
    if (host.clipsToBounds) host.clipsToBounds = NO;
    if (parent.clipsToBounds || parent.layer.masksToBounds) { parent.clipsToBounds = NO; parent.layer.masksToBounds = NO; }
    if (parent.layer.mask) parent.layer.mask = nil;
    DSStageContainerView *card = (DSStageContainerView *)parent.superview;
    if (!card.realKb814Unclipped) card.realKb814Unclipped = YES;
    // Mask = card (rounded) + keyboard, in host coordinates.
    CGRect cardRect = [parent convertRect:parent.bounds toView:host];
    CGRect keysScreen = !CGRectIsEmpty(DSRK814AppKeys) ? DSRK814AppKeys : DSRK814MgrKeys;
    CGRect keys = CGRectIsEmpty(keysScreen) ? CGRectNull : [host convertRect:keysScreen fromView:nil];
    if (!_rk814Mask) {
        _rk814Mask = [CAShapeLayer layer];
        _rk814Mask.fillColor = UIColor.blackColor.CGColor;
    }
    if (!CGRectEqualToRect(_rk814Mask.frame, host.bounds)) _rk814Mask.frame = host.bounds;
    if (!CGRectEqualToRect(cardRect, _rk814MaskCard) || !CGRectEqualToRect(keys, _rk814MaskKeys)) {
        _rk814MaskCard = cardRect;
        _rk814MaskKeys = keys;
        CGFloat radius = MAX(0.0, card.cornerRadius);
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:cardRect cornerRadius:radius];
        if (!CGRectIsNull(keys)) [path appendPath:[UIBezierPath bezierPathWithRect:keys]];
        _rk814Mask.fillRule = kCAFillRuleNonZero;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _rk814Mask.path = path.CGPath;
        [CATransaction commit];
        DSRK814Log(@"mask", [NSString stringWithFormat:@"mask = card %@ r%.0f + keyboard %@ (%@)", NSStringFromCGRect(cardRect), radius,
                             CGRectIsNull(keys) ? @"none" : NSStringFromCGRect(keys),
                             !CGRectIsEmpty(DSRK814AppKeys) ? @"relayed by Messages" : (!CGRectIsEmpty(DSRK814MgrKeys) ? @"stage note" : @"keys down")]);
    }
    if (host.layer.mask != _rk814Mask) host.layer.mask = _rk814Mask;
    if (host.layer.mask != _rk814Mask) {
        __weak __typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf realKb814Fail:@"mask was not taken by the host layer"]; });
        return NO;
    }
    // Clipping ancestors above the card (logged; a clip there would cut the keys).
    {
        NSMutableArray *clips = [NSMutableArray array];
        UIView *v = card.superview;
        for (NSInteger depth = 0; v && depth < 8 && ![v isKindOfClass:UIWindow.class]; depth++, v = v.superview) {
            if (v.layer.masksToBounds || v.layer.mask) [clips addObject:[NSString stringWithFormat:@"%@%@", NSStringFromClass(v.class), NSStringFromCGRect([v convertRect:v.bounds toView:nil])]];
        }
        DSRK814Log(@"clips", [NSString stringWithFormat:@"clipping views above the card: %@", clips.count ? [clips componentsJoinedByString:@", "] : @"none"]);
    }
    // Safe area follows the card edges (chat in the card); written on change, not mid-drag.
    CGRect cardScreen = [parent convertRect:parent.bounds toView:nil];
    UIEdgeInsets want = [self realKb814InsetsForCard:cardScreen];
    if ((fabs(want.top - _rk814Insets.top) > 1.0 || fabs(want.bottom - _rk814Insets.bottom) > 1.0) && !_rk814InsetsPending &&
        !DSStageDragSettlingFast(0.25) && !DSSceneWriteWouldTrap()) {
        _rk814InsetsPending = YES;
        __weak __typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong __typeof(weakSelf) s = weakSelf;
            if (!s) return;
            s->_rk814InsetsPending = NO;
            if (!s->_rk814 || DSSceneWriteWouldTrap()) return;
            UIView *p = s->_hostView.superview;
            if (!p) return;
            UIEdgeInsets now = [s realKb814InsetsForCard:[p convertRect:p.bounds toView:nil]];
            DSRK814Log(@"insets", [NSString stringWithFormat:@"safe area %@ -> %@ (card moved)", NSStringFromUIEdgeInsets(s->_rk814Insets), NSStringFromUIEdgeInsets(now)]);
            s->_rk814Insets = now;
            [s forceSceneGeometry];
        });
    }
    // Read-back: the scene has to really be phone-size.
    if (!_rk814Confirmed) {
        CGRect got = CGRectZero;
        NSString *summary = [self phoneSize676SceneSummary:&got];
        if (CGRectGetHeight(got) >= phone.height - 2.0 && CGRectGetWidth(got) >= phone.width - 3.0) {
            _rk814Confirmed = YES;
            DSRK814Log(@"confirm", [NSString stringWithFormat:@"scene confirmed phone-size after %ld layouts: %@", (long)_rk814Layouts, summary]);
        } else if (++_rk814Layouts > 60) {
            NSString *reason = [NSString stringWithFormat:@"scene never became phone-size (%@)", summary];
            __weak __typeof(self) weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf realKb814Fail:reason]; });
        }
    }
    return YES;
}

- (void)layoutHostView {
    DS_PERF_BEGIN();
    [self layoutHostView697Body];
    DS_PERF_END(DSPerfBucketHostLayout);
}

- (void)layoutHostView697Body {
    if (!_hostView) {
        [self phoneSize690RemoveStrip:@"no host view"];
        return;
    }
    {
        UIView *p690 = _hostView.superview;
        BOOL tiny690 = CGRectGetWidth(p690.bounds) < 80.0 && CGRectGetHeight(p690.bounds) < 80.0;
        if (_ps690Strip && (!_phoneSize || _cameraTall || !p690 || p690.tag == 9158 || tiny690 || CGRectIsEmpty(p690.bounds))) {
            [self phoneSize690RemoveStrip:@"card not phone-size / minimized"];
        }
    }
    if ([_bundleIdentifier isEqualToString:@"com.apple.MobileSMS"]) {
        {
            NSString *line754 = [NSString stringWithFormat:@"layoutHost Messages frame=%@", NSStringFromCGRect(_hostView.frame)];
            if (DSTrace754Fresh(line754, 1)) DSTraceFormat(@"%@", line754);   // 4.5.754 log754 (logging only)
        }
    }
    UIView *parent = _hostView.superview;
    CGFloat scale = _contentScale > 0 ? _contentScale : 1.0;
    // 4.5.814 realkb814 (Messages only; one cached gate read otherwise).
    if (_rk814) {
        if ([self realKb814LayoutInParent:parent]) return;
    } else if (!_rk814Pending && !_phoneSize && !_rk814Failed && [_bundleIdentifier isEqualToString:@"com.apple.MobileSMS"] && DSRealKb814On()) {
        NSString *why814 = nil;
        if ([self realKb814Wanted:&why814]) {
            _rk814Pending = YES;
            __weak __typeof(self) weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong __typeof(weakSelf) s = weakSelf;
                if (!s) return;
                s->_rk814Pending = NO;
                [s realKb814Start];
            });
        } else {
            DSRK814Log(@"skip", [NSString stringWithFormat:@"waiting: %@", why814 ?: @"?"]);
        }
    }
    @try {
        [self phoneSize696UpdateKeysSceneForParent:parent];
    } @catch (NSException *exception) {
    }
    // 4.5.707 beeper707: the phone-size branch below writes its own transform;
    // resetting it to identity first was two transform changes (and a bounds /
    // center pass) on every layout of a scaled card.
    BOOL tiny707 = parent && CGRectGetWidth(parent.bounds) < 80.0 && CGRectGetHeight(parent.bounds) < 80.0;
    BOOL ps707 = _phoneSize && !_cameraTall && parent && !CGRectIsEmpty(parent.bounds) && parent.tag != 9158 && !tiny707 &&
                 DSFeature699On("beeper707");
    if (!ps707) _hostView.transform = CGAffineTransformIdentity;

    // At the normal scale the app is the card, edge to edge. A view left at the
    // screen size is clipped, which is the bottom stage showing only part of the app.
    // A mask on an ancestor does not clip this view. Its superview's bounds do,
    // and only while this view stays the size the scene was given.
    // The corner card and the hidden holder are not sizes the app can be laid
    // out into. Leaving the view there is what crashed a minimized app.
    BOOL tinyParent = CGRectGetWidth(parent.bounds) < 80.0 && CGRectGetHeight(parent.bounds) < 80.0;
    if (parent && (parent.tag == 9158 || tinyParent)) {
        _hostView.autoresizingMask = UIViewAutoresizingNone;
        // Minimized. The live view stays off the card. Leaving it visible at
        // the old card size paints the app on the Home Screen.
        if (parent.tag == 9158) _hostView.hidden = YES;
        // 4.5.695: a 684-mode phone-size card stays phone-size (no shrink);
        // in a tiny card the phone-size picture is scaled to its width
        // (transform only; the view's bounds and the scene are not touched).
        BOOL keep695 = _phoneSize && [self phoneSize695KeepsAway:@"card minimized"];
        if (keep695 && parent.tag != 9158 && tinyParent) {
            CGSize b = _hostView.bounds.size;
            CGFloat s = b.width > 1.0 ? CGRectGetWidth(parent.bounds) / b.width : 0.0;
            if (isfinite(s) && s > 0.001 && s < 1.0) {
                _hostView.transform = CGAffineTransformMakeScale(s, s);
                _hostView.center = CGPointMake(CGRectGetMidX(parent.bounds), CGRectGetMidY(parent.bounds));
            }
        }
        // 4.5.675: a minimized card is never phone-size. Back to the card
        // size, outside this layout pass.
        if (_phoneSize && !keep695) {
            __weak __typeof(self) weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf setPhoneSize675:NO keyboardTop:0.0 why:@"card minimized"];
            });
        }
        return;
    }
    // 4.5.680: an allowlisted app on a card is always phone-size. Card open,
    // restore and resize all come through here; the switch itself runs
    // outside this layout pass (throttled, 1 s).
    if (!_phoneSize && !_cameraTall && parent && !CGRectIsEmpty(parent.bounds)) [self phoneSize680GrowSoon];
    // 4.5.675 phonesize675: the phone-size scene at the card's width, with
    // scene y = keyboard top on the card's bottom edge. The card clips the
    // rest (the top of the app above, the part behind the keys below).
    if (_phoneSize && !_cameraTall && parent && !CGRectIsEmpty(parent.bounds)) {
        CGSize phone = [self phoneSize675SceneSize];
        CGFloat width = CGRectGetWidth(parent.bounds);
        CGFloat height = CGRectGetHeight(parent.bounds);
        CGFloat fit = [self phoneSize675FitForWidth:width height:height];
        CGFloat keyTop = [self phoneSize675PinForCardHeight:height fit:fit];
        if (_hostView.autoresizingMask != UIViewAutoresizingNone) _hostView.autoresizingMask = UIViewAutoresizingNone;
        if (!_hostView.autoresizesSubviews) _hostView.autoresizesSubviews = YES;
        CGRect phoneBounds = CGRectMake(0.0, 0.0, phone.width, phone.height);
        if (!ps707 || !CGRectEqualToRect(_hostView.bounds, phoneBounds)) _hostView.bounds = phoneBounds;
        // 4.5.694: vertical squash so the real top bar (from view_top) fits;
        // x stays fit (full width), the bar line keyTop stays on the card bottom.
        CGFloat sy = [self phoneSize694ScaleYForWidth:width height:height fit:fit keyTop:keyTop];
        // 4.5.698: a little bigger (crop a few pt of the top band and the sides);
        // keyTop stays on the card bottom. Off file / latch = 697 exactly.
        CGFloat sx = fit;
        CGFloat cx = width / 2.0;
        [self phoneSize698ForWidth:width height:height phone:phone fit:fit keyTop:keyTop sx:&sx sy:&sy cx:&cx];
        CGAffineTransform squash = CGAffineTransformMakeScale(sx, sy);
        CGPoint middle = CGPointMake(cx, height - keyTop * sy + phone.height * sy / 2.0);
        if (!ps707 || !CGAffineTransformEqualToTransform(_hostView.transform, squash)) _hostView.transform = squash;
        if (!ps707 || fabs(_hostView.center.x - middle.x) > 0.01 || fabs(_hostView.center.y - middle.y) > 0.01) _hostView.center = middle;
        // 4.5.679: scene size, scale and the visible app-y range, on every change.
        if (fabs(_ps679LoggedWidth - phone.width) > 0.5 || fabs(_ps679LoggedFit - fit) > 0.0005 || fabs(_ps679LoggedPin - keyTop) > 0.5) {
            _ps679LoggedWidth = phone.width;
            _ps679LoggedFit = fit;
            _ps679LoggedPin = keyTop;
            NSString *kind = _phoneSizePreGrown ? (_phoneSizeKeyTop < 1.0 ? @"pre-grown, tap-safe" : @"pre-grown, bottom-anchored") : @"keyboard up";
            DSDiagnosticsRecordFormat(@"SpringBoard: phonesize679 %@ scene %.0fx%.0f at scale %.4f%@ (%@): visible app y %.0f..%.0f in card %.0fx%.0f; side crop %.1f pt each side",
                                      _bundleIdentifier ?: @"?", phone.width, phone.height, fit,
                                      _phoneSizeNudging ? @" (nudge running)" : @"", kind,
                                      keyTop - height / MAX(fit, 0.01), keyTop, width, height,
                                      MAX(0.0, (phone.width * fit - width) / 2.0));
        }
        objc_setAssociatedObject(_hostView, DSCardHostKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (_hostView.hidden) _hostView.hidden = NO;
        if (ps707) {
            // 4.5.707 beeper707: the parent clips (a plain rectangle inside the
            // card's rounded content view). The host does not clip again, has no
            // group opacity and is never rasterised, and the rounded clips
            // inside it are dropped once.
            DSFeature699MarkTrying("beeper707");
            if (_hostView.layer.masksToBounds) {
                _hostView.clipsToBounds = NO;
                _hostView.layer.masksToBounds = NO;
            }
            if (_hostView.layer.allowsGroupOpacity) _hostView.layer.allowsGroupOpacity = NO;
            if (_hostView.layer.shouldRasterize) _hostView.layer.shouldRasterize = NO;
            if (!parent.layer.masksToBounds) {
                parent.clipsToBounds = YES;
                parent.layer.masksToBounds = YES;
            }
            if (!_beeper707Flat) {
                _beeper707Flat = YES;
                NSInteger flat = DSBeeper707Flatten(_hostView, 0);
                if (!_beeper707Logged) {
                    _beeper707Logged = YES;
                    DSDiagnosticsRecordFormat(@"SpringBoard: beeper707 %@ phone-size host drawn flat: %ld nested rounded clips dropped, host clip off (the card clips), squash %.3fx%.3f",
                                              _bundleIdentifier ?: @"?", (long)flat, sx, sy);
                }
            }
        } else {
            _hostView.clipsToBounds = YES;
            _hostView.layer.masksToBounds = YES;
            parent.clipsToBounds = YES;
            parent.layer.masksToBounds = YES;
        }
        // 4.5.690: the recreated top bar over the card (picture only on the
        // SpringBoard side; the host view above is placed exactly as before).
        @try {
            [self phoneSize690UpdateStripInParent:parent width:width height:height fit:fit cardBottomY:keyTop];
        } @catch (NSException *exception) {
            [self phoneSize690RemoveStrip:[NSString stringWithFormat:@"threw %@", exception.reason ?: exception.name ?: @"?"]];
        }
        return;
    }
    if (_beeper707Flat) {
        // Out of phone-size (or minimised): the scene gets its corners back.
        _beeper707Flat = NO;
        _hostView.layer.allowsGroupOpacity = YES;
        [self roundHostedSceneToCard];
    }
    // 4.5.668 sbcam668: the phone-size camera scene, at the card's width,
    // bottom-aligned. The card (parent) clips what is above it.
    if (_cameraTall && parent && !CGRectIsEmpty(parent.bounds)) {
        CGSize phone = [self cameraTallSize];
        CGFloat width = CGRectGetWidth(parent.bounds);
        CGFloat height = CGRectGetHeight(parent.bounds);
        CGFloat fit = width / phone.width;
        _hostView.autoresizingMask = UIViewAutoresizingNone;
        _hostView.bounds = CGRectMake(0.0, 0.0, phone.width, phone.height);
        _hostView.transform = CGAffineTransformMakeScale(fit, fit);
        _hostView.center = CGPointMake(width / 2.0, height - phone.height * fit / 2.0);
        objc_setAssociatedObject(_hostView, DSCardHostKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        _hostView.hidden = NO;
        _hostView.clipsToBounds = YES;
        _hostView.layer.masksToBounds = YES;
        parent.clipsToBounds = YES;
        parent.layer.masksToBounds = YES;
        return;
    }
    if (parent && !CGRectIsEmpty(parent.bounds) && fabs(scale - 1.0) < 0.02) {
        CGFloat width = CGRectGetWidth(parent.bounds);
        CGFloat height = CGRectGetHeight(parent.bounds);
        // The app was laid out at the tall size once. The host stays that tall
        // and the card clips it. Shrinking the host to the card on each move
        // is the empty band: the picture then thinks it is still the old size.
        if (_revealingTallContent && CGRectGetHeight(_stageFrame) > height) {
            height = CGRectGetHeight(_stageFrame);
            _hostView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            // The picture has to grow with this one change. Leaving it at the
            // half height is the black band, even when the host is already tall.
            _hostView.autoresizesSubviews = YES;
            CGRect want = CGRectMake(0.0, 0.0, width, height);
            if (!CGRectEqualToRect(_hostView.frame, want)) _hostView.frame = want;
            objc_setAssociatedObject(_hostView, DSCardHostKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            _hostView.hidden = NO;
            _hostView.clipsToBounds = YES;
            _hostView.layer.masksToBounds = YES;
            if ([_bundleIdentifier isEqualToString:@"com.apple.mobilephone"]) {
                parent.clipsToBounds = YES;
                parent.layer.masksToBounds = YES;
                [self clipHostContentsToCard];
            }
            [self roundHostedSceneToCard];
            return;
        }
        UIViewAutoresizing mask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        if (_keyboardClipHeight > 1.0) {
            UIView *card = parent.superview;
            if (card && CGRectGetHeight(card.bounds) > height + 0.5) {
                height = CGRectGetHeight(card.bounds);
            }
            mask = UIViewAutoresizingFlexibleWidth;
        }
        if (_hostView.autoresizingMask != mask) _hostView.autoresizingMask = mask;
        CGRect want = CGRectMake(0.0, 0.0, width, height);
        if (!CGRectEqualToRect(_hostView.frame, want)) _hostView.frame = want;
        objc_setAssociatedObject(_hostView, DSCardHostKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        _hostView.hidden = NO;
        _hostView.clipsToBounds = !_messagesKeyboardVisible;
        _hostView.layer.masksToBounds = !_messagesKeyboardVisible;
        if ([_bundleIdentifier isEqualToString:@"com.apple.mobilephone"] && parent) {
            parent.clipsToBounds = YES;
            parent.layer.masksToBounds = YES;
        }
        [self clipHostContentsToCard];
        // 4.5.705 perf705: once, after the clamp (the clamp never touches corners).
        if (!DSPerf705On()) [self roundHostedSceneToCard];
        if (!_clampingHost) {
            _clampingHost = YES;
            [self clampOversizedSubviewsOf:_hostView depth:0];
            _clampingHost = NO;
        }
        [self roundHostedSceneToCard];
        if (!DSSceneWriteWouldTrap()) {
            [self hideStrayPresentationsOutsideCard];
            [self scheduleStrayPresentationSweep];
        }
        return;
    }

    CGRect logical = [self logicalFrame];
    CGFloat shrink = scale > 0 ? 1.0 / scale : 1.0;
    _hostView.autoresizingMask = UIViewAutoresizingNone;
    _hostView.frame = CGRectMake(0, 0, CGRectGetWidth(logical), CGRectGetHeight(logical));
    _hostView.transform = CGAffineTransformMakeScale(shrink, shrink);
    if (parent && !CGRectIsEmpty(parent.bounds)) {
        _hostView.center = CGPointMake(CGRectGetMidX(parent.bounds), CGRectGetMidY(parent.bounds));
    } else {
        _hostView.center = CGPointMake(CGRectGetWidth(_stageFrame) / 2.0, CGRectGetHeight(_stageFrame) / 2.0);
    }
    objc_setAssociatedObject(_hostView, DSCardHostKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    _hostView.hidden = NO;
    _hostView.clipsToBounds = !_messagesKeyboardVisible;
    _hostView.layer.masksToBounds = !_messagesKeyboardVisible;
    if ([_bundleIdentifier isEqualToString:@"com.apple.mobilephone"] && parent) {
        parent.clipsToBounds = YES;
        parent.layer.masksToBounds = YES;
    }
    [self clipHostContentsToCard];
    if (!DSPerf705On()) [self roundHostedSceneToCard];
    if (!_clampingHost) {
        _clampingHost = YES;
        [self clampOversizedSubviewsOf:_hostView depth:0];
        _clampingHost = NO;
    }
    [self roundHostedSceneToCard];
    if (!DSSceneWriteWouldTrap()) {
        [self hideStrayPresentationsOutsideCard];
        [self scheduleStrayPresentationSweep];
    }
}

static long long DSHostReadLong(id target, NSString *name, long long fallback) {
    SEL selector = NSSelectorFromString(name);
    if (!target || ![target respondsToSelector:selector]) return fallback;
    @try {
        NSMethodSignature *signature = [target methodSignatureForSelector:selector];
        const char *type = signature.methodReturnType;
        if (!type) return fallback;
        if (type[0] == 'B' || type[0] == 'c' || type[0] == 'C') {
            return ((BOOL (*)(id, SEL))objc_msgSend)(target, selector) ? 1 : 0;
        }
        if (strchr("iIlLqQsS", type[0])) return ((long long (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (NSException *exception) {
    }
    return fallback;
}

- (NSString *)cameraStateSummary {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    @try {
        pid_t pid = [self hostedProcessIdentifier];
        [parts addObject:[NSString stringWithFormat:@"pid=%d", pid]];
        [parts addObject:[NSString stringWithFormat:@"host=%@", _appViewController ? @"appview" : (_ownSceneIdentifier ? @"own-scene" : (_scene ? @"raw" : @"none"))]];
        [parts addObject:[NSString stringWithFormat:@"stageFg=%d staysBg=%d followsHome=%d", _foreground, _staysBackgrounded, _followsSystemHome]];
        BOOL assertionValid = NO;
        if (_runningAssertion) {
            assertionValid = DSHostReadLong(_runningAssertion, @"valid", 1) != 0;
        }
        [parts addObject:[NSString stringWithFormat:@"runAssertion=%@",
                          _runningAssertion ? (assertionValid ? (_runningAssertionPid == pid || _runningAssertionPid == 0 ? @"valid" : @"valid-other-pid") : @"invalid") : @"none"]];
        FBScene *scene = [self hostedScene];
        id settings = [scene respondsToSelector:@selector(settings)] ? scene.settings : nil;
        if (settings) {
            [parts addObject:[NSString stringWithFormat:@"scene fg=%lld occluded=%lld backgrounded=%lld deactivation=0x%llx",
                              DSHostReadLong(settings, @"isForeground", -1), DSHostReadLong(settings, @"isOccluded", -1),
                              DSHostReadLong(settings, @"isBackgrounded", -1), DSHostReadLong(settings, @"deactivationReasons", -1)]];
        } else {
            [parts addObject:@"scene=none"];
        }
        id process = [scene respondsToSelector:@selector(clientProcess)] ? scene.clientProcess : nil;
        if (process) {
            [parts addObject:[NSString stringWithFormat:@"fbProcess fg=%lld visibility=%lld",
                              DSHostReadLong(process, @"isForeground", -1), DSHostReadLong(process, @"visibility", -1)]];
        }
        SBApplication *application = [self application];
        id processState = [application respondsToSelector:@selector(processState)]
            ? ((id (*)(id, SEL))objc_msgSend)(application, @selector(processState))
            : nil;
        if (processState) {
            [parts addObject:[NSString stringWithFormat:@"sbState fg=%lld visibility=%lld task=%lld running=%lld",
                              DSHostReadLong(processState, @"isForeground", -1), DSHostReadLong(processState, @"visibility", -1),
                              DSHostReadLong(processState, @"taskState", -1), DSHostReadLong(processState, @"isRunning", -1)]];
        } else {
            [parts addObject:@"sbState=none"];
        }
    } @catch (NSException *exception) {
        [parts addObject:[NSString stringWithFormat:@"threw %@", exception.name ?: @"?"]];
    }
    return [parts componentsJoinedByString:@" "];
}

- (pid_t)hostedProcessIdentifier {
    SBApplication *application = [self application];
    if ([application respondsToSelector:@selector(pid)]) {
        pid_t pid = application.pid;
        if (pid > 0) return pid;
    }
    FBScene *scene = [self appViewScene] ?: _scene;
    id process = [scene respondsToSelector:@selector(clientProcess)] ? scene.clientProcess : nil;
    if ([process respondsToSelector:@selector(pid)]) {
        pid_t pid = ((pid_t (*)(id, SEL))objc_msgSend)(process, @selector(pid));
        if (pid > 0) return pid;
    }
    return 0;
}

// ---- 4.5.719 bg719 ----------------------------------------------------------------
// True backgrounding, the safe way (4.5.717's Visibility hold is gone for good).
// SpringBoard asks RunningBoard for a legacy background keep-alive on the
// staged / minimised app's pid: RBSAssertion(target pid, RBSLegacyAttribute
// reason Audio(1), then Continuous(10005), flags PreventSuspend |
// PreventThrottleDownCPU | AllowIdleSleep). No Visibility, no scene change.
// - The acquire / invalidate run on a private serial queue (they are XPC to
//   runningboardd); our own state is only touched on the main thread.
// - Once per process and card: a pid that was tried is not tried again unless
//   a relaunch (new pid), an unlock or a card change allows ONE re-take.
//   Never from the stage tick.
// - First use only after the user staged an app and >= 30 s after SpringBoard
//   started. Never Messages, never SpringBoard's own pid, never pid <= 0.
// - Per-action latch: bg719-trying before every take and release, cleared 15 s
//   after the last one; 3 failed takes in a row switch it off for this run.
// Off: /var/mobile/.dynamicstage-bg719-off (crash latch bg719-trying / -crashed).
static BOOL DS719UserStaged = NO;
static BOOL DS719RunOff = NO;
static NSInteger DS719FailStreak = 0;
static BOOL DS719WaitScheduled = NO;

void DSBg719NoteUserStaged(void) {
    DS719UserStaged = YES;
}

static dispatch_queue_t DS719Queue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.recreated.dynamicstage.bg719", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

- (BOOL)bg719AssertionValid {
    id assertion = _bg719Assertion;
    if (!assertion) return NO;
    if (![assertion respondsToSelector:@selector(isValid)]) return YES;
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(assertion, @selector(isValid));
    } @catch (NSException *exception) {
        return NO;
    }
}

- (void)bg719Release:(NSString *)why {
    _bg719Gen += 1;          // an acquire still in flight is dropped when it lands
    _bg719Busy = NO;
    id assertion = _bg719Assertion;
    pid_t pid = _bg719Pid;
    _bg719Assertion = nil;
    _bg719Pid = 0;
    if (!assertion) return;
    DSFeature719MarkAction("bg719");
    dispatch_async(DS719Queue(), ^{
        @try {
            if ([assertion respondsToSelector:@selector(invalidate)]) {
                ((void (*)(id, SEL))objc_msgSend)(assertion, @selector(invalidate));
            }
        } @catch (NSException *exception) {
        }
    });
    DSDiagnosticsRecordFormat(@"SpringBoard: bg719 released %@ pid %d (%@)", _bundleIdentifier ?: @"?", (int)pid, why ?: @"?");
}

// A relaunch, an unlock or a card change: one re-take is allowed.
- (void)bg719AllowRetake {
    _bg719RetakeAllowed = YES;
}

- (void)bg719Request:(NSString *)why {
    if (!NSThread.isMainThread) return;
    if (DS719RunOff || !DS719UserStaged) return;
    if (_bundleIdentifier.length == 0 || [_bundleIdentifier isEqualToString:@"com.apple.MobileSMS"]) return;
    if (!_appViewController && !_scene && !_hostView) return;
    if (DSSceneHostBundleDiedPending(_bundleIdentifier)) return;
    if (!DSFeature699On("bg719")) {
        if (_bg719Assertion) [self bg719Release:@"switched off"];
        return;
    }
    NSTimeInterval up = DSProcessUptime719();
    if (up < 30.0) {
        if (!DS719WaitScheduled) {
            DS719WaitScheduled = YES;
            __weak __typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((30.5 - up) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                DS719WaitScheduled = NO;
                [weakSelf bg719Request:@"30 s after start"];
            });
        }
        return;
    }
    if (_bg719Busy) return;
    pid_t pid = [self hostedProcessIdentifier];
    if (pid <= 0 || pid == getpid()) return;
    if (_bg719Assertion) {
        if (_bg719Pid == pid && [self bg719AssertionValid]) return;
        BOOL relaunched = _bg719Pid != pid;
        [self bg719Release:relaunched ? @"the app relaunched" : @"RunningBoard dropped it"];
        if (relaunched) _bg719RetakeAllowed = YES;
    }
    if (_bg719TriedPid == pid && !_bg719RetakeAllowed) return;   // once per process and card
    _bg719RetakeAllowed = NO;
    _bg719TriedPid = pid;

    Class targetClass = objc_getClass("RBSTarget");
    Class attributeClass = objc_getClass("RBSLegacyAttribute");
    Class assertionClass = objc_getClass("RBSAssertion");
    SEL targetSel = @selector(targetWithPid:);
    SEL attributeSel = @selector(attributeWithReason:flags:);
    SEL initSel = @selector(initWithExplanation:target:attributes:);
    SEL acquireSel = @selector(acquireWithError:);
    if (!targetClass || !attributeClass || !assertionClass ||
        ![targetClass respondsToSelector:targetSel] ||
        ![attributeClass respondsToSelector:attributeSel] ||
        ![assertionClass instancesRespondToSelector:initSel] ||
        ![assertionClass instancesRespondToSelector:acquireSel] ||
        ![assertionClass instancesRespondToSelector:@selector(invalidate)]) {
        DS719RunOff = YES;
        DSDiagnosticsRecordFormat(@"SpringBoard: bg719 RunningBoard API missing (target=%d legacy=%d assertion=%d) - off for this run",
                                  targetClass != nil, attributeClass != nil, assertionClass != nil);
        return;
    }

    _bg719Busy = YES;
    NSUInteger gen = ++_bg719Gen;
    NSString *bundle = [_bundleIdentifier copy];
    NSString *reasonWhy = [why copy] ?: @"?";
    DSFeature719MarkAction("bg719");
    __weak __typeof(self) weakSelf = self;
    dispatch_async(DS719Queue(), ^{
        id acquiredAssertion = nil;
        NSUInteger usedReason = 0;
        NSString *failure = nil;
        // PreventSuspend | PreventThrottleDownCPU | AllowIdleSleep
        const NSUInteger flags = (1u << 0) | (1u << 1) | (1u << 2);
        const NSUInteger reasons[2] = { 1u /* audio */, 10005u /* continuous */ };
        for (int r = 0; r < 2 && !acquiredAssertion; r++) {
            id assertion = nil;
            NSError *error = nil;
            BOOL ok = NO;
            @try {
                id target = ((id (*)(id, SEL, int))objc_msgSend)(targetClass, targetSel, (int)pid);
                id attribute = ((id (*)(id, SEL, NSUInteger, NSUInteger))objc_msgSend)(attributeClass, attributeSel, reasons[r], flags);
                if (target && attribute) {
                    NSString *explanation = [NSString stringWithFormat:@"Dynamic Stage bg719 %@", bundle];
                    assertion = ((id (*)(id, SEL, NSString *, id, NSArray *))objc_msgSend)([assertionClass alloc], initSel,
                                                                                          explanation, target, @[attribute]);
                }
                if (assertion) ok = ((BOOL (*)(id, SEL, NSError **))objc_msgSend)(assertion, acquireSel, &error);
            } @catch (NSException *exception) {
                ok = NO;
                failure = [NSString stringWithFormat:@"threw %@", exception.name ?: @"?"];
            }
            if (ok) {
                acquiredAssertion = assertion;
                usedReason = reasons[r];
            } else {
                if (error) failure = [NSString stringWithFormat:@"reason %lu: %@", (unsigned long)reasons[r],
                                      error.localizedFailureReason ?: error.localizedDescription ?: @"?"];
                @try {
                    if (assertion) ((void (*)(id, SEL))objc_msgSend)(assertion, @selector(invalidate));
                } @catch (NSException *exception) {
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong __typeof(weakSelf) host = weakSelf;
            BOOL stale = !host || host->_bg719Gen != gen || [host hostedProcessIdentifier] != pid;
            if (host && host->_bg719Gen == gen) host->_bg719Busy = NO;
            if (!acquiredAssertion) {
                DS719FailStreak += 1;
                DSDiagnosticsRecordFormat(@"SpringBoard: bg719 could not hold %@ pid %d (%@; %@) [%ld in a row]", bundle, (int)pid,
                                          failure ?: @"no assertion", reasonWhy, (long)DS719FailStreak);
                if (DS719FailStreak >= 3 && !DS719RunOff) {
                    DS719RunOff = YES;
                    DSDiagnosticsRecord(@"SpringBoard: bg719 off for this SpringBoard run (3 failed takes in a row)");
                }
                return;
            }
            DS719FailStreak = 0;
            if (stale) {
                DSFeature719MarkAction("bg719");
                dispatch_async(DS719Queue(), ^{
                    @try {
                        ((void (*)(id, SEL))objc_msgSend)(acquiredAssertion, @selector(invalidate));
                    } @catch (NSException *exception) {
                    }
                });
                DSDiagnosticsRecordFormat(@"SpringBoard: bg719 released %@ pid %d (card changed while taking it)", bundle, (int)pid);
                return;
            }
            host->_bg719Assertion = acquiredAssertion;
            host->_bg719Pid = pid;
            DSDiagnosticsRecordFormat(@"SpringBoard: bg719 holding %@ pid %d (%@, %@)", bundle, (int)pid,
                                      usedReason == 1 ? @"audio" : @"continuous", reasonWhy);
        });
    });
}

- (void)releaseRunningAssertion {
    id assertion = _runningAssertion;
    _runningAssertion = nil;
    _runningAssertionPid = 0;
    if (!assertion) return;
    @try {
        if ([assertion respondsToSelector:@selector(invalidate)]) {
            ((void (*)(id, SEL))objc_msgSend)(assertion, @selector(invalidate));
        }
    } @catch (NSException *exception) {
    }
}

// A minimized app was only marked backgrounded, so RunningBoard suspended it
// or the app crashed in that transition. This assertion is what keeps the
// process scheduled after the card has left the screen.
- (DSRunningAssertion *)acquireRunningAssertionForClass:(Class)assertionClass
                                                    pid:(pid_t)pid
                                                  flags:(NSUInteger)flags
                                                 reason:(NSUInteger)reason {
    DSRunningAssertion *assertion = nil;
    @try {
        if (pid > 0) {
            assertion = [(DSRunningAssertion *)[assertionClass alloc] initWithPID:(NSInteger)pid
                                                                             flags:flags
                                                                            reason:reason
                                                                              name:@"Dynamic Stage"
                                                                       withHandler:nil];
        } else if (_bundleIdentifier.length > 0) {
            assertion = [(DSRunningAssertion *)[assertionClass alloc] initWithBundleIdentifier:_bundleIdentifier
                                                                                          flags:flags
                                                                                         reason:reason
                                                                                           name:@"Dynamic Stage"
                                                                                    withHandler:nil];
        }
    } @catch (NSException *exception) {
        assertion = nil;
    }
    if (!assertion) return nil;
    BOOL valid = YES;
    if ([assertion respondsToSelector:@selector(valid)]) valid = assertion.valid;
    if (valid) return assertion;
    @try {
        if ([assertion respondsToSelector:@selector(invalidate)]) [assertion invalidate];
    } @catch (NSException *exception) {
    }
    return nil;
}

- (void)holdRunningAssertion {
    // 4.5.657: killed from the switcher; never wake or relaunch it from here.
    if (DSSceneHostBundleDiedPending(_bundleIdentifier)) return;
    if (!_appViewController && !_scene && !_hostView) return;
    @try {
        [self bg719Request:@"stage hold"];
    } @catch (NSException *exception) {
    }
    pid_t pid = [self hostedProcessIdentifier];
    if (_runningAssertion && (pid <= 0 || _runningAssertionPid == pid)) {
        BOOL valid = YES;
        if ([_runningAssertion respondsToSelector:@selector(valid)]) {
            valid = ((BOOL (*)(id, SEL))objc_msgSend)(_runningAssertion, @selector(valid));
        }
        if (valid) return;
        [self releaseRunningAssertion];
    } else if (_runningAssertion) {
        [self releaseRunningAssertion];
    }

    Class assertionClass = objc_getClass("BKSProcessAssertion");
    if (!assertionClass) {
        [self scheduleRunningAssertionRetry];
        return;
    }

    // Prevent suspend, keep the CPU from being throttled to a stop, and still
    // let the phone sleep. Continuous is the reason that does not expire.
    NSUInteger flags = (1u << 0) | (1u << 1) | (1u << 2);
    NSUInteger reasons[] = { 10005u, 9u, 7u, 10004u };
    for (NSUInteger index = 0; index < 4; index++) {
        DSRunningAssertion *assertion = [self acquireRunningAssertionForClass:assertionClass
                                                                            pid:pid
                                                                          flags:flags
                                                                         reason:reasons[index]];
        if (!assertion && pid > 0) {
            assertion = [self acquireRunningAssertionForClass:assertionClass pid:0 flags:flags reason:reasons[index]];
        }
        if (!assertion) continue;
        _runningAssertion = assertion;
        _runningAssertionPid = pid > 0 ? pid : 0;
        _runningAssertionAttempts = 0;
        DSDiagnosticsRecordFormat(@"SpringBoard: %@ stays running in the background", _bundleIdentifier);
        return;
    }
    [self scheduleRunningAssertionRetry];
}

- (void)scheduleRunningAssertionRetry {
    if (_runningAssertionRetry || _runningAssertionAttempts >= 4) return;
    _runningAssertionRetry = YES;
    _runningAssertionAttempts += 1;
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_runningAssertionRetry = NO;
        if (!strongSelf->_appViewController && !strongSelf->_scene && !strongSelf->_hostView) return;
        [strongSelf holdRunningAssertion];
    });
}

- (void)setFollowsSystemHomeTransition:(BOOL)follows {
    if (!_appViewController || _followsSystemHome == follows) return;
    _followsSystemHome = follows;
    // 4.5.659: SpringBoard finishes its side of the hand-back after the
    // property flips. No stage wake / mode change inside this window.
    if (!follows) _systemHomeSettleUntil = CFAbsoluteTimeGetCurrent() + 3.0;
    SBAppViewController *controller = _appViewController;
    @try {
        // Property only. Changing the app view's mode on the way back runs in
        // the same moment the next transition starts — Spotlight's keyboard
        // was the one on screen — and that mode change is the SIGTRAP.
        if ([controller respondsToSelector:@selector(setAutomatesLifecycle:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setAutomatesLifecycle:), follows);
        }
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: %@ home-transition handoff threw %@",
                                  _bundleIdentifier, exception.name ?: @"?");
    }
    if (!follows) [self holdRunningAssertion];
    if (follows) {
        DSDiagnosticsRecordFormat(@"SpringBoard: %@ will follow the home transition", _bundleIdentifier);
    }
}

- (void)setStaysBackgrounded:(BOOL)stays {
    BOOL changed = _staysBackgrounded != stays;
    _staysBackgrounded = stays;
    if (_appViewController) {
        objc_setAssociatedObject(_appViewController, @selector(appViewControllerStaysBackgrounded:),
                                 @(stays), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (stays || _appViewController || _scene) [self holdRunningAssertion];
    if (DSAvoidSceneLifecycle()) return;
    if (changed && (_scene || _appViewController)) [self registerGeometryOnlyOverride];
}

- (void)setForeground:(BOOL)foreground {
    _foreground = foreground;
    if (DSAvoidSceneLifecycle()) return;

    // SpringBoard's app view owns the app's lifecycle, and telling its scene it is
    // foreground from outside is exactly what makes it assert - which takes
    // SpringBoard with it. So under an app view the stage only ever dictates size.
    if (_appViewController) {
        [self registerGeometryOnlyOverride];
        if (foreground) [self wakeIfBackgrounded];
        return;
    }

    [self registerOverride];
    [self pushSettings];
}

- (NSDictionary *)overrideDescription {
    NSMutableDictionary *description = [@{
        @"frame" : [NSValue valueWithCGRect:[self frameForScene]],
        @"insets" : [NSValue valueWithUIEdgeInsets:[self insetsForScene]],
        @"foreground" : @(_foreground),
    } mutableCopy];
    CGFloat statusBar = _phoneSize ? [self phoneSize688StatusBarHeight] : 0.0;
    if (statusBar > 0.0) description[@"statusBar"] = @(statusBar);
    return description;
}

- (void)registerOverride {
    if (DSSceneHostBundleDiedPending(_bundleIdentifier)) return;
    NSString *identifier = [_scene respondsToSelector:@selector(identifier)] ? _scene.identifier : nil;
    if (identifier.length == 0) return;
    [DSSceneOverridesLock() lock];
    DSSceneOverrides()[identifier] = [self overrideDescription];
    DSSceneOverrideCountValue = (NSInteger)DSSceneOverrides().count;
    [DSSceneOverridesLock() unlock];
    _registeredOverride = YES;
}

- (void)removeOverride {
    if (!_registeredOverride) return;
    NSString *identifier = [_scene respondsToSelector:@selector(identifier)] ? _scene.identifier : nil;
    if (identifier.length == 0) return;
    [DSSceneOverridesLock() lock];
    [DSSceneOverrides() removeObjectForKey:identifier];
    DSSceneOverrideCountValue = (NSInteger)DSSceneOverrides().count;
    [DSSceneOverridesLock() unlock];
    _registeredOverride = NO;
    // 4.5.688: a raised status bar height goes back to the scene's own value.
    if (DSPhoneSize688HasStatusBarOriginal(identifier) && !DSAvoidSceneLifecycle()) {
        DSUpdateSceneSettings(_scene, ^(FBSMutableSceneSettings *settings) {
            DSPhoneSize688ApplyStatusBar(settings, identifier, 0.0);
        });
    }
}

- (void)pushSettings {
    if (_appViewController) {
        [self forceSceneGeometry];
        return;
    }
    if (!_scene) return;
    CGRect logical = [self frameForScene];
    UIEdgeInsets insets = [self insetsForScene];
    BOOL foreground = _foreground;

    [self updateSceneSettings:^(FBSMutableSceneSettings *settings) {
        @try {
            settings.frame = logical;
            if ([settings respondsToSelector:@selector(setSafeAreaInsetsPortrait:)]) {
                settings.safeAreaInsetsPortrait = insets;
            }
            if ([settings respondsToSelector:@selector(setInterfaceOrientation:)]) {
                settings.interfaceOrientation = UIInterfaceOrientationPortrait;
            }
            if ([settings respondsToSelector:@selector(setDeviceOrientation:)]) {
                settings.deviceOrientation = UIDeviceOrientationPortrait;
            }
            if ([settings respondsToSelector:@selector(setForeground:)]) settings.foreground = foreground;
            // Minimized means "not the front app", not "suspend the process".
            // backgrounded YES is what made the app stop or crash.
            BOOL backgrounded = foreground ? NO : (_staysBackgrounded ? NO : YES);
            if ([settings respondsToSelector:@selector(setBackgrounded:)]) settings.backgrounded = backgrounded;
            if (_staysBackgrounded && [settings respondsToSelector:@selector(setDeactivated:)]) {
                settings.deactivated = NO;
            }
            if ([settings respondsToSelector:@selector(setOccluded:)]) settings.occluded = NO;
            if ([settings respondsToSelector:@selector(setDeactivated:)]) settings.deactivated = NO;
            if ([settings respondsToSelector:@selector(setStatusBarDisabled:)]) settings.statusBarDisabled = YES;
        } @catch (NSException *exception) {
        }
    }];
}

- (void)updateSceneSettings:(void (^)(FBSMutableSceneSettings *settings))block {
    DSUpdateSceneSettings(_scene, block);
}

#pragma mark - Teardown

- (void)relinquishKeepingBackgrounded:(BOOL)background {
    [self phoneSize690RemoveStrip:@"card let go"];
    [self restoreOwnedStrayPresentations];
    _straySweepScheduled = NO;
    [self bg719Release:@"card closed"];
    [self releaseRunningAssertion];
    [self removeOverride];

    // SpringBoard's app view takes itself apart, including handing the app back to
    // whatever SpringBoard wants to do with it next.
    if (_appViewController) {
        [self tearDownAppViewController];
        _hostView = nil;
        _scene = nil;
        _nudgedThisLaunch = NO;
        _tookOverForegroundLaunch = NO;
        return;
    }

    // A scene the stage made is the stage's to take down, and there is nothing to
    // hand back: the app keeps running, it simply loses this window.
    if (_ownSceneIdentifier) {
        NSString *identifier = _ownSceneIdentifier;
        UIScenePresenter *presenter = _presenter;
        FBScene *scene = _scene;
        [_hostView removeFromSuperview];
        _ownSceneIdentifier = nil;
        _presenter = nil;
        _hostView = nil;
        _scene = nil;
        _tookOverForegroundLaunch = NO;

        @try {
            [presenter deactivate];
            [presenter invalidate];
            FBSceneManager *manager = (FBSceneManager *)[objc_getClass("FBSceneManager") sharedInstance];
            if ([manager respondsToSelector:@selector(destroyScene:withTransitionContext:)]) {
                [manager destroyScene:identifier withTransitionContext:nil];
                // FrontBoard takes either the name of the scene or the scene itself
                // depending on the build, and takes the wrong one in silence, so the
                // result is checked: a scene left behind is a window the app keeps
                // for nothing.
                if ([manager respondsToSelector:@selector(sceneWithIdentifier:)] &&
                    [manager sceneWithIdentifier:identifier]) {
                    [manager destroyScene:(id)scene withTransitionContext:nil];
                }
            }
        } @catch (NSException *exception) {
            DSDiagnosticsRecordFormat(@"SpringBoard: taking down %@'s stage window threw %@",
                                      _bundleIdentifier, exception.name ?: @"?");
        }
        return;
    }

    // Restore a sane full screen geometry before handing the scene back, so the
    // app is not left thinking it is stage sized next time it is launched.
    CGRect screenBounds = UIScreen.mainScreen.bounds;
    UIEdgeInsets screenInsets = UIEdgeInsetsZero;
    UIWindow *window = UIApplication.sharedApplication.windows.firstObject;
    if (@available(iOS 11.0, *)) screenInsets = window.safeAreaInsets;

    [self updateSceneSettings:^(FBSMutableSceneSettings *settings) {
        @try {
            settings.frame = screenBounds;
            if ([settings respondsToSelector:@selector(setSafeAreaInsetsPortrait:)]) {
                settings.safeAreaInsetsPortrait = screenInsets;
            }
            if ([settings respondsToSelector:@selector(setStatusBarDisabled:)]) settings.statusBarDisabled = NO;
            if ([settings respondsToSelector:@selector(setForeground:)]) settings.foreground = NO;
            if ([settings respondsToSelector:@selector(setBackgrounded:)]) settings.backgrounded = background;
        } @catch (NSException *exception) {
        }
    }];

    [_hostView removeFromSuperview];
    _hostView = nil;
    _scene = nil;
    _tookOverForegroundLaunch = NO;
}

- (void)terminate {
    NSString *identifier = _bundleIdentifier;
    SBApplication *application = [self application];
    [self relinquishKeepingBackgrounded:NO];

    // SBApplication's own killer is the polite path: it tears down the scene
    // bookkeeping SpringBoard keeps alongside the process.
    SEL killer = @selector(killForReason:andReport:withDescription:);
    if ([application respondsToSelector:killer]) {
        @try {
            ((void (*)(id, SEL, NSInteger, BOOL, id))objc_msgSend)(application, killer, 1, NO, @"Dynamic Stage");
            return;
        } @catch (NSException *exception) {
        }
    }

    id service = DSSystemService();
    SEL selector = @selector(terminateApplication:forReason:andReport:withDescription:);
    if (![service respondsToSelector:selector]) return;
    @try {
        ((void (*)(id, SEL, id, NSInteger, BOOL, id))objc_msgSend)(service, selector, identifier, 1, NO, @"Dynamic Stage");
    } @catch (NSException *exception) {
    }
}

- (BOOL)isProcessAlive {
    SBApplication *application = [self application];
    if (!application) return NO;
    @try {
        if ([application respondsToSelector:@selector(isRunning)]) {
            return ((BOOL (*)(id, SEL))objc_msgSend)(application, @selector(isRunning));
        }
        if ([application respondsToSelector:@selector(process)]) {
            id process = ((id (*)(id, SEL))objc_msgSend)(application, @selector(process));
            return process != nil;
        }
    } @catch (NSException *exception) {
    }
    return _scene != nil;
}

#pragma mark - Override application

// ---- 4.5.657: system transition (home swipe / app switcher) -------------
// 4.5.650-656 asked SBMainSwitcherController -isMainSwitcherVisible here (at
// most every 0.1 s from the hooks, and every 0.3 s from a poll that ran for as
// long as the switcher stayed open) and re-posted the Darwin state every 2 s.
// All of that ran while the user was flicking cards away. The switcher is no
// longer asked at all: "busy" is the home gesture / its quiet window, plus
// DSSystemOwnsScreen, which the home gesture begin sets and the next stage use
// clears. The Darwin state is posted on the gesture's begin and end only.
static BOOL DSSysGesturePosted = NO;

// Darwin state = absolute time the home gesture began (0 = over). Posted on a
// change only; apps treat a value older than 4s as over.
static void DSPostSystemGestureState(void) {
    BOOL active = DSHomeGestureActive;
    if (active == DSSysGesturePosted) return;
    DSSysGesturePosted = active;
    static int token = NOTIFY_TOKEN_INVALID;
    if (token == NOTIFY_TOKEN_INVALID) {
        notify_register_check("com.recreated.dynamicstage.systemgesture", &token);
    }
    if (token != NOTIFY_TOKEN_INVALID) notify_set_state(token, active ? (uint64_t)CFAbsoluteTimeGetCurrent() : 0);
    notify_post("com.recreated.dynamicstage.systemgesture");
}

static void DSRunAfterTransitionBlocks(void) {
    if (DSAfterTransitionBlocks.count == 0 || DSSystemOwnsScreen) return;
    if (DSAvoidSceneLifecycle()) {
        // Only the gesture itself (at most its 2.5 s timeout) or its 1.15 s
        // quiet window; never the switcher.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            DSRunAfterTransitionBlocks();
        });
        return;
    }
    NSArray<dispatch_block_t> *blocks = [DSAfterTransitionBlocks copy];
    [DSAfterTransitionBlocks removeAllObjects];
    for (dispatch_block_t block in blocks) {
        @try {
            block();
        } @catch (NSException *exception) {
        }
    }
}

+ (BOOL)systemTransitionBusy {
    if (DSAvoidSceneLifecycle()) return YES;
    // A card back on screen means the stage is in use again, whichever path
    // brought it back (ivar reads only; NO whenever the switcher is up,
    // because the swipe into it parks every card).
    if (DSSystemOwnsScreen && pthread_main_np() && DSStageCardOnScreenFast()) [self noteStageInUse];
    return DSSystemOwnsScreen;
}

+ (void)noteSystemTookScreen {
    DSSystemOwnsScreen = YES;
    // 4.5.661: the camera presence elements come out of the display layout.
    // Queued, never from inside the gesture callback; the arbiter waits for
    // the gesture to end before it touches the layout.
    dispatch_async(dispatch_get_main_queue(), ^{
        [DSCameraArbiter refreshSoon];
    });
}

+ (void)noteStageInUse {
    // 4.5.661: re-add the camera presence elements lazily (coalesced, 50 ms).
    [DSCameraArbiter refreshSoon];
    if (!DSSystemOwnsScreen && DSAfterTransitionBlocks.count == 0) return;
    DSSystemOwnsScreen = NO;
    if (DSAfterTransitionBlocks.count == 0) return;
    // Never inside the stage method that noted the use.
    dispatch_async(dispatch_get_main_queue(), ^{
        DSRunAfterTransitionBlocks();
    });
}

+ (void)performWhenSystemTransitionOver:(dispatch_block_t)block {
    if (!block) return;
    if (!DSSystemOwnsScreen && !DSAvoidSceneLifecycle()) {
        block();
        return;
    }
    if (!DSAfterTransitionBlocks) DSAfterTransitionBlocks = [NSMutableArray array];
    if (DSAfterTransitionBlocks.count < 8) [DSAfterTransitionBlocks addObject:[block copy]];
    if (!DSSystemOwnsScreen) DSRunAfterTransitionBlocks();
}

+ (void)setHomeGestureActive:(BOOL)active {
    BOOL changed = DSHomeGestureActive != active;
    DSHomeGestureActive = active;
    if (!active) {
        DSHomeGestureQuietUntil = CFAbsoluteTimeGetCurrent() + 1.15;
        DSHomeGestureEndedAt = CFAbsoluteTimeGetCurrent();
    }
    if (changed) DSPostSystemGestureState();
    if (changed && NSThread.isMainThread) DSGest770NoteEvent(active ? @"home began" : @"home ended");
}

+ (BOOL)homeGestureIsActive {
    return DSAvoidSceneLifecycle();
}

+ (void)beginSystemPullCallback {
    DSSystemPullDepth += 1;
}

+ (void)endSystemPullCallback {
    if (DSSystemPullDepth > 0) DSSystemPullDepth -= 1;
}

+ (BOOL)systemPullCallbackIsActive {
    return DSSystemPullDepth > 0;
}

+ (void)beginSceneSettingsUpdate {
    DSSceneSettingsUpdateDepth += 1;
}

+ (void)endSceneSettingsUpdate {
    if (DSSceneSettingsUpdateDepth > 0) DSSceneSettingsUpdateDepth -= 1;
}

+ (NSInteger)sceneSettingsUpdateDepth {
    return DSSceneSettingsUpdateDepth;
}

+ (BOOL)stageRequestedFrame:(CGRect)frame forSceneIdentifier:(NSString *)identifier {
    if (identifier.length == 0 || CGRectIsEmpty(frame)) return NO;
    [DSSceneOverridesLock() lock];
    NSDictionary *override = DSSceneOverrides()[identifier];
    [DSSceneOverridesLock() unlock];
    if (!override) return NO;
    CGRect wanted = [override[@"frame"] CGRectValue];
    if (CGRectIsEmpty(wanted)) return NO;
    return fabs(CGRectGetWidth(wanted) - CGRectGetWidth(frame)) < 3.0 &&
           fabs(CGRectGetHeight(wanted) - CGRectGetHeight(frame)) < 3.0;
}

+ (void)noteFullScreenHandoffOfBundleIdentifier:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0) return;
    DSHandedOffBundle = [bundleIdentifier copy];
    DSHandedOffUntil = CFAbsoluteTimeGetCurrent() + 3.0;
    [DSSceneOverridesLock() lock];
    for (NSString *identifier in [DSSceneOverrides().allKeys copy]) {
        if ([identifier rangeOfString:bundleIdentifier].location == NSNotFound) continue;
        [DSSceneOverrides() removeObjectForKey:identifier];
    }
    DSSceneOverrideCountValue = (NSInteger)DSSceneOverrides().count;
    [DSSceneOverridesLock() unlock];
}

+ (void)noteHomeHandBack {
    DSHomeHandBackAt = CFAbsoluteTimeGetCurrent();
}

+ (void)noteSystemEdgePullActive:(BOOL)active {
    if (DSSystemEdgePullActive == active) return;
    DSSystemEdgePullActive = active;
    if (active) DSSystemEdgePullStartedAt = CFAbsoluteTimeGetCurrent();
    else DSSystemEdgePullEndedAt = CFAbsoluteTimeGetCurrent();
}

// A pull that never reported its end counts as over after 10 s.
+ (BOOL)systemEdgePullIsActive {
    return DSSystemEdgePullActive && CFAbsoluteTimeGetCurrent() - DSSystemEdgePullStartedAt < 10.0;
}

// Data reads only. Called from inside the FBScene update hook.
+ (NSString *)systemTransitionHoldsSceneReason {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if ([self systemEdgePullIsActive]) return @"corner pull adopted from the system gesture";
    if (DSSystemEdgePullEndedAt > 0 && now - DSSystemEdgePullEndedAt < 1.5) return @"corner pull just ended";
    if (DSHomeHandBackAt > 0 && now - DSHomeHandBackAt < 3.0) return @"home hand-back settling";
    if (DSHomeGestureEndedAt > 0 && now - DSHomeGestureEndedAt < 4.0) return @"home transition finishing";
    return nil;
}

+ (BOOL)isStageActivatingSceneIdentifier:(NSString *)identifier {
    if (identifier.length == 0 || DSActivatingBundle.length == 0) return NO;
    if (CFAbsoluteTimeGetCurrent() >= DSActivatingUntil) return NO;
    return [identifier rangeOfString:DSActivatingBundle].location != NSNotFound;
}

+ (BOOL)isHandingOffSceneIdentifier:(NSString *)identifier {
    if (identifier.length == 0 || DSHandedOffBundle.length == 0) return NO;
    if (CFAbsoluteTimeGetCurrent() >= DSHandedOffUntil) return NO;
    return [identifier rangeOfString:DSHandedOffBundle].location != NSNotFound;
}

+ (BOOL)readForegroundFlag:(id)settings known:(BOOL *)known {
    if (known) *known = NO;
    if (!settings) return NO;
    for (NSString *name in @[ @"isForeground", @"foreground" ]) {
        SEL selector = NSSelectorFromString(name);
        if (![settings respondsToSelector:selector]) continue;
        @try {
            BOOL value = ((BOOL (*)(id, SEL))objc_msgSend)(settings, selector);
            if (known) *known = YES;
            return value;
        } @catch (NSException *exception) {
        }
    }
    return NO;
}

// 4.5.716 blackout716 ("Blacked out again after lock screen and minimised for
// ages", 4.5.715): locked while the Beeper card was minimised, the scene was
// put in the background; after the corner restore every foreground update -
// including the ones the stage's own wake (_activateApp) caused - was written
// back to the committed background here, so the wake never took and the card
// stayed black. Within 2 s of the stage waking this app, a background ->
// foreground update now lands (never foreground -> background, never Messages,
// never while locked). Off: /var/mobile/.dynamicstage-blackout716-off (crash
// latch blackout716-trying / -crashed) = exactly 4.5.715.
+ (BOOL)blackout716LetsForegroundLand:(FBScene *)scene incoming:(FBSMutableSceneSettings *)settings {
    if (DSWake716Bundle.length == 0) return NO;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now >= DSWake716Until) return NO;
    NSString *identifier = [scene respondsToSelector:@selector(identifier)] ? scene.identifier : nil;
    if (identifier.length == 0 || [identifier rangeOfString:DSWake716Bundle].location == NSNotFound) return NO;
    if ([identifier rangeOfString:@"MobileSMS"].location != NSNotFound) return NO;
    BOOL knownIncoming = NO;
    BOOL incoming = [self readForegroundFlag:settings known:&knownIncoming];
    if (!knownIncoming || !incoming) return NO;
    if (DSPS696DeviceLocked()) return NO;
    if (!DSFeature699On("blackout716")) return NO;
    DSFeature699MarkTrying("blackout716");
    static CFAbsoluteTime lastLog = 0;
    if (now - lastLog > 1.0 || now < lastLog) {
        lastLog = now;
        DSDiagnosticsRecordFormat(@"SpringBoard: blackout716 %@ woken by the stage: its foreground update lands (the scene was held in the background)", identifier);
    }
    return YES;
}

+ (void)keepCommittedForegroundOfScene:(FBScene *)scene onSettings:(FBSMutableSceneSettings *)settings {
    if (!settings || ![scene respondsToSelector:@selector(settings)]) return;
    BOOL known = NO;
    BOOL foreground = [self readForegroundFlag:scene.settings known:&known];
    if (!known || ![settings respondsToSelector:@selector(setForeground:)]) return;
    if (!foreground && [self blackout716LetsForegroundLand:scene incoming:settings]) return;
    @try {
        settings.foreground = foreground;
    } @catch (NSException *exception) {
    }
}

+ (BOOL)applyOverridesToSettings:(FBSMutableSceneSettings *)settings forScene:(FBScene *)scene {
    DS_PERF_BEGIN();
    BOOL applied = [self applyOverrides697ToSettings:settings forScene:scene];
    DS_PERF_END(DSPerfBucketSceneHook);
    return applied;
}

+ (BOOL)applyOverrides697ToSettings:(FBSMutableSceneSettings *)settings forScene:(FBScene *)scene {
    if (DSAvoidSceneLifecycle()) return NO;
    if (!settings || ![scene respondsToSelector:@selector(identifier)]) return NO;
    NSString *identifier = scene.identifier;
    if (identifier.length == 0) return NO;
    if (DSHandedOffBundle.length > 0 && CFAbsoluteTimeGetCurrent() < DSHandedOffUntil &&
        [identifier rangeOfString:DSHandedOffBundle].location != NSNotFound) {
        // The card override is gone. A settings write that still carries the
        // split size would put Messages back in that rectangle.
        CGRect screen = UIScreen.mainScreen.bounds;
        CGRect frame = CGRectZero;
        @try {
            frame = settings.frame;
        } @catch (NSException *exception) {
        }
        BOOL shortOfPhone = CGRectGetWidth(screen) > 80.0 && CGRectGetHeight(screen) > 80.0 &&
            (CGRectGetWidth(frame) + 8.0 < CGRectGetWidth(screen) ||
             CGRectGetHeight(frame) + 24.0 < CGRectGetHeight(screen));
        if (!shortOfPhone) return NO;
        UIEdgeInsets insets = UIEdgeInsetsZero;
        if (@available(iOS 11.0, *)) {
            insets = UIApplication.sharedApplication.windows.firstObject.safeAreaInsets;
        }
        DSApplyGeometry(settings, CGRectMake(0.0, 0.0, CGRectGetWidth(screen), CGRectGetHeight(screen)), insets);
        DSPhoneSize688ApplyStatusBar(settings, identifier, 0.0);
        return YES;
    }

    [DSSceneOverridesLock() lock];
    NSDictionary *override = DSSceneOverrides()[identifier];
    [DSSceneOverridesLock() unlock];
    if (!override) return NO;

    DSApplyGeometry(settings, [override[@"frame"] CGRectValue], [override[@"insets"] UIEdgeInsetsValue]);
    // 4.5.799: keep our occlusion reason on every settings write we touch, so a
    // geometry update cannot wipe what the contributor put in.
    if (DSReg799On()) {
        NSString *reason = override[@"reg799Reason"];
        if (reason.length == 0) {
            // Fall back: match an owned app view whose scene is this one.
            for (SBAppViewController *c in DSOwnedAppViewControllers()) {
                @try {
                    id h = DSIvar(c, @"_sceneHandle");
                    if (!h && [c respondsToSelector:@selector(sceneHandle)]) h = ((id (*)(id, SEL))objc_msgSend)(c, @selector(sceneHandle));
                    FBScene *sc = [h respondsToSelector:@selector(scene)] ? ((FBScene *(*)(id, SEL))objc_msgSend)(h, @selector(scene)) : nil;
                    if (sc == scene || (sc.identifier.length && [sc.identifier isEqualToString:identifier])) {
                        Ivar iv = class_getInstanceVariable(object_getClass(c), "_identifier");
                        id ident = iv ? object_getIvar(c, iv) : nil;
                        if ([ident isKindOfClass:[NSString class]]) reason = ident;
                        break;
                    }
                } @catch (NSException *e) {}
            }
        }
        if (reason.length) [DSSceneHost reg799AppendReason:reason toSettings:settings log:NO];
    }
    // 4.5.688 mode=statusbar: keep the raised status bar height (or put it back).
    if (override[@"statusBar"] || DSPhoneSize688HasStatusBarOriginal(identifier)) {
        DSPhoneSize688ApplyStatusBar(settings, identifier, [override[@"statusBar"] doubleValue]);
    }
    // A minimized app stays backgrounded. Never write foreground YES here.
    // That write is the assert that safe-modes SpringBoard.
    if ([override[@"staysBackgrounded"] boolValue]) {
        @try {
            // Not the front app. Still running: backgrounded YES suspends it.
            if ([settings respondsToSelector:@selector(setForeground:)]) settings.foreground = NO;
            if ([settings respondsToSelector:@selector(setBackgrounded:)]) settings.backgrounded = NO;
            if ([settings respondsToSelector:@selector(setDeactivated:)]) settings.deactivated = NO;
        } @catch (NSException *exception) {
        }
    }
    // 4.5.652: a visible card whose app holds the camera is on screen and in
    // front as far as its own scene is concerned: not occluded, nothing
    // deactivating it. Foreground itself is never written here (see above),
    // and nothing is written during the home / switcher gesture.
    if (![override[@"staysBackgrounded"] boolValue] && ![self homeGestureIsActive] &&
        ![self systemTransitionBusy] && [DSCameraArbiter sceneIdentifierHoldsCamera:identifier]) {
        @try {
            if ([settings respondsToSelector:@selector(setOccluded:)]) settings.occluded = NO;
            SEL reasons = NSSelectorFromString(@"setDeactivationReasons:");
            if ([settings respondsToSelector:reasons]) {
                ((void (*)(id, SEL, unsigned long long))objc_msgSend)(settings, reasons, 0ULL);
            }
            static CFAbsoluteTime DSCameraSceneLog = 0;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - DSCameraSceneLog > 3.0) {
                DSCameraSceneLog = now;
                DSDiagnosticsRecordFormat(@"SpringBoard: camera658 %@ holds the camera: scene kept unoccluded, no deactivation, path=scene-front", identifier);
            }
        } @catch (NSException *exception) {
        }
    }
    // 4.5.696 keys: a visible phone-size card's scene does not keep
    // SpringBoard's systemAnimation deactivation (0x20); only that bit, only
    // while it is foreground, never during the home gesture, a system
    // transition or with the phone locked.
    if (![override[@"staysBackgrounded"] boolValue] && DSPS696IsKeysScene(identifier) && DSPS696Enabled(1) &&
        ![self homeGestureIsActive] && ![self systemTransitionBusy] && !DSPS696DeviceLocked()) {
        @try {
            BOOL known = NO;
            BOOL foreground = [self readForegroundFlag:settings known:&known];
            SEL getReasons = @selector(deactivationReasons);
            SEL setReasons = NSSelectorFromString(@"setDeactivationReasons:");
            if (known && foreground && [settings respondsToSelector:getReasons] && [settings respondsToSelector:setReasons]) {
                unsigned long long reasons = ((unsigned long long (*)(id, SEL))objc_msgSend)(settings, getReasons);
                if (reasons & 0x20ULL) {
                    ((void (*)(id, SEL, unsigned long long))objc_msgSend)(settings, setReasons, reasons & ~0x20ULL);
                    DSPS696MarkTrying(1);
                    static CFAbsoluteTime DSPS696KeysLog = 0;
                    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                    if (now - DSPS696KeysLog > 3.0 || now < DSPS696KeysLog) {
                        DSPS696KeysLog = now;
                        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize696 keys: cleared SpringBoard's systemAnimation deactivation (0x%llx -> 0x%llx) on the phone-size card %@, "
                                                  @"so the app is already active at the first tap", reasons, reasons & ~0x20ULL, identifier);
                        DSCall758NoteSystemAnimation(identifier);
                    }
                }
            }
        } @catch (NSException *exception) {
        }
    }
    if ([override[@"geometryOnly"] boolValue]) return YES;

    @try {
        if ([settings respondsToSelector:@selector(setForeground:)]) {
            settings.foreground = [override[@"foreground"] boolValue];
        }
        if ([settings respondsToSelector:@selector(setStatusBarDisabled:)]) settings.statusBarDisabled = YES;
    } @catch (NSException *exception) {
        return NO;
    }
    return YES;
}

+ (BOOL)ownsAppViewController:(id)controller {
    if (!controller) return NO;
    return [DSOwnedAppViewControllers() containsObject:controller];
}

+ (BOOL)appViewControllerStaysBackgrounded:(id)controller {
    if (!controller) return NO;
    NSNumber *value = objc_getAssociatedObject(controller, @selector(appViewControllerStaysBackgrounded:));
    return value.boolValue;
}

+ (BOOL)sceneIdentifierStaysBackgrounded:(NSString *)identifier {
    if (identifier.length == 0) return NO;
    [DSSceneOverridesLock() lock];
    NSDictionary *override = DSSceneOverrides()[identifier];
    BOOL stays = [override[@"staysBackgrounded"] boolValue];
    [DSSceneOverridesLock() unlock];
    return stays;
}

+ (BOOL)sceneIdentifierHasOverride:(NSString *)identifier {
    if (identifier.length == 0) return NO;
    [DSSceneOverridesLock() lock];
    BOOL has = DSSceneOverrides()[identifier] != nil;
    [DSSceneOverridesLock() unlock];
    return has;
}

+ (FBScene *)liveSceneForBundleIdentifier:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0) return nil;

    [DSSceneOverridesLock() lock];
    FBScene *found = nil;
    for (NSString *identifier in DSLiveScenes().keyEnumerator.allObjects) {
        if ([identifier rangeOfString:bundleIdentifier].location == NSNotFound) continue;
        FBScene *scene = [DSLiveScenes() objectForKey:identifier];
        if (scene) {
            found = scene;
            break;
        }
    }
    [DSSceneOverridesLock() unlock];
    return found;
}


// 4.5.672 keys672: read only, never writes the scene.
- (NSString *)keys672SceneSummary {
    @try {
        FBScene *scene = [self appViewScene] ?: _scene;
        if (!scene || ![scene respondsToSelector:@selector(settings)]) return @"scene=?";
        FBSSceneSettings *settings = scene.settings;
        if (!settings) return @"scene settings=?";
        NSString *insets = @"?";
        if ([settings respondsToSelector:@selector(safeAreaInsetsPortrait)]) {
            UIEdgeInsets value = ((UIEdgeInsets (*)(id, SEL))objc_msgSend)(settings, @selector(safeAreaInsetsPortrait));
            insets = NSStringFromUIEdgeInsets(value);
        }
        NSInteger orientation = [settings respondsToSelector:@selector(interfaceOrientation)] ? settings.interfaceOrientation : -1;
        return [NSString stringWithFormat:@"scene frame=%@ safeArea=%@ orientation=%ld (stage wants frame=%@ safeArea=%@)",
                NSStringFromCGRect(settings.frame), insets, (long)orientation,
                NSStringFromCGRect([self frameForScene]), NSStringFromUIEdgeInsets([self insetsForScene])];
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"scene read threw %@", exception.name ?: @"?"];
    }
}

@end

// ---- 4.5.770 gest770 (log-only) -------------------------------------------------
// Records what the user does around a minimised card and what the system does
// with it: every bottom-edge pull (ours or the system's) and how it ended, the
// switcher window showing / hiding (window hidden flags only, no switcher
// controller queries), the app view's state on every minimise / restore and the
// first Live update after a restore. Changes only. Never for Messages.
static void DSGest770StartPoll(void);
void DSGest770LogLayout(NSString *why);
void DSGest770NoteEvent(NSString *why);
static BOOL DSGest770PollAsleep = NO;
BOOL DSGest770On(void) {
    static BOOL marked = NO;
    if (!DS770On("gest770")) return NO;
    if (!marked) {
        marked = YES;
        DSFeature699MarkTrying("gest770");
        DSGest770StartPoll();
    } else if (DSGest770PollAsleep && NSThread.isMainThread) {
        DSGest770StartPoll();   // 4.5.796: wake the sleeping poll
    }
    return YES;
}

static NSString *DSGest770Contexts(CALayer *layer, int depth, NSMutableArray *out) {
    if (!layer || depth > 8 || out.count >= 3) return nil;
    if ([NSStringFromClass(layer.class) isEqualToString:@"CALayerHost"] && [layer respondsToSelector:@selector(contextId)]) {
        unsigned int cid = ((unsigned int (*)(id, SEL))objc_msgSend)(layer, @selector(contextId));
        [out addObject:[NSString stringWithFormat:@"%u%@", cid, layer.hidden ? @"(hidden)" : @""]];
    }
    for (CALayer *sub in layer.sublayers) DSGest770Contexts(sub, depth + 1, out);
    return nil;
}

NSString *DSGest770SceneState(id controller, id scene) {
    @try {
        NSInteger mode = -1;
        if ([controller respondsToSelector:@selector(displayMode)]) mode = ((NSInteger (*)(id, SEL))objc_msgSend)(controller, @selector(displayMode));
        id settings = [scene respondsToSelector:@selector(settings)] ? ((id (*)(id, SEL))objc_msgSend)(scene, @selector(settings)) : nil;
        BOOL known = NO;
        BOOL fg = settings ? [DSSceneHost readForegroundFlag:settings known:&known] : NO;
        long long deact = -1;
        if ([settings respondsToSelector:@selector(deactivationReasons)]) deact = ((long long (*)(id, SEL))objc_msgSend)(settings, @selector(deactivationReasons));
        NSString *active = @"?";
        if ([scene respondsToSelector:@selector(isActive)]) active = ((BOOL (*)(id, SEL))objc_msgSend)(scene, @selector(isActive)) ? @"1" : @"0";
        NSMutableArray *ctx = [NSMutableArray array];
        UIView *view = [controller isKindOfClass:UIViewController.class] && [controller isViewLoaded] ? [controller view] : nil;
        DSGest770Contexts(view.layer, 0, ctx);
        return [NSString stringWithFormat:@"mode=%ld fg=%@ active=%@ deact=%lld layerHosts=[%@] view=%@",
                (long)mode, known ? (fg ? @"1" : @"0") : @"?", active, deact,
                [ctx componentsJoinedByString:@","], view ? (view.window ? @"in-window" : @"no-window") : @"none"];
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"state threw %@", exception.name];
    }
}

static NSMutableDictionary<NSString *, NSNumber *> *DSGest770Restored = nil;
void DSGest770MarkRestored(NSString *bundle) {
    if (!bundle.length || [bundle isEqualToString:@"com.apple.MobileSMS"] || !DSGest770On()) return;
    if (!DSGest770Restored) DSGest770Restored = [NSMutableDictionary dictionary];
    DSGest770Restored[bundle] = @(CFAbsoluteTimeGetCurrent());
}

void DSGest770FirstAfterRestore(id controller, id handle, NSString *what) {
    if (DSGest770Restored.count == 0) return;
    @try {
        id scene = [handle respondsToSelector:@selector(scene)] ? ((id (*)(id, SEL))objc_msgSend)(handle, @selector(scene)) : nil;
        NSString *sid = [scene respondsToSelector:@selector(identifier)] ? ((id (*)(id, SEL))objc_msgSend)(scene, @selector(identifier)) : nil;
        if (![sid isKindOfClass:NSString.class]) return;
        for (NSString *bundle in DSGest770Restored.allKeys) {
            if (![sid hasPrefix:bundle]) continue;
            double at = DSGest770Restored[bundle].doubleValue;
            [DSGest770Restored removeObjectForKey:bundle];
            DSDiagnosticsRecordFormat(@"SpringBoard: gest770 first Live update after restoring %@ (+%.2f s): %@; %@",
                                      bundle, CFAbsoluteTimeGetCurrent() - at, what ?: @"-", DSGest770SceneState(controller, scene));
            return;
        }
    } @catch (NSException *exception) {}
}

@implementation DSSceneHost (Gest770)
- (NSString *)gest770State {
    id controller = [self valueForKey:@"_appViewController"];
    return [NSString stringWithFormat:@"%@ pid=%d alive=%d", DSGest770SceneState(controller, [self hostedScene]),
            (int)[self hostedProcessIdentifier], [self isProcessAlive]];
}
@end

static NSString *DSGest770StateName(UIGestureRecognizerState s) {
    switch (s) {
        case UIGestureRecognizerStatePossible: return @"possible";
        case UIGestureRecognizerStateBegan: return @"began";
        case UIGestureRecognizerStateChanged: return @"changed";
        case UIGestureRecognizerStateEnded: return @"ended";
        case UIGestureRecognizerStateCancelled: return @"cancelled";
        case UIGestureRecognizerStateFailed: return @"failed";
    }
    return @"?";
}

// 4.5.772: the real switcher state (the guarded read 4.5.650-656 shipped),
// asked only from the 0.25 s gest770 poll / pull lines while a card exists.
static NSString *DSGest772SwitcherState(void) {
    // 4.5.810 switch810: SBMainSwitcherController / SBMainSwitcherViewController
    // have no +sharedInstance / -isMainSwitcherVisible on 20F75, so this always
    // said "unreadable". Verified in 20F75 (arch799/allmethods.txt):
    // +[SBMainSwitcherControllerCoordinator sharedInstanceIfExists] and
    // -[SBMainSwitcherControllerCoordinator isAnySwitcherVisible]. Read-only;
    // IfExists never creates the coordinator. Off: switch810-off / core810-off.
    if (!DS810On("switch810")) return @"unreadable";
    Class c = objc_getClass("SBMainSwitcherControllerCoordinator");
    SEL shared = sel_registerName("sharedInstanceIfExists");
    SEL visible = sel_registerName("isAnySwitcherVisible");
    if (!c || ![c respondsToSelector:shared]) return @"unreadable";
    @try {
        id coordinator = ((id (*)(id, SEL))objc_msgSend)(c, shared);
        if (!coordinator || ![coordinator respondsToSelector:visible]) return @"unreadable";
        return ((BOOL (*)(id, SEL))objc_msgSend)(coordinator, visible) ? @"OPEN" : @"closed";
    } @catch (NSException *exception) {
        return @"?";
    }
}

static NSString *DSGest770SwitcherSummary(void) {
    if (DS772On("hide772")) return DSGest772SwitcherState();
    NSMutableArray *shown = [NSMutableArray array];
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            NSString *cls = NSStringFromClass(w.class);
            if ([cls rangeOfString:@"Switcher"].location == NSNotFound) continue;
            if (!w.hidden && w.alpha > 0.01) [shown addObject:[NSString stringWithFormat:@"%@@%.0f", cls, w.windowLevel]];
        }
    }
    return shown.count ? [shown componentsJoinedByString:@","] : @"none";
}

@interface DSGest770PullObserver : NSObject
@property (nonatomic, assign) BOOL adopted;
@property (nonatomic, assign) CFAbsoluteTime began;
@end
@implementation DSGest770PullObserver
- (void)pullChanged:(UIPanGestureRecognizer *)gesture {
    UIGestureRecognizerState s = gesture.state;
    if (s != UIGestureRecognizerStateEnded && s != UIGestureRecognizerStateCancelled && s != UIGestureRecognizerStateFailed) return;
    @try {
        CGPoint p = [gesture locationInView:nil];
        CGPoint t = [gesture translationInView:nil];
        CGPoint v = [gesture velocityInView:nil];
        DSDiagnosticsRecordFormat(@"SpringBoard: gest770 edge pull %@ after %.2f s (%@) at %.0f,%.0f moved (%.0f,%.0f) v=(%.0f,%.0f) home=%d busy=%d switcher=%@",
                                  DSGest770StateName(s), CFAbsoluteTimeGetCurrent() - self.began, self.adopted ? @"ours" : @"system's",
                                  p.x, p.y, t.x, t.y, v.x, v.y, [DSSceneHost homeGestureIsActive], [DSSceneHost systemTransitionBusy],
                                  DSGest770SwitcherSummary());
    } @catch (NSException *exception) {}
    [gesture removeTarget:self action:@selector(pullChanged:)];
    objc_setAssociatedObject(gesture, @selector(pullChanged:), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    DSGest770NoteEvent(@"pull ended");
}
@end

void DSGest770NoteEdgePull(UIPanGestureRecognizer *gesture, BOOL adopted) {
    if (!gesture || !DSGest770On()) return;
    @try {
        CGPoint p = [gesture locationInView:nil];
        CGPoint v = [gesture velocityInView:nil];
        DSDiagnosticsRecordFormat(@"SpringBoard: gest770 edge pull began at %.0f,%.0f v=(%.0f,%.0f): %@ (parked=%d stage visible=%d home=%d switcher=%@)",
                                  p.x, p.y, v.x, v.y, adopted ? @"claimed by the stage" : @"left to the system (home / switcher)",
                                  DSStageHasParkedCardFast(), DSStageVisibleFast(), [DSSceneHost homeGestureIsActive], DSGest770SwitcherSummary());
        if (objc_getAssociatedObject(gesture, @selector(pullChanged:))) return;
        DSGest770PullObserver *o = [DSGest770PullObserver new];
        o.adopted = adopted;
        o.began = CFAbsoluteTimeGetCurrent();
        objc_setAssociatedObject(gesture, @selector(pullChanged:), o, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [gesture addTarget:o action:@selector(pullChanged:)];
    } @catch (NSException *exception) {}
}

void DSGest770NoteSuppressed(CGPoint point, NSString *who) {
    if (!DSGest770On()) return;
    static CFAbsoluteTime last = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - last < 0.5) return;
    last = now;
    DSDiagnosticsRecordFormat(@"SpringBoard: gest770 %@ refused a system gesture at %.0f,%.0f (the stage keeps the touch)", who, point.x, point.y);
}

// 4.5.805 poll805: the gest770 layout line (log only) is written from the
// SpringBoard events that change it - a card's host750 state change, the home
// gesture starting / ending and each edge pull - instead of a 4 Hz timer.
// Off: poll805-off (back to the 0.25 s poll).
extern void DSPerf812Crumb(void);
void DSGest770LogLayout(NSString *why) {
    static NSString *lastSig = nil;
    if (!NSThread.isMainThread) return;
    DSPerf812Crumb();
    @try {
        NSString *sig = [NSString stringWithFormat:@"switcher=%@ home=%d busy=%d stage visible=%d parked=%d",
                         DSGest770SwitcherSummary(), [DSSceneHost homeGestureIsActive], [DSSceneHost systemTransitionBusy],
                         DSStageVisibleFast(), DSStageHasParkedCardFast()];
        if ([sig isEqualToString:lastSig]) return;
        lastSig = sig;
        DSDiagnosticsRecordFormat(@"SpringBoard: gest770 layout %@", sig);
    } @catch (NSException *exception) {}
}
// 4.5.811 switch811: when the key / competing window is SBMainSwitcherWindow,
// re-read the gest770 layout line (read-only, same dedupe as poll805).
// Off: switch811-off / core811-off.
void DSGest811NoteOther(NSString *otherName) {
    @try {
        if (!NSThread.isMainThread || ![otherName isEqualToString:@"SBMainSwitcherWindow"] || !DS811On("switch811") || !DSGest770On()) return;
        DSGest770LogLayout(@"switch811");
    } @catch (NSException *exception) {}
}
void DSGest770NoteEvent(NSString *why) {
    if (!DS805On("poll805") || !DSGest770On()) return;
    static BOOL marked = NO;
    if (!marked) { marked = YES; DSFeature699MarkTrying("poll805"); }
    DSFeature719MarkAction("poll805");
    DSGest770LogLayout(why);
}

static void DSGest770StartPoll(void) {
    if (DS805On("poll805")) return;   // 4.5.805: events instead (DSGest770NoteEvent)
    static dispatch_source_t timer = nil;
    if (timer) {
        if (DSGest770PollAsleep) { DSGest770PollAsleep = NO; dispatch_resume(timer); }
        return;
    }
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(0.25 * NSEC_PER_SEC), (uint64_t)(0.05 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{
        if (!DSStageHasParkedCardFast() && !DSStageVisibleFast() && !DSStageHasSceneHostFast()) {
            // 4.5.796: nothing staged, so the 4 Hz poll sleeps until the next gest770 use.
            if (DS796CoreOn() && !DSGest770PollAsleep) { DSGest770PollAsleep = YES; dispatch_suspend(timer); }
            return;
        }
        DSGest770LogLayout(@"poll");
    });
    dispatch_resume(timer);
}
