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
- (void)setStageFrame:(CGRect)frame safeAreaInsets:(UIEdgeInsets)insets;
- (void)setForeground:(BOOL)foreground;

// Hands the scene back to SpringBoard. `background` keeps the process alive so
// notifications keep flowing; otherwise it is left suspended as usual.
- (void)relinquishKeepingBackgrounded:(BOOL)background;
- (void)terminate;
- (BOOL)isProcessAlive;

// The scene now showing on the stage, whichever way it was come by.
- (FBScene *)hostedScene;

// Called once the host view is in the card, so SpringBoard's app view learns it has
// finished moving in.
- (void)noteHostViewAttached;

// Called by the FBScene hook so SpringBoard's own layout passes cannot undo the
// stage geometry.
+ (BOOL)applyOverridesToSettings:(FBSMutableSceneSettings *)settings forScene:(FBScene *)scene;

// An app view controller of the stage's own making is not part of SpringBoard's
// scene layout, so settings churn makes it assert; the hook that contains that has
// to know which ones are the stage's.
+ (BOOL)ownsAppViewController:(id)controller;

// SpringBoard's scene manager for the built-in display. It owns where a hosted
// app's keyboard goes, among other things.
+ (id)mainDisplaySceneManager;

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
