#import "DSStageManager.h"
#import "DSStageWindow.h"
#import "DSStageContainerView.h"
#import "DSAppPickerViewController.h"
#import "DSAppLibrary.h"
#import "DSGestureController.h"
#import "DSSceneHost.h"
#import "DSKeyboardHost.h"
#import "DSPreferences.h"
#import "DSPrivate.h"
#import "DSIntroViewController.h"
#import "DSDiagnostics.h"
#import "DSKeyboardVisibility.h"
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
    NSString *_bundleIdentifierToRestoreInFront;
    BOOL _notedKeyboardOnce;
    BOOL _notedStrayKeyboard;
    // Where the card sits while the app on it is being typed into. Empty the rest of the
    // time, and the rest of the time the card's frame comes from its state as usual.
    CGRect _typingFrame;
    CGFloat _typingKeys;
    NSTimeInterval _typingResizeDuration;
    BOOL _typingResizeQueued;
    NSTimeInterval _ignoreSystemPullUntil;
    // The keyboard as the arbiter last described it, in display points, or zero when
    // there is none on screen. Whose keyboard it is does not matter: it is on the
    // display, the card is on the display, and the card gives way.
    CGRect _keyboardFrame;
    NSTimer *_autoKillTimer;
    NSInteger _stageQuarterTurns;

    DSStageState _stateBeforeTracking;
    CGFloat _trackingProgress;
    BOOL _trackingPassedSplit;
    BOOL _activated;

    UIPanGestureRecognizer *_dragPan;
    UIPanGestureRecognizer *_systemPull;
    NSString *_lastRefusal;
    UIImpactFeedbackGenerator *_feedback;
    __weak UIWindow *_windowBeforeStage;
}

static BOOL sSystemEdgePullAvailable;

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

    // Nothing is on the stage when SpringBoard starts. Saying so explicitly clears
    // whatever was published before it last went away: an app that read a stale
    // "you are on the stage" would launch full screen pinned to portrait with no
    // status bar and no way to find out otherwise.
    [self publishStageStateForBundleIdentifier:nil frame:CGRectZero active:NO];

    [[DSPreferences sharedPreferences] startObserving];
    _feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [self buildWindow];
    [self observeKeyboard];

    DSDiagnosticsRecordFormat(@"SpringBoard: stage ready, screen %@, corner %@, pull comes from %@",
                              NSStringFromCGRect([self screenBounds]),
                              NSStringFromCGRect([DSGestureController triggerRect]),
                              sSystemEdgePullAvailable ? @"the system edge gesture" : @"a window in the corner");

    // Only one of the two ever runs. When SpringBoard's own edge pull can be taken
    // over, a second recogniser in the same corner would mean two things happening
    // per drag; when it cannot, the corner window is all there is.
    if (!sSystemEdgePullAvailable) {
        _gesture = [[DSGestureController alloc] init];
        _gesture.delegate = self;
        [_gesture install];
    }
}

+ (void)setSystemEdgePullAvailable:(BOOL)available {
    sSystemEdgePullAvailable = available;
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

#pragma mark - Typing

// Text goes to the key window, and the stage's window was never made key: the
// search field could be tapped but nothing could be typed into it, in the stage
// or in an app hosted on it. SpringBoard gets its window back when the stage
// leaves, so nothing else on the device notices.
- (void)takeKeyWindow {
    if (!_window || _window.isKeyWindow) return;

    if (!_windowBeforeStage) {
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            if (window != _window && window.isKeyWindow) {
                _windowBeforeStage = window;
                break;
            }
        }
    }
    @try {
        // Both halves in one call. Being merely unhidden and merely key are not the
        // same as being a window UIKit will bring a keyboard up for.
        [_window makeKeyAndVisible];
        if (!_window.isKeyWindow) {
            DSDiagnosticsRecord(@"SpringBoard: the stage window would not become key, so nothing can be typed");
        }
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: could not take the key window - %@", exception.reason ?: @"?");
    }
}

- (void)giveBackKeyWindow {
    UIWindow *previous = _windowBeforeStage;
    _windowBeforeStage = nil;
    if (!_window.isKeyWindow) return;
    @try {
        [previous makeKeyWindow];
    } @catch (NSException *exception) {
    }
}

// Clears stale keyboard bookkeeping from a staged app and makes the stage window key
// again so SpringBoard's search field can raise UIKit's keyboard.
- (void)preparePickerForSearchKeyboard {
    if (_sceneHost.isHosting) return;
    _notedStrayKeyboard = NO;
    [self takeKeyWindow];

    // Called when the overlay finishes opening and when the search field asks for focus.
    // If a keyboard is already on screen, resetting lift here is what left the card on
    // the keys the first time someone typed after opening the stage.
    CGRect keys = DSVisibleKeyboardFrameOnScreen();
    if (!CGRectIsNull(keys)) {
        [self noteKeyboardFrame:keys source:@"SpringBoard" duration:0.25];
        return;
    }

    _notedKeyboardOnce = NO;
    _keyboardFrame = CGRectZero;
    if (CGRectIsEmpty(_typingFrame)) {
        [_container setLiftOffset:0.0];
    }
}

// The card lives at the bottom of the screen, which is exactly where every keyboard on
// the device comes up, so it is held above whichever one is there.
//
// Two things say a keyboard is up, and they agree: this process gets the ordinary
// UIKit notifications for its own keyboard - the stage's search field - and the
// keyboard arbiter running here is told about every other process's. Nothing has to be
// reported by the app on the stage: its keyboard is drawn into a scene of the
// keyboard's own, which DSKeyboardHost hosts in a window the size of the display and
// refuses inside the card, so it is never in the card to be measured.
- (void)observeKeyboard {
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(keyboardFrameWillChange:)
                                              name:UIKeyboardWillChangeFrameNotification
                                            object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(keyboardWillShow:)
                                              name:UIKeyboardWillShowNotification
                                            object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                          selector:@selector(keyboardWillHide:)
                                              name:UIKeyboardWillHideNotification
                                            object:nil];
}

- (void)keyboardWillShow:(NSNotification *)notification {
    if (![self isShowingAppPicker]) return;
    [self keyboardFrameWillChange:notification];
}

- (void)keyboardFrameWillChange:(NSNotification *)notification {
    CGRect keyboard = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    [self noteKeyboardFrame:keyboard
                    source:@"SpringBoard"
                  duration:[notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue]];
}

- (void)keyboardWillHide:(NSNotification *)notification {
    [self noteKeyboardFrame:CGRectZero
                    source:@"SpringBoard"
                  duration:[notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue]];
}

- (void)keyboardOnScreen:(BOOL)onScreen frame:(CGRect)frame source:(NSString *)source {
    [self noteKeyboardFrame:onScreen ? frame : CGRectZero
                    source:source.length > 0 ? source : @"an app"
                  duration:0.25];
}

// While an app is on the stage, the arbiter still hears keyboards from Spotlight and
// from other processes behind the card. Treating those as the staged app's keyboard
// going away was the keys vanishing mid-sentence; ignoring them keeps _typingKeys
// authoritative until the staged app itself reports a hide.
- (BOOL)keyboardSourceAffectsLayout:(NSString *)source keyboard:(CGRect)keyboard {
    if (!_sceneHost.isHosting) return YES;

    NSString *staged = _sceneHost.bundleIdentifier;
    if (staged.length > 0 && [source isEqualToString:staged]) return YES;

    if ([source isEqualToString:@"SpringBoard"]) {
        if ([self isShowingAppPicker]) return YES;
        return !_sceneHost.isHosting;
    }

    if (_typingKeys > 0.0 || !CGRectIsEmpty(_typingFrame)) {
        if (CGRectIsEmpty(keyboard)) return NO;
        if ([source isEqualToString:@"com.apple.Spotlight"]) return NO;
        return NO;
    }
    return YES;
}

// The arbiter sometimes reports a keyboard anchored at the top of the display ({0,0})
// even though UIKit draws it on the bottom edge. Treat keyboard-sized frames that start
// in the upper half as bottom-anchored before any layout runs.
- (CGRect)keyboardFrameOnDisplay:(CGRect)keyboard {
    CGRect screen = [self screenBounds];
    CGFloat height = CGRectGetHeight(keyboard);
    if (height < kDSKeyboardPresentHeight) return keyboard;

    if (CGRectGetMinY(keyboard) >= CGRectGetMaxY(screen)) return keyboard;

    if (CGRectGetMinY(keyboard) < CGRectGetHeight(screen) * 0.55 &&
        height <= CGRectGetHeight(screen) * 0.65) {
        keyboard.origin.y = CGRectGetHeight(screen) - height;
        keyboard.origin.x = 0.0;
        keyboard.size.width = CGRectGetWidth(screen);
    }
    return keyboard;
}

// SpringBoard's search keyboard often arrives as a short frame first (243pt) before the
// suggestion bar settles (301pt). Lifting for the first report leaves the card on the keys.
- (CGRect)keyboardFrameForPickerSearch:(CGRect)keyboard {
    if (CGRectIsEmpty(keyboard)) return keyboard;
    CGRect screen = [self screenBounds];
    CGFloat keys = CGRectGetHeight(keyboard);
    if (keys < kDSKeyboardPresentHeight || keys > CGRectGetHeight(screen) * 0.6) {
        keys = 301.0;
    } else {
        keys = MAX(keys, 301.0);
    }
    return CGRectMake(0.0, CGRectGetMaxY(screen) - keys, CGRectGetWidth(screen), keys);
}

// One place for both, and the card's only answer to a keyboard: move up out of its way.
- (void)noteKeyboardFrame:(CGRect)keyboard source:(NSString *)source duration:(NSTimeInterval)duration {
    CGRect screen = [self screenBounds];
    keyboard = [self keyboardFrameOnDisplay:keyboard];
    if (CGRectGetHeight(keyboard) < kDSKeyboardPresentHeight ||
        CGRectGetMinY(keyboard) >= CGRectGetMaxY(screen)) {
        keyboard = CGRectZero;
    }

    if (![self keyboardSourceAffectsLayout:source keyboard:keyboard]) {
        if (!_notedStrayKeyboard && (!CGRectIsEmpty(keyboard) || _typingKeys > 0.0)) {
            _notedStrayKeyboard = YES;
            DSDiagnosticsRecordFormat(@"SpringBoard: ignored a keyboard from %@ while %@ is on the stage",
                                      source.length > 0 ? source : @"?",
                                      _sceneHost.bundleIdentifier);
        }
        return;
    }

    if ([self isShowingAppPicker] && !CGRectIsEmpty(keyboard)) {
        keyboard = [self keyboardFrameForPickerSearch:keyboard];
    }

    BOOL unchanged = CGRectEqualToRect(keyboard, _keyboardFrame);
    if (unchanged) {
        // The frame did not move but something else cleared the lift underneath it -
        // the overlay open path calling preparePickerForSearchKeyboard after the first
        // keyboardWillShow is the usual case.
        if (CGRectIsEmpty(keyboard) || ![self isShowingAppPicker]) return;
        CGRect resting = [self stageFrameForState:_state == DSStageStateSplit ? DSStageStateSplit
                                                                               : DSStageStateOverlay];
        CGFloat overlap = CGRectGetMaxY(resting) - CGRectGetMinY(keyboard) + kDSStageInset;
        if (_container.liftOffset >= MAX(overlap, 0.0) - 0.5) return;
    } else {
        _keyboardFrame = keyboard;
    }
    [[DSKeyboardHost sharedHost] setKeyboardFrame:self.isStageVisible ? keyboard : CGRectZero
                                           source:source];

    // Whether a keyboard comes up at all, and where, is the whole question when typing
    // does not work - and it is not something a user can be expected to describe.
    if (!_notedKeyboardOnce && !CGRectIsEmpty(keyboard)) {
        _notedKeyboardOnce = YES;
        DSDiagnosticsRecordFormat(@"SpringBoard: %@ put a keyboard up at %@ (the display is %@)",
                                  source, NSStringFromCGRect(keyboard), NSStringFromCGRect(screen));
    }

    if (!self.isStageVisible) return;

    // The staged app's own keyboard is drawn inside the card, because the card is that
    // app's whole window - there is no separate keyboard layer in SpringBoard to move and
    // this firmware will not host a keyboard scene for a phone. So the card is made the
    // right shape for it instead. Lifting the card would be lifting the keyboard with it.
    if (_sceneHost.isHosting && source.length > 0 &&
        [source isEqualToString:_sceneHost.bundleIdentifier]) {
        [self makeRoomForTheStagedAppsKeyboard:keyboard duration:duration];
        return;
    }

    // A keyboard belonging to neither SpringBoard nor the app on the stage, while there is
    // an app on the stage: written down once, because it would mean the card is being
    // shaped around the wrong keyboard, or around none.
    if (_sceneHost.isHosting && !_notedStrayKeyboard && !CGRectIsEmpty(keyboard) &&
        ![source isEqualToString:@"SpringBoard"]) {
        _notedStrayKeyboard = YES;
        DSDiagnosticsRecordFormat(@"SpringBoard: a keyboard came up for %@ while %@ is on the stage",
                                  source, _sceneHost.bundleIdentifier);
    }

    // While the card is the shape of the staged app's keyboard, a keyboard belonging to
    // anything else is none of the card's business. Spotlight reports one from behind the
    // stage, and lifting the card for it would take the app's own keys back off the bottom
    // of the display - which is the keyboard appearing and then leaving again.
    if (!CGRectIsEmpty(_typingFrame)) return;

    CGRect resting = [self stageFrameForState:_state == DSStageStateSplit ? DSStageStateSplit : DSStageStateOverlay];
    CGFloat overlap = CGRectIsEmpty(keyboard) ? 0.0
                                             : CGRectGetMaxY(resting) - CGRectGetMinY(keyboard) + kDSStageInset;
    [self liftCardBy:MAX(overlap, 0.0) duration:duration];
}

// The card, shaped around a keyboard that is drawn inside it: full display width, ending
// on the display's bottom edge, and tall enough that the app keeps a usable amount of
// itself above the keys. Put back the moment the keyboard goes.
- (void)makeRoomForTheStagedAppsKeyboard:(CGRect)keyboard duration:(NSTimeInterval)duration {
    CGFloat keys = 0.0;
    if (!CGRectIsEmpty(keyboard)) {
        CGRect screen = [self screenBounds];
        // The arbiter often reports a transient frame at the top of the display before
        // the real keyboard settles on the bottom edge; following those is the card
        // jumping and strips of the app showing under the stage.
        if (CGRectGetMinY(keyboard) < CGRectGetHeight(screen) * 0.55) return;
        keys = CGRectGetHeight(keyboard);
        if (keys < kDSKeyboardPresentHeight || keys > CGRectGetHeight(screen) * 0.6) keys = 301.0;
        // The picker's own keyboard is 301 points tall, and that is the size that
        // already lands correctly. An app reports its keyboard in stages - 243, then
        // 288 with a suggestion bar - and following each of those is the card
        // visibly jumping. Never smaller than the picker, never smaller than a
        // keyboard already on screen.
        keys = MAX(keys, 301.0);
        keys = MAX(keys, _typingKeys);
    }
    if (fabs(keys - _typingKeys) < 0.5) return;
    _typingKeys = keys;

    // And the reports come in a burst, so they are let finish before anything moves.
    _typingResizeDuration = MIN(duration, 0.08);
    if (_typingResizeQueued) return;
    _typingResizeQueued = YES;
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf applyTypingLayout];
    });
}

- (void)applyTypingLayout {
    _typingResizeQueued = NO;
    if (!self.isStageVisible) return;

    CGRect screen = [self screenBounds];
    CGRect wanted = CGRectZero;
    if (_typingKeys > 0.0) {
        DSStageState state = _state == DSStageStateSplit ? DSStageStateSplit : DSStageStateOverlay;
        CGRect resting = [self restingStageFrameForState:state];
        CGFloat keyboardTop = CGRectGetHeight(screen) - _typingKeys;
        CGFloat lift = CGRectGetMaxY(resting) - keyboardTop;
        if (lift < 0.0) lift = 0.0;
        wanted = CGRectOffset(resting, 0.0, -lift);
        CGFloat minY = kDSStageKeyboardHeadroom;
        if (CGRectGetMinY(wanted) < minY) {
            wanted.origin.y = minY;
            wanted.size.height = MAX(keyboardTop - minY, 180.0);
        }
    }
    if (CGRectEqualToRect(wanted, _typingFrame)) return;

    BOOL wasTyping = !CGRectIsEmpty(_typingFrame);
    _typingFrame = wanted;
    if (!wasTyping && !CGRectIsEmpty(wanted)) {
        DSDiagnosticsRecordFormat(@"SpringBoard: the card sits at %@ above a %gpt keyboard",
                                  NSStringFromCGRect(wanted), _typingKeys);
    }

    [_container setLiftOffset:0.0];
    [_container setClipsContents:YES];
    DSStageState state = _state == DSStageStateSplit ? DSStageStateSplit : DSStageStateOverlay;
    void (^resize)(void) = ^{
        [self layoutStageForState:state];
        self->_container.cornerRadius = [self cornerRadiusForState:state];
    };
    if (_typingResizeDuration > 0.0) {
        [UIView animateWithDuration:_typingResizeDuration animations:resize];
    } else {
        resize();
    }
}

- (void)liftCardBy:(CGFloat)offset duration:(NSTimeInterval)duration {
    // However wrong the number that got here, the card stays on the screen. A card
    // lifted off the top takes the search field, the app and every way of closing the
    // stage with it, and reads as the stage having broken.
    CGRect resting = [self stageFrameForState:_state == DSStageStateSplit ? DSStageStateSplit : DSStageStateOverlay];
    CGFloat headroom = MAX(CGRectGetMinY(resting) - kDSStageKeyboardHeadroom, 0.0);
    offset = MIN(MAX(offset, 0.0), headroom);

    if (fabs(offset - _container.liftOffset) < 0.5) return;

    void (^lift)(void) = ^{
        [self->_container setLiftOffset:offset];
        // The app is told where its window has moved to, so anything UIKit places
        // against the display - an input accessory view above the keyboard, most of
        // all - is placed against the card where it is now.
        if (self->_sceneHost.isHosting) [self pushLiftedGeometryToApp];
    };
    if (duration > 0.0) {
        [UIView animateWithDuration:duration animations:lift];
    } else {
        lift();
    }
}

- (void)pushLiftedGeometryToApp {
    CGRect window = CGRectOffset([self stageFrameForState:_state == DSStageStateSplit ? DSStageStateSplit : DSStageStateOverlay],
                                 0.0, -_container.liftOffset);
    [_sceneHost setStageFrame:window safeAreaInsets:[self stageSafeAreaInsets]];
    [self publishStageStateForBundleIdentifier:_sceneHost.bundleIdentifier frame:window active:YES];
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

// While typing, the app draws its keyboard at the full width of the display. The
// card stays inset, but the hosted view and the scene both need the display width
// or the keys are clipped on the sides and odd strips show under the card.
- (CGRect)fullWidthHostFrameForCard:(CGRect)card {
    CGRect screen = [self screenBounds];
    CGFloat y = CGRectGetMinY(card);
    return CGRectMake(0.0, y, CGRectGetWidth(screen), CGRectGetMaxY(screen) - y);
}

// The stage owns the bottom half of the display in both states. Floating over an
// app it is a card inset on three sides; sharing the screen it goes edge to edge
// and only the gap above it survives.
- (CGRect)stageFrameForState:(DSStageState)state {
    if (!CGRectIsEmpty(_typingFrame) && state != DSStageStateClosed && state != DSStageStateMinimized) {
        return _typingFrame;
    }
    return [self restingStageFrameForState:state];
}

// The card's usual size, ignoring any keyboard. Overlay is the inset half-screen
// card; split is edge to edge below the split line.
- (CGRect)restingStageFrameForState:(DSStageState)state {
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
            return CGRectMake(kDSStageInset, screenHeight,
                              screenWidth - kDSStageInset * 2.0,
                              screenHeight - top - kDSStageInset);
    }
}

- (CGFloat)cornerRadiusForState:(DSStageState)state {
    CGFloat display = [self displayCornerRadius];
    // Edge to edge the card's corners are the display's own; inset on both sides
    // they stay concentric with it.
    if (state == DSStageStateSplit) return display;
    return display - kDSStageInset;
}

// Whatever keyboard was up went away with the app that owned it.
- (void)forgetStagedAppKeyboard {
    _keyboardFrame = CGRectZero;
    [[DSKeyboardHost sharedHost] standDown];
    [_container setLiftOffset:0.0];
    _typingKeys = 0.0;
    _notedStrayKeyboard = NO;
    _container.passThroughToHost = NO;
    [_container setClipsContents:YES];
    if (!CGRectIsEmpty(_typingFrame)) {
        _typingFrame = CGRectZero;
        if (self.isStageVisible) {
            [self layoutStageForState:_state == DSStageStateSplit ? DSStageStateSplit : DSStageStateOverlay];
        }
    }
}

- (CGRect)hostFrameForSplit {
    CGRect bounds = [self screenBounds];
    return CGRectMake(0, 0, CGRectGetWidth(bounds), [self splitLine]);
}

- (UIEdgeInsets)stageSafeAreaInsets {
    // While the app is being typed into the card reaches the bottom of the display, so
    // the app is given the display's own bottom inset: its keyboard sits above the home
    // indicator rather than under it, exactly as it would full screen.
    if (!CGRectIsEmpty(_typingFrame)) {
        UIEdgeInsets insets = UIEdgeInsetsZero;
        insets.bottom = [self screenSafeAreaInsets].bottom;
        return insets;
    }

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

- (BOOL)isShowingAppPicker {
    return self.isStageVisible && !_picker.view.hidden && !_sceneHost.isHosting;
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
    return [self reasonStageCannotActivate] == nil;
}

// Said in words rather than as a flag, because "nothing happens when I pull from
// the corner" is the one report this tweak cannot investigate from the outside.
// The reason ends up in the log the Settings page reads back.
- (NSString *)reasonStageCannotActivate {
    DSPreferences *preferences = [DSPreferences sharedPreferences];
    if (!preferences.enabled) return @"the tweak is switched off in Settings";
    if ([[NSFileManager defaultManager] fileExistsAtPath:kDSKillSwitchPath]) {
        return @"the kill switch file is in place";
    }
    if ([DSIntroViewController isPresenting]) return @"the walkthrough is still on screen";

    Class lockScreenClass = objc_getClass("SBLockScreenManager");
    if (lockScreenClass) {
        SBLockScreenManager *manager = [lockScreenClass sharedInstance];
        if ([manager respondsToSelector:@selector(isUILocked)] && manager.isUILocked) {
            return @"the device is locked";
        }
    }

    // Portrait only, matching the stock tweak's documented limitation.
    if ([self activeOrientation] != UIInterfaceOrientationPortrait) return @"the screen is not portrait";

    SBApplication *front = [self frontApplication];
    if (!front && preferences.disableOnHomeScreen) {
        return @"Disable on Home Screen is on and the home screen is showing";
    }
    if (front && [preferences isApplicationDisabled:front.bundleIdentifier]) {
        return [NSString stringWithFormat:@"the stage is switched off for %@", front.bundleIdentifier];
    }

    return nil;
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
    // Only ever the card itself, where a swipe up belongs to the stage rather than
    // to the home gesture. The corner is deliberately left alone: the pull that
    // opens the stage is taken over from the system's own edge gesture, so that
    // gesture has to be allowed to begin. The app sharing the screen keeps its
    // gestures, and a stage left open in some state it should not be in cannot
    // take the home gesture away from the whole device - the card has to actually
    // be on screen and the touch has to be inside it.
    if (!self.isStageVisible || !_container.window) return NO;
    CGRect card = CGRectOffset(_container.frame, 0.0, -_container.liftOffset);
    if (CGRectContainsPoint(card, point)) return YES;

    // The home gesture starts on the display's bottom edge. When the card is inset
    // that edge is a few points below the card, so a drag that began on the corner
    // and left it downwards is otherwise taken as going home - which is the
    // "taken away before it finished" line, followed by the stage opening again.
    CGRect screen = [self screenBounds];
    CGRect belowCorner = CGRectMake(CGRectGetMaxX(card) - 130.0,
                                    CGRectGetMaxY(card) - 4.0,
                                    130.0,
                                    MAX(CGRectGetMaxY(screen) - CGRectGetMaxY(card), 0.0) + 12.0);
    return CGRectContainsPoint(belowCorner, point);
}

- (BOOL)shouldWindowCaptureTouchAtPoint:(CGPoint)point {
    if (_state == DSStageStateClosed || _state == DSStageStateMinimized) return NO;

    CGRect card = CGRectOffset(_container.frame, 0.0, -_container.liftOffset);
    if (CGRectContainsPoint(card, point)) return YES;

    // While typing, the app's keyboard is drawn in the host view below the card.
    // Those touches have to land on this window or they never reach the keys.
    if (_typingKeys > 0.0 && self.hasHostedApp) {
        CGRect screen = [self screenBounds];
        CGRect keys = CGRectMake(0.0,
                                 CGRectGetMaxY(card),
                                 CGRectGetWidth(screen),
                                 MAX(CGRectGetMaxY(screen) - CGRectGetMaxY(card), _typingKeys));
        return CGRectContainsPoint(keys, point);
    }
    return NO;
}

#pragma mark - Corner pull

- (BOOL)gestureControllerShouldBegin:(DSGestureController *)controller atPoint:(CGPoint)point {
    if (_systemPull || _state == DSStageStateTracking) return NO;
    if (_state == DSStageStateOverlay || _state == DSStageStateSplit) return NO;
    if (_state == DSStageStateMinimized) return YES;
    return [self canActivateStage];
}

#pragma mark - The system's own edge pull

// The pull that opens the stage starts at the very bottom of the screen, which is
// not a place a tweak can put a gesture recogniser and expect to win: the home
// and switcher gestures are recognised above every window on the display, so a
// recogniser in a window of the tweak's own either loses the touch or fights the
// system for it, and the report from the device is that dragging from the corner
// does nothing at all. So the tweak lets SpringBoard recognise the pull, and takes
// over the recogniser it is handed the moment SpringBoard says a pull off the
// bottom edge has begun in the stage's corner. The switcher is never told about
// that drag, so exactly one thing happens per pull.
- (BOOL)adoptSystemEdgePull:(UIPanGestureRecognizer *)gesture {
    if (!gesture || _systemPull) return NO;
    if (CFAbsoluteTimeGetCurrent() < _ignoreSystemPullUntil) return NO;
    if (_state != DSStageStateClosed && _state != DSStageStateMinimized) return NO;

    // By the time the pull is reported as begun the finger has already left the
    // bottom edge, so how far up it is says nothing. Which side of the screen it
    // started on is what separates the stage's corner from a swipe home.
    CGPoint start = [gesture locationInView:nil];
    if (start.x < CGRectGetWidth([self screenBounds]) - kDSTriggerWidth) return NO;

    if (_state != DSStageStateMinimized) {
        NSString *refusal = [self reasonStageCannotActivate];
        if (refusal) {
            [self noteRefusedPull:refusal];
            return NO;
        }
    }

    _systemPull = gesture;
    [gesture addTarget:self action:@selector(handleSystemPull:)];
    _lastRefusal = nil;
    DSDiagnosticsRecord(@"SpringBoard: corner pull picked up from the system gesture");
    [self gestureControllerDidBegin:nil];
    return YES;
}

- (void)noteRefusedPull:(NSString *)reason {
    // A pull is refused every time the user swipes up to go home from that corner,
    // so only a change of reason is worth writing down.
    if ([reason isEqualToString:_lastRefusal]) return;
    _lastRefusal = reason;
    DSDiagnosticsRecordFormat(@"SpringBoard: corner pull refused because %@", reason);
}

- (void)handleSystemPull:(UIPanGestureRecognizer *)gesture {
    if (gesture != _systemPull) return;

    // UIKit calls this one directly, so it is on its own for containment.
    @try {
        CGPoint translation = [gesture translationInView:nil];
        switch (gesture.state) {
            case UIGestureRecognizerStateChanged:
                [self gestureController:nil didUpdateTranslation:translation];
                break;
            case UIGestureRecognizerStateEnded:
                [self releaseSystemPull];
                [self gestureController:nil didEndWithTranslation:translation velocity:[gesture velocityInView:nil]];
                break;
            case UIGestureRecognizerStateCancelled:
            case UIGestureRecognizerStateFailed:
                [self releaseSystemPull];
                [self gestureControllerDidCancel:nil];
                break;
            default:
                break;
        }
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: the pull threw %@ - %@", exception.name, exception.reason);
        [self releaseSystemPull];
        @try {
            [self cancelTracking];
        } @catch (NSException *ignored) {
        }
    }
}

- (void)releaseSystemPull {
    [_systemPull removeTarget:self action:@selector(handleSystemPull:)];
    _systemPull = nil;
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
    if (_state != DSStageStateOverlay) DSDiagnosticsRecord(@"SpringBoard: stage on screen");
    _state = DSStageStateOverlay;
    _window.hidden = NO;
    [self takeKeyWindow];
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
        if (!self.hasHostedApp) [self preparePickerForSearchKeyboard];
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
    [self takeKeyWindow];
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

    _ignoreSystemPullUntil = CFAbsoluteTimeGetCurrent() + 0.6;
    [self restoreHostLayout];
    [_picker dismissKeyboard];
    [[DSKeyboardHost sharedHost] keyboardIsNoLongerOnScreen];
    [_container setLiftOffset:0.0];
    void (^layout)(void) = ^{
        self->_container.frame = [self stageFrameForState:DSStageStateClosed];
        self->_container.cornerRadius = [self cornerRadiusForState:DSStageStateOverlay];
    };
    void (^finish)(void) = ^{
        self->_state = DSStageStateMinimized;
        [self giveBackKeyWindow];
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

// The same place the pull lands, reachable without the pull.
- (void)openStageAnimated:(BOOL)animated {
    if (!_activated) {
        DSDiagnosticsRecord(@"SpringBoard: asked to open the stage before it was ready");
        return;
    }
    if (_state == DSStageStateOverlay || _state == DSStageStateSplit) {
        DSDiagnosticsRecord(@"SpringBoard: asked to open the stage, it is already open");
        return;
    }
    if (_state != DSStageStateMinimized) {
        NSString *refusal = [self reasonStageCannotActivate];
        if (refusal) {
            DSDiagnosticsRecordFormat(@"SpringBoard: asked to open the stage, refused because %@", refusal);
            return;
        }
    }
    DSDiagnosticsRecord(@"SpringBoard: opening the stage");

    if (!self.hasHostedApp) {
        [_picker resetScrollPosition];
        [self showPickerImmediately];
    }
    [self enterStateOverlayAnimated:animated];
}

- (void)closeStageAnimated:(BOOL)animated {
    _ignoreSystemPullUntil = CFAbsoluteTimeGetCurrent() + 0.6;
    [self cancelAutoKill];
    [self restoreHostLayout];
    [_picker dismissKeyboard];
    [[DSKeyboardHost sharedHost] keyboardIsNoLongerOnScreen];

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
        [self->_container setLiftOffset:0.0];
        self->_container.cornerRadius = [self cornerRadiusForState:DSStageStateOverlay];
        self->_container.frame = [self stageFrameForState:DSStageStateClosed];
        self->_openAppIcon.alpha = 0.0;
        [self giveBackKeyWindow];
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
    [self forgetStagedAppKeyboard];
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

    // Carried on the notification as well, so an app that the sandbox keeps away
    // from the file above can still recognise itself and hook nothing when it is
    // not the one being hosted.
    static int token = NOTIFY_TOKEN_INVALID;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_check(kDSStageGeometryNotification, &token);
    });
    if (token != NOTIFY_TOKEN_INVALID) {
        notify_set_state(token, active ? (DSIdentifierHash(identifier) | kDSStageStateActiveBit) : 0);
    }

    notify_post(kDSStageGeometryNotification);
}

#pragma mark - Stage content

- (void)layoutStageForState:(DSStageState)state {
    CGRect frame = [self stageFrameForState:state];
    _container.frame = frame;
    // The card itself stays its usual size. The app's view is allowed to continue
    // below it only as a masked keyboard band, never as a taller stage.
    [_container setClipsContents:YES];
    if (!_sceneHost.isHosting) return;

    CGRect window = CGRectOffset(frame, 0.0, -_container.liftOffset);
    if (_typingKeys > 0.0) {
        window = [self fullWidthHostFrameForCard:window];
    }
    [_sceneHost setStageFrame:window safeAreaInsets:[self stageSafeAreaInsets]];
    [self placeHostViewInCardOrOnDisplay];
    [self publishStageStateForBundleIdentifier:_sceneHost.bundleIdentifier frame:window active:YES];
}

// While typing the hosted app has to live on the display, not inside the card:
// the card is only as tall as the overlay, and the keyboard is drawn in the
// extra height below it. Masked to a rounded card plus a square keyboard so it
// cannot read as one stretched stage.
- (void)placeHostViewInCardOrOnDisplay {
    UIView *hostView = _sceneHost.hostView;
    if (!hostView) return;

    UIView *root = _window.rootViewController.view;
    CGRect card = _container.frame;
    BOOL typing = _typingKeys > 0.0 && self.isStageVisible;

    if (typing) {
        CGRect app = [self fullWidthHostFrameForCard:card];
        if (hostView.superview != root) {
            [root insertSubview:hostView belowSubview:_container];
        }
        hostView.clipsToBounds = NO;
        hostView.transform = CGAffineTransformIdentity;
        hostView.frame = app;
        CGRect cardInHost = CGRectMake(CGRectGetMinX(card),
                                       0.0,
                                       CGRectGetWidth(card),
                                       CGRectGetHeight(card));
        [self maskHostView:hostView
                cardInHost:cardInHost
                    radius:_container.cornerRadius
            keyboardHeight:_typingKeys];
        _container.passThroughToHost = YES;
    } else {
        hostView.layer.mask = nil;
        hostView.clipsToBounds = YES;
        _container.passThroughToHost = NO;
        if (hostView.superview != _container.contentView) {
            [_container.contentView insertSubview:hostView atIndex:0];
        }
        hostView.frame = _container.contentView.bounds;
    }
}

- (void)maskHostView:(UIView *)hostView
          cardInHost:(CGRect)cardInHost
              radius:(CGFloat)radius
      keyboardHeight:(CGFloat)keyboardHeight {
    CGRect bounds = hostView.bounds;
    if (CGRectIsEmpty(bounds) || CGRectGetHeight(cardInHost) < 1.0) {
        hostView.layer.mask = nil;
        return;
    }
    CGFloat hostWidth = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    CGFloat cardHeight = CGRectGetHeight(cardInHost);
    CGFloat keys = MAX(keyboardHeight, 0.0);
    CGFloat keyboardTop = keys > 1.0 ? height - keys : height;

    UIBezierPath *path = [UIBezierPath bezierPath];
    CGRect cardVisible = CGRectMake(CGRectGetMinX(cardInHost),
                                    CGRectGetMinY(cardInHost),
                                    CGRectGetWidth(cardInHost),
                                    MIN(cardHeight, height));
    [path appendPath:[UIBezierPath bezierPathWithRoundedRect:cardVisible
                                           byRoundingCorners:(UIRectCornerTopLeft | UIRectCornerTopRight |
                                                              UIRectCornerBottomLeft | UIRectCornerBottomRight)
                                                 cornerRadii:CGSizeMake(radius, radius)]];
    if (keys > 1.0 && keyboardTop >= 0.0 && keyboardTop < height) {
        [path appendPath:[UIBezierPath bezierPathWithRect:CGRectMake(0.0, keyboardTop, hostWidth, keys)]];
    }
    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.frame = bounds;
    mask.path = path.CGPath;
    hostView.layer.mask = mask;
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
    if (!_sceneHost.isHosting) {
        [[DSKeyboardHost sharedHost] standDown];
        [self preparePickerForSearchKeyboard];
    }
}

- (void)appPickerNeedsKeyWindowForSearch:(DSAppPickerViewController *)picker {
    [self preparePickerForSearchKeyboard];
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
    if (entry.bundleIdentifier.length == 0) {
        DSDiagnosticsRecord(@"SpringBoard: a plate was tapped with no app behind it");
        return;
    }
    [_picker dismissKeyboard];
    DSPreferences *preferences = [DSPreferences sharedPreferences];
    if ([preferences isApplicationDisabled:entry.bundleIdentifier]) {
        DSDiagnosticsRecordFormat(@"SpringBoard: %@ is switched off in its own settings, so it was not opened",
                                  entry.bundleIdentifier);
        return;
    }

    // Swap out whatever was already on the stage.
    if (_sceneHost && ![_sceneHost.bundleIdentifier isEqualToString:entry.bundleIdentifier]) {
        DSSceneHost *previous = _sceneHost;
        _sceneHost = nil;
        [self forgetStagedAppKeyboard];
        [previous relinquishKeepingBackgrounded:[preferences backgroundsOnMinimize:previous.bundleIdentifier]];
    }

    // Remembered before anything is launched: if the app turns out to need opening
    // for real, this is who has to be put back in front afterwards.
    SBApplication *wasInFront = [self frontApplication];
    _bundleIdentifierToRestoreInFront =
        [wasInFront.bundleIdentifier isEqualToString:entry.bundleIdentifier] ? nil : wasInFront.bundleIdentifier;

    [preferences noteApplicationOpened:entry.bundleIdentifier];
    [self publishStageStateForBundleIdentifier:entry.bundleIdentifier
                                        frame:[self stageFrameForState:_state == DSStageStateSplit ? DSStageStateSplit : DSStageStateOverlay]
                                       active:YES];
    [self presentLaunchPlaceholderForEntry:entry];

    DSSceneHost *host = _sceneHost ?: [[DSSceneHost alloc] initWithBundleIdentifier:entry.bundleIdentifier];
    _sceneHost = host;
    // SpringBoard's app view has to belong to a view controller to know which way up
    // the app should be, and the stage window's own is the one it will live in.
    host.parentViewController = _window.rootViewController;

    DSDiagnosticsRecordFormat(@"SpringBoard: putting %@ on the stage", entry.bundleIdentifier);
    // Before the app arrives, not after: the card is asked whether it may draw the
    // keyboard layer the first time the app's scene is laid out, and once it has said
    // yes the keyboard is in the card for as long as the app is.
    [[DSKeyboardHost sharedHost] takeOverKeyboardForApplication:entry.bundleIdentifier stageWindow:_window];

    __weak __typeof(self) weakSelf = self;
    [host prepareWithCompletion:^(BOOL ready) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!ready || strongSelf->_sceneHost != host) {
            DSDiagnosticsRecordFormat(@"SpringBoard: %@ did not make it onto the stage, back to the picker",
                                      host.bundleIdentifier);
            strongSelf->_bundleIdentifierToRestoreInFront = nil;
            [strongSelf dismissLaunchPlaceholder];
            if (strongSelf->_sceneHost == host) {
                strongSelf->_sceneHost = nil;
                // The app was told it was on the stage before it was asked for, so
                // it has to be told otherwise now, and anything already done to its
                // scene has to be undone. An app left believing it is staged runs
                // portrait locked with no status bar wherever it is opened next.
                [strongSelf publishStageStateForBundleIdentifier:nil frame:CGRectZero active:NO];
                [host relinquishKeepingBackgrounded:NO];
            }
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
        DSDiagnosticsRecordFormat(@"SpringBoard: %@ was ready but handed over no view", _sceneHost.bundleIdentifier);
        _bundleIdentifierToRestoreInFront = nil;
        [self dismissLaunchPlaceholder];
        return;
    }
    DSDiagnosticsRecordFormat(@"SpringBoard: %@ is on the stage", _sceneHost.bundleIdentifier);

    _picker.view.hidden = YES;
    _picker.view.alpha = 1.0;
    [_container setBackdropHidden:YES];
    hostView.frame = _container.contentView.bounds;
    [_container.contentView insertSubview:hostView atIndex:0];
    [_sceneHost noteHostViewAttached];

    [self layoutStageForState:_state == DSStageStateSplit ? DSStageStateSplit : DSStageStateOverlay];
    [self applyStageRotation];
    [[DSKeyboardHost sharedHost] noteStagedAppScene:_sceneHost.hostedScene];
    [self updateHomeAffordance];
    [self returnFrontToWhereItWas];

    UIView *placeholder = _launchPlaceholder;
    _launchPlaceholder = nil;
    [UIView animateWithDuration:0.3 animations:^{
        placeholder.alpha = 0.0;
    } completion:^(BOOL finished) {
        [placeholder removeFromSuperview];
    }];
}

// Only ever needed when an app refused to start in the background and had to be
// opened for real, which makes it the front app for as long as it takes to get its
// layer into the card. Putting the screen back where it was is the difference
// between the stage opening an app and the stage throwing the user into one.
- (void)returnFrontToWhereItWas {
    NSString *previous = _bundleIdentifierToRestoreInFront;
    _bundleIdentifierToRestoreInFront = nil;
    if (!_sceneHost.tookOverForegroundLaunch) return;

    SpringBoard *springBoard = (SpringBoard *)UIApplication.sharedApplication;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            if (previous.length > 0 &&
                [springBoard respondsToSelector:@selector(launchApplicationWithIdentifier:suspended:)]) {
                DSDiagnosticsRecordFormat(@"SpringBoard: putting %@ back in front", previous);
                [springBoard launchApplicationWithIdentifier:previous suspended:NO];
                return;
            }
            for (NSString *name in @[ @"_simulateHomeButtonPress", @"clickedMenuButton" ]) {
                SEL selector = NSSelectorFromString(name);
                id target = [springBoard respondsToSelector:selector] ? springBoard : nil;
                if (!target) {
                    Class controller = objc_getClass("SBUIController");
                    id shared = [controller respondsToSelector:@selector(sharedInstance)]
                        ? ((id (*)(id, SEL))objc_msgSend)(controller, @selector(sharedInstance))
                        : nil;
                    target = [shared respondsToSelector:selector] ? shared : nil;
                }
                if (!target) continue;
                DSDiagnosticsRecord(@"SpringBoard: back to the home screen behind the stage");
                ((void (*)(id, SEL))objc_msgSend)(target, selector);
                return;
            }
        } @catch (NSException *exception) {
        }
    });
}

// Back to the picker, app stays alive.
- (void)exitToPickerAnimated:(BOOL)animated {
    if (!self.hasHostedApp) return;
    DSSceneHost *host = _sceneHost;
    _sceneHost = nil;
    _stageQuarterTurns = 0;
    _ignoreSystemPullUntil = CFAbsoluteTimeGetCurrent() + 0.6;

    UIView *hostView = host.hostView;
    [self forgetStagedAppKeyboard];
    [_container setClipsContents:YES];
    [_container setBackdropHidden:NO];
    _container.hostingApp = NO;

    // The picker is on screen before the hosted view starts to leave. A black frame
    // was the picker still hidden while the app view had already gone, or the
    // window itself having been closed by a put-away that was meant to be this.
    [self showPickerImmediately];
    [_container.contentView bringSubviewToFront:_picker.view];
    [_picker.view layoutIfNeeded];

    if (!hostView.superview) {
        [self publishStageStateForBundleIdentifier:nil frame:CGRectZero active:NO];
        [host relinquishKeepingBackgrounded:[[DSPreferences sharedPreferences] backgroundsOnMinimize:host.bundleIdentifier]];
        [self scheduleAutoKillForHost:host];
        [self updateHomeAffordance];
        return;
    }

    // The picker stays on top for the whole crossfade. Pulling the hosted view in
    // front of it was a black card: the app layer covered the recents list until it
    // had already faded out.
    hostView.layer.mask = nil;
    hostView.clipsToBounds = NO;
    hostView.transform = CGAffineTransformIdentity;
    hostView.layer.cornerCurve = kCACornerCurveContinuous;
    hostView.layer.masksToBounds = YES;

    void (^layout)(void) = ^{
        hostView.transform = CGAffineTransformMakeScale(0.92, 0.92);
        hostView.alpha = 0.0;
        self->_picker.view.alpha = 1.0;
    };
    void (^finish)(void) = ^{
        hostView.transform = CGAffineTransformIdentity;
        hostView.alpha = 1.0;
        hostView.layer.cornerRadius = 0.0;
        hostView.layer.masksToBounds = NO;
        [hostView removeFromSuperview];
        [self publishStageStateForBundleIdentifier:nil frame:CGRectZero active:NO];
        [host relinquishKeepingBackgrounded:[[DSPreferences sharedPreferences] backgroundsOnMinimize:host.bundleIdentifier]];
        [self showPickerImmediately];
        [self scheduleAutoKillForHost:host];
        [self updateHomeAffordance];
    };

    if (animated) {
        [UIView animateWithDuration:0.22
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
    [self forgetStagedAppKeyboard];
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
    // The card's own home indicator and the corner grip only exist while there is an
    // app to leave and a card the app is in the way of.
    _container.hostingApp = self.hasHostedApp;

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

// There is deliberately nothing here that tells SpringBoard which scene the keyboard
// belongs to. 1.4.0 asked the keyboard focus coordinator to point the keyboard at the
// staged app's scene, which is what broke typing in the picker: once an app had been
// staged, SpringBoard's keyboard belonged to that app's scene and the stage's own
// search field could not raise one again. Neither side needs the help. The picker's
// field is SpringBoard's own, in a window the stage makes key; a text field inside the
// staged app is asked for by that app, in its own process, the way it would be if the
// app were full screen.

#pragma mark - In-stage gestures

// Far enough for the direction of a drag from the corner to mean anything.
static const CGFloat kDSCornerIntentTravel = 14.0;

// How far a drag from the bottom right corner has gone into the card. Left and up both
// count, and together, because that is the shape of the movement a thumb on that corner
// makes: the finger rolls inward and upward at once.
static CGFloat DSInwardTravel(CGPoint translation) {
    return MAX(-translation.x, 0.0) + MAX(-translation.y, 0.0);
}

typedef NS_ENUM(NSInteger, DSCornerIntent) {
    DSCornerIntentUndecided = 0,
    DSCornerIntentPutAway,
    DSCornerIntentLeaveApp,
};

// One recogniser drives all three in-stage gestures; which one it is depends on
// where the drag started.
- (void)handleStagePan:(UIPanGestureRecognizer *)recognizer {
    static BOOL fromTop = NO;
    static BOOL fromCorner = NO;
    static BOOL fromEdge = NO;
    // A drag from the corner is two gestures until it has gone far enough to say which.
    // Down and away puts the card back in the corner it came from; inward, across the
    // card, drops the app and brings the list back.
    //
    // Leaving an app used to be a swipe up from the bottom of the card, which is the
    // same movement in the same place as the home gesture, ten points below. The card
    // could refuse the home gesture inside itself but not below itself, and a thumb
    // going up from the bottom of a card inset from the bottom of the display starts
    // below it about as often as not: the phone went home instead. Sideways from the
    // corner is nothing else's gesture.
    static NSInteger cornerIntent = DSCornerIntentUndecided;

    CGPoint location = [recognizer locationInView:_container];
    CGPoint translation = [recognizer translationInView:_window];
    CGPoint velocity = [recognizer velocityInView:_window];
    CGRect resting = [self stageFrameForState:_state == DSStageStateSplit ? DSStageStateSplit : DSStageStateOverlay];

    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan: {
            CGPoint start = CGPointMake(location.x - translation.x, location.y - translation.y);

            // The card is about to be moved by hand, so it stops being held up out
            // of the keyboard's way first: its own frame has to mean what it says
            // for the rest of this drag.
            [_picker dismissKeyboard];
            [_container setLiftOffset:0.0];

            fromCorner = self.hasHostedApp && CGRectContainsPoint([_container cornerGripRect], start);
            fromEdge = self.hasHostedApp && CGRectContainsPoint([_container edgeGripRect], start) && !fromCorner;
            cornerIntent = DSCornerIntentUndecided;
            fromTop = !fromCorner && !fromEdge && CGRectContainsPoint([_container dragAffordanceRect], start);
            // Whether a drag inside the card was picked up at all, and what it was taken
            // for. "It will not let me go back" has two completely different causes -
            // the gesture never starting, and it starting and being read as something
            // else - and they are indistinguishable from the outside.
            DSDiagnosticsRecordFormat(@"SpringBoard: a drag began in the card at %@ - %@",
                                      NSStringFromCGPoint(start),
                                      fromEdge ? @"the edge grip"
                                               : (fromCorner ? @"the grip"
                                                             : (fromTop ? @"the grabber" : @"neither grip")));
            break;
        }
        case UIGestureRecognizerStateChanged: {
            if (fromCorner || fromEdge) {
                if (cornerIntent == DSCornerIntentUndecided &&
                    hypot(translation.x, translation.y) > kDSCornerIntentTravel) {
                    // While an app is on the stage the corner only leaves the app. Putting
                    // the card away from that grip closed the window and left a black
                    // screen - the log caught a downward drag of 71 points from the
                    // corner being read as put-away, then the stage having to be opened
                    // again. The grabber at the top is still how the card is put away.
                    cornerIntent = self.hasHostedApp ? DSCornerIntentLeaveApp
                                                     : DSCornerIntentPutAway;
                }

                if (cornerIntent == DSCornerIntentLeaveApp) {
                    // The app shrinks under the finger, the way it shrinks on the way
                    // out, so the drag says what letting go will do.
                    CGFloat travel = fromEdge ? MAX(-translation.x, 0.0) : DSInwardTravel(translation);
                    travel = MIN(travel, 160.0);
                    _sceneHost.hostView.transform = CGAffineTransformMakeScale(1.0 - travel / 900.0,
                                                                              1.0 - travel / 900.0);
                } else {
                    CGFloat offset = MAX(translation.y, 0.0);
                    _container.frame = CGRectOffset(resting, 0, offset);
                    _container.alpha = 1.0 - MIN(offset / (CGRectGetHeight(resting) * 0.6), 0.75);
                }
            } else if (fromTop) {
                _container.frame = CGRectOffset(resting, 0, MAX(translation.y, -70.0));
            }
            break;
        }
        case UIGestureRecognizerStateEnded: {
            if (fromCorner || fromEdge) {
                DSDiagnosticsRecordFormat(@"SpringBoard: the drag from the %@ went %@ and was read as %@",
                                          fromEdge ? @"edge" : @"corner",
                                          NSStringFromCGPoint(translation),
                                          cornerIntent == DSCornerIntentLeaveApp ? @"leaving the app"
                                                                                : @"putting the card away");
            }

            if ((fromCorner || fromEdge) && cornerIntent == DSCornerIntentLeaveApp) {
                BOOL leave = NO;
                if (fromEdge) {
                    leave = (-translation.x > 55.0 && -translation.x > fabs(translation.y) * 1.1) ||
                            (-velocity.x > 650.0 && -velocity.x > fabs(velocity.y));
                } else {
                    leave = DSInwardTravel(translation) > 48.0 ||
                            (DSInwardTravel(translation) > 32.0 && DSInwardTravel(velocity) > 500.0);
                }
                if (leave) {
                    [self exitToPickerAnimated:YES];
                } else {
                    [UIView animateWithDuration:0.25 animations:^{
                        self->_sceneHost.hostView.transform = CGAffineTransformIdentity;
                    }];
                }
            } else if (fromCorner || fromEdge) {
                if (translation.y > CGRectGetHeight(resting) * 0.2 || velocity.y > 700.0) {
                    [self closeStageAnimated:YES];
                } else {
                    [self snapBackTo:resting];
                }
            } else if (fromTop) {
                if (translation.y > CGRectGetHeight(resting) * 0.38 || velocity.y > 950.0) {
                    [self minimizeAnimated:YES];
                } else if (translation.y < -40.0 && _state == DSStageStateOverlay) {
                    [self enterStateSplitAnimated:YES];
                } else if (translation.y > 40.0 && _state == DSStageStateSplit) {
                    [self enterStateOverlayAnimated:YES];
                } else {
                    [self snapBackTo:resting];
                }
            }
            fromTop = fromCorner = fromEdge = NO;
            cornerIntent = DSCornerIntentUndecided;
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            // Something else took the touch: the system's own gestures are refused
            // inside the card, so if this keeps happening it is a gesture that is not
            // going through the manager the stage hooks.
            if (fromCorner || fromEdge || fromTop) {
                DSDiagnosticsRecord(@"SpringBoard: a drag inside the card was taken away before it finished");
            }
            if (cornerIntent == DSCornerIntentLeaveApp) {
                _sceneHost.hostView.transform = CGAffineTransformIdentity;
            } else if (fromTop || fromCorner || fromEdge) {
                [self snapBackTo:resting];
            }
            fromTop = fromCorner = fromEdge = NO;
            cornerIntent = DSCornerIntentUndecided;
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
    return CGRectUnion([_container cornerGripRect], [_container edgeGripRect]);
}

#pragma mark - External events

- (void)noteSceneDestroyedForBundleIdentifier:(NSString *)bundleIdentifier {
    if (!_sceneHost || ![_sceneHost.bundleIdentifier isEqualToString:bundleIdentifier]) return;
    DSDiagnosticsRecordFormat(@"SpringBoard: %@ went away while it was on the stage", bundleIdentifier);
    _sceneHost = nil;
    [self forgetStagedAppKeyboard];
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
        DSDiagnosticsRecord(@"SpringBoard: showing the walkthrough");
        [DSIntroViewController presentIntro];
    });
}

@end
