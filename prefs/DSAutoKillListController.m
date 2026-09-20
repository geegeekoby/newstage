#import "DSAutoKillListController.h"
#import "DSPrefsStore.h"
#import "DSConstants.h"

static NSArray<NSString *> *DSAutoKillTitles(void) {
    return @[ @"On Close", @"5 minutes", @"10 minutes" ];
}

@implementation DSAutoKillListController

+ (NSString *)currentSelectionTitle {
    NSInteger selection = [[DSPrefsStore sharedStore] integerForKey:kDSPrefAutoKill fallback:DSAutoKillOnClose];
    NSArray *titles = DSAutoKillTitles();
    if (selection < 0 || selection >= (NSInteger)titles.count) selection = DSAutoKillOnClose;
    return titles[selection];
}

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"AutoKill" target:self];
        [self refreshCheckmarks];
    }
    return _specifiers;
}

- (void)refreshCheckmarks {
    NSInteger selection = [[DSPrefsStore sharedStore] integerForKey:kDSPrefAutoKill fallback:DSAutoKillOnClose];
    NSArray<NSString *> *titles = DSAutoKillTitles();

    for (PSSpecifier *specifier in _specifiers) {
        if (specifier.cellType == PSGroupCell) continue;
        NSString *title = [specifier propertyForKey:@"value"] ?: specifier.name;
        NSInteger index = [titles indexOfObject:title];
        BOOL checked = index != NSNotFound && index == selection;
        [specifier setProperty:@(checked ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone)
                       forKey:@"accessory"];
    }
}

// Bound from AutoKill.plist; PSListController hands the tapped specifier over.
- (void)selectAutoKillOption:(PSSpecifier *)specifier {
    NSString *title = [specifier propertyForKey:@"value"] ?: specifier.name;
    NSInteger index = [DSAutoKillTitles() indexOfObject:title];
    if (index == NSNotFound) return;

    [[DSPrefsStore sharedStore] setObject:@(index) forKey:kDSPrefAutoKill];
    [self refreshCheckmarks];
    [self reloadSpecifiers];

    NSIndexPath *selected = self.table.indexPathForSelectedRow;
    if (selected) [self.table deselectRowAtIndexPath:selected animated:YES];
}

@end
