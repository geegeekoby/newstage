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
#import "DSStageDebug.h"

void DSCameraStageInstall(void);
void DSCameraStageDidBecomeStaged(void);
// 4.5.663: camera chrome on a short stage card (FILL + bottom-align).
BOOL DSCameraStageNeedsTallLayout(void);
void DSCameraStageNoteCameraUI(BOOL visible);
void DSCameraStageNoteCameraScreen(id controller, BOOL visible);
void DSCameraStageApplyLayoutFit(void);
BOOL DSCameraStageHoldsView(UIView *view);
BOOL DSCameraStageWritesView(void);
static void DSCam663NoteSessionChanged(void);
static BOOL DSCam664Recompute(void);
static void DSCam666UpdateTouchPath(void);

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

// 4.5.661: camera permission (AVCaptureDevice authorizationStatusForMediaType:
// video), carried in bits 12-14 of every event: 0 AVFoundation not loaded yet,
// 1 + status (1 not determined, 2 restricted, 3 denied, 4 authorized). Read at
// most every 2 s; never loads AVFoundation itself.
static uint32_t DSCam661Authorization(void) {
    static atomic_uint cached = 0;
    static _Atomic(double) readAt = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - atomic_load(&readAt) < 2.0) return atomic_load(&cached);
    uint32_t value = 0;
    Class device = objc_getClass("AVCaptureDevice");
    SEL selector = @selector(authorizationStatusForMediaType:);
    if (device && [device respondsToSelector:selector]) {
        @try {
            NSInteger status = ((NSInteger (*)(id, SEL, id))objc_msgSend)(device, selector, @"vide");
            value = (status >= 0 && status <= 3) ? (uint32_t)status + 1 : 0;
        } @catch (NSException *exception) {
            value = 0;
        }
    }
    atomic_store(&cached, value);
    atomic_store(&readAt, now);
    return value;
}

// Rate limited: per event kind (0.25 s; Hello 2 s; State 8 s) and 60 a
// minute overall. A few notify calls, no file access, any thread.
// 4.5.661: seq is 12 bits (bits 0-11), the permission status bits 12-14.
static void DSCam660Emit(int event, int reason, uint32_t flags, uint32_t extra) {
    uint32_t authorization = DSCam661Authorization();
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
    DSCam660Seq = (uint16_t)((DSCam660Seq + 1) & 0x0fff);
    if (DSCam660Seq == 0) DSCam660Seq = 1;
    uint16_t seq = DSCam660Seq;
    uint64_t state = (uint64_t)seq;
    state |= ((uint64_t)(authorization & 0x7)) << 12;
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
                    // 4.5.664: keep the cached camera-layout answer fresh.
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (DSCam664Recompute()) DSCameraStageApplyLayoutFit();
                    });
                    return;
                }
                DSCameraPost(kDSCameraEventStop, 0, DSCameraFlagsForSession(nil, NO));
                DSCam660Event(kDSCamera660EvStop, 1, nil, NO);
                DSCameraLog(@"idle", @"no session is running any more, released the camera claim");
                dispatch_async(dispatch_get_main_queue(), ^{
                    DSCameraStopHeartbeat();
                    DSCam663NoteSessionChanged();
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

static BOOL DSCameraAnySessionLive(void);

#pragma mark - 4.5.663 camera chrome (FILL + bottom-align, all windows)

// 4.5.662 used FIT (min) + center on the key window only. After that build the
// user still reported the take-picture / shutter button missing in most apps.
// Phone already solved "bottom controls on a short card" for the dial pad:
// FILL (max of W/H scales) + bottom-align so the shutter end of a phone-tall
// layout stays on the card (top chrome may clip). Mirror that here.
// Also scale every non-keyboard window — Signal / Messenger / Beeper often put
// the camera UI in a secondary window the key-window-only fit never touched —
// and treat a live AVCaptureVideoPreviewLayer as camera-open even when the VC
// class name does not match "Camera".

static const void *DSCam663ScaledKey = &DSCam663ScaledKey;
static const void *DSCam663ScaleKey = &DSCam663ScaleKey;
static BOOL DSCam663Applying = NO;
static BOOL DSCam663FitQueued = NO;

static BOOL DSCameraIsMobilePhoneBundle(void) {
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"";
    return [bundle isEqualToString:@"com.apple.mobilephone"];
}

static BOOL DSCam663LayerHasPreview(CALayer *layer, Class previewClass, NSInteger depth) {
    if (!layer || depth > 24) return NO;
    // 4.5.664: a hidden or empty layer is not a camera on screen.
    if (layer.hidden || layer.opacity < 0.05f) return NO;
    if ([layer isKindOfClass:previewClass]) {
        return CGRectGetWidth(layer.bounds) >= 40.0 && CGRectGetHeight(layer.bounds) >= 40.0;
    }
    NSArray *subs = nil;
    @try { subs = layer.sublayers; } @catch (NSException *exception) { return NO; }
    for (CALayer *sub in subs) {
        if (DSCam663LayerHasPreview(sub, previewClass, depth + 1)) return YES;
    }
    return NO;
}

static BOOL DSCam663IsKeyboardishWindow(UIWindow *window);

static BOOL DSCameraHasPreviewLayer(void) {
    Class previewClass = NSClassFromString(@"AVCaptureVideoPreviewLayer");
    if (!previewClass) return NO;
    @try {
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            if (![window isKindOfClass:UIWindow.class] || window.hidden || window.alpha < 0.05) continue;
            if (DSCam663IsKeyboardishWindow(window)) continue;
            if (DSCam663LayerHasPreview(window.layer, previewClass, 0)) return YES;
        }
    } @catch (NSException *exception) {
        return NO;
    }
    return NO;
}

// 4.5.664: "camera open" is decided here, on the main thread, only when
// something camera-related happens (session start / stop, a camera screen
// appearing / going away, the heartbeat, the keyboard). 4.5.663 decided it
// inside every UIScreen.bounds read: a recursive walk of every window's layer
// tree per call, and a camera-ish view-controller name alone (CKBrowser,
// CKPhoto, MediaPicker, Scanner, Lens, ...) counted as open, with a counter
// that leaked when a screen appeared without a matching disappear. A false
// "open" handed the app the real phone screen, unclamped its frames and
// scaled every window, which is no place for a keyboard.
// Now it needs a running video session, or a live preview layer on screen
// together with an interrupted session or a camera screen. Never while a
// keyboard is up.
// ---- 4.5.667: a camera preview on screen counts by itself -----------------
// Beeper's camera (React Native) ran on a card with the green dot on
// ("camera661 sensor data ... type = camera; state = active", 16:13:16), yet no
// camera event, no layout664 line and no FILL followed: the 664 rule needed
// our startRunning hook to have seen the session (running) or a camera-named
// view controller (screens), and Beeper's camera screen is neither. So a live
// AVCaptureVideoPreviewLayer that covers a good part of a normal (never a
// keyboard / text-effects) window now counts as "camera open" on its own.
// Looked for on camera events, on layout passes while the camera layout is on,
// and once a second while the app is staged and active (UIKit and React
// Native add the preview a beat after the screen, so one look is not enough).
static NSString *DSCam667PreviewWhere = nil;

static BOOL DSCam667LayerFind(CALayer *layer, Class previewClass, CALayer *windowLayer, NSInteger depth,
                              NSInteger *budget, CGRect *found) {
    if (!layer || depth > 40 || *budget <= 0) return NO;
    *budget -= 1;
    if (layer.hidden || layer.opacity < 0.05f) return NO;
    if ([layer isKindOfClass:previewClass]) {
        CGRect inWindow = CGRectNull;
        @try { inWindow = [layer convertRect:layer.bounds toLayer:windowLayer]; } @catch (NSException *exception) { return NO; }
        if (CGRectGetWidth(inWindow) >= 80.0 && CGRectGetHeight(inWindow) >= 80.0) {
            if (found) *found = inWindow;
            return YES;
        }
        return NO;
    }
    NSArray *subs = nil;
    @try { subs = layer.sublayers; } @catch (NSException *exception) { return NO; }
    for (CALayer *sub in subs) {
        if (DSCam667LayerFind(sub, previewClass, windowLayer, depth + 1, budget, found)) return YES;
    }
    return NO;
}

// Main thread. YES when a preview covers >= 30% of the window it is in.
static BOOL DSCam667PreviewOnScreen(NSString **whereOut) {
    Class previewClass = NSClassFromString(@"AVCaptureVideoPreviewLayer");
    if (!previewClass) return NO;
    @try {
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            if (![window isKindOfClass:UIWindow.class] || window.hidden || window.alpha < 0.05) continue;
            if (DSCam663IsKeyboardishWindow(window)) continue;
            NSInteger budget = 6000;
            CGRect found = CGRectNull;
            if (!DSCam667LayerFind(window.layer, previewClass, window.layer, 0, &budget, &found)) continue;
            CGRect visible = CGRectIntersection(found, window.bounds);
            if (CGRectIsNull(visible)) continue;
            CGFloat windowArea = MAX(1.0, CGRectGetWidth(window.bounds) * CGRectGetHeight(window.bounds));
            CGFloat share = CGRectGetWidth(visible) * CGRectGetHeight(visible) / windowArea;
            if (share < 0.30) continue;
            if (whereOut) {
                *whereOut = [NSString stringWithFormat:@"%.0fx%.0f at %.0f,%.0f = %.0f%% of %@ lvl=%.0f",
                             CGRectGetWidth(found), CGRectGetHeight(found),
                             CGRectGetMinX(found), CGRectGetMinY(found), share * 100.0,
                             NSStringFromClass(object_getClass(window)), window.windowLevel];
            }
            return YES;
        }
    } @catch (NSException *exception) {
    }
    return NO;
}

static atomic_bool DSCam664Tall = false;
static BOOL DSCam664KeyboardUp = NO;
static BOOL DSCam664Dirty = YES;
static NSString *DSCam664Why = @"init";

static NSHashTable *DSCam664CameraScreens(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

static NSInteger DSCam664CameraScreensOnScreen(void) {
    NSInteger count = 0;
    @try {
        for (UIViewController *controller in DSCam664CameraScreens().allObjects) {
            if (![controller isKindOfClass:UIViewController.class]) continue;
            if (!controller.isViewLoaded) continue;
            UIView *view = controller.view;
            if (!view.window || view.window.hidden || view.hidden) continue;
            count++;
        }
    } @catch (NSException *exception) {
    }
    return count;
}

static BOOL DSCam664SessionRunning(BOOL *interruptedOut) {
    BOOL running = NO;
    BOOL interrupted = NO;
    @synchronized(DSCameraSessions()) {
        for (id session in DSCameraSessions().allObjects) {
            BOOL ok = NO;
            if (DSCameraCall(session, @selector(isRunning), &ok) && ok) running = YES;
            ok = NO;
            if (DSCameraCall(session, @selector(isInterrupted), &ok) && ok) interrupted = YES;
        }
    }
    if (interruptedOut) *interruptedOut = interrupted;
    return running;
}

// Main thread. Returns YES when the answer changed.
static BOOL DSCam664Recompute(void) {
    BOOL tall = NO;
    NSString *why = nil;
    if (!DSCameraStaged()) {
        why = @"not staged";
    } else if (DSCameraIsMobilePhoneBundle()) {
        why = @"Phone has its own fill";
    } else if (DSCam664KeyboardUp) {
        why = @"keyboard up";
    } else {
        BOOL interrupted = NO;
        BOOL running = DSCam664SessionRunning(&interrupted);
        NSInteger screens = DSCam664CameraScreensOnScreen();
        BOOL preview = (running || interrupted || screens > 0) ? DSCameraHasPreviewLayer() : NO;
        NSString *where = nil;
        BOOL bigPreview = (!running && !(preview && (interrupted || screens > 0))) ? DSCam667PreviewOnScreen(&where) : NO;
        if (running) {
            tall = YES;
            why = @"video session running";
        } else if (preview && (interrupted || screens > 0)) {
            tall = YES;
            why = interrupted ? @"interrupted session with a preview on screen" : @"camera screen with a preview on screen";
        } else if (bigPreview) {
            // 4.5.667: Beeper / React Native cameras (no hooked session seen).
            tall = YES;
            why = [NSString stringWithFormat:@"camera preview on screen without a hooked session: %@", where ?: @"?"];
            DSCam667PreviewWhere = where;
        } else {
            why = [NSString stringWithFormat:@"no camera on screen (running=%d interrupted=%d screens=%ld preview=%d)",
                   running, interrupted, (long)screens, preview];
        }
    }
    BOOL old = atomic_exchange(&DSCam664Tall, tall);
    BOOL changed = old != tall || ![why isEqualToString:DSCam664Why];
    DSCam664Why = why;
    if (old != tall) {
        DSCameraLog(@"layout664", @"camera layout %s: %@", tall ? "on" : "off", why);
    }
    return old != tall || changed;
}

BOOL DSCameraStageNeedsTallLayout(void) {
    // Cheap: read on every UIScreen bounds call.
    if (!atomic_load(&DSCam664Tall)) return NO;
    return DSCameraStaged();
}

static BOOL DSCam663IsKeyboardishWindow(UIWindow *window) {
    if (![window isKindOfClass:UIWindow.class]) return YES;
    NSString *name = NSStringFromClass(object_getClass(window));
    if ([name containsString:@"Keyboard"] || [name containsString:@"TextEffects"]) return YES;
    if ([name containsString:@"UIRemoteKeyboard"] || [name containsString:@"UITextEffects"]) return YES;
    // 4.5.664: subclasses with other names (editing overlay, input hosts),
    // and anything above the app's normal windows.
    if ([name containsString:@"EditingOverlay"] || [name containsString:@"InputWindow"] ||
        [name containsString:@"InputHost"] || [name containsString:@"InputSet"]) return YES;
    static Class effects;
    static Class remote;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        effects = objc_getClass("UITextEffectsWindow");
        remote = objc_getClass("UIRemoteKeyboardWindow");
    });
    if (effects && [window isKindOfClass:effects]) return YES;
    if (remote && [window isKindOfClass:remote]) return YES;
    if ([window respondsToSelector:@selector(_isTextEffectsWindow)]) {
        @try {
            if (((BOOL (*)(id, SEL))objc_msgSend)(window, @selector(_isTextEffectsWindow))) return YES;
        } @catch (NSException *exception) {
        }
    }
    if (window.windowLevel >= UIWindowLevelStatusBar) return YES;
    return NO;
}

static void DSCam663RestoreRoot(UIView *root) {
    if (!root) return;
    if (!objc_getAssociatedObject(root, DSCam663ScaledKey)) return;
    @try {
        root.transform = CGAffineTransformIdentity;
        objc_setAssociatedObject(root, DSCam663ScaledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(root, DSCam663ScaleKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        DSCameraLog(@"layout663", @"restored root after camera chrome closed");
    } @catch (NSException *exception) {
    }
}

static NSHashTable *DSCam667PresentedViews(void);
static void DSCam667RestorePresented(void);
static void DSCam667NoteReleased(NSString *why);

static void DSCam663RestoreAll(void) {
    @try {
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            if (DSCam663IsKeyboardishWindow(window)) continue;
            UIView *root = window.rootViewController.view;
            DSCam663RestoreRoot(root);
        }
    } @catch (NSException *exception) {
    }
    DSCam667RestorePresented();
    DSCam667NoteReleased(DSCam664Why);
}

// FILL scale (same formula as DSPhoneExpectedRootFill) + bottom-align.
static void DSCam663ApplyToWindow(UIWindow *window, CGFloat layoutW, CGFloat layoutH, CGFloat cardW, CGFloat cardH, CGFloat scale) {
    if (!window || DSCam663IsKeyboardishWindow(window)) return;
    UIView *root = window.rootViewController.view;
    if (![root isKindOfClass:UIView.class]) return;

    CGRect wantWindow = CGRectMake(0.0, 0.0, cardW, cardH);
    if (!CGAffineTransformIsIdentity(window.transform)) window.transform = CGAffineTransformIdentity;
    if (fabs(CGRectGetWidth(window.bounds) - cardW) > 0.5 ||
        fabs(CGRectGetHeight(window.bounds) - cardH) > 0.5 ||
        fabs(CGRectGetMinX(window.frame)) > 0.5 ||
        fabs(CGRectGetMinY(window.frame)) > 0.5) {
        window.frame = wantWindow;
    }
    if (!window.clipsToBounds) window.clipsToBounds = YES;
    if (!window.layer.masksToBounds) window.layer.masksToBounds = YES;

    BOOL boundsWrong = fabs(CGRectGetWidth(root.bounds) - layoutW) > 0.5 ||
                       fabs(CGRectGetHeight(root.bounds) - layoutH) > 0.5;
    if (boundsWrong) {
        root.transform = CGAffineTransformIdentity;
        root.bounds = CGRectMake(0.0, 0.0, layoutW, layoutH);
    }

    CGFloat visualH = layoutH * scale;
    // Bottom-align when the filled content is at least as tall as the card:
    // shutter / flip / gallery stay on-card; status / top chrome may clip.
    CGFloat centerY = (visualH >= cardH - 0.5) ? (cardH - visualH / 2.0) : (cardH / 2.0);
    CGPoint wantCenter = CGPointMake(cardW / 2.0, centerY);
    CGAffineTransform wantT = CGAffineTransformMakeScale(scale, scale);
    if (fabs(root.center.x - wantCenter.x) > 0.25 || fabs(root.center.y - wantCenter.y) > 0.25) {
        root.center = wantCenter;
    }
    CGAffineTransform t = root.transform;
    if (fabs(t.a - wantT.a) > 0.0005 || fabs(t.d - wantT.d) > 0.0005 ||
        fabs(t.b) > 0.0005 || fabs(t.c) > 0.0005 || fabs(t.tx) > 0.25 || fabs(t.ty) > 0.25) {
        root.transform = wantT;
    }
    if (root.clipsToBounds) root.clipsToBounds = NO;
    if (root.layer.masksToBounds) root.layer.masksToBounds = NO;
    // Intermediate containers that clip the shutter after the root scale.
    @try {
        for (UIView *child in root.subviews) {
            if (child.clipsToBounds && CGRectGetHeight(child.bounds) > layoutH * 0.5) {
                child.clipsToBounds = NO;
                if (child.layer.masksToBounds) child.layer.masksToBounds = NO;
            }
        }
    } @catch (NSException *exception) {
    }
    objc_setAssociatedObject(root, DSCam663ScaledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(root, DSCam663ScaleKey, @(scale), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// ---- 4.5.666: camera buttons on a stage card -------------------------------
// The 4.5.665 log (Messages on a card, camera open 15:55:54 -> 15:56:02):
// the camera there is Apple's CameraMessagesApp extension in a remote view
// (CKFunCameraViewController + MSMessageExtensionBrowserViewController +
// _MSMessageExtensionRemoteViewController). Its preview, shutter, flip, flash
// and close are drawn and handled by the extension's own process. No capture
// session ran in Messages (no startRunning line, running=0), so the 663/664
// FILL transform never ran, and no rim651 hit was logged, so SpringBoard's
// rim did not take the taps.
// A touch only reaches that extension if the window server finds no window of
// Messages' own drawn over it first. The stage keeps Messages' keyboard
// windows (UIRemoteKeyboardWindow / UITextEffectsWindow) card-sized on top of
// everything ("app left UIRemoteKeyboardWindow at {{0, 0}, {420, 458}}" as the
// camera opened), and the stage's keyboard hit filters then hand the touch to
// the window below. That is fine for an in-process view and a dead end for a
// remote one: a touch Messages received is never passed on to the extension.
// So while a camera screen is up on a card and no keyboard is up:
//  - card-sized keyboard / text-effects windows that hold neither the camera
//    screen nor a remote view are hidden (taken out of the touch path), and
//    put back as soon as the camera screen goes or a keyboard comes up,
//  - the stage's keyboard hit filters step aside (plain UIKit hit testing),
//  - every tap's hit result is logged: tap666 <bundle> point=... hit=<class>.
static atomic_bool DSCam666CameraUp = false;
static BOOL DSCam666TickQueued = NO;

static NSHashTable *DSCam666HiddenWindows(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

BOOL DSCameraStageCameraScreenUp(void) {
    return atomic_load(&DSCam666CameraUp);
}

static NSString *DSCam666Bundle(void) {
    return NSBundle.mainBundle.bundleIdentifier ?: @"?";
}

static BOOL DSCam666IsInputWindow(UIWindow *window) {
    if (![window isKindOfClass:UIWindow.class]) return NO;
    static Class effects;
    static Class remote;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        effects = objc_getClass("UITextEffectsWindow");
        remote = objc_getClass("UIRemoteKeyboardWindow");
    });
    if (effects && [window isKindOfClass:effects]) return YES;
    if (remote && [window isKindOfClass:remote]) return YES;
    NSString *name = NSStringFromClass(object_getClass(window));
    return [name containsString:@"TextEffects"] || [name containsString:@"RemoteKeyboard"] ||
           [name containsString:@"KeyboardWindow"];
}

static BOOL DSCam666IsRemoteContentName(NSString *name) {
    if (name.length == 0 || [name containsString:@"Keyboard"]) return NO;
    return [name hasSuffix:@"RemoteView"] || [name containsString:@"RemoteViewController"] ||
           [name containsString:@"SizeTrackingView"] || [name containsString:@"MessageExtension"];
}

static BOOL DSCam666ViewHoldsRemoteContent(UIView *view, NSInteger depth) {
    if (!view || depth > 22 || view.hidden) return NO;
    NSString *name = NSStringFromClass(object_getClass(view));
    if (DSCam666IsRemoteContentName(name) &&
        CGRectGetWidth(view.bounds) >= 100.0 && CGRectGetHeight(view.bounds) >= 100.0) {
        return YES;
    }
    NSArray *subviews = nil;
    @try { subviews = view.subviews; } @catch (NSException *exception) { return NO; }
    for (UIView *sub in subviews) {
        if (DSCam666ViewHoldsRemoteContent(sub, depth + 1)) return YES;
    }
    return NO;
}

static BOOL DSCam666WindowHoldsCamera(UIWindow *window) {
    @try {
        for (UIViewController *controller in DSCam664CameraScreens().allObjects) {
            if (![controller isKindOfClass:UIViewController.class] || !controller.isViewLoaded) continue;
            if (controller.view.window == window) return YES;
        }
    } @catch (NSException *exception) {
        return YES;
    }
    return DSCam666ViewHoldsRemoteContent(window, 0);
}

static NSString *DSCam666WindowLine(void) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    @try {
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            if (parts.count >= 8) break;
            [parts addObject:[NSString stringWithFormat:@"%@ lvl=%.0f %@ hidden=%d camera=%d",
                              NSStringFromClass(object_getClass(window)), window.windowLevel,
                              NSStringFromCGRect(window.frame), window.hidden,
                              DSCam666WindowHoldsCamera(window)]];
        }
    } @catch (NSException *exception) {
    }
    return [parts componentsJoinedByString:@"; "];
}

static void DSCam666RestoreWindows(NSString *why) {
    NSArray *hidden = DSCam666HiddenWindows().allObjects;
    if (hidden.count == 0) return;
    [DSCam666HiddenWindows() removeAllObjects];
    for (UIWindow *window in hidden) {
        @try {
            if (window.hidden) window.hidden = NO;
        } @catch (NSException *exception) {
        }
    }
    DSTraceFormat(@"tap666 %@ put %lu keyboard window(s) back (%@)", DSCam666Bundle(),
                  (unsigned long)hidden.count, why ?: @"?");
}

// ---- 4.5.667: Messages' camera extension gets a phone-shaped container ----
// Buttonnot.txt (4.5.666, Messages on a card, 16:17:49-16:18:01): the camera
// is CKFunCameraViewController hosting Apple's camera extension through
// _MSMessageExtensionRemoteViewController. Every tap reached the extension's
// view (tap666 ... window=UIWindow lvl=0 hit=_UIRemoteView
// vc=_MSMessageExtensionRemoteViewController remote=1), the close X at the top
// (391,29) worked, and the taps on the lower part (y 355-431) did nothing.
// The extension is not injected: its camera UI is laid out for the phone
// (430x932: top bar, 4:3 viewfinder, then the shutter row near the bottom)
// inside a 420x458 remote view, so the shutter row sits below the card and
// what shows on the lower card is viewfinder, not buttons.
// While such a camera screen is up (no keyboard, no in-process camera layout),
// the view holding it gets the phone's bounds, so the extension lays its
// camera out exactly as on the phone, and is scaled to FIT the card (all of
// it: close X at the top, shutter row at the bottom). The window server maps
// touches through that scale. The stage's own frame hooks leave the view
// alone while this holds (DSCameraStageHoldsView).
// A view we reshaped goes back to filling its container when it filled it
// before (the frame saved mid-animation can be off the card).
static CGRect DSCam667RestoreFrame(UIView *view, NSValue *saved) {
    UIView *container = view.superview;
    if (container) {
        CGRect box = container.bounds;
        if (!saved) return box;
        CGRect old = saved.CGRectValue;
        if (fabs(CGRectGetWidth(old) - CGRectGetWidth(box)) <= 2.0 &&
            fabs(CGRectGetHeight(old) - CGRectGetHeight(box)) <= 2.0) return box;
        return old;
    }
    return saved ? saved.CGRectValue : view.frame;
}

static NSString *DSCam667Bundle(void);
static const void *DSCam667RemoteKey = &DSCam667RemoteKey;
static atomic_bool DSCam667RemoteOn = false;
static BOOL DSCam667RemoteWriting = NO;

static NSHashTable *DSCam667RemoteViews(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

BOOL DSCameraStageWritesView(void) {
    return DSCam667RemoteWriting && [NSThread isMainThread];
}

BOOL DSCameraStageHoldsView(UIView *view) {
    if (!atomic_load(&DSCam667RemoteOn) || DSCam667RemoteWriting || !view) return NO;
    if (![NSThread isMainThread]) return NO;
    return objc_getAssociatedObject(view, DSCam667RemoteKey) != nil;
}

static UIView *DSCam667FindRemoteView(UIView *view, NSInteger depth) {
    if (!view || depth > 22) return nil;
    NSString *name = NSStringFromClass(object_getClass(view));
    if ([name hasSuffix:@"RemoteView"] && ![name containsString:@"Keyboard"]) return view;
    for (UIView *sub in view.subviews) {
        UIView *found = DSCam667FindRemoteView(sub, depth + 1);
        if (found) return found;
    }
    return nil;
}

// The view to reshape: the camera screen's view, or the nearest ancestor that
// fills a card-sized container.
static UIView *DSCam667RemoteTarget(UIView *view, CGFloat cardW, CGFloat cardH) {
    UIView *candidate = view;
    for (NSInteger i = 0; candidate && i < 6; i++) {
        if (objc_getAssociatedObject(candidate, DSCam667RemoteKey)) return candidate;
        UIView *container = candidate.superview;
        if (!container) return nil;
        CGSize cs = container.bounds.size;
        BOOL cardSized = fabs(cs.width - cardW) <= 2.0 && fabs(cs.height - cardH) <= 2.0;
        if (cardSized) {
            CGRect frame = candidate.frame;
            if (CGRectGetWidth(frame) >= cardW * 0.9 && CGRectGetHeight(frame) >= cardH * 0.9) return candidate;
        }
        if ([container isKindOfClass:UIWindow.class]) return nil;
        candidate = container;
    }
    return nil;
}

// 4.5.668: the width fill crops the top of the extension camera, which is
// where its own close / Done sits. A Done of the stage's own, top-right on
// the card, dismisses the camera screen the way that button does (the
// extension's own close asks its host to dismiss it, which is this).
static __weak UIViewController *DSCam668DoneOwner = nil;
static __weak UIButton *DSCam668DoneButton = nil;

static void DSCam668RemoveDone(void) {
    UIButton *button = DSCam668DoneButton;
    DSCam668DoneButton = nil;
    DSCam668DoneOwner = nil;
    @try { [button removeFromSuperview]; } @catch (NSException *exception) {}
}

static void DSCam668DoneTapped(void) {
    UIViewController *owner = DSCam668DoneOwner;
    UIViewController *presenter = nil;
    @try {
        for (UIViewController *walk = owner; walk && !presenter; walk = walk.parentViewController) {
            presenter = walk.presentingViewController;
            if (presenter) owner = walk;
        }
    } @catch (NSException *exception) {
        presenter = nil;
    }
    DSTraceFormat(@"layout668 %@ stage Done tapped: dismissing %@ from %@", DSCam667Bundle(),
                  owner ? NSStringFromClass(object_getClass(owner)) : @"nil",
                  presenter ? NSStringFromClass(object_getClass(presenter)) : @"nil");
    @try {
        if (presenter) [presenter dismissViewControllerAnimated:YES completion:nil];
        else if (owner.navigationController && owner.navigationController.topViewController == owner) {
            [owner.navigationController popViewControllerAnimated:YES];
        } else if (owner) {
            [owner dismissViewControllerAnimated:YES completion:nil];
        }
    } @catch (NSException *exception) {
        DSTraceFormat(@"layout668 %@ stage Done could not dismiss (%@)", DSCam667Bundle(), exception.reason ?: exception.name ?: @"?");
    }
}

static void DSCam668EnsureDone(UIView *container, UIViewController *owner) {
    if (!container) return;
    UIButton *button = DSCam668DoneButton;
    if (owner) DSCam668DoneOwner = owner;
    if (button && button.superview != container) {
        [button removeFromSuperview];
        button = nil;
    }
    if (!button) {
        if (@available(iOS 14.0, *)) {
            button = [UIButton buttonWithType:UIButtonTypeSystem primaryAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
                (void)action;
                DSCam668DoneTapped();
            }]];
        } else {
            return;
        }
        [button setTitle:@"Done" forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        button.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
        button.layer.cornerRadius = 15.0;
        button.contentEdgeInsets = UIEdgeInsetsMake(5.0, 12.0, 5.0, 12.0);
        button.accessibilityLabel = @"Done";
        [container addSubview:button];
        DSCam668DoneButton = button;
    }
    [button sizeToFit];
    CGSize size = button.bounds.size;
    CGFloat width = MAX(size.width, 60.0);
    CGFloat height = MAX(size.height, 30.0);
    CGRect want = CGRectMake(CGRectGetWidth(container.bounds) - width - 12.0, 12.0, width, height);
    if (!CGRectEqualToRect(button.frame, want)) button.frame = want;
    if (container.subviews.lastObject != button) [container bringSubviewToFront:button];
}

// 4.5.670: Apple's camera extension in Messages always lays out phone-shaped
// (top bar, 4:3 preview, mode row, shutter row: ~430x932), and the 4.5.666 log
// showed that a card-sized view does not make it lay out card-shaped (its
// shutter row sat below the card, only the close X at the top was reachable).
// A 0.46-aspect layout cannot fill a 0.92-aspect card without cropping about
// half of it, so there are two honest choices:
//   FIT  (default): the whole camera UI, every button, scaled to the card's
//        height; only the empty status-bar strip above the top bar and the
//        home-indicator strip below the shutter row are cropped. The camera
//        is a centred column; Apple's own close / Retake / Send are on it.
//   FILL (4.5.668): the card's full width, bottom-aligned, the top cropped,
//        with the stage's own Done for the cropped close button.
// A small pill on the card switches between them (remembered in Messages).
static NSString *const DSCam670FillKey = @"DynamicStage670MessagesCameraFill";
static __weak UIButton *DSCam670ToggleButton = nil;
static void DSCam667ApplyRemoteFit(void);

// 4.5.673: FILL is the default. FIT only when this key is set (the pill,
// shown only in FIT or when the live mirror cannot be built, sets it).
static NSString *const DSCam673FitKey = @"DynamicStage673MessagesCameraFit";

static BOOL DSCam670FillPreferred(void) {
    (void)DSCam670FillKey;
    @try {
        return ![[NSUserDefaults standardUserDefaults] boolForKey:DSCam673FitKey];
    } @catch (NSException *exception) {
        return YES;
    }
}

static void DSCam670RemoveToggle(void) {
    UIButton *button = DSCam670ToggleButton;
    DSCam670ToggleButton = nil;
    @try { [button removeFromSuperview]; } @catch (NSException *exception) {}
}

static void DSCam670ToggleTapped(void) {
    BOOL fill = !DSCam670FillPreferred();
    @try {
        [[NSUserDefaults standardUserDefaults] setBool:!fill forKey:DSCam673FitKey];
    } @catch (NSException *exception) {
    }
    DSTraceFormat(@"layout670 %@ remote camera switched to %@ by the stage pill", DSCam667Bundle(), fill ? @"FILL (width, top cropped)" : @"FIT (whole camera UI)");
    DSCam667ApplyRemoteFit();
}

// The pill sits in the empty side margin in FIT (never over Apple's
// controls) and top-left in FILL (Done is top-right there).
static void DSCam670EnsureToggle(UIView *container, BOOL fill) {
    if (!container) return;
    UIButton *button = DSCam670ToggleButton;
    if (button && button.superview != container) {
        [button removeFromSuperview];
        button = nil;
    }
    if (!button) {
        if (@available(iOS 14.0, *)) {
            button = [UIButton buttonWithType:UIButtonTypeSystem primaryAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
                (void)action;
                DSCam670ToggleTapped();
            }]];
        } else {
            return;
        }
        button.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        button.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
        button.layer.cornerRadius = 13.0;
        button.contentEdgeInsets = UIEdgeInsetsMake(4.0, 10.0, 4.0, 10.0);
        [container addSubview:button];
        DSCam670ToggleButton = button;
    }
    NSString *title = fill ? @"Fit" : @"Fill";
    if (![[button titleForState:UIControlStateNormal] isEqualToString:title]) {
        [button setTitle:title forState:UIControlStateNormal];
        button.accessibilityLabel = fill ? @"Show the whole camera" : @"Fill the card width";
    }
    [button sizeToFit];
    CGSize size = button.bounds.size;
    CGFloat width = MAX(size.width, 44.0);
    CGFloat height = MAX(size.height, 26.0);
    CGRect want = fill ? CGRectMake(12.0, 12.0, width, height)
                       : CGRectMake(CGRectGetWidth(container.bounds) - width - 8.0, 8.0, width, height);
    if (!CGRectEqualToRect(button.frame, want)) button.frame = want;
    if (container.subviews.lastObject != button) [container bringSubviewToFront:button];
}

// ---- 4.5.673: FILL with Apple's top bar on the card ------------------------
// Apple's camera extension lays out phone-shaped (430x932): top bar (close,
// flash, Live ...; after a shot the review screen's top controls), the 4:3
// preview, then the mode row and the shutter row. At the card's width
// (scale 0.977) that is 910pt in a 458pt card, so FILL has to leave out a
// band. 4.5.673 leaves out the MIDDLE of the preview instead of the top: the
// card shows layout y 0..110 (Apple's top bar) at the top and the bottom of
// the camera (lower preview, mode row, shutter row) under it.
// The extension draws in its own process and the window server sends a touch
// to whichever process owns the layer under the finger at touch-down
// (backboardd -> contextIdAtPosition); a touch Messages receives can never be
// handed on to the extension, and one extension layer can only be in one
// place. So exactly one band is the REAL camera at a time and the other band
// is a live mirror of it (_UIPortalView, same pixels, same scale, same place):
//   BOTTOM live (default): shutter, mode row, flip, zoom, preview taps go
//     straight to the camera; the top bar is a live mirror.
//   TOP live: the real camera is moved down so Apple's real top bar sits
//     exactly where the mirror was; the bottom band is then the mirror.
// A touch on the mirrored band switches which band is real (the picture does
// not move, the band blinks once); the next tap there goes to Apple's button.
// Every button on the card is therefore Apple's own and works, the mirrored
// band on its second tap. If _UIPortalView is missing, the 4.5.668 FILL (top
// cropped, stage Done) is used.
static const CGFloat DSCam673TopBand = 110.0;   // layout pt, Apple's top bar
static int DSCam673Live = 0;                    // 0 bottom band real, 1 top band real
static __weak UIView *DSCam673TopMirror = nil;
static __weak UIView *DSCam673BottomMirror = nil;
static BOOL DSCam673PortalMissingLogged = NO;

@interface DSCam673MirrorView : UIView
@property (nonatomic, assign) NSInteger band; // 0 top, 1 bottom
@end

static void DSCam673MirrorTouched(DSCam673MirrorView *mirror, CGPoint point);

@implementation DSCam673MirrorView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha < 0.01 || !self.userInteractionEnabled) return nil;
    return [self pointInside:point withEvent:event] ? self : nil;
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    CGPoint point = touch ? [touch locationInView:self] : CGPointZero;
    DSCam673MirrorTouched(self, point);
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
}
@end

static void DSCam673SetBool(id object, NSString *setter, BOOL value) {
    SEL sel = NSSelectorFromString(setter);
    if (object && [object respondsToSelector:sel]) ((void (*)(id, SEL, BOOL))objc_msgSend)(object, sel, value);
}

static UIView *DSCam673PortalIn(UIView *mirror) {
    for (UIView *sub in mirror.subviews) {
        if ([NSStringFromClass(object_getClass(sub)) containsString:@"Portal"]) return sub;
    }
    return nil;
}

// Main thread, inside DSCam667RemoteWriting.
static DSCam673MirrorView *DSCam673EnsureMirror(UIView *container, UIView *source, NSInteger band) {
    __weak UIView *existing = band == 0 ? DSCam673TopMirror : DSCam673BottomMirror;
    DSCam673MirrorView *mirror = (DSCam673MirrorView *)existing;
    if (mirror && mirror.superview != container) {
        [mirror removeFromSuperview];
        mirror = nil;
    }
    UIView *portal = mirror ? DSCam673PortalIn(mirror) : nil;
    if (portal) {
        SEL getter = NSSelectorFromString(@"sourceView");
        id current = [portal respondsToSelector:getter] ? ((id (*)(id, SEL))objc_msgSend)(portal, getter) : nil;
        if (current != source) {
            SEL set = NSSelectorFromString(@"setSourceView:");
            if ([portal respondsToSelector:set]) ((void (*)(id, SEL, id))objc_msgSend)(portal, set, source);
        }
        return mirror;
    }
    Class portalClass = NSClassFromString(@"_UIPortalView");
    if (!portalClass || ![portalClass instancesRespondToSelector:NSSelectorFromString(@"setSourceView:")]) return nil;
    if (!mirror) {
        mirror = [[DSCam673MirrorView alloc] initWithFrame:CGRectZero];
        mirror.band = band;
        mirror.clipsToBounds = YES;
        mirror.backgroundColor = UIColor.blackColor;
        mirror.autoresizingMask = UIViewAutoresizingNone;
        mirror.accessibilityLabel = band == 0 ? @"Camera top controls" : @"Camera shutter controls";
        objc_setAssociatedObject(mirror, DSCam667RemoteKey, [NSValue valueWithCGRect:CGRectZero], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [container addSubview:mirror];
        if (band == 0) DSCam673TopMirror = mirror;
        else DSCam673BottomMirror = mirror;
    }
    @try {
        portal = [[portalClass alloc] initWithFrame:CGRectZero];
    } @catch (NSException *exception) {
        portal = nil;
    }
    if (!portal) return nil;
    portal.userInteractionEnabled = NO;
    portal.autoresizingMask = UIViewAutoresizingNone;
    DSCam673SetBool(portal, @"setMatchesPosition:", NO);
    DSCam673SetBool(portal, @"setMatchesTransform:", NO);
    DSCam673SetBool(portal, @"setMatchesAlpha:", NO);
    DSCam673SetBool(portal, @"setHidesSourceView:", NO);
    DSCam673SetBool(portal, @"setAllowsHitTesting:", NO);
    DSCam673SetBool(portal, @"setForwardsClientHitTestingToSourceView:", NO);
    ((void (*)(id, SEL, id))objc_msgSend)(portal, NSSelectorFromString(@"setSourceView:"), source);
    objc_setAssociatedObject(portal, DSCam667RemoteKey, [NSValue valueWithCGRect:CGRectZero], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [mirror addSubview:portal];
    return mirror;
}

static void DSCam673RemoveMirrors(void) {
    UIView *top = DSCam673TopMirror;
    UIView *bottom = DSCam673BottomMirror;
    DSCam673TopMirror = nil;
    DSCam673BottomMirror = nil;
    BOOL was = DSCam667RemoteWriting;
    DSCam667RemoteWriting = YES;
    @try { [top removeFromSuperview]; } @catch (NSException *exception) {}
    @try { [bottom removeFromSuperview]; } @catch (NSException *exception) {}
    DSCam667RemoteWriting = was;
}

// One mirror: frame on the card, and the portal placed so that layout y
// `layoutTop` of the camera lands at the mirror's top edge at `scale`.
// `source` is where the mirrored view sits inside the camera layout (layout
// pt); `layoutLeft` is where layout x 0 lands in the mirror (card pt).
static void DSCam673PlaceMirror(UIView *mirror, CGRect frame, CGRect source, CGFloat layoutLeft,
                                CGFloat scale, CGFloat layoutTop, BOOL visible) {
    if (!mirror) return;
    if (!CGRectEqualToRect(mirror.frame, frame)) mirror.frame = frame;
    if (mirror.hidden == visible) mirror.hidden = !visible;
    UIView *portal = DSCam673PortalIn(mirror);
    if (portal) {
        CGRect bounds = CGRectMake(0.0, 0.0, CGRectGetWidth(source), CGRectGetHeight(source));
        if (!CGRectEqualToRect(portal.bounds, bounds)) {
            portal.transform = CGAffineTransformIdentity;
            portal.bounds = bounds;
        }
        CGPoint center = CGPointMake(layoutLeft + CGRectGetMidX(source) * scale,
                                     (CGRectGetMidY(source) - layoutTop) * scale);
        if (fabs(portal.center.x - center.x) > 0.25 || fabs(portal.center.y - center.y) > 0.25) portal.center = center;
        CGAffineTransform t = portal.transform;
        if (fabs(t.a - scale) > 0.0005 || fabs(t.d - scale) > 0.0005) portal.transform = CGAffineTransformMakeScale(scale, scale);
    }
    if (visible && mirror.superview.subviews.lastObject != mirror) [mirror.superview bringSubviewToFront:mirror];
}

static void DSCam673Blink(UIView *container, CGRect frame) {
    if (!container || CGRectIsEmpty(frame)) return;
    UIView *flash = [[UIView alloc] initWithFrame:frame];
    flash.userInteractionEnabled = NO;
    flash.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.22];
    [container addSubview:flash];
    [UIView animateWithDuration:0.35 animations:^{
        flash.alpha = 0.0;
    } completion:^(BOOL finished) {
        (void)finished;
        [flash removeFromSuperview];
    }];
}

static void DSCam673MirrorTouched(DSCam673MirrorView *mirror, CGPoint point) {
    if (!mirror) return;
    int want = mirror.band == 0 ? 1 : 0;
    if (DSCam673Live == want) return;
    DSCam673Live = want;
    DSTraceFormat(@"layout673 %@ mirrored %@ band touched at %.0f,%.0f: real camera is now the %@ band (Apple's %@ live where the mirror was); "
                  @"this touch stayed in Messages, the next tap there reaches Apple's button",
                  DSCam667Bundle(), mirror.band == 0 ? @"TOP" : @"BOTTOM", point.x, point.y,
                  want == 1 ? @"TOP" : @"BOTTOM",
                  want == 1 ? @"top bar (close / flash / Live / Retake)" : @"shutter row (shutter / modes / flip / zoom)");
    CGRect blink = mirror.frame;
    UIView *container = mirror.superview;
    DSCam667ApplyRemoteFit();
    DSCam673Blink(container, blink);
}

static void DSCam667RestoreRemote(NSString *why) {
    DSCam668RemoveDone();
    DSCam670RemoveToggle();
    DSCam673RemoveMirrors();
    NSArray *views = DSCam667RemoteViews().allObjects;
    BOOL was = atomic_exchange(&DSCam667RemoteOn, false);
    if (views.count == 0) {
        if (was) DSTraceFormat(@"layout670 %@ remote camera fit off (%@)", DSCam667Bundle(), why ?: @"?");
        return;
    }
    [DSCam667RemoteViews() removeAllObjects];
    DSCam667RemoteWriting = YES;
    for (UIView *view in views) {
        @try {
            NSValue *saved = objc_getAssociatedObject(view, DSCam667RemoteKey);
            objc_setAssociatedObject(view, DSCam667RemoteKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            view.transform = CGAffineTransformIdentity;
            view.frame = DSCam667RestoreFrame(view, saved);
        } @catch (NSException *exception) {
        }
    }
    DSCam667RemoteWriting = NO;
    DSTraceFormat(@"layout670 %@ remote camera fit off (%@), %lu view(s) back to the card",
                  DSCam667Bundle(), why ?: @"?", (unsigned long)views.count);
}

static void DSCam667LogRemoteGeometry(UIView *target, NSString *when) {
    @try {
        UIView *remote = DSCam667FindRemoteView(target, 0);
        CGRect targetOnCard = target.window ? [target convertRect:target.bounds toView:target.window] : CGRectNull;
        CGRect remoteOnCard = (remote && remote.window) ? [remote convertRect:remote.bounds toView:remote.window] : CGRectNull;
        DSTraceFormat(@"layout670 %@ remote camera %@: target=%@ bounds=%.0fx%.0f scale=%.3f on card=%@ | remote=%@ bounds=%.0fx%.0f on card=%@",
                      DSCam667Bundle(), when ?: @"?", NSStringFromClass(object_getClass(target)),
                      CGRectGetWidth(target.bounds), CGRectGetHeight(target.bounds), target.transform.a,
                      NSStringFromCGRect(targetOnCard),
                      remote ? NSStringFromClass(object_getClass(remote)) : @"none",
                      CGRectGetWidth(remote.bounds), CGRectGetHeight(remote.bounds), NSStringFromCGRect(remoteOnCard));
    } @catch (NSException *exception) {
    }
}

// Main thread.
static void DSCam667ApplyRemoteFit(void) {
    NSString *off = nil;
    if (!DSCameraStaged()) off = @"not staged";
    else if (DSCameraIsMobilePhoneBundle()) off = @"Phone";
    else if (!atomic_load(&DSCam666CameraUp)) off = @"camera screen gone";
    else if (DSCam664KeyboardUp) off = @"keyboard up";
    else if (atomic_load(&DSCam664Tall)) off = @"in-app camera layout is on";
    CGRect device = [DSStageContext sharedContext].deviceBounds;
    CGRect stage = [DSStageContext sharedContext].stageBounds;
    CGFloat layoutW = CGRectGetWidth(device);
    CGFloat layoutH = CGRectGetHeight(device);
    CGFloat cardW = CGRectGetWidth(stage);
    CGFloat cardH = CGRectGetHeight(stage);
    if (!off && (layoutW < 80.0 || layoutH < 80.0 || cardW < 80.0 || cardH < 80.0 || cardH > layoutH - 40.0)) {
        off = @"card not settled";
    }
    UIView *target = nil;
    UIViewController *owner = nil;
    if (!off) {
        @try {
            for (UIViewController *controller in DSCam664CameraScreens().allObjects) {
                if (![controller isKindOfClass:UIViewController.class] || !controller.isViewLoaded) continue;
                UIView *view = controller.view;
                if (!view.window || view.window.hidden || view.hidden) continue;
                if (DSCam663IsKeyboardishWindow(view.window)) continue;
                if (!DSCam666ViewHoldsRemoteContent(view, 0)) continue;
                target = DSCam667RemoteTarget(view, cardW, cardH);
                owner = controller;
                if (target) break;
            }
        } @catch (NSException *exception) {
            target = nil;
        }
        if (!target) off = owner ? @"no card-filling view holds the remote camera" : @"no remote camera on screen";
    }
    if (off) {
        if (atomic_load(&DSCam667RemoteOn) || DSCam667RemoteViews().count > 0) DSCam667RestoreRemote(off);
        return;
    }
    UIView *container = target.superview;
    CGSize cs = container ? container.bounds.size : CGSizeMake(cardW, cardH);
    if (cs.width < 80.0 || cs.height < 80.0) cs = CGSizeMake(cardW, cardH);
    // 4.5.670: FIT shows the whole camera UI; FILL (default since 4.5.673) is the 4.5.668
    // width fill. See DSCam670FillPreferred above for why a card-sized,
    // unscaled extension view cannot work.
    BOOL fill = DSCam670FillPreferred();
    CGFloat scale = 1.0;
    CGPoint wantCenter = CGPointMake(cs.width / 2.0, cs.height / 2.0);
    CGFloat visibleTop = 0.0;
    CGFloat visibleBottom = layoutH;
    // 4.5.673 split FILL: top band layout 0..topBand, bottom band
    // layout bottomTop..visibleBottom, middle of the preview left out.
    BOOL split = NO;
    CGFloat topBand = 0.0;
    CGFloat bottomTop = 0.0;
    if (fill) {
        scale = cs.width / layoutW;
        if (scale < 0.2 || scale > 1.0) return;
        if (layoutH * scale > cs.height + 0.5) {
            CGFloat visibleH = cs.height / scale;
            CGFloat bottomCrop = MIN(layoutH >= 800.0 ? 30.0 : 0.0, MAX(0.0, layoutH - visibleH));
            visibleBottom = layoutH - bottomCrop;
            topBand = layoutH >= 800.0 ? DSCam673TopBand : round(DSCam673TopBand * layoutH / 932.0);
            CGFloat bottomSpan = (cs.height - topBand * scale) / scale;
            bottomTop = visibleBottom - bottomSpan;
            split = bottomTop > topBand + 20.0 && bottomSpan > 200.0;
            if (split && DSCam673Live == 1) {
                // Real camera top-aligned: Apple's top bar is live at card
                // y 0..topBand*scale; the bottom band is the mirror.
                wantCenter = CGPointMake(cs.width / 2.0, layoutH * scale / 2.0);
                visibleTop = 0.0;
            } else {
                CGFloat contentBottom = cs.height + bottomCrop * scale;
                wantCenter = CGPointMake(cs.width / 2.0, contentBottom - layoutH * scale / 2.0);
                visibleTop = visibleBottom - visibleH;
            }
        }
    } else {
        // Only the strips with no controls are cropped: the status-bar band
        // above the camera's top bar and the home-indicator band below its
        // shutter row.
        CGFloat topCrop = layoutH >= 800.0 ? 30.0 : 0.0;
        CGFloat bottomCrop = layoutH >= 800.0 ? 24.0 : 0.0;
        CGFloat spanH = layoutH - topCrop - bottomCrop;
        scale = MIN(cs.width / layoutW, cs.height / spanH);
        if (scale < 0.2 || scale > 1.0) return;
        CGFloat spanMid = topCrop + spanH / 2.0;
        wantCenter = CGPointMake(cs.width / 2.0, cs.height / 2.0 + (layoutH / 2.0 - spanMid) * scale);
        CGFloat shownH = cs.height / scale;
        visibleTop = MAX(0.0, spanMid - shownH / 2.0);
        visibleBottom = MIN(layoutH, spanMid + shownH / 2.0);
    }
    wantCenter.x = round(wantCenter.x * 2.0) / 2.0;
    wantCenter.y = round(wantCenter.y * 2.0) / 2.0;
    BOOL first = objc_getAssociatedObject(target, DSCam667RemoteKey) == nil;
    // Another view held before (screen swapped): put it back first.
    for (UIView *old in DSCam667RemoteViews().allObjects) {
        if (old != target) {
            DSCam667RestoreRemote(@"camera view swapped");
            break;
        }
    }
    if (first) DSCam673Live = 0; // each camera opens with the shutter row live
    DSCam667RemoteWriting = YES;
    @try {
        if (first) {
            objc_setAssociatedObject(target, DSCam667RemoteKey, [NSValue valueWithCGRect:target.frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [DSCam667RemoteViews() addObject:target];
        }
        if (fabs(CGRectGetWidth(target.bounds) - layoutW) > 0.5 || fabs(CGRectGetHeight(target.bounds) - layoutH) > 0.5) {
            target.transform = CGAffineTransformIdentity;
            target.bounds = CGRectMake(0.0, 0.0, layoutW, layoutH);
        }
        if (fabs(target.center.x - wantCenter.x) > 0.25 || fabs(target.center.y - wantCenter.y) > 0.25) target.center = wantCenter;
        CGAffineTransform t = target.transform;
        if (fabs(t.a - scale) > 0.0005 || fabs(t.d - scale) > 0.0005 || fabs(t.b) > 0.0005 || fabs(t.c) > 0.0005 ||
            fabs(t.tx) > 0.25 || fabs(t.ty) > 0.25) {
            target.transform = CGAffineTransformMakeScale(scale, scale);
        }
    } @catch (NSException *exception) {
    }
    // 4.5.673: the live mirror of whichever band is not the real camera.
    BOOL mirrored = NO;
    if (split && container) {
        @try {
            UIView *source = DSCam667FindRemoteView(target, 0) ?: target;
            CGRect sourceRect = CGRectMake(0.0, 0.0, layoutW, layoutH);
            if (source != target) {
                CGPoint origin = [source convertPoint:CGPointZero toView:target];
                sourceRect = CGRectMake(origin.x, origin.y, CGRectGetWidth(source.bounds), CGRectGetHeight(source.bounds));
            }
            UIView *topMirror = DSCam673EnsureMirror(container, source, 0);
            UIView *bottomMirror = topMirror ? DSCam673EnsureMirror(container, source, 1) : nil;
            if (topMirror && bottomMirror) {
                CGFloat layoutLeft = wantCenter.x - layoutW * scale / 2.0;
                CGFloat topH = round(topBand * scale * 2.0) / 2.0;
                DSCam673PlaceMirror(topMirror, CGRectMake(0.0, 0.0, cs.width, topH), sourceRect, layoutLeft,
                                    scale, 0.0, DSCam673Live == 0);
                DSCam673PlaceMirror(bottomMirror, CGRectMake(0.0, topH, cs.width, cs.height - topH), sourceRect, layoutLeft,
                                    scale, visibleBottom - (cs.height - topH) / scale, DSCam673Live == 1);
                mirrored = YES;
            }
        } @catch (NSException *exception) {
            mirrored = NO;
        }
    }
    DSCam667RemoteWriting = NO;
    if (!mirrored) {
        BOOL hadMirrors = DSCam673TopMirror != nil || DSCam673BottomMirror != nil;
        DSCam673RemoveMirrors();
        if (DSCam673Live == 1 && split) {
            // No mirror: go back to the 4.5.668 FILL on the next tick.
            DSCam673Live = 0;
            dispatch_async(dispatch_get_main_queue(), ^{ DSCam667ApplyRemoteFit(); });
        }
        if (split && !DSCam673PortalMissingLogged) {
            DSCam673PortalMissingLogged = YES;
            DSTraceFormat(@"layout673 %@ no live mirror (_UIPortalView %@): FILL keeps the 4.5.668 layout (top bar cropped, stage Done, Fit pill)%@",
                          DSCam667Bundle(), NSClassFromString(@"_UIPortalView") ? @"would not build" : @"missing",
                          hadMirrors ? @", mirrors removed" : @"");
        }
    }
    atomic_store(&DSCam667RemoteOn, true);
    // 4.5.670: the stage's Done only when Apple's own close / Retake band is
    // cropped (FILL); in FIT Apple's top bar is on the card.
    // 4.5.673: with the live top band Apple's close / Retake is on the card,
    // so no stage Done; the Fit pill only in FIT or without the mirror.
    BOOL doneNeeded = !mirrored && visibleTop > 40.0 && container != nil;
    if (doneNeeded) DSCam668EnsureDone(container, owner);
    else DSCam668RemoveDone();
    if (container && !mirrored) DSCam670EnsureToggle(container, fill);
    else DSCam670RemoveToggle();
    if (mirrored) {
        static int DSCam673LastLogged = -1;
        int state = DSCam673Live;
        if (first || state != DSCam673LastLogged) {
            DSCam673LastLogged = state;
            CGFloat topH = topBand * scale;
            DSTraceFormat(@"layout673 %@ remote camera FILL split: card %.0fx%.0f scale=%.3f, card y 0..%.0f = Apple's top bar (layout y 0..%.0f), "
                          @"card y %.0f..%.0f = camera bottom (layout y %.0f..%.0f), preview middle %.0f..%.0f left out; real camera=%@ band, "
                          @"%@ band = live mirror (tap once to make it real); stage Done=0 pill=none",
                          DSCam667Bundle(), cs.width, cs.height, scale, topH, topBand, topH, cs.height,
                          visibleBottom - (cs.height - topH) / scale, visibleBottom, topBand,
                          visibleBottom - (cs.height - topH) / scale,
                          state == 1 ? @"TOP" : @"BOTTOM", state == 1 ? @"BOTTOM" : @"TOP");
        }
    }
    static int DSCam670LastMode = -1;
    int mode = fill ? 1 : 0;
    if (first || mode != DSCam670LastMode) {
        DSCam670LastMode = mode;
        DSTraceFormat(@"layout670 %@ remote camera %@ for %@: %@ gets the phone's %.0fx%.0f, scale=%.3f into %.0fx%.0f (shown %.0fx%.0f), "
                      @"layout y=%.0f..%.0f on the card, stage Done=%d, pill=%@",
                      DSCam667Bundle(), fill ? @"FILL (card width, top cropped)" : @"FIT (whole camera UI, every button on the card)",
                      NSStringFromClass(object_getClass(owner)), NSStringFromClass(object_getClass(target)),
                      layoutW, layoutH, scale, cs.width, cs.height, layoutW * scale, MIN(cs.height, layoutH * scale),
                      visibleTop, visibleBottom, doneNeeded, fill ? @"Fit" : @"Fill");
    }
    if (first) {
        __weak UIView *weakTarget = target;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *strong = weakTarget;
            if (strong && atomic_load(&DSCam667RemoteOn)) DSCam667LogRemoteGeometry(strong, @"after 0.7s");
        });
    }
}

// Main thread.
static void DSCam666UpdateTouchPath(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ DSCam666UpdateTouchPath(); });
        return;
    }
    BOOL up = DSCameraStaged() && !DSCameraIsMobilePhoneBundle() && DSCam664CameraScreensOnScreen() > 0;
    BOOL was = atomic_exchange(&DSCam666CameraUp, up);
    if (up != was) {
        DSTraceFormat(@"tap666 %@ camera screen %s; windows: %@", DSCam666Bundle(), up ? "up" : "gone",
                      DSCam666WindowLine());
    }
    if (!up) {
        DSCam666RestoreWindows(@"camera screen gone");
        DSCam667ApplyRemoteFit();
        return;
    }
    if (DSCam664KeyboardUp) {
        DSCam666RestoreWindows(@"keyboard up");
    } else {
        CGRect stage = [DSStageContext sharedContext].stageBounds;
        CGRect card = CGRectMake(0.0, 0.0, CGRectGetWidth(stage), CGRectGetHeight(stage));
        CGFloat cardArea = MAX(1.0, CGRectGetWidth(card) * CGRectGetHeight(card));
        @try {
            for (UIWindow *window in UIApplication.sharedApplication.windows) {
                if (!DSCam666IsInputWindow(window) || window.hidden) continue;
                if ([DSCam666HiddenWindows() containsObject:window]) continue;
                CGRect frame = window.frame;
                CGFloat overlap = CGRectGetWidth(CGRectIntersection(frame, card)) *
                                  CGRectGetHeight(CGRectIntersection(frame, card));
                if (CGRectIsNull(CGRectIntersection(frame, card)) || overlap < cardArea * 0.25) continue;
                if (DSCam666WindowHoldsCamera(window)) continue;
                [DSCam666HiddenWindows() addObject:window];
                window.hidden = YES;
                DSTraceFormat(@"tap666 %@ camera up: %@ lvl=%.0f %@ taken out of the touch path (it sat over the camera)",
                              DSCam666Bundle(), NSStringFromClass(object_getClass(window)), window.windowLevel,
                              NSStringFromCGRect(frame));
            }
        } @catch (NSException *exception) {
        }
    }
    // 4.5.667: phone-shaped container for a remote (extension) camera.
    DSCam667ApplyRemoteFit();
    // While the camera screen is up, look again twice a second (UIKit can
    // show a keyboard window again on its own; Messages has no session, so
    // the camera heartbeat does not run).
    if (!DSCam666TickQueued) {
        DSCam666TickQueued = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            DSCam666TickQueued = NO;
            if (atomic_load(&DSCam666CameraUp) || DSCam666HiddenWindows().count > 0) DSCam666UpdateTouchPath();
        });
    }
}

// Called from the window hit-test hooks while a camera screen is up. A few
// lines per tap: one per window asked, per touch.
void DSCameraStageNoteHit(UIWindow *window, CGPoint point, UIEvent *event, UIView *hit, NSString *path) {
    if (!atomic_load(&DSCam666CameraUp) || !event) return;
    if (event.type != UIEventTypeTouches) return;
    static NSTimeInterval lastTimestamp = -1;
    static NSInteger linesThisTouch = 0;
    static __weak UIWindow *lastWindow = nil;
    static CFAbsoluteTime windowStart = 0;
    static NSInteger linesThisWindow = 0;
    if (event.timestamp != lastTimestamp) {
        lastTimestamp = event.timestamp;
        linesThisTouch = 0;
        lastWindow = nil;
    } else if (window == lastWindow) {
        return; // hitTest runs more than once per touch
    }
    if (linesThisTouch >= 3) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - windowStart > 60.0) {
        windowStart = now;
        linesThisWindow = 0;
    }
    if (linesThisWindow >= 60) return;
    linesThisTouch += 1;
    linesThisWindow += 1;
    lastWindow = window;
    NSString *hitName = hit ? NSStringFromClass(object_getClass(hit)) : @"nil";
    NSString *owner = @"";
    @try {
        UIResponder *responder = hit.nextResponder;
        for (NSInteger i = 0; responder && i < 12; i++) {
            if ([responder isKindOfClass:UIViewController.class]) {
                owner = [@" vc=" stringByAppendingString:NSStringFromClass(object_getClass(responder))];
                break;
            }
            responder = responder.nextResponder;
        }
    } @catch (NSException *exception) {
    }
    BOOL remote = hit && DSCam666IsRemoteContentName(hitName);
    DSTraceFormat(@"tap666 %@ point=%.0f,%.0f window=%@ lvl=%.0f hit=%@%@ remote=%d path=%@",
                  DSCam666Bundle(), point.x, point.y, NSStringFromClass(object_getClass(window)),
                  window.windowLevel, hitName, owner, remote, path ?: @"-");
}

// ---- 4.5.667: presented camera screens, the "engaged" line ----------------
// A camera screen presented modally (React Native Modal, native-stack
// fullScreenModal, UIImagePickerController) is not under the window's root
// view; it sits in a UITransitionView beside it, so the 663 root FILL never
// reached it. A full-window presented view gets the same treatment: phone
// bounds, FILL scale, bottom-aligned in its container.
static const void *DSCam667PresentedKey = &DSCam667PresentedKey;
static BOOL DSCam667Engaged = NO;

static NSHashTable *DSCam667PresentedViews(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

static NSString *DSCam667Bundle(void) {
    return NSBundle.mainBundle.bundleIdentifier ?: @"?";
}

static void DSCam667RestorePresented(void) {
    NSArray *views = DSCam667PresentedViews().allObjects;
    if (views.count == 0) return;
    [DSCam667PresentedViews() removeAllObjects];
    for (UIView *view in views) {
        @try {
            NSValue *saved = objc_getAssociatedObject(view, DSCam667PresentedKey);
            objc_setAssociatedObject(view, DSCam667PresentedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            view.transform = CGAffineTransformIdentity;
            view.frame = DSCam667RestoreFrame(view, saved);
        } @catch (NSException *exception) {
        }
    }
    DSTraceFormat(@"layout667 %@ put %lu presented camera view(s) back", DSCam667Bundle(), (unsigned long)views.count);
}

// YES when the presented view filled its (card-sized) container before we
// touched it, or is one we already scaled.
static BOOL DSCam667ApplyToPresented(UIView *view, CGFloat layoutW, CGFloat layoutH, CGFloat cardW, CGFloat cardH, CGFloat scale) {
    if (![view isKindOfClass:UIView.class] || !view.window || view.hidden) return NO;
    UIView *container = view.superview;
    if (!container || [container isKindOfClass:UIWindow.class]) return NO;
    CGSize cs = container.bounds.size;
    if (fabs(cs.width - cardW) > 2.0 || fabs(cs.height - cardH) > 2.0) return NO;
    BOOL ours = objc_getAssociatedObject(view, DSCam667PresentedKey) != nil;
    if (!ours) {
        CGRect frame = view.frame;
        BOOL full = CGRectGetWidth(frame) >= cardW * 0.9 && CGRectGetHeight(frame) >= cardH * 0.9;
        if (!full) return NO;
        objc_setAssociatedObject(view, DSCam667PresentedKey, [NSValue valueWithCGRect:frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [DSCam667PresentedViews() addObject:view];
    }
    if (fabs(CGRectGetWidth(view.bounds) - layoutW) > 0.5 || fabs(CGRectGetHeight(view.bounds) - layoutH) > 0.5) {
        view.transform = CGAffineTransformIdentity;
        view.bounds = CGRectMake(0.0, 0.0, layoutW, layoutH);
    }
    CGFloat visualH = layoutH * scale;
    CGFloat centerY = (visualH >= cs.height - 0.5) ? (cs.height - visualH / 2.0) : (cs.height / 2.0);
    CGPoint wantCenter = CGPointMake(cs.width / 2.0, centerY);
    if (fabs(view.center.x - wantCenter.x) > 0.25 || fabs(view.center.y - wantCenter.y) > 0.25) view.center = wantCenter;
    CGAffineTransform t = view.transform;
    if (fabs(t.a - scale) > 0.0005 || fabs(t.d - scale) > 0.0005 || fabs(t.b) > 0.0005 || fabs(t.c) > 0.0005 ||
        fabs(t.tx) > 0.25 || fabs(t.ty) > 0.25) {
        view.transform = CGAffineTransformMakeScale(scale, scale);
    }
    if (container.clipsToBounds == NO) container.clipsToBounds = YES;
    return YES;
}

static NSInteger DSCam667ApplyPresentedInWindow(UIWindow *window, CGFloat layoutW, CGFloat layoutH, CGFloat cardW, CGFloat cardH, CGFloat scale) {
    NSInteger count = 0;
    UIViewController *presented = window.rootViewController.presentedViewController;
    for (NSInteger i = 0; presented && i < 6; i++) {
        if (presented.isViewLoaded && !presented.isBeingDismissed) {
            UIView *view = presented.view;
            // A presentation controller may wrap the view; use the piece that
            // sits directly in the transition container.
            UIView *piece = view;
            for (NSInteger k = 0; piece.superview && k < 4; k++) {
                CGSize cs = piece.superview.bounds.size;
                if (fabs(cs.width - cardW) <= 2.0 && fabs(cs.height - cardH) <= 2.0) break;
                if ([piece.superview isKindOfClass:UIWindow.class]) break;
                piece = piece.superview;
            }
            if (DSCam667ApplyToPresented(piece, layoutW, layoutH, cardW, cardH, scale)) count++;
        }
        presented = presented.presentedViewController;
    }
    return count;
}

static void DSCam667NoteEngaged(CGFloat scale, CGFloat layoutW, CGFloat layoutH, CGFloat cardW, CGFloat cardH,
                                NSInteger roots, NSInteger presented) {
    static NSInteger lastPresented = -1;
    if (DSCam667Engaged && presented == lastPresented) return;
    BOOL first = !DSCam667Engaged;
    DSCam667Engaged = YES;
    lastPresented = presented;
    DSTraceFormat(@"layout667 %@ camera layout %@: FILL scale=%.3f phone=%.0fx%.0f card=%.0fx%.0f roots=%ld presented=%ld bottomAlign=1 why=%@",
                  DSCam667Bundle(), first ? @"ENGAGED" : @"updated", scale, layoutW, layoutH, cardW, cardH,
                  (long)roots, (long)presented, DSCam664Why ?: @"?");
    if (!first) return;
    // Where the shutter area ended up, once UIKit has laid the screen out.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!DSCam667Engaged) return;
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        @try {
            for (UIWindow *window in UIApplication.sharedApplication.windows) {
                if (DSCam663IsKeyboardishWindow(window) || window.hidden) continue;
                UIView *root = window.rootViewController.view;
                if (!root) continue;
                CGRect onCard = [root convertRect:root.bounds toView:window];
                [parts addObject:[NSString stringWithFormat:@"%@ root=%@ bounds=%.0fx%.0f on card=%@",
                                  NSStringFromClass(object_getClass(window)),
                                  NSStringFromClass(object_getClass(window.rootViewController)),
                                  CGRectGetWidth(root.bounds), CGRectGetHeight(root.bounds), NSStringFromCGRect(onCard)]];
                if (parts.count >= 3) break;
            }
            for (UIView *view in DSCam667PresentedViews().allObjects) {
                if (!view.window) continue;
                CGRect onCard = [view convertRect:view.bounds toView:view.window];
                [parts addObject:[NSString stringWithFormat:@"presented %@ bounds=%.0fx%.0f on card=%@",
                                  NSStringFromClass(object_getClass(view)), CGRectGetWidth(view.bounds),
                                  CGRectGetHeight(view.bounds), NSStringFromCGRect(onCard)]];
                if (parts.count >= 5) break;
            }
        } @catch (NSException *exception) {
        }
        DSTraceFormat(@"layout667 %@ camera layout geometry: %@ preview=%@", DSCam667Bundle(),
                      [parts componentsJoinedByString:@"; "], DSCam667PreviewWhere ?: @"-");
    });
}

static void DSCam667NoteReleased(NSString *why) {
    if (!DSCam667Engaged) return;
    DSCam667Engaged = NO;
    DSTraceFormat(@"layout667 %@ camera layout released (%@)", DSCam667Bundle(), why ?: @"?");
}

void DSCameraStageApplyLayoutFit(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ DSCameraStageApplyLayoutFit(); });
        return;
    }
    if (DSCam663Applying) return;
    {
        // Layout passes call this a lot while the camera is open; the preview
        // walk runs at most every 0.25 s unless an event asked for it.
        static CFAbsoluteTime lastRecompute = 0;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (DSCam664Dirty || now - lastRecompute > 0.25) {
            DSCam664Dirty = NO;
            lastRecompute = now;
            DSCam664Recompute();
        }
    }
    if (!DSCameraStageNeedsTallLayout()) {
        DSCam663RestoreAll();
        return;
    }

    CGRect device = [DSStageContext sharedContext].deviceBounds;
    CGRect stage = [DSStageContext sharedContext].stageBounds;
    CGFloat layoutW = CGRectGetWidth(device);
    CGFloat layoutH = CGRectGetHeight(device);
    CGFloat cardW = CGRectGetWidth(stage);
    CGFloat cardH = CGRectGetHeight(stage);
    if (layoutW < 80.0 || layoutH < 80.0 || cardW < 80.0 || cardH < 80.0) return;
    // Card still phone-sized (stage not settled): nothing to fit yet.
    if (cardH > layoutH - 40.0) return;

    // FILL (max), not FIT (min): same as Phone dial pad — bottom controls win.
    CGFloat scale = cardW / layoutW;
    if (layoutH * scale < cardH - 0.5) scale = cardH / layoutH;
    if (scale < 0.2 || scale > 1.05) return;

    DSCam663Applying = YES;
    @try {
        NSInteger applied = 0;
        NSInteger presented = 0;
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            if (DSCam663IsKeyboardishWindow(window)) continue;
            if (window.hidden) continue;
            DSCam663ApplyToWindow(window, layoutW, layoutH, cardW, cardH, scale);
            applied++;
            // 4.5.667: modally presented camera screens too.
            presented += DSCam667ApplyPresentedInWindow(window, layoutW, layoutH, cardW, cardH, scale);
        }
        DSCam667NoteEngaged(scale, layoutW, layoutH, cardW, cardH, applied, presented);
        static CFAbsoluteTime lastLog = 0;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - lastLog > 2.0) {
            lastLog = now;
            DSCameraLog(@"layout663", @"fill camera chrome scale=%.2f layout=%.0fx%.0f card=%.0fx%.0f windows=%ld bottomAlign=1",
                        scale, layoutW, layoutH, cardW, cardH, (long)applied);
        }
    } @catch (NSException *exception) {
    }
    DSCam663Applying = NO;
}

static void DSCam663RequestFit(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ DSCam663RequestFit(); });
        return;
    }
    DSCam664Dirty = YES;
    if (DSCam663FitQueued) return;
    DSCam663FitQueued = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        DSCam663FitQueued = NO;
        DSCameraStageApplyLayoutFit();
        // One settle pass: UIKit often clears the root transform on the next
        // layout after we write it (same race Phone had before 4.5.650).
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (DSCameraStageNeedsTallLayout()) DSCameraStageApplyLayoutFit();
        });
        // 4.5.664: a camera screen's preview layer often arrives a beat after
        // the screen itself; look again (cheap when nothing changed).
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (DSCam664Recompute() || DSCameraStageNeedsTallLayout()) DSCameraStageApplyLayoutFit();
        });
    });
}

void DSCameraStageNoteCameraUI(BOOL visible) {
    // Kept for older callers; the controller-aware entry below is used now.
    (void)visible;
    DSCam663RequestFit();
}

void DSCameraStageNoteCameraScreen(id controller, BOOL visible) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ DSCameraStageNoteCameraScreen(controller, visible); });
        return;
    }
    if (controller) {
        @try {
            if (visible) [DSCam664CameraScreens() addObject:controller];
            else [DSCam664CameraScreens() removeObject:controller];
        } @catch (NSException *exception) {
        }
    }
    DSCam663RequestFit();
    // 4.5.666: the view is often not in its window yet at willAppear.
    DSCam666UpdateTouchPath();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DSCam666UpdateTouchPath();
    });
}

static void DSCam664KeyboardChanged(NSNotification *note, BOOL hiding) {
    BOOL up = NO;
    if (!hiding) {
        // Show notifications only; a full keyboard is >= 120pt. The screen
        // size is hooked in a staged app, so the y position is not compared.
        CGRect end = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
        up = CGRectGetHeight(end) >= 120.0;
    }
    if (up == DSCam664KeyboardUp) return;
    DSCam664KeyboardUp = up;
    if (DSCam664Recompute() || up) DSCameraStageApplyLayoutFit();
    // 4.5.666: a keyboard puts the keyboard windows back at once.
    if (atomic_load(&DSCam666CameraUp) || DSCam666HiddenWindows().count > 0) DSCam666UpdateTouchPath();
}

static void DSCam664ObserveKeyboard(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        NSOperationQueue *main = NSOperationQueue.mainQueue;
        [center addObserverForName:UIKeyboardWillShowNotification object:nil queue:main usingBlock:^(NSNotification *note) {
            DSCam664KeyboardChanged(note, NO);
        }];
        [center addObserverForName:UIKeyboardDidShowNotification object:nil queue:main usingBlock:^(NSNotification *note) {
            DSCam664KeyboardChanged(note, NO);
        }];
        [center addObserverForName:UIKeyboardWillHideNotification object:nil queue:main usingBlock:^(NSNotification *note) {
            DSCam664KeyboardChanged(note, YES);
        }];
    });
}

static void DSCam663NoteSessionChanged(void) {
    DSCam663RequestFit();
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
    DSCam663NoteSessionChanged();
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
        DSCam663NoteSessionChanged();
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
    // 4.5.664: an interruption changes "camera on screen"; look again.
    [center addObserverForName:interrupted object:nil queue:nil usingBlock:^(NSNotification *note) {
        (void)note;
        DSCam663RequestFit();
    }];
    [center addObserverForName:ended object:nil queue:nil usingBlock:^(NSNotification *note) {
        DSCameraPost(kDSCameraEventInterruptionEnded, 0, DSCameraFlagsForSession(note.object, NO));
        DSCam660Event(kDSCamera660EvInterruptionEnded, 0, note.object, NO);
        DSCameraLog(@"ended", @"session interruption ended staged=%d", DSCameraStaged());
        DSCam663RequestFit();
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
        DSCam664ObserveKeyboard();
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

// 4.5.667: once a second while staged and active, look for a camera preview
// (Beeper's camera never calls a hooked startRunning we saw, and its screen
// has no camera-like controller name). Cheap when nothing is there: a capped
// layer walk of the app's normal windows; keyboards stop it (664).
static void DSCam667PollTick(void) {
    static NSInteger quietTicks = 0;
    BOOL staged = DSCameraStaged();
    BOOL wasTall = atomic_load(&DSCam664Tall);
    if (!staged || DSCameraIsMobilePhoneBundle()) {
        if (wasTall) {
            DSCam664Recompute();
            DSCameraStageApplyLayoutFit();
        }
        return;
    }
    UIApplicationState state = UIApplicationStateActive;
    @try { state = UIApplication.sharedApplication.applicationState; } @catch (NSException *exception) {}
    if (state == UIApplicationStateBackground) return;
    if (DSCam664KeyboardUp && !wasTall) return;
    DSCam664Recompute();
    BOOL tall = atomic_load(&DSCam664Tall);
    if (tall || wasTall) {
        quietTicks = 0;
        DSCameraStageApplyLayoutFit();
    } else {
        quietTicks++;
    }
}

// 4.5.701 battery701: the watch timer fired once a second in every injected
// app (Messages, Messenger, Signal, Beeper) for the app's whole life, even when
// not on a card or in the background (the tick then returns at once - the
// wake-up is the cost). Now it fires every 4 s (2 s leeway) while the app is
// not on a card or is in the background, and goes back to once a second
// right away when the app comes to the foreground or SpringBoard posts a stage
// change. On a card and in the foreground: once a second as before.
static dispatch_source_t DSCam667Timer;
static int DSCam667Cadence = 0;   // 0 = 1 s, 1 = 4 s

static void DSCam667SetCadence(int want) {
    if (!DSCam667Timer || want == DSCam667Cadence) return;
    DSCam667Cadence = want;
    double every = want == 0 ? 1.0 : 4.0;
    double leeway = want == 0 ? 0.25 : 2.0;
    dispatch_source_set_timer(DSCam667Timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(every * NSEC_PER_SEC)),
                              (uint64_t)(every * NSEC_PER_SEC), (uint64_t)(leeway * NSEC_PER_SEC));
}

static void DSCam667AdaptCadence(void) {
    if (!DSBattery701AppOn()) {
        DSCam667SetCadence(0);
        return;
    }
    UIApplicationState state = UIApplicationStateActive;
    @try { state = UIApplication.sharedApplication.applicationState; } @catch (NSException *exception) {}
    BOOL busy = DSCameraStaged() && state != UIApplicationStateBackground;
    DSCam667SetCadence((busy || atomic_load(&DSCam664Tall)) ? 0 : 1);
}

static void DSCam667StartPoll(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (DSCameraIsMobilePhoneBundle()) return;
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                                  (uint64_t)(1.0 * NSEC_PER_SEC), (uint64_t)(0.25 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(timer, ^{
            @try {
                DSCam667PollTick();
                DSCam667AdaptCadence();
            } @catch (NSException *exception) {
            }
        });
        DSCam667Timer = timer;
        dispatch_resume(timer);
        static dispatch_source_t keep;
        keep = timer;
        // Back to once a second at once on foreground / stage changes.
        void (^fast)(void) = ^{
            if (DSBattery701AppOn()) DSCam667AdaptCadence();
        };
        for (NSNotificationName name in @[ UIApplicationWillEnterForegroundNotification, UIApplicationDidBecomeActiveNotification ]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                (void)note;
                // The stage bit may arrive a moment after activation.
                DSCam667SetCadence(0);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), fast);
            }];
        }
        int token = NOTIFY_TOKEN_INVALID;
        notify_register_dispatch(kDSStageGeometryNotification, &token, dispatch_get_main_queue(), ^(int t) {
            (void)t;
            DSCam667SetCadence(0);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), fast);
        });
        int peer = NOTIFY_TOKEN_INVALID;
        notify_register_dispatch(kDSStagePeerNotification, &peer, dispatch_get_main_queue(), ^(int t) {
            (void)t;
            DSCam667SetCadence(0);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), fast);
        });
        DSTraceFormat(@"layout667 %@ camera preview watch on (once a second while on a card)", DSCam667Bundle());
    });
}

void DSCameraStageInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 4.5.660: answers SpringBoard's "you are on a card" ping.
        DSCam660ListenForPing();
        // 4.5.664: camera layout steps aside while a keyboard is up.
        DSCam664ObserveKeyboard();
        // 4.5.667: preview watch, independent of the capture hooks.
        DSCam667StartPoll();
        DSCameraTryInstall();
        if (!atomic_load(&DSCameraInstalled)) {
            // AVFoundation often arrives later, with the camera screen.
            _dyld_register_func_for_add_image(DSCameraImageAdded);
            DSCameraPostHelloSoon(0);
            DSCameraLog(@"wait", @"camera hooks waiting for AVFoundation to load");
        }
    });
}
