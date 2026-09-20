#import "DSCrashReports.h"
#import <UIKit/UIKit.h>

static NSString *const kDSCrashReportDirectory = @"/var/mobile/Library/Logs/CrashReporter";

// Reports older than this are not worth showing: they are about a build that has
// probably been replaced twice over.
static const NSTimeInterval kDSCrashReportMaxAge = 2 * 24 * 60 * 60;

static NSString *DSFirstMatch(NSString *text, NSString *pattern) {
    NSError *error = nil;
    NSRegularExpression *expression =
        [NSRegularExpression regularExpressionWithPattern:pattern
                                                 options:NSRegularExpressionCaseInsensitive
                                                   error:&error];
    if (!expression) return nil;

    NSTextCheckingResult *match = [expression firstMatchInString:text
                                                        options:0
                                                          range:NSMakeRange(0, text.length)];
    if (!match) return nil;

    NSMutableArray<NSString *> *groups = [NSMutableArray array];
    for (NSUInteger index = 1; index < match.numberOfRanges; index++) {
        NSRange range = [match rangeAtIndex:index];
        if (range.location == NSNotFound) continue;
        NSString *group = [[text substringWithRange:range]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (group.length > 0) [groups addObject:group];
    }
    if (groups.count == 0) return nil;
    return [groups componentsJoinedByString:@": "];
}

// The newest report belonging to the Settings app, whatever this iOS version calls
// the file.
static NSString *DSNewestSettingsReportPath(NSDate **when) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSArray<NSString *> *names = [manager contentsOfDirectoryAtPath:kDSCrashReportDirectory error:NULL];
    if (names.count == 0) return nil;

    NSString *newest = nil;
    NSDate *newestDate = nil;

    for (NSString *name in names) {
        NSString *extension = name.pathExtension.lowercaseString;
        if (![extension isEqualToString:@"ips"] && ![extension isEqualToString:@"crash"]) continue;
        if (![name hasPrefix:@"Preferences-"] && ![name hasPrefix:@"Settings-"]) continue;

        NSString *path = [kDSCrashReportDirectory stringByAppendingPathComponent:name];
        NSDate *date = [manager attributesOfItemAtPath:path error:NULL].fileModificationDate;
        if (!date) continue;
        if (newestDate && [date compare:newestDate] != NSOrderedDescending) continue;
        newest = path;
        newestDate = date;
    }

    if (!newest) return nil;
    if (-newestDate.timeIntervalSinceNow > kDSCrashReportMaxAge) return nil;
    if (when) *when = newestDate;
    return newest;
}

NSString *DSLastSettingsCrashSummary(void) {
    @try {
        NSDate *when = nil;
        NSString *path = DSNewestSettingsReportPath(&when);
        if (!path) return nil;

        NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
        if (data.length == 0) return nil;
        if (data.length > 512 * 1024) data = [data subdataWithRange:NSMakeRange(0, 512 * 1024)];

        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (text.length == 0) return nil;

        // An uncaught Objective-C exception says exactly what went wrong, so it is
        // worth more than anything else in the file. Failing that, what killed the
        // process is at least the difference between a bad pointer and an assertion.
        NSString *what = DSFirstMatch(text, @"uncaught exception of type ([A-Za-z]+)[^']*'([^']{0,180})'");
        if (!what) what = DSFirstMatch(text, @"Terminating app due to uncaught exception '([^']+)', reason: '([^']{0,180})'");
        if (!what) what = DSFirstMatch(text, @"\"(EXC_[A-Z_]+)\"");
        if (!what) what = DSFirstMatch(text, @"Exception Type:\\s+(\\S+)");
        if (!what) what = @"no reason recorded";

        // Whether the tweak's own code is in the report at all. A crash that never
        // touches it is somebody else's, and saying so is as useful as the reason.
        NSString *ours = [text rangeOfString:@"DynamicStage"].location != NSNotFound
            ? @"the tweak's bundle is in it"
            : @"the tweak's bundle is not in it";

        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"HH:mm";
        NSString *summary = [NSString stringWithFormat:@"Settings crashed at %@ - %@ (%@)",
                                                       [formatter stringFromDate:when], what, ours];
        if (summary.length > 240) summary = [[summary substringToIndex:237] stringByAppendingString:@"..."];
        return summary;
    } @catch (NSException *exception) {
        return nil;
    }
}
