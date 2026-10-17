#import <dlfcn.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/time.h>
#import "DSCameraArbiter.h"
#import "DSStageManager.h"
#import "DSStageLiftState.h"
#import "DSStageWindow.h"
#import "DSStageContainerView.h"
#import "DSAppPickerViewController.h"
#import "DSSearchFieldView.h"
#import "DSRimCatcherView.h"
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
#import "DSInCallStage.h"

// 4.5.734 call733: while a call screen is up, coming, or just gone (the call653
// guard window, incl. its 4 s tail) or the stage has stepped aside for it, the
// stage's own movers do nothing: no tuck, no outside minimise, no kb707 move,
// no stuck727/heal700 forcing, no black731 host step. Cards stay as they are.
// Off: /var/mobile/.dynamicstage-call733-off (per-action latch).
static BOOL DSCall733HandsOff(NSString *who) {
    if (!DSFeature699On("call733")) return NO;
    BOOL active = NO;
    @try {
        active = DSCallStepAsideActive() || DSCallGuardActive();
    } @catch (NSException *exception) {
        active = NO;
    }
    if (!active) return NO;
    static CFAbsoluteTime lastLog;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastLog > 5.0) {
        lastLog = now;
        DSFeature719MarkAction("call733");
        DSDiagnosticsRecordFormat(@"SpringBoard: call733 call on screen: %@ left alone", who ?: @"?");
    }
    return YES;
}
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <sys/stat.h>
#import <unistd.h>
#import <stdio.h>
#import <pthread.h>

// Bumped when a hosted keyboard goes down so a late clip retry does not reopen it.
static NSInteger DSHostedClipGeneration = 0;
// One watch for Messages' real keyboard. A new arbiter event must not restart it.
static NSInteger DSMessagesKeyboardWatch = 0;
static BOOL DSMessagesKeyboardWatchArmed = NO;
// The arbiter's frame for Messages. A made-up 301pt rect is not stored here.


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

// 4.5.678 phonesize678 B: watches a touch on a card and never recognises.
// No delegate, cancels nothing, delays nothing, prevents nothing and cannot be
// waited on; it only reports touch-down, a move past 12 pt (a drag or scroll,
// not a tap) and the end. Plain UIKit, no hooks.
@interface DSPS678TouchObserver : UIGestureRecognizer
// YES: keep watching this touch (a pre-grow started); NO: drop out at once.
@property (nonatomic, copy) BOOL (^downHandler)(UITouch *touch, NSUInteger touchCount);
@property (nonatomic, copy) void (^endHandler)(BOOL moved, BOOL cancelled);
@end

@implementation DSPS678TouchObserver {
    CGPoint _start;
    BOOL _tracking;
}

- (instancetype)init {
    self = [super initWithTarget:nil action:NULL];
    if (self) {
        self.cancelsTouchesInView = NO;
        self.delaysTouchesBegan = NO;
        self.delaysTouchesEnded = NO;
    }
    return self;
}

- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer *)other { return NO; }
- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer *)other { return NO; }
- (BOOL)shouldRequireFailureOfGestureRecognizer:(UIGestureRecognizer *)other { return NO; }
- (BOOL)shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other { return NO; }

- (void)ps678Finish:(BOOL)moved cancelled:(BOOL)cancelled {
    if (!_tracking) return;
    _tracking = NO;
    void (^handler)(BOOL, BOOL) = self.endHandler;
    @try {
        if (handler) handler(moved, cancelled);
    } @catch (NSException *exception) {
    }
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    NSUInteger count = event.allTouches.count ?: touches.count;
    if (_tracking || count != 1) {
        [self ps678Finish:YES cancelled:NO];
        self.state = UIGestureRecognizerStateFailed;
        return;
    }
    UITouch *touch = touches.anyObject;
    if (!touch) {
        self.state = UIGestureRecognizerStateFailed;
        return;
    }
    _start = [touch locationInView:nil];
    BOOL (^handler)(UITouch *, NSUInteger) = self.downHandler;
    BOOL keep = NO;
    @try {
        keep = handler ? handler(touch, count) : NO;
    } @catch (NSException *exception) {
        keep = NO;
    }
    if (!keep) {
        self.state = UIGestureRecognizerStateFailed;
        return;
    }
    _tracking = YES;
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_tracking) return;
    UITouch *touch = touches.anyObject;
    if (!touch) return;
    CGPoint now = [touch locationInView:nil];
    if (hypot(now.x - _start.x, now.y - _start.y) < 12.0) return;
    [self ps678Finish:YES cancelled:NO];
    self.state = UIGestureRecognizerStateFailed;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self ps678Finish:NO cancelled:NO];
    self.state = UIGestureRecognizerStateFailed;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self ps678Finish:NO cancelled:YES];
    self.state = UIGestureRecognizerStateFailed;
}

- (void)reset {
    [super reset];
    [self ps678Finish:NO cancelled:YES];
}

@end

// The outline around a card. It is a rectangle only so the stroke can be drawn;
// touches belong to the band outside the card. A full-rectangle hit target is
// what makes a new stage drag from anywhere inside it.
@interface DSStageRimHitView : UIView
@property (nonatomic, assign) CGFloat hitBand;
// 4.5.651: how far the view's frame reaches past the card on each side (the
// card is inset(bounds, frameBand)), the window-server catchers around the
// card edge, and a window rect they must leave alone.
@property (nonatomic, assign) CGFloat frameBand;
@property (nonatomic, strong) NSArray<DSRimCatcherView *> *catchers;
@property (nonatomic, assign) CGRect catcherAvoid;
- (void)layoutRimCatchers;
// The rim is wider than the gap between the two stages. Points that land on the
// other card belong to that card, or a grab on the lower stage drags the upper one.
@property (nonatomic, copy) BOOL (^rejectsWindowPoint)(CGPoint windowPoint);
@end

@implementation DSStageRimHitView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _frameBand = kDSStageOuterDragBand + 18.0;
        _catcherAvoid = CGRectNull;
        _catchers = DSMakeRimCatchers(self, @"rim-outer", self);
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self layoutRimCatchers];
}

- (void)layoutRimCatchers {
    CGRect card = CGRectInset(self.bounds, self.frameBand, self.frameBand);
    BOOL usable = !self.hidden && CGRectGetWidth(card) > 40.0 && CGRectGetHeight(card) > 40.0;
    DSLayoutRimCatchersAvoiding(self.catchers, self, DSEdge741Outer(CGRectInset(card, -kDSRimOuterCatch, -kDSRimOuterCatch), card, self), card,
                                CGFLOAT_MAX, usable, self.catcherAvoid);
}

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

static void DSNameRimCatchers(NSArray<DSRimCatcherView *> *strips, NSString *name) {
    // 4.5.741 log741: no static NSString C array (its "left" entry came out as
    // garbage on device, "top-outer-\u00eb\u00c1", which cut the log line short).
    NSString *(^sides741)(NSUInteger) = ^NSString *(NSUInteger k) { switch (k) { case 0: return @"top"; case 1: return @"bottom"; case 2: return @"left"; default: return @"right"; } };
    for (NSUInteger i = 0; i < strips.count && i < 4; i++) {
        strips[i].catcherName = [NSString stringWithFormat:@"%@-%@", name, sides741((NSUInteger)i)];
    }
}


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

// 4.5.779 backspace779: holding delete removed one letter. This field is
// emptied after every key, and UIKit's held-delete repeat only keeps going while
// the field has text before the caret, so the repeat stopped after the first
// delete. The field now keeps a fixed filler ("x x ... x", autocorrect, smart
// edits and capitalisation are already off) and is reset to it after every key,
// so held delete repeats like a native field. Ends in "x" so the double-space
// period shortcut never fires. Off: /var/mobile/.dynamicstage-backspace779-off (core780-off too).
static NSString *DSStagedKeyboardFiller(void) {
    if (!DS780On("backspace779")) return @"";
    static NSString *filler = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableString *f = [NSMutableString string];
        for (int i = 0; i < 40; i++) [f appendString:@"x "];
        [f appendString:@"x"];
        filler = [f copy];
    });
    return filler;
}

// 4.5.805 predict805 (opt-in: /var/mobile/.dynamicstage-predict805-on, off
// file predict805-off, latch predict805). SpringBoard's keyboard shows its
// QuickType row: the hidden field keeps UIKit's default autocorrection and
// spell checking. Accepted suggestions arrive here as a replacement
// (range.length > 0 with text); they are logged and NOT sent on, because no
// verified way to replace a word in the staged app exists yet. Plain typing
// (range.length == 0) and deletes go on exactly as before.
static BOOL DS805PredictOn(void) {
    static int on = -1;
    if (on < 0) {
        on = (access("/var/mobile/.dynamicstage-predict805-on", F_OK) == 0 && DS805On("predict805")) ? 1 : 0;
        if (on) DSFeature699MarkTrying("predict805");
    }
    return on == 1;
}

@implementation DSStagedKeyboardField

- (BOOL)hasText {
    return YES;
}

- (BOOL)becomeFirstResponder {
    @try {
        NSString *filler = DSStagedKeyboardFiller();
        if (![self.text isEqualToString:filler]) {
            self.forwardingEdit = YES;
            self.text = filler;
            self.forwardingEdit = NO;
        }
    } @catch (NSException *exception) {
        self.forwardingEdit = NO;
    }
    return [super becomeFirstResponder];
}

- (void)insertText:(NSString *)text {
    if (self.forwardingEdit || text.length == 0) return;
    if (DS805PredictOn()) DSDiagnosticsRecordFormat(@"SpringBoard: predict805 insertText %lu chars", (unsigned long)text.length);
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
    if (DS805PredictOn() && string.length > 0 && range.length > 0) {
        DSFeature719MarkAction("predict805");
        DSDiagnosticsRecordFormat(@"SpringBoard: predict805 replace range={%lu,%lu} with %lu chars (a suggestion / autocorrect): logged, not sent to the app",
                                  (unsigned long)range.location, (unsigned long)range.length, (unsigned long)string.length);
        self.forwardingEdit = YES;
        self.text = DSStagedKeyboardFiller();
        self.forwardingEdit = NO;
        return NO;
    }
    if (DS805PredictOn() && string.length > 1) {
        DSDiagnosticsRecordFormat(@"SpringBoard: predict805 insert of %lu chars at the caret (sent on as typed)", (unsigned long)string.length);
    }
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
    self.text = DSStagedKeyboardFiller();
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

- (void)replaceRange:(UITextRange *)range withText:(NSString *)text {
    if (DS805PredictOn()) {
        DSFeature719MarkAction("predict805");
        DSDiagnosticsRecordFormat(@"SpringBoard: predict805 replaceRange:withText: %lu chars (logged, not sent to the app)", (unsigned long)text.length);
        return;
    }
    [super replaceRange:range withText:text];
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

static BOOL DS795RingReady(void);
static int DS795RingTokens[kDSKeyboardRingSlots];
static void DSPostKeyboardInputState(uint32_t seq, BOOL isDelete, UTF32Char code) {
    // 4.5.795 keyring795: the ring slot is always written (memory only), so
    // the app can read every key whichever transport SpringBoard is on.
    if (DS795RingReady()) {
        uint64_t ring = seq;
        if (isDelete) ring |= (1ULL << 32);
        else ring |= ((uint64_t)code & 0x1FFFFF) << 33;
        notify_set_state(DS795RingTokens[seq % kDSKeyboardRingSlots], ring);
    }
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

// ---- 4.5.795 keyring795 ------------------------------------------------------
// Rule: typed keys never touch the disk. 794 appended every key to a 0666
// plist in /var/tmp (readable and writable by any process) and rewrote it on
// the main thread per key. Now each key goes into a notify-state ring slot,
// then the main state is set and posted. Off: keyring795-off / core795-off
// (crash latch keyring795) brings back the file.
static BOOL DS795KeyringOn(void) { return DS795On("keyring795"); }
static uint32_t DS795Seq = 0;
static BOOL DS795RingReady(void) {
    static BOOL ready = NO;
    if (ready) return YES;
    for (int i = 0; i < kDSKeyboardRingSlots; i++) {
        char name[96];
        snprintf(name, sizeof(name), kDSKeyboardRingFormat, i);
        DS795RingTokens[i] = NOTIFY_TOKEN_INVALID;
        if (notify_register_check(name, &DS795RingTokens[i]) != NOTIFY_STATUS_OK) return NO;
    }
    // The app keeps the newest seq it applied; a new SpringBoard must count on
    // from there: the main state survives a respring, and the clock is the floor.
    int main = NOTIFY_TOKEN_INVALID;
    uint64_t state = 0;
    if (notify_register_check(kDSKeyboardInputNotification, &main) == NOTIFY_STATUS_OK) notify_get_state(main, &state);
    uint32_t last = (uint32_t)(state & 0xFFFFFFFF);
    uint32_t clock = (uint32_t)((uint64_t)(CFAbsoluteTimeGetCurrent() * 4.0) & 0x7FFFFFFF);
    DS795Seq = last > clock ? last : clock;
    ready = YES;
    return YES;
}
static void DSPostKeyboardInputState(uint32_t seq, BOOL isDelete, UTF32Char code);
static BOOL DS795SendKey(BOOL isDelete, NSArray<NSNumber *> *scalars) {
    if (!DS795RingReady()) return NO;
    static BOOL removed = NO;
    if (!removed) {   // the 794 file held the last 40 typed keys
        removed = YES;
        unlink(kDSKeyboardInputPath.fileSystemRepresentation);
    }
    DSFeature719MarkAction("keyring795");
    NSUInteger n = isDelete ? 1 : scalars.count;
    for (NSUInteger k = 0; k < n; k++) {
        uint32_t seq = ++DS795Seq;
        UTF32Char code = isDelete ? 0 : (UTF32Char)scalars[k].unsignedIntValue;
        uint64_t state = seq;
        if (isDelete) state |= (1ULL << 32);
        else state |= ((uint64_t)code & 0x1FFFFF) << 33;
        (void)state;
        DSPostKeyboardInputState(seq, isDelete, code);   // writes the ring slot too
    }
    return YES;
}

@interface DSStageManager (Kbfocus801)
- (BOOL)kbfocus801IsActive;
@end

static void DSEnqueueStagedKey(NSString *op, NSString *text) {
    if (op.length == 0) return;
    // 4.5.801: while kbfocus801 owns focus, skip keyring / msg742 relay.
    if ([[DSStageManager sharedManager] kbfocus801IsActive]) return;
    BOOL isDelete = [op isEqualToString:@"delete"];
    if (DS795KeyringOn()) {
        NSArray<NSNumber *> *keys = isDelete ? @[] : DSUTF32Scalars(text);
        if (!isDelete && keys.count == 0) return;
        if (DS795SendKey(isDelete, keys)) return;
    }
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

// 4.5.671: DSAppTraceRelay.m. YES while the app's DynamicStageApp.dylib
// marker is live in its container.
BOOL DSAppTraceRelayBundleIsLive(NSString *bundle);

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

// ---- 4.5.698 anim698: smooth minimise to the corner ---------------------------
// Before: the card itself was animated from 420x458 to a 56x56 square past the
// corner (UIView frame animation, 0.32 s ease-in). That animates the bounds of a
// card with three rounded clips, a mask layer, a blur backdrop and rim catchers;
// the mask and the outline are plain layers that jumped or ran their own default
// animation, and the whole stack layout ran inside the animation block.
// Now: one snapshot of the card (snapshotViewAfterScreenUpdates:NO, the same call
// the drag already uses) flies to the corner with a single transform+position
// animation; the real card is placed at its (off-screen) corner frame at once,
// outside any animation. A fast flick (which used to vanish on the spot) gets a
// short 0.18 s ease-out flight of the snapshot while the stage finishes at once.
// Off: /var/mobile/.dynamicstage-anim698-off (crash latch anim698-trying/-crashed).
@interface DSAnim698FrameMeter : NSObject
@property (nonatomic, copy) NSString *name;
- (void)start;
- (void)stop;
@end

@implementation DSAnim698FrameMeter {
    CADisplayLink *_link;
    CFTimeInterval _startedAt;
    CFTimeInterval _last;
    unsigned long _frames;
    unsigned long _slow;
    double _maxGap;
}

- (void)start {
    if (!DSPerfLogOn() || _link) return;
    _startedAt = CACurrentMediaTime();
    _last = 0;
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)tick:(CADisplayLink *)link {
    CFTimeInterval now = link.timestamp;
    CFTimeInterval expected = link.targetTimestamp - link.timestamp;
    if (!(expected > 0.001 && expected < 0.05)) expected = link.duration > 0.001 ? link.duration : (1.0 / 60.0);
    if (_last > 0) {
        double gap = now - _last;
        if (gap * 1000.0 > _maxGap) _maxGap = gap * 1000.0;
        if (gap > expected * 1.5) _slow += 1;
    }
    _last = now;
    _frames += 1;
}

- (void)stop {
    if (!_link) return;
    [_link invalidate];
    _link = nil;
    DSPerfNoteAnimation(self.name.UTF8String ?: "?", (CACurrentMediaTime() - _startedAt) * 1000.0, _frames, _slow, _maxGap);
}
@end

static char kDSAnim698FlightKey;

// ---- 4.5.702 anim702: one spring for minimise and restore -----------------------
// Fixed values (4.5.702 removed every user tune file; these are not tunable).
static char kDSAnim702AnimatorKey;
static const NSTimeInterval kDSAnim702MinimiseDuration = 0.40;
static const NSTimeInterval kDSAnim702FlickDuration = 0.34;
static const NSTimeInterval kDSAnim702RestoreDuration = 0.44;
static const CGFloat kDSAnim702Damping = 0.86;   // critically damped feel, a hint of settle
static const CGFloat kDSAnim702IconRadius = 9.0;  // the corner icon's radius

static UISpringTimingParameters *DSAnim702Spring(CGFloat velocity) {
    if (!isfinite(velocity)) velocity = 0.0;
    velocity = MAX(0.0, MIN(velocity, 10.0));
    return [[UISpringTimingParameters alloc] initWithDampingRatio:kDSAnim702Damping initialVelocity:CGVectorMake(velocity, velocity)];
}

// Release speed (pt/s) along the path, as UIKit's spring velocity (path lengths per second).
static CGFloat DSAnim702PathVelocity(CGPoint velocity, CGPoint from, CGPoint to) {
    CGFloat dx = to.x - from.x, dy = to.y - from.y;
    CGFloat d2 = dx * dx + dy * dy;
    if (!(d2 > 1.0) || !isfinite(velocity.x) || !isfinite(velocity.y)) return 0.0;
    return (velocity.x * dx + velocity.y * dy) / d2;
}

// 4.5.702 multi702: the [KEYS] / [LIFT] debug lines (with a summary of every
// card) were built on every keyboard notification and then dropped when the
// log is quiet; not built at all now.
static BOOL DSMulti702BuildLog(void) {
    return !DSLogQuiet() || !DSFeature699On("multi702");
}

@interface DSStageManager ()
- (void)launch740AppOpenedFullScreen:(NSString *)bundle;
- (NSSet<NSString *> *)picker740FullScreenBundles;
- (NSString *)perf705GaugeLine;
@end

static NSString *DSPerf705Gauge(void) {
    if (![NSThread isMainThread]) return nil;
    return [[DSStageManager sharedManager] perf705GaugeLine];
}

// 4.5.746 src746: names the path that produced a keyboard note (main thread only).
static NSString *DSSrc746Tag = nil;

// 4.5.754 log754: call-stack tags as image + offset from the image start
// ("DynamicStage+0x1a2b4 < UIKitCore+0x5c10"), which can be looked up in the
// build; the nearest exported symbol was wrong for everything else (753 log:
// every frame read "DSFold752On + N"). Off: log754-off / core754-off.
static BOOL DSLog754On(void) {
    return DSFeature699On("core754") && DSFeature699On("log754");
}

static NSString *DSCaller754(NSUInteger skip, NSUInteger count, BOOL firstOurs) {
    NSArray<NSNumber *> *addrs = [NSThread callStackReturnAddresses];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSUInteger i = skip; i < addrs.count && parts.count < count; i++) {
        Dl_info info;
        memset(&info, 0, sizeof(info));
        uintptr_t a = (uintptr_t)addrs[i].unsignedLongLongValue;
        if (!dladdr((const void *)a, &info) || !info.dli_fbase) continue;
        const char *slash = info.dli_fname ? strrchr(info.dli_fname, '/') : NULL;
        NSString *image = [NSString stringWithUTF8String:slash ? slash + 1 : (info.dli_fname ?: "?")] ?: @"?";
        if ([image hasSuffix:@".dylib"]) image = [image stringByDeletingPathExtension];
        if (firstOurs && parts.count == 0 && ![image isEqualToString:@"DynamicStage"]) continue;
        [parts addObject:[NSString stringWithFormat:@"%@+0x%lx", image, (unsigned long)(a - (uintptr_t)info.dli_fbase)]];
    }
    return parts.count ? [parts componentsJoinedByString:@" < "] : @"?";
}

// 4.5.755: each fix has its own off file and crash latch; core755-off turns
// all of them off (the 754 behaviour).
static BOOL DSCore755On(void) { return DSFeature699On("core755"); }
static BOOL DSSpring755On(void) { return DSCore755On() && DSFeature699On("spring755"); }
static BOOL DSLift755On(void) { return DSCore755On() && DSFeature699On("lift755"); }
static BOOL DSName755On(void) { return DSCore755On() && DSFeature699On("name755"); }
static BOOL DSType755On(void) { return DSCore755On() && DSFeature699On("type755"); }
static BOOL DSFocus755On(void) { return DSCore755On() && DSFeature699On("focus755"); }
// 4.5.756: each fix has its own off file and crash latch; core756-off = 4.5.755.
static BOOL DSCore756On(void) { return DSFeature699On("core756"); }
static BOOL DS756On(const char *name) { return DSCore756On() && DSFeature699On(name); }
// 4.5.757: master core757-off returns to 4.5.756.
static BOOL DSCore757On(void) { return DSFeature699On("core757"); }
static BOOL DS757On(const char *name) { return DSCore757On() && DSFeature699On(name); }
// 4.5.759: master core759-off returns to 4.5.758.
static BOOL DSCore759On(void) { return DSFeature699On("core759"); }
static BOOL DS759On(const char *name) { return DSCore759On() && DSFeature699On(name); }
// Filled by the appview670 hook in Tweak.xm (focus755 diagnostic, log only).
extern NSString *DSFocus755LastFor(NSString *bundle, CFAbsoluteTime *at);

void DSGest770NoteEvent(NSString *why);


// 4.5.808 lock808 observer (kept alive by a static; SpringBoard's observer list
// may be weak).
@interface DSLock808Observer : NSObject
@end
@implementation DSLock808Observer
- (void)backlightController:(id)controller didTransitionToBacklightState:(long long)state source:(long long)source {
    @try {
        if (!NSThread.isMainThread) {
            dispatch_async(dispatch_get_main_queue(), ^{ [[DSStageManager sharedManager] lock808NoteBacklight:state source:source]; });
            return;
        }
        [[DSStageManager sharedManager] lock808NoteBacklight:state source:source];
    } @catch (NSException *exception) {}
}
@end

static void DSLock808Install(void) {
    static DSLock808Observer *observer = nil;
    if (observer || !DS808On("lock808")) return;
    @try {
        Class cls = objc_getClass("SBBacklightController");
        id bl = [cls respondsToSelector:@selector(sharedInstance)] ? ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedInstance)) : nil;
        if (![bl respondsToSelector:@selector(addObserver:)]) { DSDiagnosticsRecord(@"SpringBoard: lock808 not installed (SBBacklightController addObserver: not found)"); return; }
        observer = [DSLock808Observer new];
        ((void (*)(id, SEL, id))objc_msgSend)(bl, @selector(addObserver:), observer);
        DSDiagnosticsRecord(@"SpringBoard: lock808 installed (SBBacklightController observer)");
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: lock808 install threw %@", exception.name ?: @"?");
    }
}

@implementation DSStageManager {
    NSString *_type755Owner;
    NSMutableDictionary<NSString *, NSNumber *> *_full756KeysY;   // coalesce756: full keys top per app
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
    BOOL _defer719Done;    // 4.5.719
    BOOL _defer719Queued;
    BOOL _stashedLeft;
    BOOL _stashedLeft2;
    UIView *_stashHolder;
    BOOL _restoreWoke;
    BOOL _systemCover;
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
    // 4.5.700 spam700 / heal700 (see spam700Note:).
    NSUInteger _spam700Gen;
    NSInteger _spam700Intent;          // 0 none, 1 minimise, 2 restore / open
    NSUInteger _spam700PendingGen;     // a minimise whose completion has not run yet
    BOOL _spam700MinimisePending;
    void (^_spam700DeferredFinish)(void);
    NSInteger _heal700Ticks;
    BOOL _battery701Marked;
    __weak DSStageContainerView *_heal700Card;
    // 4.5.702
    NSHashTable<UIViewPropertyAnimator *> *_anim702Running;
    BOOL _anim702NextSpring;
    CGFloat _anim702NextVelocity;
    CGPoint _anim702ReleaseVelocity;
    __weak DSStageContainerView *_drag702Card;
    __weak UIPanGestureRecognizer *_drag702Recognizer;
    BOOL _drag702Writing;
    NSUInteger _drag702Held;
    NSString *_kbmin702Source;
    NSUInteger _kbmin702Gen;
    // 4.5.704 focus704 (see focus704Evaluate:). 4.5.715: only the typing
    // source and the schedule generation are left (kb707 reads them).
    NSString *_focus704KeysBundle;
    NSUInteger _focus704Gen;
    // 4.5.705 focus705 (see focus705On).
    NSUInteger _focus705HideGen;
    BOOL _focus705Replaying;
    BOOL _activated;

    UIPanGestureRecognizer *_dragPan;
    // While a card is being dragged, the home gesture must not take the
    // bottom-centre band. That steal is what cancelled Terminate.
    BOOL _stageDragActive;
    UIPanGestureRecognizer *_systemPull;
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
    // 4.5.801 kbfocus801: real SBWorkspaceKeyboardFocusController focus for the
    // staged scene (bypass stand-in / keyring while active).
    BOOL _kbfocus801Active;
    NSString *_kbfocus801Bundle;
    NSString *_kbfocus802Bundle;      // 4.5.802: focus requested (once) for this bundle
    BOOL _kbfocus802ProofLogged;
    NSInteger _hide802Generation;     // 4.5.802 hide802: generation after the last staged-keyboard hide
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
    // 4.5.706 drag706 / perf706 / polish706
    CFAbsoluteTime _drag706Since;
    NSString *_drag706Seen;
    NSUInteger _drag706Settles;
    BOOL _drag706CheckQueued;
    BOOL _drag706GaveUp;
    BOOL _drag706TileCleared;
    NSUInteger _perf706TickGen;
    NSTimeInterval _perf706LastDelay;
    BOOL _perf706Marked;
    BOOL _polish706Marked;
    // 4.5.707 kb707 / corner707 / outside707
    BOOL _kb711Marked;
    CGPoint _outside707Point;
    BOOL _outside707Queued;
    CFAbsoluteTime _outside707QuietUntil;
    BOOL _outside712Marked;
    __weak DSStageContainerView *_kb707Owner;
    BOOL _kb707Active;
    BOOL _kb707Writing;
    BOOL _kb707CheckQueued;
    NSUInteger _kb707Gen;
    NSInteger _kb707Defers;
    CFAbsoluteTime _kb707AbsentSince;
    NSString *_kb707Logged;
    // 4.5.720 kb720: one owner per keyboard state
    __weak DSStageContainerView *_kb720OwnerCard;
    CGFloat _kb720OwnerLift;
    __weak DSStageContainerView *_kb720OtherCard;
    CGFloat _kb720OtherSide;
    CFAbsoluteTime _kb720ShowAt;
    NSMutableDictionary<NSString *, NSNumber *> *_kb720SaidAt;
    // 4.5.723 kb723 (kb721's fixes without the split takeover)
    CGRect _kb723ArbiterKeys;
    NSString *_kb723ArbiterBundle;
    CFAbsoluteTime _kb723MissSince;
    CFAbsoluteTime _kb723OverlapSince;
    BOOL _kb723CheckQueued;
    CFAbsoluteTime _kb723QuietUntil;
    // 4.5.725 sync725
    CFAbsoluteTime _sync725HideAt;
    CGFloat _sync725FullKeysY;
    NSUInteger _sync725Gen;
    NSUInteger _kb744HideGen;
    CFAbsoluteTime _ghost745HideAt;
    CFAbsoluteTime _ghost745ShowAt;
    BOOL _loop745Block;
    // 4.5.747 core747: one keyboard state + one card-move path.
    NSUInteger _ks747Seq;
    BOOL _ks747ArbOn;
    NSString *_ks747ArbOwner;
    CFAbsoluteTime _ks747ArbAt;
    CGRect _ks747ArbFrame;
    UIViewPropertyAnimator *_mv747Animator;
    NSUInteger _mv747Gen;
    NSMutableDictionary<NSString *, NSString *> *_host750State;
    NSMutableDictionary<NSString *, NSString *> *_host754Bundle;
    NSMutableDictionary<NSString *, NSString *> *_host754Pending;
    NSMutableDictionary<NSString *, NSNumber *> *_host754PendingAt;
    BOOL _host754TickQueued;
    CFAbsoluteTime _stuck750SeenAt[2];
    // 4.5.726 outside726 / restore726
    CFAbsoluteTime _outside726CardTouchAt;
    CFAbsoluteTime _restore726PullAt;
    NSMutableDictionary<NSString *, NSNumber *> *_restore726SaidAt;
    // 4.5.727 stuck727 / flick727
    CFAbsoluteTime _stuck727SeenAt[2];
    BOOL _stuck727Queued;
    // 4.5.728 kbshow728 / pull728
    NSString *_kbshow728Bundle;
    CFAbsoluteTime _kbshow728At;
    NSInteger _kbshow728Tries;
    NSUInteger _kbshow728Gen;
    CFAbsoluteTime _pull728DragMinAt;
    BOOL _corner771Marked;
    BOOL _keyfocus772Forcing;
    BOOL _keyfocus772Marked;
    BOOL _keyfocus773Marked;
    BOOL _rekey775Marked;
    // 4.5.771 corner771
    __weak UIGestureRecognizer *_corner771MinGesture;
    __weak UIPanGestureRecognizer *_corner771QueuedPull;
    __weak DSStageContainerView *_corner771QueuedCard;
    NSUInteger _corner771QueuedGen;
    BOOL _corner771QueuedLeft;
    // 4.5.731 home731 / kbown731
    BOOL _home731Pending;
    NSString *_kbown731Source;
    CFAbsoluteTime _kbown731At;
    // 4.5.733 flick733 / grab733
    CGRect _flick733From;
}

static BOOL sSystemEdgePullAvailable;

// ---- 4.5.657: ivar-level answers for SpringBoard hooks ------------------------
// The shared manager never goes away; this is the pointer the C accessors read.
static __unsafe_unretained DSStageManager *DSStageManagerFast = nil;
static NSMutableArray<NSString *> *DSPendingOpenedBundles = nil;
static BOOL DSPendingFrontQuery = NO;
static BOOL DSDeathCheckScheduled = NO;

static inline BOOL DSStageFastCardShown(DSStageContainerView *card, BOOL parked) {
    return card != nil && !parked && !card.hidden && card.alpha > 0.05;
}

BOOL DSStageVisibleFast(void) {
    DSStageManager *m = DSStageManagerFast;
    if (!m || !m->_activated) return NO;
    return m->_state == DSStageStateOverlay || m->_state == DSStageStateTracking;
}

// 4.5.670: a card drag in progress, or one that ended less than `window`
// seconds ago (the drop animation and the settle that follow it). The camera
// arbiter keeps its display-layout element still and the app-view hook holds
// SpringBoard's own app-view updates for the staged app over that time.
static CFTimeInterval DSStageDragEndedAt = 0;

BOOL DSStageDragSettlingFast(double window) {
    DSStageManager *m = DSStageManagerFast;
    if (!m || !m->_activated) return NO;
    if (m->_stageDragActive) return YES;
    return DSStageDragEndedAt > 0 && CACurrentMediaTime() - DSStageDragEndedAt < window;
}

// 4.5.706 drag706: the Saferestmode SIGTRAP (4.5.704, 18:14:31) was SpringBoard's
// own Live app-view update handler right after a corner pull restored Beeper and
// grew it to its 684 size: the same shape as the 670 drag trap. While a corner
// pull / restore runs, and `window` s after it, the Live app view is held like
// after a card drag.
static CFTimeInterval DSStageRestore706At = 0;
// 4.5.706 drag706: the pan that owns the current card drag, and the mark on a
// pan that began while another one held a card (ignored until it ends).
static __weak UIPanGestureRecognizer *DSDrag706Owner = nil;
static char kDSDrag706IgnoredKey;

static void DSStageRestore706Note(void) {
    DSStageRestore706At = CACurrentMediaTime();
}

BOOL DSStageRestoreSettlingFast(double window) {
    DSStageManager *m = DSStageManagerFast;
    if (!m || !m->_activated) return NO;
    if (m->_cornerRestoreCard) return YES;
    return DSStageRestore706At > 0 && CACurrentMediaTime() - DSStageRestore706At < window;
}

BOOL DSStageGestureRelevantFast(void) {
    DSStageManager *m = DSStageManagerFast;
    if (!m || !m->_activated) return NO;
    return m->_stageDragActive || m->_state == DSStageStateOverlay || m->_state == DSStageStateTracking;
}

BOOL DSStageHasSceneHostFast(void) {
    DSStageManager *m = DSStageManagerFast;
    if (!m || !m->_activated) return NO;
    return m->_sceneHost != nil || m->_topSceneHost != nil || m->_floatSceneHost != nil ||
           m->_stashedHost != nil || m->_stashedHost2 != nil;
}

// 4.5.742 msg742: staged Messages runs exactly the 739 paths. Every 740/741
// addition that can touch its scene updates, keyboard window or key / scene
// moves (hold740 replay + reactivation pass, raise740/741 trimming, open741
// skips, launch740, picker740) stands aside while Messages is on a card.
// Off (= 741 behaviour for Messages): /var/mobile/.dynamicstage-msg742-off.
BOOL DSStage742MessagesStaged(void) {
    if (![NSThread isMainThread]) return NO;
    DSStageManager *m = DSStageManagerFast;
    if (!m || !m->_activated) return NO;
    if (!DSFeature699On("msg742")) return NO;
    static NSString *const sms = @"com.apple.MobileSMS";
    @try {
        for (DSSceneHost *h in @[ m->_sceneHost ?: (id)NSNull.null, m->_topSceneHost ?: (id)NSNull.null, m->_floatSceneHost ?: (id)NSNull.null,
                                  m->_stashedHost ?: (id)NSNull.null, m->_stashedHost2 ?: (id)NSNull.null ]) {
            if ([h isKindOfClass:DSSceneHost.class] && [h.bundleIdentifier isEqualToString:sms]) return YES;
        }
    } @catch (NSException *exception) {
    }
    return NO;
}

BOOL DSStageHasParkedCardFast(void) {
    DSStageManager *m = DSStageManagerFast;
    if (!m || !m->_activated) return NO;
    return m->_primaryParked || m->_secondParked;
}

BOOL DSStageCardOnScreenFast(void) {
    // Views are read here; off the main thread the answer is "no card".
    if (!pthread_main_np()) return NO;
    DSStageManager *m = DSStageManagerFast;
    if (!m || !m->_activated) return NO;
    if (m->_state != DSStageStateOverlay && m->_state != DSStageStateTracking) return NO;
    if (DSCallStepAsideActive()) return NO;
    if ([DSSceneHost homeGestureIsActive]) return NO;
    if (m->_state == DSStageStateTracking) return YES;
    if (DSStageFastCardShown(m->_container, m->_primaryParked)) return YES;
    if (DSStageFastCardShown(m->_topContainer, m->_secondParked)) return YES;
    if (m->_floatActive && DSStageFastCardShown(m->_floatContainer, NO)) return YES;
    return NO;
}

// Only a card on screen means the user is looking at the stage (not the
// switcher, not the Home Screen): then the death is handled right away.
// Otherwise it waits for the next stage use. One check per kill, no poll.
static void DSStageScheduleDeathCheck(void) {
    if (DSDeathCheckScheduled) return;
    DSDeathCheckScheduled = YES;
    double delay = DSStageCardOnScreenFast() ? 0.05 : 2.5;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DSDeathCheckScheduled = NO;
        if (!DSSceneHostAnyDiedPending() || !DSStageCardOnScreenFast()) return;
        @try {
            [DSStageManagerFast noteStageUse];
        } @catch (NSException *exception) {
        }
    });
}

static void DSStageNoteBundleKilledOnMain(NSString *bundle) {
    DSStageManager *m = DSStageManagerFast;
    if (!m || !m->_activated || bundle.length == 0) return;
    BOOL ours = [m->_sceneHost.bundleIdentifier isEqualToString:bundle] ||
                [m->_topSceneHost.bundleIdentifier isEqualToString:bundle] ||
                [m->_floatSceneHost.bundleIdentifier isEqualToString:bundle];
    if (!ours) return;
    DSSceneHostMarkBundleDied(bundle);
    DSStageScheduleDeathCheck();
}

void DSStageNoteBundleKilled(NSString *bundleIdentifier) {
    if (bundleIdentifier.length == 0 || !DSStageHasSceneHostFast()) return;
    if (NSThread.isMainThread) {
        DSStageNoteBundleKilledOnMain(bundleIdentifier);
        return;
    }
    NSString *bundle = [bundleIdentifier copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        DSStageNoteBundleKilledOnMain(bundle);
    });
}

void DSStageNoteFrontDisplayChanged(id display) {
    DSStageManager *m = DSStageManagerFast;
    if (!m || !m->_activated) return;
    NSString *bundle = nil;
    @try {
        if ([display respondsToSelector:@selector(bundleIdentifier)]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(display, @selector(bundleIdentifier));
            if ([value isKindOfClass:NSString.class]) bundle = value;
        }
    } @catch (NSException *exception) {
    }
    if (bundle.length > 0) {
        if (![bundle isEqualToString:@"com.apple.springboard"]) {
            if (!DSPendingOpenedBundles) DSPendingOpenedBundles = [NSMutableArray array];
            [DSPendingOpenedBundles removeObject:bundle];
            [DSPendingOpenedBundles addObject:[bundle copy]];
            if (DSPendingOpenedBundles.count > 12) [DSPendingOpenedBundles removeObjectAtIndex:0];
        }
    } else if (display) {
        DSPendingFrontQuery = YES;
    }
    // 4.5.740 launch740: the staged app itself was opened full screen.
    if (bundle.length > 0 && DSStageHasSceneHostFast() && DSFeature699On("launch740")) {
        NSString *opened = [bundle copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                [DSStageManagerFast launch740AppOpenedFullScreen:opened];
            } @catch (NSException *exception) {
                DSDiagnosticsRecordFormat(@"SpringBoard: launch740 caught %@", exception.reason ?: exception.name ?: @"?");
            }
        });
    }
    // Unchanged from before: a stage left open with the tweak switched off.
    if (m->_state == DSStageStateOverlay && ![DSPreferences sharedPreferences].enabled) {
        [m closeStageAnimated:NO];
    }
    // With a card on screen the user is on the stage: apply now (async).
    if (DSStageCardOnScreenFast()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                [DSStageManagerFast noteStageUse];
            } @catch (NSException *exception) {
            }
        });
    }
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
        DSStageManagerFast = self;
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
    [self blackout696ScheduleTick];

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
        DSStageManager *manager = weakSelf;
        // 4.5.712 outside707: armed only while a stage is on screen (overlay);
        // hitTest reads this one flag and does nothing else when it is NO.
        if (manager) manager->_window.outsideArmed = manager->_state == DSStageStateOverlay;
        BOOL captured = [manager shouldWindowCaptureTouchAtPoint:point];
        // 4.5.726 outside726: the time of the last touch the stage took (a card).
        if (captured && manager) manager->_outside726CardTouchAt = CFAbsoluteTimeGetCurrent();
        return captured;
    };
    _window.outsideTouch = ^(CGPoint point) {
        [weakSelf outside707NoteTouchAt:point];
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
    _container.rimCatcherName = @"main-inner";

    _picker = DSNewAppPicker817();
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
    if (DSNative703On()) {
        // 4.5.703: the system footnote style, following the user's text size.
        _terminateHint.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        _terminateHint.adjustsFontForContentSizeCategory = YES;
    }
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
    // 4.5.719 defer719: the touch observer is no longer set up here, while
    // SpringBoard is still starting (4.5.717 crashed on this class's first use
    // in buildWindow). It goes on the card lazily when an app is first staged.
    // Off: /var/mobile/.dynamicstage-defer719-off = set it up here as before.
    if (!DSFeature699On("defer719")) [self phoneSize678ObserveTouchesOnCard:_container];

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
    // 4.5.657: each of these is a stage use (deferred switcher work runs first).
    _shelf.willOpenHandler = ^{
        [weakSelf noteStageUse];
        [weakSelf refreshShelf];
    };
    _shelf.halfHandler = ^(NSInteger half) {
        [weakSelf noteStageUse];
        [weakSelf beginStageOnHalf:half];
    };
    _shelf.slotDragHandler = ^(UIGestureRecognizerState state, CGPoint point) {
        if (state == UIGestureRecognizerStateBegan) [weakSelf noteStageUse];
        [weakSelf handleNewStageDrag:state atPoint:point];
    };
    _shelf.halfHoldHandler = ^(NSInteger half) {
        [weakSelf noteStageUse];
        [weakSelf returnHalfToPicker:half];
    };
    [root addSubview:_shelf];

    [self applyAppearance];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(native703TraitsChanged:) name:@"DSNative703TraitsChanged" object:nil];
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

// ---- 4.5.772 keyfocus772 --------------------------------------------------------
// Oaksk 02:09:01: Beeper's keys were hidden 0.1 s after they showed, with the
// home screen window key (show 2, with an app's window key, was fine). The
// stage takes the key window back the way it does on every open
// (takeKeyWindow: resign the competing key window, make the stage window key).
// Nothing forces Medusa visible; UITextEffectsWindow and the dock are untouched.
// (1) On a corner restore with a non-stage window key and no keys up: the
//     normal open-time takeKeyWindowForStageChrome, 0.6 s after the restore.
// (2) Keys up for the staged app but Medusa hidden / without hosts and a
//     non-stage window key: one takeKeyWindow per show (typing guard bypassed).
// Never for Messages. Off: keyfocus772-off, master core772-off (latch keyfocus772).
- (BOOL)keyfocus772On {
    if (!DS772On("keyfocus772")) return NO;
    if (!_keyfocus772Marked) { _keyfocus772Marked = YES; DSFeature699MarkTrying("keyfocus772"); }
    return YES;
}

- (NSString *)keyfocus772Blocker:(NSString *)bundle {
    if (!bundle.length || [bundle isEqualToString:@"com.apple.MobileSMS"] || DSStage742MessagesStaged()) return @"Messages";
    if (![self isHostingBundleIdentifier:bundle]) return @"not a staged app";
    if (!self.isStageVisible) return @"stage not on screen";
    if ([DSSceneHost homeGestureIsActive] || [DSSceneHost systemPullCallbackIsActive] || [DSSceneHost sceneSettingsUpdateDepth] > 0) return @"system gesture / scene update in progress";
    if (DSVideoIsPlayingOnScreen()) return @"video playing";
    if (!_window) return @"no stage window";
    if (DS773On("keyfocus773") ? (DSRealKeyWindow773() == _window) : DSWindowIsApplicationKey(_window)) return @"the stage window is already key";
    return nil;
}

- (BOOL)keyfocus772KeysLost:(NSString *)owner why:(NSString *)why {
    if (![self keyfocus772On]) return NO;
    UIWindow *other = DS773On("keyfocus773") ? DSRealKeyWindow773() : (_window ? DSCompetingKeyWindow(_window) : nil);   // 4.5.773: SpringBoard's real key window
    NSString *blocker = [self keyfocus772Blocker:owner];
    if (blocker) {
        DSDiagnosticsRecordFormat(@"SpringBoard: keyfocus772 %@ keys hidden (%@), key=%@: not taking key (%@)", owner ?: @"?", why, other ? NSStringFromClass(other.class) : @"?", blocker);
        return NO;
    }
    DSFeature719MarkAction("keyfocus772");
    DSDiagnosticsRecordFormat(@"SpringBoard: keyfocus772 %@ keys hidden (%@) with %@ key: the stage takes the key window back", owner, why, other ? NSStringFromClass(other.class) : @"another window");
    _keyfocus772Forcing = YES;
    @try { [self takeKeyWindow]; } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: keyfocus772 caught %@", exception.reason ?: exception.name);
    }
    _keyfocus772Forcing = NO;
    DSDiagnosticsRecordFormat(@"SpringBoard: keyfocus772 stage window key now=%d", _window ? DSWindowIsApplicationKey(_window) : 0);
    return YES;
}

// ---- 4.5.773 keyfocus773 --------------------------------------------------------
// Pkjon (772): SpringBoard itself hid Medusa (SpringBoard+0x3aa858 path) in all
// three shows; a fresh key take re-showed it (show 2), show 3 stayed hidden with
// the stage already key. While a staged app (not Messages) owns the keys and
// Medusa stays hidden / host-less >= 0.15 s: take key, or resign + re-take when
// the stage is already SpringBoard's real key window. <= 3 per show, on a later
// main-queue turn, never in a home gesture / drag / scene update callback.
// Off: keyfocus773-off, master core773-off (crash latch keyfocus773).
- (BOOL)keyfocus773Reassert:(NSString *)owner attempt:(NSInteger)attempt why:(NSString *)why {
    if (!DS773On("keyfocus773")) return NO;
    if (!_keyfocus773Marked) { _keyfocus773Marked = YES; DSFeature699MarkTrying("keyfocus773"); }
    __weak __typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) me = weakSelf;
        if (!me) return;
        @try {
            NSString *blocker = nil;
            if (!owner.length || [owner isEqualToString:@"com.apple.MobileSMS"] || DSStage742MessagesStaged()) blocker = @"Messages";
            else if (![me isHostingBundleIdentifier:owner]) blocker = @"not a staged app";
            else if (!me.isStageVisible) blocker = @"stage not on screen";
            else if ([DSSceneHost homeGestureIsActive] || [DSSceneHost systemPullCallbackIsActive] || [DSSceneHost sceneSettingsUpdateDepth] > 0) blocker = @"system gesture / scene update in progress";
            else if (me->_state == DSStageStateTracking || DSStageDragSettlingFast(0.0)) blocker = @"card drag";
            else if (DSVideoIsPlayingOnScreen()) blocker = @"video playing";
            else if (!me->_window) blocker = @"no stage window";
            UIWindow *real = DSRealKeyWindow773();
            if (blocker) {
                DSDiagnosticsRecordFormat(@"SpringBoard: keyfocus773 attempt %ld for %@ (%@) skipped: %@", (long)attempt, owner ?: @"?", why, blocker);
                return;
            }
            BOOL ours = real == me->_window;
            DSFeature719MarkAction("keyfocus773");
            DSDiagnosticsRecordFormat(@"SpringBoard: keyfocus773 attempt %ld for %@ (%@): key=%@ -> %@", (long)attempt, owner, why,
                                      real ? NSStringFromClass(real.class) : @"none", ours ? @"resign + re-take the stage key" : @"take the stage key");
            if (ours && DS775On("rekey775")) { [me rekey775:owner attempt:attempt why:why]; return; }
            if (ours) [me->_window resignKeyWindow];
            me->_keyfocus772Forcing = YES;
            @try { [me takeKeyWindow]; } @catch (NSException *exception) {
                DSDiagnosticsRecordFormat(@"SpringBoard: keyfocus773 caught %@", exception.reason ?: exception.name);
            }
            me->_keyfocus772Forcing = NO;
            UIWindow *after = DSRealKeyWindow773();
            DSDiagnosticsRecordFormat(@"SpringBoard: keyfocus773 attempt %ld done: key=%@ (stage key=%d)", (long)attempt,
                                      after ? NSStringFromClass(after.class) : @"none", after == me->_window);
        } @catch (NSException *exception) {
            DSDiagnosticsRecordFormat(@"SpringBoard: keyfocus773 threw %@", exception.reason ?: exception.name);
        }
    });
    return YES;
}

// ---- 4.5.775 rekey775 ----------------------------------------------------------
// Jjjnnj (774): the only change that ever re-showed Medusa was a real key move
// home screen -> stage (show 2, 03:24:09.283). With the stage already key the
// 773 resign + re-take was a no-op ("takeKey already"). rekey775 makes the move
// real: SpringBoard's home screen window becomes key (makeKeyWindow only, no
// touches, so no icon / home action can fire), then on the next main-queue turn
// the stage takes the key back. Called from keyfocus773 (<= 3 per show, all its
// blockers). Off: rekey775-off, master core775-off (crash latch rekey775).
static UIWindow *DSRekey775HomeWindow(UIWindow *stage) {
    Class home = objc_getClass("SBHomeScreenWindow");
    if (!home) return nil;
    NSMutableArray *candidates = [NSMutableArray array];
    if (stage.windowScene) [candidates addObjectsFromArray:stage.windowScene.windows];
    for (UIWindow *w in candidates) {
        if ([w isKindOfClass:home] && !w.hidden && w != stage) return w;
    }
    return nil;
}

- (void)rekey775:(NSString *)owner attempt:(NSInteger)attempt why:(NSString *)why {
    if (!_rekey775Marked) { _rekey775Marked = YES; DSFeature699MarkTrying("rekey775"); }
    UIWindow *home = DSRekey775HomeWindow(_window);
    if (!home) {
        DSDiagnosticsRecordFormat(@"SpringBoard: rekey775 attempt %ld for %@ (%@) skipped: no visible SBHomeScreenWindow", (long)attempt, owner, why);
        return;
    }
    DSFeature719MarkAction("rekey775");
    BOOL arbBefore = DSKbVis775ArbiterOn();
    DSDiagnosticsRecordFormat(@"SpringBoard: rekey775 attempt %ld for %@ (%@): stage key -> SBHomeScreenWindow -> stage (arbiter on=%d)", (long)attempt, owner, why, arbBefore);
    @try { [home makeKeyWindow]; } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: rekey775 home handoff caught %@", exception.reason ?: exception.name);
    }
    UIWindow *mid = DSRealKeyWindow773();
    __weak __typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) me = weakSelf;
        if (!me) return;
        @try {
            BOOL arbNow = DSKbVis775ArbiterOn();
            NSString *late = nil;
            if ([DSSceneHost homeGestureIsActive] || [DSSceneHost systemPullCallbackIsActive] || [DSSceneHost sceneSettingsUpdateDepth] > 0) late = @"system gesture / scene update began";
            else if (me->_state == DSStageStateTracking) late = @"card drag began";
            if (late) DSDiagnosticsRecordFormat(@"SpringBoard: rekey775 attempt %ld: %@ during the handoff; re-taking the stage key anyway so the home screen does not stay key", (long)attempt, late);
            me->_keyfocus772Forcing = YES;
            @try { [me takeKeyWindow]; } @catch (NSException *exception) {
                DSDiagnosticsRecordFormat(@"SpringBoard: rekey775 re-take caught %@", exception.reason ?: exception.name);
            }
            me->_keyfocus772Forcing = NO;
            UIWindow *after = DSRealKeyWindow773();
            DSDiagnosticsRecordFormat(@"SpringBoard: rekey775 attempt %ld done: key mid=%@ after=%@ (stage key=%d)%@", (long)attempt,
                                      mid ? NSStringFromClass(mid.class) : @"none", after ? NSStringFromClass(after.class) : @"none", after == me->_window,
                                      (arbBefore && !arbNow) ? @" | FIELD DROPPED: the keyboard closed during the handoff" : @"");
        } @catch (NSException *exception) {
            DSDiagnosticsRecordFormat(@"SpringBoard: rekey775 threw %@", exception.reason ?: exception.name);
        }
    });
}

- (void)keyfocus772AfterRestore:(DSStageContainerView *)card {
    if (![self keyfocus772On]) return;
    NSString *bundle = [self sceneHostForCard:card].bundleIdentifier;
    if (!bundle.length || [bundle isEqualToString:@"com.apple.MobileSMS"]) return;
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) me = weakSelf;
        if (!me) return;
        @try {
            NSString *blocker = [me keyfocus772Blocker:bundle];
            if (blocker) return;
            CGRect typing = DSTypingKeyboardFrame();
            if (!CGRectIsNull(typing) && CGRectGetHeight(typing) >= 160.0) return;   // keys up: the show path handles it
            UIWindow *other = DSCompetingKeyWindow(me->_window);
            DSFeature719MarkAction("keyfocus772");
            DSDiagnosticsRecordFormat(@"SpringBoard: keyfocus772 %@ restored with %@ key: taking the key window as on open", bundle, other ? NSStringFromClass(other.class) : @"no window");
            [me takeKeyWindowForStageChrome];
        } @catch (NSException *exception) {
            DSDiagnosticsRecordFormat(@"SpringBoard: keyfocus772 restore caught %@", exception.reason ?: exception.name);
        }
    });
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
    DSHide772NotePath(@"takeKeyWindow");
    // Taking the key window while Messages is typing resigns the field and
    // SpringBoard drops the keyboard. The keys are often still parked at the
    // bottom edge of the phone, so "on screen" misses them and the stage
    // takes the key window two seconds later. Messenger never does this mid-type.
    if (self.isStageVisible && !self.isPickerSearchActive && !_keyfocus772Forcing) {
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
    // 4.5.741 open741: one key grab per open / close. A second grab within
    // 0.6 s while the stage window is already key is skipped (Bnb log
    // 12:07:59.435 and .840). Picker search is never skipped. Off: -open741-off.
    {
        static CFAbsoluteTime lastTake741 = 0;
        static NSUInteger lastEpoch752 = 0;
        CFAbsoluteTime now741 = CFAbsoluteTimeGetCurrent();
        BOOL fold752 = DSFold752On() && !DSStage742MessagesStaged();
        if (fold752) { @try { [self host750Tick]; } @catch (NSException *exception) {} }
        if (DSFeature699On("open741") && !DSStage742MessagesStaged() && !self.isPickerSearchActive && _window.isKeyWindow &&
            now741 - lastTake741 < 0.6 && now741 >= lastTake741 && (!fold752 || DSHost752Epoch == lastEpoch752)) {
            DSFeature719MarkAction("open741");
            if (fold752) DSFeature719MarkAction("fold752");
            return;
        }
        lastTake741 = now741;
        lastEpoch752 = DSHost752Epoch;
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
    DSHide772NotePath(@"giveBackKeyWindow");
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
    if ([self kb707Owns]) {
        [self kb707Schedule];
        return;
    }
    [_container setLiftOffset:0.0];
    if (_topContainer) [_topContainer setLiftOffset:0.0];
}

// Two sources, one layout: UIKit notifications for SpringBoard's own keyboard
// (the search field) and the arbiter for staged apps. The card keeps its size and
// only lifts above the keys — picker and hosted app use the same policy.
- (void)observeKeyboard {
    {   // 4.5.772 hide772 / keyfocus772
        __weak __typeof(self) w772 = self;
        DSHide772StateProvider = ^NSString *(NSString *owner) {
            DSStageManager *m = w772;
            if (!m || !owner.length) return @"?";
            DSSceneHost *h = [m->_sceneHost.bundleIdentifier isEqualToString:owner] ? m->_sceneHost :
                             ([m->_topSceneHost.bundleIdentifier isEqualToString:owner] ? m->_topSceneHost : nil);
            return h ? [h gest770State] : @"not on a card";
        };
        DSKeyfocus773Handler = ^BOOL(NSString *owner, NSInteger attempt, NSString *why) {
            DSStageManager *m = w772;
            return m ? [m keyfocus773Reassert:owner attempt:attempt why:why] : NO;
        };
        DSKeyfocus772Handler = ^BOOL(NSString *owner, NSString *why) {
            DSStageManager *m = w772;
            return m ? [m keyfocus772KeysLost:owner why:why] : NO;
        };
    }
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
    if (DSLogQuiet()) return; // 4.5.697: debug line, verbose log only
    DSLogAppend([@"[KEYS] " stringByAppendingString:line]);
}

// One line per decision. Repeats are collapsed so a drag does not bury it.
- (void)logLift:(NSString *)line {
    if (line.length == 0) return;
    if (DSLogQuiet()) return; // 4.5.697: debug line, verbose log only
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
    if (DSMulti702BuildLog()) [self logKeys:[NSString stringWithFormat:@"uikit willShow frame=%@ staged=%ld search=%ld host=%d/%d %@",
                   NSStringFromCGRect(keyboard),
                   (long)_stagedKeyboardSlot,
                   (long)_searchSlot,
                   _sceneHost.isHosting,
                   _topSceneHost.isHosting,
                   [self lowerStageLiftSummary:keyboard]]];
    if (_searchSlot >= 0) {
        _kb720ShowAt = CFAbsoluteTimeGetCurrent();
        [self noteSearchKeyboardDebug:[NSString stringWithFormat:@"UIKit willShow %@", NSStringFromCGRect(keyboard)]];
    }
    if (![self isShowingAppPicker] && _stagedKeyboardSlot < 0 &&
        !_sceneHost.isHosting && !_topSceneHost.isHosting) return;
    [self keyboardFrameWillChange:notification];
}

- (void)keyboardFrameWillChange:(NSNotification *)notification {
    DS_PERF_BEGIN();
    [self keyboardFrameWillChange697:notification];
    DS_PERF_END(DSPerfBucketKeyboard);
}

- (void)keyboardFrameWillChange697:(NSNotification *)notification {
    CGRect keyboard = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [self phoneSize680NoteKeyboardAnimation:notification.userInfo];
    if (DSMulti702BuildLog()) [self logKeys:[NSString stringWithFormat:@"uikit change frame=%@ staged=%ld search=%ld owner=%@ req=%@ %@",
                   NSStringFromCGRect(keyboard),
                   (long)_stagedKeyboardSlot,
                   (long)_searchSlot,
                   _keyboardLiftOwner ?: @"-",
                   _hostedKeyboardRequestBundle ?: @"-",
                   [self lowerStageLiftSummary:keyboard]]];
    if (_stagedKeyboardSlot >= 0 &&
        CGRectGetMinY(keyboard) >= CGRectGetHeight(UIScreen.mainScreen.bounds) - 1.0) {
        static NSInteger parkedLogs = 0;
        // 4.5.788 flicker788: the 8-per-boot cap hid later flickers; keep
        // every one (at most 4 per 2 s). Off: -flicker788-off.
        static CFAbsoluteTime parkedWindow = 0;
        CFAbsoluteTime parkedNow = CFAbsoluteTimeGetCurrent();
        if (DS788On("flicker788") && parkedNow - parkedWindow > 2.0) { parkedWindow = parkedNow; parkedLogs = 4; }
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
        if ([self keys697CardAwayForBundle:bundle]) {
            DSKeys697Log([@"uikit-" stringByAppendingString:bundle ?: @"?"],
                         [NSString stringWithFormat:@"UIKit keyboard frame %@ not given to %@: its card is minimised / parked (another app is typing)",
                          NSStringFromCGRect(keyboard), bundle ?: @"?"]);
            return;
        }
        if ([self appKeepsItsOwnKeyboard:bundle]) return;
        // 4.5.731 kbown731: SpringBoard's UIKit posts this for its own keyboards
        // too (Spotlight, SpringBoard fields). When the keyboard arbiter's latest
        // "on" (within 1.5 s) names an app that is not on a card, this frame is
        // that app's keyboard, not the card's (Keybaord log 09:13:35: Spotlight's
        // keys lifted Beeper 317 pt). Off: -kbown731-off.
        if (bundle.length && _kbown731Source.length && ![self isHostingBundleIdentifier:_kbown731Source] &&
            CFAbsoluteTimeGetCurrent() - _kbown731At < 1.5 && DSFeature699On("kbown731")) {
            DSFeature719MarkAction("kbown731");
            DSKeys697Log([@"kbown731-" stringByAppendingString:_kbown731Source],
                         [NSString stringWithFormat:@"kbown731 UIKit keyboard frame %@ is %@'s keyboard, not given to %@",
                          NSStringFromCGRect(keyboard), _kbown731Source, bundle]);
            return;
        }
        if ([self phoneSize683ActiveForBundle:bundle] || [DSPS683SessionBundle isEqualToString:bundle]) return; // 4.5.683
        if (bundle.length > 0) {
            // Only this slot's own keyboard may move its card. A SpringBoard
            // notification while Spotlight, Edge, or Filza is typing is not
            // that keyboard.
            BOOL owns = _keyboardLiftOwner.length > 0 && [bundle isEqualToString:_keyboardLiftOwner];
            BOOL requested = _hostedKeyboardRequestBundle.length > 0 &&
                             [bundle isEqualToString:_hostedKeyboardRequestBundle];
            if (!owns && !requested && ![self hostedAppReportedRemoteKeyboard:bundle]) {
                if (DSMulti702BuildLog()) [self logKeys:[NSString stringWithFormat:@"uikit change had no owner bundle=%@ h=%.0f",
                               bundle, CGRectGetHeight(keyboard)]];
                // Both stages are up and nobody has claimed the keys yet. This
                // guess is the bottom card. Applying it throws the top card off
                // the screen, and the real note then pulls it back down.
                BOOL twoLive = _stackSlotCount >= kDSMaxStackSlots &&
                    _sceneHost.isHosting && !_primaryParked &&
                    _topSceneHost.isHosting && !_secondParked &&
                    _keyboardLiftOwner.length == 0 &&
                    _hostedKeyboardRequestBundle.length == 0;
                if ([self core747On]) {
                    // 4.5.747: the owner comes from the keyboard system, not a size guess.
                    if (_ks747ArbOn && [_ks747ArbOwner isEqualToString:bundle]) {
                        [self noteKeyboardFrame:keyboard source:bundle duration:duration];
                    } else {
                        // 4.5.754 log754: one line per burst (UIKit repeats its
                        // frame ~10 times before the keyboard system names the
                        // owner, 753 log: 96 lines). A burst ends after 1 s quiet.
                        static CFAbsoluteTime burstAt754 = 0;
                        static NSUInteger burstQuiet754 = 0;
                        CFAbsoluteTime t754 = CFAbsoluteTimeGetCurrent();
                        BOOL quiet = DSLog754On() && t754 - burstAt754 < 1.0 && t754 >= burstAt754;
                        burstAt754 = t754;
                        if (quiet) {
                            burstQuiet754 += 1;
                        } else {
                            NSString *more = burstQuiet754 ? [NSString stringWithFormat:@" (previous burst: +%lu repeats)", (unsigned long)burstQuiet754] : @"";
                            burstQuiet754 = 0;
                            DSDiagnosticsRecordFormat(@"SpringBoard: core747 UIKit keyboard %@ not given to %@: the keyboard system names %@%@",
                                                      NSStringFromCGRect(keyboard), bundle ?: @"?", _ks747ArbOn ? (_ks747ArbOwner ?: @"nobody") : @"no keyboard", more);
                        }
                    }
                    return;
                }
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
    if (DSMulti702BuildLog()) [self logKeys:[NSString stringWithFormat:@"uikit willHide end=%@ staged=%ld search=%ld %@",
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
            if (DSMulti702BuildLog()) [self logKeys:[NSString stringWithFormat:@"willHide kept, stand-in still editing end=%@ keys=%@ slot=%ld",
                           NSStringFromCGRect(end),
                           NSStringFromCGRect(visible),
                           (long)_stagedKeyboardSlot]];
            if (DSMulti702BuildLog()) [self logLift:[NSString stringWithFormat:@"willHide editing frameEmpty=%d %@",
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
        if (DSMulti702BuildLog()) [self logKeys:@"willHide kept, app draws its own keyboard"];
        return;
    }
    // Beeper's keyboard blips through a hide and a 45pt dock strip. Dropping
    // the lift there is what leaves Beeper to slide its own composer.
    if (_searchSlot < 0 && _stagedKeyboardSlot < 0 &&
        (_sceneHost.isHosting || _topSceneHost.isHosting) &&
        [self springBoardIsDrawingKeyboard]) {
        CGRect visible = DSVisibleStagedKeyboardFrameOnScreen();
        if (DSMulti702BuildLog()) [self logKeys:[NSString stringWithFormat:@"willHide kept, keys still on screen %@",
                       NSStringFromCGRect(visible)]];
        if (DSMulti702BuildLog()) [self logLift:[NSString stringWithFormat:@"willHide on-screen frameEmpty=%d %@",
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

// ---- 4.5.697 keys697 ------------------------------------------------------------
// Logs 693/694 (and back to 674): a staged app (Beeper) was minimised with its
// keyboard up and no keyboard-down ever arrived from its held scene. The stage
// kept "typing on the stage": Messages / Spotlight / Maps keyboards were then
// "ignored ... while com.beeper.chat.ios is typing on the stage" (no key window
// hand-back), their UIKit keyboard notes were taken as Beeper's ("keys672
// com.beeper.chat.ios keyboard up ... card {56, 56}") and hides were refused
// ("hide ignored, keys still"). A card that is minimised, parked or hidden no
// longer owns a keyboard. Off: /var/mobile/.dynamicstage-keys697-off.
static BOOL DSKeys697Enabled(void) {
    static CFAbsoluteTime at = 0;
    static BOOL off = NO;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - at > 2.0 || now < at) {
        at = now;
        off = access("/var/mobile/.dynamicstage-keys697-off", F_OK) == 0 ||
              access("/var/jb/var/mobile/.dynamicstage-keys697-off", F_OK) == 0;
    }
    return !off;
}

static void DSKeys697Log(NSString *key, NSString *line) {
    // 4.5.706 perf706: once a minute per key (was 5 s; 60 lines in one log).
    CFAbsoluteTime quietFor = DSFeature699On("perf706") ? 60.0 : 5.0;
    if (!DSLogGate([@"keys697-" stringByAppendingString:key ?: @"?"], key, quietFor, NULL)) return;
    DSDiagnosticsRecordFormat(@"SpringBoard: keys697 %@", line);
}

- (BOOL)keys697StageAway {
    if (!DSKeys697Enabled()) return NO;
    if (_state == DSStageStateMinimized || _state == DSStageStateClosed) return YES;
    BOOL primaryLive = _sceneHost.isHosting && !_primaryParked && !_container.hidden;
    BOOL secondLive = _topSceneHost.isHosting && !_secondParked && _topContainer && !_topContainer.hidden;
    BOOL floatLive = _floatSceneHost.isHosting && _floatContainer && !_floatContainer.hidden;
    return !primaryLive && !secondLive && !floatLive;
}

- (BOOL)keys697CardAwayForBundle:(NSString *)bundle {
    if (!DSKeys697Enabled() || bundle.length == 0) return NO;
    // Messages keeps its 696 keyboard handling.
    if ([bundle isEqualToString:@"com.apple.MobileSMS"]) return NO;
    if ([self keys697StageAway]) return YES;
    NSInteger slot = [self slotForHostedBundle:bundle];
    if (slot < 0) return NO;
    DSStageContainerView *card = [self containerForSlot:slot];
    return card && ([self cardIsParked:card] || card.hidden);
}

- (BOOL)stagedTypingSessionActive {
    if (!_sceneHost.isHosting && !_topSceneHost.isHosting) return NO;
    if ([self keys697StageAway]) return NO;
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

// 4.5.755 type755: the one answer to "is a staged app typing right now",
// taken from the keyboard system (set when it names a hosted app as the
// owner, cleared when it turns off). Used by the 'ignore' check and kbmin702.
- (NSString *)type755TypingOwner {
    if (!_type755Owner) return nil;
    // 4.5.756 type756: a typing owner whose card was closed or minimised is
    // not typing on the stage any more (755 log 16:27:24.61 -> 39.71).
    if (DS756On("type756") && (![self isHostingBundleIdentifier:_type755Owner] || [self keys697CardAwayForBundle:_type755Owner])) {
        DSFeature719MarkAction("type756");
        DSDiagnosticsRecordFormat(@"SpringBoard: type756 %@ card closed or minimised: no longer the typing owner", _type755Owner);
        _type755Owner = nil;
        return nil;
    }
    if (![self isHostingBundleIdentifier:_type755Owner] || [self keys697StageAway]) return nil;
    return _type755Owner;
}

- (void)type755NoteArbiter:(BOOL)onScreen frame:(CGRect)frame source:(NSString *)source {
    BOOL named = [source isKindOfClass:NSString.class] && source.length && ![source isEqualToString:@"?"];
    if (onScreen && named && CGRectGetHeight(frame) >= 150.0 && [self isHostingBundleIdentifier:source]) {
        _type755Owner = [source copy];
    } else if (!onScreen && _type755Owner && (!named || [source isEqualToString:_type755Owner])) {
        DSFeature719MarkAction("type755");
        DSDiagnosticsRecordFormat(@"SpringBoard: type755 %@ keyboard off: no staged app typing", _type755Owner);
        _type755Owner = nil;
    }
}

// 4.5.755 focus755 (log only): at each keyboard on/off for a staged app, the
// last focus / event-deferring update SpringBoard sent its scene (passed or
// held, empty list flagged) and the key window.
- (void)focus755Log:(BOOL)onScreen source:(NSString *)source {
    if (![source isKindOfClass:NSString.class] || source.length == 0 || ![self isHostingBundleIdentifier:source]) return;
    DSFeature719MarkAction("focus755");
    CFAbsoluteTime at = 0;
    NSString *last = DSFocus755LastFor(source, &at);
    UIWindow *key = nil;
    @try { key = UIApplication.sharedApplication.keyWindow; } @catch (NSException *exception) {}
    DSDiagnosticsRecordFormat(@"SpringBoard: focus755 %@ keyboard on=%d key window=%@ last focus update: %@",
                              source, onScreen, key ? NSStringFromClass(key.class) : @"none",
                              last ? [NSString stringWithFormat:@"%.2fs ago %@", CFAbsoluteTimeGetCurrent() - at, last] : @"none seen");
}

- (BOOL)shouldIgnoreForeignKeyboardEventFrom:(NSString *)source onScreen:(BOOL)onScreen {
    // 4.5.803 typing803: a keyboard from the app the keyboard system names as
    // the owner right now is never "foreign" (802 02:00:32.690 ignored
    // Spotlight's own keys on a stale typing flag). Off: typing803-off.
    if (DS803On("typing803") && onScreen && [source isKindOfClass:NSString.class] && source.length &&
        [source isEqualToString:DS803KeyboardOwner()] && ![self isHostingBundleIdentifier:source]) {
        DSFeature719MarkAction("typing803");
        return NO;
    }
    // 4.5.767 sbkb767: with no stage on screen nothing is "typing on the stage"
    // (Resssj 21:43:47: full-screen Messages' keys were ignored as foreign while
    // the stage was off). The rule and its log line need the stage on screen.
    // Off: sbkb767-off / core767-off (latch sbkb767).
    if (_state != DSStageStateOverlay && _state != DSStageStateTracking && DS767On("sbkb767")) {
        DSFeature719MarkAction("sbkb767");
        return NO;
    }
    if (source.length == 0 || [self isHostingBundleIdentifier:source]) return NO;
    if (DSType755On()) {
        if ([source isEqualToString:@"SpringBoard"] && _searchSlot >= 0) return NO;
        if ([self type755TypingOwner]) return YES;
        // The stage's own stand-in keyboard is SpringBoard's, not an app's.
        return _stagedKeyboardSlot >= 0 || [self springBoardIsDrawingKeyboard];
    }
    if (![self stagedTypingSessionActive]) return NO;
    if ([source isEqualToString:@"SpringBoard"] && _searchSlot >= 0) return NO;
    if (onScreen) return YES;
    if ([self springBoardIsDrawingKeyboard]) return YES;
    return NO;
}

- (void)keyboardOnScreen:(BOOL)onScreen frame:(CGRect)frame source:(NSString *)source {
    DS_PERF_BEGIN();
    [self keyboardOnScreen697:onScreen frame:frame source:source];
    DS_PERF_END(DSPerfBucketKeyboard);
}

- (void)keyboardOnScreen697:(BOOL)onScreen frame:(CGRect)frame source:(NSString *)source {
    if (DSKbNan754Bad(frame) && DSKbNan754On()) {
        DSFeature719MarkAction("kbnan754");
        DSDiagnosticsRecordFormat(@"SpringBoard: kbnan754 keyboard system frame %@ from %@ has no real size: taken as hidden",
                                  NSStringFromCGRect(frame), source ?: @"?");
        frame = CGRectZero;
        onScreen = NO;
    }
    // 4.5.723: the staged app's own keyboard report, kept for kb707 (a plain
    // copy; read only by kb707KeysForCard while kb723 is on).
    @try {
        if ([source isKindOfClass:NSString.class] && source.length && [self isHostingBundleIdentifier:source]) {
            if (onScreen && CGRectGetHeight(frame) >= 150.0) {
                _kb723ArbiterKeys = frame;
                _kb723ArbiterBundle = [source copy];
            } else if (!onScreen && [_kb723ArbiterBundle isEqualToString:source]) {
                _kb723ArbiterKeys = CGRectZero;
                _kb723ArbiterBundle = nil;
            }
        }
    } @catch (NSException *exception) {
    }
    // 4.5.768 kbvis768 (log only): sample keyboard visibility while the stage is on screen.
    @try {
        BOOL stageUp768 = _state == DSStageStateOverlay || _state == DSStageStateTracking;
        DSKbVis768NoteArbiter(onScreen, stageUp768, [source isKindOfClass:NSString.class] ? source : nil, frame);
    } @catch (NSException *exception) {}
    @try { [self ks747NoteArbiter:onScreen frame:frame owner:source]; } @catch (NSException *exception) {}
    @try {
        if (DSType755On()) [self type755NoteArbiter:onScreen frame:frame source:source];
        if (DSFocus755On()) [self focus755Log:onScreen source:source];
    } @catch (NSException *exception) {}
    if (onScreen && [source isKindOfClass:NSString.class] && source.length) {   // 4.5.731 kbown731
        _kbown731Source = [source copy];
        _kbown731At = CFAbsoluteTimeGetCurrent();
    }
    @try {
        [self kbshow728Arbiter:onScreen source:source];
    } @catch (NSException *exception) {
    }
    @try {
        [self kbmin702Note:onScreen frame:frame source:source];
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: kbmin702 caught %@", exception.reason ?: exception.name);
    }
    [self focus704NoteKeys:onScreen source:source];
    if (!onScreen && DSPhoneCallIsActive() && [self stagedTypingSessionActive]) {
        DSDiagnosticsRecord(@"SpringBoard: left the staged keyboard up during a call");
        return;
    }
    if ([self phoneSize683ActiveForBundle:source] || (!onScreen && [DSPS683SessionBundle isEqualToString:source])) {
        [self phoneSize675Log:[@"kos683-" stringByAppendingString:source ?: @"?"]
                         line:[NSString stringWithFormat:@"phonesize683 %@ keyboard on=%d %@ left to the app: no stage lift/drop, no SpringBoard key raise (its own keyboard is in the card)",
                               source ?: @"?", onScreen, NSStringFromCGRect(frame)]
                        every:5.0];
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
            NSString *typer = DS756On("type756") ? ([self type755TypingOwner] ?: (_stagedKeyboardSlot >= 0 ? @"the stage's own keyboard" : @"SpringBoard's keyboard"))
                                                 : [self primaryHostedBundleIdentifier];
            DSDiagnosticsRecordFormat(@"SpringBoard: ignored %@ keyboard while %@ is typing on the stage",
                                      source, typer ?: @"?");
        }
        return;
    }
    if (onScreen && [self isHostingBundleIdentifier:source] && [self keys697CardAwayForBundle:source]) {
        DSKeys697Log([@"away-" stringByAppendingString:source],
                     [NSString stringWithFormat:@"%@ keyboard on %@ while its card is minimised / parked: not taken as typing on the stage (no lift, no key raise)",
                      source, NSStringFromCGRect(frame)]);
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
        @try { [self fast743KeysHiding:@"keyboard note on=0"]; } @catch (NSException *e) {}
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
    // 4.5.759 keys759: Lokkk / 756–758 Beeper. DSRaiseVisibleKeyboardAboveStage
    // is a no-op ("left host alone"). With lift756 the card drops over the
    // keyboard band; keys behind the stage (998) were only visible through the
    // clear gap below the card (754, lift 0). Force a real raise for no-dylib
    // / phonesize684 apps so the host sits above the stage. Off: keys759-off.
    if (onScreen && [self isHostingBundleIdentifier:source] &&
               ![source isEqualToString:@"com.apple.MobileSMS"] &&
               ([source isEqualToString:@"com.beeper.chat.ios"] || [self phoneSize684ActiveForBundle:source])) {
        if (DS759On("keys759")) {
            DSFeature719MarkAction("keys759");
            (void)DSRaiseKeyboardWindowAboveStage();
        } else if ([source isEqualToString:@"com.beeper.chat.ios"]) {
            DSRaiseVisibleKeyboardAboveStage();
        }
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
    BOOL predict = DS805PredictOn();
    field.autocorrectionType = predict ? UITextAutocorrectionTypeDefault : UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.spellCheckingType = predict ? UITextSpellCheckingTypeDefault : UITextSpellCheckingTypeNo;
    if (predict) DSDiagnosticsRecord(@"SpringBoard: predict805 on: the staged keyboard field keeps UIKit's default autocorrection and spell checking (QuickType row)");
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
    // 4.5.803 noise803: the post still goes out every time; the line is only
    // written when the state changes. Off: noise803-off.
    static int lastLogged = -1;
    if (!DS803On("noise803") || lastLogged != (shown ? 1 : 0)) {
        lastLogged = shown ? 1 : 0;
        DSDiagnosticsRecord(shown ? @"SpringBoard: told Messages the keyboard is on screen"
                                  : @"SpringBoard: told Messages the keyboard is gone");
    }
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


// ---- 4.5.801 kbfocus801 ---------------------------------------------------------
// Request keyboard focus for a staged app's FBScene the way cover-sheet / in-call
// hosts do: SBWorkspaceKeyboardFocusController userFocusRequestForScene:reason:
// completion: (fallback SBSKeyboardFocusService). While active, the stand-in
// DSStagedKeyboardField / keyring795 / msg742 path is skipped; card lift still
// uses the real keyboard frame height. Off: kbfocus801-off / core801-off
// (crash latch kbfocus801).
- (BOOL)kbfocus801IsActive {
    return _kbfocus801Active;
}

- (id)kbfocus801FocusController {
    @try {
        Class wsClass = objc_getClass("SBMainWorkspace");
        id workspace = nil;
        if ([wsClass respondsToSelector:@selector(sharedInstance)]) {
            workspace = ((id (*)(id, SEL))objc_msgSend)(wsClass, @selector(sharedInstance));
        }
        if (!workspace) {
            Class base = objc_getClass("SBWorkspace");
            if ([base respondsToSelector:@selector(mainWorkspace)]) {
                workspace = ((id (*)(id, SEL))objc_msgSend)(base, @selector(mainWorkspace));
            }
        }
        if (workspace && [workspace respondsToSelector:@selector(keyboardFocusController)]) {
            return ((id (*)(id, SEL))objc_msgSend)(workspace, @selector(keyboardFocusController));
        }
    } @catch (NSException *e) {}
    return nil;
}

- (DSSceneHost *)kbfocus801HostForBundle:(NSString *)bundle {
    if (bundle.length == 0) return nil;
    if (_sceneHost.isHosting && [_sceneHost.bundleIdentifier isEqualToString:bundle]) return _sceneHost;
    if (_topSceneHost.isHosting && [_topSceneHost.bundleIdentifier isEqualToString:bundle]) return _topSceneHost;
    if (_floatSceneHost.isHosting && [_floatSceneHost.bundleIdentifier isEqualToString:bundle]) return _floatSceneHost;
    return nil;
}

- (void)kbfocus801ReleaseIfNeeded:(NSString *)why {
    if (!_kbfocus801Active) return;
    NSString *bundle = _kbfocus801Bundle ?: @"?";
    id focus = [self kbfocus801FocusController];
    DSSceneHost *host = [self kbfocus801HostForBundle:_kbfocus801Bundle];
    FBScene *scene = nil;
    @try { scene = [host hostedScene]; } @catch (NSException *e) {}
    id identityToken = nil;
    @try {
        if (scene && [scene respondsToSelector:@selector(identityToken)]) {
            identityToken = ((id (*)(id, SEL))objc_msgSend)(scene, @selector(identityToken));
        }
        if (!identityToken && scene && [scene respondsToSelector:@selector(identity)]) {
            identityToken = ((id (*)(id, SEL))objc_msgSend)(scene, @selector(identity));
        }
    } @catch (NSException *e) {}
    int pid = 0;
    @try {
        id client = (scene && [scene respondsToSelector:@selector(clientProcess)])
            ? ((id (*)(id, SEL))objc_msgSend)(scene, @selector(clientProcess)) : nil;
        if (client && [client respondsToSelector:@selector(pid)]) {
            pid = ((int (*)(id, SEL))objc_msgSend)(client, @selector(pid));
        }
    } @catch (NSException *e) {}
    @try {
        if (focus && scene && [focus respondsToSelector:@selector(removeKeyboardFocusFromScene:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(focus, @selector(removeKeyboardFocusFromScene:), scene);
        }
    } @catch (NSException *e) {}
    @try {
        Class svcClass = objc_getClass("SBSKeyboardFocusService");
        id svc = [svcClass respondsToSelector:@selector(new)] ? ((id (*)(id, SEL))objc_msgSend)(svcClass, @selector(new)) : nil;
        if (svc && identityToken && [svc respondsToSelector:@selector(removeKeyboardFocusFromSceneIdentity:processID:)]) {
            ((void (*)(id, SEL, id, int))objc_msgSend)(svc, @selector(removeKeyboardFocusFromSceneIdentity:processID:), identityToken, pid);
        }
    } @catch (NSException *e) {}
    DSDiagnosticsRecordFormat(@"SpringBoard: kbfocus801: keyboard owner=%@ (hide why=%@)", bundle, why ?: @"?");
    _kbfocus801Active = NO;
    _kbfocus801Bundle = nil;
}

// ---- 4.5.802 kbfocus802 ---------------------------------------------------------
// 801 counted completion "ok" as success: 8x ok for Messages, keys never shown.
// 802: one focus request per focus (no setExternalSceneIdentities:, no spin, no
// polls). The stand-in / keyring795 / msg742 path stays fully active. Only
// once kbvis768 proves the keys are visible for that owner in the current show
// (Medusa shown, live layer host, above the stage, SpringBoard sees keys - the
// stand-in uses SpringBoard's own keyboard so it can never satisfy this) does
// focus count as granted; later taps then skip the stand-in. Proof is cleared
// on every staged-keyboard hide.
// Off by default: /var/mobile/.dynamicstage-kbfocus802-on enables it;
// kbfocus802-off / core802-off and crash latch kbfocus802 still win.
- (BOOL)kbfocus802On {
    if (!DS802OptIn("kbfocus802")) return NO;
    static BOOL marked = NO;
    if (!marked) { marked = YES; DSFeature699MarkTrying("kbfocus802"); }
    return YES;
}

- (void)kbfocus802NoteVerdict:(NSString *)owner show:(NSInteger)show visible:(BOOL)visible {
    if (!_kbfocus802Bundle || ![owner isEqualToString:_kbfocus802Bundle]) return;
    if (visible && !_kbfocus801Active) {
        _kbfocus801Active = YES;
        _kbfocus801Bundle = [_kbfocus802Bundle copy];
        _kbfocus802ProofLogged = YES;
        DSFeature719MarkAction("kbfocus802");
        DSDiagnosticsRecordFormat(@"SpringBoard: kbfocus802: %@ proof=keys-visible (kbvis show %ld) - real focus granted", owner, (long)show);
    } else if (!visible && !_kbfocus801Active && !_kbfocus802ProofLogged) {
        _kbfocus802ProofLogged = YES;
        DSDiagnosticsRecordFormat(@"SpringBoard: kbfocus802: %@ proof=none -> fallback (stand-in stays; kbvis show %ld)", owner, (long)show);
    }
}

- (void)kbfocus802RequestForBundle:(NSString *)bundle {
    if (bundle.length == 0 || [_kbfocus802Bundle isEqualToString:bundle]) return;   // one request per focus
    if (!DSKbVis802Verdict) {
        DSKbVis802Verdict = ^(NSString *owner, NSInteger show, BOOL visible) {
            [[DSStageManager sharedManager] kbfocus802NoteVerdict:owner show:show visible:visible];
        };
    }
    _kbfocus802Bundle = [bundle copy];
    _kbfocus802ProofLogged = NO;
    DSSceneHost *host = [self kbfocus801HostForBundle:bundle];
    FBScene *scene = nil;
    @try { scene = [host hostedScene]; } @catch (NSException *e) { scene = nil; }
    if (!scene) {
        DSDiagnosticsRecordFormat(@"SpringBoard: kbfocus802: request %@ result=%@ -> fallback", bundle, host ? @"no-scene" : @"no-host");
        return;
    }
    id focus = [self kbfocus801FocusController];
    if (!focus || ![focus respondsToSelector:@selector(userFocusRequestForScene:reason:completion:)]) {
        DSDiagnosticsRecordFormat(@"SpringBoard: kbfocus802: request %@ result=no-controller -> fallback", bundle);
        return;
    }
    DSDiagnosticsRecordFormat(@"SpringBoard: kbfocus802: request %@ via SBWorkspaceKeyboardFocusController", bundle);
    @try {
        NSString *b = [bundle copy];
        void (^done)(BOOL) = ^(BOOL ok) {
            DSDiagnosticsRecordFormat(@"SpringBoard: kbfocus802: result %@ %@ (not trusted until keys are visible)", b, ok ? @"ok" : @"refused");
        };
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(focus, @selector(userFocusRequestForScene:reason:completion:), scene, @"DynamicStage kbfocus802", done);
    } @catch (NSException *e) {
        DSDiagnosticsRecordFormat(@"SpringBoard: kbfocus802: request %@ result=threw %@ -> fallback", bundle, e.name ?: @"?");
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
    if ([self kbfocus802On]) {
        if (_kbfocus801Active && [_kbfocus801Bundle isEqualToString:bundle]) {
            DSDiagnosticsRecordFormat(@"SpringBoard: kbfocus802: bypassed stand-in for %@ (keys proven visible)", bundle);
            return;
        }
        [self kbfocus802RequestForBundle:bundle];
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
    // 4.5.802 hide802: one hide per resign. A repeat with nothing new since the
    // last hide (same keyboard generation, stand-in not first responder, no
    // staged slot, no hosted request, no kbfocus) is dropped silently, so
    // "hiding the staged keyboard" / "told Messages the keyboard is gone" print
    // once. Off: hide802-off / core802-off.
    if (DS802On("hide802") && _hide802Generation != 0 && _hide802Generation == _stagedKeyboardEnsureGeneration &&
        _stagedKeyboardWantsHide && _stagedKeyboardSlot < 0 && !_stagedKeyboardField.isFirstResponder &&
        _hostedKeyboardRequestBundle.length == 0 && !_kbfocus801Active && _kbfocus802Bundle == nil) {
        DSFeature719MarkAction("hide802");
        return;
    }
    if (_kbfocus801Active) [self kbfocus801ReleaseIfNeeded:@"hideStagedKeyboardLikePicker"];
    else if (_kbfocus802Bundle) DSDiagnosticsRecordFormat(@"SpringBoard: kbfocus802: %@ focus ended (hide) - no proof this focus", _kbfocus802Bundle);
    _kbfocus802Bundle = nil;
    NSString *hiding = _hostedKeyboardRequestBundle;
    if (hiding.length == 0) hiding = [self hostedBundleForStagedKeyboard];
    _hostedKeyboardRequestBundle = nil;
    [self applyHostedKeyboardChrome:NO];
    if ([hiding isEqualToString:@"com.apple.MobileSMS"]) {
        [self postMessagesKeyboardShown:NO];
    }
    NSString *caller = @"?";
    if (DSLog754On()) caller = DSCaller754(1, 3, YES);
    else for (NSString *frame in [NSThread callStackSymbols]) {
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
    // 4.5.745 ghost745: remember the hide; forget the old keys.
    if (DSFeature699On("ghost745")) {
        _ghost745HideAt = CFAbsoluteTimeGetCurrent();
        _keyboardFrame = CGRectZero;
        _focus704KeysBundle = nil;
    }
    _stagedKeyboardEnsureGeneration++;
    if (_stagedKeyboardField.isFirstResponder) {
        [_stagedKeyboardField resignFirstResponder];
    }
    _stagedKeyboardSlot = -1;
    // Resigning the field does not always deliver a keyboard-down. The top
    // card was left shifted, and the keys stayed on screen.
    [self collapseHostedKeyboardLift];    _hide802Generation = _stagedKeyboardEnsureGeneration;
}

// ---- 4.5.744 kbdrag744 / kbhide744 ----------------------------------------------
// One shared dismiss: the card (nil = any) loses the keyboard now. SpringBoard's
// staged keys go through hideStagedKeyboardLikePicker; picker search ends its
// field; an app drawing its own keys is asked to end editing (kbapp744) and the
// cards spring back (fast743). Off: /var/mobile/.dynamicstage-kbdrag744-off
// (per-action crash latch).
- (BOOL)kb744CardOwnsKeyboard:(DSStageContainerView *)card {
    if (!card) return YES;
    if (_stagedKeyboardSlot >= 0 && [self containerForSlot:_stagedKeyboardSlot] == card) return YES;
    if (_searchSlot >= 0 && [self containerForSlot:_searchSlot] == card) return YES;
    if (_kb707Owner == card) return YES;
    DSSceneHost *host = [self sceneHostForCard:card];
    if (host.isHosting && _keyboardLiftOwner.length && [_keyboardLiftOwner isEqualToString:host.bundleIdentifier]) return YES;
    return NO;
}

- (void)kb744DismissForCard:(DSStageContainerView *)card why:(NSString *)why {
    @try { [self move747Cancel:why]; } @catch (NSException *exception) {}
    if (!DSFeature699On("kbdrag744")) return;
    @try {
        if (![self kb744CardOwnsKeyboard:card]) return;
        CGRect keys = DSVisibleKeyboardFrameOnScreen();
        BOOL keysUp = !CGRectIsNull(keys) && CGRectGetHeight(keys) >= 150.0;
        BOOL staged = _stagedKeyboardSlot >= 0 || _stagedKeyboardField.isFirstResponder;
        if (!keysUp && !staged && _searchSlot < 0) return;
        DSFeature719MarkAction("kbdrag744");
        DSDiagnosticsRecordFormat(@"SpringBoard: kbdrag744 dismiss keys (%@)", why ?: @"?");
        NSString *bundle = nil;
        DSStageContainerView *owner = card ?: _kb707Owner;
        if (owner) bundle = [self sceneHostForCard:owner].bundleIdentifier;
        if (!bundle.length) bundle = _keyboardLiftOwner;
        if (staged) [self hideStagedKeyboardLikePicker];
        if (_searchSlot >= 0) {
            [_window endEditing:YES];
            _searchSlot = -1;
            DSReleaseKeyboardLevelHold();
        }
        if (bundle.length && ![bundle isEqualToString:@"com.apple.MobileSMS"] &&
            ![bundle isEqualToString:@"SpringBoard"]) {
            static int token = NOTIFY_TOKEN_INVALID;
            if (token == NOTIFY_TOKEN_INVALID) notify_register_check("com.recreated.dynamicstage.kbdismiss744", &token);
            if (token != NOTIFY_TOKEN_INVALID) {
                notify_set_state(token, DSIdentifierHash(bundle));
                notify_post("com.recreated.dynamicstage.kbdismiss744");
            }
        }
        [self fast743KeysHiding:why];
        [self noteKeyboardFrame:CGRectZero source:(bundle ?: @"SpringBoard") duration:0.0];
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: kbdrag744 caught %@", exception.reason ?: exception.name);
    }
}

- (void)collapseHostedKeyboardLift {
    if (DSMulti702BuildLog()) [self logKeys:[NSString stringWithFormat:@"collapse split=%d float=%d slot=%ld frame=%@ lift=%.0f/%.0f/%.0f",
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
    if (DSMulti702BuildLog()) [self logKeys:[NSString stringWithFormat:@"req %@ %@ host=%d fr=%d slot=%ld split=%d why=%@",
                   bundle ?: @"?",
                   show ? @"show" : @"hide",
                   hosting,
                   _stagedKeyboardField.isFirstResponder,
                   (long)_stagedKeyboardSlot,
                   _splitMode,
                   why.length ? why : @"-"]];
    if (!hosting) {
        if (DSMulti702BuildLog()) [self logKeys:@"req ignored, app is not on a card"];
        return;
    }
    if (_searchSlot >= 0) {
        if (DSMulti702BuildLog()) [self logKeys:@"req ignored, picker search is open"];
        return;
    }
    // Docking a second keyboard host resigns the field and Messages sends hide.
    // The staged field was just put back, so that hide is not the user leaving.
    // Cancel is the user leaving, even inside that window.
    if (!show && !userCancel && DSPhoneCallIsActive()) {
        if (DSMulti702BuildLog()) [self logKeys:[NSString stringWithFormat:@"hide ignored, a call is up %@", bundle ?: @"?"]];
        [self keepStagedKeyboardField];
        return;
    }
    if (!show && !userCancel && CFAbsoluteTimeGetCurrent() - _stagedKeyboardKeptAt < 1.0) {
        if (DSMulti702BuildLog()) [self logKeys:[NSString stringWithFormat:@"hide ignored, stand-in was just kept %@", bundle ?: @"?"]];
        // 4.5.744 kbhide744: re-check when the window ends; a later show cancels.
        if (DSFeature699On("kbhide744") && ![bundle isEqualToString:@"com.apple.MobileSMS"]) {
            NSUInteger gen = ++_kb744HideGen;
            NSTimeInterval wait = 1.0 - (CFAbsoluteTimeGetCurrent() - _stagedKeyboardKeptAt) + 0.05;
            __weak __typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(wait, 0.05) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                __strong __typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf || gen != strongSelf->_kb744HideGen) return;
                if (CFAbsoluteTimeGetCurrent() - strongSelf->_stagedKeyboardKeptAt < 1.0) return;
                DSFeature719MarkAction("kbhide744");
                DSDiagnosticsRecord(@"SpringBoard: kbhide744 applied a hide held by the stand-in window");
                [strongSelf hideStagedKeyboardLikePicker];
            });
        }
        return;
    }
    // The conversation search field resigns itself after a letter. The keys
    // are still on screen and the stand-in is still editing. Cancel is not
    // that resign: the app marks it cancel=1.
    if (!show && !userCancel && _stagedKeyboardField.isFirstResponder &&
        [why rangeOfString:@"SearchBar"].location != NSNotFound) {
        CGRect keys = DSVisibleKeyboardFrameOnScreen();
        if (!CGRectIsNull(keys) && CGRectGetHeight(keys) >= 160.0) {
            if (DSMulti702BuildLog()) [self logKeys:[NSString stringWithFormat:@"hide ignored, search field resigned on its own keys=%@",
                           NSStringFromCGRect(keys)]];
            return;
        }
    }
    // 4.5.787 swipe787: the conversation drag in Messages is a user dismissal.
    if (!show && [why rangeOfString:@"swipe786"].location != NSNotFound) {
        DSDiagnosticsRecordFormat(@"SpringBoard: swipe787 drag-down hide from %@ (userCancel=%d), hiding the staged keys",
                                  bundle ?: @"?", userCancel);
    }
    _kb744HideGen++;
    if (show) _ghost745ShowAt = CFAbsoluteTimeGetCurrent();
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
    // 4.5.779: the gap since the previous delete shows whether held delete repeats (~0.1 s).
    static CFAbsoluteTime lastDelete = 0;
    CFAbsoluteTime nowDelete = CFAbsoluteTimeGetCurrent();
    double gapMs = lastDelete > 0 ? (nowDelete - lastDelete) * 1000.0 : -1.0;
    lastDelete = nowDelete;
    DSDiagnosticsRecordFormat(@"SpringBoard: staged key delete app=%@ fr=%d gap=%.0fms",
                              [self hostedBundleForStagedKeyboard],
                              _stagedKeyboardField.isFirstResponder, gapMs);
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
    if (DSSceneHostBundleDiedPending(bundleIdentifier)) return NO;
    if (_sceneHost.isHosting && [_sceneHost.bundleIdentifier isEqualToString:bundleIdentifier]) return YES;
    if (_topSceneHost.isHosting && [_topSceneHost.bundleIdentifier isEqualToString:bundleIdentifier]) return YES;
    if (_floatSceneHost.isHosting && [_floatSceneHost.bundleIdentifier isEqualToString:bundleIdentifier]) return YES;
    return NO;
}

// 4.5.658: camera diagnostics, read only.
- (DSSceneHost *)cameraHostForBundleIdentifier:(NSString *)bundleIdentifier slot:(NSString **)slot {
    if (bundleIdentifier.length == 0) return nil;
    if (_sceneHost.isHosting && [_sceneHost.bundleIdentifier isEqualToString:bundleIdentifier]) {
        if (slot) *slot = _primaryParked ? @"primary(parked)" : @"primary";
        return _sceneHost;
    }
    if (_topSceneHost.isHosting && [_topSceneHost.bundleIdentifier isEqualToString:bundleIdentifier]) {
        if (slot) *slot = _secondParked ? @"top(parked)" : @"top";
        return _topSceneHost;
    }
    if (_floatSceneHost.isHosting && [_floatSceneHost.bundleIdentifier isEqualToString:bundleIdentifier]) {
        if (slot) *slot = @"float";
        return _floatSceneHost;
    }
    return nil;
}

- (NSString *)cameraStateSummaryForBundleIdentifier:(NSString *)bundleIdentifier {
    NSString *slot = nil;
    DSSceneHost *host = [self cameraHostForBundleIdentifier:bundleIdentifier slot:&slot];
    if (!host) return @"card=none";
    return [NSString stringWithFormat:@"card=%@ %@", slot ?: @"?", [host cameraStateSummary] ?: @""];
}

- (pid_t)hostedProcessIdentifierForBundleIdentifier:(NSString *)bundleIdentifier {
    DSSceneHost *host = [self cameraHostForBundleIdentifier:bundleIdentifier slot:NULL];
    return host ? [host hostedProcessIdentifier] : 0;
}

// 4.5.652: every bundle on a card right now (primary, top, floating).
- (NSArray<NSString *> *)hostedBundleIdentifiers {
    NSMutableArray<NSString *> *bundles = [NSMutableArray array];
    if (_sceneHost.isHosting && _sceneHost.bundleIdentifier.length) [bundles addObject:_sceneHost.bundleIdentifier];
    if (_topSceneHost.isHosting && _topSceneHost.bundleIdentifier.length) [bundles addObject:_topSceneHost.bundleIdentifier];
    if (_floatSceneHost.isHosting && _floatSceneHost.bundleIdentifier.length) [bundles addObject:_floatSceneHost.bundleIdentifier];
    if (DSSceneHostAnyDiedPending()) {
        for (NSString *bundle in [bundles copy]) {
            if (DSSceneHostBundleDiedPending(bundle)) [bundles removeObject:bundle];
        }
    }
    return bundles;
}

// 4.5.668 sbcam668: the card's host for a bundle, only while that card is
// on screen (not parked, not the minimized corner).
- (DSSceneHost *)visibleHostForBundleIdentifier:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0) return nil;
    if (_sceneHost.isHosting && !_primaryParked && [_sceneHost.bundleIdentifier isEqualToString:bundleIdentifier]) return _sceneHost;
    if (_topSceneHost.isHosting && !_secondParked && [_topSceneHost.bundleIdentifier isEqualToString:bundleIdentifier]) return _topSceneHost;
    if (_floatSceneHost.isHosting && _floatActive && [_floatSceneHost.bundleIdentifier isEqualToString:bundleIdentifier]) return _floatSceneHost;
    return nil;
}

- (void)setCameraTall:(BOOL)tall forBundleIdentifier:(NSString *)bundleIdentifier why:(NSString *)why {
    for (DSSceneHost *host in @[ _sceneHost ?: (id)NSNull.null, _topSceneHost ?: (id)NSNull.null, _floatSceneHost ?: (id)NSNull.null ]) {
        if (![host isKindOfClass:DSSceneHost.class]) continue;
        if (![host.bundleIdentifier isEqualToString:bundleIdentifier]) continue;
        if (tall && host != [self visibleHostForBundleIdentifier:bundleIdentifier]) continue;
        if ([host isCameraTall] == tall) continue;
        [host setCameraTall:tall why:why];
    }
}

- (BOOL)cameraTallForBundleIdentifier:(NSString *)bundleIdentifier {
    for (DSSceneHost *host in @[ _sceneHost ?: (id)NSNull.null, _topSceneHost ?: (id)NSNull.null, _floatSceneHost ?: (id)NSNull.null ]) {
        if (![host isKindOfClass:DSSceneHost.class]) continue;
        if ([host.bundleIdentifier isEqualToString:bundleIdentifier] && [host isCameraTall]) return YES;
    }
    return NO;
}

- (NSArray<NSString *> *)cameraTallBundleIdentifiers {
    NSMutableArray *bundles = [NSMutableArray array];
    for (DSSceneHost *host in @[ _sceneHost ?: (id)NSNull.null, _topSceneHost ?: (id)NSNull.null, _floatSceneHost ?: (id)NSNull.null ]) {
        if (![host isKindOfClass:DSSceneHost.class]) continue;
        if ([host isCameraTall] && host.bundleIdentifier.length && ![bundles containsObject:host.bundleIdentifier]) {
            [bundles addObject:host.bundleIdentifier];
        }
    }
    return bundles;
}

- (BOOL)stagedKeyboardIsUp {
    return !CGRectIsEmpty(_keyboardFrame);
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
        if (DSMulti702BuildLog()) [self logKeys:[NSString stringWithFormat:@"kept quick bar %.0fpt, ignored %.0fpt",
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
        if (DSMulti702BuildLog()) [self logKeys:[NSString stringWithFormat:@"app kb unparsed %@", line ?: @"?"]];
        return;
    }
    NSString *bundle = bundleBuf[0] ? [NSString stringWithUTF8String:bundleBuf] : @"SpringBoard";
    CGRect frame = CGRectMake(x, y, w, h);
    BOOL hosted = bundle.length > 0 && [self isHostingBundleIdentifier:bundle];
    if (DSMulti702BuildLog()) [self logKeys:[NSString stringWithFormat:@"app kb %@ hosted=%d frame=%@ %@",
                   bundle, hosted, NSStringFromCGRect(frame), [self lowerStageLiftSummary:frame]]];
    if (!hosted) return;
    // 4.5.757 msgfit757: scene-fit nudge from a phone-width line (not keyboard
    // ownership).
    if (DS757On("msgfit757") && CGRectGetWidth(frame) >= CGRectGetWidth([self screenBounds]) - 1.0) {
        DSSceneHost *fit = [self visibleHostForBundleIdentifier:bundle];
        if (fit) {
            DSFeature719MarkAction("msgfit757");
            [fit msgfit757Nudge];
        }
    }
    CGFloat screenH = CGRectGetHeight([self screenBounds]);
    BOOL up = CGRectGetHeight(frame) >= 150.0 && CGRectGetMinY(frame) < screenH - 1.0 &&
              CGRectGetMinY(frame) > screenH * 0.35;
    if (up && DSFeature699On("src746")) {
        BOOL hideKind = strcmp(kind, "hide") == 0;
        CGFloat cardH = CGRectGetHeight(_container.bounds);
        if (cardH < 100.0) cardH = 458.0;
        BOOL cardLocalGone = CGRectGetWidth(frame) < CGRectGetWidth([self screenBounds]) - 1.0 &&
                             CGRectGetMinY(frame) >= cardH - 1.0;
        if (hideKind || cardLocalGone) {
            DSFeature719MarkAction("src746");
            up = NO;
        }
    }
    if (up && DS757On("own757") && _kb723ArbiterBundle.length &&
        ![_kb723ArbiterBundle isEqualToString:bundle] && CGRectGetHeight(_kb723ArbiterKeys) >= 150.0) {
        DSFeature719MarkAction("own757");
        return;
    }
    DSSrc746Tag = @"app dylib kb line";
    [self noteKeyboardFrame:(up ? frame : CGRectZero) source:bundle duration:0.25];
    DSSrc746Tag = nil;
}

// ---- 4.5.745 ghost745 -----------------------------------------------------------
// Depd 12:53:57.494: right after SpringBoard hid its keys (cancel), a keyboard
// "up" for Messages arrived: the app's card-local hide frame {0,458,420,233}
// (keys at the card's bottom edge = gone) / SpringBoard's keys still sliding
// off. That frame stayed as _keyboardFrame and kb707 lifted / slid the cards
// with no keyboard. A card-local frame at or below the card height is hidden;
// an "up" within 0.3 s of a SpringBoard hide with no show since is ignored.
// Off: /var/mobile/.dynamicstage-ghost745-off (per-action crash latch).
- (BOOL)ghost745IsGhost:(CGRect)keyboard source:(NSString *)source {
    if (CGRectIsEmpty(keyboard) || !DSFeature699On("ghost745")) return NO;
    if (source.length == 0 || [source isEqualToString:@"SpringBoard"]) return NO;
    CGRect screen = [self screenBounds];
    CGFloat cardH = CGRectGetHeight(_container.bounds);
    if (cardH < 100.0) cardH = 458.0;
    if (CGRectGetWidth(keyboard) < CGRectGetWidth(screen) - 1.0 && CGRectGetMinY(keyboard) >= cardH - 1.0) {
        DSFeature719MarkAction("ghost745");
        DSDiagnosticsRecordFormat(@"SpringBoard: ghost745 %@ frame %@ is at the card's bottom: hidden", source, NSStringFromCGRect(keyboard));
        return YES;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (_ghost745HideAt > 0.0 && now - _ghost745HideAt < 0.3 && now >= _ghost745HideAt && _ghost745ShowAt < _ghost745HideAt) {
        DSFeature719MarkAction("ghost745");
        // 4.5.802: one line per hide + source + frame (801 printed 4 identical).
        static CFAbsoluteTime lastHide = 0; static NSString *lastKey = nil;
        NSString *key = [NSString stringWithFormat:@"%@|%@", source, NSStringFromCGRect(keyboard)];
        BOOL repeat = DS802On("hide802") && lastHide == _ghost745HideAt && [lastKey isEqualToString:key];
        lastHide = _ghost745HideAt; lastKey = key;
        if (!repeat)
        DSDiagnosticsRecordFormat(@"SpringBoard: ghost745 ignored %@ keyboard up %@ %.2f s after SpringBoard hid its keys",
                                  source, NSStringFromCGRect(keyboard), now - _ghost745HideAt);
        return YES;
    }
    return NO;
}

// ---- 4.5.747 core747: one keyboard state ---------------------------------------
// Every keyboard input reaches the stage through two doors: the keyboard
// system's on/off + owner (keyboardOnScreen697, fed by the arbiter hook) and
// noteKeyboardFrame: (UIKit notes, the app dylib's kb lines, hosted-app notes,
// SpringBoard's own field, the delayed watchers). Both doors write one state
// with a sequence number, and a note is resolved before anything uses it:
//   1. screen coordinates (a card-local frame: at the card's bottom = gone,
//      otherwise the keys really visible on screen);
//   2. trust order, the keyboard system first: a note naming a hosted app other
//      than the keyboard system's owner is not applied; an "up" after the
//      keyboard system said off, with no keys on screen, is not applied.
// Messages keeps its own path (its keys are SpringBoard's staged keys).
// Master off: /var/mobile/.dynamicstage-core747-off (crash latch core747)
// returns to 4.5.746's paths exactly.
- (BOOL)core747On {
    return DSFeature699On("core747");
}

- (NSInteger)ks747RankForSource:(NSString *)source {
    if (DSSrc746Tag) return 1;
    if (source.length == 0 || [source isEqualToString:@"SpringBoard"]) return 3;
    return 2;
}

// 4.5.766 late766: the last app keyboard-up dropped as stale (see ks747Resolve).
static CGRect DSLate766Frame;
static NSString *DSLate766Source = nil;
static CFAbsoluteTime DSLate766At = 0.0;

- (void)ks747NoteArbiter:(BOOL)on frame:(CGRect)frame owner:(NSString *)owner {
    if (![self core747On]) return;
    if (on && DSLate766Source && DSLate766At > 0.0) {
        CFAbsoluteTime age = CFAbsoluteTimeGetCurrent() - DSLate766At;
        NSString *src = DSLate766Source;
        CGRect kb = DSLate766Frame;
        DSLate766Source = nil;
        DSLate766At = 0.0;
        if (age >= 0.0 && age < 1.0 && DS766On("late766")) {
            DSDiagnosticsRecordFormat(@"SpringBoard: late766 keyboard system said on %.2fs after a dropped up from %@: replaying it", age, src);
            __weak __typeof(self) weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf noteKeyboardFrame:kb source:src duration:0.25];
            });
        }
    }
    _ks747Seq += 1;
    _ks747ArbOn = on;
    _ks747ArbAt = CFAbsoluteTimeGetCurrent();
    if ([owner isKindOfClass:NSString.class] && owner.length) _ks747ArbOwner = [owner copy];
    else if (!on) _ks747ArbOwner = nil;
    _ks747ArbFrame = on ? frame : CGRectZero;
}

- (CGRect)ks747Resolve:(CGRect)keyboard source:(NSString *)source {
    if (![self core747On]) return keyboard;
    DSFeature719MarkAction("core747");
    _ks747Seq += 1;
    NSInteger rank = [self ks747RankForSource:source];
    CGRect out = keyboard;
    NSString *why = nil;
    BOOL messages = [source isEqualToString:@"com.apple.MobileSMS"] ||
                    (_stagedKeyboardSlot >= 0 && [self kb723IsMessages:[self containerForSlot:_stagedKeyboardSlot]]);
    // 4.5.749 msg749: Messages folded in where provably identical: its notes are
    // recorded in this state (as before), and a card-local frame at the card's
    // bottom is a hide (what src746 already does to the same lines). Nothing
    // else of the resolve applies to Messages; its input bar and keyboard
    // handoff keep their own path. Off: msg749-off / core749-off (latch msg749).
    if (messages && !CGRectIsEmpty(out) && DSFeature699On("core749") && DSFeature699On("msg749")) {
        CGFloat cardH = CGRectGetHeight(_container.bounds);
        if (cardH < 100.0) cardH = 458.0;
        if (CGRectGetWidth(out) < CGRectGetWidth([self screenBounds]) - 1.0 && CGRectGetMinY(out) >= cardH - 1.0) {
            DSFeature719MarkAction("msg749");
            out = CGRectZero;
            why = @"Messages card-local frame at the card's bottom (msg749)";
        }
    }
    if (!CGRectIsEmpty(out) && !messages) {
        CGRect screen = [self screenBounds];
        CGFloat screenH = CGRectGetHeight(screen);
        CGRect visible = DSVisibleKeyboardFrameOnScreen();
        BOOL keysVisible = !CGRectIsNull(visible) && CGRectGetHeight(visible) >= 150.0 && CGRectGetMinY(visible) < screenH - 1.0;
        if (CGRectGetWidth(out) < CGRectGetWidth(screen) - 1.0) {
            CGFloat cardH = CGRectGetHeight(_container.bounds);
            if (cardH < 100.0) cardH = 458.0;
            if (CGRectGetMinY(out) >= cardH - 1.0) { out = CGRectZero; why = @"card-local frame at the card's bottom"; }
            else if (keysVisible) out = visible;
            else { out = CGRectZero; why = @"card-local frame with no keys on screen"; }
        }
        if (!CGRectIsEmpty(out)) {
            BOOL hostedSource = source.length && ![source isEqualToString:@"SpringBoard"] && [self isHostingBundleIdentifier:source];
            BOOL ownerHosted = _ks747ArbOn && _ks747ArbOwner.length && [self isHostingBundleIdentifier:_ks747ArbOwner];
            if (hostedSource && ownerHosted && ![_ks747ArbOwner isEqualToString:source]) {
                out = CGRectZero;
                why = [NSString stringWithFormat:@"the keyboard system's owner is %@", _ks747ArbOwner];
            } else if (!_ks747ArbOn && _ks747ArbAt > 0.0 && !keysVisible && ![self springBoardIsDrawingKeyboard]) {
                out = CGRectZero;
                why = @"the keyboard system said off and no keys are on screen";
            } else if (hostedSource && !_ks747ArbOn && _ks747ArbAt > 0.0 && DS766On("late766")) {
                // 4.5.766 late766: an app's keyboard-up note that lands after the
                // keyboard system said off (Hello log: keys672 lift=-123 at
                // 07:33:25.8, lift=341 at 07:33:45.2) is stale. Dropped for 0.5 s
                // after the off, and afterwards unless keys are really on screen
                // (core747 above). If the keyboard system then says on within 1 s,
                // the dropped note is replayed, so a note that merely raced
                // ahead of the "on" still lifts the card.
                // Off: late766-off / core766-off (latch late766).
                CFAbsoluteTime since = CFAbsoluteTimeGetCurrent() - _ks747ArbAt;
                if (since >= 0.0 && since < 0.5) {
                    DSFeature719MarkAction("late766");
                    DSLate766Frame = keyboard;
                    DSLate766Source = [source copy];
                    DSLate766At = CFAbsoluteTimeGetCurrent();
                    out = CGRectZero;
                    why = [NSString stringWithFormat:@"late766: keyboard system said off %.2fs ago (stale up; replayed if it says on within 1s)", since];
                }
            }
        }
    }
    if (why) {
        static NSString *lastWhy = nil;
        static CFAbsoluteTime saidAt = 0;
        CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
        // 4.5.766 core766log: rate-limited per reason (not per wording), and
        // the line names the keyboard system's current owner and state at the
        // moment of the drop. Off: core766log-off / core766-off.
        if (DS766On("core766log")) {
            static NSString *lastKind = nil;
            static CFAbsoluteTime kindAt = 0;
            static NSInteger quiet = 0;
            NSRange colon = [why rangeOfString:@" ("];
            NSString *kind = [why hasPrefix:@"the keyboard system's owner is"] ? @"owner" : (colon.location != NSNotFound ? [why substringToIndex:colon.location] : why);
            if ([kind hasPrefix:@"late766"]) kind = @"late766";
            if ([kind isEqualToString:lastKind] && t - kindAt < 3.0 && t >= kindAt) {
                quiet++;
            } else {
                NSString *owner = _ks747ArbOn ? (_ks747ArbOwner ?: @"?") : @"none";
                DSDiagnosticsRecordFormat(@"SpringBoard: core747 keyboard #%lu %@ %@ (rank %ld) not applied: %@ [arbiter %@ owner=%@ %.2fs ago%@]",
                                          (unsigned long)_ks747Seq, source ?: @"?", NSStringFromCGRect(keyboard), (long)rank, why,
                                          _ks747ArbOn ? @"on" : @"off", owner, _ks747ArbAt > 0.0 ? t - _ks747ArbAt : -1.0,
                                          quiet ? [NSString stringWithFormat:@"; %ld like it quiet", (long)quiet] : @"");
                lastKind = kind;
                kindAt = t;
                quiet = 0;
            }
        } else if (![why isEqualToString:lastWhy] || t - saidAt > 3.0 || t < saidAt) {
            lastWhy = why;
            saidAt = t;
            DSDiagnosticsRecordFormat(@"SpringBoard: core747 keyboard #%lu %@ %@ (rank %ld) not applied: %@",
                                      (unsigned long)_ks747Seq, source ?: @"?", NSStringFromCGRect(keyboard), (long)rank, why);
        }
    }
    return out;
}

// ---- 4.5.747 core747: one card-move path -----------------------------------------
// Keyboard lift, side slide and spring back all run through kb707Animate (one
// animator). A new move stops the one in flight where it is and starts from
// there; a drag start, minimise, close, terminate or tuck cancels it.
- (void)move747Cancel:(NSString *)why {
    if (![self core747On]) return;
    _mv747Gen += 1;
    if (_mv747Animator && _mv747Animator.state == UIViewAnimatingStateActive) {
        if ([self anim748On]) {
            // 4.5.748 anim748: finish the keyboard move at its end so the views
            // match the offsets already written (stopping in place left the
            // card drawn mid-way with its offsets at the target).
            [_mv747Animator stopAnimation:NO];
            [_mv747Animator finishAnimationAtPosition:UIViewAnimatingPositionEnd];
        } else {
            [_mv747Animator stopAnimation:YES];
        }
        DSDiagnosticsRecordFormat(@"SpringBoard: core747 card move stopped (%@)", why ?: @"?");
    }
    _mv747Animator = nil;
}

// ---- 4.5.748 core748 -------------------------------------------------------------
// Master off: /var/mobile/.dynamicstage-core748-off returns to 4.5.747.
- (BOOL)core748On {
    return [self core747On] && DSFeature699On("core748");
}

// anim748: one move per card at a time. A keyboard spring in flight is ended
// cleanly when another move (kb707, drag end snap, minimise, restore, tuck:
// everything through animateSpring) starts; UIKit's additive animations carry
// each new move on from the current on-screen position.
// Off: anim748-off (crash latch anim748).
// ---- 4.5.750 core750 -------------------------------------------------------------
// Master off: /var/mobile/.dynamicstage-core750-off returns to 4.5.749.
- (BOOL)core750On {
    return [self core748On] && DSFeature699On("core750");
}

// host750: an explicit state per hosted card (attaching, live, minimised,
// hidden, detached), read from the stage's own flags on the stage tick and on
// every change. Entering "live" from any other state settles the scene once
// (scene748), instead of black731 repairing it later. Never writes foreground
// or active state. Off: host750-off (crash latch host750).
- (NSString *)host750StateFor:(DSSceneHost *)host card:(DSStageContainerView *)card {
    if (!host.isHosting || !card) return @"detached";
    if ([self cardIsParked:card] || _state == DSStageStateMinimized) return @"minimised";
    if (card.hidden || card.alpha < 0.05 || !card.window || _state != DSStageStateOverlay) return @"hidden";
    BOOL settled = [self black733HostSettled:host];   // keeps its first-seen time either way
    // 4.5.754 host754: live as soon as the app is really showing in the card,
    // not after black733's fixed 3 s (753 log: attaching took ~3.05 s every open).
    if (!settled && [self host754On] && [host host754Ready]) settled = YES;
    if (!settled) return @"attaching";
    return @"live";
}

// ---- 4.5.752 fold752: open741 folded into host750 ------------------------------
// open741 used a bare 0.6 s timer to skip a second key grab / scene move. Now
// it is skipped only while host750's state has not changed since the last
// grab / move (same open), still within 0.6 s: a real change (a card going
// live, minimised, hidden or detached) always lets the next one through.
// Off: fold752-off, master core752-off (crash latch fold752).
NSUInteger DSHost752Epoch = 0;
BOOL DSFold752On(void) {
    return DSFeature699On("core751") && DSFeature699On("core752") && DSFeature699On("fold752");
}

// 4.5.754 host754: master core754-off returns to 753. Off: host754-off (crash
// latch host754). (a) attaching -> live from host754Ready, re-checked every
// 0.15 s while a card is attaching; (b) a new state must hold 0.3 s before it
// is acted on (minimise / restore flapping no longer settles the scene each
// time); (c) the log names the app a card had when it detaches.
- (BOOL)host754On {
    return [self core750On] && DSFeature699On("core754") && DSFeature699On("host754");
}

- (void)host754QueueTick:(NSTimeInterval)after {
    if (_host754TickQueued) return;
    _host754TickQueued = YES;
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(after * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_host754TickQueued = NO;
        @try { [strongSelf host750Tick]; } @catch (NSException *exception) {}
    });
}

// 4.5.756 keys756: an app without the DynamicStage dylib cannot be told to end
// editing, so a card minimised while typing keeps the keyboard system's "on"
// (755 log: Beeper on at 16:27:22.77, minimised at 24.61, still on until
// 16:28:15.98) while nothing is drawn for it. Back on screen, a tap on its
// already-editing field asks for nothing, so no keys appear. When such a card
// comes back and the keyboard system still names its app, the stored keyboard
// report is replayed through the normal path (keys raised, card lifted).
// Off: keys756-off / core756-off (crash latch keys756).
- (void)keys756Restored:(NSString *)bundle {
    if (!DS756On("keys756")) return;
    if (![_kb723ArbiterBundle isEqualToString:bundle] || CGRectGetHeight(_kb723ArbiterKeys) < 150.0) return;
    if ([self keys697CardAwayForBundle:bundle]) return;
    DSFeature719MarkAction("keys756");
    CGRect keys = _kb723ArbiterKeys;
    DSDiagnosticsRecordFormat(@"SpringBoard: keys756 %@ came back still owning the keyboard (%@): keys shown again, card lifted", bundle, NSStringFromCGRect(keys));
    __weak __typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        @try { [strongSelf keyboardOnScreen697:YES frame:keys source:bundle]; } @catch (NSException *exception) {
            DSDiagnosticsRecordFormat(@"SpringBoard: keys756 caught %@", exception.reason ?: exception.name);
        }
    });
}


// 4.5.807 pub807 (log only). 20F75 -[SBSceneManager _addScene:] puts a scene's
// handle in _externalApplicationSceneHandles only when the scene has no
// workspaceIdentifier and belongs to another app process; _updateStateForScene:
// withSettings: then adds that handle to externalForegroundApplicationSceneHandles
// while the scene is foreground. A display-layout element plays no part in it
// (and every visible card already has one: camera661 presence). This line
// shows, on each card state change, where the staged scene really stands.
// Off: pub807-off / core807-off.
static void DSPub807Check(NSString *bundle, DSSceneHost *host, NSString *state) {
    @try {
        if (!NSThread.isMainThread || !DS807On("pub807") || !bundle.length || !host) return;
        static BOOL marked = NO;
        if (!marked) { marked = YES; DSFeature699MarkTrying("pub807"); }
        DSFeature719MarkAction("pub807");
        id scene = [host hostedScene];
        Class coord = objc_getClass("SBSceneManagerCoordinator");
        id mgr = [coord respondsToSelector:@selector(mainDisplaySceneManager)] ? ((id (*)(id, SEL))objc_msgSend)(coord, @selector(mainDisplaySceneManager)) : nil;
        id ws = (scene && [scene respondsToSelector:@selector(workspaceIdentifier)]) ? ((id (*)(id, SEL))objc_msgSend)(scene, @selector(workspaceIdentifier)) : nil;
        id handle = (mgr && scene && [mgr respondsToSelector:@selector(existingSceneHandleForScene:)])
            ? ((id (*)(id, SEL, id))objc_msgSend)(mgr, @selector(existingSceneHandleForScene:), scene) : nil;
        NSSet *ext = (mgr && [mgr respondsToSelector:@selector(externalApplicationSceneHandles)])
            ? ((id (*)(id, SEL))objc_msgSend)(mgr, @selector(externalApplicationSceneHandles)) : nil;
        NSSet *extFg = (mgr && [mgr respondsToSelector:@selector(externalForegroundApplicationSceneHandles)])
            ? ((id (*)(id, SEL))objc_msgSend)(mgr, @selector(externalForegroundApplicationSceneHandles)) : nil;
        BOOL inExt = handle && [ext isKindOfClass:NSSet.class] && [ext containsObject:handle];
        BOOL inFg = handle && [extFg isKindOfClass:NSSet.class] && [extFg containsObject:handle];
        DSDiagnosticsRecordFormat(@"SpringBoard: pub807: external-foreground now contains %@=%@ (card %@; external=%@ workspace=%@ handle=%@ scene=%@; %lu external-foreground handle(s))",
            bundle, inFg ? @"YES" : @"NO", state ?: @"?", inExt ? @"YES" : @"NO", ws ?: @"nil", handle ? @"yes" : @"no", scene ? @"yes" : @"no",
            (unsigned long)([extFg isKindOfClass:NSSet.class] ? extFg.count : 0));
    } @catch (NSException *exception) {
    }
}

- (void)host750Tick {
    if (![self core750On] || !DSFeature699On("host750")) return;
    if (!_host750State) _host750State = [NSMutableDictionary dictionary];
    BOOL h754 = [self host754On];
    if (!_host754Bundle) _host754Bundle = [NSMutableDictionary dictionary];
    if (!_host754Pending) _host754Pending = [NSMutableDictionary dictionary];
    if (!_host754PendingAt) _host754PendingAt = [NSMutableDictionary dictionary];
    DSSceneHost *hosts[2] = { _sceneHost, _topSceneHost };
    DSStageContainerView *cards[2] = { _container, _topContainer };
    for (int i = 0; i < 2; i++) {
        NSString *key = i == 0 ? @"bottom" : @"top";
        // 4.5.755 name755: the slot's app name is refreshed every tick while it
        // hosts, so a later detach names the app that was really there.
        // 4.5.756 track756: same slot state but a different app = the old app
        // left and the new one moved in (755 log 16:27:58.17: Messenger's card
        // closed, Beeper moved into the bottom slot, nothing was logged).
        if (h754 && DS756On("track756") && hosts[i].isHosting && hosts[i].bundleIdentifier.length &&
            _host754Bundle[key] && ![_host754Bundle[key] isEqualToString:hosts[i].bundleIdentifier]) {
            DSFeature719MarkAction("track756");
            DSDiagnosticsRecordFormat(@"SpringBoard: host756 %@ card: %@ left the slot, %@ moved in (%@)", key,
                                      _host754Bundle[key], hosts[i].bundleIdentifier, _host750State[key] ?: @"detached");
        }
        if (h754 && DSName755On() && hosts[i].isHosting && hosts[i].bundleIdentifier.length &&
            ![_host754Bundle[key] isEqualToString:hosts[i].bundleIdentifier]) {
            if (_host754Bundle[key]) DSFeature719MarkAction("name755");
            _host754Bundle[key] = [hosts[i].bundleIdentifier copy];
        }
        NSString *now = [self host750StateFor:hosts[i] card:cards[i]];
        NSString *was = _host750State[key] ?: @"detached";
        if (h754 && [now isEqualToString:@"attaching"]) [self host754QueueTick:0.15];
        if ([now isEqualToString:was]) {
            [_host754Pending removeObjectForKey:key];
            continue;
        }
        if (h754) {
            CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
            if (![_host754Pending[key] isEqualToString:now]) {
                _host754Pending[key] = now;
                _host754PendingAt[key] = @(t);
                [self host754QueueTick:0.3];
                continue;
            }
            if (t - _host754PendingAt[key].doubleValue < 0.3) {
                [self host754QueueTick:0.3 - (t - _host754PendingAt[key].doubleValue) + 0.01];
                continue;
            }
            [_host754Pending removeObjectForKey:key];
            DSFeature719MarkAction("host754");
        }
        _host750State[key] = now;
        DSHost752Epoch += 1;
        DSFeature719MarkAction("host750");
        NSString *bundle = hosts[i].isHosting ? hosts[i].bundleIdentifier : nil;
        if (h754 && !bundle) bundle = _host754Bundle[key];
        if (hosts[i].isHosting && hosts[i].bundleIdentifier) _host754Bundle[key] = hosts[i].bundleIdentifier;
        else if ([now isEqualToString:@"detached"]) [_host754Bundle removeObjectForKey:key];
        DSDiagnosticsRecordFormat(@"SpringBoard: host750 %@ card %@: %@ -> %@", key, bundle ?: hosts[i].bundleIdentifier ?: @"-", was, now);
        DSGest770NoteEvent(@"host750");
        if (DSGest770On() && ![bundle isEqualToString:@"com.apple.MobileSMS"] && ([now isEqualToString:@"minimised"] || [was isEqualToString:@"minimised"])) {   // 4.5.770 gest770
            @try { DSDiagnosticsRecordFormat(@"SpringBoard: gest770 %@ %@ -> %@ app view: %@", bundle ?: @"-", was, now, [hosts[i] gest770State]); } @catch (NSException *exception) {}
            if ([was isEqualToString:@"minimised"] && [now isEqualToString:@"live"]) DSGest770MarkRestored(bundle);
        }
        if ([now isEqualToString:@"live"] || [was isEqualToString:@"live"]) DSPub807Check(bundle, hosts[i], now);   // 4.5.807 log only
        if ([now isEqualToString:@"live"]) [self scene748Settle:[NSString stringWithFormat:@"host750 %@ -> live", was] after:0.1];
        if ([now isEqualToString:@"live"] && [was isEqualToString:@"minimised"] && bundle.length) [self keys756Restored:bundle];
    }
}

- (BOOL)anim748On {
    return [self core748On] && DS809Latched("anim748");
}

// scene748: one place that settles a hosted scene when its card comes back
// (keyboard slide ended, restored from minimised, search closed): it runs the
// same "card is showing the app" step black731 used to run as a later repair,
// at the moment of the transition. Hosts still starting, Messages, keyboard up,
// drags and system transitions are skipped (as black731).
// Off: scene748-off (crash latch scene748).
- (void)scene748Settle:(NSString *)why after:(NSTimeInterval)after {
    if (![self core748On] || !DSFeature699On("scene748")) return;
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(after * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        @try {
            [strongSelf scene748SettleNow:why];
        } @catch (NSException *exception) {
            DSDiagnosticsRecordFormat(@"SpringBoard: scene748 caught %@", exception.reason ?: exception.name);
        }
    });
}

- (void)scene748SettleNow:(NSString *)why {
    if (DSCall733HandsOff(@"scene748")) return;
    if (!_activated || _state != DSStageStateOverlay || _searchSlot >= 0) return;
    if (!DSPhoneSize678Always() || [self stagedKeyboardIsUp] || _stageDragActive || DSStageDragSettlingFast(0.3)) return;
    if ([DSSceneHost homeGestureIsActive] || [DSSceneHost systemTransitionBusy] || [DSSceneHost sceneSettingsUpdateDepth] > 0) return;
    DSSceneHost *hosts[2] = { _sceneHost, _topSceneHost };
    DSStageContainerView *cards[2] = { _container, _topContainer };
    for (int i = 0; i < 2; i++) {
        DSSceneHost *host = hosts[i];
        DSStageContainerView *card = cards[i];
        if (!host.isHosting || !card || card.hidden || card.alpha < 0.05 || [self cardIsParked:card]) continue;
        if ([host.bundleIdentifier isEqualToString:@"com.apple.MobileSMS"]) continue;
        if (fabs(card.sideOffset) > 0.5 || fabs(card.liftOffset) > 0.5) continue;
        if ([host isPhoneSize675] || ![self phoneSize678AlwaysAllowsHost:host] || ![self black733HostSettled:host]) continue;
        DSFeature719MarkAction("scene748");
        DSDiagnosticsRecordFormat(@"SpringBoard: scene748 %@ settled on screen (%@)", host.bundleIdentifier ?: @"?", why ?: @"?");
        [self phoneSize678HostReady:host];
    }
}

// 4.5.754 kbnan754: a keyboard frame with inf / NaN in it (CGRectNull is
// {inf, inf}) names no keyboard: it is "hidden" from the moment it arrives, at
// both doors (app / UIKit notes here, the keyboard system in keyboardOnScreen697).
// Off: kbnan754-off / core754-off (crash latch kbnan754).
static BOOL DSKbNan754Bad(CGRect r) {
    return !isfinite(r.origin.x) || !isfinite(r.origin.y) || !isfinite(r.size.width) || !isfinite(r.size.height);
}

static BOOL DSKbNan754On(void) {
    return DSFeature699On("core754") && DSFeature699On("kbnan754");
}

- (void)noteKeyboardFrame:(CGRect)keyboard source:(NSString *)source duration:(NSTimeInterval)duration {
    DSPerfCount(DSPerfCounterKeyboardNotes);
    if (DSKbNan754Bad(keyboard) && DSKbNan754On()) {
        DSFeature719MarkAction("kbnan754");
        DSDiagnosticsRecordFormat(@"SpringBoard: kbnan754 %@ keyboard frame %@ has no real size: taken as hidden",
                                  source ?: @"?", NSStringFromCGRect(keyboard));
        keyboard = CGRectZero;
    }
    @try {
        // 4.5.746 src746: every keyboard "up" credited to an app says where it came from.
        if (!CGRectIsEmpty(keyboard) && source.length && ![source isEqualToString:@"SpringBoard"] && DSFeature699On("src746")) {
            static NSString *lastKey = nil;
            static CFAbsoluteTime lastAt = 0;
            NSString *key = [NSString stringWithFormat:@"%@ %@", source, NSStringFromCGRect(keyboard)];
            CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
            // 4.5.766 src766: a frame that starts at or below the screen bottom is
            // the keys going down (Hello log flip-flopped 932/586 during a hide).
            // Tagged "down", one line per app per 3 s. Off: src766-off / core766-off.
            BOOL offscreen766 = CGRectGetMinY(keyboard) >= CGRectGetHeight([self screenBounds]) - 1.0;
            BOOL src766 = DS766On("src766");
            if (src766 && offscreen766) {
                static NSString *downSource = nil;
                static CFAbsoluteTime downAt = 0;
                static NSInteger downQuiet = 0;
                if ([source isEqualToString:downSource] && t - downAt < 3.0 && t >= downAt) {
                    downQuiet++;
                } else {
                    DSFeature719MarkAction("src766");
                    DSDiagnosticsRecordFormat(@"SpringBoard: src766 down %@ frame=%@ (offscreen%@)",
                                              source, NSStringFromCGRect(keyboard),
                                              downQuiet ? [NSString stringWithFormat:@"; %ld more quiet", (long)downQuiet] : @"");
                    downSource = [source copy];
                    downAt = t;
                    downQuiet = 0;
                }
                lastKey = key;
                lastAt = t;
            }
            if (!(src766 && offscreen766) && (![key isEqualToString:lastKey] || t - lastAt > 2.0 || t < lastAt)) {
                lastKey = key;
                lastAt = t;
                NSString *caller = DSSrc746Tag;
                if (!caller && DSLog754On()) caller = DSCaller754(1, 7, NO);
                // 4.5.815 perf815: no [NSThread callStackSymbols] (symbolicates
                // the stack on SpringBoard's main thread for every new keyboard frame).
                if (!caller && DSPerf815Fast()) caller = @"(stack not read, perf815)";
                if (!caller) {
                    NSArray<NSString *> *stack = [NSThread callStackSymbols];
                    for (NSUInteger i = 1; i < stack.count && i < 8; i++) {
                        NSString *f = stack[i];
                        NSRange r = [f rangeOfString:@"0x"];
                        if (r.location != NSNotFound) {
                            NSRange sp = [f rangeOfString:@" " options:0 range:NSMakeRange(r.location, f.length - r.location)];
                            if (sp.location != NSNotFound) f = [f substringFromIndex:sp.location + 1];
                        }
                        caller = caller ? [caller stringByAppendingFormat:@" < %@", f] : f;
                    }
                }
                CGRect visible = DSVisibleKeyboardFrameOnScreen();
                CFAbsoluteTime sinceHide = _ghost745HideAt > 0.0 ? t - _ghost745HideAt : -1.0;
                DSDiagnosticsRecordFormat(@"SpringBoard: src746 up %@ frame=%@ visible=%@ slot=%ld sinceHide=%.2f via %@",
                                          source, NSStringFromCGRect(keyboard), NSStringFromCGRect(visible),
                                          (long)[self slotForHostedBundle:source], sinceHide, caller ?: @"?");
            }
        }
        if ([self ghost745IsGhost:keyboard source:source]) keyboard = CGRectZero;
        // 4.5.815 kbrule815: one rule for shifting stages. An app's keyboard
        // counts only when that app is on a visible, full-size (not minimised)
        // card on a visible stage. A full-screen app (Signal after its card
        // closed), an app not on the stage, or a minimised card is taken as
        // keys hidden, so nothing shifts for it and shifted cards come back.
        // SpringBoard's own keys (stand-in / picker search) are unchanged.
        // Off: kbrule815-off / core815-off (812-1); latch kbrule815.
        if (!CGRectIsEmpty(keyboard) && source.length && ![source isEqualToString:@"SpringBoard"] &&
            DS815On("kbrule815") && DS809Latched("kbrule815")) {
            NSString *why815 = nil;
            NSInteger slot815 = [self slotForHostedBundle:source];
            if (![self isStageVisible]) why815 = @"stage not on screen";
            else if (slot815 < 0 || ![self isHostingBundleIdentifier:source]) why815 = @"app is not on a stage card (full screen or closed)";
            else {
                DSStageContainerView *card815 = [self containerForSlot:slot815];
                if (!card815 || !card815.window || card815.hidden || card815.alpha < 0.05 ||
                    CGRectGetWidth(card815.bounds) < 120.0 || CGRectGetHeight(card815.bounds) < 120.0) why815 = @"its card is minimised / hidden";
            }
            if (why815) {
                static NSString *said815 = nil;
                NSString *k815 = [NSString stringWithFormat:@"%@|%@", source, why815];
                if (![k815 isEqualToString:said815]) {
                    said815 = k815;
                    DSFeature719MarkAction("kbrule815");
                    DSDiagnosticsRecordFormat(@"SpringBoard: kbrule815 %@ keyboard %@ ignored: %@ (no stage shift)", source, NSStringFromCGRect(keyboard), why815);
                }
                keyboard = CGRectZero;
            }
        }
        // 4.5.802 lift802: an app's keyboard "up" that arrives after the
        // keyboard system said the keys are down (arbiter off < 1 s ago, no new
        // arbiter on) is the app's stale frame (801 01:13:22.659 Beeper
        // lift=-123 7 ms after arbiter on=0). Taken as hidden. Messages keeps
        // msg742's own path. Off: lift802-off / core802-off (latch lift802).
        // 4.5.803 lift803: state rule, no time window. An app's keyboard "up"
        // is ignored while the keyboard system's last word for that app was
        // keys-down (set at the arbiter callback, cleared by its next keys-up).
        // Off: lift803-off / core803-off (then 802's 1 s rule).
        BOOL lift803 = DS803On("lift803");
        if (lift803 && !CGRectIsEmpty(keyboard) && source.length && ![source isEqualToString:@"SpringBoard"] &&
            ![source isEqualToString:@"com.apple.MobileSMS"] && [source isEqualToString:DS803KeysDownFor()] &&
            [self isHostingBundleIdentifier:source]) {
            static NSString *saidKey = nil;
            static BOOL marked = NO;
            if (!marked) { marked = YES; DSFeature699MarkTrying("lift803"); }
            DSFeature719MarkAction("lift803");
            // 4.5.804 lift804: one line per keys-down (803 wrote one per frame
            // value, 22 lines for Beeper). Off: lift804-off.
            NSString *k = DS804On("lift804") ? [NSString stringWithFormat:@"%@|%lu", source, DS804KeysDownSerial()]
                                              : [NSString stringWithFormat:@"%@|%@", source, NSStringFromCGRect(keyboard)];
            if (![k isEqualToString:saidKey]) {
                saidKey = k;
                DSDiagnosticsRecordFormat(@"SpringBoard: lift803 ignored %@ keyboard up %@: the keyboard system said its keys are down (no lift)",
                                          source, NSStringFromCGRect(keyboard));
            }
            keyboard = CGRectZero;
        } else if (!lift803 && !CGRectIsEmpty(keyboard) && source.length && ![source isEqualToString:@"SpringBoard"] &&
            ![source isEqualToString:@"com.apple.MobileSMS"] && [self isHostingBundleIdentifier:source] &&
            !DSKbVis768ArbiterIsOn() && DSKbVis768ArbiterOffTime() > 0.0 && [self lift802KeysJustWentDown:1.0]) {
            static CFAbsoluteTime saidFor = 0;
            static BOOL marked = NO;
            if (!marked) { marked = YES; DSFeature699MarkTrying("lift802"); }
            DSFeature719MarkAction("lift802");
            if (saidFor != DSKbVis768ArbiterOffTime()) {
                saidFor = DSKbVis768ArbiterOffTime();
                DSDiagnosticsRecordFormat(@"SpringBoard: lift802 ignored %@ keyboard up %@ %.2f s after the keys went down (no lift)",
                                          source, NSStringFromCGRect(keyboard), CFAbsoluteTimeGetCurrent() - saidFor);
            }
            keyboard = CGRectZero;
        }
        keyboard = [self ks747Resolve:keyboard source:source];
    } @catch (NSException *exception) {
    }
    [self noteKeyboardFrame703:keyboard source:source duration:duration];
    // 4.5.704 focus704: after every lift / drop / side park this note made,
    // the card being typed in comes to the front and the other one steps aside.
    [self focus704Schedule];
    @try {
        [self sync725NoteKeyboard:keyboard];
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: sync725 caught %@", exception.reason ?: exception.name);
    }
}

// ---- 4.5.725 sync725 ----------------------------------------------------------
// "Why aren't the top cards synced with the change? When the keyboard goes,
// the cards should come back at once." kb707 already moved the typing card and
// slid the other one in one spring, but (a) it looked 0.05 s after the note and
// again at 0.40 s, and the first look often saw the 243 pt pre-suggestion-bar
// frame: the card lifted a bit with no slide (no overlap yet), then at 0.40 s
// lifted the rest AND started the slide - two moves, the slide 0.35 s late;
// (b) after a hide it waited 0.4 s with no keys + a 0.45 s re-check (up to
// ~0.85 s, longer while the keys were still sliding off). Now: kb707 looks at
// once (next run-loop turn) on every keyboard note and plans with the full
// keyboard height it has seen, so lift and slide start together in one spring;
// a hide springs every card back after 0.1 s (a show inside that 0.1 s cancels
// it: the picker re-raise blip). Messages and Beeper 684 keep the old timing.
// Off: /var/mobile/.dynamicstage-sync725-off (per-action crash latch; kb707
// itself is never latched).
- (BOOL)sync725On {
    return DSFeature699On("sync725");
}

- (BOOL)sync725OldTimingFor:(DSStageContainerView *)card {
    if (!card) return NO;
    DSSceneHost *host = [self sceneHostForCard:card];
    if (!host.isHosting) return NO;
    NSString *bundle = host.bundleIdentifier;
    if ([bundle isEqualToString:@"com.beeper.chat.ios"] && DSFeature699On("fast743")) return NO;
    // 4.5.786 return786: Messages springs back with the hide like every other
    // app (0.1 s blip guard), not after the 0.4 s absent wait + 0.45 s re-check.
    // Off: /var/mobile/.dynamicstage-return786-off
    if ([bundle isEqualToString:@"com.apple.MobileSMS"] && DS786On("return786")) return NO;
    return [bundle isEqualToString:@"com.apple.MobileSMS"] || [bundle isEqualToString:@"com.beeper.chat.ios"];
}

// ---- 4.5.743 fast743 -----------------------------------------------------------
// The hide note only reached sync725 once the keys had fully left the screen
// (noteHostedAppKeyboard returns early while they are still sliding), so the
// 0.1 s path never ran and kb707 fell back to its 0.4 s absent wait + 0.45 s
// re-check ("typing ended", ~0.5-0.9 s late). Now the first hide signal (app
// keyboard note on=0, arbiter on=0) starts the spring-back after 0.1 s; if the
// keys have not moved by then it was a blip and nothing happens. Messages keeps
// its old timing (msg742). Off: /var/mobile/.dynamicstage-fast743-off
// (per-action crash latch).
- (BOOL)fast743OwnerIsMessages {
    DSStageContainerView *owner = _kb707Owner;
    if (!owner) return NO;
    DSSceneHost *host = [self sceneHostForCard:owner];
    if (DS786On("return786")) return NO;   // 4.5.786 return786
    return host.isHosting && [host.bundleIdentifier isEqualToString:@"com.apple.MobileSMS"];
}

- (void)fast743KeysHiding:(NSString *)why {
    if (!DSFeature699On("fast743") || ![self sync725On] || !_kb707Active) return;
    if (![self kb707Owns] || [self fast743OwnerIsMessages]) return;
    DSFeature719MarkAction("fast743");
    CGRect keysAt = DSVisibleKeyboardFrameOnScreen();
    CGFloat yAt = CGRectIsNull(keysAt) ? -1.0 : CGRectGetMinY(keysAt);
    if (_sync725HideAt <= 0.0) _sync725HideAt = CFAbsoluteTimeGetCurrent();
    DSDiagnosticsRecordFormat(@"SpringBoard: fast743 keys hiding (%@)", why ?: @"?");
    NSUInteger gen = ++_sync725Gen;
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.11 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || gen != strongSelf->_sync725Gen) return;
        @try {
            CGRect now = DSVisibleKeyboardFrameOnScreen();
            BOOL stillUp = !CGRectIsNull(now) && CGRectGetHeight(now) >= 150.0 && yAt >= 0.0 &&
                           CGRectGetMinY(now) <= yAt + 1.0;
            if (stillUp) {
                strongSelf->_sync725HideAt = 0.0;
                DSDiagnosticsRecordFormat(@"SpringBoard: fast743 blip, keys still up");
                return;
            }
            if ([strongSelf kb707Owns]) [strongSelf kb707Evaluate:@"keys gone (fast743)"];
        } @catch (NSException *exception) {
            DSDiagnosticsRecordFormat(@"SpringBoard: fast743 caught %@", exception.reason ?: exception.name);
        }
    });
}

- (void)sync725NoteKeyboard:(CGRect)keyboard {
    if (![self sync725On] || ![self kb707Owns]) return;
    CGFloat screenH = CGRectGetHeight([self screenBounds]);
    BOOL up = !CGRectIsEmpty(keyboard) && CGRectGetHeight(keyboard) >= 150.0 && CGRectGetMinY(keyboard) < screenH - 1.0;
    if (up) {
        _sync725HideAt = 0.0;
        if (CGRectGetHeight(keyboard) >= 280.0) _sync725FullKeysY = CGRectGetMinY(keyboard);
    } else if (_kb707Active && _sync725HideAt <= 0.0) {
        // 4.5.787 return787: Messages' keyboard notes carry a zero frame even
        // while its keys are coming up (Hufhj 07:19:37.692 / 45.707), so for
        // Messages a not-up frame here is not a hide. Its fast return starts
        // only from real hide signals (arbiter on=0, SpringBoard's own hide,
        // kbdrag744). Off: /var/mobile/.dynamicstage-return787-off
        BOOL messages787 = NO;
        if (DS787On("return787")) {
            DSStageContainerView *owner = _kb707Owner;
            DSSceneHost *host = owner ? [self sceneHostForCard:owner] : nil;
            messages787 = host.isHosting && [host.bundleIdentifier isEqualToString:@"com.apple.MobileSMS"];
        }
        if (!messages787) _sync725HideAt = CFAbsoluteTimeGetCurrent();
    }
    DSFeature719MarkAction("sync725");
    NSUInteger gen = ++_sync725Gen;
    __weak __typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || gen != strongSelf->_sync725Gen) return;
        @try {
            if ([strongSelf kb707Owns]) [strongSelf kb707Evaluate:(up ? @"keys (at once)" : @"keys gone")];
        } @catch (NSException *exception) {
            DSDiagnosticsRecordFormat(@"SpringBoard: sync725 caught %@", exception.reason ?: exception.name);
        }
    });
}

- (void)sync725Later:(NSTimeInterval)after {
    NSUInteger gen = ++_sync725Gen;
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(after * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || gen != strongSelf->_sync725Gen) return;
        @try {
            if ([strongSelf kb707Owns]) [strongSelf kb707Evaluate:@"keys gone"];
        } @catch (NSException *exception) {
            DSDiagnosticsRecordFormat(@"SpringBoard: sync725 caught %@", exception.reason ?: exception.name);
        }
    });
}

- (void)noteKeyboardFrame703:(CGRect)keyboard source:(NSString *)source duration:(NSTimeInterval)duration {
    // 4.5.683: an app whose own keyboard is in its card does not move the stage.
    if (!CGRectIsEmpty(keyboard) && _searchSlot < 0 && _stagedKeyboardSlot < 0 &&
        ([self phoneSize683ActiveForBundle:source] ||
         (DSPS683SessionBundle && ([source isEqualToString:@"SpringBoard"] || [source isEqualToString:DSPS683SessionBundle])))) {
        [self phoneSize675Log:@"note683"
                         line:[NSString stringWithFormat:@"phonesize683 keyboard note %@ from %@ ignored (%@'s own keyboard is in its card): no lift, no drop, no window move",
                               NSStringFromCGRect(keyboard), source ?: @"?", DSPS683SessionBundle ?: source ?: @"?"]
                        every:5.0];
        return;
    }
    [self phoneSize675NoteKeyboard:keyboard source:source];
    if (DSMulti702BuildLog()) [self logKeys:[NSString stringWithFormat:@"note src=%@ frame=%@ %@",
                   source ?: @"?",
                   NSStringFromCGRect(keyboard),
                   [self lowerStageLiftSummary:keyboard]]];
    [self keys672NoteKeyboard:keyboard source:source];
    if (_searchSlot >= 0) {
        CGRect screen = [self screenBounds];
        CGRect keys = keyboard;
        if (CGRectIsEmpty(keys) || CGRectGetHeight(keys) < 150.0 ||
            CGRectGetMinY(keys) >= CGRectGetMaxY(screen) - 1.0) {
            keys = CGRectZero;
        }
        DSStageContainerView *card = [self containerForSlot:_searchSlot];
        // 4.5.705 focus705: the 704 flicker. A search keyboard reports short
        // or empty frames while the key window is reclaimed and the field is
        // re-asserted / restarted (ensurePickerSearchKeyboard, every 0.16 s).
        // Each such report undid the drop and the side park at once (no
        // animation), and the next show did both again: drop / slide / snap
        // back / drop... A hide now waits 0.35 s; any keyboard report in
        // between cancels it, and it only goes through when no keyboard is on
        // screen any more.
        BOOL kb720Direct = CGRectIsEmpty(keys) && card && !_focus705Replaying && [self kb707Owns] && [self kb720On];
        if (kb720Direct) {
            // 4.5.720: kb707 owns the search card; its absent window (0.4 s,
            // re-checked while keys are on screen) is the only debounce.
            _focus705HideGen += 1;
            [self kb720Act:@"search keys gone: straight to kb707 (no 705 hold on top of kb707's own wait)"];
        }
        if (!kb720Direct && CGRectIsEmpty(keys) && card && !_focus705Replaying && [self focus705On]) {
            NSUInteger hideGen = ++_focus705HideGen;
            NSInteger hideSlot = _searchSlot;
            NSString *sourceCopy = source.length ? [source copy] : @"SpringBoard";
            DSPerfCount(DSPerfCounterSearchHideHeld);
            __weak __typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                __strong __typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf || hideGen != strongSelf->_focus705HideGen) return;
                CGRect still = DSVisibleKeyboardFrameOnScreen();
                if (!CGRectIsNull(still) && CGRectGetHeight(still) >= 150.0) return;
                // The hide belongs to the search it came in for: if search has
                // ended meanwhile, undo that search's lift / park (as 704 did).
                NSInteger saved = strongSelf->_searchSlot;
                if (saved < 0) strongSelf->_searchSlot = hideSlot;
                strongSelf->_focus705Replaying = YES;
                @try {
                    [strongSelf noteKeyboardFrame:CGRectZero source:sourceCopy duration:0.0];
                } @catch (NSException *exception) {
                    DSDiagnosticsRecordFormat(@"SpringBoard: focus705 caught %@", exception.reason ?: exception.name);
                }
                strongSelf->_focus705Replaying = NO;
                if (saved < 0 && strongSelf->_searchSlot == hideSlot) strongSelf->_searchSlot = saved;
            });
            return;
        }
        if (!CGRectIsEmpty(keys)) _focus705HideGen += 1;
        if ([self kb707Owns]) {
            // 4.5.707 kb707: the search is a typing owner like any app field;
            // the controller lifts this card and slides the other one.
            _keyboardFrame = keys;
            _keyboardLiftSlot = _searchSlot;
            if (CGRectIsEmpty(keys)) [self invalidateTopKeyboardWait];
            return;
        }
        CGFloat lift = 0.0;
        if (card && !CGRectIsEmpty(keys)) {
            lift = [self splitKeyboardClearLiftForCard:card keyboard:keys];
            // Search on the top half is already clear of the keys. Bring that
            // card down onto them, the same as typing in the top stage.
            // 4.5.705 focus705: not with two stacked stages - the upper card is
            // clear of the keys and does not cover the lower one, so nothing moves.
            if (lift < 1.0 && ![self focus705UpperSearchStill]) {
                CGFloat drop = [self dropNeededToSitOnKeyboard:keys forCard:card];
                if (drop > 1.0) lift = -drop;
            }
        }
        _keyboardFrame = keys;
        _keyboardLiftSlot = _searchSlot;
        if (card && lift < -0.5) {
            [self scheduleSettledTopKeyboardMove];
            [self parkStagesForKeyboardOwner:card keysUp:YES];
            if (DSMulti702BuildLog()) [self logLift:[NSString stringWithFormat:@"search slot=%ld drop=%.0f %@",
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
        if (DSMulti702BuildLog()) [self logLift:[NSString stringWithFormat:@"search slot=%ld lift=%.0f %@",
                       (long)_searchSlot, lift, [self lowerStageLiftSummary:keys]]];
        return;
    }
    static NSInteger hideWaits = 0;
    static NSInteger showWaits = 0;
    BOOL kb744Through = NO;
    if ([DSSceneHost sceneSettingsUpdateDepth] > 0) {
        NSString *sourceCopy = source.length ? [source copy] : @"SpringBoard";
        NSTimeInterval motion = duration;
        CGRect keyboardCopy = keyboard;
        if (CGRectIsEmpty(keyboard)) {
            if (hideWaits < 8) {
                hideWaits += 1;
                if (DSMulti702BuildLog()) [self logKeys:[NSString stringWithFormat:@"hide waiting, scene update in progress try=%ld src=%@",
                               (long)hideWaits, sourceCopy]];
                __weak typeof(self) weakSelf = self;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [weakSelf noteKeyboardFrame:CGRectZero source:sourceCopy duration:motion];
                });
            } else {
                if (DSMulti702BuildLog()) [self logKeys:@"hide dropped, scene update never finished"];
                if (DSFeature699On("kbshow728")) hideWaits = 0;   // 4.5.728: same never-reset counter
                // 4.5.744 kbhide744: a hide is never dropped; apply it now.
                if (DSFeature699On("kbhide744")) {
                    DSFeature719MarkAction("kbhide744");
                    hideWaits = 0;
                    DSDiagnosticsRecord(@"SpringBoard: kbhide744 applied a hide that waited 8 scene updates");
                    kb744Through = YES;
                }
            }
        } else if (showWaits < 8 || (DSFeature699On("kbshow728") && showWaits < 24)) {
            showWaits += 1;
            if (DSMulti702BuildLog()) [self logLift:[NSString stringWithFormat:@"show waiting, scene update try=%ld %@",
                           (long)showWaits, [self lowerStageLiftSummary:keyboard]]];
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [weakSelf noteKeyboardFrame:keyboardCopy source:sourceCopy duration:motion];
            });
        } else {
            if (DSMulti702BuildLog()) [self logLift:[NSString stringWithFormat:@"show dropped, scene update never finished %@",
                           [self lowerStageLiftSummary:keyboard]]];
            // 4.5.728 kbshow728: the counter was never reset after a drop, so every
            // later show inside a scene update was dropped at once. Reset it and
            // let kb707 re-check once the update is over.
            if (DSFeature699On("kbshow728")) {
                DSFeature719MarkAction("kbshow728");
                showWaits = 0;
                DSDiagnosticsRecord(@"SpringBoard: kbshow728 recovered because a keyboard show waited 24 scene updates: counter reset, kb707 re-checks");
                [self kb707Schedule];
            }
        }
        if (!kb744Through) return;
    }
    showWaits = 0;
    if (CGRectIsEmpty(keyboard)) hideWaits = 0;
    if ([self appKeepsItsOwnKeyboard:source]) {
        if (DSMulti702BuildLog()) [self logLift:[NSString stringWithFormat:@"skipped, %@ keeps its own keyboard", source ?: @"?"]];
        return;
    }
    if ([self hostedKeyboardStaysWithTheApp] && _searchSlot < 0 && _stagedKeyboardSlot < 0) {
        if (DSMulti702BuildLog()) [self logLift:@"skipped, hosted keyboard stays with the app"];
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
            if (DSMulti702BuildLog()) [self logKeys:[NSString stringWithFormat:@"hide ignored, keys still %@", NSStringFromCGRect(visible)]];
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
        if (CGRectIsEmpty(keyboard) && [self kb707Owns]) {
            [self invalidateTopKeyboardWait];
            return;   // 4.5.707 kb707: the controller springs everything back
        }
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
    if (DS805PredictOn() && !CGRectIsEmpty(keyboard)) {
        static CGFloat lastH = 0;
        if (fabs(lastH - CGRectGetHeight(keyboard)) > 0.5) {
            lastH = CGRectGetHeight(keyboard);
            CGRect lift = [self keyboardFrameForLift:keyboard];
            DSDiagnosticsRecordFormat(@"SpringBoard: predict805 keyboard from %@ measured %.0f pt tall (lift uses %.0f pt)",
                                      source ?: @"?", CGRectGetHeight(keyboard), CGRectGetHeight(lift));
        }
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
        if (DSMulti702BuildLog()) [self logLift:[NSString stringWithFormat:@"top drop slot=%ld shift=%.0f keys671selfAvoid=%d %@",
                       (long)_keyboardLiftSlot, shift, [self keys671CardAppAvoidsKeysItself:typingCard],
                       [self lowerStageLiftSummary:keyboard]]];
        if (shift < -0.5) {
            [self scheduleSettledTopKeyboardMove];
        } else {
            [self invalidateTopKeyboardWait];
            [self setKeyboardLift:0.0 onCard:typingCard duration:motion];
        }
        return;
    }
    if (DSMulti702BuildLog()) [self logLift:[NSString stringWithFormat:@"stack slot=%ld need=%.0f keys671selfAvoid=%d %@",
                   (long)_keyboardLiftSlot, lift, [self keys671CardAppAvoidsKeysItself:typingCard],
                   [self lowerStageLiftSummary:keyboard]]];
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
    if ([self kb707Gate]) return;   // 4.5.707 kb707: the keyboard controller is the only mover
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
    // 4.5.697: the 14-line geometry dump is built on layout passes. In the
    // quiet log it is built at most once a second, only for the rim-off-card
    // crash note, and not written to the log.
    BOOL quiet = DSLogQuiet();
    if (quiet) {
        static CFAbsoluteTime quietAt = 0;
        CFAbsoluteTime quietNow = CFAbsoluteTimeGetCurrent();
        if (quietNow - quietAt < 1.0 && quietNow >= quietAt) return;
        quietAt = quietNow;
        NSString *quietSummary = [self stageGeometryDebugSummary];
        if ([quietSummary rangeOfString:@"OffCard=1"].location != NSNotFound) {
            DSCrashLogRemember([NSString stringWithFormat:@"rim off card (%@) %@", why ?: @"?", quietSummary]);
        }
        return;
    }
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
    [self fit696RefreshRestingFrameForSlot:slot];
    if (!state->hasRestingFrame) return;
    // A single card keeps its primary classification wherever it sits. The
    // lift is from that card's real bottom, not from the top half's y=463.
    // 28pt above the keyboard frame, so the suggestion bar is not still on the card.
    CGFloat keysTop = keysY - 28.0;
    CGFloat fitTop = [self fit696KeysTopForSlot:slot keyboardY:keysY];
    if (fitTop > 0.0) keysTop = fitTop;
    CGFloat overlap = [self unliftedCardBottomForSlot:slot] - keysTop;
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
    // 4.5.707 kb707: the controller only uses the lift transform, so the card's
    // frame never left its place and there is no stored frame to put back
    // (a stale one is what moved cards after typing).
    if ([self kb707Gate]) return;   // 4.5.707 kb707: the keyboard controller is the only mover
    DSLiftSlotState *state = DSLiftSlotAt(slot);
    if (!state->hasRestingFrame) return;
    DSStageContainerView *card = [self containerForSlot:slot];
    if (!card || [self cardIsParked:card]) return;
    [self fit696RefreshRestingFrameForSlot:slot];
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

// ---- 4.5.696 fit ----------------------------------------------------------------
// A phone-size (684) card shows the app down to its keyboard line (586 on this
// phone) at the card's bottom, and the keys are drawn at the phone bottom from
// that line. So the lower card rises until its bottom is exactly the keys top:
// no 28 pt gap, and always the same lift (the keyboard frame flapping between
// 586 and 631 no longer changes it). -1 when not a phone-size card.
- (CGFloat)fit696KeysTopForSlot:(NSInteger)slot keyboardY:(CGFloat)keysY {
    if (!DSPS696Enabled(2)) return -1.0;
    DSSceneHost *host = [self sceneHostForSlot:slot];
    if (!host.isHosting || ![host phoneSize696FitGeometry]) return -1.0;
    CGFloat screenH = CGRectGetHeight([self screenBounds]);
    CGFloat pin = [host phoneSize696KeysTop];
    if (!(pin > 300.0) || pin > screenH - 100.0) return -1.0;
    DSPS696MarkTrying(2);
    return (keysY > 1.0) ? MIN(keysY, pin) : pin;
}

// The stored resting frame is taken once and kept. When the card has since
// moved (bottom slot, swap, drag) the restore after typing put it back where
// the old frame said: the lower card jumped to the top slot (Blackout log,
// "restored resting frame slot 0 cardY=5" for a card resting at y=469).
// Refresh it while the card is not lifted.
- (void)fit696RefreshRestingFrameForSlot:(NSInteger)slot {
    if (slot < 0 || slot > 3) return;
    if (!DSPS696Enabled(2) || [DSSceneHost sceneSettingsUpdateDepth] > 0) return;
    DSSceneHost *host = [self sceneHostForSlot:slot];
    if (!host.isHosting || ![host phoneSize696FitGeometry]) return;
    DSLiftSlotState *state = DSLiftSlotAt(slot);
    if (!state->hasRestingFrame) return;
    DSStageContainerView *card = [self containerForSlot:slot];
    if (!card || [self cardIsParked:card] || card.hidden || fabs(card.liftOffset) > 0.5) return;
    CGFloat screenH = CGRectGetHeight([self screenBounds]);
    CGRect live = [self restingScreenFrameForSlot:slot];
    CGFloat y = [self cardYForSlot:slot];
    if (CGRectGetHeight(live) < 80.0 || y < -0.5 || (screenH > 100.0 && CGRectGetMaxY(live) > screenH + 2.0)) return;
    if (fabs(y - state->baseCardY) <= 8.0 && fabs(CGRectGetMaxY(live) - state->baseRestMaxY) <= 8.0) return;
    DSPS696MarkTrying(2);
    DSDiagnosticsRecordFormat(@"SpringBoard: phonesize696 fit: slot %ld stored resting frame y=%.0f bottom=%.0f was stale; the card rests at y=%.0f bottom=%.0f now",
                              (long)slot, state->baseCardY, state->baseRestMaxY, y, CGRectGetMaxY(live));
    state->baseCardY = y;
    state->baseCardH = CGRectGetHeight(live);
    state->baseRestMaxY = CGRectGetMaxY(live);
}

// ---- 4.5.696 blackout watchdog -----------------------------------------------
// 4.5.701 battery701: this tick ran every 1.5 s for SpringBoard's whole life.
// While the phone is locked, or with no app on the stage at all (nothing
// hosted, parked or stashed), it runs every 6 s; an unlock runs one at once
// (lock-state notification) so the 696/699 unlock checks are not delayed.
// With a card staged or minimised and the phone unlocked it stays 1.5 s.
- (NSTimeInterval)battery701TickDelay {
    if (!DSBattery701On()) return 1.5;
    BOOL locked = DSPS696DeviceLocked() || DSBattery701ScreenLocked();
    BOOL idle = !DSStageHasSceneHostFast() && !_primaryParked && !_secondParked && _state == DSStageStateClosed;
    if (!locked && !idle) return 1.5;
    // 4.5.706 perf706: nothing the tick checks can happen while the screen is
    // locked (the unlock listener ticks at once), and with nothing on the stage
    // an opening stage kicks the tick (perf706KickTick). 30 s locked, 15 s idle.
    if (DSFeature699On("perf706")) {
        if (!_perf706Marked) {
            _perf706Marked = YES;
            DSFeature699MarkTrying("perf706");
        }
        DSPerfCount(DSPerfCounterSlowTicks);
        return locked ? 30.0 : 15.0;
    }
    if (!_battery701Marked) {
        _battery701Marked = YES;
        DSFeature699MarkTrying("battery701");
        DSDiagnosticsRecordFormat(@"SpringBoard: battery701 stage tick slowed to 6 s (%@)", locked ? @"locked" : @"nothing on the stage");
    }
    return 6.0;
}

- (void)battery701ListenForUnlock {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        int token = NOTIFY_TOKEN_INVALID;
        __weak __typeof(self) weakSelf = self;
        notify_register_dispatch("com.apple.springboard.lockstate", &token, dispatch_get_main_queue(), ^(int t) {
            (void)t;
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            // 4.5.719 bg719: an unlock allows one re-take per hosted app (1.2 s
            // later: the lock screen can still report locked for a moment).
            if (strongSelf) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                __strong __typeof(weakSelf) manager = weakSelf;
                if (!manager || DSBattery701ScreenLocked() || DSPS696DeviceLocked()) return;
                @try {
                    DSSceneHost *bgHosts[5] = { manager->_sceneHost, manager->_topSceneHost, manager->_floatSceneHost,
                                                manager->_stashedHost, manager->_stashedHost2 };
                    for (int i = 0; i < 5; i++) {
                        if (!bgHosts[i].isHosting) continue;
                        [bgHosts[i] bg719AllowRetake];
                        [bgHosts[i] bg719Request:@"unlock"];
                    }
                } @catch (NSException *exception) {
                }
            });
            if (!strongSelf || !DSBattery701On()) return;
            if (DSBattery701ScreenLocked()) return;
            [strongSelf perf706KickTick];
            // Unlocked: ticks now instead of up to 6 s later (the lock screen
            // may still report locked for a moment, so twice).
            for (NSNumber *after in @[ @0.3, @1.2 ]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(after.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    @try {
                        [weakSelf blackout696Tick];
                    } @catch (NSException *exception) {
                    }
                });
            }
        });
    });
}

// 4.5.706 perf706: a stage that comes into use while the tick sleeps 15 / 30 s
// gets its checks within 0.3 s (one chain: the sleeping one is dropped).
- (void)perf706KickTick {
    if (_perf706LastDelay < 6.0) return;
    _perf706TickGen += 1;
    [self blackout696ScheduleTickAfter:0.3];
}

- (void)blackout696ScheduleTick {
    [self blackout696ScheduleTickAfter:-1.0];
}

- (void)blackout696ScheduleTickAfter:(NSTimeInterval)forced {
    __weak __typeof(self) weakSelf = self;
    [self battery701ListenForUnlock];
    DSLock808Install();   // 4.5.808 (once; main thread)
    NSTimeInterval delay = forced >= 0.0 ? forced : [self battery701TickDelay];
    _perf706LastDelay = delay;
    NSUInteger tickGen = _perf706TickGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (tickGen != strongSelf->_perf706TickGen) return;   // 4.5.706: a kicked chain replaced this one
        @try {
            static int perfTicks = 0;
            DSPerfCount(DSPerfCounterTicks);
            static dispatch_once_t gaugeOnce;
            dispatch_once(&gaugeOnce, ^{
                DSPerfSetGaugeProvider(DSPerf705Gauge);
            });
            if (DSPerfLogOn()) {
                if (++perfTicks >= 2) {
                    perfTicks = 0;
                    NSString *summary = DSPerfSummaryAndReset();
                    if (summary) DSDiagnosticsRecord([@"SpringBoard: " stringByAppendingString:summary]);
                }
            } else {
                perfTicks = 0;
            }
            // 4.5.702 drag702: never leave a card held after a drag that ended unseen.
            if (!strongSelf->_stageDragActive && (strongSelf->_drag702Card || strongSelf->_container.drag702Frozen ||
                                                  strongSelf->_topContainer.drag702Frozen || strongSelf->_floatContainer.drag702Frozen)) {
                [strongSelf drag702End];
            }
            [strongSelf blackout696Tick];
        } @catch (NSException *exception) {
            DSDiagnosticsRecordFormat(@"SpringBoard: phonesize696 blackout watchdog caught %@", exception.reason ?: exception.name);
        }
        // 4.5.704 focus704: a typing focus whose keyboard went away unseen.
        // 4.5.707 kb707: the same for the keyboard controller (a keyboard
        // that ended unseen, or a lift a layout pass took back).
        if (strongSelf->_kb707Active) {
            @try {
                [strongSelf focus704Evaluate:@"tick"];
            } @catch (NSException *exception) {
                DSDiagnosticsRecordFormat(@"SpringBoard: focus704 caught %@", exception.reason ?: exception.name);
            }
        }
        @try {
            [strongSelf heal700Tick];
        } @catch (NSException *exception) {
            DSDiagnosticsRecordFormat(@"SpringBoard: heal700 caught %@", exception.reason ?: exception.name);
        }
        @try {   // 4.5.733: only notes start times for black731 (no action here)
            if (strongSelf->_sceneHost.isHosting) [strongSelf black733HostSettled:strongSelf->_sceneHost];
            if (strongSelf->_topSceneHost.isHosting) [strongSelf black733HostSettled:strongSelf->_topSceneHost];
            if (strongSelf->_floatSceneHost.isHosting) [strongSelf black733HostSettled:strongSelf->_floatSceneHost];
        } @catch (NSException *exception) {
        }
        @try {
            [strongSelf host750Tick];   // 4.5.750 host750
        } @catch (NSException *exception) {
            DSDiagnosticsRecordFormat(@"SpringBoard: host750 caught %@", exception.reason ?: exception.name);
        }
        @try {
            [strongSelf stuck727Check:NO];
        } @catch (NSException *exception) {
            DSDiagnosticsRecordFormat(@"SpringBoard: stuck727 caught %@", exception.reason ?: exception.name);
        }
        @try {
            [strongSelf restore726Check];
        } @catch (NSException *exception) {
            DSDiagnosticsRecordFormat(@"SpringBoard: restore726 caught %@", exception.reason ?: exception.name);
        }
        @try {
            [strongSelf drag706Check:@"tick"];
        } @catch (NSException *exception) {
            DSDiagnosticsRecordFormat(@"SpringBoard: drag706 caught %@", exception.reason ?: exception.name);
        }
        // 4.5.714 msgdiag714: read-only Messages card geometry line.
        if (strongSelf->_state == DSStageStateOverlay) {
            @try {
                [strongSelf msgdiag714Tick];
            } @catch (NSException *exception) {
                DSDiagnosticsRecordFormat(@"SpringBoard: msgdiag714 caught %@", exception.reason ?: exception.name);
            }
        }
        [strongSelf blackout696ScheduleTick];
    });
}

// ---- 4.5.714 msgdiag714 ---------------------------------------------------------
// Read-only. While a stage is open and Messages is on a card, one diagnostics
// line (on change, else once a minute) with the card frame / lift / side, the
// hosted view's frame and transform inside the card, the scene settings (frame,
// safe area) and the app picture's frame inside the card. Nothing is written to
// any view, layer or scene. Off: /var/mobile/.dynamicstage-msgdiag714-off
// (crash latch msgdiag714-trying/-crashed).
- (void)msgdiag714Tick {
    if (_state != DSStageStateOverlay) return;
    DSSceneHost *found = nil;
    NSInteger foundSlot = -1;
    for (NSInteger slot = 0; slot <= 1; slot++) {
        DSSceneHost *host = [self sceneHostForSlot:slot];
        if ([host.bundleIdentifier isEqualToString:@"com.apple.MobileSMS"]) {
            found = host;
            foundSlot = slot;
            break;
        }
    }
    if (!found) return;
    if (!DSFeature699On("msgdiag714")) return;
    static BOOL marked = NO;
    if (!marked) {
        marked = YES;
        DSFeature699MarkTrying("msgdiag714");
    }
    DSStageContainerView *card = [self containerForSlot:foundSlot];
    UIView *hostView = found.hostView;
    CGRect cardFrame = card ? card.frame : CGRectZero;
    CGRect hostInCard = CGRectZero;
    if (hostView && card && hostView.window && hostView.window == card.window) {
        hostInCard = [hostView convertRect:hostView.bounds toView:card];
    }
    CGAffineTransform t = hostView ? hostView.transform : CGAffineTransformIdentity;
    NSString *line = [NSString stringWithFormat:
                      @"slot=%ld card=%@ bounds=%@ lift=%.0f side=%.0f clips=%d host=%@ hostInCard=%@ hostT={%.2f,%.2f,%.0f,%.0f} hostHidden=%d %@ %@",
                      (long)foundSlot, NSStringFromCGRect(cardFrame), NSStringFromCGRect(card ? card.bounds : CGRectZero),
                      card ? card.liftOffset : 0.0, card ? card.sideOffset : 0.0, card ? (int)card.clipsToBounds : -1,
                      NSStringFromCGRect(hostView ? hostView.frame : CGRectZero), NSStringFromCGRect(hostInCard),
                      t.a, t.d, t.tx, t.ty, hostView ? (int)hostView.hidden : -1,
                      [found keys672SceneSummary] ?: @"scene=?", [found growingContentDebugLine] ?: @"?"];
    if (!DSLogGate(@"msgdiag714", line, 60.0, NULL)) return;
    DSDiagnosticsRecordFormat(@"SpringBoard: msgdiag714 Messages geometry %@", line);
}

// ---- 4.5.700 heal700 ------------------------------------------------------------
// A hosted card that is not parked (so no corner icon and no corner pull) but
// sits off the screen / in its corner park spot, or the stage marked
// Minimized under such a card, is the stuck state of the Bugs-spam log.
// Seen on two ticks in a row (~1.5-3 s, nothing moving): end it the way the
// user last asked - last request a minimise: park it properly (icon + pull
// work again); otherwise: bring it back on screen. Off:
// /var/mobile/.dynamicstage-heal700-off (crash latch heal700-trying/-crashed).
- (BOOL)spam700OtherCardOnScreen:(DSStageContainerView *)card {
    DSStageContainerView *other = (card == _container) ? _topContainer : _container;
    if (!other || other.hidden || other.alpha < 0.05 || [self cardIsParked:other]) return NO;
    return [self sceneHostForCard:other].isHosting || other == _container;
}

- (NSString *)heal700ProblemForCard:(DSStageContainerView *)card {
    if (!card) return nil;
    DSSceneHost *host = [self sceneHostForCard:card];
    if (!host.isHosting || [self cardIsParked:card]) return nil;
    if (objc_getAssociatedObject(card, &kDSAnim698FlightKey)) return nil;
    if (card.layer.animationKeys.count > 0) return nil;
    if (card == _container && _state == DSStageStateMinimized) {
        return @"stage is Minimized but the card is not parked";
    }
    if (card.hidden) return nil;
    if (_state != DSStageStateOverlay) return nil;
    if (!card.window || card.window.hidden) return nil;
    CGRect frame = [card convertRect:card.bounds toView:nil];
    // 4.5.705 focus705: a card slid aside / lifted for a keyboard is where the
    // keyboard put it on purpose. Measured with that shift it counted as "off
    // the screen" and heal700 re-laid the stage out under the user ~3 s into
    // typing (a jump / flicker). The resting frame is what heal700 is about.
    if ([self focus705On] && (fabs(card.sideOffset) > 0.5 || fabs(card.liftOffset) > 0.5) && card.superview) {
        frame = [card.superview convertRect:[self frameWithoutKeyboardShift:card] toView:nil];
    }
    CGRect screen = [self screenBounds];
    CGRect visible = CGRectIntersection(frame, screen);
    CGFloat area = MAX(CGRectGetWidth(frame) * CGRectGetHeight(frame), 1.0);
    CGFloat shown = CGRectIsNull(visible) ? 0.0 : CGRectGetWidth(visible) * CGRectGetHeight(visible);
    if (CGRectGetWidth(frame) < 80.0 || CGRectGetHeight(frame) < 80.0 || shown < area * 0.25 || card.alpha < 0.05) {
        return [NSString stringWithFormat:@"card not parked but at %@ alpha %.2f (off the screen / park spot)",
                NSStringFromCGRect(frame), card.alpha];
    }
    return nil;
}

- (void)heal700Tick {
    if (DSCall733HandsOff(@"heal700")) return;   // 4.5.734 call733
    if (!_activated || !DSFeature699On("heal700")) {
        _heal700Ticks = 0;
        return;
    }
    if (DSPS696DeviceLocked() || _state == DSStageStateTracking || _stageDragActive || _systemPull || _overlaySettling ||
        _splitMode || _floatActive || _searchSlot >= 0 || _spam700MinimisePending || _spam700DeferredFinish ||
        DSCallStepAsideActive() || [DSSceneHost homeGestureIsActive] || [DSSceneHost systemTransitionBusy] ||
        [DSSceneHost systemEdgePullIsActive] || [DSSceneHost sceneSettingsUpdateDepth] > 0 || DSStageDragSettlingFast(1.0)) {
        _heal700Ticks = 0;
        return;
    }
    DSStageContainerView *bad = nil;
    NSString *why = [self heal700ProblemForCard:_container];
    if (why) bad = _container;
    if (!bad && _stackSlotCount >= kDSMaxStackSlots && _topContainer) {
        why = [self heal700ProblemForCard:_topContainer];
        if (why) bad = _topContainer;
    }
    // 4.5.754 heal754: a card kb707 slid aside for the keyboard (its side
    // offset) is where kb707 put it, not lost; this held even with kb720
    // latched off (753 log: two false HEAL700 lines while typing in Messages).
    // Off: heal754-off / core754-off (crash latch heal754).
    if (bad && fabs(bad.sideOffset) > 0.5 && DSFeature699On("core754") && DSFeature699On("heal754")) {
        DSFeature719MarkAction("heal754");
        _heal700Ticks = 0;
        _heal700Card = nil;
        return;
    }
    if (bad && [self kb720Typing]) {
        // 4.5.720: kb707 owns the cards while typing; heal waits until it ends.
        [self kb720Act:@"heal700 waits: kb707 holds a typing session"];
        _heal700Ticks = 0;
        _heal700Card = nil;
        return;
    }
    if (!bad || (_heal700Card && _heal700Card != bad)) {
        _heal700Ticks = 0;
        _heal700Card = bad;
        return;
    }
    _heal700Card = bad;
    if (++_heal700Ticks < 2) return;
    _heal700Ticks = 0;
    _heal700Card = nil;
    // 4.5.751 pos751: heal700 is a logging backstop; stuck727's 2 s safety snap
    // still puts a card back if it stays wrong.
    if (DSFeature699On("core751") && DSFeature699On("pos751")) {
        DSDiagnosticsRecordFormat(@"SpringBoard: HEAL700 BACKSTOP (log only) %@ card: %@",
                                  bad == _container ? @"bottom" : @"top", why ?: @"?");
        return;
    }
    DSFeature699MarkTrying("heal700");
    DSPerfCount(DSPerfCounterHealRelayouts);
    NSString *bundle = [self sceneHostForCard:bad].bundleIdentifier ?: @"?";
    BOOL otherOnScreen = [self spam700OtherCardOnScreen:bad];
    if (_spam700Intent == 1) {
        DSDiagnosticsRecordFormat(@"SpringBoard: heal700 %@: %@; last request was a minimise (#%lu): parked properly in its corner",
                                  bundle, why, (unsigned long)_spam700Gen);
        if (![self rememberedPictureForCard:bad]) [self rememberPictureForCard:bad];
        [self setParked:YES forCard:bad];
        if (bad == _container && !otherOnScreen) {
            [self minimizeCard:bad toCornerAnimated:NO];
        } else {
            [UIView performWithoutAnimation:^{
                [self layoutAllStackSlotsForState:otherOnScreen ? DSStageStateOverlay : DSStageStateMinimized];
                [self placeCard:bad atFrame:[self cornerParkFrameForCard:bad]];
            }];
            [self hideParkedCardsCompletely];
            [self updateOpenAppIcon];
            [self updateHomeAffordance];
        }
        return;
    }
    DSDiagnosticsRecordFormat(@"SpringBoard: heal700 %@: %@; last request was %@ (#%lu): put back on the stage",
                              bundle, why, _spam700Intent == 2 ? @"a restore / open" : @"none", (unsigned long)_spam700Gen);
    DSStageContainerView *card = bad;
    if (_state != DSStageStateOverlay) {
        DSStageContainerView *other = (bad == _container) ? _topContainer : _container;
        DSStageContainerView *keep = (other && [self cardIsParked:other]) ? other : nil;
        [self enterStateOverlayAnimated:YES keepingParkedCard:keep];
        __weak __typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf finishCornerRestoreOfCard:card];
        });
        return;
    }
    [self animateSpring:^{
        [self layoutAllStackSlotsForState:DSStageStateOverlay];
        [self hideParkedCardsCompletely];
    } completion:^{
        [self finishCornerRestoreOfCard:card];
    }];
}

- (void)blackout696Tick {
    if (!DSPS696Enabled(0)) return;
    static BOOL wasLocked = NO;
    if (DSPS696DeviceLocked()) {
        wasLocked = YES;
        return;
    }
    if (wasLocked) {
        wasLocked = NO;
        if (_state == DSStageStateOverlay) {
            DSDiagnosticsRecord(@"SpringBoard: phonesize696 blackout: phone unlocked, the stage cards are checked for a black card");
            // 4.5.699 blackout699: check the visible cards now, not after 3 s.
            for (NSInteger slot = 0; slot <= 2; slot++) {
                DSStageContainerView *card = [self containerForSlot:slot];
                if (card && ![self cardIsParked:card]) [self blackout699WakeSoon:card why:@"phone unlocked" attempt:0];
            }
        }
        return;
    }
    if (_state != DSStageStateOverlay || _stageDragActive || _searchSlot >= 0) return;
    if ([DSSceneHost homeGestureIsActive] || [DSSceneHost systemTransitionBusy] || [DSSceneHost sceneSettingsUpdateDepth] > 0) return;
    if (DSStageDragSettlingFast(1.5) || DSCameraLayoutChangedRecently(1.5)) return;
    for (NSInteger slot = 0; slot <= 2; slot++) {
        DSSceneHost *host = [self sceneHostForSlot:slot];
        DSStageContainerView *card = [self containerForSlot:slot];
        if (!host.isHosting || !card || [self cardIsParked:card] || card.hidden || card.alpha < 0.01 || !card.window) continue;
        if ([host.bundleIdentifier isEqualToString:@"com.apple.MobileSMS"]) continue;
        UIView *view = host.hostView;
        if (view && card.contentView && view.superview != card.contentView &&
            (view.superview == nil || (_stashHolder && view.superview == _stashHolder))) {
            [self returnHostView:host toCard:card];
            [host fitHostViewToCard];
            DSPS696MarkTrying(0);
            DSDiagnosticsRecordFormat(@"SpringBoard: phonesize696 blackout: %@ (slot %ld) app view was %@ while its card was on the stage: put back on the card",
                                      host.bundleIdentifier ?: @"?", (long)slot, view.superview ? @"in the hidden holder" : @"detached");
            continue;
        }
        NSString *did = [host blackout696Tick];
        if (did) {
            DSDiagnosticsRecordFormat(@"SpringBoard: phonesize696 blackout: %@ (slot %ld): %@", host.bundleIdentifier ?: @"?", (long)slot, did);
        }
    }
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
    DSStageContainerView *card = [self containerForSlot:slot];
    if (!card || [self cardIsParked:card] || card.hidden) return 0.0;
    if (slot == 2 || card == _floatContainer) {
        return [self splitKeyboardClearLiftForCard:card keyboard:keyboard];
    }
    if (_stackSlotCount >= kDSMaxStackSlots && ![self slotIsBottomOfTwoStages:slot]) return 0.0;
    [self captureKeyboardBaseForSlot:slot];
    [self fit696RefreshRestingFrameForSlot:slot];
    CGFloat keyboardTop = CGRectGetMinY(keyboard) - 28.0;
    // 4.5.696 fit: a phone-size card's bar line goes right onto its keys.
    CGFloat fitTop = [self fit696KeysTopForSlot:slot keyboardY:CGRectGetMinY(keyboard)];
    if (fitTop > 0.0) keyboardTop = fitTop;
    CGFloat overlap = [self unliftedCardBottomForSlot:slot] - keyboardTop;
    if (overlap < 1.0) return 0.0;
    CGFloat liveY = [self cardYForSlot:slot];
    if (_stackSlotCount < kDSMaxStackSlots && [self keys671CardAppAvoidsKeysItself:card]) {
        // 4.5.671 keys671: past the top half's resting bottom, not just past
        // the keys, so the app sees its card where it would rest up there.
        CGFloat topRestBottom = CGRectGetMaxY([self fixedHalfFrame:1]);
        CGFloat bottom = [self unliftedCardBottomForSlot:slot];
        CGFloat toTop = bottom - topRestBottom;
        NSString *bundle = [self sceneHostForSlot:slot].bundleIdentifier ?: @"?";
        if (topRestBottom <= keyboardTop + 0.5 && toTop > overlap) {
            DSKeys671Note([@"lift." stringByAppendingString:bundle],
                          [NSString stringWithFormat:@"%@ has no DynamicStage app dylib (it slides its own composer): bottom card lifted by %.0f to the top half (bottom %.0f), not by %.0f onto the keys (keyboard %@)",
                           bundle, toTop, topRestBottom, overlap, NSStringFromCGRect(keyboard)]);
            overlap = toTop;
        }
    }
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

// 4.5.671 keys671. An app without DynamicStage's app dylib (Beeper when it is
// not injected, Messenger / Signal when they are not, and any other app on a
// card) hears its own keyboard notes and slides its composer up by itself.
// The 4.5.670 log (Quickbar.txt + IMG_4444) has Beeper's composer ~82pt up
// inside the card, with an empty band under it, exactly when the stage had
// moved the card down onto the keys (card bottom 558 = keyboard top 586 - 28)
// or up from the bottom half onto them; the app is told nothing new by that
// move except where its card is (the display-layout element follows the card,
// "layout670 card moved {{5,5}} -> {{5,100}}"), and the band equals that card
// bottom minus (screen height - card height): 558 - (932 - 458) = 84. So for
// such an app the stage no longer brings the card down onto the keys: a
// single card on the top half stays where it rests, and a single card on the
// bottom half rises to the top half's resting place instead of stopping on
// the keys. Apps with the dylib (Messages, Phone, injected Messenger / Signal
// / Beeper) swallow those notes inside the app and keep the 4.5.670 moves.
// Picker search, split and the third stage are unchanged.
// 4.5.672: OFF by default. The 4.5.671 test ("that made no difference") shows
// the band under Beeper's composer does not depend on where the card is, so
// the card moves are back to 4.5.670. Opt in (testing only):
// /var/mobile/.dynamicstage-keys671-on
static BOOL DSKeys671Disabled(void) {
    static CFAbsoluteTime checkedAt = 0;
    static BOOL disabled = YES;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - checkedAt > 3.0) {
        checkedAt = now;
        disabled = access("/var/mobile/.dynamicstage-keys671-on", F_OK) != 0;
    }
    return disabled;
}

static void DSKeys671Note(NSString *key, NSString *line) {
    static NSMutableDictionary<NSString *, NSString *> *last = nil;
    if (!last) last = [NSMutableDictionary dictionary];
    if (key.length == 0 || line.length == 0) return;
    if ([last[key] isEqualToString:line]) return;
    last[key] = line;
    DSDiagnosticsRecordFormat(@"SpringBoard: keys671 %@", line);
}

- (NSString *)keys671BundleForCard:(DSStageContainerView *)card {
    if (!card) return nil;
    for (NSInteger slot = 0; slot <= 2; slot++) {
        if ([self containerForSlot:slot] != card) continue;
        DSSceneHost *host = [self sceneHostForSlot:slot];
        if (host.isHosting && host.bundleIdentifier.length > 0) return host.bundleIdentifier;
    }
    return nil;
}

// ---- 4.5.675 phonesize675 -------------------------------------------------
// While an allowlisted app with no app dylib (default: Beeper) has the
// keyboard up on a visible card, its scene is the phone's size and the card
// shows it scaled, keyboard top on the card's bottom edge (DSSceneHost). The
// evaluation runs after the note has been taken in (so _keyboardFrame is the
// stage's real keys, never an arbiter height like 644/689), coalesced.
static CGRect DSPS675LastNote;
static CFTimeInterval DSPS675LastDownAt = 0;
static NSString *DSPS675Source = nil;
static NSInteger DSPS675Generation = 0;
static NSInteger DSPS675DownChecks = 0;

- (NSArray<DSSceneHost *> *)phoneSize675Hosts {
    NSMutableArray *hosts = [NSMutableArray array];
    if (_sceneHost) [hosts addObject:_sceneHost];
    if (_topSceneHost && ![hosts containsObject:_topSceneHost]) [hosts addObject:_topSceneHost];
    if (_floatSceneHost && ![hosts containsObject:_floatSceneHost]) [hosts addObject:_floatSceneHost];
    return hosts;
}

- (void)phoneSize675Log:(NSString *)key line:(NSString *)line every:(CFTimeInterval)seconds {
    static NSMutableDictionary<NSString *, NSNumber *> *last = nil;
    static NSMutableDictionary<NSString *, NSString *> *lastLine = nil;
    if (!last) { last = [NSMutableDictionary dictionary]; lastLine = [NSMutableDictionary dictionary]; }
    CFTimeInterval now = CACurrentMediaTime();
    NSNumber *at = last[key];
    if (at && [lastLine[key] isEqualToString:line] && now - at.doubleValue < seconds) return;
    if (last.count > 48) { [last removeAllObjects]; [lastLine removeAllObjects]; }
    last[key] = @(now);
    lastLine[key] = line;
    DSDiagnosticsRecordFormat(@"SpringBoard: %@%@", [line hasPrefix:@"phonesize67"] ? @"" : @"phonesize675 ", line);
}

// ---- 4.5.676 phonesize676: switch on the earliest signal -----------------
// 4.5.675 switched 60 ms after the stage's first keyboard note. The arbiter's
// "on=1" status from the app reaches SpringBoard before that note (Beep.txt:
// arbiter on=1 line 176, UIKit change 177, note 179), so the scene is grown
// right there, with a provisional keyboard top that the first note corrects.
static NSMutableDictionary<NSString *, NSNumber *> *DSPS676LastKeyTop = nil;
static double DSPS676FocusAt = 0;
static double DSPS676EarlyAt = 0;
static BOOL DSPS676FirstNoteLogged = NO;

- (CGFloat)phoneSize676ProvisionalKeyTopFor:(NSString *)bundle height:(CGFloat)height source:(NSString **)source {
    CGFloat screenH = CGRectGetHeight([self screenBounds]);
    NSNumber *last = bundle.length ? DSPS676LastKeyTop[bundle] : nil;
    CGFloat top = 0.0;
    if (last) {
        top = last.doubleValue;
        if (source) *source = @"last keyboard top for this app";
    } else if (height >= 150.0) {
        // The arbiter's height is the app's; SpringBoard's keys are 58 pt
        // taller (243 -> 301, 288 -> 346 in Beep.txt).
        top = screenH - (height + 58.0);
        if (source) *source = [NSString stringWithFormat:@"arbiter height %.0f + 58", height];
    } else {
        top = screenH - 346.0;
        if (source) *source = @"default quick-bar keyboard";
    }
    return MAX(screenH * 0.35, MIN(screenH - 150.0, top));
}

- (void)phoneSize676EarlySignal:(NSString *)signal bundle:(NSString *)bundle height:(CGFloat)height at:(double)mediaTime {
    // 4.5.677: type checks and a catch around the whole switch. The focus
    // signal no longer exists (its hook is gone), so only "arbiter on=1" comes in.
    if (![NSThread isMainThread]) return;
    if (![signal isKindOfClass:NSString.class] || ![bundle isKindOfClass:NSString.class]) return;
    if (!isfinite(height)) height = 0.0;
    @try {
        [self phoneSize676EarlySwitch:signal bundle:bundle height:height at:mediaTime];
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize677 early switch for %@ threw %@; left to the keyboard note",
                                  bundle, exception.reason ?: exception.name ?: @"?");
    }
}

- (void)phoneSize676EarlySwitch:(NSString *)signal bundle:(NSString *)bundle height:(CGFloat)height at:(double)mediaTime {
    if (bundle.length == 0 || [bundle isEqualToString:@"com.apple.springboard"]) return;
    if (!DSPhoneSize675Allowed(bundle)) return;
    DSSceneHost *host = [self visibleHostForBundleIdentifier:bundle];
    if (!host) return;
    if (DSPhoneSize680Enabled() && [host isPhoneSize675]) return; // 4.5.680 moves the window itself
    BOOL focus = [signal isEqualToString:@"focus"];
    // 4.5.678: a pre-grown scene (B/C) only needs its mapping moved to the keys.
    BOOL preGrown = [host isPhoneSize678PreGrown];
    if ([host isPhoneSize675] && !preGrown) return;
    // A keyboard session's clock starts at its first signal: the focus request
    // when one came in the 2 s before, otherwise this arbiter status.
    BOOL recentFocus = DSPS676FocusAt > 0 && mediaTime - DSPS676FocusAt >= 0.0 && mediaTime - DSPS676FocusAt < 2.0;
    if (!preGrown && (focus || !recentFocus)) DSPhoneSize676StartSession(mediaTime);
    if (focus) {
        DSPS676FocusAt = mediaTime;
        DSPS676FirstNoteLogged = NO;
        return; // 4.5.677: no focus signal any more
    } else {
        DSPS676FirstNoteLogged = NO;
    }
    NSString *skip = nil;
    if (DSPhoneSize675Disabled()) skip = @"off file /var/mobile/.dynamicstage-phonesize675-off is present, 4.5.674 behaviour";
    else if ([self keys671AppHasDylib:bundle]) skip = @"the app has the DynamicStage app dylib (it handles the keyboard itself)";
    else if (_searchSlot >= 0) skip = @"the search card is open";
    else if (_stageQuarterTurns != 0) skip = @"the stage is rotated";
    else if ([host isCameraTall]) skip = @"the camera layout is on";
    else if (!focus && height > 0.0 && height < 150.0) skip = [NSString stringWithFormat:@"keyboard height %.0f is not a full keyboard", height];
    if (skip) {
        [self phoneSize675Log:[@"skip-" stringByAppendingString:bundle]
                         line:[NSString stringWithFormat:@"%@ skipped while typing: %@; scene stays card-size", bundle, skip]
                        every:30.0];
        return;
    }
    NSString *topSource = nil;
    CGFloat keyTop = [self phoneSize676ProvisionalKeyTopFor:bundle height:height source:&topSource];
    DSPS676EarlyAt = CACurrentMediaTime();
    DSDiagnosticsRecordFormat(@"SpringBoard: phonesize676 %@ early switch on \"%@\" t+%.0fms (seen t+%.0fms%@): provisional keyboard top y=%.0f (%@)",
                              bundle, signal, DSPhoneSize676Ms(), DSPhoneSize676MsAt(mediaTime),
                              recentFocus && !focus
                                  ? [NSString stringWithFormat:@", focus was t+%.0fms", DSPhoneSize676MsAt(DSPS676FocusAt)] : @"",
                              keyTop, topSource ?: @"?");
    [host setPhoneSize675:YES keyboardTop:keyTop why:[NSString stringWithFormat:@"early: %@", signal]];
    if (![host isPhoneSize675]) return;
    // No keyboard after all (a focus without keys, a hardware keyboard): back.
    NSInteger generation = DSPS675Generation;
    __weak typeof(self) weakSelf = self;
    __weak DSSceneHost *weakHost = host;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        DSSceneHost *h = weakHost;
        if (!strongSelf || !h || ![h isPhoneSize675]) return;
        if (generation != DSPS675Generation) return; // a keyboard note came in; the 675 path owns it now
        if (!CGRectIsEmpty(DSPS675LastNote) || [strongSelf stagedKeyboardIsUp]) return;
        [h setPhoneSize675:NO keyboardTop:0.0 why:[NSString stringWithFormat:@"early \"%@\" signal but no keyboard note within 1.5 s", signal]];
    });
}

- (void)phoneSize675NoteKeyboard:(CGRect)keyboard source:(NSString *)source {
    CGRect screen = [self screenBounds];
    CGFloat screenH = CGRectGetHeight(screen);
    BOOL up = !CGRectIsEmpty(keyboard) && CGRectGetHeight(keyboard) >= 150.0 &&
              CGRectGetMinY(keyboard) < CGRectGetMaxY(screen) - 1.0 &&
              CGRectGetMinY(keyboard) > screenH * 0.35;
    static BOOL statusLogged = NO;
    static BOOL statusOff = NO;
    BOOL off = DSPhoneSize675Disabled();
    if (!statusLogged || off != statusOff) {
        statusLogged = YES;
        statusOff = off;
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize675 build %s is %@; apps: %@",
                                  kDSBuildVersionString,
                                  off ? @"OFF (/var/mobile/.dynamicstage-phonesize675-off present: 4.5.674 behaviour)" : @"ON",
                                  DSPhoneSize675AllowlistSummary());
    }
    DSPS675LastNote = up ? keyboard : CGRectZero;
    if (up && source.length && ![source isEqualToString:@"SpringBoard"]) DSPS675Source = [source copy];
    if (up && !DSPS676FirstNoteLogged && DSPhoneSize675Allowed(source)) {
        DSPS676FirstNoteLogged = YES;
        if (DSPhoneSize676Ms() < 0 || DSPhoneSize676Ms() > 3000.0) DSPhoneSize676StartSession(0);
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize676 %@ first keyboard note t+%.0fms frame %@",
                                  source, DSPhoneSize676Ms(), NSStringFromCGRect(keyboard));
    }
    if (!up && DSPS676FirstNoteLogged && CGRectIsEmpty(keyboard) && ![self stagedKeyboardIsUp]) DSPS676FirstNoteLogged = NO;
    if (!up) {
        DSPS675LastDownAt = CACurrentMediaTime();
        DSPS675DownChecks = 0;
    }
    NSInteger generation = ++DSPS675Generation;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((up ? 0.06 : 0.3) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != DSPS675Generation) return;
        [weakSelf phoneSize675Evaluate:0 generation:generation];
    });
}

- (void)phoneSize675Evaluate:(NSInteger)attempt generation:(NSInteger)generation {
    if (generation != DSPS675Generation) return;
    NSArray<DSSceneHost *> *hosts = [self phoneSize675Hosts];
    BOOL up = !CGRectIsEmpty(DSPS675LastNote);
    __weak typeof(self) weakSelf = self;
    if (!up) {
        BOOL any = NO;
        for (DSSceneHost *host in hosts) if ([host isPhoneSize675]) any = YES;
        if (!any) return;
        // The stage keeps the keys while it ignores a hide (the 631/932
        // flicker of one typing session); its own release is the real end.
        if ([self stagedKeyboardIsUp] && DSPS675DownChecks < 40) {
            DSPS675DownChecks += 1;
            if (DSPS675DownChecks == 1) {
                DSDiagnosticsRecordFormat(@"SpringBoard: phonesize675 keyboard note says down, the stage still has keys %@; staying phone-size until it lets them go",
                                          NSStringFromCGRect(_keyboardFrame));
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf phoneSize675Evaluate:attempt generation:generation];
            });
            return;
        }
        NSString *why = [self stagedKeyboardIsUp] ? @"keyboard down; the stage still held keys after 16 s" : @"keyboard down";
        for (DSSceneHost *host in hosts) {
            if (![host isPhoneSize675]) continue;
            // 4.5.678 C (opt-in): stay phone-size, bottom-anchored.
            if (DSPhoneSize678Always() && [self phoneSize678AlwaysAllowsHost:host]) {
                [host phoneSize678RestWhy:why];
                continue;
            }
            [host setPhoneSize675:NO keyboardTop:0.0 why:why];
        }
        return;
    }
    NSString *bundle = DSPS675Source;
    DSSceneHost *host = [self visibleHostForBundleIdentifier:bundle];
    for (DSSceneHost *other in hosts) {
        if (other != host && [other isPhoneSize675] && DSPhoneSize680Enabled() && [self phoneSize678AlwaysAllowsHost:other]) {
            [other phoneSize678RestWhy:[NSString stringWithFormat:@"keyboard belongs to %@", bundle ?: @"?"]];
            continue;
        }
        if (other != host && [other isPhoneSize675]) {
            [other setPhoneSize675:NO keyboardTop:0.0
                               why:(host || ![other.bundleIdentifier isEqualToString:bundle])
                                       ? [NSString stringWithFormat:@"keyboard now belongs to %@", bundle ?: @"?"]
                                       : @"card not on screen"];
        }
    }
    if (!host) return;
    NSString *skip = nil;
    if (!DSPhoneSize675Allowed(bundle)) skip = [NSString stringWithFormat:@"not allowlisted (apps: %@)", DSPhoneSize675AllowlistSummary()];
    else if (DSPhoneSize675Disabled()) skip = @"off file /var/mobile/.dynamicstage-phonesize675-off is present, 4.5.674 behaviour";
    else if ([self keys671AppHasDylib:bundle]) skip = @"the app has the DynamicStage app dylib (it handles the keyboard itself)";
    else if (_searchSlot >= 0) skip = @"the search card is open";
    else if (_stageQuarterTurns != 0) skip = @"the stage is rotated";
    else if ([host isCameraTall]) skip = @"the camera layout is on";
    if (skip) {
        if ([host isPhoneSize675]) [host setPhoneSize675:NO keyboardTop:0.0 why:skip];
        [self phoneSize675Log:[@"skip-" stringByAppendingString:bundle ?: @"?"]
                         line:[NSString stringWithFormat:@"%@ skipped while typing: %@; scene stays card-size", bundle ?: @"?", skip]
                        every:30.0];
        return;
    }
    CGRect screen = [self screenBounds];
    CGRect keys = _keyboardFrame;
    BOOL stageKeys = !CGRectIsEmpty(keys) && CGRectGetHeight(keys) >= 150.0 &&
                     CGRectGetMinY(keys) < CGRectGetMaxY(screen) - 1.0;
    if (!stageKeys) {
        if (attempt < 8) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf phoneSize675Evaluate:attempt + 1 generation:generation];
            });
            return;
        }
        keys = DSPS675LastNote;
    }
    [self phoneSize675Log:@"keys"
                     line:[NSString stringWithFormat:@"%@ keyboard while typing: note %@, stage keys %@%@ -> keyboard top y=%.0f",
                           bundle, NSStringFromCGRect(DSPS675LastNote), NSStringFromCGRect(_keyboardFrame),
                           stageKeys ? @"" : @" (stage had none, used the note)", CGRectGetMinY(keys)]
                    every:2.0];
    if (stageKeys && bundle.length) {
        if (!DSPS676LastKeyTop) DSPS676LastKeyTop = [NSMutableDictionary dictionary];
        DSPS676LastKeyTop[bundle] = @(CGRectGetMinY(keys));
    }
    [host setPhoneSize675:YES keyboardTop:CGRectGetMinY(keys)
                      why:[host isPhoneSize675] ? [NSString stringWithFormat:@"keyboard note t+%.0fms", DSPhoneSize676Ms()] : @"keyboard up (note)"];
}

// ---- 4.5.678 phonesize678 B: grow on a touch in the composer zone ----------
// The first-tap bug: the app's keyboard comes up (and the app lays out for it)
// while its scene is still the card's 420x458; the scene grows ~5-90 ms later
// and the app keeps that layout until its next text change. A touch near the
// card's bottom edge grows the scene before the keyboard exists, so the app's
// keyboard then shows in the final 430x931 scene.
static NSInteger DSPS678Token = 0;
static BOOL DSPS678TouchActive = NO;
static __weak DSSceneHost *DSPS678TouchHost = nil;
static const CGFloat kDSPS678ComposerZone = 76.0;

- (void)phoneSize678ObserveTouchesOnCard:(DSStageContainerView *)card {
    if (![card isKindOfClass:UIView.class]) return;
    for (UIGestureRecognizer *existing in card.gestureRecognizers) {
        if ([existing isKindOfClass:DSPS678TouchObserver.class]) return;
    }
    DSPS678TouchObserver *observer = [[DSPS678TouchObserver alloc] init];
    __weak __typeof(self) weakSelf = self;
    __weak DSStageContainerView *weakCard = card;
    observer.downHandler = ^BOOL(UITouch *touch, NSUInteger count) {
        return [weakSelf phoneSize678TouchDown:touch card:weakCard count:count];
    };
    observer.endHandler = ^(BOOL moved, BOOL cancelled) {
        [weakSelf phoneSize678TouchEnded:moved cancelled:cancelled];
    };
    [card addGestureRecognizer:observer];
}

- (BOOL)phoneSize678AlwaysAllowsHost:(DSSceneHost *)host {
    NSString *bundle = host.bundleIdentifier;
    if (!host.isHosting || bundle.length == 0) return NO;
    if (!DSPhoneSize675Allowed(bundle) || DSPhoneSize675Disabled()) return NO;
    if ([self keys671AppHasDylib:bundle]) return NO;
    if (_searchSlot >= 0 || _stageQuarterTurns != 0 || [host isCameraTall]) return NO;
    return host == [self visibleHostForBundleIdentifier:bundle];
}

// ---- 4.5.740 launch740 ----------------------------------------------------------
// The staged app was opened from the home screen (icon, notification, Spotlight):
// SpringBoard reports it as the front display. Its card lets go of the scene (no
// kill, the scene stays foreground for SpringBoard) and closes, so the app opens
// normally full screen. Only for a host that has been hosting for 3 s or more (not
// the stage's own open), never during a call or the home gesture. The switcher is
// not touched. Off: /var/mobile/.dynamicstage-launch740-off (per-action latch).
- (void)launch740AppOpenedFullScreen:(NSString *)bundle {
    if (!_activated || bundle.length == 0 || !DSFeature699On("launch740")) return;
    if ([bundle isEqualToString:@"com.apple.MobileSMS"] && DSStage742MessagesStaged()) return;   // 4.5.742 msg742
    if (DSCallStepAsideActive() || DSCallGuardActive() || [DSSceneHost homeGestureIsActive]) return;
    DSStageContainerView *card = nil;
    DSSceneHost *host = nil;
    if (_floatActive && [_floatSceneHost.bundleIdentifier isEqualToString:bundle]) { card = _floatContainer; host = _floatSceneHost; }
    else if ([_topSceneHost.bundleIdentifier isEqualToString:bundle]) { card = _topContainer; host = _topSceneHost; }
    else if ([_sceneHost.bundleIdentifier isEqualToString:bundle]) { card = _container; host = _sceneHost; }
    if (!card || !host || !host.isHosting) return;
    if (![self black733HostSettled:host]) {
        DSDiagnosticsRecordFormat(@"SpringBoard: launch740 %@ became the front app but its card started under 3 s ago; left alone", bundle);
        return;
    }
    DSFeature719MarkAction("launch740");
    DSDiagnosticsRecordFormat(@"SpringBoard: launch740 %@ was opened full screen from SpringBoard: its stage card lets go of the scene and closes", bundle);
    _kb723QuietUntil = CFAbsoluteTimeGetCurrent() + 0.6;
    [self setTerminateHintVisible:NO];
    [card setLiftOffset:0.0];
    if (card == _container || card == _topContainer) {
        if (_splitMode) { _splitMode = NO; _expandedCard = nil; _splitHomeRevealed = NO; }
    }
    [self publishStageStateForBundleIdentifier:bundle frame:CGRectZero active:NO];
    [host relinquishKeepingBackgrounded:NO];
    [self setSceneHost:nil forCard:card];
    if (card == _floatContainer) {
        [self dismissFloatStageAnimated:NO terminate:NO];
    } else {
        DSStageContainerView *other = (card == _container) ? _topContainer : _container;
        DSSceneHost *otherHost = (card == _container) ? _topSceneHost : _sceneHost;
        if (_stackSlotCount >= kDSMaxStackSlots && other && otherHost.isHosting) {
            if (card == _topContainer) [self dropEmptySecondCard];
            else [self promoteSecondCardToPrimary];
        } else {
            [self dismissStageCompletelyAnimated:NO];
        }
    }
    if (_dragShell.hidden) [_dragShell clearOutline];
    [self updateOpenAppIcon];
}

// 4.5.733 crash733: when a host (this object with this app) was first seen hosting.
- (BOOL)black733HostSettled:(DSSceneHost *)host {
    static NSMutableDictionary<NSString *, NSNumber *> *seen;
    if (!seen) seen = [NSMutableDictionary dictionary];
    if (!host.isHosting) return NO;
    NSString *key = [NSString stringWithFormat:@"%p-%@", host, host.bundleIdentifier ?: @"?"];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSNumber *first = seen[key];
    if (!first) {
        if (seen.count > 64) [seen removeAllObjects];
        seen[key] = @(now);
        return NO;
    }
    return now - first.doubleValue >= 3.0;
}

// ---- 4.5.731 black731 ----------------------------------------------------------
// Plop log (4.5.730, split): opening the stage's search slid Beeper's card off to
// the left and put its scene back to card size. When the search closed and the
// card came back, nothing put the scene back to the phone-size picture the card
// is drawn for, so the card showed black until a drag. Now, whenever a visible
// card's allowlisted app is at card size with no keyboard and no search, the same
// "card is showing the app" switch the card gets when it opens runs again.
// Off: /var/mobile/.dynamicstage-black731-off (per-action latch).
// ---- 4.5.766 ev766: log-only evidence for the open bugs ---------------------
// One line of state at the moment a backstop (black731, blackout699, stuck727,
// loop745) fires or spam700 sees overlapping minimise / restore. Nothing here
// changes a card. Off: ev766-off / core766-off (latch ev766).
- (void)ev766Note:(NSString *)tag card:(DSStageContainerView *)card extra:(NSString *)extra {
    if (!DS766On("ev766")) return;
    @try {
        DSFeature719MarkAction("ev766");
        CGRect model = card ? card.frame : CGRectNull;
        CGRect shown = CGRectNull;
        CALayer *p = card.layer.presentationLayer;
        if (p) shown = p.frame;
        NSUInteger animKeys = card.layer.animationKeys.count;
        DSDiagnosticsRecordFormat(@"SpringBoard: ev766 %@ %@ state=%ld kb707=%d owner=%@ kbFrame=%@ arb=%d(%.2fs) lift=%.0f side=%.0f model=%@ shown=%@ anims=%lu mover=%@ drag=%d settle=%d home=%d trans=%d depth=%ld parked=%d spam=%ld/%d%@%@",
                                  tag ?: @"?", [self sceneHostForCard:card].bundleIdentifier ?: (card ? @"picker" : @"-"),
                                  (long)_state, _kb707Active, _kb707Owner == card ? @"this" : (_kb707Owner ? @"other" : @"none"),
                                  NSStringFromCGRect(_keyboardFrame), _ks747ArbOn, _ks747ArbAt > 0.0 ? CFAbsoluteTimeGetCurrent() - _ks747ArbAt : -1.0,
                                  card.liftOffset, card.sideOffset, NSStringFromCGRect(model), NSStringFromCGRect(shown),
                                  (unsigned long)animKeys, (_mv747Animator && _mv747Animator.state == UIViewAnimatingStateActive) ? @"running" : @"idle",
                                  _stageDragActive, DSStageDragSettlingFast(0.6), [DSSceneHost homeGestureIsActive], [DSSceneHost systemTransitionBusy],
                                  (long)[DSSceneHost sceneSettingsUpdateDepth], card ? [self cardIsParked:card] : -1,
                                  (long)_spam700Intent, _spam700MinimisePending,
                                  extra.length ? @" " : @"", extra ?: @"");
    } @catch (NSException *exception) {
    }
}

- (void)black731Check:(NSString *)why {
    if (DSCall733HandsOff(@"black731")) return;   // 4.5.734 call733
    if (!_activated || _state != DSStageStateOverlay || _searchSlot >= 0 || !DSFeature699On("black731")) return;
    if (!DSPhoneSize678Always() || [self stagedKeyboardIsUp] || _stageDragActive || DSStageDragSettlingFast(0.6)) return;
    if ([DSSceneHost homeGestureIsActive] || [DSSceneHost systemTransitionBusy] || [DSSceneHost sceneSettingsUpdateDepth] > 0) return;
    DSSceneHost *hosts[2] = { _sceneHost, _topSceneHost };
    DSStageContainerView *cards[2] = { _container, _topContainer };
    for (int i = 0; i < 2; i++) {
        DSSceneHost *host = hosts[i];
        DSStageContainerView *card = cards[i];
        if (!host.isHosting || !card || card.hidden || card.alpha < 0.05 || [self cardIsParked:card]) continue;
        if (fabs(card.sideOffset) > 0.5 || fabs(card.liftOffset) > 0.5) continue;   // still slid / lifted
        if ([host isPhoneSize675]) continue;
        if (![self phoneSize678AlwaysAllowsHost:host]) continue;
        // 4.5.733 crash733: never on a host that is still starting (Crasher on 732:
        // SIGSEGV while Beeper was being put on slot 0 right after the keyboard
        // slide ended). The host must have been seen hosting for 3 s.
        if (![self black733HostSettled:host]) continue;
        DSFeature719MarkAction("black731");
        DSDiagnosticsRecordFormat(@"SpringBoard: black731 %@ was back on screen at card size (%@): showing the app again at phone size%@",
                                  host.bundleIdentifier ?: @"?", why ?: @"?",
                                  ([self core748On] && DSFeature699On("scene748")) ? @" [scene748 backstop fired: a transition was missed]" : @"");
        [self ev766Note:@"black731" card:card extra:why];
        [self phoneSize678HostReady:host];
    }
}

// C: the card is hosting the app (2.5 s after it opened).
- (void)phoneSize678HostReady:(id)host {
    @try {
        if (![host isKindOfClass:DSSceneHost.class] || !DSPhoneSize678Always()) return;
        if (![self phoneSize678AlwaysAllowsHost:host] || [host isPhoneSize675]) return;
        if ([self stagedKeyboardIsUp]) return; // the keyboard path owns it
        if (DSStageDragSettlingFast(0.6)) {
            if (DSPhoneSize680Enabled()) {
                __weak __typeof(self) weakSelf = self;
                __weak DSSceneHost *weakHost = host;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    DSSceneHost *h = weakHost;
                    if (h) [weakSelf phoneSize678HostReady:h];
                });
            }
            return;
        }
        DSPhoneSize676StartSession(0);
        [host phoneSize678RestWhy:DSPhoneSize680Enabled() ? @"card is showing the app (4.5.680 always full screen)"
                                                          : @"card is hosting the app (/var/mobile/.dynamicstage-phonesize678-always)"];
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize678 always threw %@", exception.reason ?: exception.name ?: @"?");
    }
}

// YES when a pre-grow started for this touch (the observer then follows it).
- (BOOL)phoneSize678TouchDown:(UITouch *)touch card:(DSStageContainerView *)card count:(NSUInteger)count {
    @try {
        [self phoneSize678TouchDownUnguarded:touch card:card count:count];
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize678 touch-down threw %@; nothing changed", exception.reason ?: exception.name ?: @"?");
        DSPS678TouchActive = NO;
    }
    return DSPS678TouchActive;
}

- (void)phoneSize678TouchDownUnguarded:(UITouch *)touch card:(DSStageContainerView *)card count:(NSUInteger)count {
    DSPS678TouchActive = NO;
    if (!touch || ![card isKindOfClass:DSStageContainerView.class] || card.hidden || count != 1) return;
    DSSceneHost *host = [self sceneHostForCard:card];
    if (![host isKindOfClass:DSSceneHost.class] || !host.isHosting) return;
    NSString *bundle = host.bundleIdentifier;
    if (bundle.length == 0 || !DSPhoneSize675Allowed(bundle)) return;
    if (DSPhoneSize680Enabled()) return; // 4.5.680: no pre-grow on a tap; the scene is phone-size all the time
    BOOL always = DSPhoneSize678Always();
    if (DSPhoneSize678PreGrowDisabled() && !always) {
        [self phoneSize675Log:[@"pg-off-" stringByAppendingString:bundle]
                         line:[NSString stringWithFormat:@"phonesize678 %@ pre-grow off (/var/mobile/.dynamicstage-phonesize678-pregrow-off)", bundle]
                        every:60.0];
        return;
    }
    if ([host isPhoneSize675]) return; // already phone-size (keyboard up, or pre-grown)
    UIView *content = card.contentView ?: card;
    CGPoint inCard = [touch locationInView:card];
    CGPoint inContent = [touch locationInView:content];
    CGRect cardBounds = card.bounds;
    CGRect contentBounds = content.bounds;
    CGFloat rim = [self rimGrabBandForCard:card];
    CGRect interior = CGRectInset(cardBounds, rim, rim);
    BOOL bottomZone = inContent.y >= CGRectGetMaxY(contentBounds) - kDSPS678ComposerZone &&
                      inContent.y <= CGRectGetMaxY(contentBounds);
    BOOL corner = inCard.y > CGRectGetMaxY(cardBounds) - 44.0 &&
                  (inCard.x < CGRectGetMinX(cardBounds) + 44.0 || inCard.x > CGRectGetMaxX(cardBounds) - 44.0);
    NSString *skip = nil;
    if (!CGRectContainsPoint(interior, inCard)) skip = @"on the rim (stage drag)";
    else if (corner) skip = @"in a bottom corner (resize)";
    else if (!bottomZone && !always) return; // not the composer zone: nothing to do, nothing logged
    else if (DSPhoneSize675Disabled()) skip = @"phonesize675 off file present";
    else if ([self keys671AppHasDylib:bundle]) skip = @"the app has the DynamicStage app dylib";
    else if (_searchSlot >= 0) skip = @"the search card is open";
    else if (_stageQuarterTurns != 0) skip = @"the stage is rotated";
    else if ([host isCameraTall]) skip = @"the camera layout is on";
    else if ([self cardIsParked:card]) skip = @"card minimized";
    else if (_stageDragActive || DSStageDragSettlingFast(0.6)) skip = @"card drag in progress";
    else if (host != [self visibleHostForBundleIdentifier:bundle]) skip = @"card not on screen";
    else if ([self stagedKeyboardIsUp]) skip = @"keyboard already up (the 675 switch handles it)";
    if (skip) {
        [self phoneSize675Log:[@"pg-skip-" stringByAppendingString:bundle]
                         line:[NSString stringWithFormat:@"phonesize678 %@ touch-down at card y=%.0f of %.0f: no pre-grow, %@",
                               bundle, inContent.y, CGRectGetHeight(contentBounds), skip]
                        every:5.0];
        return;
    }
    DSPhoneSize676StartSession(CACurrentMediaTime());
    // Tap-safe (with the card picture held) only for a tap in the composer
    // zone; anywhere else (always file) the mapping is bottom-anchored at once,
    // so a scroll is never under a held picture.
    BOOL tapSafe = bottomZone && !DSPhoneSize678AnchorAtDown();
    DSDiagnosticsRecordFormat(@"SpringBoard: phonesize678 %@ touch-down t+0ms at card point (%.0f, %.0f) of %@, %@: pre-growing to the phone size before the keyboard",
                              bundle, inContent.x, inContent.y, NSStringFromCGSize(contentBounds.size),
                              bottomZone ? [NSString stringWithFormat:@"in the bottom %.0f pt (composer zone)", kDSPS678ComposerZone]
                                         : @"anywhere (always file)");
    BOOL grown = [host phoneSize678PreGrow:tapSafe
                                       why:[NSString stringWithFormat:@"phonesize678 pre-grow: touch-down at card y=%.0f", inContent.y]];
    if (!grown) return;
    NSInteger token = ++DSPS678Token;
    DSPS678TouchActive = YES;
    DSPS678TouchHost = host;
    // Never seen the finger lift and no keyboard: undo after 4 s.
    __weak __typeof(self) weakSelf = self;
    __weak DSSceneHost *weakHost = host;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf phoneSize678Expire:weakHost token:token why:@"no keyboard within 4 s of the touch-down"];
    });
}

- (void)phoneSize678TouchEnded:(BOOL)moved cancelled:(BOOL)cancelled {
    if (!DSPS678TouchActive) return;
    DSPS678TouchActive = NO;
    DSSceneHost *host = DSPS678TouchHost;
    @try {
        if (![host isPhoneSize678PreGrown]) return; // the keyboard already took over (or it switched off)
        NSString *bundle = host.bundleIdentifier ?: @"?";
        BOOL always = DSPhoneSize678Always();
        if (moved && !always) {
            [host setPhoneSize675:NO keyboardTop:0.0 why:@"phonesize678 pre-grow undone: the touch moved over 12 pt (a drag or scroll, not a tap)"];
            return;
        }
        [host phoneSize678AnchorBottom:moved ? @"touch moved" : (cancelled ? @"touch cancelled" : @"finger lifted")];
        if (always) return;
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize678 %@ finger lifted t+%.0fms: waiting for the keyboard (back to card size if none within 1.5 s)",
                                  bundle, DSPhoneSize676Ms());
        NSInteger token = DSPS678Token;
        __weak __typeof(self) weakSelf = self;
        __weak DSSceneHost *weakHost = host;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf phoneSize678Expire:weakHost token:token why:@"no keyboard within 1.5 s of the finger lifting"];
        });
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize678 touch end threw %@", exception.reason ?: exception.name ?: @"?");
    }
}

- (void)phoneSize678Expire:(DSSceneHost *)host token:(NSInteger)token why:(NSString *)why {
    if (token != DSPS678Token || ![host isPhoneSize678PreGrown]) return;
    if (DSPhoneSize678Always() && [self phoneSize678AlwaysAllowsHost:host]) return;
    if (!CGRectIsEmpty(DSPS675LastNote) || [self stagedKeyboardIsUp]) return;
    if (DSPS678TouchActive && DSPS678TouchHost == host && [why rangeOfString:@"4 s"].location == NSNotFound) return;
    DSPS678TouchActive = NO;
    [host setPhoneSize675:NO keyboardTop:0.0 why:[NSString stringWithFormat:@"phonesize678 pre-grow undone: %@", why ?: @"?"]];
}

// ---- 4.5.683 phonesize683: the app's own keyboard inside the card ------------
static NSString *DSPS683SessionBundle = nil;   // an app's own keyboard is up in its card
static NSHashTable<UIView *> *DSPS683Hidden = nil;
static NSInteger DSPS683SessionToken = 0;

static BOOL DSPS683WindowLooksLikeKeyboard(UIWindow *window) {
    if (![window isKindOfClass:UIWindow.class] || [window isKindOfClass:DSStageWindow.class]) return NO;
    NSString *name = NSStringFromClass(window.class);
    return [name rangeOfString:@"Keyboard"].location != NSNotFound || [name rangeOfString:@"TextEffects"].location != NSNotFound;
}

// SpringBoard's copy of the app's keys: a remote-context host strip at the
// bottom of the phone in one of SpringBoard's keyboard windows.
static BOOL DSPS683IsBottomKeyCopy(UIView *view) {
    if (![view isKindOfClass:UIView.class] || !view.window) return NO;
    if ([NSStringFromClass(view.class) rangeOfString:@"ContextLayerHost"].location == NSNotFound) return NO;
    if (!DSPS683WindowLooksLikeKeyboard(view.window)) return NO;
    CGRect screen = UIScreen.mainScreen.bounds;
    CGRect r = [view convertRect:view.bounds toView:nil];
    CGFloat h = CGRectGetHeight(screen);
    if (CGRectGetWidth(r) < CGRectGetWidth(screen) - 80.0) return NO;
    if (CGRectGetHeight(r) < 150.0 || CGRectGetHeight(r) > h * 0.6) return NO;
    if (CGRectGetMinY(r) < h * 0.3) return NO;
    return YES;
}

BOOL DSPhoneSize683HidesKeyCopies(void) {
    return DSPS683SessionBundle.length > 0 && !DSPhoneSize683KeepHost() && DSPhoneSize683Enabled();
}

static void DSPS683Hide(UIView *view, NSString *why) {
    if (!view || view.hidden) return;
    if (!DSPS683Hidden) DSPS683Hidden = [NSHashTable weakObjectsHashTable];
    [DSPS683Hidden addObject:view];
    view.hidden = YES;
    static CFAbsoluteTime logAt = 0;
    CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
    if (t - logAt > 1.0 || t < logAt) {
        logAt = t;
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize683 %@ hid SpringBoard's bottom-of-phone copy of the keys: %@ %@ in %@ (%@)",
                                  DSPS683SessionBundle ?: @"?", NSStringFromClass(view.class),
                                  NSStringFromCGRect([view convertRect:view.bounds toView:nil]), NSStringFromClass(view.window.class), why ?: @"?");
    }
}

// From the existing _UIContextLayerHostView layout/frame hook.
void DSPhoneSize683ConsiderContextHost(UIView *view) {
    if (!DSPS683SessionBundle) return;
    @try {
        if (!DSPhoneSize683HidesKeyCopies()) return;
        if (DSPS683IsBottomKeyCopy(view)) DSPS683Hide(view, @"layout");
    } @catch (NSException *exception) {
    }
}

static void DSPS683Walk(UIView *view, NSInteger depth, NSMutableArray<NSString *> *census, BOOL hide) {
    if (!view || depth > 9) return;
    if (census && census.count < 40) {
        [census addObject:[NSString stringWithFormat:@"%@%@ %@%@%@", [@"" stringByPaddingToLength:(NSUInteger)depth withString:@"." startingAtIndex:0],
                           NSStringFromClass(view.class), NSStringFromCGRect([view convertRect:view.bounds toView:nil]),
                           view.hidden ? ([DSPS683Hidden containsObject:view] ? @" HIDDEN(683)" : @" HIDDEN") : @"",
                           view.alpha < 0.99 ? [NSString stringWithFormat:@" a=%.2f", view.alpha] : @""]];
    }
    if (hide && DSPS683IsBottomKeyCopy(view)) DSPS683Hide(view, @"sweep");
    NSArray *children = [view.subviews copy];
    for (UIView *child in children) DSPS683Walk(child, depth + 1, census, hide);
}

static void DSPS683Sweep(BOOL hide, NSMutableArray<NSString *> *census) {
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIWindow *w in [UIApplication.sharedApplication.windows copy]) if (w && ![seen containsObject:w]) { [seen addObject:w]; [windows addObject:w]; }
    for (UIScene *scene in [UIApplication.sharedApplication.connectedScenes.allObjects copy]) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in [((UIWindowScene *)scene).windows copy]) if (w && ![seen containsObject:w]) { [seen addObject:w]; [windows addObject:w]; }
    }
    for (UIWindow *window in windows) {
        if (!DSPS683WindowLooksLikeKeyboard(window)) continue;
        if (census && census.count < 40) {
            [census addObject:[NSString stringWithFormat:@"WINDOW %@ lvl=%.0f hid=%d a=%.2f frame=%@", NSStringFromClass(window.class),
                               window.windowLevel, window.hidden, window.alpha, NSStringFromCGRect(window.frame)]];
        }
        DSPS683Walk(window, 1, census, hide);
    }
}

void DSPhoneSize683RestoreKeyCopies(NSString *why) {
    NSArray<UIView *> *views = DSPS683Hidden ? [DSPS683Hidden allObjects] : @[];
    [DSPS683Hidden removeAllObjects];
    NSInteger n = 0;
    for (UIView *view in views) {
        @try {
            if (view.hidden) { view.hidden = NO; n += 1; }
        } @catch (NSException *exception) {
        }
    }
    if (n > 0 || why.length) {
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize683 SpringBoard's key copies shown again (%ld view%@): %@", (long)n, n == 1 ? @"" : @"s", why ?: @"?");
    }
}

// ---- 4.5.680 phonesize680: keyboard signals -> the card's window ------------
static double DSPS680AskAt = 0;
static NSString *DSPS680AskBundle = nil;
static double DSPS680Duration = 0.0;     // last keyboard animation SpringBoard saw (its own notifications)
static NSInteger DSPS680Curve = -1;
static NSMutableDictionary<NSString *, NSNumber *> *DSPS680LastHeight = nil;
static BOOL DSPS680Up = NO;
static NSString *DSPS680UpBundle = nil;
// 4.5.682: instant show at keys674's layer question.
static double DSPS680HideAt = 0;          // last on=0 for an allowlisted app (media time)
static double DSPS682AskMovedAt = 0;      // keys674 ask that moved the window (0 = none pending)
static NSString *DSPS682AskMovedBundle = nil;
static NSInteger DSPS682AskToken = 0;
static double DSPS682FalseAt[2] = {0, 0}; // the last two asks without a keyboard
static double DSPS682AskPausedUntil = 0;

- (BOOL)phoneSize683ActiveForBundle:(NSString *)bundle {
    @try {
        if (![bundle isKindOfClass:NSString.class] || bundle.length == 0 || !DSPhoneSize683Enabled()) return NO;
        if (!DSPhoneSize675Allowed(bundle)) return NO;
        DSSceneHost *host = [self visibleHostForBundleIdentifier:bundle];
        return host && [host isPhoneSize683];
    } @catch (NSException *exception) {
        return NO;
    }
}

// 4.5.684: safe area = keyboard; the card's window is fixed.
- (BOOL)phoneSize684ActiveForBundle:(NSString *)bundle {
    @try {
        if (![bundle isKindOfClass:NSString.class] || bundle.length == 0 || !DSPhoneSize684Enabled()) return NO;
        if (!DSPhoneSize675Allowed(bundle)) return NO;
        DSSceneHost *host = [self visibleHostForBundleIdentifier:bundle];
        return host && [host isPhoneSize684];
    } @catch (NSException *exception) {
        return NO;
    }
}

- (void)phoneSize683EndSession:(NSString *)why {
    if (!DSPS683SessionBundle) return;
    NSString *bundle = DSPS683SessionBundle;
    DSPS683SessionBundle = nil;
    DSPS683SessionToken += 1;
    DSPhoneSize683RestoreKeyCopies([NSString stringWithFormat:@"%@ keyboard session ended (%@)", bundle, why ?: @"?"]);
}

// Arbiter on=1 / on=0 for an app in 683 mode (main queue).
- (void)phoneSize683KeyboardFrom:(NSString *)bundle on:(BOOL)on height:(CGFloat)height at:(double)mediaTime {
    DSSceneHost *host = [self visibleHostForBundleIdentifier:bundle];
    if (on) {
        BOOL fresh = ![DSPS683SessionBundle isEqualToString:bundle];
        if (fresh) {
            [self phoneSize683EndSession:@"another keyboard"];
            DSPS683SessionBundle = [bundle copy];
        }
        NSInteger token = ++DSPS683SessionToken;
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize683 %@ keyboard %@ (arbiter on=1 height %.0f at %.3f): the app's own keyboard shows inside the card; the stage does not lift, drop or move anything; %@",
                                  bundle, fresh ? @"up" : @"changed", height, mediaTime,
                                  DSPhoneSize683KeepHost() ? @"SpringBoard's bottom-of-phone copy is KEPT (/var/mobile/.dynamicstage-phonesize683-keephost)"
                                                           : @"SpringBoard's bottom-of-phone copy is hidden");
        // Sweeps: UIKit lays the keyboard host out over the next frames.
        NSArray<NSNumber *> *delays = @[@0.0, @0.05, @0.15, @0.4, @1.0];
        for (NSNumber *delay in delays) {
            BOOL census = fresh && fabs(delay.doubleValue - 0.4) < 0.01;
            __weak __typeof(self) weakSelf = self;
            __weak DSSceneHost *weakHost = host;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (token != DSPS683SessionToken || !weakSelf) return;
                @try {
                    NSMutableArray<NSString *> *lines = census ? [NSMutableArray array] : nil;
                    DSPS683Sweep(DSPhoneSize683HidesKeyCopies(), lines);
                    if (census) {
                        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize683 %@ census +400ms SpringBoard keyboard windows: %@", bundle,
                                                  lines.count ? [lines componentsJoinedByString:@" | "] : @"(none)");
                        DSSceneHost *h = weakHost;
                        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize683 %@ census +400ms card host (the app's keyboard layer should be in here): %@", bundle,
                                                  h ? [h phoneSize683HostCensus] : @"(no host)");
                    }
                } @catch (NSException *exception) {
                    DSDiagnosticsRecordFormat(@"SpringBoard: phonesize683 sweep threw %@", exception.reason ?: exception.name ?: @"?");
                }
            });
        }
    } else {
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize683 %@ keyboard down (arbiter on=0 at %.3f): the app animates its own keyboard away inside the card; nothing moves on the stage", bundle, mediaTime);
        // Show the copies again only once the app's own hide animation is done.
        NSInteger token = DSPS683SessionToken;
        __weak __typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (token != DSPS683SessionToken) return;
            [weakSelf phoneSize683EndSession:@"arbiter on=0"];
        });
    }
}

- (void)phoneSize680NoteKeyboardAnimation:(NSDictionary *)info {
    @try {
        if (![info isKindOfClass:NSDictionary.class]) return;
        id d = info[UIKeyboardAnimationDurationUserInfoKey];
        id c = info[UIKeyboardAnimationCurveUserInfoKey];
        double duration = [d respondsToSelector:@selector(doubleValue)] ? [d doubleValue] : 0.0;
        NSInteger curve = [c respondsToSelector:@selector(integerValue)] ? [c integerValue] : -1;
        if (isfinite(duration) && duration >= 0.05 && duration <= 1.0) DSPS680Duration = duration;
        if (curve >= 0 && curve <= 7) DSPS680Curve = curve;
    } @catch (NSException *exception) {
    }
}

// keys674's -_canShowKeyboardLayer answer for an app card: the earliest sign
// of its keyboard. Not a trigger (UIKit also asks during layout); its time is
// where the following arbiter on=1 move is started from.
// ---- 4.5.728 kbshow728 ---------------------------------------------------------
// A staged, visible, foreground card's app asked for its keyboard (the arbiter
// says on, or keys674's layer ask), but 0.5 s later no keys are on screen:
// reveal SpringBoard's keyboard windows and raise them above the stage, the same
// path that shows the keys every time it works ("raise keyboard"). Up to 3 tries.
// Off: /var/mobile/.dynamicstage-kbshow728-off (per-action latch).
- (DSStageContainerView *)kbshow728VisibleCardFor:(NSString *)bundle {
    if (bundle.length == 0 || _state != DSStageStateOverlay) return nil;
    DSStageContainerView *cards[2] = { _container, _topContainer };
    for (int i = 0; i < 2; i++) {
        DSStageContainerView *card = cards[i];
        if (!card || card.hidden || card.alpha < 0.05 || !card.window || [self cardIsParked:card]) continue;
        DSSceneHost *host = [self sceneHostForCard:card];
        if (host.isHosting && [host.bundleIdentifier isEqualToString:bundle]) return card;
    }
    return nil;
}

- (void)kbshow728Arbiter:(BOOL)onScreen source:(NSString *)source {
    if (!DSFeature699On("kbshow728")) return;
    if (![source isKindOfClass:NSString.class]) return;
    if (!onScreen) {
        if ([_kbshow728Bundle isEqualToString:source]) {
            _kbshow728Bundle = nil;
            _kbshow728Gen += 1;
        }
        return;
    }
    if (![self kbshow728VisibleCardFor:source]) return;
    if ([_kbshow728Bundle isEqualToString:source] && CFAbsoluteTimeGetCurrent() - _kbshow728At < 3.0) return;
    _kbshow728Bundle = [source copy];
    _kbshow728At = CFAbsoluteTimeGetCurrent();
    _kbshow728Tries = 0;
    NSUInteger gen = ++_kbshow728Gen;
    [self kbshow728CheckLater:gen];
}

- (void)kbshow728CheckLater:(NSUInteger)gen {
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || gen != strongSelf->_kbshow728Gen) return;
        @try {
            [strongSelf kbshow728Check:gen];
        } @catch (NSException *exception) {
            DSDiagnosticsRecordFormat(@"SpringBoard: kbshow728 caught %@", exception.reason ?: exception.name);
        }
    });
}

- (void)kbshow728Check:(NSUInteger)gen {
    NSString *bundle = _kbshow728Bundle;
    if (!bundle || !DSFeature699On("kbshow728")) return;
    if (![self kbshow728VisibleCardFor:bundle]) return;   // minimised / closed since: nothing to show
    CGRect keys = DSVisibleKeyboardFrameOnScreen();
    CGFloat screenH = CGRectGetHeight([self screenBounds]);
    BOOL shown = !CGRectIsNull(keys) && !CGRectIsEmpty(keys) && CGRectGetHeight(keys) >= 60.0 && CGRectGetMinY(keys) < screenH - 1.0;
    if (shown) {
        if (_kbshow728Tries > 0) {
            DSDiagnosticsRecordFormat(@"SpringBoard: kbshow728 %@ keys on screen after %ld recovery tries %@", bundle, (long)_kbshow728Tries, NSStringFromCGRect(keys));
        }
        return;
    }
    if ([DSSceneHost sceneSettingsUpdateDepth] > 0 || [DSSceneHost homeGestureIsActive] || [DSSceneHost systemTransitionBusy]) {
        [self kbshow728CheckLater:gen];
        return;
    }
    // 4.5.740 kbguard740: never force keys for an app that is not allowlisted
    // (Needs-patching log: Messenger at card size, three forced raises, then
    // the SIGTRAP) or while its scene is inactive (deactivation reasons set);
    // log why the keys are not showing instead. Off: -kbguard740-off.
    if (DS809Latched("kbguard740")) {
        NSString *why740 = nil;
        if (!DSPhoneSize675Allowed(bundle) && ![bundle isEqualToString:@"com.apple.MobileSMS"]) why740 = @"the app is not allowlisted (it runs at card size; its own keyboard path decides)";
        else {
            DSSceneHost *host740 = [self visibleHostForBundleIdentifier:bundle];
            long long reasons740 = host740 ? [host740 sceneDeactivationReasons740] : -1;
            if (reasons740 > 0) why740 = [NSString stringWithFormat:@"its scene is inactive (deactivation 0x%llx); waiting for it to become active", reasons740];
        }
        if (why740) {
            static CFAbsoluteTime log740 = 0;
            CFAbsoluteTime now740 = CFAbsoluteTimeGetCurrent();
            if (now740 - log740 > 2.0) {
                log740 = now740;
                DSDiagnosticsRecordFormat(@"SpringBoard: kbguard740 %@ asked for its keyboard but no keys are on screen: not forced, because %@", bundle, why740);
            }
            if ([why740 hasPrefix:@"its scene"] && _kbshow728Tries < 3) {
                _kbshow728Tries += 1;   // bounded: at most 3 more checks
                [self kbshow728CheckLater:gen];
            }
            return;
        }
    }
    if (_kbshow728Tries >= 3) {
        DSDiagnosticsRecordFormat(@"SpringBoard: kbshow728 %@ still no keys on screen after 3 tries (the arbiter says the keyboard is up); gave up", bundle);
        return;
    }
    _kbshow728Tries += 1;
    DSFeature719MarkAction("kbshow728");
    BOOL raised = DSRaiseKeyboardWindowAboveStage();
    DSDiagnosticsRecordFormat(@"SpringBoard: kbshow728 recovered because %@ asked for its keyboard %.1f s ago on a visible card and no keys were on screen: keyboard windows revealed and raised above the stage (try %ld, raise=%d)",
                              bundle, CFAbsoluteTimeGetCurrent() - _kbshow728At, (long)_kbshow728Tries, raised);
    [self kb707Schedule];
    [self kbshow728CheckLater:gen];
}

- (void)phoneSize680KeyboardLayerAskedFor:(NSString *)bundle at:(double)mediaTime {
    @try {
        if (DSFeature699On("kbshow728")) [self kbshow728Arbiter:YES source:bundle];   // 4.5.728: earliest sign of the app's keyboard
    } @catch (NSException *exception) {
    }
    if (![bundle isKindOfClass:NSString.class] || !DSPhoneSize680Enabled() || !DSPhoneSize675Allowed(bundle)) return;
    if ([self phoneSize683ActiveForBundle:bundle]) return; // 4.5.683: keys674 answered YES, nothing to trigger
    if ([self phoneSize684ActiveForBundle:bundle]) {
        // 4.5.684: keys674 answered NO (keys at the phone bottom); the window is fixed, nothing to trigger.
        if (!DSPS680Up) {
            [self phoneSize675Log:[@"ask684-" stringByAppendingString:bundle]
                             line:[NSString stringWithFormat:@"phonesize684 %@ keys674 layer ask at %.3f: keys stay at the phone bottom; window fixed, no 682 trigger", bundle, mediaTime]
                            every:2.0];
        }
        return;
    }
    DSPS680AskAt = mediaTime;
    DSPS680AskBundle = [bundle copy];
    // 4.5.682: the earliest signal moves the window at once (show=instant),
    // outside UIKit's layout pass that asked.
    if (!DSPS680Up) {
        NSString *b = [bundle copy];
        __weak __typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf phoneSize682AskTrigger:b at:mediaTime];
        });
    }
    if (!DSPS680Up) {
        [self phoneSize675Log:[@"ask680-" stringByAppendingString:bundle]
                         line:[NSString stringWithFormat:@"phonesize680 %@ keyboard signal \"keys674 layer ask\" at %.3f (earliest sign; the move starts on arbiter on=1, timed from here)", bundle, mediaTime]
                        every:0.3];
    }
}

- (void)phoneSize682AskTrigger:(NSString *)bundle at:(double)mediaTime {
    @try {
        if (DSPS680Up || !DSPhoneSize680Enabled() || !DSPhoneSize675Allowed(bundle)) return;
        DSPhoneSize681Tune tune = DSPhoneSize681CurrentTune();
        NSString *skip = nil;
        DSSceneHost *host = [self visibleHostForBundleIdentifier:bundle];
        double now = CACurrentMediaTime();
        if (!tune.showInstant) skip = @"show=animate (the move waits for arbiter on=1)";
        else if (!host || ![host isPhoneSize675]) skip = @"no phone-size card on screen";
        else if (mediaTime - DSPS680HideAt >= 0.0 && mediaTime - DSPS680HideAt < 0.8) skip = [NSString stringWithFormat:@"%.0f ms after the keyboard went down (UIKit re-asks on hide)", (mediaTime - DSPS680HideAt) * 1000.0];
        else if (now < DSPS682AskPausedUntil) skip = [NSString stringWithFormat:@"ask trigger paused %.0f s more (asks without a keyboard)", DSPS682AskPausedUntil - now];
        else if (DSStageDragSettlingFast(0.6)) skip = @"card is being dragged";
        else if ([host phoneSize680BarBottom] < [host phoneSize678BottomAnchor] - 0.5) skip = @"window is not at rest";
        else if (DSPS682AskMovedAt > 0 && mediaTime - DSPS682AskMovedAt < 0.3) skip = @"already moved for this ask";
        if (skip) {
            [self phoneSize675Log:[@"ask682skip-" stringByAppendingString:bundle]
                             line:[NSString stringWithFormat:@"phonesize682 %@ keys674 layer ask at %.3f: no instant move, %@", bundle, mediaTime, skip]
                            every:1.0];
            return;
        }
        NSNumber *settled = DSPS680LastHeight[bundle];
        CGFloat keys = settled ? [settled doubleValue] : 346.0;
        CGFloat sceneH = [host phoneSize675SceneSize].height;
        CGFloat anchor = [host phoneSize678BottomAnchor];
        CGFloat bar = MIN(anchor, sceneH - keys);
        DSPS682AskMovedAt = mediaTime;
        DSPS682AskMovedBundle = [bundle copy];
        NSInteger token = ++DSPS682AskToken;
        DSPhoneSize676StartSession(mediaTime);
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize682 %@ TRIGGER keys674 layer ask at %.3f (main +%.0f ms): predicted keyboard %.0f (%@) -> bar bottom %.0f, instant; reverts if no arbiter on=1 within 300 ms",
                                  bundle, mediaTime, (now - mediaTime) * 1000.0, keys,
                                  settled ? @"this app's settled keyboard last time" : @"first keyboard since respring: 243 + 58 + 45 suggestion bar", bar);
        [host phoneSize682MoveBarBottomTo:bar hide:NO signalAt:mediaTime offset:YES instant:YES why:@"keys674 layer ask"];
        __weak __typeof(self) weakSelf = self;
        __weak DSSceneHost *weakHost = host;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (token != DSPS682AskToken || DSPS682AskMovedAt <= 0) return;
            DSPS682AskMovedAt = 0;
            DSSceneHost *h = weakHost;
            if (DSPS680Up || !h || ![h isPhoneSize675] || !weakSelf) return;
            double t = CACurrentMediaTime();
            DSPS682FalseAt[0] = DSPS682FalseAt[1];
            DSPS682FalseAt[1] = t;
            BOOL pause = DSPS682FalseAt[0] > 0 && t - DSPS682FalseAt[0] < 10.0;
            if (pause) DSPS682AskPausedUntil = t + 30.0;
            DSDiagnosticsRecordFormat(@"SpringBoard: phonesize682 %@ REVERT: no arbiter on=1 within 300 ms of the keys674 ask at %.3f (no keyboard after all), window back to rest instantly%@",
                                      bundle, mediaTime, pause ? @"; second time in 10 s: the ask trigger pauses 30 s (arbiter on=1 still moves it instantly)" : @"");
            [h phoneSize682MoveBarBottomTo:[h phoneSize678BottomAnchor] hide:YES signalAt:t offset:NO instant:YES why:@"keys674 ask revert"];
        });
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize682 ask trigger threw %@", exception.reason ?: exception.name ?: @"?");
    }
}

// From the arbiter hook (main queue): YES when 680 handled it.
- (BOOL)phoneSize680KeyboardSignal:(NSString *)signal bundle:(NSString *)bundle on:(BOOL)on height:(CGFloat)height at:(double)mediaTime {
    @try {
        if (![signal isKindOfClass:NSString.class] || ![bundle isKindOfClass:NSString.class]) return NO;
        if (on && DSPS683SessionBundle && bundle.length && ![bundle isEqualToString:DSPS683SessionBundle]) {
            [self phoneSize683EndSession:[NSString stringWithFormat:@"%@ took the keyboard", bundle]];
        }
        if (bundle.length == 0 && !on && DSPS683SessionBundle) bundle = DSPS683SessionBundle;
        if (bundle.length == 0 && !on && DSPS680Up && DSPS680UpBundle.length) bundle = DSPS680UpBundle;
        if (!on && DSPS680Up && DSPS680UpBundle.length && ![bundle isEqualToString:DSPS680UpBundle]) {
            // Another app's hide; the up app's own hide (or the note) ends it.
            return NO;
        }
        if (bundle.length == 0) return NO;
        if (!DSPhoneSize680Enabled() || !DSPhoneSize675Allowed(bundle)) return NO;
        if (!on) DSPS680HideAt = mediaTime;
        // 4.5.683: the app's own keyboard is in the card; nothing to chase.
        if ([self phoneSize683ActiveForBundle:bundle] || (!on && [DSPS683SessionBundle isEqualToString:bundle])) {
            [self phoneSize683KeyboardFrom:bundle on:on height:height at:mediaTime];
            return YES;
        }
        // 4.5.684: safe area = keyboard; the app's bar does not move, so neither does the window.
        DSSceneHost *host684 = [self visibleHostForBundleIdentifier:bundle];
        if (host684 && [host684 isPhoneSize684]) {
            DSPS682AskMovedAt = 0;
            DSPS680Up = on;
            DSPS680UpBundle = on ? [bundle copy] : nil;
            if (on && height >= 150.0) {
                if (!DSPS680LastHeight) DSPS680LastHeight = [NSMutableDictionary dictionary];
                DSPS680LastHeight[bundle] = @(height + 58.0);
            }
            [host684 phoneSize684ArbiterOn:on height:height at:mediaTime];
            return YES;
        }
        BOOL askMoved = on && DSPS682AskMovedAt > 0 && [DSPS682AskMovedBundle isEqualToString:bundle] &&
                        mediaTime - DSPS682AskMovedAt >= 0.0 && mediaTime - DSPS682AskMovedAt < 0.3;
        DSPS682AskMovedAt = 0; // any arbiter status settles a pending ask move
        DSSceneHost *host = [self visibleHostForBundleIdentifier:bundle];
        if (!host) return NO;
        if (![host isPhoneSize675]) {
            [self phoneSize675Log:[@"sig680-" stringByAppendingString:bundle]
                             line:[NSString stringWithFormat:@"phonesize680 %@ keyboard signal \"%@\": scene is not phone-size yet, %@",
                                   bundle, signal, on ? @"the 4.5.675 switch at the keyboard note takes over (fallback, a scene write)" : @"nothing to move"]
                            every:2.0];
            return NO;
        }
        double now = CACurrentMediaTime();
        if (!isfinite(height) || height < 0.0) height = 0.0;
        DSPhoneSize681Tune tune = DSPhoneSize681CurrentTune();
        CGFloat sceneH = [host phoneSize675SceneSize].height;
        CGFloat anchor = [host phoneSize678BottomAnchor];
        CGFloat bar = anchor;
        NSString *topWhy = @"keyboard down";
        BOOL edge = on != DSPS680Up;
        // Reference time for the animation: the arbiter signal (captured on its
        // own queue). A negative delay counts from keys674's layer question when
        // that came within 100 ms before a show.
        double reference = mediaTime;
        BOOL fromAsk = NO;
        if (on) {
            if (!DSPS680LastHeight) DSPS680LastHeight = [NSMutableDictionary dictionary];
            NSNumber *settled = DSPS680LastHeight[bundle]; // this app's keyboard when it was last up
            CGFloat keys = 0.0;
            if (height >= 150.0) {
                // The arbiter's height is the app's keyboard minus its 58 pt
                // bottom row (243 -> 301, 288 -> 346).
                keys = height + 58.0;
                topWhy = [NSString stringWithFormat:@"arbiter height %.0f + 58", height];
                if (edge && tune.targetFinal && settled && [settled doubleValue] > keys + 0.5) {
                    // 4.5.681 target=final: aim straight at where it settled last
                    // time (the suggestion bar comes ~10-20 ms later); the next
                    // arbiter status or the keyboard note corrects a wrong guess.
                    topWhy = [NSString stringWithFormat:@"target=final: arbiter height %.0f + 58 = %.0f, predicted %.0f (this app's settled keyboard last time)",
                              height, keys, [settled doubleValue]];
                    keys = [settled doubleValue];
                } else if (edge && tune.targetFinal && !settled && height <= 250.0) {
                    // 4.5.682: first keyboard since respring: assume the
                    // suggestion bar comes (243 + 58 + 45 = 346).
                    topWhy = [NSString stringWithFormat:@"target=final, first keyboard since respring: arbiter height %.0f + 58 + 45 suggestion bar", height];
                    keys += 45.0;
                }
                DSPS680LastHeight[bundle] = @(height + 58.0);
            } else if (settled) {
                keys = [settled doubleValue];
                topWhy = @"no height yet: this app's last keyboard";
            } else {
                keys = 346.0;
                topWhy = @"no height yet: default 346";
            }
            bar = MIN(anchor, sceneH - keys);
            if (!DSPS680Up && DSPS680AskAt > 0 && [DSPS680AskBundle isEqualToString:bundle] &&
                mediaTime - DSPS680AskAt >= 0.0 && mediaTime - DSPS680AskAt < 0.1) {
                if (tune.delay < 0.0) {
                    reference = DSPS680AskAt;
                    fromAsk = YES;
                }
                if (!DSPS680Up) DSPhoneSize676StartSession(DSPS680AskAt);
            } else if (!DSPS680Up) {
                DSPhoneSize676StartSession(mediaTime);
            }
        } else {
            if (DSPS680Up) DSPhoneSize676StartSession(mediaTime);
        }
        DSPS680Up = on;
        DSPS680UpBundle = on ? [bundle copy] : nil;
        CGFloat current = [host phoneSize680BarBottom];
        CGFloat target = MAX(0.0, bar - ((on && bar < anchor - 0.5) ? tune.offset : 0.0));
        BOOL skip = fabs(current - target) < 0.5;
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize682 %@ keyboard signal \"%@\" height %.0f at %.3f (main +%.0f ms%@): %@ -> bar bottom %.0f%@; now %.0f; %@ (%@%@ %.0f ms, curve %@, delay %+.0f ms from the %@)",
                                  bundle, signal, height, mediaTime, (now - mediaTime) * 1000.0,
                                  (DSPS680AskAt > 0 && [DSPS680AskBundle isEqualToString:bundle] && mediaTime - DSPS680AskAt >= 0.0 && mediaTime - DSPS680AskAt < 0.1)
                                      ? [NSString stringWithFormat:@", keys674 ask %.0f ms earlier", (mediaTime - DSPS680AskAt) * 1000.0] : @"",
                                  on ? [NSString stringWithFormat:@"keyboard top in the scene %.0f (%@)", bar, topWhy] : @"keyboard down",
                                  bar, tune.offset != 0.0 && on ? [NSString stringWithFormat:@" (offset %+.1f -> %.0f)", tune.offset, target] : @"",
                                  current,
                                  skip ? (askMoved ? @"already there from the keys674 ask, no move" : @"already there, no move")
                                       : (askMoved ? @"CORRECTION of the keys674 ask prediction" : (edge ? @"TRIGGER, move" : @"retarget / correction")),
                                  on ? @"show" : @"hide", on && tune.showInstant ? @" instant; animate settings" : @"", on ? tune.duration : tune.hideDuration,
                                  on ? (tune.curve == DSPS681CurveKeyboard ? @"keyboard" : tune.curve == DSPS681CurveSpring ? @"spring" : tune.curve == DSPS681CurveLinear ? @"linear" : tune.curve == DSPS681CurveEaseOut ? @"easeout" : @"easeinout")
                                     : (tune.hideCurve == DSPS681CurveKeyboard ? @"keyboard" : tune.hideCurve == DSPS681CurveSpring ? @"spring" : tune.hideCurve == DSPS681CurveLinear ? @"linear" : tune.hideCurve == DSPS681CurveEaseOut ? @"easeout" : @"easeinout"),
                                  tune.delay, fromAsk ? @"keys674 ask" : @"arbiter signal");
        if (skip) return YES;
        [host phoneSize681MoveBarBottomTo:bar hide:!on signalAt:reference offset:YES
                                      why:[NSString stringWithFormat:@"%@%@", signal, edge ? @"" : @" (height change)"]];
        return YES;
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: phonesize680 keyboard signal threw %@", exception.reason ?: exception.name ?: @"?");
        return NO;
    }
}

- (BOOL)keys671AppHasDylib:(NSString *)bundle {
    if (bundle.length == 0) return YES;
    // Always injected and handled inside the app (the 664 keyboard fix, the
    // Messages app strip, the dial pad).
    if ([bundle isEqualToString:@"com.apple.MobileSMS"] ||
        [bundle isEqualToString:@"com.apple.mobilephone"] ||
        [bundle isEqualToString:@"com.apple.springboard"] ||
        [bundle isEqualToString:@"SpringBoard"]) return YES;
    return DSAppTraceRelayBundleIsLive(bundle);
}

// YES when the card's app slides its own composer for the keyboard, so the
// stage must not also put the card on the keys.
- (BOOL)keys671CardAppAvoidsKeysItself:(DSStageContainerView *)card {
    if (!card || DSKeys671Disabled()) return NO;
    if (_searchSlot >= 0) return NO;
    if (card == _floatContainer || card == _frontCard) return NO;
    NSString *bundle = [self keys671BundleForCard:card];
    if (bundle.length == 0) return NO;
    return ![self keys671AppHasDylib:bundle];
}

// 4.5.672 keys672. Diagnostics only, nothing is written. Once per keyboard
// session of a staged app: does the app have the DynamicStage app dylib (which
// swallows the app's own keyboard notes, so it never pads its composer), what
// its scene settings say right now, and which keyboard frame SpringBoard has.
// SpringBoard pushes no keyboard frame, keyboard inset, safe-area change or
// scene resize to a staged app when its keyboard shows (scene frame stays
// {{0,0},{420,458}}, safe area as set for the card), so for an app without
// the dylib the empty band under its composer is its own keyboard avoidance.
BOOL DSKeys674Active(void);
static NSString *DSKeys672LastSession = nil;

- (void)keys672NoteKeyboard:(CGRect)keyboard source:(NSString *)source {
    @try {
        CGFloat screenH = CGRectGetHeight([self screenBounds]);
        BOOL up = !CGRectIsEmpty(keyboard) && CGRectGetHeight(keyboard) >= 150.0 &&
                  (screenH < 100.0 || CGRectGetMinY(keyboard) < screenH - 1.0);
        if (!up) {
            DSKeys672LastSession = nil;
            return;
        }
        if (source.length == 0 || [source isEqualToString:@"SpringBoard"]) return;
        NSInteger slot = [self slotForHostedBundle:source];
        if (slot < 0) return;
        if (DSKeys672LastSession && [DSKeys672LastSession isEqualToString:source]) return;
        static CFAbsoluteTime lastAt = 0;
        static NSString *lastSource = nil;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        DSKeys672LastSession = [source copy];
        // Hide blips in the middle of one session re-arm the line; once per 4 s.
        if (lastSource && [lastSource isEqualToString:source] && now - lastAt < 4.0) return;
        lastAt = now;
        lastSource = [source copy];
        BOOL dylib = [self keys671AppHasDylib:source];
        DSSceneHost *host = [self sceneHostForSlot:slot];
        DSStageContainerView *card = [self containerForSlot:slot];
        NSString *scene = [host respondsToSelector:@selector(keys672SceneSummary)] ? [host keys672SceneSummary] : @"?";
        NSString *verdict = dylib
            ? @"has the app dylib: its own keyboard notes are swallowed inside the app, so it does not pad its composer (no band)"
            : (DSKeys674Active()
               ? @"has NO DynamicStage app dylib: 4.5.674 keys674 keeps its keyboard layer out of the card (the card's scene host is told it cannot show the app's keyboard layer; the keys stay in SpringBoard's keyboard host at the bottom of the phone), see the keys674 lines"
               : @"has NO DynamicStage app dylib and keys674 is off (/var/mobile/.dynamicstage-keys674-off): it hears its own keyboard notes and pads its composer by itself");
        DSDiagnosticsRecordFormat(@"SpringBoard: keys672 %@ keyboard up %@ slot=%ld card=%@ lift=%.0f; %@; %@",
                                  source, NSStringFromCGRect(keyboard), (long)slot,
                                  card ? NSStringFromCGRect(card.frame) : @"-",
                                  card ? card.liftOffset : 0.0, scene, verdict);
    } @catch (NSException *exception) {
    }
}

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
    // 4.5.680: the message bar must not move: an allowlisted always-full-screen
    // app's card stays where it rests (it is above the keys already).
    if (DSPhoneSize680Enabled() && !DS756On("lift756")) {
        NSString *bundle680 = [self keys671BundleForCard:card];
        DSSceneHost *host680 = [self sceneHostForCard:card];
        if (bundle680.length && DSPhoneSize675Allowed(bundle680) && [host680 isPhoneSize675]) {
            [self phoneSize675Log:[@"drop680-" stringByAppendingString:bundle680]
                             line:[NSString stringWithFormat:@"phonesize680 %@ card kept at rest %@, not dropped onto the keys (keyboard %@): the bar stays where it was",
                                   bundle680, NSStringFromCGRect(card.frame), NSStringFromCGRect(keyboard)]
                            every:10.0];
            return 0.0;
        }
    }
    if ([self keys671CardAppAvoidsKeysItself:card] && !DS756On("lift756")) {
        NSString *bundle = [self keys671BundleForCard:card] ?: @"?";
        CGRect rest = [self placedFrameForCard:card state:DSStageStateOverlay];
        DSKeys671Note([@"drop." stringByAppendingString:bundle],
                      [NSString stringWithFormat:@"%@ has no DynamicStage app dylib (it slides its own composer): top card kept at rest %@, not dropped onto the keys at %.0f (keyboard %@)",
                       bundle, NSStringFromCGRect(rest), CGRectGetMinY(keyboard) - 28.0, NSStringFromCGRect(keyboard)]);
        return 0.0;
    }
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
    if ([self kb707Gate]) return;   // 4.5.707 kb707: the keyboard controller is the only mover
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
    if ([self kb707Gate]) return;   // 4.5.707 kb707: the keyboard controller is the only mover
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
    if ([self kb707Gate]) return;   // 4.5.707 kb707: the keyboard controller is the only mover
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
        if (DSMulti702BuildLog()) [self logLift:[NSString stringWithFormat:@"shift skipped owner=%@ keyH=%.0f %@",
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
            if (DSMulti702BuildLog()) [self logLift:[NSString stringWithFormat:@"upper drop lift=%.0f had=%.0f %@",
                           lift, had, [self lowerStageLiftSummary:keyboard]]];
        }
        if (card == lower || card == _floatContainer || card == front) {
            if (DSMulti702BuildLog()) [self logLift:[NSString stringWithFormat:@"%@ applied lift=%.0f had=%.0f %@",
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
    if ([self kb707Gate]) return;   // 4.5.707 kb707: the keyboard controller is the only mover
    if (_splitMode || _stageDragActive) return;
    if (CGRectIsEmpty(_keyboardFrame) || _searchSlot >= 0) return;
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
    if (_kb707Active && card == _kb707Owner && [self kb707Owns]) return YES;
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

// 4.5.651: the outer rim strips of the two split cards must not cover each
// other's interior (that is the other app's touch). Cheap; runs only when the
// stage geometry changes, never per frame of the switcher.
- (void)refreshRimCatchers {
    BOOL split = _stackSlotCount >= kDSMaxStackSlots && _topContainer && !_topContainer.hidden;
    CGRect avoidForMain = split ? CGRectInset([self visualScreenFrameForCard:_topContainer], kDSStageRimGrabBand, kDSStageRimGrabBand) : CGRectNull;
    CGRect avoidForTop = split ? CGRectInset([self visualScreenFrameForCard:_container], kDSStageRimGrabBand, kDSStageRimGrabBand) : CGRectNull;
    if (_dragShell) [_dragShell setRimCatcherAvoidRect:avoidForMain];
    if ([_topRim isKindOfClass:DSStageRimHitView.class]) {
        DSStageRimHitView *rim = (DSStageRimHitView *)_topRim;
        rim.catcherAvoid = avoidForTop;
        [rim layoutRimCatchers];
    }
    if ([_floatRim isKindOfClass:DSStageRimHitView.class]) {
        [(DSStageRimHitView *)_floatRim layoutRimCatchers];
    }
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
    [self refreshRimCatchers];
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
    // 4.5.705 focus705: app search in the upper of two stacked cards. That card
    // is not dropped any more, so the lower one has nothing to make room for.
    if ([self focus705UpperSearchStill]) return NO;
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
    if ([self drag702Holds:card]) return;
    if ((card == _container || card == _topContainer) && (fabs(card.sideOffset) > 0.5 || fabs(card.liftOffset) > 0.5) &&
        [self kb720Typing] && DSKb720Close([self frameWithoutKeyboardShift:card], frame)) {
        // 4.5.720: same frame while kb707 holds the card: no zero-and-restore.
        [self kb720Act:@"same frame for a typing card: kb707's offsets left running"];
        return;
    }
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
    if ([self kb707Gate]) return;   // 4.5.707 kb707: the keyboard controller is the only mover
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
    if (DSMulti702BuildLog()) [self logLift:[NSString stringWithFormat:@"side park top=%d bottom=%d third=%d lower=%.0f upper=%.0f float=%.0f",
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
    if ([self kb707Gate]) return;   // 4.5.707 kb707: the keyboard controller is the only mover
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
    // 4.5.703 native703: the hairline outline follows light / dark too.
    DSNative703SetDark(dark);
    [_dragShell refreshOutline];
    if (_topContainer && _topRim) [self placeTopRimAroundCard:_topContainer];
}

- (void)native703TraitsChanged:(NSNotification *)note {
    (void)note;
    if (!DSNative703On()) return;
    if ([DSPreferences sharedPreferences].appearance != DSAppearanceAuto) return;
    [self applyAppearance];
    DSDiagnosticsRecordFormat(@"SpringBoard: native703 system appearance changed: stage follows (%@)",
                              UIScreen.mainScreen.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark ? @"dark" : @"light");
}

// 4.5.703 native703 haptics: light and subtle, like iOS. 1 drag start, 2 minimise,
// 3 drop / snap, 4 restore.
- (void)native703Haptic:(NSInteger)kind {
    if (kind <= 0 || !DSNative703On()) return;
    static UIImpactFeedbackGenerator *light = nil, *soft = nil;
    static CFTimeInterval last = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - last < 0.12 && now >= last) return;
    last = now;
    if (!light) light = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    if (!soft) soft = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleSoft];
    UIImpactFeedbackGenerator *generator = (kind == 2 || kind == 3) ? soft : light;
    CGFloat intensity = kind == 1 ? 0.5 : (kind == 2 ? 0.8 : (kind == 3 ? 0.6 : 0.7));
    @try {
        [generator impactOccurredWithIntensity:intensity];
        [generator prepare];
    } @catch (NSException *exception) {
    }
}

static BOOL DSNative703ReduceMotion(void) {
    return DSNative703On() && UIAccessibilityIsReduceMotionEnabled();
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

    _topPicker = DSNewAppPicker817();
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
    [self phoneSize678ObserveTouchesOnCard:_topContainer];
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
    _topContainer.rimCatcherName = @"top-inner";
    DSNameRimCatchers(topRim.catchers, @"top-outer");
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
    if (!parked) [DSSceneHost noteStageInUse];
    if (parked) {
        // 4.5.707 corner707: the safety for every path that parks (heal700,
        // kbmin702, focus, the home tuck): two parked cards never share a corner.
        BOOL wanted = card == _topContainer ? _secondMinimizedLeft : _primaryMinimizedLeft;
        BOOL side = [self corner707Side:wanted forCard:card why:@"park"];
        if (card == _topContainer) _secondMinimizedLeft = side;
        else _primaryMinimizedLeft = side;
    }
    if (card == _topContainer) _secondParked = parked;
    else _primaryParked = parked;
    // 4.5.698 anim698: a card brought back while its minimise picture is still
    // flying: hide the picture (its completion still runs when it would have).
    if (!parked) {
        UIView *flight = objc_getAssociatedObject(card, &kDSAnim698FlightKey);
        if (flight) flight.hidden = YES;
    }
    DSSceneHost *host = [self sceneHostForCard:card];
    [host setStaysBackgrounded:parked];
    if (parked) [self holdHostViewAtStageSize:host];
    else {
        [self returnHostView:host toCard:card];
        [self blackout699WakeSoon:card why:@"brought back from minimised" attempt:0];
    }
}

// ---- 4.5.699 blackout699 ------------------------------------------------------
// Blackoutagain (4.5.697): a card minimised, phone locked for a while, card
// brought back: iOS had put its scene in the background, so the card stayed
// black. The 696 watchdog only wakes after two quiet 1.5 s ticks with no drag,
// and the user was already dragging the black card - whose Live updates then
// trapped SpringBoard (see crash699 in Tweak.xm). So a card that comes back
// from minimised, and every stage card right after an unlock, is checked at
// once and woken with the same card-tap wake the 696 watchdog uses. Never
// while locked, in the home gesture / a system transition, or mid-drag (it
// tries again shortly, up to 4 times). Off: /var/mobile/.dynamicstage-blackout699-off.
- (void)blackout699WakeSoon:(DSStageContainerView *)card why:(NSString *)why attempt:(NSInteger)attempt {
    if (!card || attempt > 4 || !DSFeature699On("blackout699")) return;
    __weak __typeof(self) weakSelf = self;
    __weak DSStageContainerView *weakCard = card;
    NSTimeInterval delay = attempt == 0 ? 0.35 : 0.6;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        DSStageContainerView *strongCard = weakCard;
        if (!strongSelf || !strongCard) return;
        @try {
            [strongSelf blackout699Check:strongCard why:why attempt:attempt];
        } @catch (NSException *exception) {
            DSDiagnosticsRecordFormat(@"SpringBoard: blackout699 caught %@", exception.reason ?: exception.name);
        }
    });
}

- (void)blackout699Check:(DSStageContainerView *)card why:(NSString *)why attempt:(NSInteger)attempt {
    if (DSPS696DeviceLocked() || _state != DSStageStateOverlay) return;
    if ([self cardIsParked:card] || card.hidden || card.alpha < 0.01 || !card.window) return;
    DSSceneHost *host = [self sceneHostForCard:card];
    if (!host.isHosting || [host.bundleIdentifier isEqualToString:@"com.apple.MobileSMS"]) return;
    if (_stageDragActive || DSStageDragSettlingFast(0.5) || [DSSceneHost homeGestureIsActive] ||
        [DSSceneHost systemTransitionBusy] || [DSSceneHost sceneSettingsUpdateDepth] > 0) {
        [self blackout699WakeSoon:card why:why attempt:attempt + 1];
        return;
    }
    NSString *did = [host blackout699WakeIfBackgrounded];
    if (did) {
        DSFeature699MarkTrying("blackout699");
        // 4.5.752 bk752: host750 / scene748 settle a card as it goes live; this
        // wake is now the backstop. It still wakes (a black card is never left
        // black) and says so loudly. Off: bk752-off (log line only).
        if (DSFeature699On("core751") && DSFeature699On("core752") && DSFeature699On("bk752")) {
            DSFeature719MarkAction("bk752");
            DSDiagnosticsRecordFormat(@"SpringBoard: BLACKOUT699 BACKSTOP woke a card host750 had not settled (%@)", why ?: @"?");
        }
        DSDiagnosticsRecordFormat(@"SpringBoard: blackout699 %@ (%@): %@", host.bundleIdentifier ?: @"?", why ?: @"?", did);
        [self ev766Note:@"blackout699" card:card extra:[NSString stringWithFormat:@"attempt=%ld", (long)attempt]];
    }
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
    if ([self drag702Holds:_container]) return;
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
    if (host) {
        [self defer719EnsureTouchObserver];
        // 4.5.719 bg719: a card change allows one (re-)take for this app.
        @try {
            [host bg719AllowRetake];
            [host bg719Request:@"card change"];
        } @catch (NSException *exception) {
        }
    }
}

// ---- 4.5.719 defer719 ------------------------------------------------------------
// The phonesize678 touch observer on the bottom card, set up lazily: on the
// main thread, once an app is put on a card, never in the first 30 s after
// SpringBoard started. Idempotent (phoneSize678ObserveTouchesOnCard: skips a
// card that already has one). Off file -defer719-off: buildWindow does it, as
// before. Crash latch defer719-trying / -crashed.
- (void)defer719EnsureTouchObserver {
    if (_defer719Done || _defer719Queued || !_container) return;
    if (!DSFeature699On("defer719")) return;   // buildWindow already did it
    _defer719Queued = YES;
    NSTimeInterval up = DSProcessUptime719();
    NSTimeInterval wait = up < 30.0 ? (30.0 - up) : 0.0;
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_defer719Queued = NO;
        if (strongSelf->_defer719Done || !strongSelf->_container) return;
        strongSelf->_defer719Done = YES;
        DSFeature699MarkTrying("defer719");
        @try {
            [strongSelf phoneSize678ObserveTouchesOnCard:strongSelf->_container];
            DSDiagnosticsRecordFormat(@"SpringBoard: defer719 touch observer on the bottom card (%.0f s after start)", DSProcessUptime719());
        } @catch (NSException *exception) {
            DSDiagnosticsRecordFormat(@"SpringBoard: defer719 caught %@", exception.reason ?: exception.name);
        }
    });
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


- (DSStageContainerView *)cardOnHalf:(NSInteger)half {
    if (_floatActive && _floatIsSplitCard && _floatContainer && _floatContainer != _frontCard &&
        !_floatContainer.hidden && _floatSplitHalf == half) {
        return _floatContainer;
    }
    if (_container && _container != _frontCard && !_container.hidden && [self halfForContainer:_container] == half) return _container;
    if (_topContainer && _topContainer != _frontCard && !_topContainer.hidden && [self halfForContainer:_topContainer] == half) return _topContainer;
    return nil;
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
    layer.borderWidth = DSNative703OutlineWidth();
    layer.borderColor = DSNative703OutlineColor();
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
    [self refreshRimCatchers];
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
        if (DSNative703On()) {
            [_topRimPulseLayer removeAnimationForKey:@"rimPulse"];
            _topRimPulseLayer.opacity = 0.7;
        } else if (![_topRimPulseLayer animationForKey:@"rimPulse"]) {
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
    // 4.5.750 pos750: placeCard is the resting-frame setter every layout, drag
    // end, minimise and restore goes through. A real change of resting place
    // (not a same-place layout pass, not while kb707 holds a typing card)
    // ends a keyboard move in flight cleanly first. Off: pos750-off (latch).
    @try {
        if ([self core750On] && DS809Latched("pos750") && ![self kb720Typing]) {
            CGRect resting = (card == _container) ? [self primaryCardFrameInRoot] : [self frameWithoutKeyboardShift:card];
            if (!DSKb720Close(resting, frame)) [self move747Cancel:@"card placed somewhere new (pos750)"];
        }
    } @catch (NSException *exception) {
    }
    BOOL kb720Keep = NO;
    if ((card == _container || card == _topContainer) && [self kb720Typing]) {
        // 4.5.720: a layout pass while kb707 holds a typing session. Same
        // resting place = nothing to do (no zero-and-restore of the lift).
        CGRect resting = (card == _container) ? [self primaryCardFrameInRoot] : [self frameWithoutKeyboardShift:card];
        if (DSKb720Close(resting, frame)) {
            [self kb720Act:@"layout while typing: the card stays where kb707 holds it (not re-placed)"];
            return;
        }
        [self kb720Act:@"layout moved a typing card's resting place: kb707's lift kept, kb707 re-checks"];
        kb720Keep = YES;
    }
    CGFloat keptLift = 0.0;
    BOOL keepLift = [self shouldKeepKeyboardLiftOnCard:card];
    BOOL splitKeys = _splitMode && !CGRectIsEmpty(_keyboardFrame) && CGRectGetHeight(_keyboardFrame) >= 150.0;
    if (kb720Keep) keepLift = YES;
    else if (splitKeys && fabs(card.liftOffset) > 0.5) keepLift = YES;
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
    if (kb720Keep) [self kb707Schedule];
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
    [self refreshRimCatchers];
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
    _kb723QuietUntil = CFAbsoluteTimeGetCurrent() + 0.6;   // 4.5.723: kb723 stays out (create / picker / teardown)
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
    [self kb744DismissForCard:card why:@"minimizeIndividualCard"];   // 4.5.744 kbdrag744
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
    _kb723QuietUntil = CFAbsoluteTimeGetCurrent() + 0.6;   // 4.5.723: kb723 stays out (create / picker / teardown)
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
    // 4.5.756 park756: the promoted card keeps ITS corner side and picture
    // (755 log 16:27:58.17: Beeper sat in the left corner but the primary
    // side stayed Messenger's "right", so no corner pull could find it), and
    // the empty card's rim is hidden (the orphan top rim / ghost outline).
    if (DS756On("park756")) {
        DSFeature719MarkAction("park756");
        _primaryMinimizedLeft = _secondMinimizedLeft;
        UIView *pic = _primaryParkPicture;
        _primaryParkPicture = _secondParkPicture;
        _secondParkPicture = pic;
        if (_secondParked) _minimizedHalf = _secondHalf;
        if (_topRim) { _topRim.hidden = YES; _topRim.alpha = 0.0; }
        DSDiagnosticsRecordFormat(@"SpringBoard: park756 second card promoted to primary: parked=%d corner=%@",
                                  _secondParked, _secondMinimizedLeft ? @"left" : @"right");
    }
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


- (void)collapseToSingleTopStage {
    _kb723QuietUntil = CFAbsoluteTimeGetCurrent() + 0.6;   // 4.5.723: kb723 stays out (create / picker / teardown)
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
    // 4.5.656: the stage is hidden for a call screen; its home bar is the system's.
    if (DSCallStepAsideActive()) return NO;
    // Only while a live app owns the stage: with the picker up the recordings
    // still show the system home bar.
    return self.hasHostedApp && _state == DSStageStateOverlay;
}

- (BOOL)stageOccupiesTop {
    if (_state != DSStageStateOverlay && _state != DSStageStateTracking) return NO;
    CGFloat nearTop = CGRectGetMinY([self fixedHalfFrame:1]) + 80.0;
    // 4.5.720: while kb707 holds a typing session the bar follows where kb707
    // is moving the cards (its target), not the live lift a layout pass or a
    // keyboard blink just changed: one change per session, no blinking bar.
    BOOL kb720 = [self kb720Typing];
    BOOL (^cardIsUp)(DSStageContainerView *) = ^BOOL(DSStageContainerView *card) {
        if (!card || card.hidden || card.alpha < 0.05 || [self cardIsParked:card]) return NO;
        CGRect frame = [self rootFrameOfCard:card];
        if (kb720 && (card == self->_container || card == self->_topContainer)) {
            frame = (card == self->_container) ? [self primaryCardFrameInRoot] : [self frameWithoutKeyboardShift:card];
            if (card == self->_kb720OwnerCard) frame.origin.y -= self->_kb720OwnerLift;
            if (CGRectGetHeight(frame) < 80.0) return NO;
            return CGRectGetMinY(frame) < nearTop;
        }
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
    // 4.5.656: the call screen keeps the status bar while the stage is aside.
    if (DSCallStepAsideActive()) return NO;
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
    if (animations && [self anim748On]) {
        @try { [self move747Cancel:@"another card move started (anim748)"]; } @catch (NSException *exception) {}
    }
    BOOL spring702 = _anim702NextSpring;
    _anim702NextSpring = NO;
    if (!animations) {
        if (completion) completion();
        return;
    }
    if (spring702 && DSFeature699On("anim702")) {
        // 4.5.702 anim702: restore / open as one spring, with the pull's speed.
        DSFeature699MarkTrying("anim702");
        id<UITimingCurveProvider> timing = DSNative703ReduceMotion()
            ? (id<UITimingCurveProvider>)[[UICubicTimingParameters alloc] initWithAnimationCurve:UIViewAnimationCurveEaseInOut]
            : (id<UITimingCurveProvider>)DSAnim702Spring(_anim702NextVelocity);
        UIViewPropertyAnimator *spring = [[UIViewPropertyAnimator alloc] initWithDuration:DSNative703ReduceMotion() ? 0.22 : kDSAnim702RestoreDuration
                                                                         timingParameters:timing];
        _anim702NextVelocity = 0.0;
        spring.interruptible = YES;
        [spring addAnimations:animations];
        DSAnim698FrameMeter *meter = [DSAnim698FrameMeter new];
        meter.name = @"restore702";
        [meter start];
        __weak __typeof(self) weakSelf = self;
        __weak UIViewPropertyAnimator *weakSpring = spring;
        [spring addCompletion:^(UIViewAnimatingPosition position) {
            (void)position;
            [meter stop];
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            UIViewPropertyAnimator *done = weakSpring;
            if (strongSelf && done) [strongSelf->_anim702Running removeObject:done];
            if (completion) completion();
        }];
        [self anim702Track:spring];
        [spring startAnimation];
        return;
    }
    UIViewPropertyAnimator *animator = nil;
    if (DSNative703On()) {
        // 4.5.703 native703: snap-back, drop, open / close, split moves use the
        // system's critically damped spring (no overshoot); Reduce Motion: a short ease.
        id<UITimingCurveProvider> timing = UIAccessibilityIsReduceMotionEnabled()
            ? (id<UITimingCurveProvider>)[[UICubicTimingParameters alloc] initWithAnimationCurve:UIViewAnimationCurveEaseInOut]
            : (id<UITimingCurveProvider>)[[UISpringTimingParameters alloc] initWithDampingRatio:1.0];
        animator = [[UIViewPropertyAnimator alloc] initWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0.2 : 0.30 timingParameters:timing];
        [animator addAnimations:animations];
    } else {
        animator = [[UIViewPropertyAnimator alloc] initWithDuration:0.26 curve:UIViewAnimationCurveEaseOut animations:animations];
    }
    if (completion) {
        [animator addCompletion:^(UIViewAnimatingPosition position) {
            completion();
        }];
    }
    [animator startAnimation];
}

#pragma mark - Activation rules

// Said in words rather than as a flag, because "nothing happens when I pull from
// the corner" is the one report this tweak cannot investigate from the outside.
// The reason ends up in the log the Settings page reads back.
- (NSString *)reasonStageCannotActivate {
    DSPreferences *preferences = [DSPreferences sharedPreferences];
    if (!preferences.enabled) return @"the tweak is switched off in Settings";
    static CFAbsoluteTime killCheckedAt = 0;
    static BOOL killPresent = NO;
    CFAbsoluteTime killNow = CFAbsoluteTimeGetCurrent();
    if (!DSPerf697On() || killNow - killCheckedAt > 2.0 || killNow < killCheckedAt) {
        killCheckedAt = killNow;
        killPresent = [[NSFileManager defaultManager] fileExistsAtPath:kDSKillSwitchPath];
    }
    if (killPresent) {
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
    if (DSCallStepAsideActive()) return NO;
    // A left swipe from the phone's right corner is not a stage gesture and not
    // a system one either. Letting it through is what blanks the stage.
    if (_stageDragActive && [self pointIsTerminateBand:point]) return YES;
    if (self.isStageVisible && [self pointIsHomeBar:point]) return NO;
    return [self shouldSuppressSystemGestureAtPoint:point velocity:CGPointZero];
}

- (BOOL)shouldSuppressSystemGestureAtPoint:(CGPoint)point velocity:(CGPoint)velocity {
    // 4.5.656: the hidden stage never takes a system gesture from the call screen.
    if (DSCallStepAsideActive()) return NO;
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
    if ([self pointIsOnRimCatchRing:point]) {
        DSRimLog([NSString stringWithFormat:@"system gesture held at %.0f,%.0f (rim)", point.x, point.y]);
        return YES;
    }
    // 4.5.740 rimwin740: the finger went down on a side rim strip (left or right
    // screen edge) but SpringBoard asks about its edge gesture at a point that
    // has already moved off the ring (Needs-patching log 10:59:21.778: rim hit at
    // 0,672, no drag). Within 0.5 s of that strip touch-down, near the same spot,
    // the edge gesture is held so the stage drag wins, as with the corner pull.
    // The grab area itself is not widened. Off: -rimwin740-off.
    if (DSFeature699On("rimwin740") && DSRim740StripAt > 0) {
        CFAbsoluteTime now740 = CFAbsoluteTimeGetCurrent();
        CGRect scr740 = [self screenBounds];
        CGPoint p0 = DSRim740StripPoint;
        BOOL side = p0.x < 16.0 || p0.x > CGRectGetWidth(scr740) - 16.0;
        if (side && now740 - DSRim740StripAt < 0.5 && now740 >= DSRim740StripAt &&
            fabs(point.x - p0.x) < 60.0 && fabs(point.y - p0.y) < 60.0 &&
            point.y > 10.0 && point.y < CGRectGetHeight(scr740) - 22.0) {
            DSFeature719MarkAction("rimwin740");
            DSRimLog([NSString stringWithFormat:@"rimwin740 system edge gesture held at %.0f,%.0f (finger went down on the side rim at %.0f,%.0f)", point.x, point.y, p0.x, p0.y]);
            return YES;
        }
    }
    return NO;
}

// 4.5.651: the band just outside a visible card (kDSRimOuterCatch). A system
// edge gesture that starts there is a rim grab. Never the very top edge
// (Notification / Control Center), the bottom edge (home, switcher, corner
// pull) or while the home / switcher transition runs.
- (BOOL)pointIsOnRimCatchRing:(CGPoint)point {
    if (!self.isStageVisible || !_container.window) return NO;
    CGRect screen = [self screenBounds];
    if (point.y < 10.0 || point.y > CGRectGetHeight(screen) - 22.0) return NO;
    if ([DSSceneHost systemTransitionBusy]) return NO;
    NSMutableArray<DSStageContainerView *> *cards = [NSMutableArray arrayWithCapacity:3];
    if (_dragShell && !_dragShell.hidden && !_container.hidden && !_primaryParked) [cards addObject:_container];
    if (_stackSlotCount >= kDSMaxStackSlots && _topContainer && !_topContainer.hidden && !_secondParked) [cards addObject:_topContainer];
    if (_floatActive && _floatContainer && !_floatContainer.hidden) [cards addObject:_floatContainer];
    for (DSStageContainerView *card in cards) {
        CGRect frame = [self visualScreenFrameForCard:card];
        if (CGRectContainsPoint(CGRectInset(frame, -kDSRimOuterCatch, -kDSRimOuterCatch), point) &&
            !CGRectContainsPoint(frame, point)) {
            return YES;
        }
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
    // 4.5.756 park756: the side flags disagree with where the parked card is
    // drawn: take the parked card whose corner picture is on that side.
    if (DS756On("park756")) {
        DSStageContainerView *cards[2] = { _container, _topContainer };
        BOOL parked[2] = { _primaryParked, _secondParked };
        for (int i = 0; i < 2; i++) {
            if (!parked[i] || !cards[i] || ![self sceneHostForCard:cards[i]].isHosting) continue;
            CGRect seen = [self visualScreenFrameForCard:cards[i]];
            if (CGRectIsNull(seen) || CGRectIsEmpty(seen)) continue;
            BOOL onLeft = CGRectGetMidX(seen) < CGRectGetMidX(screen);
            if (onLeft == left) {
                DSFeature719MarkAction("park756");
                if (i == 0) _primaryMinimizedLeft = left; else _secondMinimizedLeft = left;
                DSDiagnosticsRecordFormat(@"SpringBoard: park756 corner pull matched the %@ card by where it is drawn (%@ corner); side fixed",
                                          i == 0 ? @"primary" : @"second", left ? @"left" : @"right");
                return cards[i];
            }
        }
    }
    return nil;
}

- (BOOL)gestureControllerShouldBegin:(DSGestureController *)controller atPoint:(CGPoint)point {
    (void)controller;
    if (_systemPull || _state == DSStageStateTracking) return NO;
    if (_corner771QueuedPull && [self corner771On]) return NO;   // 4.5.771: a claimed pull is waiting
    if ([self parkedCardForCornerPoint:point]) [self noteStageUse];
    _cornerRestoreCard = [self parkedCardForCornerPoint:point];
    if (_cornerRestoreCard) DSStageRestore706Note();
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
// ---- 4.5.771 corner771 ------------------------------------------------------------
// A minimised card's corner (bottom 108 pt, 86 pt in from that side, not the home
// bar) is the card's from the drag-minimise release on: no 1 s pull728 window,
// no _ignoreSystemPullUntil, no "switcher swipe" refusal. The system edge pull
// that starts there is always claimed (SpringBoard's home / switcher never get
// it). While the minimise is still flying (anim702 / spam700 pending) the pull
// is claimed and, if it ends as a restore, the restore is queued and run once
// the minimise has finished, through the normal restoreMinimizedStageAnimated:
// path (never from inside SpringBoard's gesture callback). The minimise drag's
// own touch is refused only while that recogniser is still tracking.
// Off: corner771-off, master core771-off (crash latch corner771).
- (BOOL)corner771On {
    if (!DS771On("corner771")) return NO;
    if (!_corner771Marked) { _corner771Marked = YES; DSFeature699MarkTrying("corner771"); }
    return YES;
}

- (BOOL)corner771ClaimPull:(UIPanGestureRecognizer *)gesture card:(DSStageContainerView *)card at:(CGPoint)start {
    BOOL left = [self cardMinimizedOnLeft:card];
    DSFeature719MarkAction("corner771");
    if (_anim702Running.count > 0 || _spam700MinimisePending) {
        if (_corner771QueuedPull) [_corner771QueuedPull removeTarget:self action:@selector(corner771QueuedPullChanged:)];
        _corner771QueuedPull = gesture;
        _corner771QueuedCard = card;
        _corner771QueuedLeft = left;
        _corner771QueuedGen = _spam700Gen;
        [gesture addTarget:self action:@selector(corner771QueuedPullChanged:)];
        DSDiagnosticsRecordFormat(@"SpringBoard: corner771 claimed pull in parked corner (%@) at %.0f,%.0f while the minimise is still running (anim702=%lu spam700 pending=%d)",
                                  left ? @"left" : @"right", start.x, start.y, (unsigned long)_anim702Running.count, _spam700MinimisePending);
        return YES;
    }
    DSDiagnosticsRecordFormat(@"SpringBoard: corner771 claimed pull in parked corner (%@) at %.0f,%.0f", left ? @"left" : @"right", start.x, start.y);
    [self noteStageUse];
    card = [self parkedCardForCornerPoint:start] ?: card;
    if (![self cardIsParked:card]) return YES;   // claimed, nothing to restore
    _cornerRestoreCard = card;
    DSStageRestore706Note();
    _systemPull = gesture;
    _restore726PullAt = CFAbsoluteTimeGetCurrent();
    [gesture addTarget:self action:@selector(handleSystemPull:)];
    [DSSceneHost noteSystemEdgePullActive:YES];
    DSDiagnosticsRecord(@"SpringBoard: corner pull picked up from the system gesture");
    [self gestureControllerDidBegin:nil];
    @try {
        [self grab733ClaimPullAt:start];
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: grab733 caught %@", exception.reason ?: exception.name);
    }
    return YES;
}

- (void)corner771QueuedPullChanged:(UIPanGestureRecognizer *)gesture {
    if (gesture != _corner771QueuedPull) { [gesture removeTarget:self action:@selector(corner771QueuedPullChanged:)]; return; }
    UIGestureRecognizerState st = gesture.state;
    if (st != UIGestureRecognizerStateEnded && st != UIGestureRecognizerStateCancelled && st != UIGestureRecognizerStateFailed) return;
    [gesture removeTarget:self action:@selector(corner771QueuedPullChanged:)];
    _corner771QueuedPull = nil;
    DSStageContainerView *card = _corner771QueuedCard;
    _corner771QueuedCard = nil;
    BOOL restore = st == UIGestureRecognizerStateEnded && card &&
        [self gestureIsDiagonalInwardFromLeft:_corner771QueuedLeft translation:[gesture translationInView:nil] velocity:[gesture velocityInView:nil]];
    if (!restore) {
        DSDiagnosticsRecord(@"SpringBoard: corner771 claimed pull ended without a restore (not a diagonal pull inward)");
        return;
    }
    NSUInteger gen = _corner771QueuedGen;
    DSDiagnosticsRecordFormat(@"SpringBoard: corner771 queued restore during minimise anim (%@)", _corner771QueuedLeft ? @"left" : @"right");
    // Never from inside SpringBoard's gesture callback: next main-queue turn.
    __weak __typeof(self) weakSelf = self;
    __weak DSStageContainerView *weakCard = card;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf corner771RunQueuedRestore:weakCard gen:gen tries:0];
    });
}

- (void)corner771RunQueuedRestore:(DSStageContainerView *)card gen:(NSUInteger)gen tries:(NSInteger)tries {
    if (!card) return;
    if (gen != _spam700Gen) {
        DSDiagnosticsRecord(@"SpringBoard: corner771 queued restore dropped: another minimise / restore came after it");
        return;
    }
    BOOL busy = _anim702Running.count > 0 || _spam700MinimisePending || _systemPull || _state == DSStageStateTracking ||
        [DSSceneHost homeGestureIsActive] || [DSSceneHost systemPullCallbackIsActive];
    if (busy) {
        if (tries >= 40) {
            DSDiagnosticsRecord(@"SpringBoard: corner771 queued restore dropped: the minimise did not finish within 2 s");
            return;
        }
        __weak __typeof(self) weakSelf = self;
        __weak DSStageContainerView *weakCard = card;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf corner771RunQueuedRestore:weakCard gen:gen tries:tries + 1];
        });
        return;
    }
    if (![self cardIsParked:card] || ![self sceneHostForCard:card].isHosting) {
        DSDiagnosticsRecord(@"SpringBoard: corner771 queued restore dropped: the card is no longer parked");
        return;
    }
    DSDiagnosticsRecordFormat(@"SpringBoard: corner771 running the queued restore after %.2f s", tries * 0.05);
    @try {
        [self noteStageUse];
        if (![self cardIsParked:card]) return;
        _cornerRestoreCard = card;
        DSStageRestore706Note();
        [self restoreMinimizedStageAnimated:YES];
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: corner771 queued restore caught %@", exception.reason ?: exception.name);
    }
}

- (void)restore727Refused:(NSString *)why at:(CGPoint)point {
    // 4.5.727: a refused corner pull is logged (only while a card is minimised).
    if (!_primaryParked && !_secondParked) return;
    if (!DSFeature699On("restore726")) return;
    DSFeature719MarkAction("restore726");
    [self restore726Say:[NSString stringWithFormat:@"corner pull refused at %.0f,%.0f: %@ (primary parked=%d %@, second parked=%d %@)",
                         point.x, point.y, why, _primaryParked, _primaryMinimizedLeft ? @"left" : @"right",
                         _secondParked, _secondMinimizedLeft ? @"left" : @"right"]];
}

- (BOOL)adoptSystemEdgePull:(UIPanGestureRecognizer *)gesture {
    if (!_activated) return NO;
    CGPoint start727 = gesture ? [gesture locationInView:nil] : CGPointZero;
    // 4.5.656: no stage pull over the call screen; the edge stays the system's.
    if (DSCallStepAsideActive()) { [self restore727Refused:@"call screen" at:start727]; return NO; }
    if (!gesture) return NO;
    if (_systemPull) { [self restore727Refused:@"a previous corner pull is still registered" at:start727]; return NO; }
    // 4.5.771 corner771: a parked corner owns its touch from the minimise release on.
    BOOL c771 = [self corner771On];
    DSStageContainerView *corner771Card = c771 ? [self parkedCardForCornerPoint:start727] : nil;
    if (corner771Card) {
        if (_corner771MinGesture && (_corner771MinGesture.state == UIGestureRecognizerStateBegan ||
                                     _corner771MinGesture.state == UIGestureRecognizerStateChanged)) {
            // The minimise drag's own finger is still down: that touch is never a restore.
            [self restore727Refused:@"corner771: the same touch as the minimise drag" at:start727];
            return NO;
        }
        return [self corner771ClaimPull:gesture card:corner771Card at:start727];
    }
    if (CFAbsoluteTimeGetCurrent() < _ignoreSystemPullUntil) { [self restore727Refused:@"pulls blocked for a moment after a stage move" at:start727]; return NO; }
    if (DSFeature699On("pull728") && !c771) {
        // 4.5.728 pull728: the bottom-edge gesture at the end of a minimise swipe
        // is not a restore (Bug log 09:10:40.768 -> 09:10:41.333).
        CFAbsoluteTime now728 = CFAbsoluteTimeGetCurrent();
        NSString *why728 = nil;
        if (_anim702Running.count > 0 || _spam700MinimisePending) why728 = @"pull728: a minimise animation is still running";
        else if (now728 - _pull728DragMinAt < 1.0 && now728 >= _pull728DragMinAt) why728 = @"pull728: within 1 s of a drag-minimise release";
        if (why728) {
            DSFeature719MarkAction("pull728");
            [self restore727Refused:why728 at:start727];
            return NO;
        }
    }
    CGPoint start = start727;
    CGPoint velocity = [gesture velocityInView:nil];
    CGPoint translation = [gesture translationInView:nil];
    if ([self gestureMovesLeftAlongTheBottom:translation velocity:velocity]) { [self restore727Refused:@"moving along the bottom (switcher swipe)" at:start]; return NO; }
    DSStageContainerView *card = [self parkedCardForCornerPoint:start];
    if (!card) {
        CGRect scr = [self screenBounds];
        NSString *why = [self pointIsHomeBar:start] ? @"started on the home bar"
            : start.y < CGRectGetHeight(scr) - 108.0 ? @"started above the bottom 108 pt"
            : (start.x >= 86.0 && start.x <= CGRectGetWidth(scr) - 86.0) ? @"not within 86 pt of a corner"
            : @"no minimised card in that corner";
        [self restore727Refused:why at:start];
        return NO;
    }
    // 4.5.657: stage use. An app killed from the switcher is handled now.
    [self noteStageUse];
    card = [self parkedCardForCornerPoint:start];
    if (!card) return NO;
    _cornerRestoreCard = card;
    DSStageRestore706Note();

    _systemPull = gesture;
    _restore726PullAt = CFAbsoluteTimeGetCurrent();
    [gesture addTarget:self action:@selector(handleSystemPull:)];
    [DSSceneHost noteSystemEdgePullActive:YES];
    DSDiagnosticsRecord(@"SpringBoard: corner pull picked up from the system gesture");
    [self gestureControllerDidBegin:nil];
    @try {
        [self grab733ClaimPullAt:start];
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: grab733 caught %@", exception.reason ?: exception.name);
    }
    return YES;
}

// ---- 4.5.733 grab733 -----------------------------------------------------------
// A corner pull is SpringBoard's own bottom-edge gesture, adopted by the stage.
// The same touch had already been hit-tested to the window under the finger (the
// home screen, the dock, the stage window says "not mine" while minimised), so
// the home screen's scroll / page pans moved along with the pull. Once the pull
// is ours, every pan and scroll recogniser in SpringBoard's window under the
// start point is cancelled (disabled and re-enabled, UIKit's standard cancel);
// the system gesture itself, the switcher and the home bar are not touched.
// An app behind (another process) gets the touch from the window server and
// cannot be cancelled from SpringBoard. Off: /var/mobile/.dynamicstage-grab733-off.
- (void)grab733ClaimPullAt:(CGPoint)point {
    if (!DSFeature699On("grab733")) return;
    UIWindow *under = nil;
    UIView *hit = nil;
    NSArray<UIWindow *> *windows = UIApplication.sharedApplication.windows;
    for (UIWindow *w in windows.reverseObjectEnumerator) {
        if (w == (UIWindow *)_window || w.hidden || w.alpha < 0.01 || !w.userInteractionEnabled) continue;
        if (w.windowLevel >= 1000.0) continue;   // keyboard host, system UI above the stage
        if (w.screen && w.screen != UIScreen.mainScreen) continue;
        CGPoint local = [w convertPoint:point fromWindow:nil];
        if (!CGRectContainsPoint(w.bounds, local)) continue;
        UIView *v = [w hitTest:local withEvent:nil];
        if (v) {
            under = w;
            hit = v;
            break;
        }
    }
    if (!hit) return;
    NSInteger cancelled = 0;
    UIGestureRecognizer *pull = _systemPull;
    for (UIView *v = hit; v; v = v.superview) {
        for (UIGestureRecognizer *g in v.gestureRecognizers) {
            if (g == pull || !g.enabled) continue;
            if (![g isKindOfClass:UIPanGestureRecognizer.class] && ![g isKindOfClass:UISwipeGestureRecognizer.class]) continue;
            UIGestureRecognizerState st = g.state;
            if (st != UIGestureRecognizerStatePossible && st != UIGestureRecognizerStateBegan && st != UIGestureRecognizerStateChanged) continue;
            g.enabled = NO;
            g.enabled = YES;
            cancelled += 1;
        }
    }
    if (cancelled > 0) {
        DSFeature719MarkAction("grab733");
        DSDiagnosticsRecordFormat(@"SpringBoard: grab733 corner pull claimed: cancelled %ld pan / scroll recogniser(s) in %@ under %.0f,%.0f",
                                  (long)cancelled, NSStringFromClass(under.class), point.x, point.y);
    }
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
    [DSSceneHost noteSystemEdgePullActive:NO];
}

- (void)gestureControllerDidBegin:(DSGestureController *)controller {
    (void)controller;
    _stateBeforeTracking = _state;
    // A minimized app in the corner can be pulled out even while the other
    // stage is already on screen. That pull has to win over the open card.
    if (_cornerRestoreCard && [self cardIsParked:_cornerRestoreCard]) {
        // 4.5.700 spam700: picked up while its minimise is still finishing:
        // a cancelled pull goes back to minimised, not to the open stage.
        if (_spam700MinimisePending && _stateBeforeTracking == DSStageStateOverlay && DSFeature699On("spam700") &&
            !(_stackSlotCount >= kDSMaxStackSlots && [self spam700OtherCardOnScreen:_cornerRestoreCard])) {
            _stateBeforeTracking = DSStageStateMinimized;
            DSDiagnosticsRecord(@"SpringBoard: spam700 corner pull picked up while the minimise is still finishing");
        }
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
    if (DSFeature699On("anim702")) {
        UIView *flying = objc_getAssociatedObject(card, &kDSAnim698FlightKey);
        if (flying) flying.hidden = YES;   // 4.5.702: the pulled card replaces the picture still flying in
    }
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
    // 4.5.700 spam700: minimised again since this restore: its reveal (wake,
    // foreground, layout) no longer belongs to what the user last did.
    if (card && [self cardIsParked:card] && DSFeature699On("spam700")) {
        DSFeature699MarkTrying("spam700");
        DSDiagnosticsRecordFormat(@"SpringBoard: spam700 ignored a stale restore completion (#%lu): the card was minimised again",
                                  (unsigned long)_spam700Gen);
        return;
    }
    if ([DSSceneHost homeGestureIsActive] || [DSSceneHost systemPullCallbackIsActive] ||
        [DSSceneHost sceneSettingsUpdateDepth] > 0) {
        __weak __typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf finishCornerRestoreOfCard:card];
        });
        return;
    }
    if (DSFeature699On("anim702")) [self anim702HandOffPictureForCard:card];
    else [self discardRememberedPictureForCard:card];
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
    DSHide772NotePath(@"restoreMinimizedStage");
    [self keyfocus772AfterRestore:_cornerRestoreCard ?: _container];
    [self scene748Settle:@"restored from minimised" after:0.6];
    if (DSFeature699On("spam700")) [self spam700Note:2 why:@"corner restore"];
    [DSSceneHost noteStageInUse];
    DSStageContainerView *card = _cornerRestoreCard ?: _container;
    // 4.5.702 anim702: a minimise still flying stops where it is; the card
    // springs from where the finger left it, carrying the pull's speed.
    BOOL spring702 = animated && DSFeature699On("anim702");
    CGPoint pullVelocity = (spring702 && _systemPull) ? [_systemPull velocityInView:nil] : CGPointZero;
    if (spring702) [self anim702StopRunning:@"restore"];
    if (animated) [self native703Haptic:4];
    _cornerRestoreCard = nil;
    DSStageRestore706Note();
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
    if (spring702) {
        UIView *root = card.window;
        CGRect now = root ? [card convertRect:card.bounds toView:root] : CGRectZero;
        CGRect rest = [self fixedHalfFrame:half];
        _anim702NextVelocity = DSAnim702PathVelocity(pullVelocity, CGPointMake(CGRectGetMidX(now), CGRectGetMidY(now)),
                                                     CGPointMake(CGRectGetMidX(rest), CGRectGetMidY(rest)));
    }
    if (_state != DSStageStateOverlay) {
        _anim702NextSpring = spring702;
        [self enterStateOverlayAnimated:animated keepingParkedCard:other];
        _anim702NextSpring = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), reveal);
        return;
    }
    void (^layout)(void) = ^{
        [self layoutAllStackSlotsForState:DSStageStateOverlay];
        [self hideParkedCardsCompletely];
        [self bringCardAboveItsPartner:revealed];
    };
    _anim702NextSpring = spring702;
    if (animated) [self animateSpring:layout completion:reveal];
    else { layout(); reveal(); }
    _anim702NextSpring = NO;
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
        DSStageRestore706Note();
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
        // 4.5.700 spam700: the minimise that was finishing when the pull
        // began completes now that the pull was given up.
        void (^deferred)(void) = self->_spam700DeferredFinish;
        self->_spam700DeferredFinish = nil;
        if (deferred && self->_state != DSStageStateTracking && self->_primaryParked) {
            DSDiagnosticsRecord(@"SpringBoard: spam700 corner pull given up: the minimise completion runs now");
            deferred();
        }
    }];
}



#pragma mark - Host snapshot



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
    [self perf706KickTick];   // 4.5.706 perf706
    _outside707QuietUntil = CFAbsoluteTimeGetCurrent() + 0.8;   // 4.5.707 outside707
    BOOL spam = DSFeature699On("spam700");
    if (spam) [self spam700Note:2 why:@"stage on screen"];
    NSUInteger gen = _spam700Gen;
    // One card is an ordinary stage. Split, and the extra stage it allows,
    // only exist while both halves are on screen.
    if (_stackSlotCount < kDSMaxStackSlots) {
        _splitMode = NO;
        _splitHomeRevealed = NO;
        _splitResizeHeight = 0.0;
        _expandedCard = nil;
    }
    // 4.5.702 anim702: opened from the corner icon (no pull): the card grows out of the icon.
    BOOL expand702 = animated && !_anim702NextSpring && DSFeature699On("anim702") && _state == DSStageStateMinimized &&
                     _primaryParked && keepParked != _container && _sceneHost.isHosting && _dragShell && _cornerRestoreCard == nil &&
                     !_splitMode && !_floatActive;
    if (animated && DSFeature699On("anim702")) [self anim702StopRunning:@"open"];
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
        // 4.5.700 spam700: minimised again while this was springing open.
        if (spam && gen != self->_spam700Gen && self->_spam700Intent == 1) {
            [self discardHostSnapshotAnimated:YES];
            DSDiagnosticsRecordFormat(@"SpringBoard: spam700 ignored a stale open completion (#%lu, now #%lu): minimised again",
                                      (unsigned long)gen, (unsigned long)self->_spam700Gen);
            return;
        }
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

    if (expand702 && [self anim702ExpandPrimaryWithLayout:layout completion:finish]) return;
    if (animated) {
        [self animateSpring:layout completion:finish];
    } else {
        layout();
        finish();
    }
}


- (void)minimizeAnimated:(BOOL)animated {
    [self kb744DismissForCard:nil why:@"minimizeAnimated"];   // 4.5.744 kbdrag744
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
    [self noteStageUse];
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
    [self kb744DismissForCard:nil why:@"closeStageAnimated"];   // 4.5.744 kbdrag744
    _kb723QuietUntil = CFAbsoluteTimeGetCurrent() + 0.6;   // 4.5.723: kb723 stays out (create / picker / teardown)
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
    DSGest811NoteOther(otherName);
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

- (NSString *)keys674HostedBundleForSceneIdentifier:(NSString *)identifier {
    if (identifier.length == 0) return nil;
    for (DSSceneHost *host in @[ _sceneHost ?: (id)NSNull.null, _topSceneHost ?: (id)NSNull.null, _floatSceneHost ?: (id)NSNull.null ]) {
        if (![host isKindOfClass:DSSceneHost.class] || !host.isHosting) continue;
        NSString *bundle = host.bundleIdentifier;
        if (bundle.length && [identifier rangeOfString:bundle].location != NSNotFound) return bundle;
    }
    return nil;
}

- (BOOL)isHostingSceneIdentifier:(NSString *)identifier {
    if (identifier.length == 0) return NO;
    // 4.5.657: an app killed from the switcher is not hosted any more, even
    // before the stage has handled it (a relaunch must not get card treatment).
    BOOL died = DSSceneHostAnyDiedPending();
    NSString *bottom = _sceneHost.bundleIdentifier;
    NSString *top = _topSceneHost.bundleIdentifier;
    if (_sceneHost.isHosting && bottom.length &&
        [identifier rangeOfString:bottom].location != NSNotFound &&
        !(died && DSSceneHostBundleDiedPending(bottom))) {
        return YES;
    }
    if (_topSceneHost.isHosting && top.length &&
        [identifier rangeOfString:top].location != NSNotFound &&
        !(died && DSSceneHostBundleDiedPending(top))) {
        return YES;
    }
    NSString *hovering = _floatSceneHost.bundleIdentifier;
    if (_floatSceneHost.isHosting && hovering.length &&
        [identifier rangeOfString:hovering].location != NSNotFound &&
        !(died && DSSceneHostBundleDiedPending(hovering))) {
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
    BOOL kb720Own = _ensuringPickerSearchKeyboard && _searchSlot == slot &&
                    DSSearchFieldLastUserTap() <= _pickerSearchEnsureStartedAt && [self kb720On];
    _searchSlot = slot;
    if (kb720Own) {
        // 4.5.720: our own re-assert landing here is not a new typing focus.
        [self kb720Act:@"search re-assert: no new focus schedule"];
    } else {
        [self focus704Schedule];
    }
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
        if ([strongSelf kb720On]) {
            // 4.5.720: a keyboard on its way in (UIKit said willShow, or part
            // of it is already on screen) is left alone: a reload / restart
            // now is what made it drop and come back (the picker flicker).
            CGRect partial = DSVisibleKeyboardFrameOnScreen();
            BOOL coming = CFAbsoluteTimeGetCurrent() - strongSelf->_kb720ShowAt < 0.8 ||
                          (!CGRectIsNull(partial) && CGRectGetHeight(partial) > 0.5);
            if (coming && attempt < 5) {
                [strongSelf kb720Act:@"search keys on their way: no re-raise"];
                [strongSelf ensurePickerSearchKeyboard:picker slot:slot generation:generation attempt:attempt + 1];
                return;
            }
            [strongSelf noteSearchKeyboardDebug:[strongSelf searchKeyboardDebugLine:@"search retry" attempt:attempt picker:picker]];
            [strongSelf kb720Act:@"search re-raise without resign (no hide / show)"];
            [strongSelf takeKeyWindow];
            if (!DSWindowIsApplicationKey(strongSelf->_window) && !DSVideoIsPlayingOnScreen()) {
                [strongSelf->_window makeKeyAndVisible];
            }
            // Editing: reload once at attempt 2+; not editing: become first
            // responder. A restart (resign + become) only as the last resort,
            // with no keyboard on screen at all (nothing to drop).
            BOOL editing = [picker searchFieldIsEditing];
            if (!editing) {
                [picker reassertSearchEditing];
            } else if (attempt >= 5 && CGRectIsNull(partial) && !DSVideoIsPlayingOnScreen()) {
                [picker restartSearchEditing];
            } else if (attempt >= 2) {
                [picker reassertSearchEditing];
            }
            [strongSelf ensurePickerSearchKeyboard:picker slot:slot generation:generation attempt:attempt + 1];
            return;
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
    [self scene748Settle:@"search closed" after:0.4];
    [self focus704Schedule];
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

- (NSArray<NSDictionary *> *)appPickerSlotChoices817:(DSAppPickerViewController *)picker {
    NSMutableArray *out = [NSMutableArray array];
    @try {
        NSInteger own = [self slotForPicker:picker];
        for (NSInteger slot = 0; slot <= 1; slot++) {
            if (slot != own && ![self pickerVisibleOnSlot:slot]) continue;
            DSStageContainerView *card = slot == 0 ? _container : _topContainer;
            if (!card) continue;
            BOOL upper = card == [self cardOnHalf:1];
            [out addObject:@{ @"slot": @(slot), @"here": @(slot == own),
                              @"title": upper ? @"Open on Top Card" : @"Open on Bottom Card" }];
        }
    } @catch (NSException *exception) {}
    return out;
}

- (void)appPicker:(DSAppPickerViewController *)picker didChooseEntry:(DSAppEntry *)entry slot817:(NSInteger)slot fromView:(UIView *)view {
    [picker dismissKeyboard];
    NSInteger own = [self slotForPicker:picker];
    if (slot != own) {
        if (slot < 0 || slot > 1 || ![self pickerVisibleOnSlot:slot]) slot = own;   // that card filled meanwhile
        else [[self pickerForSlot:slot] dismissKeyboard];
    }
    DSDiagnosticsRecordFormat(@"SpringBoard: picker817 menu: %@ on slot %ld (picker slot %ld)", entry.bundleIdentifier ?: @"?", (long)slot, (long)own);
    [self launchEntry:entry slot:slot];
}

- (void)appPicker:(DSAppPickerViewController *)picker didHoldEntry:(DSAppEntry *)entry fromView:(UIView *)view {
    [picker dismissKeyboard];
    [self launchFullscreen:entry.bundleIdentifier];
}

- (void)launchEntry:(DSAppEntry *)entry {
    [self launchEntry:entry slot:0];
}

- (void)launchEntry:(DSAppEntry *)entry slot:(NSInteger)slot {
    _kb723QuietUntil = CFAbsoluteTimeGetCurrent() + 0.6;   // 4.5.723: kb723 stays out (create / picker / teardown)
    [self noteStageUse];
    DSBg719NoteUserStaged();   // 4.5.719 bg719 first-use gate
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

    if (DSFeature699On("picker740")) {
        BOOL full740 = NO;
        @try {
            full740 = [[self picker740FullScreenBundles] containsObject:entry.bundleIdentifier];
        } @catch (NSException *exception) {
            full740 = NO;
        }
        if (full740 && [entry.bundleIdentifier isEqualToString:@"com.apple.MobileSMS"] && DSFeature699On("msg742")) full740 = NO;   // 4.5.742 msg742
        if (full740) {
            DSFeature719MarkAction("picker740");
            DSDiagnosticsRecordFormat(@"SpringBoard: picker740 refused %@: it is open full screen or alive as a running full-screen scene (close it in the app switcher to stage it)",
                                      entry.bundleIdentifier);
            [self refreshPickerAvailability];
            return;
        }
    }
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


- (void)attachHostedAppForSlot:(NSInteger)slot {
    _kb723QuietUntil = CFAbsoluteTimeGetCurrent() + 0.6;   // 4.5.723: kb723 stays out (create / picker / teardown)
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
    _kb723QuietUntil = CFAbsoluteTimeGetCurrent() + 0.6;   // 4.5.723: kb723 stays out (create / picker / teardown)
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
    if ([_sceneHost isPhoneSize675]) [_sceneHost setPhoneSize675:NO keyboardTop:0.0 why:@"stage rotated"];
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
    CGRect iconFrame = [self openAppIconFrameOnLeft:onLeft lift:lift];
    icon.layer.cornerRadius = DSNative703IconRadius(CGRectGetHeight(iconFrame));   // 4.5.703: iOS icon corner (9 pt before)
    icon.layer.cornerCurve = kCACornerCurveContinuous;
    [UIView performWithoutAnimation:^{
        icon.frame = iconFrame;
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
    // 4.5.707 corner707: a stashed icon stacks above the parked ones in its
    // corner instead of drawing over them.
    CGFloat lift = 0.0;
    if (DSFeature699On("corner707")) {
        if (_primaryParked && _sceneHost.isHosting && _primaryMinimizedLeft == onLeft) lift += 42.0;
        if (_secondParked && _topSceneHost.isHosting && _secondMinimizedLeft == onLeft) lift += 42.0;
    }
    [self applyOpenAppIcon:icon host:host parked:YES onLeft:onLeft lift:lift];
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
    // 4.5.702 multi702: a card going out of sight stops any animation it still
    // has, so a minimised / parked card does not keep Core Animation busy.
    if (DSFeature699On("multi702")) {
        if (_primaryParked && _dragShell && !_dragShell.hidden && !objc_getAssociatedObject(_container, &kDSAnim698FlightKey)) {
            [self multi702Quiet:_container];
        }
        if (_secondParked && _topContainer && !_topContainer.hidden && !objc_getAssociatedObject(_topContainer, &kDSAnim698FlightKey)) {
            [self multi702Quiet:_topContainer];
        }
    }
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

// 4.5.698 anim698 (see DSAnim698FrameMeter above).
- (void)anim698RemoveFlightForCard:(DSStageContainerView *)card {
    if (!card) return;
    UIViewPropertyAnimator *spring702 = objc_getAssociatedObject(card, &kDSAnim702AnimatorKey);
    if (spring702) {
        objc_setAssociatedObject(card, &kDSAnim702AnimatorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self anim702Stop:spring702];
    }
    UIView *flight = objc_getAssociatedObject(card, &kDSAnim698FlightKey);
    if (!flight) return;
    objc_setAssociatedObject(card, &kDSAnim698FlightKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [flight.layer removeAllAnimations];
    [flight removeFromSuperview];
}

// YES = handled (layout ran without animation, the snapshot flies, completion
// runs at the end, or at once with finishFirst). NO = nothing was done; the
// caller runs the 697 path.
- (BOOL)anim698FlyCard:(DSStageContainerView *)card duration:(NSTimeInterval)duration options:(UIViewAnimationOptions)options
           finishFirst:(BOOL)finishFirst layout:(void (^)(void))layout completion:(void (^)(void))completion {
    if (!DSAnim698On() || !card || !layout) return NO;
    UIView *root = card.window;
    if (!root || card.hidden || card.alpha < 0.01) return NO;
    UIView *flight = nil;
    CGRect from = CGRectZero;
    @try {
        CGRect screen = [self screenBounds];
        CGRect park = [self cornerParkFrameForCard:card];
        // Only when the card ends off the screen (the corner park frame);
        // otherwise the real card would show next to the flying picture.
        if (CGRectIntersectsRect(CGRectInset(screen, 1.0, 1.0), park)) return NO;
        from = [card convertRect:card.bounds toView:root];
        if (!(CGRectGetWidth(from) >= 40.0 && CGRectGetHeight(from) >= 40.0) ||
            !CGRectIntersectsRect(screen, from)) return NO;
        flight = [card snapshotViewAfterScreenUpdates:NO];
    } @catch (NSException *exception) {
        flight = nil;
    }
    if (!flight) return NO;
    DSAnim698MarkTrying();
    [self anim698RemoveFlightForCard:card];
    flight.userInteractionEnabled = NO;
    flight.frame = from;
    [root addSubview:flight];
    objc_setAssociatedObject(card, &kDSAnim698FlightKey, flight, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [UIView performWithoutAnimation:^{
        layout();
        [card layoutIfNeeded];
    }];
    CGRect to = [card convertRect:card.bounds toView:root];
    if (!(CGRectGetWidth(to) >= 1.0 && CGRectGetHeight(to) >= 1.0) || !isfinite(to.origin.x) || !isfinite(to.origin.y)) {
        to = [self cornerParkFrameForCard:card];
    }
    void (^finish)(void) = completion;
    if (finishFirst && finish) {
        finish();
        finish = nil;
    }
    DSAnim698FrameMeter *meter = [DSAnim698FrameMeter new];
    meter.name = finishFirst ? @"minimise-flick698" : @"minimise698";
    [meter start];
    CGFloat sx = MAX(0.02, CGRectGetWidth(to) / CGRectGetWidth(from));
    CGFloat sy = MAX(0.02, CGRectGetHeight(to) / CGRectGetHeight(from));
    CGPoint target = CGPointMake(CGRectGetMidX(to), CGRectGetMidY(to));
    __weak DSStageContainerView *weakCard = card;
    [UIView animateWithDuration:duration
                          delay:0
                        options:options | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        flight.center = target;
        flight.transform = CGAffineTransformMakeScale(sx, sy);
    }
                     completion:^(BOOL finished) {
        (void)finished;
        [meter stop];
        [flight removeFromSuperview];
        DSStageContainerView *strongCard = weakCard;
        if (strongCard && objc_getAssociatedObject(strongCard, &kDSAnim698FlightKey) == flight) {
            objc_setAssociatedObject(strongCard, &kDSAnim698FlightKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (finish) finish();
    }];
    return YES;
}

// ---- 4.5.702 anim702 ---------------------------------------------------------
// Minimise: one snapshot of the card (with a 1 pt outline and a shadowPath
// shadow that move with it) springs into the corner icon - one
// UIViewPropertyAnimator, damping 0.86, 0.40 s (0.34 s for a flick), the
// release speed of the finger carried in. The corner radius goes from the
// card's to the icon's (9 pt) on the same spring and the app icon fades in on
// the snapshot over the second half, so the flight ends looking exactly like
// the corner icon; the real icon is then shown under it and the flight fades
// out (0.16 s): no pop. Restore after a corner pull: the same spring with the
// pull's speed; the still picture hands over to the live app with a short
// cross-fade. Open from the icon: the card (its scene stays at its size, only a
// transform) grows out of the icon. A new minimise / restore / drag stops a
// running one where it is on screen (its completion still runs, spam700 drops
// it if stale). Off: /var/mobile/.dynamicstage-anim702-off = 698/700 animation.
- (void)anim702Track:(UIViewPropertyAnimator *)animator {
    if (!animator) return;
    if (!_anim702Running) _anim702Running = [NSHashTable weakObjectsHashTable];
    [_anim702Running addObject:animator];
}

- (void)anim702Stop:(UIViewPropertyAnimator *)animator {
    if (!animator) return;
    [_anim702Running removeObject:animator];
    @try {
        if (animator.state == UIViewAnimatingStateActive) {
            [animator stopAnimation:NO];
            [animator finishAnimationAtPosition:UIViewAnimatingPositionCurrent];
        }
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: anim702 stop caught %@", exception.reason ?: exception.name);
    }
}

- (void)anim702StopRunning:(NSString *)why {
    if (_anim702Running.count == 0) return;
    NSArray<UIViewPropertyAnimator *> *all = _anim702Running.allObjects;
    [_anim702Running removeAllObjects];
    NSUInteger stopped = 0;
    for (UIViewPropertyAnimator *animator in all) {
        if (animator.state != UIViewAnimatingStateActive) continue;
        stopped += 1;
        [self anim702Stop:animator];
    }
    if (stopped) {
        DSDiagnosticsRecordFormat(@"SpringBoard: anim702 %lu running animation%@ stopped where %@ on screen (%@ asked)",
                                  (unsigned long)stopped, stopped == 1 ? @"" : @"s", stopped == 1 ? @"it was" : @"they were", why ?: @"?");
    }
}

- (BOOL)anim702FlyCard:(DSStageContainerView *)card finishFirst:(BOOL)finishFirst layout:(void (^)(void))layout completion:(void (^)(void))completion {
    if (!card || !layout || !DSFeature699On("anim702")) return NO;
    UIView *root = card.window;
    if (!root || card.hidden || card.alpha < 0.01) return NO;
    CGRect from = CGRectZero;
    UIView *picture = nil;
    @try {
        CGRect screen = [self screenBounds];
        CGRect park = [self cornerParkFrameForCard:card];
        if (CGRectIntersectsRect(CGRectInset(screen, 1.0, 1.0), park)) return NO;
        from = [card convertRect:card.bounds toView:root];
        // 4.5.733 flick733: start exactly where the card is drawn (no jump at release).
        if (finishFirst && !CGRectIsNull(_flick733From) && DSFeature699On("flick733") &&
            CGRectGetWidth(_flick733From) >= 40.0 && CGRectGetHeight(_flick733From) >= 40.0 &&
            fabs(CGRectGetWidth(_flick733From) - CGRectGetWidth(from)) < 2.0 && fabs(CGRectGetHeight(_flick733From) - CGRectGetHeight(from)) < 2.0) {
            from = _flick733From;
        }
        _flick733From = CGRectNull;
        if (!(CGRectGetWidth(from) >= 40.0 && CGRectGetHeight(from) >= 40.0) || !CGRectIntersectsRect(screen, from)) return NO;
        picture = [card snapshotViewAfterScreenUpdates:NO];
    } @catch (NSException *exception) {
        picture = nil;
    }
    if (!picture) return NO;
    DSFeature699MarkTrying("anim702");
    [self anim698RemoveFlightForCard:card];

    BOOL left = [self cardMinimizedOnLeft:card];
    BOOL sameCorner = _primaryParked && _secondParked && _primaryMinimizedLeft == _secondMinimizedLeft;
    CGRect icon = [self openAppIconFrameOnLeft:left lift:(card == _topContainer && sameCorner) ? 42.0 : 0.0];
    CGFloat scale = MAX(0.02, CGRectGetHeight(icon) / CGRectGetHeight(from));
    CGSize endSize = CGSizeMake(MAX(1.0, CGRectGetWidth(from) * scale), CGRectGetHeight(icon));
    CGRect endBounds = CGRectMake(0.0, 0.0, endSize.width, endSize.height);
    CGPoint endCenter = CGPointMake(CGRectGetMidX(icon), CGRectGetMidY(icon));
    CGPoint endMid = CGPointMake(endSize.width * 0.5, endSize.height * 0.5);
    CGFloat startRadius = MAX(card.cornerRadius, 12.0);

    UIView *flight = [[UIView alloc] initWithFrame:from];
    flight.userInteractionEnabled = NO;
    flight.autoresizesSubviews = NO;
    flight.backgroundColor = UIColor.clearColor;
    // Shadow: fixed shadowPath, scaled with the flight by its transform (no rebuilds).
    UIView *shadow = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, CGRectGetWidth(from), CGRectGetHeight(from))];
    shadow.userInteractionEnabled = NO;
    shadow.backgroundColor = UIColor.clearColor;
    shadow.layer.shadowColor = UIColor.blackColor.CGColor;
    shadow.layer.shadowOpacity = 0.22f;
    shadow.layer.shadowRadius = 16.0;
    shadow.layer.shadowOffset = CGSizeMake(0.0, 6.0);
    shadow.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:shadow.bounds cornerRadius:startRadius].CGPath;
    // Picture, clipped to a rounded rect with a 1 pt outline; only its bounds and radius move.
    UIView *clip = [[UIView alloc] initWithFrame:shadow.frame];
    clip.userInteractionEnabled = NO;
    clip.autoresizesSubviews = NO;
    clip.layer.cornerRadius = startRadius;
    clip.layer.cornerCurve = kCACornerCurveContinuous;
    clip.layer.masksToBounds = YES;
    clip.layer.borderWidth = 1.0;
    clip.layer.borderColor = DSNative703On() ? DSNative703OutlineColor() : [UIColor colorWithWhite:1.0 alpha:0.16].CGColor;
    picture.frame = clip.bounds;
    picture.autoresizingMask = UIViewAutoresizingNone;
    picture.userInteractionEnabled = NO;
    [clip addSubview:picture];
    UIImageView *iconPicture = nil;
    UIImage *iconImage = nil;
    @try {
        NSString *bundle = [self sceneHostForCard:card].bundleIdentifier;
        if (bundle.length) iconImage = [[DSAppLibrary sharedLibrary] iconForBundleIdentifier:bundle];
    } @catch (NSException *exception) {
        iconImage = nil;
    }
    if (iconImage) {
        iconPicture = [[UIImageView alloc] initWithImage:iconImage];
        iconPicture.contentMode = UIViewContentModeScaleAspectFill;
        iconPicture.frame = clip.bounds;
        iconPicture.alpha = 0.0;
        [clip addSubview:iconPicture];
    }
    [flight addSubview:shadow];
    [flight addSubview:clip];
    [root addSubview:flight];
    objc_setAssociatedObject(card, &kDSAnim698FlightKey, flight, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [UIView performWithoutAnimation:^{
        layout();
        [card layoutIfNeeded];
    }];
    void (^finish)(void) = completion;
    // 4.5.727 flick727: a flick's minimise bookkeeping (hide parked cards, key
    // window, app foreground, shelf) ran on the main thread BEFORE the flight
    // started: the lag at the start. With flick727 the flight starts first and
    // the bookkeeping runs on the next turn of the main loop.
    BOOL flick727 = finishFirst && finish && DSFeature699On("flick727");
    void (^deferred727)(void) = nil;
    UIImageView *cornerIcon727 = (card == _topContainer) ? _secondOpenAppIcon : _openAppIcon;
    if (flick727) {
        DSFeature719MarkAction("flick727");
        deferred727 = finish;
        finish = nil;
    } else if (finishFirst && finish) {
        finish();
        finish = nil;
        // The stage is already minimised: the corner icon waits for the flight.
        UIImageView *cornerIcon = (card == _topContainer) ? _secondOpenAppIcon : _openAppIcon;
        cornerIcon.alpha = 0.0;
    }

    CGPoint velocity = _anim702ReleaseVelocity;
    _anim702ReleaseVelocity = CGPointZero;
    CGFloat pathVelocity = DSAnim702PathVelocity(velocity, CGPointMake(CGRectGetMidX(from), CGRectGetMidY(from)), endCenter);
    NSTimeInterval flightDuration = finishFirst ? kDSAnim702FlickDuration : kDSAnim702MinimiseDuration;
    if (flick727) {
        // Duration from the release speed: the card covers the rest of the way at
        // about the finger's speed (0.18-0.34 s). The spring starts at the finger's
        // speed (release velocity / distance, up to 30 path lengths per second).
        CGFloat speed = hypot(velocity.x, velocity.y);
        CGFloat dist = hypot(endCenter.x - CGRectGetMidX(from), endCenter.y - CGRectGetMidY(from));
        if (speed > 1.0 && dist > 1.0) flightDuration = MAX(0.18, MIN(kDSAnim702FlickDuration, 1.6 * dist / speed));
        if (!isfinite(pathVelocity) || pathVelocity < 0.0) pathVelocity = 0.0;
        pathVelocity = MIN(pathVelocity, 30.0);
        if (DSFeature699On("flick733")) {
            // 4.5.733 flick733: 727's 0.18 s floor with a velocity up to 30 made a
            // fast flick land in ~3 frames (read as "not animated"). Like the
            // system's PiP / app-close: 0.28-0.42 s, damping 0.85, the finger's
            // speed as the spring's start (clamped to 0-6 path lengths per second).
            DSFeature719MarkAction("flick733");
            flightDuration = kDSAnim702FlickDuration;
            if (speed > 1.0 && dist > 1.0) flightDuration = MAX(0.28, MIN(0.42, 2.2 * dist / speed));
            pathVelocity = MAX(0.0, MIN(pathVelocity, 6.0));
        }
    }
    BOOL flick733 = flick727 && DSFeature699On("flick733");
    UIViewPropertyAnimator *spring = [[UIViewPropertyAnimator alloc] initWithDuration:flightDuration
                                                                     timingParameters:flick727
        ? [[UISpringTimingParameters alloc] initWithDampingRatio:(flick733 ? 0.85 : kDSAnim702Damping) initialVelocity:CGVectorMake(pathVelocity, pathVelocity)]
        : DSAnim702Spring(pathVelocity)];
    spring.interruptible = YES;
    if (DSNative703ReduceMotion()) {
        // 4.5.703: Reduce Motion - the card fades out where it is, no flight.
        spring = [[UIViewPropertyAnimator alloc] initWithDuration:0.22 curve:UIViewAnimationCurveEaseInOut animations:^{
            flight.alpha = 0.0;
        }];
    } else
    [spring addAnimations:^{
        flight.center = endCenter;
        flight.bounds = endBounds;
        clip.frame = endBounds;
        clip.layer.cornerRadius = DSNative703On() ? DSNative703IconRadius(CGRectGetHeight(icon)) : kDSAnim702IconRadius;
        picture.center = endMid;
        picture.transform = CGAffineTransformMakeScale(scale, scale);
        iconPicture.frame = endBounds;
        shadow.center = endMid;
        shadow.transform = CGAffineTransformMakeScale(scale, scale);
    }];
    if (iconPicture && !DSNative703ReduceMotion()) {
        [spring addAnimations:^{
            iconPicture.alpha = 1.0;
        } delayFactor:flick733 ? 0.6 : 0.45];   // 4.5.733: the icon crossfades in at the end
    }
    DSAnim698FrameMeter *meter = [DSAnim698FrameMeter new];
    meter.name = finishFirst ? @"minimise-flick702" : @"minimise702";
    [meter start];
    __weak __typeof(self) weakSelf = self;
    __weak DSStageContainerView *weakCard = card;
    __weak UIViewPropertyAnimator *weakSpring = spring;
    [spring addCompletion:^(UIViewAnimatingPosition position) {
        [meter stop];
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        DSStageContainerView *strongCard = weakCard;
        UIViewPropertyAnimator *done = weakSpring;
        if (strongSelf && done) [strongSelf->_anim702Running removeObject:done];
        if (strongCard) {
            if (objc_getAssociatedObject(strongCard, &kDSAnim698FlightKey) == flight) {
                objc_setAssociatedObject(strongCard, &kDSAnim698FlightKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            if (done && objc_getAssociatedObject(strongCard, &kDSAnim702AnimatorKey) == done) {
                objc_setAssociatedObject(strongCard, &kDSAnim702AnimatorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
        if (finish) finish();
        if (strongSelf && strongCard && [strongSelf cardIsParked:strongCard] && strongSelf->_state == DSStageStateMinimized) {
            [strongSelf updateOpenAppIcon];
        }
        // The real corner icon is under the flight now: fade the flight out over it.
        [UIView animateWithDuration:(position == UIViewAnimatingPositionEnd ? 0.16 : 0.12)
                              delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            flight.alpha = 0.0;
        }
                         completion:^(BOOL finished) {
            (void)finished;
            [flight removeFromSuperview];
        }];
    }];
    objc_setAssociatedObject(card, &kDSAnim702AnimatorKey, spring, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self anim702Track:spring];
    [spring startAnimation];
    if (deferred727) {
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                deferred727();
            } @catch (NSException *exception) {
                DSDiagnosticsRecordFormat(@"SpringBoard: flick727 caught %@", exception.reason ?: exception.name);
            }
            // The stage is minimised now: the corner icon waits for the flight.
            cornerIcon727.alpha = 0.0;
        });
    }
    return YES;
}

// Restore: the still picture stays over the live app for a moment and fades,
// instead of being pulled out on one frame.
- (void)anim702HandOffPictureForCard:(DSStageContainerView *)card {
    UIView *picture = [self rememberedPictureForCard:card];
    UIView *hostView = [self sceneHostForCard:card].hostView;
    if (hostView) hostView.alpha = 1.0;
    [self setRememberedPicture:nil forCard:card];
    if (!picture) return;
    if (!picture.superview || picture.hidden || picture.alpha < 0.01 || !card.window) {
        [picture removeFromSuperview];
        return;
    }
    DSAnim698FrameMeter *meter = [DSAnim698FrameMeter new];
    meter.name = @"handoff702";
    [meter start];
    [UIView animateWithDuration:0.18
                          delay:0.06
                        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        picture.alpha = 0.0;
    }
                     completion:^(BOOL finished) {
        (void)finished;
        [meter stop];
        [picture removeFromSuperview];
    }];
}

// Open from the corner icon (no pull): the card is laid out at its place at
// once and grows out of the icon by a transform on its shell - no resize, no
// scene write - while the icon fades into it.
- (BOOL)anim702ExpandPrimaryWithLayout:(void (^)(void))layout completion:(void (^)(void))completion {
    UIView *shell = _dragShell;
    UIView *root = shell.superview;
    if (!shell || !root || !layout || !_container) return NO;
    DSFeature699MarkTrying("anim702");
    [UIView performWithoutAnimation:^{
        layout();
        [root layoutIfNeeded];
    }];
    CGRect rest = [_container convertRect:_container.bounds toView:root];
    CGRect icon = [self openAppIconFrameOnLeft:_primaryMinimizedLeft lift:0.0];
    if (!(CGRectGetWidth(rest) >= 40.0 && CGRectGetHeight(rest) >= 40.0) || !CGAffineTransformIsIdentity(shell.transform)) {
        if (completion) completion();
        return YES;
    }
    CGFloat scale = MAX(0.02, CGRectGetHeight(icon) / CGRectGetHeight(rest));
    CGPoint shellCenter = shell.center;
    CGAffineTransform start = CGAffineTransformMakeTranslation(CGRectGetMidX(icon) - shellCenter.x, CGRectGetMidY(icon) - shellCenter.y);
    start = CGAffineTransformScale(start, scale, scale);
    if (DSNative703ReduceMotion()) start = CGAffineTransformIdentity;   // 4.5.703: Reduce Motion - cross-fade only
    UIImageView *cornerIcon = _openAppIcon;
    [UIView performWithoutAnimation:^{
        shell.transform = start;
        shell.alpha = 0.0;
        if (cornerIcon.image) cornerIcon.alpha = 1.0;
    }];
    UIViewPropertyAnimator *spring = [[UIViewPropertyAnimator alloc] initWithDuration:kDSAnim702RestoreDuration timingParameters:DSAnim702Spring(0.0)];
    spring.interruptible = YES;
    [spring addAnimations:^{
        shell.transform = CGAffineTransformIdentity;
    }];
    [UIView animateWithDuration:0.16 delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction animations:^{
        shell.alpha = 1.0;
        cornerIcon.alpha = 0.0;
    } completion:nil];
    DSAnim698FrameMeter *meter = [DSAnim698FrameMeter new];
    meter.name = @"expand702";
    [meter start];
    __weak __typeof(self) weakSelf = self;
    __weak UIViewPropertyAnimator *weakSpring = spring;
    [spring addCompletion:^(UIViewAnimatingPosition position) {
        [meter stop];
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        UIViewPropertyAnimator *done = weakSpring;
        if (strongSelf && done) [strongSelf->_anim702Running removeObject:done];
        void (^settle)(void) = ^{
            [UIView performWithoutAnimation:^{
                shell.transform = CGAffineTransformIdentity;
                if (!shell.hidden) shell.alpha = 1.0;
            }];
        };
        if (position == UIViewAnimatingPositionEnd) settle();
        else dispatch_async(dispatch_get_main_queue(), settle);  // interrupted: a minimise took the picture as it was on screen first
        if (completion) completion();
    }];
    [self anim702Track:spring];
    [spring startAnimation];
    return YES;
}

// ---- 4.5.702 drag702 ---------------------------------------------------------
// The finger owns the card's position while it is down: a spring / snap-back
// still moving the card is stopped where it is on screen and the grab is taken
// from there; every other position write for that card (layout passes, restore
// / open completions, heal / blackout ticks, keyboard lift and side slide) is
// held until the finger lifts. Off: /var/mobile/.dynamicstage-drag702-off.
- (void)drag702TakeCard:(DSStageContainerView *)card recognizer:(UIPanGestureRecognizer *)recognizer {
    [self drag702End];
    if (!card || !DSFeature699On("drag702")) return;
    DSFeature699MarkTrying("drag702");
    [self anim702StopRunning:@"drag"];
    NSMutableArray<CALayer *> *layers = [NSMutableArray arrayWithObject:card.layer];
    if (card == _container && _dragShell) [layers insertObject:_dragShell.layer atIndex:0];
    NSUInteger synced = 0;
    for (CALayer *layer in layers) {
        if (layer.animationKeys.count == 0) continue;
        CALayer *shown = layer.presentationLayer;
        if (!shown) continue;
        synced += 1;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        layer.position = shown.position;
        layer.bounds = shown.bounds;
        [CATransaction commit];
    }
    [self stopDragMotionForCard:card];
    if (synced) {
        DSDiagnosticsRecordFormat(@"SpringBoard: drag702 the card was still animating when grabbed: taken where it was on screen, animation stopped");
    }
    _drag702Card = card;
    _drag702Recognizer = recognizer;
    _drag702Held = 0;
}

- (void)drag702FreezeCard:(DSStageContainerView *)card {
    if (card && _drag702Card == card) card.drag702Frozen = YES;
}

- (BOOL)drag702Holds:(DSStageContainerView *)card {
    if (_drag702Writing || !card || card != _drag702Card) return NO;
    UIPanGestureRecognizer *recognizer = _drag702Recognizer;
    UIGestureRecognizerState state = recognizer ? recognizer.state : UIGestureRecognizerStatePossible;
    if (!_stageDragActive || (state != UIGestureRecognizerStateBegan && state != UIGestureRecognizerStateChanged)) {
        [self drag702End];
        return NO;
    }
    if (!DSFeature699On("drag702")) return NO;
    _drag702Held += 1;
    return YES;
}

- (void)drag702End {
    DSStageContainerView *card = _drag702Card;
    _drag702Card = nil;
    _drag702Recognizer = nil;
    _container.drag702Frozen = NO;
    _topContainer.drag702Frozen = NO;
    _floatContainer.drag702Frozen = NO;
    if (card && _drag702Held > 0) {
        DSDiagnosticsRecordFormat(@"SpringBoard: drag702 held %lu position write%@ from other code while the finger was down (the card stayed under the finger)",
                                  (unsigned long)_drag702Held, _drag702Held == 1 ? @"" : @"s");
    }
    _drag702Held = 0;
}

// ---- 4.5.702 kbmin702 --------------------------------------------------------
// A keyboard that belongs to no staged app (Spotlight, a SpringBoard alert
// field, the full-screen app behind the stage) comes up: the staged card(s) on
// screen are minimised the normal way (spam700-numbered minimise). The owner is
// the arbiter's source bundle; a staged app's own keyboard (hosted, Beeper's
// in-process keys, Messages, the stand-in field, the picker search) never
// minimises. 0.3 s debounce, re-checked. Off: /var/mobile/.dynamicstage-kbmin702-off.
- (BOOL)kbmin702SourceIsStaged:(NSString *)source {
    if ([self isHostingBundleIdentifier:source]) return YES;
    for (DSSceneHost *host in @[ _sceneHost ?: (id)NSNull.null, _topSceneHost ?: (id)NSNull.null, _floatSceneHost ?: (id)NSNull.null ]) {
        if (![host isKindOfClass:DSSceneHost.class]) continue;
        NSString *bundle = host.bundleIdentifier;
        if (bundle.length && ([source isEqualToString:bundle] || [source hasPrefix:[bundle stringByAppendingString:@"."]])) return YES;
    }
    return NO;
}

- (NSString *)kbmin702Refusal:(NSString *)source {
    if (DSPS696DeviceLocked() || DSBattery701ScreenLocked()) return @"locked";
    if (_state != DSStageStateOverlay || _overlaySettling) return @"stage not settled on screen";
    if (_stageDragActive || DSStageDragSettlingFast(0.6) || _cornerRestoreCard) return @"drag";
    if ([DSSceneHost homeGestureIsActive] || [DSSceneHost systemTransitionBusy]) return @"system gesture";
    if (DSPhoneCallIsActive()) return @"call";
    if (_searchSlot >= 0 || _stagedKeyboardSlot >= 0 || [self stagedKeyboardFieldIsEditing]) return @"the stage's own keyboard";
    if (source.length == 0 || [source isEqualToString:@"?"]) return @"unknown owner";
    if ([self kbmin702SourceIsStaged:source]) return @"a staged app's own keyboard";
    if (DSType755On() && [self type755TypingOwner]) return @"a staged app is typing (type755)";
    // Out-of-process pieces of an app (photo picker, share / mail / Safari view
    // services, web content) type for the app that showed them.
    for (NSString *part in @[ @"ViewService", @"Picker", @"com.apple.WebKit", @"Extension", @"extension" ]) {
        if ([source rangeOfString:part].location != NSNotFound) return @"a remote view inside an app";
    }
    if ([self phoneSize683ActiveForBundle:source] || [DSPS683SessionBundle isEqualToString:source]) return @"683 session";
    // 4.5.704: the stage's own picker (its search field is SpringBoard's keyboard;
    // the search slot is set a moment after the field asks) and a typing focus
    // inside a stage (focus704) never minimise.
    if ([source isEqualToString:@"SpringBoard"] && ([self pickerVisibleOnSlot:0] || [self pickerVisibleOnSlot:1])) {
        return @"the stage's own picker";
    }
    // 4.5.720: the arbiter names SpringBoard "com.apple.springboard", so the
    // line above never matched the picker's own keyboard.
    if ([source isEqualToString:@"com.apple.springboard"] && ([self pickerVisibleOnSlot:0] || [self pickerVisibleOnSlot:1]) &&
        [self kb720On]) {
        [self kb720Act:@"kbmin702 ignores the picker's own keyboard"];
        return @"the stage's own picker (720)";
    }
    BOOL visible = (_sceneHost.isHosting && !_primaryParked && _container && !_container.hidden) ||
                   (_topSceneHost.isHosting && !_secondParked && _topContainer && !_topContainer.hidden) ||
                   (_floatSceneHost.isHosting && _floatActive && _floatContainer && !_floatContainer.hidden);
    if (!visible) return @"no staged app on screen";
    return nil;
}

- (void)kbmin702Note:(BOOL)onScreen frame:(CGRect)frame source:(NSString *)source {
    if (!onScreen) {
        _kbmin702Source = nil;
        return;
    }
    if (CGRectGetHeight(frame) < 150.0 || ![source isKindOfClass:NSString.class] || source.length == 0) return;
    if (!DSFeature699On("kbmin702")) return;
    _kbmin702Source = [source copy];
    if ([self kbmin702Refusal:source]) return;
    NSUInteger gen = ++_kbmin702Gen;
    NSString *owner = [source copy];
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || gen != strongSelf->_kbmin702Gen || ![strongSelf->_kbmin702Source isEqualToString:owner]) return;
        @try {
            NSString *refusal = [strongSelf kbmin702Refusal:owner];
            if (refusal) return;
            [strongSelf kbmin702Minimise:owner];
        } @catch (NSException *exception) {
            DSDiagnosticsRecordFormat(@"SpringBoard: kbmin702 caught %@", exception.reason ?: exception.name);
        }
    });
}

- (void)kbmin702Minimise:(NSString *)source {
    DSFeature699MarkTrying("kbmin702");
    [self minimiseVisibleStages:[NSString stringWithFormat:@"kbmin702 a keyboard for %@ came up (not a staged app's)", source ?: @"?"]];
}

// 4.5.707: the one "put the visible stages away" path (kbmin702, outside707).
// One card goes to its corner (corner707 picks a free one), more than one card
// takes the home tuck (opposite corners). Both are spam700-guarded.
- (void)minimiseVisibleStages:(NSString *)why {
    [self kb744DismissForCard:nil why:@"minimiseVisibleStages"];   // 4.5.744 kbdrag744
    BOOL primaryLive = _sceneHost.isHosting && !_primaryParked && _container && !_container.hidden;
    BOOL secondLive = _topSceneHost.isHosting && !_secondParked && _topContainer && !_topContainer.hidden;
    BOOL single = primaryLive && !secondLive && !_splitMode && !_floatActive && _stackSlotCount <= 1;
    DSDiagnosticsRecordFormat(@"SpringBoard: %@: %@", why ?: @"?",
                              single ? @"the staged card is minimised to its corner" : @"the staged cards are minimised (home tuck)");
    // 4.5.729 slide728: the outside-tap minimise slides the cards out their
    // nearest side with kb707's own side slide (sideParkDistanceForCard: +
    // setSideOffset: in kb707Animate), then the normal minimise runs without
    // its flight: same parked state, corner icon and corner pull as always.
    // Only outside707/726 calls land here with slide728 on. Off: -slide728-off.
    BOOL outside = [why hasPrefix:@"outside707"];
    if (outside && single && !_splitMode && !_floatActive && DSFeature699On("slide728")) {
        DSFeature719MarkAction("slide728");
        NSMutableArray<DSStageContainerView *> *cards = [NSMutableArray array];
        if (primaryLive) [cards addObject:_container];
        if (secondLive) [cards addObject:_topContainer];
        CGFloat midX = CGRectGetMidX([self screenBounds]);
        NSMutableArray<NSNumber *> *sides = [NSMutableArray array];
        for (DSStageContainerView *card in cards) {
            CGRect seen = (card == _container) ? [self primaryCardFrameInRoot] : [self frameWithoutKeyboardShift:card];
            CGFloat side = [self sideParkDistanceForCard:card goLeft:CGRectGetMidX(seen) <= midX + 0.5];
            [sides addObject:@(isfinite(side) ? side : 0.0)];
        }
        NSUInteger gen = _spam700Gen;
        [self kb707Animate:^{
            for (NSUInteger i = 0; i < cards.count; i++) {
                [cards[i] setLiftOffset:0.0];
                [cards[i] setSideOffset:sides[i].doubleValue];
            }
        }];
        __weak __typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kDSAnim702MinimiseDuration + 0.02) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            @try {
                BOOL stale = gen != strongSelf->_spam700Gen || strongSelf->_state != DSStageStateOverlay;
                void (^zero)(void) = ^{
                    [UIView performWithoutAnimation:^{
                        for (DSStageContainerView *card in cards) [card setSideOffset:0.0];
                    }];
                };
                if (stale) zero();
                if (stale) {
                    // Something else moved the stage meanwhile: cards back where they were.
                    DSDiagnosticsRecord(@"SpringBoard: slide728 the stage changed during the slide: cards put back, no minimise");
                    [strongSelf layoutAllStackSlotsForState:strongSelf->_state];
                    return;
                }
                DSDiagnosticsRecordFormat(@"SpringBoard: slide728 %lu card(s) slid out the side, then minimised to the corner (no flight)", (unsigned long)cards.count);
                if (single) {
                    [strongSelf minimizeDraggedCard:strongSelf->_container fromHalf:[strongSelf halfForContainer:strongSelf->_container]
                                             onLeft:strongSelf->_primaryMinimizedLeft animated:NO];
                } else {
                    [strongSelf tuckOpenStageAwayForHomeGesture];
                }
                // Offsets cleared only now: the cards are already parked, so the
                // minimise found them off-screen and ran no flight.
                zero();
            } @catch (NSException *exception) {
                DSDiagnosticsRecordFormat(@"SpringBoard: slide728 caught %@", exception.reason ?: exception.name);
            }
        });
        return;
    }
    if (single) {
        [self minimizeDraggedCard:_container fromHalf:[self halfForContainer:_container] onLeft:_primaryMinimizedLeft animated:YES];
    } else {
        [self tuckOpenStageAwayForHomeGesture];
    }
}

// ---- 4.5.707 outside707 ------------------------------------------------------
// "Using the home screen or an app outside the stages should minimise them."
// The stage window already decides every touch (shouldWindowCaptureTouchAtPoint:)
// and passes the ones outside the cards to the home screen / app behind; that
// decision now also reports the point (our window, no new hook). A touch well
// clear of the cards (24 pt), of the screen edges (status / Control Centre band
// on top, the home bar and the corner pull / icon squares at the bottom, 16 pt
// sides for back swipes) puts the visible stages away through
// minimiseVisibleStages: - after 0.18 s, and only if nothing else started in
// that time. Never while a finger drags a card, a keyboard is up, a minimise /
// restore is running or just ran (0.8 s), a call is up, the phone is locked,
// or the app switcher / home gesture / an edge pull is running.
// Off: /var/mobile/.dynamicstage-outside707-off (crash latch).
// ---- 4.5.726 restore726 -------------------------------------------------------
// "A staged app became permanently minimised." A minimised card comes back
// only through a corner pull that starts in the bottom corner on the side the
// card was parked to (parkedCardForCornerPoint). Every stage tick checks that
// this still works: a corner pull SpringBoard never ended (the pull turned into
// a home swipe) blocks every later pull and the heal / outside checks, so it
// is released; the remembered corner side follows the corner the card is
// actually drawn in; a stale pull block is cleared. Off:
// /var/mobile/.dynamicstage-restore726-off (per-action crash latch).
// ---- 4.5.727 stuck727 ---------------------------------------------------------
// One resting frame per card: placedFrameForCard:state: (the frame layout gives
// it). With no finger down, nothing animating and no keyboard on screen, every
// visible card in a single / two-stage layout must sit at it with no keyboard
// offset and no transform. A card that is off for 0.5 s is put there. This check
// ignores the heal700 / kb720 / drag706 / sync725 waits, so none of them can
// hold a card out of place for more than about 1 s after it is noticed.
// Off: /var/mobile/.dynamicstage-stuck727-off (per-action crash latch).
- (NSString *)stuck727BusyReason {
    if (_state != DSStageStateOverlay) return @"no stage";
    if (DSPS696DeviceLocked() || _splitMode || _floatActive || _expandedCard || _searchSlot >= 0) return @"layout";
    if (_stageDragActive || _systemPull || _state == DSStageStateTracking || [self drag706FingerDown]) return @"finger";
    if (_overlaySettling || _spam700MinimisePending || _spam700DeferredFinish || _anim702Running.count > 0) return @"animating";
    if ([DSSceneHost homeGestureIsActive] || [DSSceneHost systemTransitionBusy] || [DSSceneHost systemEdgePullIsActive] ||
        [DSSceneHost sceneSettingsUpdateDepth] > 0 || DSCallStepAsideActive()) return @"system";
    CGRect keys = DSVisibleKeyboardFrameOnScreen();
    if (!CGRectIsNull(keys) && !CGRectIsEmpty(keys) && CGRectGetHeight(keys) > 40.0 &&
        CGRectGetMinY(keys) < CGRectGetHeight([self screenBounds]) - 1.0) return @"keyboard";
    NSArray *views = @[ _container ?: (id)NSNull.null, _topContainer ?: (id)NSNull.null, _dragShell ?: (id)NSNull.null, _topRim ?: (id)NSNull.null ];
    for (id v in views) {
        if (v == (id)NSNull.null) continue;
        if (((UIView *)v).layer.animationKeys.count > 0) return @"animating";
    }
    return nil;
}

- (NSString *)stuck727ProblemForCard:(DSStageContainerView *)card want:(CGRect *)wantOut have:(CGRect *)haveOut {
    if (!card || card.hidden || card.alpha < 0.05 || !card.window || [self cardIsParked:card]) return nil;
    if (card == _topContainer && _stackSlotCount < kDSMaxStackSlots) return nil;
    if ([self drag702Holds:card]) return nil;
    CGRect want = [self placedFrameForCard:card state:_state];
    CGRect have = (card == _container) ? [self primaryCardFrameInRoot] : [self frameWithoutKeyboardShift:card];
    if (wantOut) *wantOut = want;
    if (haveOut) *haveOut = [self visualScreenFrameForCard:card];
    if (CGRectIsEmpty(want) || !isfinite(want.origin.x) || !isfinite(want.origin.y)) return nil;
    if (fabs(card.liftOffset) > 0.5 || fabs(card.sideOffset) > 0.5) return @"a keyboard offset with no keyboard on screen";
    if (!CGAffineTransformIsIdentity(card.transform)) return @"a transform left on the card";
    if (fabs(CGRectGetMinX(want) - CGRectGetMinX(have)) > 1.0 || fabs(CGRectGetMinY(want) - CGRectGetMinY(have)) > 1.0 ||
        fabs(CGRectGetWidth(want) - CGRectGetWidth(have)) > 1.0 || fabs(CGRectGetHeight(want) - CGRectGetHeight(have)) > 1.0) {
        return @"its frame is not its resting frame";
    }
    return nil;
}

- (void)stuck727Check:(BOOL)confirm {
    if (DSCall733HandsOff(@"stuck727")) return;   // 4.5.734 call733
    if (!_activated || !DSFeature699On("stuck727")) return;
    if ([self stuck727BusyReason]) {
        _stuck727SeenAt[0] = _stuck727SeenAt[1] = 0.0;
        return;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL pending = NO;
    for (NSInteger i = 0; i < 2; i++) {
        DSStageContainerView *card = i == 0 ? _container : _topContainer;
        CGRect want = CGRectZero, have = CGRectZero;
        NSString *why = [self stuck727ProblemForCard:card want:&want have:&have];
        if (!why) {
            _stuck727SeenAt[i] = 0.0;
            _stuck750SeenAt[i] = 0.0;
            continue;
        }
        if (_stuck727SeenAt[i] <= 0.0 || now < _stuck727SeenAt[i]) {
            _stuck727SeenAt[i] = now;
            pending = YES;
            continue;
        }
        if (now - _stuck727SeenAt[i] < 0.45) {
            pending = YES;
            continue;
        }
        // 4.5.750 pos750: stuck727 is a backstop. It says so loudly at once and
        // only snaps the card (the safety) if it is still off after 2 s.
        if ([self core750On] && DS809Latched("pos750")) {
            if (_stuck750SeenAt[i] <= 0.0 || now < _stuck750SeenAt[i]) {
                _stuck750SeenAt[i] = now;
                DSDiagnosticsRecordFormat(@"SpringBoard: STUCK750 BACKSTOP %@ card off its resting frame (%@): a move bypassed the one path; safety snap in 2 s if it stays",
                                          i == 0 ? @"bottom" : @"top", why);
            }
            if (now - _stuck750SeenAt[i] < 2.0) {
                pending = YES;
                continue;
            }
            _stuck750SeenAt[i] = 0.0;
        }
        _stuck727SeenAt[i] = 0.0;
        DSFeature719MarkAction("stuck727");
        NSString *bundle = [self sceneHostForCard:card].bundleIdentifier ?: @"picker";
        NSString *line = [NSString stringWithFormat:@"stuck727 forced %@ from %@ to %@ because %@ (lift %.0f, side %.0f)",
                          bundle, NSStringFromCGRect(have), NSStringFromCGRect(want), why, card.liftOffset, card.sideOffset];
        DSDiagnosticsRecordFormat(@"SpringBoard: %@%@", line, [self core747On] ? @" [core747 backstop fired: a move bypassed the one path]" : @"");
        [self ev766Note:@"stuck727" card:card extra:why];
        if ([self core747On]) [self move747Cancel:@"stuck727 backstop"];
        // 4.5.745 loop745: the lift that was undone must not come back from the
        // same stale keyboard state (Depd 12:54:10 / 12:54:13).
        if (DSFeature699On("loop745") && [why hasPrefix:@"a keyboard offset"]) {
            DSFeature719MarkAction("loop745");
            _loop745Block = YES;
            _kb707Active = NO;
            _kb707Owner = nil;
            _keyboardFrame = CGRectZero;
            _focus704KeysBundle = nil;
            _keyboardLiftOwner = nil;
            for (NSInteger s745 = 0; s745 < 2; s745++) DSLiftSlotAt(s745)->keyboardFrozen = NO;
        }
        DSStageContainerView *target = card;
        [self animateSpring:^{
            [target setLiftOffset:0.0];
            [target setSideOffset:0.0];
            target.transform = CGAffineTransformIdentity;
            [self placeCard:target atFrame:want];
        } completion:nil];
    }
    (void)confirm;
    if (pending && !_stuck727Queued) {
        _stuck727Queued = YES;
        __weak __typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_stuck727Queued = NO;
            @try {
                [strongSelf stuck727Check:YES];
            } @catch (NSException *exception) {
                DSDiagnosticsRecordFormat(@"SpringBoard: stuck727 caught %@", exception.reason ?: exception.name);
            }
        });
    }
}

- (void)restore726Say:(NSString *)line {
    if (!_restore726SaidAt) _restore726SaidAt = [NSMutableDictionary dictionary];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSNumber *last = _restore726SaidAt[line];
    if (last && now - last.doubleValue < 30.0 && now >= last.doubleValue) return;
    _restore726SaidAt[line] = @(now);
    DSDiagnosticsRecordFormat(@"SpringBoard: restore726 %@", line);
}

- (void)restore726Check {
    if (!_activated || !DSFeature699On("restore726")) return;
    if (!_primaryParked && !_secondParked && !_systemPull) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    // 1. A corner pull that never ended.
    if (_systemPull) {
        UIGestureRecognizerState st = _systemPull.state;
        BOOL live = st == UIGestureRecognizerStateBegan || st == UIGestureRecognizerStateChanged;
        BOOL old = now - _restore726PullAt > 4.0 || now < _restore726PullAt;
        if ((!live && now - _restore726PullAt > 1.0) || (old && ![self drag706FingerDown])) {
            DSFeature719MarkAction("restore726");
            [self releaseSystemPull];
            _cornerRestoreCard = nil;
            if (_state == DSStageStateTracking) [self cancelTracking];
            [self restore726Say:@"released a corner pull that never ended (it was blocking every later restore)"];
        }
    }
    // 2. A pull block far in the future.
    if (_ignoreSystemPullUntil > now + 2.0) {
        DSFeature719MarkAction("restore726");
        _ignoreSystemPullUntil = 0;
        [self restore726Say:@"cleared a stale corner-pull block"];
    }
    if (_systemPull || _stageDragActive || _state == DSStageStateTracking || [DSSceneHost homeGestureIsActive] ||
        [DSSceneHost systemTransitionBusy] || _spam700MinimisePending || _spam700DeferredFinish || _cornerRestoreCard) return;
    // 3. The remembered side must be the corner the card is drawn in.
    CGFloat midScreen = CGRectGetMidX([self screenBounds]);
    for (NSInteger i = 0; i < 2; i++) {
        DSStageContainerView *card = i == 0 ? _container : _topContainer;
        BOOL parked = i == 0 ? _primaryParked : _secondParked;
        if (!card || !parked || card.hidden || card.alpha < 0.05 || !card.window) continue;
        CGRect seen = [self visualScreenFrameForCard:card];
        if (CGRectIsEmpty(seen)) continue;   // 4.5.727: minimised cards are parked off-screen by design
        BOOL drawnLeft = CGRectGetMidX(seen) < midScreen;
        BOOL remembered = i == 0 ? _primaryMinimizedLeft : _secondMinimizedLeft;
        if (drawnLeft == remembered) continue;
        DSFeature719MarkAction("restore726");
        if (i == 0) _primaryMinimizedLeft = drawnLeft;
        else _secondMinimizedLeft = drawnLeft;
        [self restore726Say:[NSString stringWithFormat:@"%@ card is drawn in the %@ corner but the pull expected the other one: fixed",
                             i == 0 ? @"primary" : @"second", drawnLeft ? @"left" : @"right"]];
    }
}

- (BOOL)outside707Blocked:(CGPoint)point why:(NSString **)why {
    NSString *reason = nil;
    CGRect screen = [self screenBounds];
    CGFloat w = CGRectGetWidth(screen), h = CGRectGetHeight(screen);
    CGRect keysNow = DSVisibleKeyboardFrameOnScreen();
    BOOL keysUp = !CGRectIsEmpty(_keyboardFrame) || (!CGRectIsNull(keysNow) && CGRectGetHeight(keysNow) >= 100.0) ||
                  [self springBoardIsDrawingKeyboard] || _searchSlot >= 0;
    if (_state != DSStageStateOverlay || !_container) reason = @"state";
    else if (DSPS696DeviceLocked() || DSBattery701ScreenLocked()) reason = @"locked";
    else if (DSCallStepAsideActive() || [DSStageWindow callAside]) reason = @"call";
    else if (_stageDragActive || _drag702Card || _systemPull || DSStageDragSettlingFast(0.6)) reason = @"drag";
    else if (keysUp) reason = @"keyboard";
    else if (_overlaySettling || _spam700MinimisePending || _spam700DeferredFinish || _cornerRestoreCard ||
             DSStageRestoreSettlingFast(0.8) || CFAbsoluteTimeGetCurrent() < _outside707QuietUntil) reason = @"settling";
    else if ([DSSceneHost homeGestureIsActive] || [DSSceneHost systemTransitionBusy] || [DSSceneHost systemEdgePullIsActive]) reason = @"system gesture";
    else if (point.y < 44.0 || point.y > h - 40.0 || point.x < 16.0 || point.x > w - 16.0) reason = @"edge";
    else if (point.y > h - 108.0 && (point.x < 86.0 || point.x > w - 86.0)) reason = @"corner";
    else if (![self isStageVisible]) reason = @"not visible";
    else {
        NSMutableArray<DSStageContainerView *> *cards = [NSMutableArray array];
        if (_container && !_container.hidden && ![self cardIsParked:_container]) [cards addObject:_container];
        if (_topContainer && !_topContainer.hidden && _stackSlotCount >= kDSMaxStackSlots && ![self cardIsParked:_topContainer]) [cards addObject:_topContainer];
        if (_floatActive && _floatContainer && !_floatContainer.hidden) [cards addObject:_floatContainer];
        BOOL appLive = (_sceneHost.isHosting && !_primaryParked) || (_topSceneHost.isHosting && !_secondParked);
        if (cards.count == 0) reason = @"no card";
        else if (!appLive) reason = @"picker only";   // an open picker is left alone
        for (DSStageContainerView *card in cards) {
            if (CGRectContainsPoint(CGRectInset([self visualScreenFrameForCard:card], -(kDSStageOuterDragBand + 24.0), -(kDSStageOuterDragBand + 24.0)), point)) {
                reason = @"near a card";
                break;
            }
        }
    }
    // 4.5.726 outside726: stricter. Not in the bottom 140 pt (where the home
    // swipe starts: the 4.5.724 log minimised Beeper on a touch at y=853),
    // not within 56 pt of a card, not within 1 s of a touch on a card or of a
    // stage being opened / a picker shown / a card closed.
    if (!reason && DSFeature699On("outside726")) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (point.y > h - 140.0) reason = @"bottom band (726)";
        else if (now - _outside726CardTouchAt < 1.0 && now >= _outside726CardTouchAt) reason = @"card touched < 1 s ago (726)";
        else if (_kb723QuietUntil > 0.0 && now < _kb723QuietUntil + 0.4) reason = @"stage just opened / closed (726)";
        else {
            NSArray *near = @[ _container ?: (id)NSNull.null, _topContainer ?: (id)NSNull.null,
                               (_floatActive && _floatContainer) ? _floatContainer : (id)NSNull.null ];
            for (id item in near) {
                if (item == (id)NSNull.null) continue;
                DSStageContainerView *card = item;
                if (card.hidden || [self cardIsParked:card]) continue;
                if (CGRectContainsPoint(CGRectInset([self visualScreenFrameForCard:card], -(kDSStageOuterDragBand + 56.0), -(kDSStageOuterDragBand + 56.0)), point)) {
                    reason = @"near a card (726)";
                    break;
                }
            }
        }
        if (reason) DSFeature719MarkAction("outside726");
    }
    if (why) *why = reason;
    return reason != nil;
}

- (void)outside707NoteTouchAt:(CGPoint)point {
    if (DSCall733HandsOff(@"outside707")) return;   // 4.5.734 call733
    if (_state != DSStageStateOverlay || _outside707Queued) {
        if (DSGest770On()) {   // 4.5.770 gest770
            static CFAbsoluteTime last770 = 0;
            CFAbsoluteTime n770 = CFAbsoluteTimeGetCurrent();
            if (n770 - last770 > 0.3) { last770 = n770; DSDiagnosticsRecordFormat(@"SpringBoard: gest770 tap outside the cards at %.0f,%.0f: nothing done (%@)", point.x, point.y, _outside707Queued ? @"a check is already queued" : @"stage not open"); }
        }
        return;
    }   // 4.5.712: state first, no switch read with no stage open
    if (!DSFeature699On("outside707")) return;
    // 4.5.712: crash latch at first use (was: only just before a minimise).
    if (!_outside712Marked) {
        _outside712Marked = YES;
        DSFeature699MarkTrying("outside707");
    }
    NSString *why = nil;
    if ([self outside707Blocked:point why:&why]) {
        if (DSGest770On()) DSDiagnosticsRecordFormat(@"SpringBoard: gest770 tap outside the cards at %.0f,%.0f: nothing done (%@)", point.x, point.y, why ?: @"blocked");
        return;
    }
    if (DSGest770On()) DSDiagnosticsRecordFormat(@"SpringBoard: gest770 tap outside the cards at %.0f,%.0f: minimise queued (0.45 s re-check)", point.x, point.y);
    _outside707Queued = YES;
    _outside707Point = point;
    NSUInteger gen = _spam700Gen;
    __weak __typeof(self) weakSelf = self;
    // 4.5.726: 0.45 s (was 0.18): a swipe / drag has started by then and the
    // re-check below refuses it (system gesture, card touched, settling).
    NSTimeInterval wait726 = DSFeature699On("outside726") ? 0.45 : 0.18;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait726 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_outside707Queued = NO;
        @try {
            NSString *later = nil;
            if (gen != strongSelf->_spam700Gen) return;   // something else moved the stage meanwhile
            if ([strongSelf outside707Blocked:strongSelf->_outside707Point why:&later]) return;
            [strongSelf minimiseVisibleStages:[NSString stringWithFormat:@"outside707 the home screen / app behind was used at %.0f,%.0f",
                                               strongSelf->_outside707Point.x, strongSelf->_outside707Point.y]];
        } @catch (NSException *exception) {
            DSDiagnosticsRecordFormat(@"SpringBoard: outside707 caught %@", exception.reason ?: exception.name);
        }
    });
}

// ---- 4.5.702 multi702 --------------------------------------------------------
- (void)multi702Quiet:(DSStageContainerView *)card {
    if (!card || [UIView inheritedAnimationDuration] > 0.0) return;
    BOOL busy = card.layer.animationKeys.count > 0 || (card == _container && _dragShell.layer.animationKeys.count > 0);
    if (!busy) return;
    DSFeature699MarkTrying("multi702");
    [self stopDragMotionForCard:card];
}

// ---- 4.5.704 focus704 --------------------------------------------------------
// Two stages open, typing in one of them (the stage's own app search field or
// stand-in text field, or a staged app's text field): that card comes to the
// front and the other card steps aside to its nearest screen edge, with the
// 702 system spring. When the keyboard goes away the other card springs back
// and the original stacking order returns.
//
// Why the typing card ended up behind (4.5.703 and before): the picker search
// path in noteKeyboardFrame lifted the searching card with a plain
// setLiftOffset: and never called bringCardAboveItsPartner: (only liftCardBy:
// does), and its side park only knows split mode (bottomSplitIsTypingInCard:
// needs _splitMode), so with two stacked stages a search in the LOWER card
// rose over the upper card's half underneath it - picker and field behind the
// other stage. Beeper's own lift (handleKeyboardForBundle, 684) moves its card
// the same way, without a z-order raise or a companion move. The picker is
// inside its card (contentView), so it is the card's z-order that matters,
// not the window level.
//
// Ownership comes from the 697 logic (the hosted keyboard source, the search
// slot, the stand-in slot, the lift slot). Nothing moves while a finger is down
// (drag702), while a minimise / restore is finishing (spam700) or a corner
// pull is running; it is re-checked shortly after. Off:
// /var/mobile/.dynamicstage-focus704-off (crash latch focus704-trying/-crashed).
- (BOOL)focus704CardLive:(DSStageContainerView *)card {
    return card && card.superview && !card.hidden && card.alpha > 0.01 && ![self cardIsParked:card];
}

- (void)focus704NoteKeys:(BOOL)onScreen source:(NSString *)source {
    if (![source isKindOfClass:NSString.class] || source.length == 0) return;
    if (![self isHostingBundleIdentifier:source]) return;
    if (onScreen && DSFeature699On("ghost745") && _ghost745HideAt > 0.0 &&
        CFAbsoluteTimeGetCurrent() - _ghost745HideAt < 0.3 && _ghost745ShowAt < _ghost745HideAt) onScreen = NO;   // 4.5.745
    if (onScreen) {
        _focus704KeysBundle = [source copy];
    } else if ([_focus704KeysBundle isEqualToString:source]) {
        _focus704KeysBundle = nil;
    }
    [self focus704Schedule];
}

- (void)focus704Schedule {
    if ([self kb707Owns]) {   // 4.5.707: kb707 replaces the 704 step-aside
        [self kb707Schedule];
        return;
    }
    // 4.5.715: the 704 step-aside is gone. Outside the two-stage overlay this
    // only re-checks for a kb707 lift left behind (what 4.5.714 did here with
    // kb707 on: focus704 never owned a card, so its evaluate only restored).
    if (_stackSlotCount < kDSMaxStackSlots) return;
    NSUInteger gen = ++_focus704Gen;
    __weak __typeof(self) weakSelf = self;
    for (NSNumber *after in @[ @0.05, @0.40 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(after.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || gen != strongSelf->_focus704Gen) return;
            @try {
                [strongSelf focus704Evaluate:@"keys"];
            } @catch (NSException *exception) {
                DSDiagnosticsRecordFormat(@"SpringBoard: focus704 caught %@", exception.reason ?: exception.name);
            }
        });
    }
}

- (DSStageContainerView *)focus704TypingCard:(NSString **)what {
    CGRect keys = _keyboardFrame;
    BOOL keysUp = !CGRectIsEmpty(keys) && CGRectGetHeight(keys) >= 150.0;
    BOOL drawn = keysUp || [self springBoardIsDrawingKeyboard];
    @try {
        if (!drawn && (_searchSlot == 0 || _searchSlot == 1 || _stagedKeyboardSlot == 0 || _stagedKeyboardSlot == 1) && [self kb723Ready]) {
            // 4.5.723: SpringBoard's own keys on screen keep the owner across
            // a short noted frame.
            BOOL messagesField = _searchSlot < 0 && [self kb723IsMessages:[self containerForSlot:_stagedKeyboardSlot]];
            CGRect seen = DSVisibleKeyboardFrameOnScreen();
            if (!messagesField && !CGRectIsNull(seen) && CGRectGetHeight(seen) >= 150.0) drawn = YES;
        }
    } @catch (NSException *exception) {
    }
    if (_searchSlot >= 0) {
        if (!drawn) return nil;
        if (what) *what = @"the stage's app search";
        return [self containerForSlot:_searchSlot];
    }
    if (_stagedKeyboardSlot >= 0) {
        if (!drawn) return nil;
        if (what) *what = @"the stage's text field";
        return [self containerForSlot:_stagedKeyboardSlot];
    }
    NSString *bundle = _focus704KeysBundle;
    if (bundle.length > 0 && [self isHostingBundleIdentifier:bundle] && ![self keys697CardAwayForBundle:bundle]) {
        NSInteger slot = [self slotForHostedBundle:bundle];
        if (slot == 0 || slot == 1) {
            if (what) *what = bundle;
            return [self containerForSlot:slot];
        }
    }
    if (keysUp && [self stagedTypingSessionActive] && (_keyboardLiftSlot == 0 || _keyboardLiftSlot == 1)) {
        if (what) *what = [self sceneHostForSlot:_keyboardLiftSlot].bundleIdentifier ?: @"the lifted card";
        return [self containerForSlot:_keyboardLiftSlot];
    }
    return nil;
}

// 4.5.715: kb707 is the only keyboard mover for two stacked stages. The 704 /
// 705 step-aside that ran here when kb707 was off is removed: its conditions
// (overlay, not split, no third stage) are exactly the ones in which kb707
// owns the layout, so with kb707 always owning it the step-aside could not run.
- (void)focus704Evaluate:(NSString *)why {
    if ([self kb707Owns]) {
        [self kb707Evaluate:why];
        return;
    }
    // 4.5.711: the stage closed / minimised while kb707 held a lift: put the
    // cards back (no animation).
    if (_kb707Active) [self kb707Restore:@"stage left" animated:NO];
}

// ---- 4.5.707 kb707: one keyboard-avoidance controller ------------------------
// Before 707 four movers placed the cards for a keyboard: the picker-search
// branch of noteKeyboardFrame703 (lift / drop + side park), the staged-app lift
// (liftCardBy / setLift / reapplyBottomKeyboardLift, with a "companion" lift
// that pushed the upper card off the top), the two-stage side park
// (commitSideParkForOwner / applySplitKeyboardShift / the settled top move) and
// focus704's step-aside on top of those. They answered at different times with
// different curves, so cards could be moved twice or fight.
// kb707 is declarative: input = which card owns the keyboard (picker search,
// the stage's own field or an app field; focus704TypingCard) and the keyboard
// frame. Output = the owner sits directly on the keyboard (lift / drop, the
// lift transform only, frame untouched; Beeper's 684 card uses its pinned
// keyboard top so its in-scene bar stays exactly on the keys), the other card
// slides off its nearest side. Everything springs back when typing ends (0.4 s
// with no owner and no keys on screen, 3 s cap). One spring (anim702) for every
// move; nothing moves while a finger is down, a minimise / restore or corner
// pull runs, or the overlay settles. Split / third-stage layouts keep their own
// shift. The old movers above return at once while kb707 owns the layout.
// 4.5.715: there is no fallback any more. /var/mobile/.dynamicstage-kb707-off
// does nothing. The crash latch stays: after a crash within 15 s of kb707's
// first use (kb707-crashed), kb707 still owns the layout but moves no card
// (cards stay where they are for the keyboard); delete kb707-crashed to undo.
// ---- 4.5.720 kb720 -----------------------------------------------------------
// "The keyboard isn't 100% stable; the picker search sometimes flickers."
// One owner per state: in single and two-stage layouts kb707 is the only thing
// that moves a card for a keyboard. While it holds a typing session, a layout
// pass does not re-place the cards (that zeroed the lift and put it back, which
// cut kb707's spring and, for the front card or an empty noted frame, dropped
// the card until kb707 lifted it again), heal700 / drag706 leave the cards
// alone, the picker search hide goes straight to kb707's own 0.4 s window (no
// 705 hold on top), the search re-raise loop does not resign / reload a field
// whose keyboard is on its way, and the status bar decision uses the place kb707
// is moving the card to (not the live lift a layout pass just zeroed). Split
// and the third stage keep their own movers; kb707 hands over to them without
// undoing their offsets. Messages is left exactly as it was (never a kb720
// session). Off: /var/mobile/.dynamicstage-kb720-off; per-action crash latch.
static inline BOOL DSKb720Close(CGRect a, CGRect b) {
    return fabs(a.origin.x - b.origin.x) <= 0.5 && fabs(a.origin.y - b.origin.y) <= 0.5 &&
           fabs(a.size.width - b.size.width) <= 0.5 && fabs(a.size.height - b.size.height) <= 0.5;
}

- (BOOL)kb720On {
    return DSFeature699On("kb720");
}

// A kb707 typing session in a single / two-stage layout that is not Messages.
- (BOOL)kb720Typing {
    if (!_kb707Active || !_kb707Owner) return NO;
    if (_state != DSStageStateOverlay || _splitMode || _floatActive) return NO;
    DSSceneHost *host = [self sceneHostForCard:_kb707Owner];
    if (host.isHosting && [host.bundleIdentifier isEqualToString:@"com.apple.MobileSMS"]) return NO;
    return [self kb720On];
}

// The per-action latch (marker before every kb720 action) and a log line per
// kind at most every 5 s.
- (void)kb720Act:(NSString *)what {
    DSFeature719MarkAction("kb720");
    if (!what.length) return;
    if (!_kb720SaidAt) _kb720SaidAt = [NSMutableDictionary dictionary];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSNumber *last = _kb720SaidAt[what];
    if (last && now - last.doubleValue < 5.0 && now >= last.doubleValue) return;
    _kb720SaidAt[what] = @(now);
    DSDiagnosticsRecordFormat(@"SpringBoard: kb720 %@", what);
}

// ---- 4.5.723 kb723 -----------------------------------------------------------
// kb721's fixes without its split takeover (4.5.721 resprung on "new stage";
// no crash log). Single / two-stage only: split and a third stage stay on the
// 4.5.720 path. 1) SpringBoard's own keys on screen keep the search / stage
// field owner across short frames; 2) the owner app's own keyboard report is
// used when the frame was never noted; 3) a typing context with no owner /
// keys yet is re-checked every 0.3 s for up to 2 s; 4) a self-check every
// 0.35 s lifts a typing card still covering the keys after 0.3 s ("kb723
// corrected"). Nothing runs while a stage is created, a picker appears or a
// card is torn down (0.6 s after each), or while split / third stage is up.
// Every timer re-checks the card (non-nil, still in the window). All new code
// is in @try. Before each action a breadcrumb line is written synchronously to
// /var/tmp/com.recreated.dynamicstage.kb723.last (the last action survives a
// crash the handler cannot see). Off: /var/mobile/.dynamicstage-kb723-off.
static void DSKb723Breadcrumb(const char *what) {
    @try {
        char line[200];
        struct timeval tv;
        gettimeofday(&tv, NULL);
        int n = snprintf(line, sizeof(line), "%ld.%03d kb723 %s (build %s)\n",
                         (long)tv.tv_sec, (int)(tv.tv_usec / 1000), what ?: "?", kDSBuildVersionString);
        if (n <= 0) return;
        if (n >= (int)sizeof(line)) n = (int)sizeof(line) - 1;
        int fd = open("/var/tmp/com.recreated.dynamicstage.kb723.last", O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd < 0) return;
        ssize_t w = write(fd, line, (size_t)n);
        (void)w;
        close(fd);
    } @catch (NSException *exception) {
    }
}

- (void)kb723Act:(const char *)what {
    DSKb723Breadcrumb(what);
    DSFeature719MarkAction("kb723");
}

// kb723 may act: on, overlay, single / two-stage, nothing being built or torn
// down, no picker just appearing.
- (BOOL)kb723Ready {
    if (!DSFeature699On("kb723")) return NO;
    if (_state != DSStageStateOverlay || _splitMode || _floatActive) return NO;
    if (_overlaySettling || _spam700MinimisePending || _spam700DeferredFinish) return NO;
    if (!_container || !_container.window) return NO;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now < _kb723QuietUntil && _kb723QuietUntil - now < 5.0) return NO;
    return YES;
}

- (BOOL)kb723CardOK:(DSStageContainerView *)card {
    if (!card || !card.window || !card.superview) return NO;
    if (card != _container && card != _topContainer) return NO;
    return [self focus704CardLive:card];
}

- (BOOL)kb723IsMessages:(DSStageContainerView *)card {
    if (!card) return NO;
    DSSceneHost *host = [self sceneHostForCard:card];
    return host.isHosting && [host.bundleIdentifier isEqualToString:@"com.apple.MobileSMS"];
}

- (void)kb723SelfCheckLater {
    if (_kb723CheckQueued || ![self kb723Ready]) return;
    _kb723CheckQueued = YES;
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_kb723CheckQueued = NO;
        @try {
            [strongSelf kb723SelfCheck];
        } @catch (NSException *exception) {
            DSDiagnosticsRecordFormat(@"SpringBoard: kb723 caught %@", exception.reason ?: exception.name);
        }
    });
}

- (void)kb723SelfCheck {
    if (![self kb723Ready] || ![self kb707Owns] || !_kb707Active) {
        _kb723OverlapSince = 0.0;
        return;
    }
    DSStageContainerView *owner = _kb707Owner;
    if (![self kb723CardOK:owner] || [self kb723IsMessages:owner]) {
        _kb723OverlapSince = 0.0;
        return;
    }
    DSSceneHost *host = [self sceneHostForCard:owner];
    if (host.isHosting && [host.bundleIdentifier isEqualToString:@"com.beeper.chat.ios"] && !DS756On("lift756")) {
        _kb723OverlapSince = 0.0;   // Beeper's 684 card sits on its pinned keys
        return;
    }
    CGRect keys = [self kb707KeysForCard:owner];
    if (CGRectIsNull(keys) || CGRectIsEmpty(keys)) {
        _kb723OverlapSince = 0.0;
        return;
    }
    [self kb723SelfCheckLater];
    CGRect seen = [self visualScreenFrameForCard:owner];
    CGFloat overlap = CGRectGetMaxY(seen) - CGRectGetMinY(keys);
    CGFloat want = [self kb707LiftForCard:owner keyboard:keys];
    BOOL off = overlap > 8.0 && want > 0.5 && fabs(owner.liftOffset - want) > 0.5;
    if (!off) {
        _kb723OverlapSince = 0.0;
        return;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (_kb723OverlapSince <= 0.0 || now < _kb723OverlapSince) {
        _kb723OverlapSince = now;
        return;
    }
    if (now - _kb723OverlapSince < 0.3) return;
    if (_stageDragActive || _drag702Card || DSStageDragSettlingFast(0.35) || _cornerRestoreCard) return;   // next check retries
    _kb723OverlapSince = 0.0;
    [self kb723Act:"self-check lift"];
    CGFloat had = owner.liftOffset;
    _kb707Logged = nil;
    [self kb707Evaluate:@"self-check"];
    DSDiagnosticsRecordFormat(@"SpringBoard: kb723 corrected the %@ card (%@): it covered the keys by %.0f pt for over 0.3 s, lift %.0f -> %.0f",
                              owner == [self cardOnHalf:1] ? @"upper" : @"lower",
                              host.bundleIdentifier ?: @"stage field", overlap, had, owner.liftOffset);
}

- (BOOL)kb707Owns {
    // 4.5.711: no stage open = kb707 does nothing at all.
    if (_state != DSStageStateOverlay) return NO;
    if (_splitMode || _floatActive) return NO;
    // 4.5.711: the crash latch is set at first use (the first time kb707 owns
    // the layout), not only just before a card moves.
    if (!_kb711Marked) {
        // 4.5.724: kb707 (the core lift / slide) is not latchable any more. A
        // kb707-crashed latch left by another build's crash (4.5.721's "new
        // stage" respring) stopped every card move on 4.5.723. Stale markers
        // are removed once, at the first use; nothing is written.
        _kb711Marked = YES;
        BOOL had = NO;
        for (NSString *path in @[ @"/var/mobile/.dynamicstage-kb707-crashed", @"/var/mobile/.dynamicstage-kb707-trying",
                                  @"/var/jb/var/mobile/.dynamicstage-kb707-crashed" ]) {
            if (access(path.fileSystemRepresentation, F_OK) == 0) {
                had = YES;
                unlink(path.fileSystemRepresentation);
            }
        }
        if (had) DSDiagnosticsRecord(@"SpringBoard: kb724 removed a stale kb707 crash latch: keyboard lift / slide is on (not latchable since 4.5.724)");
    }
    return YES;
}

- (BOOL)kb707Gate {
    if (_kb707Writing || ![self kb707Owns]) return NO;
    [self kb707Schedule];
    return YES;
}

- (void)kb707Schedule {
    NSUInteger gen = ++_kb707Gen;
    __weak __typeof(self) weakSelf = self;
    for (NSNumber *after in @[ @0.05, @0.40 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(after.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || gen != strongSelf->_kb707Gen) return;
            @try {
                [strongSelf kb707Evaluate:@"keys"];
            } @catch (NSException *exception) {
                DSDiagnosticsRecordFormat(@"SpringBoard: kb707 caught %@", exception.reason ?: exception.name);
            }
        });
    }
}

- (void)kb707QueueCheck:(NSTimeInterval)after {
    if (_kb707CheckQueued) return;
    _kb707CheckQueued = YES;
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(after * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_kb707CheckQueued = NO;
        @try {
            [strongSelf kb707Evaluate:@"check"];
        } @catch (NSException *exception) {
            DSDiagnosticsRecordFormat(@"SpringBoard: kb707 caught %@", exception.reason ?: exception.name);
        }
    });
}

// The keyboard the owner types into: a staged app's own keyboard report
// (Beeper's frozen bottom keyboard, the 684 path), else SpringBoard's noted
// keyboard, else the keyboard on screen. CGRectNull = no keyboard.
- (CGRect)kb707KeysForCard:(DSStageContainerView *)card {
    CGRect screen = [self screenBounds];
    CGFloat w = CGRectGetWidth(screen), h = CGRectGetHeight(screen);
    NSInteger slot = card == _container ? 0 : (card == _topContainer ? 1 : -1);
    if (slot >= 0) {
        DSLiftSlotState *state = DSLiftSlotAt(slot);
        if (state->keyboardFrozen && state->frozenKeysH >= 150.0 && state->frozenKeysY > 100.0 && state->frozenKeysY < h - 1.0) {
            return CGRectMake(0.0, state->frozenKeysY, w, state->frozenKeysH);
        }
    }
    CGRect keys = _keyboardFrame;
    if (!CGRectIsEmpty(keys) && CGRectGetHeight(keys) >= 150.0 && CGRectGetMinY(keys) < h - 1.0) return keys;
    keys = DSVisibleKeyboardFrameOnScreen();
    if (!CGRectIsNull(keys) && !CGRectIsEmpty(keys) && CGRectGetHeight(keys) >= 150.0 && CGRectGetMinY(keys) < h - 1.0) return keys;
    // 4.5.723: the owner app's own keyboard report when the frame was never
    // noted (not Messages, not a 683 in-card keyboard).
    @try {
        NSString *bundle = _kb723ArbiterBundle;
        if (bundle.length && card && (slot == 0 || slot == 1) && [self kb723Ready]) {
            DSSceneHost *host = [self sceneHostForSlot:slot];
            keys = _kb723ArbiterKeys;
            // 4.5.750 ks750: read the keyboard system's frame from the one
            // keyboard state (same source, same owner, in screen space).
            // Off: ks750-off (crash latch ks750).
            if ([self core750On] && DSFeature699On("ks750")) {
                DSFeature719MarkAction("ks750");
                bundle = _ks747ArbOn ? _ks747ArbOwner : nil;
                keys = _ks747ArbOn ? _ks747ArbFrame : CGRectZero;
                if (!bundle.length) keys = CGRectZero;
            }
            if (host && host.isHosting && [host.bundleIdentifier isEqualToString:bundle] &&
                ![bundle isEqualToString:@"com.apple.MobileSMS"] && ![self phoneSize683ActiveForBundle:bundle] &&
                CGRectGetHeight(keys) >= 150.0 && CGRectGetMinY(keys) < h - 1.0 && CGRectGetMinY(keys) > h * 0.35) {
                return CGRectMake(0.0, CGRectGetMinY(keys), w, CGRectGetHeight(keys));
            }
        }
    } @catch (NSException *exception) {
    }
    return CGRectNull;
}

// Lift (+ up / - down) that puts the card's bottom on the keyboard top.
- (CGFloat)kb707LiftForCard:(DSStageContainerView *)card keyboard:(CGRect)keys {
    CGRect resting = (card == _container) ? [self primaryCardFrameInRoot] : [self frameWithoutKeyboardShift:card];
    if (CGRectGetHeight(resting) < 40.0) return 0.0;
    CGFloat keysY = CGRectGetMinY(keys);
    // 28 pt above the reported frame keeps the suggestion bar off the card
    // (the 697 lift); a 684 phone-size card sits exactly on its pinned keys
    // top so the app's own bar lands on the keyboard (Beeper).
    CGFloat keysTop = keysY - 28.0;
    NSInteger slot = card == _container ? 0 : (card == _topContainer ? 1 : -1);
    if (slot >= 0) {
        CGFloat pin = [self fit696KeysTopForSlot:slot keyboardY:keysY];
        if (pin > 0.0) keysTop = pin;
    }
    CGFloat lift = CGRectGetMaxY(resting) - keysTop;
    CGFloat maxLift = MAX(0.0, CGRectGetMinY(resting) - 5.0);
    if (lift > maxLift) lift = maxLift;
    // 4.5.756 lift756: one rule for every stage and app: the typed-in card
    // sits just above the keys, up OR down (a card resting higher comes down).
    if (DS756On("lift756")) {
        if (fabs(lift) < 1.0) lift = 0.0;
        if (lift < 0.0) {
            CGFloat maxDrop = CGRectGetHeight([self screenBounds]) - CGRectGetMaxY(resting);
            if (-lift > maxDrop) lift = -MAX(0.0, maxDrop);
        }
        return lift;
    }
    // Only up. A card already clear of the keys stays where it is (the 705
    // finding: dropping the upper card onto the keys and back is what flickered).
    if (lift < 1.0) lift = 0.0;
    return lift;
}

- (void)kb707Animate:(void (^)(void))moves {
    if (!moves) return;
    void (^body)(void) = ^{
        self->_kb707Writing = YES;
        moves();
        [self syncLiftChrome];
        self->_kb707Writing = NO;
    };
    if (!_window || _window.hidden) {
        [UIView performWithoutAnimation:body];
        return;
    }
    UIViewPropertyAnimator *animator = nil;
    if (UIAccessibilityIsReduceMotionEnabled()) {
        animator = [[UIViewPropertyAnimator alloc] initWithDuration:0.2 curve:UIViewAnimationCurveEaseInOut animations:body];
    } else {
        animator = [[UIViewPropertyAnimator alloc] initWithDuration:kDSAnim702MinimiseDuration timingParameters:DSAnim702Spring(0.0)];
        [animator addAnimations:body];
    }
    if ([self core747On]) {
        if (_mv747Animator && _mv747Animator.state == UIViewAnimatingStateActive && ![self anim748On]) [_mv747Animator stopAnimation:YES];
        _mv747Gen += 1;
        _mv747Animator = animator;
    }
    [animator startAnimation];
}

- (void)kb707Restore:(NSString *)why animated:(BOOL)animated {
    if (DSFeature699On("black731")) {   // 4.5.731 black731: re-check once the cards are back
        __weak __typeof(self) weakSelf731 = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try {
                [weakSelf731 black731Check:@"cards back from the keyboard slide"];
            } @catch (NSException *exception) {
            }
        });
    }
    _kb723OverlapSince = 0.0;
    _kb707Active = NO;
    _kb707Owner = nil;
    _kb707AbsentSince = 0.0;
    _kb707Logged = nil;
    NSMutableArray<DSStageContainerView *> *cards = [NSMutableArray array];
    for (DSStageContainerView *card in @[ _container ?: (id)NSNull.null, _topContainer ?: (id)NSNull.null, _floatContainer ?: (id)NSNull.null ]) {
        if ((id)card == NSNull.null) continue;
        if (fabs(card.liftOffset) > 0.5 || fabs(card.sideOffset) > 0.5) [cards addObject:card];
    }
    if (cards.count == 0) return;
    void (^moves)(void) = ^{
        for (DSStageContainerView *card in cards) {
            if (DSSpring755On()) { DSFeature719MarkAction("spring755"); [card setLiftOffset:0.0 sideOffset:0.0]; } else { [card setLiftOffset:0.0]; [card setSideOffset:0.0]; }
        }
    };
    BOOL live = animated && _state == DSStageStateOverlay && !_stageDragActive && !_drag702Card;
    if (live) [self kb707Animate:moves];
    else {
        [UIView performWithoutAnimation:^{
            for (DSStageContainerView *card in cards) [card.layer removeAllAnimations];
            self->_kb707Writing = YES;
            moves();
            [self syncLiftChrome];
            self->_kb707Writing = NO;
        }];
    }
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_kb707Active || strongSelf->_stageDragActive) return;
        [strongSelf restoreCardStackingOrder];
    });
    DSDiagnosticsRecordFormat(@"SpringBoard: kb707 typing ended (%@): cards spring back", why ?: @"?");
    [self scene748Settle:@"cards back from the keyboard slide" after:0.4];
}

- (void)kb707Evaluate:(NSString *)why {
    if (DSCall733HandsOff(@"kb707")) return;   // 4.5.734 call733
    if (![self kb707Owns]) {
        if (_kb707Active && _state == DSStageStateOverlay && (_splitMode || _floatActive) && [self kb720On]) {
            // 4.5.720: split / third stage own the keyboard now. Only a card
            // still exactly where kb707 put it springs back; offsets the split
            // or third-stage mover already wrote are theirs.
            [self kb720Act:@"split / third stage took the keyboard: kb707 let go, only its own offsets undone"];
            NSMutableArray<DSStageContainerView *> *mine = [NSMutableArray array];
            DSStageContainerView *ownerCard = _kb720OwnerCard, *otherCard = _kb720OtherCard;
            if (ownerCard && fabs(ownerCard.liftOffset - _kb720OwnerLift) <= 0.5 && fabs(ownerCard.sideOffset) <= 0.5 &&
                fabs(ownerCard.liftOffset) > 0.5) [mine addObject:ownerCard];
            if (otherCard && otherCard != ownerCard && fabs(otherCard.sideOffset - _kb720OtherSide) <= 0.5 &&
                fabs(otherCard.liftOffset) <= 0.5 && fabs(otherCard.sideOffset) > 0.5) [mine addObject:otherCard];
            _kb707Active = NO;
            _kb707Owner = nil;
            _kb707AbsentSince = 0.0;
            _kb707Logged = nil;
            _kb720OwnerCard = nil;
            _kb720OtherCard = nil;
            if (mine.count) {
                [UIView performWithoutAnimation:^{
                    self->_kb707Writing = YES;
                    for (DSStageContainerView *card in mine) {
                        if (DSSpring755On()) { DSFeature719MarkAction("spring755"); [card setLiftOffset:0.0 sideOffset:0.0]; } else { [card setLiftOffset:0.0]; [card setSideOffset:0.0]; }
                    }
                    [self syncLiftChrome];
                    self->_kb707Writing = NO;
                }];
            }
            return;
        }
        if (_kb707Active) [self kb707Restore:@"layout changed" animated:NO];
        return;
    }
    // 4.5.724: no crash latch here any more (it disabled every card move).
    DSPerfCount(DSPerfCounterFocusEvals);
    BOOL eligible = _state == DSStageStateOverlay && !DSBattery701ScreenLocked() && !DSPS696DeviceLocked() && _container;
    CGRect screen = [self screenBounds];
    NSString *what = nil;
    DSStageContainerView *owner = eligible ? [self focus704TypingCard:&what] : nil;
    if (owner && (![self focus704CardLive:owner] ||
                  (owner != _container && owner != _topContainer))) owner = nil;
    CGRect keys = owner ? [self kb707KeysForCard:owner] : CGRectNull;
    if (CGRectIsNull(keys)) owner = nil;
    // 4.5.745 loop745: lift / slide only for keys really on screen. After
    // stuck727 put a card back, nothing lifts again until a real keyboard
    // shows. Off: /var/mobile/.dynamicstage-loop745-off (per-action crash latch).
    if (owner && DSFeature699On("loop745")) {
        CGRect real = DSVisibleKeyboardFrameOnScreen();
        BOOL realUp = (!CGRectIsNull(real) && CGRectGetHeight(real) >= 150.0 &&
                       CGRectGetMinY(real) < CGRectGetHeight(screen) - 1.0) || [self springBoardIsDrawingKeyboard];
        if (realUp) {
            _loop745Block = NO;
        } else if (_loop745Block || !_kb707Active) {
            DSFeature719MarkAction("loop745");
            static CFAbsoluteTime saidAt = 0;
            CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
            if (t - saidAt > 5.0 || t < saidAt) {
                saidAt = t;
                DSDiagnosticsRecordFormat(@"SpringBoard: loop745 no lift (%@): no keyboard on screen (noted %@)",
                                          why ?: @"?", NSStringFromCGRect(_keyboardFrame));
                [self ev766Note:@"loop745" card:owner extra:[NSString stringWithFormat:@"block=%d real=%@", _loop745Block, NSStringFromCGRect(real)]];
            }
            _keyboardFrame = CGRectZero;
            _focus704KeysBundle = nil;
            owner = nil;
        }
    }
    // 4.5.725: a noted hide wins over keys still sliding off the screen.
    if (owner && _kb707Active && _sync725HideAt > 0.0 && [self sync725On] && ![self sync725OldTimingFor:owner]) owner = nil;
    if (owner) _kb723MissSince = 0.0;
    if (!owner) {
        if (!_kb707Active) {
            // 4.5.723: someone is typing but owner / keys are not known yet:
            // look again every 0.3 s for up to 2 s.
            @try {
                if (eligible && [self kb723Ready]) {
                    NSString *bundle = _focus704KeysBundle;
                    BOOL messages = [bundle isEqualToString:@"com.apple.MobileSMS"] ||
                        ((_stagedKeyboardSlot == 0 || _stagedKeyboardSlot == 1) && [self kb723IsMessages:[self containerForSlot:_stagedKeyboardSlot]]);
                    CGRect seen = DSVisibleKeyboardFrameOnScreen();
                    BOOL typing = _searchSlot >= 0 || _stagedKeyboardSlot >= 0 || bundle.length > 0 ||
                        (!CGRectIsEmpty(_keyboardFrame) && CGRectGetHeight(_keyboardFrame) >= 150.0) ||
                        (!CGRectIsNull(seen) && CGRectGetHeight(seen) >= 150.0);
                    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                    if (typing && !messages) {
                        if (_kb723MissSince <= 0.0 || now < _kb723MissSince) _kb723MissSince = now;
                        if (now - _kb723MissSince < 2.0) {
                            [self kb723Act:"re-check (owner / keys not known yet)"];
                            [self kb707QueueCheck:0.3];
                        }
                    } else {
                        _kb723MissSince = 0.0;
                    }
                }
            } @catch (NSException *exception) {
            }
            return;
        }
        // One typing session = one move. A keyboard that blinks (key window
        // reclaim, field re-assert, a short frame) is not the end.
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        CGRect keysNow = DSVisibleKeyboardFrameOnScreen();
        BOOL keysOnScreen = (!CGRectIsNull(keysNow) && CGRectGetHeight(keysNow) >= 150.0) || [self springBoardIsDrawingKeyboard];
        if (_kb707AbsentSince <= 0.0 || now < _kb707AbsentSince) _kb707AbsentSince = now;
        CFAbsoluteTime absent = now - _kb707AbsentSince;
        if (eligible && _sync725HideAt > 0.0 && [self sync725On] && ![self sync725OldTimingFor:_kb707Owner]) {
            // 4.5.725: the keyboard said it is going: spring back with it after
            // a 0.1 s blip guard (a show inside it cancels), no 0.4 s wait.
            CFAbsoluteTime since = now - _sync725HideAt;
            if (since < 0.0) since = 0.0;
            if (since < 0.1) {
                [self sync725Later:0.1 - since + 0.01];
                return;
            }
            if (_stageDragActive || _drag702Card) {
                [self kb707QueueCheck:0.5];
                return;
            }
            DSFeature719MarkAction("sync725");
            _sync725HideAt = 0.0;
            [self kb707Restore:@"keyboard dismissed (sync725)" animated:YES];
            return;
        }
        // 4.5.743 fast743: keys gone from the screen with no note: 0.15 s fallback.
        BOOL fast743 = DSFeature699On("fast743") && ![self fast743OwnerIsMessages];
        if (eligible && (absent < (fast743 ? 0.15 : 0.4) || keysOnScreen) && absent < 3.0) {
            [self kb707QueueCheck:(fast743 ? 0.16 : 0.45)];
            return;
        }
        // A finger holds a card: spring back after it lets go, not under it.
        if (eligible && (_stageDragActive || _drag702Card)) {
            [self kb707QueueCheck:0.5];
            return;
        }
        [self kb707Restore:(eligible ? @"typing ended" : @"stage left") animated:eligible];
        return;
    }
    _kb707AbsentSince = 0.0;
    if (_stageDragActive || _drag702Card || DSStageDragSettlingFast(0.35) || _cornerRestoreCard ||
        _spam700MinimisePending || _spam700DeferredFinish || _overlaySettling) {
        // 0.3 s for the first 12 tries, then once a second until it is free.
        [self kb707QueueCheck:(_kb707Defers < 12 ? 0.3 : 1.0)];
        _kb707Defers += 1;
        return;
    }
    _kb707Defers = 0;
    DSStageContainerView *other = nil;
    if (_stackSlotCount >= kDSMaxStackSlots) {
        other = owner == _container ? _topContainer : _container;
        if (![self focus704CardLive:other]) other = nil;
    }
    // 4.5.725 sync725: a short (pre-suggestion-bar) frame is planned with the
    // full keyboard already seen, so lift and slide start together.
    // 4.5.756 coalesce756: the full-keyboard top is remembered per app (the
    // 755 double lift 324 -> 369 at 16:26:53.092/.096 used Messages' 631, then
    // Messenger's own 586).
    CGFloat fullY = _sync725FullKeysY;
    if (DS756On("coalesce756")) {
        NSString *ob = [self sceneHostForCard:owner].bundleIdentifier;
        if (!_full756KeysY) _full756KeysY = [NSMutableDictionary dictionary];
        if (ob.length && CGRectGetHeight(keys) >= 280.0) _full756KeysY[ob] = @(CGRectGetMinY(keys));
        NSNumber *known = ob.length ? _full756KeysY[ob] : nil;
        fullY = known ? known.doubleValue : 0.0;
        if (fullY > 100.0 && CGRectGetHeight(keys) < 280.0) DSFeature719MarkAction("coalesce756");
    }
    if ([self sync725On] && ![self sync725OldTimingFor:owner] && fullY > 100.0 &&
        CGRectGetHeight(keys) < 280.0 && fullY < CGRectGetMinY(keys) - 0.5) {
        CGFloat bottom = CGRectGetMaxY(keys);
        keys.origin.y = fullY;
        keys.size.height = MAX(bottom - fullY, keys.size.height);
    }
    CGFloat lift = [self kb707LiftForCard:owner keyboard:keys];
    // 4.5.755 lift755: a phonesize684 card keeps its keyboard inside the card
    // (the app lays out above it), so kb707 never lifts it; the other card
    // still slides aside when they overlap.
    if (lift > 0.0 && DSLift755On() && !DS756On("lift756") && [[self sceneHostForCard:owner] isPhoneSize684]) {
        DSFeature719MarkAction("lift755");
        lift = 0.0;
    }
    // 4.5.816 topstay816: the top card stays where it is while typing in it
    // (815 log: "kept (already clear) 140 pt" moved it {{5, 5}} -> {{5, 145}}).
    // The bottom card still moves just above the keyboard; the other card's
    // slide-aside is unchanged. Off: /var/mobile/.dynamicstage-topstay816-off.
    if (fabs(lift) > 0.5 && owner == [self cardOnHalf:1] && DS816On("topstay816") && DS809Latched("topstay816")) {
        DSFeature719MarkAction("topstay816");
        lift = 0.0;
    }
    CGFloat side = 0.0;
    if (other) {
        // The other card makes room only when the typing card (at its lifted
        // place) would cover it; then it slides off its nearest side.
        CGRect otherSeen = (other == _container) ? [self primaryCardFrameInRoot] : [self frameWithoutKeyboardShift:other];
        CGRect ownerAt = (owner == _container) ? [self primaryCardFrameInRoot] : [self frameWithoutKeyboardShift:owner];
        ownerAt.origin.y -= lift;
        CGRect both = CGRectIntersection(ownerAt, otherSeen);
        BOOL always756 = DS756On("lift756");   // 4.5.756: every other stage leaves to the side
        if (always756 || (!CGRectIsNull(both) && CGRectGetHeight(both) > 8.0 && CGRectGetWidth(both) > 8.0)) {
            if (always756) DSFeature719MarkAction("lift756");
            BOOL goLeft = CGRectGetMidX(otherSeen) <= CGRectGetMidX(screen) + 0.5;
            side = [self sideParkDistanceForCard:other goLeft:goLeft];
            if (!isfinite(side)) side = 0.0;
        }
    }
    BOOL ownerMoves = fabs(owner.liftOffset - lift) > 0.5 || fabs(owner.sideOffset) > 0.5;
    BOOL otherMoves = other && (fabs(other.sideOffset - side) > 0.5 || fabs(other.liftOffset) > 0.5);
    BOOL fresh = owner != _kb707Owner || !_kb707Active;
    _kb707Owner = owner;
    _kb707Active = YES;
    @try {
        [self kb723SelfCheckLater];
    } @catch (NSException *exception) {
    }
    _kb720OwnerCard = owner;
    _kb720OwnerLift = lift;
    _kb720OtherCard = other;
    _kb720OtherSide = side;
    if (!ownerMoves && !otherMoves) return;
    // The typing card in front before anything moves (no z flash mid-spring).
    if (other) [self bringCardAboveItsPartner:owner];
    DSPerfCount(DSPerfCounterFocusMoves);
    [self kb707Animate:^{
        if (DSSpring755On()) { DSFeature719MarkAction("spring755"); [owner setLiftOffset:lift sideOffset:0.0]; } else { [owner setSideOffset:0.0]; [owner setLiftOffset:lift]; }
        if (other) {
            if (DSSpring755On()) { [other setLiftOffset:0.0 sideOffset:side]; } else {
            [other setLiftOffset:0.0];
            [other setSideOffset:side];
            }
        }
    }];
    if (lift < -0.5 && DS759On("keys759")) {
        DSFeature719MarkAction("keys759");
        (void)DSRaiseKeyboardWindowAboveStage();
    }
    NSString *line = [NSString stringWithFormat:@"%@|%.0f|%.0f", what ?: @"?", lift, side];
    if (fresh || ![line isEqualToString:_kb707Logged]) {
        _kb707Logged = line;
        DSDiagnosticsRecordFormat(@"SpringBoard: kb707 typing in the %@ card (%@, %@): %@ %.0f pt to the keyboard%@",
                                  owner == [self cardOnHalf:1] ? @"upper" : @"lower", what ?: @"?", why ?: @"?",
                                  lift > 0.5 ? @"lifted" : (lift < -0.5 ? @"lowered" : @"kept (already clear)"), fabs(lift),
                                  other ? [NSString stringWithFormat:@", the other card slid %@ %.0f pt", side < 0 ? @"left" : @"right", fabs(side)] : @"");
    }
}

// ---- 4.5.707 corner707 -------------------------------------------------------
// "Sometimes both stages minimise to the same corner": every park path chose
// its side on its own (kbmin702 and heal700 used the card's last side, the
// corner flick the flick side, a stash the stash side), so a second card could
// land on the first. One resolver: the side a card wants, unless the other
// stage is already parked (and hosting) in that corner - then the free corner.
// The home tuck already sends the two cards to opposite corners and passes.
// Off: /var/mobile/.dynamicstage-corner707-off (crash latch).
- (BOOL)corner707Side:(BOOL)onLeft forCard:(DSStageContainerView *)card why:(NSString *)why {
    if (!card || card == _floatContainer || !DSFeature699On("corner707")) return onLeft;
    BOOL otherParked = NO;
    BOOL otherLeft = NO;
    if (card == _topContainer) {
        otherParked = _primaryParked && _sceneHost.isHosting;
        otherLeft = _primaryMinimizedLeft;
    } else if (card == _container) {
        otherParked = _secondParked && _topSceneHost.isHosting && _stackSlotCount >= kDSMaxStackSlots;
        otherLeft = _secondMinimizedLeft;
    }
    if (!otherParked || otherLeft != onLeft) return onLeft;
    DSFeature699MarkTrying("corner707");
    DSDiagnosticsRecordFormat(@"SpringBoard: corner707 %@ card wanted the %@ corner, the other stage is parked there: using the %@ corner (%@)",
                              card == _topContainer ? @"second" : @"first", onLeft ? @"left" : @"right",
                              onLeft ? @"right" : @"left", why ?: @"?");
    return !onLeft;
}

// ---- 4.5.705 focus705 -------------------------------------------------------------
// Fixes the 704 typing-focus flicker (see the search branch of
// noteKeyboardFrame703:, topSplitIsTypingInCard: and focus704Evaluate:) and
// heal700 fighting keyboard slides. Off: /var/mobile/.dynamicstage-focus705-off
// (crash latch focus705-trying / -crashed) = exactly 4.5.704.
- (BOOL)focus705On {
    if (!DSFeature699On("focus705")) return NO;
    DSFeature699MarkTrying("focus705");
    return YES;
}

// App search in the upper of two stacked (not split) cards.
- (BOOL)focus705UpperSearchStill {
    if (_splitMode || _floatActive || _stackSlotCount < kDSMaxStackSlots || _searchSlot < 0) return NO;
    DSStageContainerView *card = [self containerForSlot:_searchSlot];
    if (!card || card != [self cardOnHalf:1]) return NO;
    if ([self sceneHostForSlot:_searchSlot].isHosting) return NO;
    return [self focus705On];
}

// 4.5.705 perf705: one line of state for the perf summary.
- (NSString *)perf705GaugeLine {
    NSMutableString *line = [NSMutableString stringWithFormat:@"gauge705 stages=%ld split=%d", (long)_stackSlotCount, (int)_splitMode];
    NSInteger blur = 0, masks = 0, hosted = 0;
    for (NSInteger slot = 0; slot <= 2; slot++) {
        DSStageContainerView *card = [self containerForSlot:slot];
        if (!card) continue;
        if ([card perf705BlurVisible]) blur += 1;
        if ([card perf705HasMask]) masks += 1;
        if ([self sceneHostForSlot:slot].isHosting) hosted += 1;
        if (fabs(card.sideOffset) > 0.5 || fabs(card.liftOffset) > 0.5) {
            [line appendFormat:@" slot%ld shift=%.0f,%.0f", (long)slot, card.sideOffset, card.liftOffset];
        }
    }
    [line appendFormat:@" hosted=%ld blurVisible=%ld maskedCards=%ld focus=%@%@ perf705=%@ focus705=%@",
     (long)hosted, (long)blur, (long)masks, _kb707Owner ? @"owner" : @"none", _kb707Active ? @"+kb707" : @"",
     DSPerf705On() ? @"on" : @"OFF", DSFeature699On("focus705") ? @"on" : @"OFF"];
    return line;
}


- (void)minimizeCard:(DSStageContainerView *)card toCornerAnimated:(BOOL)animated {
    DSHide772NotePath(@"minimizeCard");
    [self kb744DismissForCard:card why:@"minimizeCard"];   // 4.5.744 kbdrag744
    BOOL spam = DSFeature699On("spam700");
    if (spam) [self spam700Note:1 why:@"minimise"];
    NSUInteger gen = _spam700Gen;
    _primaryMinimizedLeft = [self corner707Side:_primaryMinimizedLeft forCard:_container why:@"corner"];
    _primaryParked = YES;
    _ignoreSystemPullUntil = 0;
    if (DSFeature699On("anim702")) [self anim702StopRunning:@"minimise"];
    void (^layout)(void) = ^{
        [self layoutAllStackSlotsForState:DSStageStateMinimized];
    };
    void (^body)(void) = ^{
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
    // 4.5.700 spam700: the completion runs once, and only while this minimise
    // is still what the user last asked for (see spam700MinimiseCompletion).
    __block BOOL ran = NO;
    void (^finish)(void) = ^{
        if (ran) return;
        ran = YES;
        if (!spam) {
            body();
            return;
        }
        [self spam700MinimiseCompletion:card gen:gen body:body];
    };
    if (spam) {
        _spam700MinimisePending = YES;
        _spam700PendingGen = gen;
    }
    // 4.5.702 anim702: one spring from the card to its corner icon.
    if (card && [self anim702FlyCard:card finishFirst:!animated layout:layout completion:finish]) {
        return;
    }
    // 4.5.698 anim698: a snapshot flies, the card is placed at once.
    if (card && animated &&
        [self anim698FlyCard:card duration:0.30 options:UIViewAnimationOptionCurveEaseIn finishFirst:NO layout:layout completion:finish]) {
        return;
    }
    if (card && !animated &&
        [self anim698FlyCard:card duration:0.18 options:UIViewAnimationOptionCurveEaseOut finishFirst:YES layout:layout completion:finish]) {
        return;
    }
    if (animated) {
        [self animateEaseIntoCorner:layout completion:finish];
    } else {
        layout();
        finish();
    }
}

// ---- 4.5.700 spam700 --------------------------------------------------------
// Bugs-spam log (4.5.698): a card dragged into the corner starts a 0.30 s
// minimise (its completion sets the stage to Minimized, gives the key window
// back and backgrounds the app). The corner pull picked the parked card up
// 60 ms later (14:42:29.316 pull / 29.376 minimise) and a quick pull restored
// it in ~0.15 s - before the minimise completion ran. That stale completion
// then set the stage back to Minimized under a restored card: the card is
// not parked (no corner icon, no corner pull), the stage is "minimised", so
// the next layout puts the card in the corner park spot {{466,960},{56,56}}
// and nothing can bring it back until a home swipe tucks it again. The same
// in reverse: a restore's reveal (0.26-0.45 s later, and re-tried every 0.3 s
// while the home gesture runs) woke and laid out a card that was minimised
// again since. Every minimise / restore is now a numbered request; a
// completion that no longer belongs to the user's last request is dropped.
- (void)spam700Note:(NSInteger)intent why:(NSString *)why {
    if (_spam700MinimisePending && intent != _spam700Intent) {
        [self ev766Note:@"spam700" card:nil extra:[NSString stringWithFormat:@"intent %ld -> %ld while a minimise is in flight (%@)",
                                                   (long)_spam700Intent, (long)intent, why ?: @"?"]];
    }
    _spam700Gen += 1;
    _spam700Intent = intent;
    if (intent == 2) {
        if (_spam700DeferredFinish) {
            DSDiagnosticsRecordFormat(@"SpringBoard: spam700 a deferred minimise completion was dropped: %@ (#%lu) came after it",
                                      why ?: @"restore", (unsigned long)_spam700Gen);
        }
        _spam700DeferredFinish = nil;
        _spam700MinimisePending = NO;
    }
}

- (void)spam700MinimiseCompletion:(DSStageContainerView *)card gen:(NSUInteger)gen body:(void (^)(void))body {
    if (_spam700PendingGen == gen) _spam700MinimisePending = NO;
    BOOL parkedNow = card ? [self cardIsParked:card] : _primaryParked;
    if (!parkedNow || _spam700Intent != 1) {
        DSFeature699MarkTrying("spam700");
        DSDiagnosticsRecordFormat(@"SpringBoard: spam700 ignored a stale minimise completion (#%lu; now #%lu, %@): the card was brought back after it",
                                  (unsigned long)gen, (unsigned long)_spam700Gen, parkedNow ? @"restore asked" : @"card not parked");
        return;
    }
    if (_state == DSStageStateTracking) {
        // A corner pull is running on this card: finish only if that pull is
        // cancelled (cancelTracking runs it); a restore drops it.
        _spam700DeferredFinish = [body copy];
        DSDiagnosticsRecordFormat(@"SpringBoard: spam700 minimise completion (#%lu) waits: a corner pull is running", (unsigned long)gen);
        return;
    }
    body();
}

- (void)animateEaseIntoCorner:(void (^)(void))animations completion:(void (^)(void))completion {
    // 4.5.698: timed for the perf log (frames / slow frames), 697 animation unchanged.
    DSAnim698FrameMeter *meter = [DSAnim698FrameMeter new];
    meter.name = @"minimise697";
    [meter start];
    [UIView animateWithDuration:0.32
                          delay:0
                        options:UIViewAnimationOptionCurveEaseIn | UIViewAnimationOptionAllowUserInteraction
                     animations:animations
                     completion:^(BOOL finished) {
        [meter stop];
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
    [self anim698RemoveFlightForCard:card];
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
    [self kb744DismissForCard:card why:@"minimizeDraggedCard"];   // 4.5.744 kbdrag744
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
        onLeft = [self corner707Side:onLeft forCard:card why:@"picker leave"];
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
    onLeft = [self corner707Side:onLeft forCard:card why:@"minimise"];
    if (card == _topContainer) _secondMinimizedLeft = onLeft;
    else _primaryMinimizedLeft = onLeft;
    if (card == _container) {
        _minimizedHalf = half == 0 ? 0 : 1;
        _primaryHalf = _minimizedHalf;
    }
    BOOL spam = DSFeature699On("spam700");
    if (spam) [self spam700Note:1 why:@"drag minimise"];
    if (![self rememberedPictureForCard:card]) [self rememberPictureForCard:card];
    [self showRememberedPictureOnCard:card];
    [self setParked:YES forCard:card];
    DSStageContainerView *other = (card == _container) ? _topContainer : _container;
    BOOL otherStays = _stackSlotCount >= kDSMaxStackSlots && other && !other.hidden && ![self cardIsParked:other];
    if (!otherStays) {
        [self minimizeCard:card toCornerAnimated:animated];
        return;
    }
    void (^layout)(void) = ^{
        [self layoutAllStackSlotsForState:DSStageStateOverlay];
    };
    void (^finish)(void) = ^{
        if (spam && ![self cardIsParked:card]) {
            DSDiagnosticsRecord(@"SpringBoard: spam700 ignored a stale minimise completion (other stage stays): the card was brought back after it");
            return;
        }
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


- (void)setTerminateHintAmount:(CGFloat)amount {
    if (!_terminateHint) return;
    amount = MIN(MAX(amount, 0.0), 1.0);
    // 4.5.697: every drag frame rebuilt the (hidden) red glow: gradient colours,
    // frames and two bring-to-fronts. Nothing changes while it stays hidden.
    static BOOL hiddenApplied = NO;
    if (amount <= 0.04 && hiddenApplied && _terminateGlowHost && DSPerf697On()) return;
    hiddenApplied = amount <= 0.04;
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
    [self kb744DismissForCard:nil why:@"dismissStageCompletelyAnimated"];   // 4.5.744 kbdrag744
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
    [self kb744DismissForCard:[self frontStageCard] why:@"terminateFrontStageAnimated"];   // 4.5.744 kbdrag744
    _kb723QuietUntil = CFAbsoluteTimeGetCurrent() + 0.6;   // 4.5.723: kb723 stays out (create / picker / teardown)
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
    [self kb744DismissForCard:card why:@"terminateDraggedCard"];   // 4.5.744 kbdrag744
    _kb723QuietUntil = CFAbsoluteTimeGetCurrent() + 0.6;   // 4.5.723: kb723 stays out (create / picker / teardown)
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
    [self refreshRimCatchers];
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
    // 4.5.731 rim731: the grab never reaches inside the card; the drag starts
    // only on the band outside it (the drag shell / rim views). Off: -rim731-off.
    if (DS809Latched("rim731")) return 0.0;
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

    _floatPicker = DSNewAppPicker817();
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
    [self phoneSize678ObserveTouchesOnCard:_floatContainer];

    DSStageRimHitView *floatRim = [[DSStageRimHitView alloc] initWithFrame:CGRectZero];
    floatRim.hitBand = kDSStageOuterDragBand + 18.0;
    _floatRim = floatRim;
    _floatContainer.rimCatcherName = @"float-inner";
    DSNameRimCatchers(floatRim.catchers, @"float-outer");
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
    // 4.5.675: a phone-size scene is laid out (scaled) by the host itself.
    if (keyboardBand || [sceneHost isPhoneSize675] ||
        (sceneHost.contentScale > 0.0 && fabs(sceneHost.contentScale - 1.0) > 0.02)) {
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
        onLeft = [self corner707Side:onLeft forCard:bottomCard why:@"split leave"];
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
    [self kb744DismissForCard:[self containerForSlot:2] why:@"dismissFloatStageAnimated"];   // 4.5.744 kbdrag744
    _kb723QuietUntil = CFAbsoluteTimeGetCurrent() + 0.6;   // 4.5.723: kb723 stays out (create / picker / teardown)
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
    _kb723QuietUntil = CFAbsoluteTimeGetCurrent() + 0.6;   // 4.5.723: kb723 stays out (create / picker / teardown)
    if (!_splitMode || _floatActive) return;
    // 4.5.766 three766: the third (hovering) stage had no switch. Default on,
    // unchanged; /var/mobile/.dynamicstage-three766-off (or a crash right after
    // one opened: latch three766) stops new hover stages. core766-off = 765.
    if (DSFeature699On("core766") && !DSFeature699On("three766")) {
        DSDiagnosticsRecord(@"SpringBoard: three766 off (file or crash latch): no hovering third stage");
        return;
    }
    if (DSFeature699On("core766")) DSFeature719MarkAction("three766");
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

// 4.5.651: a touch that started on the rim belongs to the stage drag. Any
// other recogniser in the stage window that got the same touch (picker
// scroll, taps, the status peek) waits for the rim pan to fail; the rim pan
// itself never waits for anyone. System gestures are held separately
// (shouldSuppressSystemGestureAtPoint).
- (BOOL)isStagePanRecognizer:(UIGestureRecognizer *)recognizer {
    return [recognizer isKindOfClass:DSQuickPanGestureRecognizer.class] && [self cardForStagePan:recognizer] != nil;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    if (![self isStagePanRecognizer:recognizer] || [self isStagePanRecognizer:other]) return NO;
    return other.view && other.view.window == _window;
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
    DS_PERF_BEGIN();
    if (recognizer.state == UIGestureRecognizerStateChanged) DSPerfCount(DSPerfCounterDragFrames);
    [self handleStagePan697Body:recognizer];
    DS_PERF_END(DSPerfBucketDrag);
}

- (void)handleStagePan697Body:(UIPanGestureRecognizer *)recognizer {
    BOOL ending706 = recognizer.state == UIGestureRecognizerStateEnded || recognizer.state == UIGestureRecognizerStateCancelled ||
        recognizer.state == UIGestureRecognizerStateFailed;
    // 4.5.706 drag706: the drag state below is shared by every card / rim pan.
    // A second pan beginning while one card was held reset it, so the held
    // card's own moves and release were ignored and it stayed where the finger
    // left it; that second pan's end also let go of the held card. One pan owns
    // the drag; any other pan is ignored until it ends.
    if (DSFeature699On("drag706")) {
        if (objc_getAssociatedObject(recognizer, &kDSDrag706IgnoredKey)) {
            if (ending706) objc_setAssociatedObject(recognizer, &kDSDrag706IgnoredKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
        UIPanGestureRecognizer *owner = DSDrag706Owner;
        if (owner && owner != recognizer &&
            (owner.state == UIGestureRecognizerStateBegan || owner.state == UIGestureRecognizerStateChanged)) {
            if (!ending706) {
                objc_setAssociatedObject(recognizer, &kDSDrag706IgnoredKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                DSDiagnosticsRecord(@"SpringBoard: drag706 a second pan began while a card was held: ignored until it ends (the held card keeps its drag)");
            }
            return;
        }
        if (ending706 && owner == recognizer) DSDrag706Owner = nil;
    }
    if (recognizer.state == UIGestureRecognizerStateBegan) [DSSceneHost noteStageInUse];
    if (ending706) {
        if (_stageDragActive) DSStageDragEndedAt = CACurrentMediaTime();
        [self drag702End];
        [self drag706DragFinished];
    }
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
        NSString *via = recognizer.view == _dragShell ? @"main-shell-pan" :
                        (recognizer.view == _topRim ? @"top-rim-pan" :
                         (recognizer.view == _floatRim ? @"float-rim-pan" :
                          (recognizer.view == _topContainer ? @"top-card-pan" :
                           (recognizer.view == _floatContainer ? @"float-card-pan" : @"card-pan"))));
        if (DS787On("rimname787")) {
            // 4.5.787 rimname787: the name went out garbled ("won by @???@?").
            // Built from C literals only, so no object lifetime is involved.
            const char *cvia = recognizer.view == _dragShell ? "main-shell-pan" :
                               (recognizer.view == _topRim ? "top-rim-pan" :
                                (recognizer.view == _floatRim ? "float-rim-pan" :
                                 (recognizer.view == _topContainer ? "top-card-pan" :
                                  (recognizer.view == _floatContainer ? "float-card-pan" : "card-pan"))));
            char line787[160];
            snprintf(line787, sizeof(line787), "drag began at %.0f,%.0f won by %s", screenPoint.x, screenPoint.y, cvia);
            DSRimLog([NSString stringWithUTF8String:line787] ?: @"drag began");
            (void)via;
        } else {
            DSRimLog([NSString stringWithFormat:@"drag began at %.0f,%.0f won by %@", screenPoint.x, screenPoint.y, via]);
        }
    }
    DSStageState layoutState = DSStageStateOverlay;
    CGRect screen = [self screenBounds];

    CGRect (^cardFrame)(void) = ^{
        if (card == _container) return [self primaryCardFrameInRoot];
        return [self frameWithoutKeyboardShift:card];
    };
    void (^moveCard)(CGRect) = ^(CGRect frame) {
        BOOL wasWriting = self->_drag702Writing;
        self->_drag702Writing = YES;   // 4.5.702 drag702: the drag's own write
        if (card == self->_container) [self setPrimaryCardFrameInRoot:frame];
        else [self assignFrame:frame toCard:card];
        self->_drag702Writing = wasWriting;
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
            if (DSFeature699On("drag706")) {
                DSDrag706Owner = recognizer;
                _drag706Settles = 0;
                _drag706GaveUp = NO;
                _drag706Seen = nil;
                _drag706TileCleared = NO;
                DSFeature699MarkTrying("drag706");
            }
            // 4.5.706 polish706: the held card's shadow grows (lift), the size never changes.
            if ([self polish706On]) [card setHeld706:YES];
            // 4.5.702 drag702: the card is grabbed where it is on screen; a
            // spring still running would keep moving it under the finger.
            [self drag702TakeCard:card recognizer:recognizer];
            [self native703Haptic:1];
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
            [self move747Cancel:@"drag"];
            [self drag702FreezeCard:card];
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
            // 4.5.706 perf706: Began already raised the card; nothing reorders the
            // pair mid-drag except the floating third stage. Re-raising it every
            // frame mutated the root's sublayers 60-120 times a second.
            BOOL perf706 = DSFeature699On("perf706");
            if (!perf706 || _floatActive) [self bringCardAboveItsPartner:card];
            else DSPerfCount(DSPerfCounterDragSkips);
            if (exitSwipe) {
                CGPoint velocity = [recognizer velocityInView:nil];
                BOOL inward = [self gestureIsDiagonalInwardFromLeft:exitFromLeft translation:translation velocity:velocity];
                BOOL downward = translation.y > 16.0 && fabs(translation.x) < fabs(translation.y);
                if (inward || !downward) break;
                exitSwipe = NO;
            }
            // 4.5.740 edge740: this "left swipe along the bottom" cancel ran for any
            // drag that started within 44 pt of the RIGHT screen edge at any
            // height, on every frame, so a right-rim grab that moved up or down
            // with any leftward drift (flat in y for a moment) was dropped and
            // snapped back mid-drag. The left, top and bottom rims never had it.
            // It now applies only to the phone's bottom-right corner it was for.
            // Off: /var/mobile/.dynamicstage-edge740-off.
            if (dragStartScreen.x > CGRectGetWidth(screen) - 44.0 &&
                (!DS809Latched("edge740") || [self pointIsPhoneRightCorner:dragStartScreen]) &&
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
            if (!perf706 || !_drag706TileCleared) {
                [self clearDragTileOnCard:card];
                _drag706TileCleared = perf706;
            } else {
                DSPerfCount(DSPerfCounterDragSkips);
            }
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
            CGPoint moveVelocity = [recognizer velocityInView:nil];
            BOOL flickLeft = NO;
            BOOL flickCorner = [self velocityIsQuickCornerSwipe:moveVelocity onLeft:&flickLeft];
            // 4.5.706 drag706: the same corner-swipe test as the release (no corner look for a wobble).
            if (flickCorner && DSFeature699On("drag706") &&
                ![self drag706FlickIsCornerSwipe:moveVelocity finger:screenPoint translation:translation onLeft:flickLeft]) {
                flickCorner = NO;
            }
            CGFloat approach = [self cornerApproachForCardFrame:fullFrame finger:screenPoint];
            CGFloat terminateApproach = flickCorner ? 0.0 : [self terminateApproachForCardFrame:fullFrame finger:screenPoint];
            // 4.5.706 perf706: the corner-hint / terminate-hint rects and the card
            // centre were built every frame and never used (dead since the hints
            // stopped shrinking the card).
            BOOL towardCorner = flickCorner || approach > 0.0 || (moveVelocity.y > 40.0 && fabs(moveVelocity.x) > 70.0);
            BOOL towardHome = terminateApproach > 0.04;
            (void)towardCorner;
            (void)towardHome;
            // 4.5.744 kbdrag744: a drag that heads for minimise / close drops the keys now.
            if (flickCorner || approach > 0.15 || terminateApproach > 0.15) {
                [self kb744DismissForCard:card why:@"drag toward minimise / close"];
            }
            CGRect frame = fullFrame;
            // 4.5.706 polish706: past the top of the screen the card follows the
            // finger with growing resistance (rubber band) instead of sliding off.
            if ([self polish706On] && !_splitMode && !draggingFront && card != _floatContainer && CGRectGetMinY(frame) < 0.0) {
                CGFloat over = -CGRectGetMinY(frame);
                CGFloat d = 120.0;
                frame.origin.y = -(1.0 - 1.0 / (over * 0.55 / d + 1.0)) * d;
            }
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
            if (!perf706 || showGhost || !_dragGhost || _dragGhost.opacity > 0.0) {
                [self updateDragGhostForFrame:CGRectZero red:NO visible:showGhost];
            } else {
                DSPerfCount(DSPerfCounterDragSkips);
            }
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
                NSInteger haptic703 = 3;
                [self clearDragTileOnCard:card];
                CGRect now = cardFrame();
                CGPoint velocity = [recognizer velocityInView:_window];
                CGRect sensor = now;
                BOOL flickLeft = NO;
                BOOL flickCorner = [self velocityIsQuickCornerSwipe:velocity onLeft:&flickLeft];
                // 4.5.706 drag706 (Forcefully-minimised log): any release with a fast
                // down-and-sideways finger minimised the card, even after the card
                // had been carried up or only nudged: lifting a finger off glass
                // often ends with that flick. A corner swipe now needs the card to
                // have travelled down and the flick to carry the finger toward the
                // bottom corner on that side.
                BOOL flick706Refused = NO;
                if (flickCorner && DSFeature699On("drag706") &&
                    ![self drag706FlickIsCornerSwipe:velocity finger:screenPoint translation:translation onLeft:flickLeft]) {
                    flickCorner = NO;
                    flick706Refused = YES;
                }
                CGFloat approach = [self cornerApproachForCardFrame:now finger:screenPoint];
                CGFloat terminateApproach = flickCorner ? 0.0 : [self terminateApproachForCardFrame:now finger:screenPoint];
                if (flick706Refused && approach <= 0.0) {
                    DSDiagnosticsRecordFormat(@"SpringBoard: drag706 %@ release flick v=(%.0f,%.0f) after moving (%.0f,%.0f) from %.0f,%.0f is not a corner swipe: the card settles, no minimise",
                                              [self sceneHostForCard:card].bundleIdentifier ?: @"card", velocity.x, velocity.y,
                                              translation.x, translation.y, dragStartScreen.x, dragStartScreen.y);
                }
                // 4.5.706 polish706: the half a single card settles on is chosen
                // where the throw would carry it (iOS PiP projection), not where
                // the finger let go.
                if ([self polish706On] && isfinite(velocity.y)) {
                    CGFloat projectY = MAX(-CGRectGetHeight(screen) * 0.5, MIN(velocity.y * 0.099, CGRectGetHeight(screen) * 0.5));
                    sensor.origin.y = MAX(0.0, MIN(CGRectGetMinY(sensor) + projectY, CGRectGetHeight(screen) - CGRectGetHeight(sensor)));
                }
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
                if (terminate) haptic703 = 0;
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
                    DSDiagnosticsRecordFormat(@"SpringBoard: drag706 %@ minimised by the drag: %@ v=(%.0f,%.0f) moved (%.0f,%.0f) released at %.0f,%.0f",
                                              [self sceneHostForCard:card].bundleIdentifier ?: @"card",
                                              flickCorner ? @"corner swipe" : @"finger at the corner", velocity.x, velocity.y,
                                              translation.x, translation.y, screenPoint.x, screenPoint.y);
                    // 4.5.733 flick733: what the user sees now (the presentation
                    // layer), taken before the follow animations are removed.
                    _flick733From = CGRectNull;
                    if (snap && DSFeature699On("flick733")) {
                        @try {
                            CALayer *pl = card.layer.presentationLayer;
                            UIView *rootView = card.window;
                            if (pl && rootView) {
                                CALayer *rootPl = rootView.layer.presentationLayer ?: rootView.layer;
                                _flick733From = [pl convertRect:pl.bounds toLayer:rootPl];
                            }
                        } @catch (NSException *exception) {
                            _flick733From = CGRectNull;
                        }
                    }
                    if (snap) [self stopMinimizedMotionForCard:card];
                    _anim702ReleaseVelocity = [recognizer velocityInView:nil];   // 4.5.702 anim702
                    _pull728DragMinAt = CFAbsoluteTimeGetCurrent();   // 4.5.728 pull728
                    _corner771MinGesture = recognizer;   // 4.5.771 corner771: the minimise's own touch
                    if (DSGest770On() && DSFeature699On("pull728") && ![self corner771On]) {   // 4.5.770 gest770: the corner grab window
                        CFAbsoluteTime set770 = _pull728DragMinAt;
                        DSDiagnosticsRecordFormat(@"SpringBoard: gest770 corner grab disabled for 1.0 s (pull728) after the drag-minimise release at %.0f,%.0f", screenPoint.x, screenPoint.y);
                        __weak __typeof(self) weak770 = self;
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            __strong __typeof(weak770) s770 = weak770;
                            if (!s770 || s770->_pull728DragMinAt != set770) return;
                            DSDiagnosticsRecordFormat(@"SpringBoard: gest770 corner grab enabled again (pull728 window over; anim702=%lu spam700 pending=%d)",
                                                      (unsigned long)s770->_anim702Running.count, s770->_spam700MinimisePending);
                        });
                    }
                    haptic703 = 2;
                    [self minimizeDraggedCard:card fromHalf:halfAtDragStart onLeft:onLeft animated:!snap];
                    _anim702ReleaseVelocity = CGPointZero;
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
                [self native703Haptic:haptic703];
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

// ---- 4.5.706 drag706 / polish706 ---------------------------------------------
- (BOOL)polish706On {
    if (!DSFeature699On("polish706")) return NO;
    if (!_polish706Marked) {
        _polish706Marked = YES;
        DSFeature699MarkTrying("polish706");
    }
    return YES;
}

// A release flick only minimises when the card travelled down during the drag
// and the flick carries the finger toward the bottom corner on its side
// (projected 0.25 s ahead).
- (BOOL)drag706FlickIsCornerSwipe:(CGPoint)velocity finger:(CGPoint)finger translation:(CGPoint)translation onLeft:(BOOL)onLeft {
    if (!isfinite(velocity.x) || !isfinite(velocity.y)) return NO;
    CGRect screen = [self screenBounds];
    CGFloat width = CGRectGetWidth(screen);
    CGFloat height = CGRectGetHeight(screen);
    if (translation.y < 48.0) return NO;
    CGPoint ahead = CGPointMake(finger.x + velocity.x * 0.25, finger.y + velocity.y * 0.25);
    if (ahead.y < height * 0.62) return NO;
    if (onLeft ? ahead.x > width * 0.5 : ahead.x < width * 0.5) return NO;
    return YES;
}

- (void)drag706DragFinished {
    if ([self polish706On] || _container.held706 || _topContainer.held706 || _floatContainer.held706) {
        [_container setHeld706:NO];
        [_topContainer setHeld706:NO];
        [_floatContainer setHeld706:NO];
    }
    if (!DSFeature699On("drag706")) return;
    // Forcefully-minimised log: "phonesize696 fit: slot 0 stored resting frame
    // y=469 ... was stale; the card rests at y=5" after the stages were swapped
    // by a drag. A keyboard lift measured from that stored frame puts the card
    // back where it was before the drag. With no keyboard anywhere the stored
    // frames are leftovers; the next lift captures fresh ones.
    BOOL keys = !CGRectIsEmpty(_keyboardFrame) || _keyboardDrawnOutside || _hostedKeyboardRequestBundle.length > 0 ||
        _stagedKeyboardSlot >= 0 || _searchSlot >= 0 || [self springBoardIsDrawingKeyboard];
    BOOL lifted = fabs(_container.liftOffset) > 0.5 || (_topContainer && fabs(_topContainer.liftOffset) > 0.5);
    if (!keys && !lifted) {
        for (NSInteger slot = 0; slot < kDSMaxStackSlots; slot++) {
            if (DSLiftSlotAt(slot)->hasRestingFrame) DSLiftSlotAt(slot)->hasRestingFrame = NO;
        }
    }
    if (_drag706CheckQueued) return;
    _drag706CheckQueued = YES;
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_drag706CheckQueued = NO;
        @try {
            [strongSelf drag706Check:@"drag end"];
        } @catch (NSException *exception) {
            DSDiagnosticsRecordFormat(@"SpringBoard: drag706 caught %@", exception.reason ?: exception.name);
        }
    });
}

- (BOOL)drag706FingerDown {
    NSArray<UIView *> *views = @[ _dragShell ?: (UIView *)NSNull.null, _container ?: (UIView *)NSNull.null,
                                  _topContainer ?: (UIView *)NSNull.null, _topRim ?: (UIView *)NSNull.null,
                                  _floatContainer ?: (UIView *)NSNull.null, _floatRim ?: (UIView *)NSNull.null ];
    for (id view in views) {
        if (view == NSNull.null) continue;
        for (UIGestureRecognizer *gesture in [(UIView *)view gestureRecognizers]) {
            if (![gesture isKindOfClass:UIPanGestureRecognizer.class]) continue;
            if (gesture.state == UIGestureRecognizerStateBegan || gesture.state == UIGestureRecognizerStateChanged) return YES;
        }
    }
    UIPanGestureRecognizer *owner = DSDrag706Owner;
    if (owner && (owner.state == UIGestureRecognizerStateBegan || owner.state == UIGestureRecognizerStateChanged)) return YES;
    if (_systemPull && (_systemPull.state == UIGestureRecognizerStateBegan || _systemPull.state == UIGestureRecognizerStateChanged)) return YES;
    return NO;
}

- (BOOL)drag706KeyboardAround {
    return !CGRectIsEmpty(_keyboardFrame) || _keyboardDrawnOutside || _hostedKeyboardRequestBundle.length > 0 ||
        _stagedKeyboardSlot >= 0 || _searchSlot >= 0 ||
        [self springBoardIsDrawingKeyboard] || DSLiftSlotAt(0)->hasRestingFrame || DSLiftSlotAt(1)->hasRestingFrame ||
        [self lift802KeysJustWentDown:0.6];
}

// 4.5.802 lift802: the keyboard went down (arbiter off) within `window` s, or
// a sync725 spring-back is still pending. Used by drag706 (the card is still
// springing back: not "a shift with no keyboard") and by noteKeyboardFrame.
- (BOOL)lift802KeysJustWentDown:(CFAbsoluteTime)window {
    if (!DS802On("lift802")) return NO;
    if (_sync725HideAt > 0.0) return YES;
    if (DS803On("lift803")) return NO;   // 4.5.803: no time window; only the pending spring-back counts
    if (DSKbVis768ArbiterIsOn()) return NO;
    CFAbsoluteTime off = DSKbVis768ArbiterOffTime(), now = CFAbsoluteTimeGetCurrent();
    return off > 0.0 && now >= off && now - off < window;
}

- (NSString *)drag706ProblemForCard:(DSStageContainerView *)card keyboard:(BOOL)keyboard {
    if (!card || card.hidden || card.alpha < 0.05 || [self cardIsParked:card]) return nil;
    if (card.layer.animationKeys.count > 0 || objc_getAssociatedObject(card, &kDSAnim698FlightKey)) return nil;
    if (card.drag702Frozen) return nil;
    if (card == _container && _dragShell.layer.animationKeys.count > 0) return nil;
    BOOL shifted = fabs(card.sideOffset) > 0.5 || fabs(card.liftOffset) > 0.5;
    if (shifted && !keyboard) {
        return [NSString stringWithFormat:@"keyboard shift (side %.0f, lift %.0f) with no keyboard", card.sideOffset, card.liftOffset];
    }
    if (keyboard) return nil;
    CGRect resting = (card == _container) ? [self primaryCardFrameInRoot] : [self frameWithoutKeyboardShift:card];
    if (CGRectGetWidth(resting) < 80.0 || CGRectGetHeight(resting) < 80.0) return nil;   // heal700's case
    CGRect placed = [self placedFrameForCard:card state:DSStageStateOverlay];
    if (!CGRectIsEmpty(placed) && CGRectGetWidth(placed) >= 80.0 &&
        (fabs(CGRectGetMinX(resting) - CGRectGetMinX(placed)) > 3.0 || fabs(CGRectGetMinY(resting) - CGRectGetMinY(placed)) > 3.0)) {
        return [NSString stringWithFormat:@"at %@ but its place is %@", NSStringFromCGRect(resting), NSStringFromCGRect(placed)];
    }
    CGRect screen = [self screenBounds];
    CGRect visible = CGRectIntersection(resting, screen);
    CGFloat area = MAX(CGRectGetWidth(resting) * CGRectGetHeight(resting), 1.0);
    CGFloat shown = CGRectIsNull(visible) ? 0.0 : CGRectGetWidth(visible) * CGRectGetHeight(visible);
    if (shown < area * 0.9) {
        return [NSString stringWithFormat:@"at %@, only %.0f%% on the screen", NSStringFromCGRect(resting), shown * 100.0 / area];
    }
    return nil;
}

// After every drag (0.6 s) and on the stage tick: no finger down, nothing
// animating, and a card that is not at a valid rest for more than 0.5 s is
// settled (sprung to its place / clamped on screen / keyboard shift dropped).
// Off: /var/mobile/.dynamicstage-drag706-off.
- (void)drag706Check:(NSString *)from {
    if (!_activated || !DSFeature699On("drag706")) return;
    BOOL finger = [self drag706FingerDown];
    if (_stageDragActive && !finger) {
        // A drag whose end never arrived: the layout skipped this card since.
        DSDrag706Owner = nil;
        _stageDragActive = NO;
        DSStageDragEndedAt = CACurrentMediaTime();
        [self drag702End];
        [_container setHeld706:NO];
        [_topContainer setHeld706:NO];
        [_floatContainer setHeld706:NO];
        DSPerfCount(DSPerfCounterSettles);
        DSDiagnosticsRecordFormat(@"SpringBoard: drag706 settled the stage from %@ reason a drag that never ended (no finger down): layout unblocked", from ?: @"?");
    }
    BOOL busy = finger || _stageDragActive || _state != DSStageStateOverlay || _splitMode || _floatActive || _expandedCard ||
        _overlaySettling || _splitCollapseClosing || _cornerRestoreCard || _spam700MinimisePending || _spam700DeferredFinish ||
        _anim702Running.count > 0 || DSPS696DeviceLocked() || DSCallStepAsideActive() ||
        [DSSceneHost homeGestureIsActive] || [DSSceneHost systemTransitionBusy] || [DSSceneHost systemEdgePullIsActive] ||
        [DSSceneHost sceneSettingsUpdateDepth] > 0 || DSStageRestoreSettlingFast(0.6) || DSStageDragSettlingFast(0.5);
    if (busy) {
        _drag706Seen = nil;
        return;
    }
    BOOL keyboard = [self drag706KeyboardAround];
    DSStageContainerView *bad = nil;
    NSString *why = [self drag706ProblemForCard:_container keyboard:keyboard];
    if (why) bad = _container;
    if (!bad && _stackSlotCount >= kDSMaxStackSlots && _topContainer) {
        why = [self drag706ProblemForCard:_topContainer keyboard:keyboard];
        if (why) bad = _topContainer;
    }
    if (!bad) {
        _drag706Seen = nil;
        return;
    }
    // 4.5.751 pos751: drag706's settle is a logging backstop (the never-ended
    // drag unblock above stays); stuck727's 2 s safety snap still applies.
    if (DSFeature699On("core751") && DSFeature699On("pos751")) {
        static CFAbsoluteTime saidAt = 0;
        CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
        if (t - saidAt > 3.0 || t < saidAt) {
            saidAt = t;
            DSDiagnosticsRecordFormat(@"SpringBoard: DRAG706 BACKSTOP (log only) %@ card from %@: %@",
                                      bad == _container ? @"bottom" : @"top", from ?: @"?", why ?: @"?");
        }
        return;
    }
    if ([self kb720Typing]) {
        // 4.5.720: kb707's lift / side slide is not a stuck drag.
        [self kb720Act:@"drag706 leaves the cards to kb707 while typing"];
        _drag706Seen = nil;
        return;
    }
    NSString *key = [NSString stringWithFormat:@"%p|%@", bad, why];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (![key isEqualToString:_drag706Seen]) {
        _drag706Seen = key;
        _drag706Since = now;
        __weak __typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try {
                [weakSelf drag706Check:@"recheck"];
            } @catch (NSException *exception) {
            }
        });
        return;
    }
    if (now - _drag706Since < 0.5) return;
    _drag706Seen = nil;
    if (_drag706GaveUp) return;
    if (_drag706Settles >= 2) {
        _drag706GaveUp = YES;
        DSDiagnosticsRecordFormat(@"SpringBoard: drag706 gave up settling %@ (%@): two settles did not hold; left until the next drag",
                                  [self sceneHostForCard:bad].bundleIdentifier ?: @"card", why);
        return;
    }
    _drag706Settles += 1;
    DSPerfCount(DSPerfCounterSettles);
    DSFeature699MarkTrying("drag706");
    NSString *bundle = [self sceneHostForCard:bad].bundleIdentifier ?: @"card";
    DSDiagnosticsRecordFormat(@"SpringBoard: drag706 settled %@ from %@ reason %@", bundle, from ?: @"?", why);
    if (fabs(bad.sideOffset) > 0.5 || fabs(bad.liftOffset) > 0.5) {
        [self clearKeyboardSideShift];
        [self animateSpring:^{
            [self->_container setLiftOffset:0.0];
            if (self->_topContainer) [self->_topContainer setLiftOffset:0.0];
        } completion:nil];
        return;
    }
    if (bad == _container && _stackSlotCount <= 1 && [self primaryCardHasCustomOverlayFrame]) {
        CGRect screen = [self screenBounds];
        CGRect frame = [self primaryCardFrameInRoot];
        CGFloat inset = 5.0;
        frame.origin.x = MAX(CGRectGetMinX(screen) + inset, MIN(CGRectGetMinX(frame), CGRectGetMaxX(screen) - inset - CGRectGetWidth(frame)));
        frame.origin.y = MAX(CGRectGetMinY(screen) + inset, MIN(CGRectGetMinY(frame), CGRectGetMaxY(screen) - inset - CGRectGetHeight(frame)));
        [self animateSpring:^{
            [self placeCard:bad atFrame:frame];
        } completion:nil];
        return;
    }
    [self snapBackToLayoutForState:DSStageStateOverlay];
    [self restoreCardStackingOrder];
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

// ---- 4.5.740 picker740 ----------------------------------------------------------
// Apps that are open full screen, or alive as a running full-screen scene (the
// switcher's live apps), read from SpringBoard's own state: the front app and
// FBSceneManager's scenes whose app process is running, minus the scenes the
// stage hosts. Greyed out in the picker and refused by launchEntry. No switcher
// UI is touched. Off: /var/mobile/.dynamicstage-picker740-off (latch).
- (NSString *)picker740BundleOfScene:(id)scene {
    @try {
        id process = [scene respondsToSelector:@selector(clientProcess)] ? ((id (*)(id, SEL))objc_msgSend)(scene, @selector(clientProcess)) : nil;
        if ([process respondsToSelector:@selector(bundleIdentifier)]) {
            id b = ((id (*)(id, SEL))objc_msgSend)(process, @selector(bundleIdentifier));
            if ([b isKindOfClass:NSString.class] && [(NSString *)b length]) {
                if ([process respondsToSelector:@selector(isRunning)] && !((BOOL (*)(id, SEL))objc_msgSend)(process, @selector(isRunning))) return nil;
                return b;
            }
        }
    } @catch (NSException *exception) {
    }
    return nil;
}

- (NSSet<NSString *> *)picker740FullScreenBundles {
    NSMutableSet<NSString *> *out = [NSMutableSet set];
    if (!DSFeature699On("picker740")) return out;
    @try {
        NSString *front = [self frontApplication].bundleIdentifier;
        if (front.length && ![front isEqualToString:@"com.apple.springboard"]) [out addObject:front];
        NSMutableArray *ours = [NSMutableArray array];
        for (DSSceneHost *h in @[ _sceneHost ?: (id)NSNull.null, _topSceneHost ?: (id)NSNull.null, _floatSceneHost ?: (id)NSNull.null,
                                  _stashedHost ?: (id)NSNull.null, _stashedHost2 ?: (id)NSNull.null ]) {
            if (![h isKindOfClass:DSSceneHost.class]) continue;
            id sc = [h hostedScene];
            if (sc) [ours addObject:sc];
        }
        Class managerClass = objc_getClass("FBSceneManager");
        id manager = [managerClass respondsToSelector:@selector(sharedInstance)] ? ((id (*)(id, SEL))objc_msgSend)(managerClass, @selector(sharedInstance)) : nil;
        NSArray *scenes = nil;
        for (NSString *name in @[ @"scenes", @"allScenes" ]) {
            SEL sel = NSSelectorFromString(name);
            if (![manager respondsToSelector:sel]) continue;
            id list = ((id (*)(id, SEL))objc_msgSend)(manager, sel);
            if ([list isKindOfClass:NSArray.class]) { scenes = list; break; }
            if ([list isKindOfClass:NSSet.class]) { scenes = [(NSSet *)list allObjects]; break; }
        }
        for (id scene in scenes) {
            if ([ours containsObject:scene]) continue;
            NSString *b = [self picker740BundleOfScene:scene];
            if (b.length && ![b isEqualToString:@"com.apple.springboard"] && ![b hasPrefix:@"com.apple.springboard."]) [out addObject:b];
        }
        // An app the stage hosts is not "full screen" here.
        for (DSSceneHost *h in @[ _sceneHost ?: (id)NSNull.null, _topSceneHost ?: (id)NSNull.null, _floatSceneHost ?: (id)NSNull.null ]) {
            if ([h isKindOfClass:DSSceneHost.class] && h.bundleIdentifier) [out removeObject:h.bundleIdentifier];
        }
        if (DSFeature699On("msg742")) [out removeObject:@"com.apple.MobileSMS"];   // 4.5.742: Messages is never greyed out
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: picker740 caught %@", exception.reason ?: exception.name ?: @"?");
        return [NSSet set];
    }
    return out;
}

- (void)refreshPickerAvailability {
    NSMutableSet<NSString *> *staged = [NSMutableSet set];
    [self rememberStagedBundleOfHost:_sceneHost inSet:staged];
    [self rememberStagedBundleOfHost:_topSceneHost inSet:staged];
    [self rememberStagedBundleOfHost:_floatSceneHost inSet:staged];
    [self rememberStagedBundleOfHost:_stashedHost inSet:staged];
    [self rememberStagedBundleOfHost:_stashedHost2 inSet:staged];
    @try {
        NSSet<NSString *> *full = [self picker740FullScreenBundles];
        if (full.count) [staged unionSet:full];
    } @catch (NSException *exception) {
    }
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
    // 4.5.746 notch746: the right-edge "Stages" tab must be on screen. Put it
    // back (in the root, unhidden, opaque, in front) and say so when it was not.
    // Off: /var/mobile/.dynamicstage-notch746-off
    @try {
        if (DSFeature699On("notch746")) {
            UIView *root = _window.rootViewController.view;
            NSMutableArray *fixed = [NSMutableArray array];
            if (root && _shelf.superview != root) { [root addSubview:_shelf]; [fixed addObject:@"re-added"]; }
            if (_shelf.hidden) { _shelf.hidden = NO; [fixed addObject:@"unhidden"]; }
            if (_shelf.alpha < 0.99) { _shelf.alpha = 1.0; [fixed addObject:@"alpha"]; }
            if (root && !CGRectEqualToRect(_shelf.frame, root.bounds)) { _shelf.frame = root.bounds; [fixed addObject:@"frame"]; }
            if (fixed.count) {
                DSFeature719MarkAction("notch746");
                [_shelf.superview bringSubviewToFront:_shelf];
                DSDiagnosticsRecordFormat(@"SpringBoard: notch746 edge tab was off screen, fixed: %@ (window level %.0f)",
                                          [fixed componentsJoinedByString:@", "], _window.windowLevel);
            }
        }
    } @catch (NSException *exception) {
    }
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
    _kb723QuietUntil = CFAbsoluteTimeGetCurrent() + 0.6;   // 4.5.723: kb723 stays out (create / picker / teardown)
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
    // 4.5.695: a phone-size (684) scene was kept while minimised; place it now.
    @try {
        [host phoneSize695ReturnedToCard];
    } @catch (NSException *exception) {
    }
}


- (void)parkStashedHost:(DSSceneHost *)host onLeft:(BOOL)left {
    if (!host.isHosting) return;
    DSStageContainerView *card = nil;
    if (!_sceneHost.isHosting) {
        card = _container;
        _sceneHost = host;
        _primaryMinimizedLeft = [self corner707Side:left forCard:_container why:@"stash"];
        _primaryParked = YES;
    } else if (!_topSceneHost.isHosting) {
        [self ensureTopStackInfrastructure];
        card = _topContainer;
        _topSceneHost = host;
        _secondMinimizedLeft = [self corner707Side:left forCard:_topContainer why:@"stash"];
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
    _kb723QuietUntil = CFAbsoluteTimeGetCurrent() + 0.6;   // 4.5.723: kb723 stays out (create / picker / teardown)
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
    _kb723QuietUntil = CFAbsoluteTimeGetCurrent() + 0.6;   // 4.5.723: kb723 stays out (create / picker / teardown)
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
    [self noteStageUse];
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


- (void)restoreParkedHostsAfterHomeGesture {
    // Still inside the quiet window, so the scene update from this property
    // write is held. Do not change display mode and do not push scene
    // settings. That push landed as Spotlight opened and safe-moded.
    [_sceneHost setFollowsSystemHomeTransition:NO];
    [_topSceneHost setFollowsSystemHomeTransition:NO];
    [_floatSceneHost setFollowsSystemHomeTransition:NO];
    // 4.5.665: SpringBoard finishes the hand-back after this; see Tweak.xm.
    [DSSceneHost noteHomeHandBack];
    DSDiagnosticsRecord(@"SpringBoard: parked apps stopped following the home transition");
}

static NSInteger DSHomeGestureGeneration = 0;

- (void)home731Track:(UIPanGestureRecognizer *)gesture {
    if (!_home731Pending) {
        if (gesture.state >= UIGestureRecognizerStateEnded) [gesture removeTarget:self action:@selector(home731Track:)];
        return;
    }
    @try {
        CGPoint t = [gesture translationInView:nil];
        CGPoint v = [gesture velocityInView:nil];
        UIGestureRecognizerState st = gesture.state;
        BOOL done = st == UIGestureRecognizerStateEnded || st == UIGestureRecognizerStateCancelled || st == UIGestureRecognizerStateFailed;
        BOOL commit = t.y <= -40.0 || (st == UIGestureRecognizerStateEnded && t.y <= -12.0 && v.y < -400.0);
        if (commit) {
            _home731Pending = NO;
            DSDiagnosticsRecordFormat(@"SpringBoard: home731 the home swipe committed (up %.0f pt, v %.0f): tucking", -t.y, -v.y);
            [self tuckOpenStageAwayForHomeGesture];
        } else if (done) {
            _home731Pending = NO;
            DSDiagnosticsRecordFormat(@"SpringBoard: home731 the home bar was touched but not swiped (up %.0f pt, v %.0f): cards left in place", -t.y, -v.y);
            // The begin froze a picture on each open card: give the live app back.
            if (_sceneHost.isHosting && !_primaryParked) [self dropHeldPictureOnCard:_container];
            if (_topSceneHost.isHosting && !_secondParked && _topContainer) [self dropHeldPictureOnCard:_topContainer];
            if (_floatSceneHost.isHosting && _floatActive) [self dropHeldPictureOnCard:_floatContainer];
        }
        if (done) [gesture removeTarget:self action:@selector(home731Track:)];
    } @catch (NSException *exception) {
        _home731Pending = NO;
        [gesture removeTarget:self action:@selector(home731Track:)];
        [self tuckOpenStageAwayForHomeGesture];
    }
}

- (void)noteHomeGestureEnded:(UIPanGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateEnded &&
        gesture.state != UIGestureRecognizerStateCancelled &&
        gesture.state != UIGestureRecognizerStateFailed) return;
    [gesture removeTarget:self action:@selector(noteHomeGestureEnded:)];
    DSHomeGestureGeneration += 1;
    [DSSceneHost setHomeGestureActive:NO];
    DSDiagnosticsRecord(@"SpringBoard: home gesture ended");
    DSGest770NoteEvent(@"home ended");
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
    // 4.5.665: no refit while a corner pull adopted from SpringBoard's own
    // gesture is running; the card comes back (and is refit) when it ends.
    if ([DSSceneHost systemEdgePullIsActive]) return;
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
    [self kb744DismissForCard:nil why:@"tuckOpenStageAwayForHomeGesture"];   // 4.5.744 kbdrag744
    if (DSCall733HandsOff(@"home tuck")) return;   // 4.5.734 call733
    BOOL hosting = _sceneHost.isHosting || _topSceneHost.isHosting;
    if (_state != DSStageStateOverlay && _state != DSStageStateTracking) {
        if (!hosting) return;
        _state = DSStageStateOverlay;
        _window.hidden = NO;
    }
    DSDiagnosticsRecord(@"SpringBoard: tucking the open stage for home");
    if (DSFeature699On("spam700")) [self spam700Note:1 why:@"home tuck"];
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
    // 4.5.729 slide728: the cards slide out their nearest side with kb707's
    // side slide (the state above is already parked / minimised), then are put
    // in their corner and hidden exactly as before. Off: -slide728-off.
    BOOL slide = flying.count > 0 && _window && !_window.hidden && DSFeature699On("slide728");
    if (slide) {
        DSFeature719MarkAction("slide728");
        CGFloat midX = CGRectGetMidX([self screenBounds]);
        NSMutableArray<NSNumber *> *sides = [NSMutableArray array];
        for (DSStageContainerView *card in flying) {
            CGRect seen = (card == _container) ? [self primaryCardFrameInRoot] : [self frameWithoutKeyboardShift:card];
            CGFloat side = [self sideParkDistanceForCard:card goLeft:CGRectGetMidX(seen) <= midX + 0.5];
            [sides addObject:@(isfinite(side) ? side : 0.0)];
        }
        NSArray<DSStageContainerView *> *cards = [flying copy];
        [self kb707Animate:^{
            for (NSUInteger i = 0; i < cards.count; i++) [cards[i] setSideOffset:sides[i].doubleValue];
        }];
        __weak __typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kDSAnim702MinimiseDuration + 0.02) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong __typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            @try {
                for (DSStageContainerView *card in cards) {
                    if ([strongSelf cardIsParked:card] && strongSelf->_state != DSStageStateOverlay) {
                        [strongSelf slide728ParkHidden:card];
                    }
                    [UIView performWithoutAnimation:^{
                        [card setSideOffset:0.0];
                    }];
                }
                [UIView performWithoutAnimation:^{
                    [strongSelf updateOpenAppIcon];
                }];
            } @catch (NSException *exception) {
                DSDiagnosticsRecordFormat(@"SpringBoard: slide728 caught %@", exception.reason ?: exception.name);
            }
        });
        DSDiagnosticsRecordFormat(@"SpringBoard: slide728 home tuck: %lu card(s) slide out the side, then park in their corner", (unsigned long)cards.count);
        return;
    }
    for (DSStageContainerView *card in flying) {
        [self slide728ParkHidden:card];
    }
    [UIView performWithoutAnimation:^{
        [self updateOpenAppIcon];
    }];
}

// The tuck's end for one card (unchanged from before 4.5.729; shared with slide728).
- (void)slide728ParkHidden:(DSStageContainerView *)card {
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

- (void)noteHomeGestureBegan:(UIPanGestureRecognizer *)gesture {
    // 4.5.657: from here until the stage is next used the system owns the
    // screen (home, switcher). Replaces asking the switcher if it is visible.
    [DSSceneHost noteSystemTookScreen];
    DSHomeGestureGeneration += 1;
    NSInteger generation = DSHomeGestureGeneration;
    if (_stagedKeyboardSlot >= 0) {
        DSDiagnosticsRecord(@"SpringBoard: home gesture, putting the staged keyboard away");
        [self hideStagedKeyboardLikePicker];
    }
    [DSSceneHost setHomeGestureActive:YES];
    // Park first, and do not hand the app view to the home transition. That
    // handoff is the icon that keeps sliding after the card is gone.
    // 4.5.731 home731: a touch on the home bar began the gesture and tucked the
    // cards at once (Wow log: began -> ended 27-110 ms later). The tuck now waits
    // until the swipe commits: 40 pt up, or an upward release. Off: -home731-off.
    BOOL open731 = (_state == DSStageStateOverlay || _state == DSStageStateTracking) &&
                   ((_sceneHost.isHosting && !_primaryParked) || (_topSceneHost.isHosting && !_secondParked));
    if (gesture && open731 && DSFeature699On("home731")) {
        DSFeature719MarkAction("home731");
        _home731Pending = YES;
        [gesture addTarget:self action:@selector(home731Track:)];
    } else {
        _home731Pending = NO;
        [self tuckOpenStageAwayForHomeGesture];
    }
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

// 4.5.657: everything that used to run inside the app switcher (an app swiped
// away, the front app changing) is applied here, the next time the stage is
// used, never during the swipe.
- (void)noteStageUse {
    [DSSceneHost noteStageInUse];
    NSArray<NSString *> *dead = DSSceneHostTakeDiedBundles();
    for (NSString *bundle in dead) {
        DSDiagnosticsRecordFormat(@"SpringBoard: switcher657 %@ was closed outside the stage (switcher or crash); handled now, on stage use",
                                  bundle);
        [self noteSceneDestroyedForBundleIdentifier:bundle];
    }
    BOOL reload = NO;
    if (DSPendingFrontQuery) {
        DSPendingFrontQuery = NO;
        NSString *front = [self frontApplication].bundleIdentifier;
        if (front.length > 0 && ![front isEqualToString:@"com.apple.springboard"]) {
            if (!DSPendingOpenedBundles) DSPendingOpenedBundles = [NSMutableArray array];
            [DSPendingOpenedBundles removeObject:front];
            [DSPendingOpenedBundles addObject:front];
        }
    }
    if (DSPendingOpenedBundles.count > 0) {
        NSArray<NSString *> *opened = [DSPendingOpenedBundles copy];
        [DSPendingOpenedBundles removeAllObjects];
        DSPreferences *preferences = [DSPreferences sharedPreferences];
        for (NSString *bundle in opened) [preferences noteApplicationOpened:bundle];
        reload = YES;
    }
    if (reload) {
        if (_picker && !_sceneHost.isHosting) [_picker reloadContent];
        if (_topPicker && _topContainer && !_topContainer.hidden && !_topSceneHost.isHosting) {
            [_topPicker reloadContent];
        }
    }
}

- (void)noteDisplayDidTurnOff {
    // 4.5.652: a locked phone takes the staged camera's card out of the layout.
    [DSCameraArbiter refreshSoon];
    if (self.isStageVisible) [self minimizeAnimated:NO];
}

// 4.5.808 lock808: SpringBoard's own backlight transitions
// (-[SBBacklightController addObserver:] ->
// backlightController:didTransitionToBacklightState:source:, 20F75) are logged,
// and on screen-off the camera presence elements are re-checked at once
// (the part of noteDisplayDidTurnOff that is safe). The stage is NOT minimised
// on screen-off: fg801 already moves the app view Live -> Static when the
// scene backgrounds under the cover sheet, and a minimise here would run the
// corner-park path under the lock screen, which is what the lock + minimise
// blackouts came from. Off: lock808-off / core808-off (latch lock808).
- (void)lock808NoteBacklight:(long long)state source:(long long)source {
    if (!DS808On("lock808")) return;
    static BOOL marked = NO;
    if (!marked) { marked = YES; DSFeature699MarkTrying("lock808"); }
    DSFeature719MarkAction("lock808");
    BOOL on = YES;
    @try {
        id bl = [objc_getClass("SBBacklightController") respondsToSelector:@selector(sharedInstance)]
            ? ((id (*)(id, SEL))objc_msgSend)(objc_getClass("SBBacklightController"), @selector(sharedInstance)) : nil;
        if ([bl respondsToSelector:@selector(screenIsOn)]) on = ((BOOL (*)(id, SEL))objc_msgSend)(bl, @selector(screenIsOn));
    } @catch (NSException *exception) {}
    DSDiagnosticsRecordFormat(@"SpringBoard: lock808: screen %@ (backlight state %lld source %lld; stage visible=%d, cards left as they are)",
                              on ? @"on" : @"off", state, source, self.isStageVisible);
    if (!on) [DSCameraArbiter refreshSoon];
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
