#import "DSMiscListController.h"
#import "DSAutoKillListController.h"
#import "DSScaleSliderCell.h"
#import "DSPrefsStore.h"
#import "DSConstants.h"
#import <notify.h>

@implementation DSMiscListController

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Misc" target:self]
                       ?: [NSMutableArray array];
        [self appendStageSpecifiers];
    }
    return _specifiers;
}

// The scale slider and the auto-kill picker are built in code: the slider needs
// a cell that renders its own percentage, and the picker's row has to show the
// current choice as its value.
- (void)appendStageSpecifiers {
    PSSpecifier *stageGroup = [PSSpecifier groupSpecifierWithName:@"Stage"];
    [stageGroup setProperty:@"Scales the app on the stage. Larger values fit more of the app's interface into the same space."
                     forKey:@"footerText"];

    PSSpecifier *scale = [PSSpecifier preferenceSpecifierNamed:@"Scale"
                                                       target:self
                                                          set:@selector(setPreferenceValue:specifier:)
                                                          get:@selector(readPreferenceValue:)
                                                       detail:Nil
                                                         cell:PSSliderCell
                                                         edit:Nil];
    [scale setProperty:kDSPrefScale forKey:@"key"];
    [scale setProperty:@(1.0) forKey:@"default"];
    [scale setProperty:@(0.8) forKey:@"min"];
    [scale setProperty:@(1.4) forKey:@"max"];
    [scale setProperty:DSScaleSliderCell.class forKey:@"cellClass"];
    [scale setProperty:@YES forKey:@"isContinuous"];

    PSSpecifier *autoKillGroup = [PSSpecifier groupSpecifierWithName:@"Auto Kill"];
    [autoKillGroup setProperty:@"How long an app stays alive after the stage closes. Killing on close frees memory immediately; keeping it alive makes reopening instant."
                        forKey:@"footerText"];

    PSSpecifier *autoKill = [PSSpecifier preferenceSpecifierNamed:@"Auto Kill"
                                                          target:self
                                                             set:NULL
                                                             get:NULL
                                                          detail:DSAutoKillListController.class
                                                            cell:PSLinkCell
                                                            edit:Nil];
    [autoKill setProperty:@"autoKill" forKey:@"id"];
    [autoKill setProperty:[DSAutoKillListController currentSelectionTitle] forKey:@"value"];

    [self addSpecifier:stageGroup];
    [self addSpecifier:scale];
    [self addSpecifier:autoKillGroup];
    [self addSpecifier:autoKill];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    // Coming back from the picker: refresh the row's value in place.
    PSSpecifier *autoKill = [self specifierForID:@"autoKill"];
    if (autoKill) {
        [autoKill setProperty:[DSAutoKillListController currentSelectionTitle] forKey:@"value"];
        [self reloadSpecifier:autoKill];
    }
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];

    NSString *key = [specifier propertyForKey:@"key"];
    if ([key isEqualToString:kDSPrefUseModernGesture]) {
        [self promptForRespringWithReason:@"Changing the gesture mode requires a respring."];
    }
}

- (void)promptForRespringWithReason:(NSString *)reason {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Dynamic Stage"
                                                                  message:[reason stringByAppendingString:@"\nRespring now?"]
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

// Opens the stage over Settings. Worth having on its own, and it answers the
// question the corner pull cannot: if the stage comes up from here, the stage
// works and it is the pull that is not being picked up.
- (void)openStage {
    notify_post(kDSOpenStageNotification);
}

// Bound to the confirmation on the "Show First Install Intro" button.
- (void)resetIntro {
    DSPrefsStore *store = [DSPrefsStore sharedStore];
    [store setObject:@NO forKey:kDSPrefIntroShown];
    notify_post(kDSResetIntroNotification);
    [store respring];
}

@end
