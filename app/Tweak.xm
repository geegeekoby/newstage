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
// The keyboard is deliberately not one of those routes. Its window is hosted
// out of the card and shown by SpringBoard, at the full width of the display.
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

static CGRect DSStageBounds(void) {
    return [DSStageContext sharedContext].stageBounds;
}

// The real display, which is what the keyboard is laid out against however small the
// window this app was given.
static CGRect DSDeviceBounds(void) {
    return [DSStageContext sharedContext].deviceBounds;
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

// The keys are drawn by this app, then handed to SpringBoard. Telling UIKit the
// keyboard is remote makes it draw nothing on an iPhone, which is why the card
// kept its own keyboard. Hosting the text-effects window instead puts that same
// keyboard into SpringBoard's window, full width, outside the card.

static void DSPublishKeyboardContextID(unsigned int contextID) {
    static int token = NOTIFY_TOKEN_INVALID;
    static unsigned int last = 0xffffffffu;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_check(kDSKeyboardContextNotification, &token);
    });
    if (token == NOTIFY_TOKEN_INVALID || contextID == last) return;
    last = contextID;
    notify_set_state(token, contextID);
    notify_post(kDSKeyboardContextNotification);
}

static id DSSharedTextEffectsWindow(void) {
    Class windowClass = objc_getClass("UITextEffectsWindow");
    SEL shared = @selector(sharedTextEffectsWindow);
    if (![windowClass respondsToSelector:shared]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(windowClass, shared);
}

static unsigned int DSKeyboardContextID(void) {
    id window = DSSharedTextEffectsWindow();
    if (!window) return 0;
    SEL enable = @selector(setEnableRemoteHosting:);
    if ([window respondsToSelector:enable]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(window, enable, YES);
    }
    SEL sceneSize = @selector(setHostedSceneSize:);
    if ([window respondsToSelector:sceneSize]) {
        ((void (*)(id, SEL, CGSize))objc_msgSend)(window, sceneSize, DSDeviceBounds().size);
    }
    SEL context = @selector(contextID);
    if (![window respondsToSelector:context]) return 0;
    return ((unsigned int (*)(id, SEL))objc_msgSend)(window, context);
}

static NSUInteger DSKeyboardGeneration = 0;

static void DSPublishKeyboardContextSoon(void) {
    if (!DSStaged()) {
        DSKeyboardGeneration++;
        DSPublishKeyboardContextID(0);
        return;
    }
    NSUInteger generation = ++DSKeyboardGeneration;
    // The context id is zero until the keyboard window has been created.
    for (NSNumber *delay in @[ @0.0, @0.12, @0.35, @0.7 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (generation != DSKeyboardGeneration) return;
            if (!DSStaged()) {
                DSPublishKeyboardContextID(0);
                return;
            }
            unsigned int contextID = DSKeyboardContextID();
            if (contextID == 0) return;
            DSPublishKeyboardContextID(contextID);
        });
    }
}

%hook UITextEffectsWindow

+ (id)_sharedTextEffectsWindowforScreen:(id)screen
                        aboveStatusBar:(BOOL)above
                           allowHosted:(BOOL)allowHosted
  matchesStatusBarOrientationOnAccess:(BOOL)matches
             shouldCreateIfNecessary:(BOOL)create {
    if (DSStaged()) allowHosted = YES;
    return %orig;
}

- (BOOL)_shouldTextEffectsWindowBeHostedForView:(UIView *)view {
    if (DSStaged()) return YES;
    return %orig;
}

- (BOOL)enableRemoteHosting {
    if (DSStaged()) return YES;
    return %orig;
}

- (void)setFrame:(CGRect)frame {
    if (DSStaged()) frame = DSDeviceBounds();
    %orig;
}

- (CGSize)keyboardScreenReferenceSize {
    if (DSStaged()) return DSDeviceBounds().size;
    return %orig;
}

- (void)didAddSubview:(UIView *)subview {
    %orig;
    if (DSStaged()) DSPublishKeyboardContextSoon();
}

%end

%hook UIKeyboardImpl

- (void)showKeyboard {
    %orig;
    if (DSStaged()) DSPublishKeyboardContextSoon();
}

- (void)hideKeyboard {
    %orig;
    DSKeyboardGeneration++;
    DSPublishKeyboardContextID(0);
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
        if (DSStaged()) DSPublishKeyboardContextSoon();
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
