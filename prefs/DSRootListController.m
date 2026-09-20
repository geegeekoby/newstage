#import "DSRootListController.h"
#import "DSPrefsStore.h"
#import "DSConstants.h"
#import "DSSafety.h"

// Nothing on this page is drawn by this tweak.
//
// It used to open with a banner of its own above the list, a logo in place of the
// title, a transparent navigation bar and a scroll handler to move the banner with
// the list. All of it ran inside Settings, on the way to the first screen the tweak
// has, and a fault in any of it takes Settings down before the page appears - which
// is the one failure that leaves every setting unreachable and looks, from the
// outside, like the tweak having no settings at all. Exceptions could be contained;
// a crash inside a layout pass that happens after the call that caused it cannot be.
//
// So the page is stock cells from a plist and nothing else. Its own decoration was
// worth less than being able to open it.
@implementation DSRootListController

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        DSPrefsNotePageOpening();
        DSPrefsRun(@"loading the settings list", ^{
            _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        });
        if (!_specifiers) _specifiers = [NSMutableArray array];
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Dynamic Stage";
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    DSPrefsNotePageShown();
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

@end
