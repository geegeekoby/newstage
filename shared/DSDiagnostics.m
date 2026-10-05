#import "DSDiagnostics.h"
#undef DSDiagnosticsRecord
#undef DSDiagnosticsRecordFormat
#undef DSBeeperDetailLog
#undef DSBeeperDetailLogFormat
#undef DSTrace
#undef DSTraceFormat
#undef DSTraceSetContext

void DSDiagnosticsRecord(NSString *message);
void DSDiagnosticsRecordFormat(NSString *format, ...);
void DSBeeperDetailLog(NSString *message);
void DSBeeperDetailLogFormat(NSString *format, ...);
void DSTrace(NSString *message);
void DSTraceFormat(NSString *format, ...);
void DSTraceSetContext(NSString *context);

#import "DSStageDebug.h"
#import "DSCrashLog.h"
#import "DSConstants.h"
#import <fcntl.h>
#import <pthread.h>
#import <unistd.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <sys/time.h>

static NSString *DSDiagnosticsStamp(void);
// Set once a SpringBoard session has started. The boot-guard path records a
// line from %ctor, and the in-memory log must not run on that path.
static BOOL DSDiagnosticsMemoryLog = NO;

static const NSUInteger kDSDiagnosticsMaxBytes = 12288;
static const NSUInteger kDSKeyboardStageLogMaxBytes = 262144;

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
    // The prefs log below is SpringBoard-only and async, so a hang loses it.
    // The trace is the copy that is already on disk.
    DSTrace(message);
    // Only SpringBoard writes this file. Other processes that load the shared
    // helpers used to append garbage over the keyboard lines.
    NSString *processName = NSProcessInfo.processInfo.processName ?: @"";
    if (![processName isEqualToString:@"SpringBoard"]) return;
    // One entry is one line, including when what is being recorded is not: the log is
    // trimmed by finding a newline and cutting there, so a message carrying its own
    // would be cut in the middle of itself.
    if ([message rangeOfString:@"\n"].location != NSNotFound) {
        message = [[message componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]
            componentsJoinedByString:@" "];
    }
    // Drop control characters that other writers used to paste into the middle
    // of a SpringBoard line.
    if ([message rangeOfCharacterFromSet:[NSCharacterSet characterSetWithRange:NSMakeRange(0, 32)]].location != NSNotFound ||
        [message rangeOfString:@"\x7f"].location != NSNotFound) {
        NSMutableString *clean = [message mutableCopy];
        for (NSUInteger index = 0; index < clean.length; ) {
            unichar unit = [clean characterAtIndex:index];
            if (unit < 0x20 || unit == 0x7f) {
                [clean deleteCharactersInRange:NSMakeRange(index, 1)];
            } else {
                index++;
            }
        }
        message = clean;
        if (message.length == 0) return;
    }
    if (message.length > kDSDiagnosticsMaxLineLength) {
        message = [[message substringToIndex:kDSDiagnosticsMaxLineLength - 3] stringByAppendingString:@"..."];
    }
    // The file write below is async and does not survive a safe mode. The crash
    // log reads this copy, which is already in memory when the process dies.
    DSCrashLogRemember(message);
    DSLogAppend(message);
    return;

    NSString *line = [NSString stringWithFormat:@"%@ %@: %@\n",
                      DSDiagnosticsStamp(),
                      processName,
                      message];

    dispatch_async(DSDiagnosticsQueue(), ^{
        __block int lockFile = -1;
        @try {
            NSString *path = DSDiagnosticsPath();
            NSString *session = DSDiagnosticsSessionID();
            NSString *written = line;
            if (session.length > 0 && [written rangeOfString:session].location == NSNotFound) {
                written = [[written substringToIndex:written.length - 1]
                    stringByAppendingFormat:@" session=%@\n", session];
            }
            // SpringBoard and the staged app both append this file. Without a
            // lock the later write drops the other process's lines.
            NSString *lockPath = [path stringByAppendingString:@".lock"];
            lockFile = open(lockPath.fileSystemRepresentation, O_RDWR | O_CREAT, 0644);
            if (lockFile >= 0) flock(lockFile, LOCK_EX);
            NSString *existing = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
            // A write that started before this respring can put the old boot back
            // on disk. Drop that boot once. The new line carries the session id, so
            // the next line is appended instead of replacing the file.
            if (session.length > 0 && [existing rangeOfString:session].location == NSNotFound) {
                existing = @"";
            }
            NSString *combined = [existing stringByAppendingString:written];

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
        } @finally {
            if (lockFile >= 0) {
                flock(lockFile, LOCK_UN);
                close(lockFile);
            }
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

static void DSWriteFreshKeyboardStageLog(NSString *session) {
    NSString *path = kDSKeyboardStageLogPath;
    NSString *header = [NSString stringWithFormat:
        @"Dynamic Stage — keyboard / dual-stack log (this boot only)\n"
        @"Path: %@\n"
        @"Cleared on every respring when SpringBoard starts.\n"
        @"Session: %@\n"
        @"Boot: %@\n"
        @"---\n",
        path,
        session.length ? session : @"?",
        DSDiagnosticsStamp()];
    [header writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

NSString *DSDiagnosticsReadKeyboardStageLog(void) {
    @try {
        NSString *text = [NSString stringWithContentsOfFile:kDSKeyboardStageLogPath
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil] ?: @"";
        return text;
    } @catch (NSException *exception) {
        return @"";
    }
}

void DSDiagnosticsAppendKeyboardStageLog(NSString *message) {
    if (message.length == 0) return;
    NSString *processName = NSProcessInfo.processInfo.processName ?: @"";
    if (![processName isEqualToString:@"SpringBoard"]) return;
    DSLogAppend([@"[KEYBOARD LOG] " stringByAppendingString:message]);
}

static const char *kDSTracePath = "/var/tmp/com.recreated.dynamicstage.trace.log";
static const char *kDSTracePreviousPath = "/var/tmp/com.recreated.dynamicstage.trace.previous.log";

static pthread_mutex_t DSTraceLock = PTHREAD_MUTEX_INITIALIZER;
static char DSTraceLast[2][360];
static volatile int DSTraceLastSlot = 0;
static char DSTraceContext[240];
static volatile int DSTraceContextReady = 0;
static CFAbsoluteTime DSTraceMainBeat = 0;
static char DSTraceDedup[360];
static int DSTraceRepeat = 0;
static CFAbsoluteTime DSTraceDedupAt = 0;
static int DSTraceWindowCount = 0;
static int DSTraceWindowDropped = 0;
static CFAbsoluteTime DSTraceWindowStart = 0;

static NSString *DSTraceClock(void) {
    struct timeval now;
    gettimeofday(&now, NULL);
    struct tm parts;
    localtime_r(&now.tv_sec, &parts);
    return [NSString stringWithFormat:@"%02d:%02d:%02d.%03d",
            parts.tm_hour, parts.tm_min, parts.tm_sec, (int)(now.tv_usec / 1000)];
}

static void DSTraceRemember(NSString *text) {
    if (text.length == 0) return;
    const char *utf8 = text.UTF8String ?: "";
    int slot = DSTraceLastSlot ^ 1;
    size_t count = 0;
    while (utf8[count] && count < sizeof(DSTraceLast[0]) - 1) {
        DSTraceLast[slot][count] = utf8[count];
        count++;
    }
    DSTraceLast[slot][count] = 0;
    DSTraceLastSlot = slot;
}

static NSString *DSTraceLastLine(void) {
    int slot = DSTraceLastSlot;
    const char *text = DSTraceLast[slot];
    if (!text[0]) return @"?";
    return [NSString stringWithUTF8String:text] ?: @"?";
}

static void DSTraceWriteBytes(const char *bytes, size_t length) {
    if (!bytes || length == 0) return;
    int fd = open(kDSTracePath, O_RDWR | O_CREAT | O_APPEND, 0666);
    if (fd < 0) return;
    flock(fd, LOCK_EX);
    off_t end = lseek(fd, 0, SEEK_END);
    if (end > 700000) {
        off_t keep = 320000;
        off_t start = end > keep ? end - keep : 0;
        char *buffer = (char *)malloc((size_t)keep);
        ssize_t count = 0;
        if (buffer && lseek(fd, start, SEEK_SET) >= 0) {
            count = read(fd, buffer, (size_t)keep);
        }
        if (count > 0 && ftruncate(fd, 0) == 0) {
            ssize_t skip = 0;
            if (start > 0) {
                while (skip < count && buffer[skip] != '\n') skip++;
                if (skip < count) skip++;
            }
            lseek(fd, 0, SEEK_SET);
            if (count > skip) {
                ssize_t ignored = write(fd, buffer + skip, (size_t)(count - skip));
                (void)ignored;
            }
        }
        free(buffer);
        lseek(fd, 0, SEEK_END);
    }
    ssize_t ignored = write(fd, bytes, length);
    (void)ignored;
    flock(fd, LOCK_UN);
    close(fd);
}

static void DSTraceCommit(NSString *message, BOOL force) {
    if (message.length == 0) return;
    if ([message rangeOfString:@"\n"].location != NSNotFound) {
        message = [[message componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]
            componentsJoinedByString:@" "];
    }
    if (message.length > 320) {
        message = [[message substringToIndex:317] stringByAppendingString:@"..."];
    }
    NSString *process = NSProcessInfo.processInfo.processName ?: @"?";
    BOOL main = NSThread.isMainThread;
    if (main) DSTraceMainBeat = CFAbsoluteTimeGetCurrent();

    pthread_mutex_lock(&DSTraceLock);
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    const char *utf8 = message.UTF8String ?: "";
    BOOL same = strncmp(DSTraceDedup, utf8, sizeof(DSTraceDedup) - 1) == 0;
    if (!force && same && (now - DSTraceDedupAt) < 1.0) {
        DSTraceRepeat += 1;
        NSString *shown = DSTraceRepeat > 1
            ? [NSString stringWithFormat:@"%@ x%d", message, DSTraceRepeat]
            : message;
        DSTraceRemember(shown);
        pthread_mutex_unlock(&DSTraceLock);
        return;
    }
    // A layout loop writes a different line every millisecond, so the check
    // above never sees a repeat. After a short burst, keep one pause line and
    // drop the rest until the main thread is quiet again.
    NSString *resumed = nil;
    if (!force) {
        if (DSTraceWindowStart == 0 || (now - DSTraceWindowStart) > 0.25) {
            if (DSTraceWindowDropped > 0) {
                resumed = [NSString stringWithFormat:@"trace resumed after dropping %d lines", DSTraceWindowDropped];
            }
            DSTraceWindowStart = now;
            DSTraceWindowCount = 0;
            DSTraceWindowDropped = 0;
        }
        DSTraceWindowCount += 1;
        if (DSTraceWindowCount > 48) {
            DSTraceWindowDropped += 1;
            pthread_mutex_unlock(&DSTraceLock);
            return;
        }
        if (DSTraceWindowCount == 48) {
            message = @"trace paused, main thread is spinning";
            utf8 = message.UTF8String ?: "";
        }
    }
    NSString *burst = nil;
    if (DSTraceRepeat > 1) {
        burst = [NSString stringWithFormat:@"%@ %@ | %@ x%d\n",
                 DSTraceClock(), process, [NSString stringWithUTF8String:DSTraceDedup] ?: message, DSTraceRepeat];
    }
    DSTraceRepeat = 1;
    DSTraceDedupAt = now;
    strncpy(DSTraceDedup, utf8, sizeof(DSTraceDedup) - 1);
    DSTraceDedup[sizeof(DSTraceDedup) - 1] = 0;
    DSTraceRemember(message);
    NSString *line = [NSString stringWithFormat:@"%@ %@ pid=%d %@ | %@\n",
                      DSTraceClock(),
                      process,
                      (int)getpid(),
                      main ? @"main" : @"bg",
                      message];
    pthread_mutex_unlock(&DSTraceLock);

    if (burst.length) {
        const char *bytes = burst.UTF8String;
        if (bytes) DSTraceWriteBytes(bytes, strlen(bytes));
    }
    if (resumed.length) {
        NSString *resumedLine = [NSString stringWithFormat:@"%@ %@ pid=%d %@ | %@\n",
                                 DSTraceClock(),
                                 process,
                                 (int)getpid(),
                                 main ? @"main" : @"bg",
                                 resumed];
        const char *bytes = resumedLine.UTF8String;
        if (bytes) DSTraceWriteBytes(bytes, strlen(bytes));
    }
    const char *bytes = line.UTF8String;
    if (bytes) DSTraceWriteBytes(bytes, strlen(bytes));
}

void DSTrace(NSString *message) {
    @try {
        DSTraceCommit(message, NO);
        NSString *processName = NSProcessInfo.processInfo.processName;
        if (message.length > 0 && [processName isEqualToString:@"SpringBoard"]) {
            DSLogAppend([@"[TRACE] " stringByAppendingString:message]);
        }
    } @catch (NSException *exception) {
    }
}

void DSTraceFormat(NSString *format, ...) {
    if (format.length == 0) return;
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    DSTrace(message);
}

void DSTraceSetContext(NSString *context) {
    if (context.length == 0) return;
    if (context.length > 180) context = [context substringToIndex:180];
    pthread_mutex_lock(&DSTraceLock);
    strncpy(DSTraceContext, context.UTF8String ?: "", sizeof(DSTraceContext) - 1);
    DSTraceContext[sizeof(DSTraceContext) - 1] = 0;
    DSTraceContextReady = 1;
    pthread_mutex_unlock(&DSTraceLock);
    DSTrace(context);
}

static void DSTraceForce(NSString *message) {
    @try {
        DSTraceCommit(message, YES);
    } @catch (NSException *exception) {
    }
}

void DSTraceArchivePreviousAndStart(void) {
    @try {
        unlink(kDSTracePreviousPath);
        rename(kDSTracePath, kDSTracePreviousPath);
    } @catch (NSException *exception) {
    }
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CFRunLoopObserverRef observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            kCFRunLoopBeforeWaiting,
            YES,
            0,
            ^(CFRunLoopObserverRef ref, CFRunLoopActivity activity) {
                (void)ref;
                (void)activity;
                DSTraceMainBeat = CFAbsoluteTimeGetCurrent();
            });
        if (observer) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
            CFRelease(observer);
        }
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                         dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(timer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                                  (uint64_t)(0.5 * NSEC_PER_SEC),
                                  (uint64_t)(0.1 * NSEC_PER_SEC));
        __block BOOL noted = NO;
        __block CFAbsoluteTime lastAlive = 0;
        dispatch_source_set_event_handler(timer, ^{
            CFAbsoluteTime beat = DSTraceMainBeat;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (beat <= 0) return;
            if (now - beat > 1.5) {
                if (!noted) {
                    noted = YES;
                    DSTraceForce([NSString stringWithFormat:@"STALL main silent for %.1fs after [%@] ctx [%s]",
                                  now - beat, DSTraceLastLine(), DSTraceContext]);
                }
            } else {
                noted = NO;
                if (DSTraceContextReady && now - lastAlive > 3.0) {
                    lastAlive = now;
                    DSTraceForce([NSString stringWithFormat:@"alive %s", DSTraceContext]);
                }
            }
        });
        dispatch_resume(timer);
    });
    DSTraceFormat(@"trace start build %s", kDSBuildVersionString);
}

static NSString *DSTraceFile(const char *path, NSUInteger cap) {
    NSString *text = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:path]
                                               encoding:NSUTF8StringEncoding
                                                  error:nil] ?: @"";
    if (cap > 0 && text.length > cap) text = [text substringFromIndex:text.length - cap];
    return text;
}

NSString *DSTraceRead(void) {
    @try {
        NSString *previous = DSTraceFile(kDSTracePreviousPath, 80 * 1024);
        NSString *current = DSTraceFile(kDSTracePath, 80 * 1024);
        return [NSString stringWithFormat:@"=== previous session ===\n%@\n=== this session ===\n%@",
                previous.length ? previous : @"(none)",
                current.length ? current : @"(none)"];
    } @catch (NSException *exception) {
        return @"";
    }
}

void DSDiagnosticsBeginSession(NSString *message) {
    if (message.length == 0) message = @"log refreshed";
    DSDiagnosticsMemoryLog = YES;
    DSLogInit();
    DSLogClear();
    DSLogAppend(message);
    NSString *session = NSUUID.UUID.UUIDString;
    NSString *line = [NSString stringWithFormat:@"%@ %@: %@ session=%@\n",
                      DSDiagnosticsStamp(),
                      NSProcessInfo.processInfo.processName ?: @"?",
                      message,
                      session];
    dispatch_async(DSDiagnosticsQueue(), ^{
        @try {
            [session writeToFile:DSDiagnosticsSessionPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSFileManager *files = NSFileManager.defaultManager;
            [files removeItemAtPath:DSDiagnosticsPath() error:nil];
            [files removeItemAtPath:kDSKeyboardStageLogPath error:nil];
            [files removeItemAtPath:kDSBeeperDetailLogPath error:nil];
            [files removeItemAtPath:@"/var/tmp/com.recreated.dynamicstage.trace.log" error:nil];
            [files removeItemAtPath:@"/var/tmp/com.recreated.dynamicstage.trace.previous.log" error:nil];
            (void)line;
        } @catch (NSException *exception) {
        }
    });
}

static const NSUInteger kDSBeeperDetailMaxBytes = 393216;
static const NSUInteger kDSBeeperDetailMaxLine = 1600;

static dispatch_queue_t DSBeeperDetailQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        queue = dispatch_queue_create("com.recreated.dynamicstage.beeper-detail", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

void DSBeeperDetailLog(NSString *message) {
    if (message.length == 0) return;
    DSLogAppend([@"[BEEPER] " stringByAppendingString:message]);
}

void DSBeeperDetailLogFormat(NSString *format, ...) {
    if (format.length == 0) return;
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    DSBeeperDetailLog(message);
}
