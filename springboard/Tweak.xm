#import "DSCameraArbiter.h"
#import "DSStageManager.h"
#import "DSSceneHost.h"
#import "DSPreferences.h"
#import "DSGestureController.h"
#import "DSPrivate.h"
#import "DSConstants.h"
#import "DSDiagnostics.h"
#import "DSCrashLog.h"
#import "DSBootstrap.h"
#import "DSHomeReady.h"
#import "DSKeyboardVisibility.h"
#import "DSStageLayout.h"
#import "DSStageContainerView.h"
#import "DSInCallStage.h"
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
//   3. activate() builds the stage UI. The launch guard stays raised for
//      several seconds after that returns. A crash or a watchdog kill in
//      that window leaves the guard raised, so the next SpringBoard start
//      loads no stage hooks and the phone stays up.
//
// A crash between (2) and the guard being cleared trips it; the next
// SpringBoard start loads only the Boot group so the device comes back.
//
// Keyboard policy for iOS 16.5.1 on an iPhone: never steal a layer, never
// refuse _canShowKeyboardLayer, never cycle presentation modes, never dlopen
// KeyboardArbiter, never point the focus coordinator at a scene, never assign
// the keyboard UI host, never create a remote keyboard window. The picker
// uses SpringBoard's own keyboard. A staged app tells UIKit its keyboard is
// remote, so the keys are drawn in SpringBoard's window above the card.

#pragma mark - Calling out of a hook

// BeginFullInstall raises the on-disk guard before activate() returns. This
// launch is allowed to run the stage. The next launch is not, unless the
// delayed success mark clears that file. Checking the file here would switch
// the stage off for the whole success window.
static BOOL DSFullInstallLive = NO;

static BOOL DSStageReady(void) {
    return !DSKillSwitchPresent() && DSFullInstallLive;
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

// The app switcher updates every card's scene on each frame. Copying those
// settings, and logging them, is what makes that scroll hitch. Only a scene
// the stage is actually hosting needs the override path.
static BOOL DSSceneUpdateMatters(NSString *identifier) {
    if (!DSStageReady() || identifier.length == 0) return NO;
    @try {
        if ([[DSStageManager sharedManager] isHostingSceneIdentifier:identifier]) return YES;
    } @catch (NSException *exception) {
        return NO;
    }
    return [DSSceneHost sceneIdentifierHasOverride:identifier];
}

static BOOL DSSceneTraceAllowed(void) {
    static CFAbsoluteTime last = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - last < 0.5) return NO;
    last = now;
    return YES;
}

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
    DSCallGuardNoteFrontChange();
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
    // The home transition updates every foreground scene. Applying that to an
    // app the stage still hosts is the SIGTRAP. Leave the scene as it is and
    // tell SpringBoard the update finished. A minimized app is the same case
    // when another app is opened from the Home Screen.
    NSString *incomingIdentifier = [self respondsToSelector:@selector(identifier)] ? self.identifier : nil;
    if (!DSSceneUpdateMatters(incomingIdentifier)) {
        %orig;
        return;
    }
    // Opening a normal app stretches this scene to the phone and backgrounds
    // it. That blacks the card and paints the app outside it. An on-screen
    // stage keeps the size and foreground it already has.
    if (incomingIdentifier.length > 0 &&
        ![DSSceneHost homeGestureIsActive] &&
        ![DSSceneHost sceneIdentifierStaysBackgrounded:incomingIdentifier] &&
        DSAsk(^BOOL(DSStageManager *manager) {
            return [manager isHostingSceneIdentifier:incomingIdentifier];
        })) {
        CGRect incomingFrame = CGRectZero;
        @try {
            incomingFrame = settings.frame;
        } @catch (NSException *exception) {
        }
        CGRect screen = UIScreen.mainScreen.bounds;
        BOOL phoneSized = CGRectGetWidth(incomingFrame) > CGRectGetWidth(screen) - 30.0 &&
                          CGRectGetHeight(incomingFrame) > CGRectGetHeight(screen) * 0.7;
        // Opening another app stretches this scene back to the phone. That is
        // the update to refuse. The tall split size is also this big, and the
        // stage just asked for it. Refusing that one leaves the app at the
        // half height, which is the black band under the old picture.
        if (phoneSized &&
            [DSSceneHost stageRequestedFrame:incomingFrame forSceneIdentifier:incomingIdentifier]) {
            phoneSized = NO;
        }
        // Split just handed this app the phone. The full-screen frame has to
        // land. Refusing it leaves the scene at the split size.
        if (phoneSized && [DSSceneHost isHandingOffSceneIdentifier:incomingIdentifier]) {
            phoneSized = NO;
        }
        // A card-sized update has to land even when its foreground flag reads
        // off, or the app stays phone-sized and the card cuts off the bottom
        // of the chat.
        if (phoneSized) {
            static CFAbsoluteTime DSLastKeptCardLog = 0;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - DSLastKeptCardLog > 1.0) {
                DSLastKeptCardLog = now;
                DSDiagnosticsRecord(@"SpringBoard: kept the open stage inside its card while another app opened");
            }
            NSString *kept = [incomingIdentifier copy];
            dispatch_async(dispatch_get_main_queue(), ^{
                DSTell(^(DSStageManager *manager) {
                    [manager keepOnScreenStageInsideCardForSceneIdentifier:kept];
                });
            });
            if (completion) {
                void (^done)(BOOL) = (void (^)(BOOL))completion;
                done(YES);
            }
            return;
        }
    }
    if ([DSSceneHost homeGestureIsActive] ||
        [DSSceneHost sceneIdentifierStaysBackgrounded:([self respondsToSelector:@selector(identifier)] ? self.identifier : nil)]) {
        NSString *identifier = [self respondsToSelector:@selector(identifier)] ? self.identifier : nil;
        BOOL hosted = [DSSceneHost sceneIdentifierStaysBackgrounded:identifier] || DSAsk(^BOOL(DSStageManager *manager) {
            return [manager isHostingSceneIdentifier:identifier];
        });
        if (hosted) {
            static CFAbsoluteTime DSLastHeldSettingsLog = 0;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - DSLastHeldSettingsLog > 1.0) {
                DSLastHeldSettingsLog = now;
                DSDiagnosticsRecord(@"SpringBoard: held a minimized stage scene update so another app can open");
            }
            if (completion) {
                void (^done)(BOOL) = (void (^)(BOOL))completion;
                done(YES);
            }
            return;
        }
    }
    // A video updates its scene constantly. Snapshotting or laying out the
    // card from inside this call updates the scene again, and that re-entry
    // is an assertion. A Messages conversation push is the same shape: the
    // presentation lays out before this call returns.
    [DSSceneHost beginSceneSettingsUpdate];
    NSString *traceIdentifier = [self respondsToSelector:@selector(identifier)] ? self.identifier : nil;
    CGRect traceFrame = CGRectZero;
    BOOL traceForegroundKnown = NO;
    BOOL traceForeground = [DSSceneHost readForegroundFlag:settings known:&traceForegroundKnown];
    @try {
        traceFrame = settings.frame;
    } @catch (NSException *exception) {
    }
    BOOL traceHosted = DSAsk(^BOOL(DSStageManager *manager) {
        return [manager isHostingSceneIdentifier:traceIdentifier];
    });
    BOOL traceCare = traceHosted ||
        [traceIdentifier rangeOfString:@"MobileSMS"].location != NSNotFound ||
        [traceIdentifier rangeOfString:@"keyboard" options:NSCaseInsensitiveSearch].location != NSNotFound;
    if (traceCare && DSSceneTraceAllowed()) {
        DSTraceFormat(@"scene update begin %@ fg=%d depth=%ld frame=%@",
                      traceIdentifier ?: @"?",
                      traceForegroundKnown ? traceForeground : -1,
                      (long)[DSSceneHost sceneSettingsUpdateDepth],
                      NSStringFromCGRect(traceFrame));
    }
    BOOL keepFront = traceHosted &&
        ![DSSceneHost homeGestureIsActive] &&
        ![DSSceneHost sceneIdentifierStaysBackgrounded:traceIdentifier];
    @try {
        if ([DSSceneHost sceneSettingsUpdateDepth] > 1) {
            FBSMutableSceneSettings *mutableSettings = keepFront ? [settings mutableCopy] : nil;
            if (mutableSettings) {
                [DSSceneHost applyOverridesToSettings:mutableSettings forScene:self];
                [DSSceneHost keepCommittedForegroundOfScene:self onSettings:mutableSettings];
                %orig(mutableSettings, context, completion);
            } else {
                %orig;
            }
            return;
        }
        @try {
            NSString *identifier = [self respondsToSelector:@selector(identifier)] ? self.identifier : nil;
            BOOL hosted = DSAsk(^BOOL(DSStageManager *manager) {
                return [manager isHostingSceneIdentifier:identifier];
            });
            if (hosted) {
                // 4.5.652: the hosted scene's foreground state, logged on change.
                [DSCameraArbiter noteHostedSceneSettings:settings identifier:identifier];
                BOOL known = NO;
                BOOL foreground = [DSSceneHost readForegroundFlag:settings known:&known];
                NSString *identCopy = [identifier copy];
                BOOL covered = known && !foreground;
                // 4.5.650 (switcher lag): only a change of covered, or at
                // most twice a second, and nothing while the home / switcher
                // transition runs (that path returned early anyway).
                static NSMutableDictionary<NSString *, NSNumber *> *lastCovered = nil;
                static NSMutableDictionary<NSString *, NSNumber *> *lastSent = nil;
                if (!lastCovered) {
                    lastCovered = [NSMutableDictionary dictionary];
                    lastSent = [NSMutableDictionary dictionary];
                }
                NSString *coverKey = identCopy ?: @"?";
                NSNumber *previous = lastCovered[coverKey];
                CFAbsoluteTime nowSent = CFAbsoluteTimeGetCurrent();
                BOOL coverChanged = !previous || previous.boolValue != covered;
                BOOL due = nowSent - [lastSent[coverKey] doubleValue] >= 0.5;
                if (coverChanged || (due && ![DSSceneHost systemTransitionBusy])) {
                    lastCovered[coverKey] = @(covered);
                    lastSent[coverKey] = @(nowSent);
                    if (lastCovered.count > 16) {
                        [lastCovered removeAllObjects];
                        [lastSent removeAllObjects];
                    }
                    dispatch_async(dispatch_get_main_queue(), ^{
                        DSTell(^(DSStageManager *manager) {
                            [manager noteHostedSceneIdentifier:identCopy covered:covered];
                        });
                    });
                }
            }
        } @catch (NSException *exception) {
        }
        @try {
            FBSMutableSceneSettings *mutableSettings = [settings mutableCopy];
            BOOL overridden = mutableSettings && [DSSceneHost applyOverridesToSettings:mutableSettings forScene:self];
            if (mutableSettings && keepFront) {
                [DSSceneHost keepCommittedForegroundOfScene:self onSettings:mutableSettings];
                overridden = YES;
            }
            if (overridden) {
                %orig(mutableSettings, context, completion);
                return;
            }
        } @catch (NSException *exception) {
        }
        %orig;
    } @finally {
        if (traceCare && DSSceneTraceAllowed()) {
            DSTraceFormat(@"scene update end %@ depth=%ld",
                          traceIdentifier ?: @"?",
                          (long)[DSSceneHost sceneSettingsUpdateDepth]);
        }
        [DSSceneHost endSceneSettingsUpdate];
    }
}

- (void)updateSettingsWithBlock:(void (^)(FBSMutableSceneSettings *settings))block {
    if (!DSStageReady() || !block) {
        %orig;
        return;
    }
    NSString *incomingIdentifier = [self respondsToSelector:@selector(identifier)] ? self.identifier : nil;
    if (!DSSceneUpdateMatters(incomingIdentifier)) {
        %orig;
        return;
    }
    // Same hold as updateSettings:withTransitionContext:. Applying a home /
    // minimized update to a hosted stage scene is the SIGTRAP. Do not %orig.
    if ([DSSceneHost homeGestureIsActive] ||
        [DSSceneHost sceneIdentifierStaysBackgrounded:incomingIdentifier]) {
        BOOL hosted = [DSSceneHost sceneIdentifierStaysBackgrounded:incomingIdentifier] || DSAsk(^BOOL(DSStageManager *manager) {
            return [manager isHostingSceneIdentifier:incomingIdentifier];
        });
        if (hosted) {
            static CFAbsoluteTime DSLastHeldBlockLog = 0;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - DSLastHeldBlockLog > 1.0) {
                DSLastHeldBlockLog = now;
                DSDiagnosticsRecord(@"SpringBoard: held a minimized stage scene update so another app can open");
            }
            return;
        }
    }

    __weak __typeof(self) weakSelf = self;
    [DSSceneHost beginSceneSettingsUpdate];
    @try {
        %orig(^(FBSMutableSceneSettings *settings) {
            FBScene *scene = (FBScene *)weakSelf;
            NSString *identifier = [scene respondsToSelector:@selector(identifier)] ? scene.identifier : nil;
            BOOL hosted = DSAsk(^BOOL(DSStageManager *manager) {
                return [manager isHostingSceneIdentifier:identifier];
            });
            if ((hosted || [identifier rangeOfString:@"MobileSMS"].location != NSNotFound) &&
                DSSceneTraceAllowed()) {
                DSTraceFormat(@"scene block %@ frame=%@", identifier ?: @"?", NSStringFromCGRect(settings.frame));
            }
            block(settings);
            @try {
                [DSSceneHost applyOverridesToSettings:settings forScene:(FBScene *)weakSelf];
                // Foreground stays whatever the scene already committed. Writing
                // YES here is a change the live app view rejects, and that
                // rejection used to take the card size down with it.
                if (hosted && ![DSSceneHost sceneIdentifierStaysBackgrounded:identifier]) {
                    [DSSceneHost keepCommittedForegroundOfScene:scene onSettings:settings];
                }
                // Kept-card path parity: if the block stretched a hosted on-screen
                // stage to phone size, put the card frame back and refit after
                // this update returns (never start another write here).
                if (hosted &&
                    ![DSSceneHost homeGestureIsActive] &&
                    ![DSSceneHost sceneIdentifierStaysBackgrounded:identifier]) {
                    CGRect after = CGRectZero;
                    @try { after = settings.frame; } @catch (NSException *e) {}
                    CGRect screen = UIScreen.mainScreen.bounds;
                    BOOL phoneSized = CGRectGetWidth(after) > CGRectGetWidth(screen) - 30.0 &&
                                      CGRectGetHeight(after) > CGRectGetHeight(screen) * 0.7;
                    if (phoneSized &&
                        ![DSSceneHost stageRequestedFrame:after forSceneIdentifier:identifier] &&
                        ![DSSceneHost isHandingOffSceneIdentifier:identifier]) {
                        static CFAbsoluteTime DSLastKeptBlockLog = 0;
                        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                        if (now - DSLastKeptBlockLog > 1.0) {
                            DSLastKeptBlockLog = now;
                            DSDiagnosticsRecord(@"SpringBoard: kept the open stage inside its card while another app opened");
                        }
                        NSString *kept = [identifier copy];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            DSTell(^(DSStageManager *manager) {
                                [manager keepOnScreenStageInsideCardForSceneIdentifier:kept];
                            });
                        });
                    }
                }
            } @catch (NSException *exception) {
            }
        });
    } @finally {
        [DSSceneHost endSceneSettingsUpdate];
    }
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
        static CFAbsoluteTime DSLastAppViewTrace = 0;
        CFAbsoluteTime traceNow = CFAbsoluteTimeGetCurrent();
        BOOL traceThis = traceNow - DSLastAppViewTrace > 1.0;
        if (traceThis) {
            DSLastAppViewTrace = traceNow;
            DSTrace(@"app-view settings update");
        }
        // SIGTRAP, not an exception: the home transition updates this host and
        // the original method asserts. Holding the update is what keeps
        // SpringBoard alive. The scene itself still changes underneath.
        if ([DSSceneHost homeGestureIsActive] || [DSSceneHost appViewControllerStaysBackgrounded:self]) {
            static CFAbsoluteTime DSLastHeldSceneLog = 0;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - DSLastHeldSceneLog > 1.0) {
                DSLastHeldSceneLog = now;
                DSDiagnosticsRecord(@"SpringBoard: held a minimized app view update so another app can open");
            }
            return;
        }
        // 4.5.653: a phone call. The call screen comes up as the main-layout
        // app and SpringBoard re-describes the hosted scene; this original
        // method then asserted (SIGTRAP, the safe mode when calling from the
        // staged Phone). Held the same way as the home gesture: the scene
        // still changes underneath and the app view stays Live, which is
        // what it is again once the call screen has gone.
        if (DSCallGuardActive()) {
            static CFAbsoluteTime DSLastCallHoldLog = 0;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - DSLastCallHoldLog > 2.0) {
                DSLastCallHoldLog = now;
                NSString *text = [diff description] ?: @"";
                text = [[text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];
                if (text.length > 240) text = [text substringToIndex:240];
                DSDiagnosticsRecordFormat(@"SpringBoard: call653 held a staged app view update during a call: %@", text);
            }
            return;
        }
        // The app view is already Live. Letting it apply a foreground change
        // throws "out from underneath us" and the card goes black.
        NSInteger displayMode = -1;
        if ([self respondsToSelector:@selector(displayMode)]) {
            displayMode = ((NSInteger (*)(id, SEL))objc_msgSend)(self, @selector(displayMode));
        }
        // 4.5.650: describing the diff (a large string) on every update was
        // per-frame work during the switcher; only the Live mode needs it.
        NSString *diffText = displayMode == 4 ? ([diff description] ?: @"") : @"";
        if (displayMode == 4 &&
            [diffText rangeOfString:@"foreground" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            static CFAbsoluteTime DSLastLiveLog = 0;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - DSLastLiveLog > 1.0) {
                DSLastLiveLog = now;
                DSDiagnosticsRecord(@"SpringBoard: left the live scene alone so a foreground change does not black the card");
            }
            return;
        }
        @try {
            %orig;
        } @catch (NSException *exception) {
            DSDiagnosticsRecordFormat(@"SpringBoard: contained a scene update from the staged app (%@)",
                                      exception.reason ?: exception.name ?: @"?");
        }
        if (traceThis) DSTrace(@"app-view settings update done");
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
    DSTell(^(DSStageManager *manager) {
        [manager noteHomeGestureBegan:gesture];
    });
    %orig;
}

- (BOOL)shouldBeginGestureAtStartingPoint:(CGPoint)point velocity:(CGPoint)velocity bounds:(CGRect)bounds {
    if (DSAsk(^BOOL(DSStageManager *manager) {
            return [manager shouldSuppressSystemGestureAtPoint:point velocity:velocity];
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
            return [manager shouldSuppressSystemGestureAtPoint:point velocity:velocity];
        })) {
        return NO;
    }
    return %orig;
}

%end

static NSInteger DSGrabberFrameDepth = 0;
static const void *DSGrabberHiddenByStageKey = &DSGrabberHiddenByStageKey;

// The pill follows the bottom of whatever scene is in front. A stage card is
// that scene, so the pill was sitting on the card. It belongs on the phone.
static CGRect DSPinnedHomeGrabberFrame(UIView *view, CGRect frame) {
    if (CGRectGetHeight(frame) < 8.0 || CGRectGetHeight(frame) > 80.0) return frame;
    UIView *superview = view.superview;
    if (!superview) return frame;
    CGRect screen = UIScreen.mainScreen.bounds;
    CGRect onScreen = [superview convertRect:frame toView:nil];
    if (CGRectGetHeight(onScreen) < 8.0 || CGRectGetHeight(onScreen) > 80.0) return frame;
    if (CGRectGetMaxY(onScreen) >= CGRectGetMaxY(screen) - 20.0) return frame;
    onScreen.origin.y = CGRectGetMaxY(screen) - CGRectGetHeight(onScreen);
    return [superview convertRect:onScreen fromView:nil];
}

// A short superview clips a pill we try to park at the phone's bottom, which
// leaves it painted on the card. Hide that one. A screen-sized superview can
// hold the pill at the real bottom.
static BOOL DSGrabberWouldBeClipped(UIView *view, CGRect frame) {
    UIView *superview = view.superview;
    if (!superview) return NO;
    CGFloat screenHeight = CGRectGetHeight(UIScreen.mainScreen.bounds);
    if (CGRectGetHeight(superview.bounds) >= screenHeight - 40.0) return NO;
    return CGRectGetMaxY(frame) > CGRectGetHeight(superview.bounds) + 4.0 ||
           CGRectGetMinY(frame) < -4.0;
}

static void DSNoteGrabberHidden(UIView *view, BOOL hidden) {
    objc_setAssociatedObject(view, DSGrabberHiddenByStageKey, hidden ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Each app card in the system switcher has its own home pill, and that pill
// moves with the card every frame. Pinning those pills to the bottom of the
// phone fights that animation. Only the stage's own card needs it.
static BOOL DSSystemSwitcherIsVisible(void) {
    Class controllerClass = objc_getClass("SBMainSwitcherController");
    if (!controllerClass || ![controllerClass respondsToSelector:@selector(sharedInstance)]) return NO;
    id controller = ((id (*)(id, SEL))objc_msgSend)(controllerClass, @selector(sharedInstance));
    SEL visible = @selector(isMainSwitcherVisible);
    if (![controller respondsToSelector:visible]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(controller, visible);
}

static BOOL DSStageShouldMoveHomeGrabber(void) {
    if (!DSStageReady()) return NO;
    if ([DSSceneHost homeGestureIsActive]) return NO;
    BOOL visible = NO;
    @try {
        visible = [DSStageManager sharedManager].isStageVisible;
    } @catch (NSException *exception) {
        return NO;
    }
    if (!visible) return NO;
    return !DSSystemSwitcherIsVisible();
}

%hook SBHomeGrabberView

- (void)setFrame:(CGRect)frame {
    if (DSGrabberFrameDepth == 0 && DSStageShouldMoveHomeGrabber()) {
        frame = DSPinnedHomeGrabberFrame(self, frame);
    }
    DSGrabberFrameDepth += 1;
    %orig(frame);
    DSGrabberFrameDepth -= 1;
}

- (void)layoutSubviews {
    %orig;
    if (!DSStageShouldMoveHomeGrabber()) return;
    if (DSGrabberFrameDepth > 0) return;
    CGRect fixed = DSPinnedHomeGrabberFrame(self, self.frame);
    BOOL clipped = DSGrabberWouldBeClipped(self, fixed);
    BOOL hide = clipped || DSAsk(^BOOL(DSStageManager *manager) {
        return [manager shouldHideSystemHomeAffordance];
    });
    if (hide) {
        if (self.alpha > 0.01) DSNoteGrabberHidden(self, YES);
        self.alpha = 0.0;
        self.userInteractionEnabled = NO;
        return;
    }
    if ([objc_getAssociatedObject(self, DSGrabberHiddenByStageKey) boolValue]) {
        DSNoteGrabberHidden(self, NO);
        self.alpha = 1.0;
        self.userInteractionEnabled = YES;
    }
    if (!CGRectEqualToRect(fixed, self.frame)) self.frame = fixed;
}

- (void)setAlpha:(CGFloat)alpha {
    if (DSStageShouldMoveHomeGrabber() && DSAsk(^BOOL(DSStageManager *manager) {
            return [manager shouldHideSystemHomeAffordance];
        })) {
        %orig(0.0);
        return;
    }
    %orig;
}

- (void)didMoveToWindow {
    %orig;
    if (DSStageShouldMoveHomeGrabber() && DSAsk(^BOOL(DSStageManager *manager) {
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

// 4.5.416 left this view out of every staged app so the keys stayed on the
// remote keyboard, which is then raised above the stage. Messages still gets
// the view, because that is the keyboard that is already working.
%hook _UIRemoteKeyboards

- (void)addHostedWindowView:(id)view fromPID:(int)pid forScene:(id)scene {
    NSString *identifier = DSAnySceneIdentifier(scene);
    BOOL staged = identifier.length > 0 && DSAsk(^BOOL(DSStageManager *manager) {
        return [manager isHostingSceneIdentifier:identifier];
    });
    BOOL messages = [identifier rangeOfString:@"MobileSMS"].location != NSNotFound;
    if (!staged || messages) {
        %orig;
        return;
    }
    static NSString *loggedIdentifier = nil;
    if (identifier.length && ![loggedIdentifier isEqualToString:identifier]) {
        loggedIdentifier = [identifier copy];
        NSString *viewName = view ? NSStringFromClass([view class]) : @"nil";
        DSDiagnosticsRecordFormat(@"SpringBoard: left %@ out of %@ so the keys stay on the raised keyboard",
                                  viewName, identifier);
    }
    (void)pid;
}

%end

static void DSForwardHostedKeyboardText(NSString *text, BOOL isDelete) {
    if (!isDelete && text.length == 0) return;
    static NSString *lastMark = nil;
    static CFAbsoluteTime lastAt = 0;
    NSString *mark = isDelete ? @"\b" : text;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (lastMark && [lastMark isEqualToString:mark] && (now - lastAt) < 0.03) return;
    lastMark = [mark copy];
    lastAt = now;
    NSString *copy = [text copy];
    DSTell(^(DSStageManager *manager) {
        if (isDelete) [manager forwardHostedKeyboardDelete];
        else [manager forwardHostedKeyboardText:copy];
    });
}

// Letters typed on SpringBoard's keyboard are delivered here. The staged app
// is another process, so the characters are written through to the field it
// already remembered. This does not take the key window or open a text field.
%hook UIKeyboardImpl

- (void)addInputString:(NSString *)string {
    %orig;
    DSForwardHostedKeyboardText(string, NO);
}

- (void)addInputString:(NSString *)string withFlags:(unsigned long long)flags {
    %orig;
    (void)flags;
    DSForwardHostedKeyboardText(string, NO);
}

- (void)insertText:(NSString *)text {
    %orig;
    DSForwardHostedKeyboardText(text, NO);
}

- (void)deleteFromInput {
    %orig;
    DSForwardHostedKeyboardText(nil, YES);
}

- (void)deleteBackward {
    %orig;
    DSForwardHostedKeyboardText(nil, YES);
}

%end

static BOOL DSHostedAppOwnsKeyboard(void);

static BOOL DSWindowIsKeyboard(UIWindow *window) {
    if (![window isKindOfClass:UIWindow.class]) return NO;
    NSString *name = NSStringFromClass(window.class);
    return [name rangeOfString:@"Keyboard"].location != NSNotFound ||
           [name rangeOfString:@"TextEffects"].location != NSNotFound;
}

// Key strip in this window's own coordinates. Comparing a point that was
// converted into screen space treated taps on the card as keys.
static CGRect DSKeyBandInWindow(UIWindow *window) {
    static CGRect cached = {{0, 0}, {0, 0}};
    static BOOL cachedValid = NO;
    static __weak UIWindow *cachedWindow = nil;
    static CFAbsoluteTime cachedAt = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (cachedValid && cachedWindow == window && (now - cachedAt) < 0.1) return cached;
    CGRect keys = DSKeyboardKeysInWindow(window);
    CGRect onScreen = DSVisibleFullKeyboardFrameOnScreen();
    if (CGRectIsNull(onScreen)) onScreen = DSVisibleKeyboardFrameOnScreen();
    if (!CGRectIsNull(onScreen)) {
        CGRect inWindow = CGRectOffset(onScreen,
                                       -CGRectGetMinX(window.frame),
                                       -CGRectGetMinY(window.frame));
        // After the first letter a second keyboard view sits at y=932. That
        // strip is below the keys the user can see, so the next tap is treated
        // as above the keys and falls through.
        if (CGRectIsNull(keys) || !CGRectIntersectsRect(keys, inWindow)) {
            keys = inWindow;
        }
    }
    if (CGRectIsNull(keys)) {
        // No key strip in the docked window. A guessed band would swallow the
        // bottom of the card after the keyboard view has been hidden.
        if (DSKeyboardWindowIsDocked(window)) return CGRectNull;
        CGRect bounds = window.bounds;
        CGFloat band = MIN(340.0, CGRectGetHeight(bounds));
        keys = CGRectMake(0.0, CGRectGetMaxY(bounds) - band, CGRectGetWidth(bounds), band);
    } else {
        keys = CGRectInset(keys, -6.0, -8.0);
    }
    cached = keys;
    cachedWindow = window;
    cachedAt = now;
    cachedValid = YES;
    return keys;
}

static BOOL DSPointInWindowIsOnKeys(UIWindow *window, CGPoint pointInWindow) {
    if (![window isKindOfClass:UIWindow.class]) return NO;
    return CGRectContainsPoint(DSKeyBandInWindow(window), pointInWindow);
}

static BOOL DSViewNameIsKeyboardChrome(UIView *view) {
    NSString *name = NSStringFromClass(object_getClass(view));
    return [name rangeOfString:@"Keyboard"].location != NSNotFound ||
           [name rangeOfString:@"TextEffects"].location != NSNotFound ||
           [name rangeOfString:@"InputSet"].location != NSNotFound ||
           [name rangeOfString:@"UIKB"].location != NSNotFound;
}

// Staged Messages is using SpringBoard's keyboard. A tap that already hit a
// key has to stay there. The app picker search is not this keyboard.
static BOOL DSMessagesSpringBoardKeyboardOwnsTouches(void) {
    if (!DSIsMessagesKeyboardUp()) return NO;
    __block BOOL search = NO;
    DSAsk(^BOOL(DSStageManager *manager) {
        search = manager.isPickerSearchActive;
        return YES;
    });
    return !search;
}

// The keyboard rect UIKit is actually drawing. A parked host at y=932 is not
// this rect. convertPoint:toView:nil stops at the window, so try the window
// origin and the local point as well.
static BOOL DSHitLandsOnVisibleKeys(UIView *view, CGPoint point) {
    if (![view isKindOfClass:UIView.class]) return NO;
    static CGRect cached = {{0, 0}, {0, 0}};
    static BOOL cachedValid = NO;
    static CFAbsoluteTime cachedAt = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!cachedValid || (now - cachedAt) >= 0.05) {
        CGRect visible = DSVisibleFullKeyboardFrameOnScreen();
        if (CGRectIsNull(visible) || CGRectGetHeight(visible) < 160.0) {
            visible = DSVisibleKeyboardFrameOnScreen();
        }
        CGFloat screenH = CGRectGetHeight(UIScreen.mainScreen.bounds);
        if (!CGRectIsNull(visible) && CGRectGetHeight(visible) >= 160.0 &&
            CGRectGetMinY(visible) < screenH - 1.0) {
            cached = CGRectInset(visible, -16.0, -20.0);
            cachedValid = YES;
        } else {
            cached = CGRectNull;
            cachedValid = NO;
        }
        cachedAt = now;
    }
    if (!cachedValid || CGRectIsNull(cached)) return NO;
    UIWindow *window = [view isKindOfClass:UIWindow.class] ? (UIWindow *)view : view.window;
    if (!window) return CGRectContainsPoint(cached, point);
    CGPoint inWindow = (view == (UIView *)window) ? point : [view convertPoint:point toView:window];
    CGPoint onScreen = CGPointMake(inWindow.x + CGRectGetMinX(window.frame),
                                   inWindow.y + CGRectGetMinY(window.frame));
    if (CGRectContainsPoint(cached, onScreen)) return YES;
    if (CGRectContainsPoint(cached, inWindow)) return YES;
    return CGRectContainsPoint(cached, point);
}

// YES when this touch is on the full-screen keyboard cover, above the keys,
// and has to fall through to the card. The windows are not moved.
static BOOL DSSpringBoardShouldPassTouch(UIView *view, CGPoint point) {
    if (!DSKeyboardTouchPassthroughArmed()) return NO;
    if (![view isKindOfClass:UIView.class]) return NO;
    if (DSHitLandsOnVisibleKeys(view, point)) return NO;
    // The app picker froze when every touch in the bottom half of the phone
    // was kept. This band is only the keyboard, and only while staged Messages
    // is the one using SpringBoard's keyboard. A key tap in that band stays.
    if (DSMessagesSpringBoardKeyboardOwnsTouches()) {
        UIWindow *kbWindow = [view isKindOfClass:UIWindow.class] ? (UIWindow *)view : view.window;
        if (kbWindow && DSWindowIsKeyboard(kbWindow)) {
            CGPoint inWindow = (view == (UIView *)kbWindow) ? point : [view convertPoint:point toView:kbWindow];
            CGFloat screenH = CGRectGetHeight(UIScreen.mainScreen.bounds);
            CGFloat screenY = inWindow.y + CGRectGetMinY(kbWindow.frame);
            // 4.5.429 kept typing by leaving taps on the lower half of this
            // keyboard. Picker search is not this keyboard.
            if (screenY >= screenH * 0.5 && screenY <= screenH + 12.0) return NO;
        }
    }
    UIWindow *window = [view isKindOfClass:UIWindow.class] ? (UIWindow *)view : view.window;
    if (!window) return NO;
    // Aperture is not the keyboard. Keeping its touches is what made the keys
    // look up and do nothing.
    NSString *scene = nil;
    if (@available(iOS 13.0, *)) {
        scene = window.windowScene.session.persistentIdentifier;
    }
    if (scene.length &&
        ([scene rangeOfString:@"SystemAperture"].location != NSNotFound ||
         [scene rangeOfString:@"SuperHighLevel"].location != NSNotFound ||
         [scene rangeOfString:@"Aperture"].location != NSNotFound)) {
        return NO;
    }
    BOOL docked = DSKeyboardWindowIsDocked(window);
    if (!docked && !DSExternalKeyboardCoversStage()) return NO;
    if (!docked && !DSWindowIsKeyboard(window) && !DSViewNameIsKeyboardChrome(view)) return NO;
    CGPoint inWindow = (view == (UIView *)window) ? point : [view convertPoint:point toView:window];
    if (DSPointInWindowIsOnKeys(window, inWindow)) return NO;
    // The keys the user can see. After the first letter the measured strip
    // moves to y=932, so a tap on those keys was passed through.
    CGRect screen = UIScreen.mainScreen.bounds;
    CGPoint onScreen = [window convertPoint:inWindow toView:nil];
    CGRect visible = DSVisibleFullKeyboardFrameOnScreen();
    if (CGRectIsNull(visible)) visible = DSVisibleKeyboardFrameOnScreen();
    if (!CGRectIsNull(visible) && CGRectGetHeight(visible) >= 160.0 &&
        CGRectContainsPoint(CGRectInset(visible, -16.0, -20.0), onScreen)) {
        return NO;
    }
    // The measured strip is often 75pt at the very bottom. The letters sit
    // above that strip, on the docked keyboard. Anything in the bottom band
    // of a keyboard that is already up belongs to the keys.
    CGFloat band = 360.0;
    if (!CGRectIsNull(visible) && CGRectGetHeight(visible) >= 160.0) {
        band = MAX(band, CGRectGetHeight(screen) - CGRectGetMinY(visible) + 24.0);
    }
    BOOL keyboardUp = DSExternalKeyboardCoversStage() || DSKeyboardWindowIsDocked(window);
    if (keyboardUp && CGRectGetHeight(screen) > 400.0 &&
        onScreen.y >= CGRectGetHeight(screen) - band &&
        onScreen.y <= CGRectGetHeight(screen) + 4.0) {
        return NO;
    }
    // The same band in the window's own coordinates. A window whose frame is
    // only the keyboard still receives the tap at a small local y.
    CGFloat windowH = CGRectGetHeight(window.bounds);
    if (keyboardUp && windowH > 80.0 && inWindow.y >= windowH - band &&
        inWindow.y <= windowH + 4.0) {
        return NO;
    }
    static NSInteger noted = 0;
    if (noted < 4) {
        noted += 1;
        UIWindow *loggedWindow = [view isKindOfClass:UIWindow.class] ? (UIWindow *)view : view.window;
        CGPoint inLogged = loggedWindow && view != (UIView *)loggedWindow
            ? [view convertPoint:point toView:loggedWindow] : point;
        CGPoint onLogged = loggedWindow
            ? CGPointMake(inLogged.x + CGRectGetMinX(loggedWindow.frame),
                          inLogged.y + CGRectGetMinY(loggedWindow.frame))
            : point;
        DSDiagnosticsRecordFormat(@"SpringBoard: a touch above the keys passed through local=%@ screen=%@ window=%@",
                                  NSStringFromCGPoint(inLogged),
                                  NSStringFromCGPoint(onLogged),
                                  loggedWindow ? NSStringFromCGRect(loggedWindow.frame) : @"none");
    }
    return YES;
}

%hook UIWindow

- (void)setHidden:(BOOL)hidden {
    %orig;
}

- (void)setWindowLevel:(CGFloat)level {
    // 4.5.416 kept the keyboard above the stage after UIKit tried to drop it
    // back to level 10. The frame and the scene are not changed here.
    if ((DSKeyboardWindowIsDocked(self) || DSKeyboardWindowShouldPinLevel(self)) &&
        level < DSKeyboardWindowLevelAboveStage()) {
        %orig(DSKeyboardWindowLevelAboveStage());
        return;
    }
    %orig(level);
}

- (void)setFrame:(CGRect)frame {
    // Stretching this window to the whole phone after the first letter puts a
    // cover over the keys. The next tap misses them and the keyboard looks frozen.
    if (DSHostedAppOwnsKeyboard() || DSKeyboardWindowIsDocked(self)) {
        %orig;
        return;
    }
    %orig;
}

- (void)setWindowScene:(UIWindowScene *)scene {
    if ([DSSceneHost sceneSettingsUpdateDepth] > 0) {
        %orig;
        return;
    }
    id replacement = DSReplacementSceneForKeyboardWindow(self, scene);
    if ([replacement isKindOfClass:UIWindowScene.class]) {
        %orig((UIWindowScene *)replacement);
        return;
    }
    %orig;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (DSInCallWindowPassesTouch((UIView *)self, point)) return NO;
    if (DSSpringBoardShouldPassTouch((UIView *)self, point)) return NO;
    return %orig;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (DSInCallWindowPassesTouch((UIView *)self, point)) return nil;
    if (DSSpringBoardShouldPassTouch((UIView *)self, point)) return nil;
    return %orig;
}

- (UIView *)_hitTestLocation:(CGPoint)point sceneLocationZ:(CGFloat)z inScene:(id)scene withWindowServerHitTestWindow:(id)serverWindow event:(UIEvent *)event {
    (void)z;
    (void)scene;
    (void)serverWindow;
    if (DSInCallWindowPassesTouch((UIView *)self, point)) return nil;
    if (DSSpringBoardShouldPassTouch((UIView *)self, point)) return nil;
    return %orig;
}

%end

// UITextEffectsWindow and UIRemoteKeyboardWindow override hitTest on
// UIAutoRotatingWindow, so the UIWindow hook never sees the touch.
%hook UIAutoRotatingWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (DSInCallWindowPassesTouch((UIView *)self, point)) return nil;
    // This is the window the keys are in. Returning nil here dropped the tap
    // after the first letter, in the search field and in the message box.
    if (DSHitLandsOnVisibleKeys((UIView *)self, point)) return %orig;
    if (DSMessagesSpringBoardKeyboardOwnsTouches() && DSWindowIsKeyboard((UIWindow *)self)) {
        CGFloat screenH = CGRectGetHeight(UIScreen.mainScreen.bounds);
        CGFloat screenY = point.y + CGRectGetMinY(((UIWindow *)self).frame);
        if (screenY >= screenH * 0.5) return %orig;
    }
    if (DSSpringBoardShouldPassTouch((UIView *)self, point)) return nil;
    return %orig;
}

%end

%hook UIView

- (void)setHidden:(BOOL)hidden {
    %orig;
}

- (void)setAlpha:(CGFloat)alpha {
    %orig;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (DSKeyboardTouchPassthroughArmed() && DSViewNameIsKeyboardChrome((UIView *)self) &&
        DSSpringBoardShouldPassTouch((UIView *)self, point)) {
        return nil;
    }
    return %orig;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (DSKeyboardTouchPassthroughArmed() && DSViewNameIsKeyboardChrome((UIView *)self) &&
        DSSpringBoardShouldPassTouch((UIView *)self, point)) {
        return NO;
    }
    return %orig;
}

%end

static BOOL DSMessagesHostStaysOnScreen(void) {
    if (!DSIsMessagesKeyboardUp()) return NO;
    return DSAsk(^BOOL(DSStageManager *manager) {
        return [manager stagedKeyboardFieldIsEditing];
    });
}

static BOOL DSHostedAppOwnsKeyboard(void) {
    return DSAsk(^BOOL(DSStageManager *manager) {
        if (!manager.isStageVisible || manager.isPickerSearchActive) return NO;
        NSString *bundle = manager.stageBundleIdentifier;
        // Search leaves the keyboard where UIKit put it. Rewriting Messages'
        // host to a 243pt strip is what made the tap miss the keys.
        if ([bundle isEqualToString:@"com.apple.MobileSMS"]) return NO;
        return bundle.length > 0 && [manager isHostingBundleIdentifier:bundle];
    });
}

%hook UIKeyboard

- (void)setFrame:(CGRect)frame {
    %orig(frame);
}

- (void)layoutSubviews {
    %orig;
    if (!DSHostedAppOwnsKeyboard()) return;
    UIView *view = (UIView *)self;
    CGRect docked = DSFrameDockingKeyboardToScreenBottom(view, view.frame);
    if (!CGRectEqualToRect(docked, view.frame)) view.frame = docked;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (DSSpringBoardShouldPassTouch((UIView *)self, point)) return nil;
    return %orig;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (DSSpringBoardShouldPassTouch((UIView *)self, point)) return NO;
    return %orig;
}

%end

%hook UIKeyboardImpl

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (DSSpringBoardShouldPassTouch((UIView *)self, point)) return nil;
    return %orig;
}

%end

static BOOL DSBeeperHostedCached(void) {
    static CFAbsoluteTime checkedAt = 0;
    static BOOL hosted = NO;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - checkedAt > 0.25) {
        checkedAt = now;
        hosted = DSAsk(^BOOL(DSStageManager *manager) {
            return [manager isHostingBundleIdentifier:@"com.beeper.chat.ios"];
        });
    }
    return hosted;
}

static void DSPinContextLayerHost(UIView *view) {
    // 4.5.650: context hosts lay out every frame of the switcher swipe; the
    // pin only matters for a staged Beeper keyboard.
    if (!DSBeeperHostedCached() || [DSSceneHost systemTransitionBusy]) return;
    if (![view isKindOfClass:UIView.class] || !view.superview || !view.window) return;
    if (view.hidden || view.alpha < 0.01) return;
    static BOOL busy = NO;
    if (busy) return;
    CGRect screen = [view convertRect:view.bounds toView:nil];
    if (CGRectGetHeight(screen) < 160.0) return;
    __block CGRect pinned = screen;
    DSTell(^(DSStageManager *manager) {
        pinned = [manager pinnedBeeperKeyboardFrameForProposed:screen];
    });
    if (CGRectEqualToRect(pinned, screen)) return;
    CGRect local = [view.superview convertRect:pinned fromView:nil];
    if (CGRectEqualToRect(local, view.frame)) return;
    busy = YES;
    view.frame = local;
    busy = NO;
}

%hook _UIContextLayerHostView

- (void)layoutSubviews {
    %orig;
    DSPinContextLayerHost((UIView *)self);
}

- (void)setFrame:(CGRect)frame {
    %orig(frame);
    DSPinContextLayerHost((UIView *)self);
}

%end

%hook UIInputSetHostView

- (void)setFrame:(CGRect)frame {
    %orig(frame);
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (DSSpringBoardShouldPassTouch((UIView *)self, point)) return nil;
    return %orig;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (DSSpringBoardShouldPassTouch((UIView *)self, point)) return NO;
    return %orig;
}

%end

// The system status bar is a window above the stage. While a card is on the
// top half that bar stays invisible. A tap on its strip shows it, then it
// hides again. The stage window is not raised over it.
static __weak UIView *DSSystemStatusBar = nil;
static BOOL DSStatusBarApplyBusy = NO;

static void DSApplySystemStatusBar(void) {
    UIView *bar = DSSystemStatusBar;
    if (![bar isKindOfClass:UIView.class] || DSStatusBarApplyBusy) return;
    BOOL hide = DSAsk(^BOOL(DSStageManager *manager) {
        return [manager shouldHideSystemStatusBar];
    });
    DSStatusBarApplyBusy = YES;
    CGFloat alpha = hide ? 0.0 : 1.0;
    if (fabs(bar.alpha - alpha) > 0.01) bar.alpha = alpha;
    DSStatusBarApplyBusy = NO;
}

static UIView *DSFindStatusBarView(UIView *view, NSInteger depth) {
    if (!view || depth > 6) return nil;
    if ([view isKindOfClass:objc_getClass("_UIStatusBar")]) return view;
    for (UIView *subview in view.subviews) {
        UIView *found = DSFindStatusBarView(subview, depth + 1);
        if (found) return found;
    }
    return nil;
}

@interface DSStatusBarPeekTarget : NSObject <UIGestureRecognizerDelegate>
@end

@implementation DSStatusBarPeekTarget

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    (void)gestureRecognizer;
    (void)touch;
    return DSAsk(^BOOL(DSStageManager *manager) {
        return [manager shouldHideSystemStatusBar];
    });
}

- (void)tapped:(UITapGestureRecognizer *)tap {
    if (tap.state != UIGestureRecognizerStateEnded) return;
    DSTell(^(DSStageManager *manager) {
        [manager peekSystemStatusBar];
    });
}

@end

static void DSAttachStatusBarPeek(UIWindow *window) {
    if (![window isKindOfClass:UIWindow.class]) return;
    static const void *key = &key;
    if (objc_getAssociatedObject(window, key)) return;
    DSStatusBarPeekTarget *target = [[DSStatusBarPeekTarget alloc] init];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:target action:@selector(tapped:)];
    tap.cancelsTouchesInView = YES;
    tap.delaysTouchesBegan = NO;
    tap.delegate = target;
    objc_setAssociatedObject(window, key, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [window addGestureRecognizer:tap];
}

static void DSCaptureSystemStatusBar(void) {
    if (DSSystemStatusBar.window) return;
    Class windowClass = objc_getClass("SBStatusBarWindow");
    if (!windowClass) windowClass = objc_getClass("UIStatusBarWindow");
    if (!windowClass) return;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (![window isKindOfClass:windowClass]) continue;
        UIView *bar = DSFindStatusBarView(window, 0);
        if (!bar) continue;
        DSSystemStatusBar = bar;
        DSAttachStatusBarPeek(window);
        break;
    }
}

%hook _UIStatusBar

- (void)didMoveToWindow {
    %orig;
    UIView *bar = (UIView *)self;
    if (!bar.window) return;
    DSSystemStatusBar = bar;
    DSAttachStatusBarPeek(bar.window);
    DSApplySystemStatusBar();
}

- (void)layoutSubviews {
    %orig;
    UIView *bar = (UIView *)self;
    DSSystemStatusBar = bar;
    if (bar.window) DSAttachStatusBarPeek(bar.window);
    DSApplySystemStatusBar();
}

- (void)setAlpha:(CGFloat)alpha {
    UIView *bar = (UIView *)self;
    if (bar != DSSystemStatusBar) {
        %orig(alpha);
        return;
    }
    if (!DSStatusBarApplyBusy && DSAsk(^BOOL(DSStageManager *manager) {
            return [manager shouldHideSystemStatusBar];
        })) {
        %orig(0.0);
        return;
    }
    %orig(alpha);
}

%end

// Staged Phone only. The scene view is the whole app. A full-screen frame is
// replaced with the card, and the view is clipped so nothing draws outside it.
// The scene presentation's own setFrame: is left alone. That call waits on the
// app and SpringBoard does not return.
static NSString *DSPhoneSceneBundle(id view) {
    SEL application = @selector(application);
    if ([view respondsToSelector:application]) {
        id app = ((id (*)(id, SEL))objc_msgSend)(view, application);
        if ([app respondsToSelector:@selector(bundleIdentifier)]) {
            id bundle = [app bundleIdentifier];
            if ([bundle isKindOfClass:NSString.class] && [(NSString *)bundle length] > 0) return bundle;
        }
    }
    SEL sceneHandle = @selector(sceneHandle);
    if ([view respondsToSelector:sceneHandle]) {
        id handle = ((id (*)(id, SEL))objc_msgSend)(view, sceneHandle);
        if ([handle respondsToSelector:application]) {
            id app = ((id (*)(id, SEL))objc_msgSend)(handle, application);
            if ([app respondsToSelector:@selector(bundleIdentifier)]) {
                id bundle = [app bundleIdentifier];
                if ([bundle isKindOfClass:NSString.class]) return bundle;
            }
        }
    }
    return nil;
}

// 4.5.650 (switcher lag): every switcher card is an SBApplicationSceneView,
// and setFrame / layoutSubviews run on each of them every frame of the
// swipe. This check used to build the class name, look the bundle up and
// lowercase it twice per call for every card - and the switcher's own Phone
// card matched too, so its frame was clamped to its parent mid-animation.
// Now: cached "is Phone staged at all" first, then only a scene view that is
// inside the stage (its window is the stage window or an ancestor is a card).
static BOOL DSPhoneStagedCached(void) {
    static CFAbsoluteTime checkedAt = 0;
    static BOOL staged = NO;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - checkedAt > 0.25) {
        checkedAt = now;
        staged = DSAsk(^BOOL(DSStageManager *manager) {
            return [manager isHostingBundleIdentifier:@"com.apple.mobilephone"];
        });
    }
    return staged;
}

static BOOL DSViewIsInsideStage(UIView *view) {
    static Class cardClass = Nil;
    static Class stageWindowClass = Nil;
    if (!cardClass) cardClass = objc_getClass("DSStageContainerView");
    if (!stageWindowClass) stageWindowClass = objc_getClass("DSStageWindow");
    UIWindow *window = view.window;
    if (window && stageWindowClass && [window isKindOfClass:stageWindowClass]) return YES;
    NSInteger depth = 0;
    for (UIView *cursor = view.superview; cursor && depth < 14; cursor = cursor.superview, depth++) {
        if (cardClass && [cursor isKindOfClass:cardClass]) return YES;
    }
    return NO;
}

static BOOL DSPhoneSceneViewIsHosted(UIView *view) {
    if (!DSPhoneStagedCached()) return NO;
    if (![view isKindOfClass:UIView.class]) return NO;
    if (view.window && !DSViewIsInsideStage(view)) return NO;
    const char *name = object_getClassName(view);
    if (name && strstr(name, "Presentation")) return NO;
    NSString *bundle = DSPhoneSceneBundle(view);
    return bundle && [bundle caseInsensitiveCompare:@"com.apple.mobilephone"] == NSOrderedSame;
}

static void DSClipPhoneSceneView(UIView *view) {
    if (!DSPhoneSceneViewIsHosted(view)) return;
    CGFloat radius = 44.0;
    Class cardClass = objc_getClass("DSStageContainerView");
    for (UIView *cursor = view.superview; cursor; cursor = cursor.superview) {
        if (cardClass && [cursor isKindOfClass:cardClass]) {
            radius = ((DSStageContainerView *)cursor).cornerRadius;
            break;
        }
    }
    // Write only what changed: these setters dirty the layer every frame.
    CALayer *layer = view.layer;
    if (!view.clipsToBounds) view.clipsToBounds = YES;
    if (!layer.masksToBounds) layer.masksToBounds = YES;
    if (radius > 1.0 && fabs(layer.cornerRadius - radius) > 0.01) {
        layer.cornerRadius = radius;
        if (@available(iOS 13.0, *)) layer.cornerCurve = kCACornerCurveContinuous;
    }
}

static CGRect DSPhoneSceneFrame(UIView *view, CGRect frame) {
    if (!DSPhoneSceneViewIsHosted(view)) return frame;
    if ([DSSceneHost sceneSettingsUpdateDepth] > 0 || [DSSceneHost homeGestureIsActive]) return frame;
    UIView *parent = view.superview;
    if (!parent) return frame;
    CGRect bounds = parent.bounds;
    if (CGRectGetWidth(bounds) < 80.0 || CGRectGetHeight(bounds) < 80.0) return frame;
    BOOL bigger = CGRectGetWidth(frame) > CGRectGetWidth(bounds) + 24.0 ||
                  CGRectGetHeight(frame) > CGRectGetHeight(bounds) + 24.0;
    if (!bigger) return frame;
    return bounds;
}

%hook SBApplicationSceneView

- (void)setFrame:(CGRect)frame {
    UIView *view = (UIView *)self;
    frame = DSPhoneSceneFrame(view, frame);
    %orig(frame);
    DSClipPhoneSceneView(view);
}

- (void)didMoveToWindow {
    %orig;
    DSClipPhoneSceneView((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    DSClipPhoneSceneView((UIView *)self);
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
    NSString *verdict = @"staged app keyboard is up";
    if (!onScreen) verdict = @"keyboard is down";
    else if (!staged) verdict = @"this keyboard is not from a staged app";
    NSString *dylib = @"no";
    if (staged && source.length) {
        dylib = [[DSStageManager sharedManager] hostedAppHasStageDylib:source] ? @"yes" : @"no";
    }
    return [NSString stringWithFormat:@"%@ | src=%@ on=%d staged=%d sbClient=%d uiHost=%@ layer=%d appDylib=%@",
            verdict, source ?: @"?", onScreen, staged, springBoard != nil, uiBundle, layer, dylib];
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
    DSTraceFormat(@"arbiter on=%d src=%@ frame=%@", onScreen, source ?: @"?", NSStringFromCGRect(frame));
    // A call deactivates the staged app and UIKit reports the keyboard down.
    // That is not the user leaving the field. Dismissing here is the keys dying.
    BOOL keepKeysDuringCall = NO;
    if (!onScreen && DSPhoneCallIsActive() && DSStageReady()) {
        keepKeysDuringCall = DSAsk(^BOOL(DSStageManager *manager) {
            return [manager stagedKeyboardFieldIsEditing] || [manager stagedTypingSessionActive];
        });
    }
    // UIKit hides the window inside %orig. If the raise flag is still set,
    // that hide is undone and the keys stay on screen after they have been
    // dismissed.
    if (!onScreen && !keepKeysDuringCall) DSAllowKeyboardToDismiss();

    %orig;

    NSString *hostNote = nil;
    BOOL releaseHost = NO;
    if (!onScreen && (DSBundleIsStaged(source) || DSWeOwnKeyboardHost)) {
        releaseHost = YES;
        DSHostAssignAttempts = 0;
    } else if (!onScreen) {
        DSHostAssignAttempts = 0;
    }

    DSArbiterBusy = NO;

    if (keepKeysDuringCall) {
        releaseHost = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            DSRevealSpringBoardKeyboard();
            DSHoldKeyboardLevelAboveStage();
            DSTell(^(DSStageManager *manager) {
                [manager keepStagedKeyboardField];
            });
            DSDiagnosticsRecord(@"SpringBoard: kept the staged keyboard up during a call");
        });
    }
    if (hostNote.length || releaseHost) {
        NSString *hostCopy = [hostNote copy];
        BOOL release = releaseHost;
        BOOL keyboardDown = !onScreen;
        NSString *sourceCopy = [source copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (keyboardDown) {
                __block BOOL restore = YES;
                DSTell(^(DSStageManager *manager) {
                    restore = [manager shouldRestoreKeyboardPlacementAfterDismiss:sourceCopy];
                });
                if (restore) DSRestoreRemoteKeyboardPlacement();
            }
            if (release) {
                DSReleaseStagedKeyboardHost();
            }
            (void)hostCopy;
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

// 4.5.650: rate-limited reader for the app's phone-fit log (see the
// phone.fit observer below).
static NSString *DSLastLineOfFile(NSString *path) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return nil;
    NSString *line = nil;
    @try {
        unsigned long long size = [handle seekToEndOfFile];
        unsigned long long start = size > 1536 ? size - 1536 : 0;
        [handle seekToFileOffset:start];
        NSData *data = [handle readDataToEndOfFile];
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!text) text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
        NSArray<NSString *> *lines = [[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                                      componentsSeparatedByString:@"\n"];
        line = lines.lastObject;
    } @catch (NSException *exception) {
        line = nil;
    }
    [handle closeFile];
    return line;
}

static BOOL DSPhoneFitReadScheduled = NO;
static CFAbsoluteTime DSPhoneFitReadAt = 0;

static void DSSchedulePhoneFitRead(int token) {
    if (DSPhoneFitReadScheduled) return;
    DSPhoneFitReadScheduled = YES;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    double wait = 0.4 - (now - DSPhoneFitReadAt);
    if (wait < 0.02) wait = 0.02;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DSPhoneFitReadScheduled = NO;
        if ([DSSceneHost systemTransitionBusy]) {
            DSSchedulePhoneFitRead(token); // read once the transition is over
            return;
        }
        DSPhoneFitReadAt = CFAbsoluteTimeGetCurrent();
        uint64_t state = 0;
        notify_get_state(token, &state);
        uint32_t hash = (uint32_t)state;
        CGFloat scale = (CGFloat)((state >> 32) & 0xff) / 100.0;
        CGFloat content = (CGFloat)((state >> 40) & 0x3ff);
        CGFloat limit = (CGFloat)((state >> 50) & 0x3ff);
        DSTell(^(DSStageManager *manager) {
            NSString *written = nil;
            for (NSString *path in @[ @"/var/tmp/com.recreated.dynamicstage.phone-fit",
                                      @"/var/jb/tmp/com.recreated.dynamicstage.phone-fit" ]) {
                written = DSLastLineOfFile(path);
                if (written.length) break;
            }
            NSString *line = written.length
                ? written
                : [NSString stringWithFormat:@"app: %@ keypad scale=%.2f content=%.0f limit=%.0f",
                   [manager bundleForKeyboardHash:hash], scale, content, limit];
            [manager noteStagedKeyResult:line];
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
        BOOL heldStandIn = (state & (1ULL << 60)) != 0;
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
                case 9: pathName = @"handoff"; break;
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
                line = [NSString stringWithFormat:@"app: key %@ -> %@ %@ fr=%d win=%d changed=%d hold=%d",
                        isDelete ? @"delete" : @"insert",
                        bundle,
                        className,
                        editing,
                        hasWindow,
                        changed,
                        heldStandIn];
            }
            [manager noteStagedKeyResult:line];
        });
    });

    // 4.5.650: the phone-fit file is a rolling log now. Show only its last
    // line, read at most every 0.4s (one trailing read), never during the
    // home / switcher transition. Reading it synchronously for every app
    // line was main-thread file I/O while Phone relaid out.
    int phoneFitToken = NOTIFY_TOKEN_INVALID;
    notify_register_dispatch("com.recreated.dynamicstage.phone.fit", &phoneFitToken, dispatch_get_main_queue(), ^(int token) {
        DSSchedulePhoneFitRead(token);
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
            DSInCallStageInstall();
            [[NSNotificationCenter defaultCenter] addObserverForName:@"DSStageStatusBarRefresh"
                                                                object:nil
                                                                 queue:NSOperationQueue.mainQueue
                                                            usingBlock:^(__unused NSNotification *note) {
                DSCaptureSystemStatusBar();
                DSApplySystemStatusBar();
            }];
            DSCaptureSystemStatusBar();

            Class arbiter = objc_getClass("_UIKeyboardArbiter");
            if (arbiter && class_getInstanceMethod(arbiter, @selector(updateKeyboardStatus:fromHandler:))) {
                %init(Arbiter, _UIKeyboardArbiter = arbiter);
            }

            [[DSStageManager sharedManager] activate];
            // 4.5.652: camera in staged apps.
            @try {
                [DSCameraArbiter start];
            } @catch (NSException *exception) {
            }
            // Hooks stay quiet while the window is built (the guard file is
            // still raised, and this flag is what lets them run). The file
            // stays raised until this process has stayed up, so a crash on
            // the next turn does not install those hooks again.
            DSFullInstallLive = YES;
            // 4.5.653: 8 s, not 15. A crash 10 s after a respring (a call
            // placed right away) used to leave the guard raised, and the next
            // SpringBoard start then skipped the whole tweak: no stage, no
            // edge notch, no log. A crash loop from the install itself still
            // happens well inside 8 s.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (DSKillSwitchPresent() || !DSFullInstallLive) return;
                DSBootstrapMarkLaunchSucceeded();
                DSDiagnosticsRecord(@"SpringBoard: stayed up, boot guard cleared");
            });

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
        // POSIX only until the guard is raised. A crash after this line leaves
        // the file in place, and the next SpringBoard start returns here
        // before any hook or signal handler exists.
        if (DSKillSwitchPresent()) return;
        if (DSLaunchGuardTripped()) {
            // 4.5.653: stay off for this one start (that is the protection),
            // then let the next respring try again instead of staying off
            // until a reinstall. A real crash loop alternates on / off and
            // never loops SpringBoard.
            DSBootstrapMarkLaunchSucceeded();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                DSDiagnosticsRecord(@"SpringBoard: DynamicStage stayed off for this start after a crash right after the last respring; respring once to turn it back on");
            });
            return;
        }
        if (!DSBootstrapBeginFullInstall()) return;

        DSCrashLogInstallHandlers();
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
