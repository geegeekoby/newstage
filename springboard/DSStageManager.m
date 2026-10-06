#import "DSStageManager.h"
#import "DSStageLiftState.h"
#import "DSStageWindow.h"
#import "DSStageContainerView.h"
#import "DSAppPickerViewController.h"
#import "DSSearchFieldView.h"
#import "DSAppLibrary.h"
#import "DSGestureController.h"
#import "DSSceneHost.h"
#import "DSPreferences.h"
#import "DSPrivate.h"
#import "DSIntroViewController.h"
#import "DSDiagnostics.h"
#import "DSStageDebug.h"
#import "DSCrashLog.h"
#import "DSKeyboardVisibility.h"
#import "DSStageLayout.h"
#import "DSStageShelfView.h"
#import "DSStageDragShellView.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <sys/stat.h>
#import <stdio.h>

// Bumped when a hosted keyboard goes down so a late clip retry does not reopen it.
static NSInteger DSHostedClipGeneration = 0;
// One watch for Messages' real keyboard. A new arbiter event must not restart it.
static NSInteger DSMessagesKeyboardWatch = 0;
static BOOL DSMessagesKeyboardWatchArmed = NO;
// The arbiter's frame for Messages. A made-up 301pt rect is not stored here.
static CGRect DSMessagesArbiterFrame = {{0, 0}, {0, 0}};
static BOOL DSMessagesArbiterFrameValid = NO;

// A keyboard at the bottom of the phone. The 75pt dock strip and the in-card
// keyboard fail this. The frame is not rewritten before the test.
static BOOL DSRectIsDisplayKeyboard(CGRect keyboard, CGRect screen) {
    CGFloat screenW = CGRectGetWidth(screen);
    CGFloat screenH = CGRectGetHeight(screen);
    if (screenW < 100.0 || screenH < 100.0) return NO;
    CGFloat height = CGRectGetHeight(keyboard);
    CGFloat width = CGRectGetWidth(keyboard);
    if (height < 160.0 || height > screenH * 0.65) return NO;
    if (width < screenW - 40.0) return NO;
    if (CGRectGetMinY(keyboard) < screenH * 0.45) return NO;
    if (CGRectGetMinY(keyboard) >= CGRectGetMaxY(screen) - 1.0) return NO;
    if (CGRectGetMaxY(keyboard) < screenH * 0.85) return NO;
    return YES;
}

// The system pan waits several points before it begins, which reads as a hitch
// when the card is already on screen. This one starts on the first real move.
@interface DSQuickPanGestureRecognizer : UIPanGestureRecognizer
@end

@implementation DSQuickPanGestureRecognizer {
    CGPoint _start;
    BOOL _haveStart;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    _haveStart = NO;
    [super touchesBegan:touches withEvent:event];
    UITouch *touch = touches.anyObject;
    if (!touch) return;
    _start = [touch locationInView:self.view.window ?: self.view];
    _haveStart = YES;
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesMoved:touches withEvent:event];
    if (self.state != UIGestureRecognizerStatePossible || !_haveStart) return;
    UITouch *touch = touches.anyObject;
    if (!touch) return;
    CGPoint now = [touch locationInView:self.view.window ?: self.view];
    if (hypot(now.x - _start.x, now.y - _start.y) < 2.0) return;
    self.state = UIGestureRecognizerStateBegan;
}

@end

// The outline around a card. It is a rectangle only so the stroke can be drawn;
// touches belong to the band outside the card. A full-rectangle hit target is
// what makes a new stage drag from anywhere inside it.
@interface DSStageRimHitView : UIView
@property (nonatomic, assign) CGFloat hitBand;
// The rim is wider than the gap between the two stages. Points that land on the
// other card belong to that card, or a grab on the lower stage drags the upper one.
@property (nonatomic, copy) BOOL (^rejectsWindowPoint)(CGPoint windowPoint);
@end

@implementation DSStageRimHitView

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    (void)event;
    if (!CGRectContainsPoint(self.bounds, point)) return NO;
    if (self.rejectsWindowPoint) {
        CGPoint windowPoint = [self convertPoint:point toView:nil];
        if (self.rejectsWindowPoint(windowPoint)) return NO;
    }
    CGFloat band = self.hitBand > 1.0 ? self.hitBand : (kDSStageOuterDragBand + 18.0);
    CGRect hole = CGRectInset(self.bounds, band, band);
    if (CGRectGetWidth(hole) < 40.0 || CGRectGetHeight(hole) < 40.0) return YES;
    return !CGRectContainsPoint(hole, point);
}

@end

// Fraction of the screen height the finger has to travel for the pull to reach
// the stage's resting size. Releasing past the cancel threshold always lands
// in overlay. The app behind is never resized.
static const CGFloat kDSPullTravelRatio = 0.42;
static const CGFloat kDSCancelProgress = 0.14;
static const CGFloat kDSPullSettleProgress = 0.82;
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
    // Clearing this field after a letter must not be forwarded as deletes.
    if (self.forwardingEdit) return YES;
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
    // The letter is already in the staged app. Keeping it in this offscreen
    // field moves the caret, and the next tap on the keys never arrives.
    // Tapping the input bar focused the field again, which is why one more
    // letter worked.
    self.text = @"";
    self.forwardingEdit = NO;
    return NO;
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
        // A sandboxed app can read /var/tmp. Preferences was not readable.
        chmod(kDSKeyboardInputPath.fileSystemRepresentation, 0666);
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

// Invalidating the card's app view starts a workspace transition. Launching
// the real app on the next turn stacks a second one, and the home swipe then
// traps. Wait until that transition is gone. Always launch eventually.
static void DSLaunchFullScreenAppWhenIdle(NSString *bundle, NSInteger attemptsLeft) {
    if (bundle.length == 0) return;
    id transaction = nil;
    Class workspaceClass = objc_getClass("SBMainWorkspace");
    if ([workspaceClass respondsToSelector:@selector(sharedInstance)]) {
        id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, @selector(sharedInstance));
        if ([workspace respondsToSelector:@selector(currentTransaction)]) {
            transaction = ((id (*)(id, SEL))objc_msgSend)(workspace, @selector(currentTransaction));
        }
    }
    if ((transaction != nil || [DSSceneHost homeGestureIsActive]) && attemptsLeft > 0) {
        NSString *held = [bundle copy];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            DSLaunchFullScreenAppWhenIdle(held, attemptsLeft - 1);
        });
        return;
    }
    SpringBoard *springBoard = (SpringBoard *)UIApplication.sharedApplication;
    if ([springBoard respondsToSelector:@selector(launchApplicationWithIdentifier:suspended:)]) {
        [springBoard launchApplicationWithIdentifier:bundle suspended:NO];
    }
    DSDiagnosticsRecordFormat(@"SpringBoard: split closed, %@ is full screen", bundle);
}

@interface DSStageManager () <DSGestureControllerDelegate, DSAppPickerDelegate, DSStagedKeyboardTarget, UIGestureRecognizerDelegate>
- (void)extendHostedSceneForKeyboard:(CGRect)keys source:(NSString *)source;
- (NSString *)hostedBundleForKeyboardNotifications;
- (void)beginMessagesKeyboardWatch:(CGRect)frame;
- (void)postMessagesKeyboardShown:(BOOL)shown;
- (void)watchMessagesKeyboardAttempt:(NSInteger)attempt
                           generation:(NSInteger)generation
                                watch:(NSInteger)watch
                                frame:(CGRect)frame;
- (void)setForegroundForAllHostedApps:(BOOL)foreground;
- (void)collapseToSingleTopStage;
- (void)addSecondStageAnimated:(BOOL)animated;
@end

typedef NS_ENUM(NSInteger, DSKeyboardType) {
    DSKeyboardTypeUnknown = 0,
    DSKeyboardTypeBottomKeyboard,
    DSKeyboardTypeTopStrip,
    DSKeyboardTypeDockStrip
};

static DSKeyboardType DSClassifyKeyboard(CGFloat keysY, CGFloat keysH, CGFloat screenH) {
    if (keysH <= 0.0 || screenH < 100.0) return DSKeyboardTypeUnknown;
    if (keysY >= screenH - 120.0 && keysH <= 120.0) return DSKeyboardTypeDockStrip;
    if (keysY <= 10.0 && keysH <= 120.0) return DSKeyboardTypeTopStrip;
    if (keysY >= screenH * 0.50) return DSKeyboardTypeBottomKeyboard;
    return DSKeyboardTypeUnknown;
}

static NSString *DSKeyboardTypeName(DSKeyboardType type) {
    switch (type) {
        case DSKeyboardTypeBottomKeyboard: return @"bottom-keyboard";
        case DSKeyboardTypeTopStrip: return @"top-strip";
        case DSKeyboardTypeDockStrip: return @"dock-strip";
        default: return @"unknown";
    }
}

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
    NSInteger _slotHalf[4];
    NSInteger _slotPrimary[4];
    // The staged app whose keyboard is allowed to move its card.
    NSString *_keyboardLiftOwner;
    // Which half of the display each card occupies once two stages are open.
    // 0 = bottom, 1 = top. The hosted app stays inside its own card.
    NSInteger _primaryHalf;
    NSInteger _secondHalf;
    // The half the card was on when it was swiped down to the corner.
    NSInteger _minimizedHalf;
    // Which bottom corner a minimized card sits in. Never straight off the bottom.
    BOOL _primaryMinimizedLeft;
    BOOL _secondMinimizedLeft;
    DSStageContainerView *_cornerRestoreCard;
    CGPoint _restoreFinger;
    BOOL _primaryParked;
    BOOL _secondParked;
    // A minimized app moved off its card so Split can use both halves. It keeps
    // running, and its icon stays in the corner it was already in.
    DSSceneHost *_stashedHost;
    DSSceneHost *_stashedHost2;
    BOOL _stashedLeft;
    BOOL _stashedLeft2;
    UIView *_stashHolder;
    BOOL _restoreWoke;
    BOOL _cornerExitFromLeft;
    DSStageContainerView *_cornerExitCard;
    BOOL _systemCover;
    UIEdgeInsets _lockedScreenInsets;
    BOOL _lockedScreenInsetsReady;
    BOOL _statusBarPeeking;
    NSInteger _statusBarPeekToken;
    BOOL _statusBarHideAppliedReady;
    BOOL _statusBarHideApplied;
    // 0 middle, 1 top, 2 bottom. The third stage rests in one of these.
    NSInteger _floatRest;
    NSInteger _swapPreviewHalf;
    // The card drawn above the two split cards. A sideways swap hands this
    // role to the split card, and the old front card becomes that half.
    DSStageContainerView *_frontCard;
    BOOL _floatIsSplitCard;
    NSInteger _floatSplitHalf;
    DSStageContainerView *_splitMiddleCard;
    UIPanGestureRecognizer *_topDragPan;

    UIView *_hostSnapshot;
    UIView *_hostBackdrop;
    UIImageView *_openAppIcon;
    UIImageView *_secondOpenAppIcon;
    UILabel *_terminateHint;
    CAGradientLayer *_terminateGlow;
    UIView *_terminateGlowHost;
    CAShapeLayer *_dragGhost;
    UILabel *_newStageGhostLabel;
    CAShapeLayer *_swapGhost;
    UIVisualEffectView *_swapGlassTop;
    UIVisualEffectView *_swapGlassBottom;
    UIView *_primaryParkPicture;
    UIView *_secondParkPicture;
    DSStageShelfView *_shelf;
    UILabel *_keyboardDebugLabel;
    DSLaunchPlaceholderView *_launchPlaceholder;
    DSLaunchPlaceholderView *_topLaunchPlaceholder;

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
    BOOL _activated;

    UIPanGestureRecognizer *_dragPan;
    // While a card is being dragged, the home gesture must not take the
    // bottom-centre band. That steal is what cancelled Terminate.
    BOOL _stageDragActive;
    UIPanGestureRecognizer *_systemPull;
    NSString *_lastRefusal;
    UIImpactFeedbackGenerator *_feedback;
    __weak UIWindow *_windowBeforeStage;
    BOOL _overlaySettling;
    // -1 unless a picker search field is the one being edited. Opening a second
    // picker must not count as searching, or that card lifts before anyone types.
    NSInteger _searchSlot;
    NSInteger _pickerSearchEnsureGeneration;
    CFAbsoluteTime _pickerSearchEnsureStartedAt;
    CFAbsoluteTime _overlaySettlingSeenSince;
    CFAbsoluteTime _overlaySettlingSeenLast;
    BOOL _ensuringPickerSearchKeyboard;
    // The hosted app's card while it is using the picker search keyboard.
    NSInteger _stagedKeyboardSlot;
    UITextField *_stagedKeyboardField;
    NSInteger _stagedKeyboardEnsureGeneration;
    BOOL _suppressStagedKeyboardEnd;
    CFAbsoluteTime _stagedKeyboardKeptAt;
    // Set only when the app or a minimize asked the keyboard to go away.
    // A resign without this is the home screen taking the key.
    BOOL _stagedKeyboardWantsHide;
    NSInteger _stagedKeyboardReassertCount;
    NSInteger _presentGeneration;
    NSMutableSet<NSNumber *> *_loadedAppHashes;
    NSMutableSet<NSNumber *> *_listeningAppHashes;
    NSMutableSet<NSNumber *> *_remoteKeyboardHashes;
    // Messenger is drawing keys in SpringBoard's window, so the card may lift
    // without dragging those keys. Until that window exists the card stays put.
    BOOL _keyboardDrawnOutside;
    // Chat apps keep their own field as first responder. While waiting for
    // SpringBoard's keyboard, keep raising windows instead of the proxy field.
    NSString *_hostedKeyboardRequestBundle;
    DSStageDragShellView *_dragShell;
    UIView *_topRim;
    CAShapeLayer *_topRimLayer;
    CAShapeLayer *_topRimPulseLayer;
    // 0 is the full rim. 1 pulses the bottom half, 2 the top half.
    NSInteger _topRimHalf;
    // Split keeps the scene on the card's real frame. Dragging the bottom card
    // grows the top one. Minimizing or terminating the bottom card clears this
    // and leaves the top card full screen via _expandedCard.
    BOOL _splitMode;
    BOOL _splitHomeRevealed;
    BOOL _splitContentPrepared;
    // The bottom card was dragged past the collapse line. The rest of that
    // gesture must not snap the top card back.
    BOOL _splitCollapseClosing;
    BOOL _applyingGeometryFix;
    DSStageContainerView *_expandedCard;
    CGFloat _splitResizeHeight;
    DSStageContainerView *_floatContainer;
    DSSceneHost *_floatSceneHost;
    DSAppPickerViewController *_floatPicker;
    UIPanGestureRecognizer *_floatDragPan;
    UIView *_floatRim;
    CAShapeLayer *_floatRimLayer;
    BOOL _floatActive;
    DSLaunchPlaceholderView *_floatLaunchPlaceholder;
    UIView *_floatParkPicture;
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
        _loadedAppHashes = [NSMutableSet set];
        _listeningAppHashes = [NSMutableSet set];
        _remoteKeyboardHashes = [NSMutableSet set];
        DSResetLiftSlots();
    }
    return self;
}

#pragma mark - Lifecycle

- (void)publishTraceContext:(NSString *)why {
    NSString *bottom = _sceneHost.isHosting ? (_sceneHost.bundleIdentifier ?: @"?") : @"-";
    NSString *top = _topSceneHost.isHosting ? (_topSceneHost.bundleIdentifier ?: @"?") : @"-";
    NSString *hover = _floatSceneHost.isHosting ? (_floatSceneHost.bundleIdentifier ?: @"?") : @"-";
    DSTraceSetContext([NSString stringWithFormat:@"%@ state=%ld split=%d bottom=%@ top=%@ hover=%@",
                       why ?: @"stage", (long)_state, _splitMode, bottom, top, hover]);
}

- (void)activate {
    if (_activated) return;
    _activated = YES;

    // Keep the previous boot's trace. A respring from a hang would otherwise
    // throw away the only record of what the main thread was inside.
    DSTraceArchivePreviousAndStart();

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
    [self refreshKeyboardDebugLabel];
    [self observeKeyboard];

    DSDiagnosticsRecordFormat(@"SpringBoard: stage ready, screen %@, corner %@, pull comes from %@",
                              NSStringFromCGRect([self screenBounds]),
                              NSStringFromCGRect([DSGestureController triggerRect]),
                              sSystemEdgePullAvailable ? @"the system edge gesture" : @"a window in the corner");
    [self publishTraceContext:@"ready"];
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
    root.backgroundColor = UIColor.clearColor;
    root.opaque = NO;
    UITapGestureRecognizer *statusPeek = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleStatusBarPeekTap:)];
    statusPeek.cancelsTouchesInView = NO;
    statusPeek.delaysTouchesBegan = NO;
    [root addGestureRecognizer:statusPeek];

    _container = [[DSStageContainerView alloc] initWithFrame:[self stageFrameForState:DSStageStateClosed]];
    _container.cornerRadius = [self cornerRadiusForState:DSStageStateOverlay];
    __weak __typeof(self) bandSelf = self;
    _container.keyboardBandLayoutHandler = ^{
        [bandSelf clipHostedSceneForKeyboardBandOnSlot:0];
    };
    _container.liftDidChangeHandler = ^{
        [bandSelf syncLiftChrome];
    };

    _dragShell = [[DSStageDragShellView alloc] initWithFrame:CGRectZero];
    _dragShell.cardView = _container;
    __weak __typeof(self) shellSelf = self;
    _dragShell.rejectsWindowPoint = ^BOOL(CGPoint windowPoint) {
        DSStageManager *manager = shellSelf;
        if (!manager || !manager->_topContainer || manager->_topContainer.hidden) return NO;
        if (manager->_stackSlotCount < kDSMaxStackSlots) return NO;
        if (manager->_container.liftOffset > 1.0) return NO;
        CGRect other = CGRectInset(manager->_topContainer.frame, kDSStageRimGrabBand, kDSStageRimGrabBand);
        return CGRectContainsPoint(other, windowPoint);
    };
    [_dragShell addSubview:_container];
    [root addSubview:_dragShell];
    _dragShell.hidden = YES;

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
    _secondOpenAppIcon = [[UIImageView alloc] initWithFrame:CGRectZero];
    _secondOpenAppIcon.contentMode = UIViewContentModeScaleAspectFit;
    _secondOpenAppIcon.layer.cornerRadius = 8.0;
    _secondOpenAppIcon.layer.cornerCurve = kCACornerCurveContinuous;
    _secondOpenAppIcon.clipsToBounds = YES;
    _secondOpenAppIcon.alpha = 0.0;
    [root addSubview:_secondOpenAppIcon];
    _terminateHint = [[UILabel alloc] initWithFrame:CGRectZero];
    _terminateHint.text = @"Terminate";
    _terminateHint.textAlignment = NSTextAlignmentCenter;
    _terminateHint.textColor = [UIColor colorWithWhite:1.0 alpha:0.42];
    _terminateHint.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
    _terminateHint.userInteractionEnabled = NO;
    _terminateHint.backgroundColor = UIColor.clearColor;
    _terminateHint.alpha = 0.0;
    [root addSubview:_terminateHint];
    _terminateGlow = [CAGradientLayer layer];
    _terminateGlow.colors = @[
        (id)[UIColor colorWithRed:0.85 green:0.08 blue:0.08 alpha:0.0].CGColor,
        (id)[UIColor colorWithRed:0.85 green:0.08 blue:0.08 alpha:0.10].CGColor,
    ];
    _terminateGlow.startPoint = CGPointMake(0.5, 0.0);
    _terminateGlow.endPoint = CGPointMake(0.5, 1.0);
    _terminateGlow.opacity = 0.0;
    [root.layer insertSublayer:_terminateGlow atIndex:0];

    _dragPan = [[DSQuickPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleStagePan:)];
    _dragPan.cancelsTouchesInView = YES;
    _dragPan.delaysTouchesBegan = NO;
    _dragPan.delegate = self;
    [_dragShell addGestureRecognizer:_dragPan];
    _swapPreviewHalf = -1;
    UITapGestureRecognizer *wakeTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleCardWakeTap:)];
    wakeTap.cancelsTouchesInView = NO;
    [_container addGestureRecognizer:wakeTap];

    _stackSlotCount = 1;
    __weak __typeof(self) weakAdd = self;
    _container.stackAddHandler = ^{
        [weakAdd addSecondStageAnimated:YES];
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
    _shelf.slotDragHandler = ^(UIGestureRecognizerState state, CGPoint point) {
        [weakSelf handleNewStageDrag:state atPoint:point];
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
// Resigning the window that is playing a video asserts and safe-modes, and
// the keyboard never comes up afterwards. makeKeyAndVisible resigns that
// window itself, so for this one call that resign is skipped. The video
// window is the only one skipped.
static UIWindow *DSResignSuppressedWindow = nil;
static IMP DSSavedResignKeyWindow = NULL;

static void DSResignKeyWindowBesideVideo(id self, SEL _cmd) {
    if (self == DSResignSuppressedWindow) return;
    if (DSSavedResignKeyWindow) ((void (*)(id, SEL))DSSavedResignKeyWindow)(self, _cmd);
}

static void DSMakeKeyBesidePlayingVideo(UIWindow *window) {
    if (!window) return;
    UIWindow *other = DSCompetingKeyWindow(window);
    Method method = other ? class_getInstanceMethod(object_getClass(other), @selector(resignKeyWindow)) : NULL;
    IMP previous = NULL;
    if (method) {
        DSResignSuppressedWindow = other;
        previous = method_setImplementation(method, (IMP)DSResignKeyWindowBesideVideo);
        DSSavedResignKeyWindow = previous;
    }
    @try {
        [window makeKeyAndVisible];
    } @catch (NSException *exception) {
    }
    if (method && previous) method_setImplementation(method, previous);
    DSResignSuppressedWindow = nil;
    DSSavedResignKeyWindow = NULL;
    DSHoldKeyboardLevelAboveStage();
}

- (void)takeKeyWindowForStageChrome {
    // Opening the card over a playing video must not touch the key window.
    // That steal is what flashes the video. The keyboard asks for the key
    // window when a field is actually tapped.
    if (DSVideoIsPlayingOnScreen()) return;
    [self takeKeyWindow];
}

- (void)takeKeyWindow {
    if ([DSSceneHost homeGestureIsActive]) return;
    // Taking the key window while Messages is typing resigns the field and
    // SpringBoard drops the keyboard. The keys are often still parked at the
    // bottom edge of the phone, so "on screen" misses them and the stage
    // takes the key window two seconds later. Messenger never does this mid-type.
    if (self.isStageVisible && !self.isPickerSearchActive) {
        CGRect typing = DSTypingKeyboardFrame();
        if (!CGRectIsNull(typing) && CGRectGetHeight(typing) >= 160.0) {
            NSString *bundle = self.stageBundleIdentifier;
            if (bundle.length > 0 && [self isHostingBundleIdentifier:bundle]) {
                static NSInteger kept = 0;
                if (kept < 4) {
                    kept += 1;
                    DSDiagnosticsRecordFormat(@"SpringBoard: left the key window alone, keyboard %@",
                                              NSStringFromCGRect(typing));
                }
                return;
            }
        }
    }
    if (!_window) {
        [self noteSearchKeyboardDebug:@"takeKey window=none"];
        return;
    }
    if (DSVideoIsPlayingOnScreen()) {
        if (!DSWindowIsApplicationKey(_window)) {
            static CFAbsoluteTime lastAttempt = 0;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            // The search field asks again until the keyboard is up. Repeating
            // the key change is the flicker.
            if (now - lastAttempt > 0.4) {
                lastAttempt = now;
                DSMakeKeyBesidePlayingVideo(_window);
            } else {
                DSHoldKeyboardLevelAboveStage();
            }
        } else {
            DSHoldKeyboardLevelAboveStage();
        }
        [self noteSearchKeyboardDebug:[self searchKeyboardDebugLine:_window.isKeyWindow ? @"takeKey beside video" : @"takeKey beside video failed"
                                                            attempt:-1
                                                             picker:nil]];
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
        // Resigning the video's window while it is playing asserts, and the
        // keyboard never comes up afterwards.
        if (!DSVideoIsPlayingOnScreen()) [other resignKeyWindow];
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
    if ([DSSceneHost homeGestureIsActive]) return;
    if (_searchSlot >= 0) {
        [self noteSearchKeyboardDebug:[self searchKeyboardDebugLine:@"give key back during search" attempt:-1 picker:nil]];
    }
    UIWindow *previous = _windowBeforeStage;
    _windowBeforeStage = nil;
    if (!_window.isKeyWindow) return;
    @try {
        // Leaving this window key is what drops the Home Screen inside the
        // stage. Resign it even when there is no window remembered to take over.
        if (previous) [previous makeKeyWindow];
        if (_window.isKeyWindow) [_window resignKeyWindow];
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
    [self takeKeyWindowForStageChrome];

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
    static int traceToken = NOTIFY_TOKEN_INVALID;
    static dispatch_once_t once;
    __weak __typeof(self) weakSelf = self;
    dispatch_once(&once, ^{
        notify_register_dispatch(kDSKeyboardRequestNotification, &requestToken, dispatch_get_main_queue(), ^(int token) {
            uint64_t state = 0;
            notify_get_state(token, &state);
            [weakSelf noteStagedAppKeyboardRequest:state];
        });
        notify_register_dispatch(kDSKeyboardTraceNotification, &traceToken, dispatch_get_main_queue(), ^(int token) {
            (void)token;
            NSString *line = [NSString stringWithContentsOfFile:kDSKeyboardTracePath
                                                       encoding:NSUTF8StringEncoding
                                                          error:nil];
            if (line.length == 0) return;
            DSLogAppend([@"[KEYS] " stringByAppendingString:line]);
            if ([line hasPrefix:@"kb "]) {
                [weakSelf noteAppReportedKeyboardLine:line];
            }
        });
    });
}

- (void)logKeys:(NSString *)line {
    if (line.length == 0) return;
    DSLogAppend([@"[KEYS] " stringByAppendingString:line]);
}

// One line per decision. Repeats are collapsed so a drag does not bury it.
- (void)logLift:(NSString *)line {
    if (line.length == 0) return;
    static NSString *last = nil;
    static NSInteger repeats = 0;
    if (last && [last isEqualToString:line]) {
        repeats += 1;
        if (repeats == 1 || repeats == 4) {
            DSLogAppend([NSString stringWithFormat:@"[LIFT] %@ (x%ld)", line, (long)(repeats + 1)]);
        }
        return;
    }
    repeats = 0;
    last = [line copy];
    DSLogAppend([@"[LIFT] " stringByAppendingString:line]);
}

- (NSString *)lowerStageLiftSummary:(CGRect)keyboard {
    NSInteger slot = [self slotOnBottomHalf];
    DSStageContainerView *card = [self containerForSlot:slot];
    CGRect placed = card ? [self placedFrameForCard:card state:DSStageStateOverlay] : CGRectZero;
    NSString *which = @"none";
    if (card == _container) which = @"primary";
    else if (card == _topContainer) which = @"second";
    else if (card == _floatContainer) which = @"float";
    return [NSString stringWithFormat:@"lower=%@ slot=%ld placed=%@ bottom=%.0f liftNow=%.0f keyTop=%.0f depth=%ld kFrame=%@ split=%d",
            which,
            (long)slot,
            NSStringFromCGRect(placed),
            CGRectGetMaxY(placed),
            card ? card.liftOffset : 0.0,
            CGRectGetMinY(keyboard),
            (long)[DSSceneHost sceneSettingsUpdateDepth],
            NSStringFromCGRect(_keyboardFrame),
            _splitMode];
}

- (void)keyboardWillShow:(NSNotification *)notification {
    CGRect keyboard = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    [self logKeys:[NSString stringWithFormat:@"uikit willShow frame=%@ staged=%ld search=%ld host=%d/%d %@",
                   NSStringFromCGRect(keyboard),
                   (long)_stagedKeyboardSlot,
                   (long)_searchSlot,
                   _sceneHost.isHosting,
                   _topSceneHost.isHosting,
                   [self lowerStageLiftSummary:keyboard]]];
    if (_searchSlot >= 0) {
        [self noteSearchKeyboardDebug:[NSString stringWithFormat:@"UIKit willShow %@", NSStringFromCGRect(keyboard)]];
    }
    if (![self isShowingAppPicker] && _stagedKeyboardSlot < 0 &&
        !_sceneHost.isHosting && !_topSceneHost.isHosting) return;
    [self keyboardFrameWillChange:notification];
}

- (void)keyboardFrameWillChange:(NSNotification *)notification {
    CGRect keyboard = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [self logKeys:[NSString stringWithFormat:@"uikit change frame=%@ staged=%ld search=%ld owner=%@ req=%@ %@",
                   NSStringFromCGRect(keyboard),
                   (long)_stagedKeyboardSlot,
                   (long)_searchSlot,
                   _keyboardLiftOwner ?: @"-",
                   _hostedKeyboardRequestBundle ?: @"-",
                   [self lowerStageLiftSummary:keyboard]]];
    if (_stagedKeyboardSlot >= 0 &&
        CGRectGetMinY(keyboard) >= CGRectGetHeight(UIScreen.mainScreen.bounds) - 1.0) {
        static NSInteger parkedLogs = 0;
        if (parkedLogs < 8) {
            parkedLogs += 1;
            DSDiagnosticsRecordFormat(@"SpringBoard: UIKit moving the keyboard off the bottom %@ fr=%d",
                                      NSStringFromCGRect(keyboard),
                                      _stagedKeyboardField.isFirstResponder);
        }
        if (_stagedKeyboardField.isFirstResponder && !_stagedKeyboardWantsHide && _searchSlot < 0) {
            if (DSReturnParkedKeyboardHost(keyboard)) return;
        }
    }
    // UIKit in SpringBoard also posts this when a staged app's keyboard moves.
    // Treating that as SpringBoard's own keyboard is what lifted the card 306pt
    // and dragged Messenger's keys back inside the chrome.
    if (_searchSlot < 0 && _stagedKeyboardSlot < 0 &&
        (_sceneHost.isHosting || _topSceneHost.isHosting)) {
        NSString *bundle = [self hostedBundleForKeyboardNotifications];
        if ([self appKeepsItsOwnKeyboard:bundle]) return;
        if (bundle.length > 0) {
            // Only this slot's own keyboard may move its card. A SpringBoard
            // notification while Spotlight, Edge, or Filza is typing is not
            // that keyboard.
            BOOL owns = _keyboardLiftOwner.length > 0 && [bundle isEqualToString:_keyboardLiftOwner];
            BOOL requested = _hostedKeyboardRequestBundle.length > 0 &&
                             [bundle isEqualToString:_hostedKeyboardRequestBundle];
            if (!owns && !requested && ![self hostedAppReportedRemoteKeyboard:bundle]) {
                [self logKeys:[NSString stringWithFormat:@"uikit change had no owner bundle=%@ h=%.0f",
                               bundle, CGRectGetHeight(keyboard)]];
                // Both stages are up and nobody has claimed the keys yet. This
                // guess is the bottom card. Applying it throws the top card off
                // the screen, and the real note then pulls it back down.
                BOOL twoLive = _stackSlotCount >= kDSMaxStackSlots &&
                    _sceneHost.isHosting && !_primaryParked &&
                    _topSceneHost.isHosting && !_secondParked &&
                    _keyboardLiftOwner.length == 0 &&
                    _hostedKeyboardRequestBundle.length == 0;
                if (!twoLive && CGRectGetHeight(keyboard) >= 150.0) {
                    [self noteKeyboardFrame:keyboard source:bundle duration:duration];
                }
                return;
            }
            if ([self hostedAppReportedRemoteKeyboard:bundle] || owns || requested) {
                (void)DSRaiseKeyboardWindowAboveStage();
                if ([self springBoardIsDrawingKeyboard]) {
                    [self noteKeyboardFrame:keyboard source:bundle duration:duration];
                }
                return;
            }
            return;
        }
    }
    [self noteKeyboardFrame:keyboard source:@"SpringBoard" duration:duration];
}

- (void)keyboardWillHide:(NSNotification *)notification {
    CGRect end = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    [self logKeys:[NSString stringWithFormat:@"uikit willHide end=%@ staged=%ld search=%ld %@",
                   NSStringFromCGRect(end),
                   (long)_stagedKeyboardSlot,
                   (long)_searchSlot,
                   [self lowerStageLiftSummary:end]]];
    // Hiding the in-card key chrome posts a hide. The picker keyboard is still
    // on screen, and clearing its frame drops the card onto the keys.
    if (_stagedKeyboardSlot >= 0 && _stagedKeyboardField.isFirstResponder) {
        CGRect visible = DSVisibleStagedKeyboardFrameOnScreen();
        if (!CGRectIsNull(visible)) {
            CGRect end = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
            [self logKeys:[NSString stringWithFormat:@"willHide kept, stand-in still editing end=%@ keys=%@ slot=%ld",
                           NSStringFromCGRect(end),
                           NSStringFromCGRect(visible),
                           (long)_stagedKeyboardSlot]];
            [self logLift:[NSString stringWithFormat:@"willHide editing frameEmpty=%d %@",
                           CGRectIsEmpty(_keyboardFrame),
                           [self lowerStageLiftSummary:visible]]];
            // The keys are up. A hide we refuse must still put the card above them,
            // including when an earlier pass stored the frame and left the lift at 0.
            if (CGRectGetHeight(visible) >= 150.0) {
                [self noteKeyboardFrame:visible source:@"SpringBoard" duration:0.2];
            }
            return;
        }
    }
    if (_searchSlot < 0 && _stagedKeyboardSlot < 0 && [self hostedKeyboardStaysWithTheApp]) {
        [self logKeys:@"willHide kept, app draws its own keyboard"];
        return;
    }
    // Beeper's keyboard blips through a hide and a 45pt dock strip. Dropping
    // the lift there is what leaves Beeper to slide its own composer.
    if (_searchSlot < 0 && _stagedKeyboardSlot < 0 &&
        (_sceneHost.isHosting || _topSceneHost.isHosting) &&
        [self springBoardIsDrawingKeyboard]) {
        CGRect visible = DSVisibleStagedKeyboardFrameOnScreen();
        [self logKeys:[NSString stringWithFormat:@"willHide kept, keys still on screen %@",
                       NSStringFromCGRect(visible)]];
        [self logLift:[NSString stringWithFormat:@"willHide on-screen frameEmpty=%d %@",
                       CGRectIsEmpty(_keyboardFrame),
                       [self lowerStageLiftSummary:visible]]];
        if (CGRectGetHeight(visible) >= 150.0) {
            NSString *source = _keyboardLiftOwner.length > 0 ? _keyboardLiftOwner : @"SpringBoard";
            [self noteKeyboardFrame:visible source:source duration:0.2];
        }
        return;
    }
    if (_searchSlot < 0 && _stagedKeyboardSlot < 0) DSReleaseKeyboardLevelHold();
    if (_searchSlot >= 0) {
        [self noteSearchKeyboardDebug:@"UIKit willHide"];
    }
    if ([self isShowingAppPicker] || _stagedKeyboardSlot >= 0) _notedKeyboardOnce = NO;
    [self noteKeyboardFrame:CGRectZero
                    source:@"SpringBoard"
                  duration:[notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue]];
}

- (NSString *)primaryHostedBundleIdentifier {
    if (_sceneHost.isHosting) return _sceneHost.bundleIdentifier;
    if (_topSceneHost.isHosting) return _topSceneHost.bundleIdentifier;
    return nil;
}

- (BOOL)stagedTypingSessionActive {
    if (!_sceneHost.isHosting && !_topSceneHost.isHosting) return NO;
    if (_hostedKeyboardRequestBundle.length > 0) return YES;
    if (_keyboardDrawnOutside) return YES;
    if (!CGRectIsEmpty(_keyboardFrame)) return YES;
    return [self springBoardIsDrawingKeyboard];
}

- (BOOL)shouldRestoreKeyboardPlacementAfterDismiss:(NSString *)source {
    // The stand-in is still the editor. This down report is UIKit parking
    // the host, not the user leaving. Restoring here is the keyboard vanishing.
    if ([self stagedKeyboardFieldIsEditing]) return NO;
    if (!_sceneHost.isHosting && !_topSceneHost.isHosting) return YES;
    // Messages reports the keyboard down a few seconds after the first letter
    // while the keys are still at the bottom of the phone. Dropping the
    // windows then is what freezes them.
    if ([self springBoardIsDrawingKeyboard]) return NO;
    // A down report from the app still on the stage drops the keyboard window
    // back under the card. Leave it in front until that app is no longer hosted.
    if ([self isHostingBundleIdentifier:source]) return NO;
    // Spotlight dismissing its own keyboard was restoring the Messages window
    // while the keys were still up.
    if ([self isHostingBundleIdentifier:@"com.apple.MobileSMS"]) return NO;
    if (![self stagedTypingSessionActive]) return YES;
    return NO;
}

- (BOOL)shouldIgnoreForeignKeyboardEventFrom:(NSString *)source onScreen:(BOOL)onScreen {
    if (source.length == 0 || [self isHostingBundleIdentifier:source]) return NO;
    if (![self stagedTypingSessionActive]) return NO;
    if ([source isEqualToString:@"SpringBoard"] && _searchSlot >= 0) return NO;
    if (onScreen) return YES;
    if ([self springBoardIsDrawingKeyboard]) return YES;
    return NO;
}

- (void)keyboardOnScreen:(BOOL)onScreen frame:(CGRect)frame source:(NSString *)source {
    if (!onScreen && DSPhoneCallIsActive() && [self stagedTypingSessionActive]) {
        DSDiagnosticsRecord(@"SpringBoard: left the staged keyboard up during a call");
        return;
    }
    if ([self appKeepsItsOwnKeyboard:source]) {
        static NSInteger logs = 0;
        if (logs < 4) {
            logs += 1;
            DSBeeperDetailLogFormat(@"SB left %@ keyboard alone on=%d frame=%@",
                                    source, onScreen, NSStringFromCGRect(frame));
            DSDiagnosticsRecordFormat(@"SpringBoard: %@ keeps its own keyboard on=%d",
                                      source, onScreen);
        }
        return;
    }
    // Picker search owns this window's keyboard. Do not retarget it.
    if (_searchSlot >= 0) return;
    if (!onScreen && [self isHostingBundleIdentifier:source] && !CGRectIsNull(DSVisibleStagedKeyboardFrameOnScreen())) {
        return;
    }
    if (!onScreen && [self stagedTypingSessionActive] && !CGRectIsNull(DSVisibleStagedKeyboardFrameOnScreen())) {
        return;
    }
    if ([self shouldIgnoreForeignKeyboardEventFrom:source onScreen:onScreen]) {
        static NSString *loggedForeign = nil;
        if (source.length && ![loggedForeign isEqualToString:source]) {
            loggedForeign = [source copy];
            DSDiagnosticsRecordFormat(@"SpringBoard: ignored %@ keyboard while %@ is typing on the stage",
                                      source, [self primaryHostedBundleIdentifier] ?: @"?");
        }
        return;
    }
    if ([self isHostingBundleIdentifier:source]) {
        if (onScreen) {
            _keyboardLiftOwner = [source copy];
        } else if (_keyboardLiftOwner.length == 0 || [_keyboardLiftOwner isEqualToString:source]) {
            _keyboardLiftOwner = nil;
        }
        if ([source isEqualToString:@"com.beeper.chat.ios"]) {
            [self handleKeyboardForBundle:source
                                    slot:[self slotOwningKeyboardSource:source]
                                      on:onScreen
                                   frame:onScreen ? frame : CGRectZero];
        }
        // The message field stays the editor. A SpringBoard text field here
        // would steal the caret and the letters would never leave SpringBoard.
        [self noteHostedAppKeyboard:onScreen frame:frame source:source];
        return;
    }
    if (_stagedKeyboardSlot >= 0) return;
    [self noteKeyboardFrame:onScreen ? frame : CGRectZero
                    source:source.length > 0 ? source : @"an app"
                  duration:0.25];
    if (!onScreen) return;
    [self giveBackKeyWindow];
}

- (BOOL)isPickerSearchActive {
    return _searchSlot >= 0;
}

- (BOOL)stagedKeyboardFieldIsEditing {
    return _stagedKeyboardSlot >= 0 && !_stagedKeyboardWantsHide && _stagedKeyboardField.isFirstResponder;
}

- (BOOL)shouldForwardHostedKeyboardText {
    if (_searchSlot >= 0) return NO;
    // The picker field already forwards each letter. Sending it again from
    // UIKeyboardImpl types every character twice.
    if (_stagedKeyboardSlot >= 0) return NO;
    if (_state == DSStageStateMinimized || _state == DSStageStateClosed) return NO;
    return _sceneHost.isHosting || _topSceneHost.isHosting;
}

- (void)forwardHostedKeyboardText:(NSString *)text {
    if (text.length == 0 || ![self shouldForwardHostedKeyboardText]) return;
    [self stagedKeyboardInsertText:text];
}

- (void)forwardHostedKeyboardDelete {
    if (![self shouldForwardHostedKeyboardText]) return;
    [self stagedKeyboardDeleteBackward];
}

- (void)clearHostedKeyboardBands {
    [_sceneHost setKeyboardClipHeight:0.0];
    [_topSceneHost setKeyboardClipHeight:0.0];
    _container.keyboardBandHeight = 0.0;
    if (_topContainer) _topContainer.keyboardBandHeight = 0.0;
}

- (void)clipHostedSceneForKeyboardBandOnSlot:(NSInteger)slot {
    DSStageContainerView *card = [self containerForSlot:slot];
    DSSceneHost *host = [self sceneHostForSlot:slot];
    if (!card || !host.isHosting) return;
    CGFloat band = card.keyboardBandHeight;
    if (band > 1.0) {
        [host setKeyboardClipHeight:band];
    } else if (host.keyboardClipHeight > 1.0) {
        [host setKeyboardClipHeight:0.0];
    }
}

// Scene extension was removed: resizing the hosted scene on every keyboard
// frame made Messenger's card jump. Clipping uses keyboardClipHeight only.
- (void)extendHostedSceneForKeyboard:(CGRect)keys source:(NSString *)source {
    (void)keys;
    (void)source;
}

- (void)beginMessagesKeyboardWatch:(CGRect)frame {
    if (DSMessagesKeyboardWatchArmed) return;
    DSMessagesKeyboardWatchArmed = YES;
    NSInteger watch = ++DSMessagesKeyboardWatch;
    [self watchMessagesKeyboardAttempt:0
                            generation:DSHostedClipGeneration
                                 watch:watch
                                 frame:frame];
}

- (void)watchMessagesKeyboardAttempt:(NSInteger)attempt
                           generation:(NSInteger)generation
                                watch:(NSInteger)watch
                                frame:(CGRect)frame {
    if (attempt >= 4) {
        if (watch == DSMessagesKeyboardWatch) DSMessagesKeyboardWatchArmed = NO;
        DSDiagnosticsRecordFormat(@"SpringBoard: Messages keys never appeared on SpringBoard. cause=%@",
                                  DSWhyFullKeyboardMissed());
        return;
    }
    static const NSTimeInterval delays[4] = { 0.30, 0.60, 1.00, 1.00 };
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[attempt] * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        DSStageManager *manager = weakSelf;
        if (!manager || watch != DSMessagesKeyboardWatch || generation != DSHostedClipGeneration) {
            if (watch == DSMessagesKeyboardWatch) DSMessagesKeyboardWatchArmed = NO;
            return;
        }
        if (![manager isHostingBundleIdentifier:@"com.apple.MobileSMS"] ||
            ![manager hostedAppReportedRemoteKeyboard:@"com.apple.MobileSMS"]) {
            DSMessagesKeyboardWatchArmed = NO;
            return;
        }
        CGRect keys = DSVisibleStagedKeyboardFrameOnScreen();
        if (CGRectIsNull(keys)) {
            [manager watchMessagesKeyboardAttempt:attempt + 1
                                       generation:generation
                                            watch:watch
                                            frame:frame];
            return;
        }
        DSMessagesKeyboardWatchArmed = NO;
        [manager noteHostedAppKeyboard:YES frame:keys source:@"com.apple.MobileSMS"];
    });
}

- (BOOL)springBoardIsDrawingKeyboard {
    return !CGRectIsNull(DSVisibleStagedKeyboardFrameOnScreen());
}

- (void)noteHostedAppKeyboard:(BOOL)onScreen frame:(CGRect)frame source:(NSString *)source {
    DSTraceFormat(@"keyboard note on=%d src=%@ frame=%@", onScreen, source ?: @"?", NSStringFromCGRect(frame));
    DSSetMessagesKeyboardIsUp([source isEqualToString:@"com.apple.MobileSMS"] && onScreen);
    NSInteger hostedSlot = [self slotForHostedBundle:source];
    if (hostedSlot >= 0) {
        [[self sceneHostForSlot:hostedSlot] setMessagesKeyboardVisible:onScreen];
        if ([source isEqualToString:@"com.apple.MobileSMS"]) {
            [[self containerForSlot:hostedSlot] setClipsContents:!onScreen];
        }
    }
    [self publishTraceContext:[NSString stringWithFormat:@"keyboard %@ on=%d", source ?: @"?", onScreen]];
    if (_searchSlot >= 0) return;
    if (!onScreen) {
        CGRect stillUp = DSVisibleStagedKeyboardFrameOnScreen();
        BOOL chromeStillThere = !CGRectIsNull(stillUp);
        // The tall keyboard is gone, so the other cards come back. A short
        // strip is the Messages quick bar: leave that host alone.
        if (!chromeStillThere || CGRectGetHeight(stillUp) < 150.0) {
            [self noteKeyboardFrame:CGRectZero source:source duration:0.0];
        }
        if (chromeStillThere) return;
        // Put the keyboard window back only after it has gone away. Doing this
        // on the way up was returning it to level 10 under the stage.
        DSRestoreRemoteKeyboardPlacement();
        [_container setClipsContents:YES];
        [_topContainer setClipsContents:YES];
        DSHostedClipGeneration++;
        [self clearHostedKeyboardBands];
        DSReleaseStagedKeyboardHost();
        _keyboardDrawnOutside = NO;
        [self noteKeyboardFrame:CGRectZero source:source duration:0.0];
        return;
    }
    // Same keyboard window the other staged apps use. Messages does not wait
    // on its own watch, and the card is not lifted for a keyboard that is not up.
    // Raising again while the keys are already on screen unhides the window
    // and the keys flash off and on for every letter.
    if ([source isEqualToString:@"com.beeper.chat.ios"] && onScreen) {
        DSRaiseVisibleKeyboardAboveStage();
    }
    BOOL alreadyUp = NO;
    CGRect alreadyFrame = CGRectNull;
    if ([source isEqualToString:@"com.apple.MobileSMS"]) {
        alreadyFrame = DSVisibleFullKeyboardFrameOnScreen();
        CGFloat screenH = CGRectGetHeight(UIScreen.mainScreen.bounds);
        alreadyUp = !CGRectIsNull(alreadyFrame) &&
                    CGRectGetHeight(alreadyFrame) >= 160.0 &&
                    CGRectGetMinY(alreadyFrame) < screenH - 1.0 &&
                    CGRectGetMinY(alreadyFrame) > screenH * 0.35;
    }
    BOOL raised = NO;
    if (alreadyUp) {
        static NSInteger skipLogs = 0;
        if (skipLogs < 6) {
            skipLogs += 1;
            DSDiagnosticsRecordFormat(@"SpringBoard: keyboard already up %@, not raised again",
                                      NSStringFromCGRect(alreadyFrame));
        }
        raised = YES;
    } else {
        raised = DSRaiseKeyboardWindowAboveStage();
    }
    [_container setClipsContents:!raised];
    [_topContainer setClipsContents:!raised];
    if ([source isEqualToString:@"com.apple.MobileSMS"]) {
        NSInteger slot = [self slotForHostedBundle:source];
        if (slot >= 0) [[self containerForSlot:slot] setClipsContents:NO];
    }
    if (raised && !alreadyUp) {
        NSInteger generation = DSHostedClipGeneration;
        NSString *sourceCopy = [source copy];
        CGRect frameCopy = frame;
        __weak __typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            DSStageManager *manager = weakSelf;
            if (!manager || generation != DSHostedClipGeneration) return;
            BOOL stillUp = DSRaiseKeyboardWindowAboveStage();
            [manager->_container setClipsContents:!stillUp];
            [manager->_topContainer setClipsContents:!stillUp];
            if ([sourceCopy isEqualToString:@"com.apple.MobileSMS"]) {
                NSInteger slot = [manager slotForHostedBundle:sourceCopy];
                if (slot >= 0) [[manager containerForSlot:slot] setClipsContents:NO];
            }
            // The first event often arrives before the key view is in the window.
            // The windows are already where 4.5.50 put them. This only lifts the card.
            if (![manager springBoardIsDrawingKeyboard]) return;
            manager->_keyboardDrawnOutside = YES;
            CGRect later = [manager keyboardFrameOnDisplay:frameCopy];
            if (CGRectIsEmpty(later)) later = frameCopy;
            [manager extendHostedSceneForKeyboard:later source:sourceCopy];
            [manager noteKeyboardFrame:later source:sourceCopy duration:0.2];
        });
    }
    // The keyboard windows are already on the stage scene. Lift when those
    // keys are actually on the display. Waiting for the app's remote signal
    // is why the card sometimes never moved: Signal's keys were on screen
    // and the signal had not arrived. Do not lift before the keys are there,
    // or the card drags the in-scene keyboard with it.
    BOOL springBoardDrawingKeys = [self springBoardIsDrawingKeyboard];
    _keyboardDrawnOutside = springBoardDrawingKeys;
    CGRect visibleKeys = DSVisibleKeyboardFrameOnScreen();
    [self clearHostedKeyboardBands];
    CGRect keys = [self keyboardFrameOnDisplay:frame];
    if (CGRectIsEmpty(keys)) keys = frame;
    if (springBoardDrawingKeys) [self extendHostedSceneForKeyboard:keys source:source];
    [self noteKeyboardFrame:keys source:source duration:0.25];
    (void)visibleKeys;
}

- (NSInteger)slotForHostedBundle:(NSString *)bundle {
    if (bundle.length == 0) return -1;
    if (_sceneHost.isHosting && [_sceneHost.bundleIdentifier isEqualToString:bundle]) return 0;
    if (_topSceneHost.isHosting && [_topSceneHost.bundleIdentifier isEqualToString:bundle]) return 1;
    if (_floatSceneHost.isHosting && [_floatSceneHost.bundleIdentifier isEqualToString:bundle]) return 2;
    return -1;
}

- (void)ensureStagedKeyboardField {
    if (_stagedKeyboardField) return;
    // A 2pt field stalls the keyboard after one letter: the caret has nowhere
    // to go, and the next tap never reaches the keys. Wide, and off the phone.
    DSStagedKeyboardField *field = [[DSStagedKeyboardField alloc] initWithFrame:CGRectMake(0, -200, 430, 44)];
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
    // isKeyWindow can be true while another window (System Aperture, the home
    // screen) is also key. Search still starts editing in that state. Bailing
    // here is what left Messages with no keyboard.
    if (!DSWindowIsApplicationKey(_window) && !DSVideoIsPlayingOnScreen()) {
        [_window makeKeyAndVisible];
        if (attempt == 0) {
            DSDiagnosticsRecordFormat(@"SpringBoard: %@ keyboard starts while another window is also key", bundle);
        }
    }
    CGRect visibleKeys = DSVisibleKeyboardFrameOnScreen();
    // A 75pt strip at the bottom of the screen is the dock, not the keyboard.
    BOOL keysVisible = !CGRectIsNull(visibleKeys) && CGRectGetHeight(visibleKeys) >= 160.0;
    // Resigning a field that is already taking keys moves the input somewhere else.
    if (field.isFirstResponder && attempt >= 2 && !keysVisible && !DSVideoIsPlayingOnScreen()) {
        field.suppressEnd = YES;
        [field resignFirstResponder];
        field.suppressEnd = NO;
    }
    if (!field.isFirstResponder) {
        [field becomeFirstResponder];
    }
    BOOL raised = field.isFirstResponder ? DSRaiseKeyboardWindowAboveStage() : NO;
    if ([bundle isEqualToString:@"com.apple.MobileSMS"]) {
        CGRect full = DSVisibleFullKeyboardFrameOnScreen();
        if (!CGRectIsNull(full)) [self postMessagesKeyboardShown:YES];
    }
    if (attempt == 0 || attempt >= 4) {
        CGRect keys = DSVisibleKeyboardFrameOnScreen();
        DSDiagnosticsRecordFormat(@"SpringBoard: %@ keyboard drive attempt %ld fr=%d key=%d raised=%d visible=%@",
                                  bundle,
                                  (long)attempt,
                                  field.isFirstResponder,
                                  DSWindowIsApplicationKey(_window),
                                  raised,
                                  NSStringFromCGRect(keys));
        if (attempt >= 4 && (CGRectIsNull(keys) || CGRectGetHeight(keys) < 160.0)) {
            DSDiagnosticsRecord(DSKeyboardWindowCensus());
        }
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
        if (!CGRectIsNull(keys) && CGRectGetHeight(keys) >= 160.0 &&
            (strongSelf->_window.isKeyWindow || DSVideoIsPlayingOnScreen())) {
            DSDiagnosticsRecordFormat(@"SpringBoard: %@ picker keyboard visible %@", bundle, NSStringFromCGRect(keys));
            if ([bundle isEqualToString:@"com.apple.MobileSMS"]) {
                [strongSelf postMessagesKeyboardShown:YES];
            }
            CGRect full = DSVisibleFullKeyboardFrameOnScreen();
            if (CGRectIsNull(full)) full = keys;
            [strongSelf noteKeyboardFrame:full source:@"SpringBoard" duration:0.2];
            return;
        }
        if (attempt >= 5) {
            DSDiagnosticsRecordFormat(@"SpringBoard: %@ picker keyboard did not appear", bundle);
            DSDiagnosticsRecord(DSKeyboardWindowCensus());
            return;
        }
        [strongSelf driveStagedKeyboardForBundle:bundle slot:slot generation:generation attempt:attempt + 1];
        [strongSelf ensureStagedKeyboardForBundle:bundle slot:slot generation:generation attempt:attempt + 1];
    });
}

- (void)postMessagesKeyboardShown:(BOOL)shown {
    static int token = NOTIFY_TOKEN_INVALID;
    if (token == NOTIFY_TOKEN_INVALID) {
        notify_register_check(kDSKeyboardShownNotification, &token);
    }
    uint64_t state = DSIdentifierHash(@"com.apple.MobileSMS");
    if (shown) state |= kDSStageStateActiveBit;
    if (token != NOTIFY_TOKEN_INVALID) notify_set_state(token, state);
    notify_post(kDSKeyboardShownNotification);
    DSDiagnosticsRecord(shown ? @"SpringBoard: told Messages the keyboard is on screen"
                              : @"SpringBoard: told Messages the keyboard is gone");
}

- (BOOL)bundlePrefersHostedTextFieldKeyboard:(NSString *)bundle {
    (void)bundle;
    // Messages used to take this path. It raised SBMedusaHostedKeyboardWindow
    // with no keys, then the app sent show=0 and the keyboard was hidden.
    // Every staged app uses the picker keyboard, docked at the bottom of the phone.
    return NO;
}

- (void)applyHostedKeyboardChrome:(BOOL)keyboardUp {
    // The keys are UITextEffectsWindow, above this stage. Unclipping the card
    // does not move them, and it leaves the picker square.
    (void)keyboardUp;
    [_container setClipsContents:YES];
    if (_topContainer) [_topContainer setClipsContents:YES];
}

- (void)raiseSpringBoardKeyboardForHostedBundle:(NSString *)bundle slot:(NSInteger)slot {
    _hostedKeyboardRequestBundle = [bundle copy];
    _stagedKeyboardWantsHide = NO;
    _stagedKeyboardReassertCount = 0;
    _stagedKeyboardEnsureGeneration++;
    notify_post(kDSStageGeometryNotification);
    notify_post(kDSStagePeerNotification);
    BOOL raised = DSRaiseKeyboardWindowAboveStage();
    [self applyHostedKeyboardChrome:raised];
    DSDiagnosticsRecordFormat(@"SpringBoard: %@ keyboard via hosted field raised=%d",
                              bundle, raised);
    if ([bundle isEqualToString:@"com.apple.MobileSMS"]) {
        [self beginMessagesKeyboardWatch:CGRectZero];
    }
    __weak __typeof(self) weakSelf = self;
    for (NSInteger attempt = 0; attempt < 6; attempt++) {
        NSTimeInterval delay = 0.12 + attempt * 0.18;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            DSStageManager *manager = weakSelf;
            if (!manager) return;
            if (![manager->_hostedKeyboardRequestBundle isEqualToString:bundle]) return;
            if ([manager slotForHostedBundle:bundle] != slot) return;
            (void)DSRaiseKeyboardWindowAboveStage();
            if (![manager springBoardIsDrawingKeyboard]) return;
            manager->_hostedKeyboardRequestBundle = nil;
            CGRect keys = DSVisibleStagedKeyboardFrameOnScreen();
            if (!CGRectIsNull(keys)) {
                [manager noteHostedAppKeyboard:YES frame:keys source:bundle];
            }
        });
    }
}

- (void)showStagedKeyboardLikePickerForBundle:(NSString *)bundle {
    if (_searchSlot >= 0) {
        DSDiagnosticsRecord(@"SpringBoard: staged keyboard stayed down, search is open");
        return;
    }
    if (_state == DSStageStateClosed) {
        DSDiagnosticsRecordFormat(@"SpringBoard: staged keyboard stayed down, stage state %ld", (long)_state);
        return;
    }
    NSInteger slot = [self slotForHostedBundle:bundle];
    if (slot < 0) {
        DSDiagnosticsRecordFormat(@"SpringBoard: staged keyboard stayed down, %@ has no slot", bundle);
        return;
    }
    if (_state == DSStageStateMinimized) {
        DSStageContainerView *card = [self containerForSlot:slot];
        if ([self cardIsParked:card]) {
            NSInteger half = [self halfForContainer:card];
            DSDiagnosticsRecordFormat(@"SpringBoard: bringing %@ back from the corner for the keyboard", bundle);
            [self revealHalf:half animated:NO];
        } else {
            _state = DSStageStateOverlay;
            _window.hidden = NO;
            _dragShell.hidden = NO;
            _dragShell.alpha = 1.0;
            [self layoutAllStackSlotsForState:DSStageStateOverlay];
        }
    }
    if ([self cardIsParked:[self containerForSlot:slot]]) {
        DSDiagnosticsRecordFormat(@"SpringBoard: staged keyboard stayed down, %@ is parked", bundle);
        return;
    }
    if ([self bundlePrefersHostedTextFieldKeyboard:bundle]) {
        [self raiseSpringBoardKeyboardForHostedBundle:bundle slot:slot];
        return;
    }
    _hostedKeyboardRequestBundle = nil;
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
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (generation != strongSelf->_stagedKeyboardEnsureGeneration) return;
        if ([strongSelf hostedAppHasStageDylib:bundle]) return;
        DSDiagnosticsRecordFormat(@"SpringBoard: %@ has not loaded the stage dylib - letters stay in SpringBoard until it does",
                                  bundle);
    });
}

- (void)hideStagedKeyboardLikePicker {
    NSString *hiding = _hostedKeyboardRequestBundle;
    if (hiding.length == 0) hiding = [self hostedBundleForStagedKeyboard];
    _hostedKeyboardRequestBundle = nil;
    [self applyHostedKeyboardChrome:NO];
    if ([hiding isEqualToString:@"com.apple.MobileSMS"]) {
        [self postMessagesKeyboardShown:NO];
    }
    NSString *caller = @"?";
    for (NSString *frame in [NSThread callStackSymbols]) {
        if ([frame rangeOfString:@"DSStage"].location == NSNotFound &&
            [frame rangeOfString:@"Tweak"].location == NSNotFound) continue;
        caller = frame.length > 160 ? [frame substringToIndex:160] : frame;
        break;
    }
    NSString *why = [NSString stringWithContentsOfFile:@"/var/tmp/com.recreated.dynamicstage.keyboard-why"
                                              encoding:NSUTF8StringEncoding
                                                 error:nil];
    DSDiagnosticsRecordFormat(@"SpringBoard: hiding the staged keyboard fr=%d keys=%@ why=%@ caller=%@",
                              _stagedKeyboardField.isFirstResponder,
                              NSStringFromCGRect(DSVisibleKeyboardFrameOnScreen()),
                              why.length ? why : @"-",
                              caller);
    DSReleaseKeyboardLevelHold();
    _stagedKeyboardWantsHide = YES;
    _stagedKeyboardEnsureGeneration++;
    if (_stagedKeyboardField.isFirstResponder) {
        [_stagedKeyboardField resignFirstResponder];
    }
    _stagedKeyboardSlot = -1;
    // Resigning the field does not always deliver a keyboard-down. The top
    // card was left shifted, and the keys stayed on screen.
    [self collapseHostedKeyboardLift];
}

- (void)collapseHostedKeyboardLift {
    [self logKeys:[NSString stringWithFormat:@"collapse split=%d float=%d slot=%ld frame=%@ lift=%.0f/%.0f/%.0f",
                   _splitMode,
                   _floatActive,
                   (long)_keyboardLiftSlot,
                   NSStringFromCGRect(_keyboardFrame),
                   [self liftOffsetForSlot:0],
                   [self liftOffsetForSlot:1],
                   [self liftOffsetForSlot:2]]];
    _keyboardFrame = CGRectZero;
    _keyboardDrawnOutside = NO;
    _keyboardLiftOwner = nil;
    _notedKeyboardOnce = NO;
    [self clearHostedKeyboardBands];
    if (_splitMode || _floatActive) {
        [UIView performWithoutAnimation:^{
            [self applySplitKeyboardShiftForKeyboard:CGRectZero owner:nil];
        }];
        return;
    }
    [UIView performWithoutAnimation:^{
        [self liftCardBy:0.0 slot:0 duration:0.0];
        if (_stackSlotCount >= kDSMaxStackSlots) [self liftCardBy:0.0 slot:1 duration:0.0];
        if (_floatActive) [self liftCardBy:0.0 slot:2 duration:0.0];
    }];
}

- (void)keepStagedKeyboardField {
    _stagedKeyboardKeptAt = CFAbsoluteTimeGetCurrent();
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
    BOOL hosting = [self isHostingBundleIdentifier:bundle];
    NSString *why = [NSString stringWithContentsOfFile:@"/var/tmp/com.recreated.dynamicstage.keyboard-why"
                                              encoding:NSUTF8StringEncoding
                                                 error:nil];
    BOOL userCancel = [why rangeOfString:@"cancel=1"].location != NSNotFound;
    [self logKeys:[NSString stringWithFormat:@"req %@ %@ host=%d fr=%d slot=%ld split=%d why=%@",
                   bundle ?: @"?",
                   show ? @"show" : @"hide",
                   hosting,
                   _stagedKeyboardField.isFirstResponder,
                   (long)_stagedKeyboardSlot,
                   _splitMode,
                   why.length ? why : @"-"]];
    if (!hosting) {
        [self logKeys:@"req ignored, app is not on a card"];
        return;
    }
    if (_searchSlot >= 0) {
        [self logKeys:@"req ignored, picker search is open"];
        return;
    }
    // Docking a second keyboard host resigns the field and Messages sends hide.
    // The staged field was just put back, so that hide is not the user leaving.
    // Cancel is the user leaving, even inside that window.
    if (!show && !userCancel && DSPhoneCallIsActive()) {
        [self logKeys:[NSString stringWithFormat:@"hide ignored, a call is up %@", bundle ?: @"?"]];
        [self keepStagedKeyboardField];
        return;
    }
    if (!show && !userCancel && CFAbsoluteTimeGetCurrent() - _stagedKeyboardKeptAt < 1.0) {
        [self logKeys:[NSString stringWithFormat:@"hide ignored, stand-in was just kept %@", bundle ?: @"?"]];
        return;
    }
    // The conversation search field resigns itself after a letter. The keys
    // are still on screen and the stand-in is still editing. Cancel is not
    // that resign: the app marks it cancel=1.
    if (!show && !userCancel && _stagedKeyboardField.isFirstResponder &&
        [why rangeOfString:@"SearchBar"].location != NSNotFound) {
        CGRect keys = DSVisibleKeyboardFrameOnScreen();
        if (!CGRectIsNull(keys) && CGRectGetHeight(keys) >= 160.0) {
            [self logKeys:[NSString stringWithFormat:@"hide ignored, search field resigned on its own keys=%@",
                           NSStringFromCGRect(keys)]];
            return;
        }
    }
    if (show) [self showStagedKeyboardLikePickerForBundle:bundle];
    else [self hideStagedKeyboardLikePicker];
}

- (NSString *)hostedBundleForStagedKeyboard {
    if (_stagedKeyboardSlot == 0 && _sceneHost.isHosting) return _sceneHost.bundleIdentifier;
    if (_stagedKeyboardSlot == 1 && _topSceneHost.isHosting) return _topSceneHost.bundleIdentifier;
    if (_stagedKeyboardSlot == 2 && _floatSceneHost.isHosting) return _floatSceneHost.bundleIdentifier;
    if (_sceneHost.isHosting) return _sceneHost.bundleIdentifier;
    if (_topSceneHost.isHosting) return _topSceneHost.bundleIdentifier;
    if (_floatSceneHost.isHosting) return _floatSceneHost.bundleIdentifier;
    return @"?";
}

- (void)stagedKeyboardInsertText:(NSString *)text {
    _stagedKeyboardReassertCount = 0;
    DSDiagnosticsRecordFormat(@"SpringBoard: staged key insert len=%lu app=%@ fr=%d",
                              (unsigned long)text.length,
                              [self hostedBundleForStagedKeyboard],
                              _stagedKeyboardField.isFirstResponder);
    DSEnqueueStagedKey(@"insert", text);
}

- (void)stagedKeyboardDeleteBackward {
    _stagedKeyboardReassertCount = 0;
    DSDiagnosticsRecordFormat(@"SpringBoard: staged key delete app=%@ fr=%d",
                              [self hostedBundleForStagedKeyboard],
                              _stagedKeyboardField.isFirstResponder);
    DSEnqueueStagedKey(@"delete", @"");
}

- (void)stagedKeyboardDidEnd {
    if (_suppressStagedKeyboardEnd) return;
    BOOL stageOpen = _state != DSStageStateMinimized && _state != DSStageStateClosed;
    if (!_stagedKeyboardWantsHide && _searchSlot < 0 && _stagedKeyboardSlot >= 0 && stageOpen) {
        NSString *why = [NSString stringWithContentsOfFile:@"/var/tmp/com.recreated.dynamicstage.keyboard-why"
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
        DSDiagnosticsRecordFormat(@"SpringBoard: stand-in ended why=%@ %@",
                                  why.length ? why : @"-",
                                  [self hostedBundleForStagedKeyboard]);
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
    if (_floatSceneHost.isHosting && [_floatSceneHost.bundleIdentifier isEqualToString:bundleIdentifier]) return YES;
    return NO;
}

- (CGRect)stageCardScreenFrameForBundleIdentifier:(NSString *)bundleIdentifier cornerRadius:(CGFloat *)radius {
    if (bundleIdentifier.length == 0 || !self.isStageVisible) return CGRectNull;
    DSStageContainerView *card = nil;
    if (_sceneHost.isHosting && !_primaryParked && [_sceneHost.bundleIdentifier isEqualToString:bundleIdentifier]) {
        card = _container;
    } else if (_topSceneHost.isHosting && !_secondParked && [_topSceneHost.bundleIdentifier isEqualToString:bundleIdentifier]) {
        card = _topContainer;
    } else if (_floatSceneHost.isHosting && _floatActive && [_floatSceneHost.bundleIdentifier isEqualToString:bundleIdentifier]) {
        card = _floatContainer;
    }
    if (!card || card.hidden || card.alpha < 0.05 || !card.window || card.window.hidden) return CGRectNull;
    CGRect inWindow = [card convertRect:card.bounds toView:nil];
    CGRect onScreen = [card.window convertRect:inWindow toWindow:nil];
    if (radius) *radius = card.cornerRadius;
    return onScreen;
}

// Beeper lays out its own keyboard and quick bar. Staging that keyboard, and
// ignoring its short dock strip, is what lifts the bar inside the card.
- (BOOL)appKeepsItsOwnKeyboard:(NSString *)bundleIdentifier {
    (void)bundleIdentifier;
    return NO;
}

- (BOOL)hostedKeyboardStaysWithTheApp {
    if (!_sceneHost.isHosting && !_topSceneHost.isHosting) return NO;
    if ([self appKeepsItsOwnKeyboard:_sceneHost.bundleIdentifier]) return YES;
    if ([self appKeepsItsOwnKeyboard:_topSceneHost.bundleIdentifier]) return YES;
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
    NSString *floatStaged = _floatSceneHost.bundleIdentifier;
    if (floatStaged.length > 0 && [source isEqualToString:floatStaged]) return YES;

    if ([source isEqualToString:@"SpringBoard"]) {
        // The picker search keyboard stays on screen and does not lift the card.
        if (_searchSlot >= 0) return NO;
        if ([self isShowingAppPicker] && !_sceneHost.isHosting && !_topSceneHost.isHosting) return NO;
        if (_stagedKeyboardSlot >= 0) return YES;
        // The remote keyboard is SpringBoard's. That is still this card's keyboard.
        if (_sceneHost.isHosting || _topSceneHost.isHosting) return YES;
        return NO;
    }

    if (CGRectIsEmpty(keyboard)) {
        if ([source isEqualToString:@"SpringBoard"]) return YES;
        if (topStaged.length > 0 && [source isEqualToString:topStaged]) return YES;
        NSString *floatStaged = _floatSceneHost.bundleIdentifier;
        if (floatStaged.length > 0 && [source isEqualToString:floatStaged]) return YES;
        if (_keyboardLiftOwner.length > 0 && [source isEqualToString:_keyboardLiftOwner]) return YES;
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
    if (height < kDSKeyboardPresentHeight || height <= 120.0) return keyboard;

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
    if (keys < 150.0) return keyboard;
    // 243pt is the keyboard before the suggestion bar. Clearing only that
    // leaves the card on the keys. A taller frame is the shortcut bar that
    // stays up, and the card has to clear that too.
    if (keys < 301.0) keys = 301.0;
    if (keys > CGRectGetHeight(screen) * 0.6) keys = 301.0;
    return CGRectMake(0.0, CGRectGetMaxY(screen) - keys, CGRectGetWidth(screen), keys);
}

// Beeper's quick bar grows the keyboard (346pt, sometimes 395pt). The app
// then reports the keys alone (243pt or 288pt). Turning that into a 301pt
// keyboard drops the bottom split and the third stage back onto the bar.
// A real shrink is a frame that is already at least 301pt, and only when
// the keys on screen got shorter too.
- (CGRect)keyboardFrameKeepingQuickBar:(CGRect)keyboard reportedHeight:(CGFloat)reportedHeight {
    if (CGRectIsEmpty(keyboard)) return keyboard;
    CGRect best = _keyboardFrame;
    CGRect visible = DSVisibleStagedKeyboardFrameOnScreen();
    if (!CGRectIsNull(visible) && CGRectGetHeight(visible) >= 150.0) {
        visible = [self keyboardFrameOnDisplay:visible];
        visible = [self keyboardFrameForLift:visible];
    } else {
        visible = CGRectZero;
    }
    if (CGRectGetHeight(visible) > CGRectGetHeight(best) + 0.5) best = visible;
    if (CGRectIsEmpty(best) || CGRectGetHeight(keyboard) + 0.5 >= CGRectGetHeight(best)) return keyboard;
    BOOL undersized = reportedHeight < 301.0;
    BOOL visibleStillTall = CGRectGetHeight(visible) + 8.0 >= CGRectGetHeight(best);
    if (!undersized && !visibleStillTall) return keyboard;
    static CGFloat loggedHad = 0;
    static CGFloat loggedReported = 0;
    CGFloat hadH = CGRectGetHeight(best);
    if (fabs(loggedHad - hadH) > 0.5 || fabs(loggedReported - reportedHeight) > 0.5) {
        loggedHad = hadH;
        loggedReported = reportedHeight;
        [self logKeys:[NSString stringWithFormat:@"kept quick bar %.0fpt, ignored %.0fpt",
                       hadH, reportedHeight]];
    }
    return best;
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

// Beeper uses the same SpringBoard keyboard as Messenger. This line says which
// card was measured, whether that card is the top one, and why the lift was
// allowed. Copy it from the stage picker's freeze trace.
- (void)logBeeperKeyboardDecision:(NSString *)cause
                           source:(NSString *)source
                         keyboard:(CGRect)keyboard
                             slot:(NSInteger)slot
                             lift:(CGFloat)lift {
    (void)cause;
    (void)source;
    (void)keyboard;
    (void)slot;
    (void)lift;
    return;
    BOOL beeperHosted = [self isHostingBundleIdentifier:@"com.beeper.chat.ios"];
    BOOL beeperSource = [source isEqualToString:@"com.beeper.chat.ios"];
    if (!beeperHosted && !beeperSource) return;
    DSStageContainerView *card = [self containerForSlot:slot];
    NSInteger half = card ? [self halfForContainer:card] : -1;
    CGRect resting = CGRectZero;
    DSLiftSlotState *liftState = DSLiftSlotAt(slot);
    if (liftState->hasRestingFrame) {
        resting = CGRectMake(0.0, liftState->baseCardY, 0.0, liftState->baseCardH);
        resting.size.height = liftState->baseRestMaxY - liftState->baseCardY;
        if (resting.size.height < 80.0) resting.size.height = liftState->baseCardH;
    } else if (card && !card.hidden && ![self cardIsParked:card]) {
        resting = [self stageCardFrameForSlot:slot];
    }
    // One card is the primary card even when it sits on the bottom half.
    // The number in the log is that classification. The bottom used for the
    // overlap is where the card actually is, not the top half's y=463.
    if (_stackSlotCount == 1 && slot >= 0 && slot <= 3 && _slotPrimary[slot] == 1) {
        half = _slotHalf[slot];
    }
    CGFloat restBottom = CGRectGetMaxY(resting);
    if (_stackSlotCount == 1 && slot == 0) {
        restBottom = [self unliftedCardBottomForSlot:slot];
    }
    CGFloat overlap = CGRectIsEmpty(keyboard) ? 0.0 : restBottom - CGRectGetMinY(keyboard);
    CGFloat companion = 0.0;
    if (lift > 0.5 && [self slotIsBottomOfTwoStages:slot]) {
        companion = [self keyboardCompanionLiftForSlot:slot];
    }
    NSString *bundle = [self sceneHostForSlot:slot].bundleIdentifier ?: @"?";
    if (companion > 0.5) {
        cause = [NSString stringWithFormat:@"%@; the other card is pushed off the top", cause ?: @"?"];
    }
    NSInteger reportedPrimary = _primaryHalf;
    if (slot >= 0 && slot <= 3 && _stackSlotCount < kDSMaxStackSlots && _slotPrimary[slot] == 1) {
        reportedPrimary = _slotPrimary[slot];
    }
    DSDiagnosticsRecordFormat(@"SpringBoard: Beeper %@ slot=%ld half=%ld stack=%ld primary=%ld overlap=%.0f lift=%.0f was=%.0f companion=%.0f",
                              cause ?: @"?",
                              (long)slot,
                              (long)half,
                              (long)_stackSlotCount,
                              (long)reportedPrimary,
                              overlap,
                              lift,
                              card ? card.liftOffset : 0.0,
                              companion);
    DSDiagnosticsRecordFormat(@"SpringBoard: Beeper frames bundle=%@ src=%@ keysY=%.0f keysH=%.0f restMaxY=%.0f cardY=%.0f cardH=%.0f",
                              bundle,
                              source ?: @"?",
                              CGRectGetMinY(keyboard),
                              CGRectGetHeight(keyboard),
                              restBottom,
                              card ? CGRectGetMinY(card.frame) : -1.0,
                              card ? CGRectGetHeight(card.frame) : -1.0);
    static NSString *lastDetail = nil;
    static CFAbsoluteTime lastDetailAt = 0;
    NSString *detail = [NSString stringWithFormat:@"SB decision %@ bundle=%@ src=%@ keys=%@ overlap=%.0f lift=%.0f cardY=%.0f cardH=%.0f liftOffset=%.0f",
                        cause ?: @"?",
                        bundle,
                        source ?: @"?",
                        NSStringFromCGRect(keyboard),
                        overlap,
                        lift,
                        card ? CGRectGetMinY(card.frame) : -1.0,
                        card ? CGRectGetHeight(card.frame) : -1.0,
                        card ? card.liftOffset : 0.0];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!lastDetail || ![lastDetail isEqualToString:detail] || now - lastDetailAt >= 1.0) {
        lastDetail = [detail copy];
        lastDetailAt = now;
        DSBeeperDetailLog(detail);
        DSBeeperDetailDumpKeyboard(cause);
    }
}

// One place for keyboard geometry. Staged apps keep the card fixed; SpringBoard
// draws full-width keys on the bottom edge of the phone.
- (void)noteAppReportedKeyboardLine:(NSString *)line {
    float x = 0, y = 0, w = 0, h = 0;
    char kind[16] = {0};
    char bundleBuf[160] = {0};
    if (sscanf(line.UTF8String ?: "", "kb %15s x=%f y=%f w=%f h=%f bundle=%159s",
               kind, &x, &y, &w, &h, bundleBuf) < 5) {
        [self logKeys:[NSString stringWithFormat:@"app kb unparsed %@", line ?: @"?"]];
        return;
    }
    NSString *bundle = bundleBuf[0] ? [NSString stringWithUTF8String:bundleBuf] : @"SpringBoard";
    CGRect frame = CGRectMake(x, y, w, h);
    BOOL hosted = bundle.length > 0 && [self isHostingBundleIdentifier:bundle];
    [self logKeys:[NSString stringWithFormat:@"app kb %@ hosted=%d frame=%@ %@",
                   bundle, hosted, NSStringFromCGRect(frame), [self lowerStageLiftSummary:frame]]];
    if (!hosted) return;
    CGFloat screenH = CGRectGetHeight([self screenBounds]);
    BOOL up = CGRectGetHeight(frame) >= 150.0 && CGRectGetMinY(frame) < screenH - 1.0 &&
              CGRectGetMinY(frame) > screenH * 0.35;
    [self noteKeyboardFrame:(up ? frame : CGRectZero) source:bundle duration:0.25];
}

- (void)noteKeyboardFrame:(CGRect)keyboard source:(NSString *)source duration:(NSTimeInterval)duration {
    [self logKeys:[NSString stringWithFormat:@"note src=%@ frame=%@ %@",
                   source ?: @"?",
                   NSStringFromCGRect(keyboard),
                   [self lowerStageLiftSummary:keyboard]]];
    if (_searchSlot >= 0) {
        CGRect screen = [self screenBounds];
        CGRect keys = keyboard;
        if (CGRectIsEmpty(keys) || CGRectGetHeight(keys) < 150.0 ||
            CGRectGetMinY(keys) >= CGRectGetMaxY(screen) - 1.0) {
            keys = CGRectZero;
        }
        DSStageContainerView *card = [self containerForSlot:_searchSlot];
        CGFloat lift = 0.0;
        if (card && !CGRectIsEmpty(keys)) {
            lift = [self splitKeyboardClearLiftForCard:card keyboard:keys];
            // Search on the top half is already clear of the keys. Bring that
            // card down onto them, the same as typing in the top stage.
            if (lift < 1.0) {
                CGFloat drop = [self dropNeededToSitOnKeyboard:keys forCard:card];
                if (drop > 1.0) lift = -drop;
            }
        }
        _keyboardFrame = keys;
        _keyboardLiftSlot = _searchSlot;
        if (card && lift < -0.5) {
            [self scheduleSettledTopKeyboardMove];
            [self parkStagesForKeyboardOwner:card keysUp:YES];
            [self logLift:[NSString stringWithFormat:@"search slot=%ld drop=%.0f %@",
                           (long)_searchSlot, -lift, [self lowerStageLiftSummary:keys]]];
            return;
        }
        if (CGRectIsEmpty(keys)) [self invalidateTopKeyboardWait];
        if (card && fabs(card.liftOffset - lift) > 0.5) {
            NSTimeInterval motion = CGRectIsEmpty(keys) ? 0.0 : (duration > 0.0 ? duration : 0.25);
            void (^move)(void) = ^{
                [card setLiftOffset:lift];
                [self syncLiftChrome];
            };
            if (motion > 0.0) [UIView animateWithDuration:motion animations:move];
            else move();
        }
        [self parkStagesForKeyboardOwner:card keysUp:!CGRectIsEmpty(keys)];
        [self logLift:[NSString stringWithFormat:@"search slot=%ld lift=%.0f %@",
                       (long)_searchSlot, lift, [self lowerStageLiftSummary:keys]]];
        return;
    }
    static NSInteger hideWaits = 0;
    static NSInteger showWaits = 0;
    if ([DSSceneHost sceneSettingsUpdateDepth] > 0) {
        NSString *sourceCopy = source.length ? [source copy] : @"SpringBoard";
        NSTimeInterval motion = duration;
        CGRect keyboardCopy = keyboard;
        if (CGRectIsEmpty(keyboard)) {
            if (hideWaits < 8) {
                hideWaits += 1;
                [self logKeys:[NSString stringWithFormat:@"hide waiting, scene update in progress try=%ld src=%@",
                               (long)hideWaits, sourceCopy]];
                __weak typeof(self) weakSelf = self;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [weakSelf noteKeyboardFrame:CGRectZero source:sourceCopy duration:motion];
                });
            } else {
                [self logKeys:@"hide dropped, scene update never finished"];
            }
        } else if (showWaits < 8) {
            showWaits += 1;
            [self logLift:[NSString stringWithFormat:@"show waiting, scene update try=%ld %@",
                           (long)showWaits, [self lowerStageLiftSummary:keyboard]]];
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [weakSelf noteKeyboardFrame:keyboardCopy source:sourceCopy duration:motion];
            });
        } else {
            [self logLift:[NSString stringWithFormat:@"show dropped, scene update never finished %@",
                           [self lowerStageLiftSummary:keyboard]]];
        }
        return;
    }
    showWaits = 0;
    if (CGRectIsEmpty(keyboard)) hideWaits = 0;
    if ([self appKeepsItsOwnKeyboard:source]) {
        [self logLift:[NSString stringWithFormat:@"skipped, %@ keeps its own keyboard", source ?: @"?"]];
        return;
    }
    if ([self hostedKeyboardStaysWithTheApp] && _searchSlot < 0 && _stagedKeyboardSlot < 0) {
        [self logLift:@"skipped, hosted keyboard stays with the app"];
        return;
    }
    CGRect screen = [self screenBounds];
    keyboard = [self keyboardFrameOnDisplay:keyboard];
    CGFloat height = CGRectGetHeight(keyboard);
    BOOL offBottom = CGRectGetMinY(keyboard) >= CGRectGetMaxY(screen) - 1.0;
    BOOL stub = height >= 1.0 && height < 150.0 && !offBottom;
    BOOL gone = CGRectIsEmpty(keyboard) || height < 1.0 || offBottom;
    BOOL hostedStage = _sceneHost.isHosting || _topSceneHost.isHosting;
    if (stub) {
        [self logBeeperKeyboardDecision:[NSString stringWithFormat:@"kept the old lift, a %.0fpt dock strip was ignored", height]
                                 source:source
                               keyboard:_keyboardFrame
                                   slot:_keyboardLiftSlot
                                   lift:[self liftOffsetForSlot:_keyboardLiftSlot]];
        return;
    }
    if (gone) {
        CGRect visible = DSVisibleStagedKeyboardFrameOnScreen();
        if (!CGRectIsNull(visible) && CGRectGetHeight(visible) >= 150.0) {
            [self logKeys:[NSString stringWithFormat:@"hide ignored, keys still %@", NSStringFromCGRect(visible)]];
            keyboard = [self keyboardFrameOnDisplay:visible];
        } else if (hostedStage && !CGRectIsEmpty(_keyboardFrame) &&
            ![self isHostingBundleIdentifier:source] &&
            [self springBoardIsDrawingKeyboard]) {
            [self logBeeperKeyboardDecision:@"kept the old lift, hide ignored because SpringBoard is still drawing keys"
                                     source:source
                                   keyboard:_keyboardFrame
                                       slot:_keyboardLiftSlot
                                       lift:[self liftOffsetForSlot:_keyboardLiftSlot]];
            return;
        } else {
            keyboard = CGRectZero;
        }
    }

    // A staged app's keyboard going down must not cancel a picker search that
    // just took the screen. The search field's own hide still clears the lift.
    if (CGRectIsEmpty(keyboard) && (_searchSlot >= 0 || _stagedKeyboardSlot >= 0) &&
        ![source isEqualToString:@"SpringBoard"]) {
        if (_splitMode) {
            _keyboardFrame = CGRectZero;
            _keyboardDrawnOutside = NO;
            [UIView performWithoutAnimation:^{
                [self applySplitKeyboardShiftForKeyboard:CGRectZero owner:nil];
            }];
        }
        return;
    }

    NSInteger liftSlot = [self slotOwningKeyboardSource:source];
    if (_stackSlotCount >= kDSMaxStackSlots) {
        NSInteger bottomSlot = [self slotOnBottomHalf];
        DSSceneHost *bottomHost = [self sceneHostForSlot:bottomSlot];
        if (bottomHost.isHosting && [source isEqualToString:bottomHost.bundleIdentifier]) {
            liftSlot = bottomSlot;
        }
    }
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
    BOOL fromThisSlot = ownerBundle.length > 0 && [source isEqualToString:ownerBundle];
    BOOL fromOtherSlot = otherBundle.length > 0 && [source isEqualToString:otherBundle];
    BOOL fromSpringBoard = [source isEqualToString:@"SpringBoard"];
    if (ownerBundle.length > 0 && source.length > 0 && !fromThisSlot && !fromOtherSlot && !fromSpringBoard) {
        // Spotlight, Edge, Filza, and every other non-staged keyboard.
        return;
    }
    // A SpringBoard hide is the keys actually leaving. Dropping it because the
    // lift was owned by the top card is why that card stayed up.
    if (CGRectIsEmpty(keyboard) && _keyboardLiftOwner.length > 0 && source.length > 0 &&
        !fromThisSlot && !fromOtherSlot && ![source isEqualToString:_keyboardLiftOwner] &&
        ![source isEqualToString:@"SpringBoard"]) {
        return;
    }
    BOOL beeperKeys = [source isEqualToString:@"com.beeper.chat.ios"] ||
        [self isHostingBundleIdentifier:@"com.beeper.chat.ios"];
    if (!beeperKeys &&
        ((_sceneHost.isHosting && [source isEqualToString:_sceneHost.bundleIdentifier]) ||
         (_topSceneHost.isHosting && [source isEqualToString:_topSceneHost.bundleIdentifier]))) {
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

    // A 243pt report is the keyboard before the suggestion bar. Lifting for
    // that leaves the card on the keys. 301pt is the settled keyboard.
    // A later short report must not throw away the quick bar on top of it.
    if (!CGRectIsEmpty(keyboard) && CGRectGetHeight(keyboard) >= 150.0) {
        CGFloat reportedHeight = CGRectGetHeight(keyboard);
        keyboard = [self keyboardFrameForLift:keyboard];
        keyboard = [self keyboardFrameKeepingQuickBar:keyboard reportedHeight:reportedHeight];
    }

    BOOL hostedAppKeys = (_sceneHost.isHosting && [source isEqualToString:_sceneHost.bundleIdentifier]) ||
                         (_topSceneHost.isHosting && [source isEqualToString:_topSceneHost.bundleIdentifier]);
    // The card moves up for the keyboard on either half. It drops when the
    // keyboard frame goes away.
    if (hostedAppKeys && !CGRectIsEmpty(keyboard) &&
        ([self hostedAppReportedRemoteKeyboard:source] || [self springBoardIsDrawingKeyboard])) {
        _keyboardDrawnOutside = YES;
    }

    BOOL unchanged = CGRectEqualToRect(keyboard, _keyboardFrame);
    if (unchanged) {
        if (CGRectIsEmpty(keyboard)) {
            // A hide that already cleared the keyboard frame was returning
            // here, so a card slid aside for the keys stayed there.
            if ([self anyStageHasSideShift]) [self clearKeyboardSideShift];
            [self invalidateTopKeyboardWait];
            BOOL lifted = (_container && fabs(_container.liftOffset) > 0.5) ||
                          (_topContainer && fabs(_topContainer.liftOffset) > 0.5) ||
                          (_floatContainer && fabs(_floatContainer.liftOffset) > 0.5);
            if (lifted) {
                [UIView performWithoutAnimation:^{
                    if (self->_container) [self->_container setLiftOffset:0.0];
                    if (self->_topContainer) [self->_topContainer setLiftOffset:0.0];
                    if (self->_floatContainer) [self->_floatContainer setLiftOffset:0.0];
                    [self syncLiftChrome];
                }];
            }
            return;
        }
        // Split and the third stage lift more than one card. Matching the
        // owner card is not enough to skip the others.
        if (!_splitMode && !_floatActive) {
            CGFloat needed = [self liftNeededToClearKeyboard:keyboard forSlot:_keyboardLiftSlot];
            DSStageContainerView *typing = [self containerForSlot:_keyboardLiftSlot];
            BOOL dropTop = needed < 1.0 && [self cardShouldDropOntoKeyboard:typing] &&
                (_stackSlotCount < kDSMaxStackSlots || [self topSplitIsTypingInCard:typing]);
            if (dropTop) {
                CGFloat drop = [self dropNeededToSitOnKeyboard:keyboard forCard:typing];
                needed = drop > 1.0 ? -drop : 0.0;
            }
            if (fabs([self liftOffsetForSlot:_keyboardLiftSlot] - needed) < 0.5 &&
                ![self sideParkNeedsUpdate]) return;
        }
    } else {
        _keyboardFrame = keyboard;
    }

    if (!_notedKeyboardOnce && !CGRectIsEmpty(keyboard)) {
        _notedKeyboardOnce = YES;
        DSDiagnosticsRecordFormat(@"SpringBoard: %@ put a keyboard up at %@ (the display is %@)",
                                  source, NSStringFromCGRect(keyboard), NSStringFromCGRect(screen));
    }

    if (!self.isStageVisible) return;

    if (_splitMode) {
        @try {
            // The shift is a transform. It does not write scene settings, so it
            // is safe while SpringBoard is already inside an update. Gating it
            // on that update is why the cards came back late.
            DSStageContainerView *owner = [self containerForSlot:_keyboardLiftSlot];
            BOOL keys = !CGRectIsEmpty(keyboard) && CGRectGetHeight(keyboard) >= 150.0;
            [UIView performWithoutAnimation:^{
                [self applySplitKeyboardShiftForKeyboard:(keys ? keyboard : CGRectZero) owner:owner];
            }];
        } @catch (NSException *exception) {
            DSCrashLogRemember([NSString stringWithFormat:@"split keyboard threw %@", exception.reason ?: @"?"]);
        }
        return;
    }

    // Two stages, not the split gesture. The bottom card slides aside and the
    // top card comes down onto the keyboard. Rewriting either card's frame
    // here is what shifted both of them, so the move stays a transform.
    if (_stackSlotCount >= kDSMaxStackSlots && _container && _topContainer) {
        DSStageContainerView *owner = [self containerForSlot:_keyboardLiftSlot];
        BOOL keysUp = !CGRectIsEmpty(keyboard) && CGRectGetHeight(keyboard) >= 150.0;
        if (keysUp && [self topSplitIsTypingInCard:owner]) {
            [self scheduleSettledTopKeyboardMove];
            return;
        }
        [self invalidateTopKeyboardWait];
        if (!_topContainer.hidden) [self parkStagesForKeyboardOwner:nil keysUp:NO];
    }

    if (_sceneHost.isHosting && !_notedStrayKeyboard && !CGRectIsEmpty(keyboard) &&
        ![source isEqualToString:@"SpringBoard"] &&
        ![source isEqualToString:_sceneHost.bundleIdentifier]) {
        _notedStrayKeyboard = YES;
        DSDiagnosticsRecordFormat(@"SpringBoard: a keyboard came up for %@ while %@ is on the stage",
                                  source, _sceneHost.bundleIdentifier);
    }

    _container.keyboardBandHeight = 0.0;
    if (_topContainer) _topContainer.keyboardBandHeight = 0.0;
    // The lower stage moves up until it clears the keyboard. A single card on
    // the top half comes down onto the keys. Beeper used to leave
    // here without moving the card, and its bottom was stored as the top half,
    // so a card at y=469 was treated as already clear.
    NSTimeInterval motion = CGRectIsEmpty(keyboard) ? 0.0 : duration;
    CGFloat lift = [self liftNeededToClearKeyboard:keyboard forSlot:_keyboardLiftSlot];
    DSStageContainerView *typingCard = [self containerForSlot:_keyboardLiftSlot];
    // One stage on the top half. A stale bottom measurement can report a few
    // points of lift and skip the drop, so the card never comes down.
    if (_stackSlotCount < kDSMaxStackSlots && [self cardShouldDropOntoKeyboard:typingCard]) {
        CGFloat drop = [self dropNeededToSitOnKeyboard:keyboard forCard:typingCard];
        CGFloat shift = drop > 1.0 ? -drop : 0.0;
        [self logLift:[NSString stringWithFormat:@"top drop slot=%ld shift=%.0f %@",
                       (long)_keyboardLiftSlot, shift, [self lowerStageLiftSummary:keyboard]]];
        if (shift < -0.5) {
            [self scheduleSettledTopKeyboardMove];
        } else {
            [self invalidateTopKeyboardWait];
            [self setKeyboardLift:0.0 onCard:typingCard duration:motion];
        }
        return;
    }
    [self logLift:[NSString stringWithFormat:@"stack slot=%ld need=%.0f %@",
                   (long)_keyboardLiftSlot, lift, [self lowerStageLiftSummary:keyboard]]];
    [self liftCardBy:lift slot:_keyboardLiftSlot duration:motion];
}

- (NSInteger)slotOnBottomHalf {
    if (_stackSlotCount < kDSMaxStackSlots) return 0;
    return _primaryHalf == 0 ? 0 : 1;
}

// UIKit's keyboard notifications have no bundle id. With two stages up, always
// blaming stack slot 0 made the bottom card keep an in-scene keyboard region
// while the top card looked fine.
- (NSString *)hostedBundleForKeyboardNotifications {
    BOOL slot0 = _sceneHost.isHosting;
    BOOL slot1 = _topSceneHost.isHosting;
    if (slot0 && !slot1 && !_floatSceneHost.isHosting) return _sceneHost.bundleIdentifier;
    if (slot1 && !slot0 && !_floatSceneHost.isHosting) return _topSceneHost.bundleIdentifier;
    if (!slot0 && !slot1 && !_floatSceneHost.isHosting) return nil;
    // The card being typed in. Blaming the bottom card left the top card's
    // keyboard up after the field resigned.
    if (_hostedKeyboardRequestBundle.length > 0 &&
        [self isHostingBundleIdentifier:_hostedKeyboardRequestBundle]) {
        return _hostedKeyboardRequestBundle;
    }
    if (_keyboardLiftOwner.length > 0 && [self isHostingBundleIdentifier:_keyboardLiftOwner]) {
        return _keyboardLiftOwner;
    }
    if (_stagedKeyboardSlot >= 0) {
        DSSceneHost *host = [self sceneHostForSlot:_stagedKeyboardSlot];
        if (host.isHosting) return host.bundleIdentifier;
    }
    if (!CGRectIsEmpty(_keyboardFrame) && _keyboardLiftSlot >= 0) {
        DSSceneHost *host = [self sceneHostForSlot:_keyboardLiftSlot];
        if (host.isHosting) return host.bundleIdentifier;
    }
    if (_floatSceneHost.isHosting && _floatActive) return _floatSceneHost.bundleIdentifier;
    DSSceneHost *bottom = [self sceneHostForSlot:[self slotOnBottomHalf]];
    if (bottom.isHosting) return bottom.bundleIdentifier;
    return _sceneHost.bundleIdentifier ?: _topSceneHost.bundleIdentifier;
}

- (void)setForegroundForAllHostedApps:(BOOL)foreground {
    // A parked app stays backgrounded. Marking it foreground while another
    // stage opens is the assert that safe-modes SpringBoard.
    if (_sceneHost.isHosting && !_primaryParked) [_sceneHost setForeground:foreground];
    if (_topSceneHost.isHosting && !_secondParked) [_topSceneHost setForeground:foreground];
    if (_floatSceneHost.isHosting) [_floatSceneHost setForeground:foreground];
}

// The card the keyboard belongs to.
- (NSInteger)slotOwningKeyboardSource:(NSString *)source {
    if (_sceneHost.bundleIdentifier.length > 0 && [source isEqualToString:_sceneHost.bundleIdentifier]) {
        return 0;
    }
    if (_topSceneHost.bundleIdentifier.length > 0 && [source isEqualToString:_topSceneHost.bundleIdentifier]) {
        return 1;
    }
    if (_floatSceneHost.bundleIdentifier.length > 0 && [source isEqualToString:_floatSceneHost.bundleIdentifier]) {
        return 2;
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
    if (state != DSStageStateOverlay) return [self restingStageFrameForState:state];
    NSInteger half = _primaryHalf == 0 ? 0 : 1;
    if (_stackSlotCount >= kDSMaxStackSlots) {
        half = slot == 1 ? _secondHalf : _primaryHalf;
    }
    return [self frameForHalf:half state:state];
}

- (CGFloat)liftOffsetForSlot:(NSInteger)slot {
    DSStageContainerView *card = [self containerForSlot:slot];
    return card ? card.liftOffset : 0.0;
}

- (CGFloat)maxLiftForSlot:(NSInteger)slot state:(DSStageState)state {
    (void)slot;
    (void)state;
    // Far enough to clear the keyboard from either half, including a card
    // that is already against the top of the screen.
    return CGRectGetHeight([self screenBounds]);
}

- (void)restoreCardStackingOrder {
    if (_stackSlotCount < kDSMaxStackSlots || !_topContainer || !_container) return;
    UIView *root = _window.rootViewController.view;
    if (!root) return;
    DSStageContainerView *upper = [self containerOnHalf:1];
    DSStageContainerView *lower = [self containerOnHalf:0];
    UIView *upperView = (upper == _container) ? (UIView *)_dragShell : upper;
    UIView *lowerView = (lower == _container) ? (UIView *)_dragShell : lower;
    if (upperView && lowerView && upperView != lowerView &&
        upperView.superview == root && lowerView.superview == root) {
        [root insertSubview:upperView aboveSubview:lowerView];
    }
    if (_topRim && _topContainer.superview == root) {
        [root insertSubview:_topRim belowSubview:_topContainer];
    }
    [self bringFloatAboveSplit];
    [self bringShelfToFront];
}

- (void)bringCardAboveItsPartner:(DSStageContainerView *)card {
    if (_stackSlotCount < kDSMaxStackSlots || !card) return;
    UIView *root = _window.rootViewController.view;
    if (!root) return;
    UIView *front = (card == _container) ? (UIView *)_dragShell : card;
    if (front.superview == root) [root bringSubviewToFront:front];
    if (card == _topContainer && _topRim.superview == root) {
        [root insertSubview:_topRim belowSubview:_topContainer];
    }
    [self bringFloatAboveSplit];
    [self bringShelfToFront];
}

- (BOOL)slotIsBottomOfTwoStages:(NSInteger)slot {
    return _stackSlotCount >= kDSMaxStackSlots && slot == [self slotOnBottomHalf];
}

// The lower stage rises until it sits above the keyboard. The upper stage is
// already clear of the keys, so its own lift stays 0. Picker search lifts too.
- (BOOL)hostedAppKeepsItsCardStill {
    return NO;
}

- (CGRect)stageCardFrameForSlot:(NSInteger)slot {
    DSStageContainerView *card = [self containerForSlot:slot];
    if (!card) return CGRectZero;
    NSInteger half = [self halfForContainer:card];
    if (half != 0 && half != 1) half = (_primaryHalf == 0) ? 0 : 1;
    return [self fixedHalfFrame:half];
}

- (void)classifySlotForBundle:(NSString *)bundleID slot:(NSInteger)slot {
    if (slot < 0 || slot > 3) return;
    // Two real cards keep their own halves. One card is always the primary card.
    // Dragging it onto the bottom half must not clear these flags, and these
    // flags must not move the card onto the top half. The top half ends at
    // y=463. The keyboard starts at y=631. Measuring the bottom card as that
    // top half is overlap -168 and the lift stays 0.
    if (_stackSlotCount >= kDSMaxStackSlots) return;
    if (_stackSlotCount != 1 && ![bundleID isEqualToString:@"com.beeper.chat.ios"]) return;
    _slotHalf[slot] = 1;
    _slotPrimary[slot] = 1;
}

// Where the card is sitting before the keyboard transform. The primary card's
// frame is inside the rim shell, so its screen position is not card.frame.
- (CGRect)restingScreenFrameForSlot:(NSInteger)slot {
    DSStageContainerView *card = [self containerForSlot:slot];
    if (!card) return CGRectZero;
    if (card == _container) return [self primaryCardFrameInRoot];
    CGRect live = card.frame;
    if (fabs(card.liftOffset) > 0.5) live.origin.y += card.liftOffset;
    return live;
}

- (void)storeRestingFrameForBundle:(NSString *)bundleID
                              slot:(NSInteger)slot
                             cardY:(CGFloat)cardY
                            cardH:(CGFloat)cardH
                         restMaxY:(CGFloat)restMaxY {
    if (slot < 0 || slot > 3) return;
    if ([DSSceneHost sceneSettingsUpdateDepth] > 0) return;
    DSLiftSlotState *state = DSLiftSlotAt(slot);
    if (state->hasRestingFrame) return;
    // A measurement past the screen is the switcher, not the card. Keep the
    // card's real half. The bottom half ends near y=927, and that is what the
    // keyboard covers.
    CGFloat screenH = CGRectGetHeight([self screenBounds]);
    if (screenH > 100.0 && restMaxY > screenH + 2.0) {
        DSLog("[REST] rejected restMaxY=%.0f, it is past the screen", restMaxY);
        CGRect live = [self restingScreenFrameForSlot:slot];
        if (CGRectGetHeight(live) > 80.0 && CGRectGetMinY(live) >= -0.5 &&
            CGRectGetMaxY(live) <= screenH + 2.0) {
            cardY = CGRectGetMinY(live);
            cardH = CGRectGetHeight(live);
            restMaxY = CGRectGetMaxY(live);
        } else {
            CGRect top = [self fixedHalfFrame:1];
            cardY = CGRectGetMinY(top);
            cardH = CGRectGetHeight(top);
            restMaxY = CGRectGetMaxY(top);
        }
    }
    if (cardY < -0.5 || cardH < 80.0) return;
    state->hasRestingFrame = YES;
    state->baseCardY = cardY;
    state->baseCardH = cardH;
    state->baseRestMaxY = restMaxY;
    DSLog("[REST] %@ slot=%ld cardY=%.0f cardH=%.0f restMaxY=%.0f",
          bundleID ?: @"?", (long)slot, cardY, cardH, restMaxY);
}

- (void)setLift:(CGFloat)lift forSlot:(NSInteger)slot {
    DSStageContainerView *card = [self containerForSlot:slot];
    if (!card || [self cardIsParked:card]) return;
    [card setLiftOffset:MAX(lift, 0.0)];
}

- (CGFloat)cardYForSlot:(NSInteger)slot {
    DSStageContainerView *card = [self containerForSlot:slot];
    if (!card) return 0.0;
    // The primary card's frame is inside the rim shell. y=36 there is y=5 on
    // the screen. Storing the shell number and writing it back as a screen
    // position is what dropped the top card onto the one below it.
    if ([self cardLivesInDragShell:card]) {
        return CGRectGetMinY([self primaryCardFrameInRoot]);
    }
    CGFloat y = CGRectGetMinY([self frameWithoutKeyboardShift:card]);
    return y;
}

- (CGFloat)cardHForSlot:(NSInteger)slot {
    DSStageContainerView *card = [self containerForSlot:slot];
    return card ? CGRectGetHeight(card.frame) : 0.0;
}

- (CGFloat)restMaxYForSlot:(NSInteger)slot {
    DSLiftSlotState *state = DSLiftSlotAt(slot);
    if (state->hasRestingFrame) return state->baseRestMaxY;
    return CGRectGetMaxY([self stageCardFrameForSlot:slot]);
}

- (BOOL)cardLivesInDragShell:(DSStageContainerView *)card {
    return card && card == _container && _dragShell && card.superview == _dragShell;
}

// Screen position of the card, the shell, the rim, and the hosted view.
// card.frame inside the shell is not a screen position. Logging it as one
// hid the jump.
- (NSString *)stageGeometryDebugSummary {
    @try {
        NSMutableString *text = [NSMutableString string];
        [text appendFormat:@"build %s split=%d float=%d half=%ld slots=%ld\n",
         kDSBuildVersionString, _splitMode, _floatActive, (long)_primaryHalf, (long)_stackSlotCount];
        CGRect card = [self primaryCardFrameInRoot];
        CGRect shell = _dragShell ? _dragShell.frame : CGRectZero;
        CGRect outline = CGRectZero;
        if (_dragShell && _dragShell.superview) {
            outline = [_dragShell convertRect:[_dragShell outlineFrame] toView:_dragShell.superview];
        }
        CGRect top = (_topContainer && !_topContainer.hidden) ? _topContainer.frame : CGRectZero;
        CGRect rim = (_topRim && !_topRim.hidden) ? _topRim.frame : CGRectZero;
        UIView *host = _sceneHost.hostView;
        CGRect hostScreen = (host && host.window) ? [host convertRect:host.bounds toView:nil] : CGRectZero;
        UIView *topHost = _topSceneHost.hostView;
        CGRect topHostScreen = (topHost && topHost.window) ? [topHost convertRect:topHost.bounds toView:nil] : CGRectZero;
        CGRect front = (_frontCard && !_frontCard.hidden) ? [self rootFrameOfCard:_frontCard] : CGRectZero;
        NSString *frontName = @"none";
        if (_frontCard == _container) frontName = @"primary";
        else if (_frontCard == _topContainer) frontName = @"second";
        else if (_frontCard == _floatContainer) frontName = @"float";
        CGRect floatFrame = (_floatContainer && !_floatContainer.hidden) ? [self rootFrameOfCard:_floatContainer] : CGRectZero;
        [text appendFormat:@"card %@\nshell %@\noutline %@\ntopCard %@\ntopRim %@\nfront(%@) %@\nfloatCard %@\nhost %@\ntopHost %@\n",
         NSStringFromCGRect(card), NSStringFromCGRect(shell), NSStringFromCGRect(outline),
         NSStringFromCGRect(top), NSStringFromCGRect(rim),
         frontName, NSStringFromCGRect(front), NSStringFromCGRect(floatFrame),
         NSStringFromCGRect(hostScreen), NSStringFromCGRect(topHostScreen)];
        BOOL cardRimApart = !CGRectIsEmpty(outline) && !CGRectIsEmpty(card) &&
            (fabs(CGRectGetMidX(outline) - CGRectGetMidX(card)) > 8.0 ||
             fabs(CGRectGetMidY(outline) - CGRectGetMidY(card)) > 8.0);
        BOOL topApart = !CGRectIsEmpty(rim) && !CGRectIsEmpty(top) &&
            (fabs(CGRectGetMidX(rim) - CGRectGetMidX(top)) > 8.0 ||
             fabs(CGRectGetMidY(rim) - CGRectGetMidY(top)) > 8.0);
        [text appendFormat:@"outlineOffCard=%d topRimOffCard=%d zShell=%.0f zTop=%.0f zFloat=%.0f\n",
         cardRimApart, topApart,
         _dragShell ? _dragShell.layer.zPosition : 0.0,
         _topContainer ? _topContainer.layer.zPosition : 0.0,
         _floatContainer ? _floatContainer.layer.zPosition : 0.0];
        [text appendFormat:@"lift primary=%.0f top=%.0f float=%.0f kFrame=%@ kSlot=%ld\n",
         _container ? _container.liftOffset : 0.0,
         _topContainer ? _topContainer.liftOffset : 0.0,
         _floatContainer ? _floatContainer.liftOffset : 0.0,
         NSStringFromCGRect(_keyboardFrame),
         (long)_keyboardLiftSlot];
        [text appendFormat:@"slot0=%@ slot1=%@ slot2=%@\n",
         _sceneHost.bundleIdentifier ?: @"-",
         _topSceneHost.bundleIdentifier ?: @"-",
         _floatSceneHost.bundleIdentifier ?: @"-"];
        return text;
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"geometry threw %@", exception.reason ?: @"?"];
    }
}

- (void)noteStageGeometry:(NSString *)why {
    NSString *summary = [self stageGeometryDebugSummary];
    if (summary.length == 0) return;
    static NSTimeInterval last = 0;
    static NSString *lastText = nil;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (lastText && [lastText isEqualToString:summary] && now - last < 1.5) return;
    last = now;
    lastText = [summary copy];
    DSLogAppend([NSString stringWithFormat:@"[GEOM] %@ %@", why ?: @"?", summary]);
    DSLogAppend([self splitGeometryDebugLine]);
    if (_splitMode && _stageDragActive) {
        DSLogAppend([self splitGeometryFixedLine]);
        DSLogAppend([self splitTopFixLine]);
    }
    if ([summary rangeOfString:@"OffCard=1"].location != NSNotFound) {
        DSCrashLogRemember([NSString stringWithFormat:@"rim off card (%@) %@", why ?: @"?", summary]);
    }
}

- (void)logStageGeometry:(NSString *)why {
    [self noteStageGeometry:why];
    return;
    DSStageContainerView *card = _container;
    if (!card) return;
    CGRect local = card.frame;
    CGRect screen = [self primaryCardFrameInRoot];
    CGRect shell = _dragShell ? _dragShell.frame : CGRectZero;
    CGRect rim = _dragShell ? [_dragShell outlineFrame] : CGRectZero;
    UIView *host = _sceneHost.hostView;
    CGRect hostInCard = (host && host.superview) ? [host.superview convertRect:host.frame toView:card] : CGRectNull;
    DSLog("[GEOM] %@ lift=%.0f local={{%.0f,%.0f} {%.0f,%.0f}} screen={{%.0f,%.0f} {%.0f,%.0f}} shell={{%.0f,%.0f} {%.0f,%.0f}} rim={{%.0f,%.0f} {%.0f,%.0f}} host={{%.0f,%.0f} {%.0f,%.0f}} ty=%.1f",
          why ?: @"?",
          card.liftOffset,
          local.origin.x, local.origin.y, local.size.width, local.size.height,
          screen.origin.x, screen.origin.y, screen.size.width, screen.size.height,
          shell.origin.x, shell.origin.y, shell.size.width, shell.size.height,
          rim.origin.x, rim.origin.y, rim.size.width, rim.size.height,
          hostInCard.origin.x, hostInCard.origin.y, hostInCard.size.width, hostInCard.size.height,
          card.transform.ty);
}

- (void)setCardY:(CGFloat)cardY cardH:(CGFloat)cardH restMaxY:(CGFloat)restMaxY forSlot:(NSInteger)slot {
    (void)restMaxY;
    DSStageContainerView *card = [self containerForSlot:slot];
    if (!card || [self cardIsParked:card]) return;
    // The lift is a transform. Writing the lifted origin into the frame is
    // what left the card at y=-244 after the keyboard closed.
    if (card.liftOffset > 0.5) return;
    if (cardY < -0.5 || cardH < 80.0) return;
    // The primary card's frame is inside the rim shell. y=5 is the screen.
    // Writing it into the shell moved the card up and left the rim behind.
    if ([self cardLivesInDragShell:card]) {
        CGRect screen = [self primaryCardFrameInRoot];
        if (fabs(screen.origin.y - cardY) < 1.0 && fabs(screen.size.height - cardH) < 1.0) {
            return;
        }
        screen.origin.y = cardY;
        screen.size.height = cardH;
        [self placeCard:card atFrame:screen];
        [_dragShell setNeedsLayout];
        [_dragShell layoutIfNeeded];
        return;
    }
    CGRect frame = [self frameWithoutKeyboardShift:card];
    frame.origin.y = cardY;
    frame.size.height = cardH;
    [self assignFrame:frame toCard:card];
}

- (CGRect)pinnedBeeperKeyboardFrameForProposed:(CGRect)proposed {
    if ([DSSceneHost sceneSettingsUpdateDepth] > 0) return proposed;
    NSInteger slot = [self slotForHostedBundle:@"com.beeper.chat.ios"];
    if (slot < 0) return proposed;
    DSLiftSlotState *state = DSLiftSlotAt(slot);
    if (!state->keyboardFrozen || state->frozenKeysH < 160.0) return proposed;
    CGRect screen = [self screenBounds];
    CGFloat screenH = CGRectGetHeight(screen);
    CGFloat screenW = CGRectGetWidth(screen);
    if (screenH < 400.0 || CGRectGetWidth(proposed) < screenW - 80.0) return proposed;
    // A full-screen or card-sized context host is not the keyboard strip.
    if (CGRectGetHeight(proposed) > screenH * 0.5) return proposed;
    if (CGRectGetMinY(proposed) < screenH * 0.45) return proposed;
    if (fabs(CGRectGetMaxY(proposed) - screenH) > 40.0) return proposed;
    if (CGRectGetHeight(proposed) <= state->frozenKeysH + 8.0) return proposed;
    return CGRectMake(0.0, screenH - state->frozenKeysH, screenW, state->frozenKeysH);
}

- (void)handleKeyboardForBundle:(NSString *)bundleID
                           slot:(NSInteger)slot
                             on:(BOOL)on
                          frame:(CGRect)frame {
    if (slot < 0 || slot > 3) return;
    if (![bundleID isEqualToString:@"com.beeper.chat.ios"]) return;
    // Writing the card from inside a scene update is the SpringBoard crash.
    if ([DSSceneHost sceneSettingsUpdateDepth] > 0) return;
    [self classifySlotForBundle:bundleID slot:slot];
    DSLiftSlotState *state = DSLiftSlotAt(slot);
    CGFloat screenH = CGRectGetHeight([self screenBounds]);
    CGFloat keysY = CGRectGetMinY(frame);
    CGFloat keysH = CGRectGetHeight(frame);
    DSKeyboardType kbType = DSClassifyKeyboard(keysY, keysH, screenH);
    DSLog("[KEYBOARD] src=%@ slot=%ld on=%d keysY=%.0f keysH=%.0f type=%@ frozen=%d frozenY=%.0f frozenH=%.0f",
          bundleID, (long)slot, on, keysY, keysH, DSKeyboardTypeName(kbType),
          state->keyboardFrozen, state->frozenKeysY, state->frozenKeysH);
    if (kbType == DSKeyboardTypeTopStrip) DSLog("[KB IGNORE] top strip keysY=%.0f keysH=%.0f", keysY, keysH);
    if (kbType == DSKeyboardTypeDockStrip) DSLog("[KB IGNORE] dock strip keysY=%.0f keysH=%.0f", keysY, keysH);
    if (!on || CGRectIsEmpty(frame)) {
        DSLog("[KB FREEZE] released slot=%ld", (long)slot);
        state->keyboardFrozen = NO;
        state->frozenKeysY = 0.0;
        state->frozenKeysH = 0.0;
        CGFloat cardY = [self cardYForSlot:slot];
        CGFloat cardH = [self cardHForSlot:slot];
        CGFloat restMaxY = [self restMaxYForSlot:slot];
        [self restoreLiftForBundle:bundleID slot:slot cardY:&cardY cardH:&cardH restMaxY:&restMaxY];
        [self setCardY:cardY cardH:cardH restMaxY:restMaxY forSlot:slot];
        return;
    }
    if (!state->keyboardFrozen && kbType == DSKeyboardTypeBottomKeyboard) {
        state->keyboardFrozen = YES;
        state->frozenKeysY = keysY;
        state->frozenKeysH = keysH;
        DSLog("[KB FREEZE] activated slot=%ld keysY=%.0f keysH=%.0f", (long)slot, keysY, keysH);
    }
    if (state->keyboardFrozen &&
        (fabs(keysY - state->frozenKeysY) > 0.5 || fabs(keysH - state->frozenKeysH) > 0.5)) {
        DSLog("[KB FREEZE] clamped %@ keysY=%.0f keysH=%.0f -> frozenY=%.0f frozenH=%.0f",
              DSKeyboardTypeName(kbType), keysY, keysH, state->frozenKeysY, state->frozenKeysH);
        keysY = state->frozenKeysY;
        keysH = state->frozenKeysH;
        kbType = DSKeyboardTypeBottomKeyboard;
    }
    if (kbType != DSKeyboardTypeBottomKeyboard) return;
    CGFloat cardY = [self cardYForSlot:slot];
    CGFloat cardH = [self cardHForSlot:slot];
    CGFloat restMaxY = [self restMaxYForSlot:slot];
    [self applyLiftForBundle:bundleID
                       slot:slot
                      keysY:keysY
                     keysH:keysH
                     cardY:&cardY
                    cardH:&cardH
                 restMaxY:&restMaxY];
    [self setCardY:cardY cardH:cardH restMaxY:restMaxY forSlot:slot];
}
- (void)applyLiftForBundle:(NSString *)bundleID
                      slot:(NSInteger)slot
                     keysY:(CGFloat)keysY
                     keysH:(CGFloat)keysH
                     cardY:(CGFloat *)ioCardY
                     cardH:(CGFloat *)ioCardH
                  restMaxY:(CGFloat *)ioRestMaxY {
    if (![bundleID isEqualToString:@"com.beeper.chat.ios"]) return;
    if ([DSSceneHost sceneSettingsUpdateDepth] > 0) return;
    CGFloat screenH = CGRectGetHeight([self screenBounds]);
    if (DSClassifyKeyboard(keysY, keysH, screenH) != DSKeyboardTypeBottomKeyboard) return;
    DSStageContainerView *card = [self containerForSlot:slot];
    if (!card || [self cardIsParked:card]) return;
    DSLiftSlotState *state = DSLiftSlotAt(slot);
    if (!state->hasRestingFrame && ioCardY && ioCardH && ioRestMaxY && *ioCardY >= -0.5) {
        [self storeRestingFrameForBundle:bundleID slot:slot cardY:*ioCardY cardH:*ioCardH restMaxY:*ioRestMaxY];
    }
    if (!state->hasRestingFrame) return;
    // A single card keeps its primary classification wherever it sits. The
    // lift is from that card's real bottom, not from the top half's y=463.
    // 28pt above the keyboard frame, so the suggestion bar is not still on the card.
    CGFloat overlap = [self unliftedCardBottomForSlot:slot] - (keysY - 28.0);
    if (overlap < 1.0) overlap = 0.0;
    CGFloat lift = MIN(overlap, CGRectGetHeight([self screenBounds]));
    CGFloat liveY = [self cardYForSlot:slot];
    if (liveY >= 0.0 && lift > liveY) lift = liveY;
    if (card.liftOffset > 0.5 && fabs(card.liftOffset - lift) < 0.5) return;
    DSLog("[LIFT] slot=%ld cardY=%.0f cardH=%.0f keysY=%.0f keysH=%.0f restMaxY=%.0f lift=%.0f liveBottom=%.0f",
          (long)slot, liveY, state->baseCardH, keysY, keysH, state->baseRestMaxY, lift,
          [self unliftedCardBottomForSlot:slot]);
    [self setLift:lift forSlot:slot];
    (void)ioCardY;
    (void)ioCardH;
    (void)ioRestMaxY;
}

- (void)restoreLiftForBundle:(NSString *)bundleID
                        slot:(NSInteger)slot
                       cardY:(CGFloat *)ioCardY
                       cardH:(CGFloat *)ioCardH
                    restMaxY:(CGFloat *)ioRestMaxY {
    if (![bundleID isEqualToString:@"com.beeper.chat.ios"]) return;
    if (slot < 0 || slot > 3) return;
    if ([self containerForSlot:slot] == _frontCard) return;
    DSLiftSlotState *state = DSLiftSlotAt(slot);
    if (!state->hasRestingFrame) return;
    DSStageContainerView *card = [self containerForSlot:slot];
    if (!card || [self cardIsParked:card]) return;
    [self setLift:0.0 forSlot:slot];
    if ([self cardLivesInDragShell:card]) {
        CGRect screen = [self primaryCardFrameInRoot];
        screen.origin.y = state->baseCardY;
        screen.size.height = state->baseCardH;
        [self placeCard:card atFrame:screen];
        [_dragShell setNeedsLayout];
        [_dragShell layoutIfNeeded];
    } else {
        CGRect frame = [self frameWithoutKeyboardShift:card];
        frame.origin.y = state->baseCardY;
        frame.size.height = state->baseCardH;
        [self assignFrame:frame toCard:card];
    }
    if (ioCardY) *ioCardY = state->baseCardY;
    if (ioCardH) *ioCardH = state->baseCardH;
    if (ioRestMaxY) *ioRestMaxY = state->baseRestMaxY;
    DSDiagnosticsRecordFormat(@"SpringBoard: restored resting frame slot %ld cardY=%.0f cardH=%.0f",
                              (long)slot, state->baseCardY, state->baseCardH);
}

- (void)captureKeyboardBaseForSlot:(NSInteger)slot {
    DSStageContainerView *card = [self containerForSlot:slot];
    if (!card) return;
    NSString *bundle = [self sceneHostForSlot:slot].bundleIdentifier ?: @"";
    CGRect screenFrame = (slot == 0) ? [self primaryCardFrameInRoot] : card.frame;
    // cardYForSlot puts the keyboard transform back. The raw frame origin
    // is negative while the card is lifted, and that value must not be stored.
    [self storeRestingFrameForBundle:bundle
                               slot:slot
                              cardY:[self cardYForSlot:slot]
                             cardH:CGRectGetHeight(card.frame)
                          restMaxY:CGRectGetMaxY(screenFrame)];
}

- (void)restoreKeyboardBaseForSlot:(NSInteger)slot {
    NSString *bundle = [self sceneHostForSlot:slot].bundleIdentifier ?: @"";
    [self restoreLiftForBundle:bundle slot:slot cardY:NULL cardH:NULL restMaxY:NULL];
}

// Screen Y of the card's bottom before the keyboard transform. The top half
// ends near y=463, which is already above a keyboard at y=631. A card on the
// bottom half ends near y=927. Measuring that card as the top half is overlap
// -168 and the lift stays 0, so the keys cover it.
- (CGFloat)unliftedCardBottomForSlot:(NSInteger)slot {
    DSLiftSlotState *state = DSLiftSlotAt(slot);
    CGRect live = [self restingScreenFrameForSlot:slot];
    CGFloat liveBottom = CGRectGetHeight(live) > 80.0 ? CGRectGetMaxY(live) : 0.0;
    CGFloat cardBottom = state->hasRestingFrame ? state->baseRestMaxY : liveBottom;
    if (cardBottom < 1.0) cardBottom = CGRectGetMaxY([self stageCardFrameForSlot:slot]);
    CGFloat screenH = CGRectGetHeight([self screenBounds]);
    if (screenH > 100.0 && cardBottom > screenH + 2.0) {
        DSLog("[REST] card bottom %.0f is past the screen, using the card", cardBottom);
        if (liveBottom > 80.0 && liveBottom <= screenH + 2.0) cardBottom = liveBottom;
        else cardBottom = CGRectGetMaxY([self fixedHalfFrame:1]);
        if (state->hasRestingFrame) state->baseRestMaxY = cardBottom;
    }
    if (liveBottom > cardBottom + 8.0 && (screenH < 100.0 || liveBottom <= screenH + 2.0)) {
        cardBottom = liveBottom;
    }
    return cardBottom;
}

- (CGFloat)liftNeededToClearKeyboard:(CGRect)keyboard forSlot:(NSInteger)slot {
    if (CGRectIsEmpty(keyboard)) return 0.0;
    if ([self hostedAppKeepsItsCardStill]) return 0.0;
    DSStageContainerView *card = [self containerForSlot:slot];
    if (!card || [self cardIsParked:card] || card.hidden) return 0.0;
    if (slot == 2 || card == _floatContainer) {
        return [self splitKeyboardClearLiftForCard:card keyboard:keyboard];
    }
    if (_stackSlotCount >= kDSMaxStackSlots && ![self slotIsBottomOfTwoStages:slot]) return 0.0;
    [self captureKeyboardBaseForSlot:slot];
    CGFloat keyboardTop = CGRectGetMinY(keyboard) - 28.0;
    CGFloat overlap = [self unliftedCardBottomForSlot:slot] - keyboardTop;
    if (overlap < 1.0) return 0.0;
    CGFloat liveY = [self cardYForSlot:slot];
    if (liveY >= 0.0 && overlap > liveY) overlap = liveY;
    return MIN(overlap, CGRectGetHeight([self screenBounds]));
}

- (void)hideTopStageOutline {
    if (!_topRim) return;
    _topRim.hidden = YES;
    _topRim.alpha = 0.0;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _topRimLayer.path = nil;
    _topRimPulseLayer.path = nil;
    _topRimPulseLayer.opacity = 0.0;
    [CATransaction commit];
}

static BOOL DSApplyingSplitKeyShift = NO;

// The top stage is already clear of the keys. Bring it down until its bottom
// sits in the same gap the other stages use, then let go when the keys leave.
- (BOOL)cardShouldDropOntoKeyboard:(DSStageContainerView *)card {
    if (!card || card.hidden || [self cardIsParked:card]) return NO;
    if (card == _floatContainer || card == _frontCard) return NO;
    return [self halfForContainer:card] == 1;
}

- (CGFloat)dropNeededToSitOnKeyboard:(CGRect)keyboard forCard:(DSStageContainerView *)card {
    if (!card || CGRectIsEmpty(keyboard) || CGRectGetHeight(keyboard) < 150.0) return 0.0;
    if (![self cardShouldDropOntoKeyboard:card]) return 0.0;
    CGRect resting = [self placedFrameForCard:card state:DSStageStateOverlay];
    if (CGRectGetHeight(resting) < 40.0) resting = [self frameWithoutKeyboardShift:card];
    if (CGRectGetHeight(resting) < 40.0) return 0.0;
    CGFloat keyboardTop = CGRectGetMinY(keyboard) - 28.0;
    CGFloat drop = keyboardTop - CGRectGetMaxY(resting);
    if (drop < 1.0) return 0.0;
    CGFloat screenH = CGRectGetHeight([self screenBounds]);
    CGFloat maxDrop = screenH - CGRectGetHeight(resting) - 8.0 - CGRectGetMinY(resting);
    if (maxDrop < 1.0) return 0.0;
    if (drop > maxDrop) drop = maxDrop;
    return drop;
}

static NSUInteger DSTopKeyboardGeneration = 0;
static BOOL DSTopKeyboardWaitPosted = NO;

- (void)invalidateTopKeyboardWait {
    DSTopKeyboardGeneration += 1;
    DSTopKeyboardWaitPosted = NO;
}

// The keyboard arrives short, then grows when the suggestion bar settles.
// Moving the top card for the short frame and again for the tall one is the
// bounce. Wait until this burst is over, then move once.
- (void)scheduleSettledTopKeyboardMove {
    if (DSTopKeyboardWaitPosted) return;
    DSTopKeyboardWaitPosted = YES;
    NSUInteger generation = DSTopKeyboardGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.16 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != DSTopKeyboardGeneration) return;
        DSTopKeyboardWaitPosted = NO;
        DSStageManager *manager = weakSelf;
        if (!manager) return;
        CGRect keyboard = manager->_keyboardFrame;
        if (CGRectIsEmpty(keyboard) || CGRectGetHeight(keyboard) < 150.0) return;
        DSStageContainerView *owner = [manager containerForSlot:manager->_keyboardLiftSlot];
        if (manager->_stackSlotCount >= kDSMaxStackSlots &&
            [manager topSplitIsTypingInCard:owner]) {
            [UIView animateWithDuration:0.28
                                  delay:0
                                options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut
                             animations:^{
                [manager applySplitKeyboardShiftForKeyboard:keyboard owner:owner];
            } completion:nil];
            return;
        }
        if (manager->_stackSlotCount < kDSMaxStackSlots && [manager cardShouldDropOntoKeyboard:owner]) {
            CGFloat drop = [manager dropNeededToSitOnKeyboard:keyboard forCard:owner];
            [manager setKeyboardLift:(drop > 1.0 ? -drop : 0.0) onCard:owner duration:0.28];
        }
    });
}

- (void)setKeyboardLift:(CGFloat)lift onCard:(DSStageContainerView *)card duration:(NSTimeInterval)duration {
    if (!card || fabs(card.liftOffset - lift) < 0.5) return;
    void (^apply)(void) = ^{
        [card setLiftOffset:lift];
        [self syncLiftChrome];
    };
    if (lift < -0.5) {
        NSTimeInterval motion = duration > 0.0 ? duration : 0.28;
        [UIView animateWithDuration:motion
                              delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut
                         animations:apply
                         completion:nil];
    } else {
        apply();
    }
}

// How far the typing card has to rise so its bottom clears the keyboard.
// A card already sitting above the keys stays where it is.
- (CGFloat)splitKeyboardClearLiftForCard:(DSStageContainerView *)card keyboard:(CGRect)keyboard {
    if (!card || CGRectIsEmpty(keyboard)) return 0.0;
    CGRect resting = [self placedFrameForCard:card state:DSStageStateOverlay];
    CGRect live = card.frame;
    // A translated frame reports the lifted position. Put it back on the rest
    // spot before measuring how far the card still overlaps the keys.
    if (fabs(card.liftOffset) > 0.5) live.origin.y += card.liftOffset;
    if (CGRectGetHeight(live) > 40.0 && CGRectGetMaxY(live) > CGRectGetMaxY(resting) + 1.0) {
        resting = live;
    }
    if (CGRectGetHeight(resting) < 40.0) return 0.0;
    // The whole card, not just a sliver, sits above the keyboard.
    CGFloat keyboardTop = CGRectGetMinY(keyboard) - 28.0;
    CGFloat lift = CGRectGetMaxY(resting) - keyboardTop;
    if (lift < 1.0) return 0.0;
    CGFloat maxLift = CGRectGetMinY(resting) - 8.0;
    if (maxLift < 0.0) maxLift = 0.0;
    if (lift > maxLift) lift = maxLift;
    return lift;
}

// Split screen. Each card rises only until its bottom clears the keyboard.
// A card already above the keys stays put.
- (void)applySplitKeyboardShiftForKeyboard:(CGRect)keyboard owner:(DSStageContainerView *)owner {
    if (DSApplyingSplitKeyShift || _stageDragActive) return;
    DSApplyingSplitKeyShift = YES;
    DSStageContainerView *front = [self frontStageCard];
    DSStageContainerView *upper = [self cardOnHalf:1];
    DSStageContainerView *lower = [self cardOnHalf:0];
    BOOL keys = owner && !CGRectIsEmpty(keyboard) && CGRectGetHeight(keyboard) >= 150.0;
    BOOL parkThird = keys && [self bottomSplitIsTypingInCard:owner];
    BOOL parkBesideTop = keys && [self topSplitIsTypingInCard:owner];
    BOOL parkForThird = keys && [self thirdStageIsTypingInCard:owner];
    if (!keys) {
        [self logLift:[NSString stringWithFormat:@"shift skipped owner=%@ keyH=%.0f %@",
                       owner ? NSStringFromClass(owner.class) : @"nil",
                       CGRectGetHeight(keyboard),
                       [self lowerStageLiftSummary:keyboard]]];
    }

    DSStageContainerView *cards[4];
    cards[0] = upper;
    cards[1] = lower;
    cards[2] = front;
    cards[3] = (_floatContainer && _floatContainer != front && _floatContainer != upper && _floatContainer != lower)
        ? _floatContainer : nil;

    BOOL seenUpper = NO, seenLower = NO, seenFront = NO, seenFloat = NO;
    for (NSInteger i = 0; i < 4; i++) {
        DSStageContainerView *card = cards[i];
        if (!card) continue;
        if (card == upper && seenUpper) continue;
        if (card == lower && seenLower) continue;
        if (card == front && seenFront) continue;
        if (card == _floatContainer && seenFloat) continue;
        if (card == upper) seenUpper = YES;
        if (card == lower) seenLower = YES;
        if (card == front) seenFront = YES;
        if (card == _floatContainer) seenFloat = YES;

        CGFloat lift = 0.0;
        BOOL slideAside = (parkThird && (card == upper || card == _floatContainer)) ||
                          (parkBesideTop && (card == lower || card == _floatContainer)) ||
                          (parkForThird && card != _floatContainer && (card == upper || card == lower));
        if (keys && !slideAside) {
            // The card being typed in rises until it clears the keys.
            // The other cards leave to the side instead of climbing onto it.
            // The top card is already clear, so it comes down onto the keys.
            lift = [self splitKeyboardClearLiftForCard:card keyboard:keyboard];
            if (lift < 1.0 && parkBesideTop && card == upper) {
                CGFloat drop = [self dropNeededToSitOnKeyboard:keyboard forCard:card];
                if (drop > 1.0) lift = -drop;
            }
        }
        CGFloat had = card.liftOffset;
        if (fabs(had - lift) > 0.5) [card setLiftOffset:lift];
        if (card == upper && lift < -0.5) {
            [self logLift:[NSString stringWithFormat:@"upper drop lift=%.0f had=%.0f %@",
                           lift, had, [self lowerStageLiftSummary:keyboard]]];
        }
        if (card == lower || card == _floatContainer || card == front) {
            [self logLift:[NSString stringWithFormat:@"%@ applied lift=%.0f had=%.0f %@",
                           card == lower ? @"lower" : (card == _floatContainer ? @"float" : @"front"),
                           lift, had, [self lowerStageLiftSummary:keyboard]]];
        }
    }
    if (_container && _container != upper && _container != lower && _container != front &&
        fabs(_container.liftOffset) > 0.5) {
        [_container setLiftOffset:0.0];
    }
    if (_topContainer && _topContainer != upper && _topContainer != lower && _topContainer != front &&
        fabs(_topContainer.liftOffset) > 0.5) {
        [_topContainer setLiftOffset:0.0];
    }
    [self syncLiftChrome];
    DSApplyingSplitKeyShift = NO;
    // Park after the lift flag drops. A note from another stage in the same
    // burst must not slide the card that is actually being typed in.
    [self parkStagesForKeyboardOwner:owner keysUp:keys];
}

- (void)reapplyBottomKeyboardLift {
    if (_splitMode || _stageDragActive) return;
    if (CGRectIsEmpty(_keyboardFrame) || _searchSlot >= 0) return;
    if ([self hostedAppKeepsItsCardStill]) {
        DSStageContainerView *stuck = [self containerForSlot:_keyboardLiftSlot];
        DSStageContainerView *partner = nil;
        if (_stackSlotCount >= kDSMaxStackSlots) {
            partner = [self containerForSlot:_keyboardLiftSlot == 0 ? 1 : 0];
        }
        BOOL dirty = (stuck && stuck.liftOffset > 0.5) || (partner && partner != stuck && partner.liftOffset > 0.5);
        if (!dirty) return;
        [UIView performWithoutAnimation:^{
            if (stuck) [stuck setLiftOffset:0.0];
            if (partner && partner != stuck) [partner setLiftOffset:0.0];
        }];
        [self restoreCardStackingOrder];
        return;
    }
    DSStageContainerView *card = [self containerForSlot:_keyboardLiftSlot];
    if (!card || card.hidden || [self cardIsParked:card]) return;
    if (_stackSlotCount >= kDSMaxStackSlots && ![self slotIsBottomOfTwoStages:_keyboardLiftSlot]) return;
    CGFloat lift = [self liftNeededToClearKeyboard:_keyboardFrame forSlot:_keyboardLiftSlot];
    if (lift < 1.0) return;
    DSStageContainerView *other = nil;
    CGFloat companion = 0.0;
    if ([self slotIsBottomOfTwoStages:_keyboardLiftSlot]) {
        other = [self containerForSlot:_keyboardLiftSlot == 0 ? 1 : 0];
        if (other && ([self cardIsParked:other] || other.hidden)) other = nil;
        if (other) companion = [self keyboardCompanionLiftForSlot:_keyboardLiftSlot];
    }
    BOOL bottomReady = fabs(card.liftOffset - lift) < 0.5;
    BOOL topReady = !other || fabs(other.liftOffset - companion) < 0.5;
    if (bottomReady && topReady) return;
    [UIView performWithoutAnimation:^{
        [card setLiftOffset:lift];
        if (other) [other setLiftOffset:companion];
    }];
    [self bringCardAboveItsPartner:card];
}

- (BOOL)shouldKeepKeyboardLiftOnCard:(DSStageContainerView *)card {
    if (CGRectIsEmpty(_keyboardFrame) || !card) return NO;
    if ([self hostedAppKeepsItsCardStill]) return NO;
    if (_searchSlot >= 0 && card == [self containerForSlot:_searchSlot]) return YES;
    if (card == [self containerForSlot:_keyboardLiftSlot]) return YES;
    if (fabs(card.sideOffset) > 0.5) return NO;
    if (card == _floatContainer || card == _frontCard) return YES;
    if (![self slotIsBottomOfTwoStages:_keyboardLiftSlot]) return NO;
    DSStageContainerView *above = [self containerForSlot:_keyboardLiftSlot == 0 ? 1 : 0];
    return card == above;
}

- (void)liftCardBy:(CGFloat)offset duration:(NSTimeInterval)duration {
    [self liftCardBy:offset slot:_keyboardLiftSlot duration:duration];
}

- (CGFloat)offscreenLiftForCard:(DSStageContainerView *)card {
    if (!card) return 0.0;
    CGRect resting = [self fixedHalfFrame:[self halfForContainer:card]];
    return CGRectGetMaxY(resting) + 12.0;
}

// Two stages, typing in the lower one. The stage above leaves the screen so
// the one being typed in is what you see. Typing in the upper stage leaves
// the lower one where it is.
- (CGFloat)keyboardCompanionLiftForSlot:(NSInteger)slot {
    if (_stackSlotCount < kDSMaxStackSlots || slot == 2) return 0.0;
    DSStageContainerView *typing = [self containerForSlot:slot];
    if (!typing || [self cardIsParked:typing] || [self halfForContainer:typing] != 0) return 0.0;
    DSStageContainerView *above = [self containerForSlot:slot == 0 ? 1 : 0];
    if (!above || above == typing || [self cardIsParked:above] || above.hidden) return 0.0;
    return [self offscreenLiftForCard:above];
}

- (void)syncLiftChrome {
    if (_topRim) {
        CGFloat offset = _topContainer ? _topContainer.liftOffset : 0.0;
        CGFloat side = _topContainer ? _topContainer.sideOffset : 0.0;
        _topRim.transform = CGAffineTransformMakeTranslation(side, -offset);
    }
    if (_dragShell) {
        [_dragShell setOutlineShiftX:(_container ? _container.sideOffset : 0.0)
                                 lift:(_container ? _container.liftOffset : 0.0)];
    }
    if (_floatRim && _floatContainer) {
        _floatRim.transform = CGAffineTransformMakeTranslation(_floatContainer.sideOffset, -_floatContainer.liftOffset);
    }
}

// Split is open and the hovering third stage is still its own card.
// Typing in the bottom half should slide that card off the side, not lift it.
- (BOOL)bottomSplitIsTypingInCard:(DSStageContainerView *)owner {
    if (!_splitMode) return NO;
    DSStageContainerView *lower = [self cardOnHalf:0];
    if (!lower) return NO;
    if (owner == lower) return YES;
    if (_searchSlot >= 0 && [self containerForSlot:_searchSlot] == lower) return YES;
    return NO;
}

- (BOOL)thirdStageIsTypingInCard:(DSStageContainerView *)owner {
    if (!_splitMode || !_floatActive || _floatIsSplitCard) return NO;
    if (!_floatContainer || _floatContainer.hidden) return NO;
    if (owner == _floatContainer) return YES;
    if (_searchSlot >= 0 && [self containerForSlot:_searchSlot] == _floatContainer) return YES;
    return NO;
}

- (BOOL)topSplitIsTypingInCard:(DSStageContainerView *)owner {
    // Two stacked stages use the same halves as split. Typing in the top one
    // still has to slide the bottom one aside.
    if (!_splitMode && _stackSlotCount < kDSMaxStackSlots) return NO;
    DSStageContainerView *upper = [self cardOnHalf:1];
    if (!upper) return NO;
    if (owner == upper) return YES;
    if (_searchSlot >= 0 && [self containerForSlot:_searchSlot] == upper) return YES;
    return NO;
}

- (CGFloat)sideParkDistanceForCard:(DSStageContainerView *)card goLeft:(BOOL)goLeft {
    CGRect resting = [self placedFrameForCard:card state:DSStageStateOverlay];
    if (CGRectGetWidth(resting) < 40.0) resting = [self rootFrameOfCard:card];
    CGRect screen = [self screenBounds];
    // Clear the card and its rim, and stop there. A wider margin made the
    // whole stage travel further than it needs to leave the screen.
    CGFloat margin = kDSStageOuterDragBand + 18.0 + 8.0;
    if (goLeft) return -(CGRectGetMaxX(resting) + margin);
    return CGRectGetWidth(screen) - CGRectGetMinX(resting) + margin;
}

// Reading frame while the keyboard slide is on reports the shifted rect.
// Writing that rect back is what left a stage off to the side after the keys
// had already gone.
- (CGRect)frameWithoutKeyboardShift:(DSStageContainerView *)card {
    if (!card) return CGRectZero;
    CGRect frame = card.frame;
    if (fabs(card.sideOffset) > 0.5) frame.origin.x -= card.sideOffset;
    // A negative lift is the top card sitting down on the keyboard. The same
    // sum puts either shift back on the resting frame.
    if (fabs(card.liftOffset) > 0.5) frame.origin.y += card.liftOffset;
    return frame;
}

// Where the card is drawn, including a keyboard lift or a drop onto the keys.
- (CGRect)visualScreenFrameForCard:(DSStageContainerView *)card {
    if (!card) return CGRectZero;
    CGRect resting = (card == _container) ? [self primaryCardFrameInRoot] : [self frameWithoutKeyboardShift:card];
    resting.origin.x += card.sideOffset;
    resting.origin.y -= card.liftOffset;
    return resting;
}

- (void)assignFrame:(CGRect)frame toCard:(DSStageContainerView *)card {
    if (!card) return;
    CGFloat side = card.sideOffset;
    CGFloat lift = card.liftOffset;
    BOOL shifted = fabs(side) > 0.5 || fabs(lift) > 0.5;
    if (shifted) {
        [UIView performWithoutAnimation:^{
            [card setSideOffset:0.0];
            [card setLiftOffset:0.0];
        }];
    }
    if (!CGRectEqualToRect(card.frame, frame)) card.frame = frame;
    if (shifted) {
        [UIView performWithoutAnimation:^{
            [card setSideOffset:side];
            [card setLiftOffset:lift];
        }];
    }
}

static NSUInteger DSSideParkGeneration = 0;

- (void)commitSideParkForOwner:(DSStageContainerView *)owner keysUp:(BOOL)keysUp generation:(NSUInteger)generation {
    if (generation != DSSideParkGeneration) return;
    // A drag is holding the card under the finger. Parking it now slides
    // that card away, and the drag's layout animation writes the slide back.
    if (_stageDragActive) return;
    BOOL bottomTyping = keysUp && [self bottomSplitIsTypingInCard:owner];
    BOOL topTyping = keysUp && [self topSplitIsTypingInCard:owner];
    BOOL thirdTyping = keysUp && [self thirdStageIsTypingInCard:owner];
    DSStageContainerView *lower = [self cardOnHalf:0];
    DSStageContainerView *upper = [self cardOnHalf:1];
    if ([self cardIsParked:lower]) lower = nil;
    if ([self cardIsParked:upper]) upper = nil;
    BOOL hovering = _floatActive && !_floatIsSplitCard && _floatContainer && !_floatContainer.hidden &&
                    _floatContainer != lower && _floatContainer != upper;
    DSStageContainerView *third = hovering ? _floatContainer : nil;

    CGFloat thirdSide = 0.0;
    CGFloat lowerSide = 0.0;
    CGFloat upperSide = 0.0;
    if (bottomTyping) {
        // Same pairing as typing in the top: the other split card leaves left,
        // the third stage leaves right. The card being typed in stays.
        if (upper && upper != owner) upperSide = [self sideParkDistanceForCard:upper goLeft:YES];
        if (third) thirdSide = [self sideParkDistanceForCard:third goLeft:NO];
    } else if (topTyping) {
        if (lower && lower != owner) lowerSide = [self sideParkDistanceForCard:lower goLeft:YES];
        if (third) thirdSide = [self sideParkDistanceForCard:third goLeft:NO];
    } else if (thirdTyping) {
        if (upper && upper != owner) upperSide = [self sideParkDistanceForCard:upper goLeft:YES];
        if (lower && lower != owner) lowerSide = [self sideParkDistanceForCard:lower goLeft:NO];
    }

    // A keyboard note from another stage can slide the typing card off first.
    // Put that card back before the others move, or it stays gone.
    if (keysUp && owner && fabs(owner.sideOffset) > 0.5) {
        [UIView performWithoutAnimation:^{
            [owner.layer removeAllAnimations];
            [owner setSideOffset:0.0];
            [self syncLiftChrome];
        }];
    }

    BOOL (^alreadyThere)(DSStageContainerView *, CGFloat) = ^BOOL(DSStageContainerView *card, CGFloat side) {
        if (!card) return YES;
        if (fabs(card.sideOffset - side) > 0.5) return NO;
        if (fabs(side) > 0.5 && card.liftOffset > 0.5) return NO;
        return YES;
    };
    // cardOnHalf skips the front card. A swap can leave the slide on that
    // card, and the check above then thinks everyone is already home.
    BOOL leftover = !keysUp && [self anyStageHasSideShift];
    if (!leftover && alreadyThere(third, thirdSide) && alreadyThere(lower, lowerSide) && alreadyThere(upper, upperSide)) {
        [self syncLiftChrome];
        return;
    }
    [self logLift:[NSString stringWithFormat:@"side park top=%d bottom=%d third=%d lower=%.0f upper=%.0f float=%.0f",
                   topTyping, bottomTyping, thirdTyping, lowerSide, upperSide, thirdSide]];
    void (^move)(void) = ^{
        if (third) {
            if (fabs(thirdSide) > 0.5) [third setLiftOffset:0.0];
            [third setSideOffset:thirdSide];
        }
        if (lower) {
            if (fabs(lowerSide) > 0.5) [lower setLiftOffset:0.0];
            [lower setSideOffset:lowerSide];
        }
        if (upper) {
            if (fabs(upperSide) > 0.5) [upper setLiftOffset:0.0];
            [upper setSideOffset:upperSide];
        }
        if (!keysUp) {
            if (self->_container && self->_container != lower && self->_container != upper && self->_container != third) {
                [self->_container setSideOffset:0.0];
            }
            if (self->_topContainer && self->_topContainer != lower && self->_topContainer != upper && self->_topContainer != third) {
                [self->_topContainer setSideOffset:0.0];
            }
            if (self->_floatContainer && self->_floatContainer != lower && self->_floatContainer != upper && self->_floatContainer != third) {
                [self->_floatContainer setSideOffset:0.0];
            }
        }
        [self syncLiftChrome];
    };
    if (!keysUp) {
        // The keyboard is gone. Come back on this turn, not after the slide
        // animation. The card that was typing was being skipped before.
        [UIView performWithoutAnimation:^{
            if (third) [third.layer removeAllAnimations];
            if (lower) [lower.layer removeAllAnimations];
            if (upper) [upper.layer removeAllAnimations];
            if (_topRim) [_topRim.layer removeAllAnimations];
            if (_floatRim) [_floatRim.layer removeAllAnimations];
            move();
        }];
        return;
    }
    [UIView animateWithDuration:0.28
                          delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut
                     animations:move
                     completion:nil];
}

- (BOOL)stageHasSideShift:(DSStageContainerView *)card {
    return card && fabs(card.sideOffset) > 0.5;
}

- (BOOL)anyStageHasSideShift {
    return [self stageHasSideShift:_container] ||
           [self stageHasSideShift:_topContainer] ||
           [self stageHasSideShift:_floatContainer];
}

// The sideways slide is only for the keyboard. A swap, a drag, and the keys
// going away all have to drop it, or the card stays off the left of the screen.
- (void)clearKeyboardSideShift {
    DSSideParkGeneration += 1;
    if (![self anyStageHasSideShift] &&
        (!_topRim || CGAffineTransformIsIdentity(_topRim.transform)) &&
        (!_floatRim || CGAffineTransformIsIdentity(_floatRim.transform))) {
        return;
    }
    [UIView performWithoutAnimation:^{
        void (^zero)(DSStageContainerView *) = ^(DSStageContainerView *card) {
            if (!card) return;
            [card.layer removeAllAnimations];
            if (fabs(card.sideOffset) > 0.5) [card setSideOffset:0.0];
        };
        zero(self->_container);
        zero(self->_topContainer);
        zero(self->_floatContainer);
        if (self->_topRim) [self->_topRim.layer removeAllAnimations];
        if (self->_floatRim) [self->_floatRim.layer removeAllAnimations];
        [self syncLiftChrome];
    }];
}

// YES when the card that should be off to the side is still on screen, or a
// card that should be on screen is still slid away. The keyboard frame can
// stay the same across a swap, and that used to skip this check.
- (BOOL)sideParkNeedsUpdate {
    BOOL keysUp = !CGRectIsEmpty(_keyboardFrame) && CGRectGetHeight(_keyboardFrame) >= 150.0;
    DSStageContainerView *owner = keysUp ? [self containerForSlot:_keyboardLiftSlot] : nil;
    BOOL topTyping = keysUp && [self topSplitIsTypingInCard:owner];
    BOOL bottomTyping = keysUp && [self bottomSplitIsTypingInCard:owner];
    BOOL thirdTyping = keysUp && [self thirdStageIsTypingInCard:owner];
    DSStageContainerView *lower = [self cardOnHalf:0];
    DSStageContainerView *upper = [self cardOnHalf:1];
    BOOL thirdLive = _splitMode && _floatActive && !_floatIsSplitCard && _floatContainer && !_floatContainer.hidden &&
                     _floatContainer != lower && _floatContainer != upper;
    if (!keysUp || (!topTyping && !bottomTyping && !thirdTyping)) {
        return [self anyStageHasSideShift];
    }
    BOOL (^parked)(DSStageContainerView *) = ^BOOL(DSStageContainerView *card) {
        return [self stageHasSideShift:card];
    };
    if (topTyping) {
        if (lower && !parked(lower)) return YES;
        if (upper && parked(upper)) return YES;
        if (thirdLive && !parked(_floatContainer)) return YES;
        return NO;
    }
    if (bottomTyping) {
        if (upper && !parked(upper)) return YES;
        if (lower && parked(lower)) return YES;
        if (thirdLive && !parked(_floatContainer)) return YES;
        return NO;
    }
    if (lower && !parked(lower)) return YES;
    if (upper && !parked(upper)) return YES;
    if (_floatContainer && parked(_floatContainer)) return YES;
    return NO;
}

- (void)parkStagesForKeyboardOwner:(DSStageContainerView *)owner keysUp:(BOOL)keysUp {
    DSSideParkGeneration += 1;
    NSUInteger generation = DSSideParkGeneration;
    if (!keysUp) {
        [self commitSideParkForOwner:nil keysUp:NO generation:generation];
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf commitSideParkForOwner:owner keysUp:YES generation:generation];
    });
}

- (void)liftCardBy:(CGFloat)offset slot:(NSInteger)slot duration:(NSTimeInterval)duration {
    if (_stageDragActive) return;
    DSStageState layoutState = DSStageStateOverlay;
    DSStageContainerView *card = [self containerForSlot:slot];
    if (!card || [self cardIsParked:card]) return;

    offset = MIN(MAX(offset, 0.0), [self maxLiftForSlot:slot state:layoutState]);

    DSStageContainerView *other = nil;
    if (_stackSlotCount >= kDSMaxStackSlots && slot != 2) {
        other = [self containerForSlot:slot == 0 ? 1 : 0];
        if (other && [self cardIsParked:other]) other = nil;
    }

    // The upper stage leaves upward. The lower stage rises until it is fully
    // above the keyboard.
    CGFloat companion = 0.0;
    if (offset > 0.5 && [self slotIsBottomOfTwoStages:slot]) {
        companion = [self keyboardCompanionLiftForSlot:slot];
    }

    BOOL cardAlready = fabs(offset - card.liftOffset) < 0.5;
    BOOL otherAlready = !other || fabs(other.liftOffset - companion) < 0.5;
    if (cardAlready && otherAlready) {
        if (offset < 0.5) [self restoreKeyboardBaseForSlot:slot];
        return;
    }

    void (^lift)(void) = ^{
        // Do not tell the app a new size. That transaction blanks it.
        // The moving card comes to the front so it can overlap the other card.
        [card setLiftOffset:offset];
        if (other) [other setLiftOffset:companion];
        if (offset < 0.5) {
            [self restoreKeyboardBaseForSlot:slot];
        }
        if (offset > 0.5) {
            [self bringCardAboveItsPartner:card];
        } else {
            [self restoreCardStackingOrder];
        }
        [self bringShelfToFront];
    };
    if (offset > 0.5 && duration > 0.0) {
        [UIView animateWithDuration:duration animations:lift];
    } else {
        lift();
    }
    if (!cardAlready || !otherAlready) {
        DSDiagnosticsRecordFormat(@"SpringBoard: lifted stack slot %ld by %.0f companion %.0f",
                                  (long)slot, offset, companion);
    }
}

- (void)pushLiftedGeometryToApp {
    DSStageState layoutState = DSStageStateOverlay;
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

// The stage is always a floating card. It never resizes the app behind it.
- (CGRect)stageFrameForState:(DSStageState)state {
    return [self restingStageFrameForState:state];
}

// One size for every stage, taken from the screen and never changed. Top and
// bottom are the same width and height. The keyboard only slides the card.
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
    // of wallpaper shows around it. Both cards are the same size. The top card
    // sits up against the status bar. The bar itself stays hidden until tapped.
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
    // A little rounder than the last build, still inside the rim's curve.
    CGFloat radius = [self displayCornerRadius] - 10.0;
    if (radius < 34.0) radius = 34.0;
    if (radius > 44.0) radius = 44.0;
    return radius;
}

// Split cards grow into the gap so the two halves sit closer together.
- (CGRect)splitPairFrame:(NSInteger)half {
    CGRect screen = [self screenBounds];
    CGFloat side = 2.0;
    CGFloat top = kDSStackCardInset;
    CGFloat bottom = 4.0;
    CGFloat gap = 2.0;
    CGFloat width = CGRectGetWidth(screen) - side * 2.0;
    CGFloat slotHeight = floor((CGRectGetHeight(screen) - top - bottom - gap) * 0.5);
    if (half == 1) return CGRectMake(side, top, width, slotHeight);
    return CGRectMake(side, top + slotHeight + gap, width, slotHeight);
}

- (CGRect)restingStageFrameForState:(DSStageState)state {
    CGRect bottom = [self fixedHalfFrame:0];
    if (state == DSStageStateClosed || state == DSStageStateMinimized) {
        // Far enough past the screen that the card's outline cannot show
        // under the home bar while no stage is open.
        bottom.origin.y = CGRectGetHeight([self screenBounds]) + 80.0;
    }
    return bottom;
}

- (CGFloat)cornerRadiusForState:(DSStageState)state {
    (void)state;
    return [self stageCardCornerRadius];
}

// Whatever keyboard was up went away with the app that owned it.
- (void)forgetStagedAppKeyboard {
    DSLeaveTextEffectsWindowWithTheCard(NO);
    _keyboardFrame = CGRectZero;
    _keyboardLiftSlot = 0;
    _keyboardDrawnOutside = NO;
    [_container setLiftOffset:0.0];
    _container.keyboardBandHeight = 0.0;
    if (_topContainer) {
        [_topContainer setLiftOffset:0.0];
        _topContainer.keyboardBandHeight = 0.0;
    }
    _notedStrayKeyboard = NO;
    _container.passThroughToHost = NO;
    [_container setClipsContents:YES];
    if (self.isStageVisible) {
        [self layoutStageForState:DSStageStateOverlay];
    }
}

- (UIEdgeInsets)stageSafeAreaInsets {
    if (!_sceneHost.isHosting || CGRectIsEmpty(_keyboardFrame)) return UIEdgeInsetsZero;
    if (_stackSlotCount < kDSMaxStackSlots) return UIEdgeInsetsZero;
    if (_keyboardDrawnOutside) return UIEdgeInsetsZero;

    DSStageState layoutState = DSStageStateOverlay;
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
    if (_keyboardDrawnOutside) return UIEdgeInsetsZero;

    DSStageState layoutState = DSStageStateOverlay;
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

- (void)bringTopStackAbovePrimaryShell {
    if (!_topContainer || !_window) return;
    UIView *root = _window.rootViewController.view;
    if (!root) return;
    if (_dragShell && _dragShell.superview == root) {
        if (_topContainer.superview != root) {
            [root addSubview:_topContainer];
        }
        [root insertSubview:_topContainer aboveSubview:_dragShell];
    }
    if (_topRim && _topRim.superview == root) {
        [root insertSubview:_topRim belowSubview:_topContainer];
        _topRim.hidden = _topContainer.hidden;
    }
    [self bringShelfToFront];
}

- (void)ensureTopStackInfrastructure {
    if (_topContainer) return;

    UIView *root = _window.rootViewController.view;
    _topContainer = [[DSStageContainerView alloc] initWithFrame:CGRectZero];
    _topContainer.hidden = YES;
    _topContainer.cornerRadius = _container.cornerRadius;
    __weak __typeof(self) bandSelf = self;
    _topContainer.keyboardBandLayoutHandler = ^{
        [bandSelf clipHostedSceneForKeyboardBandOnSlot:1];
    };
    // The card lives in the drag shell, not on the root, so "above the card"
    // would just add this on top of the notch and hide it.
    if (_shelf.superview == root) [root insertSubview:_topContainer belowSubview:_shelf];
    else [root addSubview:_topContainer];
    __weak __typeof(self) liftSelf = self;
    _topContainer.liftDidChangeHandler = ^{
        [liftSelf syncLiftChrome];
    };

    _topPicker = [[DSAppPickerViewController alloc] init];
    _topPicker.delegate = self;
    [_window.rootViewController addChildViewController:_topPicker];
    _topPicker.view.frame = _topContainer.contentView.bounds;
    _topPicker.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_topContainer.contentView addSubview:_topPicker.view];
    [_topPicker didMoveToParentViewController:_window.rootViewController];

    _topDragPan = [[DSQuickPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleStagePan:)];
    _topDragPan.cancelsTouchesInView = YES;
    _topDragPan.delaysTouchesBegan = NO;
    _topDragPan.delegate = self;
    [_topContainer addGestureRecognizer:_topDragPan];
    UITapGestureRecognizer *topWakeTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleCardWakeTap:)];
    topWakeTap.cancelsTouchesInView = NO;
    [_topContainer addGestureRecognizer:topWakeTap];
    DSStageRimHitView *topRim = [[DSStageRimHitView alloc] initWithFrame:CGRectZero];
    topRim.hitBand = kDSStageOuterDragBand + 18.0;
    __weak __typeof(self) rimSelf = self;
    topRim.rejectsWindowPoint = ^BOOL(CGPoint windowPoint) {
        DSStageManager *manager = rimSelf;
        if (!manager || manager->_stackSlotCount < kDSMaxStackSlots) return NO;
        if (manager->_topContainer.liftOffset > 1.0) return NO;
        // Only the other card's interior. Its edge is this rim's grab, and
        // rejecting the whole card made the top rim harder to hold than the bottom.
        CGRect other = CGRectInset([manager rootFrameOfCard:manager->_container], kDSStageRimGrabBand, kDSStageRimGrabBand);
        return CGRectContainsPoint(other, windowPoint);
    };
    _topRim = topRim;
    _topRim.backgroundColor = UIColor.clearColor;
    _topRimLayer = [CAShapeLayer layer];
    _topRimLayer.fillColor = UIColor.clearColor.CGColor;
    _topRimLayer.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;
    _topRimLayer.lineWidth = 3.0;
    _topRimLayer.shadowOpacity = 0.0;
    [_topRim.layer addSublayer:_topRimLayer];
    _topRimPulseLayer = [CAShapeLayer layer];
    _topRimPulseLayer.fillColor = UIColor.clearColor.CGColor;
    _topRimPulseLayer.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.95].CGColor;
    _topRimPulseLayer.lineWidth = 1.5;
    _topRimPulseLayer.opacity = 0.0;
    [_topRim.layer addSublayer:_topRimPulseLayer];
    [root insertSubview:_topRim belowSubview:_topContainer];
    UIPanGestureRecognizer *rimPan = [[DSQuickPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleStagePan:)];
    rimPan.cancelsTouchesInView = YES;
    rimPan.delaysTouchesBegan = NO;
    rimPan.delegate = self;
    [_topRim addGestureRecognizer:rimPan];
    [self bringShelfToFront];

    __weak __typeof(self) weakSelf = self;
    __weak DSStageContainerView *weakTop = _topContainer;
    _topContainer.stackAddHandler = ^{
        [weakSelf addSecondStageAnimated:YES];
    };
    [self bringTopStackAbovePrimaryShell];
    _topContainer.minimizeHandler = ^{
        [weakSelf minimizeIndividualCard:weakTop];
    };
}

- (BOOL)cardIsParked:(DSStageContainerView *)card {
    if (card == _floatContainer) return NO;
    if (card == _topContainer) return _secondParked;
    return _primaryParked;
}

- (void)setParked:(BOOL)parked forCard:(DSStageContainerView *)card {
    if (card == _floatContainer) return;
    if (card == _topContainer) _secondParked = parked;
    else _primaryParked = parked;
    DSSceneHost *host = [self sceneHostForCard:card];
    [host setStaysBackgrounded:parked];
    if (parked) [self holdHostViewAtStageSize:host];
    else [self returnHostView:host toCard:card];
}

- (CGRect)offscreenCardFrame {
    CGRect off = [self fixedHalfFrame:0];
    off.origin.y = CGRectGetHeight([self screenBounds]) + 80.0;
    return off;
}

- (BOOL)cardMinimizedOnLeft:(DSStageContainerView *)card {
    if (card == _topContainer) return _secondMinimizedLeft;
    return _primaryMinimizedLeft;
}

// A small card just past the corner it was dragged to. A full-size frame
// aimed off the bottom interpolates through the middle of the screen.
- (CGRect)cornerParkFrameForCard:(DSStageContainerView *)card {
    CGRect screen = [self screenBounds];
    CGFloat side = 56.0;
    BOOL left = [self cardMinimizedOnLeft:card];
    CGFloat x = left ? -(side + 36.0) : (CGRectGetWidth(screen) + 36.0);
    CGFloat y = CGRectGetHeight(screen) + 28.0;
    return CGRectMake(x, y, side, side);
}

// Where the card shrinks to during the home swipe, just over the corner icon.
- (CGRect)minimizeFlightFrameForCard:(DSStageContainerView *)card {
    BOOL left = [self cardMinimizedOnLeft:card];
    CGRect icon = [self openAppIconFrameOnLeft:left lift:0.0];
    return CGRectInset(icon, -8.0, -8.0);
}

// Two open stages leave in opposite directions. The top half goes left.
- (void)assignOppositeMinimizeSidesForHome {
    BOOL primaryLive = _sceneHost.isHosting && !_primaryParked;
    BOOL secondLive = _topSceneHost.isHosting && !_secondParked && _topContainer != nil;
    if (primaryLive && secondLive) {
        DSStageContainerView *upper = [self containerOnHalf:1];
        if (upper == _topContainer) {
            _secondMinimizedLeft = YES;
            _primaryMinimizedLeft = NO;
        } else {
            _primaryMinimizedLeft = YES;
            _secondMinimizedLeft = NO;
        }
        DSDiagnosticsRecord(@"SpringBoard: home sends the two stages to opposite corners");
        return;
    }
    if (primaryLive && _secondParked) _primaryMinimizedLeft = !_secondMinimizedLeft;
    else if (secondLive && _primaryParked) _secondMinimizedLeft = !_primaryMinimizedLeft;
}

- (CGRect)openAppIconFrameOnLeft:(BOOL)left lift:(CGFloat)lift {
    CGRect bounds = [self screenBounds];
    CGFloat side = 26.0;
    CGFloat insetX = 4.0;
    CGFloat insetY = 8.0;
    CGFloat x = left ? insetX : CGRectGetWidth(bounds) - insetX - side;
    CGFloat y = CGRectGetHeight(bounds) - insetY - side - lift;
    return CGRectMake(x, y, side, side);
}

// Where a card sits. Parked, closed and minimized cards are the same size, just
// below the screen, so coming back is a move and not a resize.
- (CGRect)restingFrameForPrimaryCardState:(DSStageState)state {
    if (state == DSStageStateOverlay) {
        NSInteger half = _primaryHalf == 0 ? 0 : 1;
        return [self fixedHalfFrame:half];
    }
    return [self stageFrameForState:state];
}

- (CGRect)primaryCardFrameInRoot {
    if (!_container) return CGRectZero;
    UIView *root = _window.rootViewController.view;
    CGRect frame;
    if (_dragShell && _dragShell.superview) {
        frame = [_dragShell convertRect:_container.frame toView:root];
    } else {
        frame = _container.frame;
    }
    // The keyboard lift is a transform, so frame is the card after it has
    // moved up. Callers want the resting frame. Measuring the lifted one
    // makes the next pass think the card is already clear and drop it back.
    if (fabs(_container.liftOffset) > 0.5) {
        frame.origin.y += _container.liftOffset;
    }
    if (fabs(_container.sideOffset) > 0.5) {
        frame.origin.x -= _container.sideOffset;
    }
    return frame;
}

- (BOOL)framesMatchWithinHalfPoint:(CGRect)a other:(CGRect)b {
    return fabs(CGRectGetMinX(a) - CGRectGetMinX(b)) < 0.5 &&
           fabs(CGRectGetMinY(a) - CGRectGetMinY(b)) < 0.5 &&
           fabs(CGRectGetWidth(a) - CGRectGetWidth(b)) < 0.5 &&
           fabs(CGRectGetHeight(a) - CGRectGetHeight(b)) < 0.5;
}

// A card dragged off the half snap points keeps its overlay frame instead of
// being snapped back on every layout pass. A card parked above the screen is
// the entrance position for a new stage, not a place the user left it.
- (BOOL)primaryCardHasCustomOverlayFrame {
    if (_stackSlotCount > 1 || !_container || _state != DSStageStateOverlay) return NO;
    if (_overlaySettling) return NO;
    CGRect current = [self primaryCardFrameInRoot];
    CGRect screen = [self screenBounds];
    CGRect half = [self fixedHalfFrame:0];
    // A card hanging off the screen, or shrunk on the way to a corner, is a
    // drag that did not finish. It is not a place to rest.
    if (fabs(CGRectGetWidth(current) - CGRectGetWidth(half)) > 12.0 ||
        fabs(CGRectGetHeight(current) - CGRectGetHeight(half)) > 12.0) return NO;
    if (CGRectGetMinX(current) < -8.0 || CGRectGetMaxX(current) > CGRectGetWidth(screen) + 8.0) return NO;
    if (CGRectGetMinY(current) < -8.0 || CGRectGetMaxY(current) > CGRectGetMaxY(screen) + 8.0) return NO;
    if ([self framesMatchWithinHalfPoint:current other:[self fixedHalfFrame:0]]) return NO;
    if ([self framesMatchWithinHalfPoint:current other:[self fixedHalfFrame:1]]) return NO;
    return YES;
}

- (void)setPrimaryCardFrameInRoot:(CGRect)cardFrame {
    if (!_container) return;
    CGFloat band = kDSStageOuterDragBand + 18.0;
    if (_dragShell) {
        CGRect shellFrame = CGRectInset(cardFrame, -band, -band);
        if (!CGRectEqualToRect(_dragShell.frame, shellFrame)) {
            _dragShell.frame = shellFrame;
        }
        CGRect local = CGRectMake(band, band, cardFrame.size.width, cardFrame.size.height);
        [self assignFrame:local toCard:_container];
        [_dragShell setOutlineLift:_container.liftOffset];
        [_dragShell refreshOutline];
    } else {
        [self assignFrame:cardFrame toCard:_container];
    }
}

- (CGFloat)minPrimaryCardOriginYForOverlayDrag {
    return CGRectGetMinY([self fixedHalfFrame:1]);
}

- (CGFloat)maxPrimaryCardOriginYForOverlayDrag {
    return CGRectGetMinY([self fixedHalfFrame:0]);
}

- (NSInteger)primaryHalfSnappedForCardFrame:(CGRect)cardFrame {
    CGRect top = [self fixedHalfFrame:1];
    CGRect bottom = [self fixedHalfFrame:0];
    CGFloat pivot = (CGRectGetMidY(top) + CGRectGetMidY(bottom)) / 2.0;
    return (CGRectGetMidY(cardFrame) < pivot) ? 1 : 0;
}

- (CGRect)placedFrameForCard:(DSStageContainerView *)card state:(DSStageState)state {
    if (state == DSStageStateClosed) {
        return [self offscreenCardFrame];
    }
    if ([self cardIsParked:card] || state == DSStageStateMinimized) {
        return [self cornerParkFrameForCard:card];
    }
    if (card == _expandedCard && state == DSStageStateOverlay) {
        return [self fullScreenStageFrame];
    }
    if (_floatActive && _frontCard && card == _frontCard) {
        return [self frameForFloatRest:_floatRest];
    }
    if (card == _floatContainer) {
        if (_floatActive && _floatIsSplitCard) return [self splitPairFrame:_floatSplitHalf == 1 ? 1 : 0];
        if (_floatActive) return [self frameForFloatRest:_floatRest];
        return card.frame;
    }
    if (_stackSlotCount <= 1) {
        if (state == DSStageStateOverlay) {
            if (card == _container && [self primaryCardHasCustomOverlayFrame]) {
                return [self primaryCardFrameInRoot];
            }
            return [self restingFrameForPrimaryCardState:state];
        }
        return [self stageFrameForState:state];
    }
    if (_splitMode && card == _splitMiddleCard && card != _frontCard) {
        return [self floatCardCenteredFrame];
    }
    NSInteger half = [self halfForContainer:card];
    if (_splitMode && card != _frontCard && (half == 0 || half == 1)) return [self splitPairFrame:half];
    return [self fixedHalfFrame:half];
}

- (CGRect)frameForHalf:(NSInteger)half state:(DSStageState)state {
    (void)state;
    return [self fixedHalfFrame:half];
}

- (NSInteger)visualHalfForCard:(DSStageContainerView *)card {
    if (!card || card == _frontCard) return -1;
    if (card == _floatContainer && _floatIsSplitCard) return _floatSplitHalf == 1 ? 1 : 0;
    if (card == _topContainer) return _secondHalf == 0 ? 0 : 1;
    if (card == _container) return _primaryHalf == 0 ? 0 : 1;
    return -1;
}

- (NSInteger)halfForContainer:(DSStageContainerView *)card {
    if (card == _floatContainer) return -1;
    if (card == _topContainer) return _secondHalf;
    // Where this card is drawn. A single card's primary classification does
    // not live here: reporting that as half 1 would measure the top frame.
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
    // The slide belongs to whichever card was on the other half. Carrying it
    // through the swap is what left that card off the left edge for good.
    // The layout animation was also writing the slide back when it finished.
    [self clearKeyboardSideShift];
    [_container setLiftOffset:0.0];
    [_topContainer setLiftOffset:0.0];
    void (^layout)(void) = ^{
        [self layoutAllStackSlotsForState:self->_state];
        [self restoreCardStackingOrder];
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
    DSStageState layoutState = DSStageStateOverlay;
    [self layoutHostedAppInSlot:0 state:layoutState];
    [self layoutHostedAppInSlot:1 state:layoutState];
    if (!CGRectIsEmpty(_keyboardFrame) && [self springBoardIsDrawingKeyboard]) {
        NSString *bundle = [self hostedBundleForKeyboardNotifications];
        if (bundle.length > 0) {
            [self extendHostedSceneForKeyboard:_keyboardFrame source:bundle];
            [self noteKeyboardFrame:_keyboardFrame source:bundle duration:0.0];
        }
    }
    DSDiagnosticsRecord(@"SpringBoard: swapped the two stages between top and bottom");
}

- (DSStageContainerView *)containerForSlot:(NSInteger)slot {
    if (slot == 2) return _floatContainer;
    return slot == 0 ? _container : _topContainer;
}

- (DSSceneHost *)sceneHostForSlot:(NSInteger)slot {
    if (slot == 2) return _floatSceneHost;
    return slot == 0 ? _sceneHost : _topSceneHost;
}

- (void)setSceneHost:(DSSceneHost *)host forSlot:(NSInteger)slot {
    if (slot == 2) _floatSceneHost = host;
    else if (slot == 0) _sceneHost = host;
    else _topSceneHost = host;
}

- (DSAppPickerViewController *)pickerForSlot:(NSInteger)slot {
    if (slot == 2) return _floatPicker;
    return slot == 0 ? _picker : _topPicker;
}

- (DSAppPickerViewController *)pickerForCard:(DSStageContainerView *)card {
    if (card == _floatContainer) return _floatPicker;
    if (card == _topContainer) return _topPicker;
    return _picker;
}

- (NSInteger)slotForPicker:(DSAppPickerViewController *)picker {
    if (picker == _floatPicker) return 2;
    return picker == _topPicker ? 1 : 0;
}

- (DSSceneHost *)sceneHostForCard:(DSStageContainerView *)card {
    if (card == _floatContainer) return _floatSceneHost;
    if (card == _topContainer) return _topSceneHost;
    return _sceneHost;
}

- (CGRect)rootFrameOfCard:(DSStageContainerView *)card {
    if (card == _container) return [self primaryCardFrameInRoot];
    return card.frame;
}

- (BOOL)cardMatchesItsFrame:(DSStageContainerView *)card {
    if (!card) return NO;
    if (card == _floatContainer || card == _expandedCard) return YES;
    if (_splitMode && (card == _container || card == _topContainer)) return YES;
    if (card == _container && [self primaryCardHasCustomOverlayFrame]) return YES;
    return NO;
}

- (CGRect)fullScreenStageFrame {
    return CGRectInset([self screenBounds], kDSStackCardInset, kDSStackCardInset);
}

- (CGRect)clampedOnScreenFrame:(CGRect)frame {
    CGRect screen = [self screenBounds];
    CGFloat inset = 8.0;
    if (CGRectGetWidth(frame) > CGRectGetWidth(screen) - inset * 2.0) {
        frame.size.width = CGRectGetWidth(screen) - inset * 2.0;
    }
    if (CGRectGetHeight(frame) > CGRectGetHeight(screen) - inset * 2.0) {
        frame.size.height = CGRectGetHeight(screen) - inset * 2.0;
    }
    if (CGRectGetMinX(frame) < inset) frame.origin.x = inset;
    if (CGRectGetMinY(frame) < inset) frame.origin.y = inset;
    CGFloat maxX = CGRectGetWidth(screen) - inset - CGRectGetWidth(frame);
    CGFloat maxY = CGRectGetHeight(screen) - inset - CGRectGetHeight(frame);
    if (CGRectGetMinX(frame) > maxX) frame.origin.x = maxX;
    if (CGRectGetMinY(frame) > maxY) frame.origin.y = maxY;
    return frame;
}

- (CGRect)frameJustInsideHalf:(NSInteger)half {
    // The same size as every other card. A smaller hover frame was the bottom
    // stage that did not match the rim.
    return [self fixedHalfFrame:half == 0 ? 0 : 1];
}

// The third stage sits just inside the half it covers. 4 points on each
// edge keeps it smaller than that half without looking pinched.
- (CGRect)floatCardFrameForHalf:(NSInteger)half {
    CGRect base = _splitMode ? [self splitPairFrame:half == 0 ? 0 : 1] : [self fixedHalfFrame:half == 0 ? 0 : 1];
    return CGRectInset(base, 4.0, 4.0);
}

- (CGRect)floatCardCenteredFrame {
    CGRect top = _splitMode ? [self splitPairFrame:1] : [self fixedHalfFrame:1];
    CGRect bottom = _splitMode ? [self splitPairFrame:0] : [self fixedHalfFrame:0];
    CGRect sized = CGRectInset(top, 4.0, 4.0);
    CGFloat mid = (CGRectGetMaxY(top) + CGRectGetMinY(bottom)) * 0.5;
    sized.origin.y = mid - CGRectGetHeight(sized) * 0.5;
    return sized;
}

- (CGRect)frameForFloatRest:(NSInteger)rest {
    if (rest == 1) return [self floatCardFrameForHalf:1];
    if (rest == 2) return [self floatCardFrameForHalf:0];
    return [self floatCardCenteredFrame];
}

// 1 top, 2 bottom, 0 middle. -1 means a sideways drop that swaps with a half.
- (NSInteger)floatRestForFrame:(CGRect)frame swapHalf:(NSInteger *)swapHalf {
    CGRect screen = [self screenBounds];
    CGFloat midX = CGRectGetMidX(frame);
    CGFloat midY = CGRectGetMidY(frame);
    CGFloat width = CGRectGetWidth(screen);
    CGFloat height = CGRectGetHeight(screen);
    BOOL towardSide = midX < width * 0.30 || midX > width * 0.70;
    BOOL nearCenter = fabs(midY - height * 0.5) < height * 0.22;
    if (towardSide && nearCenter) {
        CGRect top = [self splitPairFrame:1];
        CGRect bottom = [self splitPairFrame:0];
        NSInteger half = fabs(midY - CGRectGetMidY(top)) <= fabs(midY - CGRectGetMidY(bottom)) ? 1 : 0;
        if (swapHalf) *swapHalf = half;
        return -1;
    }
    if (midY < height * 0.36) return 1;
    if (midY > height * 0.64) return 2;
    return 0;
}

- (void)clearSwapPreview {
    if (_swapPreviewHalf < 0) return;
    NSInteger half = _swapPreviewHalf;
    _swapPreviewHalf = -1;
    if ([DSSceneHost sceneSettingsUpdateDepth] > 0) return;
    DSStageContainerView *target = [self cardOnHalf:half];
    if (!target || target == [self frontStageCard]) return;
    CGRect home = [self splitPairFrame:half];
    @try {
        [UIView performWithoutAnimation:^{
            [self placeCard:target atFrame:home];
        }];
    } @catch (NSException *exception) {
        DSCrashLogRemember([NSString stringWithFormat:@"swap preview threw %@", exception.reason ?: @"?"]);
    }
}

- (void)previewSwapOfHalf:(NSInteger)half direction:(CGFloat)direction {
    if ([DSSceneHost sceneSettingsUpdateDepth] > 0) return;
    if (_swapPreviewHalf != half) [self clearSwapPreview];
    _swapPreviewHalf = half;
    DSStageContainerView *target = [self cardOnHalf:half];
    if (!target || target == [self frontStageCard]) return;
    CGRect home = [self splitPairFrame:half];
    CGRect shifted = home;
    shifted.origin.x -= direction * 18.0;
    shifted.origin.y += (half == 1) ? 14.0 : -14.0;
    @try {
        [UIView performWithoutAnimation:^{
            [self placeCard:target atFrame:shifted];
        }];
    } @catch (NSException *exception) {
        DSCrashLogRemember([NSString stringWithFormat:@"swap preview threw %@", exception.reason ?: @"?"]);
    }
}

// The split card becomes the card on top. The card that was on top becomes
// that split half, at the same size as the other split card, behind it.
- (void)swapFloatWithSplitHalf:(NSInteger)half {
    if (!_floatActive) return;
    if ([DSSceneHost sceneSettingsUpdateDepth] > 0) return;
    [self clearSwapPreview];
    half = half == 0 ? 0 : 1;
    DSStageContainerView *front = [self frontStageCard];
    DSStageContainerView *splitCard = [self cardOnHalf:half];
    if (!front || !splitCard || front == splitCard || splitCard.hidden) return;
    if (front == _floatContainer) {
        _floatIsSplitCard = YES;
        _floatSplitHalf = half;
    } else if (front == _container) {
        _primaryHalf = half;
    } else if (front == _topContainer) {
        _secondHalf = half;
    }
    if (splitCard == _floatContainer) _floatIsSplitCard = NO;
    _frontCard = splitCard;
    // The card that was in this half stays on that half, in front, at the
    // smaller front size. A stored keyboard frame must not resize it.
    _floatRest = (half == 1) ? 1 : 2;
    _splitMiddleCard = nil;
    DSLiftSlotAt(0)->hasRestingFrame = NO;
    DSLiftSlotAt(1)->hasRestingFrame = NO;
    DSLiftSlotAt(2)->hasRestingFrame = NO;
    CGRect splitFrame = [self splitPairFrame:half];
    CGRect frontFrame = [self frameForFloatRest:_floatRest];
    @try {
        [self animateSpring:^{
            [front setLiftOffset:0.0];
            [splitCard setLiftOffset:0.0];
            [self placeCard:front atFrame:splitFrame];
            [self placeCard:splitCard atFrame:frontFrame];
            if (front == self->_topContainer || splitCard == self->_topContainer) {
                [self placeTopRimAroundCard:self->_topContainer];
            }
            if (front == self->_floatContainer || splitCard == self->_floatContainer) {
                [self placeFloatRim];
            }
            [self bringFloatAboveSplit];
        } completion:^{
            if ([DSSceneHost sceneSettingsUpdateDepth] == 0) {
                [self resizeHostOnCard:front toFrame:splitFrame throttle:NO];
                [self resizeHostOnCard:splitCard toFrame:frontFrame throttle:NO];
            }
            [self layoutAllStackSlotsForState:DSStageStateOverlay];
            [self bringFloatAboveSplit];
            [self noteStageGeometry:@"swap"];
        }];
    } @catch (NSException *exception) {
        DSCrashLogRemember([NSString stringWithFormat:@"split swap threw %@", exception.reason ?: @"?"]);
    }
    NSString *frontName = splitCard == _container ? @"primary" : (splitCard == _topContainer ? @"second" : @"float");
    NSString *intoName = front == _container ? @"primary" : (front == _topContainer ? @"second" : @"float");
    DSLogAppend([NSString stringWithFormat:@"[SWAP] %@ is now in front on half %ld, %@ moved into that split",
                 frontName, (long)half, intoName]);
}

- (CGRect)hoverFrameCenteredOn:(CGPoint)point {
    NSInteger half = [self primaryHalfSnappedForCardFrame:CGRectMake(point.x, point.y, 1.0, 1.0)];
    return [self frameJustInsideHalf:half];
}

// Barely smaller than the split card, and it pulls onto that half while dragging.
- (CGRect)stickyHoverFrameFrom:(CGRect)frame {
    CGRect half = [self frameJustInsideHalf:[self primaryHalfSnappedForCardFrame:frame]];
    CGRect sized = frame;
    sized.size = half.size;
    CGPoint mid = CGPointMake(CGRectGetMidX(sized), CGRectGetMidY(sized));
    CGPoint halfMid = CGPointMake(CGRectGetMidX(half), CGRectGetMidY(half));
    CGFloat dist = hypot(mid.x - halfMid.x, mid.y - halfMid.y);
    CGFloat reach = 220.0;
    if (dist < reach) {
        CGFloat t = (reach - dist) / reach;
        t = t * t * 0.8;
        sized.origin.x += (half.origin.x - sized.origin.x) * t;
        sized.origin.y += (half.origin.y - sized.origin.y) * t;
    }
    return sized;
}

- (DSStageContainerView *)cardOnHalf:(NSInteger)half {
    if (_floatActive && _floatIsSplitCard && _floatContainer && _floatContainer != _frontCard &&
        !_floatContainer.hidden && _floatSplitHalf == half) {
        return _floatContainer;
    }
    if (_container && _container != _frontCard && !_container.hidden && [self halfForContainer:_container] == half) return _container;
    if (_topContainer && _topContainer != _frontCard && !_topContainer.hidden && [self halfForContainer:_topContainer] == half) return _topContainer;
    return nil;
}

- (BOOL)floatOverlapsCard:(DSStageContainerView *)card {
    if (!_floatActive || !_floatContainer || _floatContainer.hidden || card == _floatContainer) return NO;
    if (!card || card.hidden) return NO;
    CGRect mine = CGRectInset([self rootFrameOfCard:_floatContainer], 6.0, 6.0);
    CGRect theirs = [self rootFrameOfCard:card];
    return CGRectIntersectsRect(mine, theirs);
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
    [self resetStageGeometryAfterHostedApp];

    [self takeKeyWindowForStageChrome];
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
    _container.showsStackAddButton = NO;
    _container.showsMinimizeButton = NO;
    if (_topContainer) {
        _topContainer.showsStackAddButton = NO;
        _topContainer.showsMinimizeButton = NO;
        _topContainer.hostingApp = _topSceneHost.isHosting;
    }
    _container.hostingApp = _sceneHost.isHosting;
}

- (void)layoutHostedAppInSlot:(NSInteger)slot state:(DSStageState)state {
    DSSceneHost *host = [self sceneHostForSlot:slot];
    DSStageContainerView *card = [self containerForSlot:slot];
    if (!host.isHosting || !card) return;
    // The home swipe is still a scene transition. Resizing or moving this app
    // view in that window is the SIGTRAP. The card can show its still.
    if ([DSSceneHost homeGestureIsActive]) return;
    if ([self cardIsParked:card]) {
        host.matchCardFrame = NO;
        [self holdHostViewAtStageSize:host];
        return;
    }
    if (_stashHolder && host.hostView.superview == _stashHolder) {
        [self returnHostView:host toCard:card];
    }
    [host setStaysBackgrounded:NO];

    // Local card size at the card's own origin. A half card does not reach the
    // bottom of the display, so the keyboard stays SpringBoard's. The app,
    // Messages included, lays out into this size instead of the whole screen.
    BOOL live = [self cardMatchesItsFrame:card];
    host.matchCardFrame = YES;

    CGRect frame;
    // The corner pull grows a small tile. Resizing the scene to that tile is
    // what leaves the app black when it comes back, especially after a call.
    CGRect halfSize = [self fixedHalfFrame:[self halfForContainer:card]];
    // The top card grows while the bottom one is dragged. Putting the scene
    // back at the half height leaves the new area black. host in the log is
    // this view; it already follows the card. The scene has to as well.
    BOOL growingSplitTop = _splitMode && (_stageDragActive || _splitContentPrepared) &&
        card == [self cardOnHalf:1] &&
        CGRectGetHeight([self rootFrameOfCard:card]) > CGRectGetHeight(halfSize) + 8.0;
    if (growingSplitTop) {
        [card layoutIfNeeded];
        [self matchHostAndOutlineToCard:card];
        return;
    }
    if (card == _cornerRestoreCard) {
        frame = halfSize;
        live = NO;
    } else if (live) {
        frame = [self rootFrameOfCard:card];
    } else if (_stackSlotCount <= 1 && state == DSStageStateOverlay && card == _container) {
        frame = [self primaryCardFrameInRoot];
    } else {
        frame = halfSize;
    }
    if (CGRectGetWidth(halfSize) > 1.0 &&
        (fabs(CGRectGetWidth(frame) - CGRectGetWidth(halfSize)) > 8.0 ||
         fabs(CGRectGetHeight(frame) - CGRectGetHeight(halfSize)) > 8.0)) {
        frame.size = halfSize.size;
        live = NO;
    }
    if (CGRectIsEmpty(frame)) return;
    CGRect current = host.stageFrame;
    BOOL sameSize = fabs(CGRectGetWidth(current) - CGRectGetWidth(frame)) < 0.5 &&
                    fabs(CGRectGetHeight(current) - CGRectGetHeight(frame)) < 0.5;
    BOOL sameOrigin = fabs(CGRectGetMinX(current) - CGRectGetMinX(frame)) < 0.5 &&
                      fabs(CGRectGetMinY(current) - CGRectGetMinY(frame)) < 0.5;
    card.backgroundColor = UIColor.clearColor;
    [card layoutIfNeeded];
    if (sameSize && sameOrigin) {
        // The scene is already the right size on paper. The app view still
        // re-pins itself to the whole display, and a card that is not split
        // was leaving Messages laid out for that full screen. Fit the scene
        // back to the card. The rim stays the drag; this does not move it.
        [host fitHostViewToCard];
        [host refitPresentedScene];
        return;
    }
    if (sameSize) {
        // Same card, new half of the screen. Do not run the scene resize
        // transaction; that is what blanks the app.
        [self publishStageStateForBundleIdentifier:host.bundleIdentifier frame:frame active:YES];
        [host fitHostViewToCard];
        [host refitPresentedScene];
        return;
    }
    if ([DSSceneHost sceneSettingsUpdateDepth] > 0 || [DSSceneHost systemPullCallbackIsActive]) {
        [host fitHostViewToCard];
        return;
    }
    if (live) {
        [host applyCardFrameQuietly:frame];
    } else {
        [host setStageFrame:frame safeAreaInsets:UIEdgeInsetsZero];
    }

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

static UIBezierPath *DSBottomHalfRim(CGRect rect, CGFloat radius);
static UIBezierPath *DSTopHalfRim(CGRect rect, CGFloat radius);

// The same continuous corner the card uses. A circular stroke sat outside the
// fill, which is the bottom stage whose outline the card did not fit.
static void DSFitRimBorder(CAShapeLayer *layer, CGRect bounds, CGFloat band, CGFloat radius) {
    if (!layer) return;
    CGRect glow = CGRectInset(bounds, band - 1.0, band - 1.0);
    layer.path = nil;
    layer.frame = glow;
    layer.cornerRadius = MAX(radius, 1.0);
    layer.cornerCurve = kCACornerCurveContinuous;
    layer.borderWidth = 3.0;
    layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;
    layer.lineWidth = 0.0;
    layer.fillColor = UIColor.clearColor.CGColor;
    layer.masksToBounds = NO;
}

// Setting frame while a lift transform is in place flings the card off screen.
// Clear the transform, write the frame, then put the same lift back.
- (void)placeTopRimAroundCard:(DSStageContainerView *)card {
    if (!_topRim || card != _topContainer) return;
    // The rim has to stay behind the card. After the two cards trade places the
    // rim is left above the new one, and a touch anywhere on that card hits it.
    if (card.superview) [card.superview insertSubview:_topRim belowSubview:card];
    CGFloat band = kDSStageOuterDragBand + 18.0;
    // card.frame includes the keyboard slide. Writing that into the rim, then
    // translating the rim again, left the outline off the card after the slide
    // was cleared.
    CGRect cardFrame = [self frameWithoutKeyboardShift:card];
    CGAffineTransform shift = CGAffineTransformMakeTranslation(card.sideOffset, -card.liftOffset);
    _topRim.transform = CGAffineTransformIdentity;
    _topRim.frame = CGRectInset(cardFrame, -band, -band);
    _topRim.transform = shift;
    _topRim.hidden = card.hidden;
    CGRect glow = CGRectInset(_topRim.bounds, band - 1.0, band - 1.0);
    CGFloat radius = card.cornerRadius + 1.0;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    DSFitRimBorder(_topRimLayer, _topRim.bounds, band, radius);
    _topRimLayer.shadowPath = nil;
    UIBezierPath *half = nil;
    if (_topRimHalf == 1) half = DSBottomHalfRim(glow, radius);
    else if (_topRimHalf == 2) half = DSTopHalfRim(glow, radius);
    _topRimPulseLayer.frame = _topRim.bounds;
    _topRimPulseLayer.path = half.CGPath;
    [CATransaction commit];
}

- (void)setTopRimHalf:(NSInteger)half {
    if (_topRimHalf == half) return;
    _topRimHalf = half;
    if (!_topRimPulseLayer) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (half == 0) {
        [_topRimPulseLayer removeAnimationForKey:@"rimPulse"];
        _topRimPulseLayer.opacity = 0.0;
    } else {
        _topRimPulseLayer.opacity = 1.0;
        if (![_topRimPulseLayer animationForKey:@"rimPulse"]) {
            CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
            pulse.fromValue = @0.2;
            pulse.toValue = @1.0;
            pulse.duration = 0.55;
            pulse.autoreverses = YES;
            pulse.repeatCount = HUGE_VALF;
            [_topRimPulseLayer addAnimation:pulse forKey:@"rimPulse"];
        }
    }
    [CATransaction commit];
    if (_topContainer) [self placeTopRimAroundCard:_topContainer];
}

- (void)placeCard:(DSStageContainerView *)card atFrame:(CGRect)frame {
    if (!card) return;
    CGFloat keptLift = 0.0;
    BOOL keepLift = [self shouldKeepKeyboardLiftOnCard:card];
    BOOL splitKeys = _splitMode && !CGRectIsEmpty(_keyboardFrame) && CGRectGetHeight(_keyboardFrame) >= 150.0;
    if (splitKeys && fabs(card.liftOffset) > 0.5) keepLift = YES;
    else if (card == _frontCard && !splitKeys) keepLift = NO;
    if (keepLift) keptLift = card.liftOffset;
    if (fabs(card.liftOffset) > 0.5) {
        [UIView performWithoutAnimation:^{
            [card setLiftOffset:0.0];
        }];
    }
    if (card == _container) {
        [self setPrimaryCardFrameInRoot:frame];
    } else {
        [self assignFrame:frame toCard:card];
        [self placeTopRimAroundCard:card];
        if (card == _floatContainer) [self placeFloatRim];
    }
    if (keepLift && fabs(keptLift) > 0.5) {
        [UIView performWithoutAnimation:^{
            [card setLiftOffset:keptLift];
        }];
    }
    if (splitKeys && !_stageDragActive && !DSApplyingSplitKeyShift && [DSSceneHost sceneSettingsUpdateDepth] == 0) {
        [self applySplitKeyboardShiftForKeyboard:_keyboardFrame owner:[self containerForSlot:_keyboardLiftSlot]];
    }
    if (_splitMode || _floatActive) {
        // The log is taken below. Fit the app and the rim to this card first,
        // or the line shows the previous host size under a card that already grew.
        [card layoutIfNeeded];
        if (_splitMode) {
            [self matchHostAndOutlineToCard:card];
            [self keepSplitOutlinesOnTheirCards];
        }
        [self applyCombinedGeometryFix];
    }
    [self noteStageGeometry:@"place"];
}

// Host views live inside their cards. A screen frame would slide the app out
// of the card. topHost logs as {{0,0},{0,0}} when that view is not in the
// window yet; putting it in the card is what makes the log match topCard.
- (void)applyCombinedGeometryFix {
    if (_applyingGeometryFix) return;
    _applyingGeometryFix = YES;
    @try {
        if (_splitMode) {
            if (_container && !_container.hidden) [self matchHostAndOutlineToCard:_container];
            if (_topContainer && !_topContainer.hidden) [self matchHostAndOutlineToCard:_topContainer];
            if (!_stageDragActive) [self separateOverlappingSplitCards];
        }
        if (_floatActive && _floatContainer && !_floatContainer.hidden && !_stageDragActive) {
            [self clampFloatCardToScreen];
            if ([self frontStageCard] == _floatContainer) [self bringFloatAboveSplit];
        }
    } @catch (NSException *exception) {
        DSCrashLogRemember([NSString stringWithFormat:@"geometry fix threw %@", exception.reason ?: @"?"]);
    }
    _applyingGeometryFix = NO;
}

// The lower split card must start at the upper card's bottom. Overlap is the
// collapse. This does not run under a finger; that drag is what grows the top.
- (void)separateOverlappingSplitCards {
    if (!_splitMode || _stageDragActive || _splitCollapseClosing) return;
    if (!_container || _container.hidden || !_topContainer || _topContainer.hidden) return;
    CGRect primary = [self primaryCardFrameInRoot];
    CGRect second = _topContainer.frame;
    if (CGRectGetHeight(primary) < 80.0 || CGRectGetHeight(second) < 80.0) return;
    if (CGRectGetMidY(second) <= CGRectGetMidY(primary)) return;
    if (CGRectGetMinY(second) >= CGRectGetMaxY(primary) - 1.0) return;
    CGRect fixed = second;
    fixed.origin.y = CGRectGetMaxY(primary) + 2.0;
    CGRect screen = [self screenBounds];
    if (CGRectGetMaxY(fixed) > CGRectGetMaxY(screen)) {
        fixed.origin.y = CGRectGetMaxY(screen) - CGRectGetHeight(fixed);
    }
    if (fabs(CGRectGetMinY(fixed) - CGRectGetMinY(second)) < 1.0) return;
    DSLogAppend([NSString stringWithFormat:@"[GEOM-FIX] separated topCard %@ from card %@",
                 NSStringFromCGRect(fixed), NSStringFromCGRect(primary)]);
    [self placeCard:_topContainer atFrame:fixed];
}

// A visible third stage that has slipped off the screen leaves a black gap.
// It stays on the screen, in front of the split, under the notch.
- (void)clampFloatCardToScreen {
    if (!_floatContainer || _floatContainer.hidden || _stageDragActive) return;
    CGRect screen = [self screenBounds];
    CGRect frame = [self rootFrameOfCard:_floatContainer];
    if (CGRectGetWidth(frame) < 40.0 || CGRectGetHeight(frame) < 40.0) return;
    CGRect clamped = frame;
    if (CGRectGetMinX(clamped) < CGRectGetMinX(screen)) clamped.origin.x = CGRectGetMinX(screen);
    if (CGRectGetMinY(clamped) < CGRectGetMinY(screen)) clamped.origin.y = CGRectGetMinY(screen);
    if (CGRectGetMaxX(clamped) > CGRectGetMaxX(screen)) {
        clamped.origin.x = CGRectGetMaxX(screen) - CGRectGetWidth(clamped);
    }
    if (CGRectGetMaxY(clamped) > CGRectGetMaxY(screen)) {
        clamped.origin.y = CGRectGetMaxY(screen) - CGRectGetHeight(clamped);
    }
    if (fabs(CGRectGetMinX(clamped) - CGRectGetMinX(frame)) < 1.0 &&
        fabs(CGRectGetMinY(clamped) - CGRectGetMinY(frame)) < 1.0) {
        return;
    }
    DSLogAppend([NSString stringWithFormat:@"[GEOM-FIX] clamped floatCard %@ to screen",
                 NSStringFromCGRect(clamped)]);
    [self placeCard:_floatContainer atFrame:clamped];
    [self placeFloatRim];
    [self bringFloatAboveSplit];
}

// The app is drawn in the card. The outline is the rim around that card.
// A leftover lift leaves the rim near y=-968 while the card is still on
// screen, and the top split reads as an empty black rectangle.
- (void)keepSplitOutlinesOnTheirCards {
    CGFloat screenH = CGRectGetHeight([self screenBounds]);
    if (_dragShell && _container && !_container.hidden && fabs(_container.sideOffset) < 0.5) {
        [_dragShell refreshOutline];
        CGRect c = [_dragShell convertRect:_container.frame toView:nil];
        CGRect o = [_dragShell convertRect:[_dragShell outlineFrame] toView:nil];
        CGFloat lift = _container.liftOffset;
        o.origin.y -= lift;
        BOOL apart = fabs(CGRectGetMidX(o) - CGRectGetMidX(c)) > 8.0 ||
                     fabs(CGRectGetMidY(o) - CGRectGetMidY(c)) > 8.0;
        BOOL above = CGRectGetMinY(o) < 0.0;
        BOOL below = CGRectGetMaxY(o) > screenH;
        // The border is the card, one point outside it. A stale layer keeps
        // the old half height after the card has grown.
        BOOL sizeOff = fabs(CGRectGetWidth(o) - (CGRectGetWidth(c) + 2.0)) > 4.0 ||
                       fabs(CGRectGetHeight(o) - (CGRectGetHeight(c) + 2.0)) > 4.0;
        if (apart || above || below || sizeOff) {
            o.origin.x = CGRectGetMinX(c) - 1.0;
            o.origin.y = CGRectGetMinY(c) - 1.0;
            if (o.origin.y < 0.0) o.origin.y = 0.0;
            if (o.origin.y + o.size.height > screenH) {
                o.origin.y = screenH - o.size.height;
            }
            [_dragShell setOutlineLift:0.0];
            if (_stageDragActive && (above || apart) && fabs(lift) > 0.5) {
                [UIView performWithoutAnimation:^{
                    [self->_container setLiftOffset:0.0];
                }];
            } else if (fabs(o.origin.y - (CGRectGetMinY(c) - 1.0)) < 1.0) {
                [_dragShell setOutlineLift:lift];
            }
            [_dragShell refreshOutline];
            [self noteOutlineGlued:@"primary"];
        }
    }
    if (_topRim && _topContainer && !_topContainer.hidden && _topContainer.superview &&
        fabs(_topContainer.sideOffset) < 0.5) {
        [self placeTopRimAroundCard:_topContainer];
        CGRect c = [_topContainer.superview convertRect:_topContainer.frame toView:nil];
        CGRect o = [_topRim.superview convertRect:_topRim.frame toView:nil];
        CGFloat lift = _topContainer.liftOffset;
        o.origin.y -= lift;
        CGFloat band = kDSStageOuterDragBand + 18.0;
        BOOL apart = fabs(CGRectGetMidX(o) - CGRectGetMidX(c)) > 8.0 ||
                     fabs(CGRectGetMidY(o) - CGRectGetMidY(c)) > 8.0;
        BOOL above = CGRectGetMinY(o) < 0.0;
        BOOL below = CGRectGetMaxY(o) > screenH;
        BOOL sizeOff = fabs(CGRectGetWidth(o) - (CGRectGetWidth(c) + band * 2.0)) > 4.0 ||
                       fabs(CGRectGetHeight(o) - (CGRectGetHeight(c) + band * 2.0)) > 4.0;
        if (apart || above || below || sizeOff) {
            _topRim.transform = CGAffineTransformIdentity;
            if (_stageDragActive && (above || apart) && fabs(lift) > 0.5) {
                [UIView performWithoutAnimation:^{
                    [self->_topContainer setLiftOffset:0.0];
                }];
            } else {
                _topRim.transform = CGAffineTransformMakeTranslation(0.0, -lift);
            }
            [self placeTopRimAroundCard:_topContainer];
            [self noteOutlineGlued:@"second"];
        }
    }
    [self bringShelfToFront];
}

// One line, the five frames the split logs are compared against. card and
// outline are the primary card. topCard is the other split card.
- (NSString *)splitGeometryDebugLine {
    CGRect card = [self primaryCardFrameInRoot];
    CGRect outline = CGRectZero;
    if (_dragShell && _dragShell.superview) {
        outline = [_dragShell convertRect:[_dragShell outlineFrame] toView:nil];
    }
    CGRect shell = CGRectZero;
    if (_dragShell && _dragShell.superview) {
        shell = [_dragShell.superview convertRect:_dragShell.frame toView:nil];
    }
    UIView *hostView = _sceneHost.hostView;
    CGRect host = (hostView && hostView.window) ? [hostView convertRect:hostView.bounds toView:nil] : CGRectZero;
    CGRect topCard = (_topContainer && !_topContainer.hidden) ? _topContainer.frame : CGRectZero;
    UIView *topHostView = _topSceneHost.hostView;
    CGRect topHost = (topHostView && topHostView.window) ? [topHostView convertRect:topHostView.bounds toView:nil] : CGRectZero;
    CGRect front = (_frontCard && !_frontCard.hidden) ? [self rootFrameOfCard:_frontCard] : CGRectZero;
    CGRect floatCard = (_floatContainer && !_floatContainer.hidden) ? [self rootFrameOfCard:_floatContainer] : CGRectZero;
    CGFloat zFloat = _floatContainer ? _floatContainer.layer.zPosition : 0.0;
    return [NSString stringWithFormat:@"[GEOM-DBG] card=%@ outline=%@ shell=%@ host=%@ topHost=%@ topCard=%@ float=%@ front=%@ zFloat=%.0f",
            NSStringFromCGRect(card), NSStringFromCGRect(outline), NSStringFromCGRect(shell),
            NSStringFromCGRect(host), NSStringFromCGRect(topHost), NSStringFromCGRect(topCard),
            NSStringFromCGRect(floatCard), NSStringFromCGRect(front), zFloat];
}

// Screen frames after the fit. host and outline belong to the primary card.
- (NSString *)splitGeometryFixedLine {
    CGRect card = [self primaryCardFrameInRoot];
    CGRect outline = CGRectZero;
    if (_dragShell && _dragShell.superview) {
        outline = [_dragShell convertRect:[_dragShell outlineFrame] toView:nil];
    }
    UIView *hostView = _sceneHost.hostView;
    CGRect host = (hostView && hostView.window) ? [hostView convertRect:hostView.bounds toView:nil] : CGRectZero;
    return [NSString stringWithFormat:@"[FIXED] host=%@ outline=%@ card=%@",
            NSStringFromCGRect(host), NSStringFromCGRect(outline), NSStringFromCGRect(card)];
}

// card and host are the primary card. topHost is the other card's app.
// topApp says which of those two is actually on the top half.
- (NSString *)splitTopFixLine {
    CGRect card = [self primaryCardFrameInRoot];
    CGRect outline = CGRectZero;
    if (_dragShell && _dragShell.superview) {
        outline = [_dragShell convertRect:[_dragShell outlineFrame] toView:nil];
    }
    UIView *hostView = _sceneHost.hostView;
    CGRect host = (hostView && hostView.window) ? [hostView convertRect:hostView.bounds toView:nil] : CGRectZero;
    UIView *topHostView = _topSceneHost.hostView;
    CGRect topHost = (topHostView && topHostView.window) ? [topHostView convertRect:topHostView.bounds toView:nil] : CGRectZero;
    NSString *topApp = @"host";
    DSStageContainerView *visualTop = [self cardOnHalf:1];
    if (visualTop == _topContainer) topApp = @"topHost";
    else if (visualTop == _floatContainer) topApp = @"float";
    return [NSString stringWithFormat:@"[TOP-FIX] card=%@ topHost=%@ outline=%@ host=%@ topApp=%@",
            NSStringFromCGRect(card), NSStringFromCGRect(topHost), NSStringFromCGRect(outline),
            NSStringFromCGRect(host), topApp];
}

- (void)noteOutlineGlued:(NSString *)which {
    static NSTimeInterval last = 0;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - last < 0.35) return;
    last = now;
    DSLogAppend([NSString stringWithFormat:@"[GEOM-FIX] Outline glued + clamped (%@)", which ?: @"?"]);
}

- (void)layoutAllStackSlotsForState:(DSStageState)state {
    // A layout pass under the finger was snapping the card to a half and
    // leaving the drag stuck in the middle of the screen.
    if (!_stageDragActive) {
        if (_stackSlotCount <= 1) {
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
        }
        if (_floatActive && _floatIsSplitCard && _floatContainer && _floatContainer != _frontCard && !_floatContainer.hidden) {
            [self placeCard:_floatContainer atFrame:[self placedFrameForCard:_floatContainer state:state]];
            _floatContainer.cornerRadius = [self stageCardCornerRadius];
            [self placeFloatRim];
        }
    } else if (_stackSlotCount <= 1) {
        if (_topContainer) _topContainer.hidden = YES;
    }
    if (_stackSlotCount > 1) {
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
    [self syncParkedCardVisibility];

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

    BOOL keyboardVisible = _keyboardDrawnOutside || !CGRectIsEmpty(_keyboardFrame) ||
                             _hostedKeyboardRequestBundle.length > 0 || _stagedKeyboardSlot >= 0;
    [self applyHostedKeyboardChrome:keyboardVisible];
    _container.passThroughToHost = NO;
    if (_topContainer) {
        _topContainer.passThroughToHost = NO;
    }
    // Swapping the two cards exchanges the pan pointers but leaves each
    // recogniser on the view it was created on. The rim then belongs to the
    // wrong stage: one card cannot be dragged, and the other drags everywhere.
    [self seatStagePans];

    [self updateStackChrome];
    [self layoutHostedAppInSlot:0 state:state];
    [self layoutHostedAppInSlot:1 state:state];
    if (_floatActive && _floatSceneHost.isHosting) {
        [self layoutHostedAppInSlot:2 state:state];
    }
    [self bringFloatAboveSplit];
    [self bringShelfToFront];
    if (_stackSlotCount <= 1) [self hideTopStageOutline];
    [self reapplyBottomKeyboardLift];
    [self refreshSystemStatusBar];
}

- (void)presentPickerOnCard:(DSStageContainerView *)card picker:(DSAppPickerViewController *)picker {
    if (!card || !picker) return;
    [self refreshPickerAvailability];
    picker.darkMode = card.darkMode;
    UIView *pickerView = picker.view;
    for (UIView *subview in [card.contentView.subviews copy]) {
        if (subview == pickerView) continue;
        // Never pull a live app out of its card. That is what blanks it.
        if (subview == _sceneHost.hostView || subview == _topSceneHost.hostView || subview == _floatSceneHost.hostView) continue;
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
    // Cards stay on screen. Nothing slides below the display and waits there.
    (void)card;
    (void)animated;
}

- (CGRect)offscreenTopFrame {
    CGRect frame = [self fixedHalfFrame:1];
    frame.origin.y = -(CGRectGetHeight(frame) + kDSOffscreenCardGap);
    return frame;
}

// A minimized app stays in its corner and stays backgrounded. The new stage
// is the other card. Waking the minimized scene here safe-modes SpringBoard.
- (void)addStageBesideParkedCardAnimated:(BOOL)animated {
    [self ensureTopStackInfrastructure];
    if (_stackSlotCount >= kDSMaxStackSlots && _topSceneHost.isHosting) return;
    _presentGeneration += 1;
    NSInteger generation = _presentGeneration;
    _searchSlot = -1;
    [_picker dismissKeyboard];
    if (_topPicker) [_topPicker dismissKeyboard];
    _stackSlotCount = kDSMaxStackSlots;
    _primaryParked = _sceneHost.isHosting ? YES : _primaryParked;
    _secondParked = NO;
    _secondHalf = 1;
    _state = DSStageStateOverlay;
    _window.hidden = NO;
    [self cancelAutoKill];
    [_sceneHost setStaysBackgrounded:YES];
    [_sceneHost setForeground:NO];
    [self placeCard:_topContainer atFrame:[self offscreenTopFrame]];
    _topContainer.alpha = 1.0;
    _topContainer.hidden = NO;
    _topRim.hidden = NO;
    _topRim.alpha = 1.0;
    [self presentPickerOnCard:_topContainer picker:_topPicker];
    [_topPicker resetScrollPosition];
    void (^layout)(void) = ^{
        [self layoutAllStackSlotsForState:DSStageStateOverlay];
        self->_topContainer.alpha = 1.0;
    };
    void (^finish)(void) = ^{
        if (generation != self->_presentGeneration) return;
        [self hideParkedCardsCompletely];
        [self updateStackChrome];
        [self refreshShelf];
        [self bringShelfToFront];
        [self settlePickerKeyboard];
        [self updateOpenAppIcon];
    };
    if (animated) [self animateSpring:layout completion:finish];
    else { layout(); finish(); }
}

- (void)addSecondStageAnimated:(BOOL)animated {
    NSInteger otherHalf = _primaryHalf == 0 ? 1 : 0;
    [self addSecondStageOnHalf:otherHalf animated:animated];
}

- (void)addSecondStageOnHalf:(NSInteger)half animated:(BOOL)animated {
    [self ensureTopStackInfrastructure];
    half = half == 0 ? 0 : 1;
    if (_stackSlotCount >= kDSMaxStackSlots) {
        DSDiagnosticsRecord(@"SpringBoard: two stages are already open");
        [self bringTopStackAbovePrimaryShell];
        _topContainer.hidden = NO;
        _topContainer.alpha = 1.0;
        if (_topRim) {
            _topRim.hidden = NO;
            _topRim.alpha = 1.0;
        }
        [self layoutAllStackSlotsForState:DSStageStateOverlay];
        return;
    }
    if (_state == DSStageStateClosed) {
        NSString *refusal = [self reasonStageCannotActivate];
        if (refusal) return;
    }

    _presentGeneration += 1;
    NSInteger generation = _presentGeneration;
    _searchSlot = -1;
    [_picker dismissKeyboard];
    if (_topPicker) [_topPicker dismissKeyboard];

    _stackSlotCount = kDSMaxStackSlots;
    // The stage already on screen is pushed down. The new one takes the top.
    (void)half;
    _primaryHalf = 0;
    _secondHalf = 1;
    _primaryParked = NO;
    _secondParked = NO;
    [_container setLiftOffset:0.0];
    [_topContainer setLiftOffset:0.0];

    [self bringTopStackAbovePrimaryShell];
    _topContainer.alpha = 1.0;
    _topContainer.hidden = NO;
    if (_topRim) {
        _topRim.hidden = NO;
        _topRim.alpha = 1.0;
    }
    [self presentPickerOnCard:_topContainer picker:_topPicker];
    [_topPicker resetScrollPosition];

    if (_state != DSStageStateOverlay) {
        _state = DSStageStateOverlay;
        _window.hidden = NO;
        [self cancelAutoKill];
        [self takeKeyWindowForStageChrome];
    }

    CGRect topRest = [self fixedHalfFrame:1];
    [UIView performWithoutAnimation:^{
        [self placeCard:self->_topContainer atFrame:topRest];
    }];

    void (^layout)(void) = ^{
        [self layoutAllStackSlotsForState:DSStageStateOverlay];
        self->_container.alpha = 1.0;
        self->_topContainer.alpha = 1.0;
    };
    void (^finish)(void) = ^{
        if (generation != self->_presentGeneration) return;
        [self bringTopStackAbovePrimaryShell];
        [self updateStackChrome];
        [self refreshShelf];
        [self bringShelfToFront];
        [self settlePickerKeyboard];
    };
    if (animated) {
        [self animateSpring:layout completion:finish];
    } else {
        layout();
        finish();
    }
    DSDiagnosticsRecord(@"SpringBoard: opened another stage");
}

- (void)dropEmptySecondCard {
    _stackSlotCount = 1;
    _secondParked = NO;
    _topContainer.hidden = YES;
    _topContainer.alpha = 0.0;
    [self hideTopStageOutline];
    [UIView animateWithDuration:0.28 animations:^{
        [self layoutAllStackSlotsForState:self->_state];
    } completion:^(BOOL finished) {
        [self hideTopStageOutline];
        [self refitLiveStageHosts];
        [self scheduleLiveStageRefit];
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
    _topContainer.alpha = 0.0;
    _container.hidden = NO;
    _container.alpha = 1.0;
    [self hideTopStageOutline];
    if (_dragShell) {
        if (_topContainer.superview == _dragShell) [_topContainer removeFromSuperview];
        if (_container.superview != _dragShell) {
            [_container removeFromSuperview];
            [_dragShell addSubview:_container];
        }
        _dragShell.cardView = _container;
        _dragShell.hidden = NO;
        _dragShell.alpha = 1.0;
    }
    [UIView animateWithDuration:0.28 animations:^{
        [self layoutAllStackSlotsForState:self->_state];
    } completion:^(BOOL finished) {
        [self refitLiveStageHosts];
        [self scheduleLiveStageRefit];
    }];
    [self seatStagePans];
    [self refreshShelf];
}

- (void)addStackSlotAnimated {
    // Dual stack removed. The + control is hidden; this is a no-op if something
    // still calls it.
}

- (void)collapseToSingleTopStage {
    _splitMode = NO;
    _splitHomeRevealed = NO;
    _expandedCard = nil;
    [self dismissFloatStageAnimated:NO terminate:NO];
    if (_topSceneHost.isHosting) {
        [self relinquishStackHost:_topSceneHost];
        _topSceneHost = nil;
    }
    if (_topContainer) {
        [_topContainer setLiftOffset:0.0];
        [_topContainer setSideOffset:0.0];
        _topContainer.hidden = YES;
        _topContainer.keyboardBandHeight = 0.0;
    }
    if (_topPicker) [_topPicker dismissKeyboard];
    _stackSlotCount = 1;
    _primaryHalf = 1;
    _secondHalf = 0;
    _primaryParked = NO;
    _secondParked = NO;
    [_container setLiftOffset:0.0];
    [_container setSideOffset:0.0];
    _container.keyboardBandHeight = 0.0;
    [self clearKeyboardSideShift];
    [self clearHostedKeyboardBands];
    [self parkStashedHostsOntoCards];
    [self updateOpenAppIcon];
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
    _primaryHalf = 1;
    _secondHalf = 1;
    _primaryParked = NO;
    _secondParked = NO;
    _topContainer.hidden = YES;
    [self clearKeyboardSideShift];

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
    return _state == DSStageStateOverlay || _state == DSStageStateTracking;
}

- (BOOL)isSplitMode {
    return _splitMode;
}

- (BOOL)shouldHideSystemHomeAffordance {
    // Only while a live app owns the stage: with the picker up the recordings
    // still show the system home bar.
    return self.hasHostedApp && _state == DSStageStateOverlay;
}

- (BOOL)stageOccupiesTop {
    if (_state != DSStageStateOverlay && _state != DSStageStateTracking) return NO;
    CGFloat nearTop = CGRectGetMinY([self fixedHalfFrame:1]) + 80.0;
    BOOL (^cardIsUp)(DSStageContainerView *) = ^BOOL(DSStageContainerView *card) {
        if (!card || card.hidden || card.alpha < 0.05 || [self cardIsParked:card]) return NO;
        CGRect frame = [self rootFrameOfCard:card];
        frame.origin.y -= card.liftOffset;
        if (CGRectGetHeight(frame) < 80.0) return NO;
        return CGRectGetMinY(frame) < nearTop;
    };
    if (cardIsUp(_container)) return YES;
    if (cardIsUp(_topContainer)) return YES;
    if (_floatActive && cardIsUp(_floatContainer)) return YES;
    return NO;
}

- (BOOL)shouldHideSystemStatusBar {
    return [self stageOccupiesTop] && !_statusBarPeeking;
}

- (void)handleStatusBarPeekTap:(UITapGestureRecognizer *)tap {
    if (tap.state != UIGestureRecognizerStateEnded) return;
    if (![self shouldHideSystemStatusBar]) return;
    CGPoint point = [tap locationInView:nil];
    if (point.y > 32.0) return;
    [self peekSystemStatusBar];
}

- (void)refreshSystemStatusBar {
    if ([DSSceneHost sceneSettingsUpdateDepth] > 0) return;
    if (![self stageOccupiesTop]) _statusBarPeeking = NO;
    BOOL hide = [self shouldHideSystemStatusBar];
    if (_statusBarHideAppliedReady && hide == _statusBarHideApplied) return;
    _statusBarHideApplied = hide;
    _statusBarHideAppliedReady = YES;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"DSStageStatusBarRefresh" object:nil];
}

- (void)peekSystemStatusBar {
    if (![self stageOccupiesTop]) return;
    _statusBarPeeking = YES;
    _statusBarPeekToken += 1;
    NSInteger token = _statusBarPeekToken;
    _statusBarHideAppliedReady = NO;
    [self refreshSystemStatusBar];
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        DSStageManager *manager = weakSelf;
        if (!manager || token != manager->_statusBarPeekToken) return;
        manager->_statusBarPeeking = NO;
        manager->_statusBarHideAppliedReady = NO;
        [manager refreshSystemStatusBar];
    });
}

#pragma mark - Animation

- (void)animateSpring:(void (^)(void))animations completion:(void (^)(void))completion {
    if (!animations) {
        if (completion) completion();
        return;
    }
    UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:0.26 curve:UIViewAnimationCurveEaseOut animations:animations];
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

- (BOOL)pointIsPhoneRightCorner:(CGPoint)point {
    CGRect screen = [self screenBounds];
    return point.x > CGRectGetWidth(screen) - 44.0 &&
           point.y > CGRectGetHeight(screen) - 80.0;
}

- (BOOL)pointIsHomeBar:(CGPoint)point {
    CGRect screen = [self screenBounds];
    if (point.y < CGRectGetHeight(screen) - 28.0) return NO;
    return point.x > 56.0 && point.x < CGRectGetWidth(screen) - 56.0;
}

- (BOOL)pointIsTerminateBand:(CGPoint)point {
    CGRect screen = [self screenBounds];
    if (point.y < CGRectGetHeight(screen) - 90.0) return NO;
    return fabs(point.x - CGRectGetWidth(screen) * 0.5) <= CGRectGetWidth(screen) * 0.22;
}

- (BOOL)shouldSuppressSystemGestureAtPoint:(CGPoint)point {
    // A left swipe from the phone's right corner is not a stage gesture and not
    // a system one either. Letting it through is what blanks the stage.
    if (_stageDragActive && [self pointIsTerminateBand:point]) return YES;
    if (self.isStageVisible && [self pointIsHomeBar:point]) return NO;
    return [self shouldSuppressSystemGestureAtPoint:point velocity:CGPointZero];
}

- (BOOL)shouldSuppressSystemGestureAtPoint:(CGPoint)point velocity:(CGPoint)velocity {
    if (_stageDragActive && [self pointIsTerminateBand:point]) return YES;
    if (self.isStageVisible && [self pointIsHomeBar:point]) return NO;
    (void)velocity;
    if (self.isStageVisible && [self pointIsPhoneRightCorner:point]) return YES;
    // Only ever the card itself, where a swipe up belongs to the stage rather than
    // to the home gesture. The corner is deliberately left alone: the pull that
    // opens the stage is taken over from the system's own edge gesture, so that
    // gesture has to be allowed to begin. The app sharing the screen keeps its
    // gestures, and a stage left open in some state it should not be in cannot
    // take the home gesture away from the whole device - the card has to actually
    // be on screen and the touch has to be inside it.
    if (!self.isStageVisible || !_container.window) return NO;
    CGRect card = [self visualScreenFrameForCard:_container];
    if (CGRectContainsPoint(card, point)) return YES;
    if (_stackSlotCount >= kDSMaxStackSlots && _topContainer && !_topContainer.hidden) {
        if (CGRectContainsPoint([self visualScreenFrameForCard:_topContainer], point)) return YES;
    }
    if (_floatActive && _floatContainer && !_floatContainer.hidden) {
        if (CGRectContainsPoint([self visualScreenFrameForCard:_floatContainer], point)) return YES;
    }
    return NO;
}

// A finger moving left along the bottom edge is not a stage gesture.
- (BOOL)gestureMovesLeftAlongTheBottom:(CGPoint)translation velocity:(CGPoint)velocity {
    // A diagonal that also moves up is the corner restore. Only a flat swipe
    // along the bottom is ignored.
    BOOL upward = translation.y < -16.0 || velocity.y < -80.0;
    if (upward) return NO;
    BOOL left = translation.x < -36.0 || velocity.x < -220.0;
    BOOL flat = fabs(translation.y) < 18.0 && fabs(velocity.y) < 120.0;
    return left && flat;
}

- (BOOL)shouldWindowCaptureTouchAtPoint:(CGPoint)point {
    // The notch (and its list, while open) is tappable with the stage closed.
    if ([_shelf claimsPoint:point]) return YES;
    if (_state == DSStageStateClosed || _state == DSStageStateMinimized) return NO;
    // The home bar stays the system's. Capturing it is what blanks the card.
    if ([self pointIsHomeBar:point]) return NO;

    // Eat the phone's right corner so a left swipe there never reaches a card
    // or the system gesture that blanks the hosted app.
    if (self.isStageVisible && [self pointIsPhoneRightCorner:point]) return YES;

    // The rim is wider than the drawn line so a grab on the edge of a stage
    // that is floating over another app hits the stage, not the app behind it.
    if (_dragShell && !_dragShell.hidden) {
        CGRect shell = CGRectInset([self visualScreenFrameForCard:_container], -(kDSStageOuterDragBand + 18.0), -(kDSStageOuterDragBand + 18.0));
        if (CGRectContainsPoint(CGRectInset(shell, -8.0, -8.0), point)) return YES;
    }
    if (_topRim && !_topRim.hidden) {
        CGRect rimFrame = CGRectInset([self visualScreenFrameForCard:_topContainer], -(kDSStageOuterDragBand + 18.0), -(kDSStageOuterDragBand + 18.0));
        if (CGRectContainsPoint(rimFrame, point)) return YES;
    }

    CGRect card = [self visualScreenFrameForCard:_container];
    if (CGRectContainsPoint(card, point)) {
        if (_container.keyboardBandHeight > 1.0 &&
            point.y >= CGRectGetMaxY(card) - _container.keyboardBandHeight) {
            return NO;
        }
        return YES;
    }
    if (_stackSlotCount >= kDSMaxStackSlots && _topContainer && !_topContainer.hidden) {
        CGRect top = [self visualScreenFrameForCard:_topContainer];
        if (CGRectContainsPoint(top, point)) {
            if (_topContainer.keyboardBandHeight > 1.0 &&
                point.y >= CGRectGetMaxY(top) - _topContainer.keyboardBandHeight) {
                return NO;
            }
            return YES;
        }
    }
    if (_floatActive && _floatRim && !_floatRim.hidden && CGRectContainsPoint(_floatRim.frame, point)) return YES;
    if (_floatActive && _floatContainer && !_floatContainer.hidden) {
        CGRect hovering = [self visualScreenFrameForCard:_floatContainer];
        if (CGRectContainsPoint(hovering, point)) return YES;
    }

    return NO;
}

#pragma mark - Corner pull

- (DSStageContainerView *)parkedCardForCornerPoint:(CGPoint)point {
    if ([self pointIsHomeBar:point]) return nil;
    CGRect screen = [self screenBounds];
    if (point.y < CGRectGetHeight(screen) - 108.0) return nil;
    BOOL left = point.x < 86.0;
    BOOL right = point.x > CGRectGetWidth(screen) - 86.0;
    if (!left && !right) return nil;
    if (left) {
        if (_primaryParked && _primaryMinimizedLeft) return _container;
        if (_secondParked && _secondMinimizedLeft) return _topContainer;
    } else {
        if (_primaryParked && !_primaryMinimizedLeft) return _container;
        if (_secondParked && !_secondMinimizedLeft) return _topContainer;
    }
    return nil;
}

- (BOOL)gestureControllerShouldBegin:(DSGestureController *)controller atPoint:(CGPoint)point {
    (void)controller;
    if (_systemPull || _state == DSStageStateTracking) return NO;
    _cornerRestoreCard = [self parkedCardForCornerPoint:point];
    return _cornerRestoreCard != nil;
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
    CGPoint start = [gesture locationInView:nil];
    CGPoint velocity = [gesture velocityInView:nil];
    CGPoint translation = [gesture translationInView:nil];
    if ([self gestureMovesLeftAlongTheBottom:translation velocity:velocity]) return NO;
    DSStageContainerView *card = [self parkedCardForCornerPoint:start];
    if (!card) return NO;
    _cornerRestoreCard = card;
    _cornerExitCard = nil;

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

    // UIKit calls this one directly, from inside SpringBoard's gesture.
    // A scene transaction or a display-mode change on this stack is the
    // SIGTRAP. Hold those writes until this call has returned.
    [DSSceneHost beginSystemPullCallback];
    @try {
        CGPoint translation = [gesture translationInView:nil];
        switch (gesture.state) {
            case UIGestureRecognizerStateChanged:
                if ([self gestureMovesLeftAlongTheBottom:translation velocity:[gesture velocityInView:nil]]) {
                    [self releaseSystemPull];
                    [self cancelTracking];
                    break;
                }
                [self gestureController:nil didUpdateTranslation:translation];
                break;
            case UIGestureRecognizerStateEnded: {
                CGPoint velocity = [gesture velocityInView:nil];
                [self releaseSystemPull];
                if ([self gestureMovesLeftAlongTheBottom:translation velocity:velocity]) {
                    [self cancelTracking];
                } else {
                    [self gestureController:nil didEndWithTranslation:translation velocity:velocity];
                }
                break;
            }
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
    } @finally {
        [DSSceneHost endSystemPullCallback];
    }
}

- (void)releaseSystemPull {
    [_systemPull removeTarget:self action:@selector(handleSystemPull:)];
    _systemPull = nil;
}

- (void)gestureControllerDidBegin:(DSGestureController *)controller {
    (void)controller;
    _stateBeforeTracking = _state;
    _trackingProgress = 0.0;
    // A minimized app in the corner can be pulled out even while the other
    // stage is already on screen. That pull has to win over the open card.
    if (_cornerRestoreCard && [self cardIsParked:_cornerRestoreCard]) {
        _state = DSStageStateTracking;
        return;
    }
    if (_state != DSStageStateMinimized) return;
    _state = DSStageStateTracking;
}

- (BOOL)gestureIsDiagonalInwardFromLeft:(BOOL)fromLeft translation:(CGPoint)translation velocity:(CGPoint)velocity {
    BOOL upward = translation.y < -6.0 || velocity.y < -40.0;
    BOOL inward = fromLeft ? (translation.x > 4.0 || velocity.x > 28.0)
                           : (translation.x < -4.0 || velocity.x < -28.0);
    return upward && inward;
}

- (BOOL)gestureIsDiagonalCornerRestore:(CGPoint)translation velocity:(CGPoint)velocity {
    BOOL fromLeft = _cornerRestoreCard ? [self cardMinimizedOnLeft:_cornerRestoreCard] : _primaryMinimizedLeft;
    return [self gestureIsDiagonalInwardFromLeft:fromLeft translation:translation velocity:velocity];
}

- (BOOL)touch:(CGPoint)local isBottomCornerOfCard:(DSStageContainerView *)card fromLeft:(BOOL *)fromLeft {
    CGFloat width = CGRectGetWidth(card.bounds);
    CGFloat height = CGRectGetHeight(card.bounds);
    if (width < 40.0 || height < 40.0) return NO;
    if (local.y < height - 120.0) return NO;
    CGFloat reach = MIN(160.0, width * 0.46);
    if (local.x <= reach) {
        if (fromLeft) *fromLeft = YES;
        return YES;
    }
    if (local.x >= width - reach) {
        if (fromLeft) *fromLeft = NO;
        return YES;
    }
    return NO;
}

- (CGRect)dragTileFrameAtPoint:(CGPoint)point {
    CGFloat width = 112.0;
    CGFloat height = 84.0;
    return CGRectMake(point.x - width * 0.5, point.y - height * 0.5, width, height);
}

- (void)setPullBlur:(CGFloat)amount onCard:(DSStageContainerView *)card {
    if (!card) return;
    static const NSInteger kDSPullBlurTag = 9152;
    amount = MIN(MAX(amount, 0.0), 1.0);
    UIView *existing = [card viewWithTag:kDSPullBlurTag];
    if (amount < 0.02) {
        [existing removeFromSuperview];
        return;
    }
    UIVisualEffectView *blur = [existing isKindOfClass:UIVisualEffectView.class] ? (UIVisualEffectView *)existing : nil;
    if (!blur) {
        [existing removeFromSuperview];
        blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
        blur.tag = kDSPullBlurTag;
        blur.userInteractionEnabled = NO;
        blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [card addSubview:blur];
    }
    blur.frame = card.bounds;
    blur.alpha = amount;
    [card bringSubviewToFront:blur];
}

- (void)presentDragTileForCard:(DSStageContainerView *)card frame:(CGRect)frame blur:(CGFloat)blur {
    if (!card) return;
    BOOL hosting = card.hostingApp;
    card.hidden = NO;
    card.alpha = 1.0;
    card.contentView.alpha = 1.0;
    card.cornerRadius = 18.0 + (MAX([self stageCardCornerRadius] - 18.0, 0.0) * MIN(MAX(CGRectGetWidth(frame) / 280.0, 0.0), 1.0));
    if (hosting) {
        card.backgroundColor = UIColor.clearColor;
        [card setBackdropHidden:YES];
    } else {
        card.backgroundColor = [UIColor colorWithWhite:0.11 alpha:1.0];
        [card setBackdropHidden:NO];
        DSAppPickerViewController *picker = (card == _topContainer) ? _topPicker : _picker;
        if (picker) {
            picker.view.hidden = NO;
            picker.view.alpha = 1.0;
            picker.view.frame = card.contentView.bounds;
        }
    }
    if (card == _container) {
        _dragShell.hidden = NO;
        _dragShell.alpha = 1.0;
    } else if (_topRim) {
        _topRim.hidden = NO;
        _topRim.alpha = 1.0;
    }
    [self placeCard:card atFrame:frame];
    if (!hosting && card.contentView) {
        DSAppPickerViewController *picker = (card == _topContainer) ? _topPicker : _picker;
        picker.view.frame = card.contentView.bounds;
    }
    [self setPullBlur:blur onCard:card];
    UIImageView *icon = (card == _topContainer) ? _secondOpenAppIcon : _openAppIcon;
    icon.alpha = 0.0;
}

- (void)clearDragTileOnCard:(DSStageContainerView *)card {
    if (!card) return;
    [self setPullBlur:0.0 onCard:card];
    card.contentView.alpha = 1.0;
    BOOL hosting = card.hostingApp;
    card.backgroundColor = hosting ? UIColor.clearColor : [UIColor colorWithWhite:0.11 alpha:1.0];
    [card setBackdropHidden:hosting];
    card.cornerRadius = [self cornerRadiusForState:DSStageStateOverlay];
}

- (void)followMinimizedRestore:(DSStageContainerView *)card translation:(CGPoint)translation {
    (void)translation;
    if (!card || !_systemPull) return;
    CGPoint finger = [_systemPull locationInView:nil];
    _restoreFinger = finger;
    BOOL left = [self cardMinimizedOnLeft:card];
    CGRect cornerIcon = [self openAppIconFrameOnLeft:left lift:0.0];
    CGPoint corner = CGPointMake(CGRectGetMidX(cornerIcon), CGRectGetMidY(cornerIcon));
    CGFloat pulled = MIN(hypot(finger.x - corner.x, finger.y - corner.y) / 200.0, 1.0);
    NSInteger half = [self primaryHalfSnappedForCardFrame:CGRectMake(finger.x, finger.y, 1.0, 1.0)];
    CGRect target = [self fixedHalfFrame:half == 0 ? 0 : 1];
    CGFloat width = 112.0 + (CGRectGetWidth(target) - 112.0) * pulled;
    CGFloat height = 84.0 + (CGRectGetHeight(target) - 84.0) * pulled;
    CGRect frame = CGRectMake(finger.x - width * 0.5, finger.y - height * 0.5, width, height);
    [self presentDragTileForCard:card frame:frame blur:(1.0 - pulled)];
    [self updateDragGhostForFrame:CGRectZero red:NO visible:NO];
    // The picture moves with the finger. Waking the app here is a display-mode
    // change inside SpringBoard's gesture callback, which is the SIGTRAP.
    _restoreWoke = YES;
    [self showRememberedPictureOnCard:card];
}

- (void)gestureController:(DSGestureController *)controller didUpdateTranslation:(CGPoint)translation {
    (void)controller;
    BOOL pullingMinimized = _cornerRestoreCard && [self cardIsParked:_cornerRestoreCard];
    if (!pullingMinimized && _stateBeforeTracking != DSStageStateMinimized) return;
    if (!_cornerRestoreCard) return;
    CGPoint velocity = _systemPull ? [_systemPull velocityInView:nil] : CGPointZero;
    if (![self gestureIsDiagonalCornerRestore:translation velocity:velocity]) return;
    [self followMinimizedRestore:_cornerRestoreCard translation:translation];
}

- (void)finishCornerRestoreOfCard:(DSStageContainerView *)card {
    if ([DSSceneHost homeGestureIsActive] || [DSSceneHost systemPullCallbackIsActive] ||
        [DSSceneHost sceneSettingsUpdateDepth] > 0) {
        __weak __typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf finishCornerRestoreOfCard:card];
        });
        return;
    }
    [self discardRememberedPictureForCard:card];
    if (_state == DSStageStateOverlay) {
        if (self.hasHostedApp) [self giveBackKeyWindow];
        [self setForegroundForAllHostedApps:YES];
        [self layoutAllStackSlotsForState:DSStageStateOverlay];
        [self hideParkedCardsCompletely];
        [self bringCardAboveItsPartner:card];
        DSSceneHost *host = [self sceneHostForCard:card];
        if (host.isHosting) {
            CGRect half = [self fixedHalfFrame:[self halfForContainer:card]];
            [host setStaysBackgrounded:NO];
            [host setForeground:YES];
            [host setStageFrame:half safeAreaInsets:UIEdgeInsetsZero];
            [host fitHostViewToCard];
            [host refitPresentedScene];
            [host wakeIfBackgrounded];
        }
        [self updateOpenAppIcon];
    }
}

// One stage is minimized. The one still on screen can sit on either half.
- (BOOL)onScreenCardCanTakeEitherHalf:(DSStageContainerView *)card {
    if (_splitMode || _floatActive) return NO;
    if (_stackSlotCount < kDSMaxStackSlots) return NO;
    if (card != _container && card != _topContainer) return NO;
    DSStageContainerView *other = (card == _container) ? _topContainer : _container;
    return other && [self cardIsParked:other];
}

- (void)seatCard:(DSStageContainerView *)card onHalf:(NSInteger)half leavingTheOtherHalfFree:(BOOL)leaveFree {
    half = half == 0 ? 0 : 1;
    if (card == _topContainer) _secondHalf = half;
    else if (card == _container) {
        _primaryHalf = half;
        _minimizedHalf = half;
    }
    if (!leaveFree) return;
    DSStageContainerView *other = (card == _container) ? _topContainer : _container;
    if (!other || ![self cardIsParked:other]) return;
    NSInteger free = half == 0 ? 1 : 0;
    if (other == _container) {
        _primaryHalf = free;
        _minimizedHalf = free;
    } else {
        _secondHalf = free;
    }
}

// The stage already on screen keeps its half. The one coming back takes the
// half that is empty. A pull toward the occupied half does not push that one aside.
- (NSInteger)halfForRestoringCard:(DSStageContainerView *)card fingerHalf:(NSInteger)fingerHalf {
    if (_stackSlotCount < kDSMaxStackSlots || !card) return fingerHalf;
    DSStageContainerView *other = (card == _container) ? _topContainer : _container;
    if (!other || other.hidden || [self cardIsParked:other]) return fingerHalf;
    NSInteger used = [self halfForContainer:other];
    return used == 0 ? 1 : 0;
}

- (void)restoreMinimizedStageAnimated:(BOOL)animated {
    DSStageContainerView *card = _cornerRestoreCard ?: _container;
    _cornerRestoreCard = nil;
    NSInteger fingerHalf = [self primaryHalfSnappedForCardFrame:CGRectMake(_restoreFinger.x, _restoreFinger.y, 1.0, 1.0)];
    NSInteger half = [self halfForRestoringCard:card fingerHalf:fingerHalf];
    if (card == _topContainer) _secondHalf = half;
    else {
        _minimizedHalf = half;
        _primaryHalf = half;
    }
    [self clearDragTileOnCard:card];
    [self updateDragGhostForFrame:CGRectZero red:NO visible:NO];
    DSStageContainerView *other = nil;
    if (_stackSlotCount >= kDSMaxStackSlots) {
        DSStageContainerView *partner = (card == _container) ? _topContainer : _container;
        if (partner && [self cardIsParked:partner]) other = partner;
    }
    [self setParked:NO forCard:card];
    [self bringCardAboveItsPartner:card];
    DSSceneHost *host = (card == _topContainer) ? _topSceneHost : _sceneHost;
    [host setForeground:YES];
    if (other) {
        DSSceneHost *otherHost = [self sceneHostForCard:other];
        [otherHost setStaysBackgrounded:YES];
        [otherHost setForeground:NO];
        DSDiagnosticsRecordFormat(@"SpringBoard: restored the %@ stage, the other stays minimised",
                                  [self cardMinimizedOnLeft:card] ? @"left" : @"right");
    }
    if (_state == DSStageStateTracking) _state = DSStageStateOverlay;
    DSStageContainerView *revealed = card;
    void (^reveal)(void) = ^{
        [self finishCornerRestoreOfCard:revealed];
        [self bringCardAboveItsPartner:revealed];
    };
    if (_state != DSStageStateOverlay) {
        [self enterStateOverlayAnimated:animated keepingParkedCard:other];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), reveal);
        return;
    }
    void (^layout)(void) = ^{
        [self layoutAllStackSlotsForState:DSStageStateOverlay];
        [self hideParkedCardsCompletely];
        [self bringCardAboveItsPartner:revealed];
    };
    if (animated) [self animateSpring:layout completion:reveal];
    else { layout(); reveal(); }
}

- (void)gestureController:(DSGestureController *)controller didEndWithTranslation:(CGPoint)translation velocity:(CGPoint)velocity {
    (void)controller;
    BOOL pullingMinimized = _cornerRestoreCard && (_stateBeforeTracking == DSStageStateMinimized ||
                                                   _stateBeforeTracking == DSStageStateOverlay ||
                                                   _stateBeforeTracking == DSStageStateTracking);
    if (!pullingMinimized) {
        [self cancelTracking];
        return;
    }
    if ([self gestureIsDiagonalCornerRestore:translation velocity:velocity]) {
        [self restoreMinimizedStageAnimated:YES];
        return;
    }
    [self cancelTracking];
}

- (void)gestureControllerDidCancel:(DSGestureController *)controller {
    [self cancelTracking];
}

- (void)cancelTracking {
    if (_restoreWoke) {
        _restoreWoke = NO;
        DSStageContainerView *card = _cornerRestoreCard ?: _container;
        DSSceneHost *host = (card == _topContainer) ? _topSceneHost : _sceneHost;
        [host setStaysBackgrounded:YES];
        [host setForeground:NO];
        UIView *picture = (card == _topContainer) ? _secondParkPicture : _primaryParkPicture;
        [picture removeFromSuperview];
    }
    if (_cornerRestoreCard) [self clearDragTileOnCard:_cornerRestoreCard];
    [self updateDragGhostForFrame:CGRectZero red:NO visible:NO];
    DSStageState previous = _stateBeforeTracking;
    [self animateSpring:^{
        [self animateHostSnapshotToFullScreen];
        if (self->_primaryParked) {
            [self placeCard:self->_container atFrame:[self cornerParkFrameForCard:self->_container]];
        }
        if (self->_secondParked && self->_topContainer) {
            [self placeCard:self->_topContainer atFrame:[self cornerParkFrameForCard:self->_topContainer]];
        }
        self->_container.cornerRadius = [self cornerRadiusForState:DSStageStateOverlay];
    } completion:^{
        [self discardHostSnapshotAnimated:YES];
        self->_cornerRestoreCard = nil;
        if (previous == DSStageStateOverlay || previous == DSStageStateTracking) {
            self->_state = DSStageStateOverlay;
        } else if (previous == DSStageStateMinimized) {
            self->_state = DSStageStateMinimized;
        } else {
            self->_state = DSStageStateClosed;
        }
        if (self->_state == DSStageStateMinimized) {
            [self updateOpenAppIcon];
            [self setForegroundForAllHostedApps:NO];
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

    CGFloat phase = MIN(progress / kDSPullSettleProgress, 1.0);
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
    CGFloat resting = [self cornerRadiusForState:DSStageStateOverlay];
    CGFloat phase = MIN(progress / kDSPullSettleProgress, 1.0);
    _container.cornerRadius = kDSPeekCornerRadius + (resting - kDSPeekCornerRadius) * phase;
}

#pragma mark - Host snapshot

// A still of the screen stands in for the app behind for the length of the
// gesture. It shrinks about the screen centre over black while the corner is
// pulled, then springs back to full screen. The live app is never resized.
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
    CGFloat shrinkPhase = MIN(MAX(progress / kDSPullSettleProgress, 0.0), 1.0);
    CGFloat scale = 1.0 - (1.0 - kDSHostShrinkScale) * shrinkPhase;

    _hostSnapshot.transform = CGAffineTransformIdentity;
    _hostSnapshot.frame = screen;
    _hostSnapshot.transform = CGAffineTransformMakeScale(scale, scale);
    // The black only has to appear once the app has actually left the edges.
    _hostBackdrop.alpha = MIN(shrinkPhase * 4.0, 1.0);
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

#pragma mark - States

- (void)enterStateOverlayAnimated:(BOOL)animated {
    [self enterStateOverlayAnimated:animated keepingParkedCard:nil];
}

// keepParked stays in its corner. A pull from the other corner must not wake it.
- (void)enterStateOverlayAnimated:(BOOL)animated keepingParkedCard:(DSStageContainerView *)keepParked {
    // One card is an ordinary stage. Split, and the extra stage it allows,
    // only exist while both halves are on screen.
    if (_stackSlotCount < kDSMaxStackSlots) {
        _splitMode = NO;
        _splitHomeRevealed = NO;
        _splitResizeHeight = 0.0;
        _expandedCard = nil;
    }
    if (keepParked != _container) _primaryParked = NO;
    if (keepParked != _topContainer) _secondParked = NO;
    [self cancelAutoKill];
    if (_state != DSStageStateOverlay) DSDiagnosticsRecord(@"SpringBoard: stage on screen");
    _state = DSStageStateOverlay;
    [self publishTraceContext:@"on screen"];
    if (!_primaryParked) {
        _dragShell.hidden = NO;
        _dragShell.alpha = 1.0;
    }
    _overlaySettling = animated;
    _window.hidden = NO;
    if (self.hasHostedApp) {
        [self giveBackKeyWindow];
    } else {
        [self takeKeyWindowForStageChrome];
    }
    _openAppIcon.alpha = 0.0;

    if (self.hasHostedApp) [self setForegroundForAllHostedApps:YES];

    void (^layout)(void) = ^{
        // The app behind is untouched in overlay, so the still springs back to
        // full screen before it is thrown away.
        [self animateHostSnapshotToFullScreen];
        [self layoutAllStackSlotsForState:DSStageStateOverlay];
        self->_container.cornerRadius = [self cornerRadiusForState:DSStageStateOverlay];
        [self hideParkedCardsCompletely];
    };
    void (^finish)(void) = ^{
        self->_overlaySettling = NO;
        [self discardHostSnapshotAnimated:YES];
        [self layoutStageForState:DSStageStateOverlay];
        [self hideParkedCardsCompletely];
        [self updateOpenAppIcon];
        [self ejectHomeScreenFromStageWindow];
        [self updateHomeAffordance];
        [self resetStageGeometryAfterHostedApp];
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


- (void)minimizeAnimated:(BOOL)animated {
    if (!self.hasHostedApp) {
        [self closeStageAnimated:animated];
        return;
    }
    // A hosted card stays where it is. It is not parked under the screen.
}

// The same place the pull lands, reachable without the pull.
- (void)openStageAnimated:(BOOL)animated {
    if (!_activated) {
        DSDiagnosticsRecord(@"SpringBoard: asked to open the stage before it was ready");
        return;
    }
    if (_state == DSStageStateOverlay) {
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
    [self publishTraceContext:@"opening"];

    if (!self.hasHostedApp) {
        // Same landing as a tap on the bottom square of the right-edge shelf.
        [self presentPickerOnHalf:1 animated:animated];
        return;
    }
    [self enterStateOverlayAnimated:animated];
}

- (void)closeStageAnimated:(BOOL)animated {
    _ignoreSystemPullUntil = CFAbsoluteTimeGetCurrent() + 0.6;
    [self cancelAutoKill];
    [_picker dismissKeyboard];

    // The recordings show the card leaving straight down off the bottom edge at
    // full size rather than collapsing back into the corner.
    void (^layout)(void) = ^{
        [self setPrimaryCardFrameInRoot:[self stageFrameForState:DSStageStateClosed]];
        self->_container.cornerRadius = [self cornerRadiusForState:DSStageStateOverlay];
        self->_container.alpha = 1.0;
    };
    void (^finish)(void) = ^{
        self->_state = DSStageStateClosed;
        self->_container.alpha = 1.0;
        [self->_container setLiftOffset:0.0];
        self->_container.cornerRadius = [self cornerRadiusForState:DSStageStateOverlay];
        [self setPrimaryCardFrameInRoot:[self stageFrameForState:DSStageStateClosed]];
        self->_openAppIcon.alpha = 0.0;
        [self giveBackKeyWindow];
        self->_stageQuarterTurns = 0;
        [self publishTraceContext:@"closing"];
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
    _primaryHalf = 1;
    _secondHalf = 0;
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

#pragma mark - Shared state

// The injected app-side dylib has to know it is being hosted before its first
// frame, so the target and its rectangle are published to disk plus a Darwin
// notification for anything already running.
static void DSSetCardSizeNotify(const char *name, CGRect frame) {
    static int primary = NOTIFY_TOKEN_INVALID;
    static int peer = NOTIFY_TOKEN_INVALID;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_check(kDSStageCardSizeNotification, &primary);
        notify_register_check(kDSStageCardSizePeerNotification, &peer);
    });
    int token = strcmp(name, kDSStageCardSizePeerNotification) == 0 ? peer : primary;
    if (token == NOTIFY_TOKEN_INVALID) return;
    CGFloat rawWidth = CGRectGetWidth(frame);
    CGFloat rawHeight = CGRectGetHeight(frame);
    uint32_t width = rawWidth > 0.0 ? (uint32_t)(rawWidth + 0.5) : 0;
    uint32_t height = rawHeight > 0.0 ? (uint32_t)(rawHeight + 0.5) : 0;
    uint64_t value = 0;
    if (width >= 80 && height >= 80) value = (uint64_t)width | ((uint64_t)height << 32);
    notify_set_state(token, value);
}

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
    // Each hosted app lays out into its own card. A single width/height is the
    // last card published; Messages reads the size stored under its bundle.
    NSMutableDictionary *frames = [NSMutableDictionary dictionary];
    NSArray *hosts = @[ _sceneHost ?: [NSNull null], _topSceneHost ?: [NSNull null], _floatSceneHost ?: [NSNull null] ];
    for (id item in hosts) {
        if (![item isKindOfClass:DSSceneHost.class]) continue;
        DSSceneHost *host = item;
        if (!host.isHosting || host.bundleIdentifier.length == 0) continue;
        CGRect card = host.stageFrame;
        if (CGRectGetWidth(card) < 40.0 || CGRectGetHeight(card) < 40.0) card = frame;
        frames[host.bundleIdentifier] = NSStringFromCGRect(CGRectMake(0.0, 0.0, CGRectGetWidth(card), CGRectGetHeight(card)));
    }
    if (active && identifier.length && CGRectGetWidth(frame) > 40.0 && CGRectGetHeight(frame) > 40.0) {
        frames[identifier] = NSStringFromCGRect(CGRectMake(0.0, 0.0, CGRectGetWidth(frame), CGRectGetHeight(frame)));
    }
    // A drag step publishes the card that is moving. The app being uncovered
    // has to keep the tall size, or its window stays at the original half and
    // the new area is black and cannot be scrolled.
    for (id item in hosts) {
        if (![item isKindOfClass:DSSceneHost.class]) continue;
        DSSceneHost *host = item;
        if (!host.isRevealingTallContent || host.bundleIdentifier.length == 0) continue;
        CGRect tall = host.stageFrame;
        if (CGRectGetWidth(tall) < 80.0 || CGRectGetHeight(tall) < 80.0) continue;
        frames[host.bundleIdentifier] = NSStringFromCGRect(CGRectMake(0.0, 0.0,
                                                                       CGRectGetWidth(tall),
                                                                       CGRectGetHeight(tall)));
    }
    state[@"frames"] = frames;
    NSArray *liveRecents = [DSPreferences sharedPreferences].recentApplications;
    if (liveRecents.count > 0) state[@"recents"] = liveRecents;
    [state writeToFile:kDSSharedStatePath atomically:YES];
    // Messages cannot read Preferences. The same card sizes are published
    // where a sandboxed app can read them, and on the notify state.
    [state writeToFile:kDSStageCardPath atomically:YES];
    chmod(kDSStageCardPath.fileSystemRepresentation, 0644);

    CGRect primaryCard = CGRectZero;
    CGRect peerCard = CGRectZero;
    if (stages.count > 0) {
        id encoded = frames[stages[0]];
        if ([encoded isKindOfClass:NSString.class]) primaryCard = CGRectFromString((NSString *)encoded);
    }
    if (stages.count > 1) {
        id encoded = frames[stages[1]];
        if ([encoded isKindOfClass:NSString.class]) peerCard = CGRectFromString((NSString *)encoded);
    }
    DSSetCardSizeNotify(kDSStageCardSizeNotification, primaryCard);
    DSSetCardSizeNotify(kDSStageCardSizePeerNotification, peerCard);

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
    DSDiagnosticsRecord([@"SpringBoard: " stringByAppendingString:line]);
}

- (void)refreshKeyboardDebugLabel {
    if (_keyboardDebugLabel) {
        [_keyboardDebugLabel removeFromSuperview];
        _keyboardDebugLabel = nil;
    }
}

- (NSString *)bundleForKeyboardHash:(uint32_t)hash {
    if (hash == 0) return @"?";
    if (DSIdentifierHash(_sceneHost.bundleIdentifier) == hash) return _sceneHost.bundleIdentifier;
    if (DSIdentifierHash(_topSceneHost.bundleIdentifier) == hash) return _topSceneHost.bundleIdentifier;
    for (NSString *path in @[ @"/var/tmp/com.recreated.dynamicstage.ctor",
                              @"/var/jb/tmp/com.recreated.dynamicstage.ctor" ]) {
        NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        NSRange marker = [text rangeOfString:@"bundle="];
        if (marker.location == NSNotFound) continue;
        NSString *rest = [text substringFromIndex:NSMaxRange(marker)];
        NSRange end = [rest rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *bundle = end.location == NSNotFound ? rest : [rest substringToIndex:end.location];
        if (bundle.length && DSIdentifierHash(bundle) == hash) return bundle;
    }
    return [NSString stringWithFormat:@"hash %u", hash];
}

- (BOOL)isHostingSceneIdentifier:(NSString *)identifier {
    if (identifier.length == 0) return NO;
    NSString *bottom = _sceneHost.bundleIdentifier;
    NSString *top = _topSceneHost.bundleIdentifier;
    if (_sceneHost.isHosting && bottom.length &&
        [identifier rangeOfString:bottom].location != NSNotFound) {
        return YES;
    }
    if (_topSceneHost.isHosting && top.length &&
        [identifier rangeOfString:top].location != NSNotFound) {
        return YES;
    }
    NSString *hovering = _floatSceneHost.bundleIdentifier;
    if (_floatSceneHost.isHosting && hovering.length &&
        [identifier rangeOfString:hovering].location != NSNotFound) {
        return YES;
    }
    return NO;
}

- (void)noteKeyboardDebugFromApp:(NSString *)line {
    NSString *shown = line;
    NSString *written = [NSString stringWithContentsOfFile:@"/var/mobile/Library/Preferences/com.recreated.dynamicstage.keyboard.txt"
                                                 encoding:NSUTF8StringEncoding
                                                    error:nil];
    if (written.length) shown = written;
    if (shown.length && ![shown isEqualToString:@"hash 1 staged=0 chrome=0 hid=0"]) {
        DSDiagnosticsRecord([@"app: " stringByAppendingString:shown]);
    }
    static NSUInteger beeperLogged = 0;
    NSString *beeper = [NSString stringWithContentsOfFile:@"/var/tmp/com.recreated.dynamicstage.beeper-bar.log"
                                                encoding:NSUTF8StringEncoding
                                                   error:nil];
    if (beeper.length <= beeperLogged) return;
    NSString *fresh = [beeper substringFromIndex:beeperLogged];
    beeperLogged = beeper.length;
    for (NSString *row in [fresh componentsSeparatedByString:@"\n"]) {
        if (row.length == 0) continue;
        DSDiagnosticsRecord([@"Beeper bar: " stringByAppendingString:row]);
    }
}

- (void)noteStagedKeyResult:(NSString *)line {
    if (line.length == 0) return;
    DSDiagnosticsRecord(line);
}

- (void)noteAppDylibSignal:(uint32_t)hash listening:(BOOL)listening loaded:(BOOL)loaded remote:(BOOL)remote {
    if (hash == 0) return;
    NSNumber *key = @(hash);
    if (loaded) [_loadedAppHashes addObject:key];
    if (listening) [_listeningAppHashes addObject:key];
    if (remote) [_remoteKeyboardHashes addObject:key];
    // The remote hooks load when Messages launches, before anyone taps the
    // field. Inventing a 301pt keyboard here lifted the card with no keys.
    // The arbiter reports the real keyboard when the field is focused.
}

- (BOOL)hostedAppHasStageDylib:(NSString *)bundle {
    if (bundle.length == 0) return NO;
    NSNumber *key = @(DSIdentifierHash(bundle));
    return [_listeningAppHashes containsObject:key] || [_loadedAppHashes containsObject:key];
}

- (BOOL)hostedAppReportedRemoteKeyboard:(NSString *)bundle {
    if (bundle.length == 0) return NO;
    return [_remoteKeyboardHashes containsObject:@(DSIdentifierHash(bundle))];
}

- (void)noteKeyboardDebugFromSpringBoard:(NSString *)line {
    NSString *shown = line.length ? [@"SB: " stringByAppendingString:line] : @"SB: (empty)";
    static NSString *loggedSpringBoard;
    if ([shown isEqualToString:loggedSpringBoard]) return;
    loggedSpringBoard = [shown copy];
    DSDiagnosticsRecord(shown);
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
    [self resetStageGeometryAfterHostedApp];
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
    // 4.5.650 SIGTRAP guard: no key-window change from inside a scene settings
    // update or the home transition. The keyboard check below does it a
    // moment later instead.
    if ([DSSceneHost sceneSettingsUpdateDepth] == 0 && ![DSSceneHost homeGestureIsActive]) {
        [self takeKeyWindow];
    } else {
        [self noteSearchKeyboardDebug:@"search key window deferred (scene update / home transition)"];
    }
    // A user tap newer than the running check restarts it (the old one stops
    // on the generation change). Our own reassert / restart calls land here
    // too; those must not restart it, or it never ends.
    if (_ensuringPickerSearchKeyboard && DSSearchFieldLastUserTap() <= _pickerSearchEnsureStartedAt) return;
    _ensuringPickerSearchKeyboard = YES;
    _pickerSearchEnsureStartedAt = CFAbsoluteTimeGetCurrent();
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
        if (generation != strongSelf->_pickerSearchEnsureGeneration) return; // a newer check runs
        if (strongSelf->_searchSlot != slot) {
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
        if (attempt >= 7) {
            strongSelf->_ensuringPickerSearchKeyboard = NO;
            [strongSelf noteSearchKeyboardDebug:[strongSelf searchKeyboardDebugLine:@"search missing" attempt:attempt picker:picker]];
            return;
        }
        // 4.5.650: inside a scene update or the home transition (and its quiet
        // window) a key-window change is the SIGTRAP and takeKeyWindow refuses
        // anyway. Wait it out without using up an attempt (bounded).
        if (([DSSceneHost sceneSettingsUpdateDepth] > 0 || [DSSceneHost homeGestureIsActive]) &&
            CFAbsoluteTimeGetCurrent() - strongSelf->_pickerSearchEnsureStartedAt < 3.0) {
            [strongSelf ensurePickerSearchKeyboard:picker slot:slot generation:generation attempt:attempt];
            return;
        }
        if (!picker.view.window) {
            strongSelf->_ensuringPickerSearchKeyboard = NO;
            return; // picker closed
        }
        [strongSelf noteSearchKeyboardDebug:[strongSelf searchKeyboardDebugLine:@"search retry" attempt:attempt picker:picker]];
        [strongSelf takeKeyWindow];
        if (!DSWindowIsApplicationKey(strongSelf->_window) && !DSVideoIsPlayingOnScreen()) {
            [strongSelf->_window makeKeyAndVisible];
        }
        // The first retries only reload. Restarting editing resigns the field,
        // which would drop a keyboard that is still on its way in. Over a
        // playing video that resign is also what flashes the picture.
        if (attempt >= 2 && !DSVideoIsPlayingOnScreen()) {
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
    DSReleaseKeyboardLevelHold();
    if (_searchSlot == [self slotForPicker:picker]) _searchSlot = -1;
    // Hand the key window back while an app is still staged. Leaving it key
    // is what took the keyboard away from that app after search.
    if (_sceneHost.isHosting || _topSceneHost.isHosting) {
        [self giveBackKeyWindow];
    }
}

// 4.5.650: _overlaySettling is set by the present paths and cleared only by
// the matching finish call, which returns early when a newer presentation
// bumped the generation meanwhile. Then it stayed YES, the field waited
// forever and no keyboard came up. The card has landed long before 0.6s of
// continuous "settling", so clear it then.
- (BOOL)appPickerShouldWaitBeforeSearchEditing:(DSAppPickerViewController *)picker {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!_overlaySettling) {
        _overlaySettlingSeenSince = 0;
        return NO;
    }
    if (_overlaySettlingSeenSince == 0 || now - _overlaySettlingSeenLast > 0.4) _overlaySettlingSeenSince = now;
    _overlaySettlingSeenLast = now;
    if (now - _overlaySettlingSeenSince > 0.6) {
        _overlaySettling = NO;
        _overlaySettlingSeenSince = 0;
        DSDiagnosticsRecord(@"SpringBoard: picker search: the present settle flag was stuck, cleared it so the keyboard can show");
        return NO;
    }
    return YES;
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
    if (slot < 0 || slot > 2) return;
    if (slot == 2 && !_floatContainer) return;

    DSAppPickerViewController *picker = [self pickerForSlot:slot];
    [picker dismissKeyboard];
    // The keyboard on screen is the picker's. Leaving it in place and then
    // handing it to the new app is the invisible keyboard on a bottom card.
    [self forgetStagedAppKeyboard];

    DSPreferences *preferences = [DSPreferences sharedPreferences];
    if ([preferences isApplicationDisabled:entry.bundleIdentifier]) {
        DSDiagnosticsRecordFormat(@"SpringBoard: %@ is switched off in its own settings, so it was not opened",
                                  entry.bundleIdentifier);
        return;
    }
    if ([self bundleIsAlreadyStaged:entry.bundleIdentifier excludingSlot:slot]) {
        DSDiagnosticsRecordFormat(@"SpringBoard: %@ is already on a stage, so it was not opened again",
                                  entry.bundleIdentifier);
        return;
    }

    DSSceneHost *existingHost = [self sceneHostForSlot:slot];
    if (existingHost && ![existingHost.bundleIdentifier isEqualToString:entry.bundleIdentifier]) {
        [self setSceneHost:nil forSlot:slot];
        if (slot == 0) [self forgetStagedAppKeyboard];
        [existingHost relinquishKeepingBackgrounded:[preferences backgroundsOnMinimize:existingHost.bundleIdentifier]];
    }

    SBApplication *wasInFront = [self frontApplication];
    _bundleIdentifierToRestoreInFront =
        [wasInFront.bundleIdentifier isEqualToString:entry.bundleIdentifier] ? nil : wasInFront.bundleIdentifier;

    [preferences noteApplicationOpened:entry.bundleIdentifier];
    if (_picker) [_picker reloadContent];
    if (_topPicker) [_topPicker reloadContent];
    DSStageState layoutState = DSStageStateOverlay;
    CGRect published = (slot == 2) ? [self rootFrameOfCard:_floatContainer]
                                   : [self frameForHalf:(slot == 1 ? _secondHalf : _primaryHalf) state:layoutState];
    [self publishStageStateForBundleIdentifier:entry.bundleIdentifier frame:published active:YES];
    [self presentLaunchPlaceholderForEntry:entry slot:slot];

    DSSceneHost *host = [self sceneHostForSlot:slot];
    if (!host) {
        host = [[DSSceneHost alloc] initWithBundleIdentifier:entry.bundleIdentifier];
        [self setSceneHost:host forSlot:slot];
    }
    if ([self cardMatchesItsFrame:[self containerForSlot:slot]]) {
        host.matchCardFrame = YES;
    }
    NSInteger launchHalf = slot == 1 ? _secondHalf : _primaryHalf;
    CGRect launchFrame = [self fixedHalfFrame:launchHalf == 0 ? 0 : 1];
    if (slot == 2) launchFrame = [self rootFrameOfCard:_floatContainer];
    [host noteLaunchFrame:launchFrame];
    host.parentViewController = _window.rootViewController;
    [self refreshShelf];

    DSDiagnosticsRecordFormat(@"SpringBoard: putting %@ on stack slot %ld", entry.bundleIdentifier, (long)slot);
    [self publishTraceContext:[@"launch " stringByAppendingString:entry.bundleIdentifier]];

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
                [strongSelf setSceneHost:nil forSlot:slot];
                [strongSelf publishStageStateForBundleIdentifier:nil frame:CGRectZero active:NO];
                [host relinquishKeepingBackgrounded:NO];
            }
            [strongSelf refreshShelf];
            return;
        }
        [strongSelf attachHostedAppForSlot:slot];
    }];
}

- (DSLaunchPlaceholderView *)launchPlaceholderForSlot:(NSInteger)slot {
    if (slot == 2) return _floatLaunchPlaceholder;
    return slot == 0 ? _launchPlaceholder : _topLaunchPlaceholder;
}

- (void)setLaunchPlaceholder:(DSLaunchPlaceholderView *)placeholder forSlot:(NSInteger)slot {
    if (slot == 2) _floatLaunchPlaceholder = placeholder;
    else if (slot == 0) _launchPlaceholder = placeholder;
    else _topLaunchPlaceholder = placeholder;
}

- (void)presentLaunchPlaceholderForEntry:(DSAppEntry *)entry slot:(NSInteger)slot {
    DSStageContainerView *card = [self containerForSlot:slot];
    DSAppPickerViewController *picker = [self pickerForSlot:slot];
    [[self launchPlaceholderForSlot:slot] removeFromSuperview];
    [self setLaunchPlaceholder:nil forSlot:slot];

    DSLaunchPlaceholderView *placeholder =
        [[DSLaunchPlaceholderView alloc] initWithBundleIdentifier:entry.bundleIdentifier
                                                            icon:[[DSAppLibrary sharedLibrary] iconForBundleIdentifier:entry.bundleIdentifier]
                                                            dark:card.darkMode];
    placeholder.frame = card.contentView.bounds;
    placeholder.alpha = 0.0;
    [card.contentView addSubview:placeholder];
    [self setLaunchPlaceholder:placeholder forSlot:slot];

    [UIView animateWithDuration:0.22 animations:^{
        placeholder.alpha = 1.0;
        picker.view.alpha = 0.0;
    }];
}

- (void)dismissLaunchPlaceholderForSlot:(NSInteger)slot {
    DSAppPickerViewController *picker = [self pickerForSlot:slot];
    UIView *placeholder = [self launchPlaceholderForSlot:slot];
    [self setLaunchPlaceholder:nil forSlot:slot];
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
    DSAppPickerViewController *picker = [self pickerForSlot:slot];

    UIView *hostView = host.hostView;
    if (!hostView) {
        DSDiagnosticsRecordFormat(@"SpringBoard: %@ was ready but handed over no view", host.bundleIdentifier);
        if (slot == 0) _bundleIdentifierToRestoreInFront = nil;
        [self dismissLaunchPlaceholderForSlot:slot];
        return;
    }
    DSDiagnosticsRecordFormat(@"SpringBoard: %@ is on stack slot %ld", host.bundleIdentifier, (long)slot);
    [self publishTraceContext:[@"hosted " stringByAppendingString:host.bundleIdentifier ?: @"?"]];
    DSDiagnosticsAppendKeyboardStageLog([NSString stringWithFormat:@"attach %@ slot %ld stack=%ld prim=%ld",
                                       host.bundleIdentifier, (long)slot, (long)_stackSlotCount, (long)_primaryHalf]);
    if ([host.bundleIdentifier isEqualToString:@"com.beeper.chat.ios"] && _stackSlotCount < kDSMaxStackSlots) {
        [self classifySlotForBundle:host.bundleIdentifier slot:slot];
    }

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
    [self refreshCardGeometry:card];
    [host fitHostViewToCard];
    [card setBackdropHidden:YES];
    [host noteHostViewAttached];

    DSStageState layoutState = DSStageStateOverlay;
    [self layoutStageForState:layoutState];
    if (slot == 0) [self applyStageRotation];
    DSLiftSlotAt(slot)->hasRestingFrame = NO;
    [card setLiftOffset:0.0];
    [self captureKeyboardBaseForSlot:slot];
    _searchSlot = -1;
    [self giveBackKeyWindow];
    if (slot == 0) [self returnFrontToWhereItWas];

    [self updateHomeAffordance];
    [self refreshShelf];
    [self bringFloatAboveSplit];
    if ([self cardMatchesItsFrame:card]) [self scheduleLiveStageRefit];

    UIView *placeholder = [self launchPlaceholderForSlot:slot];
    [self setLaunchPlaceholder:nil forSlot:slot];
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
            DSDiagnosticsRecord(@"SpringBoard: back to the home screen behind the stage");
            [self pressHomeButton];
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
    DSAppPickerViewController *picker = [self pickerForSlot:slot];
    if (_keyboardLiftSlot == slot) {
        _keyboardFrame = CGRectZero;
        _notedKeyboardOnce = NO;
    }
    [card setLiftOffset:0.0];
    _searchSlot = -1;
    if (_stagedKeyboardSlot == slot) [self hideStagedKeyboardLikePicker];
    [self setSceneHost:nil forSlot:slot];
    if (slot == 0) {
        _stageQuarterTurns = 0;
        [self forgetStagedAppKeyboard];
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
        [self layoutStageForState:DSStageStateOverlay];
        [self refreshShelf];
        [self bringShelfToFront];
        [self resetStageGeometryAfterHostedApp];
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
        [self layoutStageForState:DSStageStateOverlay];
        [self refreshShelf];
        [self bringShelfToFront];
        if (!self->_sceneHost.isHosting && !self->_topSceneHost.isHosting) {
            [self preparePickerForSearchKeyboard];
        } else {
            [self giveBackKeyWindow];
        }
        [self resetStageGeometryAfterHostedApp];
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
    [self publishStageStateForBundleIdentifier:nil frame:CGRectZero active:NO];
    [host relinquishKeepingBackgrounded:NO];

    SpringBoard *springBoard = (SpringBoard *)UIApplication.sharedApplication;
    if ([springBoard respondsToSelector:@selector(launchApplicationWithIdentifier:suspended:)]) {
        [springBoard launchApplicationWithIdentifier:identifier suspended:NO];
    }

    _state = DSStageStateClosed;
    [self setPrimaryCardFrameInRoot:[self stageFrameForState:DSStageStateClosed]];
    _primaryHalf = 1;
    _secondHalf = 0;
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

- (void)applyOpenAppIcon:(UIImageView *)icon
                    host:(DSSceneHost *)host
                  parked:(BOOL)parked
                  onLeft:(BOOL)onLeft
                    lift:(CGFloat)lift {
    BOOL show = [DSPreferences sharedPreferences].showOpenAppIcon && parked && host.isHosting;
    if (!show) {
        icon.alpha = 0.0;
        return;
    }
    icon.image = [[DSAppLibrary sharedLibrary] iconForBundleIdentifier:host.bundleIdentifier];
    icon.layer.cornerRadius = 9.0;
    [UIView performWithoutAnimation:^{
        icon.frame = [self openAppIconFrameOnLeft:onLeft lift:lift];
        icon.alpha = 1.0;
    }];
    _window.hidden = NO;
    if (icon.superview) [icon.superview bringSubviewToFront:icon];
}

- (void)showStashedAppIcon:(DSSceneHost *)host onLeft:(BOOL)onLeft {
    if (!host.isHosting) return;
    UIImageView *icon = _openAppIcon.alpha < 0.01 ? _openAppIcon : nil;
    if (!icon && _secondOpenAppIcon.alpha < 0.01) icon = _secondOpenAppIcon;
    if (!icon) return;
    [self applyOpenAppIcon:icon host:host parked:YES onLeft:onLeft lift:0.0];
}

- (void)updateOpenAppIcon {
    BOOL sameCorner = _primaryParked && _secondParked && _primaryMinimizedLeft == _secondMinimizedLeft;
    [self applyOpenAppIcon:_openAppIcon
                      host:_sceneHost
                    parked:_primaryParked
                    onLeft:_primaryMinimizedLeft
                      lift:0.0];
    [self applyOpenAppIcon:_secondOpenAppIcon
                      host:_topSceneHost
                    parked:_secondParked
                    onLeft:_secondMinimizedLeft
                      lift:sameCorner ? 42.0 : 0.0];
    [self showStashedAppIcon:_stashedHost onLeft:_stashedLeft];
    [self showStashedAppIcon:_stashedHost2 onLeft:_stashedLeft2];
    if (_openAppIcon.alpha < 0.01 && _secondOpenAppIcon.alpha < 0.01 &&
        (_state == DSStageStateClosed || _state == DSStageStateMinimized)) {
        [self noteStageWindowIdle];
    }
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
        if (strongSelf->_state == DSStageStateOverlay) return;
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

// The outer band moves the card between halves. The right-edge swipe and the
// bottom-right inward swipe are not gestures.
- (void)syncParkedCardVisibility {
    if (_dragShell && !_primaryParked) {
        _dragShell.hidden = NO;
        _dragShell.alpha = 1.0;
    }
    if (_topContainer && !_secondParked && _stackSlotCount >= kDSMaxStackSlots) {
        _topContainer.hidden = NO;
        _topContainer.alpha = 1.0;
        _topRim.hidden = NO;
        _topRim.alpha = 1.0;
    }
}

- (void)hideParkedCardsCompletely {
    if (_primaryParked && _dragShell) {
        _dragShell.alpha = 0.0;
        _dragShell.hidden = YES;
    }
    if (_secondParked) {
        _topContainer.alpha = 0.0;
        _topRim.alpha = 0.0;
        _topContainer.hidden = YES;
        _topRim.hidden = YES;
    }
}

- (void)minimizeCardToCornerAnimated:(BOOL)animated {
    _primaryParked = YES;
    _ignoreSystemPullUntil = 0;
    void (^layout)(void) = ^{
        [self layoutAllStackSlotsForState:DSStageStateMinimized];
    };
    void (^finish)(void) = ^{
        self->_state = DSStageStateMinimized;
        [self hideParkedCardsCompletely];
        DSReleaseStagedKeyboardHost();
        [self giveBackKeyWindow];
        [self setForegroundForAllHostedApps:NO];
        [self cancelAutoKill];
        [self updateOpenAppIcon];
        [self updateHomeAffordance];
        [self refreshShelf];
        [self bringShelfToFront];
    };
    if (animated) {
        [self animateEaseIntoCorner:layout completion:finish];
    } else {
        layout();
        finish();
    }
}

- (void)animateEaseIntoCorner:(void (^)(void))animations completion:(void (^)(void))completion {
    [UIView animateWithDuration:0.32
                          delay:0
                        options:UIViewAnimationOptionCurveEaseIn | UIViewAnimationOptionAllowUserInteraction
                     animations:animations
                     completion:^(BOOL finished) {
        if (completion) completion();
    }];
}

- (void)stopDragMotionForCard:(DSStageContainerView *)card {
    [card stopMotion];
    UIView *picture = [self rememberedPictureForCard:card];
    [picture.layer removeAllAnimations];
    if (card == _container || !card) {
        [_dragShell.layer removeAllAnimations];
        for (CALayer *layer in _dragShell.layer.sublayers) [layer removeAllAnimations];
    }
    if (card == _topContainer && _topRim) {
        [_topRim.layer removeAllAnimations];
        for (CALayer *layer in _topRim.layer.sublayers) [layer removeAllAnimations];
    }
    if (card == _floatContainer && _floatRim) {
        [_floatRim.layer removeAllAnimations];
        for (CALayer *layer in _floatRim.layer.sublayers) [layer removeAllAnimations];
    }
}

- (void)stopMinimizedMotionForCard:(DSStageContainerView *)card {
    [self stopDragMotionForCard:card];
    if (card == _container && _dragShell) {
        [_dragShell.layer removeAllAnimations];
        for (CALayer *layer in _dragShell.layer.sublayers) [layer removeAllAnimations];
    }
    if (card == _topContainer && _topRim) {
        [_topRim.layer removeAllAnimations];
        for (CALayer *layer in _topRim.layer.sublayers) [layer removeAllAnimations];
    }
    if (card == _floatContainer && _floatRim) {
        [_floatRim.layer removeAllAnimations];
        for (CALayer *layer in _floatRim.layer.sublayers) [layer removeAllAnimations];
    }
    UIImageView *icon = (card == _topContainer) ? _secondOpenAppIcon : _openAppIcon;
    [icon.layer removeAllAnimations];
}

- (void)minimizeDraggedCard:(DSStageContainerView *)card fromHalf:(NSInteger)half onLeft:(BOOL)onLeft animated:(BOOL)animated {
    if (card == _floatContainer) {
        [self dismissFloatStageAnimated:animated terminate:NO];
        return;
    }
    if (_splitMode && [self halfForContainer:card] == 0) {
        [self leaveSplitSendingTopAppFullScreenFromBottomCard:card minimizeBottom:YES onLeft:onLeft animated:animated];
        return;
    }
    if (_splitMode) {
        _splitMode = NO;
        _expandedCard = nil;
        _splitHomeRevealed = NO;
    }
    DSSceneHost *host = [self sceneHostForCard:card];
    if (!host.isHosting) {
        // The picker still leaves through the corner it was dragged to, then
        // the stage is closed. It does not slide to the bottom middle.
        if (card == _topContainer) _secondMinimizedLeft = onLeft;
        else _primaryMinimizedLeft = onLeft;
        CGRect exitFrame = [self cornerParkFrameForCard:card];
        void (^layout)(void) = ^{
            [self placeCard:card atFrame:exitFrame];
            card.alpha = 0.0;
            if (card == self->_container) self->_dragShell.alpha = 0.0;
            if (card == self->_topContainer) self->_topRim.alpha = 0.0;
        };
        void (^finish)(void) = ^{
            if (self->_stackSlotCount >= kDSMaxStackSlots && card == self->_topContainer) {
                [self dropEmptySecondCard];
                return;
            }
            if (self->_stackSlotCount >= kDSMaxStackSlots && card == self->_container && self->_topSceneHost.isHosting) {
                [self promoteSecondCardToPrimary];
                return;
            }
            [self finishDismissStage];
        };
        if (animated) [self animateEaseIntoCorner:layout completion:finish];
        else { layout(); finish(); }
        return;
    }
    if (card == _topContainer) _secondMinimizedLeft = onLeft;
    else _primaryMinimizedLeft = onLeft;
    if (card == _container) {
        _minimizedHalf = half == 0 ? 0 : 1;
        _primaryHalf = _minimizedHalf;
    }
    if (![self rememberedPictureForCard:card]) [self rememberPictureForCard:card];
    [self showRememberedPictureOnCard:card];
    [self setParked:YES forCard:card];
    DSStageContainerView *other = (card == _container) ? _topContainer : _container;
    BOOL otherStays = _stackSlotCount >= kDSMaxStackSlots && other && !other.hidden && ![self cardIsParked:other];
    if (!otherStays) {
        [self minimizeCardToCornerAnimated:animated];
        return;
    }
    void (^layout)(void) = ^{
        [self layoutAllStackSlotsForState:DSStageStateOverlay];
    };
    void (^finish)(void) = ^{
        [self hideParkedCardsCompletely];
        [self updateOpenAppIcon];
        [self updateHomeAffordance];
        [self refreshShelf];
        [self bringFloatAboveSplit];
        if (self->_expandedCard) {
            [self refitLiveStageHosts];
            [self scheduleLiveStageRefit];
        }
    };
    if (animated) [self animateSpring:layout completion:finish];
    else { layout(); finish(); }
}

// The corner continues off the bottom and the side. A full-width card can
// never fit most of itself into a small on-screen box, so the zone is the
// region past the late corner line, including off the screen.
- (CGRect)bottomCornerZoneOnLeft:(BOOL)left {
    CGRect screen = [self screenBounds];
    CGFloat width = CGRectGetWidth(screen);
    CGFloat height = CGRectGetHeight(screen);
    CGFloat x0 = width * 0.93;
    CGFloat y0 = height * 0.94;
    if (left) {
        return CGRectMake(-width, y0, width + width * 0.07, height * 2.0);
    }
    return CGRectMake(x0, y0, width * 2.0, height * 2.0);
}

- (CGFloat)fractionOfFrame:(CGRect)frame insideZone:(CGRect)zone {
    if (CGRectIsEmpty(frame) || CGRectIsEmpty(zone)) return 0.0;
    CGRect hit = CGRectIntersection(frame, zone);
    if (CGRectIsNull(hit) || CGRectIsEmpty(hit)) return 0.0;
    CGFloat cardArea = CGRectGetWidth(frame) * CGRectGetHeight(frame);
    if (cardArea < 1.0) return 0.0;
    return (CGRectGetWidth(hit) * CGRectGetHeight(hit)) / cardArea;
}

// 0 until most of the card is actually inside a bottom corner. A finger
// reaching the corner first does not count.
- (BOOL)velocityIsQuickCornerSwipe:(CGPoint)velocity onLeft:(BOOL *)onLeft {
    if (velocity.y < 700.0 || fabs(velocity.x) < 320.0) return NO;
    if (hypot(velocity.x, velocity.y) < 980.0) return NO;
    if (onLeft) *onLeft = velocity.x < 0.0;
    return YES;
}

- (CGFloat)cornerApproachForCardFrame:(CGRect)frame finger:(CGPoint)finger {
    (void)frame;
    CGRect screen = [self screenBounds];
    CGFloat width = CGRectGetWidth(screen);
    CGFloat height = CGRectGetHeight(screen);
    if (finger.y < height * 0.86) return 0.0;
    CGFloat left = hypot(finger.x, height - finger.y);
    CGFloat right = hypot(width - finger.x, height - finger.y);
    CGFloat dist = MIN(left, right);
    CGFloat reach = 70.0;
    if (dist >= reach) return 0.0;
    CGFloat t = 1.0 - dist / reach;
    return t * t * 0.55;
}

- (CGRect)terminateHintRect {
    CGRect screen = [self screenBounds];
    CGFloat width = CGRectGetWidth(screen);
    CGFloat height = CGRectGetHeight(screen);
    CGFloat hintWidth = floor(width * 0.26);
    CGFloat hintHeight = 40.0;
    return CGRectMake((width - hintWidth) / 2.0, height - 6.0 - hintHeight, hintWidth, hintHeight);
}

// How close the card's bottom edge is to the home bar. No stick, just the glow.
- (CGFloat)terminateApproachForCardFrame:(CGRect)frame finger:(CGPoint)finger {
    if ([self cornerApproachForCardFrame:frame finger:finger] > 0.0) return 0.0;
    CGRect screen = [self screenBounds];
    CGFloat width = CGRectGetWidth(screen);
    CGFloat height = CGRectGetHeight(screen);
    if (finger.y < height - 78.0) return 0.0;
    if (fabs(finger.x - width * 0.5) > width * 0.16) return 0.0;
    CGFloat t = (finger.y - (height - 78.0)) / 78.0;
    if (CGRectGetMaxY(frame) > height - 36.0) t = MAX(t, 0.65);
    return MIN(MAX(t, 0.0), 1.0);
}

- (BOOL)cardFrameInTerminateZone:(CGRect)frame finger:(CGPoint)finger {
    CGRect screen = [self screenBounds];
    CGFloat width = CGRectGetWidth(screen);
    CGFloat height = CGRectGetHeight(screen);
    BOOL middle = CGRectGetMidX(frame) > width * 0.28 && CGRectGetMidX(frame) < width * 0.72;
    if (!middle) return NO;
    // A card dragged from the top reaches this once its bottom hits the
    // bottom of the screen. The centre of a tall card never gets that low.
    BOOL cardReachedBottom = CGRectGetMaxY(frame) > height * 0.97;
    BOOL fingerAtBottom = finger.y > height * 0.92 && finger.x > width * 0.28 && finger.x < width * 0.72;
    return cardReachedBottom || fingerAtBottom;
}

- (void)setTerminateHintAmount:(CGFloat)amount {
    if (!_terminateHint) return;
    amount = MIN(MAX(amount, 0.0), 1.0);
    CGRect screen = [self screenBounds];
    CGFloat width = CGRectGetWidth(screen);
    CGFloat height = CGRectGetHeight(screen);
    CGFloat glowHeight = 120.0;
    UIView *root = _terminateHint.superview;
    if (root && !_terminateGlowHost) {
        _terminateGlowHost = [[UIView alloc] initWithFrame:CGRectZero];
        _terminateGlowHost.userInteractionEnabled = NO;
        _terminateGlowHost.backgroundColor = UIColor.clearColor;
        [root addSubview:_terminateGlowHost];
        [_terminateGlow removeFromSuperlayer];
        [_terminateGlowHost.layer addSublayer:_terminateGlow];
    }
    _terminateGlow.type = kCAGradientLayerRadial;
    _terminateGlowHost.frame = CGRectMake(0.0, height - glowHeight, width, glowHeight);
    _terminateGlow.frame = _terminateGlowHost.bounds;
    _terminateGlow.startPoint = CGPointMake(0.5, 0.72);
    _terminateGlow.endPoint = CGPointMake(1.05, -0.05);
    _terminateGlow.colors = @[
        (id)[UIColor colorWithRed:0.62 green:0.0 blue:0.03 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.48 green:0.0 blue:0.02 alpha:0.55].CGColor,
        (id)[UIColor colorWithRed:0.28 green:0.0 blue:0.02 alpha:0.0].CGColor,
    ];
    _terminateGlow.locations = @[ @0.0, @0.38, @1.0 ];
    _terminateGlow.opacity = amount > 0.04 ? 1.0 : 0.0;
    _terminateGlowHost.alpha = amount > 0.04 ? MAX(amount, 0.85) : 0.0;
    if (_terminateGlowHost.superview) {
        [_terminateGlowHost.superview bringSubviewToFront:_terminateGlowHost];
    }
    _terminateHint.alpha = 0.0;
    _terminateHint.hidden = YES;
    _terminateHint.layer.zPosition = 41.0;
    if (_terminateHint.superview) {
        [_terminateHint.superview bringSubviewToFront:_terminateHint];
    }
}

- (void)setTerminateHintVisible:(BOOL)visible {
    [self setTerminateHintAmount:visible ? 1.0 : 0.0];
}

- (UIView *)rememberedPictureForCard:(DSStageContainerView *)card {
    if (card == _floatContainer) return _floatParkPicture;
    return (card == _topContainer) ? _secondParkPicture : _primaryParkPicture;
}

- (void)setRememberedPicture:(UIView *)picture forCard:(DSStageContainerView *)card {
    if (card == _floatContainer) _floatParkPicture = picture;
    else if (card == _topContainer) _secondParkPicture = picture;
    else _primaryParkPicture = picture;
}

- (void)rememberPictureForCard:(DSStageContainerView *)card {
    if (!card.hostingApp || !card.contentView) return;
    UIView *previous = [self rememberedPictureForCard:card];
    [previous removeFromSuperview];
    UIView *picture = [card.contentView snapshotViewAfterScreenUpdates:NO];
    if (!picture) return;
    picture.userInteractionEnabled = NO;
    picture.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self setRememberedPicture:picture forCard:card];
}

- (void)showRememberedPictureOnCard:(DSStageContainerView *)card {
    UIView *picture = [self rememberedPictureForCard:card];
    if (!picture || !card.contentView) return;
    picture.frame = card.contentView.bounds;
    if (picture.superview != card.contentView) [card.contentView addSubview:picture];
    [card.contentView bringSubviewToFront:picture];
}

- (void)discardRememberedPictureForCard:(DSStageContainerView *)card {
    UIView *hostView = [self sceneHostForCard:card].hostView;
    if (hostView) hostView.alpha = 1.0;
    UIView *picture = [self rememberedPictureForCard:card];
    [picture removeFromSuperview];
    [self setRememberedPicture:nil forCard:card];
}

// The live scene is drawn by a separate layer that eases toward the card.
// A still taken at the start of the drag stays inside the card and moves
// with the finger. The live view comes back when the drag ends.
- (void)freezeHostedContentsForDrag:(DSStageContainerView *)card {
    if (!card.hostingApp) return;
    [self rememberPictureForCard:card];
    if (![self rememberedPictureForCard:card]) return;
    [self showRememberedPictureOnCard:card];
    UIView *hostView = [self sceneHostForCard:card].hostView;
    hostView.alpha = 0.0;
}

- (BOOL)dragFrame:(CGRect)frame wantsSwapForCard:(DSStageContainerView *)card {
    if (_expandedCard || card == _floatContainer) return NO;
    if (_stackSlotCount < kDSMaxStackSlots) return NO;
    DSStageContainerView *other = (card == _container) ? _topContainer : _container;
    if (!other || other.hidden || [self cardIsParked:other]) return NO;
    NSInteger own = [self halfForContainer:card];
    NSInteger otherHalf = own == 0 ? 1 : 0;
    if ([self halfForContainer:other] == own) return NO;
    CGFloat mid = CGRectGetMidY(frame);
    CGFloat ownMid = CGRectGetMidY(_splitMode ? [self splitPairFrame:own] : [self fixedHalfFrame:own]);
    CGFloat otherMid = CGRectGetMidY(_splitMode ? [self splitPairFrame:otherHalf] : [self fixedHalfFrame:otherHalf]);
    CGFloat travel = otherMid - ownMid;
    if (fabs(travel) < 1.0) return NO;
    // A short move toward the other stage is enough. They do not have to cross.
    return (mid - ownMid) / travel > 0.08;
}

// A light tug back toward the screen edge, not a wall. Heading for a corner
// or the home bar skips it, and so does the little stick on each half.
- (CGRect)frame:(CGRect)frame softenedWithVelocity:(CGPoint)velocity towardCorner:(BOOL)towardCorner towardHome:(BOOL)towardHome {
    if (towardCorner || towardHome) return frame;
    CGRect screen = [self screenBounds];
    CGFloat width = CGRectGetWidth(screen);
    CGFloat height = CGRectGetHeight(screen);
    if (frame.origin.x < 0.0) frame.origin.x *= 0.62;
    CGFloat right = CGRectGetMaxX(frame) - width;
    if (right > 0.0) frame.origin.x -= right * 0.38;
    if (frame.origin.y < 0.0) frame.origin.y *= 0.62;
    CGFloat bottom = CGRectGetMaxY(frame) - height;
    if (bottom > 0.0) frame.origin.y -= bottom * 0.38;
    if (fabs(velocity.y) > 280.0) return frame;
    CGFloat band = 10.0;
    for (NSInteger half = 0; half < 2; half++) {
        CGFloat rest = CGRectGetMinY([self fixedHalfFrame:half]);
        CGFloat delta = frame.origin.y - rest;
        if (fabs(delta) < band) frame.origin.y = rest + delta * 0.55;
    }
    return frame;
}

- (CGFloat)swapTravelForFrame:(CGRect)frame card:(DSStageContainerView *)card {
    if (_stackSlotCount < kDSMaxStackSlots) return 0.0;
    DSStageContainerView *other = (card == _container) ? _topContainer : _container;
    if (!other || other.hidden || [self cardIsParked:other]) return 0.0;
    NSInteger own = [self halfForContainer:card];
    if ([self halfForContainer:other] == own) return 0.0;
    CGFloat ownMid = CGRectGetMidY([self fixedHalfFrame:own]);
    CGFloat otherMid = CGRectGetMidY([self fixedHalfFrame:own == 0 ? 1 : 0]);
    CGFloat travel = otherMid - ownMid;
    if (fabs(travel) < 1.0) return 0.0;
    return MIN(MAX((CGRectGetMidY(frame) - ownMid) / travel, 0.0), 1.0);
}

- (UIVisualEffectView *)swapGlass:(UIVisualEffectView *)glass {
    if (glass) return glass;
    UIVisualEffectView *view = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialLight]];
    view.userInteractionEnabled = NO;
    view.clipsToBounds = YES;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.alpha = 0.0;
    UIView *root = _window.rootViewController.view;
    [root addSubview:view];
    return view;
}

static UIBezierPath *DSBottomHalfRim(CGRect rect, CGFloat radius) {
    CGFloat r = MIN(radius, MIN(CGRectGetWidth(rect), CGRectGetHeight(rect)) * 0.5);
    CGFloat minX = CGRectGetMinX(rect);
    CGFloat maxX = CGRectGetMaxX(rect);
    CGFloat maxY = CGRectGetMaxY(rect);
    CGFloat midY = CGRectGetMidY(rect);
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(minX, midY)];
    [path addLineToPoint:CGPointMake(minX, maxY - r)];
    [path addArcWithCenter:CGPointMake(minX + r, maxY - r) radius:r startAngle:M_PI endAngle:M_PI_2 clockwise:YES];
    [path addLineToPoint:CGPointMake(maxX - r, maxY)];
    [path addArcWithCenter:CGPointMake(maxX - r, maxY - r) radius:r startAngle:M_PI_2 endAngle:0 clockwise:YES];
    [path addLineToPoint:CGPointMake(maxX, midY)];
    return path;
}

static UIBezierPath *DSTopHalfRim(CGRect rect, CGFloat radius) {
    CGFloat r = MIN(radius, MIN(CGRectGetWidth(rect), CGRectGetHeight(rect)) * 0.5);
    CGFloat minX = CGRectGetMinX(rect);
    CGFloat maxX = CGRectGetMaxX(rect);
    CGFloat minY = CGRectGetMinY(rect);
    CGFloat midY = CGRectGetMidY(rect);
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(minX, midY)];
    [path addLineToPoint:CGPointMake(minX, minY + r)];
    [path addArcWithCenter:CGPointMake(minX + r, minY + r) radius:r startAngle:M_PI endAngle:-M_PI_2 clockwise:NO];
    [path addLineToPoint:CGPointMake(maxX - r, minY)];
    [path addArcWithCenter:CGPointMake(maxX - r, minY + r) radius:r startAngle:-M_PI_2 endAngle:0 clockwise:NO];
    [path addLineToPoint:CGPointMake(maxX, midY)];
    return path;
}

- (void)updateSwapGlassForCard:(DSStageContainerView *)card frame:(CGRect)frame velocity:(CGPoint)velocity {
    _swapGlassTop.alpha = 0.0;
    _swapGlassBottom.alpha = 0.0;
    UIView *root = _window.rootViewController.view;
    if (!_swapGhost) {
        _swapGhost = [CAShapeLayer layer];
        _swapGhost.fillColor = UIColor.clearColor.CGColor;
        _swapGhost.lineWidth = 1.25;
        _swapGhost.lineCap = kCALineCapRound;
        _swapGhost.lineJoin = kCALineJoinRound;
        _swapGhost.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;
        _swapGhost.zPosition = 46.0;
        [root.layer addSublayer:_swapGhost];
    }
    BOOL slow = fabs(velocity.y) < 260.0 && fabs(velocity.x) < 340.0;
    DSStageContainerView *other = (card == _container) ? _topContainer : _container;
    BOOL show = NO;
    CGRect upper = CGRectZero;
    CGRect lower = CGRectZero;
    if (slow && _stackSlotCount >= kDSMaxStackSlots && other && !other.hidden && ![self cardIsParked:other]) {
        CGRect otherFrame = (other == _container) ? [self primaryCardFrameInRoot] : other.frame;
        BOOL movingIsUpper = CGRectGetMidY(frame) <= CGRectGetMidY(otherFrame);
        upper = movingIsUpper ? frame : otherFrame;
        lower = movingIsUpper ? otherFrame : frame;
        CGFloat pass = CGRectGetMaxY(upper) - CGRectGetMinY(lower);
        show = pass > -6.0 && pass < 36.0;
    }
    if (!show) {
        [_swapGhost removeAnimationForKey:@"pulse"];
        _swapGhost.opacity = 0.0;
        return;
    }
    CGFloat radius = [self stageCardCornerRadius];
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path appendPath:DSBottomHalfRim(CGRectInset(upper, -1.0, -1.0), radius + 1.0)];
    [path appendPath:DSTopHalfRim(CGRectInset(lower, -1.0, -1.0), radius + 1.0)];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _swapGhost.frame = root.bounds;
    _swapGhost.path = path.CGPath;
    _swapGhost.opacity = 0.7;
    [CATransaction commit];
    if (![_swapGhost animationForKey:@"pulse"]) {
        CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
        pulse.fromValue = @0.28;
        pulse.toValue = @0.62;
        pulse.duration = 0.7;
        pulse.autoreverses = YES;
        pulse.repeatCount = HUGE_VALF;
        [_swapGhost addAnimation:pulse forKey:@"pulse"];
    }
}

// The full rim stays put. While two cards swap, the upper card's bottom half
// and the lower card's top half brighten and pulse. Passing the cross, speeding
// up, or heading for a corner or Terminate stops it.
- (void)updateFacingRimPulseForCard:(DSStageContainerView *)card frame:(CGRect)frame velocity:(CGPoint)velocity towardCorner:(BOOL)towardCorner towardHome:(BOOL)towardHome {
    NSInteger shellHalf = 0;
    NSInteger topHalf = 0;
    BOOL slow = !towardCorner && !towardHome && fabs(velocity.y) < 260.0 && fabs(velocity.x) < 340.0;
    DSStageContainerView *other = (card == _container) ? _topContainer : _container;
    if (slow && other && [self dragFrame:frame wantsSwapForCard:card]) {
        CGRect otherFrame = (other == _container) ? [self primaryCardFrameInRoot] : other.frame;
        BOOL movingIsUpper = CGRectGetMidY(frame) <= CGRectGetMidY(otherFrame);
        CGRect upper = movingIsUpper ? frame : otherFrame;
        CGRect lower = movingIsUpper ? otherFrame : frame;
        CGFloat pass = CGRectGetMaxY(upper) - CGRectGetMinY(lower);
        if (pass > -20.0 && pass < 90.0) {
            DSStageContainerView *upperCard = movingIsUpper ? card : other;
            shellHalf = (upperCard == _container) ? 1 : 2;
            topHalf = (upperCard == _topContainer) ? 1 : 2;
        }
    }
    _dragShell.rimHalf = shellHalf;
    [self setTopRimHalf:topHalf];
}

- (void)clearFacingRimPulse {
    _dragShell.rimHalf = 0;
    [self setTopRimHalf:0];
}

// The third stage sits on top of whichever half it covers, and that half's
// facing edge lights so the grab belongs to the card in front.
- (void)pulseRimUnderFloatFrame:(CGRect)frame {
    NSInteger half = [self primaryHalfSnappedForCardFrame:frame];
    DSStageContainerView *under = [self containerOnHalf:half];
    NSInteger edge = (half == 1) ? 1 : 2;
    _dragShell.rimHalf = (under == _container) ? edge : 0;
    [self setTopRimHalf:(under == _topContainer) ? edge : 0];
}

- (void)updateSwapGhostVisible:(BOOL)visible {
    if (!visible) {
        _swapGlassTop.alpha = 0.0;
        _swapGlassBottom.alpha = 0.0;
        if (_swapGhost) _swapGhost.opacity = 0.0;
    }
}

- (void)updateDragGhostForFrame:(CGRect)frame red:(BOOL)red visible:(BOOL)visible {
    UIView *root = _window.rootViewController.view;
    if (!_dragGhost) {
        _dragGhost = [CAShapeLayer layer];
        _dragGhost.fillColor = UIColor.clearColor.CGColor;
        _dragGhost.lineWidth = 2.0;
        _dragGhost.lineCap = kCALineCapRound;
        _dragGhost.lineJoin = kCALineJoinRound;
        _dragGhost.shadowRadius = 8.0;
        _dragGhost.shadowOffset = CGSizeZero;
        [root.layer addSublayer:_dragGhost];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _dragGhost.frame = root.bounds;
    if (!visible) {
        _dragGhost.opacity = 0.0;
        _newStageGhostLabel.hidden = YES;
        [CATransaction commit];
        return;
    }
    CGFloat radius = CGRectGetHeight(frame) < 140.0 ? 18.0 : [self stageCardCornerRadius];
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:frame cornerRadius:radius];
    _dragGhost.path = path.CGPath;
    _dragGhost.lineWidth = 1.25;
    _dragGhost.shadowOpacity = 0.0;
    _dragGhost.zPosition = 45.0;
    _dragGhost.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;
    (void)red;
    _dragGhost.opacity = 1.0;
    [CATransaction commit];
}

- (void)finishDismissStage {
    _splitMode = NO;
    _splitHomeRevealed = NO;
    _expandedCard = nil;
    [self dismissFloatStageAnimated:NO terminate:NO];
    [self setTerminateHintVisible:NO];
    _dragShell.hidden = YES;
    _dragShell.alpha = 0.0;
    [_dragShell clearOutline];
    [self hideTopStageOutline];
    if (_topContainer) _topContainer.hidden = YES;
    if (_topRim) _topRim.hidden = YES;
    _primaryParked = NO;
    _secondParked = NO;
    _state = DSStageStateClosed;
    [self teardownStageApp];
    [self parkStashedHostsOntoCards];
    if (_primaryParked || _secondParked) {
        _state = DSStageStateMinimized;
        [self hideParkedCardsCompletely];
    }
    _dragShell.hidden = YES;
    _dragShell.alpha = 0.0;
    [self giveBackKeyWindow];
    [self updateOpenAppIcon];
    [self updateHomeAffordance];
    [self noteStageWindowIdle];
}

- (void)dismissStageCompletelyAnimated:(BOOL)animated {
    _splitMode = NO;
    _splitHomeRevealed = NO;
    _expandedCard = nil;
    [self dismissFloatStageAnimated:NO terminate:NO];
    [self setTerminateHintVisible:NO];
    void (^layout)(void) = ^{
        CGRect frame = [self offscreenCardFrame];
        frame.origin.y += CGRectGetHeight(frame) + 80.0;
        [self setPrimaryCardFrameInRoot:frame];
        self->_dragShell.alpha = 0.0;
        if (self->_topContainer) {
            self->_topContainer.alpha = 0.0;
            self->_topRim.alpha = 0.0;
        }
    };
    void (^finish)(void) = ^{
        self->_dragShell.hidden = YES;
        self->_dragShell.alpha = 0.0;
        if (self->_topContainer) self->_topContainer.hidden = YES;
        if (self->_topRim) self->_topRim.hidden = YES;
        self->_primaryParked = NO;
        self->_secondParked = NO;
        self->_state = DSStageStateClosed;
        [self teardownStageApp];
        [self parkStashedHostsOntoCards];
        if (self->_primaryParked || self->_secondParked) {
            self->_state = DSStageStateMinimized;
            [self hideParkedCardsCompletely];
        }
        self->_dragShell.hidden = YES;
        self->_dragShell.alpha = 0.0;
        [self giveBackKeyWindow];
        [self updateOpenAppIcon];
        [self updateHomeAffordance];
        [self noteStageWindowIdle];
    };
    if (animated) [self animateSpring:layout completion:finish];
    else { layout(); finish(); }
}

// The card floating above the split. Closing it does not close the two halves.
- (void)terminateFrontStageAnimated:(BOOL)animated {
    [self setTerminateHintVisible:NO];
    _keyboardFrame = CGRectZero;
    [_container setLiftOffset:0.0];
    if (_topContainer) [_topContainer setLiftOffset:0.0];
    if (_floatContainer) [_floatContainer setLiftOffset:0.0];
    DSStageContainerView *front = [self frontStageCard];
    if (!front) return;
    if (front == _floatContainer) {
        [self dismissFloatStageAnimated:animated terminate:YES];
        _frontCard = nil;
        return;
    }
    DSSceneHost *host = [self sceneHostForCard:front];
    _frontCard = nil;
    if (host.isHosting) {
        [self publishStageStateForBundleIdentifier:host.bundleIdentifier frame:CGRectZero active:NO];
        [host terminate];
        [self setSceneHost:nil forCard:front];
    }
    void (^hide)(void) = ^{
        front.alpha = 0.0;
        if (front == self->_container) self->_dragShell.alpha = 0.0;
        if (front == self->_topContainer) self->_topRim.alpha = 0.0;
    };
    void (^done)(void) = ^{
        front.hidden = YES;
        front.alpha = 0.0;
        if (front == self->_container) {
            self->_dragShell.hidden = YES;
            self->_dragShell.alpha = 0.0;
            [self->_dragShell clearOutline];
        }
        if (front == self->_topContainer) {
            self->_topRim.hidden = YES;
            self->_topRim.alpha = 0.0;
        }
        [self bringFloatAboveSplit];
    };
    if (animated) {
        [UIView animateWithDuration:0.28 animations:hide completion:^(BOOL finished) { done(); }];
    } else {
        hide();
        done();
    }
}

- (void)terminateDraggedCard:(DSStageContainerView *)card animated:(BOOL)animated {
    [self setTerminateHintVisible:NO];
    if (card == _floatContainer) {
        [self dismissFloatStageAnimated:animated terminate:YES];
        return;
    }
    if (_splitMode && [self visualHalfForCard:card] == 0) {
        [self leaveSplitSendingTopAppFullScreenFromBottomCard:card minimizeBottom:NO onLeft:NO animated:animated];
        return;
    }
    if (_splitMode) {
        _splitMode = NO;
        _expandedCard = nil;
        _splitHomeRevealed = NO;
    }
    DSSceneHost *host = [self sceneHostForCard:card];
    DSStageContainerView *other = (card == _container) ? _topContainer : (card == _topContainer ? _container : nil);
    BOOL otherStays = _stackSlotCount >= kDSMaxStackSlots && other && !other.hidden;
    if (!otherStays || !host.isHosting) {
        if (_stackSlotCount >= kDSMaxStackSlots && card == _topContainer && !host.isHosting) {
            [self dropEmptySecondCard];
            return;
        }
        if (_stackSlotCount >= kDSMaxStackSlots && card == _container && !host.isHosting &&
            (_topSceneHost.isHosting || _expandedCard == _topContainer)) {
            [self promoteSecondCardToPrimary];
            return;
        }
        if (_expandedCard && _expandedCard != card) {
            if (_expandedCard == _topContainer) [self promoteSecondCardToPrimary];
            else [self dropEmptySecondCard];
            return;
        }
        [self dismissStageCompletelyAnimated:animated];
        return;
    }
    [self publishStageStateForBundleIdentifier:host.bundleIdentifier frame:CGRectZero active:NO];
    [host terminate];
    [self setSceneHost:nil forCard:card];
    [card setLiftOffset:0.0];
    if (card == _topContainer) {
        [self dropEmptySecondCard];
    } else {
        [self promoteSecondCardToPrimary];
    }
    if (_dragShell.hidden) [_dragShell clearOutline];
    [self updateOpenAppIcon];
}

- (void)setSceneHost:(DSSceneHost *)host forCard:(DSStageContainerView *)card {
    if (card == _floatContainer) _floatSceneHost = host;
    else if (card == _topContainer) _topSceneHost = host;
    else _sceneHost = host;
}

- (void)placeFloatRim {
    if (!_floatRim || !_floatContainer) return;
    if (_floatContainer.superview) [_floatContainer.superview insertSubview:_floatRim belowSubview:_floatContainer];
    CGFloat band = kDSStageOuterDragBand + 18.0;
    CGRect cardFrame = [self frameWithoutKeyboardShift:_floatContainer];
    CGAffineTransform shift = CGAffineTransformMakeTranslation(_floatContainer.sideOffset, -_floatContainer.liftOffset);
    _floatRim.transform = CGAffineTransformIdentity;
    _floatRim.frame = CGRectInset(cardFrame, -band, -band);
    _floatRim.transform = shift;
    _floatRim.hidden = _floatContainer.hidden || !_floatActive;
    CGFloat radius = _floatContainer.cornerRadius + 1.0;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    DSFitRimBorder(_floatRimLayer, _floatRim.bounds, band, radius);
    [CATransaction commit];
}

- (DSStageContainerView *)frontStageCard {
    if (_frontCard && !_frontCard.hidden) return _frontCard;
    if (_floatActive && _floatContainer && !_floatContainer.hidden) return _floatContainer;
    return nil;
}

// Whoever is the card above the two stays above them. After a swap that is
// the split card that was traded, not the view that used to be the third stage.
- (void)bringFloatAboveSplit {
    if (_dragShell) _dragShell.layer.zPosition = 0.0;
    if (_container) _container.layer.zPosition = 0.0;
    if (_topContainer) _topContainer.layer.zPosition = 0.0;
    if (_topRim) _topRim.layer.zPosition = 0.0;
    if (_floatContainer) _floatContainer.layer.zPosition = 0.0;
    if (_floatRim) _floatRim.layer.zPosition = 0.0;
    DSStageContainerView *front = [self frontStageCard];
    if (!front) {
        [self bringShelfToFront];
        if (_shelf) _shelf.layer.zPosition = 40.0;
        return;
    }
    UIView *root = front.superview ?: _window.rootViewController.view;
    if (front == _container && _dragShell) {
        _dragShell.layer.zPosition = 31.0;
        if (_dragShell.superview) [_dragShell.superview bringSubviewToFront:_dragShell];
    } else         if ([_topRim isKindOfClass:DSStageRimHitView.class]) {
            ((DSStageRimHitView *)_topRim).hitBand = (front == _topContainer) ? 52.0 : (kDSStageOuterDragBand + 18.0);
        }
        if ([_floatRim isKindOfClass:DSStageRimHitView.class]) {
            ((DSStageRimHitView *)_floatRim).hitBand = (front == _floatContainer) ? 52.0 : (kDSStageOuterDragBand + 18.0);
        }
        if (front == _topContainer) {
            if (_topRim) _topRim.layer.zPosition = 30.0;
        _topContainer.layer.zPosition = 31.0;
        if (_topRim.superview) [_topRim.superview bringSubviewToFront:_topRim];
        if (root && _topContainer.superview == root) [root bringSubviewToFront:_topContainer];
    } else if (front == _floatContainer) {
        if (_floatRim) _floatRim.layer.zPosition = 30.0;
        _floatContainer.layer.zPosition = 31.0;
        if (_floatRim.superview) [_floatRim.superview bringSubviewToFront:_floatRim];
        if (root && _floatContainer.superview == root) [root bringSubviewToFront:_floatContainer];
    }
    [self bringShelfToFront];
    if (_shelf) _shelf.layer.zPosition = 40.0;
}

- (CGFloat)rimGrabBandForCard:(DSStageContainerView *)card {
    if (card && card == [self frontStageCard]) return 40.0;
    return kDSStageRimGrabBand;
}

- (BOOL)screenPointHitsFloatingStage:(CGPoint)point {
    DSStageContainerView *front = [self frontStageCard];
    if (!front) return NO;
    CGRect card = [self rootFrameOfCard:front];
    if (CGRectContainsPoint(CGRectInset(card, -40.0, -40.0), point)) return YES;
    if (front == _floatContainer && _floatRim && !_floatRim.hidden && CGRectContainsPoint(_floatRim.frame, point)) return YES;
    if (front == _topContainer && _topRim && !_topRim.hidden && CGRectContainsPoint(_topRim.frame, point)) return YES;
    return NO;
}

- (void)ensureFloatInfrastructure {
    if (_floatContainer) return;
    UIView *root = _window.rootViewController.view;
    _floatContainer = [[DSStageContainerView alloc] initWithFrame:CGRectZero];
    _floatContainer.hidden = YES;
    _floatContainer.cornerRadius = [self stageCardCornerRadius];
    _floatContainer.showsStackAddButton = NO;
    _floatContainer.showsMinimizeButton = NO;
    UIView *above = _topContainer ?: (UIView *)_dragShell;
    if (above.superview == root) [root insertSubview:_floatContainer aboveSubview:above];
    else [root addSubview:_floatContainer];

    _floatPicker = [[DSAppPickerViewController alloc] init];
    _floatPicker.delegate = self;
    [_window.rootViewController addChildViewController:_floatPicker];
    _floatPicker.view.frame = _floatContainer.contentView.bounds;
    _floatPicker.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_floatContainer.contentView addSubview:_floatPicker.view];
    [_floatPicker didMoveToParentViewController:_window.rootViewController];

    _floatDragPan = [[DSQuickPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleStagePan:)];
    _floatDragPan.cancelsTouchesInView = YES;
    _floatDragPan.delaysTouchesBegan = NO;
    _floatDragPan.delegate = self;
    [_floatContainer addGestureRecognizer:_floatDragPan];
    UITapGestureRecognizer *wake = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleCardWakeTap:)];
    wake.cancelsTouchesInView = NO;
    [_floatContainer addGestureRecognizer:wake];

    DSStageRimHitView *floatRim = [[DSStageRimHitView alloc] initWithFrame:CGRectZero];
    floatRim.hitBand = kDSStageOuterDragBand + 18.0;
    _floatRim = floatRim;
    _floatRim.backgroundColor = UIColor.clearColor;
    _floatRim.hidden = YES;
    _floatRimLayer = [CAShapeLayer layer];
    _floatRimLayer.fillColor = UIColor.clearColor.CGColor;
    _floatRimLayer.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;
    _floatRimLayer.lineWidth = 3.0;
    [_floatRim.layer addSublayer:_floatRimLayer];
    [root insertSubview:_floatRim belowSubview:_floatContainer];
    UIPanGestureRecognizer *rimPan = [[DSQuickPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleStagePan:)];
    rimPan.cancelsTouchesInView = YES;
    rimPan.delaysTouchesBegan = NO;
    rimPan.delegate = self;
    [_floatRim addGestureRecognizer:rimPan];
    [self bringShelfToFront];
}

- (void)refitHost:(DSSceneHost *)host onCard:(DSStageContainerView *)card {
    if (!host.isHosting || !card || card.hidden || [self cardIsParked:card]) return;
    if ([DSSceneHost sceneSettingsUpdateDepth] > 0) return;
    host.matchCardFrame = YES;
    CGRect frame = [self rootFrameOfCard:card];
    if (CGRectIsEmpty(frame)) return;
    BOOL sameSize = fabs(CGRectGetWidth(host.stageFrame) - CGRectGetWidth(frame)) < 0.5 &&
                    fabs(CGRectGetHeight(host.stageFrame) - CGRectGetHeight(frame)) < 0.5;
    BOOL sameOrigin = fabs(CGRectGetMinX(host.stageFrame) - CGRectGetMinX(frame)) < 0.5 &&
                      fabs(CGRectGetMinY(host.stageFrame) - CGRectGetMinY(frame)) < 0.5;
    if (!sameSize || !sameOrigin) {
        [host applyCardFrameQuietly:frame];
        return;
    }
    [host refitPresentedScene];
}

- (void)refitLiveStageHosts {
    [self refitHost:_sceneHost onCard:_container];
    [self refitHost:_topSceneHost onCard:_topContainer];
    [self refitHost:_floatSceneHost onCard:_floatContainer];
}

- (void)scheduleLiveStageRefit {
    __weak __typeof(self) weakSelf = self;
    for (NSNumber *delay in @[ @0.35, @0.8, @1.5 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakSelf refitLiveStageHosts];
        });
    }
}

- (void)resizeHostOnCard:(DSStageContainerView *)card toFrame:(CGRect)frame throttle:(BOOL)throttle {
    if (!card) return;
    if ([DSSceneHost sceneSettingsUpdateDepth] > 0) return;
    if (CGRectGetWidth(frame) < 80.0 || CGRectGetHeight(frame) < 80.0) return;
    [card layoutIfNeeded];
    DSAppPickerViewController *picker = [self pickerForCard:card];
    if (picker && !picker.view.hidden) picker.view.frame = card.contentView.bounds;
    DSSceneHost *host = [self sceneHostForCard:card];
    if (!host.isHosting) return;
    host.matchCardFrame = YES;
    if (throttle && fabs(CGRectGetHeight(frame) - _splitResizeHeight) < 8.0) {
        [host fitHostViewToCard];
        return;
    }
    _splitResizeHeight = CGRectGetHeight(frame);
    // A scene transaction on every few points of a drag is what blanked the
    // card and stacked up into a safe mode. Geometry only while the finger moves.
    [host applyCardFrameQuietly:frame];
}

// host in the log is this card's app view. Its superview is the card, so its
// frame is the card's content bounds, not a screen rect. Writing the screen
// rect would slide the app out of the card. The scene view is not resized.
- (void)matchHostAndOutlineToCard:(DSStageContainerView *)card {
    if (!card || card.hidden) return;
    [card layoutIfNeeded];
    DSSceneHost *sceneHost = [self sceneHostForCard:card];
    BOOL keyboardBand = card.keyboardBandHeight > 1.0 || sceneHost.keyboardClipHeight > 1.0;
    if (!keyboardBand) {
        card.contentView.frame = card.bounds;
        CALayer *mask = card.contentView.layer.mask;
        if (mask) mask.frame = card.contentView.bounds;
    }
    if (card == _container) {
        [_dragShell setOutlineLift:card.liftOffset];
        [_dragShell refreshOutline];
    } else if (card == _topContainer) {
        [self placeTopRimAroundCard:card];
    } else if (card == _floatContainer) {
        [self placeFloatRim];
    }
    if (!sceneHost.isHosting) return;
    UIView *hostView = sceneHost.hostView;
    UIView *content = card.contentView;
    if (!hostView || !content) return;
    if (hostView.superview != content) {
        [content insertSubview:hostView atIndex:0];
    }
    content.clipsToBounds = YES;
    if (keyboardBand || (sceneHost.contentScale > 0.0 && fabs(sceneHost.contentScale - 1.0) > 0.02)) {
        [sceneHost fitHostViewToCard];
        return;
    }
    // The picture is already the tall size. Fitting the host to the card
    // cuts that picture back down, and the new area is black.
    if (sceneHost.isRevealingTallContent) {
        [sceneHost fitHostViewToCard];
        return;
    }
    hostView.transform = CGAffineTransformIdentity;
    CGRect want = content.bounds;
    if (CGRectGetWidth(want) < 40.0 || CGRectGetHeight(want) < 40.0) return;
    if (!CGRectEqualToRect(hostView.frame, want)) hostView.frame = want;
    hostView.contentMode = UIViewContentModeRedraw;
    hostView.layer.needsDisplayOnBoundsChange = YES;
}

// The third stage's app must not stay inside the card that is growing.
// Leaving it there freezes that card's own picture.
- (void)detachFloatHostFromCard:(DSStageContainerView *)card {
    if (!_floatActive || !_floatSceneHost.hostView || !card) return;
    UIView *floatHost = _floatSceneHost.hostView;
    if (floatHost.superview != card.contentView && ![floatHost isDescendantOfView:card]) return;
    if (!_floatContainer || _floatContainer.hidden) return;
    [_floatContainer.contentView insertSubview:floatHost atIndex:0];
    [self matchHostAndOutlineToCard:_floatContainer];
    DSLogAppend(@"[GEOM-FIX] moved the float app back onto its own card");
}

// Split just opened. Seat each app in the card it belongs to before the
// first geometry line, or the top stage logs a zero host.
- (void)bindSplitStageHosts {
    if (!_splitMode) return;
    DSStageContainerView *top = [self cardOnHalf:1];
    DSStageContainerView *bottom = [self cardOnHalf:0];
    if (top && !top.hidden) {
        top.contentView.clipsToBounds = YES;
        [self matchHostAndOutlineToCard:top];
        [[self sceneHostForCard:top] markHostNeedsLiveRedraw];
    }
    if (bottom && !bottom.hidden) [self matchHostAndOutlineToCard:bottom];
    if (_floatActive && top) [self detachFloatHostFromCard:top];
}

// The bottom card is moving. The top card's app has to be laid out at the
// new height in the same pass, or the new area stays the card's background.
- (void)updateTopStageGeometry:(CGFloat)newHeight {
    DSStageContainerView *top = [self cardOnHalf:1];
    if (!top || top.hidden || newHeight < 80.0) return;
    if (_floatActive && _splitMode) [self detachFloatHostFromCard:top];
    [top layoutIfNeeded];
    top.contentView.clipsToBounds = YES;
    [self matchHostAndOutlineToCard:top];
    DSSceneHost *sceneHost = [self sceneHostForCard:top];
    [sceneHost markHostNeedsLiveRedraw];
    [top setNeedsLayout];
    [top layoutIfNeeded];
}

// The bottom card has crossed the line where the top card is nearly the
// screen. Finish the split instead of leaving a half-updated rim.
- (void)closeSplitPastCollapseLimit {
    if (_splitCollapseClosing || !_splitMode) return;
    _splitCollapseClosing = YES;
    DSLogAppend(@"[GEOM-FIX] Bottom split collapse threshold reached — closing split");
    DSStageContainerView *bottom = [self cardOnHalf:0];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        DSStageManager *manager = weakSelf;
        if (!manager || !manager->_splitMode) return;
        [manager leaveSplitSendingTopAppFullScreenFromBottomCard:bottom
                                                   minimizeBottom:NO
                                                           onLeft:NO
                                                         animated:YES];
        DSLogAppend(@"[GEOM-FIX] Split closed and geometry restored");
    });
}

// Tallest size the top card can reach while the bottom one is dragged down.
// The app is laid out at this size once. The card only uncovers it.
- (CGRect)tallFrameForTopSplitCard {
    CGRect pair = [self splitPairFrame:1];
    CGFloat screenH = CGRectGetHeight([self screenBounds]);
    CGFloat full = screenH - CGRectGetMinY(pair) - 4.0;
    CGFloat maxH = screenH - 20.0;
    if (full > maxH) full = maxH;
    if (full < CGRectGetHeight(pair)) full = CGRectGetHeight(pair);
    pair.size.height = full;
    return pair;
}

- (void)prepareTopSplitAppForUncover {
    if (_splitCollapseClosing || !_splitMode || _splitContentPrepared) return;
    DSStageContainerView *top = [self cardOnHalf:1];
    if (!top || top.hidden) return;
    DSSceneHost *host = [self sceneHostForCard:top];
    if (!host.isHosting) return;
    top.contentView.clipsToBounds = YES;
    CGRect tall = [self tallFrameForTopSplitCard];
    _splitContentPrepared = YES;
    [host beginRevealingTallContent:tall];
    // The scene can already be this tall while the app still lays out at the
    // half card. Messages reads this published size, not the scene frame.
    [self publishStageStateForBundleIdentifier:host.bundleIdentifier frame:tall active:YES];
    DSLogAppend([NSString stringWithFormat:@"[SCENE] uncover tallH=%.0f told %@ H=%.0f",
                                          CGRectGetHeight(tall),
                                          host.bundleIdentifier ?: @"?",
                                          CGRectGetHeight(tall)]);
}

- (void)stickTopSplitCardToBottomFrame:(CGRect)bottomFrame {
    if (!_splitMode || _splitCollapseClosing) return;
    DSStageContainerView *top = [self cardOnHalf:1];
    if (!top || top.hidden || top == _frontCard) return;
    CGRect pair = [self splitPairFrame:1];
    CGFloat gap = 2.0;
    CGFloat height = CGRectGetMinY(bottomFrame) - gap - CGRectGetMinY(pair);
    CGFloat screenH = CGRectGetHeight([self screenBounds]);
    CGFloat full = screenH - CGRectGetMinY(pair) - 4.0;
    // The card is the stage. It cannot grow taller than the screen.
    CGFloat maxH = screenH - 20.0;
    if (height < CGRectGetHeight(pair)) height = CGRectGetHeight(pair);
    if (height > maxH) height = maxH;
    if (height > full) height = full;
    CGRect grown = pair;
    grown.size.height = height;
    // Before the card grows, so a layout pass cannot tell the app the
    // in-between height. That in-between height is what stays on screen.
    [self prepareTopSplitAppForUncover];
    @try {
        [self placeCard:top atFrame:grown];
        top.cornerRadius = [self stageCardCornerRadius];
        [top layoutIfNeeded];
        // The app the log calls host lives in this card. The picture stays at
        // the tall size. The card clips it. The other split card is left alone.
        [self matchHostAndOutlineToCard:top];
        [self updateTopStageGeometry:height];
        [self keepSplitOutlinesOnTheirCards];
        [self noteStageGeometry:@"grow"];
        BOOL closing = CGRectGetMaxY(grown) > screenH - 80.0;
        DSSceneHost *host = [self sceneHostForCard:top];
        if (!closing && host.isHosting && height > CGRectGetHeight(pair) + 8.0) {
            [host adoptGrowingCardFrame:grown];
        }
        if (closing) [self closeSplitPastCollapseLimit];
    } @catch (NSException *exception) {
        DSCrashLogRemember([NSString stringWithFormat:@"split grow threw %@", exception.reason ?: @"?"]);
    }
    [self bringShelfToFront];
}

// The finger let go without sending the top app full screen. Put that app
// back at the split-half height. Leaving it tall makes the keyboard sit
// under the card.
- (void)restoreSplitContentAfterGrow {
    if (!_splitContentPrepared) return;
    _splitContentPrepared = NO;
    DSStageContainerView *top = [self cardOnHalf:1];
    DSSceneHost *host = [self sceneHostForCard:top];
    CGRect half = [self splitPairFrame:1];
    [host endRevealingTallContent:half];
    if (host.bundleIdentifier.length > 0) {
        [self publishStageStateForBundleIdentifier:host.bundleIdentifier frame:half active:YES];
    }
}

- (void)pressHomeButton {
    SpringBoard *springBoard = (SpringBoard *)UIApplication.sharedApplication;
    @try {
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
            ((void (*)(id, SEL))objc_msgSend)(target, selector);
            return;
        }
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: home button threw %@", exception.name ?: @"?");
    }
}

// Split sits on the Home Screen. The app that was in front is only in its card.
// Never write scene foreground around this. That write safe-modes SpringBoard.
- (void)showHomeScreenBehindSplit {
    if (!_splitMode || _splitHomeRevealed) return;
    _splitHomeRevealed = YES;
    [self giveBackKeyWindow];
    if (_sceneHost.isHosting && !_primaryParked) [self holdPictureOfCard:_container];
    if (_topSceneHost.isHosting && !_secondParked) [self holdPictureOfCard:_topContainer];
    [self pressHomeForSplitAttempt:0];
}

// The simulated Home button updates the staged scene. Doing that while a card
// resize is still being written is the SIGTRAP that safe-modes SpringBoard.
- (void)pressHomeForSplitAttempt:(NSInteger)attempt {
    if (!_splitMode) return;
    if (attempt < 8 && [DSSceneHost sceneSettingsUpdateDepth] > 0) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf pressHomeForSplitAttempt:attempt + 1];
        });
        return;
    }
    // Hold the app view's own settings update for the transition. Letting it
    // run is the assert.
    [DSSceneHost setHomeGestureActive:YES];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DSStageManager *manager = weakSelf;
        if (!manager || !manager->_splitMode) {
            [DSSceneHost setHomeGestureActive:NO];
            return;
        }
        [manager pressHomeButton];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            DSStageManager *later = weakSelf;
            if (!later || !later->_splitMode) {
                [DSSceneHost setHomeGestureActive:NO];
                return;
            }
            [later ejectHomeScreenFromStageWindow];
            [DSSceneHost setHomeGestureActive:NO];
            if (later->_sceneHost.isHosting && !later->_primaryParked) {
                [later->_sceneHost wakeIfBackgrounded];
                [later dropHeldPictureOnCard:later->_container];
            }
            if (later->_topSceneHost.isHosting && !later->_secondParked) {
                [later->_topSceneHost wakeIfBackgrounded];
                [later dropHeldPictureOnCard:later->_topContainer];
            }
        });
    });
}

// The app that just became the real full-screen app left an empty card behind.
// Restoring the minimized app was laying that empty card out as a picker.
- (void)moveParkedSecondCardOntoPrimaryWithoutLayout {
    if (!_topContainer || !_topSceneHost.isHosting) return;
    DSStageContainerView *empty = _container;
    DSAppPickerViewController *emptyPicker = _picker;
    UIPanGestureRecognizer *emptyPan = _dragPan;
    UIView *emptyPicture = _primaryParkPicture;

    _container = _topContainer;
    _picker = _topPicker;
    _dragPan = _topDragPan;
    _primaryParkPicture = _secondParkPicture;

    _topContainer = empty;
    _topPicker = emptyPicker;
    _topDragPan = emptyPan;
    _secondParkPicture = emptyPicture;

    _sceneHost = _topSceneHost;
    _topSceneHost = nil;
    _primaryHalf = _secondHalf;
    _minimizedHalf = _primaryHalf;
    _primaryMinimizedLeft = _secondMinimizedLeft;
    _primaryParked = YES;
    _secondParked = NO;

    _topContainer.hidden = YES;
    _topContainer.alpha = 0.0;
    _topContainer.hostingApp = NO;
    if (_topRim) {
        _topRim.hidden = YES;
        _topRim.alpha = 0.0;
    }
    _container.hidden = YES;
    _container.alpha = 0.0;
    if (_topPicker) [_topPicker dismissKeyboard];

    if (_dragShell) {
        if (_topContainer.superview == _dragShell) [_topContainer removeFromSuperview];
        if (_container.superview != _dragShell) {
            [_container removeFromSuperview];
            [_dragShell addSubview:_container];
        }
        _dragShell.cardView = _container;
        UIView *root = _dragShell.superview;
        if (root && _topContainer.superview != root) {
            [root insertSubview:_topContainer aboveSubview:_dragShell];
        }
        _dragShell.hidden = YES;
        _dragShell.alpha = 0.0;
    }
    [self seatStagePans];
}

// The shell pan stays on the shell, and each other card keeps the pan that was
// made for it. Calling this after a card swap puts them back.
- (void)seatStagePans {
    if (_dragPan && _dragShell && _dragPan.view != _dragShell) {
        [_dragPan.view removeGestureRecognizer:_dragPan];
        _dragPan.delegate = self;
        [_dragShell addGestureRecognizer:_dragPan];
    }
    if (_topDragPan && _topContainer && _topDragPan.view != _topContainer) {
        [_topDragPan.view removeGestureRecognizer:_topDragPan];
        _topDragPan.delegate = self;
        [_topContainer addGestureRecognizer:_topDragPan];
    }
    if (_floatDragPan && _floatContainer && _floatDragPan.view != _floatContainer) {
        [_floatDragPan.view removeGestureRecognizer:_floatDragPan];
        _floatDragPan.delegate = self;
        [_floatContainer addGestureRecognizer:_floatDragPan];
    }
}

- (void)keepOnlyTheParkedAppAfterSplit {
    BOOL primary = _primaryParked && _sceneHost.isHosting;
    BOOL second = _secondParked && _topSceneHost.isHosting;
    if (_floatActive && !_floatSceneHost.isHosting) {
        _floatActive = NO;
        _floatContainer.hidden = YES;
        _floatRim.hidden = YES;
    }
    if (second && !primary) {
        [self moveParkedSecondCardOntoPrimaryWithoutLayout];
        primary = _primaryParked && _sceneHost.isHosting;
        second = NO;
    }
    if (second && primary) return;
    _stackSlotCount = 1;
    _secondParked = NO;
    _topSceneHost = nil;
    if (_topContainer) {
        _topContainer.hidden = YES;
        _topContainer.alpha = 0.0;
        _topContainer.hostingApp = NO;
    }
    if (_topRim) {
        _topRim.hidden = YES;
        _topRim.alpha = 0.0;
    }
    if (_topPicker) [_topPicker dismissKeyboard];
    if (primary && _sceneHost.bundleIdentifier.length > 0) {
        DSDiagnosticsRecordFormat(@"SpringBoard: %@ is the only minimized app", _sceneHost.bundleIdentifier);
    }
}

- (BOOL)viewIsHomeScreenChrome:(UIView *)view {
    NSString *name = NSStringFromClass(object_getClass(view));
    if ([name rangeOfString:@"SBIcon"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"SBRootFolder"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"SBDock"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"SBHomeScreen"].location != NSNotFound) return YES;
    return NO;
}

// Pressing Home while the stage window is key drops the Home Screen into the
// stage. Put those views back on a SpringBoard window.
- (void)ejectHomeScreenFromView:(UIView *)view depth:(NSInteger)depth homeRoot:(UIView *)homeRoot {
    if (!view || depth > 8) return;
    for (UIView *subview in [view.subviews copy]) {
        if ([self viewIsHomeScreenChrome:subview]) {
            if (!homeRoot || [homeRoot isDescendantOfView:_window]) continue;
            if (subview.superview != homeRoot) [homeRoot addSubview:subview];
            DSDiagnosticsRecordFormat(@"SpringBoard: %@ was inside the stage and was put back on the Home Screen",
                                      NSStringFromClass(object_getClass(subview)));
            continue;
        }
        [self ejectHomeScreenFromView:subview depth:depth + 1 homeRoot:homeRoot];
    }
}

- (UIView *)homeScreenRootForEject {
    UIView *fallback = nil;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window == _window) continue;
        NSString *name = NSStringFromClass(object_getClass(window));
        if ([name rangeOfString:@"Keyboard"].location != NSNotFound ||
            [name rangeOfString:@"TextEffects"].location != NSNotFound) continue;
        UIView *root = window.rootViewController.view;
        if (!root) continue;
        BOOL home = [name rangeOfString:@"SBHome"].location != NSNotFound ||
                    [name rangeOfString:@"SpringBoard"].location != NSNotFound;
        if (home) return root;
        if (!fallback && !window.hidden) fallback = root;
    }
    return fallback;
}

- (void)ejectHomeScreenFromStageWindow {
    if (!_window) return;
    UIView *homeRoot = [self homeScreenRootForEject];
    // No home window to put them back on. Removing them blanks the Home Screen.
    if (!homeRoot) return;
    [self ejectHomeScreenFromView:_window depth:0 homeRoot:homeRoot];
}

- (void)hideStageChromeAfterSplitHandoffKeepingHost:(DSSceneHost *)keep {
    [self parkStashedHostsOntoCards];
    [self keepOnlyTheParkedAppAfterSplit];
    BOOL parked = _primaryParked || _secondParked;
    // Split is over. A third stage, the home screen behind the cards, and the
    // bottom-half layout do not follow the minimized app. The host that is
    // about to open full screen stays alive.
    _splitMode = NO;
    _splitHomeRevealed = NO;
    _splitResizeHeight = 0.0;
    _expandedCard = nil;
    if (_floatSceneHost && _floatSceneHost != keep) {
        [self dismissFloatStageAnimated:NO terminate:YES];
    } else {
        _floatContainer.hidden = YES;
        _floatContainer.alpha = 0.0;
        _floatRim.hidden = YES;
        _floatRim.alpha = 0.0;
        if (_floatSceneHost == keep) {
            _floatSceneHost = nil;
            _floatActive = NO;
        }
    }
    if (!(_primaryParked && _secondParked)) {
        _stackSlotCount = 1;
        _secondParked = NO;
        _secondHalf = 0;
        if (_primaryParked) {
            _primaryHalf = 1;
            _minimizedHalf = 1;
        }
    }
    if (_sceneHost) _sceneHost.matchCardFrame = NO;
    [self dropHeldPictureOnCard:_container];
    [self dropHeldPictureOnCard:_topContainer];
    if (!_primaryParked) {
        _dragShell.hidden = YES;
        _dragShell.alpha = 0.0;
    } else {
        _dragShell.hidden = YES;
        _dragShell.alpha = 0.0;
    }
    if (_topContainer) {
        _topContainer.hidden = YES;
        _topContainer.alpha = 0.0;
        _topContainer.hostingApp = _secondParked;
    }
    if (_topRim) {
        _topRim.hidden = YES;
        _topRim.alpha = 0.0;
    }
    _state = parked ? DSStageStateMinimized : DSStageStateClosed;
    [self ejectHomeScreenFromStageWindow];
    [self seatStagePans];
    [self giveBackKeyWindow];
    [self updateOpenAppIcon];
    [self updateHomeAffordance];
    [self refreshShelf];
    [self bringShelfToFront];
    if (!parked) [self noteStageWindowIdle];
}

// The bottom card leaves. The top app grows to the edges, then it is the real
// full-screen app, not a stage card. A minimized bottom app stays in its corner.
- (void)leaveSplitSendingTopAppFullScreenFromBottomCard:(DSStageContainerView *)bottomCard
                                         minimizeBottom:(BOOL)minimizeBottom
                                                 onLeft:(BOOL)onLeft
                                               animated:(BOOL)animated {
    DSStageContainerView *top = [self cardOnHalf:1];
    DSSceneHost *topHost = [self sceneHostForCard:top];
    DSSceneHost *bottomHost = [self sceneHostForCard:bottomCard];
    NSString *bundle = topHost.isHosting ? [topHost.bundleIdentifier copy] : nil;
    _splitMode = NO;
    _splitHomeRevealed = NO;
    _expandedCard = nil;
    _splitResizeHeight = 0.0;
    _splitContentPrepared = NO;

    if (minimizeBottom && bottomHost.isHosting && bottomCard) {
        if (bottomCard == _topContainer) _secondMinimizedLeft = onLeft;
        else _primaryMinimizedLeft = onLeft;
        if (![self rememberedPictureForCard:bottomCard]) [self rememberPictureForCard:bottomCard];
        [self setParked:YES forCard:bottomCard];
    }

    DSStageContainerView *third = [self frontStageCard];
    void (^layout)(void) = ^{
        if (top && top != bottomCard) {
            [self placeCard:top atFrame:[self screenBounds]];
            top.cornerRadius = [self displayCornerRadius];
            top.alpha = 1.0;
            if (top.superview) [top.superview bringSubviewToFront:top];
            if (top == self->_container && self->_dragShell.superview) {
                [self->_dragShell.superview bringSubviewToFront:self->_dragShell];
            }
            [top layoutIfNeeded];
            DSSceneHost *growing = [self sceneHostForCard:top];
            [growing stopRevealingTallContent];
            [growing fitHostViewToCard];
        }
        if (third && third != top && third != bottomCard) {
            third.alpha = 0.0;
            if (third == self->_container) self->_dragShell.alpha = 0.0;
            if (third == self->_floatContainer) self->_floatRim.alpha = 0.0;
            if (third == self->_topContainer) self->_topRim.alpha = 0.0;
        }
        if (bottomCard && bottomCard != top) {
            if (minimizeBottom) {
                [self placeCard:bottomCard atFrame:[self cornerParkFrameForCard:bottomCard]];
            }
            bottomCard.alpha = 0.0;
            if (bottomCard == self->_container) self->_dragShell.alpha = 0.0;
            if (bottomCard == self->_topContainer) self->_topRim.alpha = 0.0;
        }
    };
    void (^finish)(void) = ^{
        // The card above the two is the third stage, even after it swapped
        // views with a split half. It leaves when the split closes. The app
        // that grew to full screen stays.
        if (third && third != top && third != bottomCard) {
            if (third == self->_floatContainer) {
                [self dismissFloatStageAnimated:NO terminate:YES];
            } else {
                DSSceneHost *thirdHost = [self sceneHostForCard:third];
                if (thirdHost.isHosting) {
                    [self publishStageStateForBundleIdentifier:thirdHost.bundleIdentifier frame:CGRectZero active:NO];
                    [thirdHost terminate];
                    [self setSceneHost:nil forCard:third];
                }
                third.hidden = YES;
                third.alpha = 0.0;
            }
        } else if (top != self->_floatContainer) {
            [self dismissFloatStageAnimated:NO terminate:YES];
        }
        self->_frontCard = nil;
        self->_floatIsSplitCard = NO;
        if (topHost == self->_floatSceneHost) {
            self->_floatSceneHost = nil;
            self->_floatActive = NO;
        }
        if (!minimizeBottom && bottomHost.isHosting) {
            [self publishStageStateForBundleIdentifier:bottomHost.bundleIdentifier frame:CGRectZero active:NO];
            [bottomHost terminate];
            [self setSceneHost:nil forCard:bottomCard];
        }
        if (bundle.length == 0) {
            [self hideStageChromeAfterSplitHandoffKeepingHost:topHost];
            [self pressHomeButton];
            return;
        }
        // Tell the app it is off the stage before the scene grows, so the
        // screen hooks are already answering with the phone.
        [self publishStageStateForBundleIdentifier:bundle frame:CGRectZero active:NO];
        [topHost handOffAtFullScreen];
        if (topHost == self->_sceneHost) self->_sceneHost = nil;
        else if (topHost == self->_topSceneHost) self->_topSceneHost = nil;
        else if (topHost == self->_floatSceneHost) {
            self->_floatSceneHost = nil;
            self->_floatActive = NO;
        }
        [DSSceneHost noteFullScreenHandoffOfBundleIdentifier:bundle];
        [topHost relinquishKeepingBackgrounded:NO];
        [self hideStageChromeAfterSplitHandoffKeepingHost:topHost];
        // Not on this turn. The card animation is still finishing, and a
        // launch started inside that completion is a scene transition the
        // home swipe then interrupts.
        NSString *launchBundle = [bundle copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            DSLaunchFullScreenAppWhenIdle(launchBundle, 12);
        });
    };
    if (animated) {
        [UIView animateWithDuration:0.34
                              delay:0
                            options:UIViewAnimationOptionCurveEaseInOut
                         animations:layout
                         completion:^(BOOL finished) { finish(); }];
    } else {
        layout();
        finish();
    }
}

- (void)dismissFloatStageAnimated:(BOOL)animated terminate:(BOOL)terminate {
    if (!_floatContainer && !_floatSceneHost) {
        _floatActive = NO;
        return;
    }
    _floatActive = NO;
    if (_frontCard == _floatContainer) _frontCard = nil;
    _floatIsSplitCard = NO;
    DSSceneHost *host = _floatSceneHost;
    _floatSceneHost = nil;
    [_floatPicker dismissKeyboard];
    void (^hide)(void) = ^{
        self->_floatContainer.alpha = 0.0;
        self->_floatRim.alpha = 0.0;
    };
    void (^done)(void) = ^{
        self->_floatContainer.hidden = YES;
        self->_floatRim.hidden = YES;
        self->_floatContainer.alpha = 1.0;
        self->_floatRim.alpha = 1.0;
        [self->_floatContainer setSideOffset:0.0];
        [self->_floatContainer setLiftOffset:0.0];
        self->_floatRim.transform = CGAffineTransformIdentity;
        [self->_floatLaunchPlaceholder removeFromSuperview];
        self->_floatLaunchPlaceholder = nil;
        if (host) {
            [self publishStageStateForBundleIdentifier:host.bundleIdentifier frame:CGRectZero active:NO];
            if (terminate) [host terminate];
            else [host relinquishKeepingBackgrounded:[[DSPreferences sharedPreferences] backgroundsOnMinimize:host.bundleIdentifier]];
        } else {
            DSDiagnosticsRecord(@"SpringBoard: hovering picker closed");
        }
        [self bringShelfToFront];
    };
    if (animated && _floatContainer) {
        [UIView animateWithDuration:0.28 animations:hide completion:^(BOOL finished) { done(); }];
    } else {
        hide();
        done();
    }
}

- (void)presentHoverStageFromPoint:(CGPoint)point {
    if (!_splitMode || _floatActive) return;
    [self ensureFloatInfrastructure];
    _presentGeneration += 1;
    NSInteger generation = _presentGeneration;
    _searchSlot = -1;
    [_floatPicker dismissKeyboard];
    _floatActive = YES;
    [self presentPickerOnCard:_floatContainer picker:_floatPicker];
    [_floatPicker resetScrollPosition];
    _floatContainer.hidden = NO;
    _floatContainer.alpha = 1.0;
    _floatRim.hidden = NO;
    _floatRim.alpha = 1.0;
    [_floatContainer setLiftOffset:0.0];
    [_floatContainer setSideOffset:0.0];
    _floatRim.transform = CGAffineTransformIdentity;
    [UIView performWithoutAnimation:^{
        [self placeCard:_floatContainer atFrame:[self seedFrameAtPoint:point]];
        self->_floatContainer.cornerRadius = 26.0;
    }];
    [self bringFloatAboveSplit];
    _overlaySettling = YES;
    _floatRest = 0;
    _frontCard = _floatContainer;
    _floatIsSplitCard = NO;
    _splitMiddleCard = nil;
    CGRect target = [self floatCardCenteredFrame];
    (void)point;
    [self animateSpring:^{
        [self placeCard:self->_floatContainer atFrame:target];
        self->_floatContainer.cornerRadius = [self stageCardCornerRadius];
        self->_floatContainer.alpha = 1.0;
    } completion:^{
        [self bringFloatAboveSplit];
        [self finishFingerStagePresentation:generation];
    }];
    DSDiagnosticsRecord(@"SpringBoard: opened a hovering stage over the split");
}

// The rim and the shell outside the card drag the stage. A touch inside the
// card belongs to the app (or the picker). The pan was on the shell with
// cancelsTouchesInView, so every touch in Messages dragged the card.
- (DSStageContainerView *)cardForStagePan:(UIGestureRecognizer *)recognizer {
    UIView *view = recognizer.view;
    if (view == _dragShell) return _dragShell.cardView ?: _container;
    if (view == _topRim) return _topContainer;
    if (view == _floatRim) return _floatContainer;
    if ([view isKindOfClass:DSStageContainerView.class]) return (DSStageContainerView *)view;
    return nil;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (![gestureRecognizer isKindOfClass:UIPanGestureRecognizer.class]) return YES;
    DSStageContainerView *card = [self cardForStagePan:gestureRecognizer];
    if (!card || card.hidden) return YES;
    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gestureRecognizer;
    DSStageContainerView *front = [self frontStageCard];
    if (front && card != front && [self screenPointHitsFloatingStage:[pan locationInView:nil]]) return NO;
    CGPoint location = [pan locationInView:card];
    CGRect interior = CGRectInset(card.bounds, [self rimGrabBandForCard:card], [self rimGrabBandForCard:card]);
    // A grab on the rim moves the card, including a vertical one. The picker
    // only keeps the drag when the finger started inside the rows.
    if (card.hostingApp || !CGRectContainsPoint(interior, location)) return YES;
    CGPoint velocity = [pan velocityInView:pan.view];
    if (fabs(velocity.y) > fabs(velocity.x) && fabs(velocity.y) > 30.0) {
        DSLog("[EDGE] vertical scroll on the picker, the rim stays out");
        return NO;
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    DSStageContainerView *card = [self cardForStagePan:recognizer];
    if (!card || card.hidden) return YES;
    CGPoint screenPoint = [touch locationInView:nil];
    DSStageContainerView *front = [self frontStageCard];
    if (front && card != front && [self screenPointHitsFloatingStage:screenPoint]) return NO;
    CGPoint point = [touch locationInView:card];
    CGRect interior = CGRectInset(card.bounds, [self rimGrabBandForCard:card], [self rimGrabBandForCard:card]);
    if (CGRectGetWidth(interior) < 40.0 || CGRectGetHeight(interior) < 40.0) return YES;
    // Inside the card the app or the picker gets the touch. The rim is the
    // band around that, on every card, including one just opened.
    return !CGRectContainsPoint(interior, point);
}

- (void)handleStagePan:(UIPanGestureRecognizer *)recognizer {
    static BOOL dragging = NO;
    static CGPoint grabFraction = {0.5, 0.5};
    static CGPoint parkBias = {0, 0};
    static NSInteger halfAtDragStart = 1;
    static CGPoint dragStartScreen = {0, 0};
    static BOOL exitSwipe = NO;
    static BOOL exitFromLeft = NO;

    DSStageContainerView *card = _container;
    if (recognizer.view == _floatRim || recognizer.view == _floatContainer) card = _floatContainer;
    else if (recognizer.view == _topRim) card = _topContainer;
    else if ([recognizer.view isKindOfClass:DSStageContainerView.class]) {
        card = (DSStageContainerView *)recognizer.view;
    }

    CGPoint translation = [recognizer translationInView:_window];
    CGPoint screenPoint = [recognizer locationInView:nil];
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        DSLog("[TOUCH] screenY=%.0f %@", screenPoint.y, screenPoint.y > 466.0 ? @"bottom-half" : @"top-half");
    }
    DSStageState layoutState = DSStageStateOverlay;
    CGRect screen = [self screenBounds];

    CGRect (^cardFrame)(void) = ^{
        if (card == _container) return [self primaryCardFrameInRoot];
        return [self frameWithoutKeyboardShift:card];
    };
    void (^moveCard)(CGRect) = ^(CGRect frame) {
        if (card == _container) [self setPrimaryCardFrameInRoot:frame];
        else [self assignFrame:frame toCard:card];
    };
    // The keyboard lift is baked into the frame so the card stays under the
    // finger. Swap and half tests use the frame without that bake, or a card
    // that was only sitting above the keys counts as a swap.
    CGRect (^withoutPark)(CGRect) = ^(CGRect frame) {
        frame.origin.x -= parkBias.x;
        frame.origin.y -= parkBias.y;
        return frame;
    };

    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan: {
            dragging = NO;
            _stageDragActive = NO;
            parkBias = CGPointZero;
            dragStartScreen = screenPoint;
            if ([self pointIsPhoneRightCorner:screenPoint] || [self pointIsHomeBar:screenPoint]) break;
            // cardFrame is the resting rect. The finger is on the card as it
            // sits, after a keyboard lift or a slide off the side. Measuring
            // the grab once that shift is gone hangs the card from the top of
            // the finger, so a drop lands centred and a little high.
            CGRect seen = cardFrame();
            seen.origin.x += card.sideOffset;
            seen.origin.y -= card.liftOffset;
            CGPoint seenBias = CGPointMake(card.sideOffset, -card.liftOffset);
            BOOL slidOff = fabs(card.sideOffset) > 0.5 || fabs(card.liftOffset) > 0.5;
            CGFloat seenSlop = kDSStageOuterDragBand + 18.0;
            BOOL fingerOnSeen = CGRectContainsPoint(CGRectInset(seen, -seenSlop, -seenSlop), screenPoint);
            [self dropHeldPictureOnCard:card];
            [_picker dismissKeyboard];
            if (_topPicker) [_topPicker dismissKeyboard];
            [_container setLiftOffset:0.0];
            if (_topContainer) [_topContainer setLiftOffset:0.0];
            if (_floatContainer) [_floatContainer setLiftOffset:0.0];

            BOOL onCard = NO;
            if (recognizer.view == _dragShell && card == _container) {
                CGPoint inShell = [recognizer locationInView:_dragShell];
                onCard = CGRectContainsPoint(_dragShell.bounds, inShell);
            } else if (recognizer.view == _topRim || recognizer.view == _floatRim) {
                UIView *rim = recognizer.view;
                onCard = CGRectContainsPoint(rim.bounds, [recognizer locationInView:rim]);
            } else {
                CGPoint inCard = [recognizer locationInView:card];
                onCard = CGRectContainsPoint(card.bounds, inCard);
            }
            if (!onCard) break;
            DSStageContainerView *front = [self frontStageCard];
            if (front && card != front && [self screenPointHitsFloatingStage:screenPoint]) break;
            CGPoint rimPoint = [recognizer locationInView:card];
            CGFloat grabBand = [self rimGrabBandForCard:card];
            CGRect rimInterior = CGRectInset(card.bounds, grabBand, grabBand);
            if (CGRectGetWidth(rimInterior) >= 40.0 && CGRectGetHeight(rimInterior) >= 40.0 &&
                CGRectContainsPoint(rimInterior, rimPoint)) {
                break;
            }
            dragging = YES;
            _stageDragActive = YES;
            [self bringCardAboveItsPartner:card];
            CGRect startFrame = (slidOff && fingerOnSeen) ? seen : cardFrame();
            if (startFrame.size.width > 1.0 && startFrame.size.height > 1.0) {
                grabFraction.x = (screenPoint.x - startFrame.origin.x) / startFrame.size.width;
                grabFraction.y = (screenPoint.y - startFrame.origin.y) / startFrame.size.height;
            } else {
                grabFraction = CGPointMake(0.5, 0.5);
            }
            grabFraction.x = MIN(MAX(grabFraction.x, 0.05), 0.95);
            grabFraction.y = MIN(MAX(grabFraction.y, 0.05), 0.95);
            // Drop the sideways slide once the grab is known. Leaving it on
            // keeps the app about a card-width left of the shell that follows
            // the finger. A card that was lifted or slid stays under the finger.
            [self clearKeyboardSideShift];
            if (slidOff && fingerOnSeen && seen.size.width > 1.0 && seen.size.height > 1.0) {
                parkBias = seenBias;
                CGRect held = seen;
                held.origin.x = screenPoint.x - grabFraction.x * CGRectGetWidth(held);
                held.origin.y = screenPoint.y - grabFraction.y * CGRectGetHeight(held);
                [UIView performWithoutAnimation:^{
                    moveCard(held);
                    if (card == self->_topContainer) [self placeTopRimAroundCard:card];
                    if (card == self->_floatContainer) [self placeFloatRim];
                    [self->_dragShell refreshOutline];
                }];
            }
            NSInteger visualHalf = [self visualHalfForCard:card];
            halfAtDragStart = visualHalf == 0 ? 0 : 1;
            if (_splitMode && visualHalf == 0) {
                DSStageContainerView *top = [self cardOnHalf:1];
                _splitResizeHeight = top ? CGRectGetHeight([self rootFrameOfCard:top]) : 0.0;
                // Lay the top app out at the tall size before the card grows,
                // so the new area is already drawn when the finger uncovers it.
                [self prepareTopSplitAppForUncover];
            }
            if (card.hostingApp) {
                [self stopDragMotionForCard:card];
                [self freezeHostedContentsForDrag:card];
            }
            exitSwipe = NO;
            DSSceneHost *host = [self sceneHostForCard:card];
            CGPoint inCard = [recognizer locationInView:card];
            BOOL fromLeft = NO;
            if (host.isHosting && [self touch:inCard isBottomCornerOfCard:card fromLeft:&fromLeft]) {
                exitSwipe = YES;
                exitFromLeft = fromLeft;
            }
            break;
        }
        case UIGestureRecognizerStateChanged: {
            if (!dragging || _splitCollapseClosing) break;
            [self bringCardAboveItsPartner:card];
            if (exitSwipe) {
                CGPoint velocity = [recognizer velocityInView:nil];
                BOOL inward = [self gestureIsDiagonalInwardFromLeft:exitFromLeft translation:translation velocity:velocity];
                BOOL downward = translation.y > 16.0 && fabs(translation.x) < fabs(translation.y);
                if (inward || !downward) break;
                exitSwipe = NO;
            }
            if (dragStartScreen.x > CGRectGetWidth(screen) - 44.0 &&
                [self gestureMovesLeftAlongTheBottom:translation velocity:[recognizer velocityInView:nil]]) {
                dragging = NO;
                _stageDragActive = NO;
                [self clearDragTileOnCard:card];
                [self setTerminateHintVisible:NO];
                [self updateSwapGhostVisible:NO];
                [self clearFacingRimPulse];
                [self updateDragGhostForFrame:CGRectZero red:NO visible:NO];
                [_dragShell setGhostRed:NO];
                [self discardRememberedPictureForCard:card];
                [self restoreSplitContentAfterGrow];
                [self snapBackToLayoutForState:layoutState];
                break;
            }
            [self clearDragTileOnCard:card];
            // The card keeps the rim's size while it moves. A drag that started
            // from a stretched bottom stage used to keep that other size.
            DSStageContainerView *frontCard = [self frontStageCard];
            BOOL draggingFront = frontCard && card == frontCard;
            CGSize full = [self fixedHalfFrame:halfAtDragStart].size;
            if (draggingFront) full = [self frameForFloatRest:_floatRest].size;
            else if (_splitMode) full = [self splitPairFrame:halfAtDragStart == 1 ? 1 : 0].size;
            CGRect fullFrame = CGRectMake(screenPoint.x - grabFraction.x * full.width,
                                          screenPoint.y - grabFraction.y * full.height,
                                          full.width, full.height);
            CGPoint center = CGPointMake(CGRectGetMidX(fullFrame), CGRectGetMidY(fullFrame));
            CGRect sensor = fullFrame;
            CGPoint moveVelocity = [recognizer velocityInView:nil];
            BOOL flickLeft = NO;
            BOOL flickCorner = [self velocityIsQuickCornerSwipe:moveVelocity onLeft:&flickLeft];
            CGFloat approach = [self cornerApproachForCardFrame:fullFrame finger:screenPoint];
            CGFloat terminateApproach = flickCorner ? 0.0 : [self terminateApproachForCardFrame:fullFrame finger:screenPoint];
            CGFloat width = CGRectGetWidth(screen);
            CGFloat height = CGRectGetHeight(screen);
            BOOL left = center.x < width * 0.5;
            CGRect cornerHint = CGRectMake(left ? 14.0 : width - 14.0 - 92.0,
                                           height - 18.0 - 64.0,
                                           92.0, 64.0);
            CGRect terminateHint = [self terminateHintRect];
            BOOL towardCorner = flickCorner || approach > 0.0 || (moveVelocity.y > 40.0 && fabs(moveVelocity.x) > 70.0);
            BOOL towardHome = terminateApproach > 0.04;
            (void)towardCorner;
            (void)towardHome;
            (void)moveVelocity;
            CGRect frame = fullFrame;
            (void)sensor;
            BOOL draggingBottomSplit = _splitMode && !draggingFront && [self visualHalfForCard:card] == 0;
            if (draggingBottomSplit) {
                CGRect home = [self splitPairFrame:0];
                frame.origin.x = home.origin.x;
                frame.size = home.size;
                flickCorner = NO;
                approach = 0.0;
                CGFloat screenH = CGRectGetHeight(screen);
                if (CGRectGetMaxY(frame) > screenH - 36.0) terminateApproach = MAX(terminateApproach, 0.7);
            }
            BOOL showGhost = NO;
            [self updateSwapGhostVisible:NO];
            if (_splitMode || card == _floatContainer) {
                [self clearFacingRimPulse];
            } else {
                [self updateFacingRimPulseForCard:card frame:frame velocity:moveVelocity towardCorner:(flickCorner || approach > 0.0) towardHome:towardHome];
            }
            // The card stays full size while it moves. Shrinking it toward a
            // corner is what left it stuck half off the screen.
            (void)cornerHint;
            if (draggingFront && approach <= 0.0 && terminateApproach < 0.2) {
                NSInteger swapHalf = 0;
                NSInteger preview = [self floatRestForFrame:withoutPark(fullFrame) swapHalf:&swapHalf];
                frame = fullFrame;
                if (preview < 0) {
                    CGFloat direction = CGRectGetMidX(withoutPark(fullFrame)) < CGRectGetWidth(screen) * 0.5 ? -1.0 : 1.0;
                    frame.origin.x += direction * 22.0;
                    [self previewSwapOfHalf:swapHalf direction:direction];
                } else {
                    [self clearSwapPreview];
                }
                [self pulseRimUnderFloatFrame:fullFrame];
                [self bringFloatAboveSplit];
            }
            (void)terminateHint;
            if (!card.hostingApp) {
                card.backgroundColor = [UIColor colorWithWhite:0.11 alpha:1.0];
                [card setBackdropHidden:NO];
            }
            BOOL splitSwap = _splitMode && !draggingFront && terminateApproach < 0.2 &&
                [self dragFrame:withoutPark(frame) wantsSwapForCard:card];
            if (splitSwap) {
                CGFloat toward = CGRectGetMidY(frame) < CGRectGetMidY(screen) ? 1.0 : -1.0;
                frame.origin.y += toward * 16.0;
                NSInteger otherHalf = [self visualHalfForCard:card] == 0 ? 1 : 0;
                DSStageContainerView *other = [self cardOnHalf:otherHalf];
                if (other && other != frontCard && !other.hidden) {
                    CGRect otherHome = [self splitPairFrame:otherHalf];
                    otherHome.origin.y -= toward * 16.0;
                    [self placeCard:other atFrame:otherHome];
                }
            }
            CGFloat bottomHome = CGRectGetMinY([self splitPairFrame:0]);
            BOOL growTop = _splitMode && !draggingFront && [self visualHalfForCard:card] == 0 &&
                CGRectGetMinY(frame) > bottomHome + 6.0;
            if (growTop && frontCard) {
                frontCard.alpha = 1.0 - terminateApproach;
                if (frontCard == _floatContainer) _floatRim.alpha = 1.0 - terminateApproach;
                if (frontCard == _topContainer) _topRim.alpha = 1.0 - terminateApproach;
                if (frontCard == _container) _dragShell.alpha = 1.0 - terminateApproach;
            } else if (_floatActive && frontCard && frontCard.alpha < 0.99) {
                frontCard.alpha = 1.0;
                if (frontCard == _floatContainer) _floatRim.alpha = 1.0;
                if (frontCard == _topContainer) _topRim.alpha = 1.0;
                if (frontCard == _container) _dragShell.alpha = 1.0;
            }
            [UIView performWithoutAnimation:^{
                moveCard(frame);
                if (card == _topContainer) [self placeTopRimAroundCard:card];
                if (card == _floatContainer) [self placeFloatRim];
                if (growTop) [self stickTopSplitCardToBottomFrame:frame];
                [self->_dragShell refreshOutline];
                CGFloat restingRadius = [self cornerRadiusForState:DSStageStateOverlay];
                card.cornerRadius = restingRadius + (16.0 - restingRadius) * approach;
            }];
            [self updateDragGhostForFrame:CGRectZero red:NO visible:showGhost];
            [self setTerminateHintAmount:terminateApproach];
            [self refreshSystemStatusBar];
            if (_floatActive && !growTop) [self bringFloatAboveSplit];
            break;
        }
        case UIGestureRecognizerStateEnded: {
            _stageDragActive = NO;
            if (dragging && exitSwipe) {
                CGPoint velocity = [recognizer velocityInView:nil];
                BOOL inward = [self gestureIsDiagonalInwardFromLeft:exitFromLeft translation:translation velocity:velocity];
                exitSwipe = NO;
                dragging = NO;
                [self clearFacingRimPulse];
                [self discardRememberedPictureForCard:card];
                if (inward && hypot(translation.x, translation.y) > 16.0) {
                    NSInteger slot = 0;
                    if (card == _floatContainer) slot = 2;
                    else if (card == _topContainer) slot = 1;
                    [self exitToPickerAnimated:YES slot:slot];
                }
                break;
            }
            exitSwipe = NO;
            if (dragging && _splitCollapseClosing) {
                [self setTerminateHintVisible:NO];
                [self updateDragGhostForFrame:CGRectZero red:NO visible:NO];
                [_dragShell setGhostRed:NO];
                _splitCollapseClosing = NO;
                dragging = NO;
                break;
            }
            if (dragging) {
                [self clearDragTileOnCard:card];
                CGRect now = cardFrame();
                CGPoint velocity = [recognizer velocityInView:_window];
                CGRect sensor = now;
                BOOL flickLeft = NO;
                BOOL flickCorner = [self velocityIsQuickCornerSwipe:velocity onLeft:&flickLeft];
                CGFloat approach = [self cornerApproachForCardFrame:now finger:screenPoint];
                CGFloat terminateApproach = flickCorner ? 0.0 : [self terminateApproachForCardFrame:now finger:screenPoint];
                // 0.90 only became true inside the home indicator, and that
                // indicator was taking the touch, so the middle of the bottom
                // edge stopped terminating.
                DSStageContainerView *frontCard = [self frontStageCard];
                BOOL draggingFront = frontCard && card == frontCard;
                BOOL terminate = !flickCorner && approach <= 0.0 && terminateApproach >= 0.55;
                BOOL swapping = !flickCorner && approach <= 0.0 && !terminate && [self dragFrame:withoutPark(now) wantsSwapForCard:card];
                if (draggingFront) swapping = NO;
                // The card in front is the third stage. Dragging it into the
                // terminate band closes that stage. The two split cards stay.
                BOOL draggingBottomSplit = _splitMode && !draggingFront && [self visualHalfForCard:card] == 0;
                if (draggingBottomSplit) {
                    flickCorner = NO;
                    approach = 0.0;
                }
                if (_splitMode && !draggingFront && [self visualHalfForCard:card] != 0) terminate = NO;
                if (!(terminate && draggingBottomSplit)) [self restoreSplitContentAfterGrow];
                [self setTerminateHintVisible:NO];
                [self updateSwapGhostVisible:NO];
                [self clearFacingRimPulse];
                [self updateDragGhostForFrame:CGRectZero red:NO visible:NO];
                [_dragShell setGhostRed:NO];
                if (draggingFront && terminate) {
                    [self discardRememberedPictureForCard:card];
                    [self terminateFrontStageAnimated:YES];
                } else if (draggingFront && !(flickCorner || approach > 0.0)) {
                    [self clearSwapPreview];
                    NSInteger swapHalf = 0;
                    NSInteger rest = [self floatRestForFrame:withoutPark(now) swapHalf:&swapHalf];
                    if (rest < 0) {
                        [self swapFloatWithSplitHalf:swapHalf];
                    } else {
                        self->_floatRest = rest;
                        if (rest == 0) self->_splitMiddleCard = nil;
                        CGRect parked = [self frameForFloatRest:rest];
                        [self animateSpring:^{
                            [self placeCard:card atFrame:parked];
                            if (card == self->_floatContainer) [self placeFloatRim];
                            if (card == self->_topContainer) [self placeTopRimAroundCard:card];
                            if (rest == 0) [self layoutAllStackSlotsForState:DSStageStateOverlay];
                        } completion:^{
                            [self resizeHostOnCard:card toFrame:parked throttle:NO];
                            [self discardRememberedPictureForCard:card];
                            [self bringFloatAboveSplit];
                        }];
                    }
                } else if ((flickCorner || approach > 0.0) && !_splitMode && !_floatActive && !draggingFront) {
                    BOOL onLeft = flickCorner ? flickLeft : screenPoint.x < CGRectGetWidth(screen) * 0.5;
                    if (!flickCorner && fabs(velocity.x) > 500.0) onLeft = velocity.x < 0.0;
                    // A fast flick is already at the corner. Another ease-in
                    // leaves the icon catching up after the card has parked.
                    CGFloat speed = hypot(velocity.x, velocity.y);
                    BOOL snap = flickCorner || (approach > 0.0 && speed > 900.0);
                    if (snap) [self stopMinimizedMotionForCard:card];
                    [self minimizeDraggedCard:card fromHalf:halfAtDragStart onLeft:onLeft animated:!snap];
                } else if (terminate) {
                    [self discardRememberedPictureForCard:card];
                    [self terminateDraggedCard:card animated:YES];
                } else if (swapping) {
                    [self discardRememberedPictureForCard:card];
                    [self swapStackHalvesAnimated:YES];
                } else if ([self onScreenCardCanTakeEitherHalf:card]) {
                    NSInteger visualHalf = [self primaryHalfSnappedForCardFrame:withoutPark(sensor)];
                    [self seatCard:card onHalf:visualHalf leavingTheOtherHalfFree:YES];
                    [self discardRememberedPictureForCard:card];
                    [self snapBackToLayoutForState:layoutState];
                    [self restoreCardStackingOrder];
                } else if (_stackSlotCount <= 1 && card == _container) {
                    // One card stays primary. The drop only chooses which half
                    // the card is drawn on. It does not clear half/primary.
                    [self classifySlotForBundle:_sceneHost.bundleIdentifier ?: @"" slot:0];
                    NSInteger visualHalf = [self primaryHalfSnappedForCardFrame:withoutPark(sensor)];
                    _primaryHalf = visualHalf;
                    CGRect parked = [self fixedHalfFrame:visualHalf];
                    [self discardRememberedPictureForCard:card];
                    [self animateSpring:^{
                        [self placeCard:card atFrame:parked];
                    } completion:^{
                        DSLiftSlotAt(0)->hasRestingFrame = NO;
                        [self captureKeyboardBaseForSlot:0];
                        [self refreshShelf];
                    }];
                } else {
                    [self discardRememberedPictureForCard:card];
                    [self snapBackToLayoutForState:layoutState];
                    [self restoreCardStackingOrder];
                }
            }
            dragging = NO;
            // The drag cleared the keyboard slide so the card could follow the
            // finger. Put that slide back now that the layout animation has
            // already been committed, or the other stage stays on screen.
            if (!CGRectIsEmpty(_keyboardFrame)) {
                NSString *bundle = [self hostedBundleForKeyboardNotifications];
                if (bundle.length > 0) {
                    [self noteKeyboardFrame:_keyboardFrame source:bundle duration:0.0];
                }
            }
            break;
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed: {
            _stageDragActive = NO;
            exitSwipe = NO;
            if (_splitCollapseClosing) {
                [self setTerminateHintVisible:NO];
                [self updateDragGhostForFrame:CGRectZero red:NO visible:NO];
                [_dragShell setGhostRed:NO];
                _splitCollapseClosing = NO;
                dragging = NO;
                break;
            }
            CGPoint finger = [recognizer locationInView:nil];
            CGFloat terminateApproach = [self terminateApproachForCardFrame:cardFrame() finger:finger];
            BOOL wasDragging = dragging;
            [self clearDragTileOnCard:card];
            [self setTerminateHintVisible:NO];
            [self updateSwapGhostVisible:NO];
            [self clearFacingRimPulse];
            [self updateDragGhostForFrame:CGRectZero red:NO visible:NO];
            [_dragShell setGhostRed:NO];
            DSStageContainerView *frontCard = [self frontStageCard];
            BOOL draggingFront = frontCard && card == frontCard;
            BOOL draggingBottomSplit = _splitMode && !draggingFront && [self visualHalfForCard:card] == 0;
            if (wasDragging && terminateApproach >= 0.55 && draggingBottomSplit) {
                // The home gesture took the touch as it crossed the indicator.
                // The finger was already in the terminate band, so finish that.
                // The top app stays at the tall size; closing the split opens it.
                [self discardRememberedPictureForCard:card];
                [self terminateDraggedCard:card animated:YES];
            } else if (wasDragging && terminateApproach >= 0.55) {
                [self restoreSplitContentAfterGrow];
                [self discardRememberedPictureForCard:card];
                [self terminateDraggedCard:card animated:YES];
            } else if (wasDragging) {
                [self restoreSplitContentAfterGrow];
                [self discardRememberedPictureForCard:card];
                [self snapBackToLayoutForState:layoutState];
            } else {
                [self restoreSplitContentAfterGrow];
            }
            dragging = NO;
            if (!CGRectIsEmpty(_keyboardFrame)) {
                NSString *bundle = [self hostedBundleForKeyboardNotifications];
                if (bundle.length > 0) {
                    [self noteKeyboardFrame:_keyboardFrame source:bundle duration:0.0];
                }
            }
            break;
        }
        default:
            break;
    }
}

- (void)snapFloatToNearestHalf {
    if (!_floatActive || !_floatContainer || _floatContainer.hidden) return;
    if ([self cardIsParked:_floatContainer]) return;
    CGRect parked = [self floatCardFrameForHalf:[self primaryHalfSnappedForCardFrame:[self rootFrameOfCard:_floatContainer]]];
    [self animateSpring:^{
        [self placeCard:self->_floatContainer atFrame:parked];
        [self placeFloatRim];
    } completion:^{
        [self resizeHostOnCard:self->_floatContainer toFrame:parked throttle:NO];
        [self bringFloatAboveSplit];
    }];
}

- (void)snapBackToLayoutForState:(DSStageState)state {
    [self animateSpring:^{
        [self layoutAllStackSlotsForState:state];
        self->_container.alpha = 1.0;
        if (self->_topContainer) self->_topContainer.alpha = 1.0;
    } completion:^{
        if (self->_splitMode || self->_expandedCard || self->_floatActive) {
            [self refitLiveStageHosts];
            [self scheduleLiveStageRefit];
        }
    }];
}

- (CGRect)closeZoneRect {
    return CGRectUnion([_container cornerGripRect], [_container edgeGripRect]);
}

#pragma mark - Stage shelf

- (void)bringShelfToFront {
    if (!_shelf.superview) return;
    // Above every card. A grown split card is almost the full width, so if
    // it stays in front the right-edge notch disappears under it.
    _shelf.layer.zPosition = 40.0;
    [_shelf.superview bringSubviewToFront:_shelf];
}

- (void)noteStageWindowIdle {
    _window.hidden = NO;
    [self refreshSystemStatusBar];
    if (_state == DSStageStateClosed) {
        _dragShell.hidden = YES;
        _dragShell.alpha = 0.0;
        if (_topRim) _topRim.hidden = YES;
    }
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

- (void)rememberStagedBundleOfHost:(DSSceneHost *)host inSet:(NSMutableSet<NSString *> *)staged {
    if (!host.isHosting || host.bundleIdentifier.length == 0) return;
    [staged addObject:host.bundleIdentifier];
}

- (void)refreshPickerAvailability {
    NSMutableSet<NSString *> *staged = [NSMutableSet set];
    [self rememberStagedBundleOfHost:_sceneHost inSet:staged];
    [self rememberStagedBundleOfHost:_topSceneHost inSet:staged];
    [self rememberStagedBundleOfHost:_floatSceneHost inSet:staged];
    [self rememberStagedBundleOfHost:_stashedHost inSet:staged];
    [self rememberStagedBundleOfHost:_stashedHost2 inSet:staged];
    _picker.unavailableBundleIdentifiers = staged;
    _topPicker.unavailableBundleIdentifiers = staged;
    _floatPicker.unavailableBundleIdentifiers = staged;
}

- (BOOL)bundleIsAlreadyStaged:(NSString *)bundle excludingSlot:(NSInteger)slot {
    if (bundle.length == 0) return NO;
    if (slot != 0 && [_sceneHost.bundleIdentifier isEqualToString:bundle]) return YES;
    if (slot != 1 && [_topSceneHost.bundleIdentifier isEqualToString:bundle]) return YES;
    if (slot != 2 && [_floatSceneHost.bundleIdentifier isEqualToString:bundle]) return YES;
    if ([_stashedHost.bundleIdentifier isEqualToString:bundle]) return YES;
    if ([_stashedHost2.bundleIdentifier isEqualToString:bundle]) return YES;
    return NO;
}

- (void)refreshShelf {
    if (!_shelf) return;
    [_shelf reloadTopBundleIdentifier:[self bundleIdentifierOnHalf:1]
             bottomBundleIdentifier:[self bundleIdentifierOnHalf:0]];
    [self refreshPickerAvailability];
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
        [self resetStageGeometryAfterHostedApp];
        if (settle) [self settlePickerKeyboard];
    };
    if (animated) {
        [self animateSpring:layout completion:finish];
    } else {
        layout();
        finish();
    }
}

- (void)clearStoredLiftForSlot:(NSInteger)slot {
    if (slot < 0 || slot > 3) return;
    DSLiftSlotState *state = DSLiftSlotAt(slot);
    state->hasRestingFrame = NO;
    state->baseCardY = 0.0;
    state->baseCardH = 0.0;
    state->baseRestMaxY = 0.0;
    state->keyboardFrozen = NO;
    state->frozenKeysY = 0.0;
    state->frozenKeysH = 0.0;
}

- (void)refreshCardGeometry:(DSStageContainerView *)card {
    if (!card) return;
    CGFloat radius = [self stageCardCornerRadius];
    if (radius < 20.0) radius = 20.0;
    card.cornerRadius = radius;
    [card resetRoundedGeometry];
}

- (void)rebuildStageOutline {
    [self clearFacingRimPulse];
    if (_dragShell) {
        [_dragShell setOutlineLift:_container ? _container.liftOffset : 0.0];
        [_dragShell setNeedsLayout];
        [_dragShell layoutIfNeeded];
    }
    if (_topContainer && !_topContainer.hidden) [self placeTopRimAroundCard:_topContainer];
    if (_dragGhost) {
        _dragGhost.path = nil;
        _dragGhost.opacity = 0.0;
    }
    if (_swapGhost) {
        [_swapGhost removeAnimationForKey:@"pulse"];
        _swapGhost.path = nil;
        _swapGhost.opacity = 0.0;
    }
    [self syncLiftChrome];
}

// Beeper's card leaves the stage window's card with the old outline, a square
// fill, and a lifted baseline. This puts that card back. It does not touch
// SpringBoard's switcher window. The stage window stays full screen: clipping
// it would cut off the rim, and it would not round the card.
- (void)resetStageGeometryAfterHostedApp {
    if ([DSSceneHost sceneSettingsUpdateDepth] > 0) {
        static BOOL waiting = NO;
        if (waiting) return;
        waiting = YES;
        __weak DSStageManager *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            waiting = NO;
            DSStageManager *manager = weakSelf;
            if (!manager || [DSSceneHost sceneSettingsUpdateDepth] > 0) return;
            [manager resetStageGeometryAfterHostedApp];
        });
        return;
    }

    if (!_sceneHost.isHosting) [self clearStoredLiftForSlot:0];
    if (!_topSceneHost.isHosting) [self clearStoredLiftForSlot:1];
    if (!_floatSceneHost.isHosting) [self clearStoredLiftForSlot:2];

    BOOL anyHost = _sceneHost.isHosting || _topSceneHost.isHosting || _floatSceneHost.isHosting;
    if (!anyHost && _searchSlot < 0) {
        _keyboardFrame = CGRectZero;
        _notedKeyboardOnce = NO;
        _keyboardDrawnOutside = NO;
        _keyboardLiftOwner = nil;
        _hostedKeyboardRequestBundle = nil;
    }

    if (_window) {
        // This window is the full screen. A 20pt mask on it rounds the screen,
        // not the card, and it clips the rim. Drop any mask it picked up and
        // put it back on the foreground scene.
        _window.layer.mask = nil;
        _window.layer.cornerRadius = 0.0;
        _window.layer.masksToBounds = NO;
        UIView *root = _window.rootViewController.view;
        root.layer.mask = nil;
        root.layer.cornerRadius = 0.0;
        root.layer.masksToBounds = NO;
        root.clipsToBounds = NO;
        CGRect screen = [self screenBounds];
        if (!CGRectEqualToRect(_window.frame, screen) && CGRectGetWidth(screen) > 100.0) {
            _window.frame = screen;
        }
        if ([_window attachToForegroundSceneIfNeeded]) {
            DSDiagnosticsRecord(@"SpringBoard: stage window moved back to the foreground scene");
        }
    }

    if (CGRectIsEmpty(_keyboardFrame)) [self clearKeyboardSideShift];
    if (!_sceneHost.isHosting) {
        [_container setLiftOffset:0.0];
        [self refreshCardGeometry:_container];
        [_container applyCardCornerClip];
        [self roundPicker:_picker onCard:_container];
    }
    if (_topContainer && !_topSceneHost.isHosting) {
        [_topContainer setLiftOffset:0.0];
        [self refreshCardGeometry:_topContainer];
        [_topContainer applyCardCornerClip];
        [self roundPicker:_topPicker onCard:_topContainer];
    }
    if (_floatContainer && !_floatSceneHost.isHosting) {
        [_floatContainer setLiftOffset:0.0];
        [self refreshCardGeometry:_floatContainer];
        [_floatContainer applyCardCornerClip];
        [self roundPicker:_floatPicker onCard:_floatContainer];
    }
    if (_dragShell) [_dragShell clearOutline];
    [self rebuildStageOutline];
    CGRect cardFrame = _container ? _container.frame : CGRectZero;
    DSLog("[CARD] reset geometry radius=%.0f mask=%d local=%@ screen=%@",
          _container.cornerRadius,
          _container.contentView.layer.mask != nil,
          NSStringFromCGRect(cardFrame),
          NSStringFromCGRect([self primaryCardFrameInRoot]));
}

- (void)roundPicker:(DSAppPickerViewController *)picker onCard:(DSStageContainerView *)card {
    if (!picker || !card) return;
    UIView *view = picker.view;
    CGFloat radius = card.cornerRadius;
    if (radius < 20.0) radius = 20.0;
    view.backgroundColor = UIColor.clearColor;
    view.clipsToBounds = YES;
    view.layer.masksToBounds = YES;
    view.layer.cornerRadius = radius;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
                               kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
}

// One present for the corner pull, the right-edge squares, and the + button.
// The card is the fixed half size before it animates, and it is never left at
// alpha 0 if that animation is interrupted.
- (void)presentPickerOnHalf:(NSInteger)half animated:(BOOL)animated {
    (void)half;
    [self collapseToSingleTopStage];
    if ([self bundleIdentifierOnHalf:1].length > 0) {
        [self revealHalf:1 animated:animated];
        [_shelf setOpen:NO animated:YES];
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
    _primaryHalf = 1;
    _secondHalf = 0;
    _stackSlotCount = 1;
    _primaryParked = NO;
    _secondParked = NO;
    _dragShell.hidden = NO;
    _dragShell.alpha = 1.0;
    if (_topContainer) _topContainer.hidden = YES;

    [self presentPickerOnCard:_container picker:_picker];
    [_picker resetScrollPosition];
    _container.hidden = NO;
    _container.alpha = 1.0;
    [_container setLiftOffset:0.0];
    // Opened the top stage. Drop the outline, mask, and lift Beeper left on this card.
    [self clearStoredLiftForSlot:0];
    [self resetStageGeometryAfterHostedApp];
    [self refreshCardGeometry:_container];
    // The first stage enters from above the screen, then settles on the top half.
    if (_state != DSStageStateOverlay) {
        [UIView performWithoutAnimation:^{
            [self placeCard:_container atFrame:[self offscreenTopFrame]];
        }];
    }
    if (_state == DSStageStateOverlay) {
        [self finishPickerLayoutAnimated:animated generation:generation settleKeyboard:YES];
    } else {
        [self enterStateOverlayAnimated:animated];
    }
    DSDiagnosticsRecord(@"SpringBoard: opened the top stage");
}

- (void)revealHalf:(NSInteger)half animated:(BOOL)animated {
    DSStageContainerView *card = [self containerOnHalf:half];
    if (!card) card = _container;
    [self setParked:NO forCard:card];
    if (_state != DSStageStateOverlay) {
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
    if (_state != DSStageStateOverlay) {
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

- (CGRect)seedFrameAtPoint:(CGPoint)point {
    CGFloat side = 108.0;
    return CGRectMake(point.x - side * 0.5, point.y - side * 0.5, side, side);
}

- (NSInteger)halfForNewStagePoint:(CGPoint)point {
    CGFloat pivot = (CGRectGetMidY([self fixedHalfFrame:1]) + CGRectGetMidY([self fixedHalfFrame:0])) * 0.5;
    return point.y >= pivot ? 0 : 1;
}

// One app on the top half, and the finger is on the very bottom edge.
// Lower than that, but not on the edge, is a normal second stage.
- (BOOL)oneHostedAppOnTopHalf {
    if (_splitMode || _floatActive) return NO;
    if (_state != DSStageStateOverlay) return NO;
    if (_primaryParked || !_sceneHost.isHosting || _container.hidden) return NO;
    if (_primaryHalf != 1) return NO;
    if (_stackSlotCount >= kDSMaxStackSlots && _topContainer && !_topContainer.hidden && !_secondParked) return NO;
    return YES;
}

- (BOOL)pointIsNewStageSplitZone:(CGPoint)point {
    if (![self oneHostedAppOnTopHalf]) return NO;
    return point.y >= CGRectGetHeight([self screenBounds]) - 40.0;
}

- (void)beginSplitUnderTopAppFromFinger:(CGPoint)finger {
    @try {
        // A keyboard lift is a transform. Laying the new split out under that
        // transform, then sending the app home, is the SIGTRAP.
        if (_stagedKeyboardSlot >= 0 || !CGRectIsEmpty(_keyboardFrame)) {
            [self hideStagedKeyboardLikePicker];
        } else {
            [self collapseHostedKeyboardLift];
        }
        _splitMode = YES;
        _floatRest = 0;
        _splitMiddleCard = nil;
        _primaryHalf = 1;
        _secondHalf = 0;
        [self ensureTopStackInfrastructure];
        [self presentSplitPickerFromFinger:finger onCard:_topContainer half:0];
        [self bindSplitStageHosts];
        DSLogAppend([NSString stringWithFormat:@"[SPLIT] opened under the top app finger={{%.0f,%.0f}}", finger.x, finger.y]);
        DSCrashLogRemember(@"split opened under the top app");
    } @catch (NSException *exception) {
        _splitMode = NO;
        DSCrashLogRemember([NSString stringWithFormat:@"split open threw %@", exception.reason ?: @"?"]);
    }
}

- (UIView *)stashHolder {
    if (!_stashHolder) {
        // Full screen and hidden. An 8pt box here is what crashed the app: its
        // live view was laid out into that box the moment it was minimized.
        _stashHolder = [[UIView alloc] initWithFrame:[self screenBounds]];
        _stashHolder.tag = 9158;
        _stashHolder.hidden = YES;
        _stashHolder.alpha = 0.0;
        _stashHolder.userInteractionEnabled = NO;
        _stashHolder.clipsToBounds = YES;
        _stashHolder.backgroundColor = UIColor.clearColor;
    }
    if (_stashHolder.superview == nil && _window.rootViewController.view) {
        [_window.rootViewController.view insertSubview:_stashHolder atIndex:0];
    }
    return _stashHolder;
}

// The live app stays at the size it had on the stage. The corner card is 56pt,
// and laying the app out into that card is what crashes it once it is minimized.
- (void)holdHostViewAtStageSize:(DSSceneHost *)host {
    UIView *view = host.hostView;
    if (!view) return;
    UIView *holder = [self stashHolder];
    if (!holder) return;
    CGRect frame = host.stageFrame;
    if (CGRectGetWidth(view.bounds) > CGRectGetWidth(frame)) frame.size = view.bounds.size;
    if (CGRectGetWidth(frame) < 40.0 || CGRectGetHeight(frame) < 40.0) frame = holder.bounds;
    frame.origin = CGPointZero;
    view.autoresizingMask = UIViewAutoresizingNone;
    view.transform = CGAffineTransformIdentity;
    view.alpha = 1.0;
    view.hidden = YES;
    view.frame = frame;
    if (view.superview != holder) [holder addSubview:view];
}

- (void)returnHostView:(DSSceneHost *)host toCard:(DSStageContainerView *)card {
    UIView *view = host.hostView;
    if (!view || !card.contentView) return;
    if (view.superview == card.contentView) return;
    view.autoresizingMask = UIViewAutoresizingNone;
    view.transform = CGAffineTransformIdentity;
    view.alpha = 1.0;
    view.hidden = NO;
    [card.contentView insertSubview:view atIndex:0];
}

// Keep a minimized app alive, off the card, so the two halves can be used for
// split. It is not woken. Its corner icon stays.
- (void)stashHost:(DSSceneHost *)host fromCard:(DSStageContainerView *)card {
    if (!host.isHosting || !card) return;
    BOOL left = [self cardMinimizedOnLeft:card];
    [host setStaysBackgrounded:YES];
    [host setForeground:NO];
    [self holdHostViewAtStageSize:host];
    if (host == _sceneHost) {
        _sceneHost = nil;
        _primaryParked = NO;
    } else if (host == _topSceneHost) {
        _topSceneHost = nil;
        _secondParked = NO;
    }
    if (!_stashedHost) {
        _stashedHost = host;
        _stashedLeft = left;
    } else if (_stashedHost != host) {
        _stashedHost2 = host;
        _stashedLeft2 = left;
    }
}

- (void)parkStashedHost:(DSSceneHost *)host onLeft:(BOOL)left {
    if (!host.isHosting) return;
    DSStageContainerView *card = nil;
    if (!_sceneHost.isHosting) {
        card = _container;
        _sceneHost = host;
        _primaryMinimizedLeft = left;
        _primaryParked = YES;
    } else if (!_topSceneHost.isHosting) {
        [self ensureTopStackInfrastructure];
        card = _topContainer;
        _topSceneHost = host;
        _secondMinimizedLeft = left;
        _secondParked = YES;
        if (_stackSlotCount < kDSMaxStackSlots) _stackSlotCount = kDSMaxStackSlots;
    } else {
        return;
    }
    if (_stashedHost == host) _stashedHost = nil;
    if (_stashedHost2 == host) _stashedHost2 = nil;
    [host setStaysBackgrounded:YES];
    [host setForeground:NO];
    [self holdHostViewAtStageSize:host];
    card.hostingApp = YES;
    [card setBackdropHidden:YES];
    [self placeCard:card atFrame:[self cornerParkFrameForCard:card]];
    card.alpha = 0.0;
    card.hidden = YES;
    if (card == _container) {
        _dragShell.alpha = 0.0;
        _dragShell.hidden = YES;
    } else {
        _topRim.alpha = 0.0;
        _topRim.hidden = YES;
    }
}

- (void)parkStashedHostsOntoCards {
    DSSceneHost *first = _stashedHost;
    DSSceneHost *second = _stashedHost2;
    BOOL firstLeft = _stashedLeft;
    BOOL secondLeft = _stashedLeft2;
    if (first) [self parkStashedHost:first onLeft:firstLeft];
    if (second && second != first) [self parkStashedHost:second onLeft:secondLeft];
}

- (DSSceneHost *)parkedHostPreferringLeft:(BOOL *)leftOut {
    if (_primaryParked && _sceneHost.isHosting) {
        if (leftOut) *leftOut = _primaryMinimizedLeft;
        return _sceneHost;
    }
    if (_secondParked && _topSceneHost.isHosting) {
        if (leftOut) *leftOut = _secondMinimizedLeft;
        return _topSceneHost;
    }
    return nil;
}

- (void)freeParkedCardForSplit:(DSStageContainerView *)card {
    if (!card) return;
    DSSceneHost *host = [self sceneHostForCard:card];
    if (host.isHosting && [self cardIsParked:card]) {
        [self stashHost:host fromCard:card];
    }
}

- (void)presentSplitPickerFromFinger:(CGPoint)finger onCard:(DSStageContainerView *)card half:(NSInteger)half {
    [self ensureTopStackInfrastructure];
    if (!card) card = _topContainer;
    half = half == 0 ? 0 : 1;
    if (card == _topContainer) {
        _secondHalf = half;
        _secondParked = NO;
    } else {
        _primaryHalf = half;
        _primaryParked = NO;
    }
    _stackSlotCount = kDSMaxStackSlots;
    _presentGeneration += 1;
    NSInteger generation = _presentGeneration;
    DSAppPickerViewController *picker = [self pickerForCard:card];
    [picker dismissKeyboard];
    [self presentPickerOnCard:card picker:picker];
    [picker resetScrollPosition];
    card.hidden = NO;
    card.alpha = 1.0;
    if (card == _topContainer) {
        _topRim.hidden = NO;
        _topRim.alpha = 1.0;
    } else {
        _dragShell.hidden = NO;
        _dragShell.alpha = 1.0;
    }
    [UIView performWithoutAnimation:^{
        [self placeCard:card atFrame:[self seedFrameAtPoint:finger]];
        card.cornerRadius = 26.0;
    }];
    _state = DSStageStateOverlay;
    _window.hidden = NO;
    [self cancelAutoKill];
    _overlaySettling = YES;
    [self animateSpring:^{
        [self layoutAllStackSlotsForState:DSStageStateOverlay];
        card.alpha = 1.0;
    } completion:^{
        [self finishFingerStagePresentation:generation];
    }];
}

// Split needs a free pair of halves. A minimized app is not using one: it stays
// in its corner. A different app already visible on a half still leaves no room.
- (BOOL)newStageSplitAvailable {
    if (_splitMode) return NO;
    if ([self reasonStageCannotActivate]) return NO;
    SBApplication *front = [self frontApplication];
    NSString *bundle = front.bundleIdentifier;
    BOOL frontUsable = bundle.length > 0 && ![[DSPreferences sharedPreferences] isApplicationDisabled:bundle];
    BOOL parkedUsable = [self parkedHostPreferringLeft:NULL] != nil;
    if (!frontUsable && !parkedUsable) return NO;

    BOOL primaryVisible = _sceneHost.isHosting && !_primaryParked;
    BOOL secondVisible = _topSceneHost.isHosting && !_secondParked;
    if (primaryVisible && secondVisible) return NO;
    if (frontUsable) {
        if (primaryVisible && ![_sceneHost.bundleIdentifier isEqualToString:bundle]) return NO;
        if (secondVisible && ![_topSceneHost.bundleIdentifier isEqualToString:bundle]) return NO;
    } else if (primaryVisible || secondVisible) {
        return NO;
    }
    return YES;
}

- (BOOL)newStageDropHasRoom {
    if (_state == DSStageStateTracking) return NO;
    if ((_primaryParked && _sceneHost.isHosting) || _state == DSStageStateMinimized) {
        return !(_stackSlotCount >= kDSMaxStackSlots && _topSceneHost.isHosting);
    }
    if (self.isStageVisible && _stackSlotCount >= kDSMaxStackSlots) return NO;
    return YES;
}

- (void)showNewStageHintAtPoint:(CGPoint)point {
    if (_state == DSStageStateTracking) {
        [self hideNewStageHint];
        return;
    }
    if (_splitMode && _floatActive) {
        [self hideNewStageHint];
        return;
    }
    BOOL split = !_splitMode && [self pointIsNewStageSplitZone:point];
    if (!split && !_splitMode && ![self newStageDropHasRoom]) {
        [self hideNewStageHint];
        return;
    }
    UIView *root = _window.rootViewController.view;
    if (!root) return;
    if (!_dragGhost) {
        _dragGhost = [CAShapeLayer layer];
        _dragGhost.fillColor = UIColor.clearColor.CGColor;
        _dragGhost.lineWidth = 1.25;
        _dragGhost.lineCap = kCALineCapRound;
        _dragGhost.lineJoin = kCALineJoinRound;
        [root.layer addSublayer:_dragGhost];
    }
    if (!_newStageGhostLabel) {
        _newStageGhostLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _newStageGhostLabel.textAlignment = NSTextAlignmentCenter;
        _newStageGhostLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
        _newStageGhostLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.78];
        _newStageGhostLabel.userInteractionEnabled = NO;
        _newStageGhostLabel.adjustsFontSizeToFitWidth = YES;
        _newStageGhostLabel.minimumScaleFactor = 0.7;
        [root addSubview:_newStageGhostLabel];
    }
    CGFloat radius = [self stageCardCornerRadius];
    UIBezierPath *path = [UIBezierPath bezierPath];
    CGRect labelFrame;
    if (_splitMode) {
        labelFrame = [self hoverFrameCenteredOn:point];
        [path appendPath:[UIBezierPath bezierPathWithRoundedRect:labelFrame cornerRadius:radius]];
        _newStageGhostLabel.text = @"Stage";
    } else if (split) {
        CGRect top = [self fixedHalfFrame:1];
        CGRect bottom = [self fixedHalfFrame:0];
        [path appendPath:[UIBezierPath bezierPathWithRoundedRect:top cornerRadius:radius]];
        [path appendPath:[UIBezierPath bezierPathWithRoundedRect:bottom cornerRadius:radius]];
        labelFrame = bottom;
        _newStageGhostLabel.text = @"Split Screen";
    } else {
        NSInteger half = [self halfForNewStagePoint:point];
        CGRect frame = [self fixedHalfFrame:half];
        [path appendPath:[UIBezierPath bezierPathWithRoundedRect:frame cornerRadius:radius]];
        labelFrame = frame;
        _newStageGhostLabel.text = (half == 0) ? @"Lower stage" : @"Stage";
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _dragGhost.frame = root.bounds;
    _dragGhost.path = path.CGPath;
    _dragGhost.lineWidth = 1.25;
    _dragGhost.shadowOpacity = 0.0;
    _dragGhost.zPosition = 4000.0;
    _dragGhost.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.92].CGColor;
    _dragGhost.opacity = 1.0;
    [CATransaction commit];
    _newStageGhostLabel.frame = CGRectInset(labelFrame, 24.0, 0.0);
    _newStageGhostLabel.hidden = NO;
    _newStageGhostLabel.alpha = 1.0;
    _newStageGhostLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    _newStageGhostLabel.layer.cornerRadius = 10.0;
    _newStageGhostLabel.layer.masksToBounds = YES;
    [self bringShelfToFront];
    // The shelf is full screen and was covering the hint.
    [root bringSubviewToFront:_newStageGhostLabel];
    DSLogAppend([NSString stringWithFormat:@"[HINT] %@ finger={{%.0f,%.0f}}", _newStageGhostLabel.text ?: @"?", point.x, point.y]);
}

- (void)hideNewStageHint {
    [self updateDragGhostForFrame:CGRectZero red:NO visible:NO];
    _newStageGhostLabel.hidden = YES;
}

- (void)handleNewStageDrag:(UIGestureRecognizerState)state atPoint:(CGPoint)point {
    if (_splitMode) {
        if (state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateChanged) {
            [self setTerminateHintVisible:NO];
            [self showNewStageHintAtPoint:point];
            return;
        }
        [self hideNewStageHint];
        [self setTerminateHintVisible:NO];
        if (state == UIGestureRecognizerStateEnded && !_floatActive) {
            [self presentHoverStageFromPoint:point];
        }
        return;
    }
    if (state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateChanged) {
        [self setTerminateHintVisible:NO];
        [self showNewStageHintAtPoint:point];
        return;
    }
    [self hideNewStageHint];
    [self setTerminateHintVisible:NO];
    if (state != UIGestureRecognizerStateEnded) return;
    if (_state == DSStageStateTracking) return;
    if ([self pointIsNewStageSplitZone:point]) {
        [self beginSplitUnderTopAppFromFinger:point];
        return;
    }
    [self beginStageFromFinger:point onHalf:[self halfForNewStagePoint:point]];
}

- (void)finishFingerStagePresentation:(NSInteger)generation {
    if (generation != _presentGeneration) return;
    _overlaySettling = NO;
    [self updateStackChrome];
    [self updateHomeAffordance];
    [self bringFloatAboveSplit];
    [self refreshShelf];
    [self settlePickerKeyboard];
    [self updateOpenAppIcon];
    if (_splitMode || _expandedCard || _floatActive) {
        [self refitLiveStageHosts];
        [self scheduleLiveStageRefit];
    }
    if (_splitMode) [self bindSplitStageHosts];
    if (_splitMode) [self showHomeScreenBehindSplit];
}

- (void)presentPickerFromFinger:(CGPoint)finger onHalf:(NSInteger)half {
    half = half == 0 ? 0 : 1;
    if (_state == DSStageStateClosed) {
        NSString *refusal = [self reasonStageCannotActivate];
        if (refusal) {
            DSDiagnosticsRecordFormat(@"SpringBoard: stage refused to open because %@", refusal);
            return;
        }
    }
    [self collapseToSingleTopStage];
    _presentGeneration += 1;
    NSInteger generation = _presentGeneration;
    _searchSlot = -1;
    [_picker dismissKeyboard];
    _primaryHalf = half;
    _secondHalf = half == 0 ? 1 : 0;
    _stackSlotCount = 1;
    _primaryParked = NO;
    _secondParked = NO;
    _dragShell.hidden = NO;
    _dragShell.alpha = 1.0;
    if (_topContainer) _topContainer.hidden = YES;
    [self presentPickerOnCard:_container picker:_picker];
    [_picker resetScrollPosition];
    _container.hidden = NO;
    _container.alpha = 1.0;
    [_container setLiftOffset:0.0];
    [UIView performWithoutAnimation:^{
        [self placeCard:_container atFrame:[self seedFrameAtPoint:finger]];
        self->_container.cornerRadius = 26.0;
    }];
    _state = DSStageStateOverlay;
    _window.hidden = NO;
    [self cancelAutoKill];
    [self takeKeyWindowForStageChrome];
    _overlaySettling = YES;
    [self animateSpring:^{
        [self layoutAllStackSlotsForState:DSStageStateOverlay];
        self->_container.alpha = 1.0;
    } completion:^{
        [self finishFingerStagePresentation:generation];
    }];
    DSDiagnosticsRecord(@"SpringBoard: opened a stage from the finger");
}

- (void)addSecondStageFromFinger:(CGPoint)finger onHalf:(NSInteger)half {
    [self ensureTopStackInfrastructure];
    if (_stackSlotCount >= kDSMaxStackSlots) return;
    half = half == 0 ? 0 : 1;
    NSInteger other = half == 0 ? 1 : 0;
    _presentGeneration += 1;
    NSInteger generation = _presentGeneration;
    _searchSlot = -1;
    [_picker dismissKeyboard];
    if (_topPicker) [_topPicker dismissKeyboard];
    if (_primaryHalf == half) _primaryHalf = other;
    _secondHalf = half;
    _stackSlotCount = kDSMaxStackSlots;
    _secondParked = NO;
    [_container setLiftOffset:0.0];
    [_topContainer setLiftOffset:0.0];
    [self presentPickerOnCard:_topContainer picker:_topPicker];
    [_topPicker resetScrollPosition];
    _topContainer.alpha = 1.0;
    _topContainer.hidden = NO;
    _topRim.hidden = NO;
    _topRim.alpha = 1.0;
    [UIView performWithoutAnimation:^{
        [self placeCard:_topContainer atFrame:[self seedFrameAtPoint:finger]];
        self->_topContainer.cornerRadius = 26.0;
    }];
    if (_state != DSStageStateOverlay) {
        _state = DSStageStateOverlay;
        _window.hidden = NO;
        [self cancelAutoKill];
        if (!self.hasHostedApp) [self takeKeyWindowForStageChrome];
    }
    _overlaySettling = YES;
    [self animateSpring:^{
        [self layoutAllStackSlotsForState:DSStageStateOverlay];
        self->_container.alpha = 1.0;
        self->_topContainer.alpha = 1.0;
    } completion:^{
        [self finishFingerStagePresentation:generation];
    }];
    DSDiagnosticsRecord(@"SpringBoard: opened another stage from the finger");
}

- (void)addStageFromFinger:(CGPoint)finger besideParkedOnHalf:(NSInteger)half {
    [self ensureTopStackInfrastructure];
    if (_stackSlotCount >= kDSMaxStackSlots && _topSceneHost.isHosting) return;
    half = half == 0 ? 0 : 1;
    _presentGeneration += 1;
    NSInteger generation = _presentGeneration;
    _searchSlot = -1;
    [_picker dismissKeyboard];
    if (_topPicker) [_topPicker dismissKeyboard];
    _stackSlotCount = kDSMaxStackSlots;
    _primaryParked = _sceneHost.isHosting ? YES : _primaryParked;
    _secondParked = NO;
    _secondHalf = half;
    _state = DSStageStateOverlay;
    _window.hidden = NO;
    [self cancelAutoKill];
    [_sceneHost setStaysBackgrounded:YES];
    [_sceneHost setForeground:NO];
    [self presentPickerOnCard:_topContainer picker:_topPicker];
    [_topPicker resetScrollPosition];
    _topContainer.alpha = 1.0;
    _topContainer.hidden = NO;
    _topRim.hidden = NO;
    _topRim.alpha = 1.0;
    [UIView performWithoutAnimation:^{
        [self placeCard:_topContainer atFrame:[self seedFrameAtPoint:finger]];
        self->_topContainer.cornerRadius = 26.0;
    }];
    _overlaySettling = YES;
    [self animateSpring:^{
        [self layoutAllStackSlotsForState:DSStageStateOverlay];
        self->_topContainer.alpha = 1.0;
    } completion:^{
        if (generation != self->_presentGeneration) return;
        [self hideParkedCardsCompletely];
        [self finishFingerStagePresentation:generation];
    }];
}

- (void)launchFrontApplicationOnSlot:(NSInteger)slot {
    SBApplication *front = [self frontApplication];
    NSString *bundle = front.bundleIdentifier;
    if (bundle.length == 0) return;
    if ([self sceneHostForSlot:slot].isHosting && [[self sceneHostForSlot:slot].bundleIdentifier isEqualToString:bundle]) {
        return;
    }
    DSAppEntry *entry = [[DSAppLibrary sharedLibrary] entryForBundleIdentifier:bundle];
    if (!entry) {
        entry = [[DSAppEntry alloc] init];
        entry.bundleIdentifier = bundle;
        entry.displayName = front.displayName.length ? front.displayName : bundle;
    }
    [self launchEntry:entry slot:slot];
}

- (void)beginSplitFromFinger:(CGPoint)finger {
    if (![self newStageSplitAvailable]) {
        [self beginStageFromFinger:finger onHalf:0];
        return;
    }
    BOOL wasVisible = self.isStageVisible;
    NSString *bundle = [self frontApplication].bundleIdentifier;
    BOOL frontUsable = bundle.length > 0 && ![[DSPreferences sharedPreferences] isApplicationDisabled:bundle];
    if (!frontUsable) bundle = [self parkedHostPreferringLeft:NULL].bundleIdentifier;
    if (bundle.length == 0) {
        [self beginStageFromFinger:finger onHalf:0];
        return;
    }
    _splitMode = YES;
    _expandedCard = nil;
    _splitResizeHeight = 0.0;
    [self ensureTopStackInfrastructure];
    if ([_sceneHost.bundleIdentifier isEqualToString:bundle]) {
        _primaryHalf = 1;
        if (_primaryParked || _state == DSStageStateMinimized) {
            [self setParked:NO forCard:_container];
            _state = DSStageStateOverlay;
            _dragShell.hidden = NO;
            _dragShell.alpha = 1.0;
            _container.hidden = NO;
            _container.alpha = 1.0;
            [_sceneHost setForeground:YES];
        }
        [self freeParkedCardForSplit:_topContainer];
        if (_topSceneHost.isHosting) {
            _secondHalf = 0;
            _presentGeneration += 1;
            NSInteger generation = _presentGeneration;
            _overlaySettling = YES;
            [self animateSpring:^{
                [self layoutAllStackSlotsForState:DSStageStateOverlay];
            } completion:^{
                [self finishFingerStagePresentation:generation];
            }];
        } else {
            [self presentSplitPickerFromFinger:finger onCard:_topContainer half:0];
        }
        DSDiagnosticsRecord(@"SpringBoard: split, app already staged, new stage on the bottom");
        return;
    }
    if ([_topSceneHost.bundleIdentifier isEqualToString:bundle]) {
        _secondHalf = 1;
        if (_secondParked) {
            [self setParked:NO forCard:_topContainer];
            _topContainer.hidden = NO;
            _topContainer.alpha = 1.0;
            _topRim.hidden = NO;
            _topRim.alpha = 1.0;
            [_topSceneHost setForeground:YES];
        }
        [self freeParkedCardForSplit:_container];
        _primaryHalf = 0;
        if (_sceneHost.isHosting) {
            _stackSlotCount = kDSMaxStackSlots;
            _state = DSStageStateOverlay;
            _window.hidden = NO;
            _presentGeneration += 1;
            NSInteger generation = _presentGeneration;
            _overlaySettling = YES;
            [self animateSpring:^{
                [self layoutAllStackSlotsForState:DSStageStateOverlay];
            } completion:^{
                [self finishFingerStagePresentation:generation];
            }];
        } else {
            [self presentSplitPickerFromFinger:finger onCard:_container half:0];
        }
        DSDiagnosticsRecord(@"SpringBoard: split, moved the open app to the top");
        return;
    }
    if (_primaryParked && _sceneHost.isHosting) [self stashHost:_sceneHost fromCard:_container];
    if (_secondParked && _topSceneHost.isHosting) [self stashHost:_topSceneHost fromCard:_topContainer];

    _presentGeneration += 1;
    NSInteger generation = _presentGeneration;
    _searchSlot = -1;
    [_picker dismissKeyboard];
    if (_topPicker) [_topPicker dismissKeyboard];
    _primaryHalf = 1;
    _secondHalf = 0;
    _stackSlotCount = kDSMaxStackSlots;
    _primaryParked = NO;
    _secondParked = NO;
    _state = DSStageStateOverlay;
    _window.hidden = NO;
    _dragShell.hidden = NO;
    _dragShell.alpha = 1.0;
    [self cancelAutoKill];
    [self presentPickerOnCard:_container picker:_picker];
    [self presentPickerOnCard:_topContainer picker:_topPicker];
    [_picker resetScrollPosition];
    [_topPicker resetScrollPosition];
    _container.hidden = NO;
    _container.alpha = 1.0;
    _topContainer.hidden = NO;
    _topContainer.alpha = 1.0;
    _topRim.hidden = NO;
    _topRim.alpha = 1.0;
    [_container setLiftOffset:0.0];
    [_topContainer setLiftOffset:0.0];
    [UIView performWithoutAnimation:^{
        if (!wasVisible) {
            [self placeCard:_container atFrame:[self fixedHalfFrame:1]];
        }
        [self placeCard:_topContainer atFrame:[self seedFrameAtPoint:finger]];
        self->_topContainer.cornerRadius = 26.0;
    }];
    _overlaySettling = YES;
    [self animateSpring:^{
        [self layoutAllStackSlotsForState:DSStageStateOverlay];
        self->_container.alpha = 1.0;
        self->_topContainer.alpha = 1.0;
    } completion:^{
        [self finishFingerStagePresentation:generation];
        [self giveBackKeyWindow];
    }];
    [self launchFrontApplicationOnSlot:0];
    DSDiagnosticsRecordFormat(@"SpringBoard: split %@ onto the top stage", bundle);
}

- (void)beginStageFromFinger:(CGPoint)finger onHalf:(NSInteger)half {
    if (_splitMode) {
        if (!_floatActive) [self presentHoverStageFromPoint:finger];
        return;
    }
    half = half == 0 ? 0 : 1;
    if (_state == DSStageStateTracking) return;
    if (self.isStageVisible && _stackSlotCount >= kDSMaxStackSlots) return;
    if ((_primaryParked && _sceneHost.isHosting) || _state == DSStageStateMinimized) {
        [self addStageFromFinger:finger besideParkedOnHalf:half];
        return;
    }
    if (self.isStageVisible && _stackSlotCount < kDSMaxStackSlots) {
        [self addSecondStageFromFinger:finger onHalf:half];
        return;
    }
    [self presentPickerFromFinger:finger onHalf:half];
}

- (void)beginStageOnHalf:(NSInteger)half {
    (void)half;
    if (_state == DSStageStateTracking) return;
    if (_splitMode) {
        if (_floatActive) return;
        CGRect screen = [self screenBounds];
        [self presentHoverStageFromPoint:CGPointMake(CGRectGetMidX(screen), CGRectGetMidY(screen))];
        return;
    }
    // The first stage takes the top. Another tap adds a stage on the free half.
    if (self.isStageVisible && _stackSlotCount < kDSMaxStackSlots) {
        [self addSecondStageOnHalf:1 animated:YES];
        return;
    }
    if ((_primaryParked && _sceneHost.isHosting) || _state == DSStageStateMinimized) {
        [self addStageBesideParkedCardAnimated:YES];
        return;
    }
    if (self.isStageVisible && _stackSlotCount >= kDSMaxStackSlots) {
        DSDiagnosticsRecord(@"SpringBoard: two stages are already open");
        return;
    }
    [self presentPickerOnHalf:1 animated:YES];
}

#pragma mark - External events

- (void)noteSceneDestroyedForBundleIdentifier:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0) return;
    if (_floatSceneHost && [_floatSceneHost.bundleIdentifier isEqualToString:bundleIdentifier]) {
        _floatSceneHost = nil;
        if (_floatContainer) [self presentPickerOnCard:_floatContainer picker:_floatPicker];
        [self resetStageGeometryAfterHostedApp];
        return;
    }
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
        [self resetStageGeometryAfterHostedApp];
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

static const NSInteger kDSHeldPictureTag = 9151;

- (void)holdPictureOfCard:(DSStageContainerView *)card {
    if (!card || card.hidden || [self cardIsParked:card]) return;
    UIView *content = card.contentView;
    UIView *previous = [content viewWithTag:kDSHeldPictureTag];
    [previous removeFromSuperview];
    UIView *picture = nil;
    @try {
        picture = [content snapshotViewAfterScreenUpdates:NO];
    } @catch (NSException *exception) {
        return;
    }
    if (!picture) return;
    picture.tag = kDSHeldPictureTag;
    picture.frame = content.bounds;
    picture.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    picture.userInteractionEnabled = NO;
    [content addSubview:picture];
}

- (void)handleCardWakeTap:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateEnded) return;
    DSStageContainerView *card = _container;
    if (recognizer.view == _floatContainer) card = _floatContainer;
    else if (recognizer.view == _topContainer) card = _topContainer;
    if ([self cardIsParked:card]) return;
    [self dropHeldPictureOnCard:card];
    DSSceneHost *host = [self sceneHostForCard:card];
    if (host.isHosting) {
        [host setStaysBackgrounded:NO];
        [host wakeIfBackgrounded];
    }
}

- (void)dropHeldPictureOnCard:(DSStageContainerView *)card {
    if (!card) return;
    UIView *picture = [card.contentView viewWithTag:kDSHeldPictureTag];
    [picture removeFromSuperview];
    DSSceneHost *host = (card == _topContainer) ? _topSceneHost : _sceneHost;
    if (host.isHosting && ![self cardIsParked:card]) [host wakeIfBackgrounded];
}

static BOOL DSCardFrameRoughlyEqual(CGRect a, CGRect b) {
    return fabs(CGRectGetMinX(a) - CGRectGetMinX(b)) < 0.75 && fabs(CGRectGetMinY(a) - CGRectGetMinY(b)) < 0.75 &&
           fabs(CGRectGetWidth(a) - CGRectGetWidth(b)) < 0.75 && fabs(CGRectGetHeight(a) - CGRectGetHeight(b)) < 0.75;
}

// 4.5.650 (switcher lag): this ran on EVERY settings update of a hosted
// scene. The app switcher updates scenes every frame of the swipe, so each
// frame did a running assertion, a foreground override + settings push (a
// scene write the app answers with a relayout) and a full placeCard
// (layoutIfNeeded + geometry log). Now: re-assert at most once a second, or
// right away when the parked set changed; never during the home / switcher
// transition; placeCard only when the card is not already at its park frame.
- (void)keepMinimizedCardsBackgrounded {
    static CFAbsoluteTime lastAssert = 0;
    static BOOL lastPrimary = NO;
    static BOOL lastSecond = NO;
    BOOL second = _secondParked && _topContainer != nil;
    BOOL setChanged = lastPrimary != _primaryParked || lastSecond != second;
    if (!_primaryParked && !second) {
        lastPrimary = NO;
        lastSecond = NO;
        return;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!setChanged && now - lastAssert < 1.0) return;
    if (!setChanged && [DSSceneHost systemTransitionBusy]) return;
    lastAssert = now;
    lastPrimary = _primaryParked;
    lastSecond = second;
    if (_primaryParked) {
        [_sceneHost setStaysBackgrounded:YES];
        [_sceneHost setForeground:NO];
        CGRect park = [self cornerParkFrameForCard:_container];
        if (setChanged || !DSCardFrameRoughlyEqual(_container.frame, park)) [self placeCard:_container atFrame:park];
    }
    if (second) {
        [_topSceneHost setStaysBackgrounded:YES];
        [_topSceneHost setForeground:NO];
        CGRect park = [self cornerParkFrameForCard:_topContainer];
        if (setChanged || !DSCardFrameRoughlyEqual(_topContainer.frame, park)) [self placeCard:_topContainer atFrame:park];
    }
}

// Only parked hosts. A visible card is not part of this crash, and turning
// system lifecycle on for it would let SpringBoard take the open stage down.
- (void)setParkedHostsFollowSystemHomeTransition:(BOOL)follows {
    if (_primaryParked && _sceneHost.isHosting) {
        [_sceneHost setFollowsSystemHomeTransition:follows];
    }
    if (_secondParked && _topSceneHost.isHosting) {
        [_topSceneHost setFollowsSystemHomeTransition:follows];
    }
}

- (void)restoreParkedHostsAfterHomeGesture {
    // Still inside the quiet window, so the scene update from this property
    // write is held. Do not change display mode and do not push scene
    // settings. That push landed as Spotlight opened and safe-moded.
    [_sceneHost setFollowsSystemHomeTransition:NO];
    [_topSceneHost setFollowsSystemHomeTransition:NO];
    [_floatSceneHost setFollowsSystemHomeTransition:NO];
    DSDiagnosticsRecord(@"SpringBoard: parked apps stopped following the home transition");
}

static NSInteger DSHomeGestureGeneration = 0;

- (void)noteHomeGestureEnded:(UIPanGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded &&
        gesture.state != UIGestureRecognizerStateCancelled &&
        gesture.state != UIGestureRecognizerStateFailed) return;
    [gesture removeTarget:self action:@selector(noteHomeGestureEnded:)];
    DSHomeGestureGeneration += 1;
    [DSSceneHost setHomeGestureActive:NO];
    DSDiagnosticsRecord(@"SpringBoard: home gesture ended");
    __weak __typeof(self) weakSelf = self;
    // Quiet lasts 1.15s. This has to run before that ends, so the property
    // write is held with the rest of the home transition.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.85 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf restoreParkedHostsAfterHomeGesture];
        [weakSelf ejectHomeScreenFromStageWindow];
    });
}

- (BOOL)sceneIdentifier:(NSString *)identifier matchesHost:(DSSceneHost *)host {
    if (!host.isHosting || identifier.length == 0 || host.bundleIdentifier.length == 0) return NO;
    return [identifier rangeOfString:host.bundleIdentifier].location != NSNotFound;
}

- (void)noteHostedSceneIdentifier:(NSString *)identifier covered:(BOOL)covered {
    if ([DSSceneHost homeGestureIsActive]) return;
    BOOL primary = [self sceneIdentifier:identifier matchesHost:_sceneHost] && !_primaryParked;
    BOOL second = [self sceneIdentifier:identifier matchesHost:_topSceneHost] && !_secondParked;
    BOOL hovering = [self sceneIdentifier:identifier matchesHost:_floatSceneHost] && _floatActive;
    if (!primary && !second && !hovering) {
        [self keepMinimizedCardsBackgrounded];
        return;
    }
    if (covered) {
        _systemCover = YES;
        if (primary) [self holdPictureOfCard:_container];
        if (second) [self holdPictureOfCard:_topContainer];
        if (hovering) [self holdPictureOfCard:_floatContainer];
    } else if (_systemCover) {
        _systemCover = NO;
        if (primary) [self dropHeldPictureOnCard:_container];
        if (second) [self dropHeldPictureOnCard:_topContainer];
        if (hovering) [self dropHeldPictureOnCard:_floatContainer];
    }
    [self keepMinimizedCardsBackgrounded];
}

- (void)keepOnScreenStageInsideCardForSceneIdentifier:(NSString *)identifier {
    if ([DSSceneHost homeGestureIsActive]) return;
    // Nested inside an FBScene settings update: writing geometry / layout that
    // starts another update is the SIGTRAP. Defer until that update returns.
    if ([DSSceneHost sceneSettingsUpdateDepth] > 0) {
        if (identifier.length == 0) return;
        NSString *kept = [identifier copy];
        __weak __typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf keepOnScreenStageInsideCardForSceneIdentifier:kept];
        });
        return;
    }
    DSSceneHost *host = nil;
    if ([self sceneIdentifier:identifier matchesHost:_sceneHost] && !_primaryParked) host = _sceneHost;
    else if ([self sceneIdentifier:identifier matchesHost:_topSceneHost] && !_secondParked) host = _topSceneHost;
    else if ([self sceneIdentifier:identifier matchesHost:_floatSceneHost] && _floatActive) host = _floatSceneHost;
    if (!host.isHosting) return;
    [host refitPresentedScene];
    [host fitHostViewToCard];
}

// An open stage is still on screen when the home swipe starts. The swipe that
// survived had already parked the app and hidden the cards. Match that before
// SpringBoard runs its own transition. A card with no app is a picker: it is
// closed, not kept.
- (void)tuckOpenStageAwayForHomeGesture {
    BOOL hosting = _sceneHost.isHosting || _topSceneHost.isHosting;
    if (_state != DSStageStateOverlay && _state != DSStageStateTracking) {
        if (!hosting) return;
        _state = DSStageStateOverlay;
        _window.hidden = NO;
    }
    DSDiagnosticsRecord(@"SpringBoard: tucking the open stage for home");
    [self assignOppositeMinimizeSidesForHome];
    _keyboardFrame = CGRectZero;
    _keyboardDrawnOutside = NO;
    [self clearKeyboardSideShift];
    [_container setLiftOffset:0.0];
    if (_topContainer) [_topContainer setLiftOffset:0.0];

    NSMutableArray<DSStageContainerView *> *flying = [NSMutableArray array];
    if (_sceneHost.isHosting && !_primaryParked) {
        if (![self rememberedPictureForCard:_container]) [self rememberPictureForCard:_container];
        [self setParked:YES forCard:_container];
        _dragShell.hidden = NO;
        _dragShell.alpha = 1.0;
        _container.hidden = NO;
        _container.alpha = 1.0;
    }
    if (_topSceneHost.isHosting && !_secondParked && _topContainer) {
        if (![self rememberedPictureForCard:_topContainer]) [self rememberPictureForCard:_topContainer];
        [self setParked:YES forCard:_topContainer];
        _topContainer.hidden = NO;
        _topContainer.alpha = 1.0;
        if (_topRim) {
            _topRim.hidden = NO;
            _topRim.alpha = 1.0;
        }
    }
    if (_floatSceneHost.isHosting) {
        [_floatSceneHost setStaysBackgrounded:YES];
        [_floatSceneHost setFollowsSystemHomeTransition:YES];
        [self holdHostViewAtStageSize:_floatSceneHost];
    }
    _floatActive = NO;
    _floatContainer.hidden = YES;
    _floatContainer.alpha = 0.0;
    if (_floatRim) {
        _floatRim.hidden = YES;
        _floatRim.alpha = 0.0;
    }
    if (!_sceneHost.isHosting) {
        _primaryParked = NO;
        _container.hidden = YES;
        _container.alpha = 0.0;
        _dragShell.hidden = YES;
        _dragShell.alpha = 0.0;
        [_picker dismissKeyboard];
    }
    if (!_topSceneHost.isHosting) {
        _secondParked = NO;
        if (_topContainer) {
            _topContainer.hidden = YES;
            _topContainer.alpha = 0.0;
            _topContainer.hostingApp = NO;
        }
        if (_topRim) {
            _topRim.hidden = YES;
            _topRim.alpha = 0.0;
        }
        [_topPicker dismissKeyboard];
    }
    [self keepOnlyTheParkedAppAfterSplit];
    if (_primaryParked && _sceneHost.isHosting && _container) {
        _dragShell.hidden = NO;
        _dragShell.alpha = 1.0;
        _container.hidden = NO;
        _container.alpha = 1.0;
        [flying addObject:_container];
    }
    if (_secondParked && _topSceneHost.isHosting && _topContainer) {
        _topContainer.hidden = NO;
        _topContainer.alpha = 1.0;
        if (_topRim) {
            _topRim.hidden = NO;
            _topRim.alpha = 1.0;
        }
        [flying addObject:_topContainer];
    }
    // Home dismisses Split. The minimized app is an ordinary stage afterwards,
    // and a third stage cannot be opened from it.
    _splitMode = NO;
    _splitHomeRevealed = NO;
    _splitResizeHeight = 0.0;
    _expandedCard = nil;
    BOOL parked = (_primaryParked && _sceneHost.isHosting) || (_secondParked && _topSceneHost.isHosting);
    _state = parked ? DSStageStateMinimized : DSStageStateClosed;
    [self giveBackKeyWindow];
    [self updateHomeAffordance];
    for (DSStageContainerView *card in flying) {
        [self placeCard:card atFrame:[self cornerParkFrameForCard:card]];
        card.alpha = 0.0;
        if (card == _container) {
            _dragShell.alpha = 0.0;
            _dragShell.hidden = YES;
        }
        if (card == _topContainer) {
            card.hidden = YES;
            _topRim.alpha = 0.0;
            _topRim.hidden = YES;
        }
    }
    [UIView performWithoutAnimation:^{
        [self updateOpenAppIcon];
    }];
}

- (void)noteHomeGestureBegan:(UIPanGestureRecognizer *)gesture {
    DSHomeGestureGeneration += 1;
    NSInteger generation = DSHomeGestureGeneration;
    if (_stagedKeyboardSlot >= 0) {
        DSDiagnosticsRecord(@"SpringBoard: home gesture, putting the staged keyboard away");
        [self hideStagedKeyboardLikePicker];
    }
    [DSSceneHost setHomeGestureActive:YES];
    // Park first, and do not hand the app view to the home transition. That
    // handoff is the icon that keeps sliding after the card is gone.
    [self tuckOpenStageAwayForHomeGesture];
    DSDiagnosticsRecordFormat(@"SpringBoard: home gesture began, stage %@",
                              _state == DSStageStateMinimized ? @"minimized" :
                              (_state == DSStageStateOverlay ? @"open" :
                               (_state == DSStageStateTracking ? @"tracking" : @"closed")));
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != DSHomeGestureGeneration) return;
        [DSSceneHost setHomeGestureActive:NO];
        DSDiagnosticsRecord(@"SpringBoard: home gesture timed out");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.85 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (generation != DSHomeGestureGeneration) return;
            [weakSelf restoreParkedHostsAfterHomeGesture];
            [weakSelf ejectHomeScreenFromStageWindow];
        });
    });
    if (_sceneHost.isHosting && !_primaryParked) [self holdPictureOfCard:_container];
    if (_topSceneHost.isHosting && !_secondParked) [self holdPictureOfCard:_topContainer];
    if (_floatSceneHost.isHosting && _floatActive) [self holdPictureOfCard:_floatContainer];
    if (gesture) [gesture addTarget:self action:@selector(noteHomeGestureEnded:)];
}

- (void)noteFrontApplicationWillChange {
    NSString *bundle = [self frontApplication].bundleIdentifier;
    if (bundle.length > 0 && ![bundle isEqualToString:@"com.apple.springboard"]) {
        [[DSPreferences sharedPreferences] noteApplicationOpened:bundle];
        if (_picker && !_sceneHost.isHosting) [_picker reloadContent];
        if (_topPicker && _topContainer && !_topContainer.hidden && !_topSceneHost.isHosting) {
            [_topPicker reloadContent];
        }
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
