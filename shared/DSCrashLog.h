#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Safe mode kills SpringBoard before the stage log can be read, and that log
// is replaced on the next start. This file is the one that survives. Installing
// a new build deletes it.

void DSCrashLogInstallHandlers(void);

// The boot guard is set when the last start died before the stage was ready.
// Copies the stage log that is still on disk. Skips a session already recorded.
void DSCrashLogNoteUncleanLaunch(void);

// Last lines the stage wrote, including ones that have not reached disk yet.
void DSCrashLogRemember(NSString *line);

NSString *DSCrashLogRead(void);

#ifdef __cplusplus
}
#endif
