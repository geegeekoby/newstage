#import "DSListController.h"
#import "DSPrefsStore.h"

@implementation DSListController

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    id value = [[DSPrefsStore sharedStore] objectForKey:key];
    return value ?: [specifier propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    [[DSPrefsStore sharedStore] setObject:value forKey:key];
}

@end
