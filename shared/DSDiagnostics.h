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
void DSDiagnosticsRecordFormat(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

// Newest line last, ready to be read on a screen. Empty string when nothing has
// been recorded yet.
NSString *DSDiagnosticsRead(void);
void DSDiagnosticsClear(void);

#ifdef __cplusplus
}
#endif
