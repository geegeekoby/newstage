#import <Foundation/Foundation.h>

// Settings loads this bundle into its own process, so anything thrown in here
// takes the whole Settings app down with it - and from the outside that looks
// like "the tweak crashes Settings" with nothing to go on. Two things stop that:
// every entry point the system calls runs inside DSPrefsRun, and a page that
// never finished appearing is rebuilt the next time without any of the parts
// that are not the settings themselves.

#ifdef __cplusplus
extern "C" {
#endif

// Runs the block, and if it throws, records what threw instead of letting it out.
// Returns NO when something was caught.
BOOL DSPrefsRun(NSString *what, void (^block)(void));

// Called as the root page starts building, and again once it is on screen.
void DSPrefsNotePageOpening(void);
void DSPrefsNotePageShown(void);

// YES when a previous open did not reach the screen, in which case the page is
// built from stock cells with none of its own drawing.
BOOL DSPrefsPlainMode(void);

// Puts the full page back for the next open.
void DSPrefsResetPlainMode(void);

#ifdef __cplusplus
}
#endif
