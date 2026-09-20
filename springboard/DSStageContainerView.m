#import "DSStageContainerView.h"
#import "DSConstants.h"

static const CGFloat kDSDragAffordanceHeight = 24.0;
static const CGFloat kDSHomeAffordanceHeight = 26.0;

@implementation DSStageContainerView {
    UIView *_shadowView;
    UIVisualEffectView *_backdrop;
    UIView *_contentView;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _cornerRadius = kDSFallbackDisplayCornerRadius;

        // The card clips its contents, which kills its own shadow, so the drop
        // shadow lives on a sibling underneath.
        _shadowView = [[UIView alloc] initWithFrame:CGRectZero];
        _shadowView.backgroundColor = UIColor.blackColor;
        _shadowView.layer.shadowColor = UIColor.blackColor.CGColor;
        _shadowView.layer.shadowOpacity = 0.28;
        _shadowView.layer.shadowRadius = 24.0;
        _shadowView.layer.shadowOffset = CGSizeMake(0, -4);
        _shadowView.layer.cornerCurve = kCACornerCurveContinuous;
        _shadowView.userInteractionEnabled = NO;

        _backdrop = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
        [self addSubview:_backdrop];

        _contentView = [[UIView alloc] initWithFrame:CGRectZero];
        _contentView.clipsToBounds = YES;
        [self addSubview:_contentView];

        self.clipsToBounds = YES;
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
    _backdrop.frame = self.bounds;
    _contentView.frame = self.bounds;
    [self updateShadow];
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
    _shadowView.frame = self.frame;
    _shadowView.layer.cornerRadius = self.layer.cornerRadius;
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
    if (@available(iOS 13.0, *)) {
        self.overrideUserInterfaceStyle = darkMode ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
    }
}

- (void)setBackdropHidden:(BOOL)hidden {
    _backdrop.hidden = hidden;
}

- (CGRect)dragAffordanceRect {
    return CGRectMake(0, 0, CGRectGetWidth(self.bounds), kDSDragAffordanceHeight);
}

- (CGRect)homeAffordanceRect {
    return CGRectMake(0,
                      CGRectGetHeight(self.bounds) - kDSHomeAffordanceHeight,
                      CGRectGetWidth(self.bounds),
                      kDSHomeAffordanceHeight);
}

@end
