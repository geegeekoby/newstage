#import <Foundation/Foundation.h>

// In-memory log for one SpringBoard boot. The picker copies it. The overlay
// reads it. Nothing here touches a window.
extern NSMutableString *DSLogBuffer;

void DSLogInit(void);
void DSLogAppend(NSString *line);
NSString *DSLogDump(void);
void DSLogClear(void);
void DSLogC(const char *format, ...);

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
