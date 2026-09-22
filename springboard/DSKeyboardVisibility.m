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
static __weak UIWindow *DSMovedKeyboardWindow = nil;
static UIWindowScene *DSMovedKeyboardScene = nil;
static CGFloat DSMovedKeyboardLevel = 0.0;

static BOOL DSSceneNameIsRemoteKeyboard(NSString *name) {
    return [name rangeOfString:@"remote-keyboard"].location != NSNotFound;
}

static BOOL DSSceneNameIsAperture(NSString *name) {
    if (name.length == 0) return NO;
    return [name rangeOfString:@"Aperture"].location != NSNotFound ||
           [name rangeOfString:@"aperture"].location != NSNotFound;
}

static UIWindowScene *DSRemoteKeyboardScene(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            NSString *identifier = scene.session.persistentIdentifier ?: @"";
            if (DSSceneNameIsRemoteKeyboard(identifier)) return (UIWindowScene *)scene;
        }
    }
    return nil;
}

CGFloat DSKeyboardWindowLevelAboveStage(void) {
    return UIWindowLevelStatusBar + 5000.0;
}

BOOL DSKeyboardWindowShouldStayAboveStage(id window) {
    return DSExternalKeyboardRaised && window != nil && window == DSMovedKeyboardWindow;
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
    UIWindow *window = DSMovedKeyboardWindow;
    UIWindowScene *scene = DSMovedKeyboardScene;
    CGFloat level = DSMovedKeyboardLevel;
    DSMovedKeyboardWindow = nil;
    DSMovedKeyboardScene = nil;
    DSMovedKeyboardLevel = 0.0;
    DSExternalKeyboardRaised = NO;
    if (!window) {
        DSClaimedKeyboardStatus = @"win=hidden";
        return;
    }
    @try {
        if (scene && window.windowScene != scene) {
            window.windowScene = scene;
        }
        window.windowLevel = level;
    } @catch (NSException *exception) {
    }
    DSClaimedKeyboardStatus = @"win=restored";
}

BOOL DSPlaceRemoteKeyboardAboveStage(id stageWindowObject) {
    UIWindow *stageWindow = [stageWindowObject isKindOfClass:UIWindow.class] ? stageWindowObject : nil;
    UIWindowScene *stageScene = stageWindow.windowScene;
    if (!stageScene) {
        DSClaimedKeyboardStatus = @"win=no-stage-scene";
        DSExternalKeyboardRaised = NO;
        return NO;
    }
    CGRect screen = UIScreen.mainScreen.bounds;
    __block UIWindow *target = nil;
    __block CGRect shown = CGRectNull;
    DSVisitApplicationWindows(^(UIWindow *window) {
        if (target) return;
        if (!DSSceneNameIsRemoteKeyboard(DSWindowSceneName(window)) &&
            window != DSMovedKeyboardWindow) {
            return;
        }
        if (window.hidden || window.alpha < 0.01) return;
        CGRect keys = DSKeyboardViewFrameInView(window);
        if (!DSKeyboardFrameIsOnScreen(keys, screen)) return;
        target = window;
        shown = keys;
    });
    if (!target) {
        DSClaimedKeyboardStatus = @"win=no-remote-keyboard-scene";
        DSExternalKeyboardRaised = NO;
        return NO;
    }
    @try {
        if (DSMovedKeyboardWindow && DSMovedKeyboardWindow != target) {
            DSRestoreRemoteKeyboardPlacement();
        }
        UIWindow *previousKey = nil;
        for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
            if (candidate.isKeyWindow && candidate != target) {
                previousKey = candidate;
                break;
            }
        }
        if (!DSMovedKeyboardWindow) {
            DSMovedKeyboardWindow = target;
            DSMovedKeyboardScene = target.windowScene;
            DSMovedKeyboardLevel = target.windowLevel;
        }
        NSString *before = DSWindowSceneName(target);
        if (target.windowScene != stageScene) {
            target.windowScene = stageScene;
        }
        if (target.windowLevel < UIWindowLevelStatusBar) {
            target.windowLevel = UIWindowLevelStatusBar;
        }
        if (target.windowScene != stageScene) {
            target.windowLevel = DSMovedKeyboardLevel;
            DSMovedKeyboardWindow = nil;
            DSMovedKeyboardScene = nil;
            DSMovedKeyboardLevel = 0.0;
            DSExternalKeyboardRaised = NO;
            DSClaimedKeyboardStatus = [NSString stringWithFormat:@"win=scene-rejected from=%@ now=%@ stage=%@ lvl=%.0f keys=%@",
                                       before,
                                       DSWindowSceneName(target),
                                       DSWindowSceneName(stageWindow),
                                       target.windowLevel,
                                       NSStringFromCGRect(shown)];
            return NO;
        }
        if (target.isKeyWindow && previousKey) {
            [previousKey makeKeyWindow];
        }
        DSExternalKeyboardRaised = YES;
        DSClaimedKeyboardStatus = [NSString stringWithFormat:@"win=on-stage-scene from=%@ now=%@ stage=%@ lvl=%.0f keys=%@",
                                   before,
                                   DSWindowSceneName(target),
                                   DSWindowSceneName(stageWindow),
                                   target.windowLevel,
                                   NSStringFromCGRect(shown)];
        return YES;
    } @catch (NSException *exception) {
        NSString *reason = exception.reason ?: @"?";
        DSRestoreRemoteKeyboardPlacement();
        DSClaimedKeyboardStatus = [NSString stringWithFormat:@"win=move-failed %@", reason];
        return NO;
    }
}

BOOL DSRaiseKeyboardWindowAboveStage(void) {
    CGRect screen = UIScreen.mainScreen.bounds;
    __block UIWindow *target = nil;
    __block CGRect shown = CGRectNull;
    __block NSInteger rank = -1;
    DSVisitApplicationWindows(^(UIWindow *window) {
        if (!DSClassNameLooksLikeKeyboard(NSStringFromClass(window.class))) return;
        if (window.hidden || window.alpha < 0.01) return;
        NSString *sceneName = DSWindowSceneName(window);
        BOOL remote = DSSceneNameIsRemoteKeyboard(sceneName);
        BOOL aperture = DSSceneNameIsAperture(sceneName);
        CGRect keys = DSKeyboardViewFrameInView(window);
        BOOL hasKeys = DSKeyboardFrameIsOnScreen(keys, screen);
        if (!remote && !aperture && !hasKeys && window != DSMovedKeyboardWindow) return;
        NSInteger score = 0;
        if (hasKeys) score += 4;
        if (aperture) score += 2;
        if (remote) score += 1;
        if (score > rank) {
            rank = score;
            target = window;
            shown = keys;
        }
    });
    if (!target) {
        DSClaimedKeyboardStatus = @"win=none";
        DSExternalKeyboardRaised = NO;
        return NO;
    }
    @try {
        if (!DSMovedKeyboardWindow) {
            DSMovedKeyboardWindow = target;
            DSMovedKeyboardScene = target.windowScene;
            DSMovedKeyboardLevel = target.windowLevel;
        }
        NSString *before = DSWindowSceneName(target);
        UIWindowScene *remoteScene = DSRemoteKeyboardScene();
        // SystemAperture clips the keyboard to the island. The remote-keyboard
        // scene is the one that already paints the picker keyboard full width.
        if (DSSceneNameIsAperture(before) && remoteScene && target.windowScene != remoteScene) {
            target.windowScene = remoteScene;
        }
        target.windowLevel = DSKeyboardWindowLevelAboveStage();
        DSExternalKeyboardRaised = YES;
        DSClaimedKeyboardStatus = [NSString stringWithFormat:@"win=above-stage from=%@ now=%@ lvl=%.0f keys=%@",
                                   before,
                                   DSWindowSceneName(target),
                                   target.windowLevel,
                                   CGRectIsNull(shown) ? @"none" : NSStringFromCGRect(shown)];
        return YES;
    } @catch (NSException *exception) {
        DSRestoreRemoteKeyboardPlacement();
        DSClaimedKeyboardStatus = [NSString stringWithFormat:@"win=raise-failed %@", exception.reason ?: @"?"];
        return NO;
    }
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
