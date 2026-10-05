#import "DSKeyboardVisibility.h"
#undef DSBeeperDetailDumpKeyboard
#import "DSConstants.h"
#import "DSDiagnostics.h"
#import "DSSceneHost.h"
#import "DSStageWindow.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static BOOL DSLeaveTextEffectsInPlace = NO;
static BOOL DSWindowIsTextEffects(id window);
static void DSVisitApplicationWindows(void (^visitor)(UIWindow *window));
static void DSTintEveryKeyboardWindow(void);
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

static void DSRevealKeyboardView(UIView *view) {
    if (![view isKindOfClass:UIView.class]) return;
    NSString *name = NSStringFromClass(view.class);
    if (!DSViewLooksLikeKeyboardInstance(name)) return;
    [view.layer removeAllAnimations];
    view.hidden = NO;
    view.alpha = 1.0;
    view.userInteractionEnabled = YES;
    view.layer.hidden = NO;
    view.layer.opacity = 1.0;
    CGRect docked = DSFrameDockingKeyboardToScreenBottom(view, view.frame);
    if (!CGRectEqualToRect(docked, view.frame)) view.frame = docked;
}

static void DSRevealKeyboardTree(UIView *view, NSInteger depth) {
    if (depth > 28 || !view) return;
    DSRevealKeyboardView(view);
    for (UIView *child in view.subviews) {
        DSRevealKeyboardTree(child, depth + 1);
    }
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

void DSReassertKeyboardViewVisibility(id viewObject) {
    (void)viewObject;
}

void DSRevealAllKeyboardWindowsOnSpringBoard(void) {
    return;
    DSVisitApplicationWindows(^(UIWindow *window) {
        if (!DSClassNameLooksLikeKeyboard(NSStringFromClass(window.class))) return;
        if (DSLeaveTextEffectsInPlace && DSWindowIsTextEffects(window)) return;
        [window.layer removeAllAnimations];
        window.hidden = NO;
        window.alpha = 1.0;
        window.userInteractionEnabled = YES;
        window.layer.hidden = NO;
        window.layer.opacity = 1.0;
        window.clipsToBounds = NO;
        window.layer.masksToBounds = NO;
        DSRevealKeyboardTree(window, 0);
    });
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

BOOL DSKeyboardWindowShouldPinLevel(id window) {
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
    DSRevealAllKeyboardWindowsOnSpringBoard();
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

NSString *DSNowPlayingBundleIdentifier(void) {
    Class mediaClass = objc_getClass("SBMediaController");
    if (!mediaClass || ![mediaClass respondsToSelector:@selector(sharedInstance)]) return nil;
    id media = ((id (*)(id, SEL))objc_msgSend)(mediaClass, @selector(sharedInstance));
    if (![media respondsToSelector:@selector(nowPlayingApplication)]) return nil;
    id playing = ((id (*)(id, SEL))objc_msgSend)(media, @selector(nowPlayingApplication));
    if (![playing respondsToSelector:@selector(bundleIdentifier)]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(playing, @selector(bundleIdentifier));
}

BOOL DSVideoIsPlayingOnScreen(void) {
    NSString *bundle = DSNowPlayingBundleIdentifier();
    if (bundle.length == 0) return NO;
    Class mediaClass = objc_getClass("SBMediaController");
    id media = [mediaClass respondsToSelector:@selector(sharedInstance)]
        ? ((id (*)(id, SEL))objc_msgSend)(mediaClass, @selector(sharedInstance)) : nil;
    if (media && [media respondsToSelector:@selector(isPlaying)]) {
        if (!((BOOL (*)(id, SEL))objc_msgSend)(media, @selector(isPlaying))) return NO;
    }
    id springBoard = UIApplication.sharedApplication;
    SEL frontSelector = @selector(_accessibilityFrontMostApplication);
    if ([springBoard respondsToSelector:frontSelector]) {
        id front = ((id (*)(id, SEL))objc_msgSend)(springBoard, frontSelector);
        NSString *frontBundle = [front respondsToSelector:@selector(bundleIdentifier)]
            ? ((id (*)(id, SEL))objc_msgSend)(front, @selector(bundleIdentifier)) : nil;
        if (frontBundle.length > 0 && ![frontBundle isEqualToString:bundle]) return NO;
    }
    return YES;
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

BOOL DSRaiseKeyboardWindowAboveStage(void) {
    // 4.5.416. Level only. Frame and scene stay where UIKit put them.
    DSTraceFormat(@"raise keyboard video=%d depth=%ld",
                  DSVideoIsPlayingOnScreen(),
                  (long)[DSSceneHost sceneSettingsUpdateDepth]);
    // Frame and scene stay put. Holding the level is what keeps the keys
    // above the card once UIKit has shown them.
    // A conversation push is already a scene update. Moving the text-effects
    // window's frame or scene from inside it waits on that update.
    if (DSVideoIsPlayingOnScreen() || [DSSceneHost sceneSettingsUpdateDepth] > 0) {
        DSHoldKeyboardLevelAboveStage();
        DSRevealAllKeyboardWindowsOnSpringBoard();
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
            DSRememberKeyboardWindow(window);
            if (window.hidden || window.alpha < 0.01) {
                window.alpha = 1.0;
                window.hidden = NO;
            }
            // Level only, the same as 4.5.416. Assigning the scene or the frame
            // here is the SIGTRAP, and lowering a keyboard window is the SIGSEGV.
            window.windowLevel = DSKeyboardWindowLevelAboveStage();
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

static UIColor *DSKeyboardWindowTintColor(NSString *name) {
    if ([name isEqualToString:@"red"]) return [UIColor colorWithRed:0.95 green:0.12 blue:0.12 alpha:1];
    if ([name isEqualToString:@"orange"]) return [UIColor colorWithRed:1 green:0.5 blue:0 alpha:1];
    if ([name isEqualToString:@"blue"]) return [UIColor colorWithRed:0.15 green:0.4 blue:1 alpha:1];
    if ([name isEqualToString:@"purple"]) return [UIColor colorWithRed:0.58 green:0.15 blue:0.95 alpha:1];
    if ([name isEqualToString:@"green"]) return [UIColor colorWithRed:0.05 green:0.75 blue:0.2 alpha:1];
    return [UIColor colorWithRed:1 green:0.15 blue:0.7 alpha:1];
}

static const void *DSKeyboardTintLabelKey = &DSKeyboardTintLabelKey;

static void DSTintKeyboardWindow(UIWindow *window) {
    (void)window;
    return;
    if (![window isKindOfClass:UIWindow.class]) return;
    NSString *tint = DSKeyboardWindowTintName(window);
    UIColor *color = DSKeyboardWindowTintColor(tint);
    window.layer.borderWidth = 8;
    window.layer.borderColor = color.CGColor;
    window.clipsToBounds = NO;
    UILabel *label = objc_getAssociatedObject(window, DSKeyboardTintLabelKey);
    if (![label isKindOfClass:UILabel.class]) {
        label = [[UILabel alloc] initWithFrame:CGRectMake(6, 588, 418, 32)];
        label.font = [UIFont boldSystemFontOfSize:15];
        label.textColor = UIColor.whiteColor;
        label.userInteractionEnabled = NO;
        label.adjustsFontSizeToFitWidth = YES;
        objc_setAssociatedObject(window, DSKeyboardTintLabelKey, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [window addSubview:label];
    }
    UIView *host = DSTallKeyboardHost(window, 0);
    UIView *anchor = host ?: window;
    if (label.superview != anchor) [anchor addSubview:label];
    label.frame = CGRectMake(0, 0, CGRectGetWidth(anchor.bounds), 28);
    label.backgroundColor = color;
    label.text = [NSString stringWithFormat:@" %@  %@", tint.uppercaseString, DSWindowSceneName(window)];
    if (host && CGRectGetHeight(host.bounds) >= 160.0) {
        host.backgroundColor = [color colorWithAlphaComponent:0.55];
        host.layer.borderWidth = 6;
        host.layer.borderColor = color.CGColor;
    }
    [anchor bringSubviewToFront:label];
}

static void DSTintEveryKeyboardWindow(void) {
    DSVisitApplicationWindows(^(UIWindow *window) {
        if (!DSClassNameLooksLikeKeyboard(NSStringFromClass(window.class))) return;
        DSTintKeyboardWindow(window);
    });
}

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
