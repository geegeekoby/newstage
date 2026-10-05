#import "DSStageShelfView.h"
#import "DSAppLibrary.h"

static const CGFloat kDSShelfNotchWidth = 14.0;
static const CGFloat kDSShelfNotchHeight = 64.0;
static const CGFloat kDSShelfPanelWidth = 108.0;
static const CGFloat kDSShelfPanelHeight = 108.0;

@interface DSShelfSlotView : UIControl
@property (nonatomic, assign) NSInteger half;
@property (nonatomic, copy) void (^holdHandler)(DSShelfSlotView *slot);
- (void)showBundleIdentifier:(NSString *)bundleIdentifier dark:(BOOL)dark title:(NSString *)title;
@end

@implementation DSShelfSlotView {
    UIImageView *_iconView;
    UIImageView *_plusView;
    UILabel *_caption;
    UILongPressGestureRecognizer *_hold;
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
        _caption.numberOfLines = 2;
        _caption.adjustsFontSizeToFitWidth = YES;
        _caption.minimumScaleFactor = 0.8;
        _caption.userInteractionEnabled = NO;
        [self addSubview:_caption];

        // A hold is the way back to the picker. It only arms once a square
        // actually has an app in it, and it eats the touch so the tap that
        // would only reveal the card does not also fire.
        _hold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(held:)];
        _hold.minimumPressDuration = 0.42;
        _hold.allowableMovement = 18.0;
        _hold.cancelsTouchesInView = YES;
        _hold.enabled = NO;
        [self addGestureRecognizer:_hold];
    }
    return self;
}

- (void)held:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        self.transform = CGAffineTransformMakeScale(0.9, 0.9);
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [feedback impactOccurred];
        return;
    }
    if (recognizer.state == UIGestureRecognizerStateEnded) {
        self.transform = CGAffineTransformIdentity;
        if (_bundleIdentifier.length > 0 && self.holdHandler) self.holdHandler(self);
        return;
    }
    if (recognizer.state == UIGestureRecognizerStateCancelled ||
        recognizer.state == UIGestureRecognizerStateFailed) {
        self.transform = CGAffineTransformIdentity;
    }
}

- (void)showBundleIdentifier:(NSString *)bundleIdentifier dark:(BOOL)dark title:(NSString *)title {
    _bundleIdentifier = [bundleIdentifier copy];
    BOOL filled = bundleIdentifier.length > 0;
    UIImage *icon = filled ? [[DSAppLibrary sharedLibrary] iconForBundleIdentifier:bundleIdentifier] : nil;
    _iconView.image = icon;
    _iconView.hidden = !filled;
    _plusView.hidden = filled;
    _caption.hidden = filled;

    _hold.enabled = filled;
    if (filled) {
        DSAppEntry *entry = [[DSAppLibrary sharedLibrary] entryForBundleIdentifier:bundleIdentifier];
        NSString *name = entry.displayName.length ? entry.displayName : bundleIdentifier;
        self.accessibilityLabel = name;
        self.accessibilityHint = @"Hold to return to the app picker";
        self.backgroundColor = UIColor.clearColor;
        self.layer.borderWidth = 0.0;
    } else {
        self.accessibilityLabel = title;
        self.accessibilityHint = nil;
        self.backgroundColor = UIColor.clearColor;
        self.layer.borderWidth = 0.0;
        _caption.text = title;
        _caption.textColor = [UIColor colorWithWhite:dark ? 1.0 : 0.0 alpha:0.82];
        _plusView.tintColor = [UIColor colorWithWhite:dark ? 1.0 : 0.0 alpha:0.9];
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _iconView.frame = self.bounds;
    CGFloat plus = 22.0;
    CGFloat block = plus + 4.0 + 18.0;
    CGFloat top = (CGRectGetHeight(self.bounds) - block) / 2.0;
    _plusView.frame = CGRectMake((CGRectGetWidth(self.bounds) - plus) / 2.0, top, plus, plus);
    _caption.frame = CGRectMake(8.0, CGRectGetMaxY(_plusView.frame) + 4.0, CGRectGetWidth(self.bounds) - 16.0, 18.0);
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.65 : 1.0;
}

@end

@implementation DSStageShelfView {
    UIControl *_notch;
    UIVisualEffectView *_notchBlur;
    UIView *_pill;
    UIImageView *_chevron;
    UIVisualEffectView *_panel;
    DSShelfSlotView *_topSlot;
    DSShelfSlotView *_bottomSlot;
    NSString *_topBundle;
    NSString *_bottomBundle;
    BOOL _open;
    BOOL _draggingSlot;
    CGPoint _slotHomeCenter;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        _notch = [[UIControl alloc] initWithFrame:CGRectZero];
        _notch.clipsToBounds = YES;
        _notch.accessibilityLabel = @"Stages";
        _notch.layer.borderWidth = 0.5;
        [_notch addTarget:self action:@selector(notchTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_notch];

        _notchBlur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
        _notchBlur.userInteractionEnabled = NO;
        _notchBlur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [_notch addSubview:_notchBlur];

        _pill = [[UIView alloc] initWithFrame:CGRectZero];
        _pill.userInteractionEnabled = NO;
        [_notch addSubview:_pill];

        _chevron = [[UIImageView alloc] initWithFrame:CGRectZero];
        _chevron.contentMode = UIViewContentModeScaleAspectFit;
        _chevron.userInteractionEnabled = NO;
        _chevron.hidden = YES;
        [_notch addSubview:_chevron];

        _panel = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
        _panel.clipsToBounds = YES;
        _panel.layer.cornerCurve = kCACornerCurveContinuous;
        _panel.layer.borderWidth = 0.5;
        _panel.alpha = 0.0;
        _panel.userInteractionEnabled = NO;
        _panel.transform = CGAffineTransformMakeTranslation(24.0, 0.0);
        [self insertSubview:_panel belowSubview:_notch];

        __weak DSStageShelfView *weakSelf = self;
        _topSlot = [[DSShelfSlotView alloc] initWithFrame:CGRectZero];
        _topSlot.half = 1;
        [_topSlot addTarget:self action:@selector(slotTapped:) forControlEvents:UIControlEventTouchUpInside];
        _topSlot.holdHandler = ^(DSShelfSlotView *slot) {
            [weakSelf slotHeld:slot];
        };
        UIPanGestureRecognizer *slotPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(slotPanned:)];
        slotPan.cancelsTouchesInView = YES;
        slotPan.delaysTouchesBegan = NO;
        [_topSlot addGestureRecognizer:slotPan];
        [_panel.contentView addSubview:_topSlot];

        _bottomSlot = [[DSShelfSlotView alloc] initWithFrame:CGRectZero];
        _bottomSlot.half = 0;
        [_bottomSlot addTarget:self action:@selector(slotTapped:) forControlEvents:UIControlEventTouchUpInside];
        _bottomSlot.holdHandler = ^(DSShelfSlotView *slot) {
            [weakSelf slotHeld:slot];
        };
        [_panel.contentView addSubview:_bottomSlot];

        self.darkMode = YES;
        [self applySlots];
        [self applyChevron];
    }
    return self;
}

- (void)setDarkMode:(BOOL)darkMode {
    _darkMode = darkMode;
    UIBlurEffectStyle style = darkMode ? UIBlurEffectStyleSystemThinMaterialDark : UIBlurEffectStyleSystemThinMaterialLight;
    _panel.effect = [UIBlurEffect effectWithStyle:style];
    _panel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:darkMode ? 0.28 : 0.45].CGColor;
    // The blur only samples this window, which is clear, so on its own the
    // tab disappears into the wallpaper. The fill is what you actually see.
    _notch.backgroundColor = [UIColor colorWithWhite:darkMode ? 0.05 : 1.0 alpha:0.94];
    _notchBlur.effect = [UIBlurEffect effectWithStyle:darkMode ? UIBlurEffectStyleSystemThinMaterialDark : UIBlurEffectStyleSystemThinMaterialLight];
    // A material in this clear window samples nothing and paints clear, which
    // hides the fill underneath. The fill is the tab.
    _notchBlur.hidden = YES;
    _notch.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:darkMode ? 0.28 : 0.45].CGColor;
    _pill.backgroundColor = [UIColor colorWithWhite:darkMode ? 1.0 : 0.12 alpha:0.92];
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
    [_topSlot showBundleIdentifier:nil dark:_darkMode title:@"New Stage"];
    _bottomSlot.hidden = YES;
}

- (CGRect)notchFrame {
    CGFloat height = CGRectGetHeight(self.bounds);
    CGFloat width = CGRectGetWidth(self.bounds);
    return CGRectMake(width - kDSShelfNotchWidth,
                      floor((height - kDSShelfNotchHeight) / 2.0),
                      kDSShelfNotchWidth,
                      kDSShelfNotchHeight);
}

- (CGRect)panelFrame {
    CGRect notch = [self notchFrame];
    CGFloat x = CGRectGetMinX(notch) - 10.0 - kDSShelfPanelWidth;
    CGFloat y = CGRectGetMidY(notch) - kDSShelfPanelHeight / 2.0;
    return CGRectMake(x, y, kDSShelfPanelWidth, kDSShelfPanelHeight);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect notch = [self notchFrame];
    _notch.frame = notch;
    // A radius as wide as the tab, with the continuous curve, masks the tab
    // down to a sliver. Keep the left edge rounded and the body visible.
    _notch.layer.cornerRadius = 8.0;
    _notch.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner;
    if (@available(iOS 13.0, *)) {
        _notch.layer.cornerCurve = kCACornerCurveContinuous;
    }
    _notchBlur.frame = _notch.bounds;

    _pill.bounds = CGRectMake(0, 0, 3.0, 22.0);
    _pill.center = CGPointMake(CGRectGetWidth(notch) / 2.0, CGRectGetHeight(notch) / 2.0);
    _pill.layer.cornerRadius = 1.5;
    _chevron.frame = CGRectInset(_notch.bounds, 0.0, 18.0);

    CGRect panel = [self panelFrame];
    _panel.bounds = CGRectMake(0, 0, CGRectGetWidth(panel), CGRectGetHeight(panel));
    _panel.center = CGPointMake(CGRectGetMidX(panel), CGRectGetMidY(panel));
    _panel.layer.cornerRadius = 26.0;
    _notch.layer.borderWidth = 0.5;
    _notchBlur.hidden = YES;

    if (!_draggingSlot) {
        _topSlot.frame = CGRectInset(_panel.bounds, 10.0, 10.0);
    }
    _bottomSlot.hidden = YES;
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
        self->_panel.transform = open ? CGAffineTransformIdentity : CGAffineTransformMakeTranslation(24.0, 0.0);
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
    if (_draggingSlot) return;
    void (^handler)(NSInteger) = self.halfHandler;
    [self setOpen:NO animated:YES];
    if (handler) handler(slot.half);
}

- (void)slotPanned:(UIPanGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        _draggingSlot = YES;
        _slotHomeCenter = _topSlot.center;
        _panel.clipsToBounds = NO;
        _panel.layer.masksToBounds = NO;
        _panel.contentView.clipsToBounds = NO;
        _panel.contentView.layer.masksToBounds = NO;
        [self bringSubviewToFront:_panel];
        _topSlot.transform = CGAffineTransformMakeScale(1.04, 1.04);
        if (self.slotDragHandler) self.slotDragHandler(recognizer.state, [recognizer locationInView:nil]);
        return;
    }
    if (recognizer.state == UIGestureRecognizerStateChanged) {
        CGPoint translation = [recognizer translationInView:_panel.contentView];
        _topSlot.center = CGPointMake(_slotHomeCenter.x + translation.x, _slotHomeCenter.y + translation.y);
        if (self.slotDragHandler) self.slotDragHandler(recognizer.state, [recognizer locationInView:nil]);
        return;
    }
    BOOL ended = recognizer.state == UIGestureRecognizerStateEnded;
    CGPoint translation = [recognizer translationInView:_panel.contentView];
    BOOL moved = ended && hypot(translation.x, translation.y) > 8.0;
    CGPoint point = [recognizer locationInView:nil];
    void (^drag)(UIGestureRecognizerState, CGPoint) = [self.slotDragHandler copy];
    if (moved) _topSlot.alpha = 0.0;
    [UIView animateWithDuration:0.22
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        self->_topSlot.center = self->_slotHomeCenter;
        self->_topSlot.transform = CGAffineTransformIdentity;
    } completion:^(BOOL finished) {
        (void)finished;
        self->_draggingSlot = NO;
        self->_topSlot.alpha = 1.0;
        self->_panel.clipsToBounds = YES;
        self->_panel.layer.masksToBounds = YES;
        self->_panel.contentView.clipsToBounds = YES;
        [self insertSubview:self->_panel belowSubview:self->_notch];
        [self setNeedsLayout];
        [self layoutIfNeeded];
    }];
    if (moved) {
        [self setOpen:NO animated:YES];
        if (drag) drag(UIGestureRecognizerStateEnded, point);
    } else if (drag) {
        drag(UIGestureRecognizerStateCancelled, point);
    }
}

- (void)slotHeld:(DSShelfSlotView *)slot {
    NSString *bundle = _topBundle;
    if (bundle.length == 0) return;
    void (^handler)(NSInteger) = self.halfHoldHandler;
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
    if (_draggingSlot) return YES;
    if (CGRectContainsPoint([self notchHitFrame], point)) return YES;
    if (_open && CGRectContainsPoint([self panelFrame], point)) return YES;
    return NO;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (_draggingSlot && _topSlot) {
        CGPoint inSlot = [self convertPoint:point toView:_topSlot];
        if ([_topSlot pointInside:inSlot withEvent:event]) return _topSlot;
    }
    if (![self claimsPoint:point]) return nil;
    UIView *hit = [super hitTest:point withEvent:event];
    if ((hit == self || !hit) && CGRectContainsPoint([self notchHitFrame], point)) return _notch;
    return hit;
}

@end
