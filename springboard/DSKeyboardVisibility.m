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

static CGRect DSRectOnScreen(UIWindow *window, CGRect rectInWindow) {
    @try {
        if (@available(iOS 13.0, *)) {
            id space = window.screen.coordinateSpace;
            if (space) return [window convertRect:rectInWindow toCoordinateSpace:space];
        }
    } @catch (NSException *exception) {
    }
    rectInWindow.origin.x += CGRectGetMinX(window.frame);
    rectInWindow.origin.y += CGRectGetMinY(window.frame);
    return rectInWindow;
}

static BOOL DSPlausibleKeyStrip(CGRect frameInWindow, UIWindow *window) {
    CGFloat screenHeight = CGRectGetHeight(UIScreen.mainScreen.bounds);
    CGFloat height = CGRectGetHeight(frameInWindow);
    if (screenHeight < 1.0 || height < kDSKeyboardPresentHeight) return NO;
    if (height > screenHeight * 0.5) return NO;
    CGRect onScreen = DSRectOnScreen(window, frameInWindow);
    if (CGRectGetMinY(onScreen) < screenHeight * 0.35) return NO;
    return YES;
}

static void DSCollectKeyStrips(UIView *view, UIWindow *window, CGRect *best, NSInteger depth) {
    if (depth > 12 || ![view isKindOfClass:UIView.class] || view.hidden || view.alpha < 0.01) return;
    NSString *name = NSStringFromClass(view.class);
    BOOL isKeyboard = [name rangeOfString:@"UIKeyboard"].location == 0 ||
                      [name rangeOfString:@"InputSetHostView"].location != NSNotFound;
    if (isKeyboard && !CGRectIsEmpty(view.bounds)) {
        CGRect frame = [view convertRect:view.bounds toView:window];
        if (DSPlausibleKeyStrip(frame, window)) {
            if (CGRectIsNull(*best) || CGRectGetHeight(frame) > CGRectGetHeight(*best)) *best = frame;
        }
    }
    for (UIView *child in view.subviews) {
        DSCollectKeyStrips(child, window, best, depth + 1);
    }
}

CGRect DSKeyboardKeysInWindow(id window) {
    if (![window isKindOfClass:UIWindow.class]) return CGRectNull;
    CGRect best = CGRectNull;
    DSCollectKeyStrips((UIWindow *)window, (UIWindow *)window, &best, 0);
    return best;
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
    return [NSString stringWithFormat:@"census=%lu %@", (unsigned long)parts.count,
            [parts componentsJoinedByString:@" || "]];
}

static NSString *DSFlatFile(NSString *path, NSUInteger limit) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSDictionary *attrs = [files attributesOfItemAtPath:path error:nil];
    if (!attrs) return @"missing";
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (text.length == 0) text = @"empty";
    NSArray *pieces = [text componentsSeparatedByCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
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
    NSString *sceneName = @"";
    if (@available(iOS 13.0, *)) {
        sceneName = window.windowScene.session.persistentIdentifier ?: @"";
    }
    [table setObject:@{
        @"scene" : window.windowScene ?: (id)NSNull.null,
        @"level" : @(window.windowLevel),
        @"touches" : @(window.userInteractionEnabled),
        @"sceneName" : sceneName ?: @""
    } forKey:window];
}

static NSString *DSRememberedSceneName(UIWindow *window) {
    NSDictionary *saved = [DSKeyboardPlacementTable() objectForKey:window];
    NSString *name = saved[@"sceneName"];
    return [name isKindOfClass:NSString.class] ? name : @"";
}

static BOOL DSNameContains(NSString *name, NSString *needle) {
    return name.length > 0 && needle.length > 0 &&
           [name rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static BOOL DSWindowCameFromAperture(UIWindow *window) {
    if (DSNameContains(NSStringFromClass(window.class), @"Aperture")) return YES;
    return DSNameContains(DSRememberedSceneName(window), @"Aperture");
}

static BOOL DSWindowCameFromRemoteKeyboard(UIWindow *window) {
    if (DSNameContains(NSStringFromClass(window.class), @"RemoteKeyboard")) return YES;
    NSString *scene = DSRememberedSceneName(window);
    return DSNameContains(scene, @"remote-keyboard") || DSNameContains(scene, @"RemoteKeyboard");
}

static BOOL DSKeyboardWindowBlocked(UIWindow *window) {
    if (DSNameContains(NSStringFromClass(window.class), @"Medusa")) return YES;
    return DSWindowCameFromAperture(window);
}

static __weak UIWindow *DSCachedActiveKeyboardWindow = nil;
static CFAbsoluteTime DSCachedActiveKeyboardWindowAt = 0;
static BOOL DSAdjustingKeyboardInteraction = NO;

static void DSInvalidateActiveKeyboardWindow(void) {
    DSCachedActiveKeyboardWindow = nil;
    DSCachedActiveKeyboardWindowAt = 0;
}

static CGFloat DSKeyStripScreenMinY(UIWindow *window, CGRect keysInWindow) {
    @try {
        if (@available(iOS 13.0, *)) {
            id space = window.screen.coordinateSpace;
            if (space) {
                CGRect onScreen = [window convertRect:keysInWindow toCoordinateSpace:space];
                return CGRectGetMinY(onScreen);
            }
        }
    } @catch (NSException *exception) {
    }
    return CGRectGetMinY(window.frame) + CGRectGetMinY(keysInWindow);
}

static void DSSetRememberedInteraction(UIWindow *window, BOOL allow) {
    if (DSAdjustingKeyboardInteraction || !window) return;
    if (![DSKeyboardPlacementTable() objectForKey:window]) return;
    if (window.userInteractionEnabled == allow) return;
    DSAdjustingKeyboardInteraction = YES;
    @try {
        window.userInteractionEnabled = allow;
    } @catch (NSException *exception) {
    }
    DSAdjustingKeyboardInteraction = NO;
}

static UIWindow *DSActiveKeyboardWindow(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (DSCachedActiveKeyboardWindow && (now - DSCachedActiveKeyboardWindowAt) < 0.1) {
        return DSCachedActiveKeyboardWindow;
    }
    __block UIWindow *best = nil;
    __block CGFloat bestMinY = -CGFLOAT_MAX;
    __block BOOL bestRemote = NO;
    __block BOOL bestVisible = NO;
    DSVisitApplicationWindows(^(UIWindow *window) {
        if (!DSClassNameLooksLikeKeyboard(NSStringFromClass(window.class))) return;
        if (DSKeyboardWindowBlocked(window)) return;
        CGRect keys = DSKeyboardKeysInWindow(window);
        if (CGRectIsNull(keys)) return;
        BOOL visible = !window.hidden && window.alpha > 0.01;
        CGFloat minY = DSKeyStripScreenMinY(window, keys);
        BOOL remote = DSWindowCameFromRemoteKeyboard(window);
        BOOL better = NO;
        if (!best) {
            better = YES;
        } else if (visible && !bestVisible) {
            better = YES;
        } else if (visible == bestVisible && minY > bestMinY + 1.0) {
            better = YES;
        } else if (visible == bestVisible && fabs(minY - bestMinY) <= 1.0 && remote && !bestRemote) {
            better = YES;
        }
        if (!better) return;
        best = window;
        bestMinY = minY;
        bestRemote = remote;
        bestVisible = visible;
    });
    DSCachedActiveKeyboardWindow = best;
    DSCachedActiveKeyboardWindowAt = now;
    return best;
}

static void DSSilenceExtraKeyboardWindows(void) {
    if (!DSExternalKeyboardRaised) return;
    UIWindow *active = DSActiveKeyboardWindow();
    DSVisitApplicationWindows(^(UIWindow *window) {
        if (!DSClassNameLooksLikeKeyboard(NSStringFromClass(window.class))) return;
        if (![DSKeyboardPlacementTable() objectForKey:window]) return;
        BOOL allow = YES;
        if (DSKeyboardWindowBlocked(window)) allow = NO;
        else if (active) allow = (window == active);
        DSSetRememberedInteraction(window, allow);
    });
}

BOOL DSKeyboardWindowIsInteractive(id windowObject) {
    if (!DSExternalKeyboardRaised || ![windowObject isKindOfClass:UIWindow.class]) return YES;
    UIWindow *window = (UIWindow *)windowObject;
    if (!DSClassNameLooksLikeKeyboard(NSStringFromClass(window.class))) return YES;
    if (DSKeyboardWindowBlocked(window)) {
        DSSetRememberedInteraction(window, NO);
        return NO;
    }
    UIWindow *active = DSActiveKeyboardWindow();
    if (!active) return YES;
    BOOL allow = (window == active);
    DSSetRememberedInteraction(window, allow);
    return allow;
}

CGRect DSInteractiveKeyboardFrameOnScreen(void) {
    if (!DSExternalKeyboardRaised) return CGRectNull;
    UIWindow *active = DSActiveKeyboardWindow();
    if (!active) return CGRectNull;
    CGRect keys = DSKeyboardKeysInWindow(active);
    if (CGRectIsNull(keys)) return CGRectNull;
    @try {
        if (@available(iOS 13.0, *)) {
            id space = active.screen.coordinateSpace;
            if (space) return [active convertRect:keys toCoordinateSpace:space];
        }
    } @catch (NSException *exception) {
    }
    return CGRectMake(CGRectGetMinX(active.frame) + CGRectGetMinX(keys),
                      CGRectGetMinY(active.frame) + CGRectGetMinY(keys),
                      CGRectGetWidth(keys),
                      CGRectGetHeight(keys));
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
    if (!DSClassNameLooksLikeKeyboard(NSStringFromClass([(UIWindow *)window class