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
// 4.5.672 keys672: read-only. The scene settings the app currently has
// (frame, portrait safe area, orientation), for the keyboard diagnostics.
- (NSString *)keys672SceneSummary;
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
// 4.5.668 sbcam668: phone-size scene shown at the card width, bottom-aligned,
// while an app with no app dylib in it uses the camera.
- (void)setCameraTall:(BOOL)tall why:(NSString *)why;
- (BOOL)isCameraTall;
// 4.5.675 phonesize675: while an allowlisted app with no app dylib in it
// (Beeper) has the keyboard up, its scene is the phone's size (screen width x
// screen height - 1, origin 0, the screen's safe area) and the host view shows
// it scaled to the card's width, with the keyboard's top edge (scene y =
// keyTop) on the card's bottom edge. The card frame never changes. Off: back
// to the card-size scene (the 4.5.674 geometry). Geometry writes only.
- (void)setPhoneSize675:(BOOL)on keyboardTop:(CGFloat)keyTop why:(NSString *)why;
- (BOOL)isPhoneSize675;
- (long long)sceneDeactivationReasons740;
// 4.5.678 phonesize678 (B/C): phone size before any keyboard.
- (BOOL)isPhoneSize678PreGrown;
- (BOOL)phoneSize678PreGrow:(BOOL)tapSafe why:(NSString *)why;
- (void)phoneSize678AnchorBottom:(NSString *)why;
- (void)phoneSize678RestWhy:(NSString *)why;
// 4.5.680 phonesize680: the card's window ends at the app's bar bottom (scene y).
- (CGFloat)phoneSize678BottomAnchor;
// 4.5.683: phone-size, allowlisted, no app dylib, 683 on: the app's own keyboard in the card.
- (BOOL)isPhoneSize683;
- (NSString *)phoneSize683HostCensus;
// 4.5.684 phonesize684: scene safe area {T,0,K,0} with K = the keyboard's
// height in the scene, the card's window fixed at app y T..(931-K).
- (BOOL)isPhoneSize684;
// 4.5.695: after the live view is put back on its card (restore): place the
// still phone-size scene with the 694 squash at once (no scene write).
- (void)phoneSize695ReturnedToCard;
// 4.5.696 (see DSSceneHost.m): fit (lower card onto the keys) and blackout watchdog.
- (BOOL)phoneSize696FitGeometry;
- (CGFloat)phoneSize696KeysTop;
- (NSString *)blackout696Tick;
// 4.5.699: wake now if the card's scene is in the background (nil = nothing done).
- (NSString *)blackout699WakeIfBackgrounded;
- (BOOL)isPhoneSize685;
- (BOOL)isPhoneSize687;
- (BOOL)isPhoneSize688Geo;
- (CGFloat)phoneSize688StatusBarHeight;
- (CGFloat)phoneSize687Bar;
- (CGFloat)phoneSize675FitForWidth:(CGFloat)width height:(CGFloat)height;
- (void)phoneSize684ArbiterOn:(BOOL)on height:(CGFloat)height at:(double)mediaTime;
- (CGFloat)phoneSize680BarBottom;
- (CGSize)phoneSize675SceneSize;
- (void)phoneSize680MoveBarBottomTo:(CGFloat)bar duration:(NSTimeInterval)duration curve:(NSInteger)curve lag:(double)lag why:(NSString *)why;
- (void)phoneSize681MoveBarBottomTo:(CGFloat)bar hide:(BOOL)hide signalAt:(double)signalAt offset:(BOOL)applyOffset why:(NSString *)why;
// 4.5.682: forceInstant = no animation whatever the tune says (the keys674 revert).
- (void)phoneSize682MoveBarBottomTo:(CGFloat)bar hide:(BOOL)hide signalAt:(double)signalAt offset:(BOOL)applyOffset instant:(BOOL)forceInstant why:(NSString *)why;
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
- (void)setForeground:(BOOL)foreground;
// A minimized card stays backgrounded. This never sets a scene foreground.
- (void)setStaysBackgrounded:(BOOL)stays;

// Hands the scene back to SpringBoard. `background` keeps the process alive so
// notifications keep flowing; otherwise it is left suspended as usual.
- (void)relinquishKeepingBackgrounded:(BOOL)background;
- (void)terminate;
- (BOOL)isProcessAlive;
- (BOOL)host754Ready;   // 4.5.754: hosting the app, scene present, app view in the card

// The scene now showing on the stage, whichever way it was come by.
- (FBScene *)hostedScene;

// 4.5.658: one line describing the hosted process for the camera log: pid,
// how it is hosted, the stage's own foreground flag, the running assertion,
// the scene settings FrontBoard holds and SpringBoard's process state. Read
// only; main thread.
- (NSString *)cameraStateSummary;
- (pid_t)hostedProcessIdentifier;
// 4.5.719 bg719: legacy RunningBoard keep-alive (see DSSceneHost.m).
- (void)bg719Request:(NSString *)why;
- (void)bg719AllowRetake;

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

// 4.5.800 reason800 / fg800; 4.5.801 fg801 (see DSSceneHost.m).
// Off: reason800-off / fg800-off / fg801-off / core800-off / core801-off.
+ (BOOL)reg799AppendReason:(NSString *)ident toSettings:(id)settings log:(BOOL)log;
+ (NSString *)reason800IdentifierForAppViewController:(id)controller;
+ (BOOL)reason800EnsureReasonOnSettings:(id)settings forAppViewController:(id)controller;
+ (BOOL)reason800EnsureReasonOnScene:(id)scene settings:(id)settings;
+ (void)fg800LeaveLiveIfBackgrounded:(id)controller handle:(id)handle previousSettings:(id)previousSettings;
+ (void)fg800RestoreLiveIfNeeded:(id)controller;
+ (BOOL)fg801ShouldSkipForegroundAssertionOrig:(id)controller previousSettings:(id)previousSettings handle:(id)handle;

// A minimized app's app view asserts if SpringBoard delivers a scene update while
// another app is opening. The hook has to drop that update.
+ (BOOL)appViewControllerStaysBackgrounded:(id)controller;
+ (BOOL)sceneIdentifierStaysBackgrounded:(NSString *)identifier;
// YES when this scene has stage geometry. The app switcher updates every
// other scene constantly; those updates must not be copied.
+ (BOOL)sceneIdentifierHasOverride:(NSString *)identifier;

// SpringBoard's scene manager for the built-in display. It owns where a hosted
// app's keyboard goes, among other things.
+ (id)mainDisplaySceneManager;

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
// 4.5.665: the home gesture ended under 4 s ago, the parked apps were handed
// back under 3 s ago, or a corner pull adopted from SpringBoard's gesture is
// running / ended under 1.5 s ago. Returns why (nil = none). A phone-sized
// update of a hosted scene inside that window is SpringBoard's own transition:
// it lands at card size, it is never refused.
+ (NSString *)systemTransitionHoldsSceneReason;
+ (void)noteHomeHandBack;
+ (void)noteSystemEdgePullActive:(BOOL)active;
+ (BOOL)systemEdgePullIsActive;
// YES when this frame is the size the stage just stored for that scene.
// A nearly full-screen update from anywhere else is another app opening,
// and that one is refused. The tall split size is this one, and it has to land.
+ (BOOL)stageRequestedFrame:(CGRect)frame forSceneIdentifier:(NSString *)identifier;

- (void)msgfit757Nudge;
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
// 4.5.675 phonesize675 switches. Off file: /var/mobile/.dynamicstage-phonesize675-off.
// Allowlist file: /var/mobile/.dynamicstage-phonesize675-apps (one bundle id per
// line, replaces the default list; default is com.beeper.chat.ios only).
FOUNDATION_EXPORT BOOL DSPhoneSize675ChangedRecently(double window);
FOUNDATION_EXPORT BOOL DSPhoneSize675Disabled(void);
FOUNDATION_EXPORT BOOL DSPhoneSize675Allowed(NSString *bundleIdentifier);
FOUNDATION_EXPORT NSString *DSPhoneSize675AllowlistSummary(void);
FOUNDATION_EXPORT CGFloat DSPhoneSize675PinOffset(void);
// 4.5.676 phonesize676: timestamps of one keyboard session (ms since its first
// signal, -1 when none), and the opt-in / opt-out files.
FOUNDATION_EXPORT void DSPhoneSize676StartSession(double mediaTime);
FOUNDATION_EXPORT double DSPhoneSize676Ms(void);
FOUNDATION_EXPORT double DSPhoneSize676MsAt(double mediaTime);
// 4.5.677: /var/mobile/.dynamicstage-phonesize677-early-off: no arbiter on=1
// early switch (4.5.675 keyboard-note trigger plus the nudge). Main queue only.
FOUNDATION_EXPORT BOOL DSPhoneSize677EarlyDisabled(void);
// /var/mobile/.dynamicstage-phonesize676-nudge-off: no relayout nudge.
FOUNDATION_EXPORT BOOL DSPhoneSize676NudgeDisabled(void);
// 4.5.678 phonesize678 files in /var/mobile: -width-off (A: back to the 676
// height nudge), -pregrow-off (B), -anchor-at-down (B: bottom-anchored at
// touch-down), -always (C, opt-in).
FOUNDATION_EXPORT BOOL DSPhoneSize678WidthDisabled(void);
// 4.5.679: /var/mobile/.dynamicstage-phonesize679-scale ("phone" or 0.80-1.00); default 1.0.
FOUNDATION_EXPORT CGFloat DSPhoneSize679Scale(BOOL *phoneMode);
FOUNDATION_EXPORT BOOL DSPhoneSize678PreGrowDisabled(void);
FOUNDATION_EXPORT BOOL DSPhoneSize678AnchorAtDown(void);
FOUNDATION_EXPORT BOOL DSPhoneSize678Always(void);
// 4.5.680: /var/mobile/.dynamicstage-phonesize680-off (exact 679), -noanim (instant).
FOUNDATION_EXPORT BOOL DSPhoneSize680Off(void);
FOUNDATION_EXPORT BOOL DSPhoneSize680NoAnim(void);
FOUNDATION_EXPORT BOOL DSPhoneSize680Enabled(void);
// 4.5.681: /var/mobile/.dynamicstage-phonesize681-tune (key=value, re-read every 2 s).
typedef NS_ENUM(NSInteger, DSPS681Curve) {
    DSPS681CurveKeyboard = 0,
    DSPS681CurveEaseInOut = 1,
    DSPS681CurveEaseOut = 2,
    DSPS681CurveLinear = 3,
    DSPS681CurveSpring = 4,
};
typedef struct {
    double duration;       // ms
    double delay;          // ms, from the keyboard signal
    NSInteger curve;
    double springDamping;  // damping ratio (curve=spring)
    double springVelocity; // initial velocity (curve=spring)
    BOOL targetFinal;      // aim straight at the predicted final bar position
    double offset;         // app pt, keyboard-up bar position correction
    double hideDuration;   // ms
    NSInteger hideCurve;
    BOOL showInstant;      // 4.5.682: show=instant (default) | animate
} DSPhoneSize681Tune;
FOUNDATION_EXPORT DSPhoneSize681Tune DSPhoneSize681CurrentTune(void);
// 4.5.683: /var/mobile/.dynamicstage-phonesize683-off (back to 682), -keephost (test).
FOUNDATION_EXPORT BOOL DSPhoneSize683Off(void);
FOUNDATION_EXPORT BOOL DSPhoneSize683KeepHost(void);
FOUNDATION_EXPORT BOOL DSPhoneSize683Enabled(void);
// 4.5.684: 683 is opt-in: /var/mobile/.dynamicstage-phonesize683-on.
FOUNDATION_EXPORT BOOL DSPhoneSize683On(void);
// 4.5.684 phonesize684: safe area = keyboard (the app's bar never moves).
// Off: /var/mobile/.dynamicstage-phonesize684-off (exact 4.5.682).
FOUNDATION_EXPORT BOOL DSPhoneSize684Off(void);
FOUNDATION_EXPORT BOOL DSPhoneSize684Enabled(void);
typedef struct {
    CGFloat bottom;  // bottom inset K override (0 = auto: learned, default 345)
    CGFloat top;     // top inset override (<0 = auto: the card's top edge)
    BOOL shortMode;  // mode=short: scene ends at the keyboard top, no bottom inset
} DSPhoneSize684Tune;
FOUNDATION_EXPORT DSPhoneSize684Tune DSPhoneSize684CurrentTune(void);
// 4.5.685/4.5.686 phonesize685: the 684 scene (bar line, insets bottom) kept;
// the card shows more of the app: app y view..(bar line + margin) at a smaller
// scale, top safe inset = view (the phone's own 59). Off:
// /var/mobile/.dynamicstage-phonesize685-off (back to 4.5.684).
FOUNDATION_EXPORT BOOL DSPhoneSize685Off(void);
FOUNDATION_EXPORT BOOL DSPhoneSize685Enabled(void);
typedef struct {
    CGFloat view;    // app y on the card's top edge (<0 = auto: the phone's top inset, 59)
    CGFloat margin;  // app pt shown below the bar line (default 14)
    CGFloat slack;   // <0 = off (default). >=0: first-685 experiment, scene ends slack pt below the bar
    CGFloat top;     // top inset override (<0 = auto: the app y on the card's top edge)
    CGFloat keyTop;  // keyboard-top / bar line override in scene y (<=0 = auto: learned, 586)
} DSPhoneSize685Tune;
FOUNDATION_EXPORT DSPhoneSize685Tune DSPhoneSize685CurrentTune(void);
// 4.5.687 phonesize687: 684's scene height and width-fill scale (x0.977), but the
// bar line is raised so the card shows app y 59..528: the bar rests at
// 528 - margin with a bottom inset of 931 - that (>= the keyboard height, so the
// bar never moves). Off: /var/mobile/.dynamicstage-phonesize687-off (back to 684).
// 686's picture (685 layer) is opt-in: /var/mobile/.dynamicstage-phonesize686-on.
FOUNDATION_EXPORT BOOL DSPhoneSize687Off(void);
FOUNDATION_EXPORT BOOL DSPhoneSize687Enabled(void);
typedef struct {
    CGFloat view;    // app y on the card's top edge (<0 = auto: the phone's top inset, 59)
    CGFloat margin;  // pt between the bar line and the card bottom (default 8)
    CGFloat top;     // top safe inset (<0 = auto: = view)
} DSPhoneSize687Tune;
FOUNDATION_EXPORT DSPhoneSize687Tune DSPhoneSize687CurrentTune(void);
// 4.5.688 phonesize688: 684's chat geometry kept (card bottom = keyboard top as the
// app sees it = resting bar); the main-screen top bar is brought onto the card by
// one of four modes (/var/mobile/.dynamicstage-phonesize688-tune mode=...):
//   684 (default since 4.5.689): exact 4.5.684.
//   statusbar (opt-in; 4.5.688's default, suspected of the safe-mode crash): 684 scene +
//             the scene's default status bar height raised to the top inset (118),
//             fenced (main thread, signature check, crash latch).
//   offset:   scene frame {0, o, 430, 931 - o} (o = 60): keyboard top in the window
//             = 586 - o = the resting bar; card shows window 57..526.
//   short:    scene {0, 0, 430, 931 - o}: same, for an app that puts the keyboard at
//             its scene bottom (height - keyboard height).
// Off: /var/mobile/.dynamicstage-phonesize688-off or -689-off (exact 684 = the default). 687 is opt-in
// (/var/mobile/.dynamicstage-phonesize687-on).
typedef NS_ENUM(NSInteger, DSPhoneSize688Mode) {
    DSPhoneSize688ModeStatusBar = 0,
    DSPhoneSize688ModeOffset = 1,
    DSPhoneSize688ModeShort = 2,
    DSPhoneSize688Mode684 = 3,
};
FOUNDATION_EXPORT BOOL DSPhoneSize688Off(void);
FOUNDATION_EXPORT BOOL DSPhoneSize688Enabled(void);
typedef struct {
    NSInteger mode;      // DSPhoneSize688Mode
    CGFloat view;        // offset/short: window y on the card top (<0 = auto 57)
    CGFloat offset;      // offset/short: o (<0 = auto from card size and view)
    CGFloat shift;       // offset: picture shift in the host (<-500 = auto, measured)
    CGFloat statusBar;   // statusbar: height (<0 = auto = the 684 top inset)
} DSPhoneSize688Tune;
FOUNDATION_EXPORT DSPhoneSize688Tune DSPhoneSize688CurrentTune(void);
// /var/mobile/.dynamicstage-phonesize676-hold-on: hold a snapshot of the card
// over the switch (default off).
FOUNDATION_EXPORT BOOL DSPhoneSize676HoldEnabled(void);

// 4.5.696: fix 0 blackout, 1 keys, 2 fit. Off file / crash latch per fix.
FOUNDATION_EXPORT BOOL DSPS696Enabled(NSInteger fix);
FOUNDATION_EXPORT void DSPS696MarkTrying(NSInteger fix);
FOUNDATION_EXPORT BOOL DSPS696DeviceLocked(void);

// 4.5.719 bg719: the user put an app on a card (first-use gate).
FOUNDATION_EXTERN void DSBg719NoteUserStaged(void);
FOUNDATION_EXPORT void DSClose741Note(NSString *bundle);
FOUNDATION_EXPORT BOOL DSClose741Recent(NSString *sceneIdentifier);

// 4.5.770 gest770: log-only gesture / switcher / restore evidence.
// Off: gest770-off, master core770-off (crash latch gest770).
FOUNDATION_EXPORT BOOL DSGest770On(void);
FOUNDATION_EXPORT NSString *DSGest770SceneState(id controller, id scene);
FOUNDATION_EXPORT void DSGest770MarkRestored(NSString *bundle);
FOUNDATION_EXPORT void DSGest770FirstAfterRestore(id controller, id handle, NSString *what);
FOUNDATION_EXPORT void DSGest770NoteEdgePull(UIPanGestureRecognizer *gesture, BOOL adopted);
FOUNDATION_EXPORT void DSGest770NoteSuppressed(CGPoint point, NSString *who);
@interface DSSceneHost (Gest770)
- (NSString *)gest770State;
@end
