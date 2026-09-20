#import "DSAppListController.h"
#import "DSAppBehaviorController.h"
#import "DSPrefsAppList.h"
#import "DSPrefsStore.h"
#import "DSConstants.h"

@implementation DSAppListController {
    UISearchController *_searchController;
    NSString *_query;
}

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self buildSpecifiers];
    }
    return _specifiers;
}

- (NSMutableArray *)buildSpecifiers {
    NSMutableArray *specifiers = [NSMutableArray array];
    NSArray<DSPrefsApp *> *applications = [[DSPrefsAppList sharedList] applicationsMatching:_query];

    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:nil];
    [group setProperty:@"Pick an app to change how it behaves on the stage. Apps set to iPad mode resize without relaunching; disabled apps are hidden from the picker."
                forKey:@"footerText"];
    [specifiers addObject:group];

    DSPrefsStore *store = [DSPrefsStore sharedStore];
    for (DSPrefsApp *application in applications) {
        PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:application.displayName
                                                               target:self
                                                                  set:NULL
                                                                  get:NULL
                                                               detail:DSAppBehaviorController.class
                                                                 cell:PSLinkCell
                                                                 edit:Nil];
        [specifier setProperty:application.bundleIdentifier forKey:@"applicationIdentifier"];
        [specifier setProperty:application.bundleIdentifier forKey:@"id"];

        UIImage *icon = [[DSPrefsAppList sharedList] iconForBundleIdentifier:application.bundleIdentifier];
        if (icon) [specifier setProperty:icon forKey:@"iconImage"];

        // Summarise the override on the row so the list doubles as an overview.
        NSDictionary *settings = [store settingsForApplication:application.bundleIdentifier];
        NSMutableArray *parts = [NSMutableArray array];
        if ([settings[kDSAppPrefDisabled] boolValue]) [parts addObject:@"Disabled"];
        if ([settings[kDSAppPrefLaunchType] integerValue] == DSLaunchTypePad) [parts addObject:@"iPad"];
        if ([settings[kDSAppPrefBackgroundOnMinimize] boolValue]) [parts addObject:@"Background"];
        if (parts.count > 0) [specifier setProperty:[parts componentsJoinedByString:@", "] forKey:@"value"];

        [specifiers addObject:specifier];
    }

    return specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    _searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    _searchController.searchResultsUpdater = self;
    _searchController.obscuresBackgroundDuringPresentation = NO;
    _searchController.searchBar.placeholder = @"Search";
    _searchController.searchBar.delegate = self;

    self.navigationItem.searchController = _searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;
    self.definesPresentationContext = YES;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Values shown on each row change while the user is inside a behaviour page.
    [self reloadApplications];
}

- (void)reloadApplications {
    _specifiers = [self buildSpecifiers];
    [self reloadSpecifiers];
}

#pragma mark - UISearchResultsUpdating

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = searchController.searchBar.text;
    if ([query isEqualToString:_query] || (query.length == 0 && _query.length == 0)) return;
    _query = [query copy];
    [self reloadApplications];
}

@end
