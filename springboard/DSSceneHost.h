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

- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier;

// Launches (suspended) if needed and calls back once a hostable scene exists.
- (void)prepareWithCompletion:(DSSceneHostReadyBlock)completion;

// Frame in screen coordinates that the app should believe it occupies.
- (void)setStageFrame:(CGRect)frame safeAreaInsets:(UIEdgeInsets)insets;
- (void)setForeground:(BOOL)foreground;

// Hands the scene back to SpringBoard. `background` keeps the process alive so
// notifications keep flowing; otherwise it is left suspended as usual.
- (void)relinquishKeepingBackgrounded:(BOOL)background;
- (void)terminate;
- (BOOL)isProcessAlive;

// Called by the FBScene hook so SpringBoard's own layout passes cannot undo the
// stage geometry.
+ (BOOL)applyOverridesToSettings:(FBSMutableSceneSettings *)settings forScene:(FBScene *)scene;

// Every scene that passes through the settings hooks is remembered, so an app's
// scene can still be found on a build where none of the usual ways to ask for it
// exist any more.
+ (void)noteLiveScene:(FBScene *)scene;
+ (FBScene *)liveSceneForBundleIdentifier:(NSString *)bundleIdentifier;

// Geometry-only override, used for the app that keeps the top half in Split
// View: SpringBoard still hosts and animates it, the stage only dictates size.
+ (void)registerGeometryOverrideForScene:(FBScene *)scene frame:(CGRect)frame insets:(UIEdgeInsets)insets;
+ (void)removeGeometryOverrideForScene:(FBScene *)scene restoringFrame:(CGRect)frame insets:(UIEdgeInsets)insets;

@end
