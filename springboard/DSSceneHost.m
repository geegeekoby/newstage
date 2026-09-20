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

// Returns YES when the app is already on the stage and no further way in is
// needed; NO means "asked, now wait and see".
typedef BOOL (^DSSceneHostAttempt)(void);

@implementation DSSceneHost {
    FBScene *_scene;
    FBSceneHostManager *_hostManager;
    UIView *_hostView;
    // Only set when the stage had to create the scene itself, which makes the
    // stage responsible for taking it down again.
    UIScenePresenter *_presenter;
    NSString *_ownSceneIdentifier;
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

    // iOS 13 and later: the app keeps scene handles, and a handle holds the scene -
    // asking a handle for its scene rather than for the one it already has is also
    // what brings a scene into being for an app that has none yet.
    for (NSString *name in @[ @"sceneHandles", @"allSceneHandles" ]) {
        SEL selector = NSSelectorFromString(name);
        if (![application respondsToSelector:selector]) continue;
        NSArray *handles = ((NSArray * (*)(id, SEL))objc_msgSend)(application, selector);
        FBScene *scene = [self sceneFromHandles:handles named:name];
        if (scene) return scene;
    }

    for (NSString *name in @[ @"mainSceneHandle", @"defaultSceneHandle", @"primarySceneHandle" ]) {
        SEL selector = NSSelectorFromString(name);
        if (![application respondsToSelector:selector]) continue;
        id handle = ((id (*)(id, SEL))objc_msgSend)(application, selector);
        FBScene *scene = [self sceneFromHandles:handle ? @[ handle ] : @[] named:name];
        if (scene) return scene;
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

// A scene handle is SpringBoard's standing claim on an app's scene, and it answers
// two different questions: the scene it already has, and the scene it should have.
// The second one makes a scene where there was none, which is the difference
// between an app that can be put on the stage and an app that is merely running.
- (FBScene *)sceneFromHandles:(NSArray *)handles named:(NSString *)name {
    for (id handle in handles) {
        for (NSString *accessor in @[ @"sceneIfExists", @"scene" ]) {
            SEL selector = NSSelectorFromString(accessor);
            if (![handle respondsToSelector:selector]) continue;
            FBScene *scene = nil;
            @try {
                scene = ((FBScene * (*)(id, SEL))objc_msgSend)(handle, selector);
            } @catch (NSException *exception) {
                DSDiagnosticsRecordFormat(@"SpringBoard: %@ %@ threw %@",
                                          name, accessor, exception.name ?: @"?");
                continue;
            }
            if (scene) {
                [self noteSceneSource:[NSString stringWithFormat:@"%@ + %@", name, accessor]];
                return scene;
            }
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

    // Three ways of asking for the app, tried in order of how little they disturb
    // the screen, each given long enough for a cold launch on a busy phone. Giving
    // up early looks exactly like the app refusing to open.
    __weak __typeof(self) weakSelf = self;
    NSMutableArray<DSSceneHostAttempt> *attempts = [NSMutableArray array];
    [attempts addObject:^BOOL { [weakSelf launchThroughUIApplication]; return NO; }];
    [attempts addObject:^BOOL { [weakSelf launchThroughSystemService]; return NO; }];
    [attempts addObject:^BOOL { return [weakSelf presentSceneOfOwnMaking]; }];
    [attempts addObject:^BOOL { [weakSelf launchInForeground]; return NO; }];
    [self runLaunchAttempts:attempts completion:completion];
}

// Each attempt either finishes the job on the spot or gives the app another two
// seconds to show up with a scene before the next one is tried.
- (void)runLaunchAttempts:(NSMutableArray<DSSceneHostAttempt> *)attempts
               completion:(DSSceneHostReadyBlock)completion {
    if (attempts.count == 0) {
        // Whether the app is running decides which half of this failed, so it is
        // worth one line: a process that is alive but sceneless is a different
        // problem from one that never started. What SpringBoard was willing to say
        // about the app goes with it, because on a device that cannot hand over a
        // crash log this is the only way to learn which door was the locked one.
        DSDiagnosticsRecordFormat(@"SpringBoard: %@ never produced a scene to put on the stage (process %@)",
                                  _bundleIdentifier,
                                  self.isProcessAlive ? @"is running" : @"is not running");
        [self recordSceneLookupInventory];
        if (completion) completion(NO);
        return;
    }

    DSSceneHostAttempt attempt = attempts.firstObject;
    [attempts removeObjectAtIndex:0];
    BOOL finished = NO;
    @try {
        finished = attempt();
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: launching %@ threw %@", _bundleIdentifier, exception.name ?: @"?");
    }
    if (finished) {
        if (completion) completion(self.isHosting);
        return;
    }

    __weak __typeof(self) weakSelf = self;
    [self waitForSceneWithAttemptsRemaining:40 then:^{
        [weakSelf runLaunchAttempts:attempts completion:completion];
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

// The last thing left to try, and the only one guaranteed to produce a scene:
// open the app the way tapping its icon does. An app opened this way is briefly
// the front app, so whoever was in front before is put back once the app's layer
// has been taken into the card. Not how the stage should open an app - but an app
// on the stage a moment late beats an app that never arrives.
- (void)launchInForeground {
    SpringBoard *springBoard = (SpringBoard *)UIApplication.sharedApplication;
    if (![springBoard respondsToSelector:@selector(launchApplicationWithIdentifier:suspended:)]) return;

    DSDiagnosticsRecordFormat(@"SpringBoard: %@ would not start in the background, opening it the ordinary way",
                              _bundleIdentifier);
    _tookOverForegroundLaunch = YES;
    [springBoard launchApplicationWithIdentifier:_bundleIdentifier suspended:NO];
}

#pragma mark - A scene of the stage's own

// When SpringBoard has no scene for an app and will not make one without opening
// the app full screen, the stage makes its own: a scene created against the app's
// running process and presented in a view here, which is how every current
// iPad-style multitasking project does it. The app connects to it and draws into
// it exactly as it would for one of SpringBoard's.
- (BOOL)presentSceneOfOwnMaking {
    if (_hostView) return YES;
    if (![self isProcessAlive]) return NO;

    NSArray<NSString *> *required = @[
        @"RBSProcessIdentity", @"RBSProcessPredicate", @"RBSProcessHandle",
        @"FBSMutableSceneDefinition", @"FBSSceneIdentity", @"FBSSceneClientIdentity",
        @"UIApplicationSceneSpecification", @"FBSMutableSceneParameters",
        @"UIMutableApplicationSceneSettings", @"UIMutableApplicationSceneClientSettings",
        @"FBSceneManager",
    ];
    for (NSString *name in required) {
        if (objc_getClass(name.UTF8String)) continue;
        DSDiagnosticsRecordFormat(@"SpringBoard: cannot make a scene here, no %@ on this build", name);
        return NO;
    }

    @try {
        RBSProcessIdentity *identity = (RBSProcessIdentity *)[objc_getClass("RBSProcessIdentity")
            identityForEmbeddedApplicationIdentifier:_bundleIdentifier];
        RBSProcessPredicate *predicate =
            (RBSProcessPredicate *)[objc_getClass("RBSProcessPredicate") predicateMatchingIdentity:identity];
        RBSProcessHandle *process =
            (RBSProcessHandle *)[objc_getClass("RBSProcessHandle") handleForPredicate:predicate error:nil];
        if (!process || process.pid <= 0) {
            DSDiagnosticsRecordFormat(@"SpringBoard: %@ has no process to make a scene against", _bundleIdentifier);
            return NO;
        }

        // The stage's own name for it, never SpringBoard's: two scenes under one
        // identity is a fight nobody wins.
        NSString *sceneIdentifier = [NSString stringWithFormat:@"sceneID:%@-dynamicstage", _bundleIdentifier];

        FBSMutableSceneDefinition *definition =
            (FBSMutableSceneDefinition *)[objc_getClass("FBSMutableSceneDefinition") definition];
        definition.identity =
            (FBSSceneIdentity *)[objc_getClass("FBSSceneIdentity") identityForIdentifier:sceneIdentifier];
        definition.clientIdentity = (FBSSceneClientIdentity *)
            [objc_getClass("FBSSceneClientIdentity") identityForProcessIdentity:process.identity];
        definition.specification = [objc_getClass("UIApplicationSceneSpecification") specification];

        FBSMutableSceneParameters *parameters = (FBSMutableSceneParameters *)
            [objc_getClass("FBSMutableSceneParameters") parametersForSpecification:definition.specification];

        CGRect frame = CGRectIsEmpty(_stageFrame) ? UIScreen.mainScreen.bounds : [self logicalFrame];
        FBSMutableSceneSettings *settings = [[objc_getClass("UIMutableApplicationSceneSettings") alloc] init];
        settings.canShowAlerts = YES;
        settings.foreground = YES;
        settings.frame = CGRectMake(0, 0, CGRectGetWidth(frame), CGRectGetHeight(frame));
        settings.interfaceOrientation = UIInterfaceOrientationPortrait;
        settings.deviceOrientation = UIDeviceOrientationPortrait;
        settings.level = 1;
        settings.statusBarDisabled = YES;
        settings.safeAreaInsetsPortrait = _safeAreaInsets;
        if ([settings respondsToSelector:@selector(setDisplayConfiguration:)]) {
            [settings setDisplayConfiguration:[UIScreen.mainScreen displayConfiguration]];
        }
        if ([settings respondsToSelector:@selector(setPersistenceIdentifier:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(settings, @selector(setPersistenceIdentifier:),
                                                  NSUUID.UUID.UUIDString);
        }
        parameters.settings = settings;

        FBSMutableSceneClientSettings *clientSettings =
            [[objc_getClass("UIMutableApplicationSceneClientSettings") alloc] init];
        clientSettings.interfaceOrientation = UIInterfaceOrientationPortrait;
        parameters.clientSettings = clientSettings;

        FBSceneManager *manager = (FBSceneManager *)[objc_getClass("FBSceneManager") sharedInstance];
        if (![manager respondsToSelector:@selector(createSceneWithDefinition:initialParameters:)]) {
            DSDiagnosticsRecord(@"SpringBoard: this build's FrontBoard will not create a scene on request");
            return NO;
        }

        FBScene *scene = [manager createSceneWithDefinition:definition initialParameters:parameters];
        if (!scene) {
            DSDiagnosticsRecordFormat(@"SpringBoard: making a scene for %@ gave back nothing", _bundleIdentifier);
            return NO;
        }

        UIScenePresentationManager *presentation =
            [scene respondsToSelector:@selector(uiPresentationManager)] ? scene.uiPresentationManager : nil;
        UIScenePresenter *presenter = [presentation respondsToSelector:@selector(createPresenterWithIdentifier:)]
            ? [presentation createPresenterWithIdentifier:sceneIdentifier]
            : nil;
        UIView *view = presenter.presentationView;
        if (!view) {
            DSDiagnosticsRecordFormat(@"SpringBoard: %@'s new scene has nothing to show", _bundleIdentifier);
            [manager destroyScene:sceneIdentifier withTransitionContext:nil];
            return NO;
        }

        [presenter activate];

        _scene = scene;
        _presenter = presenter;
        _ownSceneIdentifier = [sceneIdentifier copy];
        _hostView = view;
        _hostView.clipsToBounds = YES;
        [self noteSceneSource:@"a scene the stage made itself"];
        return YES;
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: making a scene for %@ threw %@ - %@",
                                  _bundleIdentifier, exception.name ?: @"?", exception.reason ?: @"?");
        return NO;
    }
}

// Written down only when every way in has failed, and the point of it is the next
// build: it names what this version of SpringBoard has to offer for this app, so
// the path that was missing can be taken rather than guessed at.
- (void)recordSceneLookupInventory {
    NSMutableArray<NSString *> *notes = [NSMutableArray array];
    @try {
        SBApplication *application = [self application];
        SEL base = NSSelectorFromString(@"_baseSceneIdentifier");
        if ([application respondsToSelector:base]) {
            NSString *identifier = ((NSString * (*)(id, SEL))objc_msgSend)(application, base);
            [notes addObject:[NSString stringWithFormat:@"base scene id %@", identifier.length > 0 ? identifier : @"(empty)"]];
        } else {
            [notes addObject:@"no _baseSceneIdentifier"];
        }

        unsigned int count = 0;
        Method *methods = class_copyMethodList([application class], &count);
        NSMutableArray<NSString *> *sceneMethods = [NSMutableArray array];
        for (unsigned int i = 0; i < count && sceneMethods.count < 14; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            if ([name rangeOfString:@"cene"].location == NSNotFound) continue;
            if ([name rangeOfString:@":"].location != NSNotFound) continue;
            [sceneMethods addObject:name];
        }
        free(methods);
        [notes addObject:[NSString stringWithFormat:@"app offers %@",
                          sceneMethods.count > 0 ? [sceneMethods componentsJoinedByString:@" "] : @"nothing scene shaped"]];

        NSArray *live = DSLiveScenes().keyEnumerator.allObjects;
        [notes addObject:[NSString stringWithFormat:@"%lu scenes seen, ending %@",
                          (unsigned long)live.count,
                          live.count > 0 ? [live subarrayWithRange:NSMakeRange(live.count - MIN(live.count, (NSUInteger)3), MIN(live.count, (NSUInteger)3))] : @[]]];
    } @catch (NSException *exception) {
        [notes addObject:[NSString stringWithFormat:@"inventory threw %@", exception.name ?: @"?"]];
    }

    NSString *line = [notes componentsJoinedByString:@"; "];
    if (line.length > 700) line = [line substringToIndex:700];
    DSDiagnosticsRecordFormat(@"SpringBoard: %@", line);
}

- (void)waitForSceneWithAttemptsRemaining:(NSInteger)attempts
                                     then:(void (^)(void))next
                               completion:(DSSceneHostReadyBlock)completion {
    FBScene *scene = [self resolveScene];
    if (scene) {
        _scene = scene;
        [self beginHosting];
        if (completion) completion(self.isHosting);
        return;
    }

    if (attempts <= 0) {
        if (next) next();
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self waitForSceneWithAttemptsRemaining:attempts - 1 then:next completion:completion];
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

// Where on the screen the app should believe it is. A scene borrowed from
// SpringBoard is still positioned on the display, so it keeps the stage's own
// origin; a scene the stage created is presented inside the card and has no
// business anywhere but the card's own corner.
- (CGRect)frameForScene {
    CGRect logical = [self logicalFrame];
    if (!_ownSceneIdentifier) return logical;
    return CGRectMake(0, 0, CGRectGetWidth(logical), CGRectGetHeight(logical));
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
    return @{
        @"frame" : [NSValue valueWithCGRect:[self frameForScene]],
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
    CGRect logical = [self frameForScene];
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

    // A scene the stage made is the stage's to take down, and there is nothing to
    // hand back: the app keeps running, it simply loses this window.
    if (_ownSceneIdentifier) {
        NSString *identifier = _ownSceneIdentifier;
        UIScenePresenter *presenter = _presenter;
        [_hostView removeFromSuperview];
        _ownSceneIdentifier = nil;
        _presenter = nil;
        _hostView = nil;
        _hostManager = nil;
        _scene = nil;
        _tookOverForegroundLaunch = NO;

        @try {
            [presenter deactivate];
            [presenter invalidate];
            FBSceneManager *manager = (FBSceneManager *)[objc_getClass("FBSceneManager") sharedInstance];
            if ([manager respondsToSelector:@selector(destroyScene:withTransitionContext:)]) {
                [manager destroyScene:identifier withTransitionContext:nil];
            }
        } @catch (NSException *exception) {
            DSDiagnosticsRecordFormat(@"SpringBoard: taking down %@'s stage window threw %@",
                                      _bundleIdentifier, exception.name ?: @"?");
        }
        return;
    }

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
    _tookOverForegroundLaunch = NO;
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
