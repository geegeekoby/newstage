#import "DSPinRowsCell.h"
#import "DSPrefsStore.h"
#import "DSConstants.h"

static const CGFloat kDSTileCornerRadius = 14.0;

@interface DSPinRowsTile : UIControl
@property (nonatomic, assign) NSInteger rows;
@property (nonatomic, assign, getter=isActive) BOOL active;
- (instancetype)initWithImage:(UIImage *)image title:(NSString *)title rows:(NSInteger)rows;
@end

@implementation DSPinRowsTile {
    UIImageView *_artwork;
    UILabel *_title;
    UIImageView *_mark;
}

- (instancetype)initWithImage:(UIImage *)image title:(NSString *)title rows:(NSInteger)rows {
    if ((self = [super initWithFrame:CGRectZero])) {
        _rows = rows;

        _artwork = [[UIImageView alloc] initWithImage:image];
        _artwork.contentMode = UIViewContentModeScaleAspectFill;
        _artwork.clipsToBounds = YES;
        _artwork.layer.cornerRadius = kDSTileCornerRadius;
        _artwork.layer.cornerCurve = kCACornerCurveContinuous;
        _artwork.layer.borderWidth = 1.0;
        [self addSubview:_artwork];

        _title = [[UILabel alloc] initWithFrame:CGRectZero];
        _title.text = title;
        _title.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
        _title.textAlignment = NSTextAlignmentCenter;
        _title.textColor = UIColor.labelColor;
        [self addSubview:_title];

        _mark = [[UIImageView alloc] initWithFrame:CGRectZero];
        _mark.contentMode = UIViewContentModeScaleAspectFit;
        _mark.tintColor = UIColor.systemBlueColor;
        [self addSubview:_mark];

        self.active = NO;
    }
    return self;
}

- (void)setActive:(BOOL)active {
    _active = active;
    _mark.image = [UIImage systemImageNamed:active ? @"checkmark.circle.fill" : @"circle"];
    _mark.tintColor = active ? UIColor.systemBlueColor : UIColor.tertiaryLabelColor;
    _artwork.layer.borderColor = (active ? UIColor.systemBlueColor : UIColor.clearColor).CGColor;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGRect bounds = self.bounds;
    CGFloat markHeight = 22.0;
    CGFloat titleHeight = 18.0;
    CGFloat artworkHeight = CGRectGetHeight(bounds) - titleHeight - markHeight - 10.0;

    _artwork.frame = CGRectMake(0.0, 0.0, CGRectGetWidth(bounds), artworkHeight);
    _title.frame = CGRectMake(0.0, CGRectGetMaxY(_artwork.frame) + 6.0, CGRectGetWidth(bounds), titleHeight);
    _mark.frame = CGRectMake((CGRectGetWidth(bounds) - markHeight) / 2.0,
                             CGRectGetMaxY(_title.frame) + 4.0,
                             markHeight,
                             markHeight);
}

@end

@implementation DSPinRowsCell {
    DSPinRowsTile *_double;
    DSPinRowsTile *_triple;
    UIImpactFeedbackGenerator *_feedback;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];

        NSBundle *bundle = [NSBundle bundleForClass:self.class];
        _double = [[DSPinRowsTile alloc] initWithImage:[self imageNamed:@"double" inBundle:bundle] title:@"Double" rows:2];
        _triple = [[DSPinRowsTile alloc] initWithImage:[self imageNamed:@"tripple" inBundle:bundle] title:@"Tripple" rows:3];

        for (DSPinRowsTile *tile in @[ _double, _triple ]) {
            [tile addTarget:self action:@selector(tileTapped:) forControlEvents:UIControlEventTouchUpInside];
            [self.contentView addSubview:tile];
        }

        [self refreshSelection];
    }
    return self;
}

- (UIImage *)imageNamed:(NSString *)name inBundle:(NSBundle *)bundle {
    NSString *path = [bundle pathForResource:name ofType:@"png"];
    return path ? [UIImage imageWithContentsOfFile:path] : nil;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGRect bounds = self.contentView.bounds;
    CGFloat gap = 18.0;
    CGFloat inset = 8.0;
    CGFloat width = (CGRectGetWidth(bounds) - gap - inset * 2.0) / 2.0;
    CGFloat height = CGRectGetHeight(bounds) - 16.0;

    _double.frame = CGRectMake(inset, 8.0, width, height);
    _triple.frame = CGRectMake(inset + width + gap, 8.0, width, height);
}

- (void)refreshSelection {
    NSInteger rows = [[DSPrefsStore sharedStore] integerForKey:kDSPrefPinnedRows fallback:2];
    _double.active = rows != 3;
    _triple.active = rows == 3;
}

- (void)tileTapped:(DSPinRowsTile *)tile {
    [_feedback impactOccurred];
    [[DSPrefsStore sharedStore] setObject:@(tile.rows) forKey:kDSPrefPinnedRows];
    [self refreshSelection];
}

@end
