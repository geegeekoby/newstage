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
