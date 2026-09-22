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
    UIWindowScene *foreground = DSForegroundScene();
    if (!foreground || proposedScene == foreground) return nil;
    // remote-keyboard, SystemAperture, and any other scene sit under the stage
    // no matter what level they use. The stage's own scene is the one that
    // can paint above the card.
    return foreground;
}

BOOL DSExternalKeyboardCoversStage(void) {
    return DSExternalKeyboardRaised;
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

BOOL DSRaiseKeyboardWindowAboveStage(void) {
    UIWindowScene *foreground = DSForegroundScene();
    CGRect screen = UIScreen.mainScreen.bounds;
    NSMutableArray<NSString *> *notes = [NSMutableArray array];
    __block NSInteger raised = 0;
    __block NSInteger moved = 0;
    // Pin levels before the loop. setWindowLevel: is hooked and would otherwise
    // let UIKit write level 10 or 20 back onto a window we have not finished yet.
    DSExternalKeyboardRaised = YES;
    DSVisitApplicationWindows(^(UIWindow *window) {
        NSString *className = NSStringFromClass(window.class);
        if (!DSClassNameLooksLikeKeyboard(className)) return;
        CGRect keys = DSKeyboardViewFrameInView(window);
        BOOL hasKeys = DSKeyboardFrameIsOnScreen(keys, screen);
        CGFloat height = CGRectGetHeight(window.frame);
        BOOL keyboardBand = height >= 80.0 && height <= CGRectGetHeight(screen) * 0.55;
        BOOL medusa = [className rangeOfString:@"Medusa"].location != NSNotFound;
        // A hidden full-screen text-effects window is not the keyboard. Unhiding
        // one of those covers the wallpaper. A Medusa keyboard or a short band
        // is the window that was sitting at level 20.
        if (window.hidden || window.alpha < 0.01) {
            if (!hasKeys && !medusa && !keyboardBand) return;
        }
        NSString *before = DSWindowSceneName(window);
        @try {
            DSRememberKeyboardWindow(window);
            if ((hasKeys || medusa || keyboardBand) && (window.hidden || window.alpha < 0.01)) {
                window.alpha = 1.0;
                window.hidden = NO;
            }
            if (foreground && window.windowScene != foreground) {
                window.windowScene = foreground;
                moved++;
            }
            window.windowLevel = DSKeyboardWindowLevelAboveStage();
            window.clipsToBounds = NO;
            window.layer.masksToBounds = NO;
            raised++;
            if (notes.count < 6) {
                [notes addObject:[NSString stringWithFormat:@"%@ %@->%@ lvl=%.0f keys=%@",
                                  className,
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

NSString *DSPresentedKeyboardWindowStatus(void) {
    return DSClaimedKeyboardStatus ?: @"win=none";
}
