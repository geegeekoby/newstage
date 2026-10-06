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
#import "DSConstants.h"
#import "DSStageContext.h"

void DSCameraStageInstall(void);

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

static uint32_t DSCameraFlagsForSession(id session, BOOL refused) {
    uint32_t flags = 0;
    BOOL ok = NO;
    BOOL supported = DSOrigMultitaskSupported && session ? DSOrigMultitaskSupported(session, @selector(isMultitaskingCameraAccessSupported)) : NO;
    BOOL enabled = DSOrigMultitaskEnabled && session ? DSOrigMultitaskEnabled(session, @selector(isMultitaskingCameraAccessEnabled)) : NO;
    if (supported) flags |= kDSCameraFlagMultitaskSupported;
    if (enabled) flags |= kDSCameraFlagMultitaskEnabled;
    if (atomic_load(&DSCameraAppState) == 1) flags |= kDSCameraFlagAppActive;
    if (DSCameraStaged()) flags |= kDSCameraFlagStaged;
    if (refused) flags |= kDSCameraFlagMultitaskRefused;
    if (DSCameraCall(session, @selector(isRunning), &ok) && ok) flags |= kDSCameraFlagRunning;
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
                    return;
                }
                DSCameraPost(kDSCameraEventStop, 0, DSCameraFlagsForSession(nil, NO));
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
    DSCameraLog(@"start", @"startRunning staged=%d app=%s multitask=%s path=%s",
                staged, DSCameraAppStateName(atomic_load(&DSCameraAppState)),
                multitask ? "on" : (refused ? "refused" : (staged ? "unavailable" : "not-staged")),
                staged ? (multitask ? "multitask+layout" : "layout") : "none");
    if (DSOrigStartRunning) DSOrigStartRunning(self, _cmd);
    BOOL ok = NO;
    BOOL running = DSCameraCall(self, @selector(isRunning), &ok);
    BOOL interrupted = DSCameraCall(self, @selector(isInterrupted), &ok);
    DSCameraLog(@"started", @"after startRunning running=%d interrupted=%d staged=%d", running, interrupted, staged);
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
            DSCameraLog(@"retry-cap", @"still interrupted (%s) after 2 retries, leaving it to AVFoundation",
                        DSCameraReasonName(reason));
            return;
        }
        @synchronized(attempts) {
            [attempts setObject:@[ @(count == 0 ? now : [entry[0] doubleValue]), @(count + 1) ] forKey:strong];
        }
        DSCameraPost(kDSCameraEventRetry, reason, DSCameraFlagsForSession(strong, NO));
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
        DSCameraLog(@"ended", @"session interruption ended staged=%d", DSCameraStaged());
    }];
    [center addObserverForName:runtime object:nil queue:nil usingBlock:^(NSNotification *note) {
        NSError *error = note.userInfo[@"AVCaptureSessionErrorKey"];
        DSCameraPost(kDSCameraEventRuntimeError, (NSInteger)(labs((long)error.code) & 0xff), DSCameraFlagsForSession(note.object, NO));
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
        atomic_store(&DSCameraAppState, value);
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
        DSCameraTryInstall();
        if (!atomic_load(&DSCameraInstalled)) {
            // AVFoundation often arrives later, with the camera screen.
            _dyld_register_func_for_add_image(DSCameraImageAdded);
        }
    });
}
