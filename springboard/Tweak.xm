#import "DSStageManager.h"
#import "DSSceneHost.h"
#import "DSPreferences.h"
#import "DSGestureController.h"
#import "DSPrivate.h"
#import "DSConstants.h"
#import "DSDiagnostics.h"
#import "DSBootstrap.h"
#import "DSHomeReady.h"
#import "DSKeyboardVisibility.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <unistd.h>

// Load order, after a reboot that then has to be jailbroken:
//
//   1. %ctor installs one SpringBoard hook (applicationDidFinishLaunching) and
//      nothing else. No scene hooks, no keyboard arbiter, no windows.
//   2. When the home screen exists, Stage + Arbiter groups are initialised.
//      That is the first moment a crash here could respring the phone, and it
//      is after icons and windows are up.
//   3. activate() builds the stage UI. If it returns, the launch guard is
//      cleared immediately.
//
// A crash between (2) and (3) completing trips the guard; the next SpringBoard
// start loads only the Boot group so the device comes back.
//
// Keyboard policy for iOS 16.5.1 on an iPhone: never steal a layer, never
// refuse _canShowKeyboardLayer, never cycle presentation modes, never dlopen
// KeyboardArbiter, never point the focus coordinator at a scene. The picker
// uses SpringBoard's own keyboard. A staged app is not allowed to draw keys;
// SpringBoard's client is forced to be the keyboard UI host.

#pragma mark - Calling out of a hook

static BOOL DSStageReady(void) {
    return !DSKillSwitchPresent() && !DSLaunchGuardTripped();
}

static BOOL DSAsk(BOOL (^question)(DSStageManager *manager)) {
    if (!DSStageReady()) return NO;
    @try {
        return question([DSStageManager sharedManager]);
    } @catch (NSException *exception) {
        return NO;
    }
}

static void DSTell(void (^action)(DSStageManager *manager)) {
    if (!DSStageReady()) return;
    @try {
        action([DSStageManager sharedManager]);
    } @catch (NSException *exception) {
    }
}

#pragma mark - Full install (after SpringBoard is up)

static void DSInstallRemainingHooks(void);

static void DSScheduleFullInstall(void) {
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        DSWhenHomeScreenIsReady(^{
            DSInstallRemainingHooks();
        });
    });
}

#pragma mark - Boot (the only group installed from %ctor)

%group Boot

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    DSScheduleFullInstall();
}

%end

%end

#pragma mark - Stage (installed after launch)

%group Stage

%hook SpringBoard

- (void)frontDisplayDidChange:(id)display {
    %orig;
    DSTell(^(DSStageManager *manager) {
        [manager noteFrontApplicationWillChange];
    });
}

%end

%hook FBScene

- (void)updateSettings:(FBSSceneSettings *)settings withTransitionContext:(id)context completion:(id)completion {
    if (!DSStageReady()) {
        %orig;
        return;
    }
    @try {
        FBSMutableSceneSettings *mutableSettings = [settings mutableCopy];
        if ([DSSceneHost applyOverridesToSettings:mutableSettings forScene:self]) {
            %orig(mutableSettings, context, completion);
            return;
        }
    } @catch (NSException *exception) {
    }
    %orig;
}

- (void)updateSettingsWithBlock:(void (^)(FBSMutableSceneSettings *settings))block {
    if (!DSStageReady() || !block) {
        %orig;
        return;
    }

    __weak __typeof(self) weakSelf = self;
    %orig(^(FBSMutableSceneSettings *settings) {
        block(settings);
        @try {
            [DSSceneHost applyOverridesToSettings:settings forScene:(FBScene *)weakSelf];
        } @catch (NSException *exception) {
        }
    });
}

%end

%hook FBSceneManager

- (void)destroyScene:(NSString *)identifier withTransitionContext:(id)context {
    if (identifier.length > 0) {
        DSTell(^(DSStageManager *manager) {
            NSString *bundleIdentifier = identifier;
            NSRange colon = [identifier rangeOfString:@":"];
            if (colon.location != NSNotFound) {
                bundleIdentifier = [identifier substringFromIndex:NSMaxRange(colon)];
            }
            NSRange dash = [bundleIdentifier rangeOfString:@"-" options:NSBackwardsSearch];
            if (dash.location != NSNotFound) {
                bundleIdentifier = [bundleIdentifier substringToIndex:dash.location];
            }
            [manager noteSceneDestroyedForBundleIdentifier:bundleIdentifier];
        });
    }
    %orig;
}

%end

%hook SBApplication

- (void)applicationProcessDidExit:(id)process withContext:(id)context {
    %orig;
    NSString *identifier = self.bundleIdentifier;
    if (identifier.length == 0) return;
    DSTell(^(DSStageManager *manager) {
        [manager noteSceneDestroyedForBundleIdentifier:identifier];
    });
}

%end

%hook SBAppViewController

- (void)sceneHandle:(id)handle didUpdateSettingsWithDiff:(id)diff previousSettings:(id)previousSettings {
    if ([DSSceneHost ownsAppViewController:self]) {
        @try {
            %orig;
        } @catch (NSException *exception) {
            DSDiagnosticsRecordFormat(@"SpringBoard: contained a scene update from the staged app (%@)",
                                      exception.reason ?: exception.name ?: @"?");
        }
        return;
    }
    %orig;
}

%end

%hook SBFluidSwitcherGestureManager

- (void)grabberTongueBeganPulling:(id)tongue
                     withDistance:(double)distance
                      andVelocity:(double)velocity
                       andGesture:(UIPanGestureRecognizer *)gesture {
    if (DSAsk(^BOOL(DSStageManager *manager) {
            return [manager adoptSystemEdgePull:gesture];
        })) {
        return;
    }
    %orig;
}

- (BOOL)shouldBeginGestureAtStartingPoint:(CGPoint)point velocity:(CGPoint)velocity bounds:(CGRect)bounds {
    if (DSAsk(^BOOL(DSStageManager *manager) {
            return [manager shouldSuppressSystemGestureAtPoint:point];
        })) {
        return NO;
    }
    return %orig;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    if (DSAsk(^BOOL(DSStageManager *manager) {
            return [manager shouldSuppressSystemGestureAtPoint:[touch locationInView:nil]];
        })) {
        return NO;
    }
    return %orig;
}

%end

%hook SBSystemGestureManager

- (BOOL)shouldBeginGestureAtStartingPoint:(CGPoint)point velocity:(CGPoint)velocity bounds:(CGRect)bounds {
    if (DSAsk(^BOOL(DSStageManager *manager) {
            return [manager shouldSuppressSystemGestureAtPoint:point];
        })) {
        return NO;
    }
    return %orig;
}

%end

%hook SBHomeGrabberView

- (void)setAlpha:(CGFloat)alpha {
    if (DSAsk(^BOOL(DSStageManager *manager) {
            return [manager shouldHideSystemHomeAffordance];
        })) {
        %orig(0.0);
        return;
    }
    %orig;
}

- (void)didMoveToWindow {
    %orig;
    if (DSAsk(^BOOL(DSStageManager *manager) {
            return [manager shouldHideSystemHomeAffordance];
        })) {
        self.alpha = 0.0;
    }
}

%end

%hook SBMainDisplaySceneManager

- (void)_applyStatusBarHidden:(BOOL)hidden withAnimation:(NSInteger)animation toSceneWithIdentifier:(NSString *)identifier {
    if (DSAsk(^BOOL(DSStageManager *manager) {
            NSString *stage = manager.stageBundleIdentifier;
            return stage.length > 0 && [identifier containsString:stage];
        })) {
        return;
    }
    %orig;
}

%end

static BOOL DSShouldForceMedusaForIdentifier(NSString *identifier) {
    if (identifier.length == 0) return NO;
    return DSAsk(^BOOL(DSStageManager *manager) {
        if (![identifier isEqualToString:manager.stageBundleIdentifier]) return NO;
        return [[DSPreferences sharedPreferences] launchTypeForApplication:identifier] == DSLaunchTypePad;
    });
}

%hook SBApplicationInfo

- (BOOL)isMedusaCapable {
    if (DSShouldForceMedusaForIdentifier([self respondsToSelector:@selector(bundleIdentifier)] ? [self bundleIdentifier] : nil)) {
        return YES;
    }
    return %orig;
}

%end

%hook FBApplicationInfo

- (BOOL)isMedusaCapable {
    if (DSShouldForceMedusaForIdentifier([self respondsToSelector:@selector(bundleIdentifier)] ? [self bundleIdentifier] : nil)) {
        return YES;
    }
    return %orig;
}

%end

%hook SBWindowScene

- (BOOL)_shouldAutorotate {
    if (DSAsk(^BOOL(DSStageManager *manager) { return manager.isStageVisible; })) return NO;
    return %orig;
}

%end

%hook SBLockScreenManager

- (BOOL)_shouldAutoLock {
    if (DSAsk(^BOOL(DSStageManager *manager) { return manager.isStageVisible; })) return NO;
    return %orig;
}

%end

%hook SBBacklightController

- (void)_setBacklightFactorForCurrentState {
    %orig;
    if (![self respondsToSelector:@selector(screenIsOn)] || [self screenIsOn]) return;
    DSTell(^(DSStageManager *manager) {
        [manager noteDisplayDidTurnOff];
    });
}

%end

%end

#pragma mark - Keyboard arbiter (optional; never dlopen'd)

// Who draws the keys is the keyboard UI host. On an iPhone that is the app, so
// the keys are composited inside the hosted scene. For a staged app the host is
// moved to SpringBoard before the arbiter applies the update, and moved back
// when that keyboard goes away. Text focus stays with the app.

static BOOL DSArbiterBusy = NO;
static id DSSavedKeyboardUIHandle = nil;
static BOOL DSKeyboardSceneRequested = NO;
static NSUInteger DSKeyboardPresentGeneration = 0;
static BOOL DSLoggedKeyboardRoute = NO;
static BOOL DSSignaledSpringBoardKeyboard = NO;

static NSString *DSHandlerBundle(id handler) {
    if (![handler respondsToSelector:@selector(bundleIdentifier)]) return nil;
    NSString *bundle = ((NSString * (*)(id, SEL))objc_msgSend)(handler, @selector(bundleIdentifier));
    return bundle.length > 0 ? [bundle copy] : nil;
}

static id DSCallHandler(id arbiter, SEL selector, id argument) {
    if (![arbiter respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(arbiter, selector, argument);
}

static id DSSpringBoardKeyboardHandler(id arbiter) {
    id springBoard = DSCallHandler(arbiter, @selector(handlerForBundleID:), @"com.apple.springboard");
    if (springBoard) return springBoard;
    SEL byPID = @selector(handlerForPID:);
    if (![arbiter respondsToSelector:byPID]) return nil;
    return ((id (*)(id, SEL, int))objc_msgSend)(arbiter, byPID, getpid());
}

static id DSKeyboardUIHandle(id arbiter) {
    SEL selector = @selector(keyboardUIHandle);
    if (![arbiter respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(arbiter, selector);
}

static void DSSetInputUIHost(id handler, BOOL host) {
    SEL selector = @selector(setInputUIHost:);
    if (![handler respondsToSelector:selector]) return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(handler, selector, host);
}

static void DSSetKeyboardUIHandle(id arbiter, id handler) {
    SEL selector = @selector(setKeyboardUIHandle:);
    if (!handler || ![arbiter respondsToSelector:selector]) return;
    ((void (*)(id, SEL, id))objc_msgSend)(arbiter, selector, handler);
}

static void DSCheckHostingState(id arbiter) {
    SEL selector = @selector(checkHostingState);
    if (![arbiter respondsToSelector:selector]) return;
    ((void (*)(id, SEL))objc_msgSend)(arbiter, selector);
}

static void DSUpdateKeyboardSceneSettings(id arbiter) {
    SEL selector = @selector(updateKeyboardSceneSettings);
    if (![arbiter respondsToSelector:selector]) return;
    ((void (*)(id, SEL))objc_msgSend)(arbiter, selector);
}

static id DSArbiterSceneLayer(id arbiter) {
    SEL selector = @selector(sceneLayer);
    if ([arbiter respondsToSelector:selector]) {
        id layer = ((id (*)(id, SEL))objc_msgSend)(arbiter, selector);
        if (layer) return layer;
    }
    id uiHandle = DSKeyboardUIHandle(arbiter);
    if ([uiHandle respondsToSelector:selector]) {
        return ((id (*)(id, SEL))objc_msgSend)(uiHandle, selector);
    }
    return nil;
}

static BOOL DSBundleIsStaged(NSString *bundle) {
    if (bundle.length == 0 || [bundle isEqualToString:@"com.apple.springboard"]) return NO;
    return DSAsk(^BOOL(DSStageManager *manager) {
        return [manager isHostingBundleIdentifier:bundle];
    });
}

static void DSRequestKeyboardSceneIfNeeded(id arbiter) {
    if (DSArbiterSceneLayer(arbiter) || DSKeyboardSceneRequested) return;
    SEL linkSelector = @selector(sceneLink);
    if (![arbiter respondsToSelector:linkSelector]) return;
    id link = ((id (*)(id, SEL))objc_msgSend)(arbiter, linkSelector);
    SEL create = @selector(createSceneWithCompletion:);
    if (![link respondsToSelector:create]) return;
    DSKeyboardSceneRequested = YES;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(link, create, ^(id scene) {
            (void)scene;
            id layer = DSArbiterSceneLayer(arbiter);
            DSUpdateKeyboardSceneSettings(arbiter);
            NSUInteger generation = DSKeyboardPresentGeneration;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != DSKeyboardPresentGeneration) return;
                if (layer) DSPresentArbiterKeyboardLayer(layer);
                DSRevealSpringBoardKeyboard();
            });
        });
    } @catch (NSException *exception) {
        DSKeyboardSceneRequested = NO;
    }
}

// YES when SpringBoard should be showing this keyboard.
static BOOL DSRouteStagedKeyboardToSpringBoard(id arbiter, id information, id handler) {
    if (!information) return NO;
    BOOL onScreen = YES;
    if ([information respondsToSelector:@selector(keyboardOnScreen)]) {
        onScreen = ((BOOL (*)(id, SEL))objc_msgSend)(information, @selector(keyboardOnScreen));
    }

    NSString *source = nil;
    if ([information respondsToSelector:@selector(sourceBundleIdentifier)]) {
        source = ((NSString * (*)(id, SEL))objc_msgSend)(information, @selector(sourceBundleIdentifier));
    }
    source = source.length > 0 ? [source copy] : nil;
    NSString *handlerBundle = DSHandlerBundle(handler);
    BOOL staged = DSBundleIsStaged(source) || DSBundleIsStaged(handlerBundle);

    if (staged && onScreen) {
        id springBoard = DSSpringBoardKeyboardHandler(arbiter);
        id appHandle = source.length > 0 ? DSCallHandler(arbiter, @selector(handlerForBundleID:), source) : nil;
        if (!appHandle && handlerBundle.length > 0 && DSBundleIsStaged(handlerBundle)) appHandle = handler;
        id current = DSKeyboardUIHandle(arbiter);
        BOOL appHostsUI = NO;
        if (appHandle && [appHandle respondsToSelector:@selector(inputUIHost)]) {
            appHostsUI = ((BOOL (*)(id, SEL))objc_msgSend)(appHandle, @selector(inputUIHost));
        }
        if (springBoard && appHandle && appHandle != springBoard && (current != springBoard || appHostsUI)) {
            if (!DSSavedKeyboardUIHandle && current && current != springBoard) {
                DSSavedKeyboardUIHandle = current;
            }
            DSSetInputUIHost(appHandle, NO);
            DSSetInputUIHost(springBoard, YES);
            if (current != springBoard) {
                DSSetKeyboardUIHandle(arbiter, springBoard);
                DSCheckHostingState(arbiter);
            }
            if (!DSLoggedKeyboardRoute) {
                DSLoggedKeyboardRoute = YES;
                NSString *logged = source.length > 0 ? source : handlerBundle;
                dispatch_async(dispatch_get_main_queue(), ^{
                    DSDiagnosticsRecordFormat(@"SpringBoard: %@ is using SpringBoard's keyboard",
                                              logged.length > 0 ? logged : @"staged app");
                });
            }
        }
        return YES;
    }

    // A keyboard from some other process must not steal the host back while a
    // staged app is still the one typing. Only the staged keyboard going away,
    // or that app leaving the stage, restores the previous host.
    NSString *savedBundle = DSHandlerBundle(DSSavedKeyboardUIHandle);
    BOOL savedStillStaged = DSBundleIsStaged(savedBundle);
    if ((staged && !onScreen) || (DSSavedKeyboardUIHandle && !savedStillStaged)) {
        if (DSSavedKeyboardUIHandle) {
            id previous = DSSavedKeyboardUIHandle;
            DSSavedKeyboardUIHandle = nil;
            DSKeyboardSceneRequested = NO;
            DSLoggedKeyboardRoute = NO;
            DSSignaledSpringBoardKeyboard = NO;
            id springBoard = DSSpringBoardKeyboardHandler(arbiter);
            if (previous != springBoard) DSSetInputUIHost(springBoard, NO);
            DSSetInputUIHost(previous, YES);
            DSSetKeyboardUIHandle(arbiter, previous);
            DSCheckHostingState(arbiter);
        }
        DSKeyboardPresentGeneration++;
        dispatch_async(dispatch_get_main_queue(), ^{
            DSPresentArbiterKeyboardLayer(nil);
        });
    } else if (!onScreen) {
        // The picker keyboard, and every other non-staged keyboard, was leaving
        // the full-screen keyboard window up after the keys had gone.
        DSKeyboardPresentGeneration++;
        dispatch_async(dispatch_get_main_queue(), ^{
            DSPresentArbiterKeyboardLayer(nil);
        });
    }
    return NO;
}

static NSString *DSKeyboardArbiterSummary(id arbiter, NSString *source, BOOL onScreen) {
    BOOL staged = DSBundleIsStaged(source);
    id springBoard = DSSpringBoardKeyboardHandler(arbiter);
    id uiHandle = DSKeyboardUIHandle(arbiter);
    NSString *uiBundle = DSHandlerBundle(uiHandle) ?: @"none";
    BOOL layer = DSArbiterSceneLayer(arbiter) != nil;
    NSString *verdict = @"app is still the keyboard host";
    if (!onScreen) verdict = @"keyboard is down";
    else if (!staged) verdict = @"this keyboard is not from a staged app";
    else if (!springBoard) verdict = @"SpringBoard has no keyboard client, so it cannot draw keys";
    else if ([uiBundle isEqualToString:@"com.apple.springboard"] && layer) verdict = @"keyboard scene exists";
    else if ([uiBundle isEqualToString:@"com.apple.springboard"]) verdict = @"SpringBoard is host but has no keyboard scene";
    return [NSString stringWithFormat:@"%@ | src=%@ on=%d staged=%d sbClient=%d uiHost=%@ layer=%d",
            verdict, source ?: @"?", onScreen, staged, springBoard != nil, uiBundle, layer];
}

%group Arbiter

%hook _UIKeyboardArbiter

- (void)updateKeyboardStatus:(_UIKeyboardChangedInformation *)information fromHandler:(id)handler {
    if (DSArbiterBusy) {
        %orig;
        return;
    }

    DSArbiterBusy = YES;
    BOOL present = NO;
    CGRect frame = CGRectZero;
    BOOL onScreen = YES;
    NSString *source = nil;
    @try {
        if (information && [information respondsToSelector:@selector(keyboardPosition)]) {
            frame = information.keyboardPosition;
        }
        if (information && [information respondsToSelector:@selector(keyboardOnScreen)]) {
            onScreen = information.keyboardOnScreen;
        }
        if (information && [information respondsToSelector:@selector(sourceBundleIdentifier)]) {
            source = [information.sourceBundleIdentifier copy];
        }
        if (DSStageReady() && information) {
            present = DSRouteStagedKeyboardToSpringBoard(self, information, handler);
        }
    } @catch (NSException *exception) {
        present = NO;
    }

    %orig;

    @try {
        if (present && DSStageReady()) {
            NSUInteger generation = ++DSKeyboardPresentGeneration;
            DSRouteStagedKeyboardToSpringBoard(self, information, handler);
            DSUpdateKeyboardSceneSettings(self);
            if (!DSSignaledSpringBoardKeyboard) {
                DSSignaledSpringBoardKeyboard = YES;
                id springBoard = DSSpringBoardKeyboardHandler(self);
                SEL signal = @selector(signalKeyboardChanged:onCompletion:);
                if ([springBoard respondsToSelector:signal]) {
                    ((void (*)(id, SEL, id, id))objc_msgSend)(springBoard, signal, information, nil);
                }
            }
            DSRequestKeyboardSceneIfNeeded(self);
            id layer = DSArbiterSceneLayer(self);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != DSKeyboardPresentGeneration) return;
                if (layer) DSPresentArbiterKeyboardLayer(layer);
                DSRevealSpringBoardKeyboard();
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (generation != DSKeyboardPresentGeneration) return;
                DSRevealSpringBoardKeyboard();
            });
        }
    } @catch (NSException *exception) {
    }
    NSString *summary = nil;
    @try {
        if (information) summary = [DSKeyboardArbiterSummary(self, source, onScreen) copy];
    } @catch (NSException *exception) {
    }
    DSArbiterBusy = NO;
    if (summary.length) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *shown = [NSString stringWithFormat:@"%@ | %@", summary, DSPresentedKeyboardWindowStatus()];
            DSTell(^(DSStageManager *manager) {
                [manager noteKeyboardDebugFromSpringBoard:shown];
            });
        });
    }

    if (!DSStageReady() || !information) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        DSTell(^(DSStageManager *manager) {
            [manager keyboardOnScreen:onScreen frame:frame source:source];
        });
    });
}

%end

%end

#pragma mark - Notifications

static void DSPreferencesChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                 const void *object, CFDictionaryRef userInfo) {
    [[DSPreferences sharedPreferences] reload];
    dispatch_async(dispatch_get_main_queue(), ^{
        DSTell(^(DSStageManager *manager) {
            [manager preferencesChanged];
        });
    });
}

static void DSRotateStage(CFNotificationCenterRef center, void *observer, CFStringRef name,
                          const void *object, CFDictionaryRef userInfo) {
    NSString *notification = (__bridge NSString *)name;
    NSInteger turns = 0;
    if ([notification hasSuffix:@".left"]) turns = -1;
    else if ([notification hasSuffix:@".right"]) turns = 1;
    dispatch_async(dispatch_get_main_queue(), ^{
        DSTell(^(DSStageManager *manager) {
            [manager rotateStageBy:turns];
        });
    });
}

static void DSCloseStage(CFNotificationCenterRef center, void *observer, CFStringRef name,
                         const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        DSTell(^(DSStageManager *manager) {
            [manager closeStageAnimated:YES];
        });
    });
}

static void DSOpenStage(CFNotificationCenterRef center, void *observer, CFStringRef name,
                        const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        DSTell(^(DSStageManager *manager) {
            [manager openStageAnimated:YES];
        });
    });
}

static void DSRegisterDarwinObservers(void) {
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(center, NULL, DSPreferencesChanged,
                                    CFSTR(kDSPreferencesChangedNotification), NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);
    CFNotificationCenterAddObserver(center, NULL, DSPreferencesChanged,
                                    CFSTR(kDSAppInfoChangedNotification), NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);
    for (NSString *suffix in @[ @".left", @".right", @".reset" ]) {
        NSString *name = [kDSRotateNotificationPrefix stringByAppendingString:suffix];
        CFNotificationCenterAddObserver(center, NULL, DSRotateStage,
                                        (__bridge CFStringRef)name, NULL,
                                        CFNotificationSuspensionBehaviorCoalesce);
    }
    CFNotificationCenterAddObserver(center, NULL, DSCloseStage,
                                    CFSTR(kDSCloseStageNotification), NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);
    CFNotificationCenterAddObserver(center, NULL, DSOpenStage,
                                    CFSTR(kDSOpenStageNotification), NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);

    int keyboardDebugToken = NOTIFY_TOKEN_INVALID;
    notify_register_dispatch(kDSKeyboardDebugNotification, &keyboardDebugToken, dispatch_get_main_queue(), ^(int token) {
        uint64_t state = 0;
        notify_get_state(token, &state);
        uint32_t hash = (uint32_t)state;
        BOOL staged = (state & kDSStageStateActiveBit) != 0;
        BOOL chrome = (state & (1ULL << 33)) != 0;
        NSUInteger hidden = (NSUInteger)((state >> 40) & 0xff);
        NSString *fallback = [NSString stringWithFormat:@"hash %u staged=%d chrome=%d hid=%lu",
                              hash, staged, chrome, (unsigned long)hidden];
        DSTell(^(DSStageManager *manager) {
            NSString *bundle = [manager bundleForKeyboardHash:hash];
            NSString *line = [bundle isEqualToString:[NSString stringWithFormat:@"hash %u", hash]]
                ? fallback
                : [NSString stringWithFormat:@"%@ staged=%d chrome=%d hid=%lu",
                   bundle, staged, chrome, (unsigned long)hidden];
            [manager noteKeyboardDebugFromApp:line];
        });
    });
}

static void DSInstallRemainingHooks(void) {
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        if (DSKillSwitchPresent()) {
            DSDiagnosticsRecord(@"SpringBoard: full hooks skipped (kill switch)");
            return;
        }
        if (!DSBootstrapBeginFullInstall()) {
            DSDiagnosticsRecord(@"SpringBoard: full hooks skipped (boot guard tripped)");
            return;
        }

        @try {
            Class fluidManager = objc_getClass("SBFluidSwitcherGestureManager");
            BOOL systemPull = fluidManager != Nil &&
                class_getInstanceMethod(fluidManager,
                                        @selector(grabberTongueBeganPulling:withDistance:andVelocity:andGesture:)) != NULL;
            [DSStageManager setSystemEdgePullAvailable:systemPull];

            DSRegisterDarwinObservers();
            %init(Stage);

            Class arbiter = objc_getClass("_UIKeyboardArbiter");
            if (arbiter && class_getInstanceMethod(arbiter, @selector(updateKeyboardStatus:fromHandler:))) {
                %init(Arbiter, _UIKeyboardArbiter = arbiter);
            }

            [[DSStageManager sharedManager] activate];
            DSBootstrapMarkLaunchSucceeded();

            DSDiagnosticsRecordFormat(@"SpringBoard: hooks installed after home screen, corner pull will come from %@",
                                      systemPull ? @"the system edge gesture" : @"a window in the corner");

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                DSTell(^(DSStageManager *manager) {
                    [manager showIntroIfNeeded];
                });
            });
        } @catch (NSException *exception) {
            DSDiagnosticsRecordFormat(@"SpringBoard: full install threw %@", exception.reason ?: exception.name ?: @"?");
        }
    });
}

%ctor {
    @autoreleasepool {
        if (DSKillSwitchPresent()) return;
        if (DSLaunchGuardTripped()) {
            DSDiagnosticsRecord(@"SpringBoard: boot guard tripped, only the launch hook is installed");
            return;
        }

        @try {
            %init(Boot);
            // If applicationDidFinishLaunching already ran (late inject) or never
            // reaches us, still come up.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(14.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                DSScheduleFullInstall();
            });
        } @catch (NSException *exception) {
        }
    }
}
