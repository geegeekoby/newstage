#import <UIKit/UIKit.h>

@interface DSPrefsApp : NSObject
@property (nonatomic, copy) NSString *bundleIdentifier;
@property (nonatomic, copy) NSString *displayName;
@end

// Installed applications for the two app pickers in Settings. AltList does this
// job in the stock build; rolling it locally keeps the package free of a
// dependency that has to be installed separately.
@interface DSPrefsAppList : NSObject

+ (instancetype)sharedList;

@property (nonatomic, readonly) NSArray<DSPrefsApp *> *applications;

- (void)reload;
- (DSPrefsApp *)applicationWithBundleIdentifier:(NSString *)bundleIdentifier;
- (NSArray<DSPrefsApp *> *)applicationsMatching:(NSString *)query;
- (UIImage *)iconForBundleIdentifier:(NSString *)bundleIdentifier;

@end
