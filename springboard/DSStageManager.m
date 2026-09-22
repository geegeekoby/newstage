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
#import "DSDiagnostics.h"
#import "DSKeyboardVisibility.h"
#import "DSStageLayout.h"
#import "DSStageShelfView.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>

// Fraction of the screen height the finger has to travel for the pull to reach
// the stage's resting size; a little further than that commits to Split View.
static const CGFloat kDSPullTravelRatio = 0.42;
static const CGFloat kDSCancelProgress = 0.14;
static const CGFloat kDSSplitProgress = 0.82;
static const CGFloat kDSFlickVelocity = -1150.0;

#pragma mark - Staged app keyboard

@protocol DSStagedKeyboardTarget <NSObject>
- (void)stagedKeyboardInsertText:(NSString *)text;
- (void)stagedKeyboardDeleteBackward;
- (void)stagedKeyboardDidEnd;
@end

// The same kind of field the picker search uses. It lives in the stage window,
// so UIKit draws the same keyboard. Keystrokes are handed to the hosted app.
@interface DSStagedKeyboardField : UITextField <UITextFieldDelegate>
@property (nonatomic, weak) id<DSStagedKeyboardTarget> keyTarget;
// Set while the stage window is reclaiming the key. Resigning then is not the
// user leaving the field.
@property (nonatomic, assign) BOOL suppressEnd;
// Set while the delegate is already forwarding this edit, so insertText and
// deleteBackward do not send the same key twice.
@property (nonatomic, assign) BOOL forwardingEdit;
@end

@implementation DSStagedKeyboardField

- (BOOL)hasText {
    return YES;
}

- (void)insertText:(NSString *)text {
    if (self.forwardingEdit || text.length == 0) return;
    if ([self.keyTarget respondsToSelector:@selector(stagedKeyboardInsertText:)]) {
        [self.keyTarget stagedKeyboardInsertText:text];
    }
}

- (void)deleteBackward {
    if (self.forwardingEdit) return;
    if ([self.keyTarget respondsToSelector:@selector(stagedKeyboardDeleteBackward)]) {
        [self.keyTarget stagedKeyboardDeleteBackward];
    }
}

// Letters go to the field editor, which asks the delegate. They never arrive
// at insertText:, which is why the log showed deletes and no letters.
- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string {
    (void)textField;
    self.forwardingEdit = YES;
    if (string.length > 0) {
        if ([self.keyTarget respondsToSelector:@selector(stagedKeyboardInsertText:)]) {
            [self.keyTarget stagedKeyboardInsertText:string];
        }
    } else if (range.length > 0) {
        NSUInteger count = MIN(range.length, (NSUInteger)20);
        for (NSUInteger index = 0; index < count; index++) {
            if ([self.keyTarget respondsToSelector:@selector(stagedKeyboardDeleteBackward)]) {
                [self.keyTarget stagedKeyboardDeleteBackward];
            }
        }
    }
    self.forwardingEdit = NO;
    // Rejecting the letter makes the keyboard leave this field and type
    // somewhere else. The field is off screen. The letter is also forwarded.
    return YES;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    (void)textField;
    if ([self.keyTarget respondsToSelector:@selector(stagedKeyboardInsertText:)]) {
        [self.keyTarget stagedKeyboardInsertText:@"\n"];
    }
    return NO;
}

- (BOOL)resignFirstResponder {
    BOOL resigned = [super resignFirstResponder];
    if (resigned && !self.suppressEnd && [self.keyTarget respondsToSelector:@selector(stagedKeyboardDidEnd)]) {
        [self.keyTarget stagedKeyboardDidEnd];
    }
    return resigned;
}

@end

static int DSKeyboardInputStateToken = NOTIFY_TOKEN_INVALID;

static void DSPostKeyboardInputState(uint32_t seq, BOOL isDelete, UTF32Char code) {
    if (DSKeyboardInputStateToken == NOTIFY_TOKEN_INVALID) {
        notify_register_check(kDSKeyboardInputNotification, &DSKeyboardInputStateToken);
    }
    if (DSKeyboardInputStateToken != NOTIFY_TOKEN_INVALID) {
        uint64_t state = seq;
        if (isDelete) state |= (1ULL << 32);
        else state |= ((uint64_t)code & 0x1FFFFF) << 33;
        notify_set_state(DSKeyboardInputStateToken, state);
    }
    notify_post(kDSKeyboardInputNotification);
}

static NSArray<NSNumber *> *DSUTF32Scalars(NSString *text) {
    if (text.length == 0) return @[];
    NSMutableArray<NSNumber *> *scalars = [NSMutableArray array];
    NSUInteger index = 0;
    while (index < text.length) {
        unichar unit = [text characterAtIndex:index];
        index++;
        UTF32Char code = unit;
        if (CFStringIsSurrogateHighCharacter(unit) && index < text.length) {
            unichar low = [text characterAtIndex:index];
            if (CFStringIsSurrogateLowCharacter(low)) {
                code = CFStringGetLongCharacterForSurrogatePair(unit, low);
                index++;
            }
        }
        [scalars addObject:@(code)];
    }
    return scalars;
}

static void DSEnqueueStagedKey(NSString *op, NSString *text) {
    if (op.length == 0) return;
    BOOL isDelete = [op isEqualToString:@"delete"];
    NSArray<NSNumber *> *scalars = isDelete ? @[] : DSUTF32Scalars(text);
    NSInteger count = isDelete ? 1 : MAX((NSInteger)scalars.count, 1);
    NSInteger seq = 0;
    @synchronized ([DSStagedKeyboardField class]) {
        NSMutableDictionary *root = [([NSDictionary dictionaryWithContentsOfFile:kDSKeyboardInputPath] ?: @{}) mutableCopy];
        NSMutableArray *ops = [root[@"ops"] mutableCopy] ?: [NSMutableArray array];
        seq = [root[@"seq"] integerValue] + count;
        [ops addObject:@{ @"seq" : @(seq), @"op" : op, @"text" : text ?: @"" }];
        if (ops.count > 40) {
            [ops removeObjectsInRange:NSMakeRange(0, ops.count - 40)];
        }
        root[@"seq"] = @(seq);
        root[@"ops"] = ops;
        [root writeToFile:kDSKeyboardInputPath atomically:YES];
    }
    if (isDelete || scalars.count == 0) {
        DSPostKeyboardInputState((uint32_t)seq, YES, 0);
        return;
    }
    NSInteger first = seq - (NSInteger)scalars.count + 1;
    for (NSUInteger index = 0; index < scalars.count; index++) {
        DSPostKeyboardInputState((uint32_t)(first + (NSInteger)index), NO, (UTF32Char)scalars[index].unsignedIntValue);
    }
}

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

@interface DSStageManager () <DSGestureControllerDelegate, DSAppPickerDelegate, DSStagedKeyboardTarget>
@end

@implementation DSStageManager {
    DSStageWindow *_window;
    DSStageContainerView *_container;
    DSStageContainerView *_topContainer;
    DSAppPickerViewController *_picker;
    DSAppPickerViewController *_topPicker;
    DSGestureController *_gesture;
    DSSceneHost *_sceneHost;
    DSSceneHost *_topSceneHost;

    NSInteger _stackSlotCount;
    NSInteger _keyboardLiftSlot;
    // Which half of the display each card occupies once two stages are open.
    // 0 = bottom, 1 = top. The hosted app stays inside its own card.
    NSInteger _primaryHalf;
    NSInteger _secondHalf;
    // Parked cards are off the bottom of the screen with their app still hosted.
    // Minimize never tears an app down.
    BOOL _primaryParked;
    BOOL _secondParked;
    UIEdgeInsets _lockedScreenInsets;
    BOOL _lockedScreenInsetsReady;
    UIPanGestureRecognizer *_topDragPan;

    UIView *_hostSnapshot;
    UIView *_hostBackdrop;
    UIView *_splitCornerMask;
    UIImageView *_openAppIcon;
    DSStageShelfView *_shelf;
    UILabel *_keyboardDebugLabel;
    NSString *_keyboardDebugApp;
    NSString *_keyboardDebugSpringBoard;
    NSString *_keyboardDebugSearch;
    DSLaunchPlaceholderView *_launchPlaceholder;
    DSLaunchPlaceholderView *_topLaunchPlaceholder;

    NSString *_splitHostBundleIdentifier;
    NSString *_bundleIdentifierToRestoreInFront;
    BOOL _notedKeyboardOnce;
    BOOL _notedStrayKeyboard;
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
    BOOL _overlaySettling;
    // -1 unless a picker search field is the one being edited. Opening a second
    // picker must not count as searching, or that card lifts before anyone types.
    NSInteger _searchSlot;
    NSInteger _pickerSearchEnsureGeneration;
    BOOL _ensuringPickerSearchKeyboard;
    // The hosted app's card while it is using the picker search keyboard.
    NSInteger _stagedKeyboardSlot;
    UITextField *_stagedKeyboardField;
    NSInteger _stagedKeyboardEnsureGeneration;
    BOOL _suppressStagedKeyboardEnd;
    // Set only when the app or a minimize asked the keyboard to go away.
    // A resign without this is the home screen taking the key.
    BOOL _stagedKeyboardWantsHide;
    NSInteger _stagedKeyboardReassertCount;
    NSInteger _presentGeneration;
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
        _searchSlot = -1;
        _stagedKeyboardSlot = -1;
    }
    return self;
}

#pragma mark - Lifecycle

- (void)activate {
    if (_activated) return;
    _activated = YES;

    // The previous boot's log is what made the missing keyboard impossible to
    // read. This file is only the current SpringBoard start from here on.
    DSDiagnosticsBeginSession(@"log refreshed after respring");

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
    [self noteSearchKeyboardDebug:[self searchKeyboardDebugLine:@"boot" attempt:-1 picker:nil]];

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

    _stackSlotCount = 1;
    _container.stackAddHandler = ^{
        [weakSelf addStackSlotAnimated];
    };
    __weak DSStageContainerView *weakCard = _container;
    _container.minimizeHandler = ^{
        [weakSelf minimizeIndividualCard:weakCard];
    };

    _shelf = [[DSStageShelfView alloc] initWithFrame:root.bounds];
    _shelf.willOpenHandler = ^{
        [weakSelf refreshShelf];
    };
    _shelf.halfHandler = ^(NSInteger half) {
        [weakSelf beginStageOnHalf:half];
    };
    _shelf.halfHoldHandler = ^(NSInteger half) {
        [weakSelf returnHalfToPicker:half];
    };
    [root addSubview:_shelf];

    [self applyAppearance];
    [self refreshShelf];
    // The cards stay off screen until a stage is open. The window itself stays
    // up so the edge notch can be tapped with nothing staged.
    _window.hidden = NO;
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
    if (!_window) {
        [self noteSearchKeyboardDebug:@"takeKey window=none"];
        return;
    }
    // A window left on a background scene after respring reports itself key and
    // still never shows a keyboard. Move it first, then ask again.
    BOOL movedScene = [_window attachToForegroundSceneIfNeeded];
    if (movedScene) {
        DSDiagnosticsRecord(@"SpringBoard: moved the stage window onto the foreground scene");
    }
    // After a respring SpringBoard takes the real key window back, and this
    // window keeps saying it is key. makeKeyAndVisible then does nothing, the
    // search field edits, and UIKit never asks for a keyboard.
    BOOL applicationKey = DSWindowIsApplicationKey(_window);
    if (applicationKey && !movedScene) {
        [self noteSearchKeyboardDebug:[self searchKeyboardDebugLine:@"takeKey already" attempt:-1 picker:nil]];
        return;
    }
    UIWindow *other = DSCompetingKeyWindow(_window);
    if (other) {
        if (!_windowBeforeStage) _windowBeforeStage = other;
        DSDiagnosticsRecordFormat(@"SpringBoard: taking key from %@ on %@",
                                  NSStringFromClass(other.class),
                                  other.windowScene == _window.windowScene ? @"this scene" : @"its scene");
        [other resignKeyWindow];
    }
    // makeKeyAndVisible does nothing while this window already says it is key.
    if (_window.isKeyWindow) {
        [_window resignKeyWindow];
    }

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
        [self noteSearchKeyboardDebug:[self searchKeyboardDebugLine:_window.isKeyWindow ? @"takeKey ok" : @"takeKey failed"
                                                            attempt:-1
                                                             picker:nil]];
        if (!_window.isKeyWindow) {
            DSDiagnosticsRecord(@"SpringBoard: the stage window would not become key, so nothing can be typed");
        }
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: could not take the key window - %@", exception.reason ?: @"?");
    }
}

- (void)giveBackKeyWindow {
    if (_searchSlot >= 0) {
        [self noteSearchKeyboardDebug:[self searchKeyboardDebugLine:@"give key back during search" attempt:-1 picker:nil]];
    }
    UIWindow *previous = _windowBeforeStage;
    _windowBeforeStage = nil;
    if (!_window.isKeyWindow) return;
    @try {
        [previous makeKeyWindow];
    } @catch (NSException *exception) {
    }
}

// The picker is SpringBoard's own UI, so its search field needs this window to be
// key. A staged app types in its own process: making this window key then is what
// stole the keyboard from Messenger and left search unable to type after an app
// had been staged.
- (void)preparePickerForSearchKeyboard {
    // A hosted app types through SpringBoard's keyboard. Making this window key
    // while that app is up is what took the keys away from it.
    if (_sceneHost.isHosting || _topSceneHost.isHosting) {
        [self giveBackKeyWindow];
        return;
    }
    _notedStrayKeyboard = NO;
    [self takeKeyWindow];

    CGRect keys = DSVisibleKeyboardFrameOnScreen();
    if (!CGRectIsNull(keys)) {
        [self noteKeyboardFrame:keys source:@"SpringBoard" duration:0.25];
        return;
    }

    _notedKeyboardOnce = NO;
    _keyboardFrame = CGRectZero;
    [_container setLiftOffset:0.0];
    if (_topContainer) [_topContainer setLiftOffset:0.0];
}

// Two sources, one layout: UIKit notifications for SpringBoard's own keyboard
// (the search field) and the arbiter for staged apps. The card keeps its size and
// only lifts above the keys — picker and hosted app use the same policy.
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

    static int requestToken = NOTIFY_TOKEN_INVALID;
    static dispatch_once_t once;
    __weak __typeof(self) weakSelf = self;
    dispatch_once(&once, ^{
        notify_register_dispatch(kDSKeyboardRequestNotification, &requestToken, dispatch_get_main_queue(), ^(int token) {
            uint64_t state = 0;
            notify_get_state(token, &state);
            [weakSelf noteStagedAppKeyboardRequest:state];
        });
    });
}

- (void)keyboardWillShow:(NSNotification *)notification {
    if (_searchSlot >= 0) {
        CGRect keyboard = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
        [self noteSearchKeyboardDebug:[NSString stringWithFormat:@"UIKit willShow %@", NSStringFromCGRect(keyboard)]];
    }
    if (![self isShowingAppPicker] && _stagedKeyboardSlot < 0) return;
    [self keyboardFrameWillChange:notification];
}

- (void)keyboardFrameWillChange:(NSNotification *)notification {
    CGRect keyboard = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    [self noteKeyboardFrame:keyboard
                    source:@"SpringBoard"
                  duration:[notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue]];
}

- (void)keyboardWillHide:(NSNotification *)notification {
    if (_searchSlot >= 0) {
        [self noteSearchKeyboardDebug:@"UIKit willHide"];
    }
    if ([self isShowingAppPicker] || _stagedKeyboardSlot >= 0) _notedKeyboardOnce = NO;
    [self noteKeyboardFrame:CGRectZero
                    source:@"SpringBoard"
                  duration:[notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue]];
}

- (void)keyboardOnScreen:(BOOL)onScreen frame:(CGRect)frame source:(NSString *)source {
    // Picker search owns this window's keyboard. Do not retarget it.
    if (_searchSlot >= 0) return;
    if ([self isHostingBundleIdentifier:source]) {
        if (onScreen) [self showStagedKeyboardLikePickerForBundle:source];
        return;
    }
    if (_stagedKeyboardSlot >= 0) return;
    [self noteKeyboardFrame:onScreen ? frame : CGRectZero
                    source:source.length > 0 ? source : @"an app"
                  duration:0.25];
    if (!onScreen) return;
    [self giveBackKeyWindow];
}

- (NSInteger)slotForHostedBundle:(NSString *)bundle {
    if (bundle.length == 0) return -1;
    if (_sceneHost.isHosting && [_sceneHost.bundleIdentifier isEqualToString:bundle]) return 0;
    if (_topSceneHost.isHosting && [_topSceneHost.bundleIdentifier isEqualToString:bundle]) return 1;
    return -1;
}

- (void)ensureStagedKeyboardField {
    if (_stagedKeyboardField) return;
    DSStagedKeyboardField *field = [[DSStagedKeyboardField alloc] initWithFrame:CGRectMake(0, -80, 2, 2)];
    field.keyTarget = self;
    field.alpha = 0.02;
    field.delegate = field;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.spellCheckingType = UITextSpellCheckingTypeNo;
    field.smartQuotesType = UITextSmartQuotesTypeNo;
    field.smartDashesType = UITextSmartDashesTypeNo;
    field.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
    field.returnKeyType = UIReturnKeyDefault;
    UITextInputAssistantItem *assistant = field.inputAssistantItem;
    assistant.leadingBarButtonGroups = @[];
    assistant.trailingBarButtonGroups = @[];
    field.accessibilityElementsHidden = YES;
    _stagedKeyboardField = field;
}

// The picker search keyboard, for a hosted app. The app's own keyboard is not
// started. This window takes the real key, then this field edits on that turn.
- (void)driveStagedKeyboardForBundle:(NSString *)bundle
                                slot:(NSInteger)slot
                          generation:(NSInteger)generation
                             attempt:(NSInteger)attempt {
    if (generation != _stagedKeyboardEnsureGeneration || _searchSlot >= 0) return;
    if ([self slotForHostedBundle:bundle] != slot) return;
    [self ensureStagedKeyboardField];
    _stagedKeyboardField.keyboardAppearance = _container.darkMode ? UIKeyboardAppearanceDark : UIKeyboardAppearanceLight;
    UIView *root = _window.rootViewController.view;
    if (_stagedKeyboardField.superview != root) {
        [root addSubview:_stagedKeyboardField];
    }
    _stagedKeyboardSlot = slot;
    DSStagedKeyboardField *field = (DSStagedKeyboardField *)_stagedKeyboardField;
    field.suppressEnd = YES;
    _suppressStagedKeyboardEnd = YES;
    [self takeKeyWindow];
    _suppressStagedKeyboardEnd = NO;
    field.suppressEnd = NO;
    if (!DSWindowIsApplicationKey(_window)) {
        if (attempt == 0) {
            DSDiagnosticsRecordFormat(@"SpringBoard: %@ is waiting until the stage window is the key window", bundle);
        }
        return;
    }
    CGRect visibleKeys = DSVisibleKeyboardFrameOnScreen();
    BOOL keysVisible = !CGRectIsNull(visibleKeys) && CGRectGetHeight(visibleKeys) >= kDSKeyboardPresentHeight;
    // Resigning a field that is already taking keys moves the input somewhere else.
    if (field.isFirstResponder && attempt >= 2 && !keysVisible) {
        field.suppressEnd = YES;
        [field resignFirstResponder];
        field.suppressEnd = NO;
    }
    if (!field.isFirstResponder) {
        [field becomeFirstResponder];
    }
    if (attempt == 0) {
        DSDiagnosticsRecordFormat(@"SpringBoard: %@ is using the picker search keyboard on %@",
                                  bundle, slot == 1 ? @"the top stage" : @"the bottom stage");
        DSDiagnosticsRecordFormat(@"SpringBoard: picker field fr=%d key=%d",
                                  field.isFirstResponder, DSWindowIsApplicationKey(_window));
    }
}

- (void)ensureStagedKeyboardForBundle:(NSString *)bundle
                                 slot:(NSInteger)slot
                           generation:(NSInteger)generation
                              attempt:(NSInteger)attempt {
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.16 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (generation != strongSelf->_stagedKeyboardEnsureGeneration || strongSelf->_searchSlot >= 0) return;
        if ([strongSelf slotForHostedBundle:bundle] != slot) return;
        CGRect keys = DSVisibleKeyboardFrameOnScreen();
        if (!CGRectIsNull(keys) && CGRectGetHeight(keys) >= kDSKeyboardPresentHeight &&
            DSWindowIsApplicationKey(strongSelf->_window)) {
            DSDiagnosticsRecordFormat(@"SpringBoard: %@ picker keyboard visible %@", bundle, NSStringFromCGRect(keys));
            return;
        }
        if (attempt >= 5) {
            DSDiagnosticsRecordFormat(@"SpringBoard: %@ picker keyboard did not appear", bundle);
            return;
        }
        [strongSelf driveStagedKeyboardForBundle:bundle slot:slot generation:generation attempt:attempt + 1];
        [strongSelf ensureStagedKeyboardForBundle:bundle slot:slot generation:generation attempt:attempt + 1];
    });
}

- (void)showStagedKeyboardLikePickerForBundle:(NSString *)bundle {
    if (_searchSlot >= 0) return;
    if (_state == DSStageStateMinimized || _state == DSStageStateClosed) return;
    NSInteger slot = [self slotForHostedBundle:bundle];
    if (slot < 0) return;
    if ([self cardIsParked:[self containerForSlot:slot]]) return;
    _stagedKeyboardWantsHide = NO;
    _stagedKeyboardReassertCount = 0;
    // The app may already have been running when it was staged, so it missed
    // the first post. Wake it again at the moment a text field is tapped.
    notify_post(kDSStageGeometryNotification);
    notify_post(kDSStagePeerNotification);
    CGRect keys = DSVisibleKeyboardFrameOnScreen();
    if (_stagedKeyboardField.isFirstResponder && _stagedKeyboardSlot == slot &&
        DSWindowIsApplicationKey(_window) &&
        !CGRectIsNull(keys) && CGRectGetHeight(keys) >= kDSKeyboardPresentHeight) {
        return;
    }
    NSInteger generation = ++_stagedKeyboardEnsureGeneration;
    [self driveStagedKeyboardForBundle:bundle slot:slot generation:generation attempt:0];
    [self ensureStagedKeyboardForBundle:bundle slot:slot generation:generation attempt:0];
}

- (void)hideStagedKeyboardLikePicker {
    _stagedKeyboardWantsHide = YES;
    _stagedKeyboardEnsureGeneration++;
    if (!_stagedKeyboardField.isFirstResponder) {
        _stagedKeyboardSlot = -1;
        return;
    }
    [_stagedKeyboardField resignFirstResponder];
}

- (void)keepStagedKeyboardField {
    if (_stagedKeyboardWantsHide || _searchSlot >= 0 || _stagedKeyboardSlot < 0) return;
    if (_state == DSStageStateMinimized || _state == DSStageStateClosed) return;
    if ([self cardIsParked:[self containerForSlot:_stagedKeyboardSlot]]) return;
    if (DSWindowIsApplicationKey(_window) && _stagedKeyboardField.isFirstResponder) {
        _stagedKeyboardReassertCount = 0;
        return;
    }
    if (_stagedKeyboardReassertCount >= 6) {
        DSDiagnosticsRecord(@"SpringBoard: staged keyboard left the field");
        return;
    }
    _stagedKeyboardReassertCount++;
    DSStagedKeyboardField *field = (DSStagedKeyboardField *)_stagedKeyboardField;
    field.suppressEnd = YES;
    _suppressStagedKeyboardEnd = YES;
    [self takeKeyWindow];
    _suppressStagedKeyboardEnd = NO;
    field.suppressEnd = NO;
    if (DSWindowIsApplicationKey(_window) && !field.isFirstResponder) {
        [field becomeFirstResponder];
    }
    DSDiagnosticsRecordFormat(@"SpringBoard: staged keyboard stayed on the same field fr=%d key=%d",
                              field.isFirstResponder,
                              DSWindowIsApplicationKey(_window));
}

- (void)noteStagedAppKeyboardRequest:(uint64_t)state {
    BOOL show = (state & kDSStageStateActiveBit) != 0;
    NSString *bundle = [self bundleForKeyboardHash:(uint32_t)state];
    if (![self isHostingBundleIdentifier:bundle]) return;
    if (_searchSlot >= 0) return;
    DSDiagnosticsRecordFormat(@"SpringBoard: %@ asked for the picker keyboard to %@",
                              bundle, show ? @"show" : @"hide");
    if (show) [self showStagedKeyboardLikePickerForBundle:bundle];
    else [self hideStagedKeyboardLikePicker];
}

- (void)stagedKeyboardInsertText:(NSString *)text {
    _stagedKeyboardReassertCount = 0;
    DSDiagnosticsRecordFormat(@"SpringBoard: staged key insert len=%lu", (unsigned long)text.length);
    DSEnqueueStagedKey(@"insert", text);
}

- (void)stagedKeyboardDeleteBackward {
    _stagedKeyboardReassertCount = 0;
    DSDiagnosticsRecord(@"SpringBoard: staged key delete");
    DSEnqueueStagedKey(@"delete", @"");
}

- (void)stagedKeyboardDidEnd {
    if (_suppressStagedKeyboardEnd) return;
    BOOL stageOpen = _state != DSStageStateMinimized && _state != DSStageStateClosed;
    if (!_stagedKeyboardWantsHide && _searchSlot < 0 && _stagedKeyboardSlot >= 0 && stageOpen) {
        __weak __typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf keepStagedKeyboardField];
        });
        return;
    }
    _stagedKeyboardSlot = -1;
    if (_searchSlot >= 0) return;
    if (_sceneHost.isHosting || _topSceneHost.isHosting) {
        [self giveBackKeyWindow];
    }
}

- (BOOL)isHostingBundleIdentifier:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0) return NO;
    if (_sceneHost.isHosting && [_sceneHost.bundleIdentifier isEqualToString:bundleIdentifier]) return YES;
    if (_topSceneHost.isHosting && [_topSceneHost.bundleIdentifier isEqualToString:bundleIdentifier]) return YES;
    return NO;
}

// While an app is on the stage, the arbiter still hears keyboards from Spotlight and
// from other processes behind the card. Only the staged app (or the picker on SpringBoard)
// may move the card.
- (BOOL)keyboardSourceAffectsLayout:(NSString *)source keyboard:(CGRect)keyboard {
    BOOL anyHost = _sceneHost.isHosting || _topSceneHost.isHosting;
    if (!anyHost) return YES;

    NSString *staged = _sceneHost.bundleIdentifier;
    if (staged.length > 0 && [source isEqualToString:staged]) return YES;
    NSString *topStaged = _topSceneHost.bundleIdentifier;
    if (topStaged.length > 0 && [source isEqualToString:topStaged]) return YES;

    if ([source isEqualToString:@"SpringBoard"]) {
        if ([self isShowingAppPicker] || _searchSlot >= 0 || _stagedKeyboardSlot >= 0) return YES;
        // Search can end before this hide arrives. Still drop a lift that
        // belongs to a picker, and leave a hosted app's card where it is.
        if (CGRectIsEmpty(keyboard)) {
            NSInteger slot = _keyboardLiftSlot;
            if (![self sceneHostForSlot:slot].isHosting && [self liftOffsetForSlot:slot] > 0.5) return YES;
        }
        return NO;
    }

    if (CGRectIsEmpty(keyboard)) {
        return staged.length > 0 && [source isEqualToString:staged];
    }
    if (source.length == 0) return YES;
    return NO;
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

// Keyboards often arrive as a short frame first (243pt) before the suggestion bar
// settles (301pt). Lifting for the first report leaves the card sitting on the keys.
- (CGRect)keyboardFrameForLift:(CGRect)keyboard {
    if (CGRectIsEmpty(keyboard)) return keyboard;
    CGRect screen = [self screenBounds];
    CGFloat keys = CGRectGetHeight(keyboard);
    // The picker keyboard is 301pt. A 346pt frame is the shortcut bar flashing
    // over that keyboard, and lifting for it shoves the card.
    if (keys < kDSKeyboardPresentHeight || keys > CGRectGetHeight(screen) * 0.6 || keys > 301.0) {
        keys = 301.0;
    } else {
        keys = MAX(keys, 301.0);
    }
    return CGRectMake(0.0, CGRectGetMaxY(screen) - keys, CGRectGetWidth(screen), keys);
}

// The arbiter reports the staged app's keyboard in stages; the on-screen UIKeyboard view
// is sometimes ahead of it. Prefer whichever frame needs more lift so the card clears
// the keys before the user types into the bottom of the app.
- (CGRect)keyboardFrameForHostedApp:(CGRect)reported {
    CGRect merged = reported;
    CGRect visible = DSVisibleKeyboardFrameOnScreen();
    if (CGRectIsNull(visible) || CGRectIsEmpty(visible)) return merged;

    visible = [self keyboardFrameOnDisplay:visible];
    if (CGRectGetHeight(visible) < kDSKeyboardPresentHeight) return merged;
    visible = [self keyboardFrameForLift:visible];

    if (CGRectIsEmpty(merged)) return visible;
    if (CGRectGetMinY(visible) < CGRectGetMinY(merged) - 0.5) return visible;
    if (CGRectGetHeight(visible) > CGRectGetHeight(merged) + 0.5) return visible;
    return merged;
}

// One place for both, and the card's only answer to a keyboard: move up out of its way.
- (void)noteKeyboardFrame:(CGRect)keyboard source:(NSString *)source duration:(NSTimeInterval)duration {
    CGRect screen = [self screenBounds];
    keyboard = [self keyboardFrameOnDisplay:keyboard];
    if (CGRectGetHeight(keyboard) < kDSKeyboardPresentHeight ||
        CGRectGetMinY(keyboard) >= CGRectGetMaxY(screen)) {
        keyboard = CGRectZero;
    }

    // A staged app's keyboard going down must not cancel a picker search that
    // just took the screen. The search field's own hide still clears the lift.
    if (CGRectIsEmpty(keyboard) && (_searchSlot >= 0 || _stagedKeyboardSlot >= 0) &&
        ![source isEqualToString:@"SpringBoard"]) {
        return;
    }

    // A single card on the top half already sits above the keyboard.
    if (_stackSlotCount < kDSMaxStackSlots && _primaryHalf != 0) {
        keyboard = CGRectZero;
    }

    NSInteger liftSlot = [self slotOwningKeyboardSource:source];
    DSStageContainerView *liftCard = [self containerForSlot:liftSlot];
    if (!liftCard || [self cardIsParked:liftCard]) {
        keyboard = CGRectZero;
        liftSlot = 0;
    }
    NSString *ownerBundle = [self sceneHostForSlot:liftSlot].bundleIdentifier;
    NSString *otherBundle = nil;
    if (_stackSlotCount >= kDSMaxStackSlots) {
        otherBundle = [self sceneHostForSlot:liftSlot == 0 ? 1 : 0].bundleIdentifier;
    }
    _keyboardLiftSlot = liftSlot;
    BOOL fromEitherStage = [source isEqualToString:ownerBundle] ||
                           (otherBundle.length > 0 && [source isEqualToString:otherBundle]);
    if (ownerBundle.length > 0 && source.length > 0 && !fromEitherStage &&
        ![source isEqualToString:@"SpringBoard"]) {
        keyboard = CGRectZero;
    }
    if ((_sceneHost.isHosting && [source isEqualToString:_sceneHost.bundleIdentifier]) ||
        (_topSceneHost.isHosting && [source isEqualToString:_topSceneHost.bundleIdentifier])) {
        if (!CGRectIsEmpty(keyboard)) {
            keyboard = [self keyboardFrameForHostedApp:keyboard];
        }
    }

    if (![self keyboardSourceAffectsLayout:source keyboard:keyboard]) {
        if (!_notedStrayKeyboard && !CGRectIsEmpty(keyboard)) {
            _notedStrayKeyboard = YES;
            DSDiagnosticsRecordFormat(@"SpringBoard: ignored a keyboard from %@ while %@ is on the stage",
                                      source.length > 0 ? source : @"?",
                                      _sceneHost.bundleIdentifier);
        }
        return;
    }

    if (!CGRectIsEmpty(keyboard)) {
        keyboard = [self keyboardFrameForLift:keyboard];
    }

    BOOL unchanged = CGRectEqualToRect(keyboard, _keyboardFrame);
    if (unchanged) {
        // The frame did not move but something else cleared the lift underneath it -
        // the overlay open path calling preparePickerForSearchKeyboard after the first
        // keyboardWillShow is the usual case.
        if (CGRectIsEmpty(keyboard)) return;
        DSStageState layoutState = _state == DSStageStateSplit ? DSStageStateSplit : DSStageStateOverlay;
        CGRect resting = [self restingFrameForKeyboardLiftSlot:_keyboardLiftSlot state:layoutState];
        CGFloat overlap = CGRectGetMaxY(resting) - CGRectGetMinY(keyboard) + kDSStageInset;
        CGFloat wanted = MAX(overlap, 0.0);
        NSInteger otherSlot = _keyboardLiftSlot == 0 ? 1 : 0;
        BOOL otherDown = _stackSlotCount < kDSMaxStackSlots || [self liftOffsetForSlot:otherSlot] < 0.5;
        if (fabs([self liftOffsetForSlot:_keyboardLiftSlot] - wanted) < 0.5 && otherDown) return;
    } else {
        _keyboardFrame = keyboard;
    }

    if (!_notedKeyboardOnce && !CGRectIsEmpty(keyboard)) {
        _notedKeyboardOnce = YES;
        DSDiagnosticsRecordFormat(@"SpringBoard: %@ put a keyboard up at %@ (the display is %@)",
                                  source, NSStringFromCGRect(keyboard), NSStringFromCGRect(screen));
    }

    if (!self.isStageVisible) return;

    if (_sceneHost.isHosting && !_notedStrayKeyboard && !CGRectIsEmpty(keyboard) &&
        ![source isEqualToString:@"SpringBoard"] &&
        ![source isEqualToString:_sceneHost.bundleIdentifier]) {
        _notedStrayKeyboard = YES;
        DSDiagnosticsRecordFormat(@"SpringBoard: a keyboard came up for %@ while %@ is on the stage",
                                  source, _sceneHost.bundleIdentifier);
    }

    DSStageState layoutState = _state == DSStageStateSplit ? DSStageStateSplit : DSStageStateOverlay;
    CGRect resting = [self restingFrameForKeyboardLiftSlot:_keyboardLiftSlot state:layoutState];
    CGFloat overlap = CGRectIsEmpty(keyboard) ? 0.0
                                             : CGRectGetMaxY(resting) - CGRectGetMinY(keyboard) + kDSStageInset;
    [self liftCardBy:MAX(overlap, 0.0) slot:_keyboardLiftSlot duration:duration];
}

- (NSInteger)slotOnBottomHalf {
    if (_stackSlotCount < kDSMaxStackSlots) return 0;
    return _primaryHalf == 0 ? 0 : 1;
}

// The card the keyboard belongs to. The other card is not moved.
- (NSInteger)slotOwningKeyboardSource:(NSString *)source {
    if (_sceneHost.bundleIdentifier.length > 0 && [source isEqualToString:_sceneHost.bundleIdentifier]) {
        return 0;
    }
    if (_topSceneHost.bundleIdentifier.length > 0 && [source isEqualToString:_topSceneHost.bundleIdentifier]) {
        return 1;
    }
    // The field the user is typing in. Otherwise a keyboard from SpringBoard
    // would lift the other card.
    if ([source isEqualToString:@"SpringBoard"] && _searchSlot >= 0) return _searchSlot;
    if ([source isEqualToString:@"SpringBoard"] && _stagedKeyboardSlot >= 0) return _stagedKeyboardSlot;
    if (_stackSlotCount >= kDSMaxStackSlots) {
        if (!_sceneHost.isHosting && _topSceneHost.isHosting) return 0;
        if (_sceneHost.isHosting && !_topSceneHost.isHosting) return 1;
        return [self slotOnBottomHalf];
    }
    return [self slotOnBottomHalf];
}

- (CGRect)restingFrameForKeyboardLiftSlot:(NSInteger)slot state:(DSStageState)state {
    if (_stackSlotCount >= kDSMaxStackSlots && state == DSStageStateOverlay) {
        NSInteger half = slot == 1 ? _secondHalf : _primaryHalf;
        return [self frameForHalf:half state:state];
    }
    return [self restingStageFrameForState:state];
}

- (CGFloat)liftOffsetForSlot:(NSInteger)slot {
    DSStageContainerView *card = [self containerForSlot:slot];
    return card ? card.liftOffset : 0.0;
}

- (CGFloat)maxLiftForSlot:(NSInteger)slot state:(DSStageState)state {
    CGRect resting = [self restingFrameForKeyboardLiftSlot:slot state:state];
    // The card may slide up until it meets the top margin. A top-half card is
    // already there, so its cap is zero and it stays put.
    return MAX(CGRectGetMinY(resting) - kDSStageKeyboardHeadroom, 0.0);
}

- (void)restoreCardStackingOrder {
    if (_stackSlotCount < kDSMaxStackSlots || !_topContainer || !_container) return;
    UIView *upper = [self containerOnHalf:1];
    UIView *lower = [self containerOnHalf:0];
    if (!upper || !lower || upper == lower || !upper.superview) return;
    [upper.superview insertSubview:upper aboveSubview:lower];
    [self bringShelfToFront];
    if (_keyboardDebugLabel.superview) {
        [_keyboardDebugLabel.superview bringSubviewToFront:_keyboardDebugLabel];
    }
}

- (void)liftCardBy:(CGFloat)offset duration:(NSTimeInterval)duration {
    [self liftCardBy:offset slot:_keyboardLiftSlot duration:duration];
}

- (void)liftCardBy:(CGFloat)offset slot:(NSInteger)slot duration:(NSTimeInterval)duration {
    // Only the card the keyboard covers moves, and it stays on screen. Moving the
    // other card by the same amount pushes the top stage off the top of the phone.
    DSStageState layoutState = _state == DSStageStateSplit ? DSStageStateSplit : DSStageStateOverlay;
    DSStageContainerView *card = [self containerForSlot:slot];
    if (!card || [self cardIsParked:card]) return;

    offset = MIN(MAX(offset, 0.0), [self maxLiftForSlot:slot state:layoutState]);

    DSStageContainerView *other = nil;
    if (_stackSlotCount >= kDSMaxStackSlots) {
        other = [self containerForSlot:slot == 0 ? 1 : 0];
        if (other && [self cardIsParked:other]) other = nil;
    }

    BOOL cardAlready = fabs(offset - card.liftOffset) < 0.5;
    BOOL otherAlready = !other || other.liftOffset < 0.5;
    if (cardAlready && otherAlready) return;

    void (^lift)(void) = ^{
        // Do not tell the app a new size. That transaction blanks it.
        // The moving card comes to the front so it can overlap the other card.
        [card setLiftOffset:offset];
        if (other) [other setLiftOffset:0.0];
        if (offset > 0.5 && card.superview) {
            [card.superview bringSubviewToFront:card];
            [self bringShelfToFront];
            if (self->_keyboardDebugLabel.superview) {
                [self->_keyboardDebugLabel.superview bringSubviewToFront:self->_keyboardDebugLabel];
            }
        } else {
            [self restoreCardStackingOrder];
        }
    };
    if (duration > 0.0) {
        [UIView animateWithDuration:duration animations:lift];
    } else {
        lift();
    }
    if (!cardAlready) {
        DSDiagnosticsRecordFormat(@"SpringBoard: lifted stack slot %ld by %.0f", (long)slot, offset);
    }
    [self refreshKeyboardDebugLabel];
}

- (void)pushLiftedGeometryToApp {
    DSStageState layoutState = _state == DSStageStateSplit ? DSStageStateSplit : DSStageStateOverlay;
    [self layoutHostedAppInSlot:0 state:layoutState];
    if (_stackSlotCount >= kDSMaxStackSlots) {
        [self layoutHostedAppInSlot:1 state:layoutState];
    }
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
    if (_topContainer) _topContainer.darkMode = dark;
    if (_topPicker) _topPicker.darkMode = dark;
    _shelf.darkMode = dark;
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
    return [self restingStageFrameForState:state];
}

// One size for every stage, taken from the screen and never changed. Top and
// bottom are the same width and height. Overlay and Split View use that same
// card; the keyboard only slides it.
- (UIEdgeInsets)lockedScreenInsets {
    if (_lockedScreenInsetsReady) return _lockedScreenInsets;
    UIEdgeInsets safe = [self screenSafeAreaInsets];
    if (safe.top < 1.0) safe.top = 47.0;
    if (safe.bottom < 1.0) safe.bottom = 34.0;
    _lockedScreenInsets = safe;
    _lockedScreenInsetsReady = YES;
    return _lockedScreenInsets;
}

- (CGRect)fixedHalfFrame:(NSInteger)half {
    // Each card is one half of the screen, pulled in a few points so a hairline
    // of wallpaper shows around it. Both cards are the same size.
    CGRect screen = [self screenBounds];
    CGFloat inset = kDSStackCardInset;
    CGFloat gap = kDSStackSlotGap;
    CGFloat width = CGRectGetWidth(screen) - inset * 2.0;
    CGFloat height = CGRectGetHeight(screen);
    CGFloat slotHeight = floor((height - inset * 2.0 - gap) * 0.5);
    if (half == 1) {
        return CGRectMake(inset, inset, width, slotHeight);
    }
    return CGRectMake(inset, inset + slotHeight + gap, width, slotHeight);
}

- (CGFloat)stageCardCornerRadius {
    return MAX([self displayCornerRadius] - kDSStackCardInset, 20.0);
}

- (CGRect)restingStageFrameForState:(DSStageState)state {
    CGRect bottom = [self fixedHalfFrame:0];
    if (state == DSStageStateClosed || state == DSStageStateMinimized) {
        bottom.origin.y = CGRectGetHeight([self screenBounds]);
    }
    return bottom;
}

- (CGFloat)cornerRadiusForState:(DSStageState)state {
    (void)state;
    return [self stageCardCornerRadius];
}

// Whatever keyboard was up went away with the app that owned it.
- (void)forgetStagedAppKeyboard {
    _keyboardFrame = CGRectZero;
    _keyboardLiftSlot = 0;
    [_container setLiftOffset:0.0];
    if (_topContainer) [_topContainer setLiftOffset:0.0];
    _notedStrayKeyboard = NO;
    _container.passThroughToHost = NO;
    [_container setClipsContents:YES];
    if (self.isStageVisible) {
        [self layoutStageForState:_state == DSStageStateSplit ? DSStageStateSplit : DSStageStateOverlay];
    }
}

- (CGRect)hostFrameForSplit {
    CGRect bounds = [self screenBounds];
    return CGRectMake(0, 0, CGRectGetWidth(bounds), [self splitLine]);
}

- (UIEdgeInsets)stageSafeAreaInsets {
    if (!_sceneHost.isHosting || CGRectIsEmpty(_keyboardFrame)) return UIEdgeInsetsZero;
    if (_stackSlotCount < kDSMaxStackSlots && _primaryHalf != 0) return UIEdgeInsetsZero;

    DSStageState layoutState = _state == DSStageStateSplit ? DSStageStateSplit : DSStageStateOverlay;
    DSStageContainerView *bottomCard = [self containerOnHalf:0];
    CGRect resting = (_stackSlotCount >= kDSMaxStackSlots && layoutState == DSStageStateOverlay)
        ? [self frameForHalf:0 state:layoutState]
        : [self restingStageFrameForState:layoutState];
    CGRect card = CGRectOffset(resting, 0.0, -(bottomCard ? bottomCard.liftOffset : 0.0));
    CGFloat keyboardTop = CGRectGetMinY(_keyboardFrame);
    CGFloat overlap = CGRectGetMaxY(card) - keyboardTop;
    if (overlap <= 1.0) return UIEdgeInsetsZero;

    UIEdgeInsets insets = UIEdgeInsetsZero;
    insets.bottom = overlap + [self screenSafeAreaInsets].bottom;
    return insets;
}

- (UIEdgeInsets)stageSafeAreaInsetsForTopSlot {
    if (!_topSceneHost.isHosting || CGRectIsEmpty(_keyboardFrame)) return UIEdgeInsetsZero;

    DSStageState layoutState = _state == DSStageStateSplit ? DSStageStateSplit : DSStageStateOverlay;
    CGRect resting = [self frameForHalf:1 state:layoutState];
    DSStageContainerView *topCard = [self containerOnHalf:1];
    CGRect card = CGRectOffset(resting, 0.0, -(topCard ? topCard.liftOffset : 0.0));
    CGFloat keyboardTop = CGRectGetMinY(_keyboardFrame);
    CGFloat overlap = CGRectGetMaxY(card) - keyboardTop;
    if (overlap <= 1.0) return UIEdgeInsetsZero;

    UIEdgeInsets insets = UIEdgeInsetsZero;
    insets.bottom = overlap + [self screenSafeAreaInsets].bottom;
    return insets;
}

- (UIEdgeInsets)screenSafeAreaInsets {
    UIEdgeInsets insets = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) {
        insets = UIApplication.sharedApplication.windows.firstObject.safeAreaInsets;
    }
    return insets;
}

- (BOOL)hasHostedApp {
    return _sceneHost != nil || _topSceneHost != nil;
}

#pragma mark - Stack slots

- (void)ensureTopStackInfrastructure {
    if (_topContainer) return;

    UIView *root = _window.rootViewController.view;
    _topContainer = [[DSStageContainerView alloc] initWithFrame:CGRectZero];
    _topContainer.hidden = YES;
    _topContainer.cornerRadius = _container.cornerRadius;
    [root insertSubview:_topContainer aboveSubview:_container];

    _topPicker = [[DSAppPickerViewController alloc] init];
    _topPicker.delegate = self;
    [_window.rootViewController addChildViewController:_topPicker];
    _topPicker.view.frame = _topContainer.contentView.bounds;
    _topPicker.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_topContainer.contentView addSubview:_topPicker.view];
    [_topPicker didMoveToParentViewController:_window.rootViewController];

    _topDragPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleStagePan:)];
    _topDragPan.cancelsTouchesInView = NO;
    _topDragPan.delaysTouchesBegan = NO;
    [_topContainer addGestureRecognizer:_topDragPan];
    [self bringShelfToFront];

    __weak __typeof(self) weakSelf = self;
    __weak DSStageContainerView *weakTop = _topContainer;
    _topContainer.stackAddHandler = ^{
        [weakSelf addStackSlotAnimated];
    };
    _topContainer.minimizeHandler = ^{
        [weakSelf minimizeIndividualCard:weakTop];
    };
}

- (BOOL)cardIsParked:(DSStageContainerView *)card {
    if (card == _topContainer) return _secondParked;
    return _primaryParked;
}

- (void)setParked:(BOOL)parked forCard:(DSStageContainerView *)card {
    if (card == _topContainer) _secondParked = parked;
    else _primaryParked = parked;
}

- (CGRect)offscreenCardFrame {
    CGRect off = [self fixedHalfFrame:0];
    off.origin.y = CGRectGetHeight([self screenBounds]);
    return off;
}

// Where a card sits. Parked, closed and minimized cards are the same size, just
// below the screen, so coming back is a move and not a resize.
- (CGRect)placedFrameForCard:(DSStageContainerView *)card state:(DSStageState)state {
    if ([self cardIsParked:card] || state == DSStageStateClosed || state == DSStageStateMinimized) {
        return [self offscreenCardFrame];
    }
    if (_stackSlotCount <= 1) {
        if (state == DSStageStateSplit || state == DSStageStateOverlay) {
            NSInteger half = (state == DSStageStateSplit) ? 0 : _primaryHalf;
            return [self fixedHalfFrame:half];
        }
        return [self stageFrameForState:state];
    }
    NSInteger half = [self halfForContainer:card];
    if (state == DSStageStateSplit && half != 0) return [self offscreenCardFrame];
    return [self fixedHalfFrame:half];
}

- (CGRect)frameForHalf:(NSInteger)half state:(DSStageState)state {
    (void)state;
    return [self fixedHalfFrame:half];
}

- (NSInteger)halfForContainer:(DSStageContainerView *)card {
    if (card == _topContainer) return _secondHalf;
    return _primaryHalf;
}

- (DSStageContainerView *)containerOnHalf:(NSInteger)half {
    if (_stackSlotCount < kDSMaxStackSlots) {
        return _primaryHalf == half ? _container : nil;
    }
    if (_primaryHalf == half) return _container;
    return _topContainer;
}

- (void)swapStackHalvesAnimated:(BOOL)animated {
    if (_stackSlotCount < kDSMaxStackSlots) return;
    NSInteger previous = _primaryHalf;
    _primaryHalf = _secondHalf;
    _secondHalf = previous;
    [_container setLiftOffset:0.0];
    [_topContainer setLiftOffset:0.0];
    void (^layout)(void) = ^{
        [self layoutAllStackSlotsForState:self->_state];
    };
    if (animated) {
        [UIView animateWithDuration:0.32
                              delay:0
                            options:UIViewAnimationOptionCurveEaseInOut
                         animations:layout
                         completion:nil];
    } else {
        layout();
    }
    DSDiagnosticsRecord(@"SpringBoard: swapped the two stages between top and bottom");
}

- (DSStageContainerView *)containerForSlot:(NSInteger)slot {
    return slot == 0 ? _container : _topContainer;
}

- (DSSceneHost *)sceneHostForSlot:(NSInteger)slot {
    return slot == 0 ? _sceneHost : _topSceneHost;
}

- (NSInteger)slotForPicker:(DSAppPickerViewController *)picker {
    return picker == _topPicker ? 1 : 0;
}

- (void)showFreshBottomStagePicker {
    [_launchPlaceholder removeFromSuperview];
    _launchPlaceholder = nil;

    for (UIView *subview in [_container.contentView.subviews copy]) {
        if (subview != _picker.view) [subview removeFromSuperview];
    }

    [_container setBackdropHidden:NO];
    _container.hostingApp = NO;
    _container.passThroughToHost = NO;
    _picker.view.hidden = NO;
    _picker.view.alpha = 1.0;
    _picker.view.frame = _container.contentView.bounds;
    [_container.contentView bringSubviewToFront:_picker.view];
    [_picker reloadContent];
    [_picker resetScrollPosition];
    [_picker.view layoutIfNeeded];

    [self takeKeyWindow];
    [self preparePickerForSearchKeyboard];
}

- (void)prepareTopSlotForPicker {
    if (!_topContainer || !_topPicker) return;

    [_topLaunchPlaceholder removeFromSuperview];
    _topLaunchPlaceholder = nil;

    if (_topSceneHost.isHosting) return;

    UIView *pickerView = _topPicker.view;
    for (UIView *subview in [_topContainer.contentView.subviews copy]) {
        if (subview != pickerView) [subview removeFromSuperview];
    }

    _topPicker.darkMode = _container.darkMode;
    (void)_topPicker.view;
    [_topPicker reloadContent];
    [_topPicker resetScrollPosition];

    [_topContainer setBackdropHidden:NO];
    pickerView.hidden = NO;
    pickerView.alpha = 1.0;
    pickerView.frame = _topContainer.contentView.bounds;
    if (pickerView.superview != _topContainer.contentView) {
        [_topContainer.contentView addSubview:pickerView];
    }
    [_topContainer.contentView bringSubviewToFront:pickerView];
}

- (void)updateStackChrome {
    BOOL canStack = (_state == DSStageStateOverlay) && _stackSlotCount < kDSMaxStackSlots && self.isStageVisible;
    _container.showsStackAddButton = canStack && _sceneHost.isHosting;
    _container.showsMinimizeButton = self.isStageVisible;
    if (_topContainer) {
        _topContainer.showsStackAddButton = NO;
        _topContainer.showsMinimizeButton = _stackSlotCount >= kDSMaxStackSlots && !_topContainer.hidden;
        _topContainer.hostingApp = _topSceneHost.isHosting;
    }
    _container.hostingApp = _sceneHost.isHosting;
}

- (void)layoutHostedAppInSlot:(NSInteger)slot state:(DSStageState)state {
    DSSceneHost *host = [self sceneHostForSlot:slot];
    DSStageContainerView *card = [self containerForSlot:slot];
    if (!host.isHosting || !card) return;

    CGRect frame = [self fixedHalfFrame:[self halfForContainer:card]];
    CGRect current = host.stageFrame;
    BOOL sameSize = fabs(CGRectGetWidth(current) - CGRectGetWidth(frame)) < 0.5 &&
                    fabs(CGRectGetHeight(current) - CGRectGetHeight(frame)) < 0.5;
    BOOL sameOrigin = fabs(CGRectGetMinX(current) - CGRectGetMinX(frame)) < 0.5 &&
                      fabs(CGRectGetMinY(current) - CGRectGetMinY(frame)) < 0.5;
    card.backgroundColor = UIColor.clearColor;
    [card layoutIfNeeded];
    if (sameSize && sameOrigin) {
        // The scene is already the right size. The view still has to fill the
        // card: the app view controller resets its frame after we leave.
        [host fitHostViewToCard];
        return;
    }
    if (sameSize) {
        // Same card, new half of the screen. Do not run the scene resize
        // transaction; that is what blanks the app.
        [self publishStageStateForBundleIdentifier:host.bundleIdentifier frame:frame active:YES];
        [host fitHostViewToCard];
        return;
    }
    [host setStageFrame:frame safeAreaInsets:UIEdgeInsetsZero];

    UIView *hostView = host.hostView;
    // A view that already has a parent stays there. Moving it between cards is
    // what blanks the app. A view with no parent is one the attach path has
    // not placed yet, and that one may be inserted.
    if (hostView && hostView.superview == nil) {
        [card.contentView insertSubview:hostView atIndex:0];
    }
    [card layoutIfNeeded];
    [host fitHostViewToCard];
    [self publishStageStateForBundleIdentifier:host.bundleIdentifier frame:frame active:YES];
}

// Setting frame while a lift transform is in place flings the card off screen.
// Clear the transform, write the frame, then put the same lift back.
- (void)placeCard:(DSStageContainerView *)card atFrame:(CGRect)frame {
    if (!card) return;
    CGFloat lift = card.liftOffset;
    if (lift > 0.5) {
        [UIView performWithoutAnimation:^{
            [card setLiftOffset:0.0];
        }];
    }
    if (!CGRectEqualToRect(card.frame, frame)) {
        card.frame = frame;
    }
    if (lift > 0.5) {
        [UIView performWithoutAnimation:^{
            [card setLiftOffset:lift];
        }];
    }
}

- (void)layoutAllStackSlotsForState:(DSStageState)state {
    if (_stackSlotCount <= 1) {
        if (state == DSStageStateSplit) _primaryHalf = 0;
        [self placeCard:_container atFrame:[self placedFrameForCard:_container state:state]];
        _container.cornerRadius = [self stageCardCornerRadius];
        if (_topContainer) _topContainer.hidden = YES;
    } else {
        CGFloat radius = [self stageCardCornerRadius];
        [self placeCard:_container atFrame:[self placedFrameForCard:_container state:state]];
        _container.cornerRadius = radius;
        _topContainer.hidden = NO;
        [self placeCard:_topContainer atFrame:[self placedFrameForCard:_topContainer state:state]];
        _topContainer.cornerRadius = radius;
        _picker.view.frame = _container.contentView.bounds;
        _topPicker.view.frame = _topContainer.contentView.bounds;
        if (!_sceneHost.isHosting) {
            [_container setBackdropHidden:NO];
            _picker.view.hidden = NO;
            _picker.view.alpha = 1.0;
            [_container.contentView bringSubviewToFront:_picker.view];
        }
        if (!_topSceneHost.isHosting) {
            [_topContainer setBackdropHidden:NO];
            _topPicker.view.hidden = NO;
            _topPicker.view.alpha = 1.0;
            [_topContainer.contentView bringSubviewToFront:_topPicker.view];
        }
    }

    CGFloat screenHeight = CGRectGetHeight([self screenBounds]);
    CGRect primaryPlaced = [self placedFrameForCard:_container state:state];
    if (!_container.hidden && CGRectGetMinY(primaryPlaced) < screenHeight - 1.0 &&
        CGRectGetMaxY(primaryPlaced) > 1.0) {
        _container.alpha = 1.0;
    }
    if (_topContainer && !_topContainer.hidden && _stackSlotCount >= kDSMaxStackSlots) {
        CGRect topPlaced = [self placedFrameForCard:_topContainer state:state];
        if (CGRectGetMinY(topPlaced) < screenHeight - 1.0 && CGRectGetMaxY(topPlaced) > 1.0) {
            _topContainer.alpha = 1.0;
        }
    }

    [_container setClipsContents:YES];
    _container.passThroughToHost = NO;
    if (_topContainer) {
        [_topContainer setClipsContents:YES];
        _topContainer.passThroughToHost = NO;
    }

    [self updateStackChrome];
    [self layoutHostedAppInSlot:0 state:state];
    [self layoutHostedAppInSlot:1 state:state];
}

- (void)presentPickerOnCard:(DSStageContainerView *)card picker:(DSAppPickerViewController *)picker {
    if (!card || !picker) return;
    picker.darkMode = card.darkMode;
    UIView *pickerView = picker.view;
    for (UIView *subview in [card.contentView.subviews copy]) {
        if (subview == pickerView) continue;
        // Never pull a live app out of its card. That is what blanks it.
        if (subview == _sceneHost.hostView || subview == _topSceneHost.hostView) continue;
        [subview removeFromSuperview];
    }
    card.backgroundColor = [UIColor colorWithWhite:0.11 alpha:1.0];
    card.contentView.backgroundColor = UIColor.clearColor;
    [card setBackdropHidden:NO];
    pickerView.hidden = NO;
    pickerView.alpha = 1.0;
    pickerView.backgroundColor = UIColor.clearColor;
    if (pickerView.superview != card.contentView) {
        [card.contentView addSubview:pickerView];
    }
    pickerView.frame = card.contentView.bounds;
    [card.contentView bringSubviewToFront:pickerView];
    [picker reloadContent];
    [picker resetScrollPosition];
    [pickerView layoutIfNeeded];
}


- (void)relinquishStackHost:(DSSceneHost *)host {
    if (!host) return;
    [self publishStageStateForBundleIdentifier:host.bundleIdentifier frame:CGRectZero active:NO];
    [host relinquishKeepingBackgrounded:[[DSPreferences sharedPreferences] backgroundsOnMinimize:host.bundleIdentifier]];
}

- (void)minimizeIndividualCard:(DSStageContainerView *)card {
    if (!card) return;
    DSSceneHost *host = (card == _topContainer) ? _topSceneHost : _sceneHost;
    if (!host.isHosting) {
        if (_stackSlotCount >= kDSMaxStackSlots && card == _topContainer) {
            [self dropEmptySecondCard];
            return;
        }
        if (_stackSlotCount >= kDSMaxStackSlots && card == _container && _topSceneHost.isHosting) {
            [self promoteSecondCardToPrimary];
            return;
        }
        [self closeStageAnimated:YES];
        return;
    }
    [self parkCard:card animated:YES];
}

// Slide one card away and leave its app hosted. The other card, if it is up, stays
// exactly where it is.
- (void)parkCard:(DSStageContainerView *)card animated:(BOOL)animated {
    if (!card) return;
    [self setParked:YES forCard:card];
    [card setLiftOffset:0.0];
    BOOL otherStillUp = (_stackSlotCount >= kDSMaxStackSlots) &&
                        ((card == _container && !_secondParked && !_topContainer.hidden) ||
                         (card == _topContainer && !_primaryParked));
    DSStageState layoutState = otherStillUp ? DSStageStateOverlay : DSStageStateMinimized;
    void (^layout)(void) = ^{
        [self layoutAllStackSlotsForState:layoutState];
        card.alpha = 1.0;
    };
    void (^finish)(void) = ^{
        NSInteger parkedSlot = (card == self->_topContainer) ? 1 : 0;
        if (self->_stagedKeyboardSlot == parkedSlot) [self hideStagedKeyboardLikePicker];
        if (!otherStillUp) {
            self->_primaryParked = YES;
            self->_secondParked = YES;
            self->_state = DSStageStateMinimized;
            [self giveBackKeyWindow];
            [self updateOpenAppIcon];
            [self scheduleAutoKill];
        }
        [self updateHomeAffordance];
        [self updateStackChrome];
        [self refreshShelf];
        [self bringShelfToFront];
        DSDiagnosticsRecord(@"SpringBoard: minimized a stage without closing its app");
    };
    if (animated) {
        [self animateSpring:layout completion:finish];
    } else {
        layout();
        finish();
    }
}

- (void)dropEmptySecondCard {
    _stackSlotCount = 1;
    _secondParked = NO;
    _topContainer.hidden = YES;
    [UIView animateWithDuration:0.28 animations:^{
        [self layoutAllStackSlotsForState:self->_state];
    }];
    [self refreshShelf];
}

// The empty card was the primary one. The card that still has an app becomes
// primary. The host view stays inside the card it already has.
- (void)promoteSecondCardToPrimary {
    DSStageContainerView *empty = _container;
    DSAppPickerViewController *emptyPicker = _picker;
    UIPanGestureRecognizer *emptyPan = _dragPan;
    _container = _topContainer;
    _picker = _topPicker;
    _dragPan = _topDragPan;
    _topContainer = empty;
    _topPicker = emptyPicker;
    _topDragPan = emptyPan;
    _sceneHost = _topSceneHost;
    _topSceneHost = nil;
    _primaryHalf = _secondHalf;
    _secondHalf = 1;
    _primaryParked = _secondParked;
    _secondParked = NO;
    _stackSlotCount = 1;
    _topContainer.hidden = YES;
    _container.hidden = NO;
    [UIView animateWithDuration:0.28 animations:^{
        [self layoutAllStackSlotsForState:self->_state];
    }];
    [self refreshShelf];
}

- (void)addStackSlotAnimated {
    if (_stackSlotCount >= kDSMaxStackSlots || _state != DSStageStateOverlay) return;
    if (!_sceneHost.isHosting) {
        DSDiagnosticsRecord(@"SpringBoard: + needs an app on the stage first");
        return;
    }

    // The live app stays inside the card it already has. That card moves to the
    // top half. The bottom half opens with the same picker the shelf and the
    // corner pull use.
    _primaryHalf = 1;
    [_container setLiftOffset:0.0];
    if (_topContainer) [_topContainer setLiftOffset:0.0];
    _container.backgroundColor = UIColor.clearColor;
    [self presentPickerOnHalf:0 animated:YES];
    DSDiagnosticsRecordFormat(@"SpringBoard: moved %@ to the top half and opened a new stage below",
                              _sceneHost.bundleIdentifier);
}

- (void)collapseStackKeepingBottomApp:(BOOL)animated {
    if (_stackSlotCount <= 1) return;

    // Closing. Both apps leave. Do not move a host view from one card to the
    // other; that blanks it on the way out.
    if (_topSceneHost) {
        DSSceneHost *top = _topSceneHost;
        _topSceneHost = nil;
        [self relinquishStackHost:top];
    }

    [_topLaunchPlaceholder removeFromSuperview];
    _topLaunchPlaceholder = nil;
    _stackSlotCount = 1;
    _primaryHalf = 0;
    _secondHalf = 1;
    _primaryParked = NO;
    _secondParked = NO;
    _topContainer.hidden = YES;

    void (^layout)(void) = ^{
        [self layoutAllStackSlotsForState:self->_state];
    };
    if (animated) {
        [UIView animateWithDuration:0.22 animations:layout];
    } else {
        layout();
    }
}

- (BOOL)pickerVisibleOnSlot:(NSInteger)slot {
    if (!self.isStageVisible) return NO;
    if (slot == 0) {
        return _picker && !_picker.view.hidden && !_sceneHost.isHosting && ![self cardIsParked:_container];
    }
    if (slot == 1) {
        return _topPicker && _topContainer && !_topContainer.hidden && !_topPicker.view.hidden &&
               !_topSceneHost.isHosting && ![self cardIsParked:_topContainer];
    }
    return NO;
}

- (BOOL)isShowingAppPicker {
    // A second picker sitting beside a hosted app is not "the" picker until
    // the user taps its search field. Treating it as showing the moment it
    // opens lifts that card off the bottom half.
    if (_searchSlot >= 0 && [self pickerVisibleOnSlot:_searchSlot]) return YES;
    if (_sceneHost.isHosting || _topSceneHost.isHosting) return NO;
    return [self pickerVisibleOnSlot:0] || [self pickerVisibleOnSlot:1];
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
    if (_stackSlotCount >= kDSMaxStackSlots && _topContainer && !_topContainer.hidden) {
        CGRect top = CGRectOffset(_topContainer.frame, 0.0, -_topContainer.liftOffset);
        if (CGRectContainsPoint(top, point)) return YES;
    }

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
    // The notch (and its list, while open) is tappable with the stage closed.
    if ([_shelf claimsPoint:point]) return YES;
    if (_state == DSStageStateClosed || _state == DSStageStateMinimized) return NO;

    CGRect card = CGRectOffset(_container.frame, 0.0, -_container.liftOffset);
    if (CGRectContainsPoint(card, point)) return YES;
    if (_stackSlotCount >= kDSMaxStackSlots && _topContainer && !_topContainer.hidden) {
        CGRect top = CGRectOffset(_topContainer.frame, 0.0, -_topContainer.liftOffset);
        if (CGRectContainsPoint(top, point)) return YES;
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
    if (!_activated) return NO;
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
    [_shelf setOpen:NO animated:NO];
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
    } else if (!self.hasHostedApp) {
        // The shelf's empty square uses this same present.
        [self presentPickerOnHalf:0 animated:YES];
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
            [self noteStageWindowIdle];
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
    _primaryParked = NO;
    _secondParked = NO;
    [self cancelAutoKill];
    if (_state != DSStageStateOverlay) DSDiagnosticsRecord(@"SpringBoard: stage on screen");
    _state = DSStageStateOverlay;
    _overlaySettling = animated;
    _window.hidden = NO;
    if (self.hasHostedApp) {
        [self giveBackKeyWindow];
    } else {
        [self takeKeyWindow];
    }
    _openAppIcon.alpha = 0.0;

    [self restoreHostLayout];
    if (self.hasHostedApp) [_sceneHost setForeground:YES];

    void (^layout)(void) = ^{
        // The app behind is untouched in overlay, so the still springs back to
        // full screen before it is thrown away.
        [self animateHostSnapshotToFullScreen];
        [self layoutAllStackSlotsForState:DSStageStateOverlay];
        self->_container.cornerRadius = [self cornerRadiusForState:DSStageStateOverlay];
    };
    void (^finish)(void) = ^{
        self->_overlaySettling = NO;
        [self discardHostSnapshotAnimated:YES];
        [self layoutStageForState:DSStageStateOverlay];
        [self updateHomeAffordance];
        if (!self->_sceneHost.isHosting && !self->_topSceneHost.isHosting) {
            [self presentPickerOnCard:self->_container picker:self->_picker];
            self->_container.alpha = 1.0;
            [self preparePickerForSearchKeyboard];
        }
        [self refreshShelf];
        [self bringShelfToFront];
    };

    if (animated) {
        [self animateSpring:layout completion:finish];
    } else {
        layout();
        finish();
    }
}

- (void)enterStateSplitAnimated:(BOOL)animated {
    // Split keeps every app alive. The card on the top half steps off screen;
    // the one on the bottom stays. Nothing is reparented and nothing is quit.
    if (_stackSlotCount >= kDSMaxStackSlots) {
        _primaryParked = (_primaryHalf == 1);
        _secondParked = (_secondHalf == 1);
    } else {
        _primaryParked = NO;
        _primaryHalf = 0;
    }
    [self cancelAutoKill];
    _state = DSStageStateSplit;
    _window.hidden = NO;
    if (self.hasHostedApp) {
        [self giveBackKeyWindow];
    } else {
        [self takeKeyWindow];
    }
    _openAppIcon.alpha = 0.0;

    if (self.hasHostedApp) [_sceneHost setForeground:YES];
    [self applySplitHostLayout];
    [self updateSplitCornerMask];

    void (^layout)(void) = ^{
        [self animateHostSnapshotIntoSplit];
        [self layoutAllStackSlotsForState:DSStageStateSplit];
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
    [_container setLiftOffset:0.0];
    if (_topContainer) [_topContainer setLiftOffset:0.0];
    _primaryParked = YES;
    _secondParked = YES;
    void (^layout)(void) = ^{
        [self layoutAllStackSlotsForState:DSStageStateMinimized];
        self->_container.alpha = 1.0;
        if (self->_topContainer) self->_topContainer.alpha = 1.0;
    };
    void (^finish)(void) = ^{
        self->_state = DSStageStateMinimized;
        [self giveBackKeyWindow];
        // The app stays hosted. Putting the card away is not closing it.
        [self updateOpenAppIcon];
        [self updateHomeAffordance];
        [self scheduleAutoKill];
        [self refreshShelf];
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
        // Same landing as a tap on the bottom square of the right-edge shelf.
        [self presentPickerOnHalf:0 animated:animated];
        return;
    }
    [self enterStateOverlayAnimated:animated];
}

- (void)closeStageAnimated:(BOOL)animated {
    _ignoreSystemPullUntil = CFAbsoluteTimeGetCurrent() + 0.6;
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
        [self->_container setLiftOffset:0.0];
        self->_container.cornerRadius = [self cornerRadiusForState:DSStageStateOverlay];
        self->_container.frame = [self stageFrameForState:DSStageStateClosed];
        self->_openAppIcon.alpha = 0.0;
        [self giveBackKeyWindow];
        self->_stageQuarterTurns = 0;
        [self teardownStageApp];
        [self noteStageWindowIdle];
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
    [self collapseStackKeepingBottomApp:NO];
    // Corner pull always opens the bottom half. A top stage only stays on top
    // while that stage is still around.
    _primaryHalf = 0;
    _secondHalf = 1;
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
static void DSSetStageNotify(const char *name, NSString *identifier) {
    static int primary = NOTIFY_TOKEN_INVALID;
    static int peer = NOTIFY_TOKEN_INVALID;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_check(kDSStageGeometryNotification, &primary);
        notify_register_check(kDSStagePeerNotification, &peer);
    });
    int token = strcmp(name, kDSStagePeerNotification) == 0 ? peer : primary;
    if (token == NOTIFY_TOKEN_INVALID) return;
    uint64_t value = 0;
    if (identifier.length > 0) value = DSIdentifierHash(identifier) | kDSStageStateActiveBit;
    notify_set_state(token, value);
}

- (void)publishStageStateForBundleIdentifier:(NSString *)identifier frame:(CGRect)frame active:(BOOL)active {
    // Both hosted apps have to be told. Publishing only the last one left the
    // other drawing its own keyboard inside the card.
    NSMutableArray *stages = [NSMutableArray array];
    NSString *bottom = _sceneHost.isHosting ? _sceneHost.bundleIdentifier : nil;
    NSString *top = _topSceneHost.isHosting ? _topSceneHost.bundleIdentifier : nil;
    if (bottom.length) [stages addObject:bottom];
    if (top.length && ![stages containsObject:top]) [stages addObject:top];
    if (!active && identifier.length) [stages removeObject:identifier];
    if (active && identifier.length && ![stages containsObject:identifier]) [stages addObject:identifier];

    // The same file carries the recents list, so merge rather than overwrite.
    NSMutableDictionary *state = [([NSDictionary dictionaryWithContentsOfFile:kDSSharedStatePath] ?: @{}) mutableCopy];
    state[@"stages"] = stages;
    state[@"stage"] = stages.firstObject ?: @"";
    state[@"active"] = @(stages.count > 0);
    state[@"width"] = @(CGRectGetWidth(frame));
    state[@"height"] = @(CGRectGetHeight(frame));
    [state writeToFile:kDSSharedStatePath atomically:YES];

    DSSetStageNotify(kDSStageGeometryNotification, stages.count > 0 ? stages[0] : nil);
    DSSetStageNotify(kDSStagePeerNotification, stages.count > 1 ? stages[1] : nil);
    notify_post(kDSStageGeometryNotification);
    notify_post(kDSStagePeerNotification);
    // A process that starts listening a moment later still has to see this.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        notify_post(kDSStageGeometryNotification);
        notify_post(kDSStagePeerNotification);
    });
}

static NSString *DSSceneActivationName(UISceneActivationState state) {
    switch (state) {
        case UISceneActivationStateUnattached: return @"unattached";
        case UISceneActivationStateForegroundActive: return @"fg-active";
        case UISceneActivationStateForegroundInactive: return @"fg-inactive";
        case UISceneActivationStateBackground: return @"bg";
        default: return @"other";
    }
}

- (NSString *)searchKeyboardDebugLine:(NSString *)event
                              attempt:(NSInteger)attempt
                               picker:(DSAppPickerViewController *)picker {
    UIWindow *window = _window;
    UIWindowScene *winScene = window.windowScene;
    UIWindow *keyWindow = nil;
    NSString *otherName = @"none";
    for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
        if (!candidate.isKeyWindow) continue;
        if (!keyWindow) keyWindow = candidate;
        if (candidate != window && [otherName isEqualToString:@"none"]) {
            otherName = NSStringFromClass(candidate.class);
        }
    }
    if ([otherName isEqualToString:@"none"]) {
        UIWindow *other = DSCompetingKeyWindow(window);
        if (other) otherName = NSStringFromClass(other.class);
    }
    NSMutableArray *scenes = [NSMutableArray array];
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if (![candidate isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *scene = (UIWindowScene *)candidate;
        BOOL main = !scene.screen || scene.screen == UIScreen.mainScreen;
        [scenes addObject:[NSString stringWithFormat:@"%@/%@%@",
                           DSSceneActivationName(scene.activationState),
                           main ? @"main" : @"other",
                           scene == winScene ? @"*" : @""]];
    }
    NSString *sceneList = scenes.count ? [scenes componentsJoinedByString:@","] : @"none";
    CGRect keys = DSVisibleKeyboardFrameOnScreen();
    NSString *keyText = CGRectIsNull(keys) ? @"null" : NSStringFromCGRect(keys);
    NSString *field = picker ? [picker searchEditingDebugSummary] : @"field=n/a";
    NSString *tryText = attempt < 0 ? @"try=-" : [NSString stringWithFormat:@"try=%ld", (long)attempt];
    return [NSString stringWithFormat:@"%@ %@ slot=%ld settle=%d key=%d hid=%d lvl=%.0f matchKey=%d other=%@ winScene=%@ %@ keys=%@ scenes=%@",
            event,
            tryText,
            (long)_searchSlot,
            _overlaySettling,
            window.isKeyWindow,
            window.hidden,
            window.windowLevel,
            keyWindow == window,
            otherName,
            winScene ? DSSceneActivationName(winScene.activationState) : @"none",
            field,
            keyText,
            sceneList];
}

- (void)noteSearchKeyboardDebug:(NSString *)line {
    if (line.length == 0) return;
    _keyboardDebugSearch = line;
    DSDiagnosticsRecord([@"SpringBoard: " stringByAppendingString:line]);
    [self refreshKeyboardDebugLabel];
}

- (void)refreshKeyboardDebugLabel {
    if (!_window) return;
    if (!_keyboardDebugLabel) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.numberOfLines = 10;
        label.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightMedium];
        label.textColor = UIColor.whiteColor;
        label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.78];
        label.userInteractionEnabled = NO;
        label.layer.zPosition = 5000;
        [_window.rootViewController.view addSubview:label];
        _keyboardDebugLabel = label;
    }
    NSString *text = [NSString stringWithFormat:@"%@\n%@\nlift slot0=%.0f slot1=%.0f\n%@",
                      _keyboardDebugApp.length ? _keyboardDebugApp : @"app: (no report yet)",
                      _keyboardDebugSpringBoard.length ? _keyboardDebugSpringBoard : @"SB: (no keyboard event yet)",
                      _container.liftOffset,
                      _topContainer ? _topContainer.liftOffset : 0.0,
                      _keyboardDebugSearch.length ? _keyboardDebugSearch : @"search: (not tapped yet)"];
    _keyboardDebugLabel.text = text;
    CGRect screen = [self screenBounds];
    CGSize fit = [_keyboardDebugLabel sizeThatFits:CGSizeMake(CGRectGetWidth(screen) - 8.0, 200)];
    _keyboardDebugLabel.frame = CGRectMake(4.0, 2.0, CGRectGetWidth(screen) - 8.0, MIN(168.0, ceil(fit.height) + 6.0));
    [_keyboardDebugLabel.superview bringSubviewToFront:_keyboardDebugLabel];
}

- (NSString *)bundleForKeyboardHash:(uint32_t)hash {
    if (hash == 0) return @"?";
    if (DSIdentifierHash(_sceneHost.bundleIdentifier) == hash) return _sceneHost.bundleIdentifier;
    if (DSIdentifierHash(_topSceneHost.bundleIdentifier) == hash) return _topSceneHost.bundleIdentifier;
    return [NSString stringWithFormat:@"hash %u", hash];
}

- (void)noteKeyboardDebugFromApp:(NSString *)line {
    NSString *shown = line;
    NSString *written = [NSString stringWithContentsOfFile:@"/var/mobile/Library/Preferences/com.recreated.dynamicstage.keyboard.txt"
                                                 encoding:NSUTF8StringEncoding
                                                    error:nil];
    if (written.length) shown = written;
    _keyboardDebugApp = shown.length ? [@"app: " stringByAppendingString:shown] : @"app: (empty)";
    DSDiagnosticsRecord(_keyboardDebugApp);
    [self refreshKeyboardDebugLabel];
}

- (void)noteStagedKeyResult:(NSString *)line {
    if (line.length == 0) return;
    _keyboardDebugApp = line;
    DSDiagnosticsRecord(line);
    [self refreshKeyboardDebugLabel];
}

- (void)noteKeyboardDebugFromSpringBoard:(NSString *)line {
    NSString *shown = line.length ? [@"SB: " stringByAppendingString:line] : @"SB: (empty)";
    if ([shown isEqualToString:_keyboardDebugSpringBoard]) return;
    _keyboardDebugSpringBoard = shown;
    DSDiagnosticsRecord(_keyboardDebugSpringBoard);
    [self refreshKeyboardDebugLabel];
}

#pragma mark - Stage content

- (void)layoutStageForState:(DSStageState)state {
    [self layoutAllStackSlotsForState:state];
}

- (void)showPickerImmediately {
    [self presentPickerOnCard:_container picker:_picker];
    [_picker resetScrollPosition];
    [_launchPlaceholder removeFromSuperview];
    _launchPlaceholder = nil;
    if (!_sceneHost.isHosting && !_topSceneHost.isHosting) {
        [self preparePickerForSearchKeyboard];
    }
}

// The user tapped a picker search field. This is the path that shows the
// normal SpringBoard keyboard. It is not run just because a picker appeared.
- (void)appPickerNeedsKeyWindowForSearch:(DSAppPickerViewController *)picker {
    NSInteger slot = [self slotForPicker:picker];
    if ([self sceneHostForSlot:slot].isHosting) {
        [self noteSearchKeyboardDebug:[NSString stringWithFormat:@"search ignored, slot %ld is hosting", (long)slot]];
        return;
    }
    _searchSlot = slot;
    [self noteSearchKeyboardDebug:[self searchKeyboardDebugLine:@"search asked" attempt:0 picker:picker]];
    [self takeKeyWindow];
    if (_ensuringPickerSearchKeyboard) return;
    _ensuringPickerSearchKeyboard = YES;
    NSInteger generation = ++_pickerSearchEnsureGeneration;
    [self ensurePickerSearchKeyboard:picker slot:slot generation:generation attempt:0];
}

// The search field is already the first responder and the window was asked to
// be key. After a respring that request is sometimes lost. Ask again, the same
// way, until the keyboard is actually on screen.
- (void)ensurePickerSearchKeyboard:(DSAppPickerViewController *)picker
                             slot:(NSInteger)slot
                       generation:(NSInteger)generation
                          attempt:(NSInteger)attempt {
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.16 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (generation != strongSelf->_pickerSearchEnsureGeneration || strongSelf->_searchSlot != slot) {
            strongSelf->_ensuringPickerSearchKeyboard = NO;
            [strongSelf noteSearchKeyboardDebug:[NSString stringWithFormat:@"search ensure stopped gen=%ld slot=%ld nowSlot=%ld",
                                                 (long)generation, (long)slot, (long)strongSelf->_searchSlot]];
            return;
        }
        CGRect keys = DSVisibleKeyboardFrameOnScreen();
        if (!CGRectIsNull(keys) && CGRectGetHeight(keys) >= kDSKeyboardPresentHeight) {
            strongSelf->_ensuringPickerSearchKeyboard = NO;
            [strongSelf noteSearchKeyboardDebug:[strongSelf searchKeyboardDebugLine:@"search visible" attempt:attempt picker:picker]];
            return;
        }
        if (attempt >= 5) {
            strongSelf->_ensuringPickerSearchKeyboard = NO;
            [strongSelf noteSearchKeyboardDebug:[strongSelf searchKeyboardDebugLine:@"search missing" attempt:attempt picker:picker]];
            return;
        }
        [strongSelf noteSearchKeyboardDebug:[strongSelf searchKeyboardDebugLine:@"search retry" attempt:attempt picker:picker]];
        [strongSelf takeKeyWindow];
        if (!DSWindowIsApplicationKey(strongSelf->_window)) {
            [strongSelf->_window makeKeyAndVisible];
        }
        // The first retries only reload. Restarting editing resigns the field,
        // which would drop a keyboard that is still on its way in.
        if (attempt >= 2) {
            [picker restartSearchEditing];
        } else {
            [picker reassertSearchEditing];
        }
        [strongSelf ensurePickerSearchKeyboard:picker slot:slot generation:generation attempt:attempt + 1];
    });
}

- (void)appPickerDidEndSearch:(DSAppPickerViewController *)picker {
    // Reclaiming the key window resigns the field. That is not the user leaving
    // search, and clearing the slot here stops the keyboard from being asked again.
    if (_ensuringPickerSearchKeyboard) return;
    if (_searchSlot == [self slotForPicker:picker]) _searchSlot = -1;
    // Hand the key window back while an app is still staged. Leaving it key
    // is what took the keyboard away from that app after search.
    if (_sceneHost.isHosting || _topSceneHost.isHosting) {
        [self giveBackKeyWindow];
    }
}

- (BOOL)appPickerShouldWaitBeforeSearchEditing:(DSAppPickerViewController *)picker {
    return _overlaySettling;
}

#pragma mark - Launching onto the stage

- (void)appPicker:(DSAppPickerViewController *)picker didSelectEntry:(DSAppEntry *)entry fromView:(UIView *)view {
    [picker dismissKeyboard];
    [self launchEntry:entry slot:[self slotForPicker:picker]];
}

- (void)appPicker:(DSAppPickerViewController *)picker didHoldEntry:(DSAppEntry *)entry fromView:(UIView *)view {
    [picker dismissKeyboard];
    [self launchFullscreen:entry.bundleIdentifier];
}

- (void)launchEntry:(DSAppEntry *)entry {
    [self launchEntry:entry slot:0];
}

- (void)launchEntry:(DSAppEntry *)entry slot:(NSInteger)slot {
    if (entry.bundleIdentifier.length == 0) {
        DSDiagnosticsRecord(@"SpringBoard: a plate was tapped with no app behind it");
        return;
    }
    if (slot >= kDSMaxStackSlots) return;
    if (slot == 1) [self ensureTopStackInfrastructure];

    DSAppPickerViewController *picker = slot == 0 ? _picker : _topPicker;
    DSStageContainerView *card = [self containerForSlot:slot];
    [picker dismissKeyboard];

    DSPreferences *preferences = [DSPreferences sharedPreferences];
    if ([preferences isApplicationDisabled:entry.bundleIdentifier]) {
        DSDiagnosticsRecordFormat(@"SpringBoard: %@ is switched off in its own settings, so it was not opened",
                                  entry.bundleIdentifier);
        return;
    }

    DSSceneHost *existingHost = [self sceneHostForSlot:slot];
    if (existingHost && ![existingHost.bundleIdentifier isEqualToString:entry.bundleIdentifier]) {
        if (slot == 0) {
            _sceneHost = nil;
            [self forgetStagedAppKeyboard];
        } else {
            _topSceneHost = nil;
        }
        [existingHost relinquishKeepingBackgrounded:[preferences backgroundsOnMinimize:existingHost.bundleIdentifier]];
    }

    SBApplication *wasInFront = [self frontApplication];
    _bundleIdentifierToRestoreInFront =
        [wasInFront.bundleIdentifier isEqualToString:entry.bundleIdentifier] ? nil : wasInFront.bundleIdentifier;

    [preferences noteApplicationOpened:entry.bundleIdentifier];
    DSStageState layoutState = _state == DSStageStateSplit ? DSStageStateSplit : DSStageStateOverlay;
    [self publishStageStateForBundleIdentifier:entry.bundleIdentifier
                                        frame:[self frameForHalf:(slot == 1 ? _secondHalf : _primaryHalf) state:layoutState]
                                       active:YES];
    [self presentLaunchPlaceholderForEntry:entry slot:slot];

    DSSceneHost *host = [self sceneHostForSlot:slot];
    if (!host) {
        host = [[DSSceneHost alloc] initWithBundleIdentifier:entry.bundleIdentifier];
        if (slot == 0) {
            _sceneHost = host;
        } else {
            _topSceneHost = host;
        }
    }
    host.parentViewController = _window.rootViewController;
    [self refreshShelf];

    DSDiagnosticsRecordFormat(@"SpringBoard: putting %@ on stack slot %ld", entry.bundleIdentifier, (long)slot);

    __weak __typeof(self) weakSelf = self;
    [host prepareWithCompletion:^(BOOL ready) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!ready || [strongSelf sceneHostForSlot:slot] != host) {
            DSDiagnosticsRecordFormat(@"SpringBoard: %@ did not make it onto the stage, back to the picker",
                                      host.bundleIdentifier);
            strongSelf->_bundleIdentifierToRestoreInFront = nil;
            [strongSelf dismissLaunchPlaceholderForSlot:slot];
            if ([strongSelf sceneHostForSlot:slot] == host) {
                if (slot == 0) {
                    strongSelf->_sceneHost = nil;
                } else {
                    strongSelf->_topSceneHost = nil;
                }
                [strongSelf publishStageStateForBundleIdentifier:nil frame:CGRectZero active:NO];
                [host relinquishKeepingBackgrounded:NO];
            }
            [strongSelf refreshShelf];
            return;
        }
        [strongSelf attachHostedAppForSlot:slot];
    }];
}

- (void)presentLaunchPlaceholderForEntry:(DSAppEntry *)entry slot:(NSInteger)slot {
    DSStageContainerView *card = [self containerForSlot:slot];
    DSAppPickerViewController *picker = slot == 0 ? _picker : _topPicker;
    if (slot == 0) {
        [_launchPlaceholder removeFromSuperview];
    } else {
        [_topLaunchPlaceholder removeFromSuperview];
    }

    DSLaunchPlaceholderView *placeholder =
        [[DSLaunchPlaceholderView alloc] initWithBundleIdentifier:entry.bundleIdentifier
                                                            icon:[[DSAppLibrary sharedLibrary] iconForBundleIdentifier:entry.bundleIdentifier]
                                                            dark:card.darkMode];
    placeholder.frame = card.contentView.bounds;
    placeholder.alpha = 0.0;
    [card.contentView addSubview:placeholder];
    if (slot == 0) {
        _launchPlaceholder = placeholder;
    } else {
        _topLaunchPlaceholder = placeholder;
    }

    [UIView animateWithDuration:0.22 animations:^{
        placeholder.alpha = 1.0;
        picker.view.alpha = 0.0;
    }];
}

- (void)dismissLaunchPlaceholderForSlot:(NSInteger)slot {
    DSAppPickerViewController *picker = slot == 0 ? _picker : _topPicker;
    UIView *placeholder = slot == 0 ? _launchPlaceholder : _topLaunchPlaceholder;
    if (slot == 0) {
        _launchPlaceholder = nil;
    } else {
        _topLaunchPlaceholder = nil;
    }
    picker.view.hidden = NO;
    [UIView animateWithDuration:0.2 animations:^{
        placeholder.alpha = 0.0;
        picker.view.alpha = 1.0;
    } completion:^(BOOL finished) {
        [placeholder removeFromSuperview];
    }];
}

- (void)attachHostedApp {
    [self attachHostedAppForSlot:0];
}

- (void)attachHostedAppForSlot:(NSInteger)slot {
    DSSceneHost *host = [self sceneHostForSlot:slot];
    DSStageContainerView *card = [self containerForSlot:slot];
    DSAppPickerViewController *picker = slot == 0 ? _picker : _topPicker;

    UIView *hostView = host.hostView;
    if (!hostView) {
        DSDiagnosticsRecordFormat(@"SpringBoard: %@ was ready but handed over no view", host.bundleIdentifier);
        if (slot == 0) _bundleIdentifierToRestoreInFront = nil;
        [self dismissLaunchPlaceholderForSlot:slot];
        return;
    }
    DSDiagnosticsRecordFormat(@"SpringBoard: %@ is on stack slot %ld", host.bundleIdentifier, (long)slot);

    picker.view.hidden = YES;
    picker.view.alpha = 1.0;
    hostView.opaque = YES;
    if (@available(iOS 13.0, *)) {
        hostView.backgroundColor = UIColor.systemBackgroundColor;
        card.contentView.backgroundColor = UIColor.systemBackgroundColor;
    } else {
        hostView.backgroundColor = UIColor.whiteColor;
        card.contentView.backgroundColor = UIColor.whiteColor;
    }
    // A view that already has a different parent stays there. Moving it blanks the app.
    if (hostView.superview == nil || hostView.superview == card.contentView) {
        [card.contentView insertSubview:hostView atIndex:0];
    }
    [card layoutIfNeeded];
    [host fitHostViewToCard];
    [card setBackdropHidden:YES];
    [host noteHostViewAttached];

    DSStageState layoutState = _state == DSStageStateSplit ? DSStageStateSplit : DSStageStateOverlay;
    [self layoutStageForState:layoutState];
    if (slot == 0) [self applyStageRotation];
    _searchSlot = -1;
    [self giveBackKeyWindow];
    if (slot == 0) {
        if (!CGRectIsEmpty(_keyboardFrame)) {
            [self noteKeyboardFrame:_keyboardFrame source:host.bundleIdentifier duration:0.25];
        } else {
            CGRect keys = DSVisibleKeyboardFrameOnScreen();
            if (!CGRectIsEmpty(keys)) {
                [self noteKeyboardFrame:keys source:host.bundleIdentifier duration:0.25];
            }
        }
        [self returnFrontToWhereItWas];
    }

    [self updateHomeAffordance];
    [self refreshShelf];

    UIView *placeholder = slot == 0 ? _launchPlaceholder : _topLaunchPlaceholder;
    if (slot == 0) {
        _launchPlaceholder = nil;
    } else {
        _topLaunchPlaceholder = nil;
    }
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

- (void)exitToPickerAnimated:(BOOL)animated {
    if (_sceneHost.isHosting) {
        [self exitToPickerAnimated:animated slot:0];
    } else if (_topSceneHost.isHosting) {
        [self exitToPickerAnimated:animated slot:1];
    }
}

// Back to the picker, app stays alive.
- (void)exitToPickerAnimated:(BOOL)animated slot:(NSInteger)slot {
    DSSceneHost *host = [self sceneHostForSlot:slot];
    if (!host.isHosting) return;

    DSStageContainerView *card = [self containerForSlot:slot];
    DSAppPickerViewController *picker = slot == 0 ? _picker : _topPicker;
    if (_keyboardLiftSlot == slot) {
        _keyboardFrame = CGRectZero;
        _notedKeyboardOnce = NO;
    }
    [card setLiftOffset:0.0];
    _searchSlot = -1;
    if (_stagedKeyboardSlot == slot) [self hideStagedKeyboardLikePicker];
    if (slot == 0) {
        _sceneHost = nil;
        _stageQuarterTurns = 0;
        [self forgetStagedAppKeyboard];
    } else {
        _topSceneHost = nil;
    }
    _ignoreSystemPullUntil = CFAbsoluteTimeGetCurrent() + 0.6;

    UIView *hostView = host.hostView;
    [card setClipsContents:YES];
    [card setBackdropHidden:NO];
    card.hostingApp = NO;
    card.backgroundColor = [UIColor colorWithWhite:0.11 alpha:1.0];
    card.contentView.backgroundColor = UIColor.clearColor;

    picker.view.hidden = NO;
    picker.view.alpha = 0.0;
    [picker reloadContent];
    [card.contentView bringSubviewToFront:picker.view];
    [picker.view layoutIfNeeded];

    if (!hostView || !hostView.superview) {
        [self publishStageStateForBundleIdentifier:host.bundleIdentifier frame:CGRectZero active:NO];
        [host relinquishKeepingBackgrounded:[[DSPreferences sharedPreferences] backgroundsOnMinimize:host.bundleIdentifier]];
        [self scheduleAutoKillForHost:host];
        [self presentPickerOnCard:card picker:picker];
        card.alpha = 1.0;
        card.hidden = NO;
        [self updateHomeAffordance];
        [self layoutStageForState:_state == DSStageStateSplit ? DSStageStateSplit : DSStageStateOverlay];
        [self refreshShelf];
        [self bringShelfToFront];
        if (!_sceneHost.isHosting && !_topSceneHost.isHosting) {
            [self preparePickerForSearchKeyboard];
        }
        return;
    }

    hostView.layer.mask = nil;
    hostView.clipsToBounds = NO;
    hostView.transform = CGAffineTransformIdentity;
    hostView.layer.cornerCurve = kCACornerCurveContinuous;
    hostView.layer.masksToBounds = YES;

    void (^layout)(void) = ^{
        hostView.transform = CGAffineTransformMakeScale(0.92, 0.92);
        hostView.alpha = 0.0;
        picker.view.alpha = 1.0;
    };
    void (^finish)(void) = ^{
        hostView.transform = CGAffineTransformIdentity;
        hostView.alpha = 1.0;
        hostView.layer.cornerRadius = 0.0;
        hostView.layer.masksToBounds = NO;
        [hostView removeFromSuperview];
        [self presentPickerOnCard:card picker:picker];
        card.alpha = 1.0;
        card.hidden = NO;
        [self publishStageStateForBundleIdentifier:host.bundleIdentifier frame:CGRectZero active:NO];
        [host relinquishKeepingBackgrounded:[[DSPreferences sharedPreferences] backgroundsOnMinimize:host.bundleIdentifier]];
        [self scheduleAutoKillForHost:host];
        [self updateHomeAffordance];
        [self layoutStageForState:self->_state == DSStageStateSplit ? DSStageStateSplit : DSStageStateOverlay];
        [self refreshShelf];
        [self bringShelfToFront];
        if (!self->_sceneHost.isHosting && !self->_topSceneHost.isHosting) {
            [self preparePickerForSearchKeyboard];
        } else {
            [self giveBackKeyWindow];
        }
    };

    if (animated) {
        [UIView animateWithDuration:0.22 animations:layout completion:^(BOOL finished) { finish(); }];
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
    _primaryHalf = 0;
    _secondHalf = 1;
    _stageQuarterTurns = 0;
    [self showPickerImmediately];
    [self noteStageWindowIdle];
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
            if (self->_state == DSStageStateClosed || self->_state == DSStageStateMinimized) {
                [self noteStageWindowIdle];
            }
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
    _container.hostingApp = self.hasHostedApp;
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

// The focus coordinator stays out of this. 1.4.0 pointed it at the staged app's
// scene and the picker's search field could not raise a keyboard afterwards.
// A staged app asks for SpringBoard's keyboard from its own process. This side
// only lifts the card and, when that keyboard window exists, keeps it visible.

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
- (void)offsetVisibleStackByY:(CGFloat)dy state:(DSStageState)state {
    if (_stackSlotCount <= 1) {
        CGRect base = (state == DSStageStateOverlay) ? [self fixedHalfFrame:_primaryHalf] : [self stageFrameForState:state];
        _container.frame = CGRectOffset(base, 0.0, dy);
        return;
    }
    _container.frame = CGRectOffset([self frameForHalf:_primaryHalf state:state], 0.0, dy);
    _topContainer.frame = CGRectOffset([self frameForHalf:_secondHalf state:state], 0.0, dy);
}

- (void)handleStagePan:(UIPanGestureRecognizer *)recognizer {
    static BOOL fromTop = NO;
    static BOOL fromCorner = NO;
    static BOOL fromEdge = NO;
    static NSInteger dragSlot = 0;
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

    DSStageContainerView *card = [recognizer.view isKindOfClass:DSStageContainerView.class]
        ? (DSStageContainerView *)recognizer.view
        : _container;
    dragSlot = (card == _topContainer) ? 1 : 0;
    DSSceneHost *dragHost = [self sceneHostForSlot:dragSlot];

    CGPoint location = [recognizer locationInView:card];
    CGPoint translation = [recognizer translationInView:_window];
    CGPoint velocity = [recognizer velocityInView:_window];
    DSStageState layoutState = _state == DSStageStateSplit ? DSStageStateSplit : DSStageStateOverlay;
    CGRect resting = [self stageFrameForState:layoutState];

    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan: {
            CGPoint start = CGPointMake(location.x - translation.x, location.y - translation.y);

            // The card is about to be moved by hand, so it stops being held up out
            // of the keyboard's way first: its own frame has to mean what it says
            // for the rest of this drag.
            [_picker dismissKeyboard];
            if (_topPicker) [_topPicker dismissKeyboard];
            [_container setLiftOffset:0.0];
            if (_topContainer) [_topContainer setLiftOffset:0.0];

            BOOL hostingCard = dragHost.isHosting;
            fromCorner = hostingCard && CGRectContainsPoint([card cornerGripRect], start);
            fromEdge = hostingCard && CGRectContainsPoint([card edgeGripRect], start) && !fromCorner;
            cornerIntent = DSCornerIntentUndecided;
            fromTop = !fromCorner && !fromEdge && CGRectContainsPoint([card dragAffordanceRect], start);
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
                    dragHost.hostView.transform = CGAffineTransformMakeScale(1.0 - travel / 900.0,
                                                                             1.0 - travel / 900.0);
                } else {
                    CGFloat offset = MAX(translation.y, 0.0);
                    [self offsetVisibleStackByY:offset state:layoutState];
                    _container.alpha = 1.0 - MIN(offset / (CGRectGetHeight(resting) * 0.6), 0.75);
                    if (_topContainer) _topContainer.alpha = _container.alpha;
                }
            } else if (fromTop) {
                [self offsetVisibleStackByY:MAX(translation.y, -70.0) state:layoutState];
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
                    leave = (-translation.x > 36.0 && -translation.x > fabs(translation.y) * 0.8) ||
                            (-velocity.x > 500.0 && -velocity.x > fabs(velocity.y));
                } else {
                    leave = DSInwardTravel(translation) > 48.0 ||
                            (DSInwardTravel(translation) > 32.0 && DSInwardTravel(velocity) > 500.0);
                }
                if (leave) {
                    dragHost.hostView.transform = CGAffineTransformIdentity;
                    // Same return as holding that half's square on the right-edge shelf.
                    [self returnHalfToPicker:[self halfForContainer:card]];
                } else {
                    [UIView animateWithDuration:0.25 animations:^{
                        dragHost.hostView.transform = CGAffineTransformIdentity;
                    }];
                }
            } else if (fromCorner || fromEdge) {
                if (translation.y > CGRectGetHeight(resting) * 0.2 || velocity.y > 700.0) {
                    [self closeStageAnimated:YES];
                } else {
                    [self snapBackToLayoutForState:layoutState];
                }
            } else if (fromTop) {
                if (_stackSlotCount >= kDSMaxStackSlots && _state == DSStageStateOverlay) {
                    BOOL onBottom = [self halfForContainer:card] == 0;
                    BOOL swapUp = onBottom && (translation.y < -70.0 || velocity.y < -700.0);
                    BOOL swapDown = !onBottom && (translation.y > 70.0 || velocity.y > 700.0);
                    if (swapUp || swapDown) {
                        [self swapStackHalvesAnimated:YES];
                    } else if (onBottom && (translation.y > CGRectGetHeight(resting) * 0.38 || velocity.y > 950.0)) {
                        [self parkCard:card animated:YES];
                    } else {
                        [self snapBackToLayoutForState:layoutState];
                    }
                } else if (translation.y > CGRectGetHeight(resting) * 0.38 || velocity.y > 950.0) {
                    [self parkCard:card animated:YES];
                } else if (translation.y < -40.0 && _state == DSStageStateOverlay && _stackSlotCount <= 1) {
                    [self enterStateSplitAnimated:YES];
                } else if (translation.y > 40.0 && _state == DSStageStateSplit) {
                    [self enterStateOverlayAnimated:YES];
                } else {
                    [self snapBackToLayoutForState:layoutState];
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
                dragHost.hostView.transform = CGAffineTransformIdentity;
            } else if (fromTop || fromCorner || fromEdge) {
                [self snapBackToLayoutForState:layoutState];
            }
            fromTop = fromCorner = fromEdge = NO;
            cornerIntent = DSCornerIntentUndecided;
            break;
        }
        default:
            break;
    }
}

- (void)snapBackToLayoutForState:(DSStageState)state {
    [self animateSpring:^{
        [self layoutAllStackSlotsForState:state];
        self->_container.alpha = 1.0;
        if (self->_topContainer) self->_topContainer.alpha = 1.0;
    } completion:nil];
}

- (CGRect)closeZoneRect {
    return CGRectUnion([_container cornerGripRect], [_container edgeGripRect]);
}

#pragma mark - Stage shelf

- (void)bringShelfToFront {
    if (_shelf.superview) [_shelf.superview bringSubviewToFront:_shelf];
}

- (void)noteStageWindowIdle {
    _window.hidden = NO;
    [self bringShelfToFront];
    [self refreshShelf];
}

- (NSString *)bundleIdentifierOnHalf:(NSInteger)half {
    if (_stackSlotCount < kDSMaxStackSlots) {
        if (_primaryHalf != half) return nil;
        return _sceneHost.bundleIdentifier;
    }
    if (_primaryHalf == half) return _sceneHost.bundleIdentifier;
    if (_secondHalf == half) return _topSceneHost.bundleIdentifier;
    return nil;
}

- (void)refreshShelf {
    if (!_shelf) return;
    [_shelf reloadTopBundleIdentifier:[self bundleIdentifierOnHalf:1]
             bottomBundleIdentifier:[self bundleIdentifierOnHalf:0]];
}

// Key window only when a picker is up and no app is hosted. A hosted app keeps
// the window it already has until the user actually taps a search field.
- (void)settlePickerKeyboard {
    if (_sceneHost.isHosting || _topSceneHost.isHosting) {
        [self giveBackKeyWindow];
        return;
    }
    [self preparePickerForSearchKeyboard];
}

- (void)finishPickerLayoutAnimated:(BOOL)animated generation:(NSInteger)generation settleKeyboard:(BOOL)settle {
    if (_state != DSStageStateOverlay) {
        _state = DSStageStateOverlay;
        _window.hidden = NO;
        [self cancelAutoKill];
    }
    _overlaySettling = animated;
    void (^layout)(void) = ^{
        [self layoutAllStackSlotsForState:DSStageStateOverlay];
    };
    void (^finish)(void) = ^{
        if (generation != self->_presentGeneration) return;
        self->_overlaySettling = NO;
        self->_container.alpha = 1.0;
        if (self->_stackSlotCount >= kDSMaxStackSlots && self->_topContainer) {
            self->_topContainer.alpha = 1.0;
            self->_topContainer.hidden = NO;
        }
        [self updateStackChrome];
        [self updateHomeAffordance];
        [self bringShelfToFront];
        [self refreshShelf];
        if (settle) [self settlePickerKeyboard];
    };
    if (animated) {
        [self animateSpring:layout completion:finish];
    } else {
        layout();
        finish();
    }
}

// One present for the corner pull, the right-edge squares, and the + button.
// The card is the fixed half size before it animates, and it is never left at
// alpha 0 if that animation is interrupted.
- (void)presentPickerOnHalf:(NSInteger)half animated:(BOOL)animated {
    if (half != 0 && half != 1) return;
    if ([self bundleIdentifierOnHalf:half].length > 0) {
        [self revealHalf:half animated:animated];
        return;
    }
    if (_state == DSStageStateClosed) {
        NSString *refusal = [self reasonStageCannotActivate];
        if (refusal) {
            DSDiagnosticsRecordFormat(@"SpringBoard: stage refused to open because %@", refusal);
            return;
        }
    }

    _presentGeneration += 1;
    NSInteger generation = _presentGeneration;
    _searchSlot = -1;
    [_picker dismissKeyboard];
    if (_topPicker) [_topPicker dismissKeyboard];
    NSInteger other = half == 0 ? 1 : 0;
    BOOL otherHasApp = [self bundleIdentifierOnHalf:other].length > 0;

    if (!otherHasApp && _stackSlotCount < kDSMaxStackSlots &&
        !_sceneHost.isHosting && !_topSceneHost.isHosting) {
        _primaryHalf = half;
        _secondHalf = half == 0 ? 1 : 0;
        _stackSlotCount = 1;
        _primaryParked = NO;
        _secondParked = NO;
        if (_topContainer) _topContainer.hidden = YES;
        [self presentPickerOnCard:_container picker:_picker];
        [_picker resetScrollPosition];
        _container.hidden = NO;
        _container.alpha = 1.0;
        [_container setLiftOffset:0.0];
        if (_state == DSStageStateOverlay) {
            [self finishPickerLayoutAnimated:animated generation:generation settleKeyboard:YES];
        } else {
            [self enterStateOverlayAnimated:animated];
        }
        DSDiagnosticsRecordFormat(@"SpringBoard: opened a stage on the %@ half", half == 1 ? @"top" : @"bottom");
        return;
    }

    [self ensureTopStackInfrastructure];
    _topContainer.darkMode = _container.darkMode;

    DSStageContainerView *card = nil;
    DSAppPickerViewController *picker = nil;
    if (_stackSlotCount < kDSMaxStackSlots) {
        if (_sceneHost.isHosting && _primaryHalf == half) {
            [self revealHalf:half animated:animated];
            return;
        }
        if (_primaryHalf == half && !_sceneHost.isHosting) {
            _primaryParked = NO;
            card = _container;
            picker = _picker;
        } else {
            _secondHalf = half;
            _stackSlotCount = 2;
            _secondParked = NO;
            card = _topContainer;
            picker = _topPicker;
        }
    } else {
        card = [self containerOnHalf:half];
        if (!card) {
            _secondHalf = half;
            card = (_primaryHalf == half) ? _container : _topContainer;
        }
        picker = (card == _topContainer) ? _topPicker : _picker;
        DSSceneHost *host = (card == _topContainer) ? _topSceneHost : _sceneHost;
        if (host.isHosting) return;
        [self setParked:NO forCard:card];
    }

    CGRect finalFrame = [self fixedHalfFrame:half];
    [card setLiftOffset:0.0];
    card.hidden = NO;
    card.alpha = 1.0;
    BOOL sameSize = fabs(CGRectGetWidth(card.frame) - CGRectGetWidth(finalFrame)) < 0.5 &&
                    fabs(CGRectGetHeight(card.frame) - CGRectGetHeight(finalFrame)) < 0.5;
    if (!sameSize) card.frame = finalFrame;
    [self presentPickerOnCard:card picker:picker];
    [picker resetScrollPosition];

    BOOL keepOtherParked = otherHasApp && (_state == DSStageStateMinimized || _state == DSStageStateClosed);
    if (keepOtherParked || _state == DSStageStateOverlay) {
        if (_state != DSStageStateOverlay) {
            _state = DSStageStateOverlay;
            _window.hidden = NO;
            [self cancelAutoKill];
        }
        [self finishPickerLayoutAnimated:animated generation:generation settleKeyboard:YES];
    } else {
        [self enterStateOverlayAnimated:animated];
    }
    DSDiagnosticsRecordFormat(@"SpringBoard: opened a stage on the %@ half", half == 1 ? @"top" : @"bottom");
}

- (void)revealHalf:(NSInteger)half animated:(BOOL)animated {
    DSStageContainerView *card = [self containerOnHalf:half];
    if (!card) card = _container;
    [self setParked:NO forCard:card];
    if (_state != DSStageStateOverlay && _state != DSStageStateSplit) {
        _state = DSStageStateOverlay;
        _window.hidden = NO;
        [self cancelAutoKill];
        [self giveBackKeyWindow];
    }
    DSSceneHost *host = (card == _topContainer) ? _topSceneHost : _sceneHost;
    [host setForeground:YES];
    void (^layout)(void) = ^{
        [self layoutAllStackSlotsForState:DSStageStateOverlay];
    };
    void (^finish)(void) = ^{
        [self updateHomeAffordance];
        [self updateStackChrome];
        [self refreshShelf];
        [self bringShelfToFront];
    };
    if (animated) {
        [self animateSpring:layout completion:finish];
    } else {
        layout();
        finish();
    }
}

- (NSInteger)slotForHalf:(NSInteger)half {
    if (_stackSlotCount < kDSMaxStackSlots) {
        return _primaryHalf == half ? 0 : -1;
    }
    if (_primaryHalf == half) return 0;
    if (_secondHalf == half) return 1;
    return -1;
}

// Hold on a filled notch square. That half drops its app and shows the picker.
// An empty square never reaches here.
- (void)returnHalfToPicker:(NSInteger)half {
    NSInteger slot = [self slotForHalf:half];
    if (slot < 0) return;
    DSSceneHost *host = [self sceneHostForSlot:slot];
    if (!host.isHosting) return;

    DSStageContainerView *card = [self containerForSlot:slot];
    BOOL wasParked = card && [self cardIsParked:card];
    if (card) [self setParked:NO forCard:card];
    if (_state != DSStageStateOverlay && _state != DSStageStateSplit) {
        _state = DSStageStateOverlay;
        _window.hidden = NO;
        [self cancelAutoKill];
    }
    if (wasParked) {
        [self layoutAllStackSlotsForState:DSStageStateOverlay];
    }
    [self exitToPickerAnimated:YES slot:slot];
    if (!_sceneHost.isHosting && !_topSceneHost.isHosting) {
        [self preparePickerForSearchKeyboard];
    }
    [self bringShelfToFront];
    [self refreshShelf];
    DSDiagnosticsRecordFormat(@"SpringBoard: held the %@ stage, back to the picker", half == 1 ? @"top" : @"bottom");
}

- (void)beginStageOnHalf:(NSInteger)half {
    if (half != 0 && half != 1) return;
    if (_state == DSStageStateTracking) return;
    // The corner pull lands in presentPickerOnHalf as well.
    [self presentPickerOnHalf:half animated:YES];
}

#pragma mark - External events

- (void)noteSceneDestroyedForBundleIdentifier:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0) return;
    if (_topSceneHost && [_topSceneHost.bundleIdentifier isEqualToString:bundleIdentifier]) {
        DSDiagnosticsRecordFormat(@"SpringBoard: %@ went away while it was on the top stage", bundleIdentifier);
        _topSceneHost = nil;
        if (_topContainer) {
            [self presentPickerOnCard:_topContainer picker:_topPicker];
            _topContainer.alpha = 1.0;
            _topContainer.hidden = NO;
        }
        if (!_sceneHost.isHosting && !_topSceneHost.isHosting) {
            [self preparePickerForSearchKeyboard];
        }
        [self refreshShelf];
        [self updateHomeAffordance];
        [self updateStackChrome];
        return;
    }
    if (!_sceneHost || ![_sceneHost.bundleIdentifier isEqualToString:bundleIdentifier]) return;
    DSDiagnosticsRecordFormat(@"SpringBoard: %@ went away while it was on the stage", bundleIdentifier);
    _sceneHost = nil;
    [self forgetStagedAppKeyboard];
    [self showPickerImmediately];
    if (_state == DSStageStateMinimized) {
        _state = DSStageStateClosed;
        [self noteStageWindowIdle];
    }
    [self refreshShelf];
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
    if (!_activated) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        Class lockScreenClass = objc_getClass("SBLockScreenManager");
        id manager = lockScreenClass ? [lockScreenClass sharedInstance] : nil;
        if ([manager respondsToSelector:@selector(isUILocked)] && [manager isUILocked]) {
            return;
        }
        if (!self.isStageVisible) {
            DSDiagnosticsRecord(@"SpringBoard: showing the walkthrough");
            [DSIntroViewController presentIntro];
        }
    });
}

@end
