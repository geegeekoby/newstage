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
#import <errno.h>
#import <fcntl.h>
#import <pthread.h>
#import <unistd.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <sys/time.h>
static BOOL DSTrace792Active(void);

static NSString *DSDiagnosticsStamp(void);
// 4.5.697: set around DSTrace when DSDiagnosticsRecord keeps the plain copy
// itself (main thread only; background lines keep both copies).
static BOOL DSTraceSkipMemoryCopy = NO;
// Set once a SpringBoard session has started. The boot-guard path records a
// line from %ctor, and the in-memory log must not run on that path.
static BOOL DSDiagnosticsMemoryLog = NO;

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
    // The prefs log below is SpringBoard-only and async, so a hang loses it.
    // The trace is the copy that is already on disk.
    DSTraceSkipMemoryCopy = DSLogQuiet() && NSThread.isMainThread;
    DSTrace(message);
    DSTraceSkipMemoryCopy = NO;
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
    static NSCharacterSet *controlSet = nil;
    static dispatch_once_t controlOnce;
    dispatch_once(&controlOnce, ^{
        controlSet = [NSCharacterSet characterSetWithRange:NSMakeRange(0, 32)];
    });
    if ([message rangeOfCharacterFromSet:controlSet].location != NSNotFound ||
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
static volatile BOOL DSTraceMainWaiting = NO;
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

// 4.5.667: a third-party app (Beeper, Messenger, Signal) cannot open
// /var/tmp from its sandbox, so not one of its trace lines (ctor, camera658,
// layout663/664, tap666) ever reached the log. Its lines now go to the app's
// own tmp directory instead; SpringBoard copies new lines from there into the
// shared trace (springboard/DSAppTraceRelay.m, "relay667").
static char DSTraceFallbackPath[1024];
static volatile int DSTraceFallbackState = 0; // 0 unknown, 1 shared path works, 2 fallback

static const char *DSTraceFallback(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            NSString *process = NSProcessInfo.processInfo.processName ?: @"";
            if ([process isEqualToString:@"SpringBoard"]) return;
            NSString *dir = NSTemporaryDirectory();
            if (dir.length == 0 || [dir hasPrefix:@"/var/tmp"] || [dir hasPrefix:@"/private/var/tmp"]) return;
            NSString *path = [dir stringByAppendingPathComponent:@"" kDSAppTraceFileName];
            const char *utf8 = path.fileSystemRepresentation;
            if (utf8 && strlen(utf8) < sizeof(DSTraceFallbackPath)) {
                strncpy(DSTraceFallbackPath, utf8, sizeof(DSTraceFallbackPath) - 1);
            }
        } @catch (NSException *exception) {
        }
    });
    return DSTraceFallbackPath[0] ? DSTraceFallbackPath : NULL;
}

static void DSTraceWriteBytesToPath(const char *path, off_t cap, off_t keep, const char *bytes, size_t length);

static void DSTraceWriteBytesNow(const char *bytes, size_t length);

// 4.5.697: the trace file write (open, flock, write, close) ran on the calling
// thread, the main thread for nearly every line. It goes to a serial queue now.
// The crash copy (DSCrashLogRemember) and the in-memory log are unchanged.
static dispatch_queue_t DSTraceWriteQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        queue = dispatch_queue_create("com.recreated.dynamicstage.trace-writer", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

// 4.5.706 perf706: lines that arrive while a write is already queued go out
// with it (one open / lock / write / close for the burst instead of one per
// line). Nothing waits: the first line of a burst is queued at once.
static NSMutableData *DSTracePending706 = nil;
static BOOL DSTraceFlushQueued706 = NO;
static pthread_mutex_t DSTracePendingLock706 = PTHREAD_MUTEX_INITIALIZER;

// 4.5.708: no switch or crash-latch read on the write path. The 706 burst
// batching is always used (it was the default); the write path no longer
// touches /var/mobile/.dynamicstage-* files from whatever thread or app
// constructor happens to trace, and no perf counter (itself a switch read).
// ---- 4.5.706 writer, kept for the groupd713 kill switch ----
static void DSTraceWriteBytes706(const char *bytes, size_t length) {
    if (!bytes || length == 0) return;
    DSPerfCount(DSPerfCounterTraceWrites);
    if (DSPerf697On() && DSFeature699On("perf706")) {
        BOOL schedule = NO;
        pthread_mutex_lock(&DSTracePendingLock706);
        if (!DSTracePending706) DSTracePending706 = [NSMutableData dataWithCapacity:4096];
        [DSTracePending706 appendBytes:bytes length:length];
        if (!DSTraceFlushQueued706) {
            DSTraceFlushQueued706 = YES;
            schedule = YES;
        }
        pthread_mutex_unlock(&DSTracePendingLock706);
        if (schedule) {
            dispatch_async(DSTraceWriteQueue(), ^{
                pthread_mutex_lock(&DSTracePendingLock706);
                NSData *data = DSTracePending706;
                DSTracePending706 = nil;
                DSTraceFlushQueued706 = NO;
                pthread_mutex_unlock(&DSTracePendingLock706);
                if (data.length) {
                    DSPerfCount(DSPerfCounterTraceFlushes);
                    DSTraceWriteBytesNow((const char *)data.bytes, data.length);
                }
            });
        }
        return;
    }
    if (DSPerf697On()) {
        NSData *data = [NSData dataWithBytes:bytes length:length];
        dispatch_async(DSTraceWriteQueue(), ^{
            DSTraceWriteBytesNow((const char *)data.bytes, data.length);
        });
        return;
    }
    DSTraceWriteBytesNow(bytes, length);
}

static void DSTraceWriteBytes(const char *bytes, size_t length) {
    if (!bytes || length == 0) return;
    // 4.5.713 group D kill switch: /var/mobile/.dynamicstage-groupd713-off =
    // the exact 4.5.706 writer (one cached access() every 2 s, no latch file).
    if (!DSGroupD713On()) {
        DSTraceWriteBytes706(bytes, length);
        return;
    }
    BOOL schedule = NO;
    pthread_mutex_lock(&DSTracePendingLock706);
    if (!DSTracePending706) DSTracePending706 = [NSMutableData dataWithCapacity:4096];
    [DSTracePending706 appendBytes:bytes length:length];
    if (!DSTraceFlushQueued706) {
        DSTraceFlushQueued706 = YES;
        schedule = YES;
    }
    pthread_mutex_unlock(&DSTracePendingLock706);
    if (schedule) {
        dispatch_async(DSTraceWriteQueue(), ^{
            pthread_mutex_lock(&DSTracePendingLock706);
            NSData *data = DSTracePending706;
            DSTracePending706 = nil;
            DSTraceFlushQueued706 = NO;
            pthread_mutex_unlock(&DSTracePendingLock706);
            if (data.length) DSTraceWriteBytesNow((const char *)data.bytes, data.length);
        });
    }
}

// 4.5.766 trace766: the Hello log had torn lines ("gationAlertUpdateTarg"
// repeated) from several processes trimming and appending the one shared file.
// Every process other than SpringBoard now writes its own file
// (trace.p-<process>.log); SpringBoard keeps the shared path (its own lines
// plus the relayed app lines, one writer process). Copy Logs merges them by
// time. Off: trace766-off / core766-off.
static const char *kDSTrace766Prefix = "com.recreated.dynamicstage.trace.p-";
static char DSTrace766Path[512];
static BOOL DSTrace766PerProcess(void) {
    static int state = 0;   // 0 unknown, 1 shared, 2 own file
    if (state == 0) {
        int decided = 1;
        @try {
            NSString *process = NSProcessInfo.processInfo.processName ?: @"";
            if (process.length && ![process isEqualToString:@"SpringBoard"] && DS766On("trace766")) {
                NSMutableString *safe = [NSMutableString string];
                for (NSUInteger i = 0; i < process.length && i < 40; i++) {
                    unichar c = [process characterAtIndex:i];
                    BOOL ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_';
                    unichar out = ok ? c : (unichar)'_';
                    [safe appendString:[NSString stringWithCharacters:&out length:1]];
                }
                snprintf(DSTrace766Path, sizeof(DSTrace766Path), "/var/tmp/%s%s.log", kDSTrace766Prefix, safe.UTF8String ?: "x");
                decided = 2;
            }
        } @catch (NSException *exception) {
        }
        state = decided;
    }
    return state == 2;
}

static const char *DSTraceOwnPath(void) {
    return DSTrace766PerProcess() ? DSTrace766Path : kDSTracePath;
}

static void DSTraceWriteBytesNow(const char *bytes, size_t length) {
    if (!bytes || length == 0) return;
    // Decided on the writer queue, the first time a line is written.
    (void)DSTrace766PerProcess();
    if (DSTraceFallbackState == 1) {
        DSTraceWriteBytesToPath(DSTraceOwnPath(), DSTrace766PerProcess() ? 240000 : 700000, DSTrace766PerProcess() ? 100000 : 320000, bytes, length);
        return;
    }
    if (DSTraceFallbackState == 0) {
        int probe = open(DSTraceOwnPath(), O_RDWR | O_CREAT | O_APPEND, 0666);
        if (probe >= 0) {
            close(probe);
            DSTraceFallbackState = 1;
            DSTraceWriteBytesToPath(DSTraceOwnPath(), DSTrace766PerProcess() ? 240000 : 700000, DSTrace766PerProcess() ? 100000 : 320000, bytes, length);
            return;
        }
        if (errno != EPERM && errno != EACCES && errno != EROFS) return;
        if (!DSTraceFallback()) return;
        DSTraceFallbackState = 2;
    }
    const char *fallback = DSTraceFallback();
    if (fallback) DSTraceWriteBytesToPath(fallback, 400000, 160000, bytes, length);
}

static void DSTraceAppendRelayed706(NSString *text) {
    if (text.length == 0) return;
    const char *bytes = text.UTF8String;
    if (!bytes) return;
    if (DSPerf697On()) {
        NSData *data = [NSData dataWithBytes:bytes length:strlen(bytes)];
        dispatch_async(DSTraceWriteQueue(), ^{
            DSTraceWriteBytesToPath(kDSTracePath, 700000, 320000, (const char *)data.bytes, data.length);
        });
        return;
    }
    DSTraceWriteBytesToPath(kDSTracePath, 700000, 320000, bytes, strlen(bytes));
}

void DSTraceAppendRelayed(NSString *text) {
    if (text.length == 0) return;
    const char *bytes = text.UTF8String;
    if (!bytes) return;
    if (!DSGroupD713On()) {   // 4.5.713 kill switch: the 4.5.706 relay
        DSTraceAppendRelayed706(text);
        return;
    }
    // 4.5.708: always async, no switch read.
    NSData *data = [NSData dataWithBytes:bytes length:strlen(bytes)];
    dispatch_async(DSTraceWriteQueue(), ^{
        DSTraceWriteBytesToPath(kDSTracePath, 700000, 320000, (const char *)data.bytes, data.length);
    });
}

static void DSTraceWriteBytesToPath(const char *path, off_t cap, off_t keep, const char *bytes, size_t length) {
    if (!path || !bytes || length == 0) return;
    int fd = open(path, O_RDWR | O_CREAT | O_APPEND, 0666);
    if (fd < 0) return;
    // 4.5.766: an unlocked trim is what tears lines. If the lock is not
    // granted, only append (O_APPEND keeps a single write whole).
    BOOL locked = flock(fd, LOCK_EX) == 0;
    off_t end = lseek(fd, 0, SEEK_END);
    if (end > cap && (locked || !DS766On("trace766"))) {
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
    if (locked) flock(fd, LOCK_UN);
    close(fd);
}

static NSString *DS745Label(BOOL main) {
    // 4.5.745: built from stack bytes (the "main" constant came out as "p\u00f4").
    char m[5] = { 'm', 'a', 'i', 'n', 0 }, b[3] = { 'b', 'g', 0 };
    return [NSString stringWithCString:(main ? m : b) encoding:NSASCIIStringEncoding] ?: @"?";
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
    // 4.5.741 log741: a NUL or other control character inside a message ended
    // the C string early, so the line lost its tail and newline and the next
    // line ran into it (Bnb log 12:06:42.213). Every line is now one clean,
    // whole line before it reaches the serial writer. Off: -log741-off.
    if (DSFeature699On("log741")) {
        static NSCharacterSet *bad741 = nil;
        static dispatch_once_t once741;
        dispatch_once(&once741, ^{
            bad741 = [NSCharacterSet characterSetWithRange:NSMakeRange(0, 32)];
        });
        if ([message rangeOfCharacterFromSet:bad741].location != NSNotFound) {
            message = [[message componentsSeparatedByCharactersInSet:bad741] componentsJoinedByString:@"?"];
        }
    }
    message = DSAscii745(message);
    // 4.5.745 spam745: the same line again inside 0.25 s (a layout pass logged
    // several times, interleaved with other lines) is counted, not written; the
    // count rides on the next copy. Off: /var/mobile/.dynamicstage-spam745-off
    if (!force && DSFeature699On("spam745")) {
        static NSMutableDictionary<NSString *, NSNumber *> *seenAt = nil;
        static NSMutableDictionary<NSString *, NSNumber *> *skipped = nil;
        pthread_mutex_lock(&DSTraceLock);
        if (!seenAt) { seenAt = [NSMutableDictionary dictionary]; skipped = [NSMutableDictionary dictionary]; }
        CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
        NSNumber *last = seenAt[message];
        if (last && t - last.doubleValue < 0.25 && t >= last.doubleValue) {
            skipped[message] = @(skipped[message].integerValue + 1);
            pthread_mutex_unlock(&DSTraceLock);
            return;
        }
        if (seenAt.count > 64) [seenAt removeAllObjects];
        // 4.5.810: a line skipped once and never written again stayed here for
        // the life of the process. Same cap as seenAt (repeat counts only).
        if (skipped.count > 64) [skipped removeAllObjects];
        seenAt[message] = @(t);
        NSInteger more = skipped[message].integerValue;
        if (more > 0) {
            [skipped removeObjectForKey:message];
            message = [NSString stringWithFormat:@"%@ (+%ld repeats)", message, (long)more];
        }
        pthread_mutex_unlock(&DSTraceLock);
    }
    static NSString *process815 = nil;   // 4.5.815 perf815: the process name never changes
    NSString *process = process815;
    if (!process) { process = DSAscii745(NSProcessInfo.processInfo.processName ?: @"?"); if (DSPerf815Fast()) process815 = process; }
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
    // 4.5.791 log791: strip790 / entry781 / focus791 / reopen79x lines skip the
    // burst window (Highb 07:54:12.317 dropped 41 lines right at the strip drop).
    BOOL vip791 = [message hasPrefix:@"strip79"] || [message hasPrefix:@"entry781"] ||
                  [message hasPrefix:@"focus791"] || [message hasPrefix:@"reopen79"];
    if (vip791 && !DS791On("log791")) vip791 = NO;
    if ([message hasPrefix:@"strip792"]) vip791 = YES;
    if (DSTrace792Active()) { vip791 = YES; message = [@"w792 " stringByAppendingString:message]; utf8 = message.UTF8String ?: ""; }
    if (!force && !vip791) {
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
                      DS745Label(main),
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
                                 DS745Label(main),
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
        // 4.5.697: in the quiet log a line that DSDiagnosticsRecord also keeps
        // is not copied a second time as "[TRACE] ..." (every key line was in
        // the log twice). Lines that only go through DSTrace keep their copy.
        if (message.length > 0 && [processName isEqualToString:@"SpringBoard"] && !DSTraceSkipMemoryCopy) {
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
    // 4.5.701: register the battery701 switch on the main thread before the
    // watchdog below reads it from its queue.
    (void)DSBattery701On();
    dispatch_once(&once, ^{
        CFRunLoopObserverRef observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            kCFRunLoopBeforeWaiting | kCFRunLoopAfterWaiting,
            YES,
            0,
            ^(CFRunLoopObserverRef ref, CFRunLoopActivity activity) {
                (void)ref;
                // 4.5.701: also told when the main thread wakes, so "asleep"
                // (waiting for work) is not mistaken for "stuck" once the
                // stage tick no longer wakes it every 1.5 s.
                DSTraceMainWaiting = (activity == kCFRunLoopBeforeWaiting);
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
        __block int cadence = 0;   // 0 = 0.5 s (as before), 1 = 1 s, 2 = 10 s (locked)
        static dispatch_source_t keepTimer;
        keepTimer = timer;
        dispatch_source_set_event_handler(timer, ^{
            // 4.5.701 battery701: this ran twice a second for SpringBoard's
            // whole life, screen off included. Now once a second, and every
            // 10 s (5 s leeway) while the phone is locked; a main thread that
            // is asleep waiting for work is not a stall.
            BOOL battery = DSBattery701On();
            BOOL locked = battery && DSBattery701ScreenLocked();
            int want = !battery ? 0 : (locked ? 2 : 1);
            if (want != cadence) {
                cadence = want;
                double every = want == 0 ? 0.5 : (want == 1 ? 1.0 : 10.0);
                double leeway = want == 0 ? 0.1 : (want == 1 ? 0.3 : 5.0);
                dispatch_source_set_timer(keepTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(every * NSEC_PER_SEC)),
                                          (uint64_t)(every * NSEC_PER_SEC), (uint64_t)(leeway * NSEC_PER_SEC));
            }
            if (locked) {
                noted = NO;
                return;
            }
            CFAbsoluteTime beat = DSTraceMainBeat;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (beat <= 0) return;
            if (battery && DSTraceMainWaiting) {
                noted = NO;
                return;
            }
            if (now - beat > 1.5) {
                if (!noted) {
                    noted = YES;
                    DSTraceForce([NSString stringWithFormat:@"STALL main silent for %.1fs after [%@] ctx [%s]",
                                  now - beat, DSTraceLastLine(), DSTraceContext]);
                }
            } else {
                noted = NO;
                // 4.5.698 perf698: the "alive" heartbeat (a trace file write every
                // 3 s, forever) only with the verbose log. STALL lines are unchanged.
                if (DSTraceContextReady && now - lastAlive > 3.0 && (!DSPerf698On() || DSLogVerbose())) {
                    lastAlive = now;
                    DSTraceForce([NSString stringWithFormat:@"alive %s", DSTraceContext]);
                }
            }
        });
        dispatch_resume(timer);
    });
    DSTraceFormat(@"trace start build %s", kDSBuildVersionString);
}

// 4.5.792 log792: lines written inside the capture window carry "w792 " and
// are pulled out of the full trace files into their own section on export,
// so the 80 KB tail can't push them out. Off: -log792-off.
static CFAbsoluteTime DSTrace792Until = 0;
static int DSTrace792Taps = 0;
void DSTrace792Open(double seconds) {
    if (!DS792On("log792")) return;
    DSTrace792Taps = 0;
    DSTrace792Until = CFAbsoluteTimeGetCurrent() + seconds;
}
void DSTrace792Tap(void) {
    if (DSTrace792Until == 0) return;
    if (++DSTrace792Taps >= 10) DSTrace792Until = CFAbsoluteTimeGetCurrent() + 0.5;
}
static BOOL DSTrace792Active(void) {
    return DSTrace792Until > 0 && CFAbsoluteTimeGetCurrent() < DSTrace792Until;
}

static NSString *DSTraceFile(const char *path, NSUInteger cap) {
    NSString *text = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:path]
                                               encoding:NSUTF8StringEncoding
                                                  error:nil] ?: @"";
    // 4.5.801: align the tail cut to a newline so --- trace --- never starts
    // mid-string (Hdidbdh "rsystems.signal h=288 ...").
    if (cap > 0 && text.length > cap) {
        NSUInteger start = text.length - cap;
        NSRange nl = [text rangeOfString:@"\n" options:0 range:NSMakeRange(start, text.length - start)];
        if (nl.location != NSNotFound) start = nl.location + 1;
        text = [text substringFromIndex:start];
    }
    return text;
}

// 4.5.766 trace766: SpringBoard's file plus every per-process file, merged by
// the HH:mm:ss.SSS stamp at the start of each line (a line without one stays
// behind the line before it). Lines from one file keep their order.
static NSString *DSTrace766Merged(NSString *shared) {
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:@"/var/tmp" error:nil];
    NSString *prefix = [NSString stringWithUTF8String:kDSTrace766Prefix];
    NSMutableArray<NSString *> *texts = [NSMutableArray arrayWithObject:shared ?: @""];
    NSMutableArray<NSString *> *used = [NSMutableArray array];
    for (NSString *name in names) {
        if (![name hasPrefix:prefix] || ![name hasSuffix:@".log"]) continue;
        NSString *path = [@"/var/tmp" stringByAppendingPathComponent:name];
        NSString *text = DSTraceFile(path.fileSystemRepresentation, 60 * 1024);
        if (text.length == 0) continue;
        [texts addObject:text];
        [used addObject:[name substringFromIndex:prefix.length]];
    }
    if (used.count == 0) return shared;
    NSMutableArray<NSArray *> *rows = [NSMutableArray array];
    NSUInteger order = 0;
    for (NSUInteger f = 0; f < texts.count; f++) {
        NSString *key = @"";
        for (NSString *line in [texts[f] componentsSeparatedByString:@"\n"]) {
            if (line.length == 0) continue;
            if (line.length >= 12 && [line characterAtIndex:2] == ':' && [line characterAtIndex:5] == ':' && [line characterAtIndex:8] == '.') {
                key = [line substringToIndex:12];
            }
            [rows addObject:@[ key, @(order++), line ]];
        }
    }
    [rows sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        NSComparisonResult r = [(NSString *)a[0] compare:(NSString *)b[0]];
        if (r != NSOrderedSame) return r;
        return [(NSNumber *)a[1] compare:(NSNumber *)b[1]];
    }];
    NSMutableString *out = [NSMutableString stringWithFormat:@"(trace766: merged SpringBoard + %@)\n", [used componentsJoinedByString:@", "]];
    for (NSArray *row in rows) { [out appendString:row[2]]; [out appendString:@"\n"]; }
    NSUInteger cap = DS802On("trace802") ? 400 * 1024 : 120 * 1024;
    if (out.length > cap) {
        NSUInteger start = out.length - cap;
        NSRange nl = [out rangeOfString:@"\n" options:0 range:NSMakeRange(start, out.length - start)];
        if (nl.location != NSNotFound) start = nl.location + 1;
        return [out substringFromIndex:start];
    }
    return out;
}

// 4.5.802 trace802: split sessions by SpringBoard pid. The archive rename runs
// after the first hooks of a boot have already written, so this boot's opening
// lines sat in "previous session". Lines whose "SpringBoard pid=N" matches the
// current file's pid (and the unstamped lines that follow them) move to the top
// of "this session". The current file is read up to 400 KB (801: 80 KB, which
// cut this session to its last ~1 min). Off: trace802-off / core802-off.
static NSString *DSTrace802Pid(NSString *text) {
    NSRange r = [text rangeOfString:@"SpringBoard pid="];
    if (r.location == NSNotFound) return nil;
    NSUInteger i = NSMaxRange(r), j = i;
    while (j < text.length && [text characterAtIndex:j] >= '0' && [text characterAtIndex:j] <= '9') j++;
    return j > i ? [text substringWithRange:NSMakeRange(i, j - i)] : nil;
}

static void DSTrace802Split(NSString **previous, NSString **current) {
    NSString *pid = DSTrace802Pid(*current);
    if (!pid.length || (*previous).length == 0) return;
    NSString *mark = [NSString stringWithFormat:@"SpringBoard pid=%@ ", pid];
    NSMutableArray<NSString *> *old = [NSMutableArray array], *mine = [NSMutableArray array];
    BOOL inMine = NO;
    for (NSString *line in [*previous componentsSeparatedByString:@"\n"]) {
        if (line.length == 0) continue;
        BOOL stamped = line.length >= 12 && [line characterAtIndex:2] == ':' && [line characterAtIndex:5] == ':';
        if (stamped) inMine = [line rangeOfString:mark].location != NSNotFound;
        [(inMine ? mine : old) addObject:line];
    }
    if (mine.count == 0) return;
    NSString *p = [old componentsJoinedByString:@"\n"];
    if (p.length > 80 * 1024) {
        NSUInteger start = p.length - 80 * 1024;
        NSRange nl = [p rangeOfString:@"\n" options:0 range:NSMakeRange(start, p.length - start)];
        p = [p substringFromIndex:nl.location != NSNotFound ? nl.location + 1 : start];
    }
    *previous = p;
    *current = [NSString stringWithFormat:@"(trace802: %lu lines of SpringBoard pid=%@ from before the archive)\n%@\n%@",
                (unsigned long)mine.count, pid, [mine componentsJoinedByString:@"\n"], *current ?: @""];
}

NSString *DSTraceRead(void) {
    @try {
        BOOL t802 = DS802On("trace802");
        NSString *previous = DSTraceFile(kDSTracePreviousPath, t802 ? 0 : 80 * 1024);
        NSString *current = DSTraceFile(kDSTracePath, t802 ? 400 * 1024 : 80 * 1024);
        if (t802) {
            NSString *p = previous, *c = current;
            DSTrace802Split(&p, &c);
            previous = p; current = c;
            if (previous.length > 80 * 1024) {
                NSUInteger start = previous.length - 80 * 1024;
                NSRange nl = [previous rangeOfString:@"\n" options:0 range:NSMakeRange(start, previous.length - start)];
                previous = [previous substringFromIndex:nl.location != NSNotFound ? nl.location + 1 : start];
            }
        }
        if (DS766On("trace766")) current = DSTrace766Merged(current);
        if (DS792On("log792")) {
            NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithObject:[NSString stringWithUTF8String:kDSTracePath]];
            NSString *prefix = [NSString stringWithUTF8String:kDSTrace766Prefix];
            for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:@"/var/tmp" error:nil])
                if ([name hasPrefix:prefix] && [name hasSuffix:@".log"]) [paths addObject:[@"/var/tmp" stringByAppendingPathComponent:name]];
            NSMutableArray<NSString *> *keep = [NSMutableArray array];
            for (NSString *path in paths)
                for (NSString *line in [DSTraceFile(path.fileSystemRepresentation, 0) componentsSeparatedByString:@"\n"])
                    if ([line rangeOfString:@"| w792 "].location != NSNotFound) [keep addObject:line];
            [keep sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSString *a, NSString *b) {
                return [[a substringToIndex:MIN((NSUInteger)12, a.length)] compare:[b substringToIndex:MIN((NSUInteger)12, b.length)]];
            }];
            NSString *w = [keep componentsJoinedByString:@"\n"];
            if (w.length > 160 * 1024) w = [w substringFromIndex:w.length - 160 * 1024];
            current = [NSString stringWithFormat:@"=== log792 capture window (chat open + 10 taps / 10 s, %lu lines) ===\n%@\n=== end log792 window ===\n%@",
                       (unsigned long)keep.count, w.length ? w : @"(none)", current];
        }
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
    BOOL keepPrevious767 = [message isEqualToString:@"log refreshed after respring"];
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
            // 4.5.767 prev767: the after-respring refresh keeps the previous
            // session's trace (Resssj: it was deleted right after
            // DSTraceArchivePreviousAndStart moved it, so the crashed session's
            // trace was lost). Only a manual refresh deletes it.
            // Off: prev767-off / core767-off (latch prev767).
            if (!(keepPrevious767 && DS767On("prev767"))) {
                [files removeItemAtPath:@"/var/tmp/com.recreated.dynamicstage.trace.previous.log" error:nil];
            }
            // 4.5.766 trace766: the per-process files go with the shared one.
            NSString *prefix766 = [NSString stringWithUTF8String:kDSTrace766Prefix];
            for (NSString *name in [files contentsOfDirectoryAtPath:@"/var/tmp" error:nil]) {
                if ([name hasPrefix:prefix766]) [files removeItemAtPath:[@"/var/tmp" stringByAppendingPathComponent:name] error:nil];
            }
            (void)line;
        } @catch (NSException *exception) {
        }
    });
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
