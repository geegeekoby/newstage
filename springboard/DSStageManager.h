#import <UIKit/UIKit.h>
#import "DSConstants.h"

// Owns everything on the SpringBoard side: the stage window, the corner pull
// gesture, the hosted app's scene, Split View geometry and the auto-kill timer.
@interface DSStageManager : NSObject

+ (instancetype)sharedManager;

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
- (void)closeStageAnimated:(BOOL)animated;
- (void)rotateStageBy:(NSInteger)quarterTurns;

@end
