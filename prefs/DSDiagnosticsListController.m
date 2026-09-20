#import "DSDiagnosticsListController.h"
#import "DSConstants.h"
#import "DSDiagnostics.h"
#import "DSSafety.h"
#import "DSPrefsPrivate.h"
#import <notify.h>

// Nothing here draws anything of its own. It is the page that has to work when
// the rest of the tweak does not, so it is built out of the plainest cells
// Settings has: group footers holding text, and buttons.

@implementation DSDiagnosticsListController

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self buildSpecifiers];
    }
    return _specifiers;
}

- (NSMutableArray *)buildSpecifiers {
    NSMutableArray *specifiers = [NSMutableArray array];

    PSSpecifier *state = [PSSpecifier emptyGroupSpecifier];
    [state setProperty:@"State" forKey:@"label"];
    [state setProperty:[self stateSummary] forKey:@"footerText"];
    [specifiers addObject:state];

    PSSpecifier *logGroup = [PSSpecifier emptyGroupSpecifier];
    [logGroup setProperty:@"Log" forKey:@"label"];
    NSString *log = DSDiagnosticsRead();
    [logGroup setProperty:log.length > 0 ? log : @"Nothing recorded yet. Respring, try the corner pull, then come back here."
                   forKey:@"footerText"];
    [specifiers addObject:logGroup];

    PSSpecifier *actions = [PSSpecifier emptyGroupSpecifier];
    [specifiers addObject:actions];

    [specifiers addObject:[self buttonWithLabel:@"Refresh" action:@selector(refreshLog)]];
    [specifiers addObject:[self buttonWithLabel:@"Copy Log" action:@selector(copyLog)]];
    [specifiers addObject:[self buttonWithLabel:@"Clear Log" action:@selector(clearLog)]];

    PSSpecifier *stageGroup = [PSSpecifier emptyGroupSpecifier];
    [stageGroup setProperty:@"Try The Stage" forKey:@"label"];
    [stageGroup setProperty:@"Opens the stage from here, without the corner pull. If this works and the pull does not, the pull is what to report."
                     forKey:@"footerText"];
    [specifiers addObject:stageGroup];
    [specifiers addObject:[self buttonWithLabel:@"Open Stage Now" action:@selector(openStage)]];

    return specifiers;
}

- (PSSpecifier *)buttonWithLabel:(NSString *)label action:(SEL)action {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:label
                                                           target:self
                                                              set:NULL
                                                              get:NULL
                                                           detail:Nil
                                                             cell:PSButtonCell
                                                             edit:Nil];
    specifier->action = action;
    return specifier;
}

- (NSString *)stateSummary {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];

    [lines addObject:[NSString stringWithFormat:@"Package: %@", [self installedVersion]]];
    [lines addObject:[NSString stringWithFormat:@"SpringBoard side: %@", [self lastSpringBoardLine]]];

    BOOL killed = [[NSFileManager defaultManager] fileExistsAtPath:kDSKillSwitchPath];
    [lines addObject:[NSString stringWithFormat:@"Kill switch file: %@", killed ? @"present, hooks are off" : @"absent"]];

    NSString *guard = [NSString stringWithContentsOfFile:kDSLaunchGuardPath encoding:NSUTF8StringEncoding error:nil];
    [lines addObject:[NSString stringWithFormat:@"Unfinished SpringBoard launches: %@", guard.length > 0 ? guard : @"0"]];

    return [lines componentsJoinedByString:@"\n"];
}

// Whether the tweak is in SpringBoard at all is the first thing worth knowing,
// and the log is the only place that can say so.
- (NSString *)lastSpringBoardLine {
    NSString *log = DSDiagnosticsRead();
    if (log.length == 0) return @"has not written anything yet";

    NSString *found = nil;
    for (NSString *line in [log componentsSeparatedByString:@"\n"]) {
        if ([line rangeOfString:@"SpringBoard:"].location != NSNotFound) found = line;
    }
    return found ?: @"nothing from SpringBoard in the log";
}

- (NSString *)installedVersion {
    for (NSString *path in @[ @"/var/jb/var/lib/dpkg/status", @"/var/lib/dpkg/status" ]) {
        NSString *status = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if (status.length == 0) continue;
        NSRange stanza = [status rangeOfString:[@"Package: " stringByAppendingString:kDSPackageIdentifier]];
        if (stanza.location == NSNotFound) continue;
        NSString *tail = [status substringFromIndex:stanza.location];
        NSRange key = [tail rangeOfString:@"\nVersion: "];
        if (key.location == NSNotFound) continue;
        NSString *after = [tail substringFromIndex:NSMaxRange(key)];
        NSRange newline = [after rangeOfString:@"\n"];
        return newline.location == NSNotFound ? after : [after substringToIndex:newline.location];
    }
    return @"not found in dpkg";
}

#pragma mark - Actions

- (void)refreshLog {
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (void)copyLog {
    NSString *log = [NSString stringWithFormat:@"%@\n\n%@", [self stateSummary], DSDiagnosticsRead()];
    UIPasteboard.generalPasteboard.string = log;
    [self showNote:@"Copied" message:@"The log is on the clipboard."];
}

- (void)clearLog {
    DSDiagnosticsClear();
    [self refreshLog];
}

- (void)openStage {
    notify_post(kDSOpenStageNotification);
    [self showNote:@"Asked SpringBoard To Open The Stage"
           message:@"Leave Settings and look at the screen. If nothing appeared, come back and read the log."];
}

- (void)showNote:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                  message:message
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
