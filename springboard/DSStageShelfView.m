#import "DSStageShelfView.h"
#import "DSAppLibrary.h"

static const CGFloat kDSShelfNotchWidth = 18.0;
static const CGFloat kDSShelfNotchHeight = 74.0;
static const CGFloat kDSShelfPanelWidth = 268.0;
static const CGFloat kDSShelfRowHeight = 54.0;
static const NSInteger kDSShelfRecentLimit = 8;

@interface DSShelfAppRow : UIControl
@property (nonatomic, copy) NSString *bundleIdentifier;
- (instancetype)initWithEntry:(DSAppEntry *)entry showing:(BOOL)showing dark:(BOOL)dark;
@end

@implementation DSShelfAppRow {
    UIImageView *_iconView;
    UILabel *_titleLabel;
    UILabel *_detailLabel;
}

- (instancetype)initWithEntry:(DSAppEntry *)entry showing:(BOOL)showing dark:(BOOL)dark {
    if ((self = [super initWithFrame:CGRectZero])) {
        _bundleIdentifier = [entry.bundleIdentifier copy];
        self.backgroundColor = UIColor.clearColor;

        _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.clipsToBounds = YES;
        _iconView.layer.cornerCurve = kCACornerCurveContinuous;
        _iconView.layer.cornerRadius = 9.0;
        _iconView.image = [[DSAppLibrary sharedLibrary] iconForBundleIdentifier:entry.bundleIdentifier];
        [self addSubview:_iconView];

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
        _titleLabel.text = entry.displayName.length ? entry.displayName : entry.bundleIdentifier;
        _titleLabel.textColor = dark ? UIColor.whiteColor : UIColor.blackColor;
        [self addSubview:_titleLabel];

        _detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _detailLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
        _detailLabel.text = showing ? @"Showing" : @"Recent";
        _detailLabel.textColor = showing
            ? [UIColor colorWithRed:0.35 green:0.78 blue:1.0 alpha:1.0]
            : [UIColor colorWithWhite:dark ? 1.0 : 0.0 alpha:0.45];
        [self addSubview:_detailLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat side = 36.0;
    _iconView.frame = CGRectMake(14.0, (CGRectGetHeight(self.bounds) - side) / 2.0, side, side);
    CGFloat textX = CGRectGetMaxX(_iconView.frame) + 12.0;
    CGFloat textW = CGRectGetWidth(self.bounds) - textX - 14.0;
    _titleLabel.frame = CGRectMake(textX, 8.0, textW, 20.0);
    _detailLabel.frame = CGRectMake(textX, 28.0, textW, 16.0);
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.backgroundColor = highlighted ? [UIColor colorWithWhite:1.0 alpha:0.12] : UIColor.clearColor;
}

@end

@implementation DSStageShelfView {
    UIControl *_notch;
    UIView *_pill;
    UIImageView *_chevron;
    UIVisualEffectView *_panel;
    UILabel *_titleLabel;
    UIScrollView *_scrollView;
    UILabel *_emptyLabel;
    NSArray<NSString *> *_staged;
    NSArray<NSString *> *_recent;
    BOOL _open;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        _notch = [[UIControl alloc] initWithFrame:CGRectZero];
        _notch.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.72];
        _notch.clipsToBounds = YES;
        _notch.accessibilityLabel = @"Staged apps";
        [_notch addTarget:self action:@selector(notchTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_notch];

        _pill = [[UIView alloc] initWithFrame:CGRectZero];
        _pill.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.88];
        _pill.userInteractionEnabled = NO;
        [_notch addSubview:_pill];

        _chevron = [[UIImageView alloc] initWithFrame:CGRectZero];
        _chevron.contentMode = UIViewContentModeScaleAspectFit;
        _chevron.tintColor = [UIColor colorWithWhite:1.0 alpha:0.9];
        _chevron.userInteractionEnabled = NO;
        _chevron.hidden = YES;
        [_notch addSubview:_chevron];

        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark];
        _panel = [[UIVisualEffectView alloc] initWithEffect:blur];
        _panel.clipsToBounds = YES;
        _panel.layer.cornerCurve = kCACornerCurveContinuous;
    _panel.alpha = 0.0;
    _panel.userInteractionEnabled = NO;
    _panel.transform = CGAffineTransformMakeTranslation(28.0, 0.0);
    [self addSubview:_panel];

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.text = @"Staged";
        _titleLabel.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightBold];
        _titleLabel.textColor = UIColor.whiteColor;
        [_panel.contentView addSubview:_titleLabel];

        _scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
        _scrollView.alwaysBounceVertical = NO;
        _scrollView.showsVerticalScrollIndicator = NO;
        [_panel.contentView addSubview:_scrollView];

        _emptyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _emptyLabel.font = [UIFont systemFontOfSize:15.0];
        _emptyLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
        _emptyLabel.numberOfLines = 0;
        _emptyLabel.text = @"No staged apps yet. Open one on the stage and it will show up here.";
        _emptyLabel.hidden = YES;
        [_panel.contentView addSubview:_emptyLabel];

        self.darkMode = YES;
        [self applyChevron];
    }
    return self;
}

- (void)setDarkMode:(BOOL)darkMode {
    _darkMode = darkMode;
    UIBlurEffectStyle style = darkMode ? UIBlurEffectStyleSystemThickMaterialDark : UIBlurEffectStyleSystemThickMaterialLight;
    _panel.effect = [UIBlurEffect effectWithStyle:style];
    _titleLabel.textColor = darkMode ? UIColor.whiteColor : UIColor.blackColor;
    _emptyLabel.textColor = [UIColor colorWithWhite:darkMode ? 1.0 : 0.0 alpha:0.55];
    _notch.backgroundColor = darkMode
        ? [UIColor colorWithWhite:0.16 alpha:0.78]
        : [UIColor colorWithWhite:0.96 alpha:0.82];
    _pill.backgroundColor = [UIColor colorWithWhite:darkMode ? 1.0 : 0.15 alpha:0.88];
    _chevron.tintColor = [UIColor colorWithWhite:darkMode ? 1.0 : 0.1 alpha:0.9];
    if (_open || _staged || _recent) [self rebuildList];
}

- (BOOL)open {
    return _open;
}

- (void)reloadStagedIdentifiers:(NSArray<NSString *> *)staged
              recentIdentifiers:(NSArray<NSString *> *)recent {
    _staged = [staged copy] ?: @[];
    NSMutableArray *rest = [NSMutableArray array];
    NSSet *showing = [NSSet setWithArray:_staged];
    for (NSString *identifier in recent) {
        if (identifier.length == 0 || [showing containsObject:identifier]) continue;
        [rest addObject:identifier];
        if ((NSInteger)rest.count >= kDSShelfRecentLimit) break;
    }
    _recent = rest;
    [self rebuildList];
}

- (void)rebuildList {
    for (UIView *subview in [_scrollView.subviews copy]) {
        [subview removeFromSuperview];
    }

    DSAppLibrary *library = [DSAppLibrary sharedLibrary];
    CGFloat width = kDSShelfPanelWidth;
    CGFloat y = 0.0;

    y = [self appendHeader:@"Showing" atY:y width:width];
    NSInteger showingCount = 0;
    for (NSString *identifier in _staged) {
        DSAppEntry *entry = [library entryForBundleIdentifier:identifier];
        if (!entry) continue;
        y = [self appendRowForEntry:entry showing:YES atY:y width:width];
        showingCount++;
    }
    if (showingCount == 0) {
        y = [self appendNote:@"Nothing on a stage right now." atY:y width:width];
    }

    y = [self appendHeader:@"Recent" atY:y width:width];
    NSInteger recentCount = 0;
    for (NSString *identifier in _recent) {
        DSAppEntry *entry = [library entryForBundleIdentifier:identifier];
        if (!entry) continue;
        y = [self appendRowForEntry:entry showing:NO atY:y width:width];
        recentCount++;
    }
    if (recentCount == 0) {
        y = [self appendNote:@"Apps you stage will stay in this list." atY:y width:width];
    }

    _scrollView.contentSize = CGSizeMake(width, y);
    _emptyLabel.hidden = YES;
    [self setNeedsLayout];
}

- (CGFloat)appendHeader:(NSString *)text atY:(CGFloat)y width:(CGFloat)width {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(16.0, y + 6.0, width - 32.0, 18.0)];
    label.text = text;
    label.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    label.textColor = [UIColor colorWithWhite:_darkMode ? 1.0 : 0.0 alpha:0.45];
    [_scrollView addSubview:label];
    return CGRectGetMaxY(label.frame) + 4.0;
}

- (CGFloat)appendNote:(NSString *)text atY:(CGFloat)y width:(CGFloat)width {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(16.0, y, width - 32.0, 36.0)];
    label.text = text;
    label.font = [UIFont systemFontOfSize:13.0];
    label.textColor = [UIColor colorWithWhite:_darkMode ? 1.0 : 0.0 alpha:0.4];
    label.numberOfLines = 2;
    [_scrollView addSubview:label];
    return CGRectGetMaxY(label.frame) + 4.0;
}

- (CGFloat)appendRowForEntry:(DSAppEntry *)entry showing:(BOOL)showing atY:(CGFloat)y width:(CGFloat)width {
    DSShelfAppRow *row = [[DSShelfAppRow alloc] initWithEntry:entry showing:showing dark:_darkMode];
    row.frame = CGRectMake(0.0, y, width, kDSShelfRowHeight);
    [row addTarget:self action:@selector(rowTapped:) forControlEvents:UIControlEventTouchUpInside];
    [_scrollView addSubview:row];
    return CGRectGetMaxY(row.frame);
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
    CGFloat content = _scrollView.contentSize.height + 58.0;
    CGFloat limit = CGRectGetHeight(self.bounds) - 96.0;
    return MIN(MAX(content, 168.0), MAX(limit, 168.0));
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

    _titleLabel.frame = CGRectMake(18.0, 16.0, kDSShelfPanelWidth - 36.0, 26.0);
    _scrollView.frame = CGRectMake(0.0, 50.0, kDSShelfPanelWidth, CGRectGetHeight(panel) - 58.0);
    _emptyLabel.frame = CGRectMake(18.0, 58.0, kDSShelfPanelWidth - 36.0, 72.0);
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

- (void)rowTapped:(DSShelfAppRow *)row {
    if (row.bundleIdentifier.length == 0) return;
    void (^handler)(NSString *) = self.selectionHandler;
    [self setOpen:NO animated:YES];
    if (handler) handler(row.bundleIdentifier);
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
