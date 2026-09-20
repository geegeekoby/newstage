#import "DSBannerHeaderView.h"
#import "DSPrefsPrivate.h"
#import "DSConstants.h"
#import "DSDiagnostics.h"

static NSString *DSPackageVersion(void) {
    static NSString *version;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        for (NSString *path in @[ @"/var/jb/var/lib/dpkg/status", @"/var/lib/dpkg/status" ]) {
            NSString *status = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
            if (status.length == 0) continue;

            NSString *marker = [@"Package: " stringByAppendingString:kDSPackageIdentifier];
            NSRange stanza = [status rangeOfString:marker];
            if (stanza.location == NSNotFound) continue;

            NSString *tail = [status substringFromIndex:stanza.location];
            NSRange versionKey = [tail rangeOfString:@"\nVersion: "];
            if (versionKey.location == NSNotFound) continue;

            NSString *afterKey = [tail substringFromIndex:NSMaxRange(versionKey)];
            NSRange newline = [afterKey rangeOfString:@"\n"];
            version = newline.location == NSNotFound ? afterKey : [afterKey substringToIndex:newline.location];
            break;
        }
        if (version.length == 0) version = @"1.2.0";
    });
    return version;
}

@implementation DSBannerHeaderView {
    UIView *_parallax;
    UIImageView *_artwork;
    UIVisualEffectView *_blur;
    UIView *_wordmark;
    CAGradientLayer *_fade;
}

- (instancetype)initWithBundle:(NSBundle *)bundle {
    if ((self = [super initWithFrame:CGRectZero])) {
        _preferredHeight = 300.0;
        self.clipsToBounds = YES;
        self.backgroundColor = UIColor.clearColor;

        _parallax = [[UIView alloc] initWithFrame:CGRectZero];
        [self addSubview:_parallax];

        UIImage *artwork = nil;
        NSString *path = [bundle pathForResource:@"bg" ofType:@"png"];
        if (path) artwork = [UIImage imageWithContentsOfFile:path];

        _artwork = [[UIImageView alloc] initWithImage:artwork];
        _artwork.contentMode = UIViewContentModeScaleAspectFill;
        _artwork.clipsToBounds = YES;
        [_parallax addSubview:_artwork];

        UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
        _blur = [[UIVisualEffectView alloc] initWithEffect:effect];
        _blur.alpha = 0.5;
        [_parallax addSubview:_blur];

        _fade = [CAGradientLayer layer];
        _fade.colors = @[ (id)UIColor.whiteColor.CGColor,
                          (id)[UIColor colorWithWhite:1.0 alpha:0.7].CGColor,
                          (id)UIColor.clearColor.CGColor ];
        _fade.locations = @[ @0.0, @0.6, @1.0 ];

        _wordmark = [[UIView alloc] initWithFrame:CGRectZero];
        [self addSubview:_wordmark];

        UILabel *dynamic = [self labelWithText:@"Dynamic" size:46.0 weight:UIFontWeightBold color:UIColor.labelColor];
        UILabel *stage = [self labelWithText:@"Stage" size:46.0 weight:UIFontWeightBold color:UIColor.labelColor];
        NSString *version = [NSString stringWithFormat:@"v%@ - recreation", DSPackageVersion()];
        UILabel *versionLabel = [self labelWithText:version size:15.0 weight:UIFontWeightRegular color:UIColor.secondaryLabelColor];

        [_wordmark addSubview:dynamic];
        [_wordmark addSubview:stage];
        [_wordmark addSubview:versionLabel];

        // Two lines of a wordmark have to sit tighter than their line boxes do, so
        // the gap between them is negative. The visual format language cannot say
        // that - it rejects a negative spacing and throws while the page is being
        // built, taking Settings with it - so the stack is spelled out instead.
        [NSLayoutConstraint activateConstraints:@[
            [dynamic.topAnchor constraintEqualToAnchor:_wordmark.topAnchor],
            [stage.topAnchor constraintEqualToAnchor:dynamic.bottomAnchor constant:-10.0],
            [versionLabel.topAnchor constraintEqualToAnchor:stage.bottomAnchor constant:2.0],
            [versionLabel.bottomAnchor constraintEqualToAnchor:_wordmark.bottomAnchor],
            [dynamic.leadingAnchor constraintEqualToAnchor:_wordmark.leadingAnchor],
            [stage.leadingAnchor constraintEqualToAnchor:_wordmark.leadingAnchor],
            [versionLabel.leadingAnchor constraintEqualToAnchor:_wordmark.leadingAnchor],
        ]];

        [self startDrifting];
    }
    return self;
}

- (UILabel *)labelWithText:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    return label;
}

// The stock banner loops a clip of the tweak in use behind the blur. A blurred
// still would read as static next to it, so the artwork breathes instead.
- (void)startDrifting {
    UIImageView *artwork = _artwork;
    [UIView animateWithDuration:16.0
                          delay:0.0
                        options:UIViewAnimationOptionRepeat | UIViewAnimationOptionAutoreverse | UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        artwork.transform = CGAffineTransformMake(1.18, 0.0, 0.0, 1.18, -20.0, 12.0);
    }
                     completion:nil];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // Called by UIKit while Settings is building the page, so it answers for
    // itself: a header that cannot lay itself out must not be able to take the
    // Settings app down with it.
    @try {
        [self layoutBanner];
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"prefs: the page header could not lay out - %@", exception.reason ?: @"?");
    }
}

- (void)layoutBanner {
    CGRect bounds = self.bounds;
    _parallax.frame = bounds;

    CGRect artwork = CGRectMake(-CGRectGetWidth(bounds) * 0.15,
                                -CGRectGetHeight(bounds) * 0.3,
                                CGRectGetWidth(bounds) * 1.3,
                                CGRectGetHeight(bounds) * 1.2);
    CGAffineTransform drift = _artwork.transform;
    _artwork.transform = CGAffineTransformIdentity;
    _artwork.frame = artwork;
    _artwork.transform = drift;

    _blur.transform = CGAffineTransformIdentity;
    _blur.frame = artwork;

    // Masking the parallax layer keeps the blur and the artwork fading together.
    _fade.frame = bounds;
    _parallax.layer.mask = _fade;

    CGSize wordmarkSize = [_wordmark systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
    CGFloat inset = self.layoutMargins.left > 0 ? self.layoutMargins.left : 20.0;
    _wordmark.frame = CGRectMake(inset,
                                 CGRectGetHeight(bounds) - wordmarkSize.height - 34.0,
                                 CGRectGetWidth(bounds) - inset * 2.0,
                                 wordmarkSize.height);
}

- (void)updateForContentOffset:(CGPoint)offset {
    CGFloat pulled = MAX(offset.y, 0.0);
    _wordmark.alpha = 1.0 - MIN(pulled / (_preferredHeight * 0.5), 1.0);
    _parallax.transform = CGAffineTransformMakeTranslation(0.0, pulled * 0.3);
}

@end
