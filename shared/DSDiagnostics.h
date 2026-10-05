#import <Foundation/Foundation.h>

// A crash log is the one thing this tweak cannot ask for: the device it runs on
// is not the machine it is built on, and the person testing it has no way to read
// one. So the tweak keeps its own short account of what it did - which activation
// path it took, why a pull was refused, what threw in the Settings pane - in a
// file both SpringBoard and Settings can reach, and shows it back inside its own
// preferences.

#ifdef __cplusplus
extern "C" {
#endif

void DSDiagnosticsRecord(NSString *message);
void DSDiagnosticsRecordFormat(NSString *format, ...);

// Newest line last, ready to be read on a screen. Empty string when nothing has
// been recorded yet.
NSString *DSDiagnosticsRead(void);
void DSDiagnosticsClear(void);

// Replaces the log with one line. Call this once when SpringBoard starts so the
// file the next report is copied from is only this boot.
void DSDiagnosticsBeginSession(NSString *message);

// Longer Beeper keyboard / quick-bar log. SpringBoard and the Beeper process
// both append. Replaced when SpringBoard starts a session.
void DSBeeperDetailLog(NSString *message);
void DSBeeperDetailLogFormat(NSString *format, ...);

// Keyboard / dual-stack snapshots (multiline, this boot only). Cleared when
// DSDiagnosticsBeginSession runs.
void DSDiagnosticsAppendKeyboardStageLog(NSString *message);
NSString *DSDiagnosticsReadKeyboardStageLog(void);

// Synchronous trace from the moment the stage opens. Both SpringBoard and a
// staged app append it. The file is renamed aside on the next SpringBoard
// start, so a watchdog respring keeps the lines from the boot that froze.
// A background check writes a STALL line when the main thread stops returning
// to the run loop, including the last line that thread logged.
void DSTrace(NSString *message);
void DSTraceFormat(NSString *format, ...);
void DSTraceSetContext(NSString *context);
void DSTraceArchivePreviousAndStart(void);
NSString *DSTraceRead(void);

#ifdef __cplusplus
}
#endif
