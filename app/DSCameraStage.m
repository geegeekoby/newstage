// 4.5.652: the camera inside a staged app.
//
// The camera server only streams to an app it counts as on screen. It learns
// that from the display layout SpringBoard publishes, and a stage card is not
// in that layout: SpringBoard hosts the card in its own window, so the server
// treats the staged app as background (or, once the card is in the layout,
// as one of several foreground apps) and interrupts the capture session. The
// session never runs and the preview stays black.
//
// This side runs inside the staged app (only the apps the dylib is injected
// into). It
//  - tells SpringBoard when a capture session starts, stops, is interrupted
//    and why, so SpringBoard can publish the card into the display layout
//    for exactly as long as the camera is wanted (kDSCameraNotification),
//  - while staged, asks AVFoundation for multitasking camera access (the
//    iPad split-view switch) so "several foreground apps" does not stop it,
//  - starts an interrupted session once more after SpringBoard has updated
//    the layout, if AVFoundation did not resume it on its own,
//  - logs the interruption reason, the app/scene state and the path taken,
//    rate limited.
//
// Everything is plain Objective-C runtime work, installed only once the
// AVCaptureSession class exists (it is often loaded late, for example by the
// image picker), and every call into AVFoundation is guarded.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <notify.h>
#import <stdatomic.h>
#import <os/lock.h>
#import <QuartzCore/QuartzCore.h>
#import "DSConstants.h"
#import "DSStageContext.h"
#import "DSDiagnostics.h"

void DSCameraStageInstall(void);
void DSCameraStageDidBecomeStaged(void);

static atomic_bool DSCameraInstalled = false;
static atomic_bool DSCameraCheckPending = false;
static atomic_int DSCameraAppState = 0; // 1 active, 2 inactive, 3 background
// Set when a session failed while multitasking access was being forced. From
// then on this process uses only the display layout path.
static atomic_bool DSCameraMultitaskBlocked = false;

static void (*DSOrigStartRunning)(id, SEL);
static void (*DSOrigStopRunning)(id, SEL);
static BOOL (*DSOrigMultitaskSupported)(id, SEL);
static BOOL (*DSOrigMultitaskEnabled)(id, SEL);
static void (*DSOrigSetMultitaskEnabled)(id, SEL, BOOL);

static NSHashTable *DSCameraSessions(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

static dispatch_queue_t DSCameraQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.recreated.dynamicstage.camera652", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static BOOL DSCameraStaged(void) {
    @try {
        return [DSStageContext sharedContext].staged;
    } @catch (NSException *exception) {
        return NO;
    }
}

static const char *DSCameraReasonName(NSInteger reason) {
    switch (reason) {
        case 1: return "video-not-available-in-background";
        case 2: return "audio-in-use-by-another-client";
        case 3: return "video-in-use-by-another-client";
        case 4: return "video-not-available-with-multiple-foreground-apps";
        case 5: return "video-not-available-due-to-system-pressure";
        default: return "unknown";
    }
}

static const char *DSCameraAppStateName(int state) {
    switch (state) {
        case 1: return "active";
        case 2: return "inactive";
        case 3: return "background";
        default: return "?";
    }
}

// Rate limited: one line per kind per second, and at most 40 a minute.
static void DSCameraLog(NSString *kind, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);
static void DSCameraLog(NSString *kind, NSString *format, ...) {
    static NSMutableDictionary<NSString *, NSNumber *> *last;
    static CFAbsoluteTime windowStart = 0;
    static NSInteger windowCount = 0;
    static dispatch_once_t once;
    static NSLock *lock;
    dispatch_once(&once, ^{
        last = [NSMutableDictionary dictionary];
        lock = [NSLock new];
    });
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    [lock lock];
    BOOL allowed = YES;
    if (now - windowStart > 60.0) {
        windowStart = now;
        windowCount = 0;
    }
    if (windowCount >= 40) allowed = NO;
    NSString *key = kind ?: @"?";
    if (allowed && now - [last[key] doubleValue] < 1.0) allowed = NO;
    if (allowed) {
        last[key] = @(now);
        windowCount += 1;
    }
    [lock unlock];
    if (!allowed) return;
    va_list args;
    va_start(args, format);
    NSString *text = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[DynamicStage] camera652 %@ %@", NSBundle.mainBundle.bundleIdentifier ?: @"?", text);
    // 4.5.658: the same line in the stage trace, so it shows up in the log the
    // user copies (as "<App> pid=.. | camera658 app ..."), not only in Console.
    DSTrace([@"camera658 app " stringByAppendingString:text]);
}

static BOOL DSCameraCall(id session, SEL selector, BOOL *ok) {
    if (ok) *ok = NO;
    if (!session || ![session respondsToSelector:selector]) return NO;
    @try {
        BOOL value = ((BOOL (*)(id, SEL))objc_msgSend)(session, selector);
        if (ok) *ok = YES;
        return value;
    } @catch (NSException *exception) {
        return NO;
    }
}

// 4.5.658: heartbeats and app-state posts used to pass no session, so their
// flags always said running=0 / multitask=0/0. The first live session the
// app has is used instead.
static id DSCameraFirstSession(void) {
    id found = nil;
    @synchronized(DSCameraSessions()) {
        for (id session in DSCameraSessions().allObjects) {
            found = session;
            BOOL ok = NO;
            if (DSCameraCall(session, @selector(isRunning), &ok) && ok) break;
        }
    }
    return found;
}

static uint32_t DSCameraFlagsForSession(id session, BOOL refused) {
    uint32_t flags = 0;
    BOOL ok = NO;
    if (!session) session = DSCameraFirstSession();
    BOOL supported = DSOrigMultitaskSupported && session ? DSOrigMultitaskSupported(session, @selector(isMultitaskingCameraAccessSupported)) : NO;
    BOOL enabled = DSOrigMultitaskEnabled && session ? DSOrigMultitaskEnabled(session, @selector(isMultitaskingCameraAccessEnabled)) : NO;
    if (supported) flags |= kDSCameraFlagMultitaskSupported;
    if (enabled) flags |= kDSCameraFlagMultitaskEnabled;
    if (atomic_load(&DSCameraAppState) == 1) flags |= kDSCameraFlagAppActive;
    if (DSCameraStaged()) flags |= kDSCameraFlagStaged;
    if (refused) flags |= kDSCameraFlagMultitaskRefused;
    if (DSCameraCall(session, @selector(isRunning), &ok) && ok) flags |= kDSCameraFlagRunning;
    ok = NO;
    if (DSCameraCall(session, @selector(isInterrupted), &ok) && ok) flags |= kDSCameraFlagInterrupted;
    return flags;
}

static void DSCameraPost(int event, NSInteger reason, uint32_t flags) {
    static int token = NOTIFY_TOKEN_INVALID;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_check(kDSCameraNotification, &token);
    });
    uint64_t state = DSIdentifierHash(NSBundle.mainBundle.bundleIdentifier ?: @"");
    state |= ((uint64_t)(event & 0xff)) << 32;
    state |= ((uint64_t)(reason & 0xff)) << 40;
    state |= ((uint64_t)(flags & 0xff)) << 48;
    if (token != NOTIFY_TOKEN_INVALID) notify_set_state(token, state);
    notify_post(kDSCameraNotification);
}

#pragma mark - 4.5.660 event ring to SpringBoard (diagnostics only)

// Signal, Beeper and Messenger cannot write the copied log from their sandbox,
// so their camera658 lines never reached it. Each event also goes to
// SpringBoard over Darwin notify (see kDSCamera660Prefix), and SpringBoard
// writes it as a "camera660 <bundle> ..." line. Nothing here changes what the
// camera does: it only reads state and posts.

static os_unfair_lock DSCam660Lock = OS_UNFAIR_LOCK_INIT;
static BOOL DSCam660Setup = NO;          // under the lock
static int DSCam660Doorbell = NOTIFY_TOKEN_INVALID;
static int DSCam660SlotTokens[kDSCamera660Slots];
static uint16_t DSCam660Seq = 0;
static char DSCam660DoorbellName[160];

static NSString *DSCam660Bundle(void) {
    static NSString *bundle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bundle = [NSBundle.mainBundle.bundleIdentifier copy] ?: @"";
    });
    return bundle;
}

// Under the lock. Registers the slots once and clears what a previous process
// of this app left in them, so SpringBoard never replays stale events.
static BOOL DSCam660SetupLocked(void) {
    if (DSCam660Setup) return DSCam660Doorbell != NOTIFY_TOKEN_INVALID;
    DSCam660Setup = YES;
    uint32_t hash = DSIdentifierHash(DSCam660Bundle());
    if (hash == 0) return NO;
    char name[160];
    for (int k = 0; k < kDSCamera660Slots; k++) {
        DSCam660SlotTokens[k] = NOTIFY_TOKEN_INVALID;
        if (notify_register_check(DSCamera660Name(hash, k, name, sizeof(name)), &DSCam660SlotTokens[k]) == NOTIFY_STATUS_OK) {
            notify_set_state(DSCam660SlotTokens[k], 0);
        } else {
            DSCam660SlotTokens[k] = NOTIFY_TOKEN_INVALID;
        }
    }
    DSCamera660Name(hash, -1, DSCam660DoorbellName, sizeof(DSCam660DoorbellName));
    if (notify_register_check(DSCam660DoorbellName, &DSCam660Doorbell) != NOTIFY_STATUS_OK) {
        DSCam660Doorbell = NOTIFY_TOKEN_INVALID;
    }
    return DSCam660Doorbell != NOTIFY_TOKEN_INVALID;
}

// Rate limited: per event kind (0.25 s; Hello 2 s; State 8 s) and 60 a
// minute overall. A few notify calls, no file access, any thread.
static void DSCam660Emit(int event, int reason, uint32_t flags, uint32_t extra) {
    static CFAbsoluteTime last[32];
    static CFAbsoluteTime windowStart = 0;
    static int windowCount = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    double gap = event == kDSCamera660EvState ? 8.0 : (event == kDSCamera660EvHello ? 2.0 : 0.25);
    // Each Hello cause has its own slot, so a launch Hello that SpringBoard
    // drops (app not on a card yet) cannot suppress the on-card one.
    int index = event == kDSCamera660EvHello ? 16 + (reason & 7) : (event & 15);
    os_unfair_lock_lock(&DSCam660Lock);
    if (now - windowStart > 60.0) {
        windowStart = now;
        windowCount = 0;
    }
    if (windowCount >= 60 || now - last[index] < gap || !DSCam660SetupLocked()) {
        os_unfair_lock_unlock(&DSCam660Lock);
        return;
    }
    last[index] = now;
    windowCount += 1;
    DSCam660Seq = (uint16_t)(DSCam660Seq + 1);
    if (DSCam660Seq == 0) DSCam660Seq = 1;
    uint16_t seq = DSCam660Seq;
    uint64_t state = (uint64_t)seq;
    state |= ((uint64_t)(event & 0xff)) << 16;
    state |= ((uint64_t)(reason & 0xff)) << 24;
    state |= ((uint64_t)(flags & 0xffff)) << 32;
    state |= ((uint64_t)(extra & 0xffff)) << 48;
    int slot = DSCam660SlotTokens[seq % kDSCamera660Slots];
    if (slot != NOTIFY_TOKEN_INVALID) notify_set_state(slot, state);
    notify_set_state(DSCam660Doorbell, (((uint64_t)(uint32_t)getpid()) << 16) | seq);
    os_unfair_lock_unlock(&DSCam660Lock);
    notify_post(DSCam660DoorbellName);
}

static id DSCam660Get(id target, SEL selector) {
    if (!target || ![target respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (NSException *exception) {
        return nil;
    }
}

// Read only: is a preview layer connected to this session, is it in a layer
// tree, does it have a size, is it hidden; is there a video input. That makes
// "running but black" visible. extra = connections | outputs << 8.
static uint32_t DSCam660SessionFlags(id session, uint32_t *extra) {
    uint32_t flags = 0;
    NSUInteger connections = 0;
    NSUInteger outputs = 0;
    if (extra) *extra = 0;
    if (!session) return 0;
    flags |= kDSCamera660FlagSessionKnown;
    @try {
        NSArray *outputList = DSCam660Get(session, @selector(outputs));
        if ([outputList isKindOfClass:NSArray.class]) outputs = outputList.count;
        NSArray *inputs = DSCam660Get(session, @selector(inputs));
        if ([inputs isKindOfClass:NSArray.class]) {
            for (id input in inputs) {
                id device = DSCam660Get(input, @selector(device));
                if (device && [device respondsToSelector:@selector(hasMediaType:)] &&
                    ((BOOL (*)(id, SEL, id))objc_msgSend)(device, @selector(hasMediaType:), @"vide")) {
                    flags |= kDSCamera660FlagVideoInput;
                    break;
                }
            }
        }
        NSArray *list = DSCam660Get(session, @selector(connections));
        if ([list isKindOfClass:NSArray.class]) {
            connections = list.count;
            for (id connection in list) {
                id layer = DSCam660Get(connection, @selector(videoPreviewLayer));
                if (!layer) continue;
                flags |= kDSCamera660FlagPreviewAttached;
                BOOL enabled = [connection respondsToSelector:@selector(isEnabled)]
                    ? ((BOOL (*)(id, SEL))objc_msgSend)(connection, @selector(isEnabled)) : YES;
                BOOL active = [connection respondsToSelector:@selector(isActive)]
                    ? ((BOOL (*)(id, SEL))objc_msgSend)(connection, @selector(isActive)) : YES;
                if (enabled && active) flags |= kDSCamera660FlagPreviewActive;
                if ([layer isKindOfClass:CALayer.class]) {
                    CALayer *preview = (CALayer *)layer;
                    if (preview.superlayer) flags |= kDSCamera660FlagPreviewInTree;
                    CGRect bounds = preview.bounds;
                    if (CGRectGetWidth(bounds) > 1.0 && CGRectGetHeight(bounds) > 1.0) flags |= kDSCamera660FlagPreviewHasSize;
                    if (preview.hidden || preview.opacity < 0.01f) flags |= kDSCamera660FlagPreviewHidden;
                }
            }
        }
    } @catch (NSException *exception) {
    }
    if (extra) *extra = (uint32_t)MIN(connections, (NSUInteger)255) | ((uint32_t)MIN(outputs, (NSUInteger)255) << 8);
    return flags;
}

static uint32_t DSCam660Flags(id session, BOOL refused, uint32_t *extra) {
    if (!session) session = DSCameraFirstSession();
    uint32_t flags = DSCameraFlagsForSession(session, refused) & 0x7f;
    if (atomic_load(&DSCameraInstalled)) flags |= kDSCamera660FlagHooksIn;
    if (atomic_load(&DSCameraAppState) == 3) flags |= kDSCamera660FlagAppBackground;
    flags |= DSCam660SessionFlags(session, extra);
    return flags;
}

static void DSCam660Event(int event, int reason, id session, BOOL refused) {
    uint32_t extra = 0;
    uint32_t flags = DSCam660Flags(session, refused, &extra);
    DSCam660Emit(event, reason, flags, extra);
}

static NSUInteger DSCam660SessionCount(void) {
    @synchronized(DSCameraSessions()) {
        return DSCameraSessions().allObjects.count;
    }
}

// Hello: the hook state. extra = known sessions | multitask switch present << 8.
static void DSCam660Hello(int cause) {
    dispatch_async(DSCameraQueue(), ^{
        uint32_t ignored = 0;
        uint32_t flags = DSCam660Flags(nil, NO, &ignored);
        uint32_t extra = (uint32_t)MIN(DSCam660SessionCount(), (NSUInteger)255) | ((DSOrigSetMultitaskEnabled ? 1u : 0u) << 8);
        DSCam660Emit(kDSCamera660EvHello, cause, flags, extra);
    });
}

// Multitasking camera access is AVFoundation's own switch for an app that
// shares the screen with another app. Ask for it on every staged session.
// It is refused where the hardware does not offer it; that is logged, and the
// display layout path in SpringBoard is then what gets the camera.
static BOOL DSCameraRequestMultitask(id session, BOOL *refused) {
    if (refused) *refused = NO;
    if (!session || !DSOrigSetMultitaskEnabled) return NO;
    if (atomic_load(&DSCameraMultitaskBlocked)) {
        if (refused) *refused = YES;
        return NO;
    }
    if (DSOrigMultitaskEnabled && DSOrigMultitaskEnabled(session, @selector(isMultitaskingCameraAccessEnabled))) return YES;
    @try {
        DSOrigSetMultitaskEnabled(session, @selector(setMultitaskingCameraAccessEnabled:), YES);
    } @catch (NSException *exception) {
        if (refused) *refused = YES;
        return NO;
    }
    BOOL enabled = DSOrigMultitaskEnabled ? DSOrigMultitaskEnabled(session, @selector(isMultitaskingCameraAccessEnabled)) : NO;
    if (!enabled && refused) *refused = YES;
    return enabled;
}

#pragma mark - Heartbeat

// SpringBoard drops the card from the display layout when it stops hearing
// from a session (an app that crashed or never called stopRunning).
static dispatch_source_t DSCameraHeartbeat;

static BOOL DSCameraAnySessionLive(void) {
    BOOL live = NO;
    @synchronized(DSCameraSessions()) {
        for (id session in DSCameraSessions().allObjects) {
            BOOL ok = NO;
            if (DSCameraCall(session, @selector(isRunning), &ok) && ok) { live = YES; break; }
            if (DSCameraCall(session, @selector(isInterrupted), &ok) && ok) { live = YES; break; }
        }
    }
    return live;
}

static void DSCameraStopHeartbeat(void) {
    if (!DSCameraHeartbeat) return;
    dispatch_source_cancel(DSCameraHeartbeat);
    DSCameraHeartbeat = nil;
}

static void DSCameraStartHeartbeat(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (DSCameraHeartbeat) return;
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        if (!timer) return;
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                                  (uint64_t)(4.0 * NSEC_PER_SEC), (uint64_t)(0.5 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(timer, ^{
            // The isRunning reads are cheap property reads; keep them off main anyway.
            dispatch_async(DSCameraQueue(), ^{
                BOOL live = DSCameraAnySessionLive();
                if (live) {
                    DSCameraPost(kDSCameraEventHeartbeat, 0, DSCameraFlagsForSession(nil, NO));
                    // 4.5.660: running / preview state, at most every 8 s.
                    DSCam660Event(kDSCamera660EvState, 0, nil, NO);
                    return;
                }
                DSCameraPost(kDSCameraEventStop, 0, DSCameraFlagsForSession(nil, NO));
                DSCam660Event(kDSCamera660EvStop, 1, nil, NO);
                DSCameraLog(@"idle", @"no session is running any more, released the camera claim");
                dispatch_async(dispatch_get_main_queue(), ^{
                    DSCameraStopHeartbeat();
                });
            });
        });
        DSCameraHeartbeat = timer;
        dispatch_resume(timer);
    });
}

// Only a session with a camera input claims the card. An audio-only session
// (a voice note) does not need the camera server's foreground check. With no
// inputs yet the session is given the benefit of the doubt.
static BOOL DSCameraSessionUsesVideo(id session) {
    if (!session || ![session respondsToSelector:@selector(inputs)]) return YES;
    @try {
        NSArray *inputs = ((NSArray *(*)(id, SEL))objc_msgSend)(session, @selector(inputs));
        if (![inputs isKindOfClass:NSArray.class] || inputs.count == 0) return YES;
        for (id input in inputs) {
            if (![input respondsToSelector:@selector(device)]) continue;
            id device = ((id (*)(id, SEL))objc_msgSend)(input, @selector(device));
            if (![device respondsToSelector:@selector(hasMediaType:)]) continue;
            if (((BOOL (*)(id, SEL, id))objc_msgSend)(device, @selector(hasMediaType:), @"vide")) return YES;
        }
        return NO;
    } @catch (NSException *exception) {
        return YES;
    }
}

#pragma mark - Hooks

static void DSCameraStartRunning(id self, SEL _cmd) {
    if (!DSCameraSessionUsesVideo(self)) {
        if (DSOrigStartRunning) DSOrigStartRunning(self, _cmd);
        return;
    }
    BOOL staged = DSCameraStaged();
    BOOL refused = NO;
    BOOL multitask = NO;
    if (staged) {
        multitask = DSCameraRequestMultitask(self, &refused);
    }
    @synchronized(DSCameraSessions()) {
        [DSCameraSessions() addObject:self];
    }
    // Before the session asks the camera server, so SpringBoard can already be
    // putting the card into the display layout.
    DSCameraPost(kDSCameraEventStart, 0, DSCameraFlagsForSession(self, refused));
    // 4.5.660: reason = path (0 not staged, 1 multitask on, 2 refused, 3 unavailable).
    if (staged) DSCam660Event(multitask ? kDSCamera660EvMultitaskOn : kDSCamera660EvMultitaskRefused, refused ? 1 : 0, self, refused);
    DSCam660Event(kDSCamera660EvStartCalled, staged ? (multitask ? 1 : (refused ? 2 : 3)) : 0, self, refused);
    DSCameraLog(@"start", @"startRunning staged=%d app=%s multitask=%s path=%s",
                staged, DSCameraAppStateName(atomic_load(&DSCameraAppState)),
                multitask ? "on" : (refused ? "refused" : (staged ? "unavailable" : "not-staged")),
                staged ? (multitask ? "multitask+layout" : "layout") : "none");
    if (DSOrigStartRunning) DSOrigStartRunning(self, _cmd);
    BOOL ok = NO;
    BOOL running = DSCameraCall(self, @selector(isRunning), &ok);
    BOOL interrupted = DSCameraCall(self, @selector(isInterrupted), &ok);
    DSCameraLog(@"started", @"after startRunning running=%d interrupted=%d staged=%d", running, interrupted, staged);
    // 4.5.658: what startRunning itself achieved, for SpringBoard's log.
    DSCameraPost(kDSCameraEventAfterStart, 0, DSCameraFlagsForSession(self, refused));
    DSCam660Event(kDSCamera660EvStartReturned, 0, self, refused);
    DSCameraStartHeartbeat();
}

static void DSCameraStopRunning(id self, SEL _cmd) {
    if (DSOrigStopRunning) DSOrigStopRunning(self, _cmd);
    BOOL live = NO;
    @synchronized(DSCameraSessions()) {
        [DSCameraSessions() removeObject:self];
    }
    live = DSCameraAnySessionLive();
    if (!live) {
        DSCameraPost(kDSCameraEventStop, 0, DSCameraFlagsForSession(nil, NO));
        DSCam660Event(kDSCamera660EvStop, 0, self, NO);
        DSCameraLog(@"stop", @"stopRunning, camera released");
    }
}

static BOOL DSCameraMultitaskSupported(id self, SEL _cmd) {
    BOOL original = DSOrigMultitaskSupported ? DSOrigMultitaskSupported(self, _cmd) : NO;
    // An app that checks the switch before asking for it sees it on while
    // staged. The real answer is still what AVFoundation does with the request.
    if (!original && DSCameraStaged() && !atomic_load(&DSCameraMultitaskBlocked)) return YES;
    return original;
}

static BOOL DSCameraMultitaskEnabled(id self, SEL _cmd) {
    return DSOrigMultitaskEnabled ? DSOrigMultitaskEnabled(self, _cmd) : NO;
}

static void DSCameraSetMultitaskEnabled(id self, SEL _cmd, BOOL enabled) {
    // While staged the app may not switch it back off; outside the stage the
    // app's own choice stands. A refusal must never reach the app as a throw
    // it did not cause.
    BOOL want = enabled || (DSCameraStaged() && !atomic_load(&DSCameraMultitaskBlocked));
    @try {
        if (DSOrigSetMultitaskEnabled) DSOrigSetMultitaskEnabled(self, _cmd, want);
    } @catch (NSException *exception) {
        if (enabled && !DSCameraStaged()) @throw;
        DSCam660Emit(kDSCamera660EvMultitaskRefused, 2, kDSCamera660FlagHooksIn | (DSCameraStaged() ? kDSCameraFlagStaged : 0) | kDSCameraFlagMultitaskRefused, 0);
        DSCameraLog(@"refused", @"multitasking camera access refused: %@", exception.name ?: @"?");
    }
}

static IMP DSCameraHook(Class cls, SEL selector, IMP replacement) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NULL;
    IMP original = method_getImplementation(method);
    // Inherited methods get their own copy on this class so the superclass is
    // left alone; otherwise swap in place.
    if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) {
        original = method_setImplementation(method, replacement);
    }
    return original;
}

#pragma mark - Interruptions

static void DSCameraRetryLater(id session, NSInteger reason) {
    static NSMapTable *attempts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        attempts = [NSMapTable weakToStrongObjectsMapTable];
    });
    __weak id weakSession = session;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), DSCameraQueue(), ^{
        id strong = weakSession;
        if (!strong || !DSCameraStaged()) return;
        BOOL ok = NO;
        BOOL running = DSCameraCall(strong, @selector(isRunning), &ok);
        BOOL interrupted = DSCameraCall(strong, @selector(isInterrupted), &ok);
        if (running || !interrupted) return;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        NSArray *entry = nil;
        @synchronized(attempts) {
            entry = [attempts objectForKey:strong];
        }
        NSInteger count = 0;
        if (entry.count == 2 && now - [entry[0] doubleValue] < 20.0) count = [entry[1] integerValue];
        if (count >= 2) {
            DSCam660Event(kDSCamera660EvRetryCap, (int)reason, strong, NO);
            DSCameraLog(@"retry-cap", @"still interrupted (%s) after 2 retries, leaving it to AVFoundation",
                        DSCameraReasonName(reason));
            return;
        }
        @synchronized(attempts) {
            [attempts setObject:@[ @(count == 0 ? now : [entry[0] doubleValue]), @(count + 1) ] forKey:strong];
        }
        DSCameraPost(kDSCameraEventRetry, reason, DSCameraFlagsForSession(strong, NO));
        DSCam660Event(kDSCamera660EvRetry, (int)reason, strong, NO);
        DSCameraLog(@"retry", @"still interrupted (%s) 1.5s after the layout update, startRunning again (try %ld) path=resume",
                    DSCameraReasonName(reason), (long)(count + 1));
        @try {
            ((void (*)(id, SEL))objc_msgSend)(strong, @selector(startRunning));
        } @catch (NSException *exception) {
            DSCameraLog(@"retry-threw", @"startRunning threw %@", exception.name ?: @"?");
        }
    });
}

static void DSCameraObserveSessions(void) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    NSString *interrupted = @"AVCaptureSessionWasInterruptedNotification";
    NSString *ended = @"AVCaptureSessionInterruptionEndedNotification";
    NSString *runtime = @"AVCaptureSessionRuntimeErrorNotification";
    [center addObserverForName:interrupted object:nil queue:nil usingBlock:^(NSNotification *note) {
        id session = note.object;
        NSInteger reason = [note.userInfo[@"AVCaptureSessionInterruptionReasonKey"] integerValue];
        BOOL staged = DSCameraStaged();
        uint32_t flags = DSCameraFlagsForSession(session, NO);
        DSCameraPost(kDSCameraEventInterrupted, reason, flags);
        // 4.5.660: AVCaptureSessionInterruptionReasonKey as the reason byte,
        // with the preview layer state.
        DSCam660Event(kDSCamera660EvInterrupted, (int)reason, session, NO);
        DSCameraLog([NSString stringWithFormat:@"int%ld", (long)reason],
                    @"session interrupted reason=%ld (%s) staged=%d app=%s multitask=%d/%d path=%s",
                    (long)reason, DSCameraReasonName(reason), staged,
                    DSCameraAppStateName(atomic_load(&DSCameraAppState)),
                    (flags & kDSCameraFlagMultitaskSupported) != 0, (flags & kDSCameraFlagMultitaskEnabled) != 0,
                    (staged && (reason == 1 || reason == 4)) ? "layout+resume" : "none");
        if (!staged || !session) return;
        if (reason == 1 || reason == 4) {
            if (reason == 4) {
                BOOL refused = NO;
                DSCameraRequestMultitask(session, &refused);
            }
            DSCameraRetryLater(session, reason);
        }
    }];
    [center addObserverForName:ended object:nil queue:nil usingBlock:^(NSNotification *note) {
        DSCameraPost(kDSCameraEventInterruptionEnded, 0, DSCameraFlagsForSession(note.object, NO));
        DSCam660Event(kDSCamera660EvInterruptionEnded, 0, note.object, NO);
        DSCameraLog(@"ended", @"session interruption ended staged=%d", DSCameraStaged());
    }];
    [center addObserverForName:runtime object:nil queue:nil usingBlock:^(NSNotification *note) {
        NSError *error = note.userInfo[@"AVCaptureSessionErrorKey"];
        DSCameraPost(kDSCameraEventRuntimeError, (NSInteger)(labs((long)error.code) & 0xff), DSCameraFlagsForSession(note.object, NO));
        {
            // 4.5.660: the full code (as a signed 16-bit value) in extra.
            uint32_t ignored = 0;
            uint32_t runtimeFlags = DSCam660Flags(note.object, NO, &ignored);
            DSCam660Emit(kDSCamera660EvRuntimeError, (int)(labs((long)error.code) & 0xff), runtimeFlags, (uint32_t)(uint16_t)(int16_t)error.code);
        }
        id session = note.object;
        BOOL forced = DSOrigMultitaskEnabled && session &&
            DSOrigMultitaskEnabled(session, @selector(isMultitaskingCameraAccessEnabled)) &&
            !(DSOrigMultitaskSupported && DSOrigMultitaskSupported(session, @selector(isMultitaskingCameraAccessSupported)));
        DSCameraLog(@"runtime", @"session runtime error %@ %ld staged=%d forcedMultitask=%d",
                    error.domain ?: @"?", (long)error.code, DSCameraStaged(), forced);
        if (forced && !atomic_exchange(&DSCameraMultitaskBlocked, true)) {
            // The forced switch is the likely cause. Put it back and start
            // once more on the layout path alone.
            @try {
                if (DSOrigSetMultitaskEnabled) DSOrigSetMultitaskEnabled(session, @selector(setMultitaskingCameraAccessEnabled:), NO);
            } @catch (NSException *exception) {
            }
            DSCam660Event(kDSCamera660EvUnforce, 0, session, NO);
            DSCameraLog(@"unforce", @"multitasking access switched back off for this app, path=layout");
            __weak id weakSession = session;
            dispatch_async(DSCameraQueue(), ^{
                id strong = weakSession;
                if (!strong) return;
                @try {
                    ((void (*)(id, SEL))objc_msgSend)(strong, @selector(startRunning));
                } @catch (NSException *exception) {
                }
            });
        }
    }];

    // The app's own state, read where the camera calls arrive (any thread).
    void (^state)(int) = ^(int value) {
        int previous = atomic_exchange(&DSCameraAppState, value);
        // 4.5.660: only while this app has a capture session, and only on a change.
        if (previous != value && DSCam660SessionCount() > 0) {
            dispatch_async(DSCameraQueue(), ^{
                DSCam660Event(kDSCamera660EvAppState, value, nil, NO);
            });
        }
    };
    [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) { state(1); }];
    [center addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n) { state(2); }];
    [center addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        state(3);
        // A backgrounded app has no business holding the card in the layout.
        DSCameraPost(kDSCameraEventStop, 0, DSCameraFlagsForSession(nil, NO));
    }];
    [center addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        state(2);
        dispatch_async(DSCameraQueue(), ^{
            if (DSCameraAnySessionLive()) DSCameraPost(kDSCameraEventStart, 0, DSCameraFlagsForSession(nil, NO));
        });
    }];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplicationState current = UIApplication.sharedApplication.applicationState;
        atomic_store(&DSCameraAppState, current == UIApplicationStateActive ? 1 : (current == UIApplicationStateInactive ? 2 : 3));
    });
}

#pragma mark - Install

// 4.5.658: tells SpringBoard the camera hooks exist in this app, so its log
// can tell "not one of the injected apps" from "injected, hooks in". Sent
// 1.5 s late so the stage context and SpringBoard's card are both settled;
// SpringBoard ignores it for an app that is not on a card.
static void DSCameraPostHelloSoon(NSInteger hooksIn) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), DSCameraQueue(), ^{
        DSCameraPost(kDSCameraEventHello, hooksIn, DSCameraFlagsForSession(nil, NO));
    });
    // 4.5.660: SpringBoard only logs this one if the app is on a card by then.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), DSCameraQueue(), ^{
        DSCam660Hello(kDSCamera660HelloLaunch);
    });
}

// 4.5.660: the home / switcher gesture state SpringBoard publishes
// (com.recreated.dynamicstage.systemgesture: time the gesture began, 0 when
// over; older than 4 s counts as over). Nothing is announced during it.
static BOOL DSCam660SystemGestureActive(void) {
    static int token = NOTIFY_TOKEN_INVALID;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_check("com.recreated.dynamicstage.systemgesture", &token);
    });
    if (token == NOTIFY_TOKEN_INVALID) return NO;
    uint64_t state = 0;
    if (notify_get_state(token, &state) != NOTIFY_STATUS_OK || state == 0) return NO;
    CFAbsoluteTime began = (CFAbsoluteTime)state;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    return now - began >= -1.0 && now - began < 4.0;
}

// 4.5.660: the hook state again, now that SpringBoard knows this app is on a
// card (the launch Hello of an app that was already running was ignored).
// The old-channel Hello goes too, for the camera658 "camera hook loaded" line.
static void DSCam660Announce(int cause, int attempt) {
    if (DSCam660SystemGestureActive()) {
        if (attempt >= 4) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), DSCameraQueue(), ^{
            DSCam660Announce(cause, attempt + 1);
        });
        return;
    }
    DSCameraPost(kDSCameraEventHello, atomic_load(&DSCameraInstalled) ? 1 : 0, DSCameraFlagsForSession(nil, NO));
    DSCam660Hello(cause);
}

static void DSCam660ListenForPing(void) {
    uint32_t hash = DSIdentifierHash(DSCam660Bundle());
    if (hash == 0) return;
    char name[160];
    int token = NOTIFY_TOKEN_INVALID;
    notify_register_dispatch(DSCamera660Name(hash, -2, name, sizeof(name)), &token, DSCameraQueue(), ^(int t) {
        (void)t;
        DSCam660Announce(kDSCamera660HelloPing, 0);
    });
}

void DSCameraStageDidBecomeStaged(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), DSCameraQueue(), ^{
        if (!DSCameraStaged()) return;
        DSCam660Announce(kDSCamera660HelloStaged, 0);
    });
}

static void DSCameraTryInstall(void) {
    if (atomic_load(&DSCameraInstalled)) return;
    Class session = objc_getClass("AVCaptureSession");
    if (!session) return;
    if (atomic_exchange(&DSCameraInstalled, true)) return;
    @try {
        DSOrigStartRunning = (void (*)(id, SEL))DSCameraHook(session, @selector(startRunning), (IMP)DSCameraStartRunning);
        DSOrigStopRunning = (void (*)(id, SEL))DSCameraHook(session, @selector(stopRunning), (IMP)DSCameraStopRunning);
        // iOS 16 and later only.
        if (class_getInstanceMethod(session, @selector(isMultitaskingCameraAccessSupported))) {
            DSOrigMultitaskSupported = (BOOL (*)(id, SEL))DSCameraHook(session, @selector(isMultitaskingCameraAccessSupported), (IMP)DSCameraMultitaskSupported);
        }
        if (class_getInstanceMethod(session, @selector(isMultitaskingCameraAccessEnabled))) {
            DSOrigMultitaskEnabled = (BOOL (*)(id, SEL))DSCameraHook(session, @selector(isMultitaskingCameraAccessEnabled), (IMP)DSCameraMultitaskEnabled);
        }
        if (class_getInstanceMethod(session, @selector(setMultitaskingCameraAccessEnabled:))) {
            DSOrigSetMultitaskEnabled = (void (*)(id, SEL, BOOL))DSCameraHook(session, @selector(setMultitaskingCameraAccessEnabled:), (IMP)DSCameraSetMultitaskEnabled);
        }
        DSCameraObserveSessions();
        DSCameraLog(@"install", @"capture hooks in, multitask switch %s",
                    DSOrigSetMultitaskEnabled ? "present" : "absent (before iOS 16)");
        DSCam660Emit(kDSCamera660EvHooksIn, DSOrigSetMultitaskEnabled ? 1 : 0, kDSCamera660FlagHooksIn | (DSCameraStaged() ? kDSCameraFlagStaged : 0), 0);
        DSCameraPostHelloSoon(1);
    } @catch (NSException *exception) {
        NSLog(@"[DynamicStage] camera652 install threw %@", exception.name);
    }
}

static void DSCameraImageAdded(const struct mach_header *header, intptr_t slide) {
    (void)header;
    (void)slide;
    if (atomic_load(&DSCameraInstalled)) return;
    if (atomic_exchange(&DSCameraCheckPending, true)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store(&DSCameraCheckPending, false);
        DSCameraTryInstall();
    });
}

void DSCameraStageInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 4.5.660: answers SpringBoard's "you are on a card" ping.
        DSCam660ListenForPing();
        DSCameraTryInstall();
        if (!atomic_load(&DSCameraInstalled)) {
            // AVFoundation often arrives later, with the camera screen.
            _dyld_register_func_for_add_image(DSCameraImageAdded);
            DSCameraPostHelloSoon(0);
            DSCameraLog(@"wait", @"camera hooks waiting for AVFoundation to load");
        }
    });
}
