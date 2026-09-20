#import <Foundation/Foundation.h>
#import "DSConstants.h"

// Single source of truth for settings, shared by SpringBoard, the per-app dylib
// and the preference bundle.
//
// Inside application processes the sandbox refuses cross domain CFPreferences
// lookups, so everything is read straight off disk and cached until a Darwin
// notification invalidates it.
@interface DSPreferences : NSObject

+ (instancetype)sharedPreferences;

- (void)reload;
- (void)startObserving;

// Global
@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly) BOOL showOpenAppIcon;
@property (nonatomic, readonly) BOOL disableOnHomeScreen;
@property (nonatomic, readonly) DSAppearance appearance;
@property (nonatomic, readonly) DSGestureMode gestureMode;
@property (nonatomic, readonly) NSArray<NSString *> *pinnedApplications;
@property (nonatomic, readonly) NSInteger pinnedRows;      // 2 or 3
@property (nonatomic, readonly) CGFloat scale;             // 0.8 ... 1.4
@property (nonatomic, readonly) DSAutoKill autoKill;
@property (nonatomic, readonly) BOOL introShown;

- (void)setIntroShown:(BOOL)shown;

// Per application
- (NSDictionary *)settingsForApplication:(NSString *)bundleIdentifier;
- (BOOL)isApplicationDisabled:(NSString *)bundleIdentifier;
- (DSLaunchType)launchTypeForApplication:(NSString *)bundleIdentifier;
- (BOOL)landscapeDisabledForApplication:(NSString *)bundleIdentifier;
- (BOOL)backgroundsOnMinimize:(NSString *)bundleIdentifier;

// Recently opened stage apps, most recent first. Persisted by SpringBoard.
@property (nonatomic, readonly) NSArray<NSString *> *recentApplications;
- (void)noteApplicationOpened:(NSString *)bundleIdentifier;

@end
