#import "DSStageManager.h"
#import "DSSceneHost.h"
#import "DSPreferences.h"
#import "DSGestureController.h"
#import "DSPrivate.h"
#import "DSConstants.h"
#import "DSDiagnostics.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>

// Every hook below is a thin shim over DSStageManager. The rule throughout is
// that a missing or renamed private API must degrade into "the stage does not
// open", never into a SpringBoard crash, so each one bails out early rather
// than assuming its surroundings.

#pragma mark - Boot guard

// The worst thing this tweak could do is crash SpringBoard on the way up, which
// leaves a device respringing and only usable in safe mode. So each launch is
// counted before any hook does anything and the count is cleared once SpringBoard
// has been up for a few seconds. Two launches that never got that far and the
// tweak sits the next one out, which turns a boot loop into a device that comes
// back working with the tweak switched off. Updating or reinstalling the package
// clears the count, and so does the switch on the About page.

static NSInteger DSUncleanLaunchCount(void) {
    NSString *contents = [NSString stringWithContentsOfFile:kDSLaunchGuardPath
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
    return contents.integerValue;
}

static void DSSetUncleanLaunchCount(NSInteger count) {
    if (count <= 0) {
        [[NSFileManager defaultManager] removeItemAtPath:kDSLaunchGuardPath error:NULL];
        return;
    }
    [[NSString stringWithFormat:@"%ld", (long)count] writeToFile:kDSLaunchGuardPath
                                                     atomically:YES
                                                       encoding:NSUTF8StringEncoding
                                                          error:NULL];
}

static BOOL DSTweakEnabled(void) {
    static BOOL enabled;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        if ([[NSFileManager defaultManager] fileExistsAtPath:kDSKillSwitchPath]) return;
        if (DSUncleanLaunchCount() >= kDSMaxUncleanLaunches) return;
        enabled = YES;
    });
    return enabled;
}

// Called once SpringBoard is demonstrably past the point where this tweak could
// have broken the launch.
static void DSNoteLaunchSucceeded(void) {
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            DSSetUncleanLaunchCount(0);
        });
    });
}

#pragma mark - Calling out of a hook

// Private API that moved or changed shape must degrade into "the stage does not
// open", never into a SpringBoard crash, so every call out of a hook and into the
// tweak goes through one of these.
static BOOL DSAsk(BOOL (^question)(DSStageManager *manager)) {
    if (!DSTweakEnabled()) return NO;
    @try {
        return question([DSStageManager sharedManager]);
    } @catch (NSException *exception) {
        return NO;
    }
}

static void DSTell(void (^action)(DSStageManager *manager)) {
    if (!DSTweakEnabled()) return;
    @try {
        action([DSStageManager sharedManager]);
    } @catch (NSException *exception) {
    }
}

#pragma mark - Boot

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    if (!DSTweakEnabled()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        DSTell(^(DSStageManager *manager) {
            [manager activate];
            [manager showIntroIfNeeded];
        });
        DSNoteLaunchSucceeded();
    });
}

// A new front app invalidates Split View, which is bound to the app it was
// opened over.
- (void)frontDisplayDidChange:(id)display {
    %orig;
    DSTell(^(DSStageManager *manager) {
        [manager noteFrontApplicationWillChange];
    });
}

%end

#pragma mark - Scene geometry

// SpringBoard re-pushes a scene's settings on every layout pass, so the stage's
// geometry has to be reapplied on the way through or the hosted app snaps back
// to full screen.
%hook FBScene

- (void)updateSettings:(FBSSceneSettings *)settings withTransitionContext:(id)context completion:(id)completion {
    if (!DSTweakEnabled()) {
        %orig;
        return;
    }
    @try {
        [DSSceneHost noteLiveScene:self];
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
    if (!DSTweakEnabled() || !block) {
        %orig;
        return;
    }
    @try {
        [DSSceneHost noteLiveScene:self];
    } @catch (NSException *exception) {
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

#pragma mark - Scene teardown

%hook FBSceneManager

- (void)destroyScene:(NSString *)identifier withTransitionContext:(id)context {
    if (identifier.length > 0) {
        DSTell(^(DSStageManager *manager) {
            // Scene identifiers are of the form sceneID:<bundle id>-<n>.
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

#pragma mark - Keeping the hosted app's asserts off SpringBoard

// An app view the stage made is not part of SpringBoard's scene layout, so when the
// app it shows changes its mind about being foreground, SpringBoard finds a state it
// did not put there and asserts - which is not an exception that unwinds, it is
// SpringBoard going down. Contained here, and only for the stage's own app views:
// SpringBoard's own must be left to fail loudly as they would without this tweak.
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

#pragma mark - Corner pull

// This is where the stage is opened from. SpringBoard recognises pulls off the
// bottom edge itself, above every window on the display, and reports one here
// before deciding what it means; a pull that started in the stage's corner is
// taken over on the spot and the switcher is never told about it. Anything else
// goes through untouched, so the home gesture keeps working everywhere including
// the corner when the stage has nothing to show.
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

// Once the stage is open the whole card belongs to it, so a swipe up inside the
// card returns to the picker instead of going home.
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

// Older layout of the same manager.
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

#pragma mark - Home affordance

// While a live app is on the stage the system grabber is hidden, so a swipe up
// from the bottom of the card returns to the picker instead of going home.
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

#pragma mark - Status bar

// The status bar keeps belonging to whatever fills the top of the screen; a
// stage scene must never be allowed to claim or hide it.
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

#pragma mark - iPad multitasking capability

// SpringBoard keeps a per-application flag for whether an app may be handed a
// scene that is not the whole display (the iPad multitasking path). An app the
// user has set to iPad mode needs it on, otherwise the resized scene is snapped
// straight back to full screen. It is only lifted for that app, and never for the
// sake of the keyboard: lifting it for every staged app tells SpringBoard that iPad
// multitasking is on screen, and the keyboard it then puts up for its own text
// fields - the stage's search field among them - never arrives.
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

#pragma mark - Orientation

// The stage is portrait only. Letting SpringBoard rotate a hosted scene would
// hand the app a landscape rectangle inside a portrait card.
%hook SBWindowScene

- (BOOL)_shouldAutorotate {
    if (DSAsk(^BOOL(DSStageManager *manager) { return manager.isStageVisible; })) return NO;
    return %orig;
}

%end

#pragma mark - Idle timer

// A stage app that is being watched should not let the display sleep out from
// under it any sooner than a full screen app would.
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

// The staged app says how tall its keyboard is, since SpringBoard cannot see a
// keyboard that another process drew inside its own window.
static int sKeyboardHeightToken = NOTIFY_TOKEN_INVALID;

static void DSStagedAppCheckedIn(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                 const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        DSTell(^(DSStageManager *manager) {
            [manager noteStagedAppCheckedIn];
        });
    });
}

static void DSDeliverKeyboard(CGFloat top, CGFloat height) {
    dispatch_async(dispatch_get_main_queue(), ^{
        DSTell(^(DSStageManager *manager) {
            [manager stagedAppKeyboardChangedTop:top height:height];
        });
    });
}

static BOOL DSReadKeyboardState(CGFloat *top, CGFloat *height) {
    uint64_t state = 0;
    if (sKeyboardHeightToken == NOTIFY_TOKEN_INVALID ||
        notify_get_state(sKeyboardHeightToken, &state) != NOTIFY_STATUS_OK) {
        return NO;
    }
    if (top) *top = (CGFloat)((state >> kDSKeyboardStateTopShift) & kDSKeyboardStateHeightMask);
    if (height) *height = (CGFloat)(state & kDSKeyboardStateHeightMask);
    return YES;
}

static void DSStagedAppKeyboardChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                       const void *object, CFDictionaryRef userInfo) {
    CGFloat top = 0.0;
    CGFloat height = 0.0;
    if (!DSReadKeyboardState(&top, &height)) return;
    DSDeliverKeyboard(top, height);
}

// The height carried by which name was posted, for the case where the app was not
// allowed to write the shared state above. Ten points per step, and no line to cut the
// card at: the card keeps the height it has.
static void DSStagedAppKeyboardStepped(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                       const void *object, CFDictionaryRef userInfo) {
    NSString *posted = (__bridge NSString *)name;
    NSString *prefix = @(kDSKeyboardHeightStepNotificationPrefix);
    if (![posted hasPrefix:prefix]) return;

    CGFloat stepped = [posted substringFromIndex:prefix.length].integerValue * kDSKeyboardHeightStep;

    CGFloat top = 0.0;
    CGFloat exact = 0.0;
    if (DSReadKeyboardState(&top, &exact) && fabs(exact - stepped) <= kDSKeyboardHeightStep) {
        DSDeliverKeyboard(top, exact);
        return;
    }
    DSDeliverKeyboard(0.0, stepped);
}

%ctor {
    if (!DSTweakEnabled()) {
        DSDiagnosticsRecordFormat(@"SpringBoard: hooks not installed (%@)",
                                  [[NSFileManager defaultManager] fileExistsAtPath:kDSKillSwitchPath]
                                      ? @"kill switch file present"
                                      : @"boot guard tripped, two launches did not finish");
        return;
    }

    @try {

    // Counted before a single hook is installed, and cleared again once
    // SpringBoard has been up long enough to call this launch a success.
    DSSetUncleanLaunchCount(DSUncleanLaunchCount() + 1);

    // Asked before anything is hooked, so the answer is about SpringBoard rather
    // than about this tweak's own additions to it.
    Class fluidManager = objc_getClass("SBFluidSwitcherGestureManager");
    BOOL systemPull = fluidManager != Nil &&
        class_getInstanceMethod(fluidManager,
                                @selector(grabberTongueBeganPulling:withDistance:andVelocity:andGesture:)) != NULL;
    [DSStageManager setSystemEdgePullAvailable:systemPull];

    // The rest of the edge pull's shape on this build, written down while it is
    // still stock. If the pull ever needs more of SpringBoard's own sequence than
    // its beginning, this is the list to work from.
    if (fluidManager != Nil) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(fluidManager, &count);
        NSMutableArray<NSString *> *pullMethods = [NSMutableArray array];
        for (unsigned int i = 0; i < count; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            if ([name hasPrefix:@"grabberTongue"]) [pullMethods addObject:name];
        }
        free(methods);
        DSDiagnosticsRecordFormat(@"SpringBoard: edge pull reported through %@",
                                  pullMethods.count > 0 ? [pullMethods componentsJoinedByString:@", "] : @"nothing named like a grabber tongue");
    }

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
    CFNotificationCenterAddObserver(center, NULL, DSStagedAppCheckedIn,
                                    CFSTR(kDSStagedAppCheckedInNotification), NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);
    notify_register_check(kDSKeyboardHeightNotification, &sKeyboardHeightToken);
    CFNotificationCenterAddObserver(center, NULL, DSStagedAppKeyboardChanged,
                                    CFSTR(kDSKeyboardHeightNotification), NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);
    for (int step = 0; step < kDSKeyboardHeightSteps; step++) {
        NSString *name = [NSString stringWithFormat:@"%s%d", kDSKeyboardHeightStepNotificationPrefix, step];
        CFNotificationCenterAddObserver(center, NULL, DSStagedAppKeyboardStepped,
                                        (__bridge CFStringRef)name, NULL,
                                        CFNotificationSuspensionBehaviorCoalesce);
    }

    %init(_ungrouped);

    DSDiagnosticsRecordFormat(@"SpringBoard: hooks installed, corner pull will come from %@",
                              systemPull ? @"the system edge gesture" : @"a window in the corner");

    } @catch (NSException *exception) {
        // Half-installed hooks are still safer than a SpringBoard that will not
        // start: every one of them bails out on its own if the manager is unwell.
    }
}
