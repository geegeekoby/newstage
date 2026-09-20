#import <Foundation/Foundation.h>

// Settings loads this bundle into its own process, so anything thrown in here
// takes the whole Settings app down with it - and from the outside that looks
// like "the tweak crashes Settings" with nothing to go on. So every entry point
// the system calls runs inside DSPrefsRun, and the pages themselves are built
// from the cells Settings ships rather than from anything drawn here.

#ifdef __cplusplus
extern "C" {
#endif

// Runs the block, and if it throws, records what threw instead of letting it out.
// Returns NO when something was caught.
BOOL DSPrefsRun(NSString *what, void (^block)(void));

// Called as the root page starts building, and again once it is on screen. An open
// that started and never arrived is recorded, which is the only trace left of a
// Settings crash on the way to this page.
void DSPrefsNotePageOpening(void);
void DSPrefsNotePageShown(void);

#ifdef __cplusplus
}
#endif
