#import "DSCrashReports.h"
#import <UIKit/UIKit.h>

static NSString *const kDSCrashReportDirectory = @"/var/mobile/Library/Logs/CrashReporter";

// Reports older than this are about a build that has probably been replaced twice
// over, and showing one would send the reader after a fault that is already gone.
static const NSTimeInterval kDSCrashReportMaxAge = 2 * 24 * 60 * 60;

// How far down the crashing thread is worth reading. The fault is in the first few
// frames; past that it is the run loop, which is the same in every report.
static const NSUInteger kDSCrashReportFrameCount = 7;

// Enough of a summary to be pasted and acted on, and not so much that the card turns
// into a wall of text. An uncaught exception's reason is the part worth the room: it
// says in words what went wrong.
static const NSUInteger kDSCrashReasonLimit = 400;
static const NSUInteger kDSCrashSummaryLimit = 900;

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

static NSString *DSClipped(NSString *text, NSUInteger limit) {
    if (text.length <= limit) return text;
    return [[text substringToIndex:limit - 3] stringByAppendingString:@"..."];
}

#pragma mark - What this build is, and where it lives

// The install script touches this, so its date is the moment the installed build
// arrived. Anything that crashed before then crashed in code that is no longer on the
// phone.
static NSDate *DSBuildInstalledAt(void) {
    NSFileManager *manager = NSFileManager.defaultManager;
    for (NSString *path in @[ @"/var/mobile/Library/Preferences/com.recreated.dynamicstage.installed",
                              @"/var/jb/var/mobile/Library/Preferences/com.recreated.dynamicstage.installed" ]) {
        NSDate *date = [manager attributesOfItemAtPath:path error:NULL].fileModificationDate;
        if (date) return date;
    }
    return nil;
}

static BOOL DSPathIsThisTweak(NSString *path) {
    return path.length > 0 &&
           [path rangeOfString:@"DynamicStage" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

// iOS is in /usr/lib, /System and the app bundle; everything a jailbreak adds is
// somewhere else. Naming the image a fault happened in is only useful if the machinery
// every crash passes through is excluded first.
static BOOL DSPathIsThirdParty(NSString *path) {
    if (path.length == 0) return NO;
    for (NSString *marker in @[ @"/var/jb/", @"/MobileSubstrate/", @"/TweakInject/", @"/ellekit" ]) {
        if ([path rangeOfString:marker options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

// A copy of the settings page as it was up to 1.4.8: a binary bundle, which Settings
// loads by opening it, and which the objc runtime cannot read on this device. The
// install script removes it by name, so one still being here means an upgrade has not
// run - and it is the only preference bundle on the phone this tweak can be blamed for.
static NSString *DSStaleSettingsBundlePath(void) {
    for (NSString *path in @[ @"/var/jb/Library/PreferenceBundles/DynamicStagePrefs.bundle",
                              @"/Library/PreferenceBundles/DynamicStagePrefs.bundle" ]) {
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) return path;
    }
    return nil;
}

#pragma mark - Finding a report

// The newest report belonging to one of these processes, whatever this iOS version
// calls the file, and only if it is about the build that is installed now.
static NSString *DSNewestReportPath(NSArray<NSString *> *prefixes, NSDate **when) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSArray<NSString *> *names = [manager contentsOfDirectoryAtPath:kDSCrashReportDirectory error:NULL];
    if (names.count == 0) return nil;

    NSString *newest = nil;
    NSDate *newestDate = nil;

    for (NSString *name in names) {
        NSString *extension = name.pathExtension.lowercaseString;
        if (![extension isEqualToString:@"ips"] && ![extension isEqualToString:@"crash"]) continue;

        BOOL wanted = NO;
        for (NSString *prefix in prefixes) {
            if ([name hasPrefix:prefix]) { wanted = YES; break; }
        }
        if (!wanted) continue;

        NSString *path = [kDSCrashReportDirectory stringByAppendingPathComponent:name];
        NSDate *date = [manager attributesOfItemAtPath:path error:NULL].fileModificationDate;
        if (!date) continue;
        if (newestDate && [date compare:newestDate] != NSOrderedDescending) continue;
        newest = path;
        newestDate = date;
    }

    if (!newest) return nil;
    if (-newestDate.timeIntervalSinceNow > kDSCrashReportMaxAge) return nil;

    NSDate *installed = DSBuildInstalledAt();
    if (installed && [newestDate compare:installed] == NSOrderedAscending) return nil;

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

#pragma mark - Reading the frames

static NSArray *DSUsedImages(NSDictionary *payload) {
    NSArray *images = payload[@"usedImages"];
    return [images isKindOfClass:NSArray.class] ? images : @[];
}

static NSDictionary *DSImageForFrame(NSDictionary *frame, NSArray *images) {
    NSNumber *index = frame[@"imageIndex"];
    if (![index isKindOfClass:NSNumber.class]) return nil;
    if (index.unsignedIntegerValue >= images.count) return nil;
    NSDictionary *image = images[index.unsignedIntegerValue];
    return [image isKindOfClass:NSDictionary.class] ? image : nil;
}

static NSString *DSImagePath(NSDictionary *image) {
    for (NSString *key in @[ @"path", @"name" ]) {
        NSString *value = image[key];
        if ([value isKindOfClass:NSString.class] && value.length > 0) return value;
    }
    return nil;
}

static NSString *DSImageName(NSDictionary *image) {
    NSString *name = image[@"name"];
    if ([name isKindOfClass:NSString.class] && name.length > 0) return name;
    return DSImagePath(image).lastPathComponent;
}

// "DynamicStage+0x3f1c", or the symbol where the report happens to carry one. The
// offset is enough: it can be turned back into a line of source against the build the
// report came from.
static NSString *DSFrameDescription(NSDictionary *frame, NSArray *images) {
    NSString *name = DSImageName(DSImageForFrame(frame, images)) ?: @"?";

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

static NSArray<NSDictionary *> *DSFaultingFrames(NSDictionary *payload) {
    NSArray *frames = DSFaultingThread(payload)[@"frames"];
    return [frames isKindOfClass:NSArray.class] ? frames : @[];
}

// A crash inside the dynamic linker or the objc runtime's image loading is not a fault
// in any of the code on the stack. It is a fault in the file being opened: the loader
// is partway through reading it and what it read does not make sense. The tweak whose
// hook happens to be in the middle of the load - every phone with tweaks on it has
// one hooking dlopen - is a bystander, and blaming it is how a reader ends up removing
// the wrong thing.
static BOOL DSFaultIsImageLoading(NSString *frames) {
    for (NSString *marker in @[ @"map_images", @"readClass", @"load_images", @"dlopen",
                                @"CFBundleDlfcn", @"notifyLoad" ]) {
        if ([frames rangeOfString:marker options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

// The bundles a load-time crash could have been reading, which the report lists even
// when the load never finished. Apple's own are left out: the point is to name the
// ones that arrived with a tweak.
static NSArray<NSString *> *DSThirdPartyBundlesLoaded(NSDictionary *payload) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSDictionary *image in DSUsedImages(payload)) {
        if (![image isKindOfClass:NSDictionary.class]) continue;
        NSString *path = DSImagePath(image);
        if (!DSPathIsThirdParty(path)) continue;
        if ([path rangeOfString:@".bundle"].location == NSNotFound) continue;
        NSString *name = DSImageName(image);
        if (name.length > 0 && ![names containsObject:name]) [names addObject:name];
    }
    return names;
}

#pragma mark - Summarising

static NSString *DSExceptionDescription(NSDictionary *payload) {
    NSDictionary *exception = payload[@"exception"];
    if (![exception isKindOfClass:NSDictionary.class]) return nil;

    NSMutableArray<NSString *> *what = [NSMutableArray array];
    for (NSString *key in @[ @"type", @"signal", @"subtype" ]) {
        NSString *value = exception[key];
        if ([value isKindOfClass:NSString.class] && value.length > 0) [what addObject:value];
    }
    return what.count > 0 ? [what componentsJoinedByString:@" "] : nil;
}

// An uncaught Objective-C exception says in words what went wrong, which is worth more
// than any number of addresses.
static NSString *DSExceptionReason(NSDictionary *payload) {
    NSDictionary *information = payload[@"asi"];
    if (![information isKindOfClass:NSDictionary.class]) return nil;

    for (NSArray *lines in information.allValues) {
        if (![lines isKindOfClass:NSArray.class]) continue;
        for (NSString *line in lines) {
            if (![line isKindOfClass:NSString.class]) continue;
            if ([line rangeOfString:@"exception"].location == NSNotFound) continue;
            return DSClipped(line, kDSCrashReasonLimit);
        }
    }
    return nil;
}

// The name of the image the fault is in, reading the crashing thread from the inside
// out. `ours` is answered from the whole thread rather than the innermost frame,
// because this tweak's code calling into UIKit and crashing there is still this
// tweak's crash.
static NSString *DSCulpritImageName(NSDictionary *payload, BOOL *ours) {
    NSArray *images = DSUsedImages(payload);
    NSString *culprit = nil;

    for (NSDictionary *frame in DSFaultingFrames(payload)) {
        if (![frame isKindOfClass:NSDictionary.class]) continue;
        NSString *path = DSImagePath(DSImageForFrame(frame, images));
        if (!DSPathIsThirdParty(path)) continue;
        if (DSPathIsThisTweak(path)) {
            if (ours) *ours = YES;
            return path.lastPathComponent;
        }
        if (!culprit) culprit = path.lastPathComponent;
    }
    return culprit;
}

static NSString *DSSummaryOfReportAtPath(NSString *path, NSDate *when, BOOL springBoard, BOOL *ours) {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
    if (data.length == 0) return nil;

    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text.length == 0) return nil;

    NSDictionary *payload = DSReportPayload(text);
    NSString *host = springBoard ? @"SpringBoard" : @"Settings";

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"HH:mm";
    NSString *time = [formatter stringFromDate:when];

    if (!payload) {
        // An older, plain-text report. There is no telling from one of these whose code
        // was running, so it is shown as nobody's.
        NSString *what = DSFirstMatch(text, @"Terminating app due to uncaught exception '([^']+)', reason: '([^']{0,160})'");
        if (!what) what = DSFirstMatch(text, @"Exception Type:\\s+(\\S+)");
        if (!what) return nil;
        return DSClipped([NSString stringWithFormat:@"%@ crashed at %@ - %@", host, time, what],
                         kDSCrashSummaryLimit);
    }

    NSMutableArray<NSString *> *described = [NSMutableArray array];
    NSArray *images = DSUsedImages(payload);
    for (NSDictionary *frame in DSFaultingFrames(payload)) {
        if (described.count >= kDSCrashReportFrameCount) break;
        if (![frame isKindOfClass:NSDictionary.class]) continue;
        [described addObject:DSFrameDescription(frame, images)];
    }
    NSString *frames = [described componentsJoinedByString:@" < "];

    NSMutableArray<NSString *> *parts = [NSMutableArray array];

    if (DSFaultIsImageLoading(frames)) {
        NSArray<NSString *> *bundles = DSThirdPartyBundlesLoaded(payload);
        NSString *stale = DSStaleSettingsBundlePath();
        BOOL named = stale != nil;
        for (NSString *bundle in bundles) named = named || DSPathIsThisTweak(bundle);
        if (ours) *ours = named;

        [parts addObject:[NSString stringWithFormat:
            @"%@ crashed at %@ opening a bundle - the objc runtime could not read the classes out of it",
            host, time]];
        if (stale) {
            [parts addObject:[NSString stringWithFormat:
                @"a copy of Dynamic Stage's old settings bundle is still at %@, so delete it and respring", stale]];
        } else {
            [parts addObject:@"Dynamic Stage's page is a plist and loads no code of its own, so the bundle "
                              "being opened belongs to another tweak"];
        }
        if (bundles.count > 0) {
            [parts addObject:[NSString stringWithFormat:@"bundles loaded: %@",
                                                        [bundles componentsJoinedByString:@", "]]];
        }
    } else {
        NSString *culprit = DSCulpritImageName(payload, ours);
        if (culprit && DSPathIsThisTweak(culprit)) {
            [parts addObject:[NSString stringWithFormat:@"%@ crashed at %@ in Dynamic Stage", host, time]];
        } else if (culprit) {
            [parts addObject:[NSString stringWithFormat:@"%@ crashed at %@ in %@, not in Dynamic Stage",
                                                        host, time, culprit]];
        } else {
            [parts addObject:[NSString stringWithFormat:@"%@ crashed at %@, with no tweak in the frames",
                                                        host, time]];
        }
    }

    NSString *reason = DSExceptionReason(payload);
    if (reason.length > 0) [parts addObject:reason];
    NSString *exception = DSExceptionDescription(payload);
    if (exception.length > 0) [parts addObject:exception];
    if (frames.length > 0) [parts addObject:frames];

    return DSClipped([parts componentsJoinedByString:@" - "], kDSCrashSummaryLimit);
}

NSString *DSLastCrashSummary(BOOL *implicatesTheTweak) {
    if (implicatesTheTweak) *implicatesTheTweak = NO;

    @try {
        // Settings first: the settings page is the part of this tweak that has taken its
        // host down before, so a report from Settings is worth showing even when the
        // fault turns out to be somebody else's - that answer is the whole point.
        // SpringBoard is only shown when this tweak is in the frames, because every
        // other reason SpringBoard has to crash is nothing to do with the stage.
        NSDate *settingsDate = nil;
        NSString *settingsPath = DSNewestReportPath(@[ @"Preferences-", @"Settings-" ], &settingsDate);
        NSDate *springBoardDate = nil;
        NSString *springBoardPath = DSNewestReportPath(@[ @"SpringBoard-" ], &springBoardDate);

        BOOL preferSpringBoard = settingsPath == nil ||
            (springBoardPath && [springBoardDate compare:settingsDate] == NSOrderedDescending);

        for (NSUInteger attempt = 0; attempt < 2; attempt++) {
            BOOL springBoard = (attempt == 0) == preferSpringBoard;
            NSString *path = springBoard ? springBoardPath : settingsPath;
            NSDate *when = springBoard ? springBoardDate : settingsDate;
            if (!path) continue;

            BOOL ours = NO;
            NSString *summary = DSSummaryOfReportAtPath(path, when, springBoard, &ours);
            if (summary.length == 0) continue;
            if (springBoard && !ours) continue;

            if (implicatesTheTweak) *implicatesTheTweak = ours;
            return summary;
        }
        return nil;
    } @catch (NSException *exception) {
        return nil;
    }
}
