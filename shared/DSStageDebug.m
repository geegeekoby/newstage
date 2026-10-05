#import "DSStageDebug.h"
#import <stdarg.h>

NSMutableString *DSLogBuffer = nil;

static const NSUInteger kDSLogBufferMaxBytes = 1048576;

static id DSLogLock(void) {
    static id lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [NSObject new];
    });
    return lock;
}

void DSLogInit(void) {
    @synchronized (DSLogLock()) {
        if (!DSLogBuffer) DSLogBuffer = [NSMutableString string];
    }
}

void DSLogC(const char *format, ...) {
    if (!format) return;
    va_list arguments;
    va_start(arguments, format);
    NSString *line = [[NSString alloc] initWithFormat:[NSString stringWithUTF8String:format] arguments:arguments];
    va_end(arguments);
    DSLogAppend(line);
}

void DSLogAppend(NSString *line) {
    if (line.length == 0) return;
    @synchronized (DSLogLock()) {
        if (!DSLogBuffer) DSLogBuffer = [NSMutableString string];
        [DSLogBuffer appendFormat:@"%@\n", line];
        if (DSLogBuffer.length > kDSLogBufferMaxBytes) {
            NSUInteger cut = DSLogBuffer.length - kDSLogBufferMaxBytes;
            NSRange newline = [DSLogBuffer rangeOfString:@"\n"
                                                 options:0
                                                   range:NSMakeRange(cut, DSLogBuffer.length - cut)];
            NSUInteger start = newline.location == NSNotFound ? cut : NSMaxRange(newline);
            [DSLogBuffer deleteCharactersInRange:NSMakeRange(0, start)];
        }
    }
}

NSString *DSLogDump(void) {
    @synchronized (DSLogLock()) {
        if (!DSLogBuffer) DSLogBuffer = [NSMutableString string];
        return [DSLogBuffer copy] ?: @"";
    }
}

void DSLogClear(void) {
    @synchronized (DSLogLock()) {
        if (!DSLogBuffer) DSLogBuffer = [NSMutableString string];
        [DSLogBuffer setString:@""];
    }
}
