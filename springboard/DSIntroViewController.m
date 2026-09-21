#import "DSIntroViewController.h"
#import "DSPreferences.h"
#import "DSConstants.h"
#import "DSLogoView.h"
#import "DSIntroDemoView.h"
#import <objc/runtime.h>

static UIWindow *sIntroWindow;

@interface DSIntroViewController ()
@property (nonatomic, assign) NSTimeInterval lastInteraction;
- (void)startIdleWatchdog;
- (void)noteInteraction;
@end

@interface DSIntroWindow : UIWindow
@end

@implementation DSIntroWindow
@end

@interface DSIntroStep : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *body;
@property (nonatomic, assign) DSIntroDemo demo;
@end

@implementation DSIntroStep
+ (instancetype)stepWithTitle:(NSString *)title body:(NSString *)body demo:(DSIntroDemo)demo {
    DSIntroStep *step = [[DSIntroStep alloc] init];
    step.title = title;
    step.body = body;
    step.demo = demo;
    return step;
}
@end

@implementation DSIntroViewController {
    UIVisualEffectView *_backdrop;
    DSLogoView *_logo;
    UILabel *_wordmark;
    UILabel *_title;
    UILabel *_body;
    DSIntroDemoView *_demo;
    UIButton *_primary;
    UIButton *_secondary;
    UIView *_pageDots;
    NSMutableArray<UIView *> *_dots;

    NSArray<DSIntroStep *> *_steps;
    NSInteger _step;
    NSTimer *_watchdog;
}

+ (BOOL)isPresenting {
    return sIntroWindow != nil;
}

+ (void)presentIntro {
    if (sIntroWindow) return;

    // Written now rather than when the walkthrough is finished. It covers the
    // whole screen at alert level, so if anything in here ever went wrong it
    // would be in the way of the entire device - and then the one thing that must
    // be true is that restarting gets rid of it instead of bringing it back.
    // "Show Walkthrough" in Settings is how it is seen again on purpose.
    [[DSPreferences sharedPreferences] setIntroShown:YES];

    @try {
        DSIntroViewController *controller = [[DSIntroViewController alloc] init];

        UIWindowScene *scene = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
                if ([candidate isKindOfClass:UIWindowScene.class]) {
                    scene = (UIWindowScene *)candidate;
                    break;
                }
            }
        }

        DSIntroWindow *window = scene ? [[DSIntroWindow alloc] initWithWindowScene:scene]
                                      : [[DSIntroWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        window.frame = UIScreen.mainScreen.bounds;
        window.windowLevel = UIWindowLevelAlert + 20.0;
        window.rootViewController = controller;
        window.backgroundColor = UIColor.clearColor;
        window.opaque = NO;
        sIntroWindow = window;

        window.alpha = 0.0;
        [window makeKeyAndVisible];
        [UIView animateWithDuration:0.45 animations:^{
            window.alpha = 1.0;
        }];

        [controller startIdleWatchdog];
    } @catch (NSException *exception) {
        // A half built walkthrough would be an opaque sheet with no buttons on it,
        // covering everything. Take it straight back down.
        UIWindow *window = sIntroWindow;
        sIntroWindow = nil;
        window.hidden = YES;
        window.rootViewController = nil;
    }
}

#pragma mark - Getting out of the way

// Nothing else can be used while this is up, so it must not be able to stay up.
// Three minutes without a touch and it leaves on its own; a two-finger double tap
// dismisses it immediately, wherever the buttons ended up.
- (void)startIdleWatchdog {
    _lastInteraction = NSDate.timeIntervalSinceReferenceDate;

    UITapGestureRecognizer *escape = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                            action:@selector(finish)];
    escape.numberOfTouchesRequired = 2;
    escape.numberOfTapsRequired = 2;
    [self.view addGestureRecognizer:escape];

    __weak __typeof(self) weakSelf = self;
    _watchdog = [NSTimer scheduledTimerWithTimeInterval:30.0 repeats:YES block:^(NSTimer *timer) {
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || sIntroWindow != strongSelf.view.window) {
            [timer invalidate];
            return;
        }
        if (NSDate.timeIntervalSinceReferenceDate - strongSelf.lastInteraction > 180.0) {
            [timer invalidate];
            [strongSelf finish];
        }
    }];
}

- (void)noteInteraction {
    _lastInteraction = NSDate.timeIntervalSinceReferenceDate;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    [self noteInteraction];
}

#pragma mark - Lifecycle

- (BOOL)prefersStatusBarHidden {
    return NO;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskPortrait;
}

- (BOOL)shouldAutorotate {
    return NO;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    _steps = @[
        [DSIntroStep stepWithTitle:@"Dynamic Stage"
                              body:@"Stage Manager, reimagined for iPhone. Run a second app on top of the one you are already using."
                              demo:DSIntroDemoNone],
        [DSIntroStep stepWithTitle:@"Pull from the corner"
                              body:@"Swipe up from the bottom-right corner of any app. The stage follows your finger the whole way."
                              demo:DSIntroDemoPull],
        [DSIntroStep stepWithTitle:@"Pick an app"
                              body:@"Recently opened apps sit at the top, your whole library below. Tap one and it loads right there on the stage."
                              demo:DSIntroDemoPick],
        [DSIntroStep stepWithTitle:@"Float or split"
                              body:@"Let go early and the stage floats over your app. Keep pulling and the app behind resizes into a true split view."
                              demo:DSIntroDemoSplit],
        [DSIntroStep stepWithTitle:@"Hold for fullscreen"
                              body:@"Press and hold an app in the list instead of tapping it and it opens across the whole screen, no stage involved."
                              demo:DSIntroDemoFullscreen],
        [DSIntroStep stepWithTitle:@"Put it away"
                              body:@"Swipe inward from the stage's bottom-right corner to drop the app and get the list back. Drag that corner down instead and the stage leaves, app still running."
                              demo:DSIntroDemoPutAway],
        [DSIntroStep stepWithTitle:@"You are all set"
                              body:@"Everything is tunable in Settings: appearance, pinned apps, per-app behaviour and when background apps get closed."
                              demo:DSIntroDemoNone],
    ];

    UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    _backdrop = [[UIVisualEffectView alloc] initWithEffect:effect];
    _backdrop.frame = self.view.bounds;
    _backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_backdrop];

    UIView *scrim = [[UIView alloc] initWithFrame:self.view.bounds];
    scrim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.62];
    scrim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:scrim];

    _logo = [[DSLogoView alloc] initWithFrame:CGRectZero];
    [self.view addSubview:_logo];

    _wordmark = [self labelWithFont:[UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold]
                              color:[UIColor colorWithWhite:1.0 alpha:0.45]];
    _wordmark.text = @"DYNAMIC STAGE";
    [self.view addSubview:_wordmark];

    _demo = [[DSIntroDemoView alloc] initWithFrame:CGRectZero];
    [self.view addSubview:_demo];

    _title = [self labelWithFont:[UIFont systemFontOfSize:31.0 weight:UIFontWeightBold]
                           color:UIColor.whiteColor];
    _title.numberOfLines = 2;
    [self.view addSubview:_title];

    _body = [self labelWithFont:[UIFont systemFontOfSize:16.0 weight:UIFontWeightRegular]
                          color:[UIColor colorWithWhite:1.0 alpha:0.68]];
    _body.numberOfLines = 0;
    [self.view addSubview:_body];

    _pageDots = [[UIView alloc] initWithFrame:CGRectZero];
    [self.view addSubview:_pageDots];
    _dots = [NSMutableArray array];
    for (NSUInteger index = 0; index < _steps.count; index++) {
        UIView *dot = [[UIView alloc] initWithFrame:CGRectZero];
        dot.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.25];
        dot.layer.cornerRadius = 3.0;
        [_pageDots addSubview:dot];
        [_dots addObject:dot];
    }

    _primary = [UIButton buttonWithType:UIButtonTypeSystem];
    _primary.backgroundColor = UIColor.whiteColor;
    _primary.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    [_primary setTitleColor:UIColor.blackColor forState:UIControlStateNormal];
    _primary.layer.cornerRadius = 15.0;
    _primary.layer.cornerCurve = kCACornerCurveContinuous;
    [_primary addTarget:self action:@selector(advance) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_primary];

    _secondary = [UIButton buttonWithType:UIButtonTypeSystem];
    _secondary.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
    [_secondary setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.5] forState:UIControlStateNormal];
    [_secondary setTitle:@"Skip" forState:UIControlStateNormal];
    [_secondary addTarget:self action:@selector(finish) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_secondary];

    UISwipeGestureRecognizer *forward = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(advance)];
    forward.direction = UISwipeGestureRecognizerDirectionLeft;
    [self.view addGestureRecognizer:forward];

    UISwipeGestureRecognizer *back = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(retreat)];
    back.direction = UISwipeGestureRecognizerDirectionRight;
    [self.view addGestureRecognizer:back];

    [self applyStep:0 animated:NO];
}

- (UILabel *)labelWithFont:(UIFont *)font color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.font = font;
    label.textColor = color;
    label.textAlignment = NSTextAlignmentCenter;
    return label;
}

#pragma mark - Layout

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGRect bounds = self.view.bounds;
    UIEdgeInsets safe = self.view.safeAreaInsets;
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat margin = 30.0;
    CGFloat contentWidth = width - margin * 2.0;

    CGFloat logoSide = 34.0;
    _logo.frame = CGRectMake(margin, safe.top + 14.0, logoSide, logoSide);
    _wordmark.textAlignment = NSTextAlignmentLeft;
    [_wordmark sizeToFit];
    _wordmark.frame = CGRectMake(CGRectGetMaxX(_logo.frame) + 10.0,
                                 CGRectGetMidY(_logo.frame) - CGRectGetHeight(_wordmark.bounds) / 2.0,
                                 contentWidth - logoSide - 10.0,
                                 CGRectGetHeight(_wordmark.bounds));

    CGFloat buttonHeight = 50.0;
    CGFloat bottom = CGRectGetHeight(bounds) - MAX(safe.bottom, 16.0) - 8.0;

    [_secondary sizeToFit];
    _secondary.frame = CGRectMake((width - 120.0) / 2.0, bottom - 34.0, 120.0, 34.0);

    _primary.frame = CGRectMake(margin,
                                CGRectGetMinY(_secondary.frame) - 12.0 - buttonHeight,
                                contentWidth,
                                buttonHeight);

    CGFloat dotWidth = 6.0;
    CGFloat dotGap = 7.0;
    CGFloat dotsWidth = _dots.count * dotWidth + (_dots.count - 1) * dotGap;
    _pageDots.frame = CGRectMake((width - dotsWidth) / 2.0, CGRectGetMinY(_primary.frame) - 26.0, dotsWidth, 6.0);
    [_dots enumerateObjectsUsingBlock:^(UIView *dot, NSUInteger index, BOOL *stop) {
        dot.frame = CGRectMake(index * (dotWidth + dotGap), 0, dotWidth, dotWidth);
    }];

    CGSize bodySize = [_body sizeThatFits:CGSizeMake(contentWidth, CGFLOAT_MAX)];
    _body.frame = CGRectMake(margin, CGRectGetMinY(_pageDots.frame) - 30.0 - bodySize.height, contentWidth, bodySize.height);

    CGSize titleSize = [_title sizeThatFits:CGSizeMake(contentWidth, CGFLOAT_MAX)];
    _title.frame = CGRectMake(margin, CGRectGetMinY(_body.frame) - 12.0 - titleSize.height, contentWidth, titleSize.height);

    CGFloat demoTop = CGRectGetMaxY(_logo.frame) + 24.0;
    CGFloat demoHeight = MAX(CGRectGetMinY(_title.frame) - 26.0 - demoTop, 120.0);
    _demo.frame = CGRectMake(margin, demoTop, contentWidth, demoHeight);
}

#pragma mark - Steps

- (void)applyStep:(NSInteger)step animated:(BOOL)animated {
    _step = MIN(MAX(step, 0), (NSInteger)_steps.count - 1);
    DSIntroStep *model = _steps[_step];

    void (^apply)(void) = ^{
        self->_title.text = model.title;
        self->_body.text = model.body;
        [self->_primary setTitle:(self->_step == (NSInteger)self->_steps.count - 1 ? @"Start using Dynamic Stage" : @"Continue")
                        forState:UIControlStateNormal];
        self->_secondary.alpha = self->_step == (NSInteger)self->_steps.count - 1 ? 0.0 : 1.0;
        [self->_dots enumerateObjectsUsingBlock:^(UIView *dot, NSUInteger index, BOOL *stop) {
            BOOL active = (NSInteger)index == self->_step;
            dot.backgroundColor = [UIColor colorWithWhite:1.0 alpha:active ? 0.95 : 0.25];
        }];
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
    };

    if (animated) {
        [UIView transitionWithView:self.view
                          duration:0.28
                           options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction
                        animations:apply
                        completion:nil];
    } else {
        apply();
    }

    [_demo playDemo:model.demo];
}

- (void)advance {
    [self noteInteraction];
    if (_step >= (NSInteger)_steps.count - 1) {
        [self finish];
        return;
    }
    [self applyStep:_step + 1 animated:YES];
}

- (void)retreat {
    [self noteInteraction];
    if (_step == 0) return;
    [self applyStep:_step - 1 animated:YES];
}

- (void)finish {
    [[DSPreferences sharedPreferences] setIntroShown:YES];
    [_watchdog invalidate];
    _watchdog = nil;
    [_demo stop];

    UIWindow *window = sIntroWindow;
    sIntroWindow = nil;
    [UIView animateWithDuration:0.35 animations:^{
        window.alpha = 0.0;
        window.rootViewController.view.transform = CGAffineTransformMakeScale(1.04, 1.04);
    } completion:^(BOOL finished) {
        window.hidden = YES;
        window.rootViewController = nil;
    }];
}

@end
