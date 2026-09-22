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
// uses SpringBoard's own keyboard. A staged app keeps its text field. SpringBoard
// is only told to draw that keyboard. The stage window does not take the key.

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

// A staged app keeps its own text field. This hook reports the keyboard, and when
// that keyboard belongs to a staged app it asks SpringBoard to draw the keys.
// It does not take the key window, does not change who receives the letters, and
// does not place a keyboard scene.

static NSInteger DSHostAssignAttempts = 0;
static BOOL DSRevealedHostedKeyboard = NO;

static BOOL DSArbiterBusy = NO;

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
    for (NSString *name in @[ @"keyboardUIHandle", @"keyboardUIHandler" ]) {
        SEL selector = NSSelectorFromString(name);
        if (![arbiter respondsToSelector:selector]) continue;
        id handle = ((id (*)(id, SEL))objc_msgSend)(arbiter, selector);
        if (handle) return handle;
    }
    return nil;
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

// SpringBoard draws the keys. The staged app keeps the text field. Search is
// left alone, and this does not ask the focus coordinator for anything.
static NSString *DSAssignSpringBoardKeyboardHost(id arbiter) {
    NSString *before = DSHandlerBundle(DSKeyboardUIHandle(arbiter)) ?: @"none";
    if ([before isEqualToString:@"com.apple.springboard"]) {
        return [NSString stringWithFormat:@"keyboard ui host is already %@", before];
    }
    id springBoard = DSSpringBoardKeyboardHandler(arbiter);
    if (!springBoard) {
        return @"SpringBoard has no keyboard client, so the keys stay in the app";
    }
    SEL setHandler = @selector(setKeyboardUIHandler:);
    SEL setHandle = @selector(setKeyboardUIHandle:);
    if (![arbiter respondsToSelector:setHandler] && ![arbiter respondsToSelector:setHandle]) {
        return @"keyboard ui host setter is missing";
    }
    @try {
        if ([arbiter respondsToSelector:setHandler]) {
            ((void (*)(id, SEL, id))objc_msgSend)(arbiter, setHandler, springBoard);
        } else {
            ((void (*)(id, SEL, id))objc_msgSend)(arbiter, setHandle, springBoard);
        }
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"keyboard ui host threw %@", exception.reason ?: exception.name ?: @"?"];
    }
    NSString *after = DSHandlerBundle(DSKeyboardUIHandle(arbiter)) ?: @"none";
    return [NSString stringWithFormat:@"keyboard ui host %@ -> %@", before, after];
}

static void DSRevealHostedKeyboardLater(NSString *hostNote) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (DSAsk(^BOOL(DSStageManager *manager) { return [manager isPickerSearchActive]; })) return;
        BOOL revealed = DSRevealSpringBoardKeyboard();
        CGRect keys = DSVisibleKeyboardFrameOnScreen();
        NSString *shown = [NSString stringWithFormat:@"%@ reveal=%d keys=%@",
                           hostNote ?: @"keyboard ui host",
                           revealed,
                           CGRectIsNull(keys) ? @"none" : NSStringFromCGRect(keys)];
        DSTell(^(DSStageManager *manager) {
            [manager noteKeyboardDebugFromSpringBoard:shown];
        });
        if (revealed || !CGRectIsNull(keys)) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (DSAsk(^BOOL(DSStageManager *manager) { return [manager isPickerSearchActive]; })) return;
            BOOL again = DSRevealSpringBoardKeyboard();
            CGRect later = DSVisibleKeyboardFrameOnScreen();
            NSString *second = [NSString stringWithFormat:@"keyboard window second look reveal=%d keys=%@",
                                again,
                                CGRectIsNull(later) ? @"none" : NSStringFromCGRect(later)];
            DSTell(^(DSStageManager *manager) {
                [manager noteKeyboardDebugFromSpringBoard:second];
            });
        });
    });
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
    } @catch (NSException *exception) {
    }
    (void)handler;

    %orig;
    // Draw the keys in SpringBoard. Do not change the text field, and do not
    // place a keyboard scene. Search still owns this keyboard when it is up.
    NSString *hostNote = nil;
    if (onScreen && DSStageReady() && DSBundleIsStaged(source) &&
        !DSAsk(^BOOL(DSStageManager *manager) { return [manager isPickerSearchActive]; }) &&
        DSHostAssignAttempts < 2) {
        NSString *current = DSHandlerBundle(DSKeyboardUIHandle(self)) ?: @"none";
        if (![current isEqualToString:@"com.apple.springboard"]) {
            DSHostAssignAttempts++;
            hostNote = DSAssignSpringBoardKeyboardHost(self);
        } else if (!DSRevealedHostedKeyboard) {
            DSRevealedHostedKeyboard = YES;
            hostNote = @"keyboard ui host is already com.apple.springboard";
        }
    } else if (!onScreen) {
        DSHostAssignAttempts = 0;
        DSRevealedHostedKeyboard = NO;
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

    if (hostNote.length) {
        NSString *note = [hostNote copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            DSRevealHostedKeyboardLater(note);
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

    int keyboardApplyToken = NOTIFY_TOKEN_INVALID;
    notify_register_dispatch(kDSKeyboardApplyNotification, &keyboardApplyToken, dispatch_get_main_queue(), ^(int token) {
        uint64_t state = 0;
        notify_get_state(token, &state);
        uint32_t hash = (uint32_t)state;
        BOOL changed = (state & (1ULL << 32)) != 0;
        BOOL hadField = (state & (1ULL << 33)) != 0;
        BOOL editing = (state & (1ULL << 34)) != 0;
        BOOL hasWindow = (state & (1ULL << 35)) != 0;
        BOOL isDelete = (state & (1ULL << 36)) != 0;
        BOOL notStaged = (state & (1ULL << 37)) != 0;
        BOOL listening = (state & (1ULL << 38)) != 0;
        BOOL loaded = (state & (1ULL << 39)) != 0;
        BOOL remote = (state & (1ULL << 48)) != 0;
        NSUInteger kind = (NSUInteger)((state >> 40) & 0xff);
        NSString *className = @"none";
        if (hadField && kind == 1) className = @"field";
        else if (hadField && kind == 2) className = @"textview";
        else if (hadField && kind == 3) className = @"other";
        DSTell(^(DSStageManager *manager) {
            NSString *bundle = [manager bundleForKeyboardHash:hash];
            BOOL hosted = bundle.length > 0 && ![bundle hasPrefix:@"hash "] && ![bundle isEqualToString:@"?"];
            if (loaded || listening || remote) [manager rememberAppDylibHash:hash];
            // A loaded beacon from an app that is not on a card is only remembered.
            if (loaded && !listening && !remote && !hosted) return;
            NSString *line;
            if (remote) {
                line = [NSString stringWithFormat:@"app: %@ remote keyboard, message field stays", bundle];
            } else if (listening) {
                line = [NSString stringWithFormat:@"app: %@ is listening for staged keys", bundle];
            } else if (loaded) {
                return;
            } else if (notStaged) {
                line = [NSString stringWithFormat:@"app: key arrived in %@ while it was not staged", bundle];
            } else {
                line = [NSString stringWithFormat:@"app: key %@ -> %@ %@ fr=%d win=%d changed=%d",
                        isDelete ? @"delete" : @"insert",
                        bundle,
                        className,
                        editing,
                        hasWindow,
                        changed];
            }
            [manager noteStagedKeyResult:line];
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
