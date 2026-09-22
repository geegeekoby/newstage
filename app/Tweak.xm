#import "DSStageContext.h"
#import "DSAppPrivate.h"
#import "DSPreferences.h"
#import "DSConstants.h"
#import "DSExclusions.h"
#import "DSBootstrap.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
// Injected into every UIKit app. While this process is the one on the stage,
// every route UIKit offers for "how big is the screen" answers with the stage
// rectangle and the interface stays pinned to portrait.
//
// The keyboard is deliberately not one of those routes. While this process is
// staged, every keyboard view it owns is forced out of the card. SpringBoard
// shows the same keyboard the stage picker search uses, and keystrokes from
// that keyboard are inserted here.
//
// Apps that hard-code portrait phone geometry get a small amount of extra help
// at the bottom of the file.
//
// Nothing below is hooked until the app is actually put on the stage. The filter
// is UIKit, so this dylib loads into everything with a screen - including the
// package manager the tweak is installed from - and an app that is never staged
// has no use for any of it. Installing the hooks lazily means such a process
// carries one notification observer and no patched methods at all, so a mistake
// in here cannot reach an app that is not using the feature.

static BOOL DSStaged(void) {
    return [DSStageContext sharedContext].staged;
}

static void DSBanishLocalKeyboard(void);
static void DSRequestPickerKeyboard(BOOL show);

static int DSKeyboardWantGeneration = 0;
static int DSKeyboardRequestToken = NOTIFY_TOKEN_INVALID;
static NSInteger DSLastKeyboardInputSeq = 0;

static UIResponder *DSFirstResponderInView(UIView *view) {
    if (![view isKindOfClass:UIView.class]) return nil;
    if (view.isFirstResponder) return view;
    for (UIView *subview in view.subviews) {
        UIResponder *found = DSFirstResponderInView(subview);
        if (found) return found;
    }
    return nil;
}

static UIResponder *DSCurrentKeyInput(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        UIResponder *found = DSFirstResponderInView(window);
        if (found) return found;
    }
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                UIResponder *found = DSFirstResponderInView(window);
                if (found) return found;
            }
        }
    }
    return nil;
}

static void DSApplyKeyboardOp(NSString *op, NSString *text) {
    UIResponder *responder = DSCurrentKeyInput();
    if (!responder) return;
    if ([op isEqualToString:@"delete"]) {
        if ([responder respondsToSelector:@selector(deleteBackward)]) {
            [(id)responder deleteBackward];
        }
        return;
    }
    if (text.length == 0) return;
    if ([responder respondsToSelector:@selector(insertText:)]) {
        [(id)responder insertText:text];
    }
}

static void DSDrainKeyboardInput(void) {
    if (!DSStaged()) return;
    NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:kDSKeyboardInputPath];
    for (NSDictionary *op in root[@"ops"]) {
        if (![op isKindOfClass:NSDictionary.class]) continue;
        NSInteger seq = [op[@"seq"] integerValue];
        if (seq <= DSLastKeyboardInputSeq) continue;
        DSLastKeyboardInputSeq = seq;
        DSApplyKeyboardOp(op[@"op"], op[@"text"]);
    }
}

static void DSPostKeyboardRequest(BOOL show) {
    if (DSKeyboardRequestToken == NOTIFY_TOKEN_INVALID) {
        notify_register_check(kDSKeyboardRequestNotification, &DSKeyboardRequestToken);
    }
    if (DSKeyboardRequestToken == NOTIFY_TOKEN_INVALID) return;
    NSString *identifier = NSBundle.mainBundle.bundleIdentifier ?: @"";
    uint64_t state = DSIdentifierHash(identifier);
    if (show) state |= kDSStageStateActiveBit;
    notify_set_state(DSKeyboardRequestToken, state);
    notify_post(kDSKeyboardRequestNotification);
}

static void DSRequestPickerKeyboard(BOOL show) {
    if (!DSStaged()) return;
    DSKeyboardWantGeneration++;
    int generation = DSKeyboardWantGeneration;
    if (show) {
        DSPostKeyboardRequest(YES);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != DSKeyboardWantGeneration || !DSStaged()) return;
        DSPostKeyboardRequest(NO);
    });
}

static void DSKeyboardInputArrived(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                   const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        DSDrainKeyboardInput();
    });
}

static CGRect DSStageBounds(void) {
    return [DSStageContext sharedContext].stageBounds;
}

// A window a keyboard is drawn in - the text effects window and the remote keyboard
// window that inherits from it. Neither belongs to the card: the first is full screen
// over this app's own scene, the second is hosted by SpringBoard and lives on the
// display rather than in this process at all. Told how big the card is, both draw the
// keyboard inside the card, so neither is ever told.
static BOOL DSIsKeyboardWindow(UIWindow *window) {
    if (!window) return NO;
    if ([window respondsToSelector:@selector(_isTextEffectsWindow)] && [window _isTextEffectsWindow]) return YES;
    if ([window respondsToSelector:@selector(_isRemoteKeyboardWindow)] && [window _isRemoteKeyboardWindow]) return YES;
    Class effects = objc_getClass("UITextEffectsWindow");
    return effects != Nil && [window isKindOfClass:effects];
}

#pragma mark - Screen

%hook UIScreen

- (CGRect)bounds {
    if (DSStaged() && self == UIScreen.mainScreen) return DSStageBounds();
    return %orig;
}

- (CGRect)_referenceBounds {
    if (DSStaged() && self == UIScreen.mainScreen) return DSStageBounds();
    return %orig;
}

- (CGRect)applicationFrame {
    if (DSStaged() && self == UIScreen.mainScreen) return DSStageBounds();
    return %orig;
}

%end

#pragma mark - Application frame

%hook UIApplication

- (CGRect)_applicationFrameForInterfaceOrientation:(NSInteger)orientation
                              usingStatusbarHeight:(CGFloat)height
                                   ignoreStatusBar:(BOOL)ignore {
    if (DSStaged()) return DSStageBounds();
    return %orig;
}

- (CGRect)_applicationFrameWithoutOverscanForInterfaceOrientation:(NSInteger)orientation
                                             usingStatusbarHeight:(CGFloat)height
                                                  ignoreStatusBar:(BOOL)ignore {
    if (DSStaged()) return DSStageBounds();
    return %orig;
}

- (UIInterfaceOrientation)statusBarOrientation {
    if (DSStaged()) return UIInterfaceOrientationPortrait;
    return %orig;
}

- (BOOL)isStatusBarHidden {
    if (DSStaged()) return YES;
    return %orig;
}

%end

#pragma mark - Windows

%hook UIWindow

- (CGRect)_boundsForInterfaceOrientation:(NSInteger)orientation {
    if (DSStaged() && !DSIsKeyboardWindow(self)) return DSStageBounds();
    return %orig;
}

- (CGRect)_referenceBounds {
    if (DSStaged() && !DSIsKeyboardWindow(self)) return DSStageBounds();
    return %orig;
}

- (CGRect)_sceneBounds {
    if (DSStaged() && !DSIsKeyboardWindow(self)) return DSStageBounds();
    return %orig;
}

- (BOOL)_shouldResizeWithScene {
    if (DSStaged() && !DSIsKeyboardWindow(self)) return YES;
    return %orig;
}

- (BOOL)_shouldAdjustSizeClassesAndResizeWindow {
    if (DSStaged() && !DSIsKeyboardWindow(self)) return YES;
    return %orig;
}

// Letting the window believe it owns the orientation is what stops UIKit from
// rotating the stage when the device turns.
- (BOOL)_windowOwnsInterfaceOrientation {
    if (DSStaged()) return NO;
    return %orig;
}

- (BOOL)_transformLayerRotationsAreEnabled {
    if (DSStaged()) return NO;
    return %orig;
}

// Refreshed on the way in as well as on the way out: the layout UIKit does inside
// this call asks the hooks above how big the scene is, and the answer they have is
// the one from before the resize that caused it.
- (void)_sceneBoundsDidChange {
    if (DSStaged()) [[DSStageContext sharedContext] refresh];
    %orig;
    if (DSStaged()) [[DSStageContext sharedContext] refresh];
}

- (void)didAddSubview:(UIView *)subview {
    %orig;
    if (DSStaged()) DSBanishLocalKeyboard();
}

%end

#pragma mark - Orientation

%hook UIDevice

- (UIDeviceOrientation)orientation {
    if (DSStaged()) return UIDeviceOrientationPortrait;
    return %orig;
}

- (UIUserInterfaceIdiom)userInterfaceIdiom {
    if (DSStaged() && [DSStageContext sharedContext].padMode) return UIUserInterfaceIdiomPad;
    return %orig;
}

%end

%hook UIViewController

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    if (DSStaged()) return UIInterfaceOrientationMaskPortrait;
    return %orig;
}

- (BOOL)shouldAutorotate {
    if (DSStaged()) return NO;
    return %orig;
}

- (void)attemptRotationToDeviceOrientation {
    if (DSStaged()) return;
    %orig;
}

%end

#pragma mark - Keyboard

// The keys are drawn in UITextEffectsWindow. That window is not in
// UIApplication.windows, and the keyboard views do not go through UIView's
// setHidden:, which is why a one-shot hide never stuck. While this process is
// staged, those views are pulled out of the card on every pass UIKit uses to
// put them back, and again before the run loop sleeps.

static BOOL DSBanishing = NO;
static NSUInteger DSBanishHits = 0;
static BOOL DSBanishFoundChrome = NO;

static BOOL DSNameIsLocalKeyboard(NSString *name) {
    if (name.length == 0) return NO;
    if ([name hasPrefix:@"UIKeyboard"]) return YES;
    if ([name hasPrefix:@"UIInputSet"]) return YES;
    if ([name hasPrefix:@"UIKB"]) return YES;
    if ([name hasPrefix:@"UIRemoteKeyboard"]) return YES;
    if ([name hasPrefix:@"TUIKeyboard"]) return YES;
    if ([name hasPrefix:@"UICandidate"]) return YES;
    if ([name hasPrefix:@"UIPrediction"]) return YES;
    return NO;
}

static BOOL DSWindowIsKeyboardChrome(UIWindow *window) {
    if (!window) return NO;
    if (DSIsKeyboardWindow(window)) return YES;
    NSString *name = NSStringFromClass(object_getClass(window));
    if ([name rangeOfString:@"Keyboard"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"TextEffects"].location != NSNotFound) return YES;
    return NO;
}

static void DSSuppressKeyboardView(UIView *view) {
    DSBanishHits++;
    if (!view.layer.hidden || view.layer.opacity > 0.01) {
        [view.layer removeAllAnimations];
        view.layer.hidden = YES;
        view.layer.opacity = 0;
    }
    if (view.userInteractionEnabled) view.userInteractionEnabled = NO;
    if (!view.hidden) view.hidden = YES;
    if (CGRectGetMinY(view.frame) < 8000.0) {
        CGRect frame = view.frame;
        frame.origin.y = 10000.0;
        view.frame = frame;
    }
}

static void DSBanishKeyboardInView(UIView *view, CGRect windowBounds, BOOL inKeyboardWindow, NSInteger depth) {
    if (depth > (inKeyboardWindow ? 8 : 3) || ![view isKindOfClass:UIView.class]) return;
    NSString *name = NSStringFromClass(object_getClass(view));
    CGRect frame = view.frame;
    // A keyboard sitting on the bottom edge of this window, including one that
    // fills most of a short stage. The caret is too small to match.
    BOOL bottomSlab = inKeyboardWindow &&
                      CGRectGetHeight(frame) >= 100.0 &&
                      CGRectGetWidth(frame) >= CGRectGetWidth(windowBounds) * 0.5 &&
                      CGRectGetMaxY(frame) >= CGRectGetHeight(windowBounds) - 8.0 &&
                      CGRectGetMinY(frame) > 40.0 &&
                      CGRectGetMinY(frame) < 8000.0;
    if (DSNameIsLocalKeyboard(name) || bottomSlab) {
        DSSuppressKeyboardView(view);
        return;
    }
    for (UIView *subview in view.subviews) {
        DSBanishKeyboardInView(subview, windowBounds, inKeyboardWindow, depth + 1);
    }
}

static void DSBanishKeyboardLayers(CALayer *layer, CGRect windowBounds) {
    if (!layer) return;
    NSString *name = NSStringFromClass(object_getClass(layer));
    id delegate = layer.delegate;
    NSString *delegateName = nil;
    if ([delegate isKindOfClass:UIView.class]) {
        delegateName = NSStringFromClass(object_getClass((UIView *)delegate));
    }
    CGRect frame = layer.frame;
    BOOL bottomSlab = CGRectGetHeight(frame) >= 100.0 &&
                      CGRectGetWidth(frame) >= CGRectGetWidth(windowBounds) * 0.5 &&
                      CGRectGetMaxY(frame) >= CGRectGetHeight(windowBounds) - 8.0 &&
                      CGRectGetMinY(frame) > 40.0 &&
                      CGRectGetMinY(frame) < 8000.0;
    if (DSNameIsLocalKeyboard(name) || DSNameIsLocalKeyboard(delegateName) || bottomSlab) {
        if (!layer.hidden || layer.opacity > 0.01) {
            [layer removeAllAnimations];
            layer.hidden = YES;
            layer.opacity = 0;
        }
        if (CGRectGetMinY(layer.frame) < 8000.0) {
            CGRect moved = layer.frame;
            moved.origin.y = 10000.0;
            layer.frame = moved;
        }
        return;
    }
    for (CALayer *sublayer in layer.sublayers) {
        DSBanishKeyboardLayers(sublayer, windowBounds);
    }
}

static void DSVisitLiveWindows(void (^visitor)(UIWindow *window)) {
    NSMutableSet *seen = [NSMutableSet set];
    void (^visit)(UIWindow *) = ^(UIWindow *window) {
        if (![window isKindOfClass:UIWindow.class] || [seen containsObject:window]) return;
        [seen addObject:window];
        visitor(window);
    };

    for (UIWindow *window in UIApplication.sharedApplication.windows) visit(window);
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) visit(window);
        }
    }

    Class effects = objc_getClass("UITextEffectsWindow");
    for (NSString *selectorName in @[
        @"sharedTextEffectsWindow",
        @"sharedTextEffectsWindowForWindowScene:",
        @"_sharedTextEffectsWindowAboveStatusBar"
    ]) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![effects respondsToSelector:selector]) continue;
        @try {
            if ([selectorName hasSuffix:@":"]) {
                for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                    visit(((id (*)(id, SEL, id))objc_msgSend)(effects, selector, scene));
                }
            } else {
                visit(((id (*)(id, SEL))objc_msgSend)(effects, selector));
            }
        } @catch (NSException *exception) {
        }
    }

    Class remote = objc_getClass("UIRemoteKeyboardWindow");
    SEL create = @selector(remoteKeyboardWindowForScreen:create:);
    if ([remote respondsToSelector:create]) {
        @try {
            visit(((id (*)(id, SEL, id, BOOL))objc_msgSend)(remote, create, UIScreen.mainScreen, NO));
        } @catch (NSException *exception) {
        }
    }
}

static void DSReportKeyboardDebug(NSString *windowNames) {
    static int token = NOTIFY_TOKEN_INVALID;
    static uint64_t lastState = 0;
    static NSString *lastNames = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_check(kDSKeyboardDebugNotification, &token);
    });
    NSString *identifier = NSBundle.mainBundle.bundleIdentifier ?: @"";
    BOOL staged = DSStaged();
    uint64_t state = DSIdentifierHash(identifier);
    if (staged) state |= kDSStageStateActiveBit;
    if (DSBanishFoundChrome) state |= (1ULL << 33);
    state |= (uint64_t)MIN(DSBanishHits, (NSUInteger)255) << 40;
    BOOL changed = state != lastState || (windowNames.length > 0 && ![windowNames isEqualToString:lastNames]);
    if (!changed) return;
    lastState = state;
    lastNames = [windowNames copy];
    if (token != NOTIFY_TOKEN_INVALID) {
        notify_set_state(token, state);
        notify_post(kDSKeyboardDebugNotification);
    }
    // A separate file so this cannot overwrite the stage list SpringBoard publishes.
    NSString *summary = [NSString stringWithFormat:@"%@ staged=%d chrome=%d hid=%lu windows=%@",
                         identifier, staged, DSBanishFoundChrome, (unsigned long)DSBanishHits,
                         windowNames ?: @"?"];
    [summary writeToFile:@"/var/mobile/Library/Preferences/com.recreated.dynamicstage.keyboard.txt"
              atomically:YES
                encoding:NSUTF8StringEncoding
                   error:nil];
}

static void DSBanishLocalKeyboard(void) {
    if (!DSStaged() || DSBanishing) return;
    DSBanishing = YES;
    DSBanishHits = 0;
    DSBanishFoundChrome = NO;
    NSMutableArray *names = [NSMutableArray array];
    @try {
        DSVisitLiveWindows(^(UIWindow *window) {
            NSString *name = NSStringFromClass(object_getClass(window));
            if (names.count < 8 && name.length) [names addObject:name];
            BOOL chrome = DSWindowIsKeyboardChrome(window);
            if (chrome) DSBanishFoundChrome = YES;
            if (chrome && [name rangeOfString:@"RemoteKeyboard"].location != NSNotFound) {
                DSSuppressKeyboardView(window);
                return;
            }
            CGRect bounds = window.bounds;
            DSBanishKeyboardInView(window, bounds, chrome, 0);
            if (chrome) DSBanishKeyboardLayers(window.layer, bounds);
        });
    } @catch (NSException *exception) {
    }
    DSBanishing = NO;
    DSReportKeyboardDebug([names componentsJoinedByString:@","]);
}

static void DSInstallKeyboardBanishObserver(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CFRunLoopObserverRef observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            kCFRunLoopBeforeWaiting,
            true,
            0,
            ^(CFRunLoopObserverRef observer, CFRunLoopActivity activity) {
                (void)observer;
                (void)activity;
                DSBanishLocalKeyboard();
            });
        if (observer) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
        }
    });
}

%hook UIView

- (void)setHidden:(BOOL)hidden {
    if (DSStaged() && DSNameIsLocalKeyboard(NSStringFromClass(object_getClass(self)))) hidden = YES;
    %orig;
}

- (void)didMoveToWindow {
    %orig;
    if (DSStaged() && DSNameIsLocalKeyboard(NSStringFromClass(object_getClass(self)))) {
        DSSuppressKeyboardView(self);
    }
}

%end

%hook UITextEffectsWindow

- (void)layoutSubviews {
    %orig;
    if (DSStaged()) DSBanishLocalKeyboard();
}

- (void)setFrame:(CGRect)frame {
    %orig;
    if (DSStaged()) DSBanishLocalKeyboard();
}

- (void)didAddSubview:(UIView *)subview {
    %orig;
    if (DSStaged()) DSBanishLocalKeyboard();
}

%end

%hook UIKeyboardImpl

+ (BOOL)isUsingRemoteKeyboard {
    if (DSStaged()) return YES;
    return %orig;
}

- (BOOL)isUsingRemoteKeyboard {
    if (DSStaged()) return YES;
    return %orig;
}

- (void)showKeyboard {
    %orig;
    if (!DSStaged()) return;
    DSBanishLocalKeyboard();
    DSRequestPickerKeyboard(YES);
}

- (void)hideKeyboard {
    %orig;
    if (DSStaged()) DSRequestPickerKeyboard(NO);
}

%end

%hook UITextField

- (BOOL)resignFirstResponder {
    BOOL wasEditing = self.isFirstResponder;
    BOOL resigned = %orig;
    if (wasEditing && resigned && DSStaged()) DSRequestPickerKeyboard(NO);
    return resigned;
}

%end

%hook UITextView

- (BOOL)resignFirstResponder {
    BOOL wasEditing = self.isFirstResponder;
    BOOL resigned = %orig;
    if (wasEditing && resigned && DSStaged()) DSRequestPickerKeyboard(NO);
    return resigned;
}

%end

#pragma mark - Presentation

// Full screen presentations measure themselves against the screen, so they need
// the same answer the windows now give.
%hook _UIFullscreenPresentationController

- (CGRect)frameOfPresentedViewInContainerView {
    CGRect frame = %orig;
    if (!DSStaged()) return frame;
    CGRect stage = DSStageBounds();
    frame.origin = CGPointZero;
    frame.size = stage.size;
    return frame;
}

%end

#pragma mark - Per-app fixes

// Twitter pins a container to the portrait screen bounds it captured at launch
// and shows toasts in their own screen-sized window.
%hook TFNPortraitScreenBoundsLockedContainerView

- (void)layoutSubviews {
    if (DSStaged()) self.frame = DSStageBounds();
    %orig;
}

%end

%hook TFNToastWindow

- (void)setFrame:(CGRect)frame {
    if (DSStaged()) frame = DSStageBounds();
    %orig;
}

%end

// TikTok's feed sizes its cells once against the screen and caches the result,
// so it has to be told to measure again after the stage resizes it.
%hook AWEFeedTableView

- (void)layoutSubviews {
    %orig;
    if (!DSStaged()) return;

    NSValue *previous = objc_getAssociatedObject(self, _cmd);
    CGSize size = self.bounds.size;
    if (previous && CGSizeEqualToSize(previous.CGSizeValue, size)) return;
    objc_setAssociatedObject(self, _cmd, [NSValue valueWithCGSize:size], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (previous && [self respondsToSelector:@selector(reloadData)]) {
        [(UITableView *)self reloadData];
    }
}

%end

// Messages' entry view anchors its accessory row to the screen width.
%hook CKMessageEntryView

- (void)layoutSubviews {
    if (DSStaged()) {
        CGRect frame = self.frame;
        frame.size.width = CGRectGetWidth(DSStageBounds());
        frame.origin.x = 0;
        self.frame = frame;
    }
    %orig;
}

%end

// Safari view service lays its navigation bar out from the screen width.
%hook _SFBrowserNavigationBar

- (void)layoutSubviews {
    if (DSStaged()) {
        CGRect frame = self.frame;
        frame.size.width = CGRectGetWidth(DSStageBounds());
        self.frame = frame;
    }
    %orig;
}

%end

#pragma mark - Entry point

static void DSInstallHooks(void) {
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        %init(_ungrouped);
        DSInstallKeyboardBanishObserver();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        DSKeyboardInputArrived,
                                        CFSTR(kDSKeyboardInputNotification),
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    });
}

static void DSStartObserving(void) {
    DSStageContext *context = [DSStageContext sharedContext];
    context.stagedHandler = ^{
        DSInstallHooks();
    };
    [context startObserving];
}

%ctor {
    @autoreleasepool {
        @try {
            if (DSKillSwitchPresent()) return;
            if (!DSBundleLooksLikeUserApplication()) return;
            if (![DSPreferences sharedPreferences].enabled) return;

            if ([DSStageContext processIsStagedNow]) {
                DSStartObserving();
                DSInstallHooks();
                return;
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    if (!DSBundleLooksLikeUserApplication()) return;
                    DSStartObserving();
                } @catch (NSException *exception) {
                }
            });
        } @catch (NSException *exception) {
        }
    }
}
