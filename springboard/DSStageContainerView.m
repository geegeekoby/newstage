#import "DSStageContainerView.h"
#import "DSConstants.h"

static const CGFloat kDSDragAffordanceHeight = 24.0;
static const CGFloat kDSHomeAffordanceHeight = 26.0;

static const CGFloat kDSGrabberWidth = 124.0;
static const CGFloat kDSGrabberPillWidth = 40.0;
static const CGFloat kDSGrabberPillHeight = 5.0;

// The hosted app's view is taller than the card while the app has a keyboard up, and
// the part of it below the card is that keyboard. So the content view has to be
// willing to be touched, and drawn, outside its own bounds.
@interface DSStageContentView : UIView
@property (nonatomic, assign) CGFloat spill;
@end

@implementation DSStageContentView

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGRect area = self.bounds;
    area.size.height += MAX(_spill, 0.0);
    return CGRectContainsPoint(area, point);
}

@end

@implementation DSStageContainerView {
    UIView *_shadowView;
    UIVisualEffectView *_backdrop;
    DSStageContentView *_contentView;
    UIView *_grabber;
    UIView *_grabberPill;
    CAShapeLayer *_contentMask;
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

        _contentView = [[DSStageContentView alloc] initWithFrame:CGRectZero];
        _contentView.clipsToBounds = YES;
        [self addSubview:_contentView];

        // The card is dragged by this. It has to be a view of its own, sitting
        // above the content: a drag that lands on the app grid belongs to the
        // grid's own scrolling, and the card would never see it. Being visible is
        // the other half of the job - there is otherwise nothing to say the card
        // can be moved at all.
        _grabber = [[UIView alloc] initWithFrame:CGRectZero];
        _grabber.backgroundColor = UIColor.clearColor;
        [self addSubview:_grabber];

        _grabberPill = [[UIView alloc] initWithFrame:CGRectZero];
        _grabberPill.layer.cornerRadius = kDSGrabberPillHeight / 2.0;
        _grabberPill.layer.cornerCurve = kCACornerCurveContinuous;
        _grabberPill.userInteractionEnabled = NO;
        [_grabber addSubview:_grabberPill];

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

    CGRect bounds = self.bounds;
    _grabber.frame = CGRectMake((CGRectGetWidth(bounds) - kDSGrabberWidth) / 2.0,
                                0.0,
                                kDSGrabberWidth,
                                kDSDragAffordanceHeight);
    _grabberPill.frame = CGRectMake((kDSGrabberWidth - kDSGrabberPillWidth) / 2.0,
                                    (kDSDragAffordanceHeight - kDSGrabberPillHeight) / 2.0 + 2.0,
                                    kDSGrabberPillWidth,
                                    kDSGrabberPillHeight);
    [self updateShadow];
    [self updateSpillMask];
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
    _grabberPill.backgroundColor = darkMode ? [UIColor colorWithWhite:1.0 alpha:0.34]
                                            : [UIColor colorWithWhite:0.0 alpha:0.26];
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

// Deep enough and wide enough to be found with a thumb, and in the corner the
// stage came out of so sending it back there is the same movement reversed.
- (CGRect)cornerGripRect {
    CGRect bounds = self.bounds;
    CGFloat width = MIN(kDSTriggerWidth + 28.0, CGRectGetWidth(bounds));
    CGFloat height = MIN(46.0, CGRectGetHeight(bounds));
    return CGRectMake(CGRectGetWidth(bounds) - width,
                      CGRectGetHeight(bounds) - height,
                      width,
                      height);
}

- (void)setLiftOffset:(CGFloat)offset {
    // A transform rather than a new frame: the card's resting frame belongs to
    // whichever state it is in, and the keyboard is only borrowing the space.
    CGAffineTransform lift = CGAffineTransformMakeTranslation(0.0, -offset);
    self.transform = lift;
    _shadowView.transform = lift;
    _liftOffset = offset;
}

// The app on the stage draws its keyboard at the bottom of its own window, and that
// window is the card plus this band. So over the band the card stops clipping and
// stops rounding: the keyboard comes out below the card, at the bottom of the display,
// the size and shape it would have if the app were full screen.
- (void)setKeyboardSpill:(CGFloat)spill {
    spill = MAX(spill, 0.0);
    if (fabs(spill - _keyboardSpill) < 0.5) return;
    _keyboardSpill = spill;
    _contentView.spill = spill;
    [self updateSpillMask];
}

- (void)updateSpillMask {
    CGRect bounds = self.bounds;
    if (_keyboardSpill < 0.5 || CGRectIsEmpty(bounds)) {
        if (self.layer.mask) {
            self.layer.mask = nil;
            _contentMask = nil;
        }
        self.clipsToBounds = YES;
        _contentView.clipsToBounds = YES;
        return;
    }

    self.clipsToBounds = NO;
    _contentView.clipsToBounds = NO;

    if (!_contentMask) {
        _contentMask = [CAShapeLayer layer];
        _contentMask.fillColor = UIColor.blackColor.CGColor;
    }
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    _contentMask.frame = CGRectMake(0.0, 0.0, width, height + _keyboardSpill);

    UIBezierPath *shape = [UIBezierPath bezierPathWithRoundedRect:bounds
                                                    cornerRadius:self.layer.cornerRadius];
    [shape appendPath:[UIBezierPath bezierPathWithRect:CGRectMake(0.0, height, width, _keyboardSpill)]];
    _contentMask.path = shape.CGPath;
    self.layer.mask = _contentMask;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if ([super pointInside:point withEvent:event]) return YES;
    if (_keyboardSpill < 0.5) return NO;
    CGRect band = CGRectMake(0.0, CGRectGetHeight(self.bounds), CGRectGetWidth(self.bounds), _keyboardSpill);
    return CGRectContainsPoint(band, point);
}

- (CGRect)homeAffordanceRect {
    return CGRectMake(0,
                      CGRectGetHeight(self.bounds) - kDSHomeAffordanceHeight,
                      CGRectGetWidth(self.bounds),
                      kDSHomeAffordanceHeight);
}

@end
