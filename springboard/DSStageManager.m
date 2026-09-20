#import "DSStageManager.h"
#import "DSStageWindow.h"
#import "DSStageContainerView.h"
#import "DSAppPickerViewController.h"
#import "DSAppLibrary.h"
#import "DSGestureController.h"
#import "DSSceneHost.h"
#import "DSPreferences.h"
#import "DSPrivate.h"
#import "DSIntroViewController.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>

// Fraction of the screen height the finger has to travel for the pull to reach
// the stage's resting size; a little further than that commits to Split View.
static const CGFloat kDSPullTravelRatio = 0.42;
static const CGFloat kDSCancelProgress = 0.14;
static const CGFloat kDSSplitProgress = 0.82;
static const CGFloat kDSFlickVelocity = -1150.0;

#pragma mark - Launch placeholder

// While the app boots, the stage shows its launch storyboard if it has one and
// falls back to its icon on a flat background, which is what the stock tweak's
// own walkthrough clip shows.
@interface DSLaunchPlaceholderView : UIView
- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier icon:(UIImage *)icon dark:(BOOL)dark;
@end

@implementation DSLaunchPlaceholderView {
    UIView *_storyboardView;
    UIImageView *_iconView;
}

- (instancetype)initWithBundleIdentifier:(NSString *)bundleIdentifier icon:(UIImage *)icon dark:(BOOL)dark {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.backgroundColor = dark ? UIColor.blackColor : UIColor.whiteColor;
        self.clipsToBounds = YES;
        _storyboardView = [self launchViewForBundleIdentifier:bundleIdentifier];
        if (_storyboardView) {
            [self addSubview:_storyboardView];
        } else {
            _iconView = [[UIImageView alloc] initWithImage:icon];
            _iconView.contentMode = UIViewContentModeScaleAspectFit;
            _iconView.layer.cornerRadius = 18.0;
            _iconView.layer.cornerCurve = kCACornerCurveContinuous;
            _iconView.clipsToBounds = YES;
            [self addSubview:_iconView];
        }
    }
    return self;
}

- (UIView *)launchViewForBundleIdentifier:(NSString *)bundleIdentifier {
    Class controllerClass = objc_getClass("SBApplicationController");
    SBApplication *application = [[controllerClass sharedInstance] applicationWithBundleIdentifier:bundleIdentifier];
    if (![application respondsToSelector:@selector(launchInterfaceFileName)]) return nil;

    @try {
        NSString *name = ((NSString * (*)(id, SEL))objc_msgSend)(application, @selector(launchInterfaceFileName));
        if (name.length == 0) return nil;
        NSURL *bundleURL = application.info.bundleURL ?: nil;
        NSBundle *bundle = bundleURL ? [NSBundle bundleWithURL:bundleURL] : nil;
        if (!bundle) return nil;
        UIStoryboard *storyboard = [UIStoryboard storyboardWithName:name bundle:bundle];
        UIViewController *controller = [storyboard instantiateInitialViewController];
        UIView *view = controller.view;
        view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        return view;
    } @catch (NSException *exception) {
        return nil;
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _storyboardView.frame = self.bounds;
    CGFloat side = 76.0;
    _iconView.frame = CGRectMake((CGRectGetWidth(self.bounds) - side) / 2.0,
                                 (CGRectGetHeight(self.bounds) - side) / 2.0,
                                 side, side);
}

@end

#pragma mark - Stage manager

@interface DSStageManager () <DSGestureControllerDelegate, DSAppPickerDelegate>
@end

@implementation DSStageManager {
    DSStageWindow *_window;
    DSStageContainerView *_container;
    DSAppPickerViewController *_picker;
    DSGestureController *_gesture;
    DSSceneHost *_sceneHost;

    UIView *_hostSnapshot;
    UIView *_hostBackdrop;
    UIView *_splitCornerMask;
    UIImageView *_openAppIcon;
    DSLaunchPlaceholderView *_launchPlaceholder;

    NSString *_splitHostBundleIdentifier;
    NSTimer *_autoKillTimer;
    NSInteger _stageQuarterTurns;

    DSStageState _stateBeforeTracking;
    CGFloat _trackingProgress;
    BOOL _trackingPassedSplit;
    BOOL _activated;

    UIPanGestureRecognizer *_dragPan;
    UIImpactFeedbackGenerator *_feedback;
}

+ (instancetype)sharedManager {
    static DSStageManager *shared;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        shared = [[DSStageManager alloc] init];
    });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _state = DSStageStateClosed;
    }
    return self;
}

#pragma mark - Lifecycle

- (void)activate {
    if (_activated) return;
    _activated = YES;

    [[DSPreferences sharedPreferences] startObserving];
    _feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [self buildWindow];

    _gesture = [[DSGestureController alloc] init];
    _gesture.delegate = self;
    [_gesture install];
}

- (void)buildWindow {
    _window = [DSStageWindow stageWindow];
    __weak __typeof(self) weakSelf = self;
    _window.touchTest = ^BOOL(CGPoint point) {
        return [weakSelf shouldWindowCaptureTouchAtPoint:point];
    };

    UIView *root = _window.rootViewController.view;

    _container = [[DSStageContainerView alloc] initWithFrame:[self stageFrameForState:DSStageStateClosed]];
    _container.cornerRadius = [self cornerRadiusForState:DSStageStateOverlay];
    [root addSubview:_container];

    _picker = [[DSAppPickerViewController alloc] init];
    _picker.delegate = self;
    [_window.rootViewController addChildViewController:_picker];
    _picker.view.frame = _container.contentView.bounds;
    _picker.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_container.contentView addSubview:_picker.view];
    [_picker didMoveToParentViewController:_window.rootViewController];

    _openAppIcon = [[UIImageView alloc] initWithFrame:CGRectZero];
    _openAppIcon.contentMode = UIViewContentModeScaleAspectFit;
    _openAppIcon.layer.cornerRadius = 6.0;
    _openAppIcon.layer.cornerCurve = kCACornerCurveContinuous;
    _openAppIcon.clipsToBounds = YES;
    _openAppIcon.alpha = 0.0;
    [root addSubview:_openAppIcon];

    _dragPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleStagePan:)];
    _dragPan.cancelsTouchesInView = NO;
    _dragPan.delaysTouchesBegan = NO;
    [_container addGestureRecognizer:_dragPan];

    [self applyAppearance];
}

- (void)preferencesChanged {
    [_gesture reloadPreferences];
    [self applyAppearance];
    [_picker reloadContent];
    if (![DSPreferences sharedPreferences].enabled && self.isStageVisible) {
        [self closeStageAnimated:YES];
        return;
    }
    if (_sceneHost.isHosting) [self layoutStageForState:_state];
}

- (void)applyAppearance {
    BOOL dark = YES;
    switch ([DSPreferences sharedPreferences].appearance) {
        case DSAppearanceLight: dark = NO; break;
        case DSAppearanceDark: dark = YES; break;
        case DSAppearanceAuto:
        default:
            if (@available(iOS 13.0, *)) {
                dark = UIScreen.mainScreen.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
            }
            break;
    }
    _container.darkMode = dark;
    _picker.darkMode = dark;
}

#pragma mark - Geometry

- (CGRect)screenBounds {
    return UIScreen.mainScreen.bounds;
}

- (CGFloat)displayCornerRadius {
    UIScreen *screen = UIScreen.mainScreen;
    if ([screen respondsToSelector:@selector(_displayCornerRadius)]) {
        CGFloat radius = [screen _displayCornerRadius];
        if (radius > 1.0) return radius;
    }
    return kDSFallbackDisplayCornerRadius;
}

- (CGFloat)splitLine {
    return floor(CGRectGetHeight([self screenBounds]) * kDSSplitRatio);
}

// The stage owns the bottom half of the display in both states. Floating over an
// app it is a card inset on three sides; sharing the screen it goes edge to edge
// and only the gap above it survives.
- (CGRect)stageFrameForState:(DSStageState)state {
    CGRect bounds = [self screenBounds];
    CGFloat screenHeight = CGRectGetHeight(bounds);
    CGFloat screenWidth = CGRectGetWidth(bounds);
    CGFloat top = [self splitLine] + kDSStageInset;

    switch (state) {
        case DSStageStateSplit:
            return CGRectMake(0, top, screenWidth, screenHeight - top);
        case DSStageStateOverlay:
            return CGRectMake(kDSStageInset, top,
                              screenWidth - kDSStageInset * 2.0,
                              screenHeight - top - kDSStageInset);
        default:
            // Parked just below the bottom edge, at the size it will come up as.
            return CGRectMake(kDSStageInset, screenHeight,
                              screenWidth - kDSStageInset * 2.0,
                              screenHeight - top - kDSStageInset);
    }
}

- (CGFloat)cornerRadiusForState:(DSStageState)state {
    CGFloat display = [self displayCornerRadius];
    // Inset on both sides, the card's corners stay concentric with the display's.
    return state == DSStageStateSplit ? display : display - kDSStageInset;
}

- (CGRect)hostFrameForSplit {
    CGRect bounds = [self screenBounds];
    return CGRectMake(0, 0, CGRectGetWidth(bounds), [self splitLine]);
}

- (UIEdgeInsets)stageSafeAreaInsets {
    // The stock tweak hands the app a zero inset rectangle and lets the rounded
    // bottom corners clip it, which is what the recordings show.
    return UIEdgeInsetsZero;
}

- (UIEdgeInsets)screenSafeAreaInsets {
    UIEdgeInsets insets = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) {
        insets = UIApplication.sharedApplication.windows.firstObject.safeAreaInsets;
    }
    return insets;
}

- (BOOL)hasHostedApp {
    return _sceneHost != nil;
}

- (NSString *)stageBundleIdentifier {
    return _sceneHost.bundleIdentifier;
}

- (BOOL)isStageVisible {
    return _state == DSStageStateOverlay || _state == DSStageStateSplit || _state == DSStageStateTracking;
}

- (BOOL)shouldHideSystemHomeAffordance {
    // Only while a live app owns the stage: with the picker up the recordings
    // still show the system home bar.
    return self.hasHostedApp && (_state == DSStageStateOverlay || _state == DSStageStateSplit);
}

#pragma mark - Animation

- (void)animateSpring:(void (^)(void))animations completion:(void (^)(void))completion {
    if (!animations) {
        if (completion) completion();
        return;
    }
    CGFloat stiffness = pow(2.0 * M_PI / kDSSpringResponse, 2.0);
    CGFloat damping = 4.0 * M_PI * kDSSpringDamping / kDSSpringResponse;
    UISpringTimingParameters *timing = [[UISpringTimingParameters alloc] initWithMass:1.0
                                                                            stiffness:stiffness
                                                                              damping:damping
                                                                      initialVelocity:CGVectorMake(0, 0)];
    UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:0.0 timingParameters:timing];
    [animator addAnimations:animations];
    if (completion) {
        [animator addCompletion:^(UIViewAnimatingPosition position) {
            completion();
        }];
    }
    [animator startAnimation];
}

#pragma mark - Activation rules

- (BOOL)canActivateStage {
    DSPreferences *preferences = [DSPreferences sharedPreferences];
    if (!preferences.enabled) return NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:kDSKillSwitchPath]) return NO;
    if ([DSIntroViewController isPresenting]) return NO;

    Class lockScreenClass = objc_getClass("SBLockScreenManager");
    if (lockScreenClass) {
        SBLockScreenManager *manager = [lockScreenClass sharedInstance];
        if ([manager respondsToSelector:@selector(isUILocked)] && manager.isUILocked) return NO;
    }

    // Portrait only, matching the stock tweak's documented limitation.
    if ([self activeOrientation] != UIInterfaceOrientationPortrait) return NO;

    SBApplication *front = [self frontApplication];
    if (!front && preferences.disableOnHomeScreen) return NO;
    if (front && [preferences isApplicationDisabled:front.bundleIdentifier]) return NO;

    return YES;
}

- (UIInterfaceOrientation)activeOrientation {
    SpringBoard *springBoard = (SpringBoard *)UIApplication.sharedApplication;
    if ([springBoard respondsToSelector:@selector(activeInterfaceOrientation)]) {
        return [springBoard activeInterfaceOrientation];
    }
    return UIInterfaceOrientationPortrait;
}

- (SBApplication *)frontApplication {
    SpringBoard *springBoard = (SpringBoard *)UIApplication.sharedApplication;
    if (![springBoard respondsToSelector:@selector(_accessibilityFrontMostApplication)]) return nil;
    return [springBoard _accessibilityFrontMostApplication];
}

- (BOOL)shouldSuppressSystemGestureAtPoint:(CGPoint)point {
    if (self.isStageVisible) return YES;
    if (![DSGestureController isPointInTriggerRect:point]) return NO;
    return [self canActivateStage] || _state == DSStageStateMinimized;
}

- (BOOL)shouldWindowCaptureTouchAtPoint:(CGPoint)point {
    if (_state == DSStageStateClosed || _state == DSStageStateMinimized) return NO;
    return CGRectContainsPoint(_container.frame, point);
}

#pragma mark - Corner pull

- (BOOL)gestureControllerShouldBegin:(DSGestureController *)controller atPoint:(CGPoint)point {
    if (_state == DSStageStateOverlay || _state == DSStageStateSplit) return NO;
    if (_state == DSStageStateMinimized) return YES;
    return [self canActivateStage];
}

- (void)gestureControllerDidBegin:(DSGestureController *)controller {
    _stateBeforeTracking = _state;
    _trackingPassedSplit = NO;
    _trackingProgress = 0.0;
    _state = DSStageStateTracking;

    [_feedback prepare];
    if (!self.hasHostedApp) [_picker resetScrollPosition];
    _container.frame = [self peekFrameForProgress:0.0];
    _container.cornerRadius = kDSPeekCornerRadius;
    _container.alpha = 1.0;
    _window.hidden = NO;

    // The app behind starts shrinking from the first millimetre of the drag, so
    // the still it is swapped for has to exist before the first update.
    [self prepareHostSnapshot];
    if (self.hasHostedApp) [_sceneHost setForeground:YES];
}

- (void)gestureController:(DSGestureController *)controller didUpdateTranslation:(CGPoint)translation {
    CGFloat travel = CGRectGetHeight([self screenBounds]) * kDSPullTravelRatio;
    CGFloat progress = MIN(MAX(-translation.y / travel, 0.0), 1.2);
    _trackingProgress = progress;

    _container.frame = [self peekFrameForProgress:progress];
    [self updateCornerRadiusForProgress:progress];

    BOOL passedSplit = progress >= kDSSplitProgress;
    if (passedSplit != _trackingPassedSplit) {
        _trackingPassedSplit = passedSplit;
        // Past this point releasing lands in Split View rather than overlay, so
        // the hand gets told about it.
        if (passedSplit) [_feedback impactOccurred];
    }
    [self updateHostSnapshotForProgress:progress];
}

- (void)gestureController:(DSGestureController *)controller didEndWithTranslation:(CGPoint)translation velocity:(CGPoint)velocity {
    CGFloat progress = _trackingProgress;
    BOOL flickedUp = velocity.y <= kDSFlickVelocity;

    if (progress < kDSCancelProgress && !flickedUp) {
        [self cancelTracking];
        return;
    }
    if (progress >= kDSSplitProgress) {
        [self enterStateSplitAnimated:YES];
    } else {
        [self enterStateOverlayAnimated:YES];
    }
}

- (void)gestureControllerDidCancel:(DSGestureController *)controller {
    [self cancelTracking];
}

- (void)cancelTracking {
    DSStageState previous = _stateBeforeTracking;
    [self animateSpring:^{
        [self animateHostSnapshotToFullScreen];
        self->_container.frame = [self stageFrameForState:DSStageStateClosed];
        self->_container.cornerRadius = [self cornerRadiusForState:DSStageStateOverlay];
    } completion:^{
        [self discardHostSnapshotAnimated:YES];
        self->_state = previous == DSStageStateMinimized ? DSStageStateMinimized : DSStageStateClosed;
        if (self->_state == DSStageStateMinimized) {
            [self updateOpenAppIcon];
            [self->_sceneHost setForeground:NO];
        } else {
            self->_window.hidden = YES;
        }
    }];
}

// The card lifts out of the corner, grows towards the middle of the screen and
// then morphs into the resting stage rectangle.
- (CGRect)peekFrameForProgress:(CGFloat)progress {
    CGRect bounds = [self screenBounds];
    CGRect target = [self stageFrameForState:DSStageStateOverlay];

    CGFloat phase = MIN(progress / kDSSplitProgress, 1.0);
    CGFloat eased = 1.0 - pow(1.0 - phase, 2.4);

    // Traced from the recordings: about 110x105 as it clears the corner, growing
    // to roughly 155x130 by the time the finger is halfway up.
    CGFloat width = kDSPeekWidth * (0.69 + 0.31 * eased);
    CGFloat height = kDSPeekHeight * (0.69 + 0.31 * eased);
    CGFloat travel = CGRectGetHeight(bounds) * kDSPullTravelRatio;

    CGFloat cornerCenterX = CGRectGetWidth(bounds) - kDSTriggerWidth / 2.0;
    CGFloat centerX = cornerCenterX + (CGRectGetWidth(bounds) / 2.0 - cornerCenterX) * eased;
    CGFloat centerY = CGRectGetHeight(bounds) + height / 2.0 - travel * progress;

    CGRect peek = CGRectMake(centerX - width / 2.0, centerY - height / 2.0, width, height);

    // Blend into the resting rectangle over the last stretch of the pull.
    CGFloat morph = MIN(MAX((progress - 0.55) / 0.35, 0.0), 1.0);
    morph = morph * morph * (3.0 - 2.0 * morph);
    return CGRectMake(peek.origin.x + (target.origin.x - peek.origin.x) * morph,
                      peek.origin.y + (target.origin.y - peek.origin.y) * morph,
                      peek.size.width + (target.size.width - peek.size.width) * morph,
                      peek.size.height + (target.size.height - peek.size.height) * morph);
}

- (void)updateCornerRadiusForProgress:(CGFloat)progress {
    CGFloat resting = [self cornerRadiusForState:progress >= kDSSplitProgress ? DSStageStateSplit : DSStageStateOverlay];
    CGFloat phase = MIN(progress / kDSSplitProgress, 1.0);
    _container.cornerRadius = kDSPeekCornerRadius + (resting - kDSPeekCornerRadius) * phase;
}

#pragma mark - Host snapshot

// A still of the screen stands in for the app behind for the length of the
// gesture. The recordings show that app shrinking to 0.872 about the screen
// centre over black while the corner is pulled, which is not something a live
// scene can be asked to do sixty times a second, and the still also covers the
// moment the real scene catches up with its new geometry in Split View.
- (void)prepareHostSnapshot {
    if (_hostSnapshot) return;
    UIView *snapshot = nil;
    if ([UIScreen.mainScreen respondsToSelector:@selector(snapshotViewAfterScreenUpdates:)]) {
        snapshot = [UIScreen.mainScreen snapshotViewAfterScreenUpdates:NO];
    }
    if (!snapshot) return;

    CGRect screen = [self screenBounds];

    UIView *backdrop = [[UIView alloc] initWithFrame:screen];
    backdrop.backgroundColor = UIColor.blackColor;
    backdrop.alpha = 0.0;
    backdrop.userInteractionEnabled = NO;
    [_window.rootViewController.view insertSubview:backdrop atIndex:0];
    _hostBackdrop = backdrop;

    snapshot.frame = screen;
    snapshot.layer.cornerCurve = kCACornerCurveContinuous;
    snapshot.layer.masksToBounds = YES;
    snapshot.layer.cornerRadius = [self displayCornerRadius];
    snapshot.userInteractionEnabled = NO;
    [_window.rootViewController.view insertSubview:snapshot aboveSubview:backdrop];
    _hostSnapshot = snapshot;
}

- (void)updateHostSnapshotForProgress:(CGFloat)progress {
    if (!_hostSnapshot) return;

    CGRect screen = [self screenBounds];
    CGFloat shrinkPhase = MIN(MAX(progress / kDSSplitProgress, 0.0), 1.0);
    CGFloat scale = 1.0 - (1.0 - kDSHostShrinkScale) * shrinkPhase;

    _hostSnapshot.transform = CGAffineTransformIdentity;
    _hostSnapshot.frame = screen;
    _hostSnapshot.transform = CGAffineTransformMakeScale(scale, scale);
    // The black only has to appear once the app has actually left the edges.
    _hostBackdrop.alpha = MIN(shrinkPhase * 4.0, 1.0);
}

// Split View: the still grows back to full width and settles into the top half,
// so the app appears to resize rather than jump.
- (void)animateHostSnapshotIntoSplit {
    if (!_hostSnapshot) return;
    CGRect target = [self hostFrameForSplit];
    _hostSnapshot.transform = CGAffineTransformIdentity;
    _hostSnapshot.frame = target;
}

- (void)animateHostSnapshotToFullScreen {
    if (!_hostSnapshot) return;
    _hostSnapshot.transform = CGAffineTransformIdentity;
    _hostSnapshot.frame = [self screenBounds];
    _hostBackdrop.alpha = 0.0;
}

- (void)discardHostSnapshotAnimated:(BOOL)animated {
    UIView *snapshot = _hostSnapshot;
    UIView *backdrop = _hostBackdrop;
    if (!snapshot && !backdrop) return;
    _hostSnapshot = nil;
    _hostBackdrop = nil;

    if (!animated) {
        [snapshot removeFromSuperview];
        [backdrop removeFromSuperview];
        return;
    }
    [UIView animateWithDuration:0.2 animations:^{
        snapshot.alpha = 0.0;
        backdrop.alpha = 0.0;
    } completion:^(BOOL finished) {
        [snapshot removeFromSuperview];
        [backdrop removeFromSuperview];
    }];
}

#pragma mark - Split View corner mask

// A rounded rectangle whose corners follow the same superellipse the display mask
// uses, rather than the plain arcs UIBezierPath draws. Sixteen samples a corner
// is past the point where the difference is visible.
static UIBezierPath *DSContinuousRoundedPath(CGRect rect, CGFloat radius, UIRectCorner corners) {
    static const NSInteger kSamples = 16;
    static const CGFloat kExponent = 5.0;

    radius = MIN(radius, MIN(CGRectGetWidth(rect), CGRectGetHeight(rect)) / 2.0);
    UIBezierPath *path = [UIBezierPath bezierPath];

    CGFloat minX = CGRectGetMinX(rect), maxX = CGRectGetMaxX(rect);
    CGFloat minY = CGRectGetMinY(rect), maxY = CGRectGetMaxY(rect);

    // Each corner is walked as a quarter superellipse from one edge to the next.
    // Going clockwise, the sweep runs the other way on every second corner.
    void (^corner)(CGPoint, CGFloat, CGFloat, BOOL, BOOL) =
        ^(CGPoint centre, CGFloat sx, CGFloat sy, BOOL rounded, BOOL reverse) {
        if (!rounded) {
            [path addLineToPoint:CGPointMake(centre.x + sx * radius, centre.y + sy * radius)];
            return;
        }
        for (NSInteger i = 0; i <= kSamples; i++) {
            CGFloat fraction = (CGFloat)i / (CGFloat)kSamples;
            CGFloat t = (reverse ? 1.0 - fraction : fraction) * M_PI_2;
            CGFloat dx = pow(cos(t), 2.0 / kExponent);
            CGFloat dy = pow(sin(t), 2.0 / kExponent);
            [path addLineToPoint:CGPointMake(centre.x + sx * radius * dx,
                                            centre.y + sy * radius * dy)];
        }
    };

    [path moveToPoint:CGPointMake(minX + radius, minY)];
    [path addLineToPoint:CGPointMake(maxX - radius, minY)];
    corner(CGPointMake(maxX - radius, minY + radius), 1.0, -1.0, (corners & UIRectCornerTopRight) != 0, YES);
    [path addLineToPoint:CGPointMake(maxX, maxY - radius)];
    corner(CGPointMake(maxX - radius, maxY - radius), 1.0, 1.0, (corners & UIRectCornerBottomRight) != 0, NO);
    [path addLineToPoint:CGPointMake(minX + radius, maxY)];
    corner(CGPointMake(minX + radius, maxY - radius), -1.0, 1.0, (corners & UIRectCornerBottomLeft) != 0, YES);
    [path addLineToPoint:CGPointMake(minX, minY + radius)];
    corner(CGPointMake(minX + radius, minY + radius), -1.0, -1.0, (corners & UIRectCornerTopLeft) != 0, NO);
    [path closePath];
    return path;
}

// SpringBoard does not round a scene it has resized, but the stock tweak's
// Split View clearly has the same corner profile on the bottom of the top app as
// the display itself. Everything around the resized app is black, so painting
// black wedges over its bottom corners is indistinguishable from masking it.
- (void)updateSplitCornerMask {
    CGRect host = [self hostFrameForSplit];
    CGFloat radius = [self displayCornerRadius];

    if (!_splitCornerMask) {
        _splitCornerMask = [[UIView alloc] initWithFrame:host];
        _splitCornerMask.userInteractionEnabled = NO;
        _splitCornerMask.backgroundColor = UIColor.clearColor;

        CAShapeLayer *shape = [CAShapeLayer layer];
        shape.fillColor = UIColor.blackColor.CGColor;
        shape.fillRule = kCAFillRuleEvenOdd;
        [_splitCornerMask.layer addSublayer:shape];
        [_window.rootViewController.view insertSubview:_splitCornerMask belowSubview:_container];
    }

    _splitCornerMask.frame = host;
    CAShapeLayer *shape = (CAShapeLayer *)_splitCornerMask.layer.sublayers.firstObject;

    // The host's whole rectangle minus the same rectangle with its bottom corners
    // rounded, which leaves exactly the two wedges to paint. Only the bottom two:
    // the top corners are the display's own.
    CGRect bounds = _splitCornerMask.bounds;
    UIBezierPath *path = [UIBezierPath bezierPathWithRect:bounds];
    [path appendPath:DSContinuousRoundedPath(bounds, radius,
                                             UIRectCornerBottomLeft | UIRectCornerBottomRight)];
    shape.path = path.CGPath;
    shape.frame = bounds;
    _splitCornerMask.hidden = NO;
}

- (void)removeSplitCornerMask {
    [_splitCornerMask removeFromSuperview];
    _splitCornerMask = nil;
}

#pragma mark - States

- (void)enterStateOverlayAnimated:(BOOL)animated {
    [self cancelAutoKill];
    _state = DSStageStateOverlay;
    _window.hidden = NO;
    _openAppIcon.alpha = 0.0;

    [self restoreHostLayout];
    if (self.hasHostedApp) [_sceneHost setForeground:YES];

    void (^layout)(void) = ^{
        // The app behind is untouched in overlay, so the still springs back to
        // full screen before it is thrown away.
        [self animateHostSnapshotToFullScreen];
        self->_container.frame = [self stageFrameForState:DSStageStateOverlay];
        self->_container.cornerRadius = [self cornerRadiusForState:DSStageStateOverlay];
    };
    void (^finish)(void) = ^{
        [self discardHostSnapshotAnimated:YES];
        [self layoutStageForState:DSStageStateOverlay];
        [self updateHomeAffordance];
    };

    if (animated) {
        [self animateSpring:layout completion:finish];
    } else {
        layout();
        finish();
    }
}

- (void)enterStateSplitAnimated:(BOOL)animated {
    [self cancelAutoKill];
    _state = DSStageStateSplit;
    _window.hidden = NO;
    _openAppIcon.alpha = 0.0;

    if (self.hasHostedApp) [_sceneHost setForeground:YES];
    [self applySplitHostLayout];
    [self updateSplitCornerMask];

    void (^layout)(void) = ^{
        [self animateHostSnapshotIntoSplit];
        self->_container.frame = [self stageFrameForState:DSStageStateSplit];
        self->_container.cornerRadius = [self cornerRadiusForState:DSStageStateSplit];
    };
    void (^finish)(void) = ^{
        [self layoutStageForState:DSStageStateSplit];
        [self updateHomeAffordance];
        // By now the live app has caught up with the resized scene.
        [self discardHostSnapshotAnimated:YES];
    };

    if (animated) {
        [self animateSpring:layout completion:finish];
    } else {
        layout();
        finish();
    }
}

- (void)minimizeAnimated:(BOOL)animated {
    if (!self.hasHostedApp) {
        [self closeStageAnimated:animated];
        return;
    }

    [self restoreHostLayout];
    void (^layout)(void) = ^{
        self->_container.frame = [self stageFrameForState:DSStageStateClosed];
        self->_container.cornerRadius = [self cornerRadiusForState:DSStageStateOverlay];
    };
    void (^finish)(void) = ^{
        self->_state = DSStageStateMinimized;
        // Backgrounded rather than occluded is what keeps push driven apps
        // delivering while the stage is tucked away.
        [self->_sceneHost setForeground:NO];
        [self updateOpenAppIcon];
        [self updateHomeAffordance];
        [self scheduleAutoKill];
    };

    if (animated) {
        [self animateSpring:layout completion:finish];
    } else {
        layout();
        finish();
    }
}

- (void)closeStageAnimated:(BOOL)animated {
    [self cancelAutoKill];
    [self restoreHostLayout];
    [_picker dismissKeyboard];

    // The recordings show the card leaving straight down off the bottom edge at
    // full size rather than collapsing back into the corner.
    void (^layout)(void) = ^{
        self->_container.frame = [self stageFrameForState:DSStageStateClosed];
        self->_container.cornerRadius = [self cornerRadiusForState:DSStageStateOverlay];
        self->_container.alpha = 1.0;
    };
    void (^finish)(void) = ^{
        self->_state = DSStageStateClosed;
        self->_container.alpha = 1.0;
        self->_container.cornerRadius = [self cornerRadiusForState:DSStageStateOverlay];
        self->_container.frame = [self stageFrameForState:DSStageStateClosed];
        self->_openAppIcon.alpha = 0.0;
        self->_window.hidden = YES;
        self->_stageQuarterTurns = 0;
        [self teardownStageApp];
        [self updateHomeAffordance];
    };

    if (animated) {
        [self animateSpring:layout completion:finish];
    } else {
        layout();
        finish();
    }
}

- (void)teardownStageApp {
    if (!_sceneHost) {
        [self showPickerImmediately];
        return;
    }
    DSSceneHost *host = _sceneHost;
    _sceneHost = nil;
    [self showPickerImmediately];
    [self publishStageStateForBundleIdentifier:nil frame:CGRectZero active:NO];

    if ([DSPreferences sharedPreferences].autoKill == DSAutoKillOnClose) {
        [host terminate];
    } else {
        [host relinquishKeepingBackgrounded:[[DSPreferences sharedPreferences] backgroundsOnMinimize:host.bundleIdentifier]];
        [self scheduleAutoKillForHost:host];
    }
}

#pragma mark - Split View host layout

- (void)applySplitHostLayout {
    SBApplication *front = [self frontApplication];
    FBScene *scene = [self sceneForApplication:front];
    if (!scene) return;

    _splitHostBundleIdentifier = front.bundleIdentifier;
    UIEdgeInsets insets = [self screenSafeAreaInsets];
    insets.bottom = 0;
    [DSSceneHost registerGeometryOverrideForScene:scene frame:[self hostFrameForSplit] insets:insets];
}

- (void)restoreHostLayout {
    [self removeSplitCornerMask];
    if (!_splitHostBundleIdentifier) return;

    Class controllerClass = objc_getClass("SBApplicationController");
    SBApplication *application = [[controllerClass sharedInstance] applicationWithBundleIdentifier:_splitHostBundleIdentifier];
    FBScene *scene = [self sceneForApplication:application];
    _splitHostBundleIdentifier = nil;
    if (!scene) return;

    [DSSceneHost removeGeometryOverrideForScene:scene
                                 restoringFrame:[self screenBounds]
                                         insets:[self screenSafeAreaInsets]];
}

- (FBScene *)sceneForApplication:(SBApplication *)application {
    if (!application) return nil;
    if ([application respondsToSelector:@selector(mainScene)]) {
        FBScene *scene = application.mainScene;
        if (scene) return scene;
    }
    if ([application respondsToSelector:@selector(allScenes)]) {
        return application.allScenes.firstObject;
    }
    return nil;
}

#pragma mark - Shared state

// The injected app-side dylib has to know it is being hosted before its first
// frame, so the target and its rectangle are published to disk plus a Darwin
// notification for anything already running.
- (void)publishStageStateForBundleIdentifier:(NSString *)identifier frame:(CGRect)frame active:(BOOL)active {
    // The same file carries the recents list, so merge rather than overwrite.
    NSMutableDictionary *state = [([NSDictionary dictionaryWithContentsOfFile:kDSSharedStatePath] ?: @{}) mutableCopy];
    state[@"stage"] = identifier ?: @"";
    state[@"active"] = @(active);
    state[@"width"] = @(CGRectGetWidth(frame));
    state[@"height"] = @(CGRectGetHeight(frame));
    [state writeToFile:kDSSharedStatePath atomically:YES];
    notify_post(kDSStageGeometryNotification);
}

#pragma mark - Stage content

- (void)layoutStageForState:(DSStageState)state {
    CGRect frame = [self stageFrameForState:state];
    _container.frame = frame;
    if (!_sceneHost.isHosting) return;

    [_sceneHost setStageFrame:frame safeAreaInsets:[self stageSafeAreaInsets]];
    _sceneHost.hostView.frame = _container.contentView.bounds;
    [self publishStageStateForBundleIdentifier:_sceneHost.bundleIdentifier frame:frame active:YES];
}

- (void)showPickerImmediately {
    _container.backdropHidden = NO;
    [_container setBackdropHidden:NO];
    _picker.view.hidden = NO;
    _picker.view.alpha = 1.0;
    [_picker reloadContent];
    [_picker resetScrollPosition];
    [_launchPlaceholder removeFromSuperview];
    _launchPlaceholder = nil;
}

#pragma mark - Launching onto the stage

- (void)appPicker:(DSAppPickerViewController *)picker didSelectEntry:(DSAppEntry *)entry fromView:(UIView *)view {
    [picker dismissKeyboard];
    [self launchEntry:entry];
}

- (void)appPicker:(DSAppPickerViewController *)picker didHoldEntry:(DSAppEntry *)entry fromView:(UIView *)view {
    [picker dismissKeyboard];
    [self launchFullscreen:entry.bundleIdentifier];
}

- (void)launchEntry:(DSAppEntry *)entry {
    if (entry.bundleIdentifier.length == 0) return;
    DSPreferences *preferences = [DSPreferences sharedPreferences];
    if ([preferences isApplicationDisabled:entry.bundleIdentifier]) return;

    // Swap out whatever was already on the stage.
    if (_sceneHost && ![_sceneHost.bundleIdentifier isEqualToString:entry.bundleIdentifier]) {
        DSSceneHost *previous = _sceneHost;
        _sceneHost = nil;
        [previous relinquishKeepingBackgrounded:[preferences backgroundsOnMinimize:previous.bundleIdentifier]];
    }

    [preferences noteApplicationOpened:entry.bundleIdentifier];
    [self publishStageStateForBundleIdentifier:entry.bundleIdentifier
                                        frame:[self stageFrameForState:_state == DSStageStateSplit ? DSStageStateSplit : DSStageStateOverlay]
                                       active:YES];
    [self presentLaunchPlaceholderForEntry:entry];

    DSSceneHost *host = _sceneHost ?: [[DSSceneHost alloc] initWithBundleIdentifier:entry.bundleIdentifier];
    _sceneHost = host;

    __weak __typeof(self) weakSelf = self;
    [host prepareWithCompletion:^(BOOL ready) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!ready || strongSelf->_sceneHost != host) {
            [strongSelf dismissLaunchPlaceholder];
            if (strongSelf->_sceneHost == host) strongSelf->_sceneHost = nil;
            return;
        }
        [strongSelf attachHostedApp];
    }];
}

// The tapped plate grows into the stage while the app boots.
- (void)presentLaunchPlaceholderForEntry:(DSAppEntry *)entry {
    [_launchPlaceholder removeFromSuperview];

    DSLaunchPlaceholderView *placeholder =
        [[DSLaunchPlaceholderView alloc] initWithBundleIdentifier:entry.bundleIdentifier
                                                            icon:[[DSAppLibrary sharedLibrary] iconForBundleIdentifier:entry.bundleIdentifier]
                                                            dark:_container.darkMode];
    placeholder.frame = _container.contentView.bounds;
    placeholder.alpha = 0.0;
    [_container.contentView addSubview:placeholder];
    _launchPlaceholder = placeholder;

    [UIView animateWithDuration:0.22 animations:^{
        placeholder.alpha = 1.0;
        self->_picker.view.alpha = 0.0;
    }];
}

- (void)dismissLaunchPlaceholder {
    UIView *placeholder = _launchPlaceholder;
    _launchPlaceholder = nil;
    _picker.view.hidden = NO;
    [UIView animateWithDuration:0.2 animations:^{
        placeholder.alpha = 0.0;
        self->_picker.view.alpha = 1.0;
    } completion:^(BOOL finished) {
        [placeholder removeFromSuperview];
    }];
}

- (void)attachHostedApp {
    UIView *hostView = _sceneHost.hostView;
    if (!hostView) {
        [self dismissLaunchPlaceholder];
        return;
    }

    _picker.view.hidden = YES;
    _picker.view.alpha = 1.0;
    [_container setBackdropHidden:YES];
    hostView.frame = _container.contentView.bounds;
    [_container.contentView insertSubview:hostView atIndex:0];

    [self layoutStageForState:_state == DSStageStateSplit ? DSStageStateSplit : DSStageStateOverlay];
    [self applyStageRotation];
    [self requestKeyboardFocusForStage];
    [self updateHomeAffordance];

    UIView *placeholder = _launchPlaceholder;
    _launchPlaceholder = nil;
    [UIView animateWithDuration:0.3 animations:^{
        placeholder.alpha = 0.0;
    } completion:^(BOOL finished) {
        [placeholder removeFromSuperview];
    }];
}

// Back to the picker, app stays alive.
- (void)exitToPickerAnimated:(BOOL)animated {
    if (!self.hasHostedApp) return;
    DSSceneHost *host = _sceneHost;
    _sceneHost = nil;
    _stageQuarterTurns = 0;

    UIView *hostView = host.hostView;
    _picker.view.hidden = NO;
    _picker.view.alpha = 0.0;
    [_container setBackdropHidden:NO];
    [_picker reloadContent];
    [_picker.view layoutIfNeeded];

    // The app shrinks back into its own plate in the grid, the way iOS zooms an
    // app into its icon on the way home. Without a visible plate it just shrinks
    // where it is.
    CGRect plate = [_picker plateFrameForBundleIdentifier:host.bundleIdentifier inView:_container.contentView];
    CGAffineTransform baseTransform = hostView.transform;
    CGRect hostFrame = hostView.frame;
    CGPoint hostCenter = CGPointMake(CGRectGetMidX(hostFrame), CGRectGetMidY(hostFrame));
    CGFloat zoom = CGRectIsNull(plate) ? 0.86 : CGRectGetWidth(plate) / MAX(CGRectGetWidth(hostFrame), 1.0);
    CGPoint destination = CGRectIsNull(plate)
        ? hostCenter
        : CGPointMake(CGRectGetMidX(plate), CGRectGetMidY(plate));

    hostView.layer.cornerCurve = kCACornerCurveContinuous;
    hostView.layer.masksToBounds = YES;

    void (^layout)(void) = ^{
        hostView.transform = CGAffineTransformConcat(baseTransform, CGAffineTransformMakeScale(zoom, zoom));
        hostView.center = destination;
        hostView.alpha = 0.0;
        // The layer's own radius is scaled down with it, so it is pre-divided to
        // land on the plate's radius.
        hostView.layer.cornerRadius = kDSCellRadius / MAX(zoom, 0.01);
        self->_picker.view.alpha = 1.0;
    };
    void (^finish)(void) = ^{
        hostView.transform = CGAffineTransformIdentity;
        hostView.layer.cornerRadius = 0.0;
        hostView.layer.masksToBounds = NO;
        [self publishStageStateForBundleIdentifier:nil frame:CGRectZero active:NO];
        [host relinquishKeepingBackgrounded:[[DSPreferences sharedPreferences] backgroundsOnMinimize:host.bundleIdentifier]];
        [self showPickerImmediately];
        [self scheduleAutoKillForHost:host];
        [self updateHomeAffordance];
    };

    if (animated) {
        [UIView animateWithDuration:0.32
                              delay:0.0
             usingSpringWithDamping:0.9
              initialSpringVelocity:0.0
                            options:0
                         animations:layout
                         completion:^(BOOL finished) { finish(); }];
    } else {
        layout();
        finish();
    }
}

// Hand an app the whole screen instead of the stage.
- (void)launchFullscreen:(NSString *)identifier {
    if (identifier.length == 0) return;
    [[DSPreferences sharedPreferences] noteApplicationOpened:identifier];

    DSSceneHost *host = _sceneHost;
    _sceneHost = nil;
    [self restoreHostLayout];
    [self publishStageStateForBundleIdentifier:nil frame:CGRectZero active:NO];
    [host relinquishKeepingBackgrounded:NO];

    SpringBoard *springBoard = (SpringBoard *)UIApplication.sharedApplication;
    if ([springBoard respondsToSelector:@selector(launchApplicationWithIdentifier:suspended:)]) {
        [springBoard launchApplicationWithIdentifier:identifier suspended:NO];
    }

    _state = DSStageStateClosed;
    _container.frame = [self stageFrameForState:DSStageStateClosed];
    _window.hidden = YES;
    _stageQuarterTurns = 0;
    [self showPickerImmediately];
    [self updateHomeAffordance];
}

#pragma mark - Rotation

- (void)rotateStageBy:(NSInteger)quarterTurns {
    if (!self.hasHostedApp) return;
    if (quarterTurns == 0) {
        _stageQuarterTurns = 0;
    } else {
        _stageQuarterTurns = ((_stageQuarterTurns + quarterTurns) % 4 + 4) % 4;
    }
    [UIView animateWithDuration:0.3 animations:^{
        [self applyStageRotation];
    }];
}

- (void)applyStageRotation {
    UIView *hostView = _sceneHost.hostView;
    if (!hostView) return;
    CGRect content = _container.contentView.bounds;
    if (_stageQuarterTurns % 2 == 0) {
        hostView.transform = CGAffineTransformIdentity;
        hostView.frame = content;
    } else {
        // Swap the axes, then rotate back into the stage rectangle.
        hostView.transform = CGAffineTransformIdentity;
        hostView.frame = CGRectMake(0, 0, CGRectGetHeight(content), CGRectGetWidth(content));
        hostView.transform = CGAffineTransformMakeRotation(_stageQuarterTurns == 1 ? M_PI_2 : -M_PI_2);
        hostView.center = CGPointMake(CGRectGetMidX(content), CGRectGetMidY(content));
    }
    if (_stageQuarterTurns == 2) {
        hostView.transform = CGAffineTransformMakeRotation(M_PI);
    }
}

#pragma mark - Minimised indicator

- (void)updateOpenAppIcon {
    DSPreferences *preferences = [DSPreferences sharedPreferences];
    BOOL show = preferences.showOpenAppIcon && _state == DSStageStateMinimized && self.hasHostedApp;
    if (!show) {
        [UIView animateWithDuration:0.2 animations:^{
            self->_openAppIcon.alpha = 0.0;
        } completion:^(BOOL finished) {
            if (self->_state == DSStageStateClosed) self->_window.hidden = YES;
        }];
        return;
    }

    CGRect bounds = [self screenBounds];
    CGFloat side = 22.0;
    _openAppIcon.image = [[DSAppLibrary sharedLibrary] iconForBundleIdentifier:_sceneHost.bundleIdentifier];
    _openAppIcon.frame = CGRectMake(CGRectGetWidth(bounds) - side - 10.0,
                                    CGRectGetHeight(bounds) - side - 6.0,
                                    side, side);
    _window.hidden = NO;
    [UIView animateWithDuration:0.25 animations:^{
        self->_openAppIcon.alpha = 1.0;
    }];
}

#pragma mark - Home affordance

- (void)updateHomeAffordance {
    // Toggling the system home grabber is handled by the SpringBoard hook; this
    // just pokes it to re-evaluate.
    Class grabberClass = objc_getClass("SBHomeGrabberView");
    if (!grabberClass) return;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        [self refreshHomeGrabbersInView:window ofClass:grabberClass depth:0];
    }
}

- (void)refreshHomeGrabbersInView:(UIView *)view ofClass:(Class)grabberClass depth:(NSInteger)depth {
    if (depth > 6) return;
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:grabberClass]) {
            subview.alpha = [self shouldHideSystemHomeAffordance] ? 0.0 : 1.0;
            continue;
        }
        [self refreshHomeGrabbersInView:subview ofClass:grabberClass depth:depth + 1];
    }
}

#pragma mark - Auto kill

- (void)scheduleAutoKill {
    [self scheduleAutoKillForHost:_sceneHost];
}

- (void)scheduleAutoKillForHost:(DSSceneHost *)host {
    [self cancelAutoKill];
    if (!host) return;

    NSTimeInterval delay = 0;
    switch ([DSPreferences sharedPreferences].autoKill) {
        case DSAutoKillFiveMinutes: delay = 5 * 60; break;
        case DSAutoKillTenMinutes: delay = 10 * 60; break;
        case DSAutoKillOnClose:
        case DSAutoKillNever:
        default: return;
    }

    __weak __typeof(self) weakSelf = self;
    _autoKillTimer = [NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(NSTimer *timer) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf->_state == DSStageStateOverlay || strongSelf->_state == DSStageStateSplit) return;
        [host terminate];
        if (strongSelf->_sceneHost == host) strongSelf->_sceneHost = nil;
        if (strongSelf->_state == DSStageStateMinimized) strongSelf->_state = DSStageStateClosed;
        [strongSelf updateOpenAppIcon];
    }];
}

- (void)cancelAutoKill {
    [_autoKillTimer invalidate];
    _autoKillTimer = nil;
}

#pragma mark - Keyboard

// Ask SpringBoard to re-evaluate which scene owns the keyboard so text fields
// inside the stage work. The owning class moved around between iOS 14 and 16,
// so every candidate is probed.
- (void)requestKeyboardFocusForStage {
    NSArray<NSString *> *classNames = @[ @"SBKeyboardFocusController", @"SBSceneKeyboardFocusController" ];
    SEL selector = @selector(reevaluateFocusedSceneIdentityForKeyboardFocusWithChangeInformation:stealingKeyboardOnSuccess:);
    for (NSString *name in classNames) {
        Class candidate = objc_getClass(name.UTF8String);
        if (!candidate) continue;
        if (![candidate respondsToSelector:@selector(sharedInstance)]) continue;
        id instance = ((id (*)(id, SEL))objc_msgSend)(candidate, @selector(sharedInstance));
        if (![instance respondsToSelector:selector]) continue;
        @try {
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(instance, selector, nil, YES);
        } @catch (NSException *exception) {
        }
        return;
    }
}

#pragma mark - In-stage gestures

// One recogniser drives all three in-stage gestures; which one it is depends on
// where the drag started.
- (void)handleStagePan:(UIPanGestureRecognizer *)recognizer {
    static BOOL fromTop = NO;
    static BOOL fromBottom = NO;
    static BOOL fromCorner = NO;

    CGPoint location = [recognizer locationInView:_container];
    CGPoint translation = [recognizer translationInView:_window];
    CGPoint velocity = [recognizer velocityInView:_window];
    CGRect resting = [self stageFrameForState:_state == DSStageStateSplit ? DSStageStateSplit : DSStageStateOverlay];

    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan: {
            CGPoint start = CGPointMake(location.x - translation.x, location.y - translation.y);
            fromCorner = CGRectContainsPoint([self closeZoneRect], start);
            fromTop = !fromCorner && CGRectContainsPoint([_container dragAffordanceRect], start);
            fromBottom = !fromCorner && !fromTop && self.hasHostedApp &&
                         CGRectContainsPoint([_container homeAffordanceRect], start);
            break;
        }
        case UIGestureRecognizerStateChanged: {
            if (fromCorner) {
                CGFloat offset = MAX(translation.y, 0.0);
                _container.frame = CGRectOffset(resting, 0, offset);
                _container.alpha = 1.0 - MIN(offset / (CGRectGetHeight(resting) * 0.6), 0.75);
            } else if (fromTop) {
                _container.frame = CGRectOffset(resting, 0, MAX(translation.y, -70.0));
            } else if (fromBottom) {
                CGFloat lift = MIN(MAX(-translation.y, 0.0), 120.0);
                CGFloat scale = 1.0 - lift / 900.0;
                _sceneHost.hostView.transform = CGAffineTransformMakeScale(scale, scale);
            }
            break;
        }
        case UIGestureRecognizerStateEnded: {
            if (fromCorner) {
                if (translation.y > CGRectGetHeight(resting) * 0.2 || velocity.y > 700.0) {
                    [self closeStageAnimated:YES];
                } else {
                    [self snapBackTo:resting];
                }
            } else if (fromTop) {
                if (translation.y > CGRectGetHeight(resting) * 0.22 || velocity.y > 850.0) {
                    [self minimizeAnimated:YES];
                } else if (translation.y < -40.0 && _state == DSStageStateOverlay) {
                    [self enterStateSplitAnimated:YES];
                } else if (translation.y > 40.0 && _state == DSStageStateSplit) {
                    [self enterStateOverlayAnimated:YES];
                } else {
                    [self snapBackTo:resting];
                }
            } else if (fromBottom) {
                if (translation.y < -55.0 || velocity.y < -600.0) {
                    [self exitToPickerAnimated:YES];
                } else {
                    [UIView animateWithDuration:0.25 animations:^{
                        self->_sceneHost.hostView.transform = CGAffineTransformIdentity;
                    }];
                }
            }
            fromTop = fromBottom = fromCorner = NO;
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            if (fromBottom) {
                _sceneHost.hostView.transform = CGAffineTransformIdentity;
            } else if (fromTop || fromCorner) {
                [self snapBackTo:resting];
            }
            fromTop = fromBottom = fromCorner = NO;
            break;
        }
        default:
            break;
    }
}

- (void)snapBackTo:(CGRect)resting {
    [self animateSpring:^{
        self->_container.frame = resting;
        self->_container.alpha = 1.0;
    } completion:nil];
}

- (CGRect)closeZoneRect {
    CGRect bounds = _container.bounds;
    return CGRectMake(CGRectGetWidth(bounds) - kDSTriggerWidth,
                      CGRectGetHeight(bounds) - kDSTriggerHeight,
                      kDSTriggerWidth,
                      kDSTriggerHeight);
}

#pragma mark - External events

- (void)noteSceneDestroyedForBundleIdentifier:(NSString *)bundleIdentifier {
    if (!_sceneHost || ![_sceneHost.bundleIdentifier isEqualToString:bundleIdentifier]) return;
    _sceneHost = nil;
    [self showPickerImmediately];
    if (_state == DSStageStateMinimized) {
        _state = DSStageStateClosed;
        _window.hidden = YES;
    }
    [self updateOpenAppIcon];
    [self updateHomeAffordance];
}

- (void)noteFrontApplicationWillChange {
    // Split View is bound to the app it was opened over, so a new front app
    // hands the top half back before it appears.
    if (_state == DSStageStateSplit) {
        [self restoreHostLayout];
        [self enterStateOverlayAnimated:NO];
    }
    if (_state == DSStageStateOverlay && ![DSPreferences sharedPreferences].enabled) {
        [self closeStageAnimated:NO];
    }
}

- (void)noteDisplayDidTurnOff {
    if (self.isStageVisible) [self minimizeAnimated:NO];
}

#pragma mark - Intro

- (void)showIntroIfNeeded {
    DSPreferences *preferences = [DSPreferences sharedPreferences];
    if (preferences.introShown) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        Class lockScreenClass = objc_getClass("SBLockScreenManager");
        id manager = lockScreenClass ? [lockScreenClass sharedInstance] : nil;
        if ([manager respondsToSelector:@selector(isUILocked)] && [manager isUILocked]) {
            // Try again after the device is unlocked.
            [self showIntroIfNeeded];
            return;
        }
        [DSIntroViewController presentIntro];
    });
}

@end
