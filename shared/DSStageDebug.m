#include <sys/time.h>
#include <unistd.h>
#import "DSStageDebug.h"
#import <stdarg.h>
#import <stdatomic.h>
#import <unistd.h>
#import <fcntl.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#import <stdio.h>
#import <string.h>
#import <notify.h>
#import <sys/sysctl.h>
#import <execinfo.h>
#import <dlfcn.h>

void DSPerfNoteFileStat(void);

// ---- 4.5.697 switches (2 s cache, one access() per file) --------------------
static BOOL DSPerfFileCached(const char *plain, const char *jb, volatile CFAbsoluteTime *at, volatile BOOL *value) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    CFAbsoluteTime last = *at;
    if (now - last > 2.0 || now < last) {
        DSPerfNoteFileStat();
        BOOL present = access(plain, F_OK) == 0 || (jb && access(jb, F_OK) == 0);
        *value = present;
        *at = now;
    }
    return *value;
}

BOOL DSPerf697On(void) {
    static volatile CFAbsoluteTime at = 0;
    static volatile BOOL off = NO;
    return !DSPerfFileCached("/var/mobile/.dynamicstage-perf697-off", "/var/jb/var/mobile/.dynamicstage-perf697-off", &at, &off);
}

BOOL DSLogVerbose(void) {
    static volatile CFAbsoluteTime at = 0;
    static volatile BOOL on = NO;
    return DSPerfFileCached("/var/mobile/.dynamicstage-verbose", "/var/jb/var/mobile/.dynamicstage-verbose", &at, &on);
}

BOOL DSLogQuiet(void) {
    return DSPerf697On() && !DSLogVerbose();
}

// 4.5.713: group D kill switch. A plain cached access() (2 s), no crash-latch
// file, no switch table, nothing at load; read only on a trace write.
BOOL DSGroupD713On(void) {
    static volatile CFAbsoluteTime at = 0;
    static volatile BOOL off = NO;
    return !DSPerfFileCached("/var/mobile/.dynamicstage-groupd713-off", "/var/jb/var/mobile/.dynamicstage-groupd713-off", &at, &off);
}

BOOL DSPerfLogOn(void) {
    static volatile CFAbsoluteTime at = 0;
    static volatile BOOL on = NO;
    return DSPerfFileCached("/var/mobile/.dynamicstage-perf", "/var/jb/var/mobile/.dynamicstage-perf", &at, &on);
}

// ---- 4.5.698 switches + crash latches ----------------------------------------
// 4.5.736 latch736: the 4.5.734/735 crashes were all the app trace relay
// (removed in 736), but every feature that had acted in the 15 s before each
// crash was latched off with it (the log shows phonesize696-fit). Once, on the
// first start of 4.5.736, every -trying / -crashed latch file written since 734 was installed is cleared so
// those features come back. Real crashes on 736 latch them again as usual.
static void DSLatch736ClearOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            NSFileManager *fm = NSFileManager.defaultManager;
            NSString *marker = @"/var/mobile/.dynamicstage-latch738-cleared";
            if ([fm fileExistsAtPath:marker]) return;
            NSInteger cleared = 0;
            for (NSString *dir in @[ @"/var/mobile", @"/var/jb/var/mobile" ]) {
                NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:dir error:nil];
                for (NSString *n in names) {
                    if (![n hasPrefix:@".dynamicstage-"]) continue;
                    if (![n hasSuffix:@"-crashed"] && ![n hasSuffix:@"-trying"]) continue;
                    NSString *path = [dir stringByAppendingPathComponent:n];
                    // Only latches from the relay crashes (4.5.734 installed 09:40 NZDT
                    // on 10 Oct 2026, epoch 1791578400); older latches stay.
                    NSDate *m = [fm attributesOfItemAtPath:path error:nil].fileModificationDate;
                    if (!m || m.timeIntervalSince1970 < 1791578400.0) continue;
                    if ([fm removeItemAtPath:path error:nil]) cleared++;
                }
            }
            [@"4.5.738" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSLog(@"[DynamicStage] latch736 cleared %ld stale crash latch file(s) from the relay crashes", (long)cleared);
        } @catch (NSException *exception) {
        }
    });
}

// ---- 4.5.754 latch754: latch only on a real crash --------------------------------
// Before 754 a feature was latched off whenever SpringBoard went down within
// 15 s of its use, which includes every deliberate respring and ldrestart.
// Now, once per start and before any latch check, the way the last SpringBoard
// ended decides (DSCrashLog754Arm writes it):
//   crash   = our signal / exception handler fired, a SpringBoard crash report
//             (.ips: crash, watchdog) is newer than the last start, or the boot
//             guard started safe mode  -> -trying files become -crashed (as before)
//   clean   = SIGTERM (respring, ldrestart, reboot) -> -trying files are dropped,
//             and if that session ran >= 60 s every -crashed latch is cleared
//   unknown = no marker, no report -> -trying files are dropped, latches kept
// First 754 start: the 13 latches set by the old rule are cleared once (audit).
// Off: latch754-off / core754-off = 753 behaviour. Crash latch latch754.
NSString *DSLatch754Summary = nil;

static BOOL DS754FileOff(const char *name) {
    char p[160]; snprintf(p, sizeof(p), "/var/mobile/.dynamicstage-%s-off", name);
    char j[180]; snprintf(j, sizeof(j), "/var/jb/var/mobile/.dynamicstage-%s-off", name);
    return access(p, F_OK) == 0 || access(j, F_OK) == 0;
}

void DSLatch754NoteSafeMode(void) {
    if (DS754FileOff("core754") || DS754FileOff("latch754")) return;
    if (![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) return;
    // Keep a crash marker already written; otherwise record the safe-mode start.
    NSString *was = [NSString stringWithContentsOfFile:@"/var/mobile/.dynamicstage-exit754" encoding:NSUTF8StringEncoding error:nil];
    if ([was hasPrefix:@"crash"]) return;
    [@"crash safe-mode\n" writeToFile:@"/var/mobile/.dynamicstage-exit754" atomically:NO encoding:NSUTF8StringEncoding error:nil];
}

void DSLatch754BootSweep(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (DS754FileOff("core754") || DS754FileOff("latch754")) return;
        // SpringBoard only: app processes (the app dylib) never sweep.
        if (![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) return;
        @try {
            NSFileManager *fm = NSFileManager.defaultManager;
            NSString *exitPath = @"/var/mobile/.dynamicstage-exit754";
            NSString *startPath = @"/var/mobile/.dynamicstage-start754";
            NSString *exitText = [[NSString stringWithContentsOfFile:exitPath encoding:NSUTF8StringEncoding error:nil]
                                  stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
            NSDate *exitAt = [fm attributesOfItemAtPath:exitPath error:nil].fileModificationDate;
            NSDate *lastStart = [fm attributesOfItemAtPath:startPath error:nil].fileModificationDate;
            NSString *kind = @"unknown";
            NSString *evidence = @"no exit marker";
            if ([exitText hasPrefix:@"crash"]) { kind = @"crash"; evidence = exitText; }
            // A SpringBoard crash / watchdog report newer than the last start wins.
            if (lastStart) {
                for (NSString *n in [fm contentsOfDirectoryAtPath:@"/var/mobile/Library/Logs/CrashReporter" error:nil] ?: @[]) {
                    if (![n hasPrefix:@"SpringBoard"] || ![n hasSuffix:@".ips"]) continue;
                    NSDate *m = [fm attributesOfItemAtPath:[@"/var/mobile/Library/Logs/CrashReporter" stringByAppendingPathComponent:n] error:nil].fileModificationDate;
                    if (m && [m compare:lastStart] == NSOrderedDescending) { kind = @"crash"; evidence = n; break; }
                }
            }
            NSInteger ran = 0;
            if (![kind isEqualToString:@"crash"] && [exitText hasPrefix:@"clean"] && exitAt && -exitAt.timeIntervalSinceNow < 600.0) {
                kind = @"clean";
                ran = [[exitText substringFromIndex:MIN((NSUInteger)6, exitText.length)] integerValue];
                evidence = [NSString stringWithFormat:@"SIGTERM after %ld s", (long)ran];
            }
            // 4.5.756 beat756: a respring that kills SpringBoard outright (no
            // SIGTERM, 755 log: "unknown (no exit marker)") leaves the last
            // heartbeat; with no newer crash report that is a clean end.
            if (![kind isEqualToString:@"crash"] && [exitText hasPrefix:@"alive"] && exitAt && -exitAt.timeIntervalSinceNow < 600.0 &&
                !DS754FileOff("core756") && !DS754FileOff("beat756")) {
                kind = @"clean";
                ran = [[exitText substringFromIndex:MIN((NSUInteger)6, exitText.length)] integerValue];
                evidence = [NSString stringWithFormat:@"killed without SIGTERM after about %ld s (beat756 heartbeat, no crash report)", (long)ran];
            }
            NSMutableArray<NSString *> *dropped = [NSMutableArray array], *cleared = [NSMutableArray array];
            BOOL migrate = ![fm fileExistsAtPath:@"/var/mobile/.dynamicstage-latch754-migrated"];
            NSSet *audit = [NSSet setWithArray:@[ @"kb723", @"outside726", @"kb720", @"kbmin702", @"anim698", @"anim702", @"slide728",
                                                 @"sync725", @"restore726", @"focus705", @"beeper707", @"phonesize696-keys", @"phonesize696-blackout" ]];
            // 4.5.798 one798: a crash latches only the feature tried last (newest
            // -trying marker). Older markers are dropped, so one crash no longer
            // latches off every feature used in the 15 s before it (797 log 19:26:54:
            // 9 features). Off: one798-off or core798-off (back to 797: all latch).
            NSString *newestTry = nil;
            if ([kind isEqualToString:@"crash"] && !DS754FileOff("core798") && !DS754FileOff("one798")) {
                NSDate *newestAt = nil;
                for (NSString *dir in @[ @"/var/mobile", @"/var/jb/var/mobile" ]) {
                    for (NSString *n in [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[]) {
                        if (![n hasPrefix:@".dynamicstage-"] || ![n hasSuffix:@"-trying"]) continue;
                        NSString *p = [dir stringByAppendingPathComponent:n];
                        NSDate *m = [fm attributesOfItemAtPath:p error:nil].fileModificationDate;
                        if (m && (!newestAt || [m compare:newestAt] == NSOrderedDescending)) { newestAt = m; newestTry = p; }
                    }
                }
            }
            for (NSString *dir in @[ @"/var/mobile", @"/var/jb/var/mobile" ]) {
                for (NSString *n in [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[]) {
                    if (![n hasPrefix:@".dynamicstage-"]) continue;
                    NSString *path = [dir stringByAppendingPathComponent:n];
                    if (newestTry && [n hasSuffix:@"-trying"] && ![path isEqualToString:newestTry]) {
                        NSString *core0 = [n substringFromIndex:14];
                        if ([fm removeItemAtPath:path error:nil]) [dropped addObject:[[core0 substringToIndex:core0.length - 7] stringByAppendingString:@" (older than the last one tried, one798)"]];
                        continue;
                    }
                    NSString *core = [n substringFromIndex:14];
                    if ([n hasSuffix:@"-trying"] && ![kind isEqualToString:@"crash"]) {
                        if ([fm removeItemAtPath:path error:nil]) [dropped addObject:[core substringToIndex:core.length - 7]];
                    } else if ([n hasSuffix:@"-crashed"]) {
                        NSString *feature = [core substringToIndex:core.length - 8];
                        BOOL clear = ([kind isEqualToString:@"clean"] && ran >= 60) || (migrate && [audit containsObject:feature]);
                        if (clear && [fm removeItemAtPath:path error:nil]) [cleared addObject:feature];
                    }
                }
            }
            if (migrate) [@"4.5.754" writeToFile:@"/var/mobile/.dynamicstage-latch754-migrated" atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [fm removeItemAtPath:exitPath error:nil];
            [@"4.5.754" writeToFile:startPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
            DSLatch754Summary = [NSString stringWithFormat:@"latch754 last SpringBoard exit: %@ (%@); %lu unlatched try marker(s) dropped%@%@; %lu latch(es) cleared%@%@%@",
                                 kind, evidence, (unsigned long)dropped.count, dropped.count ? @": " : @"", [dropped componentsJoinedByString:@", "],
                                 (unsigned long)cleared.count, cleared.count ? @": " : @"", [cleared componentsJoinedByString:@", "],
                                 migrate ? @" (first 754 start: old-rule latches audited)" : @""];
            NSLog(@"[DynamicStage] %@", DSLatch754Summary);
        } @catch (NSException *exception) {
        }
    });
}

static BOOL DSLatch698Crashed(const char *name) {
    // Checked once per SpringBoard start (main thread at first use).
    DSLatch736ClearOnce();
    DSLatch754BootSweep();   // 4.5.754: the sweep always runs before the first latch check
    char trying[160], crashed[160], jbCrashed[180];
    snprintf(trying, sizeof(trying), "/var/mobile/.dynamicstage-%s-trying", name);
    snprintf(crashed, sizeof(crashed), "/var/mobile/.dynamicstage-%s-crashed", name);
    snprintf(jbCrashed, sizeof(jbCrashed), "/var/jb/var/mobile/.dynamicstage-%s-crashed", name);
    if (access(trying, F_OK) == 0) {
        unlink(trying);
        FILE *f = fopen(crashed, "w");
        if (f) fclose(f);
        NSLog(@"[DynamicStage] %s LATCHED OFF: SpringBoard went down within 15 s of its first use. Delete %s to allow it again.", name, crashed);
    }
    return access(crashed, F_OK) == 0 || access(jbCrashed, F_OK) == 0;
}

static void DSLatch698MarkTrying(const char *name, volatile BOOL *marked) {
    if (*marked) return;
    *marked = YES;
    char trying[160];
    snprintf(trying, sizeof(trying), "/var/mobile/.dynamicstage-%s-trying", name);
    FILE *f = fopen(trying, "w");
    if (f) fclose(f);
    NSString *path = [NSString stringWithUTF8String:trying];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        unlink(path.fileSystemRepresentation);
    });
}

BOOL DSAnim698On(void) {
    static volatile CFAbsoluteTime at = 0;
    static volatile BOOL off = NO;
    static int latchChecked = 0;
    static BOOL latched = NO;
    if (!latchChecked) { latchChecked = 1; latched = DSLatch698Crashed("anim698"); }
    if (latched) return NO;
    return !DSPerfFileCached("/var/mobile/.dynamicstage-anim698-off", "/var/jb/var/mobile/.dynamicstage-anim698-off", &at, &off);
}

BOOL DSPerf698On(void) {
    static volatile CFAbsoluteTime at = 0;
    static volatile BOOL off = NO;
    static int latchChecked = 0;
    static BOOL latched = NO;
    if (!latchChecked) { latchChecked = 1; latched = DSLatch698Crashed("perf698"); }
    if (latched) return NO;
    return !DSPerfFileCached("/var/mobile/.dynamicstage-perf698-off", "/var/jb/var/mobile/.dynamicstage-perf698-off", &at, &off);
}

void DSAnim698MarkTrying(void) {
    static volatile BOOL marked = NO;
    DSLatch698MarkTrying("anim698", &marked);
}

void DSPerf698MarkTrying(void) {
    static volatile BOOL marked = NO;
    DSLatch698MarkTrying("perf698", &marked);
}

// ---- 4.5.699 generic switches (names: crash699, blackout699, spam700, heal700) -----------------
// 4.5.738 audit: 44 names are in use. With 32 slots, every name registered
// after the 32nd got index -1, so DSFeature699On returned NO: those features
// were silently off (which ones depended on the order they were first used).
// 4.5.794 table794: 4.5.793 used 178 names in SpringBoard against 128 slots, so
// every name first asked for after the 128th (log793, core79x ...) was silently
// off. Rule: every switch name gets a slot. table794-off / core794-off (or a
// table794 crash latch) cap the table at 128 again, as in 4.5.793.
#define DS699_MAX 512
#define DS699_OLD_MAX 128
static volatile BOOL DS794TableMarked = NO;
static volatile BOOL DS794Overflow = NO;
static int DS794Cap(void) {
    static int cap = 0;
    if (cap) return cap;
    BOOL off = access("/var/mobile/.dynamicstage-table794-off", F_OK) == 0 ||
               access("/var/jb/var/mobile/.dynamicstage-table794-off", F_OK) == 0 ||
               access("/var/mobile/.dynamicstage-core794-off", F_OK) == 0 ||
               access("/var/jb/var/mobile/.dynamicstage-core794-off", F_OK) == 0;
    cap = off ? DS699_OLD_MAX : DS699_MAX;
    return cap;
}
static const char *DS699Names[DS699_MAX];
static volatile CFAbsoluteTime DS699At[DS699_MAX];
static volatile BOOL DS699Off[DS699_MAX];
static int DS699Latched[DS699_MAX];   // 0 unknown, 1 no, 2 latched
static volatile BOOL DS699Marked[DS699_MAX];

// 4.5.704 sweep704: the stall watchdog (global queue) and the app-trace relay
// (its own queue) ask for battery701 while the main thread registers the other
// names; the table and the one-time latch check are now under a lock.
static os_unfair_lock DS699Lock = OS_UNFAIR_LOCK_INIT;

static int DS699Index(const char *name) {
    if (!name) return -1;
    int found = -1;
    os_unfair_lock_lock(&DS699Lock);
    for (int i = 0; i < DS699_MAX; i++) {
        if (DS699Names[i] && strcmp(DS699Names[i], name) == 0) { found = i; break; }
    }
    int cap = DS699_MAX;
    BOOL grew = NO;
    if (found < 0) {
        for (int i = 0; i < DS699_MAX; i++) {
            if (!DS699Names[i]) {
                if (i >= DS699_OLD_MAX) { grew = YES; cap = -1; }
                else { DS699Names[i] = name; found = i; }
                break;
            }
        }
    }
    os_unfair_lock_unlock(&DS699Lock);
    if (grew) {
        // Outside the lock: the cap and latch touch files.
        static volatile int latch794 = 0;   // 0 unknown, 1 ok, 2 latched
        if (latch794 == 0) latch794 = (DS794Cap() == DS699_MAX && !DSLatch698Crashed("table794")) ? 1 : 2;
        cap = latch794 == 1 ? DS699_MAX : DS699_OLD_MAX;
        os_unfair_lock_lock(&DS699Lock);
        for (int i = 0; i < DS699_MAX; i++) {
            if (DS699Names[i] && strcmp(DS699Names[i], name) == 0) { found = i; break; }
        }
        if (found < 0 && cap == DS699_MAX) {
            for (int i = 0; i < DS699_MAX; i++) {
                if (!DS699Names[i]) { DS699Names[i] = name; found = i; break; }
            }
        }
        os_unfair_lock_unlock(&DS699Lock);
        if (found >= 0) DSLatch698MarkTrying("table794", &DS794TableMarked);
    }
    if (found < 0 && !DS794Overflow) {
        DS794Overflow = YES;
        NSLog(@"[DynamicStage] table794: switch table full (cap %d), \"%s\" and later names are off", cap, name);
    }
    return found;
}

// ---- 4.5.796 switch796: grouped switches ---------------------------------------
// Rule: a handful of group files cover every feature switch.
//   core796-off  undoes 796's own changes (groups, verbose gate, poll sleep).
//   kb-off       every keyboard feature (kb*, keys*, reopen*, strip*, caret*,
//                swipe*, return*, backspace*, keyfocus*, rekey*, lift*, ...)
//   holds-on     brings back 794's held / replayed SpringBoard updates
//                (pass795 off); holds are off by default.
//   keyring-off  keys go back to the 794 file (keyring795 off)
//   verbose-on   turns on the log-only probes (log792 / strip792 window,
//                trace766, tree765-767, scene773, msgdiag714)
//   phonesize-off  the phone-size scene path (= phonesize675-off)
// The old per-name -off files still work; the old coreNNN-off masters for
// NNN < 796 are retired (the previous .deb is the rollback).
static BOOL DS796File(const char *name, volatile CFAbsoluteTime *at, volatile BOOL *val);
BOOL DS796CoreOn(void) {
    static volatile CFAbsoluteTime at = 0; static volatile BOOL off = NO;
    return !DS796File("core796-off", &at, &off);
}
static BOOL DS796File(const char *name, volatile CFAbsoluteTime *at, volatile BOOL *val) {
    char plain[160], jb[180];
    snprintf(plain, sizeof(plain), "/var/mobile/.dynamicstage-%s", name);
    snprintf(jb, sizeof(jb), "/var/jb/var/mobile/.dynamicstage-%s", name);
    return DSPerfFileCached(plain, jb, at, val);
}
static BOOL DS796Stem(const char *name, const char *const *stems) {
    for (int k = 0; stems[k]; k++) {
        size_t n = strlen(stems[k]);
        if (strncmp(name, stems[k], n) == 0 && (name[n] == 0 || (name[n] >= '0' && name[n] <= '9'))) return YES;
    }
    return NO;
}
// Returns 1 forced on, 0 forced off, -1 no opinion.
static int DS796Group(const char *name) {
    if (strncmp(name, "core", 4) == 0 && name[4] >= '0' && name[4] <= '9') {
        if (strcmp(name, "core796") == 0) return -1;
        if (strcmp(name, "core797") == 0) return -1;
        if (strcmp(name, "core798") == 0) return -1;
        if (strcmp(name, "core799") == 0) return -1;
        if (strcmp(name, "core800") == 0) return -1;
        // 4.5.802: core801 was missing here, so core801-off was forced on and
        // did nothing. core801 / core802 are live masters again.
        if (strcmp(name, "core801") == 0) return -1;
        if (strcmp(name, "core802") == 0) return -1;
        if (strcmp(name, "core803") == 0) return -1;
        if (strcmp(name, "core804") == 0) return -1;
        if (strcmp(name, "core805") == 0) return -1;
        if (strcmp(name, "core806") == 0) return -1;
        if (strcmp(name, "core807") == 0) return -1;
        return DS796CoreOn() ? 1 : -1;   // retired masters (unless core796-off)
    }
    if (!DS796CoreOn()) return -1;
    static const char *const kb[] = { "kb", "keys", "reopen", "strip", "caret", "swipe", "return", "backspace",
        "keyfocus", "rekey", "kbshow", "kbhide", "kbnan", "kbown", "kbmin", "kbdrag", "kbguard", "sbkb",
        "keep", "ghost", "type", "leave", "entry", "resign", "flicker", "msgfit", "ks", "lift", "src", NULL };
    static const char *const verbose[] = { "log792", "trace766", "tree765", "tree766", "tree767", "scene773", "msgdiag714", NULL };
    static volatile CFAbsoluteTime kbAt = 0, vAt = 0, hAt = 0, rAt = 0;
    static volatile BOOL kbOff = NO, vOn = NO, hOn = NO, rOff = NO;
    if (strcmp(name, "pass795") == 0) return DS796File("holds-on", &hAt, &hOn) ? 0 : -1;
    if (strcmp(name, "keyring795") == 0) return DS796File("keyring-off", &rAt, &rOff) ? 0 : -1;
    BOOL isVerbose = NO;
    for (int k = 0; verbose[k]; k++) if (strcmp(name, verbose[k]) == 0) isVerbose = YES;
    if (isVerbose) return DS796File("verbose-on", &vAt, &vOn) ? -1 : 0;
    if (DS796Stem(name, kb)) return DS796File("kb-off", &kbAt, &kbOff) ? 0 : -1;
    return -1;
}

BOOL DSFeature699On(const char *name) {
    if (!name) return NO;
    int g796 = DS796Group(name);
    if (g796 == 0) return NO;
    if (g796 == 1) return YES;
    int i = DS699Index(name);
    if (i < 0) return NO;
    if (DS699Latched[i] == 0) {
        // The latch check touches files: decide it once, outside the lock.
        int latched = DSLatch698Crashed(name) ? 2 : 1;
        os_unfair_lock_lock(&DS699Lock);
        if (DS699Latched[i] == 0) DS699Latched[i] = latched;
        os_unfair_lock_unlock(&DS699Lock);
    }
    if (DS699Latched[i] == 2) return NO;
    char plain[160], jb[180];
    snprintf(plain, sizeof(plain), "/var/mobile/.dynamicstage-%s-off", name);
    snprintf(jb, sizeof(jb), "/var/jb/var/mobile/.dynamicstage-%s-off", name);
    return !DSPerfFileCached(plain, jb, &DS699At[i], &DS699Off[i]);
}

// 4.5.766: master core766-off returns every 766 change to 4.5.765.
BOOL DS766On(const char *name) {
    return DSFeature699On("core766") && DSFeature699On(name);
}

// 4.5.767: master core767-off returns every 767 change to 4.5.766.
BOOL DS767On(const char *name) {
    return DSFeature699On("core767") && DSFeature699On(name);
}

// 4.5.769: master core769-off returns every 769 change to 4.5.768.
BOOL DS769On(const char *name) {
    return DSFeature699On("core769") && DSFeature699On(name);
}

// 4.5.715: the crash latch alone (no off file read). Decided once per start,
// the same way and in the same table slot as DSFeature699On.
BOOL DSFeature699Latched(const char *name) {
    int i = DS699Index(name);
    if (i < 0) return NO;
    if (DS699Latched[i] == 0) {
        int latched = DSLatch698Crashed(name) ? 2 : 1;
        os_unfair_lock_lock(&DS699Lock);
        if (DS699Latched[i] == 0) DS699Latched[i] = latched;
        os_unfair_lock_unlock(&DS699Lock);
    }
    return DS699Latched[i] == 2;
}

void DSFeature699MarkTrying(const char *name) {
    int i = DS699Index(name);
    if (i < 0) return;
    DSLatch698MarkTrying(name, &DS699Marked[i]);
}

// ---- 4.5.719 per-action latch + process uptime --------------------------------
static volatile unsigned long DS719ActionGen[DS699_MAX];

void DSFeature719MarkAction(const char *name) {
    int i = DS699Index(name);
    if (i < 0) return;
    char trying[160];
    snprintf(trying, sizeof(trying), "/var/mobile/.dynamicstage-%s-trying", name);
    // 4.5.738 audit: one file create per action could run every frame (main
    // thread disk I/O). The marker is rewritten at most every 2 s; the 15 s
    // removal below still waits for the latest action.
    static CFAbsoluteTime written[DS699_MAX];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - written[i] > 2.0 || now < written[i]) {
        written[i] = now;
        FILE *f = fopen(trying, "w");
        if (f) fclose(f);
    }
    unsigned long gen = __atomic_add_fetch(&DS719ActionGen[i], 1, __ATOMIC_SEQ_CST);
    NSString *path = [NSString stringWithUTF8String:trying];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Main queue on purpose: a main thread stuck in the action keeps the
        // marker (a watchdog kill then still latches the feature off).
        if (__atomic_load_n(&DS719ActionGen[i], __ATOMIC_SEQ_CST) != gen) return;
        unlink(path.fileSystemRepresentation);
    });
}

NSTimeInterval DSProcessUptime719(void) {
    static NSTimeInterval started = 0;
    if (started <= 0) {
        struct kinfo_proc info;
        size_t size = sizeof(info);
        int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
        memset(&info, 0, sizeof(info));
        if (sysctl(mib, 4, &info, &size, NULL, 0) == 0 && info.kp_proc.p_starttime.tv_sec > 0) {
            started = (NSTimeInterval)info.kp_proc.p_starttime.tv_sec + info.kp_proc.p_starttime.tv_usec / 1e6;
        } else {
            return 1e9; // unknown: treat startup as long over
        }
    }
    return [[NSDate date] timeIntervalSince1970] - started;
}

static os_unfair_lock DSPerfAnimLock = OS_UNFAIR_LOCK_INIT;
static unsigned long DSPerfAnimCount = 0, DSPerfAnimFrames = 0, DSPerfAnimSlow = 0;
static double DSPerfAnimMs = 0, DSPerfAnimMaxGap = 0, DSPerfAnimLastMs = 0;
static char DSPerfAnimLastName[48];

void DSPerfNoteAnimation(const char *name, double ms, unsigned long frames, unsigned long slow, double maxGapMs) {
    if (!DSPerfLogOn()) return;
    os_unfair_lock_lock(&DSPerfAnimLock);
    DSPerfAnimCount += 1;
    DSPerfAnimFrames += frames;
    DSPerfAnimSlow += slow;
    DSPerfAnimMs += ms;
    DSPerfAnimLastMs = ms;
    if (maxGapMs > DSPerfAnimMaxGap) DSPerfAnimMaxGap = maxGapMs;
    snprintf(DSPerfAnimLastName, sizeof(DSPerfAnimLastName), "%s", name ?: "?");
    os_unfair_lock_unlock(&DSPerfAnimLock);
}

static NSString *DSPerfAnimSummaryAndReset(void) {
    os_unfair_lock_lock(&DSPerfAnimLock);
    NSString *text = nil;
    if (DSPerfAnimCount > 0) {
        text = [NSString stringWithFormat:@" | anims %lu (last %s %.0fms), frames %lu, slow frames %lu, worst frame gap %.1fms",
                DSPerfAnimCount, DSPerfAnimLastName, DSPerfAnimLastMs, DSPerfAnimFrames, DSPerfAnimSlow, DSPerfAnimMaxGap];
    }
    DSPerfAnimCount = DSPerfAnimFrames = DSPerfAnimSlow = 0;
    DSPerfAnimMs = DSPerfAnimMaxGap = DSPerfAnimLastMs = 0;
    os_unfair_lock_unlock(&DSPerfAnimLock);
    return text;
}

static _Atomic uint64_t DSPerfNanos[DSPerfBucketCount];
static _Atomic uint64_t DSPerfMaxNanos[DSPerfBucketCount];
static _Atomic uint64_t DSPerfCalls[DSPerfBucketCount];
static _Atomic uint64_t DSPerfCounters[DSPerfCounterCount];
static CFAbsoluteTime DSPerfWindowStart = 0;
static _Atomic uint64_t DSPerfFileStats705 = 0;
static NSString *(*DSPerfGaugeProvider705)(void) = NULL;

void DSPerfNoteFileStat(void) {
    // Unconditional: DSPerfLogOn itself goes through the cached switch reader.
    atomic_fetch_add(&DSPerfFileStats705, 1);
}

void DSPerfSetGaugeProvider(NSString *(*provider)(void)) {
    DSPerfGaugeProvider705 = provider;
}

static uint64_t DSPerfToNanos(uint64_t ticks) {
    static mach_timebase_info_data_t base;
    if (base.denom == 0) mach_timebase_info(&base);
    return base.denom ? ticks * base.numer / base.denom : ticks;
}

uint64_t DSPerfNow(void) {
    if (!DSPerfLogOn()) return 0;
    uint64_t now = mach_absolute_time();
    return now ? now : 1;
}

void DSPerfAdd(DSPerfBucket bucket, uint64_t start) {
    if (start == 0 || bucket < 0 || bucket >= DSPerfBucketCount) return;
    uint64_t ns = DSPerfToNanos(mach_absolute_time() - start);
    atomic_fetch_add(&DSPerfNanos[bucket], ns);
    atomic_fetch_add(&DSPerfCalls[bucket], 1);
    uint64_t max = atomic_load(&DSPerfMaxNanos[bucket]);
    while (ns > max && !atomic_compare_exchange_weak(&DSPerfMaxNanos[bucket], &max, ns)) {
    }
}

void DSPerfCount(DSPerfCounter counter) {
    if (counter < 0 || counter >= DSPerfCounterCount) return;
    if (!DSPerfLogOn()) return;
    atomic_fetch_add(&DSPerfCounters[counter], 1);
}

NSString *DSPerfSummaryAndReset(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (DSPerfWindowStart == 0) {
        DSPerfWindowStart = now;
        return nil;
    }
    double seconds = now - DSPerfWindowStart;
    DSPerfWindowStart = now;
    static const char *names[DSPerfBucketCount] = { "drag", "cardLayout", "hostLayout", "keyboard", "sceneHook" };
    NSMutableString *line = [NSMutableString stringWithFormat:@"perf697 %.1fs main-thread time in our code:", seconds];
    uint64_t total = 0;
    for (NSInteger i = 0; i < DSPerfBucketCount; i++) {
        uint64_t ns = atomic_exchange(&DSPerfNanos[i], 0);
        uint64_t calls = atomic_exchange(&DSPerfCalls[i], 0);
        uint64_t max = atomic_exchange(&DSPerfMaxNanos[i], 0);
        total += ns;
        [line appendFormat:@" %s=%.1fms/%llu (max %.2fms)", names[i], ns / 1.0e6, calls, max / 1.0e6];
    }
    uint64_t writes = atomic_exchange(&DSPerfCounters[DSPerfCounterSceneWrites], 0);
    uint64_t lines = atomic_exchange(&DSPerfCounters[DSPerfCounterLogLines], 0);
    uint64_t dropped = atomic_exchange(&DSPerfCounters[DSPerfCounterLogDropped], 0);
    uint64_t traces = atomic_exchange(&DSPerfCounters[DSPerfCounterTraceWrites], 0);
    uint64_t frames = atomic_exchange(&DSPerfCounters[DSPerfCounterDragFrames], 0);
    [line appendFormat:@" | total %.1fms (%.1f%% of the main thread) | scene writes %llu, log lines %llu (+%llu quiet/dropped), trace writes %llu, drag frames %llu | %@%@",
     total / 1.0e6, seconds > 0 ? (total / 1.0e7) / seconds : 0.0, writes, lines, dropped, traces, frames,
     DSPerf697On() ? @"perf697 on" : @"perf697 OFF (696 paths)", DSLogVerbose() ? @", verbose log" : @", quiet log"];
    // 4.5.698: switches + minimise animation timing.
    [line appendFormat:@", %@, %@", DSPerf698On() ? @"perf698 on" : @"perf698 OFF", DSAnim698On() ? @"anim698 on" : @"anim698 OFF"];
    NSString *anims = DSPerfAnimSummaryAndReset();
    if (anims) [line appendString:anims];
    // 4.5.705 perf705: per-second rates of the per-card work.
    {
        static const DSPerfCounter ids[] = { DSPerfCounterClipPasses, DSPerfCounterClipWalks, DSPerfCounterMaskRebuilds,
            DSPerfCounterShadowUpdates, DSPerfCounterRimLayouts, DSPerfCounterRoundPasses, DSPerfCounterKeyboardNotes,
            DSPerfCounterFocusEvals, DSPerfCounterFocusMoves, DSPerfCounterSearchHideHeld, DSPerfCounterHealRelayouts,
            DSPerfCounterTicks, DSPerfCounterBlurToggles, DSPerfCounterDragSkips, DSPerfCounterTraceFlushes,
            DSPerfCounterSettles, DSPerfCounterSlowTicks };
        static const char *labels[] = { "clip", "clipWalk", "maskRebuild", "shadow", "rim", "roundHost", "kbNote",
            "focusEval", "focusMove", "searchHideHeld", "heal", "tick", "blurToggle", "dragSkip", "traceFlush",
            "settle706", "slowTick" };
        double secs = seconds > 0.01 ? seconds : 1.0;
        uint64_t stats = atomic_exchange(&DSPerfFileStats705, 0);
        [line appendFormat:@" | perf705/s: sceneWrites %.1f, logs %.1f, traceLines %.1f, fileStats %.1f", writes / secs, lines / secs, traces / secs, stats / secs];
        for (size_t i = 0; i < sizeof(ids) / sizeof(ids[0]); i++) {
            uint64_t v = atomic_exchange(&DSPerfCounters[ids[i]], 0);
            [line appendFormat:@", %s %.1f", labels[i], v / secs];
        }
        // Layout calls per second come from the buckets above (calls / window).
        NSString *(*provider)(void) = DSPerfGaugeProvider705;
        if (provider) {
            NSString *gauge = nil;
            @try { gauge = provider(); } @catch (NSException *exception) { gauge = nil; }
            if (gauge.length) [line appendFormat:@" | %@", gauge];
        }
    }
    return line;
}

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
    // 4.5.697: the debug lines ([GEOM], [KEYS], [LIFT] ...) are only built
    // with /var/mobile/.dynamicstage-verbose (or the perf697 off file).
    if (DSLogQuiet()) {
        DSPerfCount(DSPerfCounterLogDropped);
        return;
    }
    va_list arguments;
    va_start(arguments, format);
    NSString *line = [[NSString alloc] initWithFormat:[NSString stringWithUTF8String:format] arguments:arguments];
    va_end(arguments);
    DSLogAppend(line);
}

// 4.5.745 log745: every log line is printable ASCII. A line that is mostly
// not ASCII is replaced by its length and first bytes in hex so its source can
// be found. Off: /var/mobile/.dynamicstage-log745-off
NSString *DSAscii745(NSString *line) {
    if (line.length == 0 || !DSFeature699On("log745")) return line;
    NSUInteger n = line.length, bad = 0;
    unichar *buf = malloc(sizeof(unichar) * n);
    if (!buf) return line;
    [line getCharacters:buf range:NSMakeRange(0, n)];
    for (NSUInteger i = 0; i < n; i++) {
        if (buf[i] < 0x20 || buf[i] > 0x7e) { buf[i] = '?'; bad++; }
    }
    NSString *out = nil;
    if (bad == 0) {
        out = line;
    } else if (bad * 2 > n) {
        NSMutableString *hex = [NSMutableString string];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
        const uint8_t *b = data.bytes;
        for (NSUInteger i = 0; i < MIN(data.length, (NSUInteger)24); i++) [hex appendFormat:@"%02x", b[i]];
        out = [NSString stringWithFormat:@"[log745 corrupt line len=%lu bytes=%@]", (unsigned long)n, hex];
        // 4.5.793 log793: name who logged it (DS+ = our image offset).
        if (DS793On("log793")) {
            void *a[10]; int c = backtrace(a, 10);
            NSMutableArray *f = [NSMutableArray array];
            for (int i = 1; i < c; i++) {
                Dl_info info; memset(&info, 0, sizeof(info));
                if (!dladdr(a[i], &info) || !info.dli_fname) continue;
                const char *img = strrchr(info.dli_fname, '/'); img = img ? img + 1 : info.dli_fname;
                [f addObject:[NSString stringWithFormat:@"%s+0x%lx", img, (unsigned long)((uintptr_t)a[i] - (uintptr_t)info.dli_fbase)]];
            }
            out = [out stringByAppendingFormat:@" by %@", [f componentsJoinedByString:@" < "]];
        }
    } else {
        out = [NSString stringWithCharacters:buf length:n];
    }
    free(buf);
    return out;
}

static BOOL DSLog697Exempt(NSString *line) {
    // 4.5.801: never drop focus / keyboard lines (Hdidbdh lost 76 during the
    // Messages stand-in fight). Matched as substrings, case-sensitive on our tags.
    if (line.length == 0) return NO;
    static NSArray<NSString *> *keys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[ @"[KEYS]", @"kbvis", @"why775", @"keep776", @"focus", @"stand-in",
                  @"keyboard", @"keyring", @"kbfocus", @"resign", @"takeKey", @"src746",
                  @"arbiter on", @"fg800", @"fg801", @"reason800", @"occl798",
                  @"medusa802", @"lift802", @"keep802", @"hide802" ];
    });
    for (NSString *k in keys) {
        if ([line rangeOfString:k].location != NSNotFound) return YES;
    }
    return NO;
}

void DSLogAppend(NSString *line) {
    if (line.length == 0) return;
    line = DSAscii745(line);
    DSPerfCount(DSPerfCounterLogLines);
    // 4.5.697: quiet log is rate limited; 4.5.801 raises the cap to 120/s and
    // exempts focus/keyboard lines so focus fights are not truncated.
    static CFAbsoluteTime windowStart = 0;
    static NSInteger windowCount = 0;
    static NSInteger dropped = 0;
    NSString *droppedNote = nil;
    if (DSLogQuiet()) {
        BOOL exempt = DSLog697Exempt(line);
        @synchronized (DSLogLock()) {
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - windowStart > 1.0 || now < windowStart) {
                windowStart = now;
                windowCount = 0;
                if (dropped > 0) droppedNote = [NSString stringWithFormat:@"(log697: %ld lines dropped by the rate limit)", (long)dropped];
                dropped = 0;
            }
            if (!exempt) {
                windowCount += 1;
                if (windowCount > 120) {
                    dropped += 1;
                    DSPerfCount(DSPerfCounterLogDropped);
                    return;
                }
            }
        }
    }
    @synchronized (DSLogLock()) {
        if (droppedNote) [DSLogBuffer appendFormat:@"%@\n", droppedNote];
        if (!DSLogBuffer) DSLogBuffer = [NSMutableString string];
        // 4.5.802 stamp802: local HH:mm:ss.SSS on every main log line.
        // Off: stamp802-off / core802-off.
        if (DS802On("stamp802")) {
            struct timeval tv; gettimeofday(&tv, NULL);
            struct tm tmv; time_t secs = tv.tv_sec; localtime_r(&secs, &tmv);
            [DSLogBuffer appendFormat:@"%02d:%02d:%02d.%03d %@\n", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, (int)(tv.tv_usec / 1000), line];
        } else {
            [DSLogBuffer appendFormat:@"%@\n", line];
        }
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

// ---- 4.5.701 battery701 ---------------------------------------------------------
BOOL DSBattery701On(void) {
    BOOL on = DSFeature699On("battery701");
    static volatile int published = 0;
    int want = on ? 1 : 2;
    if (published != want) {
        published = want;
        int token = NOTIFY_TOKEN_INVALID;
        if (notify_register_check(kDSBattery701Notify, &token) == NOTIFY_STATUS_OK) {
            notify_set_state(token, (uint64_t)want);
            notify_cancel(token);
            notify_post(kDSBattery701Notify);
        }
    }
    return on;
}

BOOL DSBattery701AppOn(void) {
    static int token = NOTIFY_TOKEN_INVALID;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_check(kDSBattery701Notify, &token);
    });
    if (token == NOTIFY_TOKEN_INVALID) return YES;
    uint64_t state = 0;
    if (notify_get_state(token, &state) != NOTIFY_STATUS_OK) return YES;
    return state != 2;
}

BOOL DSBattery701ScreenLocked(void) {
    static int token = NOTIFY_TOKEN_INVALID;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_check("com.apple.springboard.lockstate", &token);
    });
    if (token == NOTIFY_TOKEN_INVALID) return NO;
    uint64_t state = 0;
    if (notify_get_state(token, &state) != NOTIFY_STATUS_OK) return NO;
    return state != 0;
}

BOOL DSLogGate(NSString *slot, NSString *key, double interval, NSUInteger *skipped) {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static NSMutableDictionary<NSString *, NSMutableArray *> *slots = nil;
    NSString *slotKey = slot ?: @"?";
    NSString *lineKey = key ?: @"";
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL want = NO;
    NSUInteger held = 0;
    os_unfair_lock_lock(&lock);
    if (!slots) slots = [NSMutableDictionary dictionary];
    // [lastKey, lastAt, skipped]
    NSMutableArray *record = slots[slotKey];
    if (!record) {
        if (slots.count > 256) [slots removeAllObjects];
        record = [NSMutableArray arrayWithObjects:lineKey, @(now), @0, nil];
        slots[slotKey] = record;
        want = YES;
    } else {
        CFAbsoluteTime at = [record[1] doubleValue];
        if (![record[0] isEqualToString:lineKey] || now - at >= interval || now < at) {
            held = [record[2] unsignedIntegerValue];
            record[0] = lineKey;
            record[1] = @(now);
            record[2] = @0;
            want = YES;
        } else {
            record[2] = @([record[2] unsignedIntegerValue] + 1);
        }
    }
    os_unfair_lock_unlock(&lock);
    if (skipped) *skipped = held;
    return want;
}


// 4.5.756 beat756: SpringBoard writes "alive <seconds>" to the exit marker every
// 30 s (never over a crash marker). A SIGTERM still writes "clean", a crash
// "crash". Off: /var/mobile/.dynamicstage-beat756-off or -core756-off.
void DSBeat756Start(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (DS754FileOff("core754") || DS754FileOff("latch754") || DS754FileOff("core756") || DS754FileOff("beat756")) return;
        if (access("/var/mobile/.dynamicstage-beat756-crashed", F_OK) == 0) return;
        if (![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) return;
        static dispatch_source_t timer;
        time_t started = time(NULL);
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), 30 * NSEC_PER_SEC, 5 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, ^{
            @autoreleasepool {
                const char *path = "/var/mobile/.dynamicstage-exit754";
                char head[8] = {0};
                int fd = open(path, O_RDONLY);
                if (fd >= 0) { read(fd, head, 5); close(fd); }
                if (strncmp(head, "crash", 5) == 0 || strncmp(head, "clean", 5) == 0) return;
                char line[48];
                int n = snprintf(line, sizeof(line), "alive %ld\n", (long)(time(NULL) - started));
                fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
                if (fd >= 0) { write(fd, line, (size_t)n); close(fd); }
            }
        });
        dispatch_resume(timer);
    });
}

// 4.5.770: master core770-off returns to 769.
BOOL DS770On(const char *name) {
    return DSFeature699On("core770") && DSFeature699On(name);
}

// 4.5.771: master core771-off returns to 770.
BOOL DS771On(const char *name) {
    return DSFeature699On("core771") && DSFeature699On(name);
}

// 4.5.772: master core772-off returns to 771.
BOOL DS772On(const char *name) {
    return DSFeature699On("core772") && DSFeature699On(name);
}

// 4.5.773: master core773-off returns to 772.
BOOL DS773On(const char *name) {
    return DSFeature699On("core773") && DSFeature699On(name);
}

// 4.5.774: master core774-off returns to 773.
BOOL DS774On(const char *name) {
    return DSFeature699On("core774") && DSFeature699On(name);
}

// 4.5.775: master core775-off returns to 774.
BOOL DS775On(const char *name) {
    return DSFeature699On("core775") && DSFeature699On(name);
}

// 4.5.776: master core776-off returns to 775.
BOOL DS776On(const char *name) {
    return DSFeature699On("core776") && DSFeature699On(name);
}

// 4.5.795: pass795 / sig795 / keyring795 / register795; core795-off returns to 794.
BOOL DS795On(const char *name) {
    return DSFeature699On("core795") && DS794On("core794") && DSFeature699On(name);
}

// 4.5.799: master core799-off returns every 799 change to 4.5.798.
BOOL DS799On(const char *name) {
    return DSFeature699On("core799") && DSFeature699On(name);
}

// 4.5.800: master core800-off returns every 800 change to 4.5.799.
BOOL DS800On(const char *name) {
    return DSFeature699On("core800") && DSFeature699On(name);
}

// 4.5.801: master core801-off returns every 801 change to 4.5.800.
BOOL DS801On(const char *name) {
    return DSFeature699On("core801") && DSFeature699On(name);
}

// 4.5.802: master core802-off returns every 802 change to 4.5.801.
BOOL DS802On(const char *name) {
    return DSFeature699On("core802") && DSFeature699On(name);
}

// 4.5.803: master core803-off returns every 803 change to 4.5.802.
BOOL DS803On(const char *name) {
    return DSFeature699On("core803") && DS802On("core802") && DSFeature699On(name);
}

BOOL DS804On(const char *name);
// 4.5.805: master core805-off returns every 805 change to 4.5.804.
BOOL DS805On(const char *name) {
    return DSFeature699On("core805") && DS804On("core804") && DSFeature699On(name);
}

// 4.5.806: master core806-off returns every 806 change to 4.5.805.
BOOL DS806On(const char *name) {
    return DSFeature699On("core806") && DS805On("core805") && DSFeature699On(name);
}

// 4.5.807: master core807-off returns every 807 change to 4.5.806.
BOOL DS807On(const char *name) {
    return DSFeature699On("core807") && DS806On("core806") && DSFeature699On(name);
}

// 4.5.804: master core804-off returns every 804 change to 4.5.803.
BOOL DS804On(const char *name) {
    return DSFeature699On("core804") && DS803On("core803") && DSFeature699On(name);
}

// 4.5.802: opt-in features (off unless /var/mobile/.dynamicstage-<name>-on).
BOOL DS802OptIn(const char *name) {
    if (!name || !DS802On(name)) return NO;
    char plain[160], jb[180];
    snprintf(plain, sizeof(plain), "/var/mobile/.dynamicstage-%s-on", name);
    snprintf(jb, sizeof(jb), "/var/jb/var/mobile/.dynamicstage-%s-on", name);
    return access(plain, F_OK) == 0 || access(jb, F_OK) == 0;
}


// 4.5.794: table794 (switch table 512 slots); core794-off returns to 793.
BOOL DS794On(const char *name) {
    return DSFeature699On("core794") && DS793On("core793") && DSFeature699On(name);
}

// 4.5.793: log793 (crash forensics, logging only); core793-off returns to 792.
BOOL DS793On(const char *name) {
    return DSFeature699On("core793") && DS792On("core792") && DSFeature699On(name);
}

// 4.5.792: log792 (logging only); core792-off returns to 791.
BOOL DS792On(const char *name) {
    return DSFeature699On("core792") && DS791On("core791") && DSFeature699On(name);
}

// 4.5.791: reopen791, log791; core791-off returns to 790.
BOOL DS791On(const char *name) {
    return DSFeature699On("core791") && DS790On("core790") && DSFeature699On(name);
}

// 4.5.790: caret790, reopen790, strip790; core790-off returns to 789.
BOOL DS790On(const char *name) {
    return DSFeature699On("core790") && DS789On("core789") && DSFeature699On(name);
}

// 4.5.789: reopen789; core789-off returns to 788.
BOOL DS789On(const char *name) {
    return DSFeature699On("core789") && DS788On("core788") && DSFeature699On(name);
}

// 4.5.788: reopen788, flicker788, caret788; core788-off returns to 787.
BOOL DS788On(const char *name) {
    return DSFeature699On("core788") && DS787On("core787") && DSFeature699On(name);
}

// 4.5.787: swipe787, return787, rimname787; core787-off returns to 786.
BOOL DS787On(const char *name) {
    return DSFeature699On("core787") && DS786On("core786") && DSFeature699On(name);
}

// 4.5.786: swipe786, return786; core786-off returns to 785.
BOOL DS786On(const char *name) {
    return DSFeature699On("core786") && DS785On("core785") && DSFeature699On(name);
}

// 4.5.785: reopen784; core785-off returns to 784.
BOOL DS785On(const char *name) {
    return DSFeature699On("core785") && DS784On("core784") && DSFeature699On(name);
}

// 4.5.784: strip784 log; caret778 off by default; core784-off returns to 783.
BOOL DS784On(const char *name) {
    return DSFeature699On("core784") && DS783On("core783") && DSFeature699On(name);
}

// 4.5.784: the app strip matters more than the caret. caret778 only runs
// with /var/mobile/.dynamicstage-caret778-on (or with core784-off, as 783).
BOOL DSCaret778Enabled(void) {
    if (!DS778On("caret778")) return NO;
    // 4.5.788 caret788: caret778 back on, with Messages told its keyboard is
    // visible while the staged keys are up (strip fix). Off: -caret788-off.
    // 4.5.790 caret790: caret788 is opt-in again (-caret788-on). With the box
    // kept focused the first key collapsed the entry 81 -> 44 and the strip
    // went (Shush's 07:42:23.760, 07:41:56.957); 784 with the box not focused
    // kept 81 + strip on every key (Hahahah 07:00:56.373). Off: -caret790-off.
    if (DS788On("caret788") && (!DS790On("caret790") || access("/var/mobile/.dynamicstage-caret788-on", F_OK) == 0)) return YES;
    if (!DSFeature699On("core784")) return YES;
    return access("/var/mobile/.dynamicstage-caret778-on", F_OK) == 0;
}

// 4.5.783: reopen783, strip783 log; core783-off returns to 782.
BOOL DS783On(const char *name) {
    return DSFeature699On("core783") && DS782On("core782") && DSFeature699On(name);
}

// 4.5.782: reopen782, strip782; core782-off returns to 781.
BOOL DS782On(const char *name) {
    return DSFeature699On("core782") && DS781On("core781") && DSFeature699On(name);
}

// 4.5.781: leave781, reopen781, entry781 log; core781-off returns to 780.
BOOL DS781On(const char *name) {
    return DSFeature699On("core781") && DS780On("core780") && DSFeature699On(name);
}

// 4.5.780: only backspace779 on top of 778; core780-off returns to 778.
BOOL DS780On(const char *name) {
    return DSFeature699On("core780") && DS778On("core778") && DSFeature699On(name);
}

// 4.5.779: master core779-off returns to 778.
BOOL DS779On(const char *name) {
    return DSFeature699On("core779") && DS778On("core778") && DSFeature699On(name);
}

// 4.5.778: master core778-off returns to 777.
BOOL DS778On(const char *name) {
    return DSFeature699On("core778") && DS777On("core777") && DSFeature699On(name);
}

// 4.5.777: master core777-off returns to 776.
BOOL DS777On(const char *name) {
    return DSFeature699On("core777") && DSFeature699On(name);
}
