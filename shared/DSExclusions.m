#import "DSExclusions.h"

BOOL DSIdentifierIsExcludedFromStage(NSString *identifier) {
    if (identifier.length == 0) return YES;

    static NSSet<NSString *> *excluded;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        excluded = [NSSet setWithArray:@[
            @"com.apple.springboard",
            @"com.apple.PaperBoard",
            @"com.apple.BackBoard",
            @"com.apple.backboardd",
            @"com.apple.KeyboardArbiter",
            @"com.apple.Preferences",
            @"com.apple.Spotlight",
            @"com.apple.searchd",
            @"com.apple.assertiond",
            @"com.apple.SpringBoard",
            @"com.apple.wallpaper",
            @"com.apple.WallpaperAgent",
            @"com.apple.WallpaperSettings",
            @"com.apple.chronod",
            @"com.apple.SystemUI",

            @"com.apple.webapp",
            @"com.apple.Web",
            @"com.apple.InCallService",
            @"com.apple.PassbookUIService",
            @"com.apple.SafariViewService",
            @"com.apple.SharedWebCredentialViewService",
            @"com.apple.AuthKitUIService",
            @"com.apple.ScreenshotServicesService",
            @"com.apple.UIKitSystem",
            @"com.apple.WebSheet",
            @"com.apple.PreBoard",

            @"org.coolstar.SileoStore",
            @"org.coolstar.Cydia",
            @"xyz.willy.Zebra",
            @"com.saurik.Cydia",
            @"me.apptapp.installer",

            @"com.tigisoftware.Filza",
            @"com.tigisoftware.ADManager",
            @"com.serena.Santander",
            @"ws.hbang.Terminal",
            @"com.opa334.Dopamine",
            @"com.nathan.nathanlr",
            @"com.opa334.TrollStore",
            @"com.opa334.TrollStorePersistenceHelper",
            @"com.palera1n.loader",
            @"org.coolstar.electra",
            @"org.coolstar.SafeMode",
        ]];
    });

    if ([excluded containsObject:identifier]) return YES;
    if ([identifier hasPrefix:@"com.recreated.dynamicstage"]) return YES;
    if ([identifier hasPrefix:@"com.apple.springboard."]) return YES;
    if ([identifier hasPrefix:@"com.apple.Wallpaper"]) return YES;
    if ([identifier hasPrefix:@"com.apple.wallpaper"]) return YES;
    return NO;
}
