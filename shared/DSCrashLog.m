#import "DSCrashLog.h"
#import "DSConstants.h"

#import <fcntl.h>
#import <signal.h>
#import <string.h>
#import <time.h>
#import <unistd.h>
#import <sys/stat.h>

static const char *kDSCrashLogCPath = "/var/mobile/Library/Preferences/com.recreated.dynamicstage.crash.log";
static const char *kDSStageLogCPath = "/var/mobile/Library/Preferences/com.recreated.dynamicstage.log";
static const char *kDSSessionCPath = "/var/mobile/Library/Preferences/com.recreated.dynamicstage.session";

static const int kDSCrashSignals[] = { SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE };
static const int kDSCrashSignalCount = 6;
static struct sigaction DSPreviousSignals[6];
static volatile sig_atomic_t DSCrashAlreadyWritten = 0;
static volatile sig_atomic_t DSInsideCrashHandler = 0;
static NSUncaughtExceptionHandler *DSPreviousExceptionHandler = NULL;

#define DS_RING_SLOTS 32
#define DS_RING_LINE 180
static char DSRing[DS_RING_SLOTS][DS_RING_LINE];
static volatile sig_atomic_t DSRingCount = 0;

static void DSAppend(int fd, const char *text) {
    if (fd < 0 || !text) return;
    size_t length = 0;
    while (text[length]) length++;
    if (length == 0) return;
    ssize_t ignored = write(fd, text, length);
    (void)ignored;
}

static void DSAppendUnsigned(int fd, unsigned long long value) {
    char buffer[32];
    int index = (int)sizeof(buffer);
    buffer[--index] = 0;
    if (value == 0) buffer[--index] = '0';
    while (value > 0 && index > 0) {
        buffer[--index] = (char)('0' + (value % 10));
        value /= 10;
    }
    DSAppend(fd, buffer + index);
}

static void DSAppendHex(int fd, uintptr_t value) {
    char buffer[2 + sizeof(uintptr_t) * 2 + 1];
    buffer[0] = '0';
    buffer[1] = 'x';
    const char *digits = "0123456789abcdef";
    int nibbles = (int)(sizeof(uintptr_t) * 2);
    for (int nibble = 0; nibble < nibbles; nibble++) {
        int shift = (nibbles - 1 - nibble) * 4;
        buffer[2 + nibble] = digits[(value >> shift) & 0xf];
    }
    buffer[2 + nibbles] = 0;
    DSAppend(fd, buffer);
}

static const char *DSSignalName(int sig) {
    switch (sig) {
        case SIGABRT: return "SIGABRT";
        case SIGSEGV: return "SIGSEGV";
        case SIGBUS: return "SIGBUS";
        case SIGILL: return "SIGILL";
        case SIGTRAP: return "SIGTRAP";
        case SIGFPE: return "SIGFPE";
        default: return "signal";
    }
}

static int DSOpenCrashLog(void) {
    int fd = open(kDSCrashLogCPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return -1;
    struct stat info;
    if (fstat(fd, &info) == 0 && info.st_size > 48 * 1024) {
        // The newest crash is the one that just happened. Drop the older ones
        // from this same build rather than letting the file grow without a limit.
        if (ftruncate(fd, 0) == 0) lseek(fd, 0, SEEK_SET);
    }
    if (fstat(fd, &info) == 0 && info.st_size == 0) {
        DSAppend(fd, "Dynamic Stage crash log\nBuild ");
        DSAppend(fd, kDSBuildVersionString);
        DSAppend(fd, "\nDeleted when a new build is installed.\nPath: ");
        DSAppend(fd, kDSCrashLogCPath);
        DSAppend(fd, "\n");
    }
    return fd;
}

static void DSAppendSession(int fd) {
    int session = open(kDSSessionCPath, O_RDONLY);
    if (session < 0) return;
    char identifier[80];
    ssize_t count = read(session, identifier, sizeof(identifier) - 1);
    close(session);
    if (count <= 0) return;
    identifier[count] = 0;
    for (ssize_t index = 0; index < count; index++) {
        if (identifier[index] == '\n' || identifier[index] == '\r') identifier[index] = 0;
    }
    DSAppend(fd, "session: ");
    DSAppend(fd, identifier);
    DSAppend(fd, "\n");
}

static void DSAppendRing(int fd) {
    int count = DSRingCount;
    int available = count < DS_RING_SLOTS ? count : DS_RING_SLOTS;
    if (available <= 0) return;
    DSAppend(fd, "--- recent stage lines ---\n");
    int start = count - available;
    for (int index = 0; index < available; index++) {
        const char *line = DSRing[(start + index) % DS_RING_SLOTS];
        if (!line[0]) continue;
        DSAppend(fd, line);
        DSAppend(fd, "\n");
    }
}

static void DSAppendStageLogTail(int fd) {
    int log = open(kDSStageLogCPath, O_RDONLY);
    if (log < 0) return;
    struct stat info;
    if (fstat(log, &info) != 0 || info.st_size <= 0) {
        close(log);
        return;
    }
    off_t start = info.st_size > 6000 ? info.st_size - 6000 : 0;
    if (lseek(log, start, SEEK_SET) < 0) {
        close(log);
        return;
    }
    char buffer[6000];
    ssize_t count = read(log, buffer, sizeof(buffer));
    close(log);
    if (count <= 0) return;
    DSAppend(fd, "--- stage log ---\n");
    ssize_t ignored = write(fd, buffer, (size_t)count);
    (void)ignored;
    if (buffer[count - 1] != '\n') DSAppend(fd, "\n");
}

static void DSWriteSignalCrash(int sig) {
    int fd = DSOpenCrashLog();
    if (fd < 0) return;
    DSAppend(fd, "\n=== Dynamic Stage crash ===\nbuild: ");
    DSAppend(fd, kDSBuildVersionString);
    DSAppend(fd, "\nwhen: ");
    DSAppendUnsigned(fd, (unsigned long long)time(NULL));
    DSAppend(fd, "\nsignal: ");
    DSAppend(fd, DSSignalName(sig));
    DSAppend(fd, "\n");
    DSAppendSession(fd);

    // Frame pointers only. backtrace() allocates, and allocating while a
    // signal is being delivered can hang the crash instead of recording it.
    DSAppend(fd, "backtrace:\n");
    void *frame = __builtin_frame_address(0);
    for (int index = 0; index < 16 && frame; index++) {
        void **record = (void **)frame;
        void *caller = record[1];
        DSAppend(fd, "  ");
        DSAppendHex(fd, (uintptr_t)caller);
        DSAppend(fd, "\n");
        void *next = record[0];
        if (!next || next == frame) break;
        frame = next;
    }
    DSAppendRing(fd);
    DSAppendStageLogTail(fd);
    DSAppend(fd, "=== end ===\n");
    close(fd);
}

static void DSFinishSignal(int sig, siginfo_t *info, void *context) {
    struct sigaction previous;
    memset(&previous, 0, sizeof(previous));
    for (int index = 0; index < kDSCrashSignalCount; index++) {
        if (kDSCrashSignals[index] == sig) {
            previous = DSPreviousSignals[index];
            break;
        }
    }
    if ((previous.sa_flags & SA_SIGINFO) && previous.sa_sigaction) {
        previous.sa_sigaction(sig, info, context);
        return;
    }
    if (previous.sa_handler && previous.sa_handler != SIG_DFL && previous.sa_handler != SIG_IGN) {
        previous.sa_handler(sig);
        return;
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

static void DSHandleSignal(int sig, siginfo_t *info, void *context) {
    if (DSInsideCrashHandler) {
        signal(sig, SIG_DFL);
        raise(sig);
        return;
    }
    DSInsideCrashHandler = 1;
    if (!DSCrashAlreadyWritten) {
        DSCrashAlreadyWritten = 1;
        DSWriteSignalCrash(sig);
    }
    DSFinishSignal(sig, info, context);
}

static void DSUncaughtException(NSException *exception) {
    if (!DSCrashAlreadyWritten) {
        DSCrashAlreadyWritten = 1;
        int fd = DSOpenCrashLog();
        if (fd >= 0) {
            DSAppend(fd, "\n=== Dynamic Stage crash ===\nbuild: ");
            DSAppend(fd, kDSBuildVersionString);
            DSAppend(fd, "\nwhen: ");
            DSAppendUnsigned(fd, (unsigned long long)time(NULL));
            DSAppend(fd, "\nexception: ");
            DSAppend(fd, exception.name.UTF8String ?: "?");
            DSAppend(fd, "\nreason: ");
            const char *reason = exception.reason.UTF8String;
            if (!reason) reason = "?";
            size_t length = 0;
            while (reason[length] && length < 500) length++;
            ssize_t ignored = write(fd, reason, length);
            (void)ignored;
            DSAppend(fd, "\n");
            DSAppendSession(fd);
            DSAppend(fd, "backtrace:\n");
            for (NSNumber *address in exception.callStackReturnAddresses) {
                DSAppend(fd, "  ");
                DSAppendHex(fd, (uintptr_t)address.unsignedLongLongValue);
                DSAppend(fd, "\n");
            }
            DSAppendRing(fd);
            DSAppendStageLogTail(fd);
            DSAppend(fd, "=== end ===\n");
            close(fd);
        }
    }
    if (DSPreviousExceptionHandler && DSPreviousExceptionHandler != DSUncaughtException) {
        DSPreviousExceptionHandler(exception);
    }
}

void DSCrashLogRemember(NSString *line) {
    if (line.length == 0) return;
    const char *utf8 = line.UTF8String;
    if (!utf8 || !utf8[0]) return;
    int slot = DSRingCount % DS_RING_SLOTS;
    char *dest = DSRing[slot];
    int index = 0;
    for (; index < DS_RING_LINE - 1 && utf8[index]; index++) {
        char character = utf8[index];
        if (character == '\n' || character == '\r') character = ' ';
        dest[index] = character;
    }
    dest[index] = 0;
    DSRingCount++;
}

void DSCrashLogInstallHandlers(void) {
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        DSPreviousExceptionHandler = NSGetUncaughtExceptionHandler();
        NSSetUncaughtExceptionHandler(DSUncaughtException);
        struct sigaction action;
        memset(&action, 0, sizeof(action));
        action.sa_sigaction = DSHandleSignal;
        action.sa_flags = SA_SIGINFO;
        sigemptyset(&action.sa_mask);
        for (int index = 0; index < kDSCrashSignalCount; index++) {
            sigaction(kDSCrashSignals[index], &action, &DSPreviousSignals[index]);
        }
    });
}

void DSCrashLogNoteUncleanLaunch(void) {
    @try {
        NSString *session = [NSString stringWithContentsOfFile:kDSDiagnosticsSessionPath
                                                      encoding:NSUTF8StringEncoding
                                                         error:nil] ?: @"";
        session = [session stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *existing = [NSString stringWithContentsOfFile:kDSCrashLogPath
                                                       encoding:NSUTF8StringEncoding
                                                          error:nil] ?: @"";
        if (session.length > 0 && [existing rangeOfString:session].location != NSNotFound) return;

        NSString *log = [NSString stringWithContentsOfFile:kDSDiagnosticsPath
                                                 encoding:NSUTF8StringEncoding
                                                    error:nil] ?: @"";
        if (log.length > 6000) log = [log substringFromIndex:log.length - 6000];

        NSMutableString *entry = [NSMutableString string];
        if (existing.length == 0) {
            [entry appendFormat:@"Dynamic Stage crash log\nBuild %s\nDeleted when a new build is installed.\nPath: %@\n",
                                kDSBuildVersionString, kDSCrashLogPath];
        }
        [entry appendFormat:@"\n=== Dynamic Stage crash ===\nbuild: %s\nwhen: the last SpringBoard start died before the stage was ready\nsession: %@\n--- stage log ---\n%@\n=== end ===\n",
                            kDSBuildVersionString,
                            session.length ? session : @"?",
                            log];
        int fd = open(kDSCrashLogCPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd < 0) return;
        const char *bytes = entry.UTF8String;
        if (bytes) {
            ssize_t ignored = write(fd, bytes, strlen(bytes));
            (void)ignored;
        }
        close(fd);
    } @catch (NSException *exception) {
    }
}

NSString *DSCrashLogRead(void) {
    @try {
        NSString *text = [NSString stringWithContentsOfFile:kDSCrashLogPath
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil] ?: @"";
        if (text.length > 48 * 1024) text = [text substringFromIndex:text.length - 48 * 1024];
        return text;
    } @catch (NSException *exception) {
        return @"";
    }
}
