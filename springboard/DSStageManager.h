#import <UIKit/UIKit.h>
#import "DSConstants.h"

// Owns everything on the SpringBoard side: the stage window, the corner pull
// gesture, the hosted app's scene, and the auto-kill timer.
// 4.5.683 (DSStageManager.m)
FOUNDATION_EXPORT void DSPhoneSize683ConsiderContextHost(UIView *view);
FOUNDATION_EXPORT BOOL DSPhoneSize683HidesKeyCopies(void);
FOUNDATION_EXPORT void DSPhoneSize683RestoreKeyCopies(NSString *why);

@interface DSStageManager : NSObject

+ (instancetype)sharedManager;

// Set once at load time, from whether SpringBoard on this build still reports its
// bottom edge pulls in a shape the tweak can take over.
+ (void)setSystemEdgePullAvailable:(BOOL)available;
// Called from the edge pull hook with SpringBoard's own recogniser. Returns YES
// when the stage has taken the drag over and the switcher must not see it.
- (BOOL)adoptSystemEdgePull:(UIPanGestureRecognizer *)gesture;

@property (nonatomic, readonly) DSStageState state;
@property (nonatomic, readonly, copy) NSString *stageBundleIdentifier;
// True whenever the stage owns the bottom half of the display.
@property (nonatomic, readonly) BOOL isStageVisible;
// Two cards, one above the other. The stray full-screen Messages presentation
// is only hidden in this state.
@property (nonatomic, readonly) BOOL isSplitMode;

- (void)activate;
- (void)preferencesChanged;

// Consulted by the home gesture suppression hook.
- (BOOL)shouldSuppressSystemGestureAtPoint:(CGPoint)point;
- (BOOL)shouldSuppressSystemGestureAtPoint:(CGPoint)point velocity:(CGPoint)velocity;
// True while the system home affordance has to stay out of the way.
- (BOOL)shouldHideSystemHomeAffordance;
// The system status bar stays hidden while a stage is on the top half.
// A tap on that strip shows it briefly.
- (BOOL)shouldHideSystemStatusBar;
- (void)peekSystemStatusBar;
// Card, rim, and hosted view, in screen points. Copied by the picker.
- (NSString *)stageGeometryDebugSummary;

- (void)noteSceneDestroyedForBundleIdentifier:(NSString *)bundleIdentifier;
// The system home swipe. A visible card keeps a still of itself so the scene
// update does not turn it black. A minimized card stays minimized and backgrounded.
- (void)noteHomeGestureBegan:(UIPanGestureRecognizer *)gesture;
// A phone call backgrounds the hosted scene, which paints the card black.
// Cover the live view before that update, and take the cover off when it returns.
- (void)noteHostedSceneIdentifier:(NSString *)identifier covered:(BOOL)covered;
// Another app opening tries to stretch the staged scene to the whole phone.
// Put the live card back inside its frame without backgrounding it.
- (void)keepOnScreenStageInsideCardForSceneIdentifier:(NSString *)identifier;
- (void)noteDisplayDidTurnOff;
- (void)lock808NoteBacklight:(long long)state source:(long long)source;

- (void)showIntroIfNeeded;
// Opens the stage as though the corner had been pulled all the way up.
- (void)openStageAnimated:(BOOL)animated;

// A keyboard has gone up, moved or come down anywhere on the device, as reported by
// the keyboard arbiter running in this process. The frame is in display points and
// `source` is the bundle identifier of whoever raised it, which may be the app on the
// stage, the app sharing the screen with it or SpringBoard itself. The stage does one
// thing with it: keeps the card off it.
- (void)keyboardOnScreen:(BOOL)onScreen frame:(CGRect)frame source:(NSString *)source;
// Spotlight and other background keyboards must not dismiss staged typing keys.
- (BOOL)shouldRestoreKeyboardPlacementAfterDismiss:(NSString *)source;
- (BOOL)shouldIgnoreForeignKeyboardEventFrom:(NSString *)source onScreen:(BOOL)onScreen;
// Live keyboard diagnosis, shown on the stage. `springBoardLine` is what the
// arbiter did. `appLine` is what the hosted app reported.
- (void)noteKeyboardDebugFromApp:(NSString *)line;
- (void)noteStagedKeyResult:(NSString *)line;
- (void)noteAppDylibSignal:(uint32_t)hash listening:(BOOL)listening loaded:(BOOL)loaded remote:(BOOL)remote;
- (BOOL)hostedAppHasStageDylib:(NSString *)bundle;
- (BOOL)hostedAppReportedRemoteKeyboard:(NSString *)bundle;
// True while a picker search field is editing. The arbiter must not retarget
// that keyboard to a staged app.
- (BOOL)isPickerSearchActive;
// The offscreen stand-in is the editor. While this is true, UIKit must not
// park that keyboard's host just off the bottom of the phone.
- (BOOL)stagedKeyboardFieldIsEditing;
// The staged app is still the one the keys belong to, including while a call
// tries to report the keyboard down.
- (BOOL)stagedTypingSessionActive;
- (void)keepStagedKeyboardField;
// Letters from SpringBoard's keyboard, written through to the staged app.
// Search keeps its own field. This does not move the caret.
- (BOOL)shouldForwardHostedKeyboardText;
- (void)forwardHostedKeyboardText:(NSString *)text;
- (void)forwardHostedKeyboardDelete;
- (NSString *)bundleForKeyboardHash:(uint32_t)hash;
// True when either stage card is currently hosting this bundle.
- (BOOL)isHostingBundleIdentifier:(NSString *)bundleIdentifier;
// 4.5.650: screen rect of the visible, unparked card hosting this bundle
// (CGRectNull when there is none). Used to show the call screen in the card.
- (CGRect)stageCardScreenFrameForBundleIdentifier:(NSString *)bundleIdentifier cornerRadius:(CGFloat *)radius;
// 4.5.668 sbcam668.
- (void)setCameraTall:(BOOL)tall forBundleIdentifier:(NSString *)bundleIdentifier why:(NSString *)why;
- (BOOL)cameraTallForBundleIdentifier:(NSString *)bundleIdentifier;
- (NSArray<NSString *> *)cameraTallBundleIdentifiers;
- (BOOL)stagedKeyboardIsUp;
// Beeper's first keyboard, bottom-aligned. A taller proposed rect is the
// quick bar growing. Any other rect is returned unchanged.
- (CGRect)pinnedBeeperKeyboardFrameForProposed:(CGRect)proposed;
// 4.5.652: bundles hosted on a card right now (primary, top, floating).
- (NSArray<NSString *> *)hostedBundleIdentifiers;
// 4.5.658: camera log helpers. Which card hosts the bundle (primary, top,
// float, parked) plus the host's own state line; and the hosted pid.
- (NSString *)cameraStateSummaryForBundleIdentifier:(NSString *)bundleIdentifier;
- (pid_t)hostedProcessIdentifierForBundleIdentifier:(NSString *)bundleIdentifier;
// True when this scene identifier belongs to an app on the stage.
- (BOOL)isHostingSceneIdentifier:(NSString *)identifier;
// 4.5.674 keys674: the staged app whose scene this is (nil if none), and
// whether the DynamicStage app dylib runs in it.
- (NSString *)keys674HostedBundleForSceneIdentifier:(NSString *)identifier;
- (BOOL)keys671AppHasDylib:(NSString *)bundle;
// 4.5.676 phonesize676: an early SpringBoard-side sign that a staged app is
// bringing its keyboard up ("arbiter on=1", or "focus" from the arbiter's
// focus request). height is the arbiter's keyboard height (0 if unknown);
// mediaTime is when the signal was seen (CACurrentMediaTime).
- (void)phoneSize676EarlySignal:(NSString *)signal bundle:(NSString *)bundle height:(CGFloat)height at:(double)mediaTime;
// 4.5.678 phonesize678 C (opt-in -always file): the card is hosting the app.
- (void)phoneSize678HostReady:(id)host;
// 4.5.680 phonesize680 (main queue): arbiter on=1 / on=0 for an app; YES when handled.
- (BOOL)phoneSize680KeyboardSignal:(NSString *)signal bundle:(NSString *)bundle on:(BOOL)on height:(CGFloat)height at:(double)mediaTime;
- (void)phoneSize680KeyboardLayerAskedFor:(NSString *)bundle at:(double)mediaTime;
// 4.5.683: the app's own keyboard is shown inside its card.
- (BOOL)phoneSize683ActiveForBundle:(NSString *)bundle;
// 4.5.684: safe area = keyboard, the card's window is fixed.
- (BOOL)phoneSize684ActiveForBundle:(NSString *)bundle;
- (void)closeStageAnimated:(BOOL)animated;
- (void)rotateStageBy:(NSInteger)quarterTurns;

// 4.5.657: the user is using the stage (opened it, pulled a card out, picked an
// app, touched a card). Runs the work that was kept out of the app switcher:
// stage apps killed from the switcher, recent-app bookkeeping, and clears the
// "system has the screen" state.
- (void)noteStageUse;

- (void)fast743KeysHiding:(NSString *)why;
- (void)postMessagesKeyboardShown:(BOOL)shown;
@end

// ---- 4.5.657: ivar-level answers for SpringBoard hooks ------------------------
// No locks, no syscalls, no stage manager methods. Hooks that run for every
// switcher card (home pill, status bar, gesture, scene views) return on these.
// YES when an unparked stage card (or a corner pull) is on screen right now,
// the stage is not stepped aside for a call and no home gesture is running.
FOUNDATION_EXPORT BOOL DSStageCardOnScreenFast(void);
// Same answer as -isStageVisible (state Overlay or Tracking).
FOUNDATION_EXPORT BOOL DSStageVisibleFast(void);
// The stage could claim a system gesture (stage visible or a card drag).
FOUNDATION_EXPORT BOOL DSStageGestureRelevantFast(void);
// 4.5.670: a card drag in progress or ended less than `window` seconds ago.
FOUNDATION_EXPORT BOOL DSStageDragSettlingFast(double window);
// 4.5.706 drag706: a corner pull / restore in progress or ended less than `window` s ago.
FOUNDATION_EXPORT BOOL DSStageRestoreSettlingFast(double window);
// The stage holds any app (primary, top, floating or stashed host object).
FOUNDATION_EXPORT BOOL DSStageHasSceneHostFast(void);
FOUNDATION_EXPORT BOOL DSStage742MessagesStaged(void);
// A card is parked in a corner (the only case a corner pull is adopted).
FOUNDATION_EXPORT BOOL DSStageHasParkedCardFast(void);
// An app was killed (switcher flick, crash). Data only; returns at once for an
// app the stage does not hold. The stage handles it on its next use.
FOUNDATION_EXPORT void DSStageNoteBundleKilled(NSString *bundleIdentifier);
// SpringBoard's front display changed. Recorded for the picker's recents and
// applied on the next stage use.
FOUNDATION_EXPORT void DSStageNoteFrontDisplayChanged(id display);

