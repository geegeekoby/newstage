#import "DSDiagnostics.h"
#import "DSConstants.h"

static const NSUInteger kDSDiagnosticsMaxBytes = 12288;

// No single line may take more than a small share of that window. One of the things
// written here is the reason of a caught exception, and a UIKit exception's reason can
// have a recursive dump of a whole view hierarchy inside it - thousands of lines about
// the app grid. One of those arrived and pushed everything else out, so the log read
// back as a wall of cell frames and two lines of account, which is the opposite of what
// it is for. The first part of a line says which exception and where; the rest of it has
// never been worth another line's place.
static const NSUInteger kDSDiagnosticsMaxLineLength = 400;

static NSString *DSDiagnosticsPath(void) {
    return kDSDiagnosticsPath;
}

static NSString *DSDiagnosticsSessionPath(void) {
    return kDSDiagnosticsSessionPath;
}

static NSString *DSDiagnosticsSessionID(void) {
    return [NSString stringWithContentsOfFile:DSDiagnosticsSessionPath()
                                     encoding:NSUTF8StringEncoding
                                        error:nil] ?: @"";
}

static dispatch_queue_t DSDiagnosticsQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        queue = dispatch_queue_create("com.recreated.dynamicstage.diagnostics", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSString *DSDiagnosticsStamp(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"MM-dd HH:mm:ss";
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    return [formatter stringFromDate:[NSDate date]];
}

void DSDiagnosticsRecord(NSString *message) {
    if (message.length == 0) return;
    // One entry is one line, including when what is being recorded is not: the log is
    // trimmed by finding a newline and cutting there, so a message carrying its own
    // would be cut in the middle of itself.
    if ([message rangeOfString:@"\n"].location != NSNotFound) {
        message = [[message componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]
            componentsJoinedByString:@" "];
    }
    if (message.length > kDSDiagnosticsMaxLineLength) {
        message = [[message substringToIndex:kDSDiagnosticsMaxLineLength - 3] stringByAppendingString:@"..."];
    }

    NSString *line = [NSString stringWithFormat:@"%@ %@: %@\n",
                      DSDiagnosticsStamp(),
                      NSProcessInfo.processInfo.processName ?: @"?",
                      message];

    dispatch_async(DSDiagnosticsQueue(), ^{
        @try {
            NSString *path = DSDiagnosticsPath();
            NSString *session = DSDiagnosticsSessionID();
            NSString *existing = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
            // A write that started before this respring can put the old boot back
            // on disk. Drop it the next time anything is recorded.
            if (session.length > 0 && [existing rangeOfString:session].location == NSNotFound) {
                existing = @"";
            }
            NSString *combined = [existing stringByAppendingString:line];

            // The log is a rolling window, not a record: it exists to be read on a
            // phone screen, and it must never be able to fill a disk.
            if (combined.length > kDSDiagnosticsMaxBytes) {
                NSUInteger cut = combined.length - kDSDiagnosticsMaxBytes;
                NSRange newline = [combined rangeOfString:@"\n"
                                                 options:0
                                                   range:NSMakeRange(cut, combined.length - cut)];
                combined = [combined substringFromIndex:newline.location == NSNotFound ? cut : NSMaxRange(newline)];
            }

            [combined writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } @catch (NSException *exception) {
            // Losing a log line is never worth a crash.
        }
    });
}

void DSDiagnosticsRecordFormat(NSString *format, ...) {
    if (format.length == 0) return;
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    DSDiagnosticsRecord(message);
}

NSString *DSDiagnosticsRead(void) {
    @try {
        NSString *text = [NSString stringWithContentsOfFile:DSDiagnosticsPath() encoding:NSUTF8StringEncoding error:nil] ?: @"";
        NSString *session = DSDiagnosticsSessionID();
        if (session.length == 0 || text.length == 0) return text;
        NSRange marker = [text rangeOfString:session];
        if (marker.location == NSNotFound) return text;
        NSRange lineBreak = [text rangeOfString:@"\n"
                                        options:NSBackwardsSearch
                                          range:NSMakeRange(0, marker.location)];
        if (lineBreak.location == NSNotFound) return text;
        return [text substringFromIndex:NSMaxRange(lineBreak)];
    } @catch (NSException *exception) {
        return @"";
    }
}

void DSDiagnosticsClear(void) {
    dispatch_async(DSDiagnosticsQueue(), ^{
        @try {
            [[NSFileManager defaultManager] removeItemAtPath:DSDiagnosticsPath() error:nil];
        } @catch (NSException *exception) {
        }
    });
}

void DSDiagnosticsBeginSession(NSString *message) {
    if (message.length == 0) message = @"log refreshed";
    NSString *session = NSUUID.UUID.UUIDString;
    NSString *line = [NSString stringWithFormat:@"%@ %@: %@ session=%@\n",
                      DSDiagnosticsStamp(),
                      NSProcessInfo.processInfo.processName ?: @"?",
                      message,
                      session];
    dispatch_async(DSDiagnosticsQueue(), ^{
        @try {
            [session writeToFile:DSDiagnosticsSessionPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [[NSFileManager defaultManager] removeItemAtPath:DSDiagnosticsPath() error:nil];
            [line writeToFile:DSDiagnosticsPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } @catch (NSException *exception) {
        }
    });
}
