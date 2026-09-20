#import "DSSceneHost.h"
#import "DSConstants.h"
#import "DSPreferences.h"
#import "DSDiagnostics.h"
#import <objc/runtime.h>
#import <objc/message.h>

// Scene identifier -> geometry the stage insists on. Read from the FBScene hook
// on whatever thread SpringBoard happens to update settings on.
static NSMutableDictionary<NSString *, NSDictionary *> *DSSceneOverrides(void) {
    static NSMutableDictionary *overrides;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        overrides = [NSMutableDictionary dictionary];
    });
    return overrides;
}

// Every scene SpringBoard has told to update its settings, which in practice is
// every scene there is. Weak values: this is a way of finding a scene, never a
// reason for one to stay alive.
static NSMapTable<NSString *, FBScene *> *DSLiveScenes(void) {
    static NSMapTable *scenes;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        scenes = [NSMapTable strongToWeakObjectsMapTable];
    });
    return scenes;
}

static NSLock *DSSceneOverridesLock(void) {
    static NSLock *lock;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        lock = [[NSLock alloc] init];
    });
    return lock;
}

// Shared settings writer: prefers the block based API and falls back to the
// mutable-copy + transition context form used on older builds.
static void DSUpdateSceneSettings(FBScene *scene, void (^block)(FBSMutableSceneSettings *settings)) {
    if (!scene || !block) return;
    @try {
        if ([scene respondsToSelector:@selector(updateSettingsWithBlock:)]) {
            [scene updateSettingsWithBlock:block];
            return;
        }
        FBSSceneSettings *current = [scene respondsToSelector:@selector(settings)] ? scene.settings : nil;
        if (![current respondsToSelector:@selector(mutableCopy)]) return;
        FBSMutableSceneSettings *settings = [current mutableCopy];
        block(settings);

        Class contextClass = objc_getClass("FBSSceneTransitionContext");
        id context = contextClass ? [[contextClass alloc] init] : nil;
        if ([scene respondsToSelector:@selector(updateSettings:withTransitionContext:completion:)]) {
            [scene updateSettings:settings withTransitionContext:context completion:nil];
        }
    } @catch (NSException *exception) {
    }
}

// FBSSystemService lives in FrontBoardServices and is not linked here, so the
// singleton is fetched dynamically.
static id DSSystemService(void) {
    Class serviceClass = objc_getClass("FBSSystemService");
    if (!serviceClass) return nil;
    SEL selector = @selector(sharedService);
    if (![serviceClass respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(serviceClass, selector);
}

static void DSApplyGeometry(FBSMutableSceneSettings *settings, CGRect frame, UIEdgeInsets insets) {
    @try {
        settings.frame = frame;
        if ([settings respondsToSelector:@selector(setSafeAreaInsetsPortrait:)]) {
            settings.safeAreaInsetsPortrait = insets;
        }
        if ([settings respondsToSelector:@selector(setInterfaceOrientation:)]) {
            settings.interfaceOrientation = UIInterfaceOrientationPortrait;
        }
    } @catch (NSException *exception) {
    }
}

@implementation DSSceneHost {
    FBScene *_scene;
    FBSceneHostManager *_hostManager;
    UIView *_hostView;
    CGRect _stageFrame;
    UIEdgeInsets _safeAreaInsets;
    BOOL _foreground;
    BOOL _registeredOverride;
    NSString *_sceneSource;
}

- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier {
    if ((self = [super init])) {
        _bundleIdentifier = [bundleIdentifier copy];
        _foreground = YES;
        _contentScale = [DSPreferences sharedPreferences].scale;
    }
    return self;
}

- (void)dealloc {
    [self removeOverride];
}

#pragma mark - Application lookup

- (SBApplication *)application {
    Class controllerClass = objc_getClass("SBApplicationController");
    if (!controllerClass) return nil;
    return [[controllerClass sharedInstance] applicationWithBundleIdentifier:_bundleIdentifier];
}

// An app's scene has been reached several different ways over the years, and the
// one this used - SBApplication's own mainScene - is the oldest of them. On a
// build where it has gone, every launch ended the same way: the app started, no
// scene was ever found, and the stage gave up and went back to the picker. So
// each known shape is tried in turn, ending with asking FrontBoard for every
// scene it has and picking out the one belonging to this app, which needs nothing
// from SBApplication at all. Which one answered is written down once.
- (FBScene *)resolveScene {
    FBScene *scene = [self sceneFromBaseIdentifier];
    if (scene) return scene;
    scene = [self sceneFromApplication];
    if (scene) return scene;
    return [self sceneFromSceneManager];
}

// The replacement for mainScene since iOS 13: the application knows the identifier
// of the scene it would use, and FrontBoard hands over the scene itself if one
// exists under that name.
- (FBScene *)sceneFromBaseIdentifier {
    SBApplication *application = [self application];
    SEL identifierSelector = NSSelectorFromString(@"_baseSceneIdentifier");
    if (![application respondsToSelector:identifierSelector]) return nil;

    NSString *identifier = ((NSString * (*)(id, SEL))objc_msgSend)(application, identifierSelector);
    if (identifier.length == 0) return nil;

    Class managerClass = objc_getClass("FBSceneManager");
    if (![managerClass respondsToSelector:@selector(sharedInstance)]) return nil;
    id manager = ((id (*)(id, SEL))objc_msgSend)(managerClass, @selector(sharedInstance));

    SEL lookup = NSSelectorFromString(@"sceneWithIdentifier:");
    if (![manager respondsToSelector:lookup]) return nil;

    FBScene *scene = ((FBScene * (*)(id, SEL, id))objc_msgSend)(manager, lookup, identifier);
    if (scene) [self noteSceneSource:@"the app's base scene identifier"];
    return scene;
}

- (void)noteSceneSource:(NSString *)source {
    if ([_sceneSource isEqualToString:source]) return;
    _sceneSource = [source copy];
    DSDiagnosticsRecordFormat(@"SpringBoard: %@'s scene came from %@", _bundleIdentifier, source);
}

- (FBScene *)sceneFromApplication {
    SBApplication *application = [self application];
    if (!application) return nil;

    // iOS 13 and later: the app keeps scene handles, and a handle holds the scene
    // once one exists.
    for (NSString *name in @[ @"sceneHandles", @"allSceneHandles" ]) {
        SEL selector = NSSelectorFromString(name);
        if (![application respondsToSelector:selector]) continue;
        NSArray *handles = ((NSArray * (*)(id, SEL))objc_msgSend)(application, selector);
        for (id handle in handles) {
            for (NSString *accessor in @[ @"sceneIfExists", @"scene" ]) {
                SEL sceneSelector = NSSelectorFromString(accessor);
                if (![handle respondsToSelector:sceneSelector]) continue;
                FBScene *scene = ((FBScene * (*)(id, SEL))objc_msgSend)(handle, sceneSelector);
                if (scene) {
                    [self noteSceneSource:[NSString stringWithFormat:@"%@ + %@", name, accessor]];
                    return scene;
                }
            }
        }
    }

    if ([application respondsToSelector:@selector(mainScene)]) {
        FBScene *scene = application.mainScene;
        if (scene) {
            [self noteSceneSource:@"mainScene"];
            return scene;
        }
    }

    for (NSString *name in @[ @"allScenes", @"scenes" ]) {
        SEL selector = NSSelectorFromString(name);
        if (![application respondsToSelector:selector]) continue;
        NSArray *scenes = ((NSArray * (*)(id, SEL))objc_msgSend)(application, selector);
        if (scenes.count > 0) {
            [self noteSceneSource:name];
            return scenes.firstObject;
        }
    }
    return nil;
}

- (FBScene *)sceneFromSceneManager {
    Class managerClass = objc_getClass("FBSceneManager");
    if ([managerClass respondsToSelector:@selector(sharedInstance)]) {
        id manager = ((id (*)(id, SEL))objc_msgSend)(managerClass, @selector(sharedInstance));
        for (NSString *name in @[ @"scenes", @"allScenes" ]) {
            SEL selector = NSSelectorFromString(name);
            if (![manager respondsToSelector:selector]) continue;
            NSArray *scenes = ((NSArray * (*)(id, SEL))objc_msgSend)(manager, selector);
            FBScene *match = [self sceneMatchingBundleIdentifierIn:scenes];
            if (match) {
                [self noteSceneSource:[NSString stringWithFormat:@"FBSceneManager %@", name]];
                return match;
            }
        }
    }

    // Last resort, and the one that needs nothing from anybody: every scene in
    // SpringBoard pushes settings through the hooks in Tweak.xm, so they are all
    // known here by the time they matter.
    FBScene *seen = [DSSceneHost liveSceneForBundleIdentifier:_bundleIdentifier];
    if (seen) [self noteSceneSource:@"scenes seen going past the settings hook"];
    return seen;
}

- (FBScene *)sceneMatchingBundleIdentifierIn:(NSArray *)scenes {
    for (FBScene *scene in scenes) {
        if (![scene respondsToSelector:@selector(identifier)]) continue;
        // Scene identifiers carry the bundle identifier of whoever owns them, as
        // in "sceneID:com.apple.Maps-default".
        if ([scene.identifier rangeOfString:_bundleIdentifier].location == NSNotFound) continue;
        return scene;
    }
    return nil;
}

#pragma mark - Launching

- (void)prepareWithCompletion:(DSSceneHostReadyBlock)completion {
    if (![self application]) {
        DSDiagnosticsRecordFormat(@"SpringBoard: SpringBoard has no application called %@", _bundleIdentifier);
        if (completion) completion(NO);
        return;
    }

    FBScene *scene = [self resolveScene];
    if (scene) {
        _scene = scene;
        [self beginHosting];
        if (completion) completion(self.isHosting);
        return;
    }

    // Two ways of asking for the app, neither of which brings it to the front, and
    // a wait long enough for a cold launch on a busy phone. Giving up early looks
    // exactly like the app refusing to open.
    [self launchThroughUIApplication];
    [self waitForSceneWithAttemptsRemaining:40 thenTry:^{
        [self launchThroughSystemService];
    } completion:completion];
}

- (void)launchThroughUIApplication {
    SpringBoard *springBoard = (SpringBoard *)UIApplication.sharedApplication;
    if (![springBoard respondsToSelector:@selector(launchApplicationWithIdentifier:suspended:)]) {
        DSDiagnosticsRecord(@"SpringBoard: this build has no launchApplicationWithIdentifier:suspended:");
        return;
    }
    // Suspended, so SpringBoard does not run a front-app transition; the scene is
    // forced foreground once it exists.
    [springBoard launchApplicationWithIdentifier:_bundleIdentifier suspended:YES];
}

- (void)launchThroughSystemService {
    id service = DSSystemService();
    if (![service respondsToSelector:@selector(openApplication:options:withResult:)]) {
        DSDiagnosticsRecord(@"SpringBoard: no second way to launch an app on this build");
        return;
    }
    DSDiagnosticsRecordFormat(@"SpringBoard: %@ has no scene yet, asking FrontBoard directly", _bundleIdentifier);
    NSDictionary *options = @{ @"__ActivateSuspended" : @YES };
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(service, @selector(openApplication:options:withResult:), _bundleIdentifier, options, nil);
}

- (void)waitForSceneWithAttemptsRemaining:(NSInteger)attempts
                                  thenTry:(void (^)(void))fallback
                               completion:(DSSceneHostReadyBlock)completion {
    FBScene *scene = [self resolveScene];
    if (scene) {
        _scene = scene;
        [self beginHosting];
        if (completion) completion(self.isHosting);
        return;
    }

    if (attempts <= 0) {
        if (fallback) {
            fallback();
            [self waitForSceneWithAttemptsRemaining:60 thenTry:nil completion:completion];
            return;
        }
        // Whether the app is running decides which half of this failed, so it is
        // worth one line: a process that is alive but sceneless is a different
        // problem from one that never started.
        DSDiagnosticsRecordFormat(@"SpringBoard: %@ never produced a scene to put on the stage (process %@)",
                                  _bundleIdentifier,
                                  self.isProcessAlive ? @"is running" : @"is not running");
        if (completion) completion(NO);
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self waitForSceneWithAttemptsRemaining:attempts - 1 thenTry:fallback completion:completion];
    });
}

#pragma mark - Hosting

- (void)beginHosting {
    if (!_scene || _hostView) return;
    if (![_scene respondsToSelector:@selector(hostManagerForRequester:)]) {
        DSDiagnosticsRecord(@"SpringBoard: this build's scenes cannot be hosted by a requester");
        return;
    }

    @try {
        _hostManager = [_scene hostManagerForRequester:kDSRequester];
        if (![_hostManager respondsToSelector:@selector(hostViewForRequester:enableAndOrderFront:)]) {
            DSDiagnosticsRecord(@"SpringBoard: the scene host manager has no host view to give");
            return;
        }
        _hostView = [_hostManager hostViewForRequester:kDSRequester enableAndOrderFront:YES];
        _hostView.clipsToBounds = YES;
        if (!_hostView) DSDiagnosticsRecordFormat(@"SpringBoard: hosting %@ gave back no view", _bundleIdentifier);
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: hosting %@ threw %@ - %@",
                                  _bundleIdentifier, exception.name ?: @"?", exception.reason ?: @"?");
        _hostManager = nil;
        _hostView = nil;
    }
}

- (BOOL)isHosting {
    return _hostView != nil;
}

#pragma mark - Geometry

- (void)setStageFrame:(CGRect)frame safeAreaInsets:(UIEdgeInsets)insets {
    _contentScale = [DSPreferences sharedPreferences].scale;
    _stageFrame = frame;
    _safeAreaInsets = insets;
    [self registerOverride];
    [self pushSettings];
    [self layoutHostView];
}

- (CGRect)logicalFrame {
    CGFloat scale = _contentScale > 0 ? _contentScale : 1.0;
    return CGRectMake(CGRectGetMinX(_stageFrame),
                      CGRectGetMinY(_stageFrame),
                      CGRectGetWidth(_stageFrame) * scale,
                      CGRectGetHeight(_stageFrame) * scale);
}

- (void)layoutHostView {
    if (!_hostView) return;
    CGRect logical = [self logicalFrame];
    CGFloat scale = _contentScale > 0 ? 1.0 / _contentScale : 1.0;

    _hostView.transform = CGAffineTransformIdentity;
    _hostView.frame = CGRectMake(0, 0, CGRectGetWidth(logical), CGRectGetHeight(logical));
    _hostView.transform = CGAffineTransformMakeScale(scale, scale);
    _hostView.center = CGPointMake(CGRectGetWidth(_stageFrame) / 2.0, CGRectGetHeight(_stageFrame) / 2.0);
}

- (void)setForeground:(BOOL)foreground {
    _foreground = foreground;
    [self registerOverride];
    [self pushSettings];
}

- (NSDictionary *)overrideDescription {
    CGRect logical = [self logicalFrame];
    return @{
        @"frame" : [NSValue valueWithCGRect:logical],
        @"insets" : [NSValue valueWithUIEdgeInsets:_safeAreaInsets],
        @"foreground" : @(_foreground),
    };
}

- (void)registerOverride {
    NSString *identifier = [_scene respondsToSelector:@selector(identifier)] ? _scene.identifier : nil;
    if (identifier.length == 0) return;
    [DSSceneOverridesLock() lock];
    DSSceneOverrides()[identifier] = [self overrideDescription];
    [DSSceneOverridesLock() unlock];
    _registeredOverride = YES;
}

- (void)removeOverride {
    if (!_registeredOverride) return;
    NSString *identifier = [_scene respondsToSelector:@selector(identifier)] ? _scene.identifier : nil;
    if (identifier.length == 0) return;
    [DSSceneOverridesLock() lock];
    [DSSceneOverrides() removeObjectForKey:identifier];
    [DSSceneOverridesLock() unlock];
    _registeredOverride = NO;
}

- (void)pushSettings {
    if (!_scene) return;
    CGRect logical = [self logicalFrame];
    UIEdgeInsets insets = _safeAreaInsets;
    BOOL foreground = _foreground;

    [self updateSceneSettings:^(FBSMutableSceneSettings *settings) {
        @try {
            settings.frame = logical;
            if ([settings respondsToSelector:@selector(setSafeAreaInsetsPortrait:)]) {
                settings.safeAreaInsetsPortrait = insets;
            }
            if ([settings respondsToSelector:@selector(setInterfaceOrientation:)]) {
                settings.interfaceOrientation = UIInterfaceOrientationPortrait;
            }
            if ([settings respondsToSelector:@selector(setDeviceOrientation:)]) {
                settings.deviceOrientation = UIDeviceOrientationPortrait;
            }
            if ([settings respondsToSelector:@selector(setForeground:)]) settings.foreground = foreground;
            if ([settings respondsToSelector:@selector(setBackgrounded:)]) settings.backgrounded = !foreground;
            if ([settings respondsToSelector:@selector(setOccluded:)]) settings.occluded = NO;
            if ([settings respondsToSelector:@selector(setDeactivated:)]) settings.deactivated = NO;
            if ([settings respondsToSelector:@selector(setStatusBarDisabled:)]) settings.statusBarDisabled = YES;
        } @catch (NSException *exception) {
        }
    }];
}

- (void)updateSceneSettings:(void (^)(FBSMutableSceneSettings *settings))block {
    DSUpdateSceneSettings(_scene, block);
}

#pragma mark - Teardown

- (void)relinquishKeepingBackgrounded:(BOOL)background {
    [self removeOverride];

    // Restore a sane full screen geometry before handing the scene back, so the
    // app is not left thinking it is stage sized next time it is launched.
    CGRect screenBounds = UIScreen.mainScreen.bounds;
    UIEdgeInsets screenInsets = UIEdgeInsetsZero;
    UIWindow *window = UIApplication.sharedApplication.windows.firstObject;
    if (@available(iOS 11.0, *)) screenInsets = window.safeAreaInsets;

    [self updateSceneSettings:^(FBSMutableSceneSettings *settings) {
        @try {
            settings.frame = screenBounds;
            if ([settings respondsToSelector:@selector(setSafeAreaInsetsPortrait:)]) {
                settings.safeAreaInsetsPortrait = screenInsets;
            }
            if ([settings respondsToSelector:@selector(setStatusBarDisabled:)]) settings.statusBarDisabled = NO;
            if ([settings respondsToSelector:@selector(setForeground:)]) settings.foreground = NO;
            if ([settings respondsToSelector:@selector(setBackgrounded:)]) settings.backgrounded = background;
        } @catch (NSException *exception) {
        }
    }];

    @try {
        if ([_hostManager respondsToSelector:@selector(disableHostingForRequester:)]) {
            [_hostManager disableHostingForRequester:kDSRequester];
        }
    } @catch (NSException *exception) {
    }

    [_hostView removeFromSuperview];
    _hostView = nil;
    _hostManager = nil;
    _scene = nil;
}

- (void)terminate {
    NSString *identifier = _bundleIdentifier;
    SBApplication *application = [self application];
    [self relinquishKeepingBackgrounded:NO];

    // SBApplication's own killer is the polite path: it tears down the scene
    // bookkeeping SpringBoard keeps alongside the process.
    SEL killer = @selector(killForReason:andReport:withDescription:);
    if ([application respondsToSelector:killer]) {
        @try {
            ((void (*)(id, SEL, NSInteger, BOOL, id))objc_msgSend)(application, killer, 1, NO, @"Dynamic Stage");
            return;
        } @catch (NSException *exception) {
        }
    }

    id service = DSSystemService();
    SEL selector = @selector(terminateApplication:forReason:andReport:withDescription:);
    if (![service respondsToSelector:selector]) return;
    @try {
        ((void (*)(id, SEL, id, NSInteger, BOOL, id))objc_msgSend)(service, selector, identifier, 1, NO, @"Dynamic Stage");
    } @catch (NSException *exception) {
    }
}

- (BOOL)isProcessAlive {
    SBApplication *application = [self application];
    if (!application) return NO;
    @try {
        if ([application respondsToSelector:@selector(isRunning)]) {
            return ((BOOL (*)(id, SEL))objc_msgSend)(application, @selector(isRunning));
        }
        if ([application respondsToSelector:@selector(process)]) {
            id process = ((id (*)(id, SEL))objc_msgSend)(application, @selector(process));
            return process != nil;
        }
    } @catch (NSException *exception) {
    }
    return _scene != nil;
}

#pragma mark - Override application

+ (BOOL)applyOverridesToSettings:(FBSMutableSceneSettings *)settings forScene:(FBScene *)scene {
    if (!settings || ![scene respondsToSelector:@selector(identifier)]) return NO;
    NSString *identifier = scene.identifier;
    if (identifier.length == 0) return NO;

    [DSSceneOverridesLock() lock];
    NSDictionary *override = DSSceneOverrides()[identifier];
    [DSSceneOverridesLock() unlock];
    if (!override) return NO;

    DSApplyGeometry(settings, [override[@"frame"] CGRectValue], [override[@"insets"] UIEdgeInsetsValue]);
    if ([override[@"geometryOnly"] boolValue]) return YES;

    @try {
        if ([settings respondsToSelector:@selector(setForeground:)]) {
            settings.foreground = [override[@"foreground"] boolValue];
        }
        if ([settings respondsToSelector:@selector(setStatusBarDisabled:)]) settings.statusBarDisabled = YES;
    } @catch (NSException *exception) {
        return NO;
    }
    return YES;
}

+ (void)noteLiveScene:(FBScene *)scene {
    if (![scene respondsToSelector:@selector(identifier)]) return;
    NSString *identifier = scene.identifier;
    if (identifier.length == 0) return;

    [DSSceneOverridesLock() lock];
    [DSLiveScenes() setObject:scene forKey:identifier];
    [DSSceneOverridesLock() unlock];
}

+ (FBScene *)liveSceneForBundleIdentifier:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0) return nil;

    [DSSceneOverridesLock() lock];
    FBScene *found = nil;
    for (NSString *identifier in DSLiveScenes().keyEnumerator.allObjects) {
        if ([identifier rangeOfString:bundleIdentifier].location == NSNotFound) continue;
        FBScene *scene = [DSLiveScenes() objectForKey:identifier];
        if (scene) {
            found = scene;
            break;
        }
    }
    [DSSceneOverridesLock() unlock];
    return found;
}

+ (void)registerGeometryOverrideForScene:(FBScene *)scene frame:(CGRect)frame insets:(UIEdgeInsets)insets {
    NSString *identifier = [scene respondsToSelector:@selector(identifier)] ? scene.identifier : nil;
    if (identifier.length == 0) return;

    [DSSceneOverridesLock() lock];
    DSSceneOverrides()[identifier] = @{
        @"frame" : [NSValue valueWithCGRect:frame],
        @"insets" : [NSValue valueWithUIEdgeInsets:insets],
        @"geometryOnly" : @YES,
    };
    [DSSceneOverridesLock() unlock];

    DSUpdateSceneSettings(scene, ^(FBSMutableSceneSettings *settings) {
        DSApplyGeometry(settings, frame, insets);
    });
}

+ (void)removeGeometryOverrideForScene:(FBScene *)scene restoringFrame:(CGRect)frame insets:(UIEdgeInsets)insets {
    NSString *identifier = [scene respondsToSelector:@selector(identifier)] ? scene.identifier : nil;
    if (identifier.length == 0) return;

    [DSSceneOverridesLock() lock];
    [DSSceneOverrides() removeObjectForKey:identifier];
    [DSSceneOverridesLock() unlock];

    DSUpdateSceneSettings(scene, ^(FBSMutableSceneSettings *settings) {
        DSApplyGeometry(settings, frame, insets);
    });
}

@end
