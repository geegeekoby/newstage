#import "DSStageContext.h"
#import "DSStageContainerView.h"
#import "DSKeyboardVisibility.h"
#import "DSConstants.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@implementation DSStageContext {
    DSStageContainerView *_stageView;
    UIViewController *_hostedViewController;
    BOOL _hostingApp;
    CGFloat _keyboardBandHeight;
    CGFloat _liftOffset;
}

- (instancetype)initWithStageView:(DSStageContainerView *)stageView {
    if ((self = [super init])) {
        _stageView = stageView;
        _hostingApp = NO;
        _keyboardBandHeight = 0.0;
        _liftOffset = 0.0;
    }
    return self;
}

- (BOOL)isHostingApp {
    return _hostingApp;
}

- (UIView *)hostedContentView {
    return _stageView.contentView;
}

- (void)attachHostedApp:(UIViewController *)viewController {
    if (!viewController) return;

    _hostedViewController = viewController;
    _hostingApp = YES;

    UIView *hostedView = viewController.view;
    hostedView.frame = _stageView.bounds;
    hostedView.clipsToBounds = YES;

    [_stageView.contentView addSubview:hostedView];
    [_stageView setHostingApp:YES];

    [_stageView setNeedsLayout];
    [_stageView layoutIfNeeded];
}

- (void)detachHostedApp {
    if (!_hostingApp) return;

    [_hostedViewController.view removeFromSuperview];
    _hostedViewController = nil;
    _hostingApp = NO;

    [_stageView setHostingApp:NO];
    [_stageView setNeedsLayout];
    [_stageView layoutIfNeeded];
}

#pragma mark - Keyboard Band

- (void)setKeyboardBandHeight:(CGFloat)height {
    CGFloat clamped = MAX(height, 0.0);
    if (fabs(_keyboardBandHeight - clamped) < 0.5) return;

    _keyboardBandHeight = clamped;
    _stageView.keyboardBandHeight = clamped;

    [_stageView setNeedsLayout];
    [_stageView layoutIfNeeded];
}

- (void)updateKeyboardBand {
    CGRect keys = DSVisibleKeyboardFrameOnScreen();
    if (CGRectIsNull(keys)) {
        [self setKeyboardBandHeight:0.0];
        return;
    }

    CGFloat screenHeight = UIScreen.mainScreen.bounds.size.height;
    CGFloat bandHeight = screenHeight - CGRectGetMinY(keys);

    [self setKeyboardBandHeight:bandHeight];
}

#pragma mark - Lift Offset

- (void)setLiftOffset:(CGFloat)offset {
    _liftOffset = offset;
    _stageView.liftOffset = offset;

    [_stageView setNeedsLayout];
    [_stageView layoutIfNeeded];
}

- (void)resetLiftOffset {
    _liftOffset = 0.0;
    _stageView.liftOffset = 0.0;

    [_stageView setNeedsLayout];
    [_stageView layoutIfNeeded];
}

#pragma mark - Keyboard Suppression

static BOOL DSNameIsLocalKeyboard(NSString *name) {
    if (!name.length) return NO;
    if ([name hasPrefix:@"UIKeyboard"]) return YES;
    if ([name hasPrefix:@"UIInputSet"]) return YES;
    if ([name containsString:@"Candidate"]) return YES;
    if ([name containsString:@"Prediction"]) return YES;
    return NO;
}

static void DSSuppressKeyboardView(UIView *view) {
    [view.layer removeAllAnimations];
    view.layer.hidden = YES;
    view.layer.opacity = 0.0f;
    view.userInteractionEnabled = NO;

    UIWindow *window = view.window;
    if (window) window.userInteractionEnabled = NO;
}

static void DSBanishKeyboardSubviews(UIView *view) {
    NSString *name = NSStringFromClass(object_getClass(view));
    if (DSNameIsLocalKeyboard(name)) {
        DSSuppressKeyboardView(view);
        return;
    }

    for (UIView *child in view.subviews) {
        DSBanishKeyboardSubviews(child);
    }
}

static void DSBanishLocalKeyboard(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        NSString *name = NSStringFromClass(object_getClass(window));
        if (![name containsString:@"Keyboard"] &&
            ![name containsString:@"TextEffects"]) continue;

        window.userInteractionEnabled = NO;

        for (UIView *sub in window.subviews) {
            DSBanishKeyboardSubviews(sub);
        }
    }
}

#pragma mark - UIKit Hooks

%hook UIApplication
- (void)sendEvent:(UIEvent *)event {
    %orig;
    DSBanishLocalKeyboard();
}
%end

%hook UIView
- (void)setNeedsLayout {
    %orig;
    DSBanishLocalKeyboard();
}
%end

@end
