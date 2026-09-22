#import <UIKit/UIKit.h>
#import "DSConstants.h"

// Owns everything on the SpringBoard side: the stage window, the corner pull
// gesture, the hosted app's scene, Split View geometry and the auto-kill timer.
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

- (void)activate;
- (void)preferencesChanged;

- (BOOL)canActivateStage;
// Consulted by the home gesture suppression hook.
- (BOOL)shouldSuppressSystemGestureAtPoint:(CGPoint)point;
// True while the system home affordance has to stay out of the way.
- (BOOL)shouldHideSystemHomeAffordance;

- (void)noteSceneDestroyedForBundleIdentifier:(NSString *)bundleIdentifier;
- (void)noteFrontApplicationWillChange;
- (void)noteDisplayDidTurnOff;

- (void)showIntroIfNeeded;
// Opens the stage as though the corner had been pulled all the way up.
- (void)openStageAnimated:(BOOL)animated;

// A keyboard has gone up, moved or come down anywhere on the device, as reported by
// the keyboard arbiter running in this process. The frame is in display points and
// `source` is the bundle identifier of whoever raised it, which may be the app on the
// stage, the app sharing the screen with it or SpringBoard itself. The stage does one
// thing with it: keeps the card off it.
- (void)keyboardOnScreen:(BOOL)onScreen frame:(CGRect)frame source:(NSString *)source;
// Live keyboard diagnosis, shown on the stage. `springBoardLine` is what the
// arbiter did. `appLine` is what the hosted app reported.
- (void)noteKeyboardDebugFromApp:(NSString *)line;
- (void)noteKeyboardDebugFromSpringBoard:(NSString *)line;
- (void)noteStagedKeyResult:(NSString *)line;
- (void)noteAppDylibSignal:(uint32_t)hash listening:(BOOL)listening loaded:(BOOL)loaded remote:(BOOL)remote;
- (BOOL)hostedAppHasStageDylib:(NSString *)bundle;
- (BOOL)hostedAppReportedRemoteKeyboard:(NSString *)bundle;
// True while a picker search field is editing. The arbiter must not retarget
// that keyboard to a staged app.
- (BOOL)isPickerSearchActive;
// Letters from SpringBoard's keyboard, written through to the staged app.
// Search keeps its own field. This does not move the caret.
- (BOOL)shouldForwardHostedKeyboardText;
- (void)forwardHostedKeyboardText:(NSString *)text;
- (void)forwardHostedKeyboardDelete;
- (NSString *)bundleForKeyboardHash:(uint32_t)hash;
// True when either stage card is currently hosting this bundle.
- (BOOL)isHostingBundleIdentifier:(NSString *)bundleIdentifier;
// True when this scene identifier belongs to an app on the stage.
- (BOOL)isHostingSceneIdentifier:(NSString *)identifier;
- (void)closeStageAnimated:(BOOL)animated;
- (void)rotateStageBy:(NSInteger)quarterTurns;

@end
