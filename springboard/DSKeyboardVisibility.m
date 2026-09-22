#import "DSKeyboardVisibility.h"
#import "DSConstants.h"
#import "DSDiagnostics.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static BOOL DSClassNameLooksLikeKeyboard(NSString *name) {
    if (name.length == 0) return NO;
    if ([name rangeOfString:@"Keyboard"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"TextEffects"].location != NSNotFound) return YES;
    return NO;
}

static CGRect DSKeyboardViewFrameInView(UIView *view) {
    NSString *name = NSStringFromClass(view.class);
    BOOL isKeyboard = [name rangeOfString:@"UIKeyboard"].location == 0 ||
                      [name rangeOfString:@"InputSetHostView"].location != NSNotFound;
    if (isKeyboard && !view.hidden && view.alpha > 0.01 && !CGRectIsEmpty(view.bounds)) {
        UIWindow *window = view.window;
        return window ? [view convertRect:view.bounds toView:nil] : view.frame;
    }
    if (view.hidden || view.alpha < 0.01) return CGRectNull;
    for (UIView *child in view.subviews) {
        CGRect found = DSKeyboardViewFrameInView(child);
        if (!CGRectIsNull(found)) return found;
    }
    return CGRectNull;
}

static void DSVisitApplicationWindows(void (^visitor)(UIWindow *window)) {
    NSMutableSet *seen = [NSMutableSet set];
    NSArray *appWindows = [UIApplication.sharedApplication.windows copy];
    for (UIWindow *window in appWindows) {
        if (!window || [seen containsObject:window]) continue;
        [seen addObject:window];
        visitor(window);
    }
    if (@available(iOS 13.0, *)) {
        NSArray *scenes = [UIApplication.sharedApplication.connectedScenes.allObjects copy];
        for (UIScene *scene in scenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            NSArray *windows = [((UIWindowScene *)scene).windows copy];
            for (UIWindow *window in windows) {
                if (!window || [seen containsObject:window]) continue;
                [seen addObject:window];
                visitor(window);
            }
        }
    }
}

static BOOL DSKeyboardFrameIsOnScreen(CGRect keys, CGRect screen) {
    if (CGRectIsNull(keys)) return NO;
    if (CGRectGetMinY(keys) >= CGRectGetMaxY(screen) - 1.0) return NO;
    if (CGRectGetHeight(keys) < kDSKeyboardPresentHeight) return NO;
    return YES;
}

CGRect DSVisibleKeyboardFrameOnScreen(void) {
    __block CGRect keyboard = CGRectNull;
    CGRect screen = UIScreen.mainScreen.bounds;
    DSVisitApplicationWindows(^(UIWindow *candidate) {
        if (!CGRectIsNull(keyboard)) return;
        if (candidate.hidden || candidate.alpha < 0.01) return;
        if (!DSClassNameLooksLikeKeyboard(NSStringFromClass(candidate.class))) return;
        CGRect keys = DSKeyboardViewFrameInView(candidate);
        if (!DSKeyboardFrameIsOnScreen(keys, screen)) return;
        keyboard = keys;
    });
    return keyboard;
}

static NSString *DSWindowSceneName(UIWindow *window) {
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = window.windowScene;
        if (!scene) return @"none";
        NSString *identifier = scene.session.persistentIdentifier;
        if (identifier.length == 0) identifier = @"?";
        if (identifier.length > 42) identifier = [identifier substringToIndex:42];
        return identifier;
    }
    return @"n/a";
}

NSString *DSKeyboardWindowCensus(void) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    DSVisitApplicationWindows(^(UIWindow *window) {
        if (parts.count >= 4) return;
        NSString *name = NSStringFromClass(window.class);
        if (!DSClassNameLooksLikeKeyboard(name)) return;
        CGRect keys = DSKeyboardViewFrameInView(window);
        NSString *keyText = CGRectIsNull(keys) ? @"none" : NSStringFromCGRect(keys);
        UIView *superview = window.superview;
        [parts addObject:[NSString stringWithFormat:@"%@ scene=%@ super=%@ hid=%d a=%.2f lvl=%.0f frame=%@ keys=%@",
                          name,
                          DSWindowSceneName(window),
                          superview ? NSStringFromClass(superview.class) : @"none",
                          window.hidden,
                          window.alpha,
                          window.windowLevel,
                          NSStringFromCGRect(window.frame),
                          keyText]];
    });
    if (parts.count == 0) return @"census=0";
    return [NSString stringWithFormat:@"census=%lu %@", (unsigned long)parts.count, [parts componentsJoinedByString:@" || "]];
}

static NSString *DSFlatFile(NSString *path, NSUInteger limit) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSDictionary *attrs = [files attributesOfItemAtPath:path error:nil];
    if (!attrs) return @"missing";
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (text.length == 0) text = @"empty";
    NSArray *pieces = [text componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    for (NSString *piece in pieces) {
        if (piece.length) [kept addObject:piece];
    }
    NSString *flat = [kept componentsJoinedByString:@" "];
    if (flat.length > limit) flat = [[flat substringToIndex:limit] stringByAppendingString:@"..."];
    NSDate *modified = attrs[NSFileModificationDate];
    NSTimeInterval age = modified ? -[modified timeIntervalSinceNow] : -1.0;
    return [NSString stringWithFormat:@"age=%.0fs %@", age, flat];
}

void DSLogStagedAppInjection(NSString *why) {
    NSString *libs = DSFlatFile(@"/var/jb/Library/MobileSubstrate/DynamicLibraries/DynamicStageApp.plist", 220);
    NSString *inject = DSFlatFile(@"/var/jb/usr/lib/TweakInject/DynamicStageApp.plist", 220);
    NSString *ctor = DSFlatFile(@"/var/tmp/com.recreated.dynamicstage.ctor", 180);
    if ([ctor isEqualToString:@"missing"]) {
        ctor = DSFlatFile(@"/var/jb/tmp/com.recreated.dynamicstage.ctor", 180);
    }
    NSString *mapped = DSFlatFile(@"/var/tmp/com.recreated.dynamicstage.mapped", 60);
    if ([mapped isEqualToString:@"missing"]) {
        mapped = DSFlatFile(@"/var/jb/tmp/com.recreated.dynamicstage.mapped", 60);
    }
    DSDiagnosticsRecordFormat(@"SpringBoard: %@ ctor=[%@] mapped=[%@] libsPlist=[%@] injectPlist=[%@]",
                              why ?: @"filter", ctor, mapped, libs, inject);
}

static NSString *DSClaimedKeyboardStatus = @"win=none";

static BOOL DSExternalKeyboardRaised = NO;
static NSMapTable<UIWindow *, NSDictionary *> *DSKeyboardPlacements = nil;

static NSMapTable<UIWindow *, NSDictionary *> *DSKeyboardPlacementTable(void) {
    if (!DSKeyboardPlacements) {
        DSKeyboardPlacements = [NSMapTable weakToStrongObjectsMapTable];
    }
    return DSKeyboardPlacements;
}

static BOOL DSSceneNameIsRemoteKeyboard(NSString *name) {
    return [name rangeOfString:@"remote-keyboard"].location != NSNotFound;
}

static BOOL DSSceneNameIsAperture(NSString *name) {
    if (name.length == 0) return NO;
    return [name rangeOfString:@"Aperture"].location != NSNotFound ||
           [name rangeOfString:@"aperture"].location != NSNotFound;
}

static NSString *DSSceneIdentifier(id scene) {
    if (![scene isKindOfClass:UIScene.class]) return @"";
    return ((UIScene *)scene).session.persistentIdentifier ?: @"";
}

// The stage window already lives on SpringBoard's foreground scene. A keyboard
// window has to be on that same scene before its level can sit above the card.
static UIWindowScene *DSForegroundScene(void) {
    __block UIWindowScene *stage = nil;
    __block UIWindowScene *home = nil;
    DSVisitApplicationWindows(^(UIWindow *window) {
        if (window.hidden || !window.windowScene) return;
        NSString *name = NSStringFromClass(window.class);
        if ([name rangeOfString:@"StageWindow"].location != NSNotFound) stage = window.windowScene;
        if ([name rangeOfString:@"HomeScreenWindow"].location != NSNotFound) home = window.windowScene;
    });
    return stage ?: home;
}

static void DSRememberKeyboardWindow(UIWindow *window) {
    if (!window) return;
    NSMapTable *table = DSKeyboardPlacementTable();
    if ([table objectForKey:window]) return;
    [table setObject:@{
        @"scene" : window.windowScene ?: (id)NSNull.null,
        @"level" : @(window.windowLevel)
    } forKey:window];
}

CGFloat DSKeyboardWindowLevelAboveStage(void) {
    return UIWindowLevelStatusBar + 5000.0;
}

BOOL DSKeyboardWindowShouldStayAboveStage(id window) {
    if (!DSExternalKeyboardRaised || ![window isKindOfClass:UIWindow.class]) return NO;
    return DSClassNameLooksLikeKeyboard(NSStringFromClass([(UIWindow *)window class]));
}

id DSReplacementSceneForKeyboardWindow(id window, id proposedScene) {
    if (!DSExternalKeyboardRaised || ![window isKindOfClass:UIWindow.class]) return nil;
    if (!DSClassNameLooksLikeKeyboard(NSStringFromClass([(UIWindow *)window class]))) return nil;
    if (!DSSceneNameIsAperture(DSSceneIdentifier(proposedScene))) return nil;
    UIWindowScene *foreground = DSForegroundScene();
    if (!foreground || proposedScene == foreground) return nil;
    return foreground;
}

BOOL DSExternalKeyboardCoversStage(void) {
    return DSExternalKeyboardRaised;
}

BOOL DSRevealSpringBoardKeyboard(void) {
    // UIKit creates this window when the app says the keyboard is remote.
    // Never create one ourselves, never unhide an empty full-screen window,
    // never use alert level. A window that already contains keys is lifted
    // just above the stage so those keys are not clipped to the card.
    CGRect screen = UIScreen.mainScreen.bounds;
    __block BOOL revealed = NO;
    __block CGRect shown = CGRectNull;
    __block CGFloat level = 0;
    __block NSString *windowName = nil;
    DSVisitApplicationWindows(^(UIWindow *window) {
        if (revealed) return;
        if (!DSClassNameLooksLikeKeyboard(NSStringFromClass(window.class))) return;
        if (window.hidden || window.alpha < 0.01) return;
        CGRect keys = DSKeyboardViewFrameInView(window);
        if (!DSKeyboardFrameIsOnScreen(keys, screen)) return;
        @try {
            if (window.windowLevel < UIWindowLevelStatusBar) {
                window.windowLevel = UIWindowLevelStatusBar;
            }
        } @catch (NSException *exception) {
        }
        revealed = YES;
        shown = keys;
        level = window.windowLevel;
        windowName = [NSString stringWithFormat:@"%@ scene=%@",
                      NSStringFromClass(window.class), DSWindowSceneName(window)];
    });
    DSExternalKeyboardRaised = revealed;
    if (revealed) {
        DSClaimedKeyboardStatus = [NSString stringWithFormat:@"win=raised %@ lvl=%.0f keys=%@",
                                   windowName ?: @"?", level, NSStringFromCGRect(shown)];
        return YES;
    }
    DSClaimedKeyboardStatus = @"win=none";
    return NO;
}

void DSPresentArbiterKeyboardLayer(id sceneLayer) {
    if (!sceneLayer) DSClaimedKeyboardStatus = @"win=hidden";
}

void DSRestoreRemoteKeyboardPlacement(void) {
    // Clear this before touching levels. The window hook pins any keyboard
    // window at 6000 while the flag is set, including the restore itself.
    DSExternalKeyboardRaised = NO;
    NSMapTable *table = DSKeyboardPlacements;
    NSArray<UIWindow *> *windows = table ? [table.keyEnumerator.allObjects copy] : @[];
    if (windows.count == 0) return;
    for (UIWindow *window in windows) {
        NSDictionary *saved = [table objectForKey:window];
        id scene = saved[@"scene"];
        CGFloat level = [saved[@"level"] doubleValue];
        @try {
            if ([scene isKindOfClass:UIWindowScene.class] && window.windowScene != scene) {
                window.windowScene = scene;
            }
            window.windowLevel = level;
        } @catch (NSException *exception) {
        }
    }
    [table removeAllObjects];
    DSClaimedKeyboardStatus = @"win=restored";
}

BOOL DSPlaceRemoteKeyboardAboveStage(id stageWindowObject) {
    (void)stageWindowObject;
    return DSRaiseKeyboardWindowAboveStage();
}

BOOL DSRaiseKeyboardWindowAboveStage(void) {
    UIWindowScene *foreground = DSForegroundScene();
    CGRect screen = UIScreen.mainScreen.bounds;
    NSMutableArray<NSString *> *notes = [NSMutableArray array];
    __block NSInteger raised = 0;
    __block NSInteger moved = 0;
    // Pin levels before the loop. setWindowLevel: is hooked and would otherwise
    // let UIKit write level 10 back onto a window we have not finished yet.
    DSExternalKeyboardRaised = YES;
    DSVisitApplicationWindows(^(UIWindow *window) {
        if (!DSClassNameLooksLikeKeyboard(NSStringFromClass(window.class))) return;
        if (window.hidden || window.alpha < 0.01) return;
        NSString *before = DSWindowSceneName(window);
        BOOL remote = DSSceneNameIsRemoteKeyboard(before);
        BOOL aperture = DSSceneNameIsAperture(before);
        CGRect keys = DSKeyboardViewFrameInView(window);
        BOOL hasKeys = DSKeyboardFrameIsOnScreen(keys, screen);
        if (!remote && !aperture && !hasKeys) return;
        @try {
            DSRememberKeyboardWindow(window);
            // SystemAperture clips to the island. The remote-keyboard scene is
            // left alone: moving that window off its scene stopped the keys
            // painting. An aperture window can move onto the stage's scene.
            if (aperture && foreground && window.windowScene != foreground) {
                window.windowScene = foreground;
                moved++;
            }
            window.windowLevel = DSKeyboardWindowLevelAboveStage();
            raised++;
            if (notes.count < 4) {
                [notes addObject:[NSString stringWithFormat:@"%@->%@ lvl=%.0f keys=%@",
                                  before,
                                  DSWindowSceneName(window),
                                  window.windowLevel,
                                  hasKeys ? @"yes" : @"no"]];
            }
        } @catch (NSException *exception) {
        }
    });
    if (raised == 0) {
        DSExternalKeyboardRaised = NO;
        DSClaimedKeyboardStatus = @"win=none";
        return NO;
    }
    DSClaimedKeyboardStatus = [NSString stringWithFormat:@"win=above-stage n=%ld moved=%ld %@",
                               (long)raised,
                               (long)moved,
                               [notes componentsJoinedByString:@" | "]];
    return YES;
}

void DSHidePresentedArbiterKeyboard(void) {
    DSRestoreRemoteKeyboardPlacement();
}

BOOL DSShowArbiterKeyboardAboveStage(id sceneLayer) {
    (void)sceneLayer;
    return DSRevealSpringBoardKeyboard();
}

NSString *DSPresentedKeyboardWindowStatus(void) {
    return DSClaimedKeyboardStatus ?: @"win=none";
}
