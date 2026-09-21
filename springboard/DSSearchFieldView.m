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
    NSUInteger _keyboardAttempts;
    BOOL _askingAgain;
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

#pragma mark - UITextFieldDelegate

// Typing goes to the key window, and this field's window is SpringBoard's only when
// the stage put it there. Asked for again here because this is the moment it
// actually matters, whatever happened when the stage opened.
- (BOOL)textFieldShouldBeginEditing:(UITextField *)textField {
    UIWindow *window = self.window;
    if (window && !window.isKeyWindow) {
        @try {
            [window makeKeyWindow];
        } @catch (NSException *exception) {
        }
    }
    if (!_askingAgain) _keyboardAttempts = 0;
    DSDiagnosticsRecordFormat(@"SpringBoard: search field asked for the keyboard, window is %@",
                              window.isKeyWindow ? @"key" : @"still not key");

    // Whether a keyboard then actually arrives is the whole question when typing in
    // the picker does not work, and it is not something that can be seen from here
    // any other way: written down a moment later, for the diagnostics page.
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        CGRect keyboard = CGRectNull;
        for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
            if (candidate.hidden || candidate.alpha < 0.01) continue;
            if ([NSStringFromClass(candidate.class) rangeOfString:@"Keyboard"].location == NSNotFound) continue;
            keyboard = candidate.frame;
            break;
        }
        DSDiagnosticsRecordFormat(@"SpringBoard: a moment later the keyboard is %@",
                                  CGRectIsNull(keyboard) ? @"nowhere on the display"
                                                         : NSStringFromCGRect(keyboard));
        if (CGRectIsNull(keyboard)) [weakSelf askForTheKeyboardAgain];
    });
    return YES;
}

// The field is first responder and no keyboard came up. That happens to this field and
// not to a field in an ordinary app because the window it is in only became the key
// window a moment ago, and whatever SpringBoard was doing with the keyboard before that
// - a keyboard of the staged app's going away, a focus that has not settled - can land
// between the two. Asking a second time costs a frame and fixes it; asking forever would
// be a field that cannot be left alone, so it is asked exactly once.
- (void)askForTheKeyboardAgain {
    if (_keyboardAttempts > 0 || !_field.isFirstResponder) return;
    _keyboardAttempts++;

    _askingAgain = YES;
    @try {
        [_field resignFirstResponder];
        [_field becomeFirstResponder];
    } @catch (NSException *exception) {
    }
    _askingAgain = NO;
    DSDiagnosticsRecord(@"SpringBoard: no keyboard came up for the search field, so it asked again");
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end
