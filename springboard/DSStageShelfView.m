#import "DSStageShelfView.h"
#import "DSAppLibrary.h"

static const CGFloat kDSShelfNotchWidth = 18.0;
static const CGFloat kDSShelfNotchHeight = 74.0;
static const CGFloat kDSShelfSquare = 84.0;
static const CGFloat kDSShelfPanelWidth = 116.0;

@interface DSShelfSlotView : UIControl
@property (nonatomic, assign) NSInteger half;
- (void)showBundleIdentifier:(NSString *)bundleIdentifier dark:(BOOL)dark title:(NSString *)title;
@end

@implementation DSShelfSlotView {
    UIImageView *_iconView;
    UIImageView *_plusView;
    UILabel *_caption;
    NSString *_bundleIdentifier;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.clipsToBounds = YES;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.cornerRadius = 18.0;

        _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _iconView.contentMode = UIViewContentModeScaleAspectFill;
        _iconView.clipsToBounds = YES;
        _iconView.userInteractionEnabled = NO;
        [self addSubview:_iconView];

        _plusView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _plusView.contentMode = UIViewContentModeScaleAspectFit;
        _plusView.userInteractionEnabled = NO;
        if (@available(iOS 13.0, *)) {
            _plusView.image = [UIImage systemImageNamed:@"plus"];
        }
        [self addSubview:_plusView];

        _caption = [[UILabel alloc] initWithFrame:CGRectZero];
        _caption.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightSemibold];
        _caption.textAlignment = NSTextAlignmentCenter;
        _caption.userInteractionEnabled = NO;
        [self addSubview:_caption];
    }
    return self;
}

- (void)showBundleIdentifier:(NSString *)bundleIdentifier dark:(BOOL)dark title:(NSString *)title {
    _bundleIdentifier = [bundleIdentifier copy];
    BOOL filled = bundleIdentifier.length > 0;
    UIImage *icon = filled ? [[DSAppLibrary sharedLibrary] iconForBundleIdentifier:bundleIdentifier] : nil;
    _iconView.image = icon;
    _iconView.hidden = !filled;
    _plusView.hidden = filled;
    _caption.hidden = filled;

    if (filled) {
        DSAppEntry *entry = [[DSAppLibrary sharedLibrary] entryForBundleIdentifier:bundleIdentifier];
        NSString *name = entry.displayName.length ? entry.displayName : bundleIdentifier;
        self.accessibilityLabel = name;
        self.backgroundColor = UIColor.clearColor;
        self.layer.borderWidth = 0.0;
    } else {
        self.accessibilityLabel = [NSString stringWithFormat:@"Start %@ stage", title.lowercaseString];
        self.backgroundColor = [UIColor colorWithWhite:dark ? 1.0 : 0.0 alpha:dark ? 0.08 : 0.05];
        self.layer.borderWidth = 1.5;
        self.layer.borderColor = [UIColor colorWithWhite:dark ? 1.0 : 0.0 alpha:0.28].CGColor;
        _caption.text = title;
        _caption.textColor = [UIColor colorWithWhite:dark ? 1.0 : 0.0 alpha:0.55];
        _plusView.tintColor = [UIColor colorWithWhite:dark ? 1.0 : 0.0 alpha:0.7];
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _iconView.frame = self.bounds;
    CGFloat plus = 22.0;
    _plusView.frame = CGRectMake((CGRectGetWidth(self.bounds) - plus) / 2.0, 18.0, plus, plus);
    _caption.frame = CGRectMake(4.0, CGRectGetMaxY(_plusView.frame) + 4.0, CGRectGetWidth(self.bounds) - 8.0, 14.0);
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.65 : 1.0;
}

@end

@implementation DSStageShelfView {
    UIControl *_notch;
    UIView *_pill;
    UIImageView *_chevron;
    UIVisualEffectView *_panel;
    DSShelfSlotView *_topSlot;
    DSShelfSlotView *_bottomSlot;
    NSString *_topBundle;
    NSString *_bottomBundle;
    BOOL _open;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        _notch = [[UIControl alloc] initWithFrame:CGRectZero];
        _notch.clipsToBounds = YES;
        _notch.accessibilityLabel = @"Stages";
        [_notch addTarget:self action:@selector(notchTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_notch];

        _pill = [[UIView alloc] initWithFrame:CGRectZero];
        _pill.userInteractionEnabled = NO;
        [_notch addSubview:_pill];

        _chevron = [[UIImageView alloc] initWithFrame:CGRectZero];
        _chevron.contentMode = UIViewContentModeScaleAspectFit;
        _chevron.userInteractionEnabled = NO;
        _chevron.hidden = YES;
        [_notch addSubview:_chevron];

        _panel = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
        _panel.clipsToBounds = YES;
        _panel.layer.cornerCurve = kCACornerCurveContinuous;
        _panel.alpha = 0.0;
        _panel.userInteractionEnabled = NO;
        _panel.transform = CGAffineTransformMakeTranslation(28.0, 0.0);
        [self addSubview:_panel];

        _topSlot = [[DSShelfSlotView alloc] initWithFrame:CGRectZero];
        _topSlot.half = 1;
        [_topSlot addTarget:self action:@selector(slotTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_panel.contentView addSubview:_topSlot];

        _bottomSlot = [[DSShelfSlotView alloc] initWithFrame:CGRectZero];
        _bottomSlot.half = 0;
        [_bottomSlot addTarget:self action:@selector(slotTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_panel.contentView addSubview:_bottomSlot];

        self.darkMode = YES;
        [self applySlots];
        [self applyChevron];
    }
    return self;
}

- (void)setDarkMode:(BOOL)darkMode {
    _darkMode = darkMode;
    UIBlurEffectStyle style = darkMode ? UIBlurEffectStyleSystemThickMaterialDark : UIBlurEffectStyleSystemThickMaterialLight;
    _panel.effect = [UIBlurEffect effectWithStyle:style];
    _notch.backgroundColor = darkMode
        ? [UIColor colorWithWhite:0.16 alpha:0.78]
        : [UIColor colorWithWhite:0.96 alpha:0.82];
    _pill.backgroundColor = [UIColor colorWithWhite:darkMode ? 1.0 : 0.15 alpha:0.88];
    _chevron.tintColor = [UIColor colorWithWhite:darkMode ? 1.0 : 0.1 alpha:0.9];
    [self applySlots];
}

- (BOOL)open {
    return _open;
}

- (void)reloadTopBundleIdentifier:(NSString *)top bottomBundleIdentifier:(NSString *)bottom {
    _topBundle = [top copy];
    _bottomBundle = [bottom copy];
    [self applySlots];
}

- (void)applySlots {
    [_topSlot showBundleIdentifier:_topBundle dark:_darkMode title:@"Top"];
    [_bottomSlot showBundleIdentifier:_bottomBundle dark:_darkMode title:@"Bottom"];
}

- (CGRect)notchFrame {
    CGFloat height = CGRectGetHeight(self.bounds);
    CGFloat width = CGRectGetWidth(self.bounds);
    return CGRectMake(width - kDSShelfNotchWidth,
                      floor((height - kDSShelfNotchHeight) / 2.0),
                      kDSShelfNotchWidth,
                      kDSShelfNotchHeight);
}

- (CGFloat)panelHeight {
    return 16.0 + kDSShelfSquare + 10.0 + kDSShelfSquare + 16.0;
}

- (CGRect)panelFrame {
    CGRect notch = [self notchFrame];
    CGFloat panelHeight = [self panelHeight];
    CGFloat x = CGRectGetMinX(notch) - 8.0 - kDSShelfPanelWidth;
    CGFloat y = CGRectGetMidY(notch) - panelHeight / 2.0;
    CGFloat minY = 54.0;
    CGFloat maxY = CGRectGetHeight(self.bounds) - panelHeight - 28.0;
    if (y < minY) y = minY;
    if (y > maxY) y = maxY;
    return CGRectMake(x, y, kDSShelfPanelWidth, panelHeight);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect notch = [self notchFrame];
    _notch.frame = notch;
    _notch.layer.cornerRadius = 9.0;
    _notch.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner;
    if (@available(iOS 13.0, *)) {
        _notch.layer.cornerCurve = kCACornerCurveContinuous;
    }

    _pill.bounds = CGRectMake(0, 0, 3.0, 28.0);
    _pill.center = CGPointMake(CGRectGetWidth(notch) / 2.0, CGRectGetHeight(notch) / 2.0);
    _pill.layer.cornerRadius = 1.5;
    _chevron.frame = CGRectInset(_notch.bounds, 1.0, 24.0);

    CGRect panel = [self panelFrame];
    _panel.bounds = CGRectMake(0, 0, CGRectGetWidth(panel), CGRectGetHeight(panel));
    _panel.center = CGPointMake(CGRectGetMidX(panel), CGRectGetMidY(panel));
    _panel.layer.cornerRadius = 26.0;

    CGFloat x = (kDSShelfPanelWidth - kDSShelfSquare) / 2.0;
    _topSlot.frame = CGRectMake(x, 16.0, kDSShelfSquare, kDSShelfSquare);
    _bottomSlot.frame = CGRectMake(x, 16.0 + kDSShelfSquare + 10.0, kDSShelfSquare, kDSShelfSquare);
}

- (void)applyChevron {
    if (@available(iOS 13.0, *)) {
        NSString *name = _open ? @"chevron.right" : @"chevron.left";
        _chevron.image = [UIImage systemImageNamed:name];
    }
    _pill.hidden = _open;
    _chevron.hidden = !_open;
}

- (void)notchTapped {
    [self setOpen:!_open animated:YES];
}

- (void)setOpen:(BOOL)open animated:(BOOL)animated {
    if (_open == open) return;
    if (open && self.willOpenHandler) self.willOpenHandler();
    _open = open;
    _panel.userInteractionEnabled = open;
    [self applyChevron];
    [self setNeedsLayout];
    [self layoutIfNeeded];

    void (^changes)(void) = ^{
        self->_panel.alpha = open ? 1.0 : 0.0;
        self->_panel.transform = open ? CGAffineTransformIdentity : CGAffineTransformMakeTranslation(28.0, 0.0);
    };
    if (animated) {
        [UIView animateWithDuration:0.28
                              delay:0
                            options:UIViewAnimationOptionCurveEaseInOut
                         animations:changes
                         completion:nil];
    } else {
        changes();
    }
}

- (void)slotTapped:(DSShelfSlotView *)slot {
    void (^handler)(NSInteger) = self.halfHandler;
    [self setOpen:NO animated:YES];
    if (handler) handler(slot.half);
}

- (CGRect)notchHitFrame {
    CGRect notch = [self notchFrame];
    notch.origin.x -= 8.0;
    notch.size.width += 8.0;
    notch.origin.y -= 12.0;
    notch.size.height += 24.0;
    return notch;
}

- (BOOL)claimsPoint:(CGPoint)point {
    if (CGRectContainsPoint([self notchHitFrame], point)) return YES;
    if (_open && CGRectContainsPoint([self panelFrame], point)) return YES;
    return NO;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (![self claimsPoint:point]) return nil;
    UIView *hit = [super hitTest:point withEvent:event];
    if ((hit == self || !hit) && CGRectContainsPoint([self notchHitFrame], point)) return _notch;
    return hit;
}

@end
