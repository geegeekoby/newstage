#import <Foundation/Foundation.h>

// Reads and writes the tweak's preference plist directly and posts the Darwin
// notification SpringBoard and the app-side dylib listen for.
//
// PSSpecifier's own getter/setter pair is not used for the global switches
// because the per-app settings are nested dictionaries in the same file, and
// keeping one writer avoids the two clobbering each other.
@interface DSPrefsStore : NSObject

+ (instancetype)sharedStore;

- (id)objectForKey:(NSString *)key;
- (void)setObject:(id)object forKey:(NSString *)key;

- (BOOL)boolForKey:(NSString *)key fallback:(BOOL)fallback;
- (NSInteger)integerForKey:(NSString *)key fallback:(NSInteger)fallback;
- (double)doubleForKey:(NSString *)key fallback:(double)fallback;

// Per-application settings, stored under the bundle identifier.
- (NSDictionary *)settingsForApplication:(NSString *)bundleIdentifier;
- (void)setSetting:(id)value forKey:(NSString *)key application:(NSString *)bundleIdentifier;

// Applications the user has given a per-app override, in the order shown.
@property (nonatomic, copy) NSArray<NSString *> *configuredApplications;
@property (nonatomic, copy) NSArray<NSString *> *pinnedApplications;

- (void)notifyChanged;
- (void)notifyApplicationInfoChanged;
- (void)respring;

@end
