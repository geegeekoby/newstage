#import "DSExclusions.h"

BOOL DSIdentifierIsExcludedFromStage(NSString *identifier) {
    if (identifier.length == 0) return YES;

    static NSSet<NSString *> *excluded;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        excluded = [NSSet setWithArray:@[
            // SpringBoard hosts the stage rather than living on it, and
            // PaperBoard owns the wallpaper behind it.
            @"com.apple.springboard",
            @"com.apple.PaperBoard",

            // System stubs and services with no standalone interface. "Web" is
            // the hidden web-clip stub the stock tweak also hides.
            @"com.apple.webapp",
            @"com.apple.Web",
            @"com.apple.InCallService",
            @"com.apple.PassbookUIService",
            @"com.apple.SafariViewService",
            @"com.apple.SharedWebCredentialViewService",

            // Package managers.
            @"org.coolstar.SileoStore",
            @"org.coolstar.Cydia",
            @"xyz.willy.Zebra",
            @"com.saurik.Cydia",
            @"me.apptapp.installer",

            // File managers, terminals and the jailbreaks' own apps.
            @"com.tigisoftware.Filza",
            @"com.tigisoftware.ADManager",
            @"com.serena.Santander",
            @"ws.hbang.Terminal",
            @"com.opa334.Dopamine",
            @"com.nathan.nathanlr",
            @"com.opa334.TrollStore",
            @"com.opa334.TrollStorePersistenceHelper",
            @"com.palera1n.loader",
        ]];
    });

    if ([excluded containsObject:identifier]) return YES;

    // This tweak's own bundles, and anything that has clearly said it is part of
    // the jailbreak rather than an app to multitask with.
    if ([identifier hasPrefix:@"com.recreated.dynamicstage"]) return YES;

    return NO;
}
