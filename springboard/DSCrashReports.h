#import <Foundation/Foundation.h>

// Reading the crash reports that say something about this tweak.
//
// The settings page lives inside Settings and the stage lives inside SpringBoard, so
// when either fails it takes its host with it - and the only account of why is a crash
// report that can only be reached with a file manager. SpringBoard runs as the user
// those reports belong to, so it can read them, and the stage has somewhere to show
// one. Without this, the settings page crashing is a dead end: the one place that
// could explain it is the page itself.
//
// Two things make a report worth showing, and both are checked here rather than left
// to whoever reads it. It has to be newer than the installed build, because a report
// about code that has since been replaced sends the reader after a fault that is
// already fixed - and this tweak's settings page was a binary bundle that crashed
// Settings on this device up to 1.4.8, so there are such reports on disk. And the
// image the fault actually happened in has to be named, because a phone with a dozen
// tweaks on it has a dozen candidates, and a crash in one of the others is not this
// tweak's to answer for.
//
// `implicatesTheTweak` is set to YES only when this tweak's own code appears in the
// frames of the thread that crashed. Returns nil when there is no recent report, or
// when it cannot be made sense of.
NSString *DSLastCrashSummary(BOOL *implicatesTheTweak);
