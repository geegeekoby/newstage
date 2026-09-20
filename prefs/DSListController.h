#import "DSPrefsPrivate.h"

// Every page in the bundle reads and writes through DSPrefsStore rather than
// PSSpecifier's own defaults plumbing, so the nested per-app dictionaries in the
// same plist can never be clobbered by a switch flipping somewhere else.
@interface DSListController : PSListController

- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;

@end
