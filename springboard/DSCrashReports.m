#import "DSCrashReports.h"
#import <UIKit/UIKit.h>

static NSString *const kDSCrashReportDirectory = @"/var/mobile/Library/Logs/CrashReporter";

// Reports older than this are about a build that has probably been replaced twice
// over, and showing one would send the reader after a fault that is already gone.
static const NSTimeInterval kDSCrashReportMaxAge = 2 * 24 * 60 * 60;

// How far down the crashing thread is worth reading. The fault is in the first few
// frames; past that it is the run loop, which is the same in every report.
static const NSUInteger kDSCrashReportFrameCount = 7;

static NSString *DSFirstMatch(NSString *text, NSString *pattern) {
    NSRegularExpression *expression =
        [NSRegularExpression regularExpressionWithPattern:pattern
                                                 options:NSRegularExpressionCaseInsensitive
                                                   error:NULL];
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

// An .ips report is a line of JSON naming the process, then the report itself as
// JSON. Everything worth having is in the second half.
static NSDictionary *DSReportPayload(NSString *text) {
    NSRange newline = [text rangeOfString:@"\n"];
    if (newline.location == NSNotFound) return nil;

    NSData *body = [[text substringFromIndex:NSMaxRange(newline)] dataUsingEncoding:NSUTF8StringEncoding];
    id payload = [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
    return [payload isKindOfClass:NSDictionary.class] ? payload : nil;
}

static NSDictionary *DSFaultingThread(NSDictionary *payload) {
    NSArray *threads = payload[@"threads"];
    if (![threads isKindOfClass:NSArray.class] || threads.count == 0) return nil;

    NSNumber *index = payload[@"faultingThread"];
    if ([index isKindOfClass:NSNumber.class] && index.unsignedIntegerValue < threads.count) {
        NSDictionary *thread = threads[index.unsignedIntegerValue];
        if ([thread isKindOfClass:NSDictionary.class]) return thread;
    }
    for (NSDictionary *thread in threads) {
        if ([thread isKindOfClass:NSDictionary.class] && [thread[@"triggered"] boolValue]) return thread;
    }
    return nil;
}

// "DynamicStagePrefs+0x3f1c", or the symbol where the report happens to carry one.
// The offset is enough: it can be turned back into a line of source against the
// build the report came from.
static NSString *DSFrameDescription(NSDictionary *frame, NSArray *images) {
    NSString *name = nil;
    NSNumber *imageIndex = frame[@"imageIndex"];
    if ([imageIndex isKindOfClass:NSNumber.class] && imageIndex.unsignedIntegerValue < images.count) {
        NSDictionary *image = images[imageIndex.unsignedIntegerValue];
        if ([image isKindOfClass:NSDictionary.class]) {
            name = image[@"name"];
            if (name.length == 0) name = [image[@"path"] lastPathComponent];
        }
    }
    if (name.length == 0) name = @"?";

    NSString *symbol = frame[@"symbol"];
    if ([symbol isKindOfClass:NSString.class] && symbol.length > 0) {
        return [NSString stringWithFormat:@"%@ %@", name, symbol];
    }

    NSNumber *offset = frame[@"imageOffset"];
    if ([offset isKindOfClass:NSNumber.class]) {
        return [NSString stringWithFormat:@"%@+0x%llx", name, offset.unsignedLongLongValue];
    }
    return name;
}

// Whether this tweak's code was loaded in the process that crashed. Since 1.5.0 the
// settings page is a plist and no code of the tweak's runs in Settings except the
// per-app dylib, so a Settings crash naming neither is somebody else's - and showing
// it would send the reader after a fault that is not here to be fixed.
static BOOL DSReportNamesTheTweak(NSDictionary *payload, NSString *text) {
    NSArray *images = payload[@"usedImages"];
    if ([images isKindOfClass:NSArray.class]) {
        for (NSDictionary *image in images) {
            if (![image isKindOfClass:NSDictionary.class]) continue;
            NSString *path = image[@"path"] ?: image[@"name"];
            if ([path isKindOfClass:NSString.class] &&
                [path rangeOfString:@"DynamicStage" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                return YES;
            }
        }
        return NO;
    }
    return [text rangeOfString:@"DynamicStage" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static NSString *DSSummaryFromPayload(NSDictionary *payload) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];

    NSDictionary *exception = payload[@"exception"];
    if ([exception isKindOfClass:NSDictionary.class]) {
        NSMutableArray<NSString *> *what = [NSMutableArray array];
        for (NSString *key in @[ @"type", @"signal", @"subtype" ]) {
            NSString *value = exception[key];
            if ([value isKindOfClass:NSString.class] && value.length > 0) [what addObject:value];
        }
        if (what.count > 0) [parts addObject:[what componentsJoinedByString:@" "]];
    }

    // An uncaught Objective-C exception says in words what went wrong, which is worth
    // more than any number of addresses.
    NSDictionary *information = payload[@"asi"];
    if ([information isKindOfClass:NSDictionary.class]) {
        for (NSArray *lines in information.allValues) {
            if (![lines isKindOfClass:NSArray.class]) continue;
            for (NSString *line in lines) {
                if (![line isKindOfClass:NSString.class]) continue;
                if ([line rangeOfString:@"exception"].location == NSNotFound) continue;
                [parts addObject:line.length > 200 ? [line substringToIndex:200] : line];
                break;
            }
        }
    }

    NSArray *images = [payload[@"usedImages"] isKindOfClass:NSArray.class] ? payload[@"usedImages"] : @[];
    NSArray *frames = DSFaultingThread(payload)[@"frames"];
    if ([frames isKindOfClass:NSArray.class]) {
        NSMutableArray<NSString *> *described = [NSMutableArray array];
        for (NSDictionary *frame in frames) {
            if (described.count >= kDSCrashReportFrameCount) break;
            if (![frame isKindOfClass:NSDictionary.class]) continue;
            [described addObject:DSFrameDescription(frame, images)];
        }
        if (described.count > 0) [parts addObject:[described componentsJoinedByString:@" < "]];
    }

    return parts.count > 0 ? [parts componentsJoinedByString:@" - "] : nil;
}

NSString *DSLastSettingsCrashSummary(void) {
    @try {
        NSDate *when = nil;
        NSString *path = DSNewestSettingsReportPath(&when);
        if (!path) return nil;

        NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
        if (data.length == 0) return nil;

        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (text.length == 0) return nil;

        NSDictionary *payload = DSReportPayload(text);
        if (!DSReportNamesTheTweak(payload, text)) return nil;

        NSString *what = DSSummaryFromPayload(payload);
        if (what.length == 0) {
            // An older, plain-text report.
            what = DSFirstMatch(text, @"Terminating app due to uncaught exception '([^']+)', reason: '([^']{0,160})'");
            if (!what) what = DSFirstMatch(text, @"Exception Type:\\s+(\\S+)");
        }
        if (what.length == 0) what = @"nothing in the report could be read";

        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"HH:mm";
        NSString *summary = [NSString stringWithFormat:@"Settings crashed at %@ - %@",
                                                      [formatter stringFromDate:when], what];
        if (summary.length > 700) summary = [[summary substringToIndex:697] stringByAppendingString:@"..."];
        return summary;
    } @catch (NSException *exception) {
        return nil;
    }
}
