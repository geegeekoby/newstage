#import "DSSafety.h"
#import "DSConstants.h"
#import "DSDiagnostics.h"

static BOOL sPlainMode;
static BOOL sDecided;

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

static NSInteger DSPrefsGuardCount(void) {
    NSString *contents = [NSString stringWithContentsOfFile:kDSPrefsOpenGuardPath
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
    return contents.length > 0 ? contents.integerValue : 0;
}

static void DSPrefsWriteGuardCount(NSInteger count) {
    @try {
        if (count <= 0) {
            [[NSFileManager defaultManager] removeItemAtPath:kDSPrefsOpenGuardPath error:nil];
            return;
        }
        [[NSString stringWithFormat:@"%ld", (long)count] writeToFile:kDSPrefsOpenGuardPath
                                                        atomically:YES
                                                          encoding:NSUTF8StringEncoding
                                                             error:nil];
    } @catch (NSException *exception) {
    }
}

// Called from every point the page can start being built from, because which of
// them Settings reaches first is up to Settings. Only the first call in a process
// counts: this is about whole opens, not about how many ways in there are.
void DSPrefsNotePageOpening(void) {
    if (sDecided) return;
    sDecided = YES;

    sPlainMode = DSPrefsGuardCount() > 0;
    if (sPlainMode) {
        DSDiagnosticsRecord(@"prefs: an earlier open of this page never reached the screen, so it is being built from stock cells only");
    }
    DSPrefsWriteGuardCount(DSPrefsGuardCount() + 1);
}

void DSPrefsNotePageShown(void) {
    // A page that got here in plain mode stays plain. The decoration is what did
    // not survive last time, and offering it again every other open would mean
    // crashing every other open. Restore Full Page is how it comes back.
    DSPrefsWriteGuardCount(sPlainMode ? 1 : 0);
    DSDiagnosticsRecordFormat(@"prefs: page on screen (%@)", sPlainMode ? @"plain" : @"full");
}

BOOL DSPrefsPlainMode(void) {
    return sPlainMode;
}

void DSPrefsResetPlainMode(void) {
    sPlainMode = NO;
    sDecided = YES;
    DSPrefsWriteGuardCount(0);
    DSDiagnosticsRecord(@"prefs: page decoration re-enabled by hand");
}
