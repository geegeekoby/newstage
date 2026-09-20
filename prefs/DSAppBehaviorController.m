#import "DSAppBehaviorController.h"
#import "DSPrefsAppList.h"
#import "DSPrefsStore.h"
#import "DSConstants.h"

@implementation DSAppBehaviorController {
    NSString *_bundleIdentifier;
}

- (NSString *)bundleIdentifier {
    if (_bundleIdentifier.length == 0) {
        _bundleIdentifier = [self.specifier propertyForKey:@"applicationIdentifier"]
                         ?: [self.specifier propertyForKey:@"id"];
    }
    return _bundleIdentifier;
}

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"AppBehavior" target:self];
        [self applyApplicationContext];
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    DSPrefsApp *application = [[DSPrefsAppList sharedList] applicationWithBundleIdentifier:[self bundleIdentifier]];
    self.title = application.displayName ?: [self bundleIdentifier];
}

// The iPad-only switches are pulled out of the list entirely while the app is in
// iPhone mode, because neither one can do anything in that state.
- (void)applyApplicationContext {
    DSPrefsApp *application = [[DSPrefsAppList sharedList] applicationWithBundleIdentifier:[self bundleIdentifier]];
    NSString *name = application.displayName ?: [self bundleIdentifier];

    PSSpecifier *appGroup = [self specifierForID:@"appLabel"];
    if (appGroup) {
        appGroup.name = name;
        [appGroup setProperty:[self bundleIdentifier] forKey:@"footerText"];
    }

    BOOL padMode = [self launchType] == DSLaunchTypePad;
    if (!padMode) {
        [self removeSpecifierID:@"ipadLabel"];
        [self removeSpecifierID:kDSAppPrefDisableLandscape];
        [self removeSpecifierID:@"backgroundLabel"];
        [self removeSpecifierID:kDSAppPrefBackgroundOnMinimize];
    }
}

- (DSLaunchType)launchType {
    NSDictionary *settings = [[DSPrefsStore sharedStore] settingsForApplication:[self bundleIdentifier]];
    NSNumber *type = settings[kDSAppPrefLaunchType];
    if (![type isKindOfClass:NSNumber.class]) return DSLaunchTypePhone;
    return type.integerValue == DSLaunchTypePad ? DSLaunchTypePad : DSLaunchTypePhone;
}

#pragma mark - Preferences

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    NSDictionary *settings = [[DSPrefsStore sharedStore] settingsForApplication:[self bundleIdentifier]];
    id value = settings[key];
    return value ?: [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    [[DSPrefsStore sharedStore] setSetting:value forKey:key application:[self bundleIdentifier]];

    if ([key isEqualToString:kDSAppPrefLaunchType]) {
        // Switching modes changes which rows are relevant.
        _specifiers = nil;
        [self reloadSpecifiers];
    }
}

@end
