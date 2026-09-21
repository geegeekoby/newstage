#import "DSAppLibrary.h"
#import "DSPrivate.h"
#import "DSPreferences.h"
#import "DSExclusions.h"
#import <objc/runtime.h>

@implementation DSAppEntry
@end

@implementation DSAppLibrary {
    NSArray<DSAppEntry *> *_applications;
    NSMutableDictionary<NSString *, DSAppEntry *> *_entriesByIdentifier;
    NSMutableDictionary<NSString *, UIImage *> *_iconCache;
}

+ (instancetype)sharedLibrary {
    static DSAppLibrary *shared;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        shared = [[DSAppLibrary alloc] init];
    });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _entriesByIdentifier = [NSMutableDictionary dictionary];
        _iconCache = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSArray<DSAppEntry *> *)applications {
    if (_applications.count == 0) [self reload];
    return _applications ?: @[];
}

#pragma mark - Loading

- (void)reload {
    NSMutableArray<DSAppEntry *> *entries = [NSMutableArray array];
    NSMutableDictionary *byIdentifier = [NSMutableDictionary dictionary];

    for (LSApplicationProxy *proxy in [self installedProxies]) {
        NSString *identifier = proxy.applicationIdentifier;
        if (identifier.length == 0) continue;
        if (DSIdentifierIsExcludedFromStage(identifier)) continue;
        if ([self isProxyHidden:proxy]) continue;

        DSAppEntry *entry = [[DSAppEntry alloc] init];
        entry.bundleIdentifier = identifier;
        entry.displayName = proxy.localizedName ?: identifier;
        [entries addObject:entry];
        byIdentifier[identifier] = entry;
    }

    [entries sortUsingComparator:^NSComparisonResult(DSAppEntry *a, DSAppEntry *b) {
        return [a.displayName localizedStandardCompare:b.displayName];
    }];

    _applications = entries;
    _entriesByIdentifier = byIdentifier;
}

- (NSArray *)installedProxies {
    Class workspaceClass = objc_getClass("LSApplicationWorkspace");
    if (!workspaceClass) return @[];
    LSApplicationWorkspace *workspace = [workspaceClass defaultWorkspace];
    if (![workspace respondsToSelector:@selector(allInstalledApplications)]) return @[];
    return [workspace allInstalledApplications] ?: @[];
}

- (BOOL)isProxyHidden:(LSApplicationProxy *)proxy {
    NSString *type = proxy.applicationType;
    if (type.length && !([type isEqualToString:@"User"] || [type isEqualToString:@"System"])) return YES;

    NSArray *tags = nil;
    if ([proxy respondsToSelector:@selector(appTags)]) tags = proxy.appTags;
    for (NSString *tag in tags) {
        if ([tag isEqualToString:@"hidden"] || [tag isEqualToString:@"SBAppTagHidden"]) return YES;
    }

    // Anything SpringBoard refuses to launch has no business in the picker.
    SBApplication *application = [[objc_getClass("SBApplicationController") sharedInstance] applicationWithBundleIdentifier:proxy.applicationIdentifier];
    SBApplicationInfo *info = [application respondsToSelector:@selector(info)] ? application.info : nil;
    if ([info respondsToSelector:@selector(isLaunchProhibited)] && [info isLaunchProhibited]) return YES;

    return NO;
}

#pragma mark - Lookup

- (DSAppEntry *)entryForBundleIdentifier:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0) return nil;
    DSAppEntry *entry = _entriesByIdentifier[bundleIdentifier];
    if (entry) return entry;

    // Apps installed after the last reload still need to resolve.
    [self reload];
    return _entriesByIdentifier[bundleIdentifier];
}

- (NSArray<DSAppEntry *> *)visibleApplications {
    DSPreferences *preferences = [DSPreferences sharedPreferences];
    NSMutableArray *visible = [NSMutableArray array];
    for (DSAppEntry *entry in self.applications) {
        if ([preferences isApplicationDisabled:entry.bundleIdentifier]) continue;
        [visible addObject:entry];
    }
    return visible;
}

- (NSArray<DSAppEntry *> *)applicationsMatchingSearch:(NSString *)query {
    NSArray<DSAppEntry *> *visible = [self visibleApplications];
    NSString *trimmed = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) return visible;

    NSMutableArray *matches = [NSMutableArray array];
    for (DSAppEntry *entry in visible) {
        if ([entry.displayName rangeOfString:trimmed options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound) {
            [matches addObject:entry];
        }
    }
    return matches;
}

- (NSArray<DSAppEntry *> *)recentApplicationsLimitedTo:(NSInteger)limit {
    DSPreferences *preferences = [DSPreferences sharedPreferences];
    NSMutableArray *recents = [NSMutableArray array];
    for (NSString *identifier in preferences.recentApplications) {
        if ([preferences isApplicationDisabled:identifier]) continue;
        DSAppEntry *entry = [self entryForBundleIdentifier:identifier];
        if (!entry) continue;
        [recents addObject:entry];
        if ((NSInteger)recents.count >= limit) break;
    }
    return recents;
}

- (NSArray<DSAppEntry *> *)pinnedApplications {
    DSPreferences *preferences = [DSPreferences sharedPreferences];
    NSMutableArray *pinned = [NSMutableArray array];
    for (NSString *identifier in preferences.pinnedApplications) {
        if ([preferences isApplicationDisabled:identifier]) continue;
        DSAppEntry *entry = [self entryForBundleIdentifier:identifier];
        if (entry) [pinned addObject:entry];
    }
    return pinned;
}

#pragma mark - Icons

- (UIImage *)iconForBundleIdentifier:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0) return nil;
    UIImage *cached = _iconCache[bundleIdentifier];
    if (cached) return cached;

    UIImage *icon = nil;
    if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
        // Format 2 is the 60pt home screen icon.
        icon = [UIImage _applicationIconImageForBundleIdentifier:bundleIdentifier format:2 scale:UIScreen.mainScreen.scale];
    }
    if (icon) _iconCache[bundleIdentifier] = icon;
    return icon;
}

#pragma mark - Now playing

- (BOOL)isNowPlayingApplication:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0) return NO;
    Class mediaControllerClass = objc_getClass("SBMediaController");
    if (!mediaControllerClass) return NO;
    SBMediaController *controller = [mediaControllerClass sharedInstance];
    if (![controller respondsToSelector:@selector(isPlaying)] || !controller.isPlaying) return NO;

    if ([controller respondsToSelector:@selector(nowPlayingApplicationDisplayID)]) {
        NSString *identifier = [controller nowPlayingApplicationDisplayID];
        if (identifier.length) return [identifier isEqualToString:bundleIdentifier];
    }
    if ([controller respondsToSelector:@selector(nowPlayingProcessPID)]) {
        SBApplication *application = [[objc_getClass("SBApplicationController") sharedInstance] applicationWithBundleIdentifier:bundleIdentifier];
        if ([application respondsToSelector:@selector(pid)]) {
            return application.pid > 0 && application.pid == (pid_t)[controller nowPlayingProcessPID];
        }
    }
    return NO;
}

@end
