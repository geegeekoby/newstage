#import "DSStageContainerView.h"
#import "DSConstants.h"

static const CGFloat kDSDragAffordanceHeight = 24.0;

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

        // The corner, for the same reason the grabber above is a view: a touch that
        // lands on a hosted app is delivered to that app's own process, and a gesture
        // recogniser on this side is never asked about it. While the card holds the app
        // grid the corner could be a rectangle the recogniser tested the start of a drag
        // against, because the grid is SpringBoard's own view. The moment the card held
        // an app instead, taking hold of the corner stopped working at all.
        //
        // Only while an app is on the stage, though: there is no reason to hold back a
        // piece of the app grid the grid could be using.
        _cornerGrip = [[UIView alloc] initWithFrame:CGRectZero];
        _cornerGrip.backgroundColor = UIColor.clearColor;
        _cornerGrip.userInteractionEnabled = NO;
        [self addSubview:_cornerGrip];

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

    // Narrower than the zone the pan recogniser will accept a drag from, because while
    // an app is on the stage this is a piece of that app being held back: a thumb's
    // worth is enough to take hold of the corner, and the rest stays the app's.
    CGRect grip = [self cornerGripRect];
    CGFloat gripWidth = MIN(72.0, CGRectGetWidth(grip));
    _cornerGrip.frame = CGRectMake(CGRectGetMaxX(grip) - gripWidth,
                                   CGRectGetMinY(grip),
                                   gripWidth,
                                   CGRectGetHeight(grip));

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

- (void)setHostingApp:(BOOL)hostingApp {
    _hostingApp = hostingApp;
    _cornerGrip.userInteractionEnabled = hostingApp;
}

@end
