#import "DSSearchFieldView.h"
#import "DSConstants.h"
#import "DSDiagnostics.h"

@interface DSSearchFieldView () <UITextFieldDelegate>
@end

@implementation DSSearchFieldView {
    UIView *_plate;
    UITextField *_field;
    UIImageView *_magnifier;
    UIButton *_clearButton;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _plate = [[UIView alloc] initWithFrame:CGRectZero];
        _plate.layer.cornerRadius = kDSSearchFieldRadius;
        _plate.layer.cornerCurve = kCACornerCurveContinuous;
        _plate.userInteractionEnabled = NO;
        [self addSubview:_plate];

        _magnifier = [[UIImageView alloc] initWithFrame:CGRectZero];
        _magnifier.contentMode = UIViewContentModeScaleAspectFit;
        if (@available(iOS 13.0, *)) {
            _magnifier.image = [[UIImage systemImageNamed:@"magnifyingglass"]
                imageWithConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:17.0
                                                                                      weight:UIImageSymbolWeightRegular]];
        }
        [self addSubview:_magnifier];

        _field = [[UITextField alloc] initWithFrame:CGRectZero];
        _field.font = [UIFont systemFontOfSize:kDSTitleFontSize];
        _field.delegate = self;
        _field.returnKeyType = UIReturnKeySearch;
        _field.autocorrectionType = UITextAutocorrectionTypeNo;
        _field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        _field.spellCheckingType = UITextSpellCheckingTypeNo;
        _field.clearButtonMode = UITextFieldViewModeNever;
        [_field addTarget:self action:@selector(textChanged) forControlEvents:UIControlEventEditingChanged];
        [self addSubview:_field];

        _clearButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _clearButton.hidden = YES;
        if (@available(iOS 13.0, *)) {
            [_clearButton setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
        }
        [_clearButton addTarget:self action:@selector(clearText) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_clearButton];

        self.darkMode = YES;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGRect bounds = self.bounds;
    _plate.frame = bounds;

    CGFloat side = 20.0;
    _magnifier.frame = CGRectMake(kDSSearchGlyphInset, (CGRectGetHeight(bounds) - side) / 2.0, side, side);
    _clearButton.frame = CGRectMake(CGRectGetWidth(bounds) - kDSSearchGlyphInset - side,
                                    (CGRectGetHeight(bounds) - side) / 2.0,
                                    side, side);

    CGFloat fieldX = CGRectGetMaxX(_magnifier.frame) + 10.0;
    CGFloat fieldRight = _clearButton.hidden ? CGRectGetWidth(bounds) - kDSSearchGlyphInset
                                             : CGRectGetMinX(_clearButton.frame) - 8.0;
    _field.frame = CGRectMake(fieldX, 0, MAX(fieldRight - fieldX, 0), CGRectGetHeight(bounds));
}

- (NSString *)text {
    return _field.text ?: @"";
}

- (void)setDarkMode:(BOOL)darkMode {
    _darkMode = darkMode;
    _plate.backgroundColor = darkMode ? [UIColor colorWithWhite:1.0 alpha:0.1]
                                      : [UIColor colorWithWhite:0.0 alpha:0.07];
    UIColor *placeholder = darkMode ? [UIColor colorWithWhite:1.0 alpha:0.42]
                                    : [UIColor colorWithWhite:0.0 alpha:0.38];
    _magnifier.tintColor = placeholder;
    _clearButton.tintColor = placeholder;
    _field.textColor = darkMode ? UIColor.whiteColor : UIColor.blackColor;
    _field.keyboardAppearance = darkMode ? UIKeyboardAppearanceDark : UIKeyboardAppearanceLight;
    _field.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"Search"
                                                                  attributes:@{ NSForegroundColorAttributeName : placeholder }];
}

- (void)clearText {
    _field.text = @"";
    [self updateClearButton];
    [self.delegate searchField:self didChangeText:@""];
}

- (void)textChanged {
    [self updateClearButton];
    [self.delegate searchField:self didChangeText:self.text];
}

- (void)updateClearButton {
    BOOL shouldShow = self.text.length > 0;
    if (shouldShow == !_clearButton.hidden) return;
    _clearButton.hidden = !shouldShow;
    [self setNeedsLayout];
}

- (void)requestKeyWindowFromDelegate {
    if ([self.delegate respondsToSelector:@selector(searchFieldNeedsKeyWindow:)]) {
        [self.delegate searchFieldNeedsKeyWindow:self];
    }
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldBeginEditing:(UITextField *)textField {
    if ([self.delegate respondsToSelector:@selector(searchFieldShouldWaitBeforeEditing:)] &&
        [self.delegate searchFieldShouldWaitBeforeEditing:self]) {
        __weak __typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong __typeof(weakSelf) field = weakSelf;
            if (!field) return;
            [field->_field becomeFirstResponder];
        });
        return NO;
    }

    [self requestKeyWindowFromDelegate];
    UIWindow *window = self.window;
    if (window && !window.isKeyWindow) {
        @try {
            [window makeKeyAndVisible];
        } @catch (NSException *exception) {
        }
    }
    return YES;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end
