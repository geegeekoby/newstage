#import "DSAboutListController.h"
#import "DSPrefsStore.h"
#import "DSConstants.h"

static NSString *const kDSOriginalAuthorURL = @"https://twitter.com/tomt000";

@implementation DSAboutListController

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"About" target:self];
        [self refreshKillSwitchRow];
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"About";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshKillSwitchRow];
    [self reloadSpecifiers];
}

- (BOOL)killSwitchPresent {
    for (NSString *path in @[ kDSKillSwitchPath, [@"/var/jb" stringByAppendingString:kDSKillSwitchPath] ]) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return YES;
    }
    return NO;
}

- (void)refreshKillSwitchRow {
    PSSpecifier *specifier = [self specifierForID:@"killSwitch"];
    if (!specifier) return;
    BOOL present = [self killSwitchPresent];
    specifier.name = present ? @"Remove Safe Mode Flag" : @"Create Safe Mode Flag";
    [specifier setProperty:present ? @"Hooks disabled" : @"Hooks active" forKey:@"value"];
}

#pragma mark - Actions

- (void)openOriginalAuthor {
    [UIApplication.sharedApplication openURL:[NSURL URLWithString:kDSOriginalAuthorURL] options:@{} completionHandler:nil];
}

// Dropping the flag file keeps every hook out of SpringBoard on the next boot,
// which is the only recovery path that does not need a computer.
- (void)toggleKillSwitch {
    NSFileManager *manager = [NSFileManager defaultManager];
    if ([self killSwitchPresent]) {
        for (NSString *path in @[ kDSKillSwitchPath, [@"/var/jb" stringByAppendingString:kDSKillSwitchPath] ]) {
            [manager removeItemAtPath:path error:nil];
        }
    } else {
        [@"" writeToFile:kDSKillSwitchPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }

    [self refreshKillSwitchRow];
    [self reloadSpecifiers];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Dynamic Stage"
                                                                  message:@"This takes effect after a respring.\nRespring now?"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Respring"
                                             style:UIAlertActionStyleDestructive
                                           handler:^(UIAlertAction *action) {
        [[DSPrefsStore sharedStore] respring];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
