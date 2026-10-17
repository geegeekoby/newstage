// 4.5.667: relay667 - trace lines from sandboxed staged apps.
//
// Beeper, Messenger and Signal cannot write /var/tmp from their sandbox, and
// none of their Darwin-notify reports (ctor, camera660 hello, camera events)
// has ever shown up in a log either. So the app dylib's trace now falls back to
// <the app's data container>/tmp/com.recreated.dynamicstage.app-trace.log
// (shared/DSDiagnostics.m), and SpringBoard copies the new lines from there
// into the shared trace every 1.5 s. Lines keep the app's own timestamp and
// "<Process> pid=.. main |" prefix, so they read exactly like Messages' lines.
// Read-only on the app side: SpringBoard never writes into a container.

#import "DSStageDebug.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/stat.h>
#import <errno.h>
#import "../shared/DSConstants.h"
#import "../shared/DSDiagnostics.h"

#import <signal.h>

void DSAppTraceRelayStart(void);
BOOL DSAppTraceRelayBundleIsLive(NSString *bundle);
NSString *DSAppTraceRelayBundleSummary(NSString *bundle);
void DSAppTraceRelayNoteHosted(NSArray<NSString *> *hosted);

// 4.5.668: which sandboxed apps have shown this session that the app dylib is
// running in them (a fresh trace file, or a ctor / mapped marker whose pid is
// alive), and which were on a card with no sign of it. Read on the main thread
// by the camera arbiter; written on the relay queue.
static NSLock *DSRelayStateLock(void) {
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSLock new]; });
    return lock;
}
static NSMutableDictionary<NSString *, NSNumber *> *DSRelayLive;          // bundle -> pid (0 = file only)
static NSMutableDictionary<NSString *, NSString *> *DSRelaySummary;       // bundle -> one line
static NSMutableDictionary<NSString *, NSNumber *> *DSRelayHostedSince;   // bundle -> CFAbsoluteTime

@interface DSAppTraceRelayEntry : NSObject
@property (nonatomic, copy) NSString *bundle;
@property (nonatomic, copy) NSString *path;      // nil until the container is known
@property (nonatomic) unsigned long long offset;
@property (nonatomic) BOOL primed;               // offset decided for this file
@property (nonatomic) CFAbsoluteTime lastResolve;
@property (nonatomic) BOOL reportedMissing;
@property (nonatomic) BOOL reportedFound;
@property (nonatomic) NSInteger linesRelayed;
@property (nonatomic) BOOL reportedPath;
@property (nonatomic) BOOL reportedUnreadable;
@property (nonatomic, copy) NSString *container;
@property (nonatomic, copy) NSString *markerSeen;   // last marker text logged
@property (nonatomic) BOOL reportedNoMarker;
@end

@implementation DSAppTraceRelayEntry
@end

static dispatch_queue_t DSRelayQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.recreated.dynamicstage.relay667", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSArray<NSString *> *DSRelayBundles(void) {
    // The injected apps that live in a sandbox container (DynamicStageApp.plist).
    return @[ @"com.beeper.chat.ios", @"com.facebook.Messenger", @"org.whispersystems.signal" ];
}

static NSString *DSRelayContainerFromProxy(NSString *bundle) {
    @try {
        Class proxyClass = objc_getClass("LSApplicationProxy");
        SEL make = @selector(applicationProxyForIdentifier:);
        if (!proxyClass || ![proxyClass respondsToSelector:make]) return nil;
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, make, bundle);
        if (!proxy || ![proxy respondsToSelector:@selector(dataContainerURL)]) return nil;
        NSURL *url = ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(dataContainerURL));
        if (![url isKindOfClass:NSURL.class] || url.path.length < 8) return nil;
        return url.path;
    } @catch (NSException *exception) {
        return nil;
    }
}

static NSString *DSRelayContainerFromScan(NSString *bundle) {
    NSString *root = @"/var/mobile/Containers/Data/Application";
    NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil];
    for (NSString *name in names) {
        NSString *dir = [root stringByAppendingPathComponent:name];
        NSString *meta = [dir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:meta];
        if ([info[@"MCMMetadataIdentifier"] isEqual:bundle]) return dir;
    }
    return nil;
}

static NSString *DSRelayResolve(DSAppTraceRelayEntry *entry, NSString **howOut) {
    NSString *how = @"LSApplicationProxy";
    NSString *container = DSRelayContainerFromProxy(entry.bundle);
    if (!container) {
        how = @"container scan";
        container = DSRelayContainerFromScan(entry.bundle);
    }
    if (howOut) *howOut = how;
    if (!container) return nil;
    entry.container = container;
    return [[container stringByAppendingPathComponent:@"tmp"] stringByAppendingPathComponent:@"" kDSAppTraceFileName];
}

static void DSRelaySetLive(NSString *bundle, int pid, NSString *summary) {
    [DSRelayStateLock() lock];
    if (!DSRelayLive) DSRelayLive = [NSMutableDictionary dictionary];
    if (!DSRelaySummary) DSRelaySummary = [NSMutableDictionary dictionary];
    if (pid >= 0) DSRelayLive[bundle] = @(pid);
    else [DSRelayLive removeObjectForKey:bundle];
    if (summary) DSRelaySummary[bundle] = summary;
    [DSRelayStateLock() unlock];
}

static int DSRelayMarkerPid(NSString *text) {
    NSRange range = [text rangeOfString:@"pid="];
    if (range.location == NSNotFound) return 0;
    return [[text substringFromIndex:NSMaxRange(range)] intValue];
}

static BOOL DSRelayPidAlive(int pid) {
    if (pid <= 0) return NO;
    if (kill(pid, 0) == 0) return YES;
    return errno == EPERM;
}

// 4.5.668: the image-mapped and ctor markers the app dylib drops in its own
// container (app/Tweak.xm DSWriteContainerMarker).
static void DSRelayCheckMarkers(DSAppTraceRelayEntry *entry, CFAbsoluteTime now) {
    if (entry.container.length == 0) return;
    NSString *found = nil;
    NSString *where = nil;
    NSDate *newest = nil;
    for (NSString *dir in @[ @"tmp", @"Library/Caches" ]) {
        for (NSString *name in @[ @"com.recreated.dynamicstage.ctor", @"com.recreated.dynamicstage.mapped" ]) {
            NSString *path = [[entry.container stringByAppendingPathComponent:dir] stringByAppendingPathComponent:name];
            NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
            NSDate *modified = attributes.fileModificationDate;
            if (!modified) continue;
            if (newest && [modified compare:newest] != NSOrderedDescending) continue;
            NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
            if (text.length == 0) continue;
            newest = modified;
            found = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            where = [dir stringByAppendingPathComponent:name];
        }
    }
    NSNumber *since = nil;
    [DSRelayStateLock() lock];
    since = DSRelayHostedSince[entry.bundle];
    [DSRelayStateLock() unlock];
    if (found) {
        int pid = DSRelayMarkerPid(found);
        BOOL alive = DSRelayPidAlive(pid);
        NSString *line = [NSString stringWithFormat:@"%@ (%@, %.0fs old, pid %d %@)", found, where,
                          -[newest timeIntervalSinceNow], pid, alive ? @"running" : @"gone"];
        if (![entry.markerSeen isEqualToString:found]) {
            entry.markerSeen = found;
            DSTraceFormat(@"relay668 %@ app dylib marker: %@", entry.bundle, line);
        }
        DSRelaySetLive(entry.bundle, alive ? pid : -1, line);
        if (alive) {
            entry.reportedNoMarker = NO;
            return;
        }
    } else if (entry.linesRelayed == 0) {
        DSRelaySetLive(entry.bundle, -1, @"no marker in its container");
    } else {
        return;
    }
    if (!since) entry.reportedNoMarker = NO;
    // On a card for a while with no live marker: the image never mapped here.
    if (since && now - since.doubleValue > 6.0 && !entry.reportedNoMarker) {
        entry.reportedNoMarker = YES;
        DSTraceFormat(@"relay668 %@ on a card %.0fs and %@: DynamicStageApp.dylib is NOT running in this app "
                      @"(no injection: check jailbreak-hiding / tweak-blocking settings for it); "
                      @"its camera is not handled inside the app (the SpringBoard-side camera layout is opt-in: /var/mobile/.dynamicstage-sbcam-on)",
                      entry.bundle, now - since.doubleValue,
                      found ? [NSString stringWithFormat:@"its marker is stale (%@)", found] : @"no ctor or mapped marker in its container");
    }
}

BOOL DSAppTraceRelayBundleIsLive(NSString *bundle) {
    if (bundle.length == 0) return NO;
    [DSRelayStateLock() lock];
    BOOL live = DSRelayLive[bundle] != nil;
    [DSRelayStateLock() unlock];
    return live;
}

NSString *DSAppTraceRelayBundleSummary(NSString *bundle) {
    if (bundle.length == 0) return @"?";
    [DSRelayStateLock() lock];
    NSString *summary = DSRelaySummary[bundle];
    [DSRelayStateLock() unlock];
    return summary ?: @"not checked yet";
}

void DSAppTraceRelayNoteHosted(NSArray<NSString *> *hosted) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    [DSRelayStateLock() lock];
    if (!DSRelayHostedSince) DSRelayHostedSince = [NSMutableDictionary dictionary];
    for (NSString *bundle in DSRelayHostedSince.allKeys) {
        if (![hosted containsObject:bundle]) [DSRelayHostedSince removeObjectForKey:bundle];
    }
    for (NSString *bundle in hosted) {
        if (!DSRelayHostedSince[bundle]) DSRelayHostedSince[bundle] = @(now);
    }
    [DSRelayStateLock() unlock];
}

static void DSRelayPoll(NSMutableArray<DSAppTraceRelayEntry *> *entries, CFAbsoluteTime startedAt) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    for (DSAppTraceRelayEntry *entry in entries) {
        @autoreleasepool {
            if (!entry.path && now - entry.lastResolve > 10.0) {
                entry.lastResolve = now;
                NSString *how = nil;
                entry.path = DSRelayResolve(entry, &how);
                if (!entry.path && !entry.reportedMissing) {
                    entry.reportedMissing = YES;
                    DSTraceFormat(@"relay667 %@ data container not found (%@), its trace lines cannot be relayed", entry.bundle, how ?: @"?");
                }
            }
            if (!entry.path) continue;
            DSRelayCheckMarkers(entry, now);
            if (!entry.reportedPath) {
                entry.reportedPath = YES;
                DSTraceFormat(@"relay667 %@ watching %@", entry.bundle, entry.path);
            }
            struct stat info;
            if (stat(entry.path.fileSystemRepresentation, &info) != 0) {
                if (errno != ENOENT && !entry.reportedUnreadable) {
                    entry.reportedUnreadable = YES;
                    DSTraceFormat(@"relay667 %@ cannot read its trace file (errno %d)", entry.bundle, errno);
                }
                // Reinstalled apps move containers; look again later.
                if (now - entry.lastResolve > 30.0) entry.path = nil;
                continue;
            }
            unsigned long long size = (unsigned long long)info.st_size;
            if (!entry.primed) {
                entry.primed = YES;
                // A file from before this SpringBoard started is old news.
                CFAbsoluteTime modified = (CFAbsoluteTime)info.st_mtimespec.tv_sec - kCFAbsoluteTimeIntervalSince1970;
                entry.offset = (modified < startedAt - 2.0) ? size : 0;
                if (!entry.reportedFound) {
                    entry.reportedFound = YES;
                    DSTraceFormat(@"relay667 %@ app trace file found (%llu bytes, %@), relaying its new lines",
                                  entry.bundle, size, entry.offset ? @"older lines skipped" : @"from the start");
                }
            }
            if (size < entry.offset) entry.offset = size; // the app trimmed it
            if (size == entry.offset) continue;
            unsigned long long want = size - entry.offset;
            if (want > 96 * 1024) {
                entry.offset = size - 96 * 1024;
                want = 96 * 1024;
            }
            NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:entry.path];
            if (!handle) continue;
            NSData *data = nil;
            @try {
                [handle seekToFileOffset:entry.offset];
                data = [handle readDataOfLength:(NSUInteger)want];
            } @catch (NSException *exception) {
                data = nil;
            }
            [handle closeFile];
            if (data.length == 0) continue;
            // Only whole lines; a half-written tail waits for the next poll.
            const char *bytes = (const char *)data.bytes;
            NSUInteger end = data.length;
            while (end > 0 && bytes[end - 1] != '\n') end--;
            if (end == 0) continue;
            NSString *text = [[NSString alloc] initWithBytes:bytes length:end encoding:NSUTF8StringEncoding];
            entry.offset += end;
            if (text.length == 0) continue;
            entry.linesRelayed += 1;
            if (!DSAppTraceRelayBundleIsLive(entry.bundle)) DSRelaySetLive(entry.bundle, 0, @"trace lines arriving");
            DSTraceAppendRelayed(text);
        }
    }
}

void DSAppTraceRelayStart(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<DSAppTraceRelayEntry *> *entries = [NSMutableArray array];
        for (NSString *bundle in DSRelayBundles()) {
            DSAppTraceRelayEntry *entry = [DSAppTraceRelayEntry new];
            entry.bundle = bundle;
            [entries addObject:entry];
        }
        CFAbsoluteTime startedAt = CFAbsoluteTimeGetCurrent();
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, DSRelayQueue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                                  (uint64_t)(1.5 * NSEC_PER_SEC), (uint64_t)(0.3 * NSEC_PER_SEC));
        __block unsigned idleTicks = 0;
        __block int cadence = 0;   // 4.5.701: 0 = 1.5 s (as before), 1 = 6 s idle, 2 = 30 s locked
        static dispatch_source_t relayTimer;
        relayTimer = timer;
        dispatch_source_set_event_handler(timer, ^{
            // 4.5.701 battery701: the timer itself slows down (it used to fire
            // every 1.5 s and skip 3 of 4 polls): every 6 s (2 s leeway) with
            // none of these apps on a card, and no polling at all while the
            // phone is locked (checked every 30 s; the files are read from where
            // they were left, so nothing is lost).
            if (DSBattery701On() && !DSLogVerbose()) {
                [DSRelayStateLock() lock];
                BOOL hosted = DSRelayHostedSince.count > 0;
                [DSRelayStateLock() unlock];
                BOOL locked = DSBattery701ScreenLocked();
                int want = locked ? 2 : (hosted ? 0 : 1);
                if (want != cadence) {
                    cadence = want;
                    double every = want == 0 ? 1.5 : (want == 1 ? 6.0 : 30.0);
                    double leeway = want == 0 ? 0.3 : (want == 1 ? 2.0 : 10.0);
                    dispatch_source_set_timer(relayTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(every * NSEC_PER_SEC)),
                                              (uint64_t)(every * NSEC_PER_SEC), (uint64_t)(leeway * NSEC_PER_SEC));
                }
                if (locked) return;
                if (want == 1) {
                    @try {
                        DSRelayPoll(entries, startedAt);
                    } @catch (NSException *exception) {
                    }
                    return;
                }
            } else if (cadence != 0) {
                cadence = 0;
                dispatch_source_set_timer(relayTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                                          (uint64_t)(1.5 * NSEC_PER_SEC), (uint64_t)(0.3 * NSEC_PER_SEC));
            }
            // 4.5.698 perf698: with none of these apps on a card (and no verbose
            // log) the three containers are checked every 6 s instead of every
            // 1.5 s (each check is ~8 file stats/reads). Full rate while any of
            // them is on a card, so the live/marker state is as before.
            if (DSPerf698On() && !DSLogVerbose()) {
                [DSRelayStateLock() lock];
                BOOL anyHosted = DSRelayHostedSince.count > 0;
                [DSRelayStateLock() unlock];
                if (!anyHosted && (++idleTicks % 4) != 0) return;
                if (anyHosted) idleTicks = 0;
            }
            @try {
                DSRelayPoll(entries, startedAt);
            } @catch (NSException *exception) {
            }
        });
        dispatch_resume(timer);
        static dispatch_source_t keep;
        keep = timer;
        DSDiagnosticsRecordFormat(@"SpringBoard: relay667 copying trace lines from %lu sandboxed apps (Beeper, Messenger, Signal) into this log",
                                  (unsigned long)entries.count);
    });
}
