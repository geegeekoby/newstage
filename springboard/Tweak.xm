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
// KeyboardArbiter, never point the focus coordinator at a scene, never assign
// the keyboard UI host, never create a remote keyboard window. The picker
// uses SpringBoard's own keyboard. A staged app tells UIKit its keyboard is
// remote, so the keys are drawn in SpringBoard's window above the card.

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

static NSString *DSAnySceneIdentifier(id scene) {
    if (!scene) return nil;
    for (NSString *name in @[ @"identifier", @"sceneIdentifier" ]) {
        SEL selector = NSSelectorFromString(name);
        if (![scene respondsToSelector:selector]) continue;
        id value = ((id (*)(id, SEL))objc_msgSend)(scene, selector);
        if ([value isKindOfClass:NSString.class] && [(NSString *)value length] > 0) return value;
    }
    return nil;
}

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

// The hosted keyboard view is what paints the keys inside the card. Leaving it
// out keeps them on the remote-keyboard scene. This does not move that window,
// hide a view, or assign the keyboard UI host.
%hook _UIRemoteKeyboards

- (void)addHostedWindowView:(id)view fromPID:(int)pid forScene:(id)scene {
    NSString *identifier = DSAnySceneIdentifier(scene);
    BOOL staged = identifier.length > 0 && DSAsk(^BOOL(DSStageManager *manager) {
        return [manager isHostingSceneIdentifier:identifier];
    });
    if (!staged) {
        %orig;
        return;
    }
    static BOOL logged = NO;
    if (!logged) {
        logged = YES;
        NSString *viewName = view ? NSStringFromClass([view class]) : @"nil";
        DSDiagnosticsRecordFormat(@"SpringBoard: left %@ out of %@ so the keys stay on the remote keyboard",
                                  viewName, identifier);
    }
    (void)pid;
}

%end

%hook UIWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = %orig;
    if (!DSExternalKeyboardCoversStage()) return hit;
    NSString *name = NSStringFromClass(self.class);
    BOOL keyboardWindow = [name rangeOfString:@"Keyboard"].location != NSNotFound ||
                          [name rangeOfString:@"TextEffects"].location != NSNotFound;
    if (!keyboardWindow) return hit;
    if (!hit) return nil;
    CGRect keys = DSVisibleKeyboardFrameOnScreen();
    if (!CGRectIsNull(keys) && CGRectContainsPoint(keys, point)) return hit;
    return nil;
}

%end

%end

#pragma mark - Keyboard arbiter (optional; never dlopen'd)

// Search still owns its own keyboard. This hook only records what the arbiter
// said. It does not raise a window: SpringBoard's own text-effects window is
// not the staged app's keyboard. Assigning the keyboard UI host and creating
// a remote window is what took the phone to safe mode.

static NSInteger DSHostAssignAttempts = 0;
static BOOL DSArbiterBusy = NO;
static id DSSavedKeyboardUIHandle = nil;
static BOOL DSWeOwnKeyboardHost = NO;
static __weak id DSLastKeyboardArbiter = nil;

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

static void DSSetKeyboardUIHandle(id arbiter, id handle) {
    SEL setHandler = @selector(setKeyboardUIHandler:);
    SEL setHandle = @selector(setKeyboardUIHandle:);
    @try {
        if ([arbiter respondsToSelector:setHandler]) {
            ((void (*)(id, SEL, id))objc_msgSend)(arbiter, setHandler, handle);
        } else if ([arbiter respondsToSelector:setHandle]) {
            ((void (*)(id, SEL, id))objc_msgSend)(arbiter, setHandle, handle);
        }
        if ([arbiter respondsToSelector:@selector(checkHostingState)]) {
            ((void (*)(id, SEL))objc_msgSend)(arbiter, @selector(checkHostingState));
        }
    } @catch (NSException *exception) {
    }
}

static id DSLiveKeyboardArbiter(void) {
    if (DSLastKeyboardArbiter) return DSLastKeyboardArbiter;
    Class arbiterClass = objc_getClass("_UIKeyboardArbiter");
    if (!arbiterClass) return nil;
    for (NSString *name in @[ @"sharedInstance", @"sharedArbiter", @"activeArbiter" ]) {
        SEL selector = NSSelectorFromString(name);
        if (![arbiterClass respondsToSelector:selector]) continue;
        id arbiter = ((id (*)(id, SEL))objc_msgSend)(arbiterClass, selector);
        if (arbiter) return arbiter;
    }
    return nil;
}

// Hand the keyboard UI host back so Spotlight and other apps are not stuck
// drawing through SpringBoard after the stage is done.
void DSReleaseStagedKeyboardHost(void) {
    DSHidePresentedArbiterKeyboard();
    if (!DSWeOwnKeyboardHost) return;
    id arbiter = DSLiveKeyboardArbiter();
    id restore = DSSavedKeyboardUIHandle;
    DSSavedKeyboardUIHandle = nil;
    DSWeOwnKeyboardHost = NO;
    DSHostAssignAttempts = 0;
    if (arbiter) DSSetKeyboardUIHandle(arbiter, restore);
}

static NSString *DSKeyboardArbiterSummary(id arbiter, NSString *source, BOOL onScreen) {
    BOOL staged = DSBundleIsStaged(source);
    id springBoard = DSSpringBoardKeyboardHandler(arbiter);
    id uiHandle = DSKeyboardUIHandle(arbiter);
    NSString *uiBundle = DSHandlerBundle(uiHandle) ?: @"none";
    BOOL layer = DSArbiterSceneLayer(arbiter) != nil;
    NSString *verdict = @"hosted app is drawing its own keyboard";
    if (!onScreen) verdict = @"keyboard is down";
    else if (!staged) verdict = @"this keyboard is not from a staged app";
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
    DSLastKeyboardArbiter = self;
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

    NSString *hostNote = nil;
    BOOL releaseHost = NO;
    if (!onScreen && (DSBundleIsStaged(source) || DSWeOwnKeyboardHost)) {
        releaseHost = YES;
        DSHostAssignAttempts = 0;
    } else if (!onScreen) {
        DSHostAssignAttempts = 0;
    }

    NSString *summary = nil;
    @try {
        if (information) summary = [DSKeyboardArbiterSummary(self, source, onScreen) copy];
    } @catch (NSException *exception) {
    }
    DSArbiterBusy = NO;

    if (hostNote.length || summary.length || releaseHost) {
        NSString *hostCopy = [hostNote copy];
        NSString *summaryCopy = [summary copy];
        BOOL release = releaseHost;
        BOOL keyboardDown = !onScreen;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (keyboardDown) {
                DSRestoreRemoteKeyboardPlacement();
            }
            if (release) {
                DSReleaseStagedKeyboardHost();
            }
            if (hostCopy.length) {
                DSTell(^(DSStageManager *manager) {
                    [manager noteKeyboardDebugFromSpringBoard:hostCopy];
                });
            }
            if (summaryCopy.length) {
                NSString *shown = [NSString stringWithFormat:@"%@ | %@", summaryCopy, DSPresentedKeyboardWindowStatus()];
                DSTell(^(DSStageManager *manager) {
                    [manager noteKeyboardDebugFromSpringBoard:shown];
                });
            }
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
        BOOL mapped = (state & (1ULL << 49)) != 0;
        BOOL remoteSkipped = (state & (1ULL << 50)) != 0;
        BOOL remoteArmed = (state & (1ULL << 51)) != 0;
        NSUInteger remotePath = (NSUInteger)((state >> 52) & 0xf);
        NSUInteger ctorReason = (NSUInteger)((state >> 56) & 0xf);
        NSUInteger kind = (NSUInteger)((state >> 40) & 0xff);
        NSString *className = @"none";
        if (hadField && kind == 1) className = @"field";
        else if (hadField && kind == 2) className = @"textview";
        else if (hadField && kind == 3) className = @"other";
        NSString *reasonName = @"other";
        switch (ctorReason) {
            case 0: reasonName = @"ok"; break;
            case 1: reasonName = @"kill"; break;
            case 2: reasonName = @"bundle"; break;
            case 3: reasonName = @"excluded"; break;
            case 4: reasonName = @"not-user"; break;
            case 5: reasonName = @"prefs"; break;
            case 6: reasonName = @"threw"; break;
            default: break;
        }
        DSTell(^(DSStageManager *manager) {
            NSString *bundle = [manager bundleForKeyboardHash:hash];
            [manager noteAppDylibSignal:hash listening:listening loaded:loaded remote:remote];
            NSString *pathName = @"?";
            switch (remotePath) {
                case 1: pathName = @"window-class"; break;
                case 2: pathName = @"unassociated-scene"; break;
                case 3: pathName = @"clear-scene"; break;
                case 4: pathName = @"skip-hosted-view"; break;
                case 6: pathName = @"input-set"; break;
                case 8: pathName = @"impl"; break;
                case 15: pathName = @"class-missing"; break;
                default: break;
            }
            NSString *line;
            if (remote) {
                line = [NSString stringWithFormat:@"app: %@ remote keyboard via %@, message field stays", bundle, pathName];
            } else if (remotePath == 15) {
                line = [NSString stringWithFormat:@"app: %@ remote keyboard class is missing", bundle];
            } else if (remoteSkipped) {
                line = [NSString stringWithFormat:@"app: %@ keyboard hook %@ ran but the app was not staged", bundle, pathName];
            } else if (remoteArmed) {
                line = [NSString stringWithFormat:@"app: %@ remote keyboard hooks are in", bundle];
            } else if (loaded && ctorReason != 0) {
                line = [NSString stringWithFormat:@"app: %@ ctor bailed reason=%@", bundle, reasonName];
            } else if (loaded) {
                line = [NSString stringWithFormat:@"app: %@ ctor ok", bundle];
            } else if (mapped) {
                line = @"app: dylib image mapped, ctor did not finish";
            } else if (listening) {
                line = [NSString stringWithFormat:@"app: %@ is listening for staged keys", bundle];
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

            NSString *libsPath = @"/var/jb/Library/MobileSubstrate/DynamicLibraries/DynamicStageApp.dylib";
            NSString *injectDir = @"/var/jb/usr/lib/TweakInject";
            NSString *injectPath = [injectDir stringByAppendingPathComponent:@"DynamicStageApp.dylib"];
            NSString *injectPlist = [injectDir stringByAppendingPathComponent:@"DynamicStageApp.plist"];
            NSString *payloadDylib = @"/var/jb/Library/Application Support/DynamicStage/DynamicStageApp.dylib";
            NSFileManager *files = NSFileManager.defaultManager;
            BOOL libs = [files fileExistsAtPath:libsPath];
            BOOL payload = [files fileExistsAtPath:payloadDylib];
            BOOL tweakInject = [files fileExistsAtPath:injectDir];
            BOOL tweakLink = NO;
            {
                char link[512];
                ssize_t n = readlink(injectDir.fileSystemRepresentation, link, sizeof(link) - 1);
                if (n > 0) tweakLink = YES;
            }
            BOOL injectDylib = [files fileExistsAtPath:injectPath];
            BOOL injectPlistOn = [files fileExistsAtPath:injectPlist];
            // SpringBoard runs as mobile and must not overwrite TweakInject.
            // A failed remove+copy left the filter missing and was taking the
            // phone to safe mode. postinst (root) is the only writer.
            NSArray *libNames = [files contentsOfDirectoryAtPath:@"/var/jb/Library/MobileSubstrate/DynamicLibraries" error:nil] ?: @[];
            DSDiagnosticsRecordFormat(@"SpringBoard: app dylib libs=%d tweakinject=%d link=%d injectdylib=%d injectplist=%d payload=%d files=%@",
                                      libs, tweakInject, tweakLink, injectDylib, injectPlistOn, payload,
                                      [libNames componentsJoinedByString:@","]);
            DSLogStagedAppInjection(@"filter at boot");

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
