#import <Foundation/Foundation.h>
#import <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// POSIX launch-guard and process-gate used by both dylibs.
//
// SpringBoard after a device reboot + jailbreak is not a respring: userspace is
// coming up from nothing, class lists are incomplete, and injecting a full
// SpringBoard tweak in +load/%ctor is a classic boot loop. These helpers keep
// every expensive hook off that path.

bool DSKillSwitchPresent(void);

// True when a previous full SpringBoard install crashed before it could clear
// the guard. The Boot group still loads so we can stay silent; Stage/Arbiter
// groups must not.
bool DSLaunchGuardTripped(void);

// Call once, immediately before %init of Stage/Arbiter. Increments the unclean
// count. Returns false if the guard is already tripped (do not install).
bool DSBootstrapBeginFullInstall(void);

// Call once activate() has returned. A crash between Begin and this is what
// trips the guard on the next SpringBoard start.
void DSBootstrapMarkLaunchSucceeded(void);

// Real App Store / sideloaded / /Applications bundles only. Daemons, SpringBoard,
// KeyboardArbiter, PreferenceBundles and jailbreak helpers all return false.
bool DSBundleLooksLikeUserApplication(void);

#ifdef __cplusplus
}
#endif
