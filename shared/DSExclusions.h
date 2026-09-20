#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Applications the stage keeps its hands off entirely: they are left out of the
// picker and out of the per-app settings list, and the injected dylib installs no
// hooks inside them.
//
// Two kinds of thing are in here. Some are system stubs that have no business on
// a stage at all. The rest are how a device gets fixed - package managers, file
// managers, terminals and the jailbreak app itself - and those have to keep
// behaving exactly as they do without this tweak installed, because they are what
// you reach for when something else here is broken.
BOOL DSIdentifierIsExcludedFromStage(NSString *identifier);

#ifdef __cplusplus
}
#endif
