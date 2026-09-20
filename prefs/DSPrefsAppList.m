#import "DSPrefsAppList.h"
#import "DSPrefsPrivate.h"
#import <objc/runtime.h>

@implementation DSPrefsApp
@end

// Service stubs and the tweak's own bundle have no business in either picker.
static NSSet *DSHiddenIdentifiers(void) {
    static NSSet *hidden;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        hidden = [NSSet setWithArray:@[
            @"com.apple.webapp",
            @"com.apple.Web",
            @"com.apple.springboard",
            @"com.apple.InCallService",
            @"com.apple.PassbookUIService",
            @"com.apple.SafariViewService",
            @"com.apple.SharedWebCredentialViewService",
        ]];
    });
    return hidden;
}

@implementation DSPrefsAppList {
    NSArray<DSPrefsApp *> *_applications;
    NSMutableDictionary<NSString *, DSPrefsApp *> *_byIdentifier;
    NSMutableDictionary<NSString *, UIImage *> *_icons;
}

+ (instancetype)sharedList {
    static DSPrefsAppList *shared;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        shared = [[DSPrefsAppList alloc] init];
    });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _byIdentifier = [NSMutableDictionary dictionary];
        _icons = [NSMutableDictionary dictionary];
        [self reload];
    }
    return self;
}

- (void)reload {
    Class workspaceClass = objc_getClass("LSApplicationWorkspace");
    NSArray *proxies = @[];
    if (workspaceClass) {
        LSApplicationWorkspace *workspace = [workspaceClass defaultWorkspace];
        if ([workspace respondsToSelector:@selector(allInstalledApplications)]) {
            proxies = [workspace allInstalledApplications] ?: @[];
        }
    }

    NSMutableArray<DSPrefsApp *> *applications = [NSMutableArray array];
    NSMutableDictionary *byIdentifier = [NSMutableDictionary dictionary];

    for (LSApplicationProxy *proxy in proxies) {
        NSString *identifier = proxy.applicationIdentifier;
        if (identifier.length == 0) continue;
        if ([DSHiddenIdentifiers() containsObject:identifier]) continue;
        if ([identifier hasPrefix:@"com.recreated.dynamicstage"]) continue;

        NSString *type = proxy.applicationType;
        if (type.length && !([type isEqualToString:@"User"] || [type isEqualToString:@"System"])) continue;

        BOOL tagged = NO;
        if ([proxy respondsToSelector:@selector(appTags)]) {
            for (NSString *tag in proxy.appTags) {
                if ([tag isEqualToString:@"hidden"] || [tag isEqualToString:@"SBAppTagHidden"]) tagged = YES;
            }
        }
        if (tagged) continue;

        DSPrefsApp *application = [[DSPrefsApp alloc] init];
        application.bundleIdentifier = identifier;
        application.displayName = proxy.localizedName ?: identifier;
        [applications addObject:application];
        byIdentifier[identifier] = application;
    }

    [applications sortUsingComparator:^NSComparisonResult(DSPrefsApp *a, DSPrefsApp *b) {
        return [a.displayName localizedStandardCompare:b.displayName];
    }];

    _applications = applications;
    _byIdentifier = byIdentifier;
}

- (DSPrefsApp *)applicationWithBundleIdentifier:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0) return nil;
    return _byIdentifier[bundleIdentifier];
}

- (NSArray<DSPrefsApp *> *)applicationsMatching:(NSString *)query {
    NSString *trimmed = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) return _applications;

    NSMutableArray *matches = [NSMutableArray array];
    for (DSPrefsApp *application in _applications) {
        NSRange range = [application.displayName rangeOfString:trimmed
                                                       options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch];
        if (range.location != NSNotFound) [matches addObject:application];
    }
    return matches;
}

- (UIImage *)iconForBundleIdentifier:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0) return nil;
    UIImage *cached = _icons[bundleIdentifier];
    if (cached) return cached;

    UIImage *icon = nil;
    if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
        icon = [UIImage _applicationIconImageForBundleIdentifier:bundleIdentifier format:0 scale:UIScreen.mainScreen.scale];
    }
    if (icon) _icons[bundleIdentifier] = icon;
    return icon;
}

@end
