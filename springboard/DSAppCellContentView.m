#import "DSAppCellContentView.h"
#import "DSConstants.h"


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
        _holdFill.alpha = 0.0;
        _holdFill.userInteractionEnabled = NO;
        [_plate addSubview:_holdFill];

        _icon = [[UIImageView alloc] initWithFrame:CGRectZero];
        _icon.contentMode = UIViewContentModeScaleAspectFill;
        _icon.layer.cornerRadius = 6.0;
        _icon.layer.cornerCurve = kCACornerCurveContinuous;
        _icon.clipsToBounds = YES;
        [self addSubview:_icon];

        _title = [[UILabel alloc] initWithFrame:CGRectZero];
        _title.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightMedium];
        _title.textAlignment = NSTextAlignmentLeft;
        _title.numberOfLines = 1;
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
    _holdFill.frame = bounds;
    if (_chipStyle) {
        CGFloat side = 32.0;
        _icon.layer.cornerRadius = 8.0;
        _icon.frame = CGRectMake((CGRectGetWidth(bounds) - side) / 2.0, 2.0, side, side);
        _title.frame = CGRectMake(0.0, CGRectGetMaxY(_icon.frame) + 4.0, CGRectGetWidth(bounds), 28.0);
        _waveform.frame = CGRectMake(CGRectGetMaxX(_icon.frame) - 10.0, CGRectGetMaxY(_icon.frame) - 8.0, 12.0, 10.0);
        return;
    }
    CGFloat side = kDSCellIconSide;
    _icon.layer.cornerRadius = 6.0;
    CGFloat iconY = (CGRectGetHeight(bounds) - side) / 2.0;
    _icon.frame = CGRectMake(kDSCellIconInset, iconY, side, side);
    CGFloat titleX = CGRectGetMaxX(_icon.frame) + kDSCellTitleGap;
    BOOL showsWaveform = !_waveform.hidden;
    CGFloat titleRight = CGRectGetWidth(bounds) - 12.0 - (showsWaveform ? 22.0 : 0.0);
    _title.frame = CGRectMake(titleX, 0.0, MAX(titleRight - titleX, 0.0), CGRectGetHeight(bounds));
    _waveform.frame = CGRectMake(CGRectGetWidth(bounds) - 26.0, (CGRectGetHeight(bounds) - 12.0) / 2.0, 14.0, 12.0);
}

- (void)setChipStyle:(BOOL)chipStyle {
    _chipStyle = chipStyle;
    [self setDarkMode:_darkMode];
    [self setNeedsLayout];
}

- (void)setEntry:(DSAppEntry *)entry {
    _entry = entry;
    UIImage *icon = entry.icon;
    if (!icon && entry.bundleIdentifier.length > 0) {
        icon = [[DSAppLibrary sharedLibrary] iconForBundleIdentifier:entry.bundleIdentifier];
        entry.icon = icon;
    }
    _icon.image = icon;
    _icon.backgroundColor = icon ? UIColor.clearColor : [UIColor colorWithWhite:1.0 alpha:0.12];
    _title.text = entry.displayName;
    [self setNeedsLayout];
}

- (void)setShowsNowPlaying:(BOOL)showsNowPlaying {
    _showsNowPlaying = showsNowPlaying;
    _waveform.hidden = !showsNowPlaying;
    _waveform.animating = showsNowPlaying;
    [self setNeedsLayout];
}

- (void)setUnavailable:(BOOL)unavailable {
    _unavailable = unavailable;
    self.userInteractionEnabled = !unavailable;
    self.alpha = unavailable ? 0.35 : 1.0;
}

- (void)setDarkMode:(BOOL)darkMode {
    _darkMode = darkMode;
    if (_chipStyle) {
        _plate.backgroundColor = UIColor.clearColor;
        _title.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightMedium];
        _title.textAlignment = NSTextAlignmentCenter;
        _title.numberOfLines = 2;
    } else {
        _plate.backgroundColor = darkMode ? [UIColor colorWithWhite:1.0 alpha:0.08]
                                          : [UIColor colorWithWhite:0.0 alpha:0.05];
        _title.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightMedium];
        _title.textAlignment = NSTextAlignmentLeft;
        _title.numberOfLines = 1;
    }
    _holdFill.backgroundColor = darkMode ? UIColor.whiteColor : UIColor.blackColor;
    _title.textColor = darkMode ? UIColor.whiteColor : UIColor.blackColor;
    _waveform.barColor = darkMode ? [UIColor colorWithWhite:1.0 alpha:0.55]
                                  : [UIColor colorWithWhite:0.0 alpha:0.4];
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    if (_unavailable) return;
    [UIView animateWithDuration:highlighted ? 0.1 : 0.25 animations:^{
        self->_icon.transform = highlighted ? CGAffineTransformMakeScale(0.92, 0.92) : CGAffineTransformIdentity;
        self->_title.alpha = highlighted ? 0.7 : 1.0;
    }];
}

- (void)setHoldProgress:(CGFloat)holdProgress {
    [self setHoldProgress:holdProgress animated:NO duration:0.0];
}

// A pixel trace of the stock hold shows the plate deepening evenly, with its
// edges never moving, rather than filling from one side.
- (void)setHoldProgress:(CGFloat)holdProgress animated:(BOOL)animated duration:(NSTimeInterval)duration {
    _holdProgress = MIN(MAX(holdProgress, 0.0), 1.0);
    void (^apply)(void) = ^{
        self->_holdFill.frame = self.bounds;
        self->_holdFill.alpha = self->_holdProgress * 0.14;
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
