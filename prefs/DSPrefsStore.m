#import "DSPrefsStore.h"
#import "DSConstants.h"
#import <notify.h>
#import <spawn.h>

static NSString *const kDSPrefsPath = @"/var/mobile/Library/Preferences/" kDSPreferenceDomain @".plist";
static NSString *const kDSShippedDefaultsPath = @"/Library/Application Support/DynamicStage/defaults.plist";

@implementation DSPrefsStore {
    NSMutableDictionary *_settings;
    NSDictionary *_shippedDefaults;
}

+ (instancetype)sharedStore {
    static DSPrefsStore *shared;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        shared = [[DSPrefsStore alloc] init];
    });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        [self load];
    }
    return self;
}

// Shipped files live under the rootless prefix; preference plists never do.
- (NSString *)resolvedSupportPath:(NSString *)path {
    NSString *prefixed = [@"/var/jb" stringByAppendingString:path];
    if ([[NSFileManager defaultManager] fileExistsAtPath:prefixed]) return prefixed;
    return path;
}

- (void)load {
    _settings = [([NSDictionary dictionaryWithContentsOfFile:kDSPrefsPath] ?: @{}) mutableCopy];
    _shippedDefaults = [NSDictionary dictionaryWithContentsOfFile:[self resolvedSupportPath:kDSShippedDefaultsPath]] ?: @{};
}

- (void)flush {
    [_settings writeToFile:kDSPrefsPath atomically:YES];
}

#pragma mark - Global values

- (id)objectForKey:(NSString *)key {
    if (key.length == 0) return nil;
    return _settings[key];
}

- (void)setObject:(id)object forKey:(NSString *)key {
    if (key.length == 0) return;
    if (object) {
        _settings[key] = object;
    } else {
        [_settings removeObjectForKey:key];
    }
    [self flush];
    [self notifyChanged];
}

- (BOOL)boolForKey:(NSString *)key fallback:(BOOL)fallback {
    id value = [self objectForKey:key];
    return value ? [value boolValue] : fallback;
}

- (NSInteger)integerForKey:(NSString *)key fallback:(NSInteger)fallback {
    id value = [self objectForKey:key];
    return value ? [value integerValue] : fallback;
}

- (double)doubleForKey:(NSString *)key fallback:(double)fallback {
    id value = [self objectForKey:key];
    return value ? [value doubleValue] : fallback;
}

#pragma mark - Per application values

// The tweak ships a table of known-good launch modes for popular apps; the UI
// has to show those as the starting point or every app would read "iPhone".
- (NSDictionary *)settingsForApplication:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0) return @{};

    NSDictionary *shipped = _shippedDefaults[bundleIdentifier];
    NSDictionary *user = _settings[bundleIdentifier];
    if (![shipped isKindOfClass:NSDictionary.class]) shipped = nil;
    if (![user isKindOfClass:NSDictionary.class]) user = nil;

    if (!shipped) return user ?: @{};
    if (!user) return shipped;

    NSMutableDictionary *merged = [shipped mutableCopy];
    [merged addEntriesFromDictionary:user];
    return merged;
}

- (void)setSetting:(id)value forKey:(NSString *)key application:(NSString *)bundleIdentifier {
    if (key.length == 0 || bundleIdentifier.length == 0) return;

    NSDictionary *existing = _settings[bundleIdentifier];
    NSMutableDictionary *application = [existing isKindOfClass:NSDictionary.class] ? [existing mutableCopy] : [NSMutableDictionary dictionary];
    if (value) {
        application[key] = value;
    } else {
        [application removeObjectForKey:key];
    }

    if (application.count == 0) {
        [_settings removeObjectForKey:bundleIdentifier];
    } else {
        _settings[bundleIdentifier] = application;
    }
    [self flush];

    // SpringBoard caches per-app settings separately from the global ones.
    [self notifyChanged];
    [self notifyApplicationInfoChanged];
}

- (NSArray<NSString *> *)configuredApplications {
    NSMutableArray *identifiers = [NSMutableArray array];
    for (NSString *key in _settings) {
        if (![_settings[key] isKindOfClass:NSDictionary.class]) continue;
        [identifiers addObject:key];
    }
    [identifiers sortUsingSelector:@selector(localizedStandardCompare:)];
    return identifiers;
}

- (void)setConfiguredApplications:(NSArray<NSString *> *)configuredApplications {
    // Nothing to store: an app is "configured" exactly while it owns a dictionary.
}

- (NSArray<NSString *> *)pinnedApplications {
    id pinned = [self objectForKey:kDSPrefPinnedApplications];
    if ([pinned isKindOfClass:NSArray.class]) return pinned;
    return @[ @"com.apple.Music", @"com.apple.mobilesafari", @"com.apple.DocumentsApp", @"com.apple.mobilemail" ];
}

- (void)setPinnedApplications:(NSArray<NSString *> *)pinnedApplications {
    [self setObject:(pinnedApplications ?: @[]) forKey:kDSPrefPinnedApplications];
}

#pragma mark - Notifications

- (void)notifyChanged {
    notify_post(kDSPreferencesChangedNotification);
}

- (void)notifyApplicationInfoChanged {
    notify_post(kDSAppInfoChangedNotification);
}

- (void)respring {
    [self flush];
    NSArray *candidates = @[ @"/var/jb/usr/bin/sbreload", @"/usr/bin/sbreload", @"/var/jb/usr/bin/killall", @"/usr/bin/killall" ];
    for (NSString *path in candidates) {
        if (![[NSFileManager defaultManager] isExecutableFileAtPath:path]) continue;
        BOOL isKillall = [path hasSuffix:@"killall"];
        const char *arguments[] = {
            path.fileSystemRepresentation,
            isKillall ? "-9" : NULL,
            isKillall ? "SpringBoard" : NULL,
            NULL,
        };
        pid_t pid = 0;
        posix_spawn(&pid, path.fileSystemRepresentation, NULL, NULL, (char *const *)arguments, NULL);
        return;
    }
}

@end
