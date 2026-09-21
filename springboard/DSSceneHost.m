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

// The app view controllers the stage made, so the hook that contains their asserts
// can tell them from SpringBoard's own. Weak: this is a way of recognising them,
// never a reason for one to stay alive.
static NSHashTable *DSOwnedAppViewControllers(void) {
    static NSHashTable *controllers;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        controllers = [NSHashTable weakObjectsHashTable];
    });
    return controllers;
}

static id DSIvar(id object, NSString *name) {
    if (!object || name.length == 0) return nil;
    Ivar ivar = class_getInstanceVariable([object class], name.UTF8String);
    if (!ivar) return nil;
    @try {
        return object_getIvar(object, ivar);
    } @catch (NSException *exception) {
        return nil;
    }
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
    // SpringBoard's own app view, when it could be had.
    SBAppViewController *_appViewController;
    SBDeviceApplicationSceneEntity *_entity;
    // Only set when the stage had to create the scene itself, which makes the
    // stage responsible for taking it down again.
    UIScenePresenter *_presenter;
    NSString *_ownSceneIdentifier;
    BOOL _nudgedThisLaunch;
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

#pragma mark - SpringBoard's own app view

// The way the app switcher and iPad multitasking put a live app in a view. Handing
// the job to SpringBoard is the difference between the stage assembling a scene out
// of parts - launching the app, finding the scene, hosting its layers, forcing its
// size, and hoping keyboard focus follows - and simply asking for an app view. It
// launches the app itself, so nothing needs to be started first.
- (BOOL)hostThroughAppViewController {
    if (_appViewController) return YES;

    SBApplication *application = [self application];
    UIViewController *parent = self.parentViewController;
    if (!application || !parent) return NO;

    Class entityClass = objc_getClass("SBDeviceApplicationSceneEntity");
    Class viewControllerClass = objc_getClass("SBAppViewController");
    if (!entityClass || !viewControllerClass) {
        DSDiagnosticsRecord(@"SpringBoard: no app view controller on this build, falling back to raw hosting");
        return NO;
    }

    @try {
        id sceneManager = [self mainDisplaySceneManager];
        id displayIdentity = [sceneManager respondsToSelector:@selector(displayIdentity)]
            ? ((id (*)(id, SEL))objc_msgSend)(sceneManager, @selector(displayIdentity))
            : nil;

        // Which of these a build has changes with the iOS version, and the later ones
        // are not simply newer names for the earlier: the "generating new primary
        // scene" one is the only one that promises a scene for an app that has none,
        // which is the case the stage exists for.
        SBDeviceApplicationSceneEntity *entity = nil;
        NSString *entityRoute = nil;

        SEL withProvider = NSSelectorFromString(@"defaultEntityWithApplication:sceneHandleProvider:displayIdentity:");
        if (!entity && sceneManager && displayIdentity && [entityClass respondsToSelector:withProvider]) {
            entity = ((id (*)(id, SEL, id, id, id))objc_msgSend)(entityClass, withProvider,
                                                                 application, sceneManager, displayIdentity);
            entityRoute = @"default entity with a scene handle provider";
        }

        SEL generating = NSSelectorFromString(@"initWithApplicationForMainDisplay:generatingNewPrimarySceneIfRequired:");
        if (!entity && [entityClass instancesRespondToSelector:generating]) {
            entity = ((id (*)(id, SEL, id, BOOL))objc_msgSend)([entityClass alloc], generating, application, YES);
            entityRoute = @"entity that makes a scene if the app has none";
        }

        SEL defaultForMainDisplay = NSSelectorFromString(@"defaultEntityWithApplicationForMainDisplay:");
        if (!entity && [entityClass respondsToSelector:defaultForMainDisplay]) {
            entity = ((id (*)(id, SEL, id))objc_msgSend)(entityClass, defaultForMainDisplay, application);
            entityRoute = @"default entity for the main display";
        }

        if (!entity && [entityClass instancesRespondToSelector:@selector(initWithApplicationForMainDisplay:)]) {
            entity = [[entityClass alloc] initWithApplicationForMainDisplay:application];
            entityRoute = @"plain entity for the main display";
        }

        if (!entity) {
            DSDiagnosticsRecordFormat(@"SpringBoard: no scene entity for %@ - none of the ways of asking exist here",
                                      _bundleIdentifier);
            return NO;
        }
        DSDiagnosticsRecordFormat(@"SpringBoard: %@ got its %@", _bundleIdentifier, entityRoute);

        SBAppViewController *controller =
            [[viewControllerClass alloc] initWithIdentifier:_bundleIdentifier andApplicationSceneEntity:entity];
        if (!controller) {
            DSDiagnosticsRecordFormat(@"SpringBoard: no app view controller for %@", _bundleIdentifier);
            return NO;
        }

        _entity = entity;
        _appViewController = controller;
        [DSOwnedAppViewControllers() addObject:controller];

        [parent addChildViewController:controller];
        if ([controller respondsToSelector:@selector(setIgnoresOcclusions:)]) {
            [controller setIgnoresOcclusions:NO];
        }
        // The app view runs the app's lifecycle from its own view's appearance, which
        // is what the stage wants: the app is awake while the card is on screen and
        // suspends when it is put away, decided by SpringBoard rather than dictated to
        // it from outside.
        if ([controller respondsToSelector:@selector(setAutomatesLifecycle:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setAutomatesLifecycle:), YES);
        }
        // Mode 2 is the live one. Anything else and the view shows a snapshot.
        if ([controller respondsToSelector:@selector(_setCurrentMode:)]) [controller _setCurrentMode:2];

        // Told before the app starts, so it launches at the card's size instead of
        // launching full screen and being cut down afterwards.
        [self setContentReferenceSizeOnAppView];

        // Activation settings left over from however the app was last opened decide
        // things like orientation and whether it animates; cleared so the stage's
        // own settings are the only ones in play.
        id activationSettings = DSIvar(controller, @"_activationSettings");
        if ([activationSettings respondsToSelector:@selector(clearActivationSettings)]) {
            ((void (*)(id, SEL))objc_msgSend)(activationSettings, @selector(clearActivationSettings));
        }

        [self beginSceneTransactionDeliveringActions:YES];

        if ([controller respondsToSelector:@selector(_createSceneViewController)]) {
            [controller _createSceneViewController];
        }
        // 4 is live content: the app's own render rather than a still of it.
        if ([controller respondsToSelector:@selector(setDisplayMode:animationFactory:completion:)]) {
            [controller setDisplayMode:4 animationFactory:nil completion:nil];
        }
        // An app that is only hosted is on screen but asleep; this is what makes it
        // the running, typed-into app the stage is supposed to be showing.
        if ([controller respondsToSelector:NSSelectorFromString(@"_activateApp")]) {
            ((void (*)(id, SEL))objc_msgSend)(controller, NSSelectorFromString(@"_activateApp"));
        }

        UIView *view = controller.view;
        if (!view) {
            DSDiagnosticsRecordFormat(@"SpringBoard: %@'s app view controller has no view", _bundleIdentifier);
            [self tearDownAppViewController];
            return NO;
        }
        view.backgroundColor = UIColor.clearColor;
        view.clipsToBounds = YES;
        _hostView = view;

        [self noteSceneSource:@"SpringBoard's own app view"];
        [self reportHostingOutcome];
        return YES;
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: asking for an app view for %@ threw %@ - %@",
                                  _bundleIdentifier, exception.name ?: @"?", exception.reason ?: @"?");
        [self tearDownAppViewController];
        return NO;
    }
}

// "It showed the logo and went back to the picker" and "the app is there but has
// not drawn yet" look identical from outside, so the app view is asked once it has
// had time to start, and the answer is written down.
- (void)reportHostingOutcome {
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        SBAppViewController *controller = strongSelf ? strongSelf->_appViewController : nil;
        if (!controller) return;
        @try {
            SEL hosting = NSSelectorFromString(@"isHostingAnApp");
            BOOL isHosting = [controller respondsToSelector:hosting]
                ? ((BOOL (*)(id, SEL))objc_msgSend)(controller, hosting)
                : NO;
            FBScene *scene = [strongSelf appViewScene];
            DSDiagnosticsRecordFormat(@"SpringBoard: %@ after two seconds - %@, %@, view %@",
                                      strongSelf->_bundleIdentifier,
                                      isHosting ? @"hosting the app" : @"not hosting anything",
                                      scene ? @"scene present" : @"no scene",
                                      controller.view.superview ? @"in the card" : @"not in the card");
        } @catch (NSException *exception) {
        }
    });
}

- (id)mainDisplaySceneManager {
    return [DSSceneHost mainDisplaySceneManager];
}

+ (id)mainDisplaySceneManager {
    Class coordinator = objc_getClass("SBSceneManagerCoordinator");
    if (!coordinator) return nil;
    if ([coordinator respondsToSelector:@selector(mainDisplaySceneManager)]) {
        return ((id (*)(id, SEL))objc_msgSend)(coordinator, @selector(mainDisplaySceneManager));
    }
    if ([coordinator respondsToSelector:@selector(sharedInstance)]) {
        id shared = ((id (*)(id, SEL))objc_msgSend)(coordinator, @selector(sharedInstance));
        if ([shared respondsToSelector:@selector(mainDisplaySceneManager)]) {
            return ((id (*)(id, SEL))objc_msgSend)(shared, @selector(mainDisplaySceneManager));
        }
    }
    return nil;
}

// Every size change has to go through one of these or the app keeps drawing for
// whatever size it was given last. Actions are delivered only on the first one,
// which is what launches the app.
- (void)beginSceneTransactionDeliveringActions:(BOOL)deliveringActions {
    SBAppViewController *controller = _appViewController;
    if (![controller respondsToSelector:@selector(_createSceneUpdateTransactionForApplicationSceneEntity:deliveringActions:)]) {
        return;
    }
    @try {
        id transaction = [controller _createSceneUpdateTransactionForApplicationSceneEntity:_entity
                                                                        deliveringActions:deliveringActions];
        if (!transaction) return;
        id transactions = DSIvar(controller, @"_activeTransitions");
        if ([transactions respondsToSelector:@selector(addObject:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(transactions, @selector(addObject:), transaction);
        }
        if ([transaction respondsToSelector:@selector(begin)]) {
            ((void (*)(id, SEL))objc_msgSend)(transaction, @selector(begin));
        }
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: resizing %@ threw %@", _bundleIdentifier, exception.name ?: @"?");
    }
}

// The app view controller re-pins the scene to the whole display on every
// transaction, so the stage's size has to be written after it - last write wins.
// A cold-launching app is not ready to be told for the first second or two either,
// which is why this is repeated: without it the card stays black until something
// else happens to resize it.
- (void)deliverStageSizeToApp {
    if (!_appViewController) return;
    [self setContentReferenceSizeOnAppView];
    [self beginSceneTransactionDeliveringActions:NO];
    [self forceSceneGeometry];
}

// The app view's own idea of how big the app is. It is the size the app view then
// puts into the scene, so it has to be set before each transaction rather than
// corrected after one.
- (void)setContentReferenceSizeOnAppView {
    SBAppViewController *controller = _appViewController;
    SEL selector = @selector(setContentReferenceSize:withInterfaceOrientation:);
    if (![controller respondsToSelector:selector]) return;
    CGRect frame = [self logicalFrame];
    if (CGRectIsEmpty(frame)) return;
    @try {
        ((void (*)(id, SEL, CGSize, long long))objc_msgSend)(controller, selector, frame.size,
                                                            (long long)UIInterfaceOrientationPortrait);
    } @catch (NSException *exception) {
    }
}

- (void)forceSceneGeometry {
    FBScene *scene = [self appViewScene];
    if (!scene) return;
    _scene = scene;
    [self registerGeometryOnlyOverride];

    CGRect frame = [self frameForScene];
    UIEdgeInsets insets = _safeAreaInsets;
    DSUpdateSceneSettings(scene, ^(FBSMutableSceneSettings *settings) {
        DSApplyGeometry(settings, frame, insets);
    });
}

- (FBScene *)appViewScene {
    SBAppViewController *controller = _appViewController;
    if (!controller) return nil;
    @try {
        id handle = DSIvar(controller, @"_sceneHandle");
        if (!handle && [controller respondsToSelector:@selector(sceneHandle)]) handle = controller.sceneHandle;
        if ([handle respondsToSelector:@selector(scene)]) {
            return ((FBScene * (*)(id, SEL))objc_msgSend)(handle, @selector(scene));
        }
    } @catch (NSException *exception) {
    }
    return nil;
}

// Geometry only, never lifecycle: an app view controller of the stage's own making
// is outside SpringBoard's scene layout, and telling its scene it is foreground
// behind SpringBoard's back is what makes it assert.
- (void)registerGeometryOnlyOverride {
    NSString *identifier = [_scene respondsToSelector:@selector(identifier)] ? _scene.identifier : nil;
    if (identifier.length == 0) return;
    [DSSceneOverridesLock() lock];
    DSSceneOverrides()[identifier] = @{
        @"frame" : [NSValue valueWithCGRect:[self frameForScene]],
        @"insets" : [NSValue valueWithUIEdgeInsets:_safeAreaInsets],
        @"geometryOnly" : @YES,
    };
    [DSSceneOverridesLock() unlock];
    _registeredOverride = YES;
}

// The app view controller asserts in dealloc if it is released while still showing
// a live app, so it is stood down in order first.
- (void)tearDownAppViewController {
    SBAppViewController *controller = _appViewController;
    _appViewController = nil;
    _entity = nil;
    if (!controller) return;

    [DSOwnedAppViewControllers() removeObject:controller];
    @try {
        if ([controller respondsToSelector:@selector(_setCurrentMode:)]) [controller _setCurrentMode:0];
        if ([controller respondsToSelector:@selector(invalidate)]) [controller invalidate];
        [controller willMoveToParentViewController:nil];
        [controller.view removeFromSuperview];
        [controller removeFromParentViewController];
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: putting %@'s app view away threw %@",
                                  _bundleIdentifier, exception.name ?: @"?");
    }
}

#pragma mark - Launching

- (void)prepareWithCompletion:(DSSceneHostReadyBlock)completion {
    if (![self application]) {
        DSDiagnosticsRecordFormat(@"SpringBoard: SpringBoard has no application called %@", _bundleIdentifier);
        if (completion) completion(NO);
        return;
    }

    // 4.0: one path only — SpringBoard's SBAppViewController, the same mechanism
    // the app switcher uses. Raw FBScene hosting and "make your own scene" paths
    // were removed: they fought keyboard focus, duplicated lifecycle, and failed
    // on cold launches in different ways every time.
    if ([self hostThroughAppViewController]) {
        if (completion) completion(YES);
        return;
    }

    [self launchThroughUIApplication];
    [self waitForAppViewWithAttemptsRemaining:50 completion:completion];
}

- (void)waitForAppViewWithAttemptsRemaining:(NSInteger)attempts
                                 completion:(DSSceneHostReadyBlock)completion {
    if ([self hostThroughAppViewController]) {
        if (completion) completion(YES);
        return;
    }
    if (attempts <= 0) {
        DSDiagnosticsRecordFormat(@"SpringBoard: %@ never got an app view (process %@)",
                                  _bundleIdentifier,
                                  self.isProcessAlive ? @"running" : @"not running");
        if (completion) completion(NO);
        return;
    }
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf waitForAppViewWithAttemptsRemaining:attempts - 1 completion:completion];
    });
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

        // Guarded one at a time rather than in a block: a setter that moved should
        // cost the stage that one setting, not the only way it has of opening the
        // app at all.
        CGRect frame = CGRectIsEmpty(_stageFrame) ? UIScreen.mainScreen.bounds : [self logicalFrame];
        FBSMutableSceneSettings *settings = [[objc_getClass("UIMutableApplicationSceneSettings") alloc] init];
        settings.frame = CGRectMake(0, 0, CGRectGetWidth(frame), CGRectGetHeight(frame));
        settings.foreground = YES;
        if ([settings respondsToSelector:@selector(setCanShowAlerts:)]) settings.canShowAlerts = YES;
        if ([settings respondsToSelector:@selector(setInterfaceOrientation:)]) {
            settings.interfaceOrientation = UIInterfaceOrientationPortrait;
        }
        if ([settings respondsToSelector:@selector(setDeviceOrientation:)]) {
            settings.deviceOrientation = UIDeviceOrientationPortrait;
        }
        if ([settings respondsToSelector:@selector(setLevel:)]) settings.level = 1;
        if ([settings respondsToSelector:@selector(setStatusBarDisabled:)]) settings.statusBarDisabled = YES;
        if ([settings respondsToSelector:@selector(setSafeAreaInsetsPortrait:)]) {
            settings.safeAreaInsetsPortrait = _safeAreaInsets;
        }
        if ([settings respondsToSelector:@selector(setDisplayConfiguration:)] &&
            [UIScreen.mainScreen respondsToSelector:@selector(displayConfiguration)]) {
            [settings setDisplayConfiguration:[UIScreen.mainScreen displayConfiguration]];
        }
        if ([settings respondsToSelector:@selector(setPersistenceIdentifier:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(settings, @selector(setPersistenceIdentifier:),
                                                  NSUUID.UUID.UUIDString);
        }
        parameters.settings = settings;

        FBSMutableSceneClientSettings *clientSettings =
            [[objc_getClass("UIMutableApplicationSceneClientSettings") alloc] init];
        if ([clientSettings respondsToSelector:@selector(setInterfaceOrientation:)]) {
            clientSettings.interfaceOrientation = UIInterfaceOrientationPortrait;
        }
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

- (void)noteHostViewAttached {
    SBAppViewController *controller = _appViewController;
    if (!controller || !self.parentViewController) return;
    @try {
        [controller didMoveToParentViewController:self.parentViewController];
    } @catch (NSException *exception) {
    }
}

- (FBScene *)hostedScene {
    if (_appViewController) {
        FBScene *scene = [self appViewScene];
        if (scene) return scene;
    }
    return _scene;
}

#pragma mark - Geometry

- (CGRect)stageFrame {
    return _stageFrame;
}

- (void)setStageFrame:(CGRect)frame safeAreaInsets:(UIEdgeInsets)insets {
    _contentScale = [DSPreferences sharedPreferences].scale;
    _stageFrame = frame;
    _safeAreaInsets = insets;
    [self layoutHostView];

    if (_appViewController) {
        [self deliverStageSizeToApp];
        [self nudgeStageSizeWhileAppStarts];
        return;
    }

    [self registerOverride];
    [self pushSettings];
}

// An app that is still launching is not listening yet, and one told its size too
// early draws nothing: the card stays black until something else resizes it. So the
// size is re-sent over the first few seconds of its life. Each one is a no-op once
// the app is up.
- (void)nudgeStageSizeWhileAppStarts {
    if (_nudgedThisLaunch) return;
    _nudgedThisLaunch = YES;

    __weak __typeof(self) weakSelf = self;
    for (NSNumber *delay in @[ @0.4, @0.9, @1.6, @2.6, @4.0, @6.0 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf->_appViewController) return;
            [strongSelf.hostView setNeedsLayout];
            [strongSelf.hostView layoutIfNeeded];
            [strongSelf deliverStageSizeToApp];
        });
    }
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

    // SpringBoard's app view owns the app's lifecycle, and telling its scene it is
    // foreground from outside is exactly what makes it assert - which takes
    // SpringBoard with it. So under an app view the stage only ever dictates size.
    if (_appViewController) {
        [self registerGeometryOnlyOverride];
        return;
    }

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
    if (_appViewController) {
        [self forceSceneGeometry];
        return;
    }
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

    // SpringBoard's app view takes itself apart, including handing the app back to
    // whatever SpringBoard wants to do with it next.
    if (_appViewController) {
        [self tearDownAppViewController];
        _hostView = nil;
        _scene = nil;
        _nudgedThisLaunch = NO;
        _tookOverForegroundLaunch = NO;
        return;
    }

    // A scene the stage made is the stage's to take down, and there is nothing to
    // hand back: the app keeps running, it simply loses this window.
    if (_ownSceneIdentifier) {
        NSString *identifier = _ownSceneIdentifier;
        UIScenePresenter *presenter = _presenter;
        FBScene *scene = _scene;
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
                // FrontBoard takes either the name of the scene or the scene itself
                // depending on the build, and takes the wrong one in silence, so the
                // result is checked: a scene left behind is a window the app keeps
                // for nothing.
                if ([manager respondsToSelector:@selector(sceneWithIdentifier:)] &&
                    [manager sceneWithIdentifier:identifier]) {
                    [manager destroyScene:(id)scene withTransitionContext:nil];
                }
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

+ (BOOL)ownsAppViewController:(id)controller {
    if (!controller) return NO;
    return [DSOwnedAppViewControllers() containsObject:controller];
}

+ (void)noteLiveScene:(FBScene *)scene {
    if (![scene respondsToSelector:@selector(identifier)]) return;
    NSString *identifier = scene.identifier;
    if (identifier.length == 0) return;

    [DSSceneOverridesLock() lock];
    if (DSSceneOverrides().count == 0) {
        [DSSceneOverridesLock() unlock];
        return;
    }
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
