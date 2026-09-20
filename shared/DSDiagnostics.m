#import "DSDiagnostics.h"
#import "DSConstants.h"

static const NSUInteger kDSDiagnosticsMaxBytes = 12288;

static NSString *DSDiagnosticsPath(void) {
    return kDSDiagnosticsPath;
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

    NSString *line = [NSString stringWithFormat:@"%@ %@: %@\n",
                      DSDiagnosticsStamp(),
                      NSProcessInfo.processInfo.processName ?: @"?",
                      message];

    dispatch_async(DSDiagnosticsQueue(), ^{
        @try {
            NSString *path = DSDiagnosticsPath();
            NSString *existing = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
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
        return [NSString stringWithContentsOfFile:DSDiagnosticsPath() encoding:NSUTF8StringEncoding error:nil] ?: @"";
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
