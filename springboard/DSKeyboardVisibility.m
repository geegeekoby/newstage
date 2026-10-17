#import <dlfcn.h>
#import "DSKeyboardVisibility.h"
#undef DSBeeperDetailDumpKeyboard
#import "DSConstants.h"
#import "DSDiagnostics.h"
#import "DSStageDebug.h"
#import "DSSceneHost.h"
#import "DSStageManager.h"
#import "DSStageWindow.h"
#import "DSStageManager.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>

#import <objc/runtime.h>

static BOOL DSLeaveTextEffectsInPlace = NO;
static BOOL DSWindowIsTextEffects(id window);
static void DSVisitApplicationWindows(void (^visitor)(UIWindow *window));

static NSString *DSWindowSceneName(UIWindow *window);
static BOOL DSWindowIsLiveSpringBoardKeyboard(UIWindow *window);

static BOOL DSClassNameLooksLikeKeyboard(NSString *name) {
    if (name.length == 0) return NO;
    if ([name rangeOfString:@"Keyboard"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"TextEffects"].location != NSNotFound) return YES;
    return NO;
}

static BOOL DSViewLooksLikeKeyboardInstance(NSString *name) {
    if (name.length == 0) return NO;
    if ([name rangeOfString:@"KeyboardRemoteControl"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"KeyboardLayerHost"].location != NSNotFound) return YES;
    if ([name hasPrefix:@"UIKeyboard"]) return YES;
    if ([name hasPrefix:@"UIInputSet"]) return YES;
    if ([name hasPrefix:@"UIKB"]) return YES;
    if ([name hasPrefix:@"UIRemoteKeyboard"]) return YES;
    if ([name hasPrefix:@"TUIKeyboard"]) return YES;
    if ([name hasPrefix:@"UICandidate"]) return YES;
    if ([name hasPrefix:@"UIPrediction"]) return YES;
    if ([name rangeOfString:@"Keyboard"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"InputSet"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"TextEffects"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"InputAssistant"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"Candidate"].location != NSNotFound) return YES;
    return NO;
}

static BOOL DSDockingKeyboard = NO;
static __weak UIWindow *DSDockedKeyboardWindow = nil;

static BOOL DSMessagesKeyboardIsUp = NO;

void DSSetMessagesKeyboardIsUp(BOOL up) {
    DSMessagesKeyboardIsUp = up;
}

BOOL DSIsMessagesKeyboardUp(void) {
    return DSMessagesKeyboardIsUp;
}

BOOL DSKeyboardTouchPassthroughArmed(void) {
    if (DSMessagesKeyboardIsUp || DSExternalKeyboardCoversStage()) return YES;
    UIWindow *docked = DSDockedKeyboardWindow;
    return docked != nil && !docked.hidden && docked.alpha > 0.01;
}

static BOOL DSNameIsDockableKeyboard(NSString *name) {
    if (name.length == 0) return NO;
    // The message box is a child of this host. Docking the host to the
    // bottom of the phone takes the box with it, off the card.
    if ([name rangeOfString:@"InputSetHostView"].location != NSNotFound) return !DSMessagesKeyboardIsUp;
    // Messenger, Signal, and Beeper still dock UIKeyboard. Messages does not:
    // moving that view alone leaves the globe row behind.
    if (DSMessagesKeyboardIsUp) return NO;
    return [name rangeOfString:@"UIKeyboard"].location == 0;
}

BOOL DSKeyboardWindowIsDocked(id window) {
    return [window isKindOfClass:UIWindow.class] && window == DSDockedKeyboardWindow;
}

// convertRect:toView:nil stops at the window. A window parked at y=932 then
// reports its keys at y=0, which is the top of that window, not the phone.
static CGRect DSRectOnScreen(UIView *view, CGRect rect) {
    if (![view isKindOfClass:UIView.class] || CGRectIsNull(rect)) return CGRectNull;
    UIWindow *window = [view isKindOfClass:UIWindow.class] ? (UIWindow *)view : (view.window ?: view.superview.window);
    if (!window) return CGRectNull;
    CGRect inWindow = (view == (UIView *)window) ? rect : [view convertRect:rect toView:window];
    return CGRectOffset(inWindow, CGRectGetMinX(window.frame), CGRectGetMinY(window.frame));
}

static BOOL DSRectIsOffBottom(CGRect rect, CGFloat screenH) {
    return CGRectGetMinY(rect) >= screenH - 1.0 || CGRectGetMinY(rect) > 5000.0;
}

static CGRect DSFrameInSuperviewForScreenRect(UIView *view, CGRect screenRect) {
    UIView *superview = view.superview;
    if (!superview || [view isKindOfClass:UIWindow.class]) return screenRect;
    CGRect superScreen = DSRectOnScreen(superview, superview.bounds);
    if (CGRectIsNull(superScreen)) return view.frame;
    return CGRectMake(CGRectGetMinX(screenRect) - CGRectGetMinX(superScreen),
                      CGRectGetMinY(screenRect) - CGRectGetMinY(superScreen),
                      CGRectGetWidth(screenRect),
                      CGRectGetHeight(screenRect));
}

static void DSApplyScreenFrame(UIView *view, CGRect screenRect) {
    if ([view isKindOfClass:UIWindow.class] || !view.superview) {
        view.frame = screenRect;
        return;
    }
    view.frame = DSFrameInSuperviewForScreenRect(view, screenRect);
}

// Messages leaves its keyboard at y=932. That number is on the phone: the
// window holding the keys is already off the bottom, and the keys sit at
// {0,0} inside it. Measuring them inside the window sees the top of that
// window and pushes them further off. Put the window on the phone, then put
// the keys on the bottom edge.
CGRect DSFrameKeepingKeyboardHostOnScreen(id viewObject, CGRect proposed) {
    // The keyboard host is UIKit's. Rewriting its frame makes UIKit drop the
    // keyboard and build another one.
    (void)viewObject;
    return proposed;
    if (DSDockingKeyboard || ![viewObject isKindOfClass:UIView.class]) return proposed;
    UIView *view = (UIView *)viewObject;
    if (!view.superview) return proposed;
    CGRect screen = UIScreen.mainScreen.bounds;
    CGFloat screenH = CGRectGetHeight(screen);
    if (screenH < 400.0) return proposed;
    CGRect proposedScreen = DSRectOnScreen(view.superview, proposed);
    CGRect current = DSRectOnScreen(view, view.bounds);
    BOOL keyboardSized = CGRectGetHeight(current) >= 160.0 &&
                         CGRectGetWidth(current) >= CGRectGetWidth(screen) - 40.0;
    BOOL onDisplay = keyboardSized &&
                     CGRectGetMinY(current) < screenH - 1.0 &&
                     CGRectGetMinY(current) > screenH * 0.4;
    BOOL flush = onDisplay && fabs(CGRectGetMaxY(current) - screenH) <= 12.0;
    static const void *DSDockedHostFrameKey = &DSDockedHostFrameKey;
    if (flush) {
        objc_setAssociatedObject(view, DSDockedHostFrameKey, [NSValue valueWithCGRect:view.frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL proposedOff = !CGRectIsNull(proposedScreen) && CGRectGetMinY(proposedScreen) >= screenH - 1.0;
    if (!proposedOff) return proposed;
    NSValue *saved = objc_getAssociatedObject(view, DSDockedHostFrameKey);
    if (!saved && !onDisplay) return proposed;
    static NSInteger logs = 0;
    if (logs < 8) {
        logs += 1;
        DSDiagnosticsRecordFormat(@"SpringBoard: refused to park %@ %@ off the bottom, left it at %@",
                                  NSStringFromClass(view.class),
                                  NSStringFromCGRect(proposedScreen),
                                  NSStringFromCGRect(current));
    }
    return saved ? saved.CGRectValue : view.frame;
}

static BOOL DSWindowIsLiveSpringBoardKeyboard(UIWindow *window) {
    if (![window isKindOfClass:UIWindow.class]) return NO;
    NSString *className = NSStringFromClass(window.class);
    if ([className rangeOfString:@"TextEffects"].location == NSNotFound) return NO;
    if ([className rangeOfString:@"Medusa"].location != NSNotFound) return NO;
    NSString *scene = DSWindowSceneName(window);
    if ([scene rangeOfString:@"remote-keyboard"].location != NSNotFound) return NO;
    if ([scene rangeOfString:@"Aperture"].location != NSNotFound) return NO;
    return [scene rangeOfString:@"springboard"].location != NSNotFound ||
           [scene rangeOfString:@"SpringBoard"].location != NSNotFound;
}

BOOL DSViewBelongsToLiveSpringBoardKeyboard(id viewObject) {
    if (![viewObject isKindOfClass:UIView.class]) return NO;
    return DSWindowIsLiveSpringBoardKeyboard(((UIView *)viewObject).window);
}

static UIView *DSTallKeyboardHost(UIView *view, NSInteger depth) {
    if (depth > 14 || ![view isKindOfClass:UIView.class]) return nil;
    NSString *name = NSStringFromClass(view.class);
    BOOL dockPiece = [name rangeOfString:@"DockItem"].location != NSNotFound ||
                     [name rangeOfString:@"Button"].location != NSNotFound;
    BOOL host = !dockPiece && ([name rangeOfString:@"UIKeyboard"].location == 0 ||
                               [name rangeOfString:@"InputSetHostView"].location != NSNotFound);
    if (host && CGRectGetWidth(view.bounds) >= 300.0 && CGRectGetHeight(view.bounds) >= 160.0) return view;
    UIView *found = nil;
    for (UIView *child in view.subviews) {
        UIView *next = DSTallKeyboardHost(child, depth + 1);
        if (!next) continue;
        if (!found || CGRectGetHeight(next.bounds) > CGRectGetHeight(found.bounds)) found = next;
    }
    return found;
}

static UIWindow *DSLiveSpringBoardKeyboardWindow(void) {
    __block UIWindow *best = nil;
    DSVisitApplicationWindows(^(UIWindow *window) {
        if (!DSWindowIsLiveSpringBoardKeyboard(window)) return;
        if (!best || window.windowLevel >= best.windowLevel) best = window;
    });
    return best;
}

static CGRect DSLiveHostScreen = {{0, 0}, {0, 0}};

BOOL DSReturnParkedKeyboardHost(CGRect endFrame) {
    // Moving the host back onto the screen is the same interference. UIKit
    // is left to place the keyboard.
    (void)endFrame;
    return NO;
    (void)endFrame;
    UIWindow *live = DSLiveSpringBoardKeyboardWindow();
    UIView *host = live ? DSTallKeyboardHost(live, 0) : nil;
    if (!host) return NO;
    CGRect screen = UIScreen.mainScreen.bounds;
    CGFloat screenH = CGRectGetHeight(screen);
    CGRect onScreen = DSRectOnScreen(host, host.bounds);
    BOOL onDisplay = CGRectGetHeight(onScreen) >= 160.0 &&
                     CGRectGetMinY(onScreen) < screenH - 1.0 &&
                     CGRectGetMinY(onScreen) > screenH * 0.35;
    if (onDisplay) {
        DSLiveHostScreen = onScreen;
        return YES;
    }
    static BOOL busy = NO;
    if (busy) return NO;
    static NSInteger snaps = 0;
    static CFAbsoluteTime windowStart = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (windowStart == 0 || now - windowStart > 3.0) {
        windowStart = now;
        snaps = 0;
    }
    if (snaps >= 8) return NO;
    CGRect kept = DSLiveHostScreen;
    if (CGRectGetHeight(kept) < 160.0) {
        CGFloat height = CGRectGetHeight(onScreen);
        if (height < 160.0) height = 301.0;
        kept = CGRectMake(0, screenH - height, CGRectGetWidth(screen), height);
    }
    CGRect local = DSFrameInSuperviewForScreenRect(host, kept);
    if (CGRectEqualToRect(host.frame, local)) return NO;
    snaps += 1;
    busy = YES;
    host.frame = local;
    busy = NO;
    DSDiagnosticsRecordFormat(@"SpringBoard: put the green keyboard back on screen %@", NSStringFromCGRect(kept));
    return YES;
}

CGRect DSFrameDockingKeyboardToScreenBottom(id viewObject, CGRect proposed) {
    (void)viewObject;
    return proposed;
    if (DSDockingKeyboard || ![viewObject isKindOfClass:UIView.class]) return proposed;
    UIView *view = (UIView *)viewObject;
    if (!view.superview) return proposed;
    if (view.hidden || view.alpha < 0.01) return proposed;
    NSString *name = NSStringFromClass(view.class);
    if (!DSNameIsDockableKeyboard(name)) return proposed;
    UIWindow *window = view.window ?: view.superview.window;
    if (!window) return proposed;
    CGRect screen = window.screen.bounds;
    if (CGRectIsEmpty(screen)) screen = UIScreen.mainScreen.bounds;
    CGFloat screenH = CGRectGetHeight(screen);
    CGFloat screenW = CGRectGetWidth(screen);
    if (screenH < 400.0 || screenW < 300.0) return proposed;
    CGRect onScreen = DSRectOnScreen(view.superview, proposed);
    if (CGRectIsNull(onScreen)) return proposed;
    CGFloat height = CGRectGetHeight(onScreen);
    if (height < 160.0 || height > screenH * 0.45) return proposed;
    BOOL parked = DSRectIsOffBottom(onScreen, screenH);
    BOOL atTop = CGRectGetMinY(onScreen) < 40.0 && CGRectGetWidth(onScreen) >= screenW - 80.0;
    BOOL onBottomEdge = fabs(CGRectGetMaxY(onScreen) - screenH) <= 2.0 &&
                        CGRectGetMinY(onScreen) > screenH * 0.45;
    // Keep the keyboard's own height. Stretching a 243pt keyboard into a
    // 301pt frame leaves the letter rows off the glass and only the
    // dictation row on screen.
    BOOL hovering = !parked && !atTop && !onBottomEdge &&
                    CGRectGetWidth(onScreen) >= screenW - 80.0 &&
                    CGRectGetMinY(onScreen) < screenH - 1.0;
    if (!parked && !atTop && !hovering) return proposed;
    // UIKit parks the live host at y=932 a few seconds after the keyboard
    // is up. Pulling that host back onto the screen is what reports the
    // keyboard down. If this view is already on the bottom edge, keep it.
    if (parked) {
        CGRect current = DSRectOnScreen(view, view.bounds);
        BOOL staying = CGRectGetHeight(current) >= 160.0 &&
                       CGRectGetMinY(current) < screenH - 1.0 &&
                       CGRectGetMinY(current) > screenH * 0.4 &&
                       fabs(CGRectGetMaxY(current) - screenH) <= 8.0;
        if (staying) return view.frame;
        CGRect visible = DSVisibleFullKeyboardFrameOnScreen();
        if (CGRectIsNull(visible)) visible = DSVisibleKeyboardFrameOnScreen();
        BOOL alreadyUp = DSDockedKeyboardWindow != nil ||
            (!CGRectIsNull(visible) && CGRectGetHeight(visible) >= 160.0 &&
             CGRectGetMinY(visible) < screenH - 1.0);
        if (alreadyUp) return proposed;
    }

    // Stretching this window to the whole phone after the first letter puts a
    // cover over the keys. The next tap misses them and the keyboard looks
    // frozen. The picker search keyboard and Messages both leave the window
    // the size UIKit gave it.
    BOOL textEffects = DSWindowIsTextEffects(window);
    BOOL holdWindow = !textEffects &&
                      !DSVideoIsPlayingOnScreen() &&
                      [DSSceneHost sceneSettingsUpdateDepth] == 0;
    CGRect windowScreen = DSRectOnScreen(window, window.bounds);
    BOOL windowOff = DSRectIsOffBottom(windowScreen, screenH);
    if (holdWindow && windowOff) {
        DSDockedKeyboardWindow = window;
        DSDockingKeyboard = YES;
        window.frame = screen;
        window.clipsToBounds = NO;
        if (window.windowLevel < DSKeyboardWindowLevelAboveStage()) {
            window.windowLevel = DSKeyboardWindowLevelAboveStage();
        }
        DSDockingKeyboard = NO;
        onScreen = DSRectOnScreen(view.superview, proposed);
        if (CGRectIsNull(onScreen)) return proposed;
        height = CGRectGetHeight(onScreen);
    }
    CGFloat delta = (screenH - height) - CGRectGetMinY(onScreen);
    BOOL needsMove = fabs(delta) >= 1.0;
    BOOL needsWidth = CGRectGetWidth(onScreen) < screenW - 2.0;
    if (!needsMove && !needsWidth) {
        if (holdWindow) DSDockedKeyboardWindow = window;
        return proposed;
    }

    UIView *mover = nil;
    for (UIView *parent = view.superview; parent && parent != window; parent = parent.superview) {
        if (DSWindowIsTextEffects(parent)) break;
        CGRect parentScreen = DSRectOnScreen(parent, parent.bounds);
        CGFloat parentH = CGRectGetHeight(parentScreen);
        BOOL parentOff = DSRectIsOffBottom(parentScreen, screenH);
        if (!parentOff && parentH > screenH * 0.5) break;
        if (parentOff) mover = parent;
    }
    CGRect target = CGRectMake(CGRectGetMinX(screen), screenH - height, screenW, height);
    static NSInteger logs = 0;
    if (mover && needsMove) {
        CGRect moved = DSRectOnScreen(mover, mover.bounds);
        moved.origin.y += delta;
        if (CGRectGetWidth(moved) >= screenW - 80.0 || CGRectGetWidth(moved) < screenW - 2.0) {
            moved.origin.x = CGRectGetMinX(screen);
            moved.size.width = screenW;
        }
        DSDockingKeyboard = YES;
        DSApplyScreenFrame(mover, moved);
        mover.clipsToBounds = NO;
        DSDockingKeyboard = NO;
        if (logs < 4) {
            logs += 1;
            DSDiagnosticsRecordFormat(@"SpringBoard: docked %@ by moving %@ from %@ onto the bottom of the display",
                                      name, NSStringFromClass(mover.class), NSStringFromCGRect(onScreen));
        }
        if (holdWindow) {
            DSDockedKeyboardWindow = window;
            if (window.windowLevel < DSKeyboardWindowLevelAboveStage()) {
                window.windowLevel = DSKeyboardWindowLevelAboveStage();
            }
        }
        return proposed;
    }

    CGRect docked = DSFrameInSuperviewForScreenRect(view, target);
    // The globe and dictation sit next to the host, not inside it. Move them
    // by the same amount or they stay in the card while the keys leave.
    CGFloat dy = CGRectGetMinY(docked) - CGRectGetMinY(proposed);
    if (view.superview && fabs(dy) >= 1.0) {
        for (UIView *sibling in view.superview.subviews) {
            if (sibling == view || sibling.hidden) continue;
            NSString *siblingName = NSStringFromClass(sibling.class);
            BOOL assistant = [siblingName rangeOfString:@"InputAssistant"].location != NSNotFound ||
                             [siblingName rangeOfString:@"Dictation"].location != NSNotFound ||
                             [siblingName rangeOfString:@"InputSwitcher"].location != NSNotFound ||
                             [siblingName rangeOfString:@"KeyboardDock"].location != NSNotFound;
            if (!assistant) continue;
            CGRect siblingFrame = sibling.frame;
            siblingFrame.origin.y += dy;
            DSDockingKeyboard = YES;
            sibling.frame = siblingFrame;
            DSDockingKeyboard = NO;
        }
    }
    if (logs < 4 && !CGRectEqualToRect(docked, proposed)) {
        logs += 1;
        DSDiagnosticsRecordFormat(@"SpringBoard: docked %@ %@ onto the bottom of the display %@",
                                  name, NSStringFromCGRect(onScreen), NSStringFromCGRect(docked));
    }
    if (holdWindow) {
        DSDockedKeyboardWindow = window;
        window.clipsToBounds = NO;
        if (window.windowLevel < DSKeyboardWindowLevelAboveStage()) {
            window.windowLevel = DSKeyboardWindowLevelAboveStage();
        }
    }
    return docked;
}

static void DSNoteTypingKeyboard(UIView *view, CGRect screen, CGRect *best, NSInteger depth) {
    if (depth > 16 || ![view isKindOfClass:UIView.class] || view.hidden || view.alpha < 0.01) return;
    if (!CGRectIsNull(*best)) return;
    NSString *name = NSStringFromClass(view.class);
    if (DSNameIsDockableKeyboard(name) && !CGRectIsEmpty(view.bounds)) {
        CGRect frame = DSRectOnScreen(view, view.bounds);
        CGFloat height = CGRectGetHeight(frame);
        CGFloat screenH = CGRectGetHeight(screen);
        BOOL sizeOK = height >= 160.0 && height <= screenH * 0.65 &&
                      CGRectGetWidth(frame) >= CGRectGetWidth(screen) - 80.0;
        // A host parked at y=932 is not the keyboard on screen. Treating it as
        // the keyboard left the real keys covered.
        BOOL onDisplay = CGRectGetMinY(frame) < screenH - 1.0 &&
                         CGRectGetMinY(frame) > screenH * 0.45 &&
                         fabs(CGRectGetMaxY(frame) - screenH) <= 20.0;
        if (sizeOK && onDisplay) {
            *best = frame;
            return;
        }
    }
    for (UIView *child in view.subviews) DSNoteTypingKeyboard(child, screen, best, depth + 1);
}

CGRect DSTypingKeyboardFrame(void) {
    __block CGRect best = CGRectNull;
    CGRect screen = UIScreen.mainScreen.bounds;
    DSVisitApplicationWindows(^(UIWindow *window) {
        if (!CGRectIsNull(best) || window.hidden || window.alpha < 0.01) return;
        if (!DSClassNameLooksLikeKeyboard(NSStringFromClass(window.class))) return;
        DSNoteTypingKeyboard(window, screen, &best, 0);
    });
    if (!CGRectIsNull(best)) return best;
    return DSVisibleStagedKeyboardFrameOnScreen();
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

static BOOL DSPlausibleKeyStrip(CGRect frame, CGRect windowBounds) {
    CGFloat windowHeight = CGRectGetHeight(windowBounds);
    CGFloat height = CGRectGetHeight(frame);
    if (windowHeight < 1.0 || height < kDSKeyboardPresentHeight) return NO;
    // The input host is often the whole window. That rect is the cover over
    // the card, not the keys.
    if (height > windowHeight * 0.5) return NO;
    if (CGRectGetMinY(frame) < windowHeight * 0.35) return NO;
    return YES;
}

static void DSCollectKeyStrips(UIView *view, UIWindow *window, CGRect *best, NSInteger depth) {
    if (depth > 12 || ![view isKindOfClass:UIView.class] || view.hidden || view.alpha < 0.01) return;
    NSString *name = NSStringFromClass(view.class);
    BOOL isKeyboard = [name rangeOfString:@"UIKeyboard"].location == 0 ||
                      [name rangeOfString:@"InputSetHostView"].location != NSNotFound;
    if (isKeyboard && !CGRectIsEmpty(view.bounds)) {
        CGRect frame = [view convertRect:view.bounds toView:window];
        if (DSPlausibleKeyStrip(frame, window.bounds)) {
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

// The first keyboard view in the first window is often the 75pt dock strip.
// The keys the user can see are the taller host sitting on the bottom edge.
// A 75pt strip is only used when nothing taller is on screen.
static void DSNoteBestKeyboard(UIView *view, CGRect screen, CGRect *best, NSInteger depth) {
    if (depth > 16 || ![view isKindOfClass:UIView.class] || view.hidden || view.alpha < 0.01) return;
    NSString *name = NSStringFromClass(view.class);
    BOOL isKeyboard = [name rangeOfString:@"UIKeyboard"].location == 0 ||
                      [name rangeOfString:@"InputSetHostView"].location != NSNotFound;
    if (isKeyboard && !CGRectIsEmpty(view.bounds)) {
        UIWindow *window = view.window;
        CGRect frame = window ? [view convertRect:view.bounds toView:nil] : view.frame;
        CGFloat height = CGRectGetHeight(frame);
        CGFloat screenH = CGRectGetHeight(screen);
        BOOL wide = CGRectGetWidth(frame) >= CGRectGetWidth(screen) - 40.0;
        BOOL onBottom = CGRectGetMaxY(frame) > screenH - 8.0 &&
                        CGRectGetMinY(frame) < screenH - 1.0 &&
                        CGRectGetMinY(frame) > screenH * 0.4;
        BOOL keys = height >= 160.0 && height <= screenH * 0.5 && wide && onBottom;
        BOOL strip = height >= kDSKeyboardPresentHeight && height < 160.0 && wide && onBottom;
        if (keys && (CGRectIsNull(*best) || height > CGRectGetHeight(*best))) {
            *best = frame;
        } else if (strip && CGRectIsNull(*best)) {
            *best = frame;
        }
    }
    for (UIView *child in view.subviews) {
        DSNoteBestKeyboard(child, screen, best, depth + 1);
    }
}

CGRect DSVisibleKeyboardFrameOnScreen(void) {
    __block CGRect keyboard = CGRectNull;
    CGRect screen = UIScreen.mainScreen.bounds;
    DSVisitApplicationWindows(^(UIWindow *candidate) {
        if (candidate.hidden || candidate.alpha < 0.01) return;
        if (!DSClassNameLooksLikeKeyboard(NSStringFromClass(candidate.class))) return;
        DSNoteBestKeyboard(candidate, screen, &keyboard, 0);
    });
    return keyboard;
}


BOOL DSPhoneCallIsActive(void) {
    __block BOOL found = NO;
    DSVisitApplicationWindows(^(UIWindow *window) {
        if (found || window.hidden || window.alpha < 0.02) return;
        NSString *name = NSStringFromClass(window.class);
        NSString *scene = DSWindowSceneName(window);
        NSString *blob = [NSString stringWithFormat:@"%@ %@", name ?: @"", scene ?: @""];
        if ([blob rangeOfString:@"InCall" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [blob rangeOfString:@"CallBanner" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [blob rangeOfString:@"PHAudioCall" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [blob rangeOfString:@"PhoneCall" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [blob rangeOfString:@"InCallService" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            found = YES;
        }
    });
    if (found) return YES;
    @try {
        id springBoard = [UIApplication sharedApplication];
        SEL frontSelector = @selector(_accessibilityFrontMostApplication);
        if ([springBoard respondsToSelector:frontSelector]) {
            id front = ((id (*)(id, SEL))objc_msgSend)(springBoard, frontSelector);
            NSString *bundle = [front respondsToSelector:@selector(bundleIdentifier)] ? [front bundleIdentifier] : nil;
            if ([bundle isEqualToString:@"com.apple.InCallService"]) return YES;
        }
    } @catch (NSException *exception) {
    }
    return NO;
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

// System Aperture lives in a UITextEffectsWindow. Raising that window to the
// keyboard level puts it on top of the keys, and the globe row's taps die there.
static BOOL DSWindowIsSystemChromeScene(UIWindow *window) {
    if (![window isKindOfClass:UIWindow.class]) return NO;
    NSString *scene = DSWindowSceneName(window);
    return [scene rangeOfString:@"SystemAperture"].location != NSNotFound ||
           [scene rangeOfString:@"SuperHighLevel"].location != NSNotFound ||
           [scene rangeOfString:@"Aperture"].location != NSNotFound;
}

NSString *DSKeyboardWindowCensus(void) {
    return @"census=0";
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
// Messages' reply bar is in this window. Moving it is what pulled the bar
// off the card. The key window still moves above the stage.

void DSLeaveTextEffectsWindowWithTheCard(BOOL leave) {
    DSLeaveTextEffectsInPlace = leave;
}

static BOOL DSWindowIsTextEffects(id window) {
    if (![window isKindOfClass:UIWindow.class]) return NO;
    NSString *name = NSStringFromClass([(UIWindow *)window class]);
    return [name rangeOfString:@"TextEffects"].location != NSNotFound;
}

static void DSNoteFullKeyboard(UIView *view, CGRect screen, CGRect *best, NSInteger depth) {
    if (depth > 16 || ![view isKindOfClass:UIView.class] || view.hidden || view.alpha < 0.01) return;
    NSString *name = NSStringFromClass(view.class);
    BOOL namedKeys = [name rangeOfString:@"UIKeyboard"].location == 0 ||
                     [name rangeOfString:@"InputSetHostView"].location != NSNotFound;
    if (namedKeys && !CGRectIsEmpty(view.bounds)) {
        CGRect frame = [view convertRect:view.bounds toView:nil];
        CGFloat height = CGRectGetHeight(frame);
        CGFloat screenH = CGRectGetHeight(screen);
        BOOL tallEnough = height >= 160.0 && height <= screenH * 0.65;
        BOOL wideEnough = CGRectGetWidth(frame) >= CGRectGetWidth(screen) - 40.0;
        BOOL onDisplay = CGRectGetMinY(frame) < CGRectGetMaxY(screen) - 1.0 &&
                         CGRectGetMaxY(frame) > screenH * 0.45;
        if (tallEnough && wideEnough && onDisplay &&
            (CGRectIsNull(*best) || height > CGRectGetHeight(*best))) {
            *best = frame;
        }
    }
    for (UIView *child in view.subviews) {
        DSNoteFullKeyboard(child, screen, best, depth + 1);
    }
}

static BOOL DSWindowContainsFullKeyboard(UIWindow *window) {
    if (![window isKindOfClass:UIWindow.class] || window.hidden || window.alpha < 0.01) return NO;
    CGRect best = CGRectNull;
    DSNoteFullKeyboard(window, UIScreen.mainScreen.bounds, &best, 0);
    return !CGRectIsNull(best);
}

static NSString *DSRejectKeyboardView(UIView *view, CGRect screen, NSInteger depth) {
    if (depth > 8 || ![view isKindOfClass:UIView.class]) return nil;
    NSString *name = NSStringFromClass(view.class);
    if ([name rangeOfString:@"UIKeyboard"].location == 0 && !CGRectIsEmpty(view.bounds)) {
        CGRect frame = (view.hidden || view.alpha < 0.01) ? view.frame : [view convertRect:view.bounds toView:nil];
        NSMutableArray<NSString *> *why = [NSMutableArray array];
        if (view.hidden || view.alpha < 0.01) [why addObject:@"hidden"];
        CGFloat height = CGRectGetHeight(frame);
        CGFloat screenH = CGRectGetHeight(screen);
        if (height < 160.0) [why addObject:[NSString stringWithFormat:@"shorter than a keyboard (%.0f)", height]];
        if (height > screenH * 0.65) [why addObject:[NSString stringWithFormat:@"taller than a keyboard (%.0f)", height]];
        if (CGRectGetWidth(frame) < CGRectGetWidth(screen) - 40.0) {
            [why addObject:[NSString stringWithFormat:@"narrower than the display (%.0f)", CGRectGetWidth(frame)]];
        }
        if (CGRectGetMaxY(frame) <= screenH * 0.45) [why addObject:@"sits in the top half, not at the bottom"];
        if (CGRectGetMinY(frame) >= CGRectGetMaxY(screen) - 1.0) [why addObject:@"below the display"];
        if (why.count == 0) [why addObject:@"this one matches"];
        return [NSString stringWithFormat:@"%@ frame=%@ %@", name, NSStringFromCGRect(frame), [why componentsJoinedByString:@", "]];
    }
    if (view.hidden || view.alpha < 0.01) return nil;
    for (UIView *child in view.subviews) {
        NSString *found = DSRejectKeyboardView(child, screen, depth + 1);
        if (found) return found;
    }
    return nil;
}

NSString *DSWhyFullKeyboardMissed(void) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    CGRect screen = UIScreen.mainScreen.bounds;
    DSVisitApplicationWindows(^(UIWindow *window) {
        if (parts.count >= 3) return;
        NSString *name = NSStringFromClass(window.class);
        if (!DSClassNameLooksLikeKeyboard(name)) return;
        if (window.hidden || window.alpha < 0.01) {
            [parts addObject:[NSString stringWithFormat:@"%@ is hidden alpha=%.2f frame=%@",
                              name, window.alpha, NSStringFromCGRect(window.frame)]];
            return;
        }
        NSString *keys = DSRejectKeyboardView(window, screen, 0);
        [parts addObject:keys ?: [NSString stringWithFormat:@"%@ frame=%@ has no UIKeyboard view",
                                  name, NSStringFromCGRect(window.frame)]];
    });
    if (parts.count == 0) {
        return [NSString stringWithFormat:@"no keyboard window in SpringBoard. %@", DSKeyboardWindowCensus()];
    }
    return [parts componentsJoinedByString:@" || "];
}

CGRect DSVisibleFullKeyboardFrameOnScreen(void) {
    __block CGRect best = CGRectNull;
    CGRect screen = UIScreen.mainScreen.bounds;
    DSVisitApplicationWindows(^(UIWindow *window) {
        if (window.hidden || window.alpha < 0.01) return;
        if (!DSClassNameLooksLikeKeyboard(NSStringFromClass(window.class))) return;
        DSNoteFullKeyboard(window, screen, &best, 0);
    });
    return best;
}

CGRect DSVisibleStagedKeyboardFrameOnScreen(void) {
    CGRect keys = DSVisibleFullKeyboardFrameOnScreen();
    if (!CGRectIsNull(keys)) return keys;
    keys = DSVisibleKeyboardFrameOnScreen();
    CGRect screen = UIScreen.mainScreen.bounds;
    if (!CGRectIsNull(keys) && DSKeyboardFrameIsOnScreen(keys, screen)) return keys;
    __block CGRect best = CGRectNull;
    DSVisitApplicationWindows(^(UIWindow *window) {
        if (window.hidden || window.alpha < 0.01) return;
        if (!DSClassNameLooksLikeKeyboard(NSStringFromClass(window.class))) return;
        CGRect strip = DSKeyboardKeysInWindow(window);
        if (CGRectIsNull(strip)) return;
        CGRect onScreen = [window convertRect:strip toView:nil];
        if (!DSKeyboardFrameIsOnScreen(onScreen, screen)) return;
        if (CGRectIsNull(best) || CGRectGetHeight(onScreen) > CGRectGetHeight(best)) {
            best = onScreen;
        }
    });
    return best;
}
// Level pin while a video is on screen. Separate from DSExternalKeyboardRaised
// so the frame rewrite and the unhide-everything path stay off.
static BOOL DSKeyboardLevelHeld = NO;
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
    DSStageWindow *stageWindow = [DSStageWindow stageWindow];
    if (stageWindow.windowScene) return stageWindow.windowScene;
    __block UIWindowScene *stage = nil;
    __block UIWindowScene *home = nil;
    DSVisitApplicationWindows(^(UIWindow *window) {
        if (!window.windowScene) return;
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

static BOOL DSMessagesKeyboardCoverLifted = NO;

void DSLowerStagedKeyboardCovers(void) {
    DSMessagesKeyboardCoverLifted = YES;
    DSExternalKeyboardRaised = NO;
    DSKeyboardLevelHeld = NO;
    DSClaimedKeyboardStatus = @"win=left-alone";
    return;
    DSVisitApplicationWindows(^(UIWindow *window) {
        if (!DSClassNameLooksLikeKeyboard(NSStringFromClass(window.class))) return;
        if (DSWindowIsSystemChromeScene(window)) return;
        @try {
            if (window.windowLevel > UIWindowLevelStatusBar) {
                window.windowLevel = UIWindowLevelNormal;
            }
        } @catch (NSException *exception) {
        }
    });
    DSClaimedKeyboardStatus = @"win=messages-own";
}

CGFloat DSKeyboardWindowLevelAboveStage(void) {
    // 4.5.416. Above the stage (998) and under System Aperture. 9999999 sat
    // under the aperture and the keys never appeared.
    return UIWindowLevelStatusBar + 5000.0;
}

// ---- 4.5.802 medusa802 -----------------------------------------------------------
// Proven from 20F75 SpringBoard: -[SBMedusaHostedKeyboardWindow
// initWithWindowScene:keyboardScene:] takes a default level assertion
// (priority 0, level UIWindowLevelNormal+5+15 = 20); _updateWindowLevel applies
// the highest-priority assertion (Library = 1, Spotlight = 2). So 20 is
// SpringBoard's own level, not a drop: the 6000 seen before came only from our
// direct writes (raise / hold / setWindowLevel: pin), and our restore wrote 20
// back. Any SpringBoard _updateWindowLevel then put it back to 20, under the
// stage (998). medusa802 instead takes SpringBoard's own assertion
// (newWindowLevelAssertionWithPriority:3 windowLevel:StatusBar+5000) while a
// staged app owns the keys, and invalidates it when the keys go off, so
// SpringBoard itself keeps the level. Our direct Medusa level writes, pin and
// restore are skipped while on. Messages-up keeps the old path (msg742).
// Off: medusa802-off / core802-off (crash latch medusa802).
static id DSMedusa802Assertion = nil;
static __weak UIWindow *DSMedusa802Window = nil;

BOOL DSMedusa802Handles(id window) {
    if (![window isKindOfClass:UIWindow.class] || DSMessagesKeyboardIsUp) return NO;
    if ([NSStringFromClass([window class]) rangeOfString:@"MedusaHostedKeyboardWindow"].location == NSNotFound) return NO;
    if (![window respondsToSelector:@selector(newWindowLevelAssertionWithPriority:windowLevel:)]) return NO;
    // 4.5.803: the direct Medusa level writes / pin / restore are gone; the
    // level comes only from SpringBoard's own assertion (core803-off: 802 gate).
    if (DS803On("medusa803")) return YES;
    return DS802On("medusa802");
}

void DSMedusa802Take(UIWindow *medusa, NSString *why) {
    @try {
        if (!NSThread.isMainThread || !DSMedusa802Handles(medusa)) return;
        if (DSMedusa802Assertion && DSMedusa802Window == medusa) return;
        if (DSMedusa802Assertion && [DSMedusa802Assertion respondsToSelector:@selector(invalidate)])
            ((void (*)(id, SEL))objc_msgSend)(DSMedusa802Assertion, @selector(invalidate));
        static BOOL marked = NO;
        if (!marked) { marked = YES; DSFeature699MarkTrying("medusa802"); }
        DSFeature719MarkAction("medusa802");
        CGFloat before = medusa.windowLevel;
        // Returns +1 (new...); stored in a strong static.
        id assertion = ((id (*)(id, SEL, long, double))objc_msgSend)(medusa, @selector(newWindowLevelAssertionWithPriority:windowLevel:),
                                                                     3L, (double)DSKeyboardWindowLevelAboveStage());
        DSMedusa802Assertion = assertion;
        DSMedusa802Window = medusa;
        DSDiagnosticsRecordFormat(@"SpringBoard: medusa802 took SpringBoard's Medusa level assertion (priority 3, level %.0f; was %.0f) for %@",
                                  DSKeyboardWindowLevelAboveStage(), before, why ?: @"?");
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: medusa802 take threw %@", exception.name ?: @"?");
    }
}

void DSMedusa802Release(NSString *why) {
    @try {
        if (!DSMedusa802Assertion) return;
        id a = DSMedusa802Assertion;
        DSMedusa802Assertion = nil;
        DSMedusa802Window = nil;
        if ([a respondsToSelector:@selector(invalidate)]) ((void (*)(id, SEL))objc_msgSend)(a, @selector(invalidate));
        DSDiagnosticsRecordFormat(@"SpringBoard: medusa802 released the Medusa level assertion (%@)", why ?: @"?");
    } @catch (NSException *exception) {
    }
}

static UIWindow *DSMedusa802FindWindow(void) {
    __block UIWindow *medusa = nil;
    DSVisitApplicationWindows(^(UIWindow *window) {
        if (!medusa && [NSStringFromClass(window.class) rangeOfString:@"MedusaHostedKeyboardWindow"].location != NSNotFound) medusa = window;
    });
    return medusa;
}

BOOL DSKeyboardWindowShouldPinLevel(id window) {
    if (DSMedusa802Handles(window)) return NO;   // 4.5.802: SpringBoard's own assertion holds the level
    if (DSMessagesKeyboardCoverLifted) return NO;
    if (!DSKeyboardLevelHeld && !DSExternalKeyboardRaised) return NO;
    if (![window isKindOfClass:UIWindow.class]) return NO;
    if (DSWindowIsSystemChromeScene((UIWindow *)window)) return NO;
    if (DSMessagesKeyboardIsUp) {
        NSString *scene = DSWindowSceneName((UIWindow *)window);
        NSString *className = NSStringFromClass([(UIWindow *)window class]);
        if ([scene rangeOfString:@"remote-keyboard"].location != NSNotFound ||
            [scene rangeOfString:@"Aperture"].location != NSNotFound ||
            [className rangeOfString:@"Medusa"].location != NSNotFound) return NO;
        if ([objc_getAssociatedObject(window, @selector(DSLoweredKeyboardCover)) boolValue]) return NO;
    }
    if (DSLeaveTextEffectsInPlace && DSWindowIsTextEffects(window)) return NO;
    if (DSLeaveTextEffectsInPlace && !DSWindowContainsFullKeyboard((UIWindow *)window)) return NO;
    return DSClassNameLooksLikeKeyboard(NSStringFromClass([(UIWindow *)window class]));
}

void DSHoldKeyboardLevelAboveStage(void) {
    DSKeyboardLevelHeld = YES;
    DSVisitApplicationWindows(^(UIWindow *window) {
        if (!DSClassNameLooksLikeKeyboard(NSStringFromClass(window.class))) return;
        if (DSWindowIsSystemChromeScene(window)) return;
        if (DSLeaveTextEffectsInPlace && DSWindowIsTextEffects(window)) return;
        if (DSLeaveTextEffectsInPlace && !DSWindowContainsFullKeyboard(window)) return;
        if (DSMedusa802Handles(window)) { if (!DS803On("medusa803")) DSMedusa802Take(window, @"hold"); return; }
        @try {
            if (window.windowLevel < DSKeyboardWindowLevelAboveStage()) {
                window.windowLevel = DSKeyboardWindowLevelAboveStage();
            }
        } @catch (NSException *exception) {
        }
    });
}

void DSReleaseKeyboardLevelHold(void) {
    DSKeyboardLevelHeld = NO;
}

BOOL DSKeyboardWindowShouldStayAboveStage(id window) {
    (void)window;
    return NO;
    if (DSVideoIsPlayingOnScreen()) return NO;
    if (!DSExternalKeyboardRaised || ![window isKindOfClass:UIWindow.class]) return NO;
    if (DSLeaveTextEffectsInPlace && DSWindowIsTextEffects(window)) return NO;
    if (DSLeaveTextEffectsInPlace && !DSWindowContainsFullKeyboard((UIWindow *)window)) return NO;
    return DSClassNameLooksLikeKeyboard(NSStringFromClass([(UIWindow *)window class]));
}

id DSReplacementSceneForKeyboardWindow(id window, id proposedScene) {
    (void)window;
    (void)proposedScene;
    return nil;
    if (DSVideoIsPlayingOnScreen()) return nil;
    if (!DSExternalKeyboardRaised || ![window isKindOfClass:UIWindow.class]) return nil;
    if (DSLeaveTextEffectsInPlace && DSWindowIsTextEffects(window)) return nil;
    if (DSLeaveTextEffectsInPlace && !DSWindowContainsFullKeyboard((UIWindow *)window)) return nil;
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

void DSAllowKeyboardToDismiss(void) {
    DSExternalKeyboardRaised = NO;
    DSKeyboardLevelHeld = NO;
}

BOOL DSRevealSpringBoardKeyboard(void) {
    // UIKit creates this window when the app says the keyboard is remote.
    // Never create one ourselves. Every keyboard window and subview is kept
    // visible, including ghost layers UIKit tries to hide.
    CGRect screen = UIScreen.mainScreen.bounds;
    __block BOOL revealed = NO;
    __block CGRect shown = CGRectNull;
    __block CGFloat level = 0;
    __block NSString *windowName = nil;
    DSVisitApplicationWindows(^(UIWindow *window) {
        if (revealed) return;
        if (!DSClassNameLooksLikeKeyboard(NSStringFromClass(window.class))) return;
        if (DSLeaveTextEffectsInPlace && DSWindowIsTextEffects(window)) return;
        CGRect keys = DSKeyboardViewFrameInView(window);
        if (!DSKeyboardFrameIsOnScreen(keys, screen)) return;
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
    DSKeyboardLevelHeld = NO;
    if (!DS803On("medusa803")) DSMedusa802Release(@"restore");   // 4.5.803: only keys-down releases
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
            if (!DSMedusa802Handles(window)) window.windowLevel = level;
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

NSString *DSNowPlayingBundleIdentifier(void) {
    Class mediaClass = objc_getClass("SBMediaController");
    if (!mediaClass || ![mediaClass respondsToSelector:@selector(sharedInstance)]) return nil;
    id media = ((id (*)(id, SEL))objc_msgSend)(mediaClass, @selector(sharedInstance));
    if (![media respondsToSelector:@selector(nowPlayingApplication)]) return nil;
    id playing = ((id (*)(id, SEL))objc_msgSend)(media, @selector(nowPlayingApplication));
    if (![playing respondsToSelector:@selector(bundleIdentifier)]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(playing, @selector(bundleIdentifier));
}

static NSString *DSFrontMostBundleIdentifier(void) {
    @try {
        id springBoard = UIApplication.sharedApplication;
        SEL frontSelector = @selector(_accessibilityFrontMostApplication);
        if (![springBoard respondsToSelector:frontSelector]) return nil;
        id front = ((id (*)(id, SEL))objc_msgSend)(springBoard, frontSelector);
        if (![front respondsToSelector:@selector(bundleIdentifier)]) return nil;
        NSString *bundle = ((id (*)(id, SEL))objc_msgSend)(front, @selector(bundleIdentifier));
        return [bundle isKindOfClass:NSString.class] && bundle.length > 0 ? bundle : nil;
    } @catch (NSException *exception) {
        return nil;
    }
}

static BOOL DSBundleIsOnStageCard(NSString *bundle) {
    if (bundle.length == 0) return NO;
    @try {
        DSStageManager *manager = [DSStageManager sharedManager];
        return manager && [manager isHostingBundleIdentifier:bundle];
    } @catch (NSException *exception) {
        return NO;
    }
}

// 4.5.664: why the last answer was what it was, for the keyboard log.
static NSString *DSVideoDecisionNote = @"none";

NSString *DSVideoOnScreenDetail(void) {
    return DSVideoDecisionNote ?: @"none";
}

static BOOL DSVideoDecide(BOOL onScreen, NSString *why, NSString *playing, NSString *front) {
    NSString *note = [NSString stringWithFormat:@"%@ playing=%@ front=%@", why, playing.length ? playing : @"-", front.length ? front : @"home screen"];
    if (![note isEqualToString:DSVideoDecisionNote]) {
        DSVideoDecisionNote = note;
        static NSInteger logged = 0;
        if (logged < 40) {
            logged += 1;
            DSDiagnosticsRecordFormat(@"SpringBoard: keyboard664 video-on-screen=%d (%@)", onScreen, note);
        }
    }
    return onScreen;
}

BOOL DSVideoIsPlayingOnScreen(void) {
    // "A video is playing in the full-screen app under the stage." That is the
    // only case where the stage must not take the key window (it flashes the
    // video, and resigning the video's window asserts).
    //
    // 4.5.664: before this build, background audio with no front app (music or
    // a podcast while on the home screen), or media in a staged app itself,
    // also answered YES. Then the stage window never took the key window,
    // the keyboard window was never raised or docked, and the picker search
    // began editing "over video" - no keyboard in any staged app (4.5.662
    // keyboard log: every "raise keyboard video=1", no "takeKey" at all).
    NSString *bundle = DSNowPlayingBundleIdentifier();
    if (bundle.length == 0) return DSVideoDecide(NO, @"nothing playing", nil, nil);
    Class mediaClass = objc_getClass("SBMediaController");
    id media = [mediaClass respondsToSelector:@selector(sharedInstance)]
        ? ((id (*)(id, SEL))objc_msgSend)(mediaClass, @selector(sharedInstance)) : nil;
    if (media && [media respondsToSelector:@selector(isPlaying)]) {
        if (!((BOOL (*)(id, SEL))objc_msgSend)(media, @selector(isPlaying))) {
            return DSVideoDecide(NO, @"paused", bundle, nil);
        }
    }
    NSString *front = DSFrontMostBundleIdentifier();
    if (front.length == 0) return DSVideoDecide(NO, @"audio with no full-screen app", bundle, nil);
    if (![front isEqualToString:bundle]) return DSVideoDecide(NO, @"playing app is not the front app", bundle, front);
    if (DSBundleIsOnStageCard(bundle)) return DSVideoDecide(NO, @"playing app is on a stage card", bundle, front);
    return DSVideoDecide(YES, @"full-screen app playing", bundle, front);
}

static NSString *DSBeeperShortScene(NSString *scene) {
    if (scene.length <= 36) return scene ?: @"?";
    return [scene substringToIndex:36];
}

static NSString *DSBeeperKeyboardSkip(UIWindow *window, CGRect screen) {
    NSString *className = NSStringFromClass(window.class);
    if (!DSClassNameLooksLikeKeyboard(className)) return @"not-keyboard";
    if ([className rangeOfString:@"Medusa"].location != NSNotFound) return @"medusa";
    NSString *scene = DSWindowSceneName(window);
    if ([scene rangeOfString:@"remote-keyboard"].location != NSNotFound) return @"remote-keyboard";
    if ([scene rangeOfString:@"Aperture"].location != NSNotFound) return @"aperture";
    if ([scene rangeOfString:@"springboard"].location == NSNotFound &&
        [scene rangeOfString:@"SpringBoard"].location == NSNotFound) return @"not-springboard-scene";
    CGRect keys = DSKeyboardViewFrameInView(window);
    if (CGRectIsNull(keys)) return @"no-key-view";
    if (CGRectGetMinY(keys) >= CGRectGetMaxY(screen) - 1.0) return @"keys-parked-off-bottom";
    if (CGRectGetHeight(keys) < 160.0) return @"keys-shorter-than-160";
    if (!DSKeyboardFrameIsOnScreen(keys, screen)) return @"keys-offscreen";
    return @"candidate";
}

void DSBeeperDetailDumpKeyboard(NSString *reason) {
    (void)reason;
    return;
    static CFAbsoluteTime lastAt = 0;
    static NSInteger dumps = 0;
    static BOOL pointed = NO;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (dumps >= 100) return;
    if (dumps > 3 && now - lastAt < 0.45) return;
    lastAt = now;
    dumps += 1;
    if (!pointed) {
        pointed = YES;
        DSDiagnosticsRecord(@"SpringBoard: Beeper detail log /var/tmp/com.recreated.dynamicstage.beeper-detail.log");
    }
    @try {
        CGRect screen = UIScreen.mainScreen.bounds;
        DSStageWindow *stage = [DSStageWindow stageWindow];
        NSString *ctor = [NSString stringWithContentsOfFile:@"/var/tmp/com.recreated.dynamicstage.ctor"
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
        ctor = [ctor stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (ctor.length > 240) ctor = [[ctor substringToIndex:237] stringByAppendingString:@"..."];
        DSBeeperDetailLogFormat(@"SB ctor-file %@", ctor.length ? ctor : @"missing");
        DSBeeperDetailLogFormat(@"SB dump %@ screen=%@ stage lvl=%.0f hid=%d alpha=%.2f frame=%@",
                                reason ?: @"?",
                                NSStringFromCGRect(screen),
                                stage ? stage.windowLevel : -1.0,
                                stage ? stage.hidden : -1,
                                stage ? stage.alpha : -1.0,
                                stage ? NSStringFromCGRect(stage.frame) : @"none");
        NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
        DSVisitApplicationWindows(^(UIWindow *window) {
            if (window) [windows addObject:window];
        });
        [windows sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
            if (a.windowLevel > b.windowLevel) return NSOrderedAscending;
            if (a.windowLevel < b.windowLevel) return NSOrderedDescending;
            return NSOrderedSame;
        }];
        NSInteger listed = 0;
        for (UIWindow *window in windows) {
            if (listed >= 12) break;
            listed += 1;
            NSString *className = NSStringFromClass(window.class);
            if (className.length > 42) className = [[className substringToIndex:39] stringByAppendingString:@"..."];
            DSBeeperDetailLogFormat(@"SB top%ld %@ scene=%@ lvl=%.0f hid=%d a=%.2f frame=%@",
                                    (long)listed,
                                    className,
                                    DSBeeperShortScene(DSWindowSceneName(window)),
                                    window.windowLevel,
                                    window.hidden,
                                    window.alpha,
                                    NSStringFromCGRect(window.frame));
        }
        for (UIWindow *window in windows) {
            NSString *className = NSStringFromClass(window.class);
            if (!DSClassNameLooksLikeKeyboard(className)) continue;
            CGRect keys = DSKeyboardViewFrameInView(window);
            CGFloat stageLevel = stage ? stage.windowLevel : 0.0;
            BOOL under = window.windowLevel <= stageLevel;
            if (className.length > 42) className = [[className substringToIndex:39] stringByAppendingString:@"..."];
            DSBeeperDetailLogFormat(@"SB keys %@ skip=%@ scene=%@ lvl=%.0f underStage=%d hid=%d a=%.2f frame=%@ keys=%@",
                                    className,
                                    DSBeeperKeyboardSkip(window, screen),
                                    DSBeeperShortScene(DSWindowSceneName(window)),
                                    window.windowLevel,
                                    under,
                                    window.hidden,
                                    window.alpha,
                                    NSStringFromCGRect(window.frame),
                                    CGRectIsNull(keys) ? @"none" : NSStringFromCGRect(keys));
        }
    } @catch (NSException *exception) {
        DSBeeperDetailLogFormat(@"SB dump threw %@", exception.reason ?: @"?");
    }
}

void DSRaiseVisibleKeyboardAboveStage(void) {
    // The SpringBoard keyboard host is already above the stage. Changing its
    // level covers the keys or makes UIKit build a new keyboard.
    static CFAbsoluteTime last = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - last < 1.0) return;
    last = now;
    DSClaimedKeyboardStatus = @"win=left-alone";
    DSBeeperDetailLog(@"SB left SpringBoard keyboard host alone");
    DSBeeperDetailDumpKeyboard(@"keyboard host not touched");
}

static BOOL DSRaiseKeyboardWindowAboveStageNow(void);

// 4.5.697: UIKit posts a keyboard frame change many times per keyboard
// animation ("raise keyboard ... x10" inside 16 ms in the Laggy log), and every
// call walked all SpringBoard windows. Calls within 80 ms of the last one reuse
// its answer, and one trailing raise runs 100 ms later so the final window
// levels are the same as before. Off with /var/mobile/.dynamicstage-perf697-off.
extern NSString *DSKbVis768RaiseNote;
static void DSKbVis768NoteRaise(const char *path, BOOL result) {
    static NSDateFormatter *f = nil;
    if (!f) { f = [[NSDateFormatter alloc] init]; f.dateFormat = @"HH:mm:ss.SSS"; }
    DSKbVis768RaiseNote = [NSString stringWithFormat:@"%s->%d@%@", path, result, [f stringFromDate:[NSDate date]]];
    DSHide772NotePath([NSString stringWithFormat:@"keys759 raise %s", path]);
}

BOOL DSRaiseKeyboardWindowAboveStage(void) {
    static CFAbsoluteTime lastRaise = 0;
    static BOOL lastResult = NO;
    static BOOL trailingQueued = NO;
    if (DSPerf697On() && [NSThread isMainThread]) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - lastRaise < 0.08 && now >= lastRaise) {
            if (!trailingQueued) {
                trailingQueued = YES;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    trailingQueued = NO;
                    lastRaise = CFAbsoluteTimeGetCurrent();
                    lastResult = DSRaiseKeyboardWindowAboveStageNow();
                    DSKbVis768NoteRaise("trailing", lastResult);
                });
            }
            return lastResult;
        }
        lastRaise = now;
    }
    // 4.5.740 raise740: act only on a real show / hide / move of the keys. With
    // the same keys on screen at the same frame as the last raise (which put
    // them above the stage) and no scene update in progress, the raise is not
    // repeated (Needs-patching log: "raise keyboard ... why=nothing playing" x10
    // in 10 s of typing). Keys not on screen always raise (kbshow728 recovery).
    // Off: /var/mobile/.dynamicstage-raise740-off.
    static CGRect lastKeys740 = {{0, 0}, {0, 0}};
    static CFAbsoluteTime lastAct740 = 0;
    if ([NSThread isMainThread] && DSFeature699On("raise740") && !DSStage742MessagesStaged()) {
        CGRect keys = CGRectNull;
        @try {
            keys = DSVisibleKeyboardFrameOnScreen();
        } @catch (NSException *exception) {
            keys = CGRectNull;
        }
        BOOL visible = !CGRectIsNull(keys) && !CGRectIsEmpty(keys) && CGRectGetHeight(keys) >= 60.0;
        CFAbsoluteTime now740 = CFAbsoluteTimeGetCurrent();
        if (visible && lastResult && CGRectEqualToRect(CGRectIntegral(keys), lastKeys740) &&
            [DSSceneHost sceneSettingsUpdateDepth] == 0 && now740 - lastAct740 < 5.0 && now740 >= lastAct740) {
            DSKbVis768NoteRaise("skip740", lastResult);
            return lastResult;
        }
        // 4.5.741 raise741: the "x3" at 12:06:39.253 (Bnb) were three raises in one
        // hide while the keys slid (each frame of the slide counted as a change).
        // Within 0.3 s of the last raise, only a change of shown <-> hidden acts.
        // Off: -raise741-off.
        static BOOL lastVisible741 = NO;
        if (DSFeature699On("raise741") && visible == lastVisible741 && lastAct740 > 0 &&
            now740 - lastAct740 < 0.3 && now740 >= lastAct740 && [DSSceneHost sceneSettingsUpdateDepth] == 0) {
            DSFeature719MarkAction("raise741");
            DSKbVis768NoteRaise("skip741", lastResult);
            return lastResult;
        }
        lastVisible741 = visible;
        lastKeys740 = visible ? CGRectIntegral(keys) : CGRectZero;
        lastAct740 = now740;
    }
    lastResult = DSRaiseKeyboardWindowAboveStageNow();
    DSKbVis768NoteRaise("raised", lastResult);
    return lastResult;
}

static BOOL DSRaiseKeyboardWindowAboveStageNow(void) {
    // 4.5.416. Level only. Frame and scene stay where UIKit put them.
    DSTraceFormat(@"raise keyboard video=%d depth=%ld why=%@",
                  DSVideoIsPlayingOnScreen(),
                  (long)[DSSceneHost sceneSettingsUpdateDepth],
                  DSVideoOnScreenDetail());
    // Frame and scene stay put. Holding the level is what keeps the keys
    // above the card once UIKit has shown them.
    // A conversation push is already a scene update. Moving the text-effects
    // window's frame or scene from inside it waits on that update.
    if (DSVideoIsPlayingOnScreen() || [DSSceneHost sceneSettingsUpdateDepth] > 0) {
        DSHoldKeyboardLevelAboveStage();
        DSClaimedKeyboardStatus = @"win=level-held";
        // The keyboard often arrives inside a scene update. Level-held never
        // finishes the raise, so the keys stay under the card. Try again once
        // that update has returned.
        static NSInteger DSDeferredRaiseToken = 0;
        NSInteger token = ++DSDeferredRaiseToken;
        for (NSInteger attempt = 1; attempt <= 4; attempt++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * attempt * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (token != DSDeferredRaiseToken) return;
                if (DSVideoIsPlayingOnScreen()) return;
                if ([DSSceneHost sceneSettingsUpdateDepth] > 0) return;
                DSRaiseKeyboardWindowAboveStage();
            });
        }
        return YES;
    }
    CGRect screen = UIScreen.mainScreen.bounds;
    NSMutableArray<NSString *> *notes = [NSMutableArray array];
    __block NSInteger raised = 0;
    // Pin levels before the loop. setWindowLevel: is hooked and would otherwise
    // let UIKit write level 10 back onto a window we have not finished yet.
    DSExternalKeyboardRaised = YES;
    DSVisitApplicationWindows(^(UIWindow *window) {
        NSString *className = NSStringFromClass(window.class);
        if (!DSClassNameLooksLikeKeyboard(className)) return;
        if (DSWindowIsSystemChromeScene(window)) return;
        // Messages already has its keyboard. Leave the remote window at the
        // level UIKit gave it. Other apps need that window raised.
        if (DSMessagesKeyboardIsUp) {
            NSString *sceneName = DSWindowSceneName(window);
            if ([sceneName rangeOfString:@"remote-keyboard"].location != NSNotFound ||
                [sceneName rangeOfString:@"Aperture"].location != NSNotFound ||
                [className rangeOfString:@"Medusa"].location != NSNotFound) {
                return;
            }
        }
        if (DSLeaveTextEffectsInPlace && DSWindowIsTextEffects(window)) return;
        if (DSLeaveTextEffectsInPlace && !DSWindowContainsFullKeyboard(window)) return;
        CGRect keys = DSKeyboardViewFrameInView(window);
        BOOL hasKeys = DSKeyboardFrameIsOnScreen(keys, screen);
        NSString *before = DSWindowSceneName(window);
        @try {
            BOOL medusa802 = DSMedusa802Handles(window);
            if (!medusa802) DSRememberKeyboardWindow(window);
            if (window.hidden || window.alpha < 0.01) {
                window.alpha = 1.0;
                window.hidden = NO;
            }
            // Level only, the same as 4.5.416. Assigning the scene or the frame
            // here is the SIGTRAP, and lowering a keyboard window is the SIGSEGV.
            if (medusa802) { if (!DS803On("medusa803")) DSMedusa802Take(window, @"raise"); }
            else window.windowLevel = DSKeyboardWindowLevelAboveStage();
            window.clipsToBounds = NO;
            window.layer.masksToBounds = NO;
            raised++;
            if (notes.count < 6) {
                [notes addObject:[NSString stringWithFormat:@"%@ %@ lvl=%.0f keys=%@",
                                  className,
                                  before,
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
    DSClaimedKeyboardStatus = [NSString stringWithFormat:@"win=above-stage n=%ld %@",
                               (long)raised,
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

static NSString *DSFirstResponderName(UIView *view, NSInteger depth) {
    if (depth > 10 || ![view isKindOfClass:UIView.class]) return nil;
    if (view.isFirstResponder) return NSStringFromClass(view.class);
    if (view.hidden && depth > 0) return nil;
    for (UIView *child in view.subviews) {
        NSString *found = DSFirstResponderName(child, depth + 1);
        if (found) return found;
    }
    return nil;
}

// Green is SpringBoard's own keyboard. Red is the remote keyboard. Blue is
// System Aperture. Orange is the high aperture. Purple is Medusa.
static NSString *DSKeyboardWindowTintName(UIWindow *window) {
    NSString *scene = DSWindowSceneName(window);
    NSString *className = NSStringFromClass(window.class);
    if ([scene rangeOfString:@"remote-keyboard"].location != NSNotFound) return @"red";
    if ([scene rangeOfString:@"SuperHighLevel"].location != NSNotFound) return @"orange";
    if ([scene rangeOfString:@"Aperture"].location != NSNotFound) return @"blue";
    if ([className rangeOfString:@"Medusa"].location != NSNotFound) return @"purple";
    if ([scene rangeOfString:@"springboard"].location != NSNotFound ||
        [scene rangeOfString:@"SpringBoard"].location != NSNotFound) return @"green";
    return @"pink";
}


static const void *DSKeyboardTintLabelKey = &DSKeyboardTintLabelKey;



// The first on-screen keyboard slab, with the flags that say whether it can
// take a tap. A dock button is not the keyboard. Its frame was being logged
// in place of the host that actually holds the keys.
static NSString *DSKeyboardViewDetail(UIView *view, NSInteger depth) {
    if (depth > 12 || ![view isKindOfClass:UIView.class]) return nil;
    NSString *name = NSStringFromClass(view.class);
    BOOL dockPiece = [name rangeOfString:@"DockItem"].location != NSNotFound ||
                     [name rangeOfString:@"Button"].location != NSNotFound;
    BOOL isKeyboard = !dockPiece && ([name rangeOfString:@"UIKeyboard"].location == 0 ||
                      [name rangeOfString:@"InputSetHostView"].location != NSNotFound);
    if (isKeyboard && !CGRectIsEmpty(view.bounds) && CGRectGetWidth(view.bounds) >= 200.0) {
        UIWindow *window = view.window;
        CGRect frame = window ? [view convertRect:view.bounds toView:nil] : view.frame;
        return [NSString stringWithFormat:@"%@ %@ hid=%d a=%.2f touch=%d",
                name,
                NSStringFromCGRect(frame),
                view.hidden,
                view.alpha,
                view.userInteractionEnabled];
    }
    if (view.hidden || view.alpha < 0.01) return nil;
    for (UIView *child in view.subviews) {
        NSString *found = DSKeyboardViewDetail(child, depth + 1);
        if (found) return found;
    }
    return nil;
}

NSString *DSKeyboardDebugSnapshot(void) {
    CGRect screen = UIScreen.mainScreen.bounds;
    CGRect full = DSVisibleFullKeyboardFrameOnScreen();
    CGRect visible = DSVisibleKeyboardFrameOnScreen();
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"screen=%@ messagesUp=%d full=%@ visible=%@",
                      NSStringFromCGRect(screen),
                      DSMessagesKeyboardIsUp,
                      CGRectIsNull(full) ? @"none" : NSStringFromCGRect(full),
                      CGRectIsNull(visible) ? @"none" : NSStringFromCGRect(visible)]];
    __block NSInteger count = 0;
    __block NSString *editor = nil;
    DSVisitApplicationWindows(^(UIWindow *window) {
        NSString *name = NSStringFromClass(window.class);
        BOOL keyboard = DSClassNameLooksLikeKeyboard(name);
        if (!editor && (window.isKeyWindow || keyboard)) {
            editor = DSFirstResponderName(window, 0);
        }
        if (!keyboard || count >= 6) return;
        count += 1;
        id lowered = objc_getAssociatedObject(window, @selector(DSLoweredKeyboardCover));
        NSString *keys = DSKeyboardViewDetail(window, 0);
        [lines addObject:[NSString stringWithFormat:@"win%ld %@ tint=%@ scene=%@ frame=%@ hid=%d a=%.2f lvl=%.0f keyWin=%d touch=%d lowered=%d keys=%@",
                          (long)count,
                          name,
                          DSKeyboardWindowTintName(window),
                          DSWindowSceneName(window),
                          NSStringFromCGRect(window.frame),
                          window.hidden,
                          window.alpha,
                          window.windowLevel,
                          window.isKeyWindow,
                          window.userInteractionEnabled,
                          lowered != nil,
                          keys ?: @"none"]];
    });
    if (count == 0) [lines addObject:@"win none"];
    [lines addObject:[NSString stringWithFormat:@"editor=%@ wins=%ld", editor ?: @"none", (long)count]];
    NSString *fullText = [lines componentsJoinedByString:@"\n"];
    static NSString *lastText = nil;
    BOOL changed = lastText == nil || ![lastText isEqualToString:fullText];
    if (changed) {
        lastText = [fullText copy];
        DSDiagnosticsAppendKeyboardStageLog([@"keyboard snapshot\n" stringByAppendingString:fullText]);
        NSString *compact = [lines componentsJoinedByString:@" | "];
        if (compact.length > 340) {
            compact = [[compact substringToIndex:337] stringByAppendingString:@"..."];
        }
        DSDiagnosticsRecordFormat(@"SpringBoard: kb %@", compact);
    }
    return lastText ?: fullText;
}


// ---- 4.5.765 tree765 (log only) ----------------------------------------------
// A read-only map of every keyboard / text-effects window (plus the stage
// window) and its view + layer tree on the first 3 keyboard shows, sampled at
// 0.05, 0.4 and 1.2 s. Writes its own file (not the 12 KB diagnostics ring)
// and changes nothing: only getters are read. Off: tree765-off / core765-off
// (crash latch tree765).
static const char *kDSTree765Path = "/var/mobile/Library/Preferences/com.recreated.dynamicstage.tree765.log";
static NSInteger DSTree765Shows = 0;
static BOOL DSTree765WasOn = NO;
static BOOL DSTree765Cleared = NO;

static BOOL DSTree765On(void) {
    return DSFeature699On("core765") && DSFeature699On("tree765") && access("/var/mobile/.dynamicstage-tree765-on", F_OK) == 0;   // 4.5.788: opt-in
}

static NSString *DSTree765Rect(CGRect r) {
    if (CGRectIsNull(r)) return @"null";
    return [NSString stringWithFormat:@"%.0f,%.0f %.0fx%.0f", r.origin.x, r.origin.y, r.size.width, r.size.height];
}

static void DSTree765Append(NSString *text) {
    if (text.length == 0) return;
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;
    int fd = open(kDSTree765Path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    struct stat st;
    if (fstat(fd, &st) == 0 && st.st_size > 400 * 1024) { close(fd); return; }
    (void)write(fd, data.bytes, data.length);
    close(fd);
}

static NSString *DSTree765LayerLine(CALayer *layer) {
    if (!layer) return @"layer=nil";
    NSMutableString *line = [NSMutableString stringWithFormat:@"L=%@ lh=%d op=%.2f",
                             NSStringFromClass(layer.class), layer.hidden, layer.opacity];
    @try {
        if ([layer respondsToSelector:@selector(contextId)]) {
            unsigned int cid = ((unsigned int (*)(id, SEL))objc_msgSend)(layer, @selector(contextId));
            [line appendFormat:@" ctx=%u", cid];
        }
    } @catch (NSException *exception) {
    }
    return line;
}

static void DSTree765Layers(CALayer *layer, NSInteger depth, NSMutableString *out, NSInteger *lines) {
    // Sublayers that do not back a view (layer hosts live here).
    if (!layer || depth > 14 || *lines >= 400) return;
    NSArray *subs = [layer.sublayers copy];
    for (CALayer *sub in subs) {
        if (*lines >= 400) return;
        id delegate = sub.delegate;
        if ([delegate isKindOfClass:UIView.class]) continue;
        CGRect f = CGRectNull;
        @try { f = [sub convertRect:sub.bounds toLayer:nil]; } @catch (NSException *exception) {}
        [out appendFormat:@"%*s- %@ f=%@\n", (int)(depth * 2), "", DSTree765LayerLine(sub), DSTree765Rect(f)];
        (*lines)++;
        DSTree765Layers(sub, depth + 1, out, lines);
    }
}

static void DSTree765Views(UIView *view, NSInteger depth, NSMutableString *out, NSInteger *lines) {
    if (!view || depth > 14 || *lines >= 400) return;
    CGRect f = CGRectNull;
    @try { f = view.window ? [view convertRect:view.bounds toView:nil] : view.frame; } @catch (NSException *exception) {}
    [out appendFormat:@"%*s%@ hid=%d a=%.2f f=%@ %@\n", (int)(depth * 2), "", NSStringFromClass(view.class),
     view.hidden, view.alpha, DSTree765Rect(f), DSTree765LayerLine(view.layer)];
    (*lines)++;
    DSTree765Layers(view.layer, depth + 1, out, lines);
    NSArray *subs = [view.subviews copy];
    for (UIView *child in subs) {
        if (*lines >= 400) {
            [out appendFormat:@"%*s(cut at 400 lines)\n", (int)(depth * 2), ""];
            return;
        }
        DSTree765Views(child, depth + 1, out, lines);
    }
}

static void DSTree765Dump(NSInteger show, double after) {
    if (!DSTree765On()) return;
    DSFeature719MarkAction("tree765");
    @try {
        NSMutableString *out = [NSMutableString string];
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"MM-dd HH:mm:ss.SSS";
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        [out appendFormat:@"=== tree765 build %s show %ld at +%.2f s (%@) ===\n", kDSBuildVersionString,
         (long)show, after, [fmt stringFromDate:[NSDate date]]];
        __block NSInteger windows = 0;
        DSVisitApplicationWindows(^(UIWindow *window) {
            NSString *cls = NSStringFromClass(window.class);
            BOOL keyboard = DSClassNameLooksLikeKeyboard(cls) || [cls rangeOfString:@"TextEffects"].location != NSNotFound;
            BOOL stage = [cls rangeOfString:@"DSStage"].location != NSNotFound;
            if (!keyboard && !stage) return;
            windows++;
            NSInteger lines = 0;
            [out appendFormat:@"WINDOW %@ scene=%@ lvl=%.1f hid=%d a=%.2f f=%@ %@\n", cls, DSWindowSceneName(window) ?: @"?",
             window.windowLevel, window.hidden, window.alpha, DSTree765Rect(window.frame), DSTree765LayerLine(window.layer)];
            if (stage) return;   // the stage window: header only
            NSArray *subs = [window.subviews copy];
            for (UIView *child in subs) DSTree765Views(child, 1, out, &lines);
            DSTree765Layers(window.layer, 1, out, &lines);
        });
        [out appendFormat:@"=== end tree765 show %ld (+%.2f s): %ld window(s) ===\n", (long)show, after, (long)windows];
        NSString *text = [out copy];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ DSTree765Append(text); });
        DSDiagnosticsRecordFormat(@"SpringBoard: tree765 mapped %ld keyboard window(s) for show %ld at +%.2f s (see --- tree765 ---)",
                                  (long)windows, (long)show, after);
    } @catch (NSException *exception) {
        DSDiagnosticsRecordFormat(@"SpringBoard: tree765 dump threw %@", exception.name ?: @"?");
    }
}

// 4.5.766 tree766: a dump that was due after the keyboard already went off
// (Hello log: show 3 at +1.2 s, after typing had ended) is skipped. Still
// log-only. Off: tree766-off / core766-off (latch tree766).
static NSUInteger DSTree766Gen = 0;

// 4.5.801: wipe on boot whenever the on-disk dump's build stamp differs.
// 800 only cleared inside NoteArbiter when tree765-on was set, so Hdidbdh
// still exported "tree765 build 4.5.787" from the prefs file.
void DSTree765WipeStaleOnBoot(void) {
    static BOOL once = NO;
    if (once) return;
    once = YES;
    @try {
        int rfd = open(kDSTree765Path, O_RDONLY);
        if (rfd < 0) return;
        char buf[96] = {0};
        ssize_t n = read(rfd, buf, sizeof(buf) - 1);
        close(rfd);
        if (n <= 0) return;
        NSString *head = [[NSString alloc] initWithBytes:buf length:(NSUInteger)n encoding:NSUTF8StringEncoding];
        NSString *want = [NSString stringWithFormat:@"build %s", kDSBuildVersionString];
        if (head.length && [head rangeOfString:want].location == NSNotFound) {
            unlink(kDSTree765Path);
            DSTree765Cleared = YES;
            DSDiagnosticsRecordFormat(@"SpringBoard: tree765 wiped stale dump on boot (was not %s)", kDSBuildVersionString);
        }
    } @catch (NSException *e) {}
}

void DSTree765NoteArbiter(BOOL on) {
    BOOL wasOn = DSTree765WasOn;
    DSTree765WasOn = on;
    if (!on && wasOn) DSTree766Gen++;
    if (!on || wasOn) return;
    DSTree765WipeStaleOnBoot();
    if (!DSTree765On() || DSTree765Shows >= 3) return;
    if (!DSTree765Cleared) {
        DSTree765Cleared = YES;
        unlink(kDSTree765Path);
    }
    NSInteger show = ++DSTree765Shows;
    for (NSNumber *after in @[ @0.05, @0.4, @1.2 ]) {
        double a = after.doubleValue;
        NSUInteger gen = DSTree766Gen;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(a * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if ((gen != DSTree766Gen || !DSTree765WasOn) && DS766On("tree766")) {
                DSFeature719MarkAction("tree766");
                DSDiagnosticsRecordFormat(@"SpringBoard: tree766 skipped show %ld +%.2f s dump: the keyboard already went off", (long)show, a);
                return;
            }
            DSTree765Dump(show, a);
        });
    }
}

NSString *DSTree765Read(void) {
    @try {
        NSString *text = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:kDSTree765Path]
                                                   encoding:NSUTF8StringEncoding error:nil];
        if (text.length > 300 * 1024) text = [text substringToIndex:300 * 1024];
        return text.length ? text : @"(none)";
    } @catch (NSException *exception) {
        return @"(unreadable)";
    }
}

// ---- 4.5.768 kbvis768 (log only) ---------------------------------------------
// On every keyboard show while the stage is on screen, sample the keyboard
// windows until the keyboard goes off (+0.5 s): the Medusa hosted-keyboard
// window (level, hidden, alpha, frame, scene, layer hidden/opacity, CALayerHost
// count + context ids), its nearest visible windows above and below by level,
// the stage window, the last keys759 raise, the arbiter, and SpringBoard's
// visible keyboard frame. A line only when something changed, plus a
// "keys visible?" verdict per show. Reads getters only.
// Off: kbvis768-off / core768-off (crash latch kbvis768).
NSString *DSKbVis768RaiseNote = nil;   // set by DSRaiseKeyboardWindowAboveStage
static NSUInteger DSKbVis768Gen = 0;
static NSInteger DSKbVis768Show = 0;
static BOOL DSKbVis768On_ = NO;          // arbiter on, as last told
static BOOL DSKbVis768Running = NO;
static CFAbsoluteTime DSKbVis768StartAt = 0, DSKbVis768OffAt = 0;
static NSString *DSKbVis768Owner = nil;
static CGRect DSKbVis768Frame;
static NSString *DSKbVis768LastSig = nil;
static NSString *DSKbVis768LastVerdict = nil;
static BOOL DSKbVis768SawYes = NO, DSKbVis768SawNo = NO;
static const char *kDSKbVis768Path = "/var/mobile/Library/Preferences/com.recreated.dynamicstage.kbvis768.log";

static BOOL DSKbVis768Enabled(void) {
    return DSFeature699On("core768") && DSFeature699On("kbvis768");
}

static void DSKbVis768Write(NSString *line) {
    DSDiagnosticsRecordFormat(@"SpringBoard: %@", line);
    NSDateFormatter *fmt = nil;
    static NSDateFormatter *shared = nil;
    if (!shared) {
        shared = [[NSDateFormatter alloc] init];
        shared.dateFormat = @"HH:mm:ss.SSS";
        shared.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    }
    fmt = shared;
    NSString *text = [NSString stringWithFormat:@"%@ %@\n", [fmt stringFromDate:[NSDate date]], line];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
        int fd = open(kDSKbVis768Path, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd < 0) return;
        struct stat st;
        if (fstat(fd, &st) == 0 && st.st_size > 600 * 1024) { close(fd); return; }
        (void)write(fd, data.bytes, data.length);
        close(fd);
    });
}

static void DSKbVis768Hosts(CALayer *layer, NSInteger depth, NSMutableArray *out, NSInteger *count) {
    if (!layer || depth > 24 || out.count >= 8) return;
    for (CALayer *sub in [layer.sublayers copy]) {
        if ([NSStringFromClass(sub.class) isEqualToString:@"CALayerHost"]) {
            unsigned int cid = 0;
            @try {
                if ([sub respondsToSelector:@selector(contextId)]) cid = ((unsigned int (*)(id, SEL))objc_msgSend)(sub, @selector(contextId));
            } @catch (NSException *exception) {}
            BOOL shown = !sub.hidden && sub.opacity > 0.01;
            // hidden up the chain inside the window?
            for (CALayer *p = sub.superlayer; p && p != layer; p = p.superlayer) {
                if (p.hidden || p.opacity < 0.01) { shown = NO; break; }
            }
            (*count)++;
            [out addObject:[NSString stringWithFormat:@"%u%@", cid, shown ? @"" : @"(hidden)"]];
        }
        DSKbVis768Hosts(sub, depth + 1, out, count);
    }
}

static NSString *DSKbVis768WinDesc(UIWindow *w) {
    if (!w) return @"none";
    return [NSString stringWithFormat:@"%@@%.0f%@%@", NSStringFromClass(w.class), w.windowLevel, w.hidden ? @"/hid" : @"",
            w.alpha < 0.99 ? [NSString stringWithFormat:@"/a%.2f", w.alpha] : @""];
}

extern NSString *DSFocus755LastFor(NSString *bundle, CFAbsoluteTime *at);
// ---- 4.5.772 hide772 (log only) -------------------------------------------------
// Who hides SBMedusaHostedKeyboardWindow while the arbiter is on. Off:
// hide772-off, master core772-off (crash latch hide772).
static BOOL DSName773On(void);
static void DSRegister774Probe(NSString *why);
static NSString *DSName773Stack(void);
static BOOL DSScene773On(void);
static NSString *DSScene773Recent(void);
NSString *(^DSHide772StateProvider)(NSString *owner) = nil;
BOOL (^DSKeyfocus772Handler)(NSString *owner, NSString *why) = nil;
static NSMutableArray<NSArray *> *DSHide772Paths = nil;   // [name, time]
static NSString *DSHide772LastStack = nil;
static CFAbsoluteTime DSHide772LastStackAt = 0;
static BOOL DSHide772On(void) {
    static BOOL marked = NO;
    if (!DS772On("hide772")) return NO;
    if (!marked) { marked = YES; DSFeature699MarkTrying("hide772"); }
    return YES;
}

void DSHide772NotePath(NSString *name) {
    if (!NSThread.isMainThread || !name || !DSKbVis768On_) return;
    if (!DSHide772Paths) DSHide772Paths = [NSMutableArray array];
    [DSHide772Paths addObject:@[name, @(CFAbsoluteTimeGetCurrent())]];
    while (DSHide772Paths.count > 12) [DSHide772Paths removeObjectAtIndex:0];
}

static NSString *DSHide772RecentPaths(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSMutableArray *out = [NSMutableArray array];
    for (NSArray *e in DSHide772Paths) {
        double ago = now - [e[1] doubleValue];
        if (ago <= 0.5) [out addObject:[NSString stringWithFormat:@"%@ -%.2fs", e[0], ago]];
    }
    return out.count ? [out componentsJoinedByString:@", "] : @"none";
}

static NSString *DSHide772Stack(void) {
    NSArray<NSNumber *> *addrs = [NSThread callStackReturnAddresses];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSUInteger i = 2; i < addrs.count && parts.count < 10; i++) {
        Dl_info info;
        memset(&info, 0, sizeof(info));
        uintptr_t a = (uintptr_t)addrs[i].unsignedLongLongValue;
        if (!dladdr((const void *)a, &info) || !info.dli_fbase) continue;
        const char *slash = info.dli_fname ? strrchr(info.dli_fname, '/') : NULL;
        NSString *image = [NSString stringWithUTF8String:slash ? slash + 1 : (info.dli_fname ?: "?")] ?: @"?";
        if ([image hasSuffix:@".dylib"]) image = [image stringByDeletingPathExtension];
        [parts addObject:[NSString stringWithFormat:@"%@+0x%lx", image, (unsigned long)(a - (uintptr_t)info.dli_fbase)]];
    }
    return parts.count ? [parts componentsJoinedByString:@" < "] : @"?";
}

// Called from the existing-class UIWindow -setHidden: hook (public UIKit setter).
void DSHide772NoteWindowHidden(UIWindow *window, BOOL hidden) {
    if (!hidden || !DSKbVis768On_ || !NSThread.isMainThread) return;
    if ([NSStringFromClass(window.class) rangeOfString:@"MedusaHostedKeyboard"].location == NSNotFound) return;
    if (window.hidden) return;   // already hidden: no change
    if ([DSKbVis768Owner isEqualToString:@"com.apple.springboard"] || [DSKbVis768Owner isEqualToString:@"com.apple.MobileSMS"]) return;
    if (!DSHide772On()) return;
    @try {
        DSHide772LastStack = DSHide772Stack();
        DSHide772LastStackAt = CFAbsoluteTimeGetCurrent();
        DSKbVis768Write([NSString stringWithFormat:@"hide772 setHidden:YES on %@ while the arbiter is on (owner %@): %@",
                         NSStringFromClass(window.class), DSKbVis768Owner ?: @"?", DSHide772LastStack]);
        if (DSName773On()) DSKbVis768Write([NSString stringWithFormat:@"name773 hide stack: %@", DSName773Stack()]);
        if (DSScene773On()) DSKbVis768Write([NSString stringWithFormat:@"scene773 scene updates in the 0.3 s before the hide: %@", DSScene773Recent()]);
        if (![DSKbVis768Owner isEqualToString:@"com.apple.MobileSMS"]) DSRegister774Probe(@"hide");
    } @catch (NSException *exception) {}
}

// ---- 4.5.775 -------------------------------------------------------------------
BOOL DSKbVis775ArbiterOn(void) { return DSKbVis768On_; }

// why775: log-only lines from the SpringBoard keyboard-window decision hooks.
// Only while a staged (not Messages / SpringBoard) keyboard is up, <= 16 per
// show, identical consecutive lines folded.
void DSWhy775Note(NSString *line) {
    if (!NSThread.isMainThread || !line.length || !DSKbVis768On_ || !DS775On("why775")) return;
    if (!DSKbVis768Owner || [DSKbVis768Owner isEqualToString:@"com.apple.springboard"] || [DSKbVis768Owner isEqualToString:@"com.apple.MobileSMS"]) return;
    static NSInteger show = -1, count = 0, folded = 0;
    static NSString *last = nil;
    if (show != DSKbVis768Show) { show = DSKbVis768Show; count = 0; folded = 0; last = nil; }
    if ([line isEqualToString:last]) { folded++; return; }
    if (count >= 16) return;
    count++;
    NSString *tail = folded ? [NSString stringWithFormat:@" (previous +%ld repeats)", (long)folded] : @"";
    folded = 0;
    last = [line copy];
    DSKbVis768Write([NSString stringWithFormat:@"why775 show %ld: %@%@", (long)DSKbVis768Show, line, tail]);
}

// ---- 4.5.776 keep776 ---------------------------------------------------------------
// Prevention: while the arbiter says a staged app (not Messages / SpringBoard)
// owns the keys and the stage is on screen, Tweak.xm drops SpringBoard's
// -[SBMedusaHostedKeyboardWindow setHidden:YES] when it comes from
// -[SBMedusaHostedKeyboardWindowController updateMedusaHostedKeyboardWindowForScene:isForeground:].
// When the arbiter goes off, a dropped hide is handed back to SpringBoard's own
// setHidden:YES (0.6 s later, only if Medusa is still shown and the keys stay off).
// Off: keep776-off, master core776-off (crash latch keep776).
static BOOL DSKbVis776StageOn = NO;
static BOOL DSKeep776Owed = NO;
static __weak UIWindow *DSKeep776Medusa = nil;
void (^DSKeep776ApplyHide)(UIWindow *medusa) = nil;


// ---- 4.5.803 one keyboard model, fed by the arbiter callback ---------------------
// The keyboard arbiter's updateKeyboardStatus: is the earliest signal (802 log:
// arbiter on=0 at 27.966, stale app "up" frames 27.969-27.977, keyboard note
// on=0 only at 27.987). One state, set there:
//   DS803Owner     the app the keyboard system names while keys are up (nil when down)
//   DS803DownFor   the app whose keys went down; cleared by that app's next keys-up
// medusa803: SpringBoard's Medusa level assertion exists only while DS803Owner
// is a staged app (not Messages / SpringBoard) and the stage is up.
// Off: medusa803-off / lift803-off / typing803-off, core803-off -> 802.
static NSString *DS803Owner = nil;
static NSString *DS803DownFor = nil;

NSString *DS803KeyboardOwner(void) { return DS803Owner; }
NSString *DS803KeysDownFor(void) { return DS803DownFor; }

void DS803NoteArbiter(BOOL on, NSString *source) {
    @try {
        if (!NSThread.isMainThread || !DSFeature699On("core803")) return;
        NSString *src = ([source isKindOfClass:NSString.class] && source.length) ? [source copy] : nil;
        if (on) {
            if (src) {
                DS803Owner = src;
                if ([DS803DownFor isEqualToString:src]) DS803DownFor = nil;
            }
        } else {
            NSString *was = src ?: DS803Owner;
            if (was) DS803DownFor = was;
            DS803Owner = nil;
        }
        if (!DS803On("medusa803")) return;
        if (!on) { DSMedusa802Release(@"keys off (arbiter)"); return; }
        DSStageManager *m = [DSStageManager sharedManager];
        BOOL staged = src && ![src isEqualToString:@"com.apple.springboard"] && ![src isEqualToString:@"com.apple.MobileSMS"] &&
            !DSStage742MessagesStaged() && m.isStageVisible && [m isHostingBundleIdentifier:src];
        if (!staged) { DSMedusa802Release(@"keys not owned by a staged app"); return; }
        static BOOL marked = NO;
        if (!marked) { marked = YES; DSFeature699MarkTrying("medusa803"); }
        UIWindow *medusa = DSMedusa802FindWindow();
        if (medusa) DSMedusa802Take(medusa, src);
    } @catch (NSException *exception) {
    }
}

BOOL DSKeep776Active(void) {
    @try {
        if (!NSThread.isMainThread || !DSKbVis768On_ || !DSKbVis776StageOn || !DS776On("keep776")) return NO;
        NSString *owner = DSKbVis768Owner;
        if (!owner.length || [owner isEqualToString:@"com.apple.springboard"] || [owner isEqualToString:@"com.apple.MobileSMS"] || DSStage742MessagesStaged()) return NO;
        DSStageManager *m = [DSStageManager sharedManager];
        if (!m.isStageVisible || ![m isHostingBundleIdentifier:owner]) return NO;
        static BOOL marked = NO;
        if (!marked) { marked = YES; DSFeature699MarkTrying("keep776"); }
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}

void DSKeep776NoteBlocked(UIWindow *medusa) {
    DSKeep776Owed = YES;
    DSKeep776Medusa = medusa;
    DSFeature719MarkAction("keep776");
    static NSInteger show = -1, count = 0;
    if (show != DSKbVis768Show) { show = DSKbVis768Show; count = 0; }
    if (++count <= 6)
        DSKbVis768Write([NSString stringWithFormat:@"keep776 show %ld: SpringBoard's Medusa hide (updateMedusaHostedKeyboardWindowForScene:) kept out for %@ (#%ld)",
                         (long)DSKbVis768Show, DSKbVis768Owner ?: @"?", (long)count]);
}

// 4.5.802 keep802: 801 show 11 began with Medusa hid=1 because OUR 0.6 s
// hand-back above had hidden it after the previous show. A new show cancels a
// pending hand-back, and if the hand-back already ran, the window we hid is
// shown again once (only that window, only if still hidden, only for a staged
// owner keep776 covers). Off: keep802-off / core802-off.
static NSUInteger DSKeep802Gen = 0;
static __weak UIWindow *DSKeep802HandedBack = nil;

static void DSKeep776ArbiterOff(void) {
    if (!DSKeep776Owed) return;
    DSKeep776Owed = NO;
    // 4.5.803 keep803: no hand-back timer. With medusa803 the assertion is gone
    // at keys-down, Medusa is back at SpringBoard's level 20 under the stage,
    // and SpringBoard hides it itself (802 log: shows 8/9/11/13-15 start hid=1
    // with no hand-back). Off: keep803-off / core803-off.
    if (DS803On("keep803") && DS803On("medusa803")) { DSFeature719MarkAction("keep803"); return; }
    NSUInteger gen802 = DSKeep802Gen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            UIWindow *w = DSKeep776Medusa;
            if (!w || w.hidden || DSKbVis768On_ || !DSKeep776ApplyHide) return;
            if (gen802 != DSKeep802Gen && DS802On("keep802")) return;
            DSKbVis768Write(@"keep776: keys off; handing SpringBoard's kept-out Medusa hide back");
            DSKeep776ApplyHide(w);
            DSKeep802HandedBack = w;
        } @catch (NSException *exception) {
        }
    });
}

// ---- 4.5.773 name773 / scene773 / keyfocus773 ------------------------------------
BOOL (^DSKeyfocus773Handler)(NSString *owner, NSInteger attempt, NSString *why) = nil;

UIWindow *DSRealKeyWindow773(void) {
    __block UIWindow *key = nil;
    DSVisitApplicationWindows(^(UIWindow *w) { if (!key && w.isKeyWindow) key = w; });
    return key;
}

typedef struct { uintptr_t addr; const char *cls; const char *sel; char meta; } DSName773Entry;
static DSName773Entry *DSName773Table = NULL;
static size_t DSName773Count = 0;
static NSMutableSet<NSString *> *DSName773Images = nil;
static BOOL DSName773On(void) {
    static BOOL marked = NO;
    if (!DS773On("name773")) return NO;
    if (!marked) { marked = YES; DSFeature699MarkTrying("name773"); }
    return YES;
}
static int DSName773Cmp(const void *a, const void *b) {
    uintptr_t x = ((const DSName773Entry *)a)->addr, y = ((const DSName773Entry *)b)->addr;
    return x < y ? -1 : (x > y ? 1 : 0);
}
static void DSName773LoadImage(const char *path) {
    if (!path) return;
    NSString *key = [NSString stringWithUTF8String:path];
    if (!DSName773Images) DSName773Images = [NSMutableSet set];
    if ([DSName773Images containsObject:key] || DSName773Images.count >= 4) return;
    [DSName773Images addObject:key];
    unsigned int nc = 0;
    const char **names = objc_copyClassNamesForImage(path, &nc);
    if (!names) return;
    static const char *keys[] = { "Keyboard", "Focus", "Medusa", "HostedKeyboard", "Scene", "Arbiter", "Window", "Layout", "Input" };
    BOOL strip774 = DS774On("name774");   // 4.5.774: IMPs are signed on arm64e; strip before comparing
    size_t cap = DSName773Count + 80000;
    DSName773Table = realloc(DSName773Table, cap * sizeof(DSName773Entry));
    for (unsigned int i = 0; i < nc && DSName773Count < cap; i++) {
        BOOL want = NO;
        for (int k = 0; k < (strip774 ? 9 : 7); k++) if (strstr(names[i], keys[k])) { want = YES; break; }
        if (!want) continue;
        Class c = objc_getClass(names[i]);
        if (!c) continue;
        for (int meta = 0; meta < 2; meta++) {
            Class cc = meta ? object_getClass((id)c) : c;
            unsigned int nm = 0;
            Method *ms = class_copyMethodList(cc, &nm);
            for (unsigned int j = 0; j < nm && DSName773Count < cap; j++) {
                IMP imp774 = method_getImplementation(ms[j]);
                uintptr_t a774 = (uintptr_t)imp774;
                if (strip774) {
                    a774 &= 0x0000000FFFFFFFFFULL;   // strip the PAC signature (user addresses fit in 36 bits)
                    // A method another tweak replaced points outside this image: skip it.
                    Dl_info di; memset(&di, 0, sizeof(di));
                    if (!dladdr((const void *)a774, &di) || !di.dli_fname || strcmp(di.dli_fname, path) != 0) continue;
                }
                DSName773Table[DSName773Count].addr = a774;
                DSName773Table[DSName773Count].cls = class_getName(c);
                DSName773Table[DSName773Count].sel = sel_getName(method_getName(ms[j]));
                DSName773Table[DSName773Count].meta = (char)meta;
                DSName773Count++;
            }
            free(ms);
        }
    }
    free(names);
    qsort(DSName773Table, DSName773Count, sizeof(DSName773Entry), DSName773Cmp);
}
// "-[Class sel]+0x40" for a SpringBoard / SpringBoardFoundation frame, nearest
// listed method start below it within 64 KB (only classes with the key words).
static NSString *DSName773Resolve(uintptr_t a, const char *imagePath, uintptr_t base) {
    if (DS774On("name774")) a &= 0x0000000FFFFFFFFFULL;
    DSName773LoadImage(imagePath);
    if (!DSName773Count) return nil;
    size_t lo = 0, hi = DSName773Count;
    while (lo < hi) { size_t mid = (lo + hi) / 2; if (DSName773Table[mid].addr <= a) lo = mid + 1; else hi = mid; }
    if (lo == 0) return nil;
    DSName773Entry *e = &DSName773Table[lo - 1];
    if (a - e->addr > 0x10000 || e->addr < base) return nil;
    return [NSString stringWithFormat:@"%c[%s %s]+0x%lx", e->meta ? '+' : '-', e->cls, e->sel, (unsigned long)(a - e->addr)];
}
static NSString *DSName773Stack(void) {
    NSArray<NSNumber *> *addrs = [NSThread callStackReturnAddresses];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSUInteger i = 2; i < addrs.count && parts.count < 10; i++) {
        Dl_info info; memset(&info, 0, sizeof(info));
        uintptr_t a = (uintptr_t)addrs[i].unsignedLongLongValue;
        if (!dladdr((const void *)a, &info) || !info.dli_fbase || !info.dli_fname) continue;
        const char *slash = strrchr(info.dli_fname, '/');
        const char *img = slash ? slash + 1 : info.dli_fname;
        NSString *name = nil;
        if (!strcmp(img, "SpringBoard") || !strcmp(img, "SpringBoardFoundation")) name = DSName773Resolve(a, info.dli_fname, (uintptr_t)info.dli_fbase);
        [parts addObject:[NSString stringWithFormat:@"%s+0x%lx%@", img, (unsigned long)(a - (uintptr_t)info.dli_fbase), name ? [NSString stringWithFormat:@"=%@", name] : @""]];
    }
    return [parts componentsJoinedByString:@" < "];
}

// scene773: FBScene -updateSettings:withTransitionContext:completion: (existing
// hook) sees every settings update SpringBoard itself sends to any scene; it
// does NOT see client-side settings changes coming back from an app process.
static NSMutableArray<NSArray *> *DSScene773Ring = nil;
static BOOL DSScene773On(void) {
    static BOOL marked = NO;
    if (!DS773On("scene773")) return NO;
    if (!marked) { marked = YES; DSFeature699MarkTrying("scene773"); }
    return YES;
}
BOOL DSScene773Wanted(void) {
    return NSThread.isMainThread && DSKbVis768On_ && DSKbVis768Running && DSScene773On();
}
void DSScene773Note(NSString *identifier, NSString *summary) {
    if (!DSScene773Ring) DSScene773Ring = [NSMutableArray array];
    [DSScene773Ring addObject:@[@(CFAbsoluteTimeGetCurrent()), identifier ?: @"?", summary ?: @""]];
    while (DSScene773Ring.count > 16) [DSScene773Ring removeObjectAtIndex:0];
}
static NSString *DSScene773Recent(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSMutableArray *out = [NSMutableArray array];
    for (NSArray *e in DSScene773Ring) {
        double ago = now - [e[0] doubleValue];
        if (ago <= 0.3) [out addObject:[NSString stringWithFormat:@"%@ -%.2fs {%@}", e[1], ago, e[2]]];
    }
    return out.count ? [out componentsJoinedByString:@" ; "] : @"none (no SpringBoard-sent scene update; a client-side update is not visible to this hook)";
}

// ---- 4.5.774 register774 (runtime probe, read-only) --------------------------------
// iOS 16.5.1. Which keyboard-focus classes / selectors exist in SpringBoard, and
// what they hold at each staged keyboard show and each hide. Only zero-argument
// getters whose type encoding returns an object or BOOL/integer are called, and
// only after respondsToSelector:. No writes. Off: register774-off (latch).
static BOOL DSRegister774On(void) {
    static BOOL marked = NO;
    // 4.5.795 register795: the probe read every ivar (weak / unsafe too) of
    // SpringBoard focus objects on each hide, for logging only. Now opt-in:
    // /var/mobile/.dynamicstage-register774-on. core795-off returns to 794.
    if (DSFeature699On("core795") && access("/var/mobile/.dynamicstage-register774-on", F_OK) != 0) return NO;
    if (!DS774On("register774")) return NO;
    if (!marked) { marked = YES; DSFeature699MarkTrying("register774"); }
    return YES;
}
static NSString *DSRegister774Short(id v) {
    if (!v) return @"nil";
    NSString *d = nil;
    @try { d = [v isKindOfClass:NSString.class] || [v isKindOfClass:NSNumber.class] ? [v description] : [NSString stringWithFormat:@"<%@ %p>", NSStringFromClass([v class]), v]; } @catch (NSException *e) { d = @"?"; }
    return d.length > 120 ? [d substringToIndex:120] : d;
}
static NSString *DSRegister774Call(id obj, const char *selName) {
    SEL sel = sel_registerName(selName);
    if (!obj || ![obj respondsToSelector:sel]) return nil;
    Method m = class_getInstanceMethod([obj class], sel);
    if (!m || method_getNumberOfArguments(m) != 2) return nil;
    char rt[16] = {0};
    method_getReturnType(m, rt, sizeof(rt));
    @try {
        if (rt[0] == '@') return DSRegister774Short(((id (*)(id, SEL))objc_msgSend)(obj, sel));
        if (rt[0] == 'B' || rt[0] == 'c') return ((BOOL (*)(id, SEL))objc_msgSend)(obj, sel) ? @"YES" : @"NO";
        if (rt[0] == 'q' || rt[0] == 'Q' || rt[0] == 'i' || rt[0] == 'I') return [NSString stringWithFormat:@"%lld", ((long long (*)(id, SEL))objc_msgSend)(obj, sel)];
    } @catch (NSException *e) { return @"threw"; }
    return [NSString stringWithFormat:@"(type %s, not called)", rt];
}
static NSString *DSRegister774Ivars(id obj) {
    if (!obj) return @"";
    NSMutableArray *out = [NSMutableArray array];
    for (Class c = [obj class]; c && c != NSObject.class && out.count < 24; c = class_getSuperclass(c)) {
        unsigned int n = 0;
        Ivar *iv = class_copyIvarList(c, &n);
        for (unsigned int i = 0; i < n && out.count < 24; i++) {
            const char *t = ivar_getTypeEncoding(iv[i]);
            const char *nm = ivar_getName(iv[i]);
            if (!t || !nm) continue;
            if (t[0] == '@') {
                id v = nil;
                @try { v = object_getIvar(obj, iv[i]); } @catch (NSException *e) {}
                [out addObject:[NSString stringWithFormat:@"%s=%@", nm, DSRegister774Short(v)]];
            } else {
                [out addObject:[NSString stringWithFormat:@"%s:%s", nm, t]];
            }
        }
        free(iv);
    }
    return [out componentsJoinedByString:@" "];
}
static NSMutableSet<NSString *> *DSRegister774Listed = nil;
static void DSRegister774Probe(NSString *why) {
    if (!DSRegister774On() || !NSThread.isMainThread) return;
    @try {
        NSMutableArray *lines = [NSMutableArray array];
        // 1. Classes that exist (listed once per boot).
        if (!DSRegister774Listed) {
            DSRegister774Listed = [NSMutableSet set];
            static const char *classes[] = { "SBKeyboardFocusCoordinator", "SBKeyboardFocusController", "SBSceneKeyboardFocusTarget",
                "SBKeyboardFocusTarget", "SBKeyboardFocusArbitrationReason", "SBKeyboardFocusLockAssertion", "SBMedusaHostedKeyboardWindow",
                "SBMedusaHostedKeyboardWindowController", "SBMedusaHostedKeyboardWindowManager", "SBHostedKeyboardWindowController",
                "SBMainDisplayLayoutState", "SBSDisplayLayoutElement", "SBDisplayLayoutElement", "FBSDisplayLayoutElement",
                "SBKeyboardSuppressionManager", "SBInputUISceneController", "SBRemoteKeyboardSceneController", "UIKeyboardSceneDelegate" };
            NSMutableArray *have = [NSMutableArray array];
            for (size_t i = 0; i < sizeof(classes) / sizeof(classes[0]); i++) {
                Class c = objc_getClass(classes[i]);
                if (!c) { [have addObject:[NSString stringWithFormat:@"%s=NO", classes[i]]]; continue; }
                unsigned int nm = 0; Method *ms = class_copyMethodList(c, &nm);
                NSMutableArray *sels = [NSMutableArray array];
                for (unsigned int j = 0; j < nm && sels.count < 60; j++) [sels addObject:NSStringFromSelector(method_getName(ms[j]))];
                free(ms);
                [have addObject:[NSString stringWithFormat:@"%s=YES[%@]", classes[i], [sels componentsJoinedByString:@","]]];
            }
            [lines addObject:[NSString stringWithFormat:@"classes: %@", [have componentsJoinedByString:@" | "]]];
        }
        // 2. Where the live coordinator is reachable from (SpringBoard app getters).
        id app = UIApplication.sharedApplication;
        static const char *appGetters[] = { "keyboardFocusController", "keyboardFocusCoordinator", "_keyboardFocusCoordinator",
            "keyboardFocusManager", "systemUISceneController", "keyboardSuppressionManager" };
        for (size_t i = 0; i < sizeof(appGetters) / sizeof(appGetters[0]); i++) {
            SEL sel = sel_registerName(appGetters[i]);
            if (![app respondsToSelector:sel]) continue;
            Method m = class_getInstanceMethod([app class], sel);
            char rt[8] = {0}; if (m) method_getReturnType(m, rt, sizeof(rt));
            if (!m || rt[0] != '@' || method_getNumberOfArguments(m) != 2) continue;
            id obj = nil;
            @try { obj = ((id (*)(id, SEL))objc_msgSend)(app, sel); } @catch (NSException *e) {}
            if (!obj) { [lines addObject:[NSString stringWithFormat:@"SpringBoard.%s=nil", appGetters[i]]]; continue; }
            NSMutableArray *vals = [NSMutableArray array];
            static const char *getters[] = { "focusTarget", "currentFocusTarget", "keyboardFocusTarget", "_currentFocusTarget", "focusedScene",
                "keyboardFocusScene", "sceneWithKeyboardFocus", "externalSceneWithFocus", "focusedSceneIdentityToken", "currentFocusedSceneIdentityToken",
                "lastFocusTarget", "isKeyboardFocusLocked", "hasKeyboardFocusLock", "debugDescription" };
            for (size_t g = 0; g < sizeof(getters) / sizeof(getters[0]); g++) {
                NSString *v = DSRegister774Call(obj, getters[g]);
                if (v) [vals addObject:[NSString stringWithFormat:@"%s=%@", getters[g], v]];
            }
            [lines addObject:[NSString stringWithFormat:@"SpringBoard.%s=<%@> %@ | ivars %@", appGetters[i], NSStringFromClass([obj class]),
                              [vals componentsJoinedByString:@" "], DSRegister774Ivars(obj)]];
        }
        DSKbVis768Write([NSString stringWithFormat:@"register774 probe (%@, owner %@): %@", why, DSKbVis768Owner ?: @"?",
                         lines.count ? [lines componentsJoinedByString:@" || "] : @"no candidate getter on SpringBoard"]);
    } @catch (NSException *exception) {
        DSKbVis768Write([NSString stringWithFormat:@"register774 probe threw %@", exception.name]);
    }
}

static void DSHide772Report(UIWindow *medusa, UIWindow *stage, NSInteger hostCount, NSString *what) {
    if (!DSHide772On()) return;
    @try {
        UIWindow *key = DSRealKeyWindow773();
        CFAbsoluteTime at = 0;
        NSString *focus = DSKbVis768Owner ? DSFocus755LastFor(DSKbVis768Owner, &at) : nil;
        NSString *card = DSHide772StateProvider ? DSHide772StateProvider(DSKbVis768Owner) : @"?";
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        DSKbVis768Write([NSString stringWithFormat:@"hide772 Medusa %@ while the arbiter is on (owner %@): key=%@ scene=%@ | stage=%@ key=%d | card: %@ | last focus %@ %@ | front: %@ home=%d busy=%d | our paths (0.5 s): %@ | hide stack %@ | first responder / arbiter client: not readable without new private reads",
                         what, DSKbVis768Owner ?: @"?", key ? NSStringFromClass(key.class) : @"none", key ? (DSWindowSceneName(key) ?: @"?") : @"-",
                         stage ? [NSString stringWithFormat:@"%.0f%@", stage.windowLevel, stage.hidden ? @"/hid" : @""] : @"none", stage.isKeyWindow,
                         card ?: @"?", focus.length ? [focus substringToIndex:MIN((NSUInteger)120, focus.length)] : @"none",
                         at > 0 ? [NSString stringWithFormat:@"(%.1f s ago)", now - at] : @"",
                         DSVideoOnScreenDetail() ?: @"?", [DSSceneHost homeGestureIsActive], [DSSceneHost systemTransitionBusy],
                         DSHide772RecentPaths(),
                         (DSHide772LastStackAt > 0 && now - DSHide772LastStackAt < 1.0) ? DSHide772LastStack : @"(no setHidden seen; hidden via layer or hosts removed)"]);
        (void)hostCount; (void)medusa;
    } @catch (NSException *exception) {}
}

static void DSKbVis768Sample(NSUInteger gen, BOOL final) {
    if (gen != DSKbVis768Gen || !DSKbVis768Enabled()) { DSKbVis768Running = NO; return; }
    DSFeature719MarkAction("kbvis768");
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    double t = now - DSKbVis768StartAt;
    @try {
        __block UIWindow *medusa = nil, *stage = nil;
        NSMutableArray<UIWindow *> *shown = [NSMutableArray array];
        DSVisitApplicationWindows(^(UIWindow *window) {
            NSString *cls = NSStringFromClass(window.class);
            if (!medusa && [cls rangeOfString:@"MedusaHostedKeyboard"].location != NSNotFound) medusa = window;
            if (!stage && [cls rangeOfString:@"DSStageWindow"].location != NSNotFound) stage = window;
            if (!window.hidden && window.alpha > 0.01) [shown addObject:window];
        });
        UIWindow *above = nil, *below = nil;
        if (medusa) {
            for (UIWindow *w in shown) {
                if (w == medusa) continue;
                if (w.windowLevel >= medusa.windowLevel) { if (!above || w.windowLevel < above.windowLevel) above = w; }
                else if (!below || w.windowLevel > below.windowLevel) below = w;
            }
        }
        NSMutableArray *ctx = [NSMutableArray array];
        NSInteger hostCount = 0;
        if (medusa) DSKbVis768Hosts(medusa.layer, 0, ctx, &hostCount);
        CGRect sb = CGRectNull;
        @try { sb = DSVisibleKeyboardFrameOnScreen(); } @catch (NSException *exception) {}
        NSString *medusaDesc = medusa ? [NSString stringWithFormat:@"lvl=%.0f hid=%d a=%.2f f=%@ scene=%@ lh=%d op=%.2f hosts=%ld[%@]",
                                         medusa.windowLevel, medusa.hidden, medusa.alpha, NSStringFromCGRect(medusa.frame),
                                         DSWindowSceneName(medusa) ?: @"?", medusa.layer.hidden, medusa.layer.opacity,
                                         (long)hostCount, [ctx componentsJoinedByString:@","]] : @"MISSING";
        NSString *sig = [NSString stringWithFormat:@"medusa %@ | above=%@ below=%@ | stage=%@ | raise=%@ | arb on=%d owner=%@ h=%.0f | sbkeys=%@",
                         medusaDesc, DSKbVis768WinDesc(above), DSKbVis768WinDesc(below), DSKbVis768WinDesc(stage),
                         DSKbVis768RaiseNote ?: @"none", DSKbVis768On_, DSKbVis768Owner ?: @"?", CGRectGetHeight(DSKbVis768Frame),
                         CGRectIsNull(sb) ? @"none" : NSStringFromCGRect(sb)];
        if (![sig isEqualToString:DSKbVis768LastSig]) {
            DSKbVis768LastSig = sig;
            DSKbVis768Write([NSString stringWithFormat:@"kbvis768 show %ld +%.2fs %@", (long)DSKbVis768Show, t, sig]);
        }
        // 4.5.772 hide772 / keyfocus772
        {
            static NSUInteger prevGen = 0;
            static BOOL prevVis = NO, tried = NO, reported = NO;
            static CFAbsoluteTime triedAt = 0;
            if (gen != prevGen) { prevGen = gen; prevVis = NO; tried = NO; reported = NO; triedAt = 0; }
            BOOL vis = medusa && !medusa.hidden && hostCount > 0;
            BOOL sbOwn = [DSKbVis768Owner isEqualToString:@"com.apple.springboard"] || [DSKbVis768Owner isEqualToString:@"com.apple.MobileSMS"];
            if (!sbOwn && DSKbVis768On_ && prevVis && !vis)
                DSHide772Report(medusa, stage, hostCount, medusa.hidden ? @"hidden" : @"lost its layer hosts");
            // 4.5.773 keyfocus773: up to 3 re-asserts per show, each after the
            // keys stayed hidden >= 0.15 s, 0.5 s apart.
            static CFAbsoluteTime lastVisAt = 0, lastTry773 = 0, hiddenSince = 0;
            static NSInteger tries773 = 0, reported773 = 0;
            static NSUInteger gen773 = 0;
            if (gen773 != gen) { gen773 = gen; lastVisAt = 0; lastTry773 = 0; tries773 = 0; reported773 = 0; hiddenSince = 0; }
            if (vis) { lastVisAt = now; hiddenSince = 0; } else if (hiddenSince == 0) hiddenSince = now;
            BOOL keep776 = DS776On("keep776");   // 4.5.776: prevention replaces recovery
            BOOL use773 = DSKeyfocus773Handler && DS773On("keyfocus773") && !keep776;
            if (use773 || keep776) tried = YES;   // 772's one-shot path is replaced by 773
            if (use773 && !sbOwn && DSKbVis768On_ && !vis && hiddenSince > 0 && now - hiddenSince >= 0.15 && tries773 < 3 &&
                (lastTry773 == 0 || now - lastTry773 >= 0.5)) {
                tries773++;
                lastTry773 = now;
                DSKeyfocus773Handler(DSKbVis768Owner, tries773, medusa.hidden ? @"Medusa hidden" : @"no layer host");
            }
            if (use773 && lastTry773 > 0 && reported773 < tries773 && now - lastTry773 >= 0.4) {
                reported773 = tries773;
                if (DS775On("rekey775") && !DSKbVis768On_)   // 4.5.775: teardown after dismissal is not a recovery
                    DSKbVis768Write([NSString stringWithFormat:@"keyfocus773 attempt %ld: keys came back? NO (keyboard already closed; Medusa %@)", (long)tries773, vis ? @"shown by teardown" : @"hidden"]);
                else
                    DSKbVis768Write([NSString stringWithFormat:@"keyfocus773 attempt %ld: keys came back? %@", (long)tries773, vis ? @"YES" : @"NO"]);
            }
            (void)lastVisAt;
            if (!sbOwn && DSKbVis768On_ && !vis && t >= 0.45 && !tried && DSKeyfocus772Handler) {
                tried = YES;
                if (DSKeyfocus772Handler(DSKbVis768Owner, medusa.hidden ? @"Medusa hidden" : @"no layer host")) triedAt = now;
            }
            if (triedAt > 0 && !reported && now - triedAt >= 0.5) {
                reported = YES;
                DSKbVis768Write([NSString stringWithFormat:@"keyfocus772 keys came back? %@ (+%.2f s after the attempt)", vis ? @"YES" : @"NO", now - triedAt]);
            }
            prevVis = vis;
        }
        // Verdict: could the keys be seen right now?
        NSMutableArray *why = [NSMutableArray array];
        if (!medusa) [why addObject:@"no Medusa window"];
        else {
            if (medusa.hidden) [why addObject:@"Medusa hidden"];
            if (medusa.alpha < 0.01) [why addObject:@"Medusa alpha 0"];
            if (medusa.layer.hidden || medusa.layer.opacity < 0.01) [why addObject:@"Medusa layer hidden/transparent"];
            if (hostCount == 0) [why addObject:@"no layer host"];
            else {
                BOOL anyLive = NO;
                for (NSString *c in ctx) if (![c hasPrefix:@"0"] && [c rangeOfString:@"hidden"].location == NSNotFound) anyLive = YES;
                if (!anyLive) [why addObject:@"no shown host with a context id"];
            }
            if (stage && !stage.hidden && medusa.windowLevel <= stage.windowLevel) [why addObject:[NSString stringWithFormat:@"Medusa level %.0f not above stage %.0f", medusa.windowLevel, stage.windowLevel]];
            if (!CGRectIntersectsRect(medusa.frame, medusa.screen.bounds)) [why addObject:@"Medusa frame off screen"];
        }
        if (CGRectIsNull(sb)) [why addObject:@"SpringBoard sees no keys on screen"];
        BOOL yes = why.count == 0;
        BOOL sbOwns772 = DS772On("hide772") && [DSKbVis768Owner isEqualToString:@"com.apple.springboard"];   // 4.5.772: SpringBoard's own keys are not in Medusa
        if (DSKbVis768On_ && t >= 0.5 && !sbOwns772) {
            if (yes) DSKbVis768SawYes = YES; else DSKbVis768SawNo = YES;
            if (DSKbVis802Verdict) DSKbVis802Verdict(DSKbVis768Owner, DSKbVis768Show, yes);
            NSString *verdict = yes ? @"YES" : [NSString stringWithFormat:@"NO (%@)", [why componentsJoinedByString:@"; "]];
            if (![verdict isEqualToString:DSKbVis768LastVerdict]) {
                DSKbVis768LastVerdict = verdict;
                DSKbVis768Write([NSString stringWithFormat:@"kbvis768 show %ld +%.2fs keys visible? %@ (owner %@)",
                                 (long)DSKbVis768Show, t, verdict, DSKbVis768Owner ?: @"?"]);
            }
        }
    } @catch (NSException *exception) {
        DSKbVis768Write([NSString stringWithFormat:@"kbvis768 sample threw %@", exception.name ?: @"?"]);
    }
    BOOL ended = !DSKbVis768On_ && DSKbVis768OffAt > 0 && now - DSKbVis768OffAt >= 0.5;
    if (ended || t > 90.0 || final) {
        DSKbVis768Write([NSString stringWithFormat:@"kbvis768 show %ld ended after %.1fs: keys visible %@",
                         (long)DSKbVis768Show, t,
                         (DS772On("hide772") && [DSKbVis768Owner isEqualToString:@"com.apple.springboard"]) ? @"not judged (SpringBoard's own keyboard)" :
                         DSKbVis768SawYes && DSKbVis768SawNo ? @"SOME of the time" : (DSKbVis768SawYes ? @"ALL of the time" : (DSKbVis768SawNo ? @"NEVER" : @"not judged (off within 0.5 s)"))]);
        DSKbVis768Running = NO;
        DSKbVis768Gen++;
        return;
    }
    double step = t < 1.5 ? 0.1 : 0.25;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(step * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DSKbVis768Sample(gen, NO);
    });
}

void (^DSKbVis802Verdict)(NSString *owner, NSInteger show, BOOL visible) = nil;
BOOL DSKbVis768ArbiterIsOn(void) { return DSKbVis768On_; }
CFAbsoluteTime DSKbVis768ArbiterOffTime(void) { return DSKbVis768OffAt; }

void DSKbVis768NoteArbiter(BOOL on, BOOL stageOnScreen, NSString *owner, CGRect frame) {
    @try {
        if (!NSThread.isMainThread) return;
        BOOL was = DSKbVis768On_;
        DSKbVis768On_ = on;
        DSKbVis776StageOn = stageOnScreen;
        if (!on && was) DSKeep776ArbiterOff();
        if (DS803On("medusa803")) { /* 4.5.803: DS803NoteArbiter owns the assertion */ }
        else if (!on) DSMedusa802Release(@"keys off");
        else if (stageOnScreen && [owner isKindOfClass:NSString.class] && owner.length &&
                 ![owner isEqualToString:@"com.apple.springboard"] && ![owner isEqualToString:@"com.apple.MobileSMS"] &&
                 !DSStage742MessagesStaged() && DS802On("medusa802") &&
                 [[DSStageManager sharedManager] isHostingBundleIdentifier:owner]) {
            UIWindow *medusa = DSMedusa802FindWindow();
            if (medusa) DSMedusa802Take(medusa, owner);
        } else {
            DSMedusa802Release(@"keys not owned by a staged app");
        }
        if (on) {
            if ([owner isKindOfClass:NSString.class] && owner.length) DSKbVis768Owner = [owner copy];
            DSKbVis768Frame = frame;
            DSKbVis768OffAt = 0;
            if (!was && DS802On("keep802") && !(DS803On("keep803") && DS803On("medusa803"))) {
                DSKeep802Gen++;
                UIWindow *mine = DSKeep802HandedBack;
                DSKeep802HandedBack = nil;
                if (mine && mine.hidden && DSKeep776Active()) {
                    DSFeature699MarkTrying("keep802");
                    DSFeature719MarkAction("keep802");
                    DSKbVis768Write([NSString stringWithFormat:@"keep802: new show for %@; re-showing the Medusa window our hand-back hid", DSKbVis768Owner ?: @"?"]);
                    DSDiagnosticsRecordFormat(@"SpringBoard: keep802 re-showed Medusa (our hand-back) for %@", DSKbVis768Owner ?: @"?");
                    mine.hidden = NO;
                }
            }
        } else if (was) {
            DSKbVis768OffAt = CFAbsoluteTimeGetCurrent();
        }
        if (!on || was || DSKbVis768Running || !stageOnScreen || !DSKbVis768Enabled()) return;
        static BOOL cleared = NO;
        if (!cleared) { cleared = YES; unlink(kDSKbVis768Path); }
        DSKbVis768Show++;
        DSKbVis768Running = YES;
        DSKbVis768StartAt = CFAbsoluteTimeGetCurrent();
        DSKbVis768LastSig = nil;
        DSKbVis768LastVerdict = nil;
        DSKbVis768SawYes = DSKbVis768SawNo = NO;
        NSUInteger gen = ++DSKbVis768Gen;
        DSKbVis768Write([NSString stringWithFormat:@"kbvis768 show %ld start owner=%@ h=%.0f", (long)DSKbVis768Show, DSKbVis768Owner ?: @"?", CGRectGetHeight(frame)]);
        if (![DSKbVis768Owner isEqualToString:@"com.apple.MobileSMS"] && ![DSKbVis768Owner isEqualToString:@"com.apple.springboard"]) DSRegister774Probe(@"show start");
        DSKbVis768Sample(gen, NO);
    } @catch (NSException *exception) {
    }
}

NSString *DSKbVis768Read(void) {
    @try {
        NSString *text = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:kDSKbVis768Path] encoding:NSUTF8StringEncoding error:nil];
        if (text.length > 200 * 1024) text = [text substringFromIndex:text.length - 200 * 1024];
        return text.length ? text : @"(none)";
    } @catch (NSException *exception) {
        return @"(unreadable)";
    }
}
