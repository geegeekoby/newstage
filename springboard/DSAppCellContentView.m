#import "DSAppCellContentView.h"
#import "DSConstants.h"

static const CGFloat kDSCellIconInset = 6.0;
static const CGFloat kDSCellTitleGap = 9.0;

#pragma mark - Now playing waveform

// Five bars bouncing on their own timer, which is how the stock cell marks the
// app that currently owns audio.
@interface DSWaveformView : UIView
@property (nonatomic, assign) BOOL animating;
@property (nonatomic, strong) UIColor *barColor;
@end

@implementation DSWaveformView {
    NSArray<UIView *> *_bars;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        NSMutableArray *bars = [NSMutableArray array];
        for (NSUInteger index = 0; index < 4; index++) {
            UIView *bar = [[UIView alloc] initWithFrame:CGRectZero];
            bar.layer.cornerRadius = 1.0;
            [self addSubview:bar];
            [bars addObject:bar];
        }
        _bars = bars;
        _barColor = [UIColor colorWithWhite:0.5 alpha:1.0];
    }
    return self;
}

- (void)setBarColor:(UIColor *)barColor {
    _barColor = barColor;
    for (UIView *bar in _bars) bar.backgroundColor = barColor;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self layoutBars];
}

- (void)layoutBars {
    CGFloat width = 2.0;
    CGFloat gap = 2.0;
    CGFloat height = CGRectGetHeight(self.bounds);
    [_bars enumerateObjectsUsingBlock:^(UIView *bar, NSUInteger index, BOOL *stop) {
        static const CGFloat ratios[] = { 0.5, 1.0, 0.35, 0.75 };
        CGFloat barHeight = MAX(height * ratios[index % 4], 2.0);
        bar.frame = CGRectMake(index * (width + gap), height - barHeight, width, barHeight);
        bar.backgroundColor = self.barColor;
    }];
}

- (void)setAnimating:(BOOL)animating {
    _animating = animating;
    for (UIView *bar in _bars) [bar.layer removeAllAnimations];
    if (!animating) {
        [self layoutBars];
        return;
    }

    CGFloat height = CGRectGetHeight(self.bounds);
    [_bars enumerateObjectsUsingBlock:^(UIView *bar, NSUInteger index, BOOL *stop) {
        CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"transform.scale.y"];
        animation.fromValue = @(0.35);
        animation.toValue = @(1.0);
        animation.duration = 0.34 + index * 0.07;
        animation.autoreverses = YES;
        animation.repeatCount = HUGE_VALF;
        animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        bar.layer.anchorPoint = CGPointMake(0.5, 1.0);
        bar.layer.position = CGPointMake(CGRectGetMidX(bar.frame), height);
        [bar.layer addAnimation:animation forKey:@"bounce"];
    }];
}

@end

#pragma mark - App plate

@implementation DSAppCellContentView {
    UIView *_plate;
    UIView *_holdFill;
    UIImageView *_icon;
    UILabel *_title;
    DSWaveformView *_waveform;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _plate = [[UIView alloc] initWithFrame:CGRectZero];
        _plate.layer.cornerRadius = kDSCellRadius;
        _plate.layer.cornerCurve = kCACornerCurveContinuous;
        _plate.clipsToBounds = YES;
        _plate.userInteractionEnabled = NO;
        [self addSubview:_plate];

        _holdFill = [[UIView alloc] initWithFrame:CGRectZero];
        [_plate addSubview:_holdFill];

        _icon = [[UIImageView alloc] initWithFrame:CGRectZero];
        _icon.contentMode = UIViewContentModeScaleAspectFill;
        _icon.layer.cornerRadius = kDSCellIconSide * 0.235;
        _icon.layer.cornerCurve = kCACornerCurveContinuous;
        _icon.clipsToBounds = YES;
        [self addSubview:_icon];

        _title = [[UILabel alloc] initWithFrame:CGRectZero];
        _title.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular];
        _title.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:_title];

        _waveform = [[DSWaveformView alloc] initWithFrame:CGRectZero];
        _waveform.hidden = YES;
        [self addSubview:_waveform];

        self.darkMode = YES;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGRect bounds = self.bounds;
    _plate.frame = bounds;
    _holdFill.frame = CGRectMake(0, 0, CGRectGetWidth(bounds) * self.holdProgress, CGRectGetHeight(bounds));

    CGFloat iconY = (CGRectGetHeight(bounds) - kDSCellIconSide) / 2.0;
    _icon.frame = CGRectMake(kDSCellIconInset, iconY, kDSCellIconSide, kDSCellIconSide);

    CGFloat waveformWidth = 14.0;
    BOOL showsWaveform = !_waveform.hidden;
    CGFloat titleX = CGRectGetMaxX(_icon.frame) + kDSCellTitleGap;
    CGFloat titleRight = CGRectGetWidth(bounds) - kDSCellIconInset - (showsWaveform ? waveformWidth + 6.0 : 2.0);
    _title.frame = CGRectMake(titleX, 0, MAX(titleRight - titleX, 0), CGRectGetHeight(bounds));

    _waveform.frame = CGRectMake(CGRectGetWidth(bounds) - kDSCellIconInset - waveformWidth,
                                 (CGRectGetHeight(bounds) - 12.0) / 2.0,
                                 waveformWidth,
                                 12.0);
}

- (void)setEntry:(DSAppEntry *)entry {
    _entry = entry;
    _icon.image = entry.icon;
    _title.text = entry.displayName;
    [self setNeedsLayout];
}

- (void)setShowsNowPlaying:(BOOL)showsNowPlaying {
    _showsNowPlaying = showsNowPlaying;
    _waveform.hidden = !showsNowPlaying;
    _waveform.animating = showsNowPlaying;
    [self setNeedsLayout];
}

- (void)setDarkMode:(BOOL)darkMode {
    _darkMode = darkMode;
    _plate.backgroundColor = darkMode ? [UIColor colorWithWhite:1.0 alpha:0.1]
                                      : [UIColor colorWithWhite:0.0 alpha:0.07];
    _holdFill.backgroundColor = darkMode ? [UIColor colorWithWhite:1.0 alpha:0.14]
                                        : [UIColor colorWithWhite:0.0 alpha:0.1];
    _title.textColor = darkMode ? UIColor.whiteColor : UIColor.blackColor;
    _waveform.barColor = darkMode ? [UIColor colorWithWhite:1.0 alpha:0.55]
                                  : [UIColor colorWithWhite:0.0 alpha:0.4];
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:highlighted ? 0.1 : 0.25 animations:^{
        self->_plate.backgroundColor = highlighted
            ? (self.darkMode ? [UIColor colorWithWhite:1.0 alpha:0.2] : [UIColor colorWithWhite:0.0 alpha:0.14])
            : (self.darkMode ? [UIColor colorWithWhite:1.0 alpha:0.1] : [UIColor colorWithWhite:0.0 alpha:0.07]);
        self->_icon.alpha = highlighted ? 0.85 : 1.0;
    }];
}

- (void)setHoldProgress:(CGFloat)holdProgress {
    [self setHoldProgress:holdProgress animated:NO duration:0.0];
}

- (void)setHoldProgress:(CGFloat)holdProgress animated:(BOOL)animated duration:(NSTimeInterval)duration {
    _holdProgress = MIN(MAX(holdProgress, 0.0), 1.0);
    void (^apply)(void) = ^{
        self->_holdFill.frame = CGRectMake(0, 0,
                                           CGRectGetWidth(self.bounds) * self->_holdProgress,
                                           CGRectGetHeight(self.bounds));
    };
    if (!animated) {
        [_holdFill.layer removeAllAnimations];
        apply();
        return;
    }
    [UIView animateWithDuration:duration
                          delay:0.0
                        options:UIViewAnimationOptionCurveLinear | UIViewAnimationOptionBeginFromCurrentState
                     animations:apply
                     completion:nil];
}

@end
