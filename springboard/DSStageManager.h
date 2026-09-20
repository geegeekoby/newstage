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

// SpringBoard's own keyboard window, the one that spans the display, came or went.
- (void)keyboardWindowOutsideStage:(UIWindow *)window hidden:(BOOL)hidden;

// How tall a keyboard the app on the stage has raised inside its own window, as
// reported by the app itself. Zero when it has put one away.
- (void)stagedAppKeyboardHeightChanged:(CGFloat)height;
- (void)closeStageAnimated:(BOOL)animated;
- (void)rotateStageBy:(NSInteger)quarterTurns;

@end
