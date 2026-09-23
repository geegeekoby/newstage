#import "DSStageContainerView.h"
#import "DSConstants.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat kDSDragAffordanceHeight = 36.0;
static const CGFloat kDSGrabberWidth = 124.0;
static const CGFloat kDSGrabberPillWidth = 40.0;
static const CGFloat kDSGrabberPillHeight = 5.0;

@implementation DSStageContainerView {
    UIView *_shadowView;
    UIVisualEffectView *_backdrop;
    UIView *_contentView;
    UIView *_grabber;
    UIView *_grabberPill;
    UIView *_cornerGrip;
    UIView *_edgeGrip;
    UIButton *_stackAddButton;
    UIButton *_minimizeButton;
    BOOL _applyingKeyboardBand;
    BOOL _clipsContents;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _cornerRadius = kDSFallbackDisplayCornerRadius;
        _clipsContents = YES;

        _shadowView = [[UIView alloc] initWithFrame:CGRectZero];
        _shadowView.backgroundColor = UIColor.clearColor;
        _shadowView.layer.shadowColor = UIColor.blackColor.CGColor;
        _shadowView.layer.shadowOpacity = 0.28;
        _shadowView.layer.shadowRadius = 24.0;
        _shadowView.layer.shadowOffset = CGSizeMake(0, -4);
        _shadowView.layer.cornerCurve = kCACornerCurveContinuous;
        _shadowView.userInteractionEnabled = NO;

        _backdrop = [[UIVisualEffectView alloc] initWithEffect:
                     [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
        [self addSubview:_backdrop];

        _contentView = [[UIView alloc] initWithFrame:CGRectZero];
        _contentView.backgroundColor = UIColor.clearColor;
        _contentView.clipsToBounds = YES;
        [self addSubview:_contentView];

        _grabber = [[UIView alloc] initWithFrame:CGRectZero];
        _grabber.backgroundColor = UIColor.clearColor;
        [self addSubview:_grabber];

        _grabberPill = [[UIView alloc] initWithFrame:CGRectZero];
        _grabberPill.layer.cornerRadius = kDSGrabberPillHeight / 2.0;
        _grabberPill.layer.cornerCurve = kCACornerCurveContinuous;
        _grabberPill.userInteractionEnabled = NO;
        [_grabber addSubview:_grabberPill];

        _cornerGrip = [[UIView alloc] initWithFrame:CGRectZero];
        _cornerGrip.backgroundColor = UIColor.clearColor;
        _cornerGrip.userInteractionEnabled = NO;
        [self addSubview:_cornerGrip];

        _edgeGrip = [[UIView alloc] initWithFrame:CGRectZero];
        _edgeGrip.backgroundColor = UIColor.clearColor;
        _edgeGrip.userInteractionEnabled = NO;
        [self addSubview:_edgeGrip];

        _stackAddButton = [UIButton buttonWithType:UIButtonTypeSystem];
        if (@available(iOS 13.0, *)) {
            [_stackAddButton setImage:[UIImage systemImageNamed:@"plus.circle.fill"]
                             forState:UIControlStateNormal];
        } else {
            [_stackAddButton setTitle:@"+" forState:UIControlStateNormal];
        }
        _stackAddButton.tintColor = [UIColor colorWithWhite:1.0 alpha:0.85];
        _stackAddButton.hidden = YES;
        _stackAddButton.accessibilityLabel = @"Add stage";
        [_stackAddButton addTarget:self
                            action:@selector(stackAddTapped)
                  forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_stackAddButton];

        _minimizeButton = [UIButton buttonWithType:UIButtonTypeSystem];
        if (@available(iOS 13.0, *)) {
            [_minimizeButton setImage:[UIImage systemImageNamed:@"minus.circle.fill"]
                              forState:UIControlStateNormal];
        } else {
            [_minimizeButton setTitle:@"–" forState:UIControlStateNormal];
        }
        _minimizeButton.tintColor = [UIColor colorWithWhite:1.0 alpha:0.85];
        _minimizeButton.hidden = YES;
        _minimizeButton.accessibilityLabel = @"Minimize stage";
        [_minimizeButton addTarget:self
                            action:@selector(minimizeTapped)
                  forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_minimizeButton];

        self.backgroundColor = UIColor.clearColor;
        self.clipsToBounds = YES;
        self.layer.masksToBounds = YES;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.cornerRadius = _cornerRadius;

        self.darkMode = YES;
    }
    return self;
}

- (void)willMoveToSuperview:(UIView *)superview {
    [super willMoveToSuperview:superview];
    if (superview && _shadowView.superview != superview) {
        [superview insertSubview:_shadowView belowSubview:self];
    } else if (!superview) {
        [_shadowView removeFromSuperview];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGRect bounds = self.bounds;
    CGFloat band = MIN(MAX(_keyboardBandHeight, 0.0), CGRectGetHeight(bounds));
    CGFloat appHeight = CGRectGetHeight(bounds) - band;
    BOOL pinHost = !_applyingKeyboardBand && _keyboardBandLayoutHandler != nil;

    if (band > 1.0) {
        if (pinHost) {
            _applyingKeyboardBand = YES;
            _keyboardBandLayoutHandler();
            _applyingKeyboardBand = NO;
        }

        _backdrop.frame = CGRectMake(0, 0, CGRectGetWidth(bounds), MAX(appHeight, 0));

        self.clipsToBounds = NO;
        self.layer.masksToBounds = NO;

        _contentView.clipsToBounds = YES;
        _contentView.layer.mask = nil;
        _contentView.frame = CGRectMake(0, 0, CGRectGetWidth(bounds), MAX(appHeight, 0));
        _contentView.layer.cornerRadius = _cornerRadius;
        _contentView.layer.cornerCurve = kCACornerCurveContinuous;
        _contentView.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;

        self.layer.cornerRadius = 0;

        if (pinHost) {
            _applyingKeyboardBand = YES;
            _keyboardBandLayoutHandler();
            _applyingKeyboardBand = NO;
        }

    } else {
        _backdrop.frame = bounds;

        self.clipsToBounds = _clipsContents;
        self.layer.masksToBounds = _clipsContents;

        _contentView.clipsToBounds = YES;
        _contentView.layer.mask = nil;

        if (_clipsContents) {
            _contentView.layer.cornerRadius = 0;
            self.layer.cornerRadius = _cornerRadius;
        } else {
            _contentView.layer.cornerRadius = _cornerRadius;
            _contentView.layer.cornerCurve = kCACornerCurveContinuous;
            self.layer.cornerRadius = 0;
        }

        _contentView.frame = bounds;

        if (pinHost) {
            _applyingKeyboardBand = YES;
            _keyboardBandLayoutHandler();
            _applyingKeyboardBand = NO;
        }
    }

    _grabber.frame = CGRectMake((CGRectGetWidth(bounds) - kDSGrabberWidth) / 2.0,
                                0,
                                kDSGrabberWidth,
                                kDSDragAffordanceHeight);

    _grabberPill.frame = CGRectMake((kDSGrabberWidth - kDSGrabberPillWidth) / 2.0,
                                    (kDSDragAffordanceHeight - kDSGrabberPillHeight) / 2.0 + 2.0,
                                    kDSGrabberPillWidth,
                                    kDSGrabberPillHeight);

    CGRect grip = [self cornerGripRect];
    CGFloat gripWidth = MIN(88.0, CGRectGetWidth(grip));
    CGFloat gripHeight = MIN(56.0, CGRectGetHeight(grip));
    _cornerGrip.frame = CGRectMake(CGRectGetMaxX(grip) - gripWidth,
                                   CGRectGetMaxY(grip) - gripHeight,
                                   gripWidth,
                                   gripHeight);

    _edgeGrip.frame = [self edgeGripRect];

    CGFloat addSide = 36.0;
    _stackAddButton.frame = CGRectMake(CGRectGetWidth(bounds) - addSide - 8.0,
                                       4.0,
                                       addSide,
                                       addSide);
    _stackAddButton.hidden = !_showsStackAddButton;

    CGFloat minSide = 36.0;
    _minimizeButton.frame = CGRectMake(8.0, 4.0, minSide, minSide);
    _minimizeButton.hidden = !_showsMinimizeButton;

    [self bringSubviewToFront:_cornerGrip];
    [self bringSubviewToFront:_edgeGrip];
    [self bringSubviewToFront:_stackAddButton];
    [self bringSubviewToFront:_minimizeButton];
    [self bringSubviewToFront:_grabber];

    [self updateShadow];
}

- (void)stackAddTapped {
    if (_stackAddHandler) _stackAddHandler();
}

- (void)minimizeTapped {
    if (_minimizeHandler) _minimizeHandler();
}

- (void)setShowsMinimizeButton:(BOOL)showsMinimizeButton {
    _showsMinimizeButton = showsMinimizeButton;
    _minimizeButton.hidden = !showsMinimizeButton;
}

- (void)setShowsStackAddButton:(BOOL)showsStackAddButton {
    _showsStackAddButton = showsStackAddButton;
    _stackAddButton.hidden = !showsStackAddButton;
}

- (CGRect)stackAddButtonRect {
    return _stackAddButton.frame;
}

- (void)setFrame:(CGRect)frame {
    [super setFrame:frame];
    [self updateShadow];
}

- (void)setCenter:(CGPoint)center {
    [super setCenter:center];
    [self updateShadow];
}

- (void)updateShadow {
    CGRect frame = self.frame;
    if (_keyboardBandHeight > 1.0) {
        frame.size.height = MAX(CGRectGetHeight(frame) - _keyboardBandHeight, 0);
    }
    _shadowView.frame = frame;
    _shadowView.layer.cornerRadius = _cornerRadius;
    _shadowView.alpha = self.alpha;
}

- (void)setAlpha:(CGFloat)alpha {
    [super setAlpha:alpha];
    _shadowView.alpha = alpha;
}

- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];
    _shadowView.hidden = hidden;
}

#pragma mark - Configuration

- (UIView *)contentView {
    return _contentView;
}

- (void)setCornerRadius:(CGFloat)cornerRadius {
    _cornerRadius = cornerRadius;
    self.layer.cornerRadius = cornerRadius;
    [self updateShadow];
}

- (void)setDarkMode:(BOOL)darkMode {
    _darkMode = darkMode;
    UIBlurEffectStyle style = darkMode ? UIBlurEffectStyleSystemThickMaterialDark
                                       : UIBlurEffectStyleSystemThickMaterialLight;
    _backdrop.effect = [UIBlurEffect effectWithStyle:style];
    _grabberPill.backgroundColor = darkMode ? [UIColor colorWithWhite:1.0 alpha:0.34]
                                            : [UIColor colorWithWhite:0.0 alpha:0.26];
    if (@available(iOS 13.0, *)) {
        self.overrideUserInterfaceStyle = darkMode ? UIUserInterfaceStyleDark
                                                   : UIUserInterfaceStyleLight;
    }
}

- (void)setClipsContents:(BOOL)clips {
    _clipsContents = clips;
    self.clipsToBounds = clips;
    self.layer.masksToBounds = clips;
    self.opaque = NO;

    _contentView.clipsToBounds = YES;

    if (!clips) {
        _contentView.layer.cornerRadius = _cornerRadius;
        _contentView.layer.cornerCurve = kCACornerCurveContinuous;
    }
}

- (void)setKeyboardBandHeight:(CGFloat)keyboardBandHeight {
    CGFloat height = MAX(keyboardBandHeight, 0.0);
    if (fabs(_keyboardBandHeight - height) < 0.5) return;
    _keyboardBandHeight = height;
    [self setNeedsLayout];
    [self layoutIfNeeded];
    [self updateShadow];
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (_keyboardBandHeight > 1.0 &&
        point.y >= CGRectGetHeight(self.bounds) - _keyboardBandHeight) {
        return nil;
    }

    UIView *hit = [super hitTest:point withEvent:event];
    if (!_passThroughToHost) return hit;
    if (!hit) return nil;

    if (hit == _grabber || [hit isDescendantOfView:_grabber]) return hit;
    if (hit == _cornerGrip || hit == _edgeGrip) return hit;
    if (hit == _stackAddButton || [hit isDescendantOfView:_stackAddButton]) return hit;
    if (hit == _minimizeButton || [hit isDescendantOfView:_minimizeButton]) return hit;

    return nil;
}

- (void)setBackdropHidden:(BOOL)hidden {
    _backdrop.hidden = hidden;
}

- (CGRect)dragAffordanceRect {
    return CGRectMake(0, 0, CGRectGetWidth(self.bounds), kDSDragAffordanceHeight);
}

- (CGRect)cornerGripRect {
    CGRect bounds = self.bounds;
    CGFloat width = MIN(kDSTriggerWidth + 28.0, CGRectGetWidth(bounds));
    CGFloat height = MIN(72.0, CGRectGetHeight(bounds));
    return CGRectMake(CGRectGetWidth(bounds) - width,
                      CGRectGetHeight(bounds) - height,
                      width,
                      height);
}

- (CGRect)edgeGripRect {
    CGRect bounds = self.bounds;
    CGFloat width = 44.0;
    CGFloat top = 46.0;
    if (top > CGRectGetHeight(bounds)) top = 0.0;
    return CGRectMake(CGRectGetWidth(bounds) - width,
                      top,
                      width,
                      CGRectGetHeight(bounds) - top);
}

- (void)setLiftOffset:(CGFloat)offset {
    CGAffineTransform lift = CGAffineTransformMakeTranslation(0.0, -offset);
    self.transform = lift;
    _shadowView.transform = lift;
    _liftOffset = offset;
}

- (void)setHostingApp:(BOOL)hostingApp {
    _hostingApp = hostingApp;
    _cornerGrip.userInteractionEnabled = hostingApp;
    _edgeGrip.userInteractionEnabled = hostingApp;
}

@end
