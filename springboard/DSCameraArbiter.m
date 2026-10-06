#import "DSCameraArbiter.h"
#import "DSStageManager.h"
#import "DSSceneHost.h"
#import "DSConstants.h"
#import "DSDiagnostics.h"
#import "DSInCallStage.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <os/lock.h>

@interface DSCameraClaim : NSObject
@property (nonatomic, copy) NSString *bundle;
@property (nonatomic) CFAbsoluteTime lastHeard;
@property (nonatomic, strong) id assertion;
@property (nonatomic) CGRect frame;
@property (nonatomic) NSInteger lastReason;
@property (nonatomic) CFAbsoluteTime lastResend;
@end

@implementation DSCameraClaim
@end

static const void *DSCameraOwnElementKey = &DSCameraOwnElementKey;
static NSMutableDictionary<NSString *, DSCameraClaim *> *DSCameraClaims;
static NSTimer *DSCameraTimer;
static BOOL DSCameraRefreshScheduled;

// The publisher SpringBoard uses for the main display, and the role and level
// it gives a full-screen app element. Learnt from SpringBoard's own calls.
static __weak id DSCameraPublisher;
static long long DSCameraTemplateRole = 1;
static long long DSCameraTemplateLevel = 1;
static BOOL DSCameraTemplateSeen = NO;
static id (*DSOrigAddElement)(id, SEL, id);

static os_unfair_lock DSCameraPublishedLock = OS_UNFAIR_LOCK_INIT;
static NSSet<NSString *> *DSCameraPublished;

#pragma mark - Logging

// One line per key every `gap` seconds at most, 90 a minute overall (shared
// by the camera658 and camera660 lines). Main thread.
static void DSCameraRecordV(NSString *tag, CFTimeInterval gap, NSString *key, NSString *format, va_list args) NS_FORMAT_FUNCTION(4, 0);
static void DSCameraRecordV(NSString *tag, CFTimeInterval gap, NSString *key, NSString *format, va_list args) {
    static NSMutableDictionary<NSString *, NSNumber *> *last;
    static CFAbsoluteTime windowStart = 0;
    static NSInteger windowCount = 0;
    if (!last) last = [NSMutableDictionary dictionary];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - windowStart > 60.0) {
        windowStart = now;
        windowCount = 0;
    }
    if (windowCount >= 90) return;
    NSString *slot = [NSString stringWithFormat:@"%@/%@", tag ?: @"?", key ?: @"?"];
    if (now - [last[slot] doubleValue] < gap) return;
    last[slot] = @(now);
    if (last.count > 96) [last removeAllObjects];
    windowCount += 1;
    NSString *text = [[NSString alloc] initWithFormat:format arguments:args];
    DSDiagnosticsRecord([NSString stringWithFormat:@"SpringBoard: %@ %@", tag ?: @"camera", text]);
}

static void DSCameraRecord(NSString *key, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);
static void DSCameraRecord(NSString *key, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    DSCameraRecordV(@"camera658", 2.0, key, format, args);
    va_end(args);
}

// 4.5.660 lines: one per key per second.
static void DSCamera660Record(NSString *key, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);
static void DSCamera660Record(NSString *key, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    DSCameraRecordV(@"camera660", 1.0, key, format, args);
    va_end(args);
}

static const char *DSCameraReasonName(NSInteger reason) {
    switch (reason) {
        case 0: return "-";
        case 1: return "in-background";
        case 2: return "audio-in-use";
        case 3: return "video-in-use-by-another-app";
        case 4: return "multiple-foreground-apps";
        case 5: return "system-pressure";
        default: return "other";
    }
}

static const char *DSCameraEventName(NSUInteger event) {
    switch (event) {
        case kDSCameraEventStart: return "start";
        case kDSCameraEventStop: return "stop";
        case kDSCameraEventInterrupted: return "interrupted";
        case kDSCameraEventInterruptionEnded: return "interruption-ended";
        case kDSCameraEventRuntimeError: return "runtime-error";
        case kDSCameraEventRetry: return "retry";
        case kDSCameraEventHeartbeat: return "heartbeat";
        case kDSCameraEventHello: return "hello";
        case kDSCameraEventAfterStart: return "after-start";
        default: return "?";
    }
}

#pragma mark - Small helpers

static BOOL DSCameraSend(id target, SEL selector) {
    if (!target || ![target respondsToSelector:selector]) return NO;
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (NSException *exception) {
        return NO;
    }
}

static long long DSCameraSendLong(id target, SEL selector, long long fallback) {
    if (!target || ![target respondsToSelector:selector]) return fallback;
    @try {
        return ((long long (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (NSException *exception) {
        return fallback;
    }
}

static BOOL DSCameraDeviceLocked(void) {
    @try {
        id manager = [objc_getClass("SBLockScreenManager") respondsToSelector:@selector(sharedInstance)]
            ? [objc_getClass("SBLockScreenManager") performSelector:@selector(sharedInstance)]
            : nil;
        if ([manager respondsToSelector:@selector(isUILocked)]) return DSCameraSend(manager, @selector(isUILocked));
    } @catch (NSException *exception) {
    }
    return NO;
}

static BOOL DSCameraPublisherIsMain(id publisher) {
    id configuration = nil;
    @try {
        if ([publisher respondsToSelector:@selector(displayConfiguration)]) {
            configuration = [publisher performSelector:@selector(displayConfiguration)];
        }
    } @catch (NSException *exception) {
    }
    if (!configuration) return YES; // Older builds: the first publisher is the main one.
    if ([configuration respondsToSelector:@selector(isMainDisplay)]) return DSCameraSend(configuration, @selector(isMainDisplay));
    if ([configuration respondsToSelector:@selector(isMainRootDisplay)]) return DSCameraSend(configuration, @selector(isMainRootDisplay));
    return YES;
}

static NSString *DSCameraElementSummary(id element) {
    NSString *identifier = nil;
    @try {
        if ([element respondsToSelector:@selector(identifier)]) identifier = [element performSelector:@selector(identifier)];
    } @catch (NSException *exception) {
    }
    return [NSString stringWithFormat:@"%@(role=%lld level=%lld app=%d full=%d)",
            identifier ?: @"?",
            DSCameraSendLong(element, @selector(layoutRole), -1),
            DSCameraSendLong(element, @selector(level), -1),
            DSCameraSend(element, @selector(isUIApplicationElement)),
            DSCameraSend(element, @selector(fillsDisplayBounds))];
}

static NSString *DSCameraLayoutSummary(void) {
    id publisher = DSCameraPublisher;
    if (!publisher || ![publisher respondsToSelector:@selector(currentLayout)]) return @"no layout";
    @try {
        id layout = [publisher performSelector:@selector(currentLayout)];
        NSArray *elements = [layout respondsToSelector:@selector(elements)] ? [layout performSelector:@selector(elements)] : nil;
        NSMutableArray *parts = [NSMutableArray array];
        for (id element in elements) {
            [parts addObject:DSCameraElementSummary(element)];
            if (parts.count >= 6) break;
        }
        return parts.count ? [parts componentsJoinedByString:@", "] : @"empty";
    } @catch (NSException *exception) {
        return @"unreadable";
    }
}

#pragma mark - 4.5.658 diagnostics

// The bundles app/DynamicStageApp.plist injects the app dylib (and with it
// the capture hooks) into. Any other app on a card gets no camera handling.
static NSArray<NSString *> *DSCameraInjectedBundles(void) {
    return @[ @"com.apple.MobileSMS", @"com.facebook.Messenger", @"org.whispersystems.signal",
              @"com.beeper.chat.ios", @"com.apple.mobilephone" ];
}

// Whether the bundle has an element in the main display layout right now,
// and how many application elements the layout holds (more than one app is
// what the camera server calls "multiple foreground apps").
static NSString *DSCameraLayoutPresence(NSString *bundle) {
    id publisher = DSCameraPublisher;
    if (!publisher || ![publisher respondsToSelector:@selector(currentLayout)]) return @"inLayout=? (publisher unknown)";
    @try {
        id layout = [publisher performSelector:@selector(currentLayout)];
        NSArray *elements = [layout respondsToSelector:@selector(elements)] ? [layout performSelector:@selector(elements)] : nil;
        BOOL present = NO;
        NSInteger apps = 0;
        for (id element in elements) {
            if (DSCameraSend(element, @selector(isUIApplicationElement))) apps += 1;
            NSString *identifier = [element respondsToSelector:@selector(identifier)] ? [element performSelector:@selector(identifier)] : nil;
            NSString *owner = [element respondsToSelector:@selector(bundleIdentifier)] ? [element performSelector:@selector(bundleIdentifier)] : nil;
            if (([identifier isKindOfClass:NSString.class] && [identifier isEqualToString:bundle]) ||
                ([owner isKindOfClass:NSString.class] && [owner isEqualToString:bundle])) {
                present = YES;
            }
        }
        return [NSString stringWithFormat:@"inLayout=%d layoutApps=%ld", present, (long)apps];
    } @catch (NSException *exception) {
        return @"inLayout=? (unreadable)";
    }
}

// RunningBoard's view of the process: task state and endowment namespaces.
// "visibility" there is FrontBoard saying the app is on screen; the camera
// server's background check follows it. Queried off the main thread (it is
// an XPC round trip) and logged back on it.
// 4.5.660: written as camera660, one per bundle and event class.
static void DSCameraLogRunningBoard(NSString *bundle, pid_t pid, NSString *why, NSString *cls) {
    NSString *key = [NSString stringWithFormat:@"rbs.%@.%@", bundle, cls ?: @"-"];
    if (pid <= 0) {
        DSCamera660Record(key, @"%@ runningboard: no pid (%@)", bundle, why);
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *text = nil;
        @try {
            Class identifierClass = objc_getClass("RBSProcessIdentifier");
            Class handleClass = objc_getClass("RBSProcessHandle");
            SEL withPid = NSSelectorFromString(@"identifierWithPid:");
            SEL forIdentifier = NSSelectorFromString(@"handleForIdentifier:error:");
            if (!identifierClass || !handleClass || ![identifierClass respondsToSelector:withPid] ||
                ![handleClass respondsToSelector:forIdentifier]) {
                text = @"RBS classes missing";
            } else {
                id identifier = ((id (*)(id, SEL, int))objc_msgSend)(identifierClass, withPid, pid);
                NSError *error = nil;
                id handle = identifier ? ((id (*)(id, SEL, id, NSError **))objc_msgSend)(handleClass, forIdentifier, identifier, &error) : nil;
                id state = [handle respondsToSelector:@selector(currentState)] ? [handle performSelector:@selector(currentState)] : nil;
                if (!state) {
                    text = [NSString stringWithFormat:@"no state (%@)", error.localizedDescription ?: @"no handle"];
                } else {
                    long long task = DSCameraSendLong(state, NSSelectorFromString(@"taskState"), -1);
                    NSSet *namespaces = [state respondsToSelector:NSSelectorFromString(@"endowmentNamespaces")]
                        ? ((id (*)(id, SEL))objc_msgSend)(state, NSSelectorFromString(@"endowmentNamespaces"))
                        : nil;
                    BOOL visible = NO;
                    NSMutableArray *names = [NSMutableArray array];
                    for (id name in namespaces) {
                        if (![name isKindOfClass:NSString.class]) continue;
                        if ([name rangeOfString:@"visibility"].location != NSNotFound) visible = YES;
                        [names addObject:name];
                    }
                    [names sortUsingSelector:@selector(compare:)];
                    text = [NSString stringWithFormat:@"task=%lld (4=running) visible=%d endowments=[%@]", task, visible,
                            [names componentsJoinedByString:@","]];
                }
            }
        } @catch (NSException *exception) {
            text = [NSString stringWithFormat:@"threw %@", exception.name ?: @"?"];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            DSCamera660Record(key, @"%@ runningboard pid=%d %@ (%@)", bundle, pid, text, why);
        });
    });
}

// The whole picture for one staged camera app, at the moment an event came
// in: arbiter, layout, card, scene, SpringBoard and RunningBoard state.
// Read only. Skipped while home / switcher has the screen (4.5.657 no-op).
// 4.5.660: written as camera660. The floor is per bundle and event class
// (start / interrupt / other, 1 s), so a start and the interruption right
// behind it both get their status line.
static void DSCameraLogStatus(NSString *bundle, NSString *why, BOOL force, NSString *cls) {
    static NSMutableDictionary<NSString *, NSNumber *> *lastStatus;
    if (!lastStatus) lastStatus = [NSMutableDictionary dictionary];
    if (bundle.length == 0) return;
    if ([DSSceneHost homeGestureIsActive] || [DSSceneHost systemTransitionBusy]) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSString *statusKey = [NSString stringWithFormat:@"%@.%@", bundle, cls ?: @"-"];
    if (!force && now - [lastStatus[bundle] doubleValue] < 12.0) return;
    if (now - [lastStatus[statusKey] doubleValue] < 1.0) return;
    lastStatus[statusKey] = @(now);
    lastStatus[bundle] = @(now);
    if (lastStatus.count > 48) [lastStatus removeAllObjects];
    DSCameraClaim *claim = DSCameraClaims[bundle];
    DSStageManager *manager = [DSStageManager sharedManager];
    NSString *hostState = @"?";
    pid_t pid = 0;
    @try {
        hostState = [manager cameraStateSummaryForBundleIdentifier:bundle] ?: @"?";
        pid = [manager hostedProcessIdentifierForBundleIdentifier:bundle];
    } @catch (NSException *exception) {
    }
    DSCamera660Record([NSString stringWithFormat:@"status.%@", statusKey],
                   @"%@ status (%@): claim=%d published=%d publisher=%d template=%d %@ locked=%d callGuard=%d | %@",
                   bundle, why, claim != nil, claim.assertion != nil, DSCameraPublisher != nil, DSCameraTemplateSeen,
                   DSCameraLayoutPresence(bundle), DSCameraDeviceLocked(), DSCallGuardActive(), hostState);
    DSCameraLogRunningBoard(bundle, pid, why, cls);
}

#pragma mark - Publisher hook

static id DSCameraAddElement(id self, SEL _cmd, id element) {
    id result = DSOrigAddElement ? DSOrigAddElement(self, _cmd, element) : nil;
    // 4.5.657: SpringBoard publishes the display layout on every switcher
    // transition and app kill. Once the main publisher and the app-element
    // template are known there is nothing left to learn: one pointer compare,
    // then out (no associated-object lookup, no messages).
    if (self == DSCameraPublisher && DSCameraTemplateSeen) return result;
    @try {
        // 4.5.655: the publisher already known to be the main display's is not
        // asked for its display configuration again on every layout publish.
        if (element && !objc_getAssociatedObject(element, DSCameraOwnElementKey) &&
            (self == DSCameraPublisher || DSCameraPublisherIsMain(self))) {
            BOOL hadPublisher = DSCameraPublisher != nil;
            DSCameraPublisher = self;
            if (DSCameraSend(element, @selector(isUIApplicationElement)) &&
                DSCameraSend(element, @selector(fillsDisplayBounds))) {
                DSCameraTemplateRole = DSCameraSendLong(element, @selector(layoutRole), DSCameraTemplateRole);
                DSCameraTemplateLevel = DSCameraSendLong(element, @selector(level), DSCameraTemplateLevel);
                DSCameraTemplateSeen = YES;
            }
            if (!hadPublisher && NSThread.isMainThread && DSCameraClaims.count) {
                [DSCameraArbiter refreshSoon];
            }
        }
    } @catch (NSException *exception) {
    }
    return result;
}

static void DSCameraInstallPublisherHook(void) {
    Class cls = objc_getClass("FBSDisplayLayoutPublisher");
    Method method = cls ? class_getInstanceMethod(cls, @selector(addElement:)) : NULL;
    if (!method) {
        DSDiagnosticsRecord(@"SpringBoard: camera658 no FBSDisplayLayoutPublisher addElement:, layout path off");
        return;
    }
    DSOrigAddElement = (id (*)(id, SEL, id))method_setImplementation(method, (IMP)DSCameraAddElement);
}

// Before SpringBoard has added an element since this process started, ask the
// window scene for its publisher.
static id DSCameraFindPublisher(void) {
    id publisher = DSCameraPublisher;
    if (publisher) return publisher;
    Class publisherClass = objc_getClass("FBSDisplayLayoutPublisher");
    @try {
        id app = UIApplication.sharedApplication;
        NSMutableArray *candidates = [NSMutableArray array];
        if (app) [candidates addObject:app];
        for (NSString *name in @[ @"windowSceneManager" ]) {
            SEL selector = NSSelectorFromString(name);
            if (![app respondsToSelector:selector]) continue;
            id manager = ((id (*)(id, SEL))objc_msgSend)(app, selector);
            for (NSString *sceneName in @[ @"embeddedDisplayWindowScene", @"activeDisplayWindowScene" ]) {
                SEL sceneSelector = NSSelectorFromString(sceneName);
                if (![manager respondsToSelector:sceneSelector]) continue;
                id scene = ((id (*)(id, SEL))objc_msgSend)(manager, sceneSelector);
                if (scene) [candidates addObject:scene];
            }
        }
        for (id candidate in candidates) {
            for (NSString *name in @[ @"displayLayoutPublisher", @"mainDisplayLayoutPublisher" ]) {
                SEL selector = NSSelectorFromString(name);
                if (![candidate respondsToSelector:selector]) continue;
                id found = ((id (*)(id, SEL))objc_msgSend)(candidate, selector);
                if (found && (!publisherClass || [found isKindOfClass:publisherClass])) {
                    DSCameraPublisher = found;
                    return found;
                }
            }
        }
    } @catch (NSException *exception) {
    }
    return nil;
}

#pragma mark - Publishing

static void DSCameraUpdatePublishedSet(void) {
    NSMutableSet *set = [NSMutableSet set];
    for (DSCameraClaim *claim in DSCameraClaims.allValues) {
        if (claim.assertion) [set addObject:claim.bundle];
    }
    os_unfair_lock_lock(&DSCameraPublishedLock);
    DSCameraPublished = [set copy];
    os_unfair_lock_unlock(&DSCameraPublishedLock);
}

static void DSCameraUnpublish(DSCameraClaim *claim, NSString *why) {
    if (!claim.assertion) return;
    id assertion = claim.assertion;
    claim.assertion = nil;
    claim.frame = CGRectNull;
    @try {
        if ([assertion respondsToSelector:@selector(invalidate)]) [assertion invalidate];
    } @catch (NSException *exception) {
    }
    DSCameraRecord([@"unpub." stringByAppendingString:claim.bundle ?: @"?"],
                   @"%@ taken out of the display layout (%@), path=layout-off", claim.bundle, why);
}

static BOOL DSCameraPublish(DSCameraClaim *claim, CGRect frame) {
    id publisher = DSCameraFindPublisher();
    if (!publisher || ![publisher respondsToSelector:@selector(addElement:)]) {
        DSCameraRecord(@"nopub", @"%@ wants the camera but the display layout publisher is not known yet", claim.bundle);
        return NO;
    }
    Class cls = objc_getClass("SBSDisplayLayoutElement") ?: objc_getClass("FBSDisplayLayoutElement");
    if (!cls) return NO;
    id element = nil;
    @try {
        element = [cls alloc];
        if ([element respondsToSelector:@selector(initWithIdentifier:layoutRole:)]) {
            element = ((id (*)(id, SEL, id, long long))objc_msgSend)(element, @selector(initWithIdentifier:layoutRole:),
                                                                     claim.bundle, DSCameraTemplateRole);
        } else if ([element respondsToSelector:@selector(initWithIdentifier:)]) {
            element = ((id (*)(id, SEL, id))objc_msgSend)(element, @selector(initWithIdentifier:), claim.bundle);
        } else {
            element = nil;
        }
        if (!element) return NO;
        if ([element respondsToSelector:@selector(setBundleIdentifier:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(element, @selector(setBundleIdentifier:), claim.bundle);
        }
        if ([element respondsToSelector:@selector(setUIApplicationElement:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(element, @selector(setUIApplicationElement:), YES);
        }
        if ([element respondsToSelector:@selector(setFillsDisplayBounds:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(element, @selector(setFillsDisplayBounds:), NO);
        }
        // Keyboard focus stays with whoever SpringBoard gave it to: the stage's
        // keyboard routing depends on it.
        if ([element respondsToSelector:@selector(setHasKeyboardFocus:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(element, @selector(setHasKeyboardFocus:), NO);
        }
        if ([element respondsToSelector:@selector(setLevel:)]) {
            ((void (*)(id, SEL, long long))objc_msgSend)(element, @selector(setLevel:), DSCameraTemplateLevel);
        }
        if ([element respondsToSelector:@selector(setLayoutRole:)] && ![cls instancesRespondToSelector:@selector(initWithIdentifier:layoutRole:)]) {
            ((void (*)(id, SEL, long long))objc_msgSend)(element, @selector(setLayoutRole:), DSCameraTemplateRole);
        }
        if ([element respondsToSelector:@selector(setFrame:)]) {
            ((void (*)(id, SEL, CGRect))objc_msgSend)(element, @selector(setFrame:), frame);
        }
        if ([element respondsToSelector:@selector(setReferenceFrame:)]) {
            ((void (*)(id, SEL, CGRect))objc_msgSend)(element, @selector(setReferenceFrame:), frame);
        }
        objc_setAssociatedObject(element, DSCameraOwnElementKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        id assertion = ((id (*)(id, SEL, id))objc_msgSend)(publisher, @selector(addElement:), element);
        if (!assertion) {
            DSCameraRecord(@"addnil", @"%@ display layout refused the card element", claim.bundle);
            return NO;
        }
        claim.assertion = assertion;
        claim.frame = frame;
        DSCameraRecord([@"pub." stringByAppendingString:claim.bundle ?: @"?"],
                       @"%@ card published to the display layout frame=%@ role=%lld level=%lld template=%d, path=layout-element; layout now: %@",
                       claim.bundle, NSStringFromCGRect(frame), DSCameraTemplateRole, DSCameraTemplateLevel,
                       DSCameraTemplateSeen, DSCameraLayoutSummary());
        return YES;
    } @catch (NSException *exception) {
        DSCameraRecord(@"pubthrew", @"%@ publishing the card threw %@", claim.bundle, exception.name ?: @"?");
        return NO;
    }
}

static BOOL DSCameraFramesClose(CGRect a, CGRect b) {
    if (CGRectIsNull(a) || CGRectIsNull(b)) return NO;
    return fabs(CGRectGetMinX(a) - CGRectGetMinX(b)) < 2.0 && fabs(CGRectGetMinY(a) - CGRectGetMinY(b)) < 2.0 &&
           fabs(CGRectGetWidth(a) - CGRectGetWidth(b)) < 2.0 && fabs(CGRectGetHeight(a) - CGRectGetHeight(b)) < 2.0;
}

#pragma mark - 4.5.660 per-app camera events (diagnostics only)

// The injected app writes each camera event into a ring of notify states and
// rings a per-app doorbell (kDSCamera660Prefix in DSConstants.h). This side
// reads the new slots and writes "camera660 <bundle> ..." lines. Read only:
// nothing here claims, publishes or touches a scene. During the home gesture
// or while the system has the screen (4.5.657 switcher no-op) the doorbell
// only sets a flag; the slots are read once the transition is over.

@interface DSCamera660Watch : NSObject {
@public
    int _slots[kDSCamera660Slots];
}
@property (nonatomic, copy) NSString *bundle;
@property (nonatomic) uint32_t bundleHash;
@property (nonatomic) int doorbell;
@property (nonatomic) uint32_t pid;
@property (nonatomic) uint16_t lastSeq;
@end

@implementation DSCamera660Watch
@end

static NSMutableDictionary<NSNumber *, DSCamera660Watch *> *DSCam660Watches;
static BOOL DSCam660DrainQueued;
static CFAbsoluteTime DSCam660DrainQueuedAt;
static NSMutableSet<NSNumber *> *DSCam660DirtyHashes;

static const char *DSCam660EventName(NSUInteger event) {
    switch (event) {
        case kDSCamera660EvHello: return "hello";
        case kDSCamera660EvHooksIn: return "capture hooks in";
        case kDSCamera660EvStartCalled: return "startRunning called";
        case kDSCamera660EvStartReturned: return "startRunning returned";
        case kDSCamera660EvState: return "state";
        case kDSCamera660EvInterrupted: return "interrupted";
        case kDSCamera660EvInterruptionEnded: return "interruption ended";
        case kDSCamera660EvRuntimeError: return "runtime error";
        case kDSCamera660EvMultitaskOn: return "multitask access enabled";
        case kDSCamera660EvMultitaskRefused: return "multitask access refused";
        case kDSCamera660EvRetry: return "retry startRunning";
        case kDSCamera660EvRetryCap: return "retry cap reached";
        case kDSCamera660EvStop: return "stopped";
        case kDSCamera660EvUnforce: return "multitask access switched back off";
        case kDSCamera660EvAppState: return "app state";
        default: return "?";
    }
}

static const char *DSCam660AppStateName(NSInteger state) {
    switch (state) {
        case 1: return "active";
        case 2: return "inactive";
        case 3: return "background";
        default: return "?";
    }
}

static NSString *DSCam660FlagText(uint32_t flags, uint32_t extra, BOOL withSession) {
    NSString *base = [NSString stringWithFormat:@"staged=%d appActive=%d bg=%d hooks=%d running=%d interrupted=%d multitask=%d/%d%@",
                      (flags & kDSCameraFlagStaged) != 0, (flags & kDSCameraFlagAppActive) != 0,
                      (flags & kDSCamera660FlagAppBackground) != 0, (flags & kDSCamera660FlagHooksIn) != 0,
                      (flags & kDSCameraFlagRunning) != 0, (flags & kDSCameraFlagInterrupted) != 0,
                      (flags & kDSCameraFlagMultitaskSupported) != 0, (flags & kDSCameraFlagMultitaskEnabled) != 0,
                      (flags & kDSCameraFlagMultitaskRefused) ? @" refused" : @""];
    if (!withSession) return base;
    if (!(flags & kDSCamera660FlagSessionKnown)) return [base stringByAppendingString:@" session=none"];
    NSString *preview = (flags & kDSCamera660FlagPreviewAttached)
        ? [NSString stringWithFormat:@"attached inTree=%d active=%d sized=%d hidden=%d",
           (flags & kDSCamera660FlagPreviewInTree) != 0, (flags & kDSCamera660FlagPreviewActive) != 0,
           (flags & kDSCamera660FlagPreviewHasSize) != 0, (flags & kDSCamera660FlagPreviewHidden) != 0]
        : @"none";
    return [NSString stringWithFormat:@"%@ videoInput=%d connections=%u outputs=%u preview=%@",
            base, (flags & kDSCamera660FlagVideoInput) != 0, extra & 0xff, (extra >> 8) & 0xff, preview];
}

static NSString *DSCam660Detail(NSUInteger event, NSInteger reason, uint32_t extra) {
    switch (event) {
        case kDSCamera660EvHello: {
            const char *cause = reason == kDSCamera660HelloLaunch ? "after launch"
                : (reason == kDSCamera660HelloStaged ? "app saw it is staged" : (reason == kDSCamera660HelloPing ? "answer to the on-card ping" : "?"));
            return [NSString stringWithFormat:@"(%s) sessions=%u multitaskSwitch=%s", cause, extra & 0xff,
                    ((extra >> 8) & 1) ? "present" : "absent"];
        }
        case kDSCamera660EvHooksIn:
            return [NSString stringWithFormat:@"multitask switch %s", reason ? "present" : "absent"];
        case kDSCamera660EvStartCalled: {
            const char *path = reason == 1 ? "multitask+layout" : (reason == 2 ? "layout (multitask refused)" : (reason == 3 ? "layout (multitask unavailable)" : "none (not staged)"));
            return [NSString stringWithFormat:@"path=%s", path];
        }
        case kDSCamera660EvInterrupted:
        case kDSCamera660EvRetry:
        case kDSCamera660EvRetryCap:
            return [NSString stringWithFormat:@"reason=%ld (%s)", (long)reason, DSCameraReasonName(reason)];
        case kDSCamera660EvRuntimeError:
            return [NSString stringWithFormat:@"code=%d", (int)(int16_t)(uint16_t)extra];
        case kDSCamera660EvMultitaskRefused:
            return reason == 2 ? @"(setter threw)" : (reason == 1 ? @"(blocked after an earlier error)" : @"(switch not offered)");
        case kDSCamera660EvStop:
            return reason == 1 ? @"(no session running any more)" : @"(stopRunning)";
        case kDSCamera660EvAppState:
            return [NSString stringWithFormat:@"-> %s", DSCam660AppStateName(reason)];
        default:
            return @"";
    }
}

static void DSCam660LogEntry(DSCamera660Watch *watch, uint64_t state, BOOL hosted, BOOL deferred) {
    NSUInteger event = (NSUInteger)((state >> 16) & 0xff);
    NSInteger reason = (NSInteger)((state >> 24) & 0xff);
    uint32_t flags = (uint32_t)((state >> 32) & 0xffff);
    uint32_t extra = (uint32_t)((state >> 48) & 0xffff);
    NSString *bundle = watch.bundle;
    if (!hosted) {
        // A full-screen camera is none of the stage's business; only the
        // events that say "a camera started / failed" are noted, once a while.
        if (event != kDSCamera660EvStartCalled && event != kDSCamera660EvInterrupted &&
            event != kDSCamera660EvRuntimeError) return;
    }
    BOOL withSession = event != kDSCamera660EvHello && event != kDSCamera660EvHooksIn;
    NSString *key = [NSString stringWithFormat:@"%@.%lu.%ld%@", bundle, (unsigned long)event, (long)reason, hosted ? @"" : @".off"];
    DSCamera660Record(key, @"%@ %s %@ | %@%@%@", bundle, DSCam660EventName(event), DSCam660Detail(event, reason, extra),
                      DSCam660FlagText(flags, extra, withSession),
                      hosted ? @"" : @" (not on a card, full-screen camera left alone)",
                      deferred ? @" (read after the home / switcher gesture)" : @"");
    if (!hosted) return;
    NSString *cls = nil;
    if (event == kDSCamera660EvStartCalled || event == kDSCamera660EvStartReturned || event == kDSCamera660EvRetry) cls = @"start";
    else if (event == kDSCamera660EvInterrupted || event == kDSCamera660EvRuntimeError) cls = @"interrupt";
    else if (event == kDSCamera660EvInterruptionEnded) cls = @"other";
    if (!cls) return;
    NSString *why = [NSString stringWithFormat:@"%s%@%@", DSCam660EventName(event),
                     DSCam660Detail(event, reason, extra).length ? @" " : @"", DSCam660Detail(event, reason, extra)];
    NSString *statusBundle = [bundle copy];
    // After the arbiter's own refresh (0.05 s), so a fresh publish shows.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DSCameraLogStatus(statusBundle, why, YES, cls);
    });
}

static void DSCam660DrainWatch(DSCamera660Watch *watch, NSArray<NSString *> *hostedBundles, BOOL deferred) {
    if (!watch || watch.doorbell == NOTIFY_TOKEN_INVALID) return;
    uint64_t bell = 0;
    if (notify_get_state(watch.doorbell, &bell) != NOTIFY_STATUS_OK || bell == 0) return;
    uint32_t pid = (uint32_t)(bell >> 16);
    uint16_t latest = (uint16_t)(bell & 0xffff);
    BOOL hosted = [hostedBundles containsObject:watch.bundle];
    if (pid != watch.pid) {
        // A new process of this app: it cleared its slots and counts from 1.
        watch.pid = pid;
        watch.lastSeq = 0;
        if (hosted) {
            DSCamera660Record([@"pid." stringByAppendingString:watch.bundle], @"%@ pid=%u reporting camera events to SpringBoard", watch.bundle, pid);
        }
    }
    uint16_t since = watch.lastSeq;
    uint16_t pending = (uint16_t)(latest - since);
    if (pending == 0 || pending >= 0x8000) return;
    uint64_t found[kDSCamera660Slots];
    uint16_t order[kDSCamera660Slots];
    int count = 0;
    for (int k = 0; k < kDSCamera660Slots; k++) {
        int token = watch->_slots[k];
        if (token == NOTIFY_TOKEN_INVALID) continue;
        uint64_t state = 0;
        if (notify_get_state(token, &state) != NOTIFY_STATUS_OK || state == 0) continue;
        uint16_t seq = (uint16_t)(state & 0xffff);
        uint16_t after = (uint16_t)(seq - since);
        uint16_t upTo = (uint16_t)(latest - seq);
        if (after == 0 || after >= 0x8000 || upTo >= 0x8000) continue;
        found[count] = state;
        order[count] = after;
        count += 1;
    }
    // Oldest first.
    for (int i = 1; i < count; i++) {
        for (int j = i; j > 0 && order[j - 1] > order[j]; j--) {
            uint16_t o = order[j]; order[j] = order[j - 1]; order[j - 1] = o;
            uint64_t f = found[j]; found[j] = found[j - 1]; found[j - 1] = f;
        }
    }
    if (hosted && pending > count) {
        DSCamera660Record([@"lost." stringByAppendingString:watch.bundle], @"%@ %d camera event(s) overwritten before SpringBoard read them",
                          watch.bundle, (int)(pending - count));
    }
    for (int i = 0; i < count; i++) {
        DSCam660LogEntry(watch, found[i], hosted, deferred);
    }
    watch.lastSeq = latest;
}

static void DSCam660DrainDirty(BOOL deferred) {
    if (DSCam660DirtyHashes.count == 0) return;
    NSArray<NSNumber *> *hashes = DSCam660DirtyHashes.allObjects;
    [DSCam660DirtyHashes removeAllObjects];
    NSArray<NSString *> *hosted = nil;
    @try {
        hosted = [[DSStageManager sharedManager] hostedBundleIdentifiers] ?: @[];
    } @catch (NSException *exception) {
        hosted = @[];
    }
    for (NSNumber *hash in hashes) {
        @try {
            DSCam660DrainWatch(DSCam660Watches[hash], hosted, deferred);
        } @catch (NSException *exception) {
        }
    }
}

static void DSCam660Doorbell(uint32_t hash) {
    if (!DSCam660DirtyHashes) DSCam660DirtyHashes = [NSMutableSet set];
    [DSCam660DirtyHashes addObject:@(hash)];
    if ([DSSceneHost homeGestureIsActive] || [DSSceneHost systemTransitionBusy]) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (DSCam660DrainQueued && now - DSCam660DrainQueuedAt < 30.0) return;
        DSCam660DrainQueued = YES;
        DSCam660DrainQueuedAt = now;
        [DSSceneHost performWhenSystemTransitionOver:^{
            DSCam660DrainQueued = NO;
            DSCam660DrainDirty(YES);
        }];
        return;
    }
    DSCam660DrainDirty(NO);
}

// Main thread. Cheap after the first call per bundle.
static void DSCam660WatchBundle(NSString *bundle) {
    if (bundle.length == 0) return;
    if (!DSCam660Watches) DSCam660Watches = [NSMutableDictionary dictionary];
    uint32_t hash = DSIdentifierHash(bundle);
    if (hash == 0 || DSCam660Watches[@(hash)] || DSCam660Watches.count >= 24) return;
    DSCamera660Watch *watch = [DSCamera660Watch new];
    watch.bundle = bundle;
    watch.bundleHash = hash;
    char name[160];
    for (int k = 0; k < kDSCamera660Slots; k++) {
        watch->_slots[k] = NOTIFY_TOKEN_INVALID;
        if (notify_register_check(DSCamera660Name(hash, k, name, sizeof(name)), &watch->_slots[k]) != NOTIFY_STATUS_OK) {
            watch->_slots[k] = NOTIFY_TOKEN_INVALID;
        }
    }
    int token = NOTIFY_TOKEN_INVALID;
    if (notify_register_dispatch(DSCamera660Name(hash, -1, name, sizeof(name)), &token, dispatch_get_main_queue(), ^(int t) {
            (void)t;
            DSCam660Doorbell(hash);
        }) != NOTIFY_STATUS_OK) {
        token = NOTIFY_TOKEN_INVALID;
    }
    watch.doorbell = token;
    // Whatever is already there (an app that was running before this
    // SpringBoard started) is history: start after it.
    uint64_t bell = 0;
    if (token != NOTIFY_TOKEN_INVALID && notify_get_state(token, &bell) == NOTIFY_STATUS_OK && bell != 0) {
        watch.pid = (uint32_t)(bell >> 16);
        watch.lastSeq = (uint16_t)(bell & 0xffff);
    }
    DSCam660Watches[@(hash)] = watch;
}

// After an app goes on a card: ask it for its camera hook state (it answers
// with a Hello). 1.5 s late so its stage context has flipped; never during
// the home / switcher gesture; at most once every 3 s per app.
static void DSCam660PingSoon(NSString *bundle) {
    static NSMutableDictionary<NSString *, NSNumber *> *lastPing;
    if (!lastPing) lastPing = [NSMutableDictionary dictionary];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - [lastPing[bundle] doubleValue] < 3.0) return;
    lastPing[bundle] = @(now);
    if (lastPing.count > 32) [lastPing removeAllObjects];
    NSString *copy = [bundle copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [DSSceneHost performWhenSystemTransitionOver:^{
            @try {
                if (![[[DSStageManager sharedManager] hostedBundleIdentifiers] containsObject:copy]) return;
            } @catch (NSException *exception) {
                return;
            }
            char name[160];
            notify_post(DSCamera660Name(DSIdentifierHash(copy), -2, name, sizeof(name)));
            DSCamera660Record([@"ping." stringByAppendingString:copy],
                              @"%@ on a card: asked it to report its camera hooks (a 'camera660 %@ hello' line should follow)", copy, copy);
        }];
    });
}

@implementation DSCameraArbiter

+ (void)start {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        DSCameraClaims = [NSMutableDictionary dictionary];
        DSCameraInstallPublisherHook();
        int token = NOTIFY_TOKEN_INVALID;
        notify_register_dispatch(kDSCameraNotification, &token, dispatch_get_main_queue(), ^(int t) {
            uint64_t state = 0;
            if (notify_get_state(t, &state) != NOTIFY_STATUS_OK) return;
            [DSCameraArbiter handleState:state];
        });
        DSDiagnosticsRecord(@"SpringBoard: camera658 arbiter listening (camera hooks only in Messages, Messenger, Signal, Beeper, Phone)");
        // 4.5.660: the per-app camera event channels.
        for (NSString *bundle in DSCameraInjectedBundles()) DSCam660WatchBundle(bundle);
        DSDiagnosticsRecordFormat(@"SpringBoard: camera660 listening for in-app camera events from %lu apps", (unsigned long)DSCam660Watches.count);
    });
}

+ (void)noteStagedBundle:(NSString *)bundle {
    if (bundle.length == 0) return;
    // 4.5.660: hear this app's camera events, and ask it for its hook state
    // now that it is on a card (an already-running app never sent one).
    @try {
        DSCam660WatchBundle(bundle);
        if ([DSCameraInjectedBundles() containsObject:bundle]) DSCam660PingSoon(bundle);
    } @catch (NSException *exception) {
    }
    static NSMutableDictionary<NSString *, NSNumber *> *lastNote;
    if (!lastNote) lastNote = [NSMutableDictionary dictionary];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - [lastNote[bundle] doubleValue] < 30.0) return;
    lastNote[bundle] = @(now);
    if (lastNote.count > 32) [lastNote removeAllObjects];
    if ([DSCameraInjectedBundles() containsObject:bundle]) {
        DSDiagnosticsRecordFormat(@"SpringBoard: camera658 %@ on a card: injected app, a 'camera hook loaded' line should follow", bundle);
    } else {
        DSDiagnosticsRecordFormat(@"SpringBoard: camera658 %@ on a card: NOT an injected app, DynamicStage has no camera handling inside it (only Messages, Messenger, Signal, Beeper, Phone)", bundle);
    }
}

+ (void)handleState:(uint64_t)state {
    uint32_t hash = (uint32_t)(state & 0xffffffffULL);
    NSUInteger event = (NSUInteger)((state >> 32) & 0xff);
    NSInteger reason = (NSInteger)((state >> 40) & 0xff);
    uint32_t flags = (uint32_t)((state >> 48) & 0xff);
    if (hash == 0 || event == 0) return;
    NSString *bundle = nil;
    for (NSString *hosted in [[DSStageManager sharedManager] hostedBundleIdentifiers]) {
        if (DSIdentifierHash(hosted) == hash) {
            bundle = hosted;
            break;
        }
    }
    if (!bundle) {
        DSCameraClaim *stale = nil;
        for (DSCameraClaim *claim in DSCameraClaims.allValues) {
            if (DSIdentifierHash(claim.bundle) == hash) stale = claim;
        }
        if (stale) {
            DSCameraUnpublish(stale, @"app no longer on a card");
            [DSCameraClaims removeObjectForKey:stale.bundle];
            DSCameraUpdatePublishedSet();
        }
        if (event != kDSCameraEventHeartbeat && event != kDSCameraEventHello && event != kDSCameraEventAfterStart) {
            DSCameraRecord([NSString stringWithFormat:@"off.%08x", hash],
                           @"%08x %s from an app that is not on a card, full-screen camera left alone", hash,
                           DSCameraEventName(event));
        }
        return;
    }
    NSString *flagText = [NSString stringWithFormat:@"staged=%d appActive=%d multitask=%d/%d%@ running=%d interrupted=%d",
                          (flags & kDSCameraFlagStaged) != 0, (flags & kDSCameraFlagAppActive) != 0,
                          (flags & kDSCameraFlagMultitaskSupported) != 0, (flags & kDSCameraFlagMultitaskEnabled) != 0,
                          (flags & kDSCameraFlagMultitaskRefused) ? @" refused" : @"",
                          (flags & kDSCameraFlagRunning) != 0, (flags & kDSCameraFlagInterrupted) != 0];
    // 4.5.658: the hooks announcing themselves; nothing to claim.
    if (event == kDSCameraEventHello) {
        DSCameraRecord([@"hello." stringByAppendingString:bundle], @"%@ camera hook loaded (AVFoundation hooks %@) %@",
                       bundle, reason ? @"in" : @"waiting for AVFoundation", flagText);
        return;
    }
    if (event == kDSCameraEventAfterStart) {
        DSCameraRecord([@"after." stringByAppendingString:bundle], @"%@ startRunning returned %@",
                       bundle, flagText);
        DSCameraLogStatus(bundle, @"after startRunning", YES, @"start");
        return;
    }
    if (event != kDSCameraEventHeartbeat) {
        DSCameraRecord([NSString stringWithFormat:@"ev.%@.%lu.%ld", bundle, (unsigned long)event, (long)reason],
                       @"%@ %s reason=%ld (%s) %@", bundle, DSCameraEventName(event), (long)reason,
                       DSCameraReasonName(reason), flagText);
    }
    DSCameraClaim *claim = DSCameraClaims[bundle];
    switch (event) {
        case kDSCameraEventStart:
        case kDSCameraEventRetry:
        case kDSCameraEventHeartbeat:
        case kDSCameraEventInterrupted:
        case kDSCameraEventInterruptionEnded:
        case kDSCameraEventRuntimeError: {
            // A session from an app that went to the background does not claim.
            if (event == kDSCameraEventInterrupted && reason != 1 && reason != 4 && !claim) break;
            if (!claim) {
                claim = [DSCameraClaim new];
                claim.bundle = bundle;
                claim.frame = CGRectNull;
                DSCameraClaims[bundle] = claim;
            }
            claim.lastHeard = CFAbsoluteTimeGetCurrent();
            if (event == kDSCameraEventInterrupted) {
                claim.lastReason = reason;
                // Another app took the camera, or the layout has to be sent again.
                // At most once every 3 seconds, so an interruption the layout
                // cannot fix does not turn into a loop.
                CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                if ((reason == 1 || reason == 4) && claim.assertion && now - claim.lastResend > 3.0) {
                    claim.lastResend = now;
                    DSCameraUnpublish(claim, @"interrupted, sending it again");
                }
            }
            break;
        }
        case kDSCameraEventStop:
            if (claim) {
                DSCameraUnpublish(claim, @"capture stopped");
                [DSCameraClaims removeObjectForKey:bundle];
            }
            break;
        default:
            break;
    }
    [self refreshSoon];
    // 4.5.658: full state on every real event, every 12 s on heartbeats.
    // After the refresh, so a fresh claim's publish is in it.
    NSString *statusBundle = [bundle copy];
    NSString *why = [NSString stringWithFormat:@"%s reason=%ld (%s)", DSCameraEventName(event), (long)reason, DSCameraReasonName(reason)];
    BOOL force = event != kDSCameraEventHeartbeat;
    NSString *cls = (event == kDSCameraEventStart || event == kDSCameraEventRetry) ? @"start"
        : (event == kDSCameraEventInterrupted ? @"interrupt" : @"other");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DSCameraLogStatus(statusBundle, why, force, cls);
    });
}

+ (void)refreshSoon {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [DSCameraArbiter refreshSoon];
        });
        return;
    }
    if (DSCameraRefreshScheduled) return;
    DSCameraRefreshScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DSCameraRefreshScheduled = NO;
        [DSCameraArbiter refresh];
    });
}

+ (void)timerFired:(NSTimer *)timer {
    (void)timer;
    [self refresh];
}

+ (void)refresh {
    if (!DSCameraClaims) return;
    // Nothing during the home / switcher gesture or inside a scene update:
    // come back when it is over.
    // 4.5.657: retried only across the home gesture itself (at most its
    // 2.5 s timeout + 1.15 s quiet) or a scene update, never for as long as
    // the switcher stays open.
    if ([DSSceneHost homeGestureIsActive] || [DSSceneHost sceneSettingsUpdateDepth] > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [DSCameraArbiter refreshSoon];
        });
        return;
    }
    // The system has the screen (home / switcher, every card parked): no card
    // is visible, so a staged camera's element comes out of the layout.
    BOOL systemOwns = [DSSceneHost systemTransitionBusy];
    @try {
        DSStageManager *manager = [DSStageManager sharedManager];
        NSArray<NSString *> *hosted = [manager hostedBundleIdentifiers];
        // 4.5.653: nothing in the display layout while a call screen comes
        // up or is on screen; SpringBoard is rebuilding its own layout then.
        BOOL locked = DSCameraDeviceLocked() || DSCallGuardActive();
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        for (NSString *bundle in DSCameraClaims.allKeys) {
            DSCameraClaim *claim = DSCameraClaims[bundle];
            if (![hosted containsObject:bundle]) {
                DSCameraUnpublish(claim, @"app left the stage");
                [DSCameraClaims removeObjectForKey:bundle];
                continue;
            }
            if (now - claim.lastHeard > 12.0) {
                DSCameraUnpublish(claim, @"app stopped reporting its camera");
                [DSCameraClaims removeObjectForKey:bundle];
                continue;
            }
            CGRect frame = (locked || systemOwns) ? CGRectNull : [manager stageCardScreenFrameForBundleIdentifier:bundle cornerRadius:NULL];
            if (CGRectIsNull(frame) || CGRectGetWidth(frame) < 40.0 || CGRectGetHeight(frame) < 40.0) {
                DSCameraUnpublish(claim, locked ? @"phone locked or call screen up" :
                                         (systemOwns ? @"home / switcher has the screen" : @"card not visible"));
                continue;
            }
            if (claim.assertion && DSCameraFramesClose(frame, claim.frame)) continue;
            DSCameraUnpublish(claim, @"card moved");
            DSCameraPublish(claim, frame);
        }
    } @catch (NSException *exception) {
        DSCameraRecord(@"refreshthrew", @"refresh threw %@", exception.name ?: @"?");
    }
    DSCameraUpdatePublishedSet();
    if (DSCameraClaims.count > 0 && !DSCameraTimer) {
        // Once a second while a staged camera is live: card moved, minimized,
        // closed, locked. Never per frame.
        DSCameraTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                         target:self
                                                       selector:@selector(timerFired:)
                                                       userInfo:nil
                                                        repeats:YES];
        DSCameraTimer.tolerance = 0.3;
    } else if (DSCameraClaims.count == 0 && DSCameraTimer) {
        [DSCameraTimer invalidate];
        DSCameraTimer = nil;
    }
}

+ (BOOL)sceneIdentifierHoldsCamera:(NSString *)identifier {
    if (identifier.length == 0) return NO;
    os_unfair_lock_lock(&DSCameraPublishedLock);
    NSSet<NSString *> *published = DSCameraPublished;
    os_unfair_lock_unlock(&DSCameraPublishedLock);
    for (NSString *bundle in published) {
        if ([identifier rangeOfString:bundle].location != NSNotFound) return YES;
    }
    return NO;
}

+ (void)noteHostedSceneSettings:(id)settings identifier:(NSString *)identifier {
    if (!settings || identifier.length == 0) return;
    if ([DSSceneHost systemTransitionBusy]) return;
    static NSMutableDictionary<NSString *, NSString *> *lastState;
    if (!lastState) lastState = [NSMutableDictionary dictionary];
    BOOL foreground = DSCameraSend(settings, @selector(isForeground));
    BOOL occluded = DSCameraSend(settings, @selector(isOccluded));
    long long reasons = DSCameraSendLong(settings, @selector(deactivationReasons), -1);
    BOOL camera = [self sceneIdentifierHoldsCamera:identifier];
    NSString *state = [NSString stringWithFormat:@"fg=%d occluded=%d deactivation=0x%llx camera=%d",
                       foreground, occluded, reasons, camera];
    if ([lastState[identifier] isEqualToString:state]) return;
    lastState[identifier] = state;
    if (lastState.count > 16) [lastState removeAllObjects];
    DSCameraRecord([@"scene." stringByAppendingString:identifier], @"hosted scene %@ %@", identifier, state);
}

@end
