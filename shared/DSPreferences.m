#import "DSPreferences.h"
#import <notify.h>

static NSString *const kDSPreferencePath = @"/var/mobile/Library/Preferences/" kDSPreferenceDomain @".plist";
static NSString *const kDSAppDefaultsPath = @"/Library/Application Support/DynamicStage/defaults.plist";
static const NSInteger kDSMaxRecents = 12;

@implementation DSPreferences {
    NSDictionary *_settings;
    NSDictionary *_appDefaults;
    NSDictionary *_state;
    dispatch_queue_t _queue;
    BOOL _observing;
}

+ (instancetype)sharedPreferences {
    static DSPreferences *shared;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        shared = [[DSPreferences alloc] init];
    });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.recreated.dynamicstage.prefs", DISPATCH_QUEUE_SERIAL);
        [self reload];
    }
    return self;
}

#pragma mark - Loading

// The rootless prefix only matters for files we ship; preference plists always
// live in the real /var/mobile.
- (NSString *)resolvedPath:(NSString *)path {
    if ([path hasPrefix:@"/var/mobile"]) return path;
    NSString *prefixed = [@"/var/jb" stringByAppendingString:path];
    if ([[NSFileManager defaultManager] fileExistsAtPath:prefixed]) return prefixed;
    return path;
}

- (void)reload {
    NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:kDSPreferencePath] ?: @{};
    NSDictionary *defaults = [NSDictionary dictionaryWithContentsOfFile:[self resolvedPath:kDSAppDefaultsPath]] ?: @{};
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:kDSSharedStatePath] ?: @{};
    dispatch_sync(_queue, ^{
        _settings = settings;
        _appDefaults = defaults;
        _state = state;
    });
}

- (void)startObserving {
    if (_observing) return;
    _observing = YES;
    int token = 0;
    notify_register_dispatch(kDSPreferencesChangedNotification, &token, dispatch_get_main_queue(), ^(int t) {
        [self reload];
    });
    int appToken = 0;
    notify_register_dispatch(kDSAppInfoChangedNotification, &appToken, dispatch_get_main_queue(), ^(int t) {
        [self reload];
    });
}

- (id)valueForKey:(NSString *)key fallback:(id)fallback {
    __block id value = nil;
    dispatch_sync(_queue, ^{
        value = _settings[key];
    });
    return value ?: fallback;
}

#pragma mark - Global settings

- (BOOL)enabled {
    return [[self valueForKey:kDSPrefEnabled fallback:@YES] boolValue];
}

- (BOOL)showOpenAppIcon {
    return [[self valueForKey:kDSPrefShowOpenAppIcon fallback:@YES] boolValue];
}

- (BOOL)disableOnHomeScreen {
    return [[self valueForKey:kDSPrefDisableOnHomeScreen fallback:@YES] boolValue];
}

- (DSAppearance)appearance {
    return (DSAppearance)[[self valueForKey:kDSPrefAppearance fallback:@(DSAppearanceAuto)] integerValue];
}

- (DSGestureMode)gestureMode {
    return (DSGestureMode)[[self valueForKey:kDSPrefUseModernGesture fallback:@(DSGestureModeSystem)] integerValue];
}

- (NSArray<NSString *> *)pinnedApplications {
    NSArray *pinned = [self valueForKey:kDSPrefPinnedApplications fallback:nil];
    if (![pinned isKindOfClass:NSArray.class]) {
        pinned = @[ @"com.apple.Music", @"com.apple.mobilesafari", @"com.apple.DocumentsApp", @"com.apple.mobilemail" ];
    }
    return pinned;
}

- (NSInteger)pinnedRows {
    NSInteger rows = [[self valueForKey:kDSPrefPinnedRows fallback:@2] integerValue];
    return rows == 3 ? 3 : 2;
}

- (CGFloat)scale {
    CGFloat scale = [[self valueForKey:kDSPrefScale fallback:@1.0] doubleValue];
    return MIN(MAX(scale, 0.8), 1.4);
}

- (DSAutoKill)autoKill {
    return (DSAutoKill)[[self valueForKey:kDSPrefAutoKill fallback:@(DSAutoKillNever)] integerValue];
}

- (BOOL)introShown {
    return [[self valueForKey:kDSPrefIntroShown fallback:@NO] boolValue];
}

- (void)setIntroShown:(BOOL)shown {
    NSMutableDictionary *settings = [([NSDictionary dictionaryWithContentsOfFile:kDSPreferencePath] ?: @{}) mutableCopy];
    settings[kDSPrefIntroShown] = @(shown);
    [settings writeToFile:kDSPreferencePath atomically:YES];
    [self reload];
}

#pragma mark - Per application settings

- (NSDictionary *)settingsForApplication:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0) return @{};
    __block NSDictionary *fromDefaults = nil;
    __block NSDictionary *fromUser = nil;
    dispatch_sync(_queue, ^{
        fromDefaults = _appDefaults[bundleIdentifier];
        fromUser = _settings[bundleIdentifier];
    });
    if (![fromDefaults isKindOfClass:NSDictionary.class]) fromDefaults = nil;
    if (![fromUser isKindOfClass:NSDictionary.class]) fromUser = nil;
    if (!fromDefaults) return fromUser ?: @{};
    if (!fromUser) return fromDefaults;

    NSMutableDictionary *merged = [fromDefaults mutableCopy];
    [merged addEntriesFromDictionary:fromUser];
    return merged;
}

- (BOOL)isApplicationDisabled:(NSString *)bundleIdentifier {
    return [[self settingsForApplication:bundleIdentifier][kDSAppPrefDisabled] boolValue];
}

- (DSLaunchType)launchTypeForApplication:(NSString *)bundleIdentifier {
    NSNumber *type = [self settingsForApplication:bundleIdentifier][kDSAppPrefLaunchType];
    if (![type isKindOfClass:NSNumber.class]) return DSLaunchTypePhone;
    return type.integerValue == DSLaunchTypePad ? DSLaunchTypePad : DSLaunchTypePhone;
}

- (BOOL)landscapeDisabledForApplication:(NSString *)bundleIdentifier {
    return [[self settingsForApplication:bundleIdentifier][kDSAppPrefDisableLandscape] boolValue];
}

- (BOOL)backgroundsOnMinimize:(NSString *)bundleIdentifier {
    return [[self settingsForApplication:bundleIdentifier][kDSAppPrefBackgroundOnMinimize] boolValue];
}

#pragma mark - Recents

- (NSArray<NSString *> *)recentApplications {
    __block NSArray *recents = nil;
    dispatch_sync(_queue, ^{
        recents = _state[@"recents"];
    });
    return [recents isKindOfClass:NSArray.class] ? recents : @[];
}

- (void)noteApplicationOpened:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0) return;
    NSMutableArray *recents = [[self recentApplications] mutableCopy];
    [recents removeObject:bundleIdentifier];
    [recents insertObject:bundleIdentifier atIndex:0];
    while (recents.count > kDSMaxRecents) [recents removeLastObject];

    NSMutableDictionary *state = [([NSDictionary dictionaryWithContentsOfFile:kDSSharedStatePath] ?: @{}) mutableCopy];
    state[@"recents"] = recents;
    [state writeToFile:kDSSharedStatePath atomically:YES];
    dispatch_sync(_queue, ^{
        _state = state;
    });
}

@end
