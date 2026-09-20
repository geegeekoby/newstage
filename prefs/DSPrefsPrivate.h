// Private interfaces the preference bundle needs. Preferences.framework itself
// comes from Theos' vendor headers; everything here is hand declared so the
// bundle keeps building against an SDK that has no header for it.

#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <Preferences/PSControlTableCell.h>
#import <Preferences/PSSliderTableCell.h>
#import <Preferences/PSSwitchTableCell.h>

@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *applicationIdentifier;
@property (nonatomic, readonly) NSString *localizedName;
@property (nonatomic, readonly) NSString *applicationType;
@property (nonatomic, readonly) NSArray *appTags;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray<LSApplicationProxy *> *)allInstalledApplications;
@end

@interface UIImage (DSPrefsPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier
                                               format:(NSInteger)format
                                                scale:(CGFloat)scale;
@end

// The blur behind the banner is tuned rather than taken as-is: the stock effect
// is far too milky over a wallpaper crop this small.
@interface UIBlurEffect (DSPrefsPrivate)
+ (instancetype)effectWithBlurRadius:(CGFloat)radius;
- (id)effectSettings;
@end

@interface PSListController (DSPrefsPrivate)
- (UITableView *)table;
@end
