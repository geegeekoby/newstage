#import "DSStageManager.h"
#import "DSSceneHost.h"
#import "DSPreferences.h"
#import "DSGestureController.h"
#import "DSPrivate.h"
#import "DSConstants.h"
#import "DSDiagnostics.h"
#import "DSBootstrap.h"
#import "DSHomeReady.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>

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
// uses SpringBoard's own keyboard. A staged app is told to use that same
// keyboard; if SpringBoard does not present one, the app draws its own.

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

%group Arbiter

%hook _UIKeyboardArbiter

- (void)updateKeyboardStatus:(_UIKeyboardChangedInformation *)information fromHandler:(id)handler {
    %orig;
    if (!DSStageReady() || !information) return;
    @try {
        if (![information respondsToSelector:@selector(keyboardPosition)]) return;
        CGRect frame = information.keyboardPosition;
        BOOL onScreen = ![information respondsToSelector:@selector(keyboardOnScreen)] ||
                        information.keyboardOnScreen;
        NSString *source = [information respondsToSelector:@selector(sourceBundleIdentifier)]
            ? information.sourceBundleIdentifier
            : nil;

        dispatch_async(dispatch_get_main_queue(), ^{
            DSTell(^(DSStageManager *manager) {
                [manager keyboardOnScreen:onScreen frame:frame source:source];
            });
        });
    } @catch (NSException *exception) {
    }
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
