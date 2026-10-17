#import "DSCrashLog.h"
#import "DSConstants.h"

#import <fcntl.h>
#import <signal.h>
#import <string.h>
#import <time.h>
#import <unistd.h>
#import <sys/stat.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <sys/ucontext.h>

// 4.5.793 log793: last risky step, written synchronously before the call.
static char DSCrumb793[1024];   // 4.5.798: was 320 (crash lines were cut)
static volatile int DSCrumb793Seq = 0;
void DSCrash793Crumb(const char *text) {
    if (!text) return;
    size_t i = 0;
    for (; i < sizeof(DSCrumb793) - 1 && text[i]; i++) {
        char ch = text[i];
        DSCrumb793[i] = (ch >= 0x20 && ch <= 0x7e) ? ch : '?';
    }
    DSCrumb793[i] = 0;
    DSCrumb793Seq++;
}
static uintptr_t DS793PC = 0, DS793LR = 0;

// ---- 4.5.795 sig795: async-signal-safe crash writer -----------------------------
// The handler used dladdr() (takes the dyld lock) and access(). Rule: the
// handler only reads memory filled in before the crash. Image ranges are
// recorded when each image loads; the off-file checks are read at install.
// Off: sig795-off / core795-off (the handler goes back to 794's dladdr path).
#import <mach-o/loader.h>
#define DS795_IMAGES 4096   // 4.5.797: 1024 was too few (796 crash: our own frame had no image)
typedef struct { uintptr_t base, end; char name[40]; } DS795Image;
static DS795Image DS795Images[DS795_IMAGES];
static volatile int DS795ImageCount = 0;
static int DS795Safe = 0;          // decided at install
static int DS795Log793 = 1;        // log793 on (read at install when sig795 is on)
static int DS795Core793 = 1;
static uintptr_t DS795SelfBase = 0;
static void DS795AddImage(const struct mach_header *mh, intptr_t slide) {
    if (!mh) return;
    int i = DS795ImageCount;
    if (i >= DS795_IMAGES) return;
    const struct mach_header_64 *h = (const struct mach_header_64 *)mh;
    const uint8_t *cmd = (const uint8_t *)(h + 1);
    uintptr_t base = (uintptr_t)mh, end = 0;
    for (uint32_t c = 0; c < h->ncmds; c++) {
        const struct load_command *lc = (const struct load_command *)cmd;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
            if (strcmp(sg->segname, "__TEXT") == 0) end = base + (uintptr_t)sg->vmsize;
        }
        cmd += lc->cmdsize;
    }
    if (!end) return;
    Dl_info info; memset(&info, 0, sizeof(info));
    const char *name = "?";
    if (dladdr(mh, &info) && info.dli_fname) { name = strrchr(info.dli_fname, '/'); name = name ? name + 1 : info.dli_fname; }
    DS795Images[i].base = base; DS795Images[i].end = end;
    strlcpy(DS795Images[i].name, name, sizeof(DS795Images[i].name));
    DS795ImageCount = i + 1;
    (void)slide;
}
static const DS795Image *DS795Find(uintptr_t a) {
    int n = DS795ImageCount;
    for (int i = 0; i < n; i++) if (a >= DS795Images[i].base && a < DS795Images[i].end) return &DS795Images[i];
    return NULL;
}

static const char *kDSCrashLogCPath = "/var/mobile/Library/Preferences/com.recreated.dynamicstage.crash.log";
static const char *kDSStageLogCPath = "/var/mobile/Library/Preferences/com.recreated.dynamicstage.log";
static const char *kDSSessionCPath = "/var/mobile/Library/Preferences/com.recreated.dynamicstage.session";

static const int kDSCrashSignals[] = { SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE };
static const int kDSCrashSignalCount = 6;
static struct sigaction DSPreviousSignals[6];
static volatile sig_atomic_t DSCrashAlreadyWritten = 0;
static volatile sig_atomic_t DSInsideCrashHandler = 0;
static NSUncaughtExceptionHandler *DSPreviousExceptionHandler = NULL;

// ---- 4.5.754 latch754: how did the last SpringBoard end? ----------------------
// A crash (signal / uncaught exception) writes "crash"; a deliberate respring,
// ldrestart or userspace reboot (SIGTERM) writes "clean <seconds it ran>". The
// next start reads it (DSLatch754BootSweep) so a crash latch is only set on a
// real crash. Async-signal-safe: open / write / close only.
static const char *kDSExit754Path = "/var/mobile/.dynamicstage-exit754";
static volatile sig_atomic_t DS754Armed = 0;
static time_t DS754StartedAt = 0;
static struct sigaction DS754PreviousTerm;

static void DS754WriteExit(const char *a, unsigned long long n, int withNumber) {
    int fd = open(kDSExit754Path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    size_t l = 0; while (a[l]) l++;
    ssize_t ignored = write(fd, a, l); (void)ignored;
    if (withNumber) {
        char buffer[32]; int index = (int)sizeof(buffer); buffer[--index] = 0;
        if (n == 0) buffer[--index] = '0';
        while (n > 0 && index > 0) { buffer[--index] = (char)('0' + n % 10); n /= 10; }
        const char *t = &buffer[index]; size_t tl = 0; while (t[tl]) tl++;
        ignored = write(fd, " ", 1); ignored = write(fd, t, tl);
    }
    ignored = write(fd, "\n", 1);
    close(fd);
}

#define DS_RING_SLOTS 32
#define DS_RING_LINE 600   // 4.5.798: was 180 (crash lines were cut)
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
    if (DS795Safe ? (DS795Log793 && DS795Core793) :
        (access("/var/mobile/.dynamicstage-log793-off", F_OK) != 0 &&
         access("/var/mobile/.dynamicstage-core793-off", F_OK) != 0)) {
        DSAppend(fd, "last step (log793): ");
        DSAppend(fd, DSCrumb793[0] ? DSCrumb793 : "(none)");
        DSAppend(fd, "\npc: "); DSAppendHex(fd, DS793PC);
        DSAppend(fd, "\nlr: "); DSAppendHex(fd, DS793LR);
        if (DS795Safe) {
            if (DS795SelfBase) { DSAppend(fd, "\nDynamicStage base: "); DSAppendHex(fd, DS795SelfBase); }
        } else {
        Dl_info me; memset(&me, 0, sizeof(me));
        if (dladdr((void *)&DSCrash793Crumb, &me) && me.dli_fbase) {
            DSAppend(fd, "\nDynamicStage base: "); DSAppendHex(fd, (uintptr_t)me.dli_fbase);
        }
        }
        DSAppend(fd, "\n");
    }
    DSAppend(fd, "backtrace:\n");
    void *frame = __builtin_frame_address(0);
    for (int index = 0; index < 16 && frame; index++) {
        void **record = (void **)frame;
        void *caller = record[1];
        DSAppend(fd, "  ");
        DSAppendHex(fd, (uintptr_t)caller);
        // 4.5.793 log793: image + offset (PAC bits stripped).
        if (DS795Safe) {
            uintptr_t raw = (uintptr_t)caller & 0x0000000FFFFFFFFFULL;
            const DS795Image *im = DS795Log793 ? DS795Find(raw) : NULL;
            if (im) { DSAppend(fd, " "); DSAppend(fd, im->name); DSAppend(fd, "+"); DSAppendHex(fd, raw - im->base); }
        } else if (access("/var/mobile/.dynamicstage-log793-off", F_OK) != 0) {
            Dl_info fi; memset(&fi, 0, sizeof(fi));
            uintptr_t raw = (uintptr_t)caller & 0x0000000FFFFFFFFFULL;
            if (dladdr((void *)raw, &fi) && fi.dli_fname) {
                const char *img = strrchr(fi.dli_fname, '/'); img = img ? img + 1 : fi.dli_fname;
                DSAppend(fd, " "); DSAppend(fd, img); DSAppend(fd, "+");
                DSAppendHex(fd, raw - (uintptr_t)fi.dli_fbase);
            }
        }
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
    if (context) {
        ucontext_t *uc = (ucontext_t *)context;
        if (uc->uc_mcontext) {
            DS793PC = (uintptr_t)__darwin_arm_thread_state64_get_pc(uc->uc_mcontext->__ss) & 0x0000000FFFFFFFFFULL;
            DS793LR = (uintptr_t)__darwin_arm_thread_state64_get_lr(uc->uc_mcontext->__ss) & 0x0000000FFFFFFFFFULL;
        }
    }
    if (DS754Armed) DS754WriteExit("crash signal", 0, 0);
    if (!DSCrashAlreadyWritten) {
        DSCrashAlreadyWritten = 1;
        DSWriteSignalCrash(sig);
    }
    DSFinishSignal(sig, info, context);
}

static void DSUncaughtException(NSException *exception) {
    if (DS754Armed) DS754WriteExit("crash exception", 0, 0);
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

static void DS754HandleTerm(int sig, siginfo_t *info, void *context) {
    if (DS754Armed) {
        time_t now = time(NULL);
        DS754WriteExit("clean", (unsigned long long)(now > DS754StartedAt ? now - DS754StartedAt : 0), 1);
    }
    struct sigaction previous = DS754PreviousTerm;
    if ((previous.sa_flags & SA_SIGINFO) && previous.sa_sigaction) { previous.sa_sigaction(sig, info, context); return; }
    if (previous.sa_handler == SIG_IGN) return;   // SpringBoard's own handling (dispatch source) carries on
    if (previous.sa_handler && previous.sa_handler != SIG_DFL) { previous.sa_handler(sig); return; }
    signal(sig, SIG_DFL);
    raise(sig);
}

// Off: /var/mobile/.dynamicstage-latch754-off or -core754-off (back to 753:
// no exit marker, every 15 s window latches as before). Crash latch latch754.
void DSCrashLog754Arm(void) {
    if (access("/var/mobile/.dynamicstage-core754-off", F_OK) == 0 ||
        access("/var/mobile/.dynamicstage-latch754-off", F_OK) == 0 ||
        access("/var/mobile/.dynamicstage-latch754-crashed", F_OK) == 0) return;
    DS754StartedAt = time(NULL);
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = DS754HandleTerm;
    action.sa_flags = SA_SIGINFO;
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, &DS754PreviousTerm);
    DS754Armed = 1;
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
        // 4.5.795 sig795 (decided once, before any crash).
        BOOL off795 = access("/var/mobile/.dynamicstage-sig795-off", F_OK) == 0 ||
                      access("/var/mobile/.dynamicstage-core795-off", F_OK) == 0 ||
                      access("/var/mobile/.dynamicstage-sig795-crashed", F_OK) == 0;
        if (!off795) {
            DS795Log793 = access("/var/mobile/.dynamicstage-log793-off", F_OK) != 0;
            DS795Core793 = access("/var/mobile/.dynamicstage-core793-off", F_OK) != 0;
            Dl_info me; memset(&me, 0, sizeof(me));
            if (dladdr((void *)&DSCrash793Crumb, &me)) DS795SelfBase = (uintptr_t)me.dli_fbase;
            _dyld_register_func_for_add_image(DS795AddImage);
            DS795Safe = 1;
        }
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
