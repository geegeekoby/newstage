// Private interfaces used by the SpringBoard side of Dynamic Stage.
//
// Everything here is declared rather than pulled from a header dump so the
// project builds against a stock iOS SDK. Every call site guards with
// -respondsToSelector: or a %c() class lookup, because a missing symbol on an
// unexpected iOS build must degrade into "the stage does not open" rather than
// a SpringBoard crash.

#import <UIKit/UIKit.h>

// FrontBoardServices ---------------------------------------------------------

@interface FBSSceneSettings : NSObject
@property (nonatomic, readonly) CGRect frame;
@property (nonatomic, readonly) BOOL foreground;
@property (nonatomic, readonly) NSInteger interfaceOrientation;
- (id)mutableCopy;
@end

@interface FBSMutableSceneSettings : FBSSceneSettings
@property (nonatomic, assign, readwrite) CGRect frame;
@property (nonatomic, assign, readwrite) BOOL foreground;
@property (nonatomic, assign, readwrite) BOOL backgrounded;
@property (nonatomic, assign, readwrite) BOOL occluded;
@property (nonatomic, assign, readwrite) BOOL deactivated;
@property (nonatomic, assign, readwrite) NSInteger interfaceOrientation;
@property (nonatomic, assign, readwrite) NSInteger deviceOrientation;
@property (nonatomic, assign, readwrite) UIEdgeInsets safeAreaInsetsPortrait;
@property (nonatomic, assign, readwrite) BOOL statusBarDisabled;
@property (nonatomic, assign, readwrite) BOOL canShowAlerts;
@property (nonatomic, assign, readwrite) NSInteger level;
@property (nonatomic, assign, readwrite) CGFloat displayScale;
- (void)setDisplayConfiguration:(id)configuration;
@end

@interface FBSSceneClientSettings : NSObject
@end

@interface FBSMutableSceneClientSettings : FBSSceneClientSettings
@property (nonatomic, assign, readwrite) NSInteger interfaceOrientation;
@property (nonatomic, assign, readwrite) NSUInteger supportedInterfaceOrientations;
@end

@interface FBSSceneTransitionContext : NSObject
@property (nonatomic, copy) id animationFence;
- (void)setActions:(NSSet *)actions;
@end

// KeyboardArbiter -----------------------------------------------------------

// The keyboard of every process on the device is arbitrated in SpringBoard, and this
// is what it is told each time one goes up, moves or comes down. The position is in
// display points, because the keyboard belongs to the display rather than to whichever
// app raised it.
@interface _UIKeyboardChangedInformation : NSObject
@property (nonatomic, readonly) CGRect keyboardPosition;
@property (nonatomic, readonly) BOOL keyboardOnScreen;
@property (nonatomic, copy) NSString *sourceBundleIdentifier;
@end

@interface _UIKeyboardArbiter : NSObject
- (void)updateKeyboardStatus:(_UIKeyboardChangedInformation *)information fromHandler:(id)handler;
@end

// FrontBoard ----------------------------------------------------------------

@interface FBSceneHostManager : NSObject
- (UIView *)hostViewForRequester:(NSString *)requester enableAndOrderFront:(BOOL)enableAndOrderFront;
- (void)enableHostingForRequester:(NSString *)requester priority:(NSUInteger)priority;
- (void)disableHostingForRequester:(NSString *)requester;
@end

@interface FBScene : NSObject
@property (nonatomic, readonly) NSString *identifier;
@property (nonatomic, readonly) FBSSceneSettings *settings;
@property (nonatomic, readonly) FBSSceneClientSettings *clientSettings;
@property (nonatomic, readonly) id clientProcess;
- (FBSceneHostManager *)hostManagerForRequester:(NSString *)requester;
- (void)updateSettings:(FBSSceneSettings *)settings withTransitionContext:(FBSSceneTransitionContext *)context completion:(void (^)(BOOL))completion;
- (void)updateSettingsWithBlock:(void (^)(FBSMutableSceneSettings *settings))block;
- (void)updateClientSettingsWithBlock:(void (^)(FBSMutableSceneClientSettings *settings))block;
@end

@interface FBProcess : NSObject
@property (nonatomic, readonly) NSInteger pid;
@end

// Making a scene from nothing -----------------------------------------------
//
// The usual way to put an app on the stage is to borrow the scene SpringBoard
// already keeps for it. An app that has never been opened has no such scene, and
// nothing SpringBoard is willing to do short of opening the app full screen will
// create one. These are the pieces needed to create a scene of the stage's own
// against a running app process and present it in a view - the same route used by
// every current iPad-style multitasking project.

@interface RBSProcessIdentity : NSObject
+ (instancetype)identityForEmbeddedApplicationIdentifier:(NSString *)identifier;
@end

@interface RBSProcessPredicate : NSObject
+ (instancetype)predicateMatchingIdentity:(RBSProcessIdentity *)identity;
@end

@interface RBSProcessHandle : NSObject
+ (instancetype)handleForPredicate:(RBSProcessPredicate *)predicate error:(NSError **)error;
@property (nonatomic, readonly) pid_t pid;
@property (nonatomic, readonly, copy) RBSProcessIdentity *identity;
@end

@interface FBSSceneIdentity : NSObject
+ (instancetype)identityForIdentifier:(NSString *)identifier;
@end

@interface FBSSceneClientIdentity : NSObject
+ (instancetype)identityForProcessIdentity:(RBSProcessIdentity *)identity;
@end

@interface FBSMutableSceneDefinition : NSObject
+ (instancetype)definition;
@property (nonatomic, strong) FBSSceneIdentity *identity;
@property (nonatomic, strong) FBSSceneClientIdentity *clientIdentity;
@property (nonatomic, strong) id specification;
@end

@interface FBSMutableSceneParameters : NSObject
+ (instancetype)parametersForSpecification:(id)specification;
@property (nonatomic, strong) FBSSceneSettings *settings;
@property (nonatomic, strong) FBSSceneClientSettings *clientSettings;
@end

@interface FBSceneManager : NSObject
+ (instancetype)sharedInstance;
- (FBScene *)sceneWithIdentifier:(NSString *)identifier;
- (FBScene *)createSceneWithDefinition:(FBSMutableSceneDefinition *)definition
                     initialParameters:(FBSMutableSceneParameters *)parameters;
- (void)destroyScene:(NSString *)identifier withTransitionContext:(id)context;
@end

@interface UIScenePresenter : NSObject
@property (nonatomic, readonly) UIView *presentationView;
- (void)activate;
- (void)deactivate;
- (void)invalidate;
- (void)modifyPresentationContext:(void (^)(id context))block;
@end

@interface UIScenePresentationManager : NSObject
- (UIScenePresenter *)createPresenterWithIdentifier:(NSString *)identifier;
@end

@interface FBScene (DSPresentation)
- (UIScenePresentationManager *)uiPresentationManager;
@end

// SpringBoard ---------------------------------------------------------------

@interface SBApplicationInfo : NSObject
@property (nonatomic, readonly) NSString *bundleIdentifier;
@property (nonatomic, readonly) NSString *displayName;
@property (nonatomic, readonly) NSURL *bundleURL;
@property (nonatomic, readonly) NSString *bundlePath;
- (BOOL)isLaunchProhibited;
- (BOOL)supportsMultipleScenes;
- (BOOL)isMedusaCapable;
@end

// FrontBoard's own copy of the same record; which one SpringBoard consults for
// the multitasking flag moved between iOS versions, so both are hooked.
@interface FBApplicationInfo : NSObject
@property (nonatomic, readonly) NSString *bundleIdentifier;
- (BOOL)isMedusaCapable;
@end

@interface SBApplication : NSObject
@property (nonatomic, readonly) NSString *bundleIdentifier;
@property (nonatomic, readonly) NSString *displayName;
- (SBApplicationInfo *)info;
- (pid_t)pid;
- (FBScene *)mainScene;
- (NSArray<FBScene *> *)allScenes;
- (NSArray<FBScene *> *)scenes;
- (BOOL)isRunning;
- (id)processState;
@end

@interface SBApplicationController : NSObject
+ (instancetype)sharedInstance;
- (SBApplication *)applicationWithBundleIdentifier:(NSString *)bundleIdentifier;
- (NSArray<SBApplication *> *)allApplications;
@end

// SpringBoard's own way of showing a live app in a view ------------------------
//
// This is what the app switcher and iPad multitasking use, and it does the whole
// job: it makes the scene, launches the app if it is not running, hosts its render,
// and keeps it in SpringBoard's own lifecycle and keyboard-focus bookkeeping. The
// stage asks for it by name rather than assembling any of that itself.

@interface SBSceneManagerCoordinator : NSObject
+ (instancetype)sharedInstance;
+ (id)mainDisplaySceneManager;
- (id)mainDisplaySceneManager;
@end

@interface SBDeviceApplicationSceneEntity : NSObject
+ (instancetype)defaultEntityWithApplication:(id)application
                         sceneHandleProvider:(id)provider
                             displayIdentity:(id)displayIdentity;
- (instancetype)initWithApplicationForMainDisplay:(id)application;
@property (nonatomic, readonly) id sceneHandle;
@end

@interface SBSceneHandle : NSObject
- (FBScene *)scene;
- (FBScene *)sceneIfExists;
@end

@interface SBAppViewController : UIViewController
- (instancetype)initWithIdentifier:(NSString *)identifier andApplicationSceneEntity:(id)entity;
- (void)setIgnoresOcclusions:(BOOL)ignoresOcclusions;
- (void)_setCurrentMode:(long long)mode;
- (id)_createSceneUpdateTransactionForApplicationSceneEntity:(id)entity deliveringActions:(BOOL)deliveringActions;
- (void)_createSceneViewController;
- (void)setDisplayMode:(long long)mode animationFactory:(id)factory completion:(id)completion;
- (void)invalidate;
- (SBSceneHandle *)sceneHandle;
@end

@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstance;
@property (nonatomic, readonly) BOOL isUILocked;
@end

@interface SBHomeGrabberView : UIView
@end

@interface SBBacklightController : NSObject
+ (instancetype)sharedInstance;
- (BOOL)screenIsOn;
@end

@interface SBMainDisplaySceneManager : NSObject
- (void)_applyStatusBarHidden:(BOOL)hidden withAnimation:(NSInteger)animation toSceneWithIdentifier:(NSString *)identifier;
@end

@interface SpringBoard : UIApplication
- (void)launchApplicationWithIdentifier:(NSString *)identifier suspended:(BOOL)suspended;
- (SBApplication *)_accessibilityFrontMostApplication;
- (UIInterfaceOrientation)activeInterfaceOrientation;
- (void)_simulateHomeButtonPress;
@end

// UIKit private -------------------------------------------------------------

@interface UIImage (DSPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier format:(NSInteger)format scale:(CGFloat)scale;
@end

@interface UIScreen (DSPrivate)
- (CGFloat)_displayCornerRadius;
- (id)displayConfiguration;
@end

@interface UIGestureRecognizer (DSPrivate)
- (BOOL)_delaysTouchesForSystemGestures;
@end

@interface UIWindow (DSPrivate)
- (void)_setSecure:(BOOL)secure;
@end

// MobileCoreServices --------------------------------------------------------

@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *applicationIdentifier;
@property (nonatomic, readonly) NSString *localizedName;
@property (nonatomic, readonly) NSString *applicationType;
@property (nonatomic, readonly) NSArray *appTags;
@property (nonatomic, readonly) NSURL *bundleURL;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray<LSApplicationProxy *> *)allInstalledApplications;
@end

// Media --------------------------------------------------------------------

@interface SBMediaController : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isPlaying;
- (NSInteger)nowPlayingProcessPID;
- (NSString *)nowPlayingApplicationDisplayID;
@end
