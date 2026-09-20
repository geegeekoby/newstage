#import "DSStageContext.h"
#import "DSAppPrivate.h"
#import "DSPreferences.h"
#import "DSConstants.h"
#import "DSExclusions.h"
#import <objc/runtime.h>
#import <objc/message.h>

// Injected into every UIKit app. While this process is the one on the stage,
// every route UIKit offers for "how big is the screen" answers with the stage
// rectangle, the interface stays pinned to portrait, and the keyboard is kept
// inside the card instead of floating over the app behind it.
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
    if (DSStaged()) return DSStageBounds();
    return %orig;
}

- (CGRect)_referenceBounds {
    if (DSStaged()) return DSStageBounds();
    return %orig;
}

- (CGRect)_sceneBounds {
    if (DSStaged()) return DSStageBounds();
    return %orig;
}

- (BOOL)_shouldResizeWithScene {
    if (DSStaged()) return YES;
    return %orig;
}

- (BOOL)_shouldAdjustSizeClassesAndResizeWindow {
    if (DSStaged()) return YES;
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

- (void)_sceneBoundsDidChange {
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

// The text effects window is a sibling of the app's own windows and is sized from
// the screen, so without this the keyboard draws outside the card.
%hook UITextEffectsWindow

- (void)setFrame:(CGRect)frame {
    if (DSStaged()) {
        CGRect stage = DSStageBounds();
        frame.origin = CGPointZero;
        frame.size.width = CGRectGetWidth(stage);
        if (CGRectGetHeight(frame) > CGRectGetHeight(stage)) frame.size.height = CGRectGetHeight(stage);
    }
    %orig;
}

- (CGRect)_boundsForInterfaceOrientation:(NSInteger)orientation {
    if (DSStaged()) return DSStageBounds();
    return %orig;
}

%end

%hook UIInputSetHostView

- (void)setFrame:(CGRect)frame {
    if (DSStaged()) {
        frame.size.width = CGRectGetWidth(DSStageBounds());
        frame.origin.x = 0;
    }
    %orig;
}

%end

%hook UIInputResponderController

- (CGRect)_sceneBounds {
    if (DSStaged()) return DSStageBounds();
    return %orig;
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

// Called once, the first time this process is put on the stage.
static void DSInstallHooks(void) {
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        %init(_ungrouped);
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
            if ([[NSFileManager defaultManager] fileExistsAtPath:kDSKillSwitchPath]) return;

            NSString *identifier = NSBundle.mainBundle.bundleIdentifier;
            if (DSIdentifierIsExcludedFromStage(identifier)) return;
            if (![DSPreferences sharedPreferences].enabled) return;

            if ([DSStageContext processIsStagedNow]) {
                // Launched onto the stage: the hooks have to be in place before
                // this app lays anything out, so its first frame is the right
                // size rather than a full screen one that snaps.
                DSStartObserving();
                DSInstallHooks();
                return;
            }

            // Every other app - which is nearly all of them, nearly all of the
            // time - gets left alone until the run loop is going. A constructor
            // runs while the app is still assembling itself, and none of this is
            // needed that early.
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    DSStartObserving();
                } @catch (NSException *exception) {
                }
            });
        } @catch (NSException *exception) {
        }
    }
}
