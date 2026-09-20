#import "DSPinnedAppsListController.h"
#import "DSPinRowsCell.h"
#import "DSPrefsAppList.h"
#import "DSPrefsStore.h"
#import "DSConstants.h"

static const CGFloat kDSRowsCellHeight = 226.0;

@implementation DSPinnedAppsListController {
    UISearchController *_searchController;
    NSString *_query;
    NSMutableArray<NSString *> *_pinned;
    UIImpactFeedbackGenerator *_feedback;
}

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        _pinned = [[[DSPrefsStore sharedStore] pinnedApplications] mutableCopy];
        _specifiers = [self buildSpecifiers];
    }
    return _specifiers;
}

- (NSMutableArray *)buildSpecifiers {
    NSMutableArray *specifiers = [NSMutableArray array];
    DSPrefsAppList *list = [DSPrefsAppList sharedList];

    PSSpecifier *rowsGroup = [PSSpecifier groupSpecifierWithName:@"Rows"];
    [rowsGroup setProperty:@"How many rows of pinned apps the stage keeps above the recently opened ones." forKey:@"footerText"];
    [specifiers addObject:rowsGroup];

    PSSpecifier *rows = [PSSpecifier preferenceSpecifierNamed:@"Count"
                                                      target:self
                                                         set:NULL
                                                         get:NULL
                                                      detail:Nil
                                                        cell:PSTitleValueCell
                                                        edit:Nil];
    [rows setProperty:DSPinRowsCell.class forKey:@"cellClass"];
    [rows setProperty:@(kDSRowsCellHeight) forKey:@"height"];
    [rows setProperty:@"pinRows" forKey:@"id"];
    [specifiers addObject:rows];

    PSSpecifier *pinnedGroup = [PSSpecifier groupSpecifierWithName:@"Pinned Apps"];
    [pinnedGroup setProperty:@"Drag to reorder. Tap an app below to pin it, tap a pinned app to remove it." forKey:@"footerText"];
    [pinnedGroup setProperty:@"pinnedGroup" forKey:@"id"];
    [specifiers addObject:pinnedGroup];

    for (NSString *identifier in _pinned) {
        DSPrefsApp *application = [list applicationWithBundleIdentifier:identifier];
        PSSpecifier *specifier = [self specifierForApplicationIdentifier:identifier
                                                                   name:application.displayName ?: identifier
                                                                 pinned:YES];
        [specifiers addObject:specifier];
    }

    PSSpecifier *libraryGroup = [PSSpecifier groupSpecifierWithName:@"App Library"];
    [libraryGroup setProperty:@"library" forKey:@"id"];
    [specifiers addObject:libraryGroup];

    for (DSPrefsApp *application in [list applicationsMatching:_query]) {
        if ([_pinned containsObject:application.bundleIdentifier]) continue;
        [specifiers addObject:[self specifierForApplicationIdentifier:application.bundleIdentifier
                                                                name:application.displayName
                                                              pinned:NO]];
    }

    return specifiers;
}

- (PSSpecifier *)specifierForApplicationIdentifier:(NSString *)identifier name:(NSString *)name pinned:(BOOL)pinned {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:name
                                                          target:self
                                                             set:NULL
                                                             get:NULL
                                                          detail:Nil
                                                            cell:PSLinkCell
                                                            edit:Nil];
    specifier->action = @selector(toggleApplication:);
    [specifier setProperty:identifier forKey:@"applicationIdentifier"];
    [specifier setProperty:@(pinned) forKey:@"pinned"];
    [specifier setProperty:@YES forKey:@"hidesDisclosureIndicator"];
    [specifier setProperty:@(pinned ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone) forKey:@"accessory"];

    UIImage *icon = [[DSPrefsAppList sharedList] iconForBundleIdentifier:identifier];
    if (icon) [specifier setProperty:icon forKey:@"iconImage"];
    return specifier;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    _feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];

    _searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    _searchController.searchResultsUpdater = self;
    _searchController.obscuresBackgroundDuringPresentation = NO;
    _searchController.searchBar.placeholder = @"Search";
    _searchController.searchBar.delegate = self;
    self.navigationItem.searchController = _searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;
    self.definesPresentationContext = YES;

    // Editing stays on for the whole page so the reorder grips are always there,
    // which is what makes the pinned group feel draggable rather than modal.
    [self.table setEditing:YES animated:NO];
    self.table.allowsSelectionDuringEditing = YES;
}

#pragma mark - Pinning

- (void)toggleApplication:(PSSpecifier *)specifier {
    NSString *identifier = [specifier propertyForKey:@"applicationIdentifier"];
    if (identifier.length == 0) return;

    [_feedback impactOccurred];
    if ([_pinned containsObject:identifier]) {
        [_pinned removeObject:identifier];
    } else {
        [_pinned addObject:identifier];
    }
    [self commitPinned];
    [self rebuild];
}

- (void)commitPinned {
    [[DSPrefsStore sharedStore] setPinnedApplications:[_pinned copy]];
}

- (void)rebuild {
    _specifiers = [self buildSpecifiers];
    [self reloadSpecifiers];
    [self.table setEditing:YES animated:NO];
}

#pragma mark - Reordering

- (NSInteger)pinnedGroupIndex {
    NSInteger group = 0;
    NSInteger row = 0;
    if ([self getGroup:&group row:&row ofSpecifierID:@"pinnedGroup"]) return group;
    return NSNotFound;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == [self pinnedGroupIndex] && _pinned.count > 1;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

- (NSIndexPath *)tableView:(UITableView *)tableView
targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)sourceIndexPath
       toProposedIndexPath:(NSIndexPath *)proposedIndexPath {
    NSInteger pinnedGroup = [self pinnedGroupIndex];
    if (proposedIndexPath.section == pinnedGroup) return proposedIndexPath;
    // Dragging out of the group would mean "unpin"; the tap already does that, so
    // the row is clamped to the ends of the pinned list instead.
    NSInteger row = proposedIndexPath.section < pinnedGroup ? 0 : (NSInteger)_pinned.count - 1;
    return [NSIndexPath indexPathForRow:row inSection:pinnedGroup];
}

- (void)tableView:(UITableView *)tableView
moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath
      toIndexPath:(NSIndexPath *)destinationIndexPath {
    NSInteger pinnedGroup = [self pinnedGroupIndex];
    if (sourceIndexPath.section != pinnedGroup || destinationIndexPath.section != pinnedGroup) return;
    if (sourceIndexPath.row >= (NSInteger)_pinned.count) return;

    NSString *identifier = _pinned[sourceIndexPath.row];
    [_pinned removeObjectAtIndex:sourceIndexPath.row];
    NSInteger destination = MIN(destinationIndexPath.row, (NSInteger)_pinned.count);
    [_pinned insertObject:identifier atIndex:destination];

    [self commitPinned];
    [_feedback impactOccurred];

    // The move is already reflected in the table; rebuilding keeps the specifier
    // order in step without animating the rows a second time.
    _specifiers = [self buildSpecifiers];
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([super respondsToSelector:@selector(tableView:willDisplayCell:forRowAtIndexPath:)]) {
        [super tableView:tableView willDisplayCell:cell forRowAtIndexPath:indexPath];
    }
    cell.showsReorderControl = indexPath.section == [self pinnedGroupIndex];
}

#pragma mark - UISearchResultsUpdating

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = searchController.searchBar.text;
    if ([query isEqualToString:_query] || (query.length == 0 && _query.length == 0)) return;
    _query = [query copy];
    [self rebuild];
}

@end
