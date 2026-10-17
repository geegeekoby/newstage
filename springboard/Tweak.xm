#import <os/lock.h>
#import "DSCameraArbiter.h"
#import "DSStageManager.h"
#import "DSStageDragShellView.h"
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
#import "DSStageDebug.h"
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

// 4.5.655 (switcher lag): DSKillSwitchPresent() is three access() syscalls.
// DSStageReady runs at the top of DSAsk / DSTell and of the home pill, status
// bar and FBScene hooks, which SpringBoard calls for every switcher card on
// every frame of the swipe, with or without a stage on screen. The file is an
// emergency off switch, so reading it at most once a second is enough. The
// %ctor, the full install and the boot guard still read the file directly.
static BOOL DSKillSwitchCached(void) {
    static CFAbsoluteTime checkedAt = 0;
    static BOOL present = NO;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - checkedAt > 1.0 || now < checkedAt) {
        present = DSKillSwitchPresent() ? YES : NO;
        checkedAt = now;
    }
    return present;
}

static BOOL DSStageReady(void) {
    return DSFullInstallLive && !DSKillSwitchCached();
}

extern "C" void DSKeys674Install(void);

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

// 4.5.755 focus755: the last keyboard-focus / event-deferring settings update
// SpringBoard sent each scene, passed or held. Log only; read by the manager
// at keyboard on/off. Off: focus755-off / core755-off.
static NSMutableDictionary<NSString *, NSArray *> *DSFocus755Last = nil;

extern "C" NSString *DSFocus755LastFor(NSString *bundle, CFAbsoluteTime *at) {
    if (![bundle isKindOfClass:NSString.class] || bundle.length == 0) return nil;
    for (NSString *scene in DSFocus755Last) {
        if ([scene rangeOfString:bundle].location == NSNotFound) continue;
        NSArray *entry = DSFocus755Last[scene];
        if (at) *at = [entry[0] doubleValue];
        return entry[1];
    }
    return nil;
}

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
    // 4.5.657: nothing on the stage and no stage geometry anywhere: two static
    // reads, then out (no manager call, no lock).
    if (!DSStageHasSceneHostFast() && DSSceneHostOverrideCount() == 0) return NO;
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

// ---- 4.5.795 pass795 -----------------------------------------------------------
// Rule: SpringBoard's own scene and app-view updates for a staged app always
// reach SpringBoard, at once and in order. No hold, no replay, no drop, and
// no completion(YES) without %orig. Every crash table entry since 667 traps in
// SpringBoard's own -[SBAppViewController sceneHandle:didUpdateSettingsWithDiff:
// previousSettings:] right after we had held, dropped or replayed an earlier
// update for the same app view.
// 4.5.808 holds808: the 794 holds (holds-on, pass795-off, core795-off, latch
// pass795) are deleted; SpringBoard's updates always pass. No feature name is
// left for a latch to target, so this only logs.
static void DS795NoteWouldHold(NSString *what) {
    static CFAbsoluteTime last = 0;
    static NSString *lastWhat = nil;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - last > 1.0 || now < last || ![what isEqualToString:lastWhat]) {
        last = now; lastWhat = [what copy];
        DSDiagnosticsRecordFormat(@"SpringBoard: pass795 passed to SpringBoard (794 would have held it: %@)", what);
    }
}

// 4.5.706 perf706: an app that is not injected (Signal) had SpringBoard send it
// ~40 identical scene updates in a few seconds, each one a trace line. The same
// scene / fg / depth / frame is traced once per 3 s; the skipped count is added
// to the next line that does go out.
static BOOL DSPerf706SceneTraceWanted(NSString *identifier, int fg, long depth, CGRect frame) {
    if (!DSFeature699On("perf706")) return YES;
    NSString *key = [NSString stringWithFormat:@"%@|%d|%ld|%@", identifier ?: @"?", fg, depth, NSStringFromCGRect(frame)];
    NSUInteger was = 0;
    BOOL want = DSLogGate(@"perf706-scene-trace", key, 3.0, &was);
    if (want && was > 0) DSTraceFormat(@"scene update begin: %lu identical updates not traced (perf706)", (unsigned long)was);
    return want;
}

#pragma mark - Stage (installed after launch)

%group Stage

%hook SpringBoard

- (void)frontDisplayDidChange:(id)display {
    %orig;
    // 4.5.656 call guard: kept as it was (one static write + async check).
    DSCallGuardNoteFrontChange();
    // 4.5.657: this fires as the switcher closes onto an app. The picker
    // reload and the recents write it used to run here now wait for the next
    // stage use; this only records the bundle (no manager call).
    if (!DSStageReady()) return;
    @try {
        DSStageNoteFrontDisplayChanged(display);
    } @catch (NSException *exception) {
    }
}

%end

%hook FBScene

- (void)updateSettings:(FBSSceneSettings *)settings withTransitionContext:(id)context completion:(id)completion {
    // 4.5.657: every switcher card's scene goes through here each frame. With
    // nothing on the stage and no stage geometry this is two static reads.
    if (!DSStageReady() || (!DSStageHasSceneHostFast() && DSSceneHostOverrideCount() == 0)) {
        %orig;
        return;
    }
    if (DSScene773Wanted()) {   // 4.5.773 scene773 (log only)
        @try {
            NSString *sid773 = [self respondsToSelector:@selector(identifier)] ? self.identifier : nil;
            BOOL fk = NO; BOOL fg = [DSSceneHost readForegroundFlag:settings known:&fk];
            DSScene773Note(sid773, [NSString stringWithFormat:@"frame=%@ fg=%@", NSStringFromCGRect(settings.frame), fk ? (fg ? @"1" : @"0") : @"?"]);
        } @catch (NSException *exception) {}
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
        // 4.5.659: this update is the answer to the stage's own activation of
        // the app view after a home-transition hand-back. Refusing it (done
        // without %orig) left SpringBoard's activation half applied: the
        // SIGTRAP right after "... was woken" / "kept the open stage inside
        // its card" in the 4.5.657 crash log. It lands below, with the card
        // geometry written over the phone frame.
        if (phoneSized && [DSSceneHost isStageActivatingSceneIdentifier:incomingIdentifier]) {
            phoneSized = NO;
            static CFAbsoluteTime DSLastActivationPassLog = 0;
            CFAbsoluteTime passNow = CFAbsoluteTimeGetCurrent();
            if (passNow - DSLastActivationPassLog > 1.0) {
                DSLastActivationPassLog = passNow;
                DSDiagnosticsRecordFormat(@"SpringBoard: home659 let the stage's own activation update of %@ land at card size (not refused)",
                                          incomingIdentifier);
            }
        }
        // 4.5.665: the 4.5.663 / 4.5.662 safe-mode SIGTRAP. Home swipe with
        // the stage minimized, a corner pull adopted from SpringBoard's own
        // gesture before the home transition had finished, the parked apps
        // handed back, and then this branch refused SpringBoard's phone-sized
        // update of the same app (done without %orig) while its transaction
        // was still running. 4.5.659 only exempted the stage's own activation.
        // Inside that window the update now lands like the 659 one: the card
        // geometry is written over the phone frame and the committed
        // foreground is kept (normal path below), then the card is refit.
        if (phoneSized) {
            NSString *systemReason = [DSSceneHost systemTransitionHoldsSceneReason];
            if (systemReason.length > 0) {
                phoneSized = NO;
                static CFAbsoluteTime DSLastSystemPassLog = 0;
                CFAbsoluteTime passNow = CFAbsoluteTimeGetCurrent();
                if (passNow - DSLastSystemPassLog > 1.0) {
                    DSLastSystemPassLog = passNow;
                    DSDiagnosticsRecordFormat(@"SpringBoard: home665 let SpringBoard's update of %@ land at card size (%@), not refused",
                                              incomingIdentifier, systemReason);
                }
                NSString *refit = [incomingIdentifier copy];
                // After the update and after the 1.15 s quiet window; the refit
                // itself waits out any home gesture / nested update.
                for (NSNumber *delay in @[ @0.0, @1.3 ]) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        DSTell(^(DSStageManager *manager) {
                            [manager keepOnScreenStageInsideCardForSceneIdentifier:refit];
                        });
                    });
                }
            }
        }
        // A card-sized update has to land even when its foreground flag reads
        // off, or the app stays phone-sized and the card cuts off the bottom
        // of the chat.
        // 4.5.668: never refused any more. This was the last place a
        // SpringBoard update of a hosted scene was answered with done(YES)
        // and no %orig. SpringBoard's own bookkeeping then thinks the update
        // landed while the scene never got it, and the next settings diff its
        // SBAppViewController sees for that app view no longer matches: the
        // SIGTRAP inside -[SBAppViewController sceneHandle:didUpdateSettings
        // WithDiff:previousSettings:] in every 662-667 crash log (symbolized
        // 668: frame 2 = our hook's %orig, Tweak.xm "owned app view" path),
        // each preceded by "kept the open stage inside its card while another
        // app opened". Like 659 / 665, it lands now: the card geometry is
        // written over the phone frame and the committed foreground is kept
        // (normal path below), then the card is refit.
        if (phoneSized) {
            phoneSized = NO;
            static CFAbsoluteTime DSLastKeptCardLog = 0;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - DSLastKeptCardLog > 1.0) {
                DSLastKeptCardLog = now;
                DSDiagnosticsRecordFormat(@"SpringBoard: home668 kept the open stage inside its card while another app opened "
                                          @"(%@'s phone-size update lands at card size, not refused)", incomingIdentifier);
            }
            NSString *kept = [incomingIdentifier copy];
            // 4.5.741 close741: the closing app's last update lands (668 rule) but
            // never refits the stage that stays open (Bnb log 12:07:14.328).
            BOOL closing741 = DSClose741Recent(incomingIdentifier);
            if (closing741) {
                DSFeature719MarkAction("close741");
                DSDiagnosticsRecordFormat(@"SpringBoard: close741 %@ is closing: update landed, no refit of the open stage", incomingIdentifier);
            }
            for (NSNumber *delay in (closing741 ? @[] : @[ @0.0, @1.3 ])) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    DSTell(^(DSStageManager *manager) {
                        [manager keepOnScreenStageInsideCardForSceneIdentifier:kept];
                    });
                });
            }
        }
    }
    if ([DSSceneHost homeGestureIsActive] ||
        [DSSceneHost sceneIdentifierStaysBackgrounded:([self respondsToSelector:@selector(identifier)] ? self.identifier : nil)]) {
        NSString *identifier = [self respondsToSelector:@selector(identifier)] ? self.identifier : nil;
        BOOL hosted = [DSSceneHost sceneIdentifierStaysBackgrounded:identifier] || DSAsk(^BOOL(DSStageManager *manager) {
            return [manager isHostingSceneIdentifier:identifier];
        });
        if (hosted) DS795NoteWouldHold(@"minimized / home scene update");   // 4.5.808: always passed (holds gone)
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
    if (traceCare && DSSceneTraceAllowed() && DSPerf706SceneTraceWanted(traceIdentifier, traceForegroundKnown ? traceForeground : -1,
                                                                           (long)[DSSceneHost sceneSettingsUpdateDepth], traceFrame)) {
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
            // 4.5.800 reason800: even when keepFront is NO (home), hosted scenes must
            // carry our ignoreOcclusionReasons id through the commit.
            if (!mutableSettings && traceHosted) mutableSettings = [settings mutableCopy];
            if (mutableSettings) {
                [DSSceneHost applyOverridesToSettings:mutableSettings forScene:self];
                if (keepFront) [DSSceneHost keepCommittedForegroundOfScene:self onSettings:mutableSettings];
                if (traceHosted) [DSSceneHost reason800EnsureReasonOnScene:self settings:mutableSettings];
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
                // 4.5.657: nothing at all while the system has the screen
                // (home / switcher) and no card is on screen.
                BOOL systemOwns = [DSSceneHost systemTransitionBusy];
                BOOL quiet = systemOwns && !DSStageCardOnScreenFast();
                if (!quiet && (coverChanged || (due && !systemOwns))) {
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
            // 4.5.800 reason800: always re-append for hosted scenes (incl. home).
            // Force the mutable path so a wiped ignoreOcclusionReasons set cannot
            // slip through as a bare %orig when ensure had nothing else to change.
            if (mutableSettings && traceHosted) {
                [DSSceneHost reason800EnsureReasonOnScene:self settings:mutableSettings];
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
    if (!DSStageReady() || !block || (!DSStageHasSceneHostFast() && DSSceneHostOverrideCount() == 0)) {
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
        if (hosted) DS795NoteWouldHold(@"minimized / home scene block update");   // 4.5.808: always passed (holds gone)
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
                // 4.5.800 reason800: contributor-bypass path (home/layout) too.
                if (hosted) [DSSceneHost reason800EnsureReasonOnScene:scene settings:settings];
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
                    BOOL closing741 = phoneSized && DSClose741Recent(identifier);
                    if (closing741) {
                        DSFeature719MarkAction("close741");
                        DSDiagnosticsRecordFormat(@"SpringBoard: close741 %@ is closing (card torn down just now): its last update is not a reason to refit the open stage", identifier);
                    }
                    if (phoneSized && !closing741 &&
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

// 4.5.657: swiping a card away in the app switcher destroys its scene and
// kills its process inside the swipe. Both hooks used to run the stage's
// "app closed" handling right there (picker, shelf, home affordance, host
// teardown). Now: nothing unless the stage holds an app, and then only a
// data-only note; the stage handles it on its next use.
- (void)destroyScene:(NSString *)identifier withTransitionContext:(id)context {
    if (identifier.length > 0 && DSStageReady() && DSStageHasSceneHostFast()) {
        @try {
            NSString *bundleIdentifier = identifier;
            NSRange colon = [identifier rangeOfString:@":"];
            if (colon.location != NSNotFound) {
                bundleIdentifier = [identifier substringFromIndex:NSMaxRange(colon)];
            }
            NSRange dash = [bundleIdentifier rangeOfString:@"-" options:NSBackwardsSearch];
            if (dash.location != NSNotFound) {
                bundleIdentifier = [bundleIdentifier substringToIndex:dash.location];
            }
            DSStageNoteBundleKilled(bundleIdentifier);
        } @catch (NSException *exception) {
        }
    }
    %orig;
}

%end

%hook SBApplication

- (void)applicationProcessDidExit:(id)process withContext:(id)context {
    %orig;
    if (!DSStageReady() || !DSStageHasSceneHostFast()) return;
    @try {
        DSStageNoteBundleKilled(self.bundleIdentifier);
    } @catch (NSException *exception) {
    }
}

%end

// ---- 4.5.765 corner765 -------------------------------------------------------
// Off: corner765-off / core765-off (crash latch corner765).
static CFAbsoluteTime DSCorner765At = 0;

// 4.5.740 hold740: generation of the pending held Live update (main thread).
static NSUInteger DSHold740Gen = 0;
static BOOL DSHold740Replaying = NO;

// ---- 4.5.769 focus769 -----------------------------------------------------------
// Cbskh (767) 01:18:17.123: Beeper's keyboardFocus update was held for the
// corner restore and dropped by corner767; SpringBoard never got it, the keys
// were invisible, and at 01:20:10.6 an empty-focus update passed and SpringBoard
// trapped. Per scene: the app's latest focus (from the diffs) and the focus last
// delivered to SpringBoard (%orig). 0 unknown, 1 keyboardFocus, 2 empty.
// Off: focus769-off / core769-off (crash latch focus769).
static NSMutableDictionary<NSString *, NSNumber *> *DSFocus769Latest = nil;
static NSMutableDictionary<NSString *, NSNumber *> *DSFocus769Delivered = nil;
static NSUInteger DSFocus769PendingGen = 0;

static NSInteger DSFocus769StateOf(NSString *text) {
    if (text.length == 0) return 0;
    NSRange r = [text rangeOfString:@"targetOfEventDeferringEnvironments = "];
    if (r.location == NSNotFound) return 0;
    NSString *rest = [text substringFromIndex:NSMaxRange(r)];
    if ([rest hasPrefix:@"(empty)"]) return 2;
    if ([rest rangeOfString:@"keyboardFocus"].location != NSNotFound && [rest rangeOfString:@"keyboardFocus"].location < 40) return 1;
    return 0;
}

static NSString *DSFocus769Key(id handle) {
    @try {
        id scene = [handle respondsToSelector:@selector(scene)] ? ((id (*)(id, SEL))objc_msgSend)(handle, @selector(scene)) : nil;
        id ident = [scene respondsToSelector:@selector(identifier)] ? ((id (*)(id, SEL))objc_msgSend)(scene, @selector(identifier)) : nil;
        if ([ident isKindOfClass:NSString.class]) return ident;
    } @catch (NSException *exception) {}
    return @"?";
}


// 4.5.798 card state, short, for the crash breadcrumb and focus798.
static NSString *DS798Card(id ctrl) {
    @try {
        UIView *v = [ctrl respondsToSelector:@selector(view)] ? ((UIView *(*)(id, SEL))objc_msgSend)(ctrl, @selector(view)) : nil;
        NSInteger mode = [ctrl respondsToSelector:@selector(displayMode)] ? ((NSInteger (*)(id, SEL))objc_msgSend)(ctrl, @selector(displayMode)) : -1;
        BOOL io = [ctrl respondsToSelector:@selector(ignoresOcclusions)] ? ((BOOL (*)(id, SEL))objc_msgSend)(ctrl, @selector(ignoresOcclusions)) : NO;
        return [NSString stringWithFormat:@"mode=%ld io=%d minimised=%d home=%d busy=%d stageVisible=%d parked=%d win=%@ hid=%d a=%.2f",
                (long)mode, io, [DSSceneHost appViewControllerStaysBackgrounded:ctrl], [DSSceneHost homeGestureIsActive], [DSSceneHost systemTransitionBusy],
                DSStageVisibleFast(), DSStageHasParkedCardFast(),
                v.window ? NSStringFromClass(v.window.class) : @"none", v.window ? (int)v.window.hidden : -1, v.window ? v.window.alpha : 0.0];
    } @catch (NSException *e) { return @"?"; }
}

// 4.5.798 occl798 - the root crash fix (disassembly of SpringBoard 16.5.1 20F75,
// -[SBAppViewController sceneHandle:didUpdateSettingsWithDiff:previousSettings:]
// +740 = SpringBoard+0xa1fa8, the trap in every crash since 667):
//   if (_ignoresOcclusions && ![[scene.settings ignoreOcclusionReasons] containsObject:_identifier])
//       BSAssert -> brk #0  ("Invalid condition not satisfying: [[sceneSettings
//       ignoreOcclusionReasons] containsObject:_identifier]", SBAppViewController.m:445)
// We set ignoresOcclusions YES on our app views (DSSceneHost). The reason only
// enters the scene's settings through SpringBoard's own activation; when
// SpringBoard's main screen updates the same scene its reasons replace ours, and
// the next settings update to our app view traps. One plain rule, read from the
// same state SpringBoard checks, at the moment it checks: our app view claims
// ignoresOcclusions only while the scene really carries its reason. If not, the
// claim is dropped before %orig, so the check is skipped instead of failing.
// Off: occl798-off or core798-off (back to 797), plus crash latch.
static void DS798Occlusion(id ctrl, id handle) {
    if (!DSFeature699On("core798") || !DSFeature699On("occl798")) return;
    @try {
        if (![ctrl respondsToSelector:@selector(ignoresOcclusions)] || ![ctrl respondsToSelector:@selector(setIgnoresOcclusions:)]) return;
        if (!((BOOL (*)(id, SEL))objc_msgSend)(ctrl, @selector(ignoresOcclusions))) return;
        id scene = [handle respondsToSelector:@selector(scene)] ? ((id (*)(id, SEL))objc_msgSend)(handle, @selector(scene)) : nil;
        id settings = [scene respondsToSelector:@selector(settings)] ? ((id (*)(id, SEL))objc_msgSend)(scene, @selector(settings)) : nil;
        id reasons = [settings respondsToSelector:@selector(ignoreOcclusionReasons)] ? ((id (*)(id, SEL))objc_msgSend)(settings, @selector(ignoreOcclusionReasons)) : nil;
        Ivar iv = class_getInstanceVariable(object_getClass(ctrl), "_identifier");
        id ident = iv ? object_getIvar(ctrl, iv) : nil;
        BOOL has = ident && [reasons respondsToSelector:@selector(containsObject:)] && [reasons containsObject:ident];
        // 4.5.799: when reg799's contributor is doing its job the reason is here.
        // Log that (rate-limited) as proof; only drop ignoresOcclusions when missing.
        if (has) {
            static CFAbsoluteTime lastOk = 0;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - lastOk > 2.0) {
                lastOk = now;
                NSString *ok = [NSString stringWithFormat:@"occl798 ok reason present %@ ctrl=%p (reg799 holding the claim) card[%@]",
                                ident ?: @"?", ctrl, DS798Card(ctrl)];
                DSDiagnosticsRecordFormat(@"SpringBoard: %@", ok);
                DSCrash793Crumb(ok.UTF8String);
            }
            return;
        }
        ((void (*)(id, SEL, BOOL))objc_msgSend)(ctrl, @selector(setIgnoresOcclusions:), NO);
        NSString *line = [NSString stringWithFormat:@"occl798 dropped ignoresOcclusions on %@ ctrl=%p: scene reasons %@ lack %@ (SpringBoard would have trapped here) card[%@]",
                          ident ?: @"?", ctrl, reasons ? [[reasons description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "] : @"(none)", ident ?: @"?", DS798Card(ctrl)];
        DSDiagnosticsRecordFormat(@"SpringBoard: %@", line);
        DSCrash793Crumb(line.UTF8String);
    } @catch (NSException *e) {}
}

// 4.5.798 focus798: focus797 on both paths (797 ran it only with pass795 on).
static void DS798Focus(id self, id handle, id diff) {
    NSInteger mode795 = [self respondsToSelector:@selector(displayMode)] ? ((NSInteger (*)(id, SEL))objc_msgSend)(self, @selector(displayMode)) : -1;
            // 4.5.797 focus797 (logging only): every keyboard-focus diff passed to a
            // staged Live app view, with the card and keyboard state. The 796
            // trap (18:46:33) was such a diff, with pass795 on, 2.8 s after the
            // card was minimised and while Spotlight's keyboard was up.
            if (mode795 == 4 && DSFeature699On("focus797")) {
                NSString *full = [diff description] ?: @"";
                if ([full rangeOfString:@"targetOfEventDeferringEnvironments"].location != NSNotFound) {
                    @try {
                        UIView *v = [self respondsToSelector:@selector(view)] ? ((UIView *(*)(id, SEL))objc_msgSend)(self, @selector(view)) : nil;
                        UIWindow *kw = nil;
                        for (UIWindow *w in UIApplication.sharedApplication.windows) if (w.isKeyWindow) { kw = w; break; }
                        NSString *f797 = [NSString stringWithFormat:@"focus798 %@ %@ minimised=%d home=%d busy=%d stageVisible=%d parked=%d view=%@ win=%@ hid=%d a=%.2f key=%@",
                            DSFocus769Key(handle), DSFocus769StateOf(full) == 1 ? @"keyboardFocus" : (DSFocus769StateOf(full) == 2 ? @"empty" : @"other"),
                            [DSSceneHost appViewControllerStaysBackgrounded:self], [DSSceneHost homeGestureIsActive], [DSSceneHost systemTransitionBusy],
                            DSStageVisibleFast(), DSStageHasParkedCardFast(), v ? @"yes" : @"no",
                            v.window ? NSStringFromClass(v.window.class) : @"none", v.window ? (int)v.window.hidden : -1, v.window ? v.window.alpha : 0.0,
                            kw ? NSStringFromClass(kw.class) : @"none"];
                        DSDiagnosticsRecordFormat(@"SpringBoard: %@", f797);
                        DSCrash793Crumb(f797.UTF8String);
                    } @catch (NSException *e) {}
                }
            }
}

%hook SBAppViewController

- (void)sceneHandle:(id)handle didUpdateSettingsWithDiff:(id)diff previousSettings:(id)previousSettings {
        if ([DSSceneHost ownsAppViewController:self]) {
        // 4.5.800 reason800: re-append ignoreOcclusionReasons before occl798 inspects
        // (home/layout paths bypass the reg799 contributor and wipe the set).
        @try {
            id scene = [handle respondsToSelector:@selector(scene)] ? ((id (*)(id, SEL))objc_msgSend)(handle, @selector(scene)) : nil;
            id settings = [scene respondsToSelector:@selector(settings)] ? ((id (*)(id, SEL))objc_msgSend)(scene, @selector(settings)) : nil;
            if (settings) [DSSceneHost reason800EnsureReasonOnSettings:settings forAppViewController:self];
        } @catch (NSException *e) {}
        // 4.5.800 fg800 / 4.5.801 fg801: leave Live before SpringBoard applies
        // foreground=NO (fg801 uses automatesLifecycle briefly like cover-sheet);
        // restore Live + displayMode 4 / layerHosts when foreground again.
        [DSSceneHost fg800LeaveLiveIfBackgrounded:self handle:handle previousSettings:previousSettings];
        @try {
            id sceneFg = [handle respondsToSelector:@selector(scene)] ? ((id (*)(id, SEL))objc_msgSend)(handle, @selector(scene)) : nil;
            id stFg = [sceneFg respondsToSelector:@selector(settings)] ? ((id (*)(id, SEL))objc_msgSend)(sceneFg, @selector(settings)) : nil;
            BOOL knownFg = NO;
            BOOL fgNow = stFg ? [DSSceneHost readForegroundFlag:stFg known:&knownFg] : NO;
            if (knownFg && fgNow) [DSSceneHost fg800RestoreLiveIfNeeded:self];
        } @catch (NSException *e) {}
        BOOL fg801SkipOrig = [DSSceneHost fg801ShouldSkipForegroundAssertionOrig:self previousSettings:previousSettings handle:handle];
        // 4.5.798: both run before either path (pass795 or the old one).
        DS798Occlusion(self, handle);
        DS798Focus(self, handle, diff);
        if (DS793On("log793")) {
            NSString *c798 = [NSString stringWithFormat:@"appview update ctrl=%p card[%@]", self, DS798Card(self)];
            DSCrash793Crumb(c798.UTF8String);
        }
        static CFAbsoluteTime DSLastAppViewTrace = 0;
        CFAbsoluteTime traceNow = CFAbsoluteTimeGetCurrent();
        BOOL traceThis = traceNow - DSLastAppViewTrace > 1.0;
        if (traceThis) {
            DSLastAppViewTrace = traceNow;
            DSTrace(@"app-view settings update");
        }
        // 4.5.795 pass795: always %orig, at once (see the helper above).
        // 4.5.808 holds808: the 794 hold / skip / replay path below it is gone.
        {
            NSString *would = nil;
            if ([DSSceneHost homeGestureIsActive] || [DSSceneHost appViewControllerStaysBackgrounded:self]) would = @"home gesture / stays backgrounded";
            else if (DSCallGuardActive()) would = @"call";
            else if (DSStageDragSettlingFast(1.2)) would = @"card drag";
            else if (DSStageRestoreSettlingFast(1.5)) would = @"corner restore";
            if (would) DS795NoteWouldHold(would);
            NSInteger mode795 = [self respondsToSelector:@selector(displayMode)] ? ((NSInteger (*)(id, SEL))objc_msgSend)(self, @selector(displayMode)) : -1;
            static CFAbsoluteTime last795 = 0;
            CFAbsoluteTime now795 = CFAbsoluteTimeGetCurrent();
            NSString *dd = nil;
            if (mode795 == 4 && (now795 - last795 > 0.5 || DS793On("log793"))) {
                dd = [[([diff description] ?: @"") componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];
                while ([dd rangeOfString:@"  "].location != NSNotFound) dd = [dd stringByReplacingOccurrencesOfString:@"  " withString:@" "];
                NSRange ch = [dd rangeOfString:@"changes" options:NSCaseInsensitiveSearch];
                if (ch.location != NSNotFound && ch.location > 0) dd = [dd substringFromIndex:ch.location];
                if (dd.length > 500) dd = [dd substringToIndex:500];
            }
            if (mode795 == 4 && now795 - last795 > 0.5) {
                last795 = now795;
                DSDiagnosticsRecordFormat(@"SpringBoard: appview670 %@ mode=4 pass795 update: %@", DSFocus769Key(handle), dd ?: @"");
            }
            if (DS793On("log793")) {
                NSString *crumb = [NSString stringWithFormat:@"appview pass795 mode=%ld handle=%p ctrl=%p diff=%p prev=%p card[%@] %@",
                                   (long)mode795, handle, self, diff, previousSettings, DS798Card(self), dd ?: @""];
                DSCrash793Crumb(crumb.UTF8String);
            }
            @try {
                if (fg801SkipOrig) {
                    DSDiagnosticsRecordFormat(@"SpringBoard: fg801: skipped SBAppViewController foreground=NO orig (mode already Static; cover-sheet ordering)");
                    DSCrash793Crumb("fg801 skipped foreground=NO orig");
                } else {
                    %orig;
                }
                if (DS793On("log793")) DSCrash793Crumb("appview pass795 returned");
            } @catch (NSException *exception) {
                DSDiagnosticsRecordFormat(@"SpringBoard: contained a scene update from the staged app (%@)",
                                          exception.reason ?: exception.name ?: @"?");
            }
            if (traceThis) DSTrace(@"app-view settings update done");
            return;
        }
    }
    %orig;
}

%end

%hook SBFluidSwitcherGestureManager

// 4.5.657: the only switcher-class hook left, in its minimal form. It fires
// once when a swipe off the bottom edge begins (not per frame, not for card
// flicks inside the switcher). It is kept because it is the only early signal
// for the home-swipe SIGTRAP protection: noteHomeGestureBegan raises the
// scene-lifecycle hold before SpringBoard's home transition re-describes the
// hosted scenes. It now does nothing unless the stage holds an app or is on
// screen, and the corner pull is only offered with a card parked in a corner.
- (void)grabberTongueBeganPulling:(id)tongue
                     withDistance:(double)distance
                      andVelocity:(double)velocity
                       andGesture:(UIPanGestureRecognizer *)gesture {
    if (!DSStageReady()) {
        %orig;
        return;
    }
    BOOL adopted770 = DSStageHasParkedCardFast() && DSAsk(^BOOL(DSStageManager *manager) {
            return [manager adoptSystemEdgePull:gesture];
        });
    if (DSStageHasParkedCardFast() || DSStageVisibleFast() || DSStageHasSceneHostFast()) DSGest770NoteEdgePull(gesture, adopted770);   // 4.5.770 gest770
    if (adopted770) return;
    if (DSStageHasSceneHostFast() || DSStageVisibleFast()) {
        DSTell(^(DSStageManager *manager) {
            [manager noteHomeGestureBegan:gesture];
        });
    }
    %orig;
}

// 4.5.657: every YES path of the suppression needs the stage visible or a card
// drag in progress, so anything else returns %orig on an ivar read.
- (BOOL)shouldBeginGestureAtStartingPoint:(CGPoint)point velocity:(CGPoint)velocity bounds:(CGRect)bounds {
    if (!DSStageReady() || !DSStageGestureRelevantFast()) return %orig;
    if (DSAsk(^BOOL(DSStageManager *manager) {
            return [manager shouldSuppressSystemGestureAtPoint:point velocity:velocity];
        })) {
        DSGest770NoteSuppressed(point, @"switcher");
        return NO;
    }
    return %orig;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    if (!DSStageReady() || !DSStageGestureRelevantFast()) return %orig;
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
    if (!DSStageReady() || !DSStageGestureRelevantFast()) return %orig;
    if (DSAsk(^BOOL(DSStageManager *manager) {
            return [manager shouldSuppressSystemGestureAtPoint:point velocity:velocity];
        })) {
        DSGest770NoteSuppressed(point, @"system");
        return NO;
    }
    return %orig;
}

%end

static NSInteger DSGrabberFrameDepth = 0;
// 4.5.657: pills the stage hid, held weakly. Replaces an associated-object
// lookup that 656 did on every layout of every pill (each switcher card has
// one) whenever the stage was not moving pills.
static NSHashTable<UIView *> *DSHiddenGrabbers = nil;

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
    if (!view) return;
    if (hidden) {
        if (!DSHiddenGrabbers) DSHiddenGrabbers = [NSHashTable weakObjectsHashTable];
        [DSHiddenGrabbers addObject:view];
    } else {
        [DSHiddenGrabbers removeObject:view];
    }
}

static BOOL DSGrabberHiddenByStage(UIView *view) {
    return DSHiddenGrabbers.count > 0 && [DSHiddenGrabbers containsObject:view];
}

// 4.5.657: the pill is only touched while a stage card is actually on screen
// (ivar reads; no manager call, no switcher query). The old test asked
// SBMainSwitcherController -isMainSwitcherVisible and the switcher
// transition state from every pill on every frame. A home / switcher swipe
// parks every card first, so with the switcher open this is always NO.
static BOOL DSStageShouldMoveHomeGrabber(void) {
    if (!DSStageReady()) return NO;
    return DSStageCardOnScreenFast();
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
    if (!DSStageShouldMoveHomeGrabber()) {
        // 4.5.656: a pill the stage hid is given back when the stage no longer
        // moves pills (call screen, switcher, stage closed).
        if (DSGrabberFrameDepth == 0 && DSGrabberHiddenByStage(self)) {
            DSNoteGrabberHidden(self, NO);
            self.alpha = 1.0;
            self.userInteractionEnabled = YES;
        }
        return;
    }
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
    if (DSGrabberHiddenByStage(self)) {
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
    // 4.5.657: nothing staged, nothing to keep (pointer reads).
    if (!DSStageReady() || !DSStageHasSceneHostFast()) {
        %orig;
        return;
    }
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
    // 4.5.657: SpringBoard asks this for app layouts while the switcher
    // builds its cards; nothing staged returns on pointer reads.
    if (!DSStageReady() || !DSStageHasSceneHostFast()) return NO;
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
    // 4.5.683: the app's own keyboard is meant to show inside its card.
    __block BOOL ownKeyboard683 = NO;
    __block NSString *bundle683 = nil;
    @try {
        DSTell(^(DSStageManager *manager) {
            if (![manager respondsToSelector:@selector(phoneSize683ActiveForBundle:)]) return;
            bundle683 = [manager keys674HostedBundleForSceneIdentifier:identifier];
            ownKeyboard683 = bundle683.length > 0 && [manager phoneSize683ActiveForBundle:bundle683];
        });
    } @catch (NSException *exception) {
        ownKeyboard683 = NO;
    }
    if (ownKeyboard683) {
        %orig;
        UIView *added = [view isKindOfClass:UIView.class] ? (UIView *)view : nil;
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize683 %@ UIKit added its hosted keyboard view %@ for %@ (pid %d): let through (4.5.683; before it was left out)",
                                  bundle683, added ? NSStringFromClass(added.class) : @"?", identifier, pid);
        __weak UIView *weakAdded = added;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *v = weakAdded;
            if (!v) return;
            DSDiagnosticsRecordFormat(@"SpringBoard: phonesize683 hosted keyboard view now %@ in %@ / %@ hidden=%d",
                                      NSStringFromCGRect([v convertRect:v.bounds toView:nil]),
                                      v.superview ? NSStringFromClass(v.superview.class) : @"no superview",
                                      v.window ? NSStringFromClass(v.window.class) : @"no window", v.hidden);
        });
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
        // 4.5.803 noise803: hitTest runs several times per touch; one line per point.
        static CGPoint lastPassed803 = {-1, -1};
        BOOL same803 = DS803On("noise803") && CGPointEqualToPoint(lastPassed803, onLogged);
        lastPassed803 = onLogged;
        if (!same803)
        DSDiagnosticsRecordFormat(@"SpringBoard: a touch above the keys passed through local=%@ screen=%@ window=%@",
                                  NSStringFromCGPoint(inLogged),
                                  NSStringFromCGPoint(onLogged),
                                  loggedWindow ? NSStringFromCGRect(loggedWindow.frame) : @"none");
    }
    return YES;
}

%hook UIWindow

// 4.5.772 hide772: public UIKit setter; one class-name check only while a
// staged keyboard is up (log only, never changes the call).
- (void)setHidden:(BOOL)hidden {
    if (hidden) DSHide772NoteWindowHidden(self, hidden);
    %orig;
}

// 4.5.655: the pass-through setHidden: hook is gone. The setFrame: hook below
// is gone too: both of its branches called %orig, but it first asked the stage
// manager (kill-switch syscalls included) on every window frame change.

- (void)setWindowLevel:(CGFloat)level {
    // 4.5.416 kept the keyboard above the stage after UIKit tried to drop it
    // back to level 10. The frame and the scene are not changed here.
    if ((DSKeyboardWindowIsDocked(self) || DSKeyboardWindowShouldPinLevel(self)) &&
        level < DSKeyboardWindowLevelAboveStage() && !DSMedusa802Handles(self)) {
        %orig(DSKeyboardWindowLevelAboveStage());
        return;
    }
    %orig(level);
}

// 4.5.657: the setWindowScene: hook is gone. Its helper
// (DSReplacementSceneForKeyboardWindow) has returned nil since the keyboard
// scene work was switched off, so it only cost a call on every window the
// switcher moved between scenes.

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
    // 4.5.657: every branch below ends in %orig unless the staged keyboard
    // pass-through is armed (static reads).
    if (!DSKeyboardTouchPassthroughArmed()) return %orig;
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

// 4.5.655: no setHidden: / setAlpha: hooks on UIView in SpringBoard. They only
// called %orig, and the switcher sets alpha / hidden on its views every frame.
%hook UIView

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


static BOOL DSHostedAppOwnsKeyboard(void) {
    // 4.5.657: only with a stage card on screen (ivar reads first).
    if (!DSStageReady() || !DSStageCardOnScreenFast()) return NO;
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
    // 4.5.657: a card on screen first (ivar reads), before any manager call.
    if (!DSStageReady() || !DSStageCardOnScreenFast()) return;
    // 4.5.683: SpringBoard's bottom-of-phone copy of an app's keys is hidden
    // while that app's own keyboard is up inside its card (static check first).
    if (DSPhoneSize683HidesKeyCopies()) DSPhoneSize683ConsiderContextHost(view);
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
// 4.5.657: bars the stage hid, held weakly (was an associated object read on
// every layout of every status bar, switcher cards included).
static NSHashTable<UIView *> *DSHiddenStatusBars = nil;
static void DSAttachStatusBarPeek(UIWindow *window);

static BOOL DSStatusBarHiddenByStage(UIView *bar) {
    return bar && DSHiddenStatusBars.count > 0 && [DSHiddenStatusBars containsObject:bar];
}

static void DSNoteStatusBarHiddenByStage(UIView *bar, BOOL hidden) {
    if (!bar || DSStatusBarHiddenByStage(bar) == hidden) return;
    if (hidden) {
        if (!DSHiddenStatusBars) DSHiddenStatusBars = [NSHashTable weakObjectsHashTable];
        [DSHiddenStatusBars addObject:bar];
    } else {
        [DSHiddenStatusBars removeObject:bar];
    }
}

// 4.5.655 (switcher lag): every _UIStatusBar in SpringBoard runs this from
// layoutSubviews (Home Screen, switcher, Control Center...). It used to force
// alpha 1.0 back onto any bar that SpringBoard had faded, including during the
// switcher transition, and attach a tap recognizer to every window holding one.
// Now a bar is only touched to hide it while a card covers the top, and only a
// bar the stage hid is given its alpha back. Bars the stage never hid are left
// to SpringBoard.
static void DSApplySystemStatusBar(void) {
    UIView *bar = DSSystemStatusBar;
    if (![bar isKindOfClass:UIView.class] || DSStatusBarApplyBusy) return;
    // 4.5.657: hiding needs a card on screen (ivar reads before the manager).
    BOOL hide = DSStageCardOnScreenFast() && DSAsk(^BOOL(DSStageManager *manager) {
        return [manager shouldHideSystemStatusBar];
    });
    BOOL ours = DSStatusBarHiddenByStage(bar);
    if (!hide && !ours) return;
    DSStatusBarApplyBusy = YES;
    if (hide) {
        if (bar.window) DSAttachStatusBarPeek(bar.window);
        DSNoteStatusBarHiddenByStage(bar, YES);
        if (bar.alpha > 0.01) bar.alpha = 0.0;
    } else {
        DSNoteStatusBarHiddenByStage(bar, NO);
        if (bar.alpha < 0.99) bar.alpha = 1.0;
    }
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
    if (!DSStageCardOnScreenFast()) return NO;
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
    Class windowClass = objc_getClass("UIStatusBarWindow");   // 4.5.809: no SBStatusBarWindow on 20F75
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

// 4.5.655: with the stage off (kill switch, boot guard) these return right
// after %orig. The peek tap is attached when a bar is actually hidden.
%hook _UIStatusBar

// 4.5.657: with no stage card on screen a bar returns right after %orig,
// unless it is one the stage hid (then it is given back). Switcher cards'
// bars are never adopted as "the system bar" any more.
- (void)didMoveToWindow {
    %orig;
    if (!DSStageReady()) return;
    UIView *bar = (UIView *)self;
    if (!bar.window) return;
    if (!DSStageCardOnScreenFast() && !DSStatusBarHiddenByStage(bar)) return;
    DSSystemStatusBar = bar;
    DSApplySystemStatusBar();
}

- (void)layoutSubviews {
    %orig;
    if (!DSStageReady()) return;
    UIView *bar = (UIView *)self;
    if (!DSStageCardOnScreenFast() && !DSStatusBarHiddenByStage(bar)) return;
    DSSystemStatusBar = bar;
    DSApplySystemStatusBar();
}

- (void)setAlpha:(CGFloat)alpha {
    UIView *bar = (UIView *)self;
    if (bar != DSSystemStatusBar || DSStatusBarApplyBusy || !DSStageCardOnScreenFast()) {
        %orig(alpha);
        return;
    }
    if (DSAsk(^BOOL(DSStageManager *manager) {
            return [manager shouldHideSystemStatusBar];
        })) {
        DSNoteStatusBarHiddenByStage(bar, YES);
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

// 4.5.657: every switcher card is an SBApplicationSceneView in SpringBoard's
// switcher window. The first test is now "is this view in the stage window"
// (one class check), before the cached manager question. The superview walk
// only runs for a view that is not in any window yet.
static BOOL DSSceneViewCouldBeStaged(UIView *view) {
    if (!DSStageReady() || !DSStageHasSceneHostFast()) return NO;
    static Class stageWindowClass = Nil;
    if (!stageWindowClass) stageWindowClass = objc_getClass("DSStageWindow");
    UIWindow *window = view.window;
    if (window) return stageWindowClass != Nil && [window isKindOfClass:stageWindowClass];
    return DSViewIsInsideStage(view);
}

static BOOL DSPhoneSceneViewIsHosted(UIView *view) {
    if (![view isKindOfClass:UIView.class]) return NO;
    if (!DSSceneViewCouldBeStaged(view)) return NO;
    if (!DSPhoneStagedCached()) return NO;
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






static BOOL DSBundleIsStaged(NSString *bundle) {
    if (bundle.length == 0 || [bundle isEqualToString:@"com.apple.springboard"]) return NO;
    return DSAsk(^BOOL(DSStageManager *manager) {
        return [manager isHostingBundleIdentifier:bundle];
    });
}

static void DSSetKeyboardUIHandle(id arbiter, id handle) {
    SEL setHandle = @selector(setKeyboardUIHandle:);   // 4.5.809: setKeyboardUIHandler: does not exist (20F75)
    @try {
        if ([arbiter respondsToSelector:setHandle]) {
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


// 4.5.677: the 4.5.676 focus hook (a manual MSHookMessageEx on
// -[_UIKeyboardArbiter handlerRequestedFocus:shouldStealKeyboard:]) is gone.
// 4.5.676 crashed SpringBoard (SIGSEGV) in the first objc message lookup after
// that hook went in, on the main thread during activate. It only logged by
// default. No hook other than the long-standing updateKeyboardStatus one is
// put on the arbiter.

// ---- 4.5.775 why775 (log only) -------------------------------------------------
// Logs the inputs and results of SpringBoard's Medusa keyboard-window decision.
// Never changes arguments or return values. Each group is installed only when
// class_getInstanceMethod finds the exact selector. Off: why775-off, master
// core775-off (crash latch why775).
@interface SBMedusaHostedKeyboardWindowController : NSObject
@end
@interface SBInputUISceneController : NSObject
@end

static NSString *DSWhy775Ident(id obj) {
    if (!obj) return @"nil";
    @try {
        NSString *ident = nil;
        if ([obj respondsToSelector:@selector(identifier)]) {
            id v = ((id (*)(id, SEL))objc_msgSend)(obj, @selector(identifier));
            if ([v isKindOfClass:NSString.class]) ident = v;
        }
        if (!ident && [obj respondsToSelector:@selector(session)]) {
            id session = ((id (*)(id, SEL))objc_msgSend)(obj, @selector(session));
            if ([session respondsToSelector:@selector(persistentIdentifier)]) {
                id v = ((id (*)(id, SEL))objc_msgSend)(session, @selector(persistentIdentifier));
                if ([v isKindOfClass:NSString.class]) ident = v;
            }
        }
        NSString *text = ident ?: [obj description];
        if (text.length > 140) text = [[text substringToIndex:140] stringByAppendingString:@"..."];
        return [NSString stringWithFormat:@"%@<%@>", NSStringFromClass([obj class]), text ?: @"?"];
    } @catch (NSException *exception) {
        return @"unreadable";
    }
}

%group Why775Update
%hook SBMedusaHostedKeyboardWindowController
- (void)updateMedusaHostedKeyboardWindowForScene:(id)scene isForeground:(unsigned long)isForeground {
    // 4.5.802: proven from the 801 .o: clang treats a BOOL argument as already
    // 0/1 and folds `!= 0 ? 1 : 0` away, storing raw w3. SpringBoard's caller
    // leaves junk in the upper bits (0x6D3E4C3F). Take the whole register and
    // test only the low byte (the real BOOL).
    volatile int fgLog = ((isForeground & 0xffUL) != 0) ? 1 : 0;
    %orig;
    @try {
        id w = [self respondsToSelector:@selector(medusaHostedKeyboardWindow)] ? ((id (*)(id, SEL))objc_msgSend)(self, @selector(medusaHostedKeyboardWindow)) : nil;
        DSWhy775Note([NSString stringWithFormat:@"updateMedusaHostedKeyboardWindowForScene:%@ isForeground:%d -> window hidden=%@",
                      DSWhy775Ident(scene), fgLog, [w isKindOfClass:UIWindow.class] ? (((UIWindow *)w).hidden ? @"YES" : @"NO") : @"?"]);
    } @catch (NSException *exception) {
    }
}
%end
%end

%group Why775Sized
%hook SBMedusaHostedKeyboardWindowController
- (BOOL)shouldKeyboardBeWindowSizedForHostWithIdentity:(id)identity {
    BOOL r = %orig;
    @try {
        DSWhy775Note([NSString stringWithFormat:@"shouldKeyboardBeWindowSizedForHostWithIdentity:%@ -> %d", DSWhy775Ident(identity), r]);
    } @catch (NSException *exception) {
    }
    return r;
}
%end
%end

%group Why775Target
%hook SBInputUISceneController
- (id)_targetSceneForKeyboardFocusedSceneIdentity:(id)identity {
    id r = %orig;
    @try {
        DSWhy775Note([NSString stringWithFormat:@"_targetSceneForKeyboardFocusedSceneIdentity:%@ -> %@", DSWhy775Ident(identity), DSWhy775Ident(r)]);
    } @catch (NSException *exception) {
    }
    return r;
}
%end
%end

// ---- 4.5.776 keep776 ---------------------------------------------------------------
// Approach (b): only -[SBMedusaHostedKeyboardWindow setHidden:YES] issued from
// inside -[SBMedusaHostedKeyboardWindowController updateMedusaHostedKeyboardWindowForScene:isForeground:]
// (the proven hide path, stacks A and B) is dropped, and only while
// DSKeep776Active(). setHidden:NO and every other caller pass through. Hidden
// windows are never forced visible. Any exception -> %orig.
@interface SBMedusaHostedKeyboardWindow : UIWindow
@end
static NSInteger DSKeep776UpdateDepth = 0;
static BOOL DSKeep776Bypass = NO;

%group Keep776Update
%hook SBMedusaHostedKeyboardWindowController
- (void)updateMedusaHostedKeyboardWindowForScene:(id)scene isForeground:(BOOL)isForeground {
    DSKeep776UpdateDepth++;
    @try {
        %orig;
    } @catch (NSException *exception) {
        DSKeep776UpdateDepth--;
        @throw;
    }
    DSKeep776UpdateDepth--;
}
%end
%end

%group Keep776Hide
%hook SBMedusaHostedKeyboardWindow
- (void)setHidden:(BOOL)hidden {
    BOOL drop = NO;
    @try {
        drop = hidden && !DSKeep776Bypass && DSKeep776UpdateDepth > 0 && NSThread.isMainThread && !((UIWindow *)self).hidden && DSKeep776Active();
        if (drop) DSKeep776NoteBlocked((UIWindow *)self);
        // 4.5.806 keep806 / why806 (same synchronous call; no timer).
        if (!drop && hidden && !DSKeep776Bypass && DSKeep776UpdateDepth > 0 && NSThread.isMainThread) {
            NSString *held = DSKeep806HoldingFor((UIWindow *)self);
            if (held) { drop = YES; DSKeep806NoteDropped(held); }
            else DSWhy806NotePassed((UIWindow *)self, ((UIWindow *)self).hidden, DSKeep776Bypass, DSKeep776UpdateDepth);
        }
    } @catch (NSException *exception) {
        drop = NO;
    }
    if (drop) return;
    %orig;
}
%end
%end

static void DSKeep776Install(void) {
    if (!DS776On("keep776")) return;
    Class ctrl = objc_getClass("SBMedusaHostedKeyboardWindowController");
    Class win = objc_getClass("SBMedusaHostedKeyboardWindow");
    // Both must exist with their own implementations, or neither goes in.
    BOOL ok = ctrl && win &&
        class_getInstanceMethod(ctrl, @selector(updateMedusaHostedKeyboardWindowForScene:isForeground:)) &&
        class_getInstanceMethod(win, @selector(setHidden:)) &&
        class_getInstanceMethod(win, @selector(setHidden:)) != class_getInstanceMethod(objc_getClass("UIWindow"), @selector(setHidden:));
    if (!ok) { DSDiagnosticsRecord(@"SpringBoard: keep776 not installed (selectors not found)"); return; }
    %init(Keep776Update, SBMedusaHostedKeyboardWindowController = ctrl);
    %init(Keep776Hide, SBMedusaHostedKeyboardWindow = win);
    DSKeep776ApplyHide = ^(UIWindow *medusa) {
        DSKeep776Bypass = YES;
        @try { [medusa setHidden:YES]; } @catch (NSException *exception) {}
        DSKeep776Bypass = NO;
    };
    DSDiagnosticsRecord(@"SpringBoard: keep776 installed (Medusa hide from updateMedusaHostedKeyboardWindowForScene: kept out while a staged app owns the keys)");
}

static void DSWhy775Install(void) {
    if (!DS775On("why775")) return;
    DSFeature699MarkTrying("why775");
    Class ctrl = objc_getClass("SBMedusaHostedKeyboardWindowController");
    Class input = objc_getClass("SBInputUISceneController");
    NSMutableArray *done = [NSMutableArray array];
    if (ctrl && class_getInstanceMethod(ctrl, @selector(updateMedusaHostedKeyboardWindowForScene:isForeground:))) {
        %init(Why775Update, SBMedusaHostedKeyboardWindowController = ctrl); [done addObject:@"update"];
    }
    if (ctrl && class_getInstanceMethod(ctrl, @selector(shouldKeyboardBeWindowSizedForHostWithIdentity:))) {
        %init(Why775Sized, SBMedusaHostedKeyboardWindowController = ctrl); [done addObject:@"sized"];
    }
    if (input && class_getInstanceMethod(input, @selector(_targetSceneForKeyboardFocusedSceneIdentity:))) {
        %init(Why775Target, SBInputUISceneController = input); [done addObject:@"target"];
    }
    DSDiagnosticsRecordFormat(@"SpringBoard: why775 hooks installed: %@", done.count ? [done componentsJoinedByString:@","] : @"none");
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
    // 4.5.803: the one keyboard model is set from here (earliest signal).
    if (DSStageReady()) {
        BOOL on803 = onScreen;
        NSString *src803 = [source copy];
        dispatch_async(dispatch_get_main_queue(), ^{ DS803NoteArbiter(on803, src803); });
    }
    // 4.5.743 fast743: the arbiter's on=0 is the earliest hide signal.
    if (!onScreen && DSStageReady()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                DSTell(^(DSStageManager *manager) {
                    if ([manager respondsToSelector:@selector(fast743KeysHiding:)]) [manager fast743KeysHiding:@"arbiter on=0"];
                    // 4.5.778 caret778: the keys are down (swipe-down included), so a
                    // staged Messages lets go of its message box. Off: caret778-off.
                    if (DSCaret778Enabled() && [manager respondsToSelector:@selector(postMessagesKeyboardShown:)]) {
                        [manager postMessagesKeyboardShown:NO];
                    }
                });
            } @catch (NSException *exception) {
            }
        });
    }
    // 4.5.676 phonesize676: the earliest sign that a staged app's keyboard is
    // coming up. The stage grows an allowlisted app's scene right away instead
    // of after its first keyboard note.
    // 4.5.677: defensive. Only values already read above (copied string, a
    // finite height, a timestamp) leave this queue; nothing else of the arbiter,
    // the handler or the information object is touched here, and all the stage
    // work (allowlist, off files, host lookup) happens on the main queue.
    // 4.5.680 phonesize680: the same values also move an always-full-screen
    // card's window with the keyboard (on=1 and on=0); tried first, the 676
    // early switch only runs when 680 did not take it.
    @try {
        if (onScreen && [source isKindOfClass:NSString.class] && source.length && DSStageReady()) {
            NSString *earlySource = [source copy];
            CGFloat earlyHeight = CGRectGetHeight(frame);
            if (!isfinite(earlyHeight) || earlyHeight < 0.0) earlyHeight = 0.0;
            double earlyAt = CACurrentMediaTime();
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    DSTell(^(DSStageManager *manager) {
                        if ([manager respondsToSelector:@selector(phoneSize680KeyboardSignal:bundle:on:height:at:)] &&
                            [manager phoneSize680KeyboardSignal:@"arbiter on=1" bundle:earlySource on:YES height:earlyHeight at:earlyAt]) {
                            return;
                        }
                        if (DSPhoneSize677EarlyDisabled()) return;
                        if (![manager respondsToSelector:@selector(phoneSize676EarlySignal:bundle:height:at:)]) return;
                        [manager phoneSize676EarlySignal:@"arbiter on=1" bundle:earlySource height:earlyHeight at:earlyAt];
                    });
                } @catch (NSException *exception) {
                    DSDiagnosticsRecordFormat(@"SpringBoard: phonesize677 early switch threw %@", exception.reason ?: exception.name ?: @"?");
                }
            });
        } else if (!onScreen && DSStageReady()) {
            NSString *hideSource = [source isKindOfClass:NSString.class] ? [source copy] : @"";
            double hideAt = CACurrentMediaTime();
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    DSTell(^(DSStageManager *manager) {
                        if (![manager respondsToSelector:@selector(phoneSize680KeyboardSignal:bundle:on:height:at:)]) return;
                        [manager phoneSize680KeyboardSignal:@"arbiter on=0" bundle:hideSource on:NO height:0.0 at:hideAt];
                    });
                } @catch (NSException *exception) {
                    DSDiagnosticsRecordFormat(@"SpringBoard: phonesize680 hide signal threw %@", exception.reason ?: exception.name ?: @"?");
                }
            });
        }
    } @catch (NSException *exception) {
    }
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
            // 4.5.657: was a 0.4 s re-poll for as long as the switcher stayed
            // open. Now one deferred read on the next stage use.
            static BOOL deferred = NO;
            if (deferred) return;
            deferred = YES;
            [DSSceneHost performWhenSystemTransitionOver:^{
                deferred = NO;
                DSSchedulePhoneFitRead(token);
            }];
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


// ---- 4.5.749 core749 ---------------------------------------------------------
// Master off: /var/mobile/.dynamicstage-core749-off returns to 4.5.748.
static BOOL DS749FileOff(const char *name) {
    char a[160], b[180];
    snprintf(a, sizeof(a), "/var/mobile/.dynamicstage-%s-off", name);
    snprintf(b, sizeof(b), "/var/jb/var/mobile/.dynamicstage-%s-off", name);
    return access(a, F_OK) == 0 || access(b, F_OK) == 0;
}

// latch749: one loud line at startup listing every feature a crash latch has
// turned off (name, when, why), also written to /var/mobile/DynamicStage-latched.txt.
// Off: latch749-off / core749-off.
static void DSLatch749Report(void) {
    if (DS749FileOff("core749") || !DSFeature699On("latch749")) return;
    @try {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSDateFormatter *f = [NSDateFormatter new];
        f.dateFormat = @"MM-dd HH:mm:ss";
        NSMutableArray *items = [NSMutableArray array];
        for (NSString *dir in @[ @"/var/mobile", @"/var/jb/var/mobile" ]) {
            for (NSString *n in [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[]) {
                if (![n hasPrefix:@".dynamicstage-"] || ![n hasSuffix:@"-crashed"]) continue;
                NSString *name = [[n substringFromIndex:14] stringByReplacingOccurrencesOfString:@"-crashed" withString:@""];
                NSDate *m = [fm attributesOfItemAtPath:[dir stringByAppendingPathComponent:n] error:nil].fileModificationDate;
                [items addObject:[NSString stringWithFormat:@"%@ (latched %@, SpringBoard went down within 15 s of its use; delete %@/%@ to allow it)",
                                  name, m ? [f stringFromDate:m] : @"?", dir, n]];
            }
        }
        NSString *line = items.count
            ? [NSString stringWithFormat:@"LATCHED OFF %lu feature(s): %@", (unsigned long)items.count, [items componentsJoinedByString:@"; "]]
            : @"latch749: no feature is latched off";
        DSDiagnosticsRecord(@"SpringBoard: zone749 home731 / outside726 keep their timer windows (no verified system signal for them); the call tail now follows the call screen");
        // 4.5.798: the one long line was cut at the log's line limit (797 log showed
        // 3 of 9 names). Now a short count line with every name, then one line each.
        if (items.count) {
            NSMutableArray *names = [NSMutableArray array];
            for (NSString *it in items) [names addObject:[it componentsSeparatedByString:@" ("].firstObject ?: it];
            DSDiagnosticsRecordFormat(@"SpringBoard: LATCHED OFF %lu feature(s): %@", (unsigned long)items.count, [names componentsJoinedByString:@", "]);
            NSUInteger k = 0;
            for (NSString *it in items) DSDiagnosticsRecordFormat(@"SpringBoard: latched %lu/%lu %@", (unsigned long)++k, (unsigned long)items.count, it);
        } else {
            DSDiagnosticsRecordFormat(@"SpringBoard: %@", line);
        }
        [line writeToFile:@"/var/mobile/DynamicStage-latched.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *exception) {
    }
}

// safe749: when the boot guard skips the tweak for one start, a light safe mode
// still shows the right-edge Stages tab (a plain window, no hooks, no stage
// features). Tapping it says why the tweak is off and to respring.
// Off: safe749-off / core749-off.
static UIWindow *DSSafe749Window = nil;
static void DSSafe749Tapped(void) {
    UIView *root = DSSafe749Window.rootViewController.view;
    UILabel *label = (UILabel *)[root viewWithTag:749];
    if (label) { label.hidden = !label.hidden; return; }
}
@interface DSSafe749Target : NSObject
@end
@implementation DSSafe749Target
- (void)tap { DSSafe749Tapped(); }
@end
static void DSSafe749Start(NSString *why) {
    if (DS749FileOff("core749") || DS749FileOff("safe749")) return;
    @try {
        UIWindowScene *scene = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:UIWindowScene.class] && s.activationState == UISceneActivationStateForegroundActive) { scene = (UIWindowScene *)s; break; }
        }
        if (!scene) return;
        CGRect screen = scene.coordinateSpace.bounds;
        UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
        w.frame = CGRectMake(CGRectGetWidth(screen) - 300.0, CGRectGetMidY(screen) - 60.0, 300.0, 120.0);
        w.windowLevel = UIWindowLevelAlert - 1.0;
        w.backgroundColor = UIColor.clearColor;
        UIViewController *vc = [UIViewController new];
        vc.view.backgroundColor = UIColor.clearColor;
        w.rootViewController = vc;
        UIControl *tab = [[UIControl alloc] initWithFrame:CGRectMake(286.0, 28.0, 14.0, 64.0)];
        tab.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.94];
        tab.layer.cornerRadius = 8.0;
        tab.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner;
        tab.accessibilityLabel = @"Stages (safe mode)";
        static DSSafe749Target *target;
        target = [DSSafe749Target new];
        [tab addTarget:target action:@selector(tap) forControlEvents:UIControlEventTouchUpInside];
        [vc.view addSubview:tab];
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0.0, 10.0, 278.0, 100.0)];
        label.tag = 749;
        label.numberOfLines = 0;
        label.font = [UIFont systemFontOfSize:13.0];
        label.textColor = UIColor.whiteColor;
        label.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.92];
        label.layer.cornerRadius = 12.0;
        label.clipsToBounds = YES;
        label.text = @"  DynamicStage is in safe mode for this start (it crashed right after the last respring). Respring to turn it back on.";
        label.hidden = YES;
        [vc.view addSubview:label];
        w.hidden = NO;
        DSSafe749Window = w;
        DSDiagnosticsRecordFormat(@"SpringBoard: safe749 safe mode: full tweak skipped (%@); Stages tab shown, no stage features started", why ?: @"?");
    } @catch (NSException *exception) {
    }
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
            // 4.5.674 keys674 (keyboard layer of apps without the app dylib).
            @try {
                DSKeys674Install();
            } @catch (NSException *exception) {
            }
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
            @try { DSKeep776Install(); } @catch (NSException *exception) {
                DSDiagnosticsRecordFormat(@"SpringBoard: keep776 install caught %@", exception.reason ?: exception.name);
            }
            @try { DSWhy775Install(); } @catch (NSException *exception) {
                DSDiagnosticsRecordFormat(@"SpringBoard: why775 install caught %@", exception.reason ?: exception.name);
            }

            [[DSStageManager sharedManager] activate];
            DSLatch749Report();   // 4.5.749 latch749
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

            DSTree765WipeStaleOnBoot();
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
            DSLatch754NoteSafeMode();   // 4.5.754 latch754: safe mode = crash evidence for the next start
            // 4.5.653: stay off for this one start (that is the protection),
            // then let the next respring try again instead of staying off
            // until a reinstall. A real crash loop alternates on / off and
            // never loops SpringBoard.
            DSBootstrapMarkLaunchSucceeded();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                DSDiagnosticsRecord(@"SpringBoard: DynamicStage stayed off for this start after a crash right after the last respring; respring once to turn it back on");
                DSSafe749Start(@"boot guard: SpringBoard crashed within 8 s of the previous start");   // 4.5.749 safe749
            });
            return;
        }
        if (!DSBootstrapBeginFullInstall()) return;

        DSLatch754BootSweep();      // 4.5.754 latch754: decide latches from how the last SpringBoard ended
        DSCrashLogInstallHandlers();
        DSCrashLog754Arm();
        DSBeat756Start();           // 4.5.756 beat756: clean-respring heartbeat
        DSFeature699MarkTrying("latch754");   // crash latch for latch754 itself (15 s after start)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (DSLatch754Summary) DSDiagnosticsRecordFormat(@"SpringBoard: %@", DSLatch754Summary);
        });
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
