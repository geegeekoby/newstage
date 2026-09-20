#import "DSScaleSliderCell.h"

static const CGFloat kDSValueLabelWidth = 52.0;

@implementation DSScaleSliderCell {
    UILabel *_valueLabel;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier])) {
        _valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:15.0 weight:UIFontWeightRegular];
        _valueLabel.textColor = UIColor.secondaryLabelColor;
        _valueLabel.textAlignment = NSTextAlignmentRight;
        [self.contentView addSubview:_valueLabel];

        UISlider *slider = (UISlider *)self.control;
        if ([slider isKindOfClass:UISlider.class]) {
            [slider addTarget:self action:@selector(sliderValueChanged:) forControlEvents:UIControlEventValueChanged];
            [self updateValueLabelWithValue:slider.value];
        }
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGRect controlFrame = self.control.frame;
    CGFloat trailing = CGRectGetMaxX(controlFrame);
    self.control.frame = CGRectMake(CGRectGetMinX(controlFrame),
                                    CGRectGetMinY(controlFrame),
                                    CGRectGetWidth(controlFrame) - kDSValueLabelWidth,
                                    CGRectGetHeight(controlFrame));
    _valueLabel.frame = CGRectMake(trailing - kDSValueLabelWidth + 6.0,
                                   CGRectGetMinY(controlFrame),
                                   kDSValueLabelWidth - 6.0,
                                   CGRectGetHeight(controlFrame));
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    UISlider *slider = (UISlider *)self.control;
    if ([slider isKindOfClass:UISlider.class]) [self updateValueLabelWithValue:slider.value];
}

- (void)sliderValueChanged:(UISlider *)slider {
    // Snap to 5% steps so the label never lands on a value the stage cannot
    // reproduce exactly after the round trip through the plist.
    float stepped = roundf(slider.value * 20.0f) / 20.0f;
    if (fabsf(stepped - slider.value) > 0.0001f) slider.value = stepped;
    [self updateValueLabelWithValue:stepped];
}

- (void)updateValueLabelWithValue:(float)value {
    _valueLabel.text = [NSString stringWithFormat:@"%d%%", (int)roundf(value * 100.0f)];
}

@end
