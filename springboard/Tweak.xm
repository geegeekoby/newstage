#import "DSStageManager.h"
#import "DSSceneHost.h"
#import "DSPreferences.h"
#import "DSGestureController.h"
#import "DSPrivate.h"
#import "DSConstants.h"
#import <objc/runtime.h>
#import <objc/message.h>

// Every hook below is a thin shim over DSStageManager. The rule throughout is
// that a missing or renamed private API must degrade into "the stage does not
// open", never into a SpringBoard crash, so each one bails out early rather
// than assuming its surroundings.

static BOOL DSTweakEnabled(void) {
    static BOOL killed;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        killed = [[NSFileManager defaultManager] fileExistsAtPath:kDSKillSwitchPath];
    });
    return !killed;
}

#pragma mark - Boot

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    if (!DSTweakEnabled()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[DSStageManager sharedManager] activate];
        [[DSStageManager sharedManager] showIntroIfNeeded];
    });
}

// A new front app invalidates Split View, which is bound to the app it was
// opened over.
- (void)frontDisplayDidChange:(id)display {
    %orig;
    if (!DSTweakEnabled()) return;
    [[DSStageManager sharedManager] noteFrontApplicationWillChange];
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
    if (DSTweakEnabled() && identifier.length > 0) {
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
        [[DSStageManager sharedManager] noteSceneDestroyedForBundleIdentifier:bundleIdentifier];
    }
    %orig;
}

%end

%hook SBApplication

- (void)applicationProcessDidExit:(id)process withContext:(id)context {
    %orig;
    if (!DSTweakEnabled()) return;
    NSString *identifier = self.bundleIdentifier;
    if (identifier.length == 0) return;
    [[DSStageManager sharedManager] noteSceneDestroyedForBundleIdentifier:identifier];
}

%end

#pragma mark - Home gesture

// The stage owns the bottom-right corner. In the corner the system home gesture
// has to stand down so the pull is picked up on its first frame; once the stage
// is open the whole card belongs to it.
%hook SBFluidSwitcherGestureManager

- (BOOL)shouldBeginGestureAtStartingPoint:(CGPoint)point velocity:(CGPoint)velocity bounds:(CGRect)bounds {
    if (DSTweakEnabled() && [[DSStageManager sharedManager] shouldSuppressSystemGestureAtPoint:point]) {
        return NO;
    }
    return %orig;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    if (DSTweakEnabled()) {
        CGPoint point = [touch locationInView:nil];
        if ([[DSStageManager sharedManager] shouldSuppressSystemGestureAtPoint:point]) return NO;
    }
    return %orig;
}

%end

// Older layout of the same manager.
%hook SBSystemGestureManager

- (BOOL)shouldBeginGestureAtStartingPoint:(CGPoint)point velocity:(CGPoint)velocity bounds:(CGRect)bounds {
    if (DSTweakEnabled() && [[DSStageManager sharedManager] shouldSuppressSystemGestureAtPoint:point]) {
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
    if (DSTweakEnabled() && [[DSStageManager sharedManager] shouldHideSystemHomeAffordance]) {
        %orig(0.0);
        return;
    }
    %orig;
}

- (void)didMoveToWindow {
    %orig;
    if (DSTweakEnabled() && [[DSStageManager sharedManager] shouldHideSystemHomeAffordance]) {
        self.alpha = 0.0;
    }
}

%end

#pragma mark - Status bar

// The status bar keeps belonging to whatever fills the top of the screen; a
// stage scene must never be allowed to claim or hide it.
%hook SBMainDisplaySceneManager

- (void)_applyStatusBarHidden:(BOOL)hidden withAnimation:(NSInteger)animation toSceneWithIdentifier:(NSString *)identifier {
    if (DSTweakEnabled()) {
        NSString *stage = [DSStageManager sharedManager].stageBundleIdentifier;
        if (stage.length > 0 && [identifier containsString:stage]) return;
    }
    %orig;
}

%end

#pragma mark - iPad multitasking capability

// SpringBoard keeps a per-application flag for whether an app may be handed a
// scene that is not the whole display (the iPad multitasking path). An app the
// user has set to iPad mode needs it on, otherwise the resized scene is snapped
// straight back to full screen. It is only lifted for the app on the stage, so
// nothing else in SpringBoard changes behaviour.
static BOOL DSShouldForceMedusaForIdentifier(NSString *identifier) {
    if (!DSTweakEnabled() || identifier.length == 0) return NO;
    DSStageManager *manager = [DSStageManager sharedManager];
    if (![identifier isEqualToString:manager.stageBundleIdentifier]) return NO;
    return [[DSPreferences sharedPreferences] launchTypeForApplication:identifier] == DSLaunchTypePad;
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
    if (DSTweakEnabled() && [DSStageManager sharedManager].isStageVisible) return NO;
    return %orig;
}

%end

#pragma mark - Idle timer

// A stage app that is being watched should not let the display sleep out from
// under it any sooner than a full screen app would.
%hook SBLockScreenManager

- (BOOL)_shouldAutoLock {
    if (DSTweakEnabled() && [DSStageManager sharedManager].isStageVisible) return NO;
    return %orig;
}

%end

%hook SBBacklightController

- (void)_setBacklightFactorForCurrentState {
    %orig;
    if (!DSTweakEnabled()) return;
    if ([self respondsToSelector:@selector(screenIsOn)] && ![self screenIsOn]) {
        [[DSStageManager sharedManager] noteDisplayDidTurnOff];
    }
}

%end

#pragma mark - Notifications

static void DSPreferencesChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                 const void *object, CFDictionaryRef userInfo) {
    [[DSPreferences sharedPreferences] reload];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[DSStageManager sharedManager] preferencesChanged];
    });
}

static void DSRotateStage(CFNotificationCenterRef center, void *observer, CFStringRef name,
                          const void *object, CFDictionaryRef userInfo) {
    NSString *notification = (__bridge NSString *)name;
    NSInteger turns = 0;
    if ([notification hasSuffix:@".left"]) turns = -1;
    else if ([notification hasSuffix:@".right"]) turns = 1;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[DSStageManager sharedManager] rotateStageBy:turns];
    });
}

static void DSCloseStage(CFNotificationCenterRef center, void *observer, CFStringRef name,
                         const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[DSStageManager sharedManager] closeStageAnimated:YES];
    });
}

%ctor {
    if (!DSTweakEnabled()) return;

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

    %init(_ungrouped);
}
