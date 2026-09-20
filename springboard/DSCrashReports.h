#import <Foundation/Foundation.h>

// Reading the Settings app's own crash reports.
//
// The tweak's settings page lives inside Settings, so when it fails it takes Settings
// with it - and the only account of why is a crash report that can only be reached
// with a file manager. SpringBoard runs as the same user those reports belong to, so
// it can read them, and the stage has somewhere to show one. Without this the page
// crashing is a dead end: the one place that could explain it is the page itself.
//
// Returns nil when there is no recent report, or when it cannot be made sense of.
NSString *DSLastSettingsCrashSummary(void);
