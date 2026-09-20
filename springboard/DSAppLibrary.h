#import <UIKit/UIKit.h>

@interface DSAppEntry : NSObject
@property (nonatomic, copy) NSString *bundleIdentifier;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, strong) UIImage *icon;
@end

// Installed application list feeding the stage picker. Mirrors what the stock
// tweak shows: every visible, launchable app minus the ones excluded in
// settings, sorted the way the App Library sorts them.
@interface DSAppLibrary : NSObject

+ (instancetype)sharedLibrary;

@property (nonatomic, readonly) NSArray<DSAppEntry *> *applications;

- (void)reload;
- (DSAppEntry *)entryForBundleIdentifier:(NSString *)bundleIdentifier;
- (NSArray<DSAppEntry *> *)applicationsMatchingSearch:(NSString *)query;
- (NSArray<DSAppEntry *> *)recentApplicationsLimitedTo:(NSInteger)limit;
- (NSArray<DSAppEntry *> *)pinnedApplications;
- (UIImage *)iconForBundleIdentifier:(NSString *)bundleIdentifier;

// The stage shows a small waveform next to whichever app currently owns audio.
- (BOOL)isNowPlayingApplication:(NSString *)bundleIdentifier;

@end
