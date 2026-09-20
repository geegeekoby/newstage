#import "DSRootListController.h"
#import "DSAboutListController.h"
#import "DSBannerHeaderView.h"
#import "DSPrefsStore.h"
#import "DSConstants.h"
#import "DSDiagnostics.h"
#import "DSSafety.h"

static NSString *const kDSOriginalAuthorURL = @"https://twitter.com/tomt000";

@implementation DSRootListController {
    DSBannerHeaderView *_banner;
    UIButton *_creditButton;
    BOOL _restoreNavigationBar;
}

- (instancetype)init {
    if ((self = [super init])) {
        DSPrefsNotePageOpening();
    }
    return self;
}

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        DSPrefsNotePageOpening();
        // The plain page carries the same settings with none of the custom cells,
        // so a page that cannot be drawn can still be used.
        NSString *name = DSPrefsPlainMode() ? @"RootSafe" : @"Root";
        DSPrefsRun(@"loading the settings list", ^{
            _specifiers = [self loadSpecifiersFromPlistName:name target:self];
        });
        if (!_specifiers) {
            DSPrefsRun(@"loading the plain settings list", ^{
                _specifiers = [self loadSpecifiersFromPlistName:@"RootSafe" target:self];
            });
        }
        if (!_specifiers) _specifiers = [NSMutableArray array];
    }
    return _specifiers;
}

- (void)viewDidLoad {
    DSPrefsNotePageOpening();
    [super viewDidLoad];

    if (DSPrefsPlainMode()) {
        self.title = @"Dynamic Stage";
        return;
    }

    DSPrefsRun(@"building the page header", ^{
        [self installBanner];
    });
    DSPrefsRun(@"building the navigation bar items", ^{
        [self installNavigationItems];
    });
}

- (void)installBanner {
    NSBundle *bundle = [NSBundle bundleForClass:self.class];

    _banner = [[DSBannerHeaderView alloc] initWithBundle:bundle];
    _banner.frame = CGRectMake(0.0, 0.0, CGRectGetWidth(self.table.bounds), _banner.preferredHeight);
    _banner.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.table.tableHeaderView = _banner;
    self.table.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
}

- (void)installNavigationItems {
    NSBundle *bundle = [NSBundle bundleForClass:self.class];

    NSString *logoPath = [bundle pathForResource:@"logo@3x" ofType:@"png"];
    UIImage *logo = logoPath ? [UIImage imageWithContentsOfFile:logoPath] : nil;
    if (logo.CGImage) {
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
    if (DSPrefsPlainMode()) return;
    DSPrefsRun(@"clearing the navigation bar background", ^{
        [self setNavigationBarTransparent:YES];
    });
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    DSPrefsNotePageShown();
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (DSPrefsPlainMode()) return;
    DSPrefsRun(@"restoring the navigation bar background", ^{
        [self setNavigationBarTransparent:NO];
    });
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!_creditButton) return;

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

- (void)restoreFullPage {
    DSPrefsResetPlainMode();
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Restored"
                                                                  message:@"The page will be shown in full the next time it is opened."
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)openOriginalAuthor {
    [UIApplication.sharedApplication openURL:[NSURL URLWithString:kDSOriginalAuthorURL] options:@{} completionHandler:nil];
}

#pragma mark - UIScrollViewDelegate

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    // Asking super whether it responds to a selector still answers for this
    // class, so it says yes to the method being written right here and then sends
    // it to a superclass that need not implement it. The superclass has to be
    // asked about its own instances instead.
    if ([DSRootListController.superclass instancesRespondToSelector:_cmd]) {
        [super scrollViewDidScroll:scrollView];
    }
    [_banner updateForContentOffset:scrollView.contentOffset];
}

@end
