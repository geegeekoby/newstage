#import "DSRootListController.h"
#import "DSAboutListController.h"
#import "DSBannerHeaderView.h"
#import "DSPrefsStore.h"
#import "DSConstants.h"

static NSString *const kDSOriginalAuthorURL = @"https://twitter.com/tomt000";

@implementation DSRootListController {
    DSBannerHeaderView *_banner;
    UIButton *_creditButton;
    BOOL _restoreNavigationBar;
}

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    NSBundle *bundle = [NSBundle bundleForClass:self.class];

    _banner = [[DSBannerHeaderView alloc] initWithBundle:bundle];
    _banner.frame = CGRectMake(0.0, 0.0, CGRectGetWidth(self.table.bounds), _banner.preferredHeight);
    _banner.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.table.tableHeaderView = _banner;
    self.table.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;

    NSString *logoPath = [bundle pathForResource:@"logo@3x" ofType:@"png"];
    UIImage *logo = logoPath ? [UIImage imageWithContentsOfFile:logoPath] : nil;
    if (logo) {
        UIImage *scaled = [UIImage imageWithCGImage:logo.CGImage scale:3.0 orientation:UIImageOrientationUp];
        UIImageView *titleView = [[UIImageView alloc] initWithImage:scaled];
        titleView.contentMode = UIViewContentModeScaleAspectFit;
        titleView.frame = CGRectMake(0.0, 0.0, 26.0, 26.0);
        self.navigationItem.titleView = titleView;
    }

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"About"
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:self
                                                                            action:@selector(openAbout)];

    _creditButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_creditButton setImage:[UIImage systemImageNamed:@"bird.fill"] forState:UIControlStateNormal];
    _creditButton.tintColor = [UIColor colorWithRed:0.11 green:0.63 blue:0.95 alpha:1.0];
    [_creditButton addTarget:self action:@selector(openOriginalAuthor) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_creditButton];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self setNavigationBarTransparent:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self setNavigationBarTransparent:NO];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGRect bounds = self.view.bounds;
    UIEdgeInsets safeArea = self.view.safeAreaInsets;
    _creditButton.frame = CGRectMake(CGRectGetMaxX(bounds) - 44.0,
                                     CGRectGetMaxY(bounds) - safeArea.bottom - 42.0,
                                     30.0,
                                     30.0);
}

// The banner has to sit under the bar, exactly as the stock page does; the
// original appearance is restored on the way out so the rest of Settings is not
// left see-through.
- (void)setNavigationBarTransparent:(BOOL)transparent {
    UINavigationBar *bar = self.navigationController.navigationBar;
    if (!bar) return;

    if (transparent) {
        UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
        [appearance configureWithTransparentBackground];
        bar.standardAppearance = appearance;
        bar.scrollEdgeAppearance = appearance;
        bar.compactAppearance = appearance;
        _restoreNavigationBar = YES;
        return;
    }

    if (!_restoreNavigationBar) return;
    UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithDefaultBackground];
    bar.standardAppearance = appearance;
    bar.scrollEdgeAppearance = nil;
    bar.compactAppearance = nil;
    _restoreNavigationBar = NO;
}

#pragma mark - Preferences

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];

    NSString *key = [specifier propertyForKey:@"key"];
    if ([key isEqualToString:kDSPrefEnabled]) {
        [self promptForRespring];
    }
}

- (void)promptForRespring {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Dynamic Stage"
                                                                  message:@"Toggling this setting requires a respring.\nRespring now?"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Respring"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction *action) {
        [[DSPrefsStore sharedStore] respring];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Actions

- (void)openAbout {
    DSAboutListController *about = [[DSAboutListController alloc] init];
    [self.navigationController pushViewController:about animated:YES];
}

- (void)openOriginalAuthor {
    [UIApplication.sharedApplication openURL:[NSURL URLWithString:kDSOriginalAuthorURL] options:@{} completionHandler:nil];
}

#pragma mark - UIScrollViewDelegate

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if ([super respondsToSelector:@selector(scrollViewDidScroll:)]) {
        [super scrollViewDidScroll:scrollView];
    }
    [_banner updateForContentOffset:scrollView.contentOffset];
}

@end
