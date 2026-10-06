#import <UIKit/UIKit.h>
#import "DSPrivate.h"

typedef void (^DSSceneHostReadyBlock)(BOOL ready);

// Wraps one application's scene: launches it without letting SpringBoard hand
// it the whole screen, hosts its live render in a SpringBoard view, and keeps
// forcing the geometry the stage wants.
@interface DSSceneHost : NSObject

@property (nonatomic, readonly, copy) NSString *bundleIdentifier;
@property (nonatomic, readonly) UIView *hostView;
@property (nonatomic, readonly) BOOL isHosting;
// Logical size handed to the app, which is the stage size multiplied by the
// scale preference; the host view is then transformed back down.
@property (nonatomic, readonly) CGFloat contentScale;
// Set when the app could only be started by opening it for real, which leaves it
// as the front app; whoever was in front before has to be put back.
@property (nonatomic, readonly) BOOL tookOverForegroundLaunch;

// The stage's own view controller. SpringBoard's app view controller has to be a
// child of a real view controller or the app it shows never learns which way up it
// is, so the stage hands its own over before asking for anything.
@property (nonatomic, weak) UIViewController *parentViewController;

- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier;

// Launches (suspended) if needed and calls back once a hostable scene exists.
- (void)prepareWithCompletion:(DSSceneHostReadyBlock)completion;

// Frame in screen coordinates that the app should believe it occupies.
@property (nonatomic, readonly) CGRect stageFrame;
// When set, the scene uses the card's frame as given. Ordinary cards leave this
// off so a card on the bottom half does not host the keyboard inside itself.
@property (nonatomic, assign) BOOL matchCardFrame;
- (void)setStageFrame:(CGRect)frame safeAreaInsets:(UIEdgeInsets)insets;
// Stores the card size before the app view exists. The app is created at this
// size, so its own bars land inside the card.
- (void)noteLaunchFrame:(CGRect)frame;
// The top app is laid out once at the tallest size this drag can reach.
// The card is a window onto that layout. YES while that window is open.
@property (nonatomic, readonly, getter=isRevealingTallContent) BOOL revealingTallContent;
// Puts the hosted view in the card it is attached to. Does not resize the scene.
// While a card is growing under the finger, the app is laid out once at the
// tallest size. The card clips that layout, so more of it appears as the card
// grows. A scene transaction on every move dropped Messages' keyboard.
- (BOOL)beginRevealingTallContent:(CGRect)fullFrame;
- (void)endRevealingTallContent:(CGRect)cardFrame;
- (void)stopRevealingTallContent;
// Split is closing and this app is about to fill the phone. The scene is
// still the card until this write. Without it, Messages keeps the 426 by 460
// layout after it looks full screen.
- (void)handOffAtFullScreen;
- (void)fitHostViewToCard;
// Asks the hosted view to redraw after its card changes size. Does not set a
// frame on the scene view. That call waits on the app and safe-modes SpringBoard.
- (void)markHostNeedsLiveRedraw;
// The card grew. The app was already laid out at the tall size, so this only
// keeps the host there. It does not write scene settings.
- (void)adoptGrowingCardFrame:(CGRect)frame;
// Scene size, host size, and the picture inside the host. For the blank band.
- (NSString *)growingContentDebugLine;
// The app view re-pins the scene to the whole display after launch. Write the
// card size again when the live scene is still larger than the card.
// This does not start a scene transaction. A transaction here is what blanks
// the card and, stacked up, what safe-modes SpringBoard.
- (void)refitPresentedScene;
// Same geometry write, for a card whose size is changing under a finger.
- (void)applyCardFrameQuietly:(CGRect)frame;
// How much of the bottom of the card the host view should extend past, so the
// content view's bounds clip that band. Does not change the scene's size.
- (void)setKeyboardClipHeight:(CGFloat)height;
- (CGFloat)keyboardClipHeight;
// Messages draws its keyboard below the card. The host has to stop clipping
// that area or the keys are painted and then thrown away.
- (void)setMessagesKeyboardVisible:(BOOL)visible;
// An app whose scene was backgrounded while its card was parked comes back
// black until it is asked to run again. Called when the card is shown.
- (void)wakeIfBackgrounded;
// The app view re-pins itself to the full display and the card stays black until
// geometry is written again. Call this after the card has moved.
- (void)refreshPresentedGeometry;
- (void)setForeground:(BOOL)foreground;
// A minimized card stays backgrounded. This never sets a scene foreground.
- (void)setStaysBackgrounded:(BOOL)stays;

// Hands the scene back to SpringBoard. `background` keeps the process alive so
// notifications keep flowing; otherwise it is left suspended as usual.
- (void)relinquishKeepingBackgrounded:(BOOL)background;
- (void)terminate;
- (BOOL)isProcessAlive;

// The scene now showing on the stage, whichever way it was come by.
- (FBScene *)hostedScene;

// 4.5.658: one line describing the hosted process for the camera log: pid,
// how it is hosted, the stage's own foreground flag, the running assertion,
// the scene settings FrontBoard holds and SpringBoard's process state. Read
// only; main thread.
- (NSString *)cameraStateSummary;
- (pid_t)hostedProcessIdentifier;

// Called once the host view is in the card, so SpringBoard's app view learns it has
// finished moving in.
- (void)noteHostViewAttached;

// Called by the FBScene hook so SpringBoard's own layout passes cannot undo the
// stage geometry.
+ (BOOL)applyOverridesToSettings:(FBSMutableSceneSettings *)settings forScene:(FBScene *)scene;

// `foreground` on these settings is read with -isForeground. Calling -foreground
// throws, and a failed read looks like "foreground off", which is what made the
// card throw away the update that fits the scene to the card.
+ (BOOL)readForegroundFlag:(id)settings known:(BOOL *)known;
// Puts the scene's already-committed foreground back onto a pending update so
// the card size can land without backgrounding a scene that is on screen.
+ (void)keepCommittedForegroundOfScene:(FBScene *)scene onSettings:(FBSMutableSceneSettings *)settings;

// An app view controller of the stage's own making is not part of SpringBoard's
// scene layout, so settings churn makes it assert; the hook that contains that has
// to know which ones are the stage's.
+ (BOOL)ownsAppViewController:(id)controller;
// A minimized app's app view asserts if SpringBoard delivers a scene update while
// another app is opening. The hook has to drop that update.
+ (BOOL)appViewControllerStaysBackgrounded:(id)controller;
+ (BOOL)sceneIdentifierStaysBackgrounded:(NSString *)identifier;
// YES when this scene has stage geometry. The app switcher updates every
// other scene constantly; those updates must not be copied.
+ (BOOL)hasAnySceneOverride;
+ (BOOL)sceneIdentifierHasOverride:(NSString *)identifier;

// SpringBoard's scene manager for the built-in display. It owns where a hosted
// app's keyboard goes, among other things.
+ (id)mainDisplaySceneManager;

// Every scene that passes through the settings hooks is remembered, so an app's
// scene can still be found on a build where none of the usual ways to ask for it
// exist any more.
+ (void)noteLiveScene:(FBScene *)scene;
+ (FBScene *)liveSceneForBundleIdentifier:(NSString *)bundleIdentifier;

// The system home swipe is already a scene transition. Writing foreground or
// starting another transaction in that window is a SIGTRAP.
+ (void)setHomeGestureActive:(BOOL)active;
+ (BOOL)homeGestureIsActive;
// 4.5.657: YES while the home gesture / its quiet window runs, and from the
// moment a home / switcher swipe begins with a stage app around until the
// stage is next used (noteStageInUse). The app switcher itself is never
// asked (4.5.650-656 polled SBMainSwitcherController every 0.1-0.3 s while
// it was open); the stage's own state is the signal. The staged apps hear
// only the gesture begin / end (com.recreated.dynamicstage.systemgesture).
+ (BOOL)systemTransitionBusy;
// 4.5.657: a home / switcher swipe began with a stage app hosted or a card on
// screen. Set from the home gesture begin only (one static write).
+ (void)noteSystemTookScreen;
// 4.5.657: the user is using the stage again (opened it, pulled a card back,
// touched a card). Clears the flag above and runs deferred work.
+ (void)noteStageInUse;
// 4.5.657: runs the block now, or once the system transition is over and the
// stage is next used. Replaces the 0.4 s re-poll loops during the switcher.
+ (void)performWhenSystemTransitionOver:(dispatch_block_t)block;
// The corner pull runs inside SpringBoard's own gesture callback. A display
// mode change or a new scene transaction from that callback is a SIGTRAP.
+ (void)beginSystemPullCallback;
+ (void)endSystemPullCallback;
+ (BOOL)systemPullCallbackIsActive;
// Nonzero while an FBScene settings update is on the stack. Fitting a
// presentation, or starting another update, from inside that call never returns.
+ (void)beginSceneSettingsUpdate;
+ (void)endSceneSettingsUpdate;
+ (NSInteger)sceneSettingsUpdateDepth;
// A minimized app is still a live app view that refuses system lifecycle.
// SpringBoard's home transition traps on that. While the swipe is in progress
// the parked host follows the system, then the stage takes lifecycle back.
- (void)setFollowsSystemHomeTransition:(BOOL)follows;
// The app just left its card and became the real front app. Drop any stage
// override for it so the home swipe cannot resize that scene.
+ (void)noteFullScreenHandoffOfBundleIdentifier:(NSString *)bundleIdentifier;
// YES for a few seconds after that handoff. A later settings write must not
// put the split size back.
+ (BOOL)isHandingOffSceneIdentifier:(NSString *)identifier;
// 4.5.659: YES for ~1.5 s after the stage activated this scene's app view
// right after a home-transition hand-back. That activation's own scene update
// lands (card geometry applied) instead of being refused.
+ (BOOL)isStageActivatingSceneIdentifier:(NSString *)identifier;
// YES when this frame is the size the stage just stored for that scene.
// A nearly full-screen update from anywhere else is another app opening,
// and that one is refused. The tall split size is this one, and it has to land.
+ (BOOL)stageRequestedFrame:(CGRect)frame forSceneIdentifier:(NSString *)identifier;

@end

// ---- 4.5.657: an app killed from the app switcher ----------------------------
// The kill hooks only call DSSceneHostMarkBundleDied (data only: a set entry
// and the dead scene's geometry overrides removed). Nothing in the stage UI
// runs during the swipe. Hosting checks treat the bundle as gone at once, so a
// relaunch of the same app is never given the card frame. The manager does the
// real "stage app closed" handling on the next stage use.
FOUNDATION_EXPORT void DSSceneHostMarkBundleDied(NSString *bundleIdentifier);
FOUNDATION_EXPORT BOOL DSSceneHostBundleDiedPending(NSString *bundleIdentifier);
FOUNDATION_EXPORT BOOL DSSceneHostAnyDiedPending(void);
FOUNDATION_EXPORT NSArray<NSString *> *DSSceneHostTakeDiedBundles(void);
FOUNDATION_EXPORT void DSSceneHostClearDied(NSString *bundleIdentifier);
// Number of scene identifiers with stage geometry (no lock; a hint for the
// FBScene hooks' first exit).
FOUNDATION_EXPORT NSInteger DSSceneHostOverrideCount(void);

