#import "DSInCallStage.h"
#import "DSStageManager.h"
#import "DSSceneHost.h"
#import "DSDiagnostics.h"
#import "DSConstants.h"
#import "DSKeyboardVisibility.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>

// ---- state ------------------------------------------------------------------
static CFAbsoluteTime DSInCallArmedUntil = 0;
static NSInteger DSInCallSource = 0;
static NSInteger DSInCallGeneration = 0;      // bumps on every arm / disarm
static BOOL DSInCallContained = NO;
static __weak UIWindow *DSInCallWindow = nil;
static __weak UIView *DSInCallTarget = nil;
static CGRect DSInCallCardRect;               // screen coordinates
static BOOL DSInCallLoggedLowLevel = NO;
static BOOL DSInCallLoggedBanner = NO;

static const void *DSInCallSavedTransformKey = &DSInCallSavedTransformKey;
static const void *DSInCallSavedRadiusKey = &DSInCallSavedRadiusKey;
static const void *DSInCallSavedMasksKey = &DSInCallSavedMasksKey;
static const void *DSInCallSavedLevelKey = &DSInCallSavedLevelKey;
static const void *DSInCallSavedBackgroundKey = &DSInCallSavedBackgroundKey;

static NSString *const DSPhoneBundle = @"com.apple.mobilephone";
// 4.5.653: scaling the call screen into the card stays off. The call UI is the
// main-layout app (SBMainSwitcherWindow level 5); moving that window is not
// safe, and the hosted Phone scene's update during that transition was the
// SIGTRAP behind the safe modes. See DSCallGuardActive.
static const BOOL kDSInCallContainmentEnabled = NO;

// ---- 4.5.653 call guard, narrowed in 4.5.656 ----------------------------------
// 4.5.653 held every update to the staged app view from the moment the staged
// Phone's call key was tapped, for 25 s. That covered iOS's own switch to the
// call screen as well. The 4.5.652 log of the crash shows the order: call key
// 40.55, the Phone scene's deactivation update 40.80 (applied fine), call
// screen up in the main layout 40.88, then the update that asserted 42.88,
// two seconds after the call screen was already in front. 4.5.656 lets the
// updates of that transition through and holds once the call screen is in
// front (or a call window is up), for 4 s after it goes, and, if the call
// screen is never seen, from 1.5 s after the call key until the arm runs out.
static CFAbsoluteTime DSCallGuardArmedUntil = 0;
static CFAbsoluteTime DSCallGuardArmedAt = 0;
static CFAbsoluteTime DSCallGuardCheckedAt = 0;
static CFAbsoluteTime DSCallGuardFlipAt = 0;
static BOOL DSCallGuardLastActive = NO;
static const CFAbsoluteTime kDSCallArmSeconds = 25.0;
static const CFAbsoluteTime kDSCallHoldDelay = 1.5;

// 4.5.656 step-aside state.
static NSString *const DSInCallServiceBundle = @"com.apple.InCallService";
static BOOL DSCallScreenFront = NO;            // InCallService is the front app
static BOOL DSCallScreenSeenSinceArm = NO;
static CFAbsoluteTime DSCallScreenGoneAt = 0;
static BOOL DSCallAside = NO;
static CFAbsoluteTime DSCallAsideSince = 0;
static NSInteger DSCallAsideGeneration = 0;
static NSInteger DSCallHeldCount = 0;
static const CFAbsoluteTime kDSCallAsideWaitSeconds = 10.0;
static void DSCallAsideEvaluate(NSString *why);

static void DSCallGuardLog(NSString *line) {
    static CFAbsoluteTime last = 0;
    static NSString *lastLine = nil;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if ([lastLine isEqualToString:line] && now - last < 5.0) return;
    if (now - last < 0.5) return;
    last = now;
    lastLine = [line copy];
    DSDiagnosticsRecordFormat(@"SpringBoard: call653 %@", line);
}

// Rate limited: one line per distinct text every 3 s, at most 8 a second.
static void DSCall656Log(NSString *line) {
    if (line.length == 0) return;
    static NSMutableDictionary<NSString *, NSNumber *> *lastByLine = nil;
    static CFAbsoluteTime windowStart = 0;
    static NSInteger count = 0;
    if (!lastByLine) lastByLine = [NSMutableDictionary dictionary];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSNumber *last = lastByLine[line];
    if (last && now - last.doubleValue < 3.0) return;
    if (now - windowStart > 1.0) {
        windowStart = now;
        count = 0;
    }
    if (++count > 8) return;
    if (lastByLine.count > 32) [lastByLine removeAllObjects];
    lastByLine[line] = @(now);
    DSDiagnosticsRecordFormat(@"SpringBoard: call656 %@", line);
}

static BOOL DSReadCallScreenFront(void) {
    @try {
        id springBoard = [UIApplication sharedApplication];
        SEL frontSelector = @selector(_accessibilityFrontMostApplication);
        if (![springBoard respondsToSelector:frontSelector]) return NO;
        id front = ((id (*)(id, SEL))objc_msgSend)(springBoard, frontSelector);
        NSString *bundle = [front respondsToSelector:@selector(bundleIdentifier)] ? [front bundleIdentifier] : nil;
        return [bundle isEqualToString:DSInCallServiceBundle];
    } @catch (NSException *exception) {
        return NO;
    }
}

static void DSNoteCallScreenFront(BOOL front, CFAbsoluteTime now) {
    if (front == DSCallScreenFront) return;
    DSCallScreenFront = front;
    if (front) {
        if (now < DSCallGuardArmedUntil) DSCallScreenSeenSinceArm = YES;
        DSCall656Log(@"call screen (InCallService) is in front");
    } else {
        DSCallScreenGoneAt = now;
        DSCall656Log(@"call screen left the front");
        // The call screen came and went: the arm has done its job. The 4 s
        // after-call hold below still applies.
        if (DSCallScreenSeenSinceArm) DSCallGuardArmedUntil = 0;
    }
}

static void DSCallGuardRefresh(CFAbsoluteTime now) {
    if (now - DSCallGuardCheckedAt <= 0.5) return;
    DSCallGuardCheckedAt = now;
    BOOL active = NO;
    BOOL front = NO;
    @try {
        front = DSReadCallScreenFront();
        active = front || DSPhoneCallIsActive();
    } @catch (NSException *exception) {
        active = NO;
    }
    DSNoteCallScreenFront(front, now);
    if (active != DSCallGuardLastActive) {
        DSCallGuardLastActive = active;
        DSCallGuardFlipAt = now;
        DSCallGuardLog(active ? @"call screen is up, staged app views hold their updates"
                              : @"call screen is gone, staged app views update again in 4 s");
    }
}

BOOL DSCallGuardActive(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    DSCallGuardRefresh(now);
    if (DSCallGuardLastActive) return YES;
    if (DSCallGuardFlipAt > 0 && now - DSCallGuardFlipAt < 4.0) return YES;
    // Armed by the staged Phone but no call screen seen yet: let the first
    // 1.5 s through (iOS's switch to the call screen), hold after that.
    return now < DSCallGuardArmedUntil && now - DSCallGuardArmedAt >= kDSCallHoldDelay;
}

void DSCallGuardNoteHeldUpdate(void) {
    DSCallHeldCount += 1;
    if (DSCallHeldCount == 1 || DSCallHeldCount % 20 == 0) {
        DSCall656Log([NSString stringWithFormat:@"held %ld staged app view update(s) during this call", (long)DSCallHeldCount]);
    }
}

void DSCallGuardNoteFrontChange(void) {
    DSCallGuardCheckedAt = 0;
    dispatch_async(dispatch_get_main_queue(), ^{
        DSCallAsideEvaluate(@"front-change");
    });
}

static void DSCallGuardArm(NSInteger source) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    DSCallGuardArmedAt = now;
    DSCallGuardArmedUntil = now + kDSCallArmSeconds;
    DSCallGuardCheckedAt = 0;
    DSCallScreenSeenSinceArm = DSCallScreenFront;
    DSCallHeldCount = 0;
    DSCallGuardLog([NSString stringWithFormat:@"staged Phone started a call (source=%ld), guard armed for 25 s", (long)source]);
    DSCall656Log([NSString stringWithFormat:@"staged Phone started a call (source=%ld): stage steps aside for the call screen, staged app view updates pass for %.1f s",
                  (long)source, kDSCallHoldDelay]);
    DSCallAsideEvaluate(@"call-key");
}

// ---- 4.5.656 step aside -----------------------------------------------------
// The stage window is level 998; the call screen is InCallService in the main
// app layout (SBMainSwitcherWindow, level 5). A visible card covered it and
// took its touches. While a call screen is coming (armed by the staged Phone)
// or is the front app, the stage windows are hidden. No scene is written, no
// card is minimized or moved, so there is nothing to assert on. When the call
// screen has gone the windows come back as they were.
BOOL DSCallStepAsideActive(void) {
    return DSCallAside;
}

static void DSCallAsideSchedule(NSInteger generation, double delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != DSCallAsideGeneration) return;
        DSCallAsideEvaluate(@"watch");
    });
}

static void DSCallAsideSet(BOOL aside, NSString *why) {
    if (aside == DSCallAside) return;
    DSCallAside = aside;
    DSCallAsideSince = CFAbsoluteTimeGetCurrent();
    @try {
        Class windowClass = objc_getClass("DSStageWindow");
        if (windowClass && [windowClass respondsToSelector:@selector(setCallAside:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(windowClass, @selector(setCallAside:), aside);
        }
    } @catch (NSException *exception) {
    }
    // The status bar and home bar go back to the system while the stage is
    // aside, and come back under the stage's rules afterwards.
    [[NSNotificationCenter defaultCenter] postNotificationName:@"DSStageStatusBarRefresh" object:nil];
    DSCall656Log(aside ? [NSString stringWithFormat:@"stage hidden so the call screen shows (%@)", why ?: @"?"]
                       : [NSString stringWithFormat:@"stage back after the call screen (%@)", why ?: @"?"]);
}

static void DSCallAsideEvaluate(NSString *why) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            DSCallAsideEvaluate(why);
        });
        return;
    }
    @try {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        DSCallGuardCheckedAt = 0;
        DSCallGuardRefresh(now);
        BOOL armed = now < DSCallGuardArmedUntil;
        BOOL waiting = armed && !DSCallScreenSeenSinceArm && now - DSCallGuardArmedAt < kDSCallAsideWaitSeconds;
        if (armed && !DSCallScreenSeenSinceArm && !waiting) {
            DSCall656Log(@"the call screen did not come to the front within 10 s");
        }
        // A short grace after the call screen leaves, so a flicker between the
        // outgoing and the connected screen does not bring the card back.
        BOOL grace = DSCallAside && DSCallScreenGoneAt > 0 && now - DSCallScreenGoneAt < 0.8;
        BOOL want = DSCallScreenFront || waiting || grace;
        if (want && !DSCallAside) {
            DSCallAsideSet(YES, DSCallScreenFront ? @"call screen in front" : why);
        } else if (!want && DSCallAside) {
            // Never in the middle of a scene update (the SIGTRAP path).
            if ([DSSceneHost sceneSettingsUpdateDepth] > 0) {
                DSCallAsideSchedule(DSCallAsideGeneration, 0.15);
                return;
            }
            DSCallAsideSet(NO, why);
        }
        if (DSCallAside || waiting) {
            NSInteger generation = ++DSCallAsideGeneration;
            DSCallAsideSchedule(generation, 0.5);
        }
    } @catch (NSException *exception) {
    }
}

static const CGFloat DSInCallRaisedLevel = 999.0; // stage window 998, keyboard host 1000

static void DSInCallRunPass(NSString *why, NSInteger generation);

// ---- logging (rate limited; never per frame) --------------------------------
static void DSInCallAppend(const char *path, const char *text) {
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    struct stat info;
    if (fstat(fd, &info) == 0 && info.st_size > 96 * 1024) ftruncate(fd, 0);
    ssize_t wrote = write(fd, text, strlen(text));
    (void)wrote;
    close(fd);
}

static void DSInCallLog(NSString *line) {
    if (line.length == 0) return;
    static NSString *last = nil;
    static CFAbsoluteTime windowStart = 0;
    static NSInteger count = 0;
    if ([last isEqualToString:line]) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - windowStart > 1.0) {
        windowStart = now;
        count = 0;
    }
    if (++count > 6) return;
    last = line;
    DSDiagnosticsRecordFormat(@"SpringBoard: incall650 %@", line);
    NSString *stamped = [NSString stringWithFormat:@"%.3f sb: incall650 %@\n", fmod(now, 100000.0), line];
    const char *text = stamped.UTF8String;
    if (!text) return;
    DSInCallAppend("/var/tmp/com.recreated.dynamicstage.phone-fit", text);
    DSInCallAppend("/var/jb/tmp/com.recreated.dynamicstage.phone-fit", text);
}

// ---- stage card -------------------------------------------------------------
static CGRect DSInCallCurrentCard(CGFloat *radius) {
    __block CGRect rect = CGRectNull;
    @try {
        DSStageManager *manager = [DSStageManager sharedManager];
        if (manager) rect = [manager stageCardScreenFrameForBundleIdentifier:DSPhoneBundle cornerRadius:radius];
    } @catch (NSException *exception) {
        rect = CGRectNull;
    }
    if (CGRectIsNull(rect) || CGRectGetWidth(rect) < 80.0 || CGRectGetHeight(rect) < 120.0) return CGRectNull;
    // 4.5.651: keep the card's inner rim band free. The call window sits above
    // the stage (999 > 998), so a call screen covering the card edge would
    // take the rim's touches; inset by the band, those reach the rim.
    rect = CGRectInset(rect, kDSRimInnerCatch, kDSRimInnerCatch);
    if (radius) *radius = MAX(0.0, *radius - kDSRimInnerCatch);
    return rect;
}

// ---- finding the InCallService scene ----------------------------------------
static NSString *DSInCallStringFrom(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) return nil;
    @try {
        id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
        if ([value isKindOfClass:NSString.class] && [(NSString *)value length] > 0) return value;
    } @catch (NSException *exception) {
    }
    return nil;
}

static id DSInCallObjectFrom(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (NSException *exception) {
        return nil;
    }
}

static id DSInCallObjectIvar(id object, const char *name) {
    if (!object) return nil;
    for (Class cls = object_getClass(object); cls && cls != UIView.class && cls != NSObject.class; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (!ivar) continue;
        const char *type = ivar_getTypeEncoding(ivar);
        if (!type || type[0] != '@') return nil;
        @try {
            return object_getIvar(object, ivar);
        } @catch (NSException *exception) {
            return nil;
        }
    }
    return nil;
}

// Scene identifier / bundle of a scene-ish view, by whatever this build has.
static NSString *DSInCallIdentifierOfView(UIView *view) {
    NSString *found = nil;
    for (NSString *name in @[ @"scene", @"presentedScene", @"hostedScene" ]) {
        id scene = DSInCallObjectFrom(view, NSSelectorFromString(name));
        found = DSInCallStringFrom(scene, @selector(identifier));
        if (found) return found;
    }
    found = DSInCallStringFrom(view, NSSelectorFromString(@"sceneIdentifier"));
    if (found) return found;
    id presenter = DSInCallObjectFrom(view, NSSelectorFromString(@"presenter"));
    id presenterScene = DSInCallObjectFrom(presenter, NSSelectorFromString(@"scene"));
    found = DSInCallStringFrom(presenterScene, @selector(identifier));
    if (found) return found;
    id handle = DSInCallObjectFrom(view, NSSelectorFromString(@"sceneHandle"));
    found = DSInCallStringFrom(handle, NSSelectorFromString(@"sceneIdentifier"));
    if (found) return found;
    id application = DSInCallObjectFrom(handle, NSSelectorFromString(@"application"));
    found = DSInCallStringFrom(application, @selector(bundleIdentifier));
    if (found) return found;
    id ivarScene = DSInCallObjectIvar(view, "_scene");
    found = DSInCallStringFrom(ivarScene, @selector(identifier));
    return found;
}

static BOOL DSInCallClassLooksLikeScene(const char *name) {
    if (!name) return NO;
    return strstr(name, "ScenePresentation") || strstr(name, "SceneLayerHost") || strstr(name, "SceneView") ||
           strstr(name, "SceneHostView") || strstr(name, "ScenePresentationView");
}

static BOOL DSInCallIdentifierIsCallUI(NSString *identifier) {
    return identifier && [identifier rangeOfString:@"InCallService" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static UIView *DSInCallFindSceneView(UIView *view, NSInteger depth, NSInteger *budget) {
    if (!view || depth > 16 || *budget <= 0) return nil;
    (*budget)--;
    if (view.hidden || view.alpha < 0.01) return nil;
    if (DSInCallClassLooksLikeScene(object_getClassName(view)) && DSInCallIdentifierIsCallUI(DSInCallIdentifierOfView(view))) {
        return view;
    }
    for (UIView *subview in view.subviews.reverseObjectEnumerator) {
        UIView *hit = DSInCallFindSceneView(subview, depth + 1, budget);
        if (hit) return hit;
    }
    return nil;
}

static NSArray<UIWindow *> *DSInCallCandidateWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    @try {
        UIApplication *application = UIApplication.sharedApplication;
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in application.connectedScenes) {
                if (![scene isKindOfClass:UIWindowScene.class]) continue;
                for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                    if (![windows containsObject:window]) [windows addObject:window];
                }
            }
        }
        for (UIWindow *window in application.windows) {
            if (![windows containsObject:window]) [windows addObject:window];
        }
    } @catch (NSException *exception) {
    }
    Class stageWindowClass = objc_getClass("DSStageWindow");
    NSMutableArray<UIWindow *> *result = [NSMutableArray array];
    for (UIWindow *window in windows) {
        if (window.hidden || window.alpha < 0.01) continue;
        if (stageWindowClass && [window isKindOfClass:stageWindowClass]) continue;
        const char *name = object_getClassName(window);
        if (name && (strstr(name, "Keyboard") || strstr(name, "TextEffects"))) continue;
        [result addObject:window];
    }
    [result sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        if (a.windowLevel == b.windowLevel) return NSOrderedSame;
        return a.windowLevel > b.windowLevel ? NSOrderedAscending : NSOrderedDescending;
    }];
    return result;
}

// The full-screen view to scale: the scene view, or its topmost ancestor
// below the window that is still screen-sized.
static UIView *DSInCallTargetFor(UIView *sceneView, UIWindow *window) {
    CGSize screen = UIScreen.mainScreen.bounds.size;
    UIView *target = sceneView;
    for (UIView *parent = sceneView.superview; parent && parent != window; parent = parent.superview) {
        CGSize size = parent.bounds.size;
        if (fabs(size.width - screen.width) > 2.0 || fabs(size.height - screen.height) > 2.0) break;
        if (parent.superview == window) {
            target = parent;
            break;
        }
        target = parent;
    }
    return target;
}

// ---- apply / restore --------------------------------------------------------
static void DSInCallRestore(NSString *why) {
    UIView *target = DSInCallTarget;
    UIWindow *window = DSInCallWindow;
    BOOL was = DSInCallContained;
    DSInCallContained = NO;
    DSInCallTarget = nil;
    DSInCallWindow = nil;
    @try {
        if (target) {
            NSValue *transform = objc_getAssociatedObject(target, DSInCallSavedTransformKey);
            if (transform) target.transform = transform.CGAffineTransformValue;
            NSNumber *radius = objc_getAssociatedObject(target, DSInCallSavedRadiusKey);
            if (radius) target.layer.cornerRadius = radius.doubleValue;
            NSNumber *masks = objc_getAssociatedObject(target, DSInCallSavedMasksKey);
            if (masks) target.layer.masksToBounds = masks.boolValue;
            objc_setAssociatedObject(target, DSInCallSavedTransformKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(target, DSInCallSavedRadiusKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(target, DSInCallSavedMasksKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (window) {
            NSNumber *level = objc_getAssociatedObject(window, DSInCallSavedLevelKey);
            if (level) window.windowLevel = level.doubleValue;
            id background = objc_getAssociatedObject(window, DSInCallSavedBackgroundKey);
            if (background) window.backgroundColor = [background isKindOfClass:UIColor.class] ? background : nil;
            objc_setAssociatedObject(window, DSInCallSavedLevelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(window, DSInCallSavedBackgroundKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    } @catch (NSException *exception) {
    }
    if (was) DSInCallLog([NSString stringWithFormat:@"restored (%@)", why ?: @"?"]);
}

static void DSInCallDisarm(NSString *why) {
    DSInCallRestore(why);
    DSInCallArmedUntil = 0;
    DSInCallGeneration++;
}

static BOOL DSInCallApply(UIView *target, UIWindow *window, CGRect card, CGFloat radius) {
    CGSize size = target.bounds.size;
    if (size.width < 50.0 || size.height < 50.0) return NO;
    CGFloat scale = MIN(CGRectGetWidth(card) / size.width, CGRectGetHeight(card) / size.height);
    if (scale <= 0.05 || scale > 1.0) return NO;
    // The target's center in window space without any transform, then the
    // translation that puts it at the card's center (window == screen space
    // for these full-screen windows).
    CGPoint center = target.center;
    if (target.superview && target.superview != window) {
        center = [target.superview convertPoint:center toView:nil];
    }
    CGPoint cardCenter = [window convertPoint:CGPointMake(CGRectGetMidX(card), CGRectGetMidY(card)) fromWindow:nil];
    CGAffineTransform transform = CGAffineTransformMake(scale, 0, 0, scale, cardCenter.x - center.x, cardCenter.y - center.y);
    if (!objc_getAssociatedObject(target, DSInCallSavedTransformKey)) {
        objc_setAssociatedObject(target, DSInCallSavedTransformKey, [NSValue valueWithCGAffineTransform:target.transform], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(target, DSInCallSavedRadiusKey, @(target.layer.cornerRadius), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(target, DSInCallSavedMasksKey, @(target.layer.masksToBounds), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!objc_getAssociatedObject(window, DSInCallSavedLevelKey)) {
        objc_setAssociatedObject(window, DSInCallSavedLevelKey, @(window.windowLevel), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(window, DSInCallSavedBackgroundKey, window.backgroundColor ?: (id)NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [UIView performWithoutAnimation:^{
        if (!CGAffineTransformEqualToTransform(target.transform, transform)) target.transform = transform;
        CGFloat wantRadius = radius > 1.0 ? radius / scale : 0.0;
        if (fabs(target.layer.cornerRadius - wantRadius) > 0.01) target.layer.cornerRadius = wantRadius;
        if (@available(iOS 13.0, *)) target.layer.cornerCurve = kCACornerCurveContinuous;
        if (!target.layer.masksToBounds) target.layer.masksToBounds = YES;
        if (window.windowLevel < DSInCallRaisedLevel) window.windowLevel = DSInCallRaisedLevel;
        if (window.backgroundColor) window.backgroundColor = nil;
    }];
    DSInCallContained = YES;
    DSInCallTarget = target;
    DSInCallWindow = window;
    DSInCallCardRect = card;
    return YES;
}

// ---- passes -----------------------------------------------------------------
static void DSInCallScheduleWatch(NSInteger generation) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != DSInCallGeneration || !DSInCallContained) return;
        DSInCallRunPass(@"watch", generation);
    });
}

static void DSInCallRunPass(NSString *why, NSInteger generation) {
    if (generation != DSInCallGeneration) return;
    @try {
        BOOL armed = CFAbsoluteTimeGetCurrent() < DSInCallArmedUntil;
        if (!armed && !DSInCallContained) return;
        // Never write while a scene update is on the stack (the SIGTRAP).
        if ([DSSceneHost sceneSettingsUpdateDepth] > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                DSInCallRunPass(why, generation);
            });
            return;
        }
        // Home / switcher swipe: hand the call screen back to the system.
        if ([DSSceneHost homeGestureIsActive]) {
            DSInCallDisarm(@"home-gesture");
            return;
        }
        CGFloat radius = 0.0;
        CGRect card = DSInCallCurrentCard(&radius);
        if (CGRectIsNull(card)) {
            DSInCallDisarm(@"card-gone");
            return;
        }
        UIWindow *window = DSInCallWindow;
        UIView *target = DSInCallTarget;
        if (DSInCallContained) {
            if (!target || !target.window || target.window.hidden || !window || window.hidden) {
                DSInCallDisarm(@"call-ui-gone");
                return;
            }
            DSInCallApply(target, window, card, radius); // follows card moves; no-op when same
            DSInCallScheduleWatch(generation);
            return;
        }
        // Not contained yet: look for the call screen.
        UIView *sceneView = nil;
        for (UIWindow *candidate in DSInCallCandidateWindows()) {
            NSInteger budget = 800;
            sceneView = DSInCallFindSceneView(candidate, 0, &budget);
            if (sceneView) {
                window = candidate;
                break;
            }
        }
        if (!sceneView) return; // a later sweep looks again
        CGRect onScreen = [sceneView convertRect:sceneView.bounds toView:nil];
        CGSize screen = UIScreen.mainScreen.bounds.size;
        if (CGRectGetHeight(onScreen) < screen.height * 0.8 || CGRectGetWidth(onScreen) < screen.width * 0.9) {
            if (!DSInCallLoggedBanner) {
                DSInCallLoggedBanner = YES;
                DSInCallLog([NSString stringWithFormat:@"call UI is not full-screen (banner %@), left alone", NSStringFromCGRect(onScreen)]);
            }
            return; // banner: system handles it; a later sweep may see it expand
        }
        if (window.windowLevel < 10.0) {
            if (!DSInCallLoggedLowLevel) {
                DSInCallLoggedLowLevel = YES;
                DSInCallLog([NSString stringWithFormat:@"call UI is in the main app layout (level %.0f %s), cannot contain it", window.windowLevel, object_getClassName(window)]);
            }
            DSInCallDisarm(@"main-layout");
            return;
        }
        target = DSInCallTargetFor(sceneView, window);
        if (DSInCallApply(target, window, card, radius)) {
            DSInCallLog([NSString stringWithFormat:@"contained source=%ld via %@ window=%s level=%.0f target=%s card=%@",
                         (long)DSInCallSource, why, object_getClassName(window), window.windowLevel,
                         object_getClassName(target), NSStringFromCGRect(card)]);
            DSInCallScheduleWatch(generation);
        }
    } @catch (NSException *exception) {
        DSInCallRestore(@"exception");
    }
}

static void DSInCallArm(NSInteger source) {
    CGRect card = DSInCallCurrentCard(NULL);
    if (CGRectIsNull(card)) {
        DSInCallLog([NSString stringWithFormat:@"signal source=%ld ignored: Phone is not in a visible stage card", (long)source]);
        return;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    CFAbsoluteTime until = now + (source == 2 ? 20.0 : 12.0);
    if (DSInCallContained || (now < DSInCallArmedUntil && until <= DSInCallArmedUntil)) {
        if (until > DSInCallArmedUntil) DSInCallArmedUntil = until;
        return; // already watching
    }
    DSInCallArmedUntil = until;
    DSInCallSource = source;
    DSInCallLoggedBanner = NO;
    DSInCallLoggedLowLevel = NO;
    NSInteger generation = ++DSInCallGeneration;
    DSInCallLog([NSString stringWithFormat:@"armed source=%ld card=%@", (long)source, NSStringFromCGRect(card)]);
    static const double sweeps[] = { 0.12, 0.3, 0.6, 1.0, 1.6, 2.4, 3.5, 5.0, 7.0, 10.0, 14.0, 19.0 };
    for (size_t i = 0; i < sizeof(sweeps) / sizeof(sweeps[0]); i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sweeps[i] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (generation != DSInCallGeneration || DSInCallContained) return;
            DSInCallRunPass(@"sweep", generation);
        });
    }
}

void DSInCallStageInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        int token = NOTIFY_TOKEN_INVALID;
        notify_register_dispatch("com.recreated.dynamicstage.phone.outgoing", &token, dispatch_get_main_queue(), ^(int t) {
            uint64_t state = 0;
            notify_get_state(t, &state);
            NSInteger source = (NSInteger)(state & 0xf);
            uint64_t posted = state >> 4;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (posted == 0 || fabs(now - (CFAbsoluteTime)posted) > 5.0) return; // stale
            if (source != 1 && source != 2) return;
            DSCallGuardArm(source);
            if (!kDSInCallContainmentEnabled) return;
            DSInCallArm(source);
        });
        DSDiagnosticsRecord(kDSInCallContainmentEnabled
                                ? @"SpringBoard: incall650 listening for calls started in the staged Phone"
                                : @"SpringBoard: call653 guard listening (call screen containment is off)");
    });
}

BOOL DSInCallWindowPassesTouch(UIView *view, CGPoint point) {
    if (!DSInCallContained) return NO;
    UIWindow *window = DSInCallWindow;
    if (!window || (UIView *)window != view) return NO;
    CGPoint screen = [window convertPoint:point toWindow:nil];
    return !CGRectContainsPoint(DSInCallCardRect, screen);
}
