#import "DSCameraArbiter.h"
#import "DSSceneHost.h"
#import "DSConstants.h"
#import "DSPreferences.h"
#import "DSDiagnostics.h"
#import "DSKeyboardVisibility.h"
#import "DSStageDebug.h"
#import "DSStageManager.h"
#import "DSStageContainerView.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>

// Local declaration only. SpringBoard already has the class; linking
// AssertionServices is not required, and a normal message keeps ARC correct.
@interface DSRunningAssertion : NSObject
- (instancetype)initWithPID:(NSInteger)pid flags:(NSUInteger)flags reason:(NSUInteger)reason name:(NSString *)name withHandler:(id)handler;
- (instancetype)initWithBundleIdentifier:(NSString *)identifier flags:(NSUInteger)flags reason:(NSUInteger)reason name:(NSString *)name withHandler:(id)handler;
- (BOOL)valid;
- (void)invalidate;
@end

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

static BOOL DSHomeGestureActive = NO;
static CFAbsoluteTime DSHomeGestureQuietUntil = 0;
static NSString *DSHandedOffBundle = nil;
static CFAbsoluteTime DSHandedOffUntil = 0;

static NSInteger DSSystemPullDepth = 0;
// How many FBScene settings updates are on the stack. A presentation frame
// written from inside one waits on the update that is waiting on the frame.
static NSInteger DSSceneSettingsUpdateDepth = 0;

static BOOL DSAvoidSceneLifecycle(void) {
    if (DSHomeGestureActive || DSSystemPullDepth > 0) return YES;
    return CFAbsoluteTimeGetCurrent() < DSHomeGestureQuietUntil;
}

// Starting a transaction, or changing an app view's mode, while SpringBoard is
// already inside one of those is the SIGTRAP that drops SpringBoard into safe
// mode. @try does not catch it.
static BOOL DSSceneWriteWouldTrap(void) {
    return DSAvoidSceneLifecycle() || DSSceneSettingsUpdateDepth > 0;
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
    if (!scene || !block || DSSceneWriteWouldTrap()) return;
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

// The scene view clears clipsToBounds whenever it lays out, so the app stays a
// square past the card's continuous corner. Marking the view and reapplying at
// the end of its own layout is what keeps the curve.
static const void *DSRoundInfoKey = &DSRoundInfoKey;
static const void *DSRoundHookKey = &DSRoundHookKey;
static const void *DSPresentationKey = &DSPresentationKey;
static const void *DSContainingKey = &DSContainingKey;
static const void *DSCardHostKey = &DSCardHostKey;

static void DSApplyRoundInfo(UIView *view) {
    NSDictionary *info = objc_getAssociatedObject(view, DSRoundInfoKey);
    if (!info) return;
    CGFloat radius = [info[@"r"] doubleValue];
    if (radius < 1.0) return;
    CACornerMask corners = (CACornerMask)[info[@"c"] unsignedIntegerValue];
    view.clipsToBounds = YES;
    view.layer.masksToBounds = YES;
    view.layer.cornerRadius = radius;
    if (@available(iOS 13.0, *)) {
        view.layer.cornerCurve = kCACornerCurveContinuous;
        view.layer.maskedCorners = corners;
    }
}

static BOOL DSClassImplementsSelector(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *list = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(list[index]) == sel) {
            found = YES;
            break;
        }
    }
    free(list);
    return found;
}

static BOOL DSViewIsScenePresentation(UIView *view) {
    if (![view isKindOfClass:UIView.class]) return NO;
    NSString *name = NSStringFromClass(object_getClass(view));
    return [name rangeOfString:@"ScenePresentation"].location != NSNotFound;
}

static UIView *DSCardHostForView(UIView *view) {
    UIView *host = view.superview;
    while (host && !objc_getAssociatedObject(host, DSCardHostKey)) host = host.superview;
    return host;
}

static NSHashTable *DSHiddenStrayPresentations(void) {
    static NSHashTable *views;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        views = [NSHashTable weakObjectsHashTable];
    });
    return views;
}

static void DSRestoreStrayPresentations(void) {
    for (UIView *view in DSHiddenStrayPresentations().allObjects) {
        view.hidden = NO;
        view.alpha = 1.0;
        view.userInteractionEnabled = YES;
    }
    [DSHiddenStrayPresentations() removeAllObjects];
}

static void DSHideStrayPresentation(UIView *view) {
    if (!view) return;
    view.hidden = YES;
    view.alpha = 0.0;
    view.userInteractionEnabled = NO;
    [DSHiddenStrayPresentations() addObject:view];
}

static void DSClearSceneChrome(UIView *view) {
    view.backgroundColor = UIColor.clearColor;
    view.opaque = NO;
    view.layer.backgroundColor = UIColor.clearColor.CGColor;
    view.clipsToBounds = YES;
    view.layer.masksToBounds = YES;
}

static void DSContainScenePresentation(UIView *view) {
    if (!view || !objc_getAssociatedObject(view, DSPresentationKey)) return;
    if (DSSceneSettingsUpdateDepth > 0) return;
    // Corner only. setFrame: on a scene presentation starts another scene
    // update, and the one already running is the conversation push.
    DSClearSceneChrome(view);
    DSApplyRoundInfo(view);
}

static void DSAfterHostedLayout(id view) {
    DSApplyRoundInfo(view);
    DSContainScenePresentation(view);
}

static void DSInstallRoundHook(Class cls) {
    if (!cls || objc_getAssociatedObject(cls, DSRoundHookKey)) return;
    SEL sel = @selector(layoutSubviews);
    if (DSClassImplementsSelector(cls, sel)) {
        Method method = class_getInstanceMethod(cls, sel);
        IMP original = method_getImplementation(method);
        id block = ^(id self) {
            ((void (*)(id, SEL))original)(self, sel);
            DSAfterHostedLayout(self);
        };
        method_setImplementation(method, imp_implementationWithBlock(block));
    } else {
        Class hooked = cls;
        id block = ^(id self) {
            struct objc_super sup;
            sup.receiver = self;
            sup.super_class = class_getSuperclass(hooked);
            ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, sel);
            DSAfterHostedLayout(self);
        };
        class_addMethod(cls, sel, imp_implementationWithBlock(block), "v@:");
    }
    objc_setAssociatedObject(cls, DSRoundHookKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void DSMarkPresentationsUnder(UIView *view, CGFloat radius, CACornerMask corners, NSInteger depth) {
    if (!view || depth > 14) return;
    if (DSViewIsScenePresentation(view)) {
        objc_setAssociatedObject(view, DSPresentationKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (radius > 1.0) {
            objc_setAssociatedObject(view, DSRoundInfoKey,
                                     @{ @"r" : @(radius), @"c" : @(corners) },
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        DSInstallRoundHook(object_getClass(view));
        DSContainScenePresentation(view);
    }
    for (UIView *subview in view.subviews) {
        DSMarkPresentationsUnder(subview, radius, corners, depth + 1);
    }
}

static BOOL DSViewIsMediaSurface(UIView *view) {
    if (![view isKindOfClass:UIView.class]) return NO;
    NSString *name = NSStringFromClass(object_getClass(view));
    return [name rangeOfString:@"AVPlayer"].location != NSNotFound ||
           [name rangeOfString:@"AVSample"].location != NSNotFound ||
           [name rangeOfString:@"WKComposit"].location != NSNotFound ||
           [name rangeOfString:@"WKContent"].location != NSNotFound ||
           [name rangeOfString:@"WKWeb"].location != NSNotFound ||
           [name rangeOfString:@"WebKit"].location != NSNotFound ||
           [name rangeOfString:@"PictureInPicture"].location != NSNotFound ||
           [name rangeOfString:@"PGHosted"].location != NSNotFound;
}

static void DSMarkRounded(UIView *view, CGFloat radius, CACornerMask corners) {
    if (!view || radius < 1.0 || DSViewIsMediaSurface(view)) return;
    objc_setAssociatedObject(view, DSRoundInfoKey,
                             @{ @"r" : @(radius), @"c" : @(corners) },
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    DSInstallRoundHook(object_getClass(view));
    DSApplyRoundInfo(view);
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
    BOOL _deliveredOnce;
    BOOL _deferredSizeDelivery;
    BOOL _cardFitPending;
    BOOL _revealingTallContent;
    BOOL _revealSizeSent;
    BOOL _revealWriteQueued;
    CGFloat _growSentHeight;
    NSInteger _revealGeneration;
    BOOL _cardFitNoted;
    NSInteger _cardFitAttempts;
    NSInteger _cardFitWaits;
    CGFloat _cardFitWidth;
    CGFloat _cardFitHeight;
    CGFloat _deliveredWidth;
    CGFloat _deliveredHeight;
    CGRect _stageFrame;
    UIEdgeInsets _safeAreaInsets;
    BOOL _foreground;
    BOOL _staysBackgrounded;
    BOOL _followsSystemHome;
    BOOL _registeredOverride;
    // Keeps RunningBoard from suspending a hosted app once its card is off screen.
    id _runningAssertion;
    pid_t _runningAssertionPid;
    NSInteger _runningAssertionAttempts;
    BOOL _runningAssertionRetry;
    NSInteger _mediaActivateAttempts;
    NSInteger _cardSizeGeneration;
    BOOL _straySweepScheduled;
    NSHashTable *_hiddenStrays;
    NSTimeInterval _straySweepLast;
    BOOL _strayHideNoted;
    BOOL _matchCardFrame;
    BOOL _clampingHost;
    NSString *_sceneSource;
    CGFloat _keyboardClipHeight;
    BOOL _messagesKeyboardVisible;
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
    [self restoreOwnedStrayPresentations];
    [self releaseRunningAssertion];
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
        DSDiagnosticsRecordFormat(@"SpringBoard: creating app view for %@", _bundleIdentifier);

        SBAppViewController *controller =
            [[viewControllerClass alloc] initWithIdentifier:_bundleIdentifier andApplicationSceneEntity:entity];
        DSDiagnosticsRecordFormat(@"SpringBoard: created app view for %@", _bundleIdentifier);
        if (!controller) {
            DSDiagnosticsRecordFormat(@"SpringBoard: no app view controller for %@", _bundleIdentifier);
            return NO;
        }

        _entity = entity;
        _appViewController = controller;
        [DSOwnedAppViewControllers() addObject:controller];

        [parent addChildViewController:controller];
        // Occlusion and appearance must not suspend the app. Minimizing slides the
        // card off screen; if the app view treated that as "gone", Safari and others
        // tore their scene down and the card came back empty or see-through.
        if ([controller respondsToSelector:@selector(setIgnoresOcclusions:)]) {
            [controller setIgnoresOcclusions:YES];
        }
        if ([controller respondsToSelector:@selector(setAutomatesLifecycle:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setAutomatesLifecycle:), NO);
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
        // Activating while another app is playing a video asserts. The scene
        // transaction above already starts the app; activation waits.
        [self activateHostedAppWhenMediaAllows];

        UIView *view = controller.view;
        if (!view) {
            DSDiagnosticsRecordFormat(@"SpringBoard: %@'s app view controller has no view", _bundleIdentifier);
            [self tearDownAppViewController];
            return NO;
        }
        // Clear lets the wallpaper show through until the app paints, and some
        // apps (Safari) never paint an opaque root view of their own.
        view.opaque = YES;
        if (@available(iOS 13.0, *)) {
            view.backgroundColor = UIColor.systemBackgroundColor;
        } else {
            view.backgroundColor = UIColor.whiteColor;
        }
        view.clipsToBounds = YES;
        _hostView = view;

        [self noteSceneSource:@"SpringBoard's own app view"];
        [self holdRunningAssertion];
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
    DSTraceFormat(@"scene transaction %@ actions=%d", _bundleIdentifier ?: @"?", deliveringActions);
    if (DSSceneWriteWouldTrap()) return;
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
- (BOOL)appViewIsShowingContent {
    SBAppViewController *controller = _appViewController;
    if (!controller) return NO;
    SEL hosting = NSSelectorFromString(@"isHostingAnApp");
    if ([controller respondsToSelector:hosting]) {
        @try {
            return ((BOOL (*)(id, SEL))objc_msgSend)(controller, hosting);
        } @catch (NSException *exception) {
        }
    }
    return [self appViewScene] != nil;
}

// Repeating this after the app is already on screen is what flickers the card:
// each transaction re-pins the scene and the view goes blank until it draws again.
- (void)deliverStageSizeToApp {
    // A second transaction while the card is uncovering a tall layout pins the
    // app back to the half height. That half height is the black band.
    if (_revealingTallContent) return;
    if (DSSceneWriteWouldTrap()) {
        if (_deferredSizeDelivery) return;
        _deferredSizeDelivery = YES;
        __weak __typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_deferredSizeDelivery = NO;
            [strongSelf deliverStageSizeToApp];
        });
        return;
    }
    if (!_appViewController) return;
    CGSize size = [self logicalFrame].size;
    if (CGSizeEqualToSize(size, CGSizeZero)) return;
    BOOL sameSize = _deliveredOnce &&
                    fabs(size.width - _deliveredWidth) < 0.5 &&
                    fabs(size.height - _deliveredHeight) < 0.5;
    if (sameSize && [self appViewIsShowingContent]) {
        // The number we handed over matches the card, but the app view can
        // still have pinned the scene back to the whole display. Fit that
        // without another transaction.
        if ([self sceneFrameIsLargerThanStage]) [self scheduleCardSizeFit];
        return;
    }

    _deliveredOnce = YES;
    _deliveredWidth = size.width;
    _deliveredHeight = size.height;
    // The transaction re-pins the scene to the whole display. The stage size has
    // to be the last thing written, or the card clips a full-screen app.
    [self beginSceneTransactionDeliveringActions:NO];
    [self setContentReferenceSizeOnAppView];
    [self forceSceneGeometry];
    [self layoutHostView];
    [self scheduleSizeCorrection];
}

- (void)refitPresentedScene {
    // Geometry only. deliverStageSizeToApp starts a scene transaction, and the
    // app view answers that by pinning itself to the whole display again.
    [self layoutHostView];
    if ([self sceneFrameIsLargerThanStage]) [self scheduleCardSizeFit];
}

- (void)scheduleSettledCardSizeDelivery {
    if (!_appViewController) return;
    _cardSizeGeneration += 1;
    NSInteger generation = _cardSizeGeneration;
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.22 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_cardSizeGeneration != generation) return;
        if (!strongSelf->_appViewController || !strongSelf->_matchCardFrame) return;
        if (strongSelf->_revealingTallContent) return;
        // One transaction after the size settles. A transaction on every
        // layout is what blanked the card and stacked into a safe mode.
        strongSelf->_deliveredOnce = NO;
        [strongSelf deliverStageSizeToApp];
        [strongSelf layoutHostView];
    });
}

- (void)applyCardFrameQuietly:(CGRect)frame {
    if (_revealingTallContent) {
        [self layoutHostView];
        return;
    }
    if (CGRectIsEmpty(frame)) return;
    // A corner tile is not a scene size. Writing it is what blacks the app
    // when the card is pulled back out.
    if (CGRectGetWidth(frame) < 80.0 || CGRectGetHeight(frame) < 80.0) return;
    _contentScale = [DSPreferences sharedPreferences].scale;
    [self rememberCardFitSize:frame];
    BOOL sizeChanged = fabs(CGRectGetWidth(_stageFrame) - CGRectGetWidth(frame)) > 1.0 ||
                       fabs(CGRectGetHeight(_stageFrame) - CGRectGetHeight(frame)) > 1.0 ||
                       CGRectIsEmpty(_stageFrame);
    _stageFrame = frame;
    _matchCardFrame = YES;
    if (DSSceneWriteWouldTrap()) {
        [self layoutHostView];
        if (sizeChanged) [self scheduleSettledCardSizeDelivery];
        return;
    }
    if (_appViewController) {
        [self setContentReferenceSizeOnAppView];
        [self forceSceneGeometry];
    } else if (_scene) {
        [self registerOverride];
        [self pushSettings];
    }
    [self layoutHostView];
    if (sizeChanged) [self scheduleSettledCardSizeDelivery];
}

- (void)clampOversizedSubviewsOf:(UIView *)view depth:(NSInteger)depth {
    if (!view || depth > 6) return;
    CGRect bounds = view.bounds;
    if (CGRectIsEmpty(bounds)) return;
    for (UIView *subview in view.subviews) {
        // A video layer is larger than the card on purpose. Forcing its frame
        // while it is playing is what safe-modes SpringBoard, Safari included.
        if (DSViewIsMediaSurface(subview)) continue;
        // The scene presentation's setFrame: waits on the client. Clamping it
        // while a conversation is pushing never returns.
        if (DSViewIsScenePresentation(subview)) continue;
        BOOL oversized = CGRectGetWidth(subview.bounds) > CGRectGetWidth(bounds) + 2.0 ||
                         CGRectGetHeight(subview.bounds) > CGRectGetHeight(bounds) + 2.0;
        BOOL hanging = CGRectGetMaxX(subview.frame) > CGRectGetWidth(bounds) + 2.0 ||
                       CGRectGetMaxY(subview.frame) > CGRectGetHeight(bounds) + 2.0 ||
                       subview.frame.origin.x < -2.0 || subview.frame.origin.y < -2.0;
        NSString *subName = NSStringFromClass(object_getClass(subview));
        BOOL keyboardPiece = [subName rangeOfString:@"Keyboard"].location != NSNotFound ||
                             [subName rangeOfString:@"TextEffects"].location != NSNotFound ||
                             [subName rangeOfString:@"InputSet"].location != NSNotFound;
        if (keyboardPiece) {
            subview.clipsToBounds = NO;
            subview.layer.masksToBounds = NO;
            [self clampOversizedSubviewsOf:subview depth:depth + 1];
            continue;
        }
        if (oversized || hanging) {
            subview.transform = CGAffineTransformIdentity;
            subview.frame = bounds;
            subview.clipsToBounds = YES;
            subview.layer.masksToBounds = YES;
        }
        [self clampOversizedSubviewsOf:subview depth:depth + 1];
    }
}

- (BOOL)sceneFrameIsLargerThanStage {
    FBScene *scene = [self appViewScene];
    if (!scene || ![scene respondsToSelector:@selector(settings)]) return NO;
    FBSSceneSettings *settings = scene.settings;
    if (!settings) return NO;
    CGRect got = settings.frame;
    CGRect want = [self frameForScene];
    if (CGRectIsEmpty(got) || CGRectIsEmpty(want)) return NO;
    return CGRectGetWidth(got) > CGRectGetWidth(want) + 24.0 ||
           CGRectGetHeight(got) > CGRectGetHeight(want) + 24.0;
}

// The launch transaction finishes after we return and puts the full display back.
// Correct that once it has landed. Do not start another transaction: that is the flicker.
// One write at a time. A write on every layout is what blanked the card.
- (void)scheduleCardSizeFit {
    if (_cardFitPending || _cardFitAttempts >= 4) return;
    _cardFitPending = YES;
    NSTimeInterval delay = (_cardFitAttempts == 0 && _cardFitWaits == 0) ? 0.05 : 0.35;
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_cardFitPending = NO;
        if (!strongSelf->_appViewController) {
            if (strongSelf->_cardFitWaits < 12) {
                strongSelf->_cardFitWaits += 1;
                [strongSelf scheduleCardSizeFit];
            }
            return;
        }
        // The home swipe is still a scene transition. Retry after it, and do
        // not count those waits as failed fits.
        if (DSAvoidSceneLifecycle()) {
            if (strongSelf->_cardFitWaits < 12) {
                strongSelf->_cardFitWaits += 1;
                [strongSelf scheduleCardSizeFit];
            }
            return;
        }
        // No scene yet, or the launch transaction has not re-pinned the full
        // display yet. Look again. Once a fit has landed, a card-sized scene
        // stops this.
        if (![strongSelf sceneFrameIsLargerThanStage]) {
            if (strongSelf->_cardFitAttempts == 0 && strongSelf->_cardFitWaits < 4) {
                strongSelf->_cardFitWaits += 1;
                [strongSelf scheduleCardSizeFit];
            }
            return;
        }
        if (strongSelf->_cardFitAttempts >= 4) return;
        strongSelf->_cardFitAttempts += 1;
        strongSelf->_cardFitWaits = 0;
        if (!strongSelf->_cardFitNoted) {
            strongSelf->_cardFitNoted = YES;
            DSDiagnosticsRecordFormat(@"SpringBoard: fitting %@'s scene to the card",
                                      strongSelf->_bundleIdentifier);
        }
        [strongSelf setContentReferenceSizeOnAppView];
        [strongSelf forceSceneGeometry];
        [strongSelf layoutHostView];
        if ([strongSelf sceneFrameIsLargerThanStage]) [strongSelf scheduleCardSizeFit];
    });
}

- (void)rememberCardFitSize:(CGRect)frame {
    CGFloat width = CGRectGetWidth(frame);
    CGFloat height = CGRectGetHeight(frame);
    if (fabs(width - _cardFitWidth) < 24.0 && fabs(height - _cardFitHeight) < 24.0) return;
    _cardFitWidth = width;
    _cardFitHeight = height;
    _cardFitAttempts = 0;
    _cardFitWaits = 0;
    _cardFitNoted = NO;
}

- (void)scheduleSizeCorrection {
    [self scheduleCardSizeFit];
}

// The app view's own idea of how big the app is. It is the size the app view then
// puts into the scene, so it has to be set before each transaction rather than
// corrected after one.
- (void)setContentReferenceSizeOnAppView {
    if (DSSceneWriteWouldTrap()) return;
    SBAppViewController *controller = _appViewController;
    CGRect frame = [self logicalFrame];
    if (CGRectIsEmpty(frame) || !controller) return;
    @try {
        SEL selector = @selector(setContentReferenceSize:withInterfaceOrientation:);
        if ([controller respondsToSelector:selector]) {
            ((void (*)(id, SEL, CGSize, long long))objc_msgSend)(controller, selector, frame.size,
                                                                (long long)UIInterfaceOrientationPortrait);
            return;
        }
        SEL both = NSSelectorFromString(@"setContentReferenceSize:withContentOrientation:andContainerOrientation:");
        if ([controller respondsToSelector:both]) {
            ((void (*)(id, SEL, CGSize, long long, long long))objc_msgSend)(controller, both, frame.size,
                                                                            (long long)UIInterfaceOrientationPortrait,
                                                                            (long long)UIInterfaceOrientationPortrait);
        }
    } @catch (NSException *exception) {
    }
}

- (void)forceSceneGeometry {
    DSTraceFormat(@"force geometry %@ depth=%ld frame=%@",
                  _bundleIdentifier ?: @"?",
                  (long)DSSceneSettingsUpdateDepth,
                  NSStringFromCGRect([self frameForScene]));
    if (DSAvoidSceneLifecycle() || DSSceneSettingsUpdateDepth > 0) return;
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
    NSMutableDictionary *override = [@{
        @"frame" : [NSValue valueWithCGRect:[self frameForScene]],
        @"insets" : [NSValue valueWithUIEdgeInsets:_safeAreaInsets],
        @"geometryOnly" : @YES,
    } mutableCopy];
    if (_staysBackgrounded) override[@"staysBackgrounded"] = @YES;
    DSSceneOverrides()[identifier] = override;
    [DSSceneOverridesLock() unlock];
    _registeredOverride = YES;
}

// The app view controller asserts in dealloc if it is released while still showing
// a live app, so it is stood down in order first.
- (void)tearDownAppViewController {
    [self restoreOwnedStrayPresentations];
    _straySweepScheduled = NO;
    [self releaseRunningAssertion];
    SBAppViewController *controller = _appViewController;
    _appViewController = nil;
    _entity = nil;
    _deliveredOnce = NO;
    _cardFitPending = NO;
    _cardFitNoted = NO;
    _cardFitAttempts = 0;
    _cardFitWaits = 0;
    _deliveredWidth = 0;
    _deliveredHeight = 0;
    if (!controller) return;

    [DSOwnedAppViewControllers() removeObject:controller];
    _followsSystemHome = NO;
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
        _hostView.opaque = YES;
        if (@available(iOS 13.0, *)) {
            _hostView.backgroundColor = UIColor.systemBackgroundColor;
        } else {
            _hostView.backgroundColor = UIColor.whiteColor;
        }
        if (!_hostView) DSDiagnosticsRecordFormat(@"SpringBoard: hosting %@ gave back no view", _bundleIdentifier);
        else [self holdRunningAssertion];
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

// The size the app is created at. Set before the app view exists, so Messages
// and the rest lay out for the card instead of the whole screen.
- (void)noteLaunchFrame:(CGRect)frame {
    if (CGRectIsEmpty(frame)) return;
    _contentScale = [DSPreferences sharedPreferences].scale;
    _stageFrame = frame;
    [self rememberCardFitSize:frame];
    // The app view's launch transaction puts the full display back after this
    // returns. The card size has to be written again once that scene exists.
    [self scheduleCardSizeFit];
}

- (void)setStageFrame:(CGRect)frame safeAreaInsets:(UIEdgeInsets)insets {
    if (_revealingTallContent) {
        [self layoutHostView];
        return;
    }
    _contentScale = [DSPreferences sharedPreferences].scale;
    [self rememberCardFitSize:frame];
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

// One follow-up, and only while the app has not drawn yet. A stream of scene
// transactions after that is the flicker on the way in.
- (void)nudgeStageSizeWhileAppStarts {
    if (_nudgedThisLaunch) return;
    _nudgedThisLaunch = YES;

    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->_appViewController) return;
        if ([strongSelf appViewIsShowingContent]) return;
        [strongSelf.hostView setNeedsLayout];
        [strongSelf.hostView layoutIfNeeded];
        strongSelf->_deliveredOnce = NO;
        [strongSelf deliverStageSizeToApp];
    });
}

- (CGRect)logicalFrame {
    CGFloat scale = _contentScale > 0 ? _contentScale : 1.0;
    return CGRectMake(CGRectGetMinX(_stageFrame),
                      CGRectGetMinY(_stageFrame),
                      CGRectGetWidth(_stageFrame) * scale,
                      CGRectGetHeight(_stageFrame) * scale);
}

- (void)activateHostedAppWhenMediaAllows {
    if (DSSystemPullDepth > 0 || DSSceneSettingsUpdateDepth > 0) {
        if (_mediaActivateAttempts >= 8) return;
        _mediaActivateAttempts += 1;
        __weak __typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf activateHostedAppWhenMediaAllows];
        });
        return;
    }
    if (DSAvoidSceneLifecycle()) return;
    SBAppViewController *controller = _appViewController;
    if (!controller) return;
    NSString *playing = DSNowPlayingBundleIdentifier();
    BOOL otherVideo = DSVideoIsPlayingOnScreen() &&
                      playing.length > 0 &&
                      ![playing isEqualToString:_bundleIdentifier];
    if (otherVideo) {
        if (_mediaActivateAttempts >= 6) return;
        _mediaActivateAttempts += 1;
        __weak __typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf activateHostedAppWhenMediaAllows];
        });
        return;
    }
    _mediaActivateAttempts = 0;
    @try {
        if ([controller respondsToSelector:@selector(_setCurrentMode:)]) [controller _setCurrentMode:2];
        if ([controller respondsToSelector:@selector(setDisplayMode:animationFactory:completion:)]) {
            [controller setDisplayMode:4 animationFactory:nil completion:nil];
        }
        SEL activate = NSSelectorFromString(@"_activateApp");
        if ([controller respondsToSelector:activate]) {
            ((void (*)(id, SEL))objc_msgSend)(controller, activate);
        }
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: waking %@ threw %@", _bundleIdentifier, exception.name ?: @"?");
    }
}

- (void)wakeIfBackgrounded {
    if (DSAvoidSceneLifecycle()) return;
    SBAppViewController *controller = _appViewController;
    if (!controller) return;
    BOOL foreground = YES;
    @try {
        FBScene *scene = [self appViewScene];
        FBSSceneSettings *settings = [scene respondsToSelector:@selector(settings)] ? scene.settings : nil;
        SEL isForeground = NSSelectorFromString(@"isForeground");
        if ([settings respondsToSelector:isForeground]) {
            foreground = ((BOOL (*)(id, SEL))objc_msgSend)(settings, isForeground);
        } else if ([settings respondsToSelector:@selector(foreground)]) {
            foreground = settings.foreground;
        }
    } @catch (NSException *exception) {
    }
    if (foreground && [self appViewIsShowingContent]) return;
    [self activateHostedAppWhenMediaAllows];
    [self layoutHostView];
    DSDiagnosticsRecordFormat(@"SpringBoard: %@ had been put in the background off the stage and was woken",
                              _bundleIdentifier);
}

// Where on the screen the app should believe it is. A scene borrowed from
// SpringBoard is still positioned on the display, so it keeps the stage's own
// origin; a scene the stage created is presented inside the card and has no
// business anywhere but the card's own corner.
- (CGRect)frameForScene {
    CGRect logical = [self logicalFrame];
    CGFloat width = CGRectGetWidth(logical);
    CGFloat height = CGRectGetHeight(logical);
    if (width < 1.0 || height < 1.0) return logical;
    // The app view already lives inside the card. A screen origin, including
    // the old y=5 rewrite for a bottom card, is what UIScenePresentationView
    // copies into its own frame, so the picture leaves the rim.
    if (_hostView.superview || _ownSceneIdentifier || _matchCardFrame) {
        return CGRectMake(0.0, 0.0, width, height);
    }
    // Not in a card yet. Keep the scene off the bottom edge so iOS does not
    // host the keyboard inside it.
    CGRect screen = UIScreen.mainScreen.bounds;
    if (CGRectGetMaxY(logical) > CGRectGetHeight(screen) * 0.55) {
        logical.origin.x = 5.0;
        logical.origin.y = 5.0;
    }
    return logical;
}

- (void)fitHostViewToCard {
    [self layoutHostView];
}

- (void)markHostNeedsLiveRedraw {
    if (_revealingTallContent) return;
    UIView *host = _hostView;
    if (!host) return;
    host.contentMode = UIViewContentModeRedraw;
    host.layer.needsDisplayOnBoundsChange = YES;
    if (!_messagesKeyboardVisible) {
        host.clipsToBounds = YES;
        host.layer.masksToBounds = YES;
    }
    [host setNeedsLayout];
    [host layoutIfNeeded];
    [host.layer setNeedsDisplay];
}

- (void)sendRevealFrame:(CGRect)frame
             generation:(NSInteger)generation
              revealing:(BOOL)revealing
                attempt:(NSInteger)attempt {
    __weak __typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        DSSceneHost *host = weakSelf;
        if (!host || host->_revealGeneration != generation) return;
        if (host->_revealingTallContent != revealing) return;
        if (DSSceneWriteWouldTrap()) {
            if (attempt >= 8) {
                host->_revealWriteQueued = NO;
                return;
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                DSSceneHost *again = weakSelf;
                if (!again || again->_revealGeneration != generation) return;
                if (again->_revealingTallContent != revealing) return;
                [again sendRevealFrame:frame generation:generation revealing:revealing attempt:attempt + 1];
            });
            return;
        }
        CGRect use = frame;
        if (revealing && CGRectGetHeight(host->_stageFrame) > CGRectGetHeight(frame) + 12.0) {
            use = host->_stageFrame;
        }
        host->_contentScale = [DSPreferences sharedPreferences].scale;
        host->_stageFrame = use;
        host->_matchCardFrame = YES;
        // The picture has to be the tall size before the scene is told, or
        // the app lays out into the old half and the new area stays empty.
        // One update, after the finger callback has returned. Repeating this
        // on every move blanks the card.
        [host layoutHostView];
        [host setContentReferenceSizeOnAppView];
        [host beginSceneTransactionDeliveringActions:NO];
        [host setContentReferenceSizeOnAppView];
        [host forceSceneGeometry];
        if (revealing) host->_revealSizeSent = YES;
        host->_growSentHeight = CGRectGetHeight(use);
        host->_revealWriteQueued = NO;
        [host layoutHostView];
        if (revealing) {
            DSLogAppend([host growingContentDebugLine]);
        }
        if (revealing && CGRectGetHeight(host->_stageFrame) > CGRectGetHeight(use) + 28.0) {
            CGRect latest = host->_stageFrame;
            host->_revealWriteQueued = YES;
            host->_growSentHeight = CGRectGetHeight(latest);
            [host sendRevealFrame:latest generation:generation revealing:YES attempt:0];
        }
        if (!revealing) return;
        // The transaction finishes after we return and pins the scene back to
        // the full display. Put the tall card size back without another
        // transaction, or the new area stays black.
        for (NSNumber *delay in @[ @0.12, @0.35, @0.6 ]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                DSSceneHost *again = weakSelf;
                if (!again || again->_revealGeneration != generation) return;
                if (!again->_revealingTallContent || !again->_revealSizeSent) return;
                if (DSSceneWriteWouldTrap()) return;
                // A newer drag step already stored a taller size. Do not
                // put the old one back over it.
                if (CGRectGetHeight(again->_stageFrame) > CGRectGetHeight(frame) + 12.0) return;
                again->_stageFrame = frame;
                again->_matchCardFrame = YES;
                [again setContentReferenceSizeOnAppView];
                [again forceSceneGeometry];
                [again layoutHostView];
            });
        }
    });
}

// The picture was following the card. A taller card then showed empty space
// under the old picture. The picture stays at the tall size and the card
// uncovers it, so later card growth must not resize that picture.
- (void)keepPictureFromTrackingHostFrom:(UIView *)view depth:(NSInteger)depth {
    if (!view || depth > 8) return;
    for (UIView *subview in view.subviews) {
        NSString *name = NSStringFromClass(object_getClass(subview));
        BOOL keyboard = [name rangeOfString:@"Keyboard"].location != NSNotFound ||
                        [name rangeOfString:@"TextEffects"].location != NSNotFound ||
                        [name rangeOfString:@"InputSet"].location != NSNotFound;
        if (keyboard) {
            [self keepPictureFromTrackingHostFrom:subview depth:depth + 1];
            continue;
        }
        UIViewAutoresizing mask = subview.autoresizingMask;
        mask &= ~(UIViewAutoresizingFlexibleHeight |
                  UIViewAutoresizingFlexibleTopMargin |
                  UIViewAutoresizingFlexibleBottomMargin);
        if (subview.autoresizingMask != mask) subview.autoresizingMask = mask;
        [self keepPictureFromTrackingHostFrom:subview depth:depth + 1];
    }
}

- (void)keepPictureFromTrackingHost {
    if (!_hostView) return;
    _hostView.autoresizesSubviews = NO;
    [self keepPictureFromTrackingHostFrom:_hostView depth:0];
}

- (void)restorePictureTrackingFrom:(UIView *)view depth:(NSInteger)depth {
    if (!view || depth > 8) return;
    for (UIView *subview in view.subviews) {
        NSString *name = NSStringFromClass(object_getClass(subview));
        BOOL keyboard = [name rangeOfString:@"Keyboard"].location != NSNotFound ||
                        [name rangeOfString:@"TextEffects"].location != NSNotFound ||
                        [name rangeOfString:@"InputSet"].location != NSNotFound;
        if (!keyboard && !DSViewIsScenePresentation(subview)) {
            subview.autoresizingMask |= UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        }
        [self restorePictureTrackingFrom:subview depth:depth + 1];
    }
}

- (void)restorePictureTracking {
    if (_hostView) _hostView.autoresizesSubviews = YES;
    [self restorePictureTrackingFrom:_hostView depth:0];
}

// The card is growing under the finger. The app was told the tall size once,
// at the start. Changing that size on the way down is what left the new area black.
- (void)adoptGrowingCardFrame:(CGRect)frame {
    (void)frame;
    if (!_revealingTallContent) return;
    [self layoutHostView];
}

- (BOOL)beginRevealingTallContent:(CGRect)fullFrame {
    if (CGRectGetWidth(fullFrame) < 80.0 || CGRectGetHeight(fullFrame) < 80.0) return NO;
    _contentScale = [DSPreferences sharedPreferences].scale;
    _stageFrame = fullFrame;
    _matchCardFrame = YES;
    _revealingTallContent = YES;
    [self layoutHostView];
    if (_revealSizeSent || _revealWriteQueued) return YES;
    _revealWriteQueued = YES;
    [self sendRevealFrame:fullFrame generation:_revealGeneration revealing:YES attempt:0];
    return YES;
}

- (void)endRevealingTallContent:(CGRect)cardFrame {
    [self restorePictureTracking];
    _revealingTallContent = NO;
    _revealSizeSent = NO;
    _revealWriteQueued = NO;
    _growSentHeight = 0.0;
    _revealGeneration += 1;
    if (CGRectGetWidth(cardFrame) < 80.0 || CGRectGetHeight(cardFrame) < 80.0) {
        [self layoutHostView];
        return;
    }
    _contentScale = [DSPreferences sharedPreferences].scale;
    _stageFrame = cardFrame;
    _matchCardFrame = YES;
    [self layoutHostView];
    NSInteger generation = _revealGeneration;
    _revealWriteQueued = YES;
    [self sendRevealFrame:cardFrame generation:generation revealing:NO attempt:0];
}

- (void)stopRevealingTallContent {
    [self restorePictureTracking];
    _revealingTallContent = NO;
    _revealSizeSent = NO;
    _revealWriteQueued = NO;
    _growSentHeight = 0.0;
    _revealGeneration += 1;
}

- (void)writeFullScreenFrameAttempt:(NSInteger)attempt {
    CGRect screen = UIScreen.mainScreen.bounds;
    if (CGRectGetWidth(screen) < 80.0 || CGRectGetHeight(screen) < 80.0) return;
    _contentScale = 1.0;
    _matchCardFrame = YES;
    _stageFrame = CGRectMake(0.0, 0.0, CGRectGetWidth(screen), CGRectGetHeight(screen));
    UIEdgeInsets insets = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) {
        UIWindow *window = UIApplication.sharedApplication.windows.firstObject;
        insets = window.safeAreaInsets;
    }
    _safeAreaInsets = insets;
    [self registerGeometryOnlyOverride];
    if (DSSceneWriteWouldTrap()) {
        if (attempt >= 8 || !_appViewController) return;
        __weak __typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            DSSceneHost *host = weakSelf;
            if (!host || !host->_appViewController) return;
            [host writeFullScreenFrameAttempt:attempt + 1];
        });
        return;
    }
    _deliveredOnce = NO;
    _deliveredWidth = 0.0;
    _deliveredHeight = 0.0;
    [self setContentReferenceSizeOnAppView];
    [self forceSceneGeometry];
    [self layoutHostView];
    DSLogAppend([NSString stringWithFormat:@"[SCENE] full screen handoff %@ frame=%@",
                                           _bundleIdentifier ?: @"?",
                                           NSStringFromCGRect([self frameForScene])]);
}

- (void)handOffAtFullScreen {
    [self stopRevealingTallContent];
    // Set before the scene write. A phone-sized update is otherwise refused
    // while this host is still on the stage, and the scene stays the split.
    if (_bundleIdentifier.length > 0) {
        DSHandedOffBundle = [_bundleIdentifier copy];
        DSHandedOffUntil = CFAbsoluteTimeGetCurrent() + 3.0;
    }
    [self writeFullScreenFrameAttempt:0];
}

static id DSIvarInHierarchy(id object, NSString *name) {
    Class cls = [object class];
    while (cls) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (ivar) {
            @try {
                return object_getIvar(object, ivar);
            } @catch (NSException *exception) {
                return nil;
            }
        }
        cls = class_getSuperclass(cls);
    }
    return nil;
}

static void DSCollectPresentations(UIView *view, NSMutableArray<UIView *> *found, NSInteger depth) {
    if (!view || depth > 22) return;
    if (DSViewIsScenePresentation(view)) [found addObject:view];
    for (UIView *subview in view.subviews) {
        DSCollectPresentations(subview, found, depth + 1);
    }
}

- (NSString *)growingContentDebugLine {
    CGRect hostBounds = _hostView ? _hostView.bounds : CGRectZero;
    CGRect sceneFrame = CGRectZero;
    @try {
        FBScene *scene = [self appViewScene] ?: _scene;
        FBSSceneSettings *settings = [scene respondsToSelector:@selector(settings)] ? scene.settings : nil;
        if (settings) sceneFrame = settings.frame;
    } @catch (NSException *exception) {
    }
    CGRect picture = CGRectZero;
    NSInteger count = 0;
    if (_hostView) {
        NSMutableArray<UIView *> *found = [NSMutableArray array];
        DSCollectPresentations(_hostView, found, 0);
        count = found.count;
        UIView *pictureView = found.firstObject;
        if (pictureView) picture = pictureView.bounds;
    }
    return [NSString stringWithFormat:
            @"[SCENE] %@ stageH=%.0f sceneH=%.0f host={{%.0f,%.0f}} picture={{%.0f,%.0f}} n=%ld sent=%d queued=%d",
            _bundleIdentifier ?: @"?",
            CGRectGetHeight(_stageFrame),
            CGRectGetHeight(sceneFrame),
            CGRectGetWidth(hostBounds), CGRectGetHeight(hostBounds),
            CGRectGetWidth(picture), CGRectGetHeight(picture),
            (long)count, _revealSizeSent, _revealWriteQueued];
}

static BOOL DSNameContains(NSString *name, NSArray<NSString *> *parts) {
    for (NSString *part in parts) {
        if ([name rangeOfString:part].location != NSNotFound) return YES;
    }
    return NO;
}

static BOOL DSWindowIsKeyboard(UIWindow *window) {
    NSString *name = NSStringFromClass(object_getClass(window));
    return DSNameContains(name, @[ @"Keyboard", @"TextEffects" ]);
}

// Notifications, calls, and the keyboard have to stay on screen during Split.
// Their windows are not Messages' leftover scene.
static BOOL DSWindowShouldBeLeftAlone(UIWindow *window) {
    if (DSWindowIsKeyboard(window)) return YES;
    NSString *name = NSStringFromClass(object_getClass(window));
    return DSNameContains(name, @[ @"Banner", @"Notification", @"Call", @"InCall", @"CoverSheet" ]);
}

static BOOL DSViewIsSystemChrome(UIView *view) {
    NSString *name = NSStringFromClass(object_getClass(view));
    return DSNameContains(name, @[
        @"HomeScreen", @"FloatingDock", @"Wallpaper", @"Icon", @"StatusBar",
        @"Banner", @"Notification", @"Keyboard", @"TextEffects", @"CoverSheet",
        @"CallScreen", @"Dock",
    ]);
}

static NSArray<UIWindow *> *DSAllWindows(void) {
    SEL all = NSSelectorFromString(@"allWindowsIncludingInternalWindows:");
    if ([UIWindow respondsToSelector:all]) {
        @try {
            NSArray *windows = ((NSArray * (*)(id, SEL, BOOL))objc_msgSend)([UIWindow class], all, YES);
            if (windows.count > 0) return windows;
        } @catch (NSException *exception) {
        }
    }
    return UIApplication.sharedApplication.windows ?: @[];
}

static NSString *DSIdentifierFromObject(id object) {
    if (!object || [object isKindOfClass:NSString.class]) return nil;
    @try {
        if ([object respondsToSelector:@selector(identifier)]) {
            id identifier = [object identifier];
            if ([identifier isKindOfClass:NSString.class] && [identifier length] > 0) return identifier;
        }
    } @catch (NSException *exception) {
    }
    return nil;
}

// The presentation view rarely is the scene. The scene sits on an ivar a level
// or two down, and that is the only way to know the view is Messages'.
static NSString *DSIdentifierOnPresentation(UIView *view) {
    NSArray<NSString *> *names = @[
        @"_scene", @"scene", @"_fbScene", @"_uiScene", @"_presenter", @"presenter",
        @"_scenePresenter", @"_presentation", @"_hostingController",
    ];
    for (NSString *name in names) {
        id object = DSIvarInHierarchy(view, name);
        NSString *identifier = DSIdentifierFromObject(object);
        if (identifier.length > 0) return identifier;
        if (!object) continue;
        for (NSString *nested in @[ @"_scene", @"scene", @"_fbScene" ]) {
            identifier = DSIdentifierFromObject(DSIvarInHierarchy(object, nested));
            if (identifier.length > 0) return identifier;
        }
        if ([object respondsToSelector:@selector(scene)]) {
            @try {
                identifier = DSIdentifierFromObject([object scene]);
            } @catch (NSException *exception) {
                identifier = nil;
            }
            if (identifier.length > 0) return identifier;
        }
    }
    return nil;
}

static NSString *DSBundleIdentifierNear(id start) {
    id responder = start;
    for (NSInteger hop = 0; responder && hop < 14; hop++) {
        @try {
            if ([responder respondsToSelector:@selector(bundleIdentifier)]) {
                id value = [responder bundleIdentifier];
                if ([value isKindOfClass:NSString.class] && [value length] > 0) return value;
            }
            for (NSString *ivarName in @[ @"_application", @"application" ]) {
                id app = DSIvarInHierarchy(responder, ivarName);
                if ([app respondsToSelector:@selector(bundleIdentifier)]) {
                    id value = [app bundleIdentifier];
                    if ([value isKindOfClass:NSString.class] && [value length] > 0) return value;
                }
            }
        } @catch (NSException *exception) {
        }
        if ([responder isKindOfClass:UIView.class]) {
            responder = [(UIView *)responder nextResponder];
        } else if ([responder respondsToSelector:@selector(parentViewController)]) {
            responder = [responder parentViewController];
        } else if ([responder respondsToSelector:@selector(nextResponder)]) {
            responder = [responder nextResponder];
        } else {
            break;
        }
    }
    return nil;
}

// Hide the black wrapper around the stray presentation, and stop before a view
// that also holds the Home Screen or this card.
static UIView *DSContainerToHide(UIView *presentation, UIView *cardHost) {
    UIView *target = presentation;
    UIView *current = presentation;
    while (current.superview && ![current.superview isKindOfClass:UIWindow.class]) {
        UIView *parent = current.superview;
        if (DSViewIsSystemChrome(parent)) break;
        if (objc_getAssociatedObject(parent, DSCardHostKey)) break;
        if (cardHost && (parent == cardHost || [cardHost isDescendantOfView:parent])) break;
        target = parent;
        current = parent;
    }
    return target;
}

// Messages, as the app Split just took off the full screen, keeps a second
// UIScenePresentationView at the screen size. It is black and it sits outside
// the top card. The one inside the card stays. Other apps do not leave this
// view behind, so the walk only runs for Messages.
- (void)hideStrayPresentationsOutsideCard {
    if (_revealingTallContent && !_revealSizeSent) return;
    if (!_matchCardFrame || !_hostView) return;
    if (![_bundleIdentifier isEqualToString:@"com.apple.MobileSMS"]) return;
    DSTraceFormat(@"hideStray split=%d depth=%ld",
                  DSStageManager.sharedManager.isSplitMode,
                  (long)DSSceneSettingsUpdateDepth);
    // A single staged card has one presentation, and the conversation push
    // resizes it. Hiding that view stalls the push until SpringBoard resprings.
    // The black full-screen leftover only exists once Split has taken Messages
    // off the full screen.
    if (!DSStageManager.sharedManager.isSplitMode) return;
    // Home gesture / nested scene update: walking presentations here can start
    // work that updates scenes and SIGTRAPs SpringBoard.
    if (DSSceneWriteWouldTrap()) return;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (_straySweepLast > 0.0 && now - _straySweepLast < 0.15) return;
    _straySweepLast = now;

    UIView *host = _hostView;
    CGRect card = [host convertRect:host.bounds toView:nil];
    if (CGRectGetWidth(card) < 40.0 || CGRectGetHeight(card) < 40.0) return;
    FBScene *scene = [self appViewScene] ?: _scene;
    NSString *sceneIdentifier = [scene respondsToSelector:@selector(identifier)] ? scene.identifier : nil;
    NSString *bundle = _bundleIdentifier;

    for (UIWindow *window in DSAllWindows()) {
        if (DSWindowShouldBeLeftAlone(window)) continue;
        NSMutableArray<UIView *> *found = [NSMutableArray array];
        DSCollectPresentations(window, found, 0);
        for (UIView *view in found) {
            UIView *owner = DSCardHostForView(view);
            if ([view isDescendantOfView:host] || owner == host) {
                CGRect frame = [view convertRect:view.bounds toView:nil];
                BOOL hanging = CGRectGetWidth(frame) > CGRectGetWidth(card) + 24.0 ||
                               CGRectGetHeight(frame) > CGRectGetHeight(card) + 24.0;
                if (hanging) {
                    objc_setAssociatedObject(view, DSPresentationKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    DSContainScenePresentation(view);
                }
                continue;
            }
            if (owner) continue;
            CGRect frame = [view convertRect:view.bounds toView:nil];
            BOOL outside = CGRectGetWidth(frame) > CGRectGetWidth(card) + 24.0 ||
                           CGRectGetHeight(frame) > CGRectGetHeight(card) + 24.0 ||
                           CGRectGetMinY(frame) < CGRectGetMinY(card) - 24.0 ||
                           CGRectGetMaxY(frame) > CGRectGetMaxY(card) + 24.0 ||
                           CGRectGetMinX(frame) < CGRectGetMinX(card) - 24.0 ||
                           CGRectGetMaxX(frame) > CGRectGetMaxX(card) + 24.0;
            if (!outside || DSViewIsSystemChrome(view)) continue;
            NSString *identifier = DSIdentifierOnPresentation(view);
            NSString *near = DSBundleIdentifierNear(view);
            BOOL ours = (sceneIdentifier.length > 0 && [identifier isEqualToString:sceneIdentifier]) ||
                        (identifier.length > 0 &&
                         [identifier rangeOfString:bundle].location != NSNotFound) ||
                        [near isEqualToString:bundle];
            if (near.length > 0 && ![near isEqualToString:bundle]) continue;
            if (!ours && identifier.length > 0 &&
                [identifier rangeOfString:@"springboard" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                continue;
            }
            BOOL underChrome = NO;
            for (UIView *walk = view.superview; walk && ![walk isKindOfClass:UIWindow.class]; walk = walk.superview) {
                if (DSViewIsSystemChrome(walk)) {
                    underChrome = YES;
                    break;
                }
            }
            CGRect screen = UIScreen.mainScreen.bounds;
            BOOL screenSized = CGRectGetWidth(frame) > CGRectGetWidth(screen) - 80.0 &&
                               CGRectGetHeight(frame) > CGRectGetHeight(screen) * 0.70;
            // No identifier on it, and it is not inside Home Screen chrome.
            // A screen-sized presentation then is the full-screen Messages view.
            if (!ours && !underChrome && identifier.length == 0 && near.length == 0 && screenSized) ours = YES;
            if (!ours) continue;
            UIView *target = DSContainerToHide(view, host);
            if (!target || target == host || [host isDescendantOfView:target]) continue;
            if ([target isDescendantOfView:host] || DSViewIsSystemChrome(target)) continue;
            [self hideOwnedStrayPresentation:target];
        }
    }
}

- (void)hideOwnedStrayPresentation:(UIView *)view {
    if (!view) return;
    // Already hidden by somebody else. Leave it, so a later restore does not
    // uncover a view SpringBoard meant to keep off screen.
    if (view.hidden && ![DSHiddenStrayPresentations() containsObject:view]) return;
    DSHideStrayPresentation(view);
    if (!_hiddenStrays) _hiddenStrays = [NSHashTable weakObjectsHashTable];
    [_hiddenStrays addObject:view];
    if (_strayHideNoted) return;
    _strayHideNoted = YES;
    DSDiagnosticsRecord(@"SpringBoard: hid Messages' full-screen scene presentation outside the split card");
}

- (void)restoreOwnedStrayPresentations {
    for (UIView *view in _hiddenStrays.allObjects) {
        view.hidden = NO;
        view.alpha = 1.0;
        view.userInteractionEnabled = YES;
        [DSHiddenStrayPresentations() removeObject:view];
    }
    [_hiddenStrays removeAllObjects];
    if ([_bundleIdentifier isEqualToString:@"com.apple.MobileSMS"]) DSRestoreStrayPresentations();
}

- (void)scheduleStrayPresentationSweep {
    if (_straySweepScheduled || !_matchCardFrame) return;
    if (![_bundleIdentifier isEqualToString:@"com.apple.MobileSMS"]) return;
    _straySweepScheduled = YES;
    __weak __typeof(self) weakSelf = self;
    // Home is pressed at 0.45s and the scene is woken at about 1.05s. That wake
    // is when Messages puts the full-screen presentation back.
    for (NSNumber *delay in @[ @0.25, @0.7, @1.2, @2.0 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (DSSceneWriteWouldTrap()) return;
            [weakSelf hideStrayPresentationsOutsideCard];
        });
    }
}

- (CGFloat)keyboardClipHeight {
    return _keyboardClipHeight;
}

- (void)setMessagesKeyboardVisible:(BOOL)visible {
    _messagesKeyboardVisible = visible;
    if (!_hostView) return;
    _hostView.clipsToBounds = !visible;
    _hostView.layer.masksToBounds = !visible;
}

- (void)setKeyboardClipHeight:(CGFloat)height {
    _keyboardClipHeight = MAX(height, 0.0);
    [self layoutHostView];
}

- (void)roundFilledSubviewsOf:(UIView *)view
                       radius:(CGFloat)radius
                      corners:(CACornerMask)corners
                        depth:(NSInteger)depth {
    if (!view || depth > 5) return;
    CGRect bounds = view.bounds;
    if (CGRectIsEmpty(bounds)) return;
    for (UIView *subview in view.subviews) {
        BOOL fills = CGRectGetWidth(subview.bounds) >= CGRectGetWidth(bounds) - 2.0 &&
                     CGRectGetHeight(subview.bounds) >= CGRectGetHeight(bounds) - 2.0;
        if (!fills) continue;
        DSMarkRounded(subview, radius, corners);
        [self roundFilledSubviewsOf:subview radius:radius corners:corners depth:depth + 1];
    }
}

// Ancestor clips do not contain a hosted scene. The scene view itself has to
// wear the card's continuous corner, and it has to put that corner back after
// its own layout clears it.
- (void)roundHostedSceneToCard {
    UIView *host = _hostView;
    if (!host) return;
    UIView *source = host.superview;
    CGFloat radius = 0.0;
    CACornerMask corners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    while (source) {
        if (source.layer.cornerRadius > 1.0) {
            radius = source.layer.cornerRadius;
            if (@available(iOS 11.0, *)) corners = source.layer.maskedCorners;
            break;
        }
        // The card's layer radius is 0 while it is unclipped for a keyboard.
        // The property is still the real corner. Without it the scene stays a
        // square and the outline is the only rounded piece.
        if ([source isKindOfClass:DSStageContainerView.class]) {
            CGFloat cardRadius = ((DSStageContainerView *)source).cornerRadius;
            if (cardRadius > 1.0) {
                radius = cardRadius;
                break;
            }
        }
        source = source.superview;
    }
    DSMarkPresentationsUnder(host, radius, corners, 0);
    if (radius < 1.0) return;
    DSMarkRounded(host, radius, corners);
    [self roundFilledSubviewsOf:host radius:radius corners:corners depth:0];
}

// The scene view can be taller than the card. masksToBounds on the host is
// what keeps that picture inside the card. This does not set the scene
// presentation's frame. That call waits on the app.
- (void)clipHostContentsToCard {
    if (![_bundleIdentifier isEqualToString:@"com.apple.mobilephone"]) return;
    UIView *host = _hostView;
    if (!host || _messagesKeyboardVisible) return;
    host.clipsToBounds = YES;
    host.layer.masksToBounds = YES;
    CGRect bounds = host.bounds;
    if (CGRectGetWidth(bounds) < 40.0 || CGRectGetHeight(bounds) < 40.0) return;
    CALayer *mask = host.layer.mask;
    if (!mask) {
        mask = [CALayer layer];
        mask.backgroundColor = UIColor.blackColor.CGColor;
        host.layer.mask = mask;
    }
    if (!CGRectEqualToRect(mask.frame, bounds)) mask.frame = bounds;
    // Mask frame is fine mid-update. The window walk that hides presentations
    // is not: that is a SIGTRAP during home / nested scene writes.
    if (DSSceneWriteWouldTrap() || !_matchCardFrame) return;
    CGRect card = [host convertRect:bounds toView:nil];
    if (CGRectGetWidth(card) < 80.0 || CGRectGetHeight(card) < 80.0) return;
    for (UIWindow *window in DSAllWindows()) {
        if (DSWindowShouldBeLeftAlone(window)) continue;
        NSMutableArray<UIView *> *found = [NSMutableArray array];
        DSCollectPresentations(window, found, 0);
        for (UIView *view in found) {
            if ([view isDescendantOfView:host] || DSCardHostForView(view) == host) continue;
            NSString *identifier = DSIdentifierOnPresentation(view);
            NSString *near = DSBundleIdentifierNear(view);
            BOOL ours = (identifier.length > 0 &&
                         [identifier rangeOfString:@"mobilephone" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                        [near isEqualToString:@"com.apple.mobilephone"];
            if (!ours) continue;
            CGRect frame = [view convertRect:view.bounds toView:nil];
            BOOL outside = CGRectGetWidth(frame) > CGRectGetWidth(card) + 24.0 ||
                           CGRectGetHeight(frame) > CGRectGetHeight(card) + 24.0 ||
                           CGRectGetMinY(frame) < CGRectGetMinY(card) - 24.0 ||
                           CGRectGetMaxY(frame) > CGRectGetMaxY(card) + 24.0;
            if (!outside) continue;
            UIView *target = DSContainerToHide(view, host);
            if (!target || target == host || [host isDescendantOfView:target]) continue;
            if ([target isDescendantOfView:host] || DSViewIsSystemChrome(target)) continue;
            DSHideStrayPresentation(target);
        }
    }
}

- (void)layoutHostView {
    if (!_hostView) return;
    if ([_bundleIdentifier isEqualToString:@"com.apple.MobileSMS"]) {
        DSTraceFormat(@"layoutHost Messages frame=%@", NSStringFromCGRect(_hostView.frame));
    }
    UIView *parent = _hostView.superview;
    CGFloat scale = _contentScale > 0 ? _contentScale : 1.0;
    _hostView.transform = CGAffineTransformIdentity;

    // At the normal scale the app is the card, edge to edge. A view left at the
    // screen size is clipped, which is the bottom stage showing only part of the app.
    // A mask on an ancestor does not clip this view. Its superview's bounds do,
    // and only while this view stays the size the scene was given.
    // The corner card and the hidden holder are not sizes the app can be laid
    // out into. Leaving the view there is what crashed a minimized app.
    BOOL tinyParent = CGRectGetWidth(parent.bounds) < 80.0 && CGRectGetHeight(parent.bounds) < 80.0;
    if (parent && (parent.tag == 9158 || tinyParent)) {
        _hostView.autoresizingMask = UIViewAutoresizingNone;
        // Minimized. The live view stays off the card. Leaving it visible at
        // the old card size paints the app on the Home Screen.
        if (parent.tag == 9158) _hostView.hidden = YES;
        return;
    }
    if (parent && !CGRectIsEmpty(parent.bounds) && fabs(scale - 1.0) < 0.02) {
        CGFloat width = CGRectGetWidth(parent.bounds);
        CGFloat height = CGRectGetHeight(parent.bounds);
        // The app was laid out at the tall size once. The host stays that tall
        // and the card clips it. Shrinking the host to the card on each move
        // is the empty band: the picture then thinks it is still the old size.
        if (_revealingTallContent && CGRectGetHeight(_stageFrame) > height) {
            height = CGRectGetHeight(_stageFrame);
            _hostView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            // The picture has to grow with this one change. Leaving it at the
            // half height is the black band, even when the host is already tall.
            _hostView.autoresizesSubviews = YES;
            CGRect want = CGRectMake(0.0, 0.0, width, height);
            if (!CGRectEqualToRect(_hostView.frame, want)) _hostView.frame = want;
            objc_setAssociatedObject(_hostView, DSCardHostKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            _hostView.hidden = NO;
            _hostView.clipsToBounds = YES;
            _hostView.layer.masksToBounds = YES;
            if ([_bundleIdentifier isEqualToString:@"com.apple.mobilephone"]) {
                parent.clipsToBounds = YES;
                parent.layer.masksToBounds = YES;
                [self clipHostContentsToCard];
            }
            [self roundHostedSceneToCard];
            return;
        }
        UIViewAutoresizing mask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        if (_keyboardClipHeight > 1.0) {
            UIView *card = parent.superview;
            if (card && CGRectGetHeight(card.bounds) > height + 0.5) {
                height = CGRectGetHeight(card.bounds);
            }
            mask = UIViewAutoresizingFlexibleWidth;
        }
        if (_hostView.autoresizingMask != mask) _hostView.autoresizingMask = mask;
        CGRect want = CGRectMake(0.0, 0.0, width, height);
        if (!CGRectEqualToRect(_hostView.frame, want)) _hostView.frame = want;
        objc_setAssociatedObject(_hostView, DSCardHostKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        _hostView.hidden = NO;
        _hostView.clipsToBounds = !_messagesKeyboardVisible;
        _hostView.layer.masksToBounds = !_messagesKeyboardVisible;
        if ([_bundleIdentifier isEqualToString:@"com.apple.mobilephone"] && parent) {
            parent.clipsToBounds = YES;
            parent.layer.masksToBounds = YES;
        }
        [self clipHostContentsToCard];
        [self roundHostedSceneToCard];
        if (!_clampingHost) {
            _clampingHost = YES;
            [self clampOversizedSubviewsOf:_hostView depth:0];
            _clampingHost = NO;
        }
        [self roundHostedSceneToCard];
        if (!DSSceneWriteWouldTrap()) {
            [self hideStrayPresentationsOutsideCard];
            [self scheduleStrayPresentationSweep];
        }
        return;
    }

    CGRect logical = [self logicalFrame];
    CGFloat shrink = scale > 0 ? 1.0 / scale : 1.0;
    _hostView.autoresizingMask = UIViewAutoresizingNone;
    _hostView.frame = CGRectMake(0, 0, CGRectGetWidth(logical), CGRectGetHeight(logical));
    _hostView.transform = CGAffineTransformMakeScale(shrink, shrink);
    if (parent && !CGRectIsEmpty(parent.bounds)) {
        _hostView.center = CGPointMake(CGRectGetMidX(parent.bounds), CGRectGetMidY(parent.bounds));
    } else {
        _hostView.center = CGPointMake(CGRectGetWidth(_stageFrame) / 2.0, CGRectGetHeight(_stageFrame) / 2.0);
    }
    objc_setAssociatedObject(_hostView, DSCardHostKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    _hostView.hidden = NO;
    _hostView.clipsToBounds = !_messagesKeyboardVisible;
    _hostView.layer.masksToBounds = !_messagesKeyboardVisible;
    if ([_bundleIdentifier isEqualToString:@"com.apple.mobilephone"] && parent) {
        parent.clipsToBounds = YES;
        parent.layer.masksToBounds = YES;
    }
    [self clipHostContentsToCard];
    [self roundHostedSceneToCard];
    if (!_clampingHost) {
        _clampingHost = YES;
        [self clampOversizedSubviewsOf:_hostView depth:0];
        _clampingHost = NO;
    }
    [self roundHostedSceneToCard];
    if (!DSSceneWriteWouldTrap()) {
        [self hideStrayPresentationsOutsideCard];
        [self scheduleStrayPresentationSweep];
    }
}

- (void)refreshPresentedGeometry {
    // Fit the view that is already on the card. Starting another scene
    // transaction here re-pins the app to the whole display and the card goes black.
    [self layoutHostView];
}

- (pid_t)hostedProcessIdentifier {
    SBApplication *application = [self application];
    if ([application respondsToSelector:@selector(pid)]) {
        pid_t pid = application.pid;
        if (pid > 0) return pid;
    }
    FBScene *scene = [self appViewScene] ?: _scene;
    id process = [scene respondsToSelector:@selector(clientProcess)] ? scene.clientProcess : nil;
    if ([process respondsToSelector:@selector(pid)]) {
        pid_t pid = ((pid_t (*)(id, SEL))objc_msgSend)(process, @selector(pid));
        if (pid > 0) return pid;
    }
    return 0;
}

- (void)releaseRunningAssertion {
    id assertion = _runningAssertion;
    _runningAssertion = nil;
    _runningAssertionPid = 0;
    if (!assertion) return;
    @try {
        if ([assertion respondsToSelector:@selector(invalidate)]) {
            ((void (*)(id, SEL))objc_msgSend)(assertion, @selector(invalidate));
        }
    } @catch (NSException *exception) {
    }
}

// A minimized app was only marked backgrounded, so RunningBoard suspended it
// or the app crashed in that transition. This assertion is what keeps the
// process scheduled after the card has left the screen.
- (DSRunningAssertion *)acquireRunningAssertionForClass:(Class)assertionClass
                                                    pid:(pid_t)pid
                                                  flags:(NSUInteger)flags
                                                 reason:(NSUInteger)reason {
    DSRunningAssertion *assertion = nil;
    @try {
        if (pid > 0) {
            assertion = [(DSRunningAssertion *)[assertionClass alloc] initWithPID:(NSInteger)pid
                                                                             flags:flags
                                                                            reason:reason
                                                                              name:@"Dynamic Stage"
                                                                       withHandler:nil];
        } else if (_bundleIdentifier.length > 0) {
            assertion = [(DSRunningAssertion *)[assertionClass alloc] initWithBundleIdentifier:_bundleIdentifier
                                                                                          flags:flags
                                                                                         reason:reason
                                                                                           name:@"Dynamic Stage"
                                                                                    withHandler:nil];
        }
    } @catch (NSException *exception) {
        assertion = nil;
    }
    if (!assertion) return nil;
    BOOL valid = YES;
    if ([assertion respondsToSelector:@selector(valid)]) valid = assertion.valid;
    if (valid) return assertion;
    @try {
        if ([assertion respondsToSelector:@selector(invalidate)]) [assertion invalidate];
    } @catch (NSException *exception) {
    }
    return nil;
}

- (void)holdRunningAssertion {
    if (!_appViewController && !_scene && !_hostView) return;
    pid_t pid = [self hostedProcessIdentifier];
    if (_runningAssertion && (pid <= 0 || _runningAssertionPid == pid)) {
        BOOL valid = YES;
        if ([_runningAssertion respondsToSelector:@selector(valid)]) {
            valid = ((BOOL (*)(id, SEL))objc_msgSend)(_runningAssertion, @selector(valid));
        }
        if (valid) return;
        [self releaseRunningAssertion];
    } else if (_runningAssertion) {
        [self releaseRunningAssertion];
    }

    Class assertionClass = objc_getClass("BKSProcessAssertion");
    if (!assertionClass) {
        [self scheduleRunningAssertionRetry];
        return;
    }

    // Prevent suspend, keep the CPU from being throttled to a stop, and still
    // let the phone sleep. Continuous is the reason that does not expire.
    NSUInteger flags = (1u << 0) | (1u << 1) | (1u << 2);
    NSUInteger reasons[] = { 10005u, 9u, 7u, 10004u };
    for (NSUInteger index = 0; index < 4; index++) {
        DSRunningAssertion *assertion = [self acquireRunningAssertionForClass:assertionClass
                                                                            pid:pid
                                                                          flags:flags
                                                                         reason:reasons[index]];
        if (!assertion && pid > 0) {
            assertion = [self acquireRunningAssertionForClass:assertionClass pid:0 flags:flags reason:reasons[index]];
        }
        if (!assertion) continue;
        _runningAssertion = assertion;
        _runningAssertionPid = pid > 0 ? pid : 0;
        _runningAssertionAttempts = 0;
        DSDiagnosticsRecordFormat(@"SpringBoard: %@ stays running in the background", _bundleIdentifier);
        return;
    }
    [self scheduleRunningAssertionRetry];
}

- (void)scheduleRunningAssertionRetry {
    if (_runningAssertionRetry || _runningAssertionAttempts >= 4) return;
    _runningAssertionRetry = YES;
    _runningAssertionAttempts += 1;
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_runningAssertionRetry = NO;
        if (!strongSelf->_appViewController && !strongSelf->_scene && !strongSelf->_hostView) return;
        [strongSelf holdRunningAssertion];
    });
}

- (void)setFollowsSystemHomeTransition:(BOOL)follows {
    if (!_appViewController || _followsSystemHome == follows) return;
    _followsSystemHome = follows;
    SBAppViewController *controller = _appViewController;
    @try {
        // Property only. Changing the app view's mode on the way back runs in
        // the same moment the next transition starts — Spotlight's keyboard
        // was the one on screen — and that mode change is the SIGTRAP.
        if ([controller respondsToSelector:@selector(setAutomatesLifecycle:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(setAutomatesLifecycle:), follows);
        }
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: %@ home-transition handoff threw %@",
                                  _bundleIdentifier, exception.name ?: @"?");
    }
    if (!follows) [self holdRunningAssertion];
    if (follows) {
        DSDiagnosticsRecordFormat(@"SpringBoard: %@ will follow the home transition", _bundleIdentifier);
    }
}

- (void)setStaysBackgrounded:(BOOL)stays {
    BOOL changed = _staysBackgrounded != stays;
    _staysBackgrounded = stays;
    if (_appViewController) {
        objc_setAssociatedObject(_appViewController, @selector(appViewControllerStaysBackgrounded:),
                                 @(stays), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (stays || _appViewController || _scene) [self holdRunningAssertion];
    if (DSAvoidSceneLifecycle()) return;
    if (changed && (_scene || _appViewController)) [self registerGeometryOnlyOverride];
}

- (void)setForeground:(BOOL)foreground {
    _foreground = foreground;
    if (DSAvoidSceneLifecycle()) return;

    // SpringBoard's app view owns the app's lifecycle, and telling its scene it is
    // foreground from outside is exactly what makes it assert - which takes
    // SpringBoard with it. So under an app view the stage only ever dictates size.
    if (_appViewController) {
        [self registerGeometryOnlyOverride];
        if (foreground) [self wakeIfBackgrounded];
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
            // Minimized means "not the front app", not "suspend the process".
            // backgrounded YES is what made the app stop or crash.
            BOOL backgrounded = foreground ? NO : (_staysBackgrounded ? NO : YES);
            if ([settings respondsToSelector:@selector(setBackgrounded:)]) settings.backgrounded = backgrounded;
            if (_staysBackgrounded && [settings respondsToSelector:@selector(setDeactivated:)]) {
                settings.deactivated = NO;
            }
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
    [self restoreOwnedStrayPresentations];
    _straySweepScheduled = NO;
    [self releaseRunningAssertion];
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

// ---- 4.5.650: system transition (home swipe / app switcher) -------------
// The swipe up into the app switcher runs SpringBoard's own animation every
// frame. Stage hooks that ran full work on each of those frames (scene view
// clip/frame, context host pin, hosted scene bookkeeping, app relayout) were
// the lag. They now ask this first.
static BOOL DSSwitcherVisibleCached = NO;
static CFAbsoluteTime DSSwitcherCheckedAt = 0;
static BOOL DSSysGesturePosted = NO;
static CFAbsoluteTime DSSysGesturePostedAt = 0;
static NSInteger DSSysGesturePollGeneration = 0;

static BOOL DSReadSwitcherVisible(void) {
    static const char *names[] = { "SBMainSwitcherController", "SBMainSwitcherViewController" };
    for (int i = 0; i < 2; i++) {
        Class controllerClass = objc_getClass(names[i]);
        if (!controllerClass || ![controllerClass respondsToSelector:@selector(sharedInstance)]) continue;
        @try {
            id controller = ((id (*)(id, SEL))objc_msgSend)(controllerClass, @selector(sharedInstance));
            if (!controller || ![controller respondsToSelector:@selector(isMainSwitcherVisible)]) continue;
            return ((BOOL (*)(id, SEL))objc_msgSend)(controller, @selector(isMainSwitcherVisible));
        } @catch (NSException *exception) {
            return NO;
        }
    }
    return NO;
}

// Darwin state = absolute time the transition began (0 = over). Refreshed
// every 2s while it lasts; apps treat a value older than 4s as over.
static void DSPostSystemGestureState(void) {
    BOOL active = DSHomeGestureActive || DSSwitcherVisibleCached;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (active == DSSysGesturePosted && (!active || now - DSSysGesturePostedAt < 2.0)) return;
    DSSysGesturePosted = active;
    DSSysGesturePostedAt = now;
    static int token = NOTIFY_TOKEN_INVALID;
    if (token == NOTIFY_TOKEN_INVALID) {
        notify_register_check("com.recreated.dynamicstage.systemgesture", &token);
    }
    if (token != NOTIFY_TOKEN_INVALID) notify_set_state(token, active ? (uint64_t)now : 0);
    notify_post("com.recreated.dynamicstage.systemgesture");
}

// Only runs while a transition is active; stops by itself (no timer).
static void DSSystemTransitionPoll(NSInteger generation) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != DSSysGesturePollGeneration) return;
        DSSwitcherVisibleCached = DSReadSwitcherVisible();
        DSSwitcherCheckedAt = CFAbsoluteTimeGetCurrent();
        DSPostSystemGestureState();
        if (DSSwitcherVisibleCached || DSHomeGestureActive) DSSystemTransitionPoll(generation);
    });
}

+ (BOOL)systemTransitionBusy {
    if (DSAvoidSceneLifecycle()) return YES;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - DSSwitcherCheckedAt > 0.1) {
        DSSwitcherCheckedAt = now;
        BOOL visible = DSReadSwitcherVisible();
        if (visible != DSSwitcherVisibleCached) {
            DSSwitcherVisibleCached = visible;
            DSPostSystemGestureState();
            if (visible) DSSystemTransitionPoll(++DSSysGesturePollGeneration);
        }
    }
    return DSSwitcherVisibleCached;
}

+ (void)setHomeGestureActive:(BOOL)active {
    BOOL changed = DSHomeGestureActive != active;
    DSHomeGestureActive = active;
    if (!active) DSHomeGestureQuietUntil = CFAbsoluteTimeGetCurrent() + 1.15;
    if (changed) {
        DSPostSystemGestureState();
        if (active) DSSystemTransitionPoll(++DSSysGesturePollGeneration);
    }
}

+ (BOOL)homeGestureIsActive {
    return DSAvoidSceneLifecycle();
}

+ (void)beginSystemPullCallback {
    DSSystemPullDepth += 1;
}

+ (void)endSystemPullCallback {
    if (DSSystemPullDepth > 0) DSSystemPullDepth -= 1;
}

+ (BOOL)systemPullCallbackIsActive {
    return DSSystemPullDepth > 0;
}

+ (void)beginSceneSettingsUpdate {
    DSSceneSettingsUpdateDepth += 1;
}

+ (void)endSceneSettingsUpdate {
    if (DSSceneSettingsUpdateDepth > 0) DSSceneSettingsUpdateDepth -= 1;
}

+ (NSInteger)sceneSettingsUpdateDepth {
    return DSSceneSettingsUpdateDepth;
}

+ (BOOL)stageRequestedFrame:(CGRect)frame forSceneIdentifier:(NSString *)identifier {
    if (identifier.length == 0 || CGRectIsEmpty(frame)) return NO;
    [DSSceneOverridesLock() lock];
    NSDictionary *override = DSSceneOverrides()[identifier];
    [DSSceneOverridesLock() unlock];
    if (!override) return NO;
    CGRect wanted = [override[@"frame"] CGRectValue];
    if (CGRectIsEmpty(wanted)) return NO;
    return fabs(CGRectGetWidth(wanted) - CGRectGetWidth(frame)) < 3.0 &&
           fabs(CGRectGetHeight(wanted) - CGRectGetHeight(frame)) < 3.0;
}

+ (void)noteFullScreenHandoffOfBundleIdentifier:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0) return;
    DSHandedOffBundle = [bundleIdentifier copy];
    DSHandedOffUntil = CFAbsoluteTimeGetCurrent() + 3.0;
    [DSSceneOverridesLock() lock];
    for (NSString *identifier in [DSSceneOverrides().allKeys copy]) {
        if ([identifier rangeOfString:bundleIdentifier].location == NSNotFound) continue;
        [DSSceneOverrides() removeObjectForKey:identifier];
    }
    [DSSceneOverridesLock() unlock];
}

+ (BOOL)isHandingOffSceneIdentifier:(NSString *)identifier {
    if (identifier.length == 0 || DSHandedOffBundle.length == 0) return NO;
    if (CFAbsoluteTimeGetCurrent() >= DSHandedOffUntil) return NO;
    return [identifier rangeOfString:DSHandedOffBundle].location != NSNotFound;
}

+ (BOOL)readForegroundFlag:(id)settings known:(BOOL *)known {
    if (known) *known = NO;
    if (!settings) return NO;
    for (NSString *name in @[ @"isForeground", @"foreground" ]) {
        SEL selector = NSSelectorFromString(name);
        if (![settings respondsToSelector:selector]) continue;
        @try {
            BOOL value = ((BOOL (*)(id, SEL))objc_msgSend)(settings, selector);
            if (known) *known = YES;
            return value;
        } @catch (NSException *exception) {
        }
    }
    return NO;
}

+ (void)keepCommittedForegroundOfScene:(FBScene *)scene onSettings:(FBSMutableSceneSettings *)settings {
    if (!settings || ![scene respondsToSelector:@selector(settings)]) return;
    BOOL known = NO;
    BOOL foreground = [self readForegroundFlag:scene.settings known:&known];
    if (!known || ![settings respondsToSelector:@selector(setForeground:)]) return;
    @try {
        settings.foreground = foreground;
    } @catch (NSException *exception) {
    }
}

+ (BOOL)applyOverridesToSettings:(FBSMutableSceneSettings *)settings forScene:(FBScene *)scene {
    if (DSAvoidSceneLifecycle()) return NO;
    if (!settings || ![scene respondsToSelector:@selector(identifier)]) return NO;
    NSString *identifier = scene.identifier;
    if (identifier.length == 0) return NO;
    if (DSHandedOffBundle.length > 0 && CFAbsoluteTimeGetCurrent() < DSHandedOffUntil &&
        [identifier rangeOfString:DSHandedOffBundle].location != NSNotFound) {
        // The card override is gone. A settings write that still carries the
        // split size would put Messages back in that rectangle.
        CGRect screen = UIScreen.mainScreen.bounds;
        CGRect frame = CGRectZero;
        @try {
            frame = settings.frame;
        } @catch (NSException *exception) {
        }
        BOOL shortOfPhone = CGRectGetWidth(screen) > 80.0 && CGRectGetHeight(screen) > 80.0 &&
            (CGRectGetWidth(frame) + 8.0 < CGRectGetWidth(screen) ||
             CGRectGetHeight(frame) + 24.0 < CGRectGetHeight(screen));
        if (!shortOfPhone) return NO;
        UIEdgeInsets insets = UIEdgeInsetsZero;
        if (@available(iOS 11.0, *)) {
            insets = UIApplication.sharedApplication.windows.firstObject.safeAreaInsets;
        }
        DSApplyGeometry(settings, CGRectMake(0.0, 0.0, CGRectGetWidth(screen), CGRectGetHeight(screen)), insets);
        return YES;
    }

    [DSSceneOverridesLock() lock];
    NSDictionary *override = DSSceneOverrides()[identifier];
    [DSSceneOverridesLock() unlock];
    if (!override) return NO;

    DSApplyGeometry(settings, [override[@"frame"] CGRectValue], [override[@"insets"] UIEdgeInsetsValue]);
    // A minimized app stays backgrounded. Never write foreground YES here.
    // That write is the assert that safe-modes SpringBoard.
    if ([override[@"staysBackgrounded"] boolValue]) {
        @try {
            // Not the front app. Still running: backgrounded YES suspends it.
            if ([settings respondsToSelector:@selector(setForeground:)]) settings.foreground = NO;
            if ([settings respondsToSelector:@selector(setBackgrounded:)]) settings.backgrounded = NO;
            if ([settings respondsToSelector:@selector(setDeactivated:)]) settings.deactivated = NO;
        } @catch (NSException *exception) {
        }
    }
    // 4.5.652: a visible card whose app holds the camera is on screen and in
    // front as far as its own scene is concerned: not occluded, nothing
    // deactivating it. Foreground itself is never written here (see above),
    // and nothing is written during the home / switcher gesture.
    if (![override[@"staysBackgrounded"] boolValue] && ![self homeGestureIsActive] &&
        ![self systemTransitionBusy] && [DSCameraArbiter sceneIdentifierHoldsCamera:identifier]) {
        @try {
            if ([settings respondsToSelector:@selector(setOccluded:)]) settings.occluded = NO;
            SEL reasons = NSSelectorFromString(@"setDeactivationReasons:");
            if ([settings respondsToSelector:reasons]) {
                ((void (*)(id, SEL, unsigned long long))objc_msgSend)(settings, reasons, 0ULL);
            }
            static CFAbsoluteTime DSCameraSceneLog = 0;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - DSCameraSceneLog > 3.0) {
                DSCameraSceneLog = now;
                DSDiagnosticsRecordFormat(@"SpringBoard: camera652 %@ holds the camera: scene kept unoccluded, no deactivation, path=scene-front", identifier);
            }
        } @catch (NSException *exception) {
        }
    }
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

+ (BOOL)appViewControllerStaysBackgrounded:(id)controller {
    if (!controller) return NO;
    NSNumber *value = objc_getAssociatedObject(controller, @selector(appViewControllerStaysBackgrounded:));
    return value.boolValue;
}

+ (BOOL)sceneIdentifierStaysBackgrounded:(NSString *)identifier {
    if (identifier.length == 0) return NO;
    [DSSceneOverridesLock() lock];
    NSDictionary *override = DSSceneOverrides()[identifier];
    BOOL stays = [override[@"staysBackgrounded"] boolValue];
    [DSSceneOverridesLock() unlock];
    return stays;
}

+ (BOOL)hasAnySceneOverride {
    [DSSceneOverridesLock() lock];
    BOOL any = DSSceneOverrides().count > 0;
    [DSSceneOverridesLock() unlock];
    return any;
}

+ (BOOL)sceneIdentifierHasOverride:(NSString *)identifier {
    if (identifier.length == 0) return NO;
    [DSSceneOverridesLock() lock];
    BOOL has = DSSceneOverrides()[identifier] != nil;
    [DSSceneOverridesLock() unlock];
    return has;
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

@end
