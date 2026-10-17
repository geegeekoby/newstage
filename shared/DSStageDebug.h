#import <Foundation/Foundation.h>

// In-memory log for one SpringBoard boot. The picker copies it. The overlay
// reads it. Nothing here touches a window.
extern NSMutableString *DSLogBuffer;

void DSLogInit(void);
void DSLogAppend(NSString *line);
NSString *DSAscii745(NSString *line);
NSString *DSLogDump(void);
void DSLogClear(void);
void DSLogC(const char *format, ...);

// ---- 4.5.697 performance ---------------------------------------------------
// DSPerf697On: the 697 performance changes (quiet log, async trace writes,
//   no per-frame card relayout). Off: /var/mobile/.dynamicstage-perf697-off.
// DSLogVerbose: /var/mobile/.dynamicstage-verbose = full log (every debug line).
// DSPerfLogOn: /var/mobile/.dynamicstage-perf = timing summary every ~3 s.
// All three are cached for 2 s (one access() per file per 2 s).
BOOL DSPerf697On(void);
BOOL DSLogVerbose(void);
BOOL DSLogQuiet(void);
BOOL DSPerfLogOn(void);
typedef NS_ENUM(NSInteger, DSPerfBucket) {
    DSPerfBucketDrag = 0,      // stage pan handler
    DSPerfBucketCardLayout,    // card layoutSubviews
    DSPerfBucketHostLayout,    // DSSceneHost layoutHostView
    DSPerfBucketKeyboard,      // keyboard notes / UIKit keyboard notifications
    DSPerfBucketSceneHook,     // scene settings hooks (overrides)
    DSPerfBucketCount
};
typedef NS_ENUM(NSInteger, DSPerfCounter) {
    DSPerfCounterSceneWrites = 0,
    DSPerfCounterLogLines,
    DSPerfCounterLogDropped,
    DSPerfCounterTraceWrites,
    DSPerfCounterDragFrames,
    // 4.5.705 perf705 counters (counted only while /var/mobile/.dynamicstage-perf exists).
    DSPerfCounterClipPasses,       // applyCardCornerClip runs (card layout)
    DSPerfCounterClipWalks,        // blur-subview class walks actually done
    DSPerfCounterMaskRebuilds,     // CALayer masks rebuilt on contentView/backdrop
    DSPerfCounterShadowUpdates,    // updateShadow runs
    DSPerfCounterRimLayouts,       // layoutRimCatchers runs
    DSPerfCounterRoundPasses,      // roundHostedSceneToCard walks
    DSPerfCounterKeyboardNotes,    // noteKeyboardFrame calls
    DSPerfCounterFocusEvals,       // focus704 evaluations
    DSPerfCounterFocusMoves,       // focus704/705 slides or raises actually done
    DSPerfCounterSearchHideHeld,   // focus705 search-hide debounces
    DSPerfCounterHealRelayouts,    // heal700 re-layouts
    DSPerfCounterTicks,            // stage ticks
    DSPerfCounterFileStats,        // access()/fileExists calls by our switches
    DSPerfCounterBlurToggles,      // perf705 backdrop blur hidden/shown
    // 4.5.706
    DSPerfCounterDragSkips,        // perf706 per-drag-frame work skipped (z-order, tile, ghost)
    DSPerfCounterTraceFlushes,     // perf706 trace file writes actually done (lines are TraceWrites)
    DSPerfCounterSettles,          // drag706 watchdog settles
    DSPerfCounterSlowTicks,        // perf706 stage ticks taken at the locked / idle cadence
    DSPerfCounterCount
};
uint64_t DSPerfNow(void);                       // 0 when the perf log is off
void DSPerfAdd(DSPerfBucket bucket, uint64_t start);
void DSPerfCount(DSPerfCounter counter);
NSString *DSPerfSummaryAndReset(void);
// 4.5.705: SpringBoard supplies a one-line state gauge (cards, blur, masks...).
void DSPerfSetGaugeProvider(NSString *(*provider)(void));
void DSPerfNoteFileStat(void);          // nil when nothing to say
// ---- 4.5.698 ------------------------------------------------------------------
// DSAnim698On: the smooth minimise flight (a snapshot flies to the corner, the
//   real card is placed without animation). Off: /var/mobile/.dynamicstage-anim698-off.
// DSPerf698On: the 698 sweep fixes. Off: /var/mobile/.dynamicstage-perf698-off.
// Both have a crash latch: /var/mobile/.dynamicstage-<name>-trying is written at the
// first use and removed after 15 s; found at the next SpringBoard start ->
// -<name>-crashed (feature stays off until that file is deleted).
BOOL DSAnim698On(void);
BOOL DSPerf698On(void);
void DSAnim698MarkTrying(void);
void DSPerf698MarkTrying(void);
// 4.5.699: generic switch + crash latch: name "crash699" -> off file
// /var/mobile/.dynamicstage-crash699-off, latch -crash699-trying/-crashed.
FOUNDATION_EXTERN BOOL DSFeature699On(const char *name);
FOUNDATION_EXTERN void DSFeature699MarkTrying(const char *name);
// 4.5.715: YES when name's crash latch (name-crashed) is set; the off file is not read.
FOUNDATION_EXTERN BOOL DSFeature699Latched(const char *name);
FOUNDATION_EXTERN void DSLatch754BootSweep(void);
FOUNDATION_EXTERN void DSBeat756Start(void);
FOUNDATION_EXTERN void DSLatch754NoteSafeMode(void);
FOUNDATION_EXTERN NSString *DSLatch754Summary;
// 4.5.719: per-action crash latch. Writes /var/mobile/.dynamicstage-<name>-trying
// before EVERY action; the file is removed only once SpringBoard has stayed up
// 15 s after the latest action. A crash inside that window latches the feature
// off at the next start (same -crashed file as DSFeature699On reads).
FOUNDATION_EXTERN void DSFeature719MarkAction(const char *name);
// 4.5.766: "<name>766" switch under the core766 master. Off file
// /var/mobile/.dynamicstage-<name>-off or -core766-off; crash latch per name.
FOUNDATION_EXTERN BOOL DS766On(const char *name);
// 4.5.767: "<name>767" switch under the core767 master (core767-off = 4.5.766).
FOUNDATION_EXTERN BOOL DS767On(const char *name);
// 4.5.769: "<name>769" switch under the core769 master (core769-off = 4.5.768).
FOUNDATION_EXTERN BOOL DS769On(const char *name);
// 4.5.719: seconds since this process started (sysctl, no state at load).
FOUNDATION_EXTERN NSTimeInterval DSProcessUptime719(void);
// 4.5.701 battery701: less idle work (slower ticks while locked / nothing staged,
// slower app-side backup polls while the app is in the background). SpringBoard:
// off file /var/mobile/.dynamicstage-battery701-off + crash latch; SpringBoard
// publishes the switch as notify state of kDSBattery701Notify (1 on, 2 off) for
// the app dylibs, which cannot read the off file from their sandbox.
#define kDSBattery701Notify "com.recreated.dynamicstage.battery701"
FOUNDATION_EXTERN BOOL DSBattery701On(void);        // SpringBoard (off file + latch)
FOUNDATION_EXTERN BOOL DSBattery701AppOn(void);     // app dylibs (notify state)
FOUNDATION_EXTERN BOOL DSBattery701ScreenLocked(void); // any thread
// Animation timing for the perf log (no-op when the perf log is off).
void DSPerfNoteAnimation(const char *name, double ms, unsigned long frames, unsigned long slow, double maxGapMs);
#define DS_PERF_BEGIN() uint64_t _dsPerfStart = DSPerfNow()
#define DS_PERF_END(bucket) do { if (_dsPerfStart) DSPerfAdd((bucket), _dsPerfStart); } while (0)

#define DSLog(fmt, ...) DSLogC(fmt, ##__VA_ARGS__)

#define DSLogKeyboard(src,on,frame,keysY,keysH,quickDelta,visible,safeTop,safeBottom) \
    DSLog("[KEYBOARD] src=%@ on=%d frame={{%.0f, %.0f}, {%.0f, %.0f}} keysY=%.0f keysH=%.0f quickBarDelta=%.0f visibleAreaHeight=%.0f safeAreaInsets top=%.0f bottom=%.0f", \
    (src) ?: @"?", (int)(on), (frame).origin.x, (frame).origin.y, (frame).size.width, (frame).size.height, \
    (keysY), (keysH), (quickDelta), (visible), (safeTop), (safeBottom))

#define DSLogBaseline(slot,bundle,cardY,cardH,restMaxY,rejected) \
    DSLog("[BASELINE] slot=%ld bundle=%@ cardY=%.0f cardH=%.0f restMaxY=%.0f rejectedNegative=%d", \
    (long)(slot), (bundle) ?: @"?", (cardY), (cardH), (restMaxY), (int)(rejected))

#define DSLogLift(slot,bundle,baseY,baseH,cardBottom,keysY,overlap,lift,was,newY,reason) \
    DSLog("[LIFT] slot=%ld bundle=%@ baseCardY=%.0f baseCardH=%.0f cardBottom=%.0f keysY=%.0f overlap=%.0f lift=%.0f (was %.0f) newCardY=%.0f reason=%@", \
    (long)(slot), (bundle) ?: @"?", (baseY), (baseH), (cardBottom), (keysY), (overlap), (lift), (was), (newY), (reason) ?: @"?")

#define DSLogSlot(slot,bundle,half,primary,stack,reason) \
    DSLog("[SLOT] slot=%ld bundle=%@ half=%d primary=%d stack=%ld reason=%@", \
    (long)(slot), (bundle) ?: @"?", (int)(half), (int)(primary), (long)(stack), (reason) ?: @"?")

#define DSLogCardBefore(slot,cardY,cardH,restMaxY) \
    DSLog("[CARD BEFORE] slot=%ld cardY=%.0f cardH=%.0f restMaxY=%.0f", \
    (long)(slot), (cardY), (cardH), (restMaxY))

#define DSLogCardAfter(slot,cardY,cardH,restMaxY) \
    DSLog("[CARD AFTER] slot=%ld cardY=%.0f cardH=%.0f restMaxY=%.0f", \
    (long)(slot), (cardY), (cardH), (restMaxY))

#define DSLogStateChange(slot,oldY,newY,oldH,newH,oldRest,newRest,oldLift,newLift) \
    DSLog("[STATE CHANGE] slot=%ld keysY: %.0f -> %.0f keysH: %.0f -> %.0f restMaxY: %.0f -> %.0f lift: %.0f -> %.0f", \
    (long)(slot), (oldY), (newY), (oldH), (newH), (oldRest), (newRest), (oldLift), (newLift))

#define DSLogQuickBar(oldH,newH,delta,treated) \
    DSLog("[QUICKBAR] oldKeysH=%.0f newKeysH=%.0f delta=%.0f treatingAsKeyboardHeightChange=%d", \
    (oldH), (newH), (delta), (int)(treated))

#define DSLogScene(host,level) \
    DSLog("[SCENE] host=%@ windowLevel=%.0f", (host) ?: @"?", (level))

#define DSLogStage(frame) \
    DSLog("[STAGE] containerFrame={{%.0f, %.0f}, {%.0f, %.0f}}", \
    (frame).origin.x, (frame).origin.y, (frame).size.width, (frame).size.height)

#define DSLogSource(src,staged) \
    DSLog("[SOURCE] src=%@ staged=%d", (src) ?: @"?", (int)(staged))

#define DSLogKeyboardWindows(windows) \
    DSLog("[KB WINDOWS] %@", (windows) ?: @"none")

#define DSLogKeyboardEventSource(uikitEvent, sbEvent, dsEvent) \
    DSLog("[KB EVENT] UIKit=%@ SB=%@ DS=%@", (uikitEvent) ?: @"?", (sbEvent) ?: @"?", (dsEvent) ?: @"?")

#define DSLogQuickBarCause(oldH,newH,delta,cause) \
    DSLog("[QUICKBAR CAUSE] oldH=%.0f newH=%.0f delta=%.0f cause=%@", (oldH), (newH), (delta), (cause) ?: @"unknown")

#define DSLogLiftReason(reason,cardBottom,keysY,restMaxY,slotMode) \
    DSLog("[LIFT REASON] %@ | cardBottom=%.0f keysY=%.0f restMaxY=%.0f slotMode=%@", \
        (reason) ?: @"?", (cardBottom), (keysY), (restMaxY), (slotMode) ?: @"?")

#define DSLogRestingFrameDecision(cardY,cardH,restMaxY,reason) \
    DSLog("[REST DECISION] cardY=%.0f cardH=%.0f restMaxY=%.0f reason=%@", \
        (cardY), (cardH), (restMaxY), (reason) ?: @"?")

#define DSLogSceneHost(host,scene,window) \
    DSLog("[SCENE HOST] host=%@ scene=%@ window=%@", (host) ?: @"?", (scene) ?: @"?", (window) ?: @"?")

#define DSLogGeometrySnapshot(cardY,cardH,keysY,keysH,visible,safeTop,safeBottom,stageFrame) \
    DSLog("[GEOMETRY] cardY=%.0f cardH=%.0f keysY=%.0f keysH=%.0f visible=%.0f safeTop=%.0f safeBottom=%.0f stageFrame={{%.0f, %.0f}, {%.0f, %.0f}}", \
        (cardY), (cardH), (keysY), (keysH), (visible), (safeTop), (safeBottom), \
        (stageFrame).origin.x, (stageFrame).origin.y, (stageFrame).size.width, (stageFrame).size.height)

#define DSLogKeyboardCensus(count,primary,remote,springboard,medusa,aperture) \
    DSLog("[KB CENSUS] total=%d primary=%@ remote=%@ springboard=%@ medusa=%@ aperture=%@", \
        (int)(count), (primary) ?: @"none", (remote) ?: @"none", (springboard) ?: @"none", (medusa) ?: @"none", (aperture) ?: @"none")

#define DSLogKeyboardFrameSource(src,windowClass,level,frame,reason) \
    DSLog("[KB FRAME SRC] src=%@ window=%@ lvl=%ld frame={{%.0f, %.0f}, {%.0f, %.0f}} reason=%@", \
        (src) ?: @"?", (windowClass) ?: @"?", (long)(level), \
        (frame).origin.x, (frame).origin.y, (frame).size.width, (frame).size.height, (reason) ?: @"?")

#define DSLogQuickBarTrigger(delta,trigger,windowClass) \
    DSLog("[QB TRIGGER] delta=%.0f trigger=%@ window=%@", (delta), (trigger) ?: @"unknown", (windowClass) ?: @"none")

#define DSLogKeyboardOwnership(owner,staged,remote,sb,medusa) \
    DSLog("[KB OWNERSHIP] owner=%@ staged=%d remote=%d springboard=%d medusa=%d", \
        (owner) ?: @"?", (int)(staged), (int)(remote), (int)(sb), (int)(medusa))

#define DSLogLiftEligibility(cardBottom,keysY,restMaxY,slotMode,eligible,reason) \
    DSLog("[LIFT ELIGIBILITY] cardBottom=%.0f keysY=%.0f restMaxY=%.0f slotMode=%@ eligible=%d reason=%@", \
        (cardBottom), (keysY), (restMaxY), (slotMode) ?: @"?", (int)(eligible), (reason) ?: @"?")

#define DSLogBaselineStability(cardY,cardH,restMaxY,stable,reason) \
    DSLog("[BASELINE STABILITY] cardY=%.0f cardH=%.0f restMaxY=%.0f stable=%d reason=%@", \
        (cardY), (cardH), (restMaxY), (int)(stable), (reason) ?: @"?")

#define DSLogDockStripInteraction(keysH,ignored,reason) \
    DSLog("[DOCK STRIP] keysH=%.0f ignored=%d reason=%@", (keysH), (int)(ignored), (reason) ?: @"?")

#define DSLogKeyboardArbitration(winner,priority,reason) \
    DSLog("[KB ARBITRATION] winner=%@ priority=%d reason=%@", (winner) ?: @"?", (int)(priority), (reason) ?: @"?")

#define DSLogKeyboardOwnerChange(oldOwner,newOwner,reason) \
    DSLog("[KB OWNER CHANGE] old=%@ new=%@ reason=%@", (oldOwner) ?: @"none", (newOwner) ?: @"?", (reason) ?: @"?")

#define DSLogKeyboardFrameDecision(finalY,finalH,source,reason) \
    DSLog("[KB FRAME DECISION] keysY=%.0f keysH=%.0f source=%@ reason=%@", \
        (finalY), (finalH), (source) ?: @"?", (reason) ?: @"?")

#define DSLogKeyboardFreezeReason(keysY,keysH,reason) \
    DSLog("[KB FREEZE] keysY=%.0f keysH=%.0f reason=%@", (keysY), (keysH), (reason) ?: @"?")

#define DSLogDockStripIgnore(keysH,frozenH,reason) \
    DSLog("[DOCK IGNORE] keysH=%.0f frozenH=%.0f reason=%@", (keysH), (frozenH), (reason) ?: @"?")

#define DSLogKeyboardStability(score,reason) \
    DSLog("[KB STABILITY] score=%d reason=%@", (int)(score), (reason) ?: @"?")

#define DSLogKeyboardHistory(history) \
    DSLog("[KB HISTORY] %@", (history) ?: @"none")

// 4.5.707: the one log throttle (was four hand-rolled ones: keys697, the
// phonesize695 "kept" line, the 704 held-update line and the 706 scene trace).
// Per `slot`: YES when `key` differs from the slot's last key or `interval`
// seconds have passed; *skipped (optional) = lines held back since the last YES.
FOUNDATION_EXPORT BOOL DSLogGate(NSString *slot, NSString *key, double interval, NSUInteger *skipped);

// 4.5.713: NO when /var/mobile/.dynamicstage-groupd713-off exists (the trace
// writer then runs the 4.5.706 code).
FOUNDATION_EXPORT BOOL DSGroupD713On(void);
// 4.5.770: core770-off returns to 769.
FOUNDATION_EXTERN BOOL DS770On(const char *name);
// 4.5.771: core771-off returns to 770.
FOUNDATION_EXTERN BOOL DS771On(const char *name);
// 4.5.772: core772-off returns to 771.
FOUNDATION_EXTERN BOOL DS772On(const char *name);
// 4.5.773: core773-off returns to 772.
FOUNDATION_EXTERN BOOL DS773On(const char *name);
// 4.5.774: core774-off returns to 773.
FOUNDATION_EXTERN BOOL DS774On(const char *name);
FOUNDATION_EXTERN BOOL DS775On(const char *name);
FOUNDATION_EXTERN BOOL DS776On(const char *name);
FOUNDATION_EXTERN BOOL DS777On(const char *name);
FOUNDATION_EXTERN BOOL DS778On(const char *name);
FOUNDATION_EXTERN BOOL DS779On(const char *name);
FOUNDATION_EXTERN BOOL DS780On(const char *name);
FOUNDATION_EXTERN BOOL DS781On(const char *name);
FOUNDATION_EXTERN BOOL DS782On(const char *name);
FOUNDATION_EXTERN BOOL DS783On(const char *name);
FOUNDATION_EXTERN BOOL DS784On(const char *name);
FOUNDATION_EXTERN BOOL DS785On(const char *name);
FOUNDATION_EXTERN BOOL DS786On(const char *name);
FOUNDATION_EXTERN BOOL DS787On(const char *name);
FOUNDATION_EXTERN BOOL DS788On(const char *name);
FOUNDATION_EXTERN BOOL DS789On(const char *name);
FOUNDATION_EXTERN BOOL DS790On(const char *name);
FOUNDATION_EXTERN BOOL DS791On(const char *name);
FOUNDATION_EXTERN BOOL DS792On(const char *name);
FOUNDATION_EXTERN BOOL DS793On(const char *name);
FOUNDATION_EXTERN BOOL DS794On(const char *name);
FOUNDATION_EXTERN BOOL DS795On(const char *name);
FOUNDATION_EXTERN BOOL DS799On(const char *name);
FOUNDATION_EXTERN BOOL DS800On(const char *name);
FOUNDATION_EXTERN BOOL DS801On(const char *name);
FOUNDATION_EXTERN BOOL DS802On(const char *name);
FOUNDATION_EXTERN BOOL DS802OptIn(const char *name);
FOUNDATION_EXTERN BOOL DS803On(const char *name);
FOUNDATION_EXTERN BOOL DS804On(const char *name);
FOUNDATION_EXTERN BOOL DS805On(const char *name);
FOUNDATION_EXTERN BOOL DS806On(const char *name);
FOUNDATION_EXTERN BOOL DS807On(const char *name);
FOUNDATION_EXTERN BOOL DS808On(const char *name);
FOUNDATION_EXTERN BOOL DS809On(const char *name);
FOUNDATION_EXTERN BOOL DS809Latched(const char *name);
FOUNDATION_EXTERN BOOL DS810On(const char *name);
FOUNDATION_EXTERN BOOL DS811On(const char *name);
FOUNDATION_EXTERN void DSPass811NoteThrough(CGPoint screen, BOOL keysUp);
FOUNDATION_EXTERN void DSGest811NoteOther(NSString *otherName);
FOUNDATION_EXTERN BOOL DS796CoreOn(void);
FOUNDATION_EXTERN BOOL DSCaret778Enabled(void);
