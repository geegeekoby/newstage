#import "DSSafety.h"
#import "DSConstants.h"
#import "DSDiagnostics.h"

static BOOL sNoted;

BOOL DSPrefsRun(NSString *what, void (^block)(void)) {
    if (!block) return YES;
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"prefs: %@ threw %@ - %@",
                                  what ?: @"something",
                                  exception.name ?: @"?",
                                  exception.reason ?: @"?");
        return NO;
    } @catch (...) {
        DSDiagnosticsRecordFormat(@"prefs: %@ threw something that is not an exception", what ?: @"something");
        return NO;
    }
}

// A crash on the way to this page leaves nothing behind: Settings is gone before
// anything can be written about why. What can be left behind is a mark saying an
// open began, cleared once the page is on screen - so an open that finds the mark
// still there knows the last one never arrived, and says so in the log.
void DSPrefsNotePageOpening(void) {
    if (sNoted) return;
    sNoted = YES;

    if ([NSFileManager.defaultManager fileExistsAtPath:kDSPrefsOpenGuardPath]) {
        DSDiagnosticsRecord(@"prefs: the previous open of this page never reached the screen");
    }
    @try {
        [@"opening" writeToFile:kDSPrefsOpenGuardPath
                     atomically:YES
                       encoding:NSUTF8StringEncoding
                          error:nil];
    } @catch (NSException *exception) {
    }
}

void DSPrefsNotePageShown(void) {
    @try {
        [NSFileManager.defaultManager removeItemAtPath:kDSPrefsOpenGuardPath error:nil];
    } @catch (NSException *exception) {
    }
    DSDiagnosticsRecord(@"prefs: page on screen");
}
