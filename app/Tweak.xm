#import "DSStageContext.h"
#import "DSAppPrivate.h"
#import "DSPreferences.h"
#import "DSConstants.h"
#import "DSExclusions.h"
#import "DSBootstrap.h"
#import "DSDiagnostics.h"
#import "DSStagePipeline.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>
#import <stdio.h>
#import <string.h>
#import <math.h>
// Injected into Messages, Messenger, and Signal. While that process is on the stage, UIKit is
// told the keyboard is remote so SpringBoard draws the keys outside the card, full width,
// on the bottom edge of the phone. The field that was tapped stays the editor.
// Keyboard windows are left the size of the phone. Telling them the card size
// draws the keys inside the card. The reply bar stays at the spot it had on
// the card. Focusing the field docks that bar to the bottom of the phone-sized
// text-effects window, which is below the card, and only that bar is put back.
// Nothing here reparents the hosted app, and nothing asks SpringBoard to open
// the picker stand-in. Hooks are installed before the first keyboard.
// The constructor always reports, including when it returns without hooking,
// because a silent return is indistinguishable from ElleKit never loading this
// dylib.

static BOOL DSStaged(void) {
    return [DSStageContext sharedContext].staged;
}

// Messenger, Signal, and Beeper keep SpringBoard's keyboard. Messages does not:
// StageDuo 1.2 leaves MobileSMS on its own keyboard so the iMessage app strip
// (the quick bar under the field) stays attached to that keyboard.
static BOOL DSMessagesDrawsOwnKeyboard(void) {
    return NO;
}

static BOOL DSMessagesInputIsTransitioning(UIView *view, CGRect frame);
static BOOL DSMessagesInputFrameIsParkedOffScreen(CGRect frame);
static BOOL DSMessagesOwnsKeyboard(void) {
    if (!DSStaged()) return NO;
    static int messages = -1;
    if (messages < 0) {
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"";
        messages = [bundle isEqualToString:@"com.apple.MobileSMS"] ? 1 : 0;
    }
    return messages == 1;
}

// Staged chat apps use SpringBoard's phone-width keyboard, not an in-card copy.
static BOOL DSUsesStageKeyboard(void) {
    static int cached = -1;
    if (cached < 0) {
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"";
        BOOL chat = [bundle isEqualToString:@"com.apple.MobileSMS"] ||
                    [bundle isEqualToString:@"com.facebook.Messenger"] ||
                    [bundle isEqualToString:@"org.whispersystems.signal"] ||
                    [bundle isEqualToString:@"com.beeper.chat.ios"];
        cached = chat ? 1 : 0;
    }
    return cached == 1;
}

#define DSMessagesUsesStageKeyboard DSUsesStageKeyboard

// Messages is allowed to move its own reply bar. Beeper is not: the card
// lifts, and Beeper's layout stays where it was.
static BOOL DSIsBeeper(void) {
    // Beeper uses the same keyboard path as Messenger and Signal.
    return NO;
}

static BOOL DSBeeperKeepsItsLayout(void) {
    return DSStaged() && DSIsBeeper();
}

// Beeper's own window while SpringBoard is showing it as a card. Do not
// change its frame, transform, alpha, or level.
static BOOL DSIsBeeperCard(UIWindow *window) {
    if (!DSIsBeeper() || ![window isKindOfClass:UIWindow.class]) return NO;
    CGRect frame = window.frame;
    CGFloat screenH = CGRectGetHeight(UIScreen.mainScreen.bounds);
    BOOL shorterThanPhone = CGRectGetHeight(frame) > 80.0 && CGRectGetHeight(frame) < screenH - 100.0;
    if (frame.origin.y > 0.0 && shorterThanPhone) return YES;
    if (shorterThanPhone) return YES;
    return DSStaged();
}

// SpringBoard already keeps Beeper's card above the keyboard. A second slide
// inside the app is what lifts the quick bar off the keyboard.
static BOOL DSBeeperKeyboardUp = NO;

static void DSBeeperRememberKeyboard(CGRect end) {
    CGFloat screenH = CGRectGetHeight(UIScreen.mainScreen.bounds);
    DSBeeperKeyboardUp = screenH > 400.0 &&
        CGRectGetHeight(end) >= 100.0 &&
        CGRectGetMinY(end) < screenH - 1.0;
}

static NSString *DSBeeperShortClass(id object) {
    if (!object) return @"?";
    NSString *name = NSStringFromClass(object_getClass(object));
    if (name.length > 48) name = [[name substringToIndex:45] stringByAppendingString:@"..."];
    return name.length ? name : @"?";
}

static UIResponder *DSCurrentKeyInput(void);
static BOOL DSResponderTakesText(UIResponder *responder);

// One line in the stage log for each time Beeper's bar moves. SpringBoard
// reads the file when this notification arrives.
static void DSBeeperShipLine(NSString *line) {
    if (!DSBeeperKeepsItsLayout() || line.length == 0) return;
    DSTraceFormat(@"Beeper %@", line);
    NSString *path = @"/var/tmp/com.recreated.dynamicstage.beeper-bar.log";
    NSString *existing = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSString *combined = [existing stringByAppendingFormat:@"%@\n", line];
    if (combined.length > 6000) {
        combined = [combined substringFromIndex:combined.length - 4500];
        NSRange newline = [combined rangeOfString:@"\n"];
        if (newline.location != NSNotFound) combined = [combined substringFromIndex:NSMaxRange(newline)];
    }
    [combined writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    chmod(path.fileSystemRepresentation, 0666);
    static int token = NOTIFY_TOKEN_INVALID;
    if (token == NOTIFY_TOKEN_INVALID) {
        notify_register_check(kDSKeyboardDebugNotification, &token);
    }
    if (token != NOTIFY_TOKEN_INVALID) notify_set_state(token, 1);
    notify_post(kDSKeyboardDebugNotification);
}

static BOOL DSBeeperNameLooksLikeQuickBar(NSString *name) {
    if (name.length == 0) return NO;
    if ([name rangeOfString:@"Composer"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"Compose"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"Quick"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"InputBar"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"MessageBar"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"Accessory"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"Toolbar"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"ChatInput"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"Reply"].location != NSNotFound) return YES;
    return NO;
}

static BOOL DSBeeperViewIsQuickBar(UIView *view) {
    if (![view isKindOfClass:UIView.class]) return NO;
    if (DSBeeperNameLooksLikeQuickBar(DSBeeperShortClass(view))) return YES;
    CGFloat width = CGRectGetWidth(view.bounds);
    CGFloat height = CGRectGetHeight(view.bounds);
    return width >= 180.0 && height >= 24.0 && height <= 180.0;
}

static NSString *DSBeeperChain(UIView *view) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    UIView *cursor = view;
    for (NSInteger index = 0; index < 6 && [cursor isKindOfClass:UIView.class]; index++) {
        [parts addObject:DSBeeperShortClass(cursor)];
        cursor = cursor.superview;
    }
    return [parts componentsJoinedByString:@" < "];
}

static void DSBeeperDetailSnapshot(NSString *reason) {
    (void)reason;
    return;
    if (!DSIsBeeper()) return;
    static CFAbsoluteTime lastAt = 0;
    static NSInteger shots = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (shots >= 80) return;
    if (shots > 2 && now - lastAt < 0.4) return;
    lastAt = now;
    shots += 1;
    @try {
        UIResponder *editor = DSCurrentKeyInput();
        UIView *editorView = [editor isKindOfClass:UIView.class] ? (UIView *)editor : nil;
        UIView *accessory = nil;
        UIView *inputView = nil;
        if ([editor respondsToSelector:@selector(inputAccessoryView)]) {
            accessory = ((UIView *(*)(id, SEL))objc_msgSend)(editor, @selector(inputAccessoryView));
        }
        if ([editor respondsToSelector:@selector(inputView)]) {
            inputView = ((UIView *(*)(id, SEL))objc_msgSend)(editor, @selector(inputView));
        }
        DSBeeperDetailLogFormat(@"APP snap %@ staged=%d editor=%@ fr=%d frame=%@ accessory=%@ input=%@",
                                reason ?: @"?",
                                DSStaged(),
                                editor ? DSBeeperShortClass(editor) : @"none",
                                editor.isFirstResponder,
                                editorView ? NSStringFromCGRect(editorView.frame) : @"none",
                                accessory ? [NSString stringWithFormat:@"%@ %@", DSBeeperShortClass(accessory), NSStringFromCGRect(accessory.frame)] : @"none",
                                inputView ? [NSString stringWithFormat:@"%@ %@", DSBeeperShortClass(inputView), NSStringFromCGRect(inputView.frame)] : @"none");
        NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            if (window) [windows addObject:window];
        }
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:UIWindowScene.class]) continue;
                for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                    if (window && ![windows containsObject:window]) [windows addObject:window];
                }
            }
        }
        NSInteger keyboardWindows = 0;
        NSInteger bars = 0;
        for (UIWindow *window in windows) {
            NSString *name = DSBeeperShortClass(window);
            BOOL keyboard = [name rangeOfString:@"Keyboard"].location != NSNotFound ||
                            [name rangeOfString:@"TextEffects"].location != NSNotFound ||
                            [name rangeOfString:@"InputSet"].location != NSNotFound;
            if (keyboard && keyboardWindows < 8) {
                keyboardWindows += 1;
                DSBeeperDetailLogFormat(@"APP win %@ lvl=%.0f hid=%d a=%.2f frame=%@",
                                        name, window.windowLevel, window.hidden, window.alpha,
                                        NSStringFromCGRect(window.frame));
            }
        }
        for (UIWindow *window in windows) {
            if (window.hidden || window.alpha < 0.01) continue;
            NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:window];
            NSInteger depth = 0;
            while (pending.count && depth < 7 && bars < 16) {
                if (pending.count > 60) break;
                NSArray<UIView *> *level = [pending copy];
                [pending removeAllObjects];
                for (UIView *view in level) {
                    for (UIView *child in view.subviews) {
                        if ([child isKindOfClass:UIView.class]) [pending addObject:child];
                    }
                    CGFloat width = CGRectGetWidth(view.bounds);
                    CGFloat height = CGRectGetHeight(view.bounds);
                    if (width < 140.0 || height < 20.0 || height > 220.0) continue;
                    CGRect onScreen = [view convertRect:view.bounds toView:nil];
                    CGFloat screenH = CGRectGetHeight(UIScreen.mainScreen.bounds);
                    if (CGRectGetMinY(onScreen) < screenH * 0.45) continue;
                    bars += 1;
                    UIEdgeInsets insets = view.safeAreaInsets;
                    DSBeeperDetailLogFormat(@"APP bar %@ y=%.0f h=%.0f ty=%.0f safeB=%.0f hid=%d chain=%@",
                                            DSBeeperShortClass(view),
                                            CGRectGetMinY(onScreen),
                                            height,
                                            view.transform.ty,
                                            insets.bottom,
                                            view.hidden,
                                            DSBeeperChain(view));
                    if (bars >= 24) break;
                }
                depth += 1;
            }
        }
        if (bars == 0) DSBeeperDetailLog(@"APP bar none in the lower half");
    } @catch (NSException *exception) {
        DSBeeperDetailLogFormat(@"APP snap threw %@", exception.reason ?: @"?");
    }
}

static void DSBeeperNoteQuickBar(NSString *what, UIView *view, CGRect before, CGRect after) {
    if (!DSBeeperKeepsItsLayout() || ![view isKindOfClass:UIView.class]) return;
    CGFloat dy = CGRectGetMinY(after) - CGRectGetMinY(before);
    CGFloat dh = CGRectGetHeight(after) - CGRectGetHeight(before);
    BOOL lifted = dy <= -8.0;
    BOOL shortened = dh <= -8.0;
    if (!lifted && !shortened) return;
    NSString *name = DSBeeperShortClass(view);
    CGFloat width = CGRectGetWidth(view.bounds);
    CGFloat height = CGRectGetHeight(after);
    BOOL bar = width >= 180.0 && height >= 24.0 && height <= 180.0;
    if (!DSBeeperNameLooksLikeQuickBar(name) && !bar) return;
    UIResponder *editor = DSCurrentKeyInput();
    BOOL typing = editor.isFirstResponder && DSResponderTakesText(editor);
    CGRect screen = view.window ? [view convertRect:view.bounds toView:nil] : CGRectNull;
    UIEdgeInsets insets = view.safeAreaInsets;
    DSBeeperDetailLogFormat(@"APP lift %@ dy=%.0f dh=%.0f before=%@ after=%@ screen=%@ ty=%.0f safeB=%.0f typing=%d editor=%@ chain=%@",
                            name,
                            dy,
                            dh,
                            NSStringFromCGRect(before),
                            NSStringFromCGRect(after),
                            CGRectIsNull(screen) ? @"none" : NSStringFromCGRect(screen),
                            view.transform.ty,
                            insets.bottom,
                            typing,
                            editor ? DSBeeperShortClass(editor) : @"none",
                            DSBeeperChain(view));
    DSBeeperDetailSnapshot(what);
    NSString *line = [NSString stringWithFormat:@"%@ %@ dy=%.0f dh=%.0f before=%@ after=%@ screen=%@ ty=%.0f typing=%d editor=%@",
                      what,
                      name,
                      dy,
                      dh,
                      NSStringFromCGRect(before),
                      NSStringFromCGRect(after),
                      CGRectIsNull(screen) ? @"none" : NSStringFromCGRect(screen),
                      view.transform.ty,
                      typing,
                      editor ? DSBeeperShortClass(editor) : @"none"];
    static NSString *last = nil;
    static CFAbsoluteTime lastAt = 0;
    static NSInteger count = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (count >= 40) return;
    if (last && [last isEqualToString:line] && now - lastAt < 0.3) return;
    count += 1;
    last = [line copy];
    lastAt = now;
    DSBeeperShipLine(line);
}

// A handful of lines per kind of move. The freeze trace is what gets pasted
// back: which Beeper view shifted, and whether this process asked for it.
static void DSBeeperDebug(NSString *key, NSString *line) {
    if (!DSBeeperKeepsItsLayout() || key.length == 0 || line.length == 0) return;
    if (!NSThread.isMainThread) return;
    static NSMutableDictionary<NSString *, NSNumber *> *counts = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        counts = [NSMutableDictionary dictionary];
    });
    if (counts.count > 40 && counts[key] == nil) return;
    NSInteger seen = counts[key].integerValue + 1;
    counts[key] = @(seen);
    if (seen != 1 && seen != 5 && seen != 20) return;
    DSTraceFormat(@"Beeper %@ (seen %ld)", line, (long)seen);
}

// Set once UIKit has been asked for a remote keyboard. Until then the in-card
// keys stay, so a failed handoff still has something to type on.
static BOOL DSMessagesKeyboardHosted = NO;
static NSUInteger DSMessagesHandoffToken = 0;
static NSInteger DSMessagesHandoffDepth = 0;
// Remote-creation hooks only. Hiding the in-card keys is a separate step.
static BOOL DSMessagesRemoteHooks = NO;
// The reply bar is held from the moment the handoff starts.
static BOOL DSMessagesBarHeld = NO;
// Keyboard-frame notes are dropped only after the new keyboard has been created.
static BOOL DSMessagesDropsKeyboardNotes = NO;
static BOOL DSMessagesHandoffInFlight = NO;
static BOOL DSMessagesHandoffResign = NO;
static BOOL DSMessagesChatOnScreen = NO;
static CFAbsoluteTime DSMessagesChatReadyAt = 0;
static CFAbsoluteTime DSMessagesHandoffCooldownUntil = 0;
// Counted every time UIKit asks, including after the once-only path report.
static int DSRemoteImplAsks = 0;
static int DSRemoteSceneAsks = 0;

static BOOL DSMessagesFieldIsEditing = NO;
// Set for the tap that wants SpringBoard's keyboard. A resign in this window
// is the stage taking the key, not the user leaving the field.
static BOOL DSStageKeyboardWanted = NO;

static BOOL DSMessagesKeepsOwnKeys(void) {
    // SpringBoard's stand-in is the editor for the whole Messages session. The
    // keys inside that card stay hidden for that session. Every other app
    // uses the raised SpringBoard keyboard, the same as 4.5.416.
    if (DSMessagesOwnsKeyboard()) {
        if (DSStageKeyboardWanted) return NO;
        return !DSMessagesFieldIsEditing;
    }
    return DSMessagesDrawsOwnKeyboard() && !DSMessagesKeyboardHosted;
}

// The reply bar stays where it was while the keyboard moves to SpringBoard.
static BOOL DSMessagesHoldsReplyBar(void) {
    return DSMessagesBarHeld;
}

// In-card key chrome is hidden only after SpringBoard's keyboard view is on
// screen. Until then the field still has something to type on.
static BOOL DSMessagesLocalKeysHidden = NO;
static BOOL DSMessagesPickerAsked = NO;

// Messages keeps the keyboard it built. Every other staged app uses SpringBoard's
// keyboard, and that window is raised above the stage the way 4.5.416 did it.
static BOOL DSMessagesWantsRemoteKeyboard(void) {
    if (!DSStaged()) return NO;
    if (DSMessagesOwnsKeyboard()) return NO;
    (void)DSMessagesRemoteHooks;
    return YES;
}

static void DSReleaseMessagesKeyboardHost(void);
static void DSScheduleMessagesKeyboardHandoff(UIResponder *responder);

static CFAbsoluteTime DSStageKeyboardGuardUntil = 0;
// The reply bar, as it was when the field was tapped. A later keyboard inset
// grows that bar downward. The anchor is what it has to stay.
static CGRect DSEntryAnchorFrame = {{0, 0}, {0, 0}};
static CGFloat DSEntryAnchorBottomInset = 0;
static CGFloat DSEntryAnchorWindowMaxY = 0;
static BOOL DSEntryAnchorValid = NO;
static BOOL DSApplyingEntryPin = NO;
static __weak UIView *DSEntryAnchorView = nil;

static void DSClearEntryAnchor(void) {
    UIView *entry = DSEntryAnchorView;
    if (entry && !CGAffineTransformIsIdentity(entry.transform)) {
        DSApplyingEntryPin = YES;
        entry.transform = CGAffineTransformIdentity;
        DSApplyingEntryPin = NO;
    }
    DSEntryAnchorValid = NO;
    DSEntryAnchorView = nil;
    DSEntryAnchorWindowMaxY = 0;
}

// The text box is also named MessageEntry. It sits at the top of the bar and
// is narrower than the card. The bar itself is the outer MessageEntryView.
static BOOL DSViewIsMessageEntryBar(UIView *view) {
    if (![view isKindOfClass:UIView.class]) return NO;
    NSString *name = NSStringFromClass(object_getClass(view));
    if ([name rangeOfString:@"MessageEntryView"].location == NSNotFound) return NO;
    if ([name rangeOfString:@"RichText"].location != NSNotFound) return NO;
    if ([name rangeOfString:@"Content"].location != NSNotFound) return NO;
    CGFloat height = CGRectGetHeight(view.bounds);
    CGFloat width = CGRectGetWidth(view.bounds);
    return height >= 20.0 && height <= 240.0 && width >= 120.0;
}

static UIView *DSEntryBarInTree(UIView *view, NSInteger depth, UIView *best) {
    if (!view || depth > 18) return best;
    if ([view isKindOfClass:UICollectionView.class] || [view isKindOfClass:UITableView.class]) return best;
    if (DSViewIsMessageEntryBar(view)) {
        if (!best || CGRectGetWidth(view.bounds) >= CGRectGetWidth(best.bounds)) best = view;
    }
    for (UIView *subview in view.subviews) {
        best = DSEntryBarInTree(subview, depth + 1, best);
    }
    return best;
}

static void DSRecordKeyboardWhy(NSString *why);
static CGRect DSStageBounds(void);
static CGFloat DSEntryOnCardMinY = 0;

// The reply bar starts on the card, then Messages parks it a few thousand
// points down. That park is what hides the box. Put it back on the spot it
// just had. A move of a few thousand points is the park, not a bad reading.
static void DSShowMessageEntryAboveKeyboard(UIResponder *responder) {
    NSString *who = NSStringFromClass(responder.class);
    UIView *entry = nil;
    UIView *view = [responder isKindOfClass:UIView.class] ? (UIView *)responder : nil;
    for (NSInteger depth = 0; view && depth < 16; depth++) {
        if (DSViewIsMessageEntryBar(view)) entry = view;
        view = view.superview;
    }
    if (!entry) {
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            entry = DSEntryBarInTree(window, 0, nil);
            if (entry) break;
        }
    }
    if (!entry || !entry.window) {
        DSRecordKeyboardWhy([NSString stringWithFormat:@"focus %@ entry=missing", who]);
        return;
    }
    UIWindow *window = entry.window;
    CGRect inWindow = [entry convertRect:entry.bounds toView:window];
    CGRect onScreen = CGRectOffset(inWindow, CGRectGetMinX(window.frame), CGRectGetMinY(window.frame));
    CGFloat screenH = CGRectGetHeight([DSStageContext sharedContext].deviceBounds);
    CGFloat cardH = CGRectGetHeight(DSStageBounds());
    CGFloat barH = CGRectGetHeight(onScreen);
    CGFloat minY = CGRectGetMinY(onScreen);
    NSString *where = [NSString stringWithFormat:@"focus %@ entry=%@ cardH=%.0f",
                       who, NSStringFromCGRect(onScreen), cardH];
    if (barH < 20.0 || barH > 240.0 || screenH < 400.0) {
        DSRecordKeyboardWhy([where stringByAppendingString:@" skip"]);
        return;
    }
    BOOL parked = minY > 1500.0 || minY < -1500.0;
    if (!parked && minY > 20.0 && CGRectGetMaxY(onScreen) < screenH - 40.0) {
        DSEntryOnCardMinY = minY;
        DSRecordKeyboardWhy([where stringByAppendingString:@" on-card"]);
        return;
    }
    if (!parked) {
        DSRecordKeyboardWhy(where);
        return;
    }
    CGFloat target = DSEntryOnCardMinY > 20.0 ? DSEntryOnCardMinY : (cardH - barH);
    if (target < 20.0 || target > screenH - barH) target = screenH - 301.0 - barH;
    CGFloat ty = target - minY;
    if (fabs(ty) < 1.0 || fabs(ty) > 8000.0) {
        DSRecordKeyboardWhy([where stringByAppendingFormat:@" ty=%.0f skip", ty]);
        return;
    }
    for (UIView *ancestor = entry; ancestor; ancestor = ancestor.superview) {
        ancestor.clipsToBounds = NO;
        ancestor.layer.masksToBounds = NO;
        if (ancestor == (UIView *)window) break;
    }
    entry.hidden = NO;
    entry.alpha = 1.0;
    entry.userInteractionEnabled = YES;
    entry.transform = CGAffineTransformTranslate(entry.transform, 0.0, ty);
    CGRect moved = CGRectOffset([entry convertRect:entry.bounds toView:window],
                                CGRectGetMinX(window.frame), CGRectGetMinY(window.frame));
    DSRecordKeyboardWhy([NSString stringWithFormat:@"%@ parked back %@", where, NSStringFromCGRect(moved)]);
}

static void DSAnchorMessageEntry(UIResponder *responder) {
    if (DSEntryAnchorValid) return;
    static BOOL anchoring = NO;
    if (anchoring) return;
    anchoring = YES;
    UIView *entry = nil;
    UIView *view = [responder isKindOfClass:UIView.class] ? (UIView *)responder : nil;
    for (NSInteger depth = 0; view && depth < 16; depth++) {
        if (DSViewIsMessageEntryBar(view)) entry = view;
        view = view.superview;
    }
    if (!entry) {
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            entry = DSEntryBarInTree(window, 0, nil);
            if (entry) break;
        }
    }
    if (!entry) {
        anchoring = NO;
        return;
    }
    DSEntryAnchorView = entry;
    DSEntryAnchorFrame = entry.frame;
    DSEntryAnchorBottomInset = entry.safeAreaInsets.bottom;
    CGRect onScreen = CGRectZero;
    if (entry.window) {
        onScreen = [entry convertRect:entry.bounds toView:nil];
        CGFloat screenH = CGRectGetHeight(UIScreen.mainScreen.bounds);
        CGFloat maxY = CGRectGetMaxY(onScreen);
        CGFloat minY = CGRectGetMinY(onScreen);
        // A parked composer reports a screen y of several thousand. Pinning
        // against that clears the slide that keeps the bar on the card.
        if (!(screenH > 100.0 && maxY > 1.0 && maxY <= screenH + 40.0 && minY > -80.0)) {
            anchoring = NO;
            DSTraceFormat(@"app entry is off the card %@, not anchored", NSStringFromCGRect(onScreen));
            return;
        }
        DSEntryAnchorWindowMaxY = maxY;
    } else {
        anchoring = NO;
        DSTrace(@"app entry has no window, not anchored");
        return;
    }
    DSEntryAnchorValid = YES;
    anchoring = NO;
    DSTraceFormat(@"app anchored entry %@ %@ screen %@ inset %.0f",
                  NSStringFromClass(object_getClass(entry)),
                  NSStringFromCGRect(entry.frame),
                  NSStringFromCGRect(onScreen),
                  DSEntryAnchorBottomInset);
}

// Holding the bar on every layout pass is the fight that stalls typing.
// A few corrections settle it. After that, UIKit's frame stands.
static BOOL DSEntryHoldOpen(void) {
    static NSInteger holds = 0;
    static NSInteger logs = 0;
    static CFAbsoluteTime windowStart = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (windowStart == 0 || now - windowStart > 1.0) {
        windowStart = now;
        holds = 0;
    }
    holds += 1;
    if (holds > 6) {
        if (logs < 2) {
            logs += 1;
            DSTrace(@"app stopped holding entry");
        }
        return NO;
    }
    return YES;
}

static CGRect DSClampedEntryFrame(UIView *view, CGRect frame) {
    if (!DSEntryAnchorValid || view != DSEntryAnchorView) return frame;
    BOOL lower = frame.origin.y > DSEntryAnchorFrame.origin.y + 0.5;
    BOOL taller = CGRectGetHeight(frame) > CGRectGetHeight(DSEntryAnchorFrame) + 0.5;
    if (!lower && !taller) return frame;
    if (!DSEntryHoldOpen()) return frame;
    static NSInteger logs = 0;
    if (logs < 4) {
        logs += 1;
        DSTraceFormat(@"app held entry %@ -> %@",
                      NSStringFromCGRect(DSEntryAnchorFrame), NSStringFromCGRect(frame));
    }
    frame.origin.y = DSEntryAnchorFrame.origin.y;
    frame.size.height = CGRectGetHeight(DSEntryAnchorFrame);
    return frame;
}

static void DSShipKeyboardTrace(NSString *line);

static void DSRequestSpringBoardKeyboard(BOOL show) {
    if (!DSStaged() || !DSMessagesUsesStageKeyboard()) return;
    if (show) {
        DSStageKeyboardWanted = YES;
        DSStageKeyboardGuardUntil = CFAbsoluteTimeGetCurrent() + 1.5;
    } else {
        DSStageKeyboardWanted = NO;
        DSStageKeyboardGuardUntil = 0;
        DSClearEntryAnchor();
    }
    uint64_t state = DSIdentifierHash(NSBundle.mainBundle.bundleIdentifier ?: @"");
    if (show) state |= kDSStageStateActiveBit;
    static int token = NOTIFY_TOKEN_INVALID;
    if (token == NOTIFY_TOKEN_INVALID) {
        notify_register_check(kDSKeyboardRequestNotification, &token);
    }
    uint32_t setStatus = 1;
    if (token != NOTIFY_TOKEN_INVALID) setStatus = notify_set_state(token, state);
    uint32_t postStatus = notify_post(kDSKeyboardRequestNotification);
    DSShipKeyboardTrace([NSString stringWithFormat:@"app req %@ %@",
                         NSBundle.mainBundle.bundleIdentifier ?: @"?",
                         show ? @"show" : @"hide"]);
    DSTraceFormat(@"app keyboard request %@ token=%d set=%u post=%u",
                  show ? @"show" : @"hide", token, setStatus, postStatus);
}

// The picker keyboard, without the blank input view. The message field stays
// first responder. Resigning it is what hid the keys and shifted the bar.
static void DSPostPickerKeyboard(BOOL show) {
    if (!DSStaged() || !DSMessagesDrawsOwnKeyboard()) return;
    uint64_t state = DSIdentifierHash(NSBundle.mainBundle.bundleIdentifier ?: @"");
    if (show) state |= kDSStageStateActiveBit;
    static int token = NOTIFY_TOKEN_INVALID;
    if (token == NOTIFY_TOKEN_INVALID) {
        notify_register_check(kDSKeyboardRequestNotification, &token);
    }
    uint32_t setStatus = 1;
    if (token != NOTIFY_TOKEN_INVALID) setStatus = notify_set_state(token, state);
    uint32_t postStatus = notify_post(kDSKeyboardRequestNotification);
    DSTraceFormat(@"app keyboard request %@ token=%d set=%u post=%u",
                  show ? @"show" : @"hide", token, setStatus, postStatus);
}

// A custom input view with no height tells Messages there is nothing to slide
// up for. SpringBoard draws the keys. Returning this before the field is
// tapped would change the conversation, so it is only used after the tap.
static UIView *DSMessagesBlankInputView(void) {
    static UIView *blank = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        blank = [[UIView alloc] initWithFrame:CGRectZero];
        blank.backgroundColor = UIColor.clearColor;
        blank.userInteractionEnabled = NO;
        blank.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    });
    return blank;
}

static NSMutableDictionary<NSString *, NSValue *> *DSInputViewOrigs = nil;

static UIView *DSBlankInputViewHook(id self, SEL cmd) {
    if (DSStaged() && DSMessagesUsesStageKeyboard() && DSStageKeyboardWanted) {
        return DSMessagesBlankInputView();
    }
    NSValue *boxed = DSInputViewOrigs[NSStringFromClass(object_getClass(self))];
    IMP orig = boxed ? (IMP)boxed.pointerValue : NULL;
    if (!orig) return nil;
    return ((UIView *(*)(id, SEL))orig)(self, cmd);
}

static void DSSuppressLocalKeyboardForResponder(UIResponder *responder) {
    if (!DSStaged() || !DSMessagesUsesStageKeyboard() || !responder) return;
    Class cls = object_getClass(responder);
    SEL sel = @selector(inputView);
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL owns = NO;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) == sel) owns = YES;
    }
    free(methods);
    if (!owns) return;
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    if (method_getImplementation(method) == (IMP)DSBlankInputViewHook) return;
    if (!DSInputViewOrigs) DSInputViewOrigs = [NSMutableDictionary dictionary];
    NSString *key = NSStringFromClass(cls);
    if (DSInputViewOrigs[key]) return;
    IMP previous = method_setImplementation(method, (IMP)DSBlankInputViewHook);
    DSInputViewOrigs[key] = [NSValue valueWithPointer:(void *)previous];
    DSTraceFormat(@"app blank keyboard on %@", key);
}

static void DSArmStageKeyboard(UIResponder *responder);
static void DSRecordKeyboardWhy(NSString *why);
static void DSNoteStageKeyboardResign(UIResponder *responder);

// UIKit moves these shells down to sit above its own keyboard. That is the
// conversation leaving the card. Keep the frame it had when the field was tapped.
static CGRect DSMessagesHoldFrame(UIView *view, CGRect proposed) {
    // Freezing a shell mid-layout is what locked the keyboard and the reply bar.
    (void)view;
    return proposed;
    if (!DSStaged() || !DSMessagesHoldsReplyBar() || !view) return proposed;
    CGRect current = view.frame;
    if (CGRectGetWidth(current) < 40.0 || CGRectGetHeight(current) < 40.0) return proposed;
    // y of ±4000 is the composer parked off the card, or coming back on.
    if (fabs(current.origin.y) > 1500.0 || fabs(proposed.origin.y) > 1500.0) return proposed;
    // A few points at a time still walks the bar down the card. Hold any shift.
    BOOL moved = fabs(proposed.origin.x - current.origin.x) > 0.5 ||
                 fabs(proposed.origin.y - current.origin.y) > 0.5;
    BOOL resized = fabs(CGRectGetWidth(proposed) - CGRectGetWidth(current)) > 24.0 ||
                   fabs(CGRectGetHeight(proposed) - CGRectGetHeight(current)) > 24.0;
    if (!moved && !resized) return proposed;
    static NSInteger logs = 0;
    if (logs < 12) {
        logs += 1;
        DSTraceFormat(@"app froze %@ %@ -> %@",
                      NSStringFromClass(object_getClass(view)),
                      NSStringFromCGRect(current),
                      NSStringFromCGRect(proposed));
    }
    return current;
}

static void DSBanishLocalKeyboard(void);
static BOOL DSResignIsFromKeyWindow(void);
static BOOL DSResponderTakesText(UIResponder *responder);
static BOOL DSIsKeyboardWindow(UIWindow *window);

static NSInteger DSLastKeyboardInputSeq = 0;
// Letters already in the file when this process starts are from an earlier
// launch. Applying them with the new key is the hitch on the first tap.
static BOOL DSKeyboardCaughtUp = NO;
static BOOL DSInKeyboardApply = NO;
static BOOL DSDrainQueued = NO;
// The field the user tapped. SpringBoard taking the key window can make UIKit
// drop first-responder status; the field is still where the text has to go.
static __weak UIResponder *DSKeyboardTarget = nil;
static BOOL DSKeyboardTargetOnScreen = NO;
static CFAbsoluteTime DSKeyboardShownAt = 0;
static BOOL DSLoggedMissingTextTarget = NO;
static NSString *DSLoggedEditingClass = nil;
// Set while a letter is being written into the tapped field. The app must not
// open its own keyboard for that, and it must not hide the one already up.
static BOOL DSDeliveringStageKey = NO;

static void DSPrepareMessagesForSpringBoardKeyboard(UIResponder *responder) {
    if (!DSMessagesOwnsKeyboard() || !DSResponderTakesText(responder)) return;
    DSStageKeyboardWanted = YES;
    DSStageKeyboardGuardUntil = CFAbsoluteTimeGetCurrent() + 1.5;
}

static void DSArmStageKeyboard(UIResponder *responder) {
    if (!DSStaged() || !DSMessagesUsesStageKeyboard() || DSDeliveringStageKey) return;
    // Beeper keeps the keyboard UIKit attached to its field. Asking
    // SpringBoard for another one, and blanking this one, is why the keys
    // never appear and the quick bar lifts.
    if (DSIsBeeper()) return;
    // Same keyboard as the picker search: SpringBoard shows it. No blank
    // input view, so the message field and the app strip stay.
    if (DSMessagesOwnsKeyboard()) {
        DSStageKeyboardWanted = YES;
        DSStageKeyboardGuardUntil = CFAbsoluteTimeGetCurrent() + 1.5;
        if ([NSStringFromClass(responder.class) rangeOfString:@"SearchBar"].location == NSNotFound) {
            DSShowMessageEntryAboveKeyboard(responder);
            __weak UIResponder *weakResponder = responder;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIResponder *strongResponder = weakResponder;
                if (strongResponder) DSShowMessageEntryAboveKeyboard(strongResponder);
            });
        } else {
            DSRecordKeyboardWhy([NSString stringWithFormat:@"focus %@", NSStringFromClass(responder.class)]);
        }
        DSRequestSpringBoardKeyboard(YES);
        return;
    }
    DSStageKeyboardWanted = YES;
    DSStageKeyboardGuardUntil = CFAbsoluteTimeGetCurrent() + 1.5;
    DSMessagesBarHeld = YES;
    DSAnchorMessageEntry(responder);
    DSSuppressLocalKeyboardForResponder(responder);
    DSRequestSpringBoardKeyboard(YES);
}

static void DSRecordKeyboardWhy(NSString *why) {
    if (why.length == 0) return;
    NSString *path = @"/var/tmp/com.recreated.dynamicstage.keyboard-why";
    [why writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    chmod(path.fileSystemRepresentation, 0666);
}

// SpringBoard's stage log is a different process. This is the line that shows
// up there when the app decides to keep or drop the keyboard.
static void DSShipKeyboardTrace(NSString *line) {
    if (line.length == 0) return;
    [line writeToFile:kDSKeyboardTracePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    chmod(kDSKeyboardTracePath.fileSystemRepresentation, 0666);
    static int token = NOTIFY_TOKEN_INVALID;
    if (token == NOTIFY_TOKEN_INVALID) {
        notify_register_check(kDSKeyboardTraceNotification, &token);
    }
    if (token != NOTIFY_TOKEN_INVALID) notify_post(kDSKeyboardTraceNotification);
}

// A phone call deactivates the app. That resign is not the user leaving the
// field, and letting it through is what takes the stage keyboard down.
static BOOL DSResignIsSystemDeactivation(void) {
    for (NSString *frame in NSThread.callStackSymbols) {
        if ([frame rangeOfString:@"resignActive"].location != NSNotFound) return YES;
        if ([frame rangeOfString:@"_deactivate"].location != NSNotFound) return YES;
        if ([frame rangeOfString:@"InCall" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
        if ([frame rangeOfString:@"beginInterruption"].location != NSNotFound) return YES;
        if ([frame rangeOfString:@"AVAudioSession"].location != NSNotFound) return YES;
    }
    return NO;
}

static BOOL DSResignIsSearchCancel(void) {
    for (NSString *frame in NSThread.callStackSymbols) {
        if ([frame rangeOfString:@"cancelButton" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
        if ([frame rangeOfString:@"CancelButton"].location != NSNotFound) return YES;
        if ([frame rangeOfString:@"searchBarCancel" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
        if ([frame rangeOfString:@"_cancelButtonPressed"].location != NSNotFound) return YES;
        if ([frame rangeOfString:@"DSSearchCancel"].location != NSNotFound) return YES;
    }
    return NO;
}

static IMP DSSearchCancelOrig = NULL;
static void DSSearchCancel(id self, SEL cmd) {
    DSShipKeyboardTrace(@"search cancel button");
    DSRecordKeyboardWhy(@"cancel=1");
    DSStageKeyboardWanted = NO;
    DSStageKeyboardGuardUntil = 0;
    DSRequestSpringBoardKeyboard(NO);
    if (DSSearchCancelOrig) ((void (*)(id, SEL))DSSearchCancelOrig)(self, cmd);
}

static void DSInstallSearchCancelHook(void) {
    Class bar = objc_getClass("UISearchBar");
    NSString *found = @"none";
    for (NSString *name in @[ @"_cancelButtonPressed", @"_cancelButtonClicked:", @"cancelButtonClicked:" ]) {
        SEL sel = NSSelectorFromString(name);
        Method method = class_getInstanceMethod(bar, sel);
        if (!method) continue;
        found = name;
        DSSearchCancelOrig = method_setImplementation(method, (IMP)DSSearchCancel);
        break;
    }
    DSShipKeyboardTrace([NSString stringWithFormat:@"hook search-cancel %@", found]);
}

static void DSNoteStageKeyboardResign(UIResponder *responder) {
    if (DSIsBeeper()) return;
    if (!DSStaged() || !DSMessagesUsesStageKeyboard() || DSDeliveringStageKey) return;
    if (DSMessagesOwnsKeyboard()) {
        NSString *name = NSStringFromClass(responder.class);
        // Messages resigns the conversation search field after a letter. That
        // is not the user leaving. Cancel is: the button is on the stack.
        BOOL searchField = [name rangeOfString:@"SearchBar"].location != NSNotFound;
        BOOL cancel = DSResignIsSearchCancel();
        BOOL inGuard = CFAbsoluteTimeGetCurrent() < DSStageKeyboardGuardUntil;
        BOOL blocked = (searchField && !cancel) || (inGuard && !cancel);
        NSString *why = [NSString stringWithFormat:@"resign %@ cancel=%d blocked=%d guard=%d",
                         name, cancel, blocked, inGuard];
        DSRecordKeyboardWhy(cancel ? @"cancel=1" : why);
        DSShipKeyboardTrace(why);
        if (blocked) return;
        DSStageKeyboardWanted = NO;
        DSRequestSpringBoardKeyboard(NO);
        return;
    }
    if (CFAbsoluteTimeGetCurrent() < DSStageKeyboardGuardUntil) {
        DSTraceFormat(@"app ignored hide %@", NSStringFromClass(responder.class));
        return;
    }
    DSTraceFormat(@"app resigned %@", NSStringFromClass(responder.class));
    DSRequestSpringBoardKeyboard(NO);
}
// The message box became the editor. UIKit then hides its own keyboard because
// the stage window took the key, and that hide is what removes the blue line.
static BOOL DSComposerHeld = NO;
static CFAbsoluteTime DSComposerHeldAt = 0;
static BOOL DSSuppressComposerResign = NO;
static BOOL DSAllowKeyboardHide = NO;

static void DSHoldComposer(void) {
    DSComposerHeld = YES;
    DSComposerHeldAt = CFAbsoluteTimeGetCurrent();
}

static void DSReleaseComposer(void) {
    DSComposerHeld = NO;
    DSComposerHeldAt = 0;
}

static BOOL DSResignIsFromKeyWindow(void) {
    for (NSString *frame in NSThread.callStackSymbols) {
        if ([frame rangeOfString:@"resignKeyWindow"].location != NSNotFound) return YES;
        if ([frame rangeOfString:@"makeKeyWindow"].location != NSNotFound) return YES;
        if ([frame rangeOfString:@"becomeKeyWindow"].location != NSNotFound) return YES;
    }
    return NO;
}

static BOOL DSKeepComposer(UIResponder *responder) {
    if (DSMessagesOwnsKeyboard()) return NO;
    if (DSMessagesHandoffResign) return NO;
    if (!DSStaged() || DSDeliveringStageKey || !responder) return NO;
    BOOL text = DSResponderTakesText(responder) ||
        [responder isKindOfClass:UITextField.class] ||
        [responder isKindOfClass:UITextView.class];
    if (!text) return NO;
    // The first letter shows, then a resign about a second later wipes the
    // field back to "Text Message" and the keyboard stops taking keys.
    if (DSStageKeyboardWanted) return YES;
    if (!DSComposerHeld) return NO;
    if (DSSuppressComposerResign || DSResignIsFromKeyWindow()) return YES;
    return DSComposerHeldAt > 0 && CFAbsoluteTimeGetCurrent() - DSComposerHeldAt < 1.0;
}

static UIResponder *DSFirstResponderInView(UIView *view) {
    if (![view isKindOfClass:UIView.class]) return nil;
    if (view.isFirstResponder) return view;
    for (UIView *subview in view.subviews) {
        UIResponder *found = DSFirstResponderInView(subview);
        if (found) return found;
    }
    return nil;
}

static UIResponder *DSCurrentKeyInput(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        UIResponder *found = DSFirstResponderInView(window);
        if (found) return found;
    }
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                UIResponder *found = DSFirstResponderInView(window);
                if (found) return found;
            }
        }
    }
    return nil;
}

static BOOL DSResponderTakesText(UIResponder *responder) {
    if (!responder) return NO;
    if ([responder isKindOfClass:UITextField.class] || [responder isKindOfClass:UITextView.class]) return YES;
    return [responder respondsToSelector:@selector(insertText:)] &&
           [responder respondsToSelector:@selector(deleteBackward)];
}

static NSString *DSPlainText(UIResponder *responder) {
    if ([responder isKindOfClass:UITextField.class]) return ((UITextField *)responder).text ?: @"";
    if ([responder isKindOfClass:UITextView.class]) return ((UITextView *)responder).text ?: @"";
    if ([responder conformsToProtocol:@protocol(UITextInput)]) {
        id<UITextInput> input = (id<UITextInput>)responder;
        UITextRange *all = [input textRangeFromPosition:input.beginningOfDocument toPosition:input.endOfDocument];
        return all ? ([input textInRange:all] ?: @"") : @"";
    }
    return nil;
}

static void DSInsertTextIntoInput(id<UITextInput> input, NSString *text) {
    UITextRange *selected = input.selectedTextRange;
    if (!selected && input.endOfDocument) {
        UITextPosition *end = input.endOfDocument;
        selected = [input textRangeFromPosition:end toPosition:end];
    }
    if (selected) [input replaceRange:selected withText:text];
}

static void DSDeleteFromInput(id<UITextInput> input) {
    UITextRange *selected = input.selectedTextRange;
    if (!selected) return;
    if ([input comparePosition:selected.start toPosition:selected.end] != NSOrderedSame) {
        [input replaceRange:selected withText:@""];
        return;
    }
    UITextPosition *before = [input positionFromPosition:selected.start offset:-1];
    if (!before) return;
    UITextRange *range = [input textRangeFromPosition:before toPosition:selected.start];
    if (range) [input replaceRange:range withText:@""];
}

static NSString *DSResponderClassName(UIResponder *responder) {
    return responder ? NSStringFromClass(object_getClass(responder)) : @"nil";
}

static void DSLogEditingTarget(UIResponder *responder) {
    NSString *name = DSResponderClassName(responder);
    if ([name isEqualToString:DSLoggedEditingClass]) return;
    DSLoggedEditingClass = [name copy];
    BOOL editing = responder.isFirstResponder;
    BOOL hasWindow = [responder isKindOfClass:UIView.class] && ((UIView *)responder).window != nil;
    DSDiagnosticsRecordFormat(@"app: editing %@ fr=%d win=%d", name, editing, hasWindow);
}

static void DSRememberKeyboardTarget(UIResponder *responder) {
    if (!DSResponderTakesText(responder)) return;
    UIResponder *existing = DSKeyboardTarget;
    if (existing && existing != responder &&
        [existing isKindOfClass:UITextField.class] &&
        [responder isKindOfClass:UIView.class] &&
        [(UIView *)responder isDescendantOfView:(UIView *)existing]) {
        return;
    }
    DSKeyboardTarget = responder;
    DSKeyboardTargetOnScreen = [responder isKindOfClass:UIView.class] && ((UIView *)responder).window != nil;
    DSLoggedMissingTextTarget = NO;
}

static UIResponder *DSBottomTextInputInView(UIView *view, UIResponder *best, CGFloat *bestY) {
    if (([view isKindOfClass:UITextField.class] || [view isKindOfClass:UITextView.class]) &&
        !view.hidden && view.alpha > 0.01 && view.window) {
        CGRect frame = [view convertRect:view.bounds toView:nil];
        CGFloat y = CGRectGetMaxY(frame);
        if (y >= *bestY) {
            *bestY = y;
            best = view;
        }
    }
    for (UIView *subview in view.subviews) {
        best = DSBottomTextInputInView(subview, best, bestY);
    }
    return best;
}

static UIResponder *DSBottomTextInput(void) {
    UIResponder *best = nil;
    CGFloat bestY = -CGFLOAT_MAX;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (DSIsKeyboardWindow(window)) continue;
        best = DSBottomTextInputInView(window, best, &bestY);
    }
    return best;
}

static UIResponder *DSTypingResponder(void) {
    UIResponder *remembered = DSKeyboardTarget;
    if ([remembered isKindOfClass:UIView.class] && ((UIView *)remembered).window) return remembered;
    if (remembered && ![remembered isKindOfClass:UIView.class]) return remembered;
    UIResponder *current = DSCurrentKeyInput();
    if (current) return current;
    return DSBottomTextInput();
}

static NSRange DSEditRange(NSString *current, NSRange range, BOOL isDelete) {
    if (!current) current = @"";
    if (range.location == NSNotFound || NSMaxRange(range) > current.length) {
        range = NSMakeRange(current.length, 0);
    }
    if (isDelete && range.length == 0) {
        if (range.location == 0) return NSMakeRange(NSNotFound, 0);
        return NSMakeRange(range.location - 1, 1);
    }
    return range;
}

static void DSNotifyInputDelegate(id<UITextInput> input, BOOL willChange) {
    id<UITextInputDelegate> delegate = input.inputDelegate;
    if (willChange && [delegate respondsToSelector:@selector(textWillChange:)]) {
        [delegate textWillChange:input];
    } else if (!willChange && [delegate respondsToSelector:@selector(textDidChange:)]) {
        [delegate textDidChange:input];
    }
}

// insertText: does nothing once the stage window has taken the key and this
// field is no longer first responder. Write the storage, then tell the
// field's own delegate, which is what actually keeps the message.
static void DSWritePlainText(UIResponder *responder, NSString *replacement, BOOL isDelete) {
    NSString *repl = isDelete ? @"" : (replacement ?: @"");
    if ([responder isKindOfClass:UITextView.class]) {
        UITextView *view = (UITextView *)responder;
        NSString *current = view.textStorage.string ?: view.text ?: @"";
        NSRange range = view.isFirstResponder ? view.selectedRange : NSMakeRange(current.length, 0);
        range = DSEditRange(current, range, isDelete);
        if (range.location == NSNotFound) return;
        id delegate = view.delegate;
        SEL shouldChange = @selector(textView:shouldChangeTextInRange:replacementText:);
        BOOL allow = YES;
        if ([delegate respondsToSelector:shouldChange]) {
            allow = ((BOOL (*)(id, SEL, UITextView *, NSRange, NSString *))objc_msgSend)(
                delegate, shouldChange, view, range, repl);
        }
        NSString *afterAsk = view.text ?: @"";
        if (!allow && ![afterAsk isEqualToString:current]) return;
        NSString *next = [current stringByReplacingCharactersInRange:range withString:repl];
        if ([afterAsk isEqualToString:current]) {
            DSNotifyInputDelegate(view, YES);
            NSTextStorage *storage = view.textStorage;
            if (storage && NSMaxRange(range) <= storage.length) {
                [storage beginEditing];
                [storage replaceCharactersInRange:range withString:repl];
                [storage endEditing];
            }
            if (![(view.text ?: @"") isEqualToString:next]) view.text = next;
            NSUInteger caret = range.location + repl.length;
            if (caret <= (view.text ?: @"").length) view.selectedRange = NSMakeRange(caret, 0);
            DSNotifyInputDelegate(view, NO);
        }
        SEL didChange = @selector(textViewDidChange:);
        if ([delegate respondsToSelector:didChange]) {
            ((void (*)(id, SEL, UITextView *))objc_msgSend)(delegate, didChange, view);
        }
        [NSNotificationCenter.defaultCenter postNotificationName:UITextViewTextDidChangeNotification object:view];
        return;
    }
    if ([responder isKindOfClass:UITextField.class]) {
        UITextField *field = (UITextField *)responder;
        NSString *current = field.text ?: @"";
        NSRange range = NSMakeRange(current.length, 0);
        if (field.isFirstResponder && [field conformsToProtocol:@protocol(UITextInput)]) {
            id<UITextInput> input = (id<UITextInput>)field;
            UITextRange *selected = input.selectedTextRange;
            if (selected && input.beginningOfDocument) {
                NSInteger start = [input offsetFromPosition:input.beginningOfDocument toPosition:selected.start];
                NSInteger end = [input offsetFromPosition:input.beginningOfDocument toPosition:selected.end];
                if (start >= 0 && end >= start && end <= (NSInteger)current.length) {
                    range = NSMakeRange((NSUInteger)start, (NSUInteger)(end - start));
                }
            }
        }
        range = DSEditRange(current, range, isDelete);
        if (range.location == NSNotFound) return;
        id delegate = field.delegate;
        SEL shouldChange = @selector(textField:shouldChangeCharactersInRange:replacementString:);
        BOOL allow = YES;
        if ([delegate respondsToSelector:shouldChange]) {
            allow = ((BOOL (*)(id, SEL, UITextField *, NSRange, NSString *))objc_msgSend)(
                delegate, shouldChange, field, range, repl);
        }
        NSString *afterAsk = field.text ?: @"";
        if (!allow && ![afterAsk isEqualToString:current]) return;
        if ([afterAsk isEqualToString:current]) {
            field.text = [current stringByReplacingCharactersInRange:range withString:repl];
        }
        [field sendActionsForControlEvents:UIControlEventEditingChanged];
        [NSNotificationCenter.defaultCenter postNotificationName:UITextFieldTextDidChangeNotification object:field];
        return;
    }
    if ([responder conformsToProtocol:@protocol(UITextInput)]) {
        id<UITextInput> input = (id<UITextInput>)responder;
        DSNotifyInputDelegate(input, YES);
        if (isDelete) DSDeleteFromInput(input);
        else DSInsertTextIntoInput(input, repl);
        DSNotifyInputDelegate(input, NO);
    }
    if ([responder respondsToSelector:@selector(setText:)] && !isDelete && repl.length > 0) {
        NSString *now = DSPlainText(responder);
        if (!now || [now rangeOfString:repl].location == NSNotFound) {
            [(id)responder setText:repl];
        }
    }
}

static void DSWriteFile(const char *path, const char *text) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    ssize_t wrote = write(fd, text, strlen(text));
    (void)wrote;
    close(fd);
}

// notify_register_check can fail in a sandboxed app before anyone is listening.
// The post still has to happen, or SpringBoard never learns this image mapped.
static void DSPostApply(uint64_t state) {
    static int token = NOTIFY_TOKEN_INVALID;
    if (token == NOTIFY_TOKEN_INVALID) {
        notify_register_check(kDSKeyboardApplyNotification, &token);
    }
    if (token != NOTIFY_TOKEN_INVALID) notify_set_state(token, state);
    notify_post(kDSKeyboardApplyNotification);
}

static void DSReportKeyApplied(BOOL isDelete, UIResponder *responder, BOOL changed, BOOL notStaged, BOOL heldStandIn) {
    uint64_t state = DSIdentifierHash(NSBundle.mainBundle.bundleIdentifier ?: @"");
    if (changed) state |= (1ULL << 32);
    if (responder) state |= (1ULL << 33);
    if (responder.isFirstResponder) state |= (1ULL << 34);
    BOOL hasWindow = [responder isKindOfClass:UIView.class] && ((UIView *)responder).window != nil;
    if (hasWindow) state |= (1ULL << 35);
    if (isDelete) state |= (1ULL << 36);
    if (notStaged) state |= (1ULL << 37);
    // The stand-in kept the keyboard. The message field was not made the editor.
    if (heldStandIn) state |= (1ULL << 60);
    NSUInteger kind = 0;
    if ([responder isKindOfClass:UITextField.class]) kind = 1;
    else if ([responder isKindOfClass:UITextView.class]) kind = 2;
    else if (responder) kind = 3;
    state |= ((uint64_t)kind) << 40;
    DSPostApply(state);
}

static void DSReportListening(void) {
    uint64_t state = DSIdentifierHash(NSBundle.mainBundle.bundleIdentifier ?: @"");
    state |= (1ULL << 38);
    DSPostApply(state);
}

static void DSReportCtor(int reason) {
    NSString *identifier = @"";
    NSString *path = @"";
    NSString *proc = @"";
    @try {
        identifier = NSBundle.mainBundle.bundleIdentifier ?: @"";
        path = NSBundle.mainBundle.bundlePath ?: @"";
        proc = NSProcessInfo.processInfo.processName ?: @"";
    } @catch (NSException *exception) {
    }
    const char *names[] = { "ok", "kill", "bundle", "excluded", "not-user", "prefs", "threw" };
    const char *why = (reason >= 0 && reason <= 6) ? names[reason] : "other";
    char line[1024];
    snprintf(line, sizeof(line), "%s proc=%s bundle=%s path=%s\n",
             why,
             proc.UTF8String ?: "?",
             identifier.UTF8String ?: "?",
             path.UTF8String ?: "?");
    DSWriteFile("/var/tmp/com.recreated.dynamicstage.ctor", line);
    DSWriteFile("/var/jb/tmp/com.recreated.dynamicstage.ctor", line);
    uint64_t state = DSIdentifierHash(identifier);
    state |= (1ULL << 39) | (1ULL << 49);
    state |= ((uint64_t)(reason & 0xf) << 56);
    DSPostApply(state);
}

static void DSReportLoaded(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        uint64_t state = DSIdentifierHash(NSBundle.mainBundle.bundleIdentifier ?: @"");
        state |= (1ULL << 39);
        DSPostApply(state);
    });
}

static void DSReportRemoteKeyboard(void) {
    static BOOL reported = NO;
    if (reported) return;
    reported = YES;
    uint64_t state = DSIdentifierHash(NSBundle.mainBundle.bundleIdentifier ?: @"");
    state |= (1ULL << 48) | (1ULL << 39) | (1ULL << 38) | (1ULL << 49);
    DSPostApply(state);
}

static void DSReportRemoteSkipped(void) {
    static BOOL reported = NO;
    if (reported) return;
    reported = YES;
    uint64_t state = DSIdentifierHash(NSBundle.mainBundle.bundleIdentifier ?: @"");
    state |= (1ULL << 50) | (1ULL << 39) | (1ULL << 49);
    DSPostApply(state);
}

// Bit 48 is "SpringBoard may lift". A call that happens before the app is
// staged must not consume that, or the later staged call never gets through.
static int DSRemoteStagedPath = 0;
static uint32_t DSRemotePathsReported = 0;

static void DSReportRemotePath(int path, BOOL staged) {
    // Bit 48 makes SpringBoard raise its own keyboard window. That window
    // covers Messages' keys, and the taps never arrive.
    if (DSMessagesOwnsKeyboard()) return;
    uint64_t state = DSIdentifierHash(NSBundle.mainBundle.bundleIdentifier ?: @"");
    state |= (1ULL << 39) | (1ULL << 49) | (1ULL << 51);
    if (path > 0) state |= ((uint64_t)(path & 0xf) << 52);
    if (!staged) {
        static BOOL skipped = NO;
        if (skipped) return;
        skipped = YES;
        state |= (1ULL << 50);
        DSPostApply(state);
        return;
    }
    // These getters run on every layout. Reporting again each time the path
    // number changed woke SpringBoard on every pass and the keyboard show
    // never settled. Each path is delivered once.
    uint32_t bit = 1u << (path & 0xf);
    if (DSRemotePathsReported & bit) return;
    DSRemotePathsReported |= bit;
    DSRemoteStagedPath = path;
    state |= (1ULL << 48);
    DSPostApply(state);
}

static void DSReportRemoteArmed(void) {
    uint64_t state = DSIdentifierHash(NSBundle.mainBundle.bundleIdentifier ?: @"");
    state |= (1ULL << 39) | (1ULL << 49) | (1ULL << 51);
    DSPostApply(state);
}

static void DSReportRemoteMissing(void) {
    uint64_t state = DSIdentifierHash(NSBundle.mainBundle.bundleIdentifier ?: @"");
    state |= (1ULL << 39) | (1ULL << 49);
    state |= (15ULL << 52);
    DSPostApply(state);
}

static void DSTypeText(UIResponder *responder, NSString *text) {
    NSString *before = DSPlainText(responder);
    if ([responder conformsToProtocol:@protocol(UITextInput)]) {
        DSInsertTextIntoInput((id<UITextInput>)responder, text);
    }
    NSString *after = DSPlainText(responder);
    BOOL unchanged = before && after && [before isEqualToString:after];
    if (unchanged || ![responder conformsToProtocol:@protocol(UITextInput)]) {
        if ([responder respondsToSelector:@selector(insertText:)]) [(id)responder insertText:text];
    }
}

static void DSTypeDelete(UIResponder *responder) {
    NSString *before = DSPlainText(responder);
    if ([responder respondsToSelector:@selector(deleteBackward)]) [(id)responder deleteBackward];
    NSString *after = DSPlainText(responder);
    BOOL unchanged = before && after && [before isEqualToString:after];
    if (unchanged && [responder conformsToProtocol:@protocol(UITextInput)]) {
        DSDeleteFromInput((id<UITextInput>)responder);
    }
}

static void DSApplyKeyboardOp(NSString *op, NSString *text) {
    UIResponder *responder = DSTypingResponder();
    BOOL isDelete = [op isEqualToString:@"delete"];
    if (!responder) {
        if (!DSLoggedMissingTextTarget) {
            DSLoggedMissingTextTarget = YES;
            DSDiagnosticsRecord(@"app: keyboard had no text field to type into");
        }
        DSReportKeyApplied(isDelete, nil, NO, NO, NO);
        return;
    }
    DSLogEditingTarget(responder);
    DSDeliveringStageKey = YES;
    // Making the message field first responder resigns the stand-in. Its
    // input view is empty, so UIKit dismisses the live keyboard and the
    // stand-in then becomes first responder again. That gap is the flicker.
    // The letter is written into the field without moving the keyboard.
    BOOL heldStandIn = DSMessagesOwnsKeyboard() && DSStageKeyboardWanted;
    if (!heldStandIn &&
        !responder.isFirstResponder &&
        [responder respondsToSelector:@selector(becomeFirstResponder)]) {
        [responder becomeFirstResponder];
    }
    NSString *before = DSPlainText(responder);
    if (isDelete) {
        DSTypeDelete(responder);
    } else if (text.length > 0) {
        DSTypeText(responder, text);
    } else {
        DSDeliveringStageKey = NO;
        return;
    }
    NSString *after = DSPlainText(responder);
    BOOL unchanged = (!before && !after) || (before && after && [before isEqualToString:after]);
    if (unchanged) {
        DSWritePlainText(responder, text, isDelete);
        after = DSPlainText(responder);
        unchanged = (!before && !after) || (before && after && [before isEqualToString:after]);
    }
    DSDeliveringStageKey = NO;
    DSReportKeyApplied(isDelete, responder, before && after && !unchanged, NO, heldStandIn);
    NSString *changed = @"?";
    if (before && after) changed = unchanged ? @"0" : @"1";
    BOOL editing = responder.isFirstResponder;
    BOOL hasWindow = [responder isKindOfClass:UIView.class] && ((UIView *)responder).window != nil;
    DSDiagnosticsRecordFormat(@"app: key %@ -> %@ fr=%d win=%d changed=%@ hold=%d",
                              isDelete ? @"delete" : @"insert",
                              DSResponderClassName(responder),
                              editing,
                              hasWindow,
                              changed,
                              heldStandIn);
}

static int DSKeyboardInputStateToken = NOTIFY_TOKEN_INVALID;

static NSString *DSStringFromUTF32(UTF32Char code) {
    if (code == 0 || code > 0x10FFFF) return nil;
    if (code <= 0xFFFF) {
        unichar unit = (unichar)code;
        return [NSString stringWithCharacters:&unit length:1];
    }
    unichar pair[2];
    pair[0] = (unichar)(((code - 0x10000) >> 10) + 0xD800);
    pair[1] = (unichar)(((code - 0x10000) & 0x3FF) + 0xDC00);
    return [NSString stringWithCharacters:pair length:2];
}

// Messenger cannot always read the preferences file. The same letter is also
// carried on the notification, one character at a time.
static void DSApplyNotifyState(void) {
    if (DSKeyboardInputStateToken == NOTIFY_TOKEN_INVALID) {
        notify_register_check(kDSKeyboardInputNotification, &DSKeyboardInputStateToken);
    }
    if (DSKeyboardInputStateToken == NOTIFY_TOKEN_INVALID) return;
    uint64_t state = 0;
    notify_get_state(DSKeyboardInputStateToken, &state);
    NSInteger seq = (NSInteger)(state & 0xFFFFFFFF);
    if (seq <= DSLastKeyboardInputSeq) return;
    DSLastKeyboardInputSeq = seq;
    if ((state & (1ULL << 32)) != 0) {
        DSApplyKeyboardOp(@"delete", @"");
        return;
    }
    NSString *text = DSStringFromUTF32((UTF32Char)((state >> 33) & 0x1FFFFF));
    if (text.length == 0) return;
    DSApplyKeyboardOp(@"insert", text);
}

// Skip every letter already queued. The next notification is a new key.
static void DSCatchUpKeyboardInput(void) {
    NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:kDSKeyboardInputPath];
    NSInteger seq = [root[@"seq"] integerValue];
    BOOL saw = root != nil;
    for (NSDictionary *op in root[@"ops"]) {
        if (![op isKindOfClass:NSDictionary.class]) continue;
        saw = YES;
        NSInteger opSeq = [op[@"seq"] integerValue];
        if (opSeq > seq) seq = opSeq;
    }
    if (DSKeyboardInputStateToken == NOTIFY_TOKEN_INVALID) {
        notify_register_check(kDSKeyboardInputNotification, &DSKeyboardInputStateToken);
    }
    if (DSKeyboardInputStateToken != NOTIFY_TOKEN_INVALID) {
        uint64_t state = 0;
        if (notify_get_state(DSKeyboardInputStateToken, &state) == NOTIFY_STATUS_OK) {
            saw = YES;
            NSInteger stateSeq = (NSInteger)(state & 0xFFFFFFFF);
            if (stateSeq > seq) seq = stateSeq;
        }
    }
    if (!saw) return;
    if (seq > DSLastKeyboardInputSeq) DSLastKeyboardInputSeq = seq;
    DSKeyboardCaughtUp = YES;
}

static void DSDrainKeyboardInput(void) {
    if (!DSStaged()) {
        DSReportKeyApplied(NO, nil, NO, YES, NO);
        return;
    }
    if (DSInKeyboardApply) {
        DSDrainQueued = YES;
        return;
    }
    DSInKeyboardApply = YES;
    NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:kDSKeyboardInputPath];
    NSMutableArray<NSDictionary *> *pending = [NSMutableArray array];
    NSInteger maxSeq = [root[@"seq"] integerValue];
    for (NSDictionary *op in root[@"ops"]) {
        if (![op isKindOfClass:NSDictionary.class]) continue;
        NSInteger seq = [op[@"seq"] integerValue];
        if (seq > maxSeq) maxSeq = seq;
        if (seq <= DSLastKeyboardInputSeq) continue;
        [pending addObject:op];
    }
    // The file still holds earlier launches. The post that woke us is the
    // last one. Replaying the rest inserts extra letters and relayouts.
    if (!DSKeyboardCaughtUp) {
        DSKeyboardCaughtUp = YES;
        if (pending.count > 1) {
            DSTraceFormat(@"app skipped %ld old keys", (long)(pending.count - 1));
            NSDictionary *newest = pending.lastObject;
            NSInteger newestSeq = [newest[@"seq"] integerValue];
            [pending removeAllObjects];
            if (newest) [pending addObject:newest];
            if (newestSeq > 0 && newestSeq - 1 > DSLastKeyboardInputSeq) {
                DSLastKeyboardInputSeq = newestSeq - 1;
            }
        }
    }
    NSInteger before = DSLastKeyboardInputSeq;
    for (NSDictionary *op in pending) {
        NSInteger seq = [op[@"seq"] integerValue];
        if (seq <= DSLastKeyboardInputSeq) continue;
        DSLastKeyboardInputSeq = seq;
        DSApplyKeyboardOp(op[@"op"], op[@"text"]);
    }
    if (maxSeq > DSLastKeyboardInputSeq) DSLastKeyboardInputSeq = maxSeq;
    // A read can miss the line SpringBoard just wrote. The notification still
    // carries that one letter.
    if (DSLastKeyboardInputSeq == before) DSApplyNotifyState();
    DSInKeyboardApply = NO;
    if (DSDrainQueued) {
        DSDrainQueued = NO;
        DSDrainKeyboardInput();
    }
}

static CGRect DSStageBounds(void) {
    return [DSStageContext sharedContext].stageBounds;
}

// The remote keyboard window is SpringBoard's. The text-effects window is this
// process's input scene. Both stay the size of the phone. Told the card size,
// both draw the keys inside the card.
static BOOL DSIsRemoteKeyboardWindow(UIWindow *window) {
    if (![window isKindOfClass:UIWindow.class]) return NO;
    if ([window respondsToSelector:@selector(_isRemoteKeyboardWindow)] && [window _isRemoteKeyboardWindow]) return YES;
    NSString *name = NSStringFromClass(object_getClass(window));
    return [name rangeOfString:@"RemoteKeyboard"].location != NSNotFound;
}

static BOOL DSWindowUsesStageGeometry(UIWindow *window) {
    // SpringBoard already hosts Beeper in the card. Telling Beeper's own
    // window that it is the card as well is the second layout, and the
    // quick bar lifts.
    if (DSIsBeeper()) return NO;
    return window && !DSIsKeyboardWindow(window);
}

// A window a keyboard is drawn in. Hits on its keys are ignored, and it is
// never given the card's size.
static BOOL DSIsKeyboardWindow(UIWindow *window) {
    if (!window) return NO;
    if (DSIsRemoteKeyboardWindow(window)) return YES;
    if ([window respondsToSelector:@selector(_isTextEffectsWindow)] && [window _isTextEffectsWindow]) return YES;
    Class effects = objc_getClass("UITextEffectsWindow");
    return effects != Nil && [window isKindOfClass:effects];
}

// Hosted remote windows live in the card scene. The plain one is the keyboard
// SpringBoard already shows at the bottom of the phone. Hiding that one is
// why the keys never came up.
static BOOL DSIsPlainRemoteKeyboardWindow(UIWindow *window) {
    if (!DSIsRemoteKeyboardWindow(window)) return NO;
    NSString *name = NSStringFromClass(object_getClass(window));
    return [name rangeOfString:@"Hosted"].location == NSNotFound;
}

static BOOL DSHideKeysInThisWindow(UIWindow *window) {
    // The plain remote window in this process is the card (420 by 458 on a
    // 430 by 932 phone). Showing it paints the keys inside the stage. The
    // phone-width keyboard is SpringBoard's window, and that one is docked
    // to the bottom of the display.
    if (!window || !DSIsKeyboardWindow(window)) return NO;
    return YES;
}

#pragma mark - Screen

static BOOL DSIsMobilePhone(void);

// Phone keeps the real display metrics. Its root is laid out in a card-shaped
// box and scaled uniformly to fill the card (DSPhoneScaleRootIntoCard).
// This dylib is also in Messages. Those apps must keep the card metrics.
static BOOL DSPhoneKeepsRealScreen(void) {
    return DSIsMobilePhone();
}

%hook UIScreen

- (CGRect)bounds {
    if (DSIsBeeper() || DSPhoneKeepsRealScreen()) return %orig;
    if (DSStaged() && self == UIScreen.mainScreen) return DSStageBounds();
    return %orig;
}

- (CGRect)_referenceBounds {
    if (DSIsBeeper() || DSPhoneKeepsRealScreen()) return %orig;
    if (DSStaged() && self == UIScreen.mainScreen) return DSStageBounds();
    return %orig;
}

- (CGRect)applicationFrame {
    if (DSIsBeeper() || DSPhoneKeepsRealScreen()) return %orig;
    if (DSStaged() && self == UIScreen.mainScreen) return DSStageBounds();
    return %orig;
}

// ChatKit reads these, not -bounds. Other apps follow the card from their own
// view. Messages keeps laying out against the phone unless these agree.
- (CGRect)nativeBounds {
    CGRect native = %orig;
    if (DSIsBeeper() || DSPhoneKeepsRealScreen()) return native;
    if (DSIsReadingHardwareDisplay() || !DSStaged() || self != UIScreen.mainScreen) return native;
    CGRect stage = DSStageBounds();
    if (CGRectGetWidth(stage) < 80.0 || CGRectGetHeight(stage) < 80.0) return native;
    CGFloat scale = self.nativeScale > 0 ? self.nativeScale : self.scale;
    if (scale <= 0.0) return native;
    return CGRectMake(0.0, 0.0,
                      round(CGRectGetWidth(stage) * scale),
                      round(CGRectGetHeight(stage) * scale));
}

- (CGRect)_unjailedReferenceBounds {
    if (DSIsBeeper() || DSPhoneKeepsRealScreen()) return %orig;
    if (DSStaged() && self == UIScreen.mainScreen) return DSStageBounds();
    return %orig;
}

- (CGRect)_unjailedBounds {
    if (DSIsBeeper() || DSPhoneKeepsRealScreen()) return %orig;
    if (DSStaged() && self == UIScreen.mainScreen) return DSStageBounds();
    return %orig;
}

%end

#pragma mark - Application frame

%hook UIApplication

- (CGRect)_applicationFrameForInterfaceOrientation:(NSInteger)orientation
                              usingStatusbarHeight:(CGFloat)height
                                   ignoreStatusBar:(BOOL)ignore {
    if (DSIsBeeper() || DSPhoneKeepsRealScreen()) return %orig;
    if (DSStaged()) return DSStageBounds();
    return %orig;
}

- (CGRect)_applicationFrameWithoutOverscanForInterfaceOrientation:(NSInteger)orientation
                                             usingStatusbarHeight:(CGFloat)height
                                                  ignoreStatusBar:(BOOL)ignore {
    if (DSIsBeeper() || DSPhoneKeepsRealScreen()) return %orig;
    if (DSStaged()) return DSStageBounds();
    return %orig;
}

- (UIInterfaceOrientation)statusBarOrientation {
    if (DSIsBeeper()) return %orig;
    if (DSStaged()) return UIInterfaceOrientationPortrait;
    return %orig;
}

- (BOOL)isStatusBarHidden {
    if (DSIsBeeper()) return %orig;
    if (DSStaged()) return YES;
    return %orig;
}

%end

// The phone-sized keyboard window is only for the moment someone is typing.
// Leaving it up all the time is what carries the quick bar off the card.
static BOOL DSMessagesTyping(void) {
    if (!DSMessagesOwnsKeyboard()) return NO;
    // SpringBoard already placed this keyboard. Do not grow a second one.
    if (DSStageKeyboardWanted) return NO;
    UIResponder *responder = DSCurrentKeyInput();
    return responder.isFirstResponder && DSResponderTakesText(responder);
}

#pragma mark - Windows

%hook UIWindow

- (CGRect)_boundsForInterfaceOrientation:(NSInteger)orientation {
    if (DSStaged() && DSWindowUsesStageGeometry(self)) return DSStageBounds();
    return %orig;
}

- (CGRect)_referenceBounds {
    if (DSStaged() && DSWindowUsesStageGeometry(self)) return DSStageBounds();
    return %orig;
}

- (CGRect)_sceneBounds {
    if (DSStaged() && DSWindowUsesStageGeometry(self)) return DSStageBounds();
    return %orig;
}

- (BOOL)_shouldResizeWithScene {
    // The keyboard window stays the size of the phone, so the keys sit below
    // the card. The app's own windows still follow the card.
    if (DSMessagesTyping() && DSIsKeyboardWindow(self)) return YES;
    if (DSStaged() && DSWindowUsesStageGeometry(self)) return YES;
    return %orig;
}

- (BOOL)resizesToFullScreen {
    if (DSMessagesTyping() && DSIsKeyboardWindow(self)) return YES;
    return %orig;
}

- (BOOL)_shouldAdjustSizeClassesAndResizeWindow {
    if (DSStaged() && DSWindowUsesStageGeometry(self)) return YES;
    return %orig;
}

- (void)resignKeyWindow {
    BOOL hold = DSStaged() && !DSIsKeyboardWindow(self);
    if (hold) DSSuppressComposerResign = YES;
    %orig;
    if (hold) DSSuppressComposerResign = NO;
}

// Letting the window believe it owns the orientation is what stops UIKit from
// rotating the stage when the device turns.
- (BOOL)_windowOwnsInterfaceOrientation {
    if (DSIsBeeper()) return %orig;
    if (DSStaged()) return NO;
    return %orig;
}

- (BOOL)_transformLayerRotationsAreEnabled {
    if (DSIsBeeper()) return %orig;
    if (DSMessagesTyping() && DSIsKeyboardWindow(self)) return YES;
    if (DSStaged()) return NO;
    return %orig;
}

// Refreshed on the way in as well as on the way out: the layout UIKit does inside
// this call asks the hooks above how big the scene is, and the answer they have is
// the one from before the resize that caused it.
- (void)_sceneBoundsDidChange {
    if (DSStaged()) [[DSStageContext sharedContext] refresh];
    %orig;
    if (DSStaged()) [[DSStageContext sharedContext] refresh];
}

%end

#pragma mark - Orientation

%hook UIDevice

- (UIDeviceOrientation)orientation {
    if (DSStaged()) return UIDeviceOrientationPortrait;
    return %orig;
}

- (UIUserInterfaceIdiom)userInterfaceIdiom {
    if (DSStaged() && [DSStageContext sharedContext].padMode) return UIUserInterfaceIdiomPad;
    return %orig;
}

%end

static BOOL DSNameIsHomeChrome(NSString *name) {
    if (name.length == 0) return NO;
    if ([name rangeOfString:@"HomeGrabber"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"HomeAffordance"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"HomeIndicator"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"LumaDodgePill"].location != NSNotFound) return YES;
    return NO;
}

static void DSHideHomeChromeInView(UIView *view, NSInteger depth) {
    if (!DSStaged() || !view || depth > 10) return;
    if (DSNameIsHomeChrome(NSStringFromClass(object_getClass(view)))) {
        view.hidden = YES;
        view.alpha = 0.0;
        view.userInteractionEnabled = NO;
        return;
    }
    if ([view isKindOfClass:UICollectionView.class] || [view isKindOfClass:UITableView.class]) return;
    for (UIView *subview in view.subviews) DSHideHomeChromeInView(subview, depth + 1);
}

static UIView *DSFindMessageEntry(UIView *view, NSInteger depth) {
    if (!view || depth > 18) return nil;
    if ([view isKindOfClass:UICollectionView.class] || [view isKindOfClass:UITableView.class]) return nil;
    NSString *name = NSStringFromClass(object_getClass(view));
    if ([name rangeOfString:@"MessageEntry"].location != NSNotFound) return view;
    for (UIView *subview in view.subviews) {
        UIView *found = DSFindMessageEntry(subview, depth + 1);
        if (found) return found;
    }
    return nil;
}

// The reply field and the latest messages are laid out at the bottom of the
// phone. Pin that field to the bottom of the card and end the thread there,
// so the bottom of the conversation is on screen.
static BOOL DSClampingStage = NO;
// Held while the input bar is moved onto the conversation, so layout and
// setFrame cannot re-enter that move. The input stays put; this still guards
// the drop of the conversation onto it.
static NSInteger DSInputReparentDepth = 0;
static BOOL DSDroppingStage = NO;
static NSInteger DSDropQueryDepth = 0;
static BOOL DSViewIsCompatibilityInputView(UIView *view);
static CGRect DSDroppedRectForRoot(UIView *view);
static void DSDropOurViewToInput(void);
static void DSPinViewToStageBottom(UIView *view);

// Messages lays the reply bar out for the full display, so it sits below the
// card. Move that bar onto the card's bottom edge. A transform survives the
// layout pass that would put the frame back. The keyboard window is not resized.
// Moving the reply bar while the conversation is pushing aborts that push.
// The chat appears, then the list comes back, and neither the bar nor the
// keyboard is on screen. The bar is moved only after the chat has appeared.
// The view under the field (the gray keyboard slab) must not move with it.
// Climbing to the field's parent lifts that slab up over the field.
static BOOL DSReplyBarMayMove = NO;
static void DSTraceInputLayout(NSString *cause, UIView *view);

static void DSTraceInputOnce(NSString *key, NSString *line) {
    static NSMutableSet<NSString *> *seen = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        seen = [NSMutableSet set];
    });
    if (key.length == 0 || seen.count > 48 || [seen containsObject:key]) return;
    [seen addObject:key];
    DSTrace(line);
}

static BOOL DSNameIsUnderInputPiece(NSString *name) {
    if (name.length == 0) return NO;
    if ([name rangeOfString:@"Keyboard"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"InputSet"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"InputView"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"Backdrop"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"Prediction"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"Candidate"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"Dictation"].location != NSNotFound) return YES;
    return NO;
}

static NSString *DSViewBrief(UIView *view) {
    if (![view isKindOfClass:UIView.class]) return @"nil";
    return [NSString stringWithFormat:@"%@ f=%@ ty=%.0f hid=%d a=%.2f",
            NSStringFromClass(object_getClass(view)),
            NSStringFromCGRect(view.frame),
            view.transform.ty,
            view.hidden,
            view.alpha];
}

static NSString *DSPiecesAroundEntry(UIView *entry) {
    if (![entry isKindOfClass:UIView.class]) return @"no-entry";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    CGFloat entryBottom = CGRectGetMaxY(entry.frame);
    UIView *parent = entry.superview;
    for (UIView *sibling in parent.subviews) {
        if (sibling == entry) continue;
        BOOL below = CGRectGetMaxY(sibling.frame) > entryBottom + 4.0;
        BOOL above = CGRectGetMaxY(sibling.frame) <= CGRectGetMinY(entry.frame) + 4.0;
        if (!below && !above) continue;
        if (CGRectGetHeight(sibling.bounds) < 8.0 && CGRectGetWidth(sibling.bounds) < 8.0) continue;
        [parts addObject:[NSString stringWithFormat:@"%@ %@", below ? @"below" : @"above", DSViewBrief(sibling)]];
        if (parts.count >= 4) break;
    }
    for (UIView *child in entry.subviews) {
        if (CGRectGetMinY(child.frame) < CGRectGetHeight(entry.bounds) * 0.55) continue;
        [parts addObject:[NSString stringWithFormat:@"inside %@", DSViewBrief(child)]];
        if (parts.count >= 6) break;
    }
    return parts.count ? [parts componentsJoinedByString:@" | "] : @"nothing beside the field";
}

static void DSForgetReplyBarSpot(void) {
}

static void DSPullMessageBarUp(UIView *entry) {
    // The reply bar is already on the bottom of the card. Shifting it when
    // the field focuses is what lifted it into the conversation (frame y=-156
    // on a card that is 458pt tall).
    (void)entry;
}

static void DSScheduleReplyBarPull(UIView *entry) {
    UIView *held = entry;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!DSStaged()) return;
        DSReplyBarMayMove = YES;
        if (held) DSPullMessageBarUp(held);
    });
}

// The window stays the size of the phone. Shrinking that frame is what pulls
// the home bar onto the card. Messages still measures its bars, thread, and
// reply field from the phone, so a view laid out at the phone's size is fitted
// to the card. Cells inside a scrolling transcript are left alone.
static BOOL DSFrameIsPhoneWide(CGRect frame, CGRect device, CGRect stage) {
    CGFloat width = CGRectGetWidth(frame);
    return width > CGRectGetWidth(device) * 0.85 && width > CGRectGetWidth(stage) + 12.0;
}

static BOOL DSFrameIsPhoneTall(CGRect frame, CGRect device, CGRect stage) {
    CGFloat height = CGRectGetHeight(frame);
    return height > MAX(CGRectGetHeight(device), 1.0) * 0.70 && height > CGRectGetHeight(stage) + 12.0;
}

static CGRect DSFittedStageFrame(UIView *view, CGRect frame) {
    if (DSClampingStage || !DSStaged() || !view) return frame;
    // Phone keeps its full-screen frames. The root scale fits that UI to the
    // card. Fitting each piece here is what clipped the header.
    if (DSIsMobilePhone()) {
        UIWindow *owning = [view isKindOfClass:UIWindow.class] ? (UIWindow *)view : view.window;
        if (!owning || !DSIsKeyboardWindow(owning)) return frame;
    }
    // The reply field is placed by the reparent below. Fitting it here pulls
    // it back to the phone, or stretches a tall input view over the thread.
    if (DSViewIsCompatibilityInputView(view)) return frame;
    UIWindow *owning = [view isKindOfClass:UIWindow.class] ? (UIWindow *)view : view.window;
    if (owning && DSIsKeyboardWindow(owning)) {
        CGRect stage = DSStageBounds();
        if (CGRectGetHeight(frame) > 80.0 &&
            (CGRectGetMaxY(frame) > CGRectGetHeight(stage) + 12.0 ||
             CGRectGetHeight(frame) > CGRectGetHeight(stage) * 0.4)) {
            DSTraceInputOnce([NSString stringWithFormat:@"kbwin-%@", NSStringFromClass(object_getClass(view))],
                             [NSString stringWithFormat:@"app left %@ at %@. cause=it lives in %@ %@, and fitting it would lift the piece under the field into the card",
                              NSStringFromClass(object_getClass(view)),
                              NSStringFromCGRect(frame),
                              NSStringFromClass(object_getClass(owning)),
                              NSStringFromCGRect(owning.bounds)]);
        }
        return frame;
    }
    NSString *fitName = NSStringFromClass(object_getClass(view));
    if (DSNameIsUnderInputPiece(fitName)) {
        DSTraceInputOnce([NSString stringWithFormat:@"under-%@", fitName],
                         [NSString stringWithFormat:@"app left %@ at %@. cause=this is the piece under the field, and fitting its frame lifts it above the field",
                          fitName, NSStringFromCGRect(frame)]);
        return frame;
    }
    UIView *parent = view.superview;
    if (!parent) return frame;
    BOOL inWindow = [parent isKindOfClass:UIWindow.class];
    if (inWindow && DSIsKeyboardWindow((UIWindow *)parent)) return frame;
    // A transcript cell sits below the visible bounds on purpose.
    if ([parent isKindOfClass:UIScrollView.class]) return frame;
    CGRect stage = DSStageBounds();
    if (CGRectGetWidth(stage) < 80.0 || CGRectGetHeight(stage) < 80.0) return frame;
    // A card-sized frame at the top of the phone is the old fit. The
    // conversation belongs on the lower band, where the reply field already is.
    if (inWindow && ((UIWindow *)parent).rootViewController.view == view) {
        CGRect dropped = DSDroppedRectForRoot(view);
        if (CGRectGetHeight(dropped) > 80.0 &&
            (CGRectGetMinY(dropped) > 1.0 ||
             fabs(CGRectGetHeight(dropped) - CGRectGetHeight(frame)) > 1.0 ||
             fabs(CGRectGetMinY(dropped) - CGRectGetMinY(frame)) > 1.0)) {
            view.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
            view.clipsToBounds = YES;
            return dropped;
        }
    }
    if (CGRectGetHeight(frame) <= CGRectGetHeight(stage) + 12.0 &&
        CGRectGetWidth(frame) <= CGRectGetWidth(stage) + 12.0 &&
        CGRectGetMaxX(frame) <= CGRectGetWidth(inWindow ? stage : parent.bounds) + 12.0 &&
        CGRectGetMaxY(frame) <= CGRectGetHeight(inWindow ? stage : parent.bounds) + 12.0) {
        return frame;
    }
    CGRect device = [DSStageContext sharedContext].deviceBounds;
    BOOL phoneWide = DSFrameIsPhoneWide(frame, device, stage);
    BOOL phoneTall = DSFrameIsPhoneTall(frame, device, stage);
    if (!inWindow) {
        BOOL parentStillPhone = CGRectGetWidth(parent.bounds) > CGRectGetWidth(stage) + 24.0 ||
                                CGRectGetHeight(parent.bounds) > CGRectGetHeight(stage) + 24.0;
        if (parentStillPhone || CGRectGetWidth(parent.bounds) < 40.0 || CGRectGetHeight(parent.bounds) < 40.0) {
            return frame;
        }
    }
    if (inWindow && (phoneTall || phoneWide)) {
        view.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
        view.clipsToBounds = YES;
        UIView *root = ((UIWindow *)parent).rootViewController.view;
        CGRect dropped = DSDroppedRectForRoot(root ?: view);
        if (phoneTall && view != root && CGRectGetHeight(frame) > 96.0) {
            DSTraceInputOnce([NSString stringWithFormat:@"tall-%@", NSStringFromClass(object_getClass(view))],
                             [NSString stringWithFormat:@"app left tall %@ at %@. cause=stretching it to the card would cover the thread above the field",
                              NSStringFromClass(object_getClass(view)), NSStringFromCGRect(frame)]);
            return frame;
        }
        if (phoneTall && CGRectGetHeight(dropped) > 80.0) return dropped;
        if (phoneTall && DSDropQueryDepth > 0) return frame;
        if (phoneTall) return CGRectMake(0.0, 0.0, CGRectGetWidth(stage), CGRectGetHeight(stage));
        CGRect fitted = frame;
        fitted.size.width = CGRectGetWidth(dropped) > 80.0 ? CGRectGetWidth(dropped) : CGRectGetWidth(stage);
        fitted.origin.x = 0.0;
        CGFloat bandTop = CGRectGetHeight(dropped) > 80.0 ? CGRectGetMinY(dropped) : 0.0;
        CGFloat bandBottom = CGRectGetHeight(dropped) > 80.0 ? CGRectGetMaxY(dropped) : CGRectGetHeight(stage);
        if (CGRectGetMaxY(fitted) > bandBottom + 1.0 || CGRectGetMinY(fitted) < bandTop - 1.0) {
            CGFloat lifted = MAX(bandTop, bandBottom - CGRectGetHeight(fitted));
            if (lifted + 12.0 < CGRectGetMinY(frame) &&
                (!DSViewIsMessageEntryBar(view) || CGRectGetHeight(fitted) > 160.0)) {
                DSTraceInputOnce([NSString stringWithFormat:@"lift-%@", NSStringFromClass(object_getClass(view))],
                                 [NSString stringWithFormat:@"app left %@ at %@. cause=pinning its bottom to the card would move this %.0fpt piece from under the field to y=%.0f",
                                  NSStringFromClass(object_getClass(view)), NSStringFromCGRect(frame),
                                  CGRectGetHeight(fitted), lifted]);
                return frame;
            }
            fitted.origin.y = lifted;
        }
        return fitted;
    }
    // A full-width card is as wide as the phone, so the reply bar is not
    // "phone wide" — it is just sitting at the bottom of the phone. Pull that
    // bar up onto the card and let its own layout use the new width.
    BOOL hangs = !inWindow &&
                 (CGRectGetMaxY(frame) > CGRectGetHeight(parent.bounds) + 12.0 ||
                  CGRectGetWidth(frame) > CGRectGetWidth(parent.bounds) + 12.0);
    if (!phoneWide && !phoneTall && !hangs) return frame;
    CGRect fitted = frame;
    CGFloat parentW = CGRectGetWidth(parent.bounds);
    CGFloat parentH = CGRectGetHeight(parent.bounds);
    if (phoneWide || CGRectGetWidth(fitted) > parentW + 2.0) {
        fitted.size.width = parentW;
        fitted.origin.x = 0.0;
    }
    if (phoneTall) {
        if (CGRectGetHeight(frame) > 96.0 && CGRectGetMinY(frame) > 40.0) {
            DSTraceInputOnce([NSString stringWithFormat:@"cover-%@", NSStringFromClass(object_getClass(view))],
                             [NSString stringWithFormat:@"app left %@ at %@. cause=giving it the parent's full height would paint it over the field",
                              NSStringFromClass(object_getClass(view)), NSStringFromCGRect(frame)]);
            return frame;
        }
        fitted.size.height = parentH;
        fitted.origin.y = 0.0;
    } else if (CGRectGetMaxY(fitted) > parentH + 1.0) {
        CGFloat lifted = MAX(0.0, parentH - CGRectGetHeight(fitted));
        if (lifted + 12.0 < CGRectGetMinY(frame) &&
            (!DSViewIsMessageEntryBar(view) || CGRectGetHeight(fitted) > 160.0)) {
            DSTraceInputOnce([NSString stringWithFormat:@"hang-%@", NSStringFromClass(object_getClass(view))],
                             [NSString stringWithFormat:@"app left %@ at %@. cause=the piece under the field is %.0fpt, and pulling its bottom up to %.0f puts it above the field",
                              NSStringFromClass(object_getClass(view)), NSStringFromCGRect(frame),
                              CGRectGetHeight(fitted), lifted]);
            return frame;
        }
        fitted.origin.y = lifted;
    }
    if (fitted.origin.x < 0.0) fitted.origin.x = 0.0;
    if (fitted.origin.y < 0.0) fitted.origin.y = 0.0;
    return fitted;
}

static void DSReflowCollectionIfWidthChanged(UIView *view) {
    if (![view isKindOfClass:UICollectionView.class]) return;
    UICollectionView *collection = (UICollectionView *)view;
    CGSize size = collection.bounds.size;
    NSValue *previous = objc_getAssociatedObject(collection, @selector(bounds));
    if (previous && fabs(previous.CGSizeValue.width - size.width) < 1.0) return;
    objc_setAssociatedObject(collection, @selector(bounds), [NSValue valueWithCGSize:size], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!previous) return;
    [collection.collectionViewLayout invalidateLayout];
}

static void DSClampScreenSizedChildren(UIView *view, NSInteger depth) {
    if (!view || depth > 12 || DSClampingStage || !DSStaged()) return;
    CGRect stage = DSStageBounds();
    if (CGRectGetHeight(stage) < 80.0 || CGRectGetWidth(stage) < 80.0) return;
    CGRect device = [DSStageContext sharedContext].deviceBounds;
    BOOL parentCard = CGRectGetWidth(view.bounds) <= CGRectGetWidth(stage) + 24.0 &&
                      CGRectGetHeight(view.bounds) <= CGRectGetHeight(stage) + 24.0 &&
                      CGRectGetWidth(view.bounds) > 40.0 &&
                      CGRectGetHeight(view.bounds) > 40.0;
    for (UIView *subview in view.subviews) {
        CGRect frame = subview.frame;
        BOOL phoneWide = DSFrameIsPhoneWide(frame, device, stage);
        BOOL phoneTall = DSFrameIsPhoneTall(frame, device, stage);
        BOOL hanging = CGRectGetMaxY(frame) > CGRectGetHeight(view.bounds) + 12.0 ||
                       CGRectGetWidth(frame) > CGRectGetWidth(view.bounds) + 12.0;
        if (parentCard && (phoneWide || phoneTall || hanging) && ![view isKindOfClass:UIScrollView.class]) {
            CGRect fitted = frame;
            if (phoneTall) {
                fitted = CGRectMake(0.0, 0.0, CGRectGetWidth(view.bounds), CGRectGetHeight(view.bounds));
            } else {
                if (phoneWide || CGRectGetWidth(fitted) > CGRectGetWidth(view.bounds) + 2.0) {
                    fitted.size.width = CGRectGetWidth(view.bounds);
                    fitted.origin.x = 0.0;
                }
                if (CGRectGetMaxY(fitted) > CGRectGetHeight(view.bounds) + 1.0) {
                    fitted.origin.y = MAX(0.0, CGRectGetHeight(view.bounds) - CGRectGetHeight(fitted));
                }
            }
            if (!CGRectEqualToRect(fitted, frame)) {
                DSClampingStage = YES;
                subview.frame = fitted;
                DSClampingStage = NO;
                [subview setNeedsLayout];
            }
        }
        if ([subview isKindOfClass:UICollectionView.class] || [subview isKindOfClass:UITableView.class]) {
            DSReflowCollectionIfWidthChanged(subview);
            continue;
        }
        DSClampScreenSizedChildren(subview, depth + 1);
    }
}

// Shrinking the transcript keeps the same content offset, which reveals older
// messages and hides the ones that were on screen. Keep the bottom edge put.
static void DSKeepTranscriptBottom(UIView *view, NSInteger depth) {
    if (!view || depth > 12) return;
    if ([view isKindOfClass:UIScrollView.class]) {
        UIScrollView *scroll = (UIScrollView *)view;
        CGFloat nowH = CGRectGetHeight(scroll.bounds);
        if (nowH >= 80.0) {
            NSNumber *previous = objc_getAssociatedObject(scroll, @selector(contentOffset));
            CGFloat oldH = previous.doubleValue;
            objc_setAssociatedObject(scroll, @selector(contentOffset), @(nowH), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (oldH > 80.0 && nowH < oldH - 24.0) {
                UIEdgeInsets inset = scroll.adjustedContentInset;
                CGFloat oldVisible = oldH - inset.top - inset.bottom;
                CGFloat newVisible = nowH - inset.top - inset.bottom;
                if (newVisible > 40.0) {
                    CGFloat target = scroll.contentOffset.y + oldVisible - newVisible;
                    CGFloat minY = -inset.top;
                    CGFloat maxY = scroll.contentSize.height - newVisible;
                    if (maxY < minY) maxY = minY;
                    if (target < minY) target = minY;
                    if (target > maxY) target = maxY;
                    if (fabs(target - scroll.contentOffset.y) > 1.0) {
                        scroll.contentOffset = CGPointMake(scroll.contentOffset.x, target);
                    }
                }
            }
        }
    }
    if ([view isKindOfClass:UICollectionView.class] || [view isKindOfClass:UITableView.class]) return;
    for (UIView *subview in view.subviews) DSKeepTranscriptBottom(subview, depth + 1);
}

static BOOL DSPhoneLayoutFrozen = NO;
static BOOL DSPhoneScaleScheduled = NO;
static void DSPhoneApplyCardFrame(UIView *root);
static void DSPhoneScaleRootIntoCard(UIView *root);
static void DSPhoneScheduleScaleRootIntoCard(UIView *root);

%hook UIViewController

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    if (DSStaged()) return UIInterfaceOrientationMaskPortrait;
    return %orig;
}

- (BOOL)shouldAutorotate {
    if (DSStaged()) return NO;
    return %orig;
}

- (void)attemptRotationToDeviceOrientation {
    if (DSStaged()) return;
    %orig;
}

- (void)viewWillAppear:(BOOL)animated {
    NSString *name = NSStringFromClass(self.class);
    if (DSStaged() &&
        ([name rangeOfString:@"Chat"].location != NSNotFound ||
         [name rangeOfString:@"Transcript"].location != NSNotFound ||
         [name rangeOfString:@"Conversation"].location != NSNotFound ||
         [name rangeOfString:@"Message"].location != NSNotFound ||
         [name rangeOfString:@"CK"].location == 0)) {
        DSTraceFormat(@"app willAppear %@", name);
    }
    // The push lays the reply bar out. Sliding it now cancels the push.
    if ([name rangeOfString:@"CKChatController"].location != NSNotFound ||
        [name rangeOfString:@"CKTranscript"].location != NSNotFound ||
        [name rangeOfString:@"ConversationList"].location != NSNotFound) {
        DSReplyBarMayMove = NO;
    }
    if ([name rangeOfString:@"ConversationList"].location != NSNotFound ||
        [name rangeOfString:@"Inbox"].location != NSNotFound) {
        DSForgetReplyBarSpot();
    }
    // Back on the conversation list. Drop the keyboard hold before UIKit
    // parks the composer off screen, or the bar stays painted on the list.
    if (DSStaged() && DSMessagesDrawsOwnKeyboard() &&
        ([name rangeOfString:@"ConversationList"].location != NSNotFound ||
         [name rangeOfString:@"Inbox"].location != NSNotFound)) {
        DSMessagesChatOnScreen = NO;
        DSMessagesChatReadyAt = 0;
        DSMessagesHandoffToken++;
        DSReleaseMessagesKeyboardHost();
        DSTrace(@"app left the conversation");
    } else if (DSStaged() && DSMessagesDrawsOwnKeyboard() &&
               [name rangeOfString:@"ChatController"].location != NSNotFound) {
        // A new conversation is another scene update. The keyboard is created
        // only after that update has had time to finish. An existing SpringBoard
        // keyboard is left alone.
        DSMessagesChatOnScreen = YES;
        if (!DSMessagesKeyboardHosted && !DSMessagesHandoffInFlight) {
            DSMessagesHandoffCooldownUntil = 0;
            DSMessagesChatReadyAt = CFAbsoluteTimeGetCurrent() + 0.45;
            DSScheduleMessagesKeyboardHandoff(nil);
        }
    }
    %orig;
}

- (void)viewDidLayoutSubviews {
    %orig;
    if (!DSStaged()) return;
    static NSInteger refitDepth = 0;
    if (refitDepth > 0) return;
    UIWindow *window = self.view.window;
    if (!window) return;
    // Walking the transcript from here, or calling layoutIfNeeded, runs while
    // the conversation is already laying out. The push never finishes, and
    // SpringBoard resprings.
    if (window.rootViewController != self) return;
    // After the root has laid out at full size. Doing this here keeps the
    // 5% width stretch from being cleared by that layout pass.
    // Schedule off this layout turn: mutating bounds+transform mid-layout is a
    // SIGTRAP (not catchable by @try).
    if (DSIsMobilePhone()) DSPhoneScheduleScaleRootIntoCard(self.view);
    refitDepth += 1;
    DSHideHomeChromeInView(window, 0);
    refitDepth -= 1;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!DSStaged()) return;
    NSString *name = NSStringFromClass(object_getClass(self));
    BOOL chat = [name rangeOfString:@"CKChatController"].location != NSNotFound ||
                [name rangeOfString:@"CKTranscript"].location != NSNotFound;
    if (!chat) return;
    UIView *entry = nil;
    if ([self respondsToSelector:@selector(entryView)]) {
        id candidate = ((id (*)(id, SEL))objc_msgSend)(self, @selector(entryView));
        if ([candidate isKindOfClass:UIView.class]) entry = candidate;
    }
    if (!entry) entry = DSFindMessageEntry(self.view, 0);
    DSScheduleReplyBarPull(entry);
}

%end

#pragma mark - Keyboard

// The keys are drawn in UITextEffectsWindow. That window is not in
// UIApplication.windows, and the keyboard views do not go through UIView's
// setHidden:, which is why a one-shot hide never stuck. While this process is
// staged, those views are pulled out of the card on every pass UIKit uses to
// put them back, and again before the run loop sleeps.

static BOOL DSBanishing = NO;
static NSUInteger DSBanishHits = 0;
static BOOL DSBanishFoundChrome = NO;

static BOOL DSNameIsKeyboardLayerHost(NSString *name) {
    if (name.length == 0) return NO;
    return [name rangeOfString:@"KeyboardLayerHost"].location != NSNotFound;
}

static BOOL DSNameIsKeyboardRemoteControl(NSString *name) {
    if (name.length == 0) return NO;
    return [name rangeOfString:@"KeyboardRemoteControl"].location != NSNotFound;
}

static BOOL DSNameIsLocalKeyboard(NSString *name) {
    if (name.length == 0) return NO;
    if (DSNameIsKeyboardRemoteControl(name)) return NO;
    // UIRemoteKeyboardWindow is the keyboard window, not a key. Holding its
    // frame is what freezes the keyboard and the reply overlay together.
    if ([name rangeOfString:@"Window"].location != NSNotFound) return NO;
    if (DSNameIsKeyboardLayerHost(name)) return YES;
    if ([name hasPrefix:@"UIKeyboard"]) return YES;
    // UIInputSetHostView is the long parent of the reply field. Hiding it
    // left that field out of the card. The key views inside it still match
    // UIKeyboard / UIKB above.
    if ([name hasPrefix:@"UIKB"]) return YES;
    if ([name hasPrefix:@"UIRemoteKeyboard"]) return YES;
    if ([name hasPrefix:@"TUIKeyboard"]) return YES;
    if ([name hasPrefix:@"UICandidate"]) return YES;
    if ([name hasPrefix:@"UIPrediction"]) return YES;
    return NO;
}

static BOOL DSWindowIsKeyboardChrome(UIWindow *window) {
    if (!window) return NO;
    if (DSIsKeyboardWindow(window)) return YES;
    NSString *name = NSStringFromClass(object_getClass(window));
    if ([name rangeOfString:@"Keyboard"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"TextEffects"].location != NSNotFound) return YES;
    return NO;
}

static void DSSuppressKeyboardView(UIView *view) {
    if (DSMessagesKeepsOwnKeys()) return;
    DSBanishHits++;
    if (DSBanishHits <= 4) {
        DSTraceFormat(@"app hid %@. cause=local key chrome after SpringBoard's keyboard is up. parent=%@",
                      DSViewBrief(view),
                      view.superview ? NSStringFromClass(object_getClass(view.superview)) : @"none");
    }
    [view.layer removeAllAnimations];
    view.hidden = YES;
    view.alpha = 0.0;
    view.userInteractionEnabled = NO;
    view.layer.hidden = YES;
    view.layer.opacity = 0.0;
}

static BOOL DSNameIsMessageChrome(NSString *name) {
    if (name.length == 0) return NO;
    if ([name rangeOfString:@"MessageEntry"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"CompatibilityInput"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"VisualEffect"].location != NSNotFound) return YES;
    return NO;
}

// Direct children of the input host that are the reply field. Messages uses a
// CK prefix, WhatsApp a WA prefix. Messenger and Signal use the longer names.
static BOOL DSNameIsStageComposer(NSString *name) {
    if (name.length < 2) return NO;
    if ([name hasPrefix:@"CK"] || [name hasPrefix:@"WA"]) return YES;
    if ([name rangeOfString:@"MessageEntry"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"CompatibilityInput"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"Composer"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"InputToolbar"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"MessageInput"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"InputBar"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"InputAccessory"].location != NSNotFound) return YES;
    return NO;
}

static void DSBanishKeyboardInView(UIView *view, CGRect windowBounds, BOOL inKeyboardWindow, NSInteger depth) {
    if (depth > (inKeyboardWindow ? 8 : 3) || ![view isKindOfClass:UIView.class]) return;
    NSString *name = NSStringFromClass(object_getClass(view));
    if (DSNameIsMessageChrome(name)) {
        for (UIView *subview in view.subviews) {
            DSBanishKeyboardInView(subview, windowBounds, inKeyboardWindow, depth + 1);
        }
        return;
    }
    CGRect frame = view.frame;
    // A keyboard sitting on the bottom edge of this window, including one that
    // fills most of a short stage. The caret is too small to match.
    BOOL bottomSlab = inKeyboardWindow &&
                      CGRectGetHeight(frame) >= 100.0 &&
                      CGRectGetWidth(frame) >= CGRectGetWidth(windowBounds) * 0.5 &&
                      CGRectGetMaxY(frame) >= CGRectGetHeight(windowBounds) - 8.0 &&
                      CGRectGetMinY(frame) > 40.0 &&
                      CGRectGetMinY(frame) < 8000.0;
    if (DSNameIsLocalKeyboard(name) || bottomSlab) {
        DSSuppressKeyboardView(view);
        return;
    }
    for (UIView *subview in view.subviews) {
        DSBanishKeyboardInView(subview, windowBounds, inKeyboardWindow, depth + 1);
    }
}

static void DSBanishKeyboardLayers(CALayer *layer, CGRect windowBounds) {
    if (!layer) return;
    NSString *name = NSStringFromClass(object_getClass(layer));
    id delegate = layer.delegate;
    NSString *delegateName = nil;
    if ([delegate isKindOfClass:UIView.class]) {
        delegateName = NSStringFromClass(object_getClass((UIView *)delegate));
    }
    CGRect frame = layer.frame;
    BOOL bottomSlab = CGRectGetHeight(frame) >= 100.0 &&
                      CGRectGetWidth(frame) >= CGRectGetWidth(windowBounds) * 0.5 &&
                      CGRectGetMaxY(frame) >= CGRectGetHeight(windowBounds) - 8.0 &&
                      CGRectGetMinY(frame) > 40.0 &&
                      CGRectGetMinY(frame) < 8000.0;
    if (DSNameIsLocalKeyboard(name) || DSNameIsLocalKeyboard(delegateName) || bottomSlab) {
        [layer removeAllAnimations];
        layer.hidden = YES;
        layer.opacity = 0.0;
        return;
    }
    for (CALayer *sublayer in layer.sublayers) {
        DSBanishKeyboardLayers(sublayer, windowBounds);
    }
}

static void DSVisitLiveWindows(void (^visitor)(UIWindow *window)) {
    NSMutableSet *seen = [NSMutableSet set];
    void (^visit)(UIWindow *) = ^(UIWindow *window) {
        if (![window isKindOfClass:UIWindow.class] || [seen containsObject:window]) return;
        [seen addObject:window];
        visitor(window);
    };

    for (UIWindow *window in UIApplication.sharedApplication.windows) visit(window);
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) visit(window);
        }
    }

    Class effects = objc_getClass("UITextEffectsWindow");
    for (NSString *selectorName in @[
        @"sharedTextEffectsWindow",
        @"sharedTextEffectsWindowForWindowScene:",
        @"_sharedTextEffectsWindowAboveStatusBar"
    ]) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![effects respondsToSelector:selector]) continue;
        @try {
            if ([selectorName hasSuffix:@":"]) {
                for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                    visit(((id (*)(id, SEL, id))objc_msgSend)(effects, selector, scene));
                }
            } else {
                visit(((id (*)(id, SEL))objc_msgSend)(effects, selector));
            }
        } @catch (NSException *exception) {
        }
    }

    Class remote = objc_getClass("UIRemoteKeyboardWindow");
    SEL create = @selector(remoteKeyboardWindowForScreen:create:);
    if ([remote respondsToSelector:create]) {
        @try {
            visit(((id (*)(id, SEL, id, BOOL))objc_msgSend)(remote, create, UIScreen.mainScreen, NO));
        } @catch (NSException *exception) {
        }
    }
}

static NSString *DSChainBrief(UIView *view) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    UIView *cursor = view;
    for (NSInteger i = 0; cursor && i < 6; i++) {
        [parts addObject:DSViewBrief(cursor)];
        if ([cursor isKindOfClass:UIWindow.class]) break;
        cursor = cursor.superview;
    }
    return parts.count ? [parts componentsJoinedByString:@" < "] : @"none";
}

static UIView *DSEntryForResponder(UIResponder *responder) {
    UIView *view = [responder isKindOfClass:UIView.class] ? (UIView *)responder : nil;
    UIView *cursor = view;
    for (NSInteger i = 0; cursor && i < 10; i++) {
        if ([NSStringFromClass(object_getClass(cursor)) rangeOfString:@"MessageEntry"].location != NSNotFound) {
            return cursor;
        }
        cursor = cursor.superview;
    }
    return view;
}

static NSString *DSKeyboardWindowBrief(void) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    DSVisitLiveWindows(^(UIWindow *window) {
        if (parts.count >= 3 || !DSWindowIsKeyboardChrome(window)) return;
        [parts addObject:[NSString stringWithFormat:@"%@ f=%@ hid=%d a=%.2f lvl=%.0f",
                          NSStringFromClass(object_getClass(window)),
                          NSStringFromCGRect(window.frame),
                          window.hidden,
                          window.alpha,
                          window.windowLevel]];
    });
    return parts.count ? [parts componentsJoinedByString:@" || "] : @"no keyboard window in this app";
}

static void DSTraceInputLayout(NSString *cause, UIView *view) {
    (void)cause;
    (void)view;
}

static void DSReportKeyboardDebug(NSString *windowNames) {
    (void)windowNames;
    return;
    static int token = NOTIFY_TOKEN_INVALID;
    static uint64_t lastState = 0;
    static NSString *lastNames = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_check(kDSKeyboardDebugNotification, &token);
    });
    NSString *identifier = NSBundle.mainBundle.bundleIdentifier ?: @"";
    BOOL staged = DSStaged();
    uint64_t state = DSIdentifierHash(identifier);
    if (staged) state |= kDSStageStateActiveBit;
    if (DSBanishFoundChrome) state |= (1ULL << 33);
    state |= (uint64_t)MIN(DSBanishHits, (NSUInteger)255) << 40;
    BOOL changed = state != lastState || (windowNames.length > 0 && ![windowNames isEqualToString:lastNames]);
    if (!changed) return;
    lastState = state;
    lastNames = [windowNames copy];
    if (token != NOTIFY_TOKEN_INVALID) {
        notify_set_state(token, state);
        notify_post(kDSKeyboardDebugNotification);
    }
    // A separate file so this cannot overwrite the stage list SpringBoard publishes.
    NSString *summary = [NSString stringWithFormat:@"%@ staged=%d chrome=%d hid=%lu windows=%@",
                         identifier, staged, DSBanishFoundChrome, (unsigned long)DSBanishHits,
                         windowNames ?: @"?"];
    [summary writeToFile:@"/var/mobile/Library/Preferences/com.recreated.dynamicstage.keyboard.txt"
              atomically:YES
                encoding:NSUTF8StringEncoding
                   error:nil];
}

static void DSKillHostedKeyboardView(id view) {
    if (DSMessagesKeepsOwnKeys()) return;
    if (![view isKindOfClass:UIView.class] || !DSStaged()) return;
    UIView *host = (UIView *)view;
    DSBanishFoundChrome = YES;
    [host.layer removeAllAnimations];
    host.hidden = YES;
    host.alpha = 0.0;
    host.userInteractionEnabled = NO;
    host.layer.hidden = YES;
    host.layer.opacity = 0.0f;
    for (UIView *sub in host.subviews) {
        DSKillHostedKeyboardView(sub);
    }
}

static void DSStripKeyboardLayerHostView(UIView *view) {
    if (DSMessagesKeepsOwnKeys()) return;
    if (!DSStaged() || !view) return;
    if (!DSNameIsKeyboardLayerHost(NSStringFromClass(object_getClass(view)))) return;
    [view removeFromSuperview];
    DSKillHostedKeyboardView(view);
}

static CGRect DSStageContainerFrameOnScreen(void) {
    __block UIWindow *appWindow = nil;
    DSVisitLiveWindows(^(UIWindow *window) {
        if (appWindow) return;
        if (DSWindowIsKeyboardChrome(window)) return;
        appWindow = window;
    });
    if (appWindow) {
        return [appWindow convertRect:appWindow.bounds toView:nil];
    }
    CGRect stage = DSStageBounds();
    return CGRectMake(0.0, 0.0, stage.size.width, stage.size.height);
}

static void DSLayoutKeyboardRemoteControlView(UIView *view) {
    if (!DSStaged() || !view || !view.superview) return;
    if (!DSNameIsKeyboardRemoteControl(NSStringFromClass(object_getClass(view)))) return;

    // Touch routing only. A full-card visible cover looked like a flickering ghost keyboard.
    CGRect bounds = view.superview.bounds;
    CGFloat band = MIN(340.0, CGRectGetHeight(bounds));
    CGRect local = CGRectMake(0.0, CGRectGetHeight(bounds) - band, CGRectGetWidth(bounds), band);

    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    view.hidden = NO;
    view.opaque = NO;
    view.backgroundColor = UIColor.clearColor;
    view.alpha = 0.02;
    view.userInteractionEnabled = YES;
    if (!CGRectEqualToRect(view.frame, local)) {
        view.frame = local;
    }
}

static void DSLayoutKeyboardRemoteControlsInTree(UIView *root, NSInteger depth) {
    if (!root || depth > 24) return;
    if (DSNameIsKeyboardRemoteControl(NSStringFromClass(object_getClass(root)))) {
        DSLayoutKeyboardRemoteControlView(root);
        return;
    }
    for (UIView *subview in root.subviews) {
        DSLayoutKeyboardRemoteControlsInTree(subview, depth + 1);
    }
}

static void DSStripKeyboardLayerHostsInTree(UIView *root, NSInteger depth) {
    if (!root || depth > 28) return;
    for (UIView *subview in [root.subviews copy]) {
        if (DSNameIsKeyboardLayerHost(NSStringFromClass(object_getClass(subview)))) {
            DSStripKeyboardLayerHostView(subview);
            continue;
        }
        DSStripKeyboardLayerHostsInTree(subview, depth + 1);
    }
}

static BOOL DSFittingEffectsWindow = NO;
static NSInteger DSCompactDepth = 0;

// The three long views in the debugger: the text-effects window, the input
// container, and the input host. The editing overlay is the same kind of
// full-phone view. Anything else in that window is the reply field sitting
// at the bottom of them.
static BOOL DSViewIsStageShell(UIView *view) {
    if (![view isKindOfClass:UIView.class]) return NO;
    if ([view isKindOfClass:UIWindow.class] && DSIsRemoteKeyboardWindow((UIWindow *)view)) return NO;
    UIWindow *window = [view isKindOfClass:UIWindow.class] ? (UIWindow *)view : view.window;
    if (window && DSIsRemoteKeyboardWindow(window)) return NO;
    NSString *name = NSStringFromClass(object_getClass(view));
    if ([name rangeOfString:@"TextEffects"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"InputSetContainer"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"InputSetHost"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"EditingOverlay"].location != NSNotFound) return YES;
    return NO;
}

static CGRect DSStageShellFrame(UIView *view) {
    CGRect stage = DSStageBounds();
    if (CGRectGetWidth(stage) < 80.0 || CGRectGetHeight(stage) < 80.0) return CGRectZero;
    CGRect target = CGRectMake(0.0, 0.0, CGRectGetWidth(stage), CGRectGetHeight(stage));
    if ([view isKindOfClass:UIWindow.class]) return target;
    UIView *parent = view.superview;
    if (!parent) return target;
    CGFloat parentW = CGRectGetWidth(parent.bounds);
    CGFloat parentH = CGRectGetHeight(parent.bounds);
    if (parentW > 40.0 && parentH > 40.0 &&
        parentW <= CGRectGetWidth(stage) + 24.0 &&
        parentH <= CGRectGetHeight(stage) + 24.0) {
        return parent.bounds;
    }
    return target;
}

static void DSClipView(UIView *view) {
    view.clipsToBounds = YES;
    view.layer.masksToBounds = YES;
}

// A bar laid out at the bottom of the phone, inside a parent we just clipped
// to the card. Keep its height and sit it on the bottom of that parent.
static CGRect DSPinFrameInsideStage(UIView *view, CGRect frame) {
    UIView *parent = view.superview;
    if (!parent || DSViewIsStageShell(view)) return frame;
    UIWindow *window = [parent isKindOfClass:UIWindow.class] ? (UIWindow *)parent : parent.window;
    if (!window || DSIsRemoteKeyboardWindow(window) || !DSIsKeyboardWindow(window)) return frame;
    NSString *name = NSStringFromClass(object_getClass(view));
    if (DSNameIsLocalKeyboard(name) || DSNameIsKeyboardRemoteControl(name)) return frame;
    CGRect stage = DSStageBounds();
    CGFloat limitW = CGRectGetWidth(stage);
    CGFloat limitH = CGRectGetHeight(stage);
    if (limitW < 80.0 || limitH < 80.0) return frame;
    CGFloat parentW = CGRectGetWidth(parent.bounds);
    CGFloat parentH = CGRectGetHeight(parent.bounds);
    if (parentW > 40.0 && parentW <= limitW + 24.0) limitW = parentW;
    if (parentH > 40.0 && parentH <= limitH + 24.0) limitH = parentH;
    CGFloat width = CGRectGetWidth(frame);
    CGFloat height = CGRectGetHeight(frame);
    BOOL taller = height > limitH + 12.0;
    BOOL hangs = CGRectGetMaxY(frame) > limitH + 2.0 || CGRectGetMinY(frame) >= limitH - 1.0;
    BOOL wider = width > limitW + 12.0;
    if (!taller && !hangs && !wider) return frame;
    if (taller && height > limitH * 0.55) {
        DSClipView(view);
        return CGRectMake(0.0, 0.0, limitW, limitH);
    }
    CGFloat useH = height > 1.0 ? MIN(height, limitH) : MIN(52.0, limitH);
    CGFloat useW = (wider || width > limitW * 0.5) ? limitW : width;
    return CGRectMake(0.0, limitH - useH, useW, useH);
}

static CGRect DSFrameForStagedView(UIView *view, CGRect frame) {
    if (!DSStaged() || DSClampingStage || !view) return frame;
    // The text-effects window, input container, and input host ignore a forced
    // frame. Their contents are slid up instead, so leave the frame UIKit set.
    UIWindow *window = [view isKindOfClass:UIWindow.class] ? (UIWindow *)view : view.window;
    if (DSViewIsStageShell(view)) return frame;
    if (window && DSIsKeyboardWindow(window) && !DSIsRemoteKeyboardWindow(window)) return frame;
    return DSPinFrameInsideStage(view, frame);
}

// How much of the phone-height input window is actually on the stage. The
// published card is used when it is shorter than that window. Otherwise the
// stage is one half of the phone, which is the part that stays on screen.
static CGFloat DSVisibleCardHeight(UIWindow *effectsWindow) {
    CGFloat windowH = CGRectGetHeight(effectsWindow.bounds);
    CGRect stage = DSStageBounds();
    CGRect device = [DSStageContext sharedContext].deviceBounds;
    CGFloat stageH = CGRectGetHeight(stage);
    BOOL stageIsPhone = CGRectGetHeight(device) > 80.0 &&
                        fabs(stageH - CGRectGetHeight(device)) < 12.0 &&
                        fabs(CGRectGetWidth(stage) - CGRectGetWidth(device)) < 12.0;
    if (!stageIsPhone && stageH > 80.0 && stageH + 24.0 < windowH) return stageH;
    __block CGFloat rootH = 0;
    DSVisitLiveWindows(^(UIWindow *window) {
        if (window == effectsWindow || DSWindowIsKeyboardChrome(window)) return;
        UIView *root = window.rootViewController.view ?: window.subviews.firstObject;
        CGFloat height = CGRectGetHeight(root.bounds);
        if (height > 80.0 && height + 24.0 < windowH && height > rootH) rootH = height;
    });
    if (rootH > 80.0) return rootH;
    if (stageIsPhone && windowH > 160.0) return floor(windowH * 0.5);
    if (stageH > 80.0 && stageH + 24.0 < windowH) return stageH;
    return stageH > 80.0 ? stageH : windowH;
}

static void DSLiftViewBottomTo(UIView *view, CGFloat cardH) {
    CGFloat height = CGRectGetHeight(view.bounds);
    if (height < 1.0) return;
    CGFloat bottom = view.center.y + height * 0.5;
    CGFloat ty = cardH - bottom;
    if (ty > -0.5) {
        if (!CGAffineTransformIsIdentity(view.transform)) view.transform = CGAffineTransformIdentity;
        return;
    }
    if (fabs(view.transform.ty - ty) < 0.5 && fabs(view.transform.tx) < 0.5) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    view.transform = CGAffineTransformMakeTranslation(0.0, ty);
    [CATransaction commit];
}

// The three long views stay the height of the phone. Slide each one up so the
// reply field at its bottom lands on the bottom of the stage. A view inside
// one that already moved is left where that parent put it.
static void DSLiftEffectsNode(UIView *view, CGFloat cardH, BOOL ancestorLifted, NSInteger depth) {
    if (!view || depth > 18) return;
    NSString *name = NSStringFromClass(object_getClass(view));
    if (depth > 0 && DSNameIsKeyboardRemoteControl(name)) {
        DSLayoutKeyboardRemoteControlView(view);
        return;
    }
    if (depth > 0 && DSNameIsLocalKeyboard(name)) {
        DSSuppressKeyboardView(view);
        return;
    }
    // The reply field is shifted onto the card by its own transform. Clearing
    // that transform puts the field back under the card.
    if (depth > 0 && DSNameIsStageComposer(name)) return;
    BOOL lifted = ancestorLifted;
    if (!ancestorLifted && depth > 0 && ![view isKindOfClass:UIWindow.class]) {
        CGFloat height = CGRectGetHeight(view.bounds);
        CGFloat bottom = view.center.y + height * 0.5;
        BOOL hangs = height > 1.0 && bottom > cardH + 2.0;
        BOOL shell = DSViewIsStageShell(view);
        BOOL chrome = DSNameIsMessageChrome(name);
        if (hangs && (shell || chrome)) {
            // These stay at the bottom of the phone. A translation here is what
            // kept trying to drag the reply field up into the card.
            if (!CGAffineTransformIsIdentity(view.transform)) view.transform = CGAffineTransformIdentity;
            lifted = YES;
        } else if (!hangs && !CGAffineTransformIsIdentity(view.transform)) {
            view.transform = CGAffineTransformIdentity;
        }
    } else if (ancestorLifted && depth > 0 && !CGAffineTransformIsIdentity(view.transform)) {
        view.transform = CGAffineTransformIdentity;
    }
    for (UIView *subview in view.subviews) DSLiftEffectsNode(subview, cardH, lifted, depth + 1);
}

static void DSCompactEffectsNode(UIView *view, NSInteger depth) {
    if (!view || depth > 16 || !DSStaged()) return;
    NSString *name = NSStringFromClass(object_getClass(view));
    if (depth > 0 && DSNameIsKeyboardRemoteControl(name)) {
        DSLayoutKeyboardRemoteControlView(view);
        return;
    }
    if (depth > 0 && DSNameIsLocalKeyboard(name)) {
        DSSuppressKeyboardView(view);
        return;
    }
    if (DSViewIsStageShell(view)) {
        CGRect target = DSStageShellFrame(view);
        DSClipView(view);
        if (CGRectGetWidth(target) > 40.0 && !CGRectEqualToRect(view.frame, target)) {
            DSClampingStage = YES;
            view.transform = CGAffineTransformIdentity;
            view.frame = target;
            DSClampingStage = NO;
        }
    } else if (depth > 0) {
        CGRect pinned = DSPinFrameInsideStage(view, view.frame);
        if (!CGRectEqualToRect(pinned, view.frame)) {
            DSClampingStage = YES;
            view.frame = pinned;
            DSClampingStage = NO;
        }
        if ([name rangeOfString:@"MessageEntry"].location != NSNotFound) DSPullMessageBarUp(view);
    }
    for (UIView *subview in view.subviews) DSCompactEffectsNode(subview, depth + 1);
}

// The reply field under the three shells is often a plain UIView plus the
// blur layers. Those are not shells, so shortening the shells left them
// hanging out past the bottom. A view that holds that chrome and sticks out
// of its parent is sat on the parent's bottom.
static BOOL DSViewHoldsReplyChrome(UIView *view, NSInteger depth) {
    if (!view || depth > 8) return NO;
    if ([view isKindOfClass:UIScrollView.class]) return NO;
    NSString *name = NSStringFromClass(object_getClass(view));
    if (DSNameIsMessageChrome(name)) return YES;
    if ([name rangeOfString:@"Backdrop"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"EffectContent"].location != NSNotFound) return YES;
    for (UIView *subview in view.subviews) {
        if (DSViewHoldsReplyChrome(subview, depth + 1)) return YES;
    }
    return NO;
}

static BOOL DSShouldSeatInShell(UIView *view) {
    if (![view isKindOfClass:UIView.class] || DSViewIsStageShell(view)) return NO;
    if ([view isKindOfClass:UIScrollView.class]) return NO;
    NSString *name = NSStringFromClass(object_getClass(view));
    if (DSNameIsLocalKeyboard(name) || DSNameIsKeyboardRemoteControl(name)) return NO;
    if (DSNameIsKeyboardLayerHost(name)) return NO;
    return DSViewHoldsReplyChrome(view, 0);
}

static UIView *DSNearestShell(UIView *view) {
    UIView *cursor = view.superview;
    for (NSInteger depth = 0; cursor && depth < 12; depth++) {
        if (DSViewIsStageShell(cursor)) return cursor;
        cursor = cursor.superview;
    }
    return view.superview;
}

static void DSSeatReplyOnParentBottom(UIView *view) {
    UIView *parent = view.superview;
    if (!parent || DSInputReparentDepth > 0) return;
    UIView *shell = DSNearestShell(view);
    if (!shell) return;
    CGFloat parentH = CGRectGetHeight(parent.bounds);
    CGFloat parentW = CGRectGetWidth(parent.bounds);
    CGFloat shellH = CGRectGetHeight(shell.bounds);
    if (parentH < 20.0 || parentW < 40.0 || shellH < 40.0) return;
    CGFloat height = CGRectGetHeight(view.bounds);
    if (height < 1.0) height = CGRectGetHeight(view.frame);
    if (height < 20.0) return;

    // Bottom of the innermost shell, expressed in this view's parent. That is
    // the bottom of the three views that already fit the card.
    CGPoint shellBottom = [shell convertPoint:CGPointMake(0.0, shellH) toView:parent];
    CGFloat targetBottom = shellBottom.y;
    if (parent != shell) targetBottom = MIN(targetBottom, parentH);
    CGFloat maxY = CGRectGetMaxY(view.frame);
    if (maxY <= targetBottom + 1.5 && CGRectGetMinY(view.frame) < targetBottom - 1.0) return;

    CGRect frame = view.frame;
    frame.origin.y = targetBottom - height;
    if (CGRectGetWidth(frame) > parentW + 2.0) {
        frame.origin.x = 0.0;
        frame.size.width = parentW;
    }
    BOOL outer = DSInputReparentDepth == 0;
    if (outer) DSInputReparentDepth += 1;
    view.transform = CGAffineTransformIdentity;
    DSClampingStage = YES;
    view.frame = frame;
    DSClampingStage = NO;
    shell.clipsToBounds = YES;
    if (CGRectGetMaxY(view.frame) > targetBottom + 2.0) DSLiftViewBottomTo(view, targetBottom);
    if (outer) DSInputReparentDepth -= 1;
}

static void DSSeatReplyTree(UIView *view, NSInteger depth) {
    if (!view || depth > 18) return;
    NSString *name = NSStringFromClass(object_getClass(view));
    if (depth > 0 && (DSNameIsLocalKeyboard(name) || DSNameIsKeyboardRemoteControl(name))) return;
    if (depth > 0 && DSShouldSeatInShell(view)) DSSeatReplyOnParentBottom(view);
    for (UIView *subview in [view.subviews copy]) DSSeatReplyTree(subview, depth + 1);
}

static NSInteger DSShellPinDepth = 0;

static BOOL DSConstraintPinsShellToParent(NSLayoutConstraint *constraint, UIView *shell) {
    if (![constraint isKindOfClass:NSLayoutConstraint.class] || !shell) return NO;
    UIView *parent = shell.superview;
    id first = constraint.firstItem;
    id second = constraint.secondItem;
    if (first == shell && second == nil) {
        return constraint.firstAttribute == NSLayoutAttributeWidth ||
               constraint.firstAttribute == NSLayoutAttributeHeight;
    }
    if (parent && ((first == shell && second == parent) || (second == shell && first == parent))) return YES;
    NSString *identifier = constraint.identifier;
    if (identifier.length > 0 &&
        [identifier rangeOfString:@"UIInputWindowController"].location != NSNotFound &&
        (first == shell || second == shell)) {
        return YES;
    }
    return NO;
}

// UIInputSetContainerView and UIInputSetHostView are stretched to the phone by
// constraints owned by UITextEffectsWindow. Setting their frame is undone on the
// next layout pass. Drop those parent pins and give the shell the card's size.
// The reply field stays constrained to the host, so it lands on the card bottom.
static void DSFitOneInputShell(UIView *shell, CGRect card) {
    if (![shell isKindOfClass:UIView.class] || [shell isKindOfClass:UIWindow.class]) return;
    NSMutableArray<NSLayoutConstraint *> *pins = [NSMutableArray array];
    @try {
        for (NSLayoutConstraint *constraint in shell.constraints) {
            if (DSConstraintPinsShellToParent(constraint, shell)) [pins addObject:constraint];
        }
        if (shell.superview) {
            for (NSLayoutConstraint *constraint in shell.superview.constraints) {
                if (DSConstraintPinsShellToParent(constraint, shell)) [pins addObject:constraint];
            }
        }
        if (pins.count) [NSLayoutConstraint deactivateConstraints:pins];
    } @catch (NSException *exception) {
    }
    shell.translatesAutoresizingMaskIntoConstraints = YES;
    shell.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
    UIView *parent = shell.superview;
    CGRect target = CGRectMake(0.0, 0.0, CGRectGetWidth(card), CGRectGetHeight(card));
    if (parent && ![parent isKindOfClass:UIWindow.class]) {
        CGFloat parentW = CGRectGetWidth(parent.bounds);
        CGFloat parentH = CGRectGetHeight(parent.bounds);
        if (parentW > 40.0 && parentH > 40.0 &&
            parentW <= CGRectGetWidth(card) + 24.0 &&
            parentH <= CGRectGetHeight(card) + 24.0) {
            target = parent.bounds;
        }
    }
    shell.clipsToBounds = YES;
    if (!CGAffineTransformIsIdentity(shell.transform)) shell.transform = CGAffineTransformIdentity;
    if (!CGRectEqualToRect(shell.frame, target)) {
        DSClampingStage = YES;
        shell.frame = target;
        DSClampingStage = NO;
    }
}

static void DSPinShellTree(UIView *view, CGRect card, NSInteger depth) {
    if (!view || depth > 8) return;
    for (UIView *subview in [view.subviews copy]) {
        if (DSViewIsStageShell(subview) && ![subview isKindOfClass:UIWindow.class]) {
            BOOL tall = CGRectGetHeight(subview.bounds) > CGRectGetHeight(card) + 24.0 ||
                        CGRectGetMaxY(subview.frame) > CGRectGetHeight(card) + 24.0;
            BOOL wide = CGRectGetWidth(subview.bounds) > CGRectGetWidth(card) + 24.0;
            if (tall || wide) DSFitOneInputShell(subview, card);
        }
        DSPinShellTree(subview, card, depth + 1);
    }
}

static void DSPinInputShellsToStage(void) {
    // Pinning these shells to the card resizes the keyboard scene.
    return;
    if (!DSStaged() || DSShellPinDepth > 0) return;
    DSTrace(@"app pin input shells");
    CGRect card = DSStageBounds();
    if (CGRectGetWidth(card) < 80.0 || CGRectGetHeight(card) < 80.0) return;
    DSShellPinDepth += 1;
    DSVisitLiveWindows(^(UIWindow *window) {
        if (DSIsRemoteKeyboardWindow(window) || !DSIsKeyboardWindow(window)) return;
        NSString *name = NSStringFromClass(object_getClass(window));
        if ([name rangeOfString:@"TextEffects"].location == NSNotFound) return;
        DSPinShellTree(window, card, 0);
    });
    DSShellPinDepth -= 1;
}

// The input host stays the height of the phone. Its reply field is a direct
// child (CK in Messages, WA in WhatsApp). Slide that child so its bottom edge
// lands on the bottom of the card. The host's constraints put the frame back
// on the next layout, so the slide is a transform and it is applied again
// after every layout.
static NSInteger DSComposerShiftDepth = 0;
static CFAbsoluteTime DSComposerShiftQuietUntil = 0;

static void DSApplyComposerShift(UIView *view, CGFloat targetBottom) {
    CGFloat height = CGRectGetHeight(view.bounds);
    if (height < 18.0 || height > 240.0 || targetBottom < height + 8.0) return;
    // frame includes the transform already applied. Measuring that frame and
    // writing the difference back flips the field between two positions, and
    // each flip posts a keyboard show. Subtract the current slide first.
    CGFloat currentTy = view.transform.ty;
    CGFloat ty = targetBottom - (CGRectGetMaxY(view.frame) - currentTy);
    if (ty > 4000.0 || ty < -4000.0) return;
    if (fabs(currentTy - ty) < 0.5 && fabs(view.transform.tx) < 0.5) return;
    // A downward slide is the keyboard inset. On the card it walks the reply
    // bar off the bottom. Messages keeps its own keys, so the bar stays put.
    if (DSMessagesDrawsOwnKeyboard() && ty > 24.0) {
        static NSInteger logs = 0;
        if (logs < 6) {
            logs += 1;
            DSTraceFormat(@"app skipped composer slide %@ ty=%.0f",
                          NSStringFromClass(object_getClass(view)), ty);
        }
        return;
    }
    // One slide. A layout that wants a different slide is the keyboard
    // reacting to the one just applied, and answering it is the freeze.
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now < DSComposerShiftQuietUntil) return;
    DSComposerShiftQuietUntil = now + 0.4;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    view.transform = CGAffineTransformMakeTranslation(0.0, ty);
    [CATransaction commit];
}

static void DSTranslateComposersInHost(UIView *host) {
    // The reply bar is moved by DSPullMessageBarUp. Sliding every composer
    // from the input host's layout is the freeze.
    (void)host;
    return;
    if (!DSStaged() || DSComposerShiftDepth > 0 || ![host isKindOfClass:UIView.class]) return;
    UIWindow *window = [host isKindOfClass:UIWindow.class] ? (UIWindow *)host : host.window;
    CGFloat cardH = (window && DSIsKeyboardWindow(window)) ? DSVisibleCardHeight(window) : 0;
    if (cardH < 80.0) cardH = CGRectGetHeight(DSStageBounds());
    if (cardH < 80.0) return;

    CGFloat hostTop = 0;
    if (window && host != (UIView *)window) {
        @try {
            hostTop = CGRectGetMinY([host convertRect:host.bounds toView:window]);
        } @catch (NSException *exception) {
            hostTop = CGRectGetMinY(host.frame);
        }
    }
    CGFloat targetBottom = cardH - hostTop;
    CGFloat hostH = CGRectGetHeight(host.bounds);
    if (hostH > 40.0 && hostH + 8.0 < targetBottom) targetBottom = hostH;
    if (targetBottom < 40.0) return;

    DSComposerShiftDepth += 1;
    for (UIView *subview in [host.subviews copy]) {
        NSString *name = NSStringFromClass(object_getClass(subview));
        if (DSNameIsLocalKeyboard(name) || DSNameIsKeyboardRemoteControl(name)) continue;
        if (DSNameIsStageComposer(name)) {
            DSApplyComposerShift(subview, targetBottom);
            continue;
        }
        if (DSViewIsStageShell(subview)) continue;
        CGFloat wrapperTop = CGRectGetMinY(subview.frame);
        for (UIView *child in [subview.subviews copy]) {
            NSString *childName = NSStringFromClass(object_getClass(child));
            if (!DSNameIsStageComposer(childName)) continue;
            DSApplyComposerShift(child, targetBottom - wrapperTop);
        }
    }
    DSComposerShiftDepth -= 1;
}

static void DSTranslateComposersInTree(UIView *view, NSInteger depth) {
    if (!view || depth > 6) return;
    NSString *name = NSStringFromClass(object_getClass(view));
    if (depth > 0 && [name rangeOfString:@"InputSetHost"].location != NSNotFound) {
        DSTranslateComposersInHost(view);
        return;
    }
    for (UIView *subview in view.subviews) DSTranslateComposersInTree(subview, depth + 1);
}

static void DSFitTextEffectsWindow(UIWindow *window) {
    // This window stays the size of the phone so the keys are drawn outside the card.
    (void)window;
    return;
    if (!DSStaged() || !window || DSFittingEffectsWindow || DSCompactDepth > 0) return;
    DSTrace(@"app fit text effects");
    if (DSIsRemoteKeyboardWindow(window)) return;
    NSString *name = NSStringFromClass(object_getClass(window));
    if ([name rangeOfString:@"TextEffects"].location == NSNotFound) return;
    CGFloat cardH = DSVisibleCardHeight(window);
    if (cardH < 80.0) return;
    DSCompactDepth += 1;
    DSLiftEffectsNode(window, cardH, NO, 0);
    DSPinShellTree(window, CGRectMake(0.0, 0.0, CGRectGetWidth(DSStageBounds()), cardH), 0);
    DSTranslateComposersInTree(window, 0);
    DSCompactDepth -= 1;
}

// The view the card actually shows. The stage window itself is in SpringBoard,
// a different process, so the input bar has to join this app's root view.
static UIView *DSStagedAppRoot(void) {
    __block UIView *found = nil;
    __block CGFloat foundH = CGFLOAT_MAX;
    DSVisitLiveWindows(^(UIWindow *window) {
        if (DSWindowIsKeyboardChrome(window) || DSIsRemoteKeyboardWindow(window)) return;
        UIView *root = window.rootViewController.view;
        if (![root isKindOfClass:UIView.class]) return;
        CGFloat height = CGRectGetHeight(root.bounds);
        if (height < 80.0) return;
        if (!found || height < foundH) {
            found = root;
            foundH = height;
        }
    });
    return found;
}

static CGFloat DSCardHeightForInput(UIView *stageView) {
    CGRect stage = DSStageBounds();
    CGRect device = [DSStageContext sharedContext].deviceBounds;
    CGFloat stageH = CGRectGetHeight(stage);
    CGFloat deviceH = CGRectGetHeight(device);
    CGFloat rootH = stageView ? CGRectGetHeight(stageView.bounds) : 0;
    BOOL stageIsPhone = deviceH > 80.0 &&
                        fabs(stageH - deviceH) < 12.0 &&
                        fabs(CGRectGetWidth(stage) - CGRectGetWidth(device)) < 12.0;
    if (!stageIsPhone && stageH > 80.0) {
        if (rootH > 80.0 && rootH + 8.0 < stageH) return rootH;
        return stageH;
    }
    if (rootH > 80.0 && deviceH > 80.0 && rootH + 24.0 < deviceH) return rootH;
    if (deviceH > 160.0) return floor(deviceH * 0.5);
    return rootH > 80.0 ? rootH : stageH;
}

static void DSShrinkScrollsAbove(UIView *view, UIView *bar, CGFloat barTop, NSInteger depth) {
    if (!view || view == bar || depth > 10) return;
    if ([view isKindOfClass:UIScrollView.class]) {
        UIScrollView *scroll = (UIScrollView *)view;
        CGFloat oldH = CGRectGetHeight(scroll.frame);
        if (oldH > 80.0 && CGRectGetMaxY(scroll.frame) > barTop + 1.0) {
            CGRect frame = scroll.frame;
            CGFloat newH = barTop - CGRectGetMinY(frame);
            if (newH > 40.0 && newH < oldH - 1.0) {
                BOOL nearBottom = scroll.contentSize.height < 1.0 ||
                    scroll.contentOffset.y + oldH > scroll.contentSize.height - 80.0;
                frame.size.height = newH;
                DSClampingStage = YES;
                scroll.frame = frame;
                DSClampingStage = NO;
                if (nearBottom) {
                    CGPoint offset = scroll.contentOffset;
                    offset.y += oldH - newH;
                    CGFloat maxY = scroll.contentSize.height - newH;
                    if (maxY < 0) maxY = 0;
                    if (offset.y > maxY) offset.y = maxY;
                    if (offset.y < 0) offset.y = 0;
                    scroll.contentOffset = offset;
                }
            }
        }
        return;
    }
    for (UIView *subview in view.subviews) {
        if (subview == bar) continue;
        DSShrinkScrollsAbove(subview, bar, barTop, depth + 1);
    }
}

static void DSStageWidthAndHeight(UIView *stageView, CGFloat *width, CGFloat *height) {
    CGFloat cardH = DSCardHeightForInput(stageView);
    CGFloat cardW = CGRectGetWidth(stageView.bounds);
    CGRect stage = DSStageBounds();
    if (CGRectGetWidth(stage) > 80.0 && CGRectGetWidth(stage) + 2.0 < cardW) cardW = CGRectGetWidth(stage);
    if (width) *width = cardW;
    if (height) *height = cardH;
}

// Sit a bar that already lives in the conversation on the card's bottom.
// Messages lays that bar out for the phone and will put it back on the next
// layout, so this runs again after that layout. It does not call layoutIfNeeded.
static void DSPinViewToStageBottom(UIView *view) {
    if (!DSStaged() || ![view isKindOfClass:UIView.class]) return;
    UIView *stageView = DSStagedAppRoot();
    if (!stageView || view == stageView || view.superview == nil) return;
    if (view.superview != stageView && ![view isDescendantOfView:stageView]) return;

    CGFloat cardW = 0;
    CGFloat cardH = 0;
    DSStageWidthAndHeight(stageView, &cardW, &cardH);
    if (cardW < 80.0 || cardH < 80.0) return;

    CGFloat height = CGRectGetHeight(view.bounds);
    if (height < 1.0) height = CGRectGetHeight(view.frame);
    if (height < 20.0 || height > cardH * 0.55) return;

    BOOL direct = view.superview == stageView;
    CGRect frame;
    if (direct) {
        frame = CGRectMake(0.0, cardH - height, cardW, height);
    } else {
        if (CGAffineTransformIsIdentity(view.transform)) {
            CGRect inStage = [view convertRect:view.bounds toView:stageView];
            if (fabs(cardH - CGRectGetMaxY(inStage)) < 1.0) return;
        }
        CGRect inStage = [view convertRect:view.bounds toView:stageView];
        CGFloat delta = cardH - CGRectGetMaxY(inStage);
        frame = view.frame;
        frame.origin.y += delta;
        if (CGRectGetHeight(view.superview.bounds) > height + 30.0) {
            frame.size.width = cardW;
            frame.origin.x = 0.0;
        }
    }

    BOOL placed = CGRectEqualToRect(view.frame, frame) && CGAffineTransformIsIdentity(view.transform);
    if (placed) {
        if (direct) [stageView bringSubviewToFront:view];
        return;
    }

    BOOL outer = DSInputReparentDepth == 0;
    if (outer) DSInputReparentDepth += 1;
    view.transform = CGAffineTransformIdentity;
    if (direct) {
        view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
        view.translatesAutoresizingMaskIntoConstraints = YES;
    }
    DSClampingStage = YES;
    view.frame = frame;
    DSClampingStage = NO;
    if (direct) {
        [stageView bringSubviewToFront:view];
        stageView.clipsToBounds = YES;
        DSShrinkScrollsAbove(stageView, view, CGRectGetMinY(view.frame), 0);
    }
    if (outer) DSInputReparentDepth -= 1;
}

// UICompatibilityInputViewController's own view. It is the next responder of
// that view, which is how the system window keeps the reply field.
static BOOL DSViewIsCompatibilityInputView(UIView *view) {
    Class inputClass = objc_getClass("UICompatibilityInputViewController");
    if (!inputClass || ![view isKindOfClass:UIView.class]) return NO;
    return [view.nextResponder isKindOfClass:inputClass];
}

// The reply field, wherever UIKit left it. A phone-tall input controller is the
// shell around that field, so it does not count: the field itself is shorter.
static void DSConsiderInputAnchor(UIView *view, NSInteger depth, UIView **best, CGFloat *bestBottom) {
    if (!view || depth > 22 || !best || !bestBottom) return;
    NSString *name = NSStringFromClass(object_getClass(view));
    if (DSNameIsLocalKeyboard(name) || DSNameIsKeyboardRemoteControl(name)) return;
    CGFloat height = CGRectGetHeight(view.bounds);
    BOOL entry = [name rangeOfString:@"MessageEntry"].location != NSNotFound;
    BOOL compat = DSViewIsCompatibilityInputView(view);
    if ((entry || compat) && height >= 20.0 && height <= 280.0 && view.window) {
        CGRect screen = CGRectZero;
        @try {
            screen = [view convertRect:view.bounds toView:nil];
        } @catch (NSException *exception) {
            screen = CGRectZero;
        }
        CGFloat bottom = CGRectGetMaxY(screen);
        if (bottom > *bestBottom && CGRectGetWidth(screen) > 40.0) {
            *bestBottom = bottom;
            *best = view;
        }
        if (entry) return;
    }
    if ([view isKindOfClass:UICollectionView.class] || [view isKindOfClass:UITableView.class]) return;
    for (UIView *subview in view.subviews) DSConsiderInputAnchor(subview, depth + 1, best, bestBottom);
}

static UIView *DSInputAnchorView(void) {
    __block UIView *best = nil;
    __block CGFloat bestBottom = -1.0;
    DSVisitLiveWindows(^(UIWindow *window) {
        if (DSIsRemoteKeyboardWindow(window)) return;
        DSConsiderInputAnchor(window, 0, &best, &bestBottom);
    });
    return best;
}

// The conversation stays at the top of the card. The reply field is moved by
// the input window's own scene constraints, not by shifting this root.
static CGRect DSDroppedRectForRoot(UIView *root) {
    (void)root;
    return CGRectZero;
    if (DSDropQueryDepth > 0 || ![root isKindOfClass:UIView.class]) return CGRectZero;
    UIView *parent = root.superview;
    if (![parent isKindOfClass:UIWindow.class] || DSIsKeyboardWindow((UIWindow *)parent)) return CGRectZero;
    CGRect stage = DSStageBounds();
    CGFloat cardW = CGRectGetWidth(stage);
    CGFloat cardH = CGRectGetHeight(stage);
    CGFloat windowW = CGRectGetWidth(parent.bounds);
    CGFloat windowH = CGRectGetHeight(parent.bounds);
    if (cardW < 80.0) cardW = windowW;
    if (cardH < 80.0) cardH = windowH;
    if (cardW < 80.0 || cardH < 80.0) return CGRectZero;
    if (windowW > 40.0 && windowW < cardW) cardW = windowW;
    // The window is already the card. Sliding that window is a separate step.
    if (windowH <= cardH + 24.0) return CGRectMake(0.0, 0.0, cardW, cardH);

    DSDropQueryDepth += 1;
    UIView *input = DSInputAnchorView();
    CGFloat inputTop = windowH;
    if (input && input != root && ![root isDescendantOfView:input]) {
        CGRect inWindow = CGRectZero;
        @try {
            if (input.window == (UIWindow *)parent) {
                inWindow = [input convertRect:input.bounds toView:parent];
            } else {
                CGRect screen = [input convertRect:input.bounds toView:nil];
                inWindow = [parent convertRect:screen fromView:nil];
            }
        } @catch (NSException *exception) {
            inWindow = CGRectZero;
        }
        if (CGRectGetHeight(inWindow) >= 20.0 && CGRectGetMinY(inWindow) > 40.0) {
            inputTop = CGRectGetMinY(inWindow);
        }
    }
    DSDropQueryDepth -= 1;

    CGFloat sliceTop = windowH - cardH;
    if (sliceTop < 0.0) sliceTop = 0.0;
    CGFloat y = sliceTop;
    CGFloat height = cardH;
    if (inputTop > sliceTop + 80.0 && inputTop < windowH - 1.0) {
        height = inputTop - sliceTop;
    }
    if (height < 80.0) height = cardH;
    if (y + height > windowH) height = windowH - y;
    return CGRectMake(0.0, y, cardW, height);
}

static void DSSlideWindowDownToInput(UIWindow *window, UIView *input) {
    if (!window || !input || input.window == window || DSIsKeyboardWindow(window)) return;
    CGRect stage = DSStageBounds();
    CGFloat cardH = CGRectGetHeight(stage);
    CGFloat windowH = CGRectGetHeight(window.bounds);
    if (cardH < 80.0 || windowH > cardH + 24.0) return;
    CGRect device = [DSStageContext sharedContext].deviceBounds;
    CGRect inputScreen = CGRectZero;
    CGRect windowScreen = CGRectZero;
    @try {
        inputScreen = [input convertRect:input.bounds toView:nil];
        windowScreen = [window convertRect:window.bounds toView:nil];
    } @catch (NSException *exception) {
        return;
    }
    if (CGRectGetHeight(inputScreen) < 20.0 || CGRectGetWidth(inputScreen) < 40.0) return;
    // Only when the window's screen position is its frame. Otherwise each
    // layout would add the same gap again and the window would leave the phone.
    if (fabs(CGRectGetMinY(windowScreen) - window.frame.origin.y) > 30.0) return;
    CGFloat desiredY = CGRectGetMinY(inputScreen) - CGRectGetHeight(window.bounds);
    if (desiredY < 0.0) desiredY = 0.0;
    if (desiredY > CGRectGetHeight(device) - 40.0) return;
    if (fabs(window.frame.origin.y - desiredY) <= 1.0) return;
    CGRect frame = window.frame;
    frame.origin.y = desiredY;
    window.frame = frame;
}

// The reply field is pinned to the text-effects window with constraints. Retarget
// those shells to the card. Moving the conversation does not change that pin.
static void DSDropOurViewToInput(void) {
    return;
    if (!DSStaged() || DSDroppingStage || DSInputReparentDepth > 0) return;
    UIView *root = DSStagedAppRoot();
    if (!root) return;
    UIView *parent = root.superview;
    if (![parent isKindOfClass:UIWindow.class] || DSIsKeyboardWindow((UIWindow *)parent)) return;
    UIWindow *window = (UIWindow *)parent;

    DSDroppingStage = YES;
    UIView *input = DSInputAnchorView();
    CGFloat windowH = CGRectGetHeight(window.bounds);
    CGRect stage = DSStageBounds();
    BOOL windowIsCard = windowH <= CGRectGetHeight(stage) + 24.0;
    if (windowIsCard && input) DSSlideWindowDownToInput(window, input);

    CGRect want = DSDroppedRectForRoot(root);
    if (CGRectGetWidth(want) > 80.0 && CGRectGetHeight(want) > 80.0) {
        root.clipsToBounds = YES;
        root.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
        if (!CGAffineTransformIsIdentity(root.transform)) root.transform = CGAffineTransformIdentity;
        if (!CGRectEqualToRect(root.frame, want)) {
            DSClampingStage = YES;
            root.frame = want;
            DSClampingStage = NO;
        }
        if (!windowIsCard) {
            for (UIView *sibling in window.subviews) {
                if (sibling == root || DSViewIsStageShell(sibling)) continue;
                NSString *name = NSStringFromClass(object_getClass(sibling));
                if (DSNameIsLocalKeyboard(name) || DSNameIsKeyboardRemoteControl(name) || DSNameIsHomeChrome(name)) continue;
                CGFloat height = CGRectGetHeight(sibling.bounds);
                CGFloat width = CGRectGetWidth(sibling.bounds);
                if (height < 80.0 || width < 80.0) continue;
                BOOL phoneSized = height > CGRectGetHeight(want) + 24.0 || width > CGRectGetWidth(want) + 24.0;
                BOOL atTop = CGRectGetMinY(sibling.frame) + 2.0 < CGRectGetMinY(want);
                if (!phoneSized && !atTop) continue;
                if (CGRectEqualToRect(sibling.frame, want)) continue;
                if (!CGAffineTransformIsIdentity(sibling.transform)) sibling.transform = CGAffineTransformIdentity;
                sibling.clipsToBounds = YES;
                DSClampingStage = YES;
                sibling.frame = want;
                DSClampingStage = NO;
            }
        }
        DSClampScreenSizedChildren(root, 0);
        DSKeepTranscriptBottom(root, 0);
    }
    DSDroppingStage = NO;
}

static UIView *DSOwningInputView(UIView *view) {
    Class inputClass = objc_getClass("UICompatibilityInputViewController");
    UIResponder *responder = view;
    while (responder) {
        if (inputClass && [responder isKindOfClass:inputClass]) {
            UIView *controllerView = ((UIViewController *)responder).view;
            return [controllerView isKindOfClass:UIView.class] ? controllerView : view;
        }
        responder = responder.nextResponder;
    }
    return view;
}

// The reply field stays in the text-effects window. Callers that used to pull
// it onto the conversation now drop the conversation down to the field instead.
static void DSReparentStagedMessageInput(void) {
    DSDropOurViewToInput();
}

extern "C" void DSRelayoutStagedMessageInput(void) {
    if (!DSStaged() || DSInputReparentDepth > 0) return;
    // Pin only. layoutIfNeeded here runs while the conversation is still
    // pushing, and that push never comes back.
    DSDropOurViewToInput();
}

// The card hooks are off. Roots that were fitted to the split, and a keyboard
// window still the size of that split, have to fill the phone. Leaving them
// is the reply bar sitting in the middle of Messages until the app is killed.
extern "C" void DSRestoreAfterLeavingStage(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            DSRestoreAfterLeavingStage();
        });
        return;
    }
    if (DSStaged()) return;
    CGRect device = [DSStageContext sharedContext].deviceBounds;
    if (CGRectGetWidth(device) < 80.0 || CGRectGetHeight(device) < 80.0) return;
    DSClampingStage = YES;
    @try {
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            if (![window isKindOfClass:UIWindow.class]) continue;
            window.transform = CGAffineTransformIdentity;
            if (DSIsKeyboardWindow(window)) {
                CGFloat width = CGRectGetWidth(window.bounds);
                CGFloat height = CGRectGetHeight(window.bounds);
                BOOL cardSized = width > 80.0 && height > 80.0 &&
                    (width + 8.0 < CGRectGetWidth(device) || height + 40.0 < CGRectGetHeight(device));
                if (cardSized && !CGRectEqualToRect(window.frame, device)) window.frame = device;
                continue;
            }
            UIView *root = window.rootViewController.view;
            if (![root isKindOfClass:UIView.class]) continue;
            root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            root.transform = CGAffineTransformIdentity;
            CGFloat parentW = CGRectGetWidth(window.bounds);
            CGFloat parentH = CGRectGetHeight(window.bounds);
            if (parentW < 40.0 || parentH < 40.0) continue;
            CGRect want = CGRectMake(0.0, 0.0, parentW, parentH);
            if (!CGRectEqualToRect(root.frame, want)) root.frame = want;
            [root setNeedsLayout];
            [window setNeedsLayout];
        }
    } @catch (NSException *exception) {
    }
    DSClampingStage = NO;
    DSTrace(@"app restored the phone layout");
}

static void DSBanishLocalKeyboard(void) {
    if (!DSStaged() || DSBanishing) return;
    DSTrace(@"app banish keyboard. cause=SpringBoard reported a full keyboard, so the copy inside the card is hidden");
    DSBanishing = YES;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    DSVisitLiveWindows(^(UIWindow *window) {
        if (!DSWindowIsKeyboardChrome(window)) return;
        [names addObject:NSStringFromClass(object_getClass(window))];
        NSString *name = NSStringFromClass(object_getClass(window));
        // The reply bar lives in the text-effects window. Key views inside it
        // are hidden below. A hosted keyboard window is only keys.
        if ([name rangeOfString:@"TextEffects"].location == NSNotFound) {
            DSKillHostedKeyboardView(window);
        }
        DSBanishKeyboardInView(window, window.bounds, YES, 0);
        DSBanishKeyboardLayers(window.layer, window.bounds);
    });
    DSVisitLiveWindows(^(UIWindow *window) {
        if (DSWindowIsKeyboardChrome(window)) return;
        DSStripKeyboardLayerHostsInTree(window, 0);
    });
    DSVisitLiveWindows(^(UIWindow *window) {
        if (!DSWindowIsKeyboardChrome(window)) return;
        DSLayoutKeyboardRemoteControlsInTree(window, 0);
    });
    DSBanishing = NO;
    if (names.count) DSReportKeyboardDebug([names componentsJoinedByString:@","]);
}

static void DSOnKeyboardWillChangeFrame(NSNotification *note) {
    // Hiding key views from here posts these same four notes, which hide the
    // views again. That loop is what spun the main thread while a conversation
    // opened. The trace stays. Nothing else runs.
    CGRect end = CGRectZero;
    CGRect begin = CGRectZero;
    NSValue *endValue = note.userInfo[UIKeyboardFrameEndUserInfoKey];
    NSValue *beginValue = note.userInfo[UIKeyboardFrameBeginUserInfoKey];
    if ([endValue isKindOfClass:NSValue.class]) end = endValue.CGRectValue;
    if ([beginValue isKindOfClass:NSValue.class]) begin = beginValue.CGRectValue;
    static NSString *lastName = nil;
    static CGRect lastEnd = {{0, 0}, {0, 0}};
    static NSInteger repeats = 0;
    BOOL same = [note.name isEqualToString:lastName] && CGRectEqualToRect(end, lastEnd);
    if (same) {
        repeats += 1;
        if (repeats > 1) return;
    } else {
        repeats = 0;
        lastName = [note.name copy];
        lastEnd = end;
    }
    CGRect stage = DSStageBounds();
    NSString *why = @"frame changed";
    if (CGRectGetHeight(end) < 1.0) why = @"keyboard height is 0, so nothing is showing";
    else if (CGRectGetWidth(end) + 24.0 < CGRectGetWidth(stage)) why = @"narrower than the card, so this is not the full keyboard";
    else if (CGRectGetMinY(end) >= CGRectGetHeight(stage) - 2.0 && CGRectGetHeight(stage) + 24.0 < CGRectGetHeight([DSStageContext sharedContext].deviceBounds)) {
        why = @"the frame starts below the card, which is where the piece under the field lives";
    }
    DSTraceFormat(@"app keyboard note %@ begin=%@ end=%@. cause=%@ localHidden=%d remote=%d",
                  note.name ?: @"?",
                  NSStringFromCGRect(begin),
                  NSStringFromCGRect(end),
                  why,
                  DSMessagesLocalKeysHidden,
                  DSMessagesWantsRemoteKeyboard());
}

static void DSInstallKeyboardBanishObserver(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // These notes are logged only. Acting on them posts the same notes again
        // and the conversation push never returns.
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        for (NSString *name in @[
            UIKeyboardWillShowNotification,
            UIKeyboardDidShowNotification,
            UIKeyboardWillChangeFrameNotification,
            UIKeyboardDidChangeFrameNotification
        ]) {
            [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                            usingBlock:^(__unused NSNotification *note) {
                DSOnKeyboardWillChangeFrame(note);
            }];
        }
    });
}

static BOOL DSHitViewIsKeyboardChrome(UIView *view) {
    UIView *cursor = view;
    for (NSInteger depth = 0; cursor && depth < 14; depth++) {
        if ([cursor isKindOfClass:UIWindow.class]) break;
        NSString *name = NSStringFromClass(object_getClass(cursor));
        if (DSNameIsKeyboardRemoteControl(name)) return NO;
        if (DSNameIsMessageChrome(name)) return NO;
        if (DSNameIsLocalKeyboard(name)) return YES;
        if (DSNameIsKeyboardLayerHost(name)) return YES;
        if ([name rangeOfString:@"Keyboard"].location != NSNotFound) return YES;
        if ([name rangeOfString:@"InputSet"].location != NSNotFound) return YES;
        cursor = cursor.superview;
    }
    return NO;
}

// The staged app still has its own text-effects window, full of key buttons,
// even though SpringBoard is drawing the keys. A tap on the card was hitting
// those buttons. Selection handles in that window are small and stay tappable.
// Nothing here hides a view or moves a window.
static BOOL DSStagedKeyboardHitBlocksContent(UIWindow *window, UIView *hit) {
    if (!DSStaged() || !DSWindowIsKeyboardChrome(window)) return NO;
    if (!hit || hit == (UIView *)window) return YES;
    if (DSHitViewIsKeyboardChrome(hit)) return YES;
    CGRect inWindow = [hit convertRect:hit.bounds toView:window];
    CGRect bounds = window.bounds;
    if (CGRectGetHeight(inWindow) > CGRectGetHeight(bounds) * 0.45 &&
        CGRectGetWidth(inWindow) > CGRectGetWidth(bounds) * 0.7) {
        return YES;
    }
    return NO;
}

static BOOL DSIsMobilePhone(void) {
    static int cached = -1;
    if (cached < 0) {
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"";
        cached = [bundle isEqualToString:@"com.apple.mobilephone"] ? 1 : 0;
    }
    return cached == 1;
}

// Phone lays the keypad out for the whole display. The card is about half
// that tall, so the bottom rows sit past the stage. The previous fit ran in
// this dylib, and this dylib was not injected into Phone, so the pad never
// moved. Scale whatever Phone just laid out back into the card.
static BOOL DSPhoneClassHas(id object, const char *needle) {
    const char *name = object_getClassName(object);
    return name && needle && strstr(name, needle) != NULL;
}

static BOOL DSPhoneViewIsKeypad(UIView *view) {
    if (!view) return NO;
    if (DSPhoneClassHas(view, "Keyboard")) return NO;
    if (DSPhoneClassHas(view, "NumberPad") || DSPhoneClassHas(view, "PhonePad") ||
        DSPhoneClassHas(view, "Keypad")) return YES;
    // Favorites is a grid of round photos. That is not the dial pad.
    if ([view isKindOfClass:UIScrollView.class]) return NO;
    if (DSPhoneClassHas(view, "Collection") || DSPhoneClassHas(view, "Table") || DSPhoneClassHas(view, "Cell")) return NO;
    if (CGRectGetWidth(view.bounds) < 160.0 || CGRectGetHeight(view.bounds) < 160.0) return NO;
    CGFloat side = 0.0;
    NSInteger squares = 0;
    for (UIView *subview in view.subviews) {
        if (subview.hidden) continue;
        CGFloat width = CGRectGetWidth(subview.bounds);
        CGFloat height = CGRectGetHeight(subview.bounds);
        if (width < 52.0 || height < 52.0) continue;
        if (fabs(width - height) > width * 0.28) continue;
        if (side > 1.0 && fabs(width - side) > side * 0.25) continue;
        if (side < 1.0) side = width;
        squares += 1;
    }
    return squares >= 9;
}

// Set while a child frame is being restored so that layout does not scale the
// keypad a second time in the middle of this pass.

static BOOL DSPhoneIsCardRoot(UIView *view);
static void DSPhoneFindKeypad(UIView *view, NSInteger depth, UIView **best, CGFloat *bestArea);
static void DSPhoneFitCardRoot(UIView *root);
static void DSPhoneRestoreLifted(UIView *view, NSInteger depth);
static void DSPhoneWriteFit(NSString *line, CGFloat scale, CGFloat box, CGFloat band);

// The card size at the origin of Phone's window. SpringBoard's scene stays
// the full display, so Phone lays the header out at the top of 932pt unless
// this frame is in place before that layout.
static CGRect DSPhoneCardFrame(void) {
    if (!DSIsMobilePhone() || !DSStaged()) return CGRectZero;
    CGRect stage = DSStageBounds();
    CGRect device = [DSStageContext sharedContext].deviceBounds;
    if (CGRectGetWidth(stage) < 80.0 || CGRectGetHeight(stage) < 80.0) return CGRectZero;
    if (CGRectGetHeight(device) > 80.0 && CGRectGetHeight(stage) > CGRectGetHeight(device) - 40.0) return CGRectZero;
    return CGRectMake(0.0, 0.0, CGRectGetWidth(stage), CGRectGetHeight(stage));
}

// The card is the window. A full-screen root is what paints the top of Phone
// outside the stage, where the card clips it away.
static void DSPhoneApplyCardFrame(UIView *root) {
    if (!DSIsMobilePhone() || !DSStaged() || !root || DSPhoneLayoutFrozen || DSClampingStage) return;
    @try {
        UIWindow *window = [root isKindOfClass:UIWindow.class] ? (UIWindow *)root : root.window;
        if (![window isKindOfClass:UIWindow.class] || DSIsKeyboardWindow(window)) return;
        CGRect want = DSPhoneCardFrame();
        if (CGRectGetWidth(want) < 80.0 || CGRectGetHeight(want) < 80.0) return;
        window.clipsToBounds = YES;
        window.layer.masksToBounds = YES;
        if (fabs(CGRectGetWidth(window.bounds) - CGRectGetWidth(want)) > 1.0 ||
            fabs(CGRectGetHeight(window.bounds) - CGRectGetHeight(want)) > 1.0 ||
            fabs(CGRectGetMinX(window.frame)) > 1.0 ||
            fabs(CGRectGetMinY(window.frame)) > 1.0) {
            window.transform = CGAffineTransformIdentity;
            window.frame = want;
        }
        UIView *content = window.rootViewController.view ?: root;
        content.clipsToBounds = YES;
        content.layer.masksToBounds = YES;
        CGRect bounds = CGRectMake(0.0, 0.0, CGRectGetWidth(window.bounds), CGRectGetHeight(window.bounds));
        if (!CGRectEqualToRect(content.frame, bounds)) {
            content.transform = CGAffineTransformIdentity;
            content.frame = bounds;
        }
    } @catch (NSException *exception) {
    }
}

static void DSPhoneContainCard(UIView *any) {
    if (!DSIsMobilePhone() || !DSStaged() || !any || DSPhoneLayoutFrozen || DSClampingStage) return;
    DSPhoneLayoutFrozen = YES;
    DSClampingStage = YES;
    DSPhoneApplyCardFrame(any);
    DSClampingStage = NO;
    DSPhoneLayoutFrozen = NO;
    UIWindow *window = [any isKindOfClass:UIWindow.class] ? (UIWindow *)any : any.window;
    if ([window isKindOfClass:UIWindow.class]) {
        DSPhoneWriteFit([NSString stringWithFormat:@"app: phone contained %@", NSStringFromCGRect(window.bounds)],
                        1.0, CGRectGetHeight(window.bounds), CGRectGetHeight(DSStageBounds()));
    }
}

static void DSAdjustPhoneLayoutForStage(UIView *root);

// Other staged apps lay out at the card size, so they fill the card. Phone
// keeps the real screen metrics (DSPhoneKeepsRealScreen), so it draws a
// full-phone dialer (round keys). SpringBoard's host view is the card's
// shape: if the scene stays phone-aspect, the host stretches it and every
// circle becomes a wide oval (4.5.636–641 fill).
//
// Fix (4.5.644): window = card, root = device size, ONE uniform root scale,
// bottom-align so 1–call + tabs stay on-card (keys stay round).
// Fix (4.5.645): root fill alone left the dial block floating high (native
// gap between call and tabs). After root fill, resize JUST the dial pad
// (digits + call/delete) to fill the band above the tab/quick bar — uniform
// preferred, mild non-uniform stretch OK. Stage card size stays fixed; tabs
// stay at the bottom of the card.
static const CGFloat DSPhoneMinLayoutHeight = 560.0; // kept for logs / fallbacks

static void DSPhoneScaleRootIntoCard(UIView *root) {
    if (!DSIsMobilePhone() || !DSStaged() || !root || DSPhoneLayoutFrozen || DSClampingStage) return;
    UIWindow *window = [root isKindOfClass:UIWindow.class] ? (UIWindow *)root : root.window;
    if (![window isKindOfClass:UIWindow.class] || DSIsKeyboardWindow(window)) return;
    if (window.rootViewController.view != root) return;
    CGRect device = [DSStageContext sharedContext].deviceBounds;
    CGRect stage = DSStageBounds();
    CGFloat fullW = CGRectGetWidth(device);
    CGFloat fullH = CGRectGetHeight(device);
    CGFloat cardW = CGRectGetWidth(stage);
    CGFloat cardH = CGRectGetHeight(stage);
    if (fullW < 80.0 || fullH < 80.0 || cardW < 80.0 || cardH < 80.0) return;
    if (cardH > fullH - 40.0) return;
    // Device-aspect layout + one uniform scale. Prefer width-fill; if that
    // leaves a vertical gap, height-fill instead (still uniform X=Y).
    CGFloat layoutW = fullW;
    CGFloat layoutH = fullH;
    CGFloat scale = cardW / layoutW;
    if (layoutH * scale < cardH - 0.5) scale = cardH / layoutH;
    if (scale < 0.2 || scale > 1.05) return;
    DSPhoneLayoutFrozen = YES;
    DSClampingStage = YES;
    @try {
        // Scene size must match the card or SB's host view stretches X/Y.
        window.transform = CGAffineTransformIdentity;
        CGRect wantWindow = CGRectMake(0.0, 0.0, cardW, cardH);
        if (fabs(CGRectGetWidth(window.bounds) - cardW) > 0.5 ||
            fabs(CGRectGetHeight(window.bounds) - cardH) > 0.5 ||
            fabs(CGRectGetMinX(window.frame)) > 0.5 ||
            fabs(CGRectGetMinY(window.frame)) > 0.5) {
            window.frame = wantWindow;
        }
        window.clipsToBounds = YES;
        window.layer.masksToBounds = YES;

        // Identity only while rewriting bounds; fill scale goes back on below.
        root.transform = CGAffineTransformIdentity;
        if (fabs(CGRectGetWidth(root.bounds) - layoutW) > 0.5 ||
            fabs(CGRectGetHeight(root.bounds) - layoutH) > 0.5 ||
            fabs(CGRectGetMinX(root.bounds)) > 0.5 || fabs(CGRectGetMinY(root.bounds)) > 0.5) {
            root.bounds = CGRectMake(0.0, 0.0, layoutW, layoutH);
        }
        CGFloat visualH = layoutH * scale;
        CGFloat visualW = layoutW * scale;
        // Bottom-align whenever content is taller than the card: tabs + call +
        // keypad stay in view; status / nav / empty top chrome may clip.
        // Never top-align an oversized root (that only shows rows 1–6).
        CGFloat centerX = cardW / 2.0;
        CGFloat centerY;
        if (visualH >= cardH - 0.5) {
            centerY = cardH - visualH / 2.0; // bottom edge of content == card bottom
        } else {
            centerY = cardH / 2.0;
        }
        // If width-fill made us wider than the card, keep horizontally centered.
        (void)visualW;
        root.center = CGPointMake(centerX, centerY);
        root.transform = CGAffineTransformMakeScale(scale, scale); // identical X/Y
        // Clip at the window (card), not by wiping content above the keypad.
        root.clipsToBounds = NO;
        root.layer.masksToBounds = NO;
        DSPhoneWriteFit([NSString stringWithFormat:@"app: phone fill scale=%.2f layout=%.0fx%.0f card=%.0fx%.0f full=%.0fx%.0f bottomAlign=%d",
                         scale, layoutW, layoutH, cardW, cardH, fullW, fullH,
                         (visualH >= cardH - 0.5) ? 1 : 0],
                        scale, cardW, cardH);
    } @catch (NSException *exception) {
    }
    DSClampingStage = NO;
    DSPhoneLayoutFrozen = NO;
}

// Coalesce scale applies onto the next main turn so layoutSubviews / viewDidLayout
// never mutate bounds+transform mid-cascade (SIGTRAP).
static void DSPhoneScheduleScaleRootIntoCard(UIView *root) {
    if (!DSIsMobilePhone() || !DSStaged() || !root || DSPhoneLayoutFrozen || DSClampingStage) return;
    if (DSPhoneScaleScheduled) return;
    DSPhoneScaleScheduled = YES;
    __weak UIView *weakRoot = root;
    dispatch_async(dispatch_get_main_queue(), ^{
        DSPhoneScaleScheduled = NO;
        UIView *strongRoot = weakRoot;
        if (!strongRoot) return;
        // 4.5.645: root fill keeps round keys + full pad on-card; then dial
        // pad-only resize fills the band above the tab/quick bar (closes the
        // floating-high gap). DSResizePhoneKeypad measures in root space and
        // scales to FILL (not the old 0.82 shrink).
        DSPhoneScaleRootIntoCard(strongRoot);
        DSAdjustPhoneLayoutForStage(strongRoot);
    });
}

static void DSFitPhoneAfterLayout(UIView *view) {
    if (!DSPhoneIsCardRoot(view)) return;
    DSPhoneScheduleScaleRootIntoCard(view);
}

static const void *DSPhoneScaledKey = &DSPhoneScaledKey;
static const void *DSPhoneScaleKey = &DSPhoneScaleKey;
static const void *DSPhoneCenterKey = &DSPhoneCenterKey;
static const void *DSPhoneLiftFrameKey = &DSPhoneLiftFrameKey;
static const void *DSPhoneHomeKey = &DSPhoneHomeKey;
// The frame Phone laid out, kept so the next pass can put it back and scale
// once. Scaling the frame that is already scaled shrinks the keys to nothing.
static const void *DSPhoneNaturalFrameKey = &DSPhoneNaturalFrameKey;
static const void *DSPhoneNaturalRootKey = &DSPhoneNaturalRootKey;
// Set on the dial-button grid only. The header keeps the frame Phone laid
// out, so a keypad scale cannot slide "Add Number" above the card.
static const void *DSPhoneGridPieceKey = &DSPhoneGridPieceKey;
static const CGFloat DSPhoneDialScale = 1.0; // 4.5.645: fill uses computed sx/sy; this is unused floor bias
static const CGFloat DSPhoneDialBottomMargin = 8.0; // sit call just above tab/quick bar
static const CGFloat DSPhoneNumberDisplayLift = 10.0; // small LCD nudge only
static const CGFloat DSPhoneDialTopPad = 36.0; // leave room for Add Number / LCD strip
static const CGFloat DSPhoneDialMaxAspect = 1.14; // mild stretch cap (sx/sy)
// 4.5.641+: dial grid uses transform (keeps circles when sx≈sy).
// 4.5.645: dial-grid FILL re-enabled after root fill; lift stores sx in
// CGRect width and sy in height (height 0 = uniform legacy).
// Lift = {offset.x, offset.y, sx, sy}. Applied = the center we last wrote, so
// an Auto Layout reset (natural center) can be told apart from our own lift.
static const void *DSPhoneGridLiftKey = &DSPhoneGridLiftKey;
static const void *DSPhoneGridAppliedKey = &DSPhoneGridAppliedKey;
// Typed-number strip: the y Phone laid out and the y we wrote, so repeated
// passes lift it once instead of 22pt more every pass.
static const void *DSPhoneLcdNaturalYKey = &DSPhoneLcdNaturalYKey;
static const void *DSPhoneLcdWrittenYKey = &DSPhoneLcdWrittenYKey;

static BOOL DSPhoneHasGridLift(UIView *view) {
    return view && objc_getAssociatedObject(view, DSPhoneGridLiftKey) != nil;
}

// Apply (or re-apply) the stored lift on top of the natural center.
// Lift rect: origin = offset, size.width = sx, size.height = sy (0 ⇒ sx).
static void DSPhoneApplyGridLift(UIView *view, CGPoint natural) {
    NSValue *lift = objc_getAssociatedObject(view, DSPhoneGridLiftKey);
    if (!lift) return;
    CGRect l = lift.CGRectValue;
    CGFloat scaleX = CGRectGetWidth(l);
    CGFloat scaleY = CGRectGetHeight(l);
    if (scaleX < 0.3 || scaleX > 1.85) scaleX = 1.0;
    if (scaleY < 0.05) scaleY = scaleX; // legacy uniform (height stored as 0)
    else if (scaleY < 0.3 || scaleY > 1.85) scaleY = scaleX;
    CGPoint center = CGPointMake(natural.x + CGRectGetMinX(l), natural.y + CGRectGetMinY(l));
    BOOL wasFrozen = DSPhoneLayoutFrozen;
    DSPhoneLayoutFrozen = YES;
    view.clipsToBounds = NO;
    view.center = center;
    view.transform = CGAffineTransformMakeScale(scaleX, scaleY);
    DSPhoneLayoutFrozen = wasFrozen;
    objc_setAssociatedObject(view, DSPhoneGridAppliedKey, [NSValue valueWithCGPoint:center], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Back to the natural center with identity transform, lift data cleared.
static void DSPhoneClearGridLift(UIView *view) {
    if (!view) return;
    NSValue *lift = objc_getAssociatedObject(view, DSPhoneGridLiftKey);
    NSValue *applied = objc_getAssociatedObject(view, DSPhoneGridAppliedKey);
    BOOL wasFrozen = DSPhoneLayoutFrozen;
    DSPhoneLayoutFrozen = YES;
    CGPoint center = view.center;
    view.transform = CGAffineTransformIdentity;
    if (lift && applied && fabs(center.x - applied.CGPointValue.x) < 0.5 && fabs(center.y - applied.CGPointValue.y) < 0.5) {
        CGRect l = lift.CGRectValue;
        view.center = CGPointMake(center.x - CGRectGetMinX(l), center.y - CGRectGetMinY(l));
    }
    DSPhoneLayoutFrozen = wasFrozen;
    objc_setAssociatedObject(view, DSPhoneGridLiftKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, DSPhoneGridAppliedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}


static void DSPhoneRestoreLifted(UIView *view, NSInteger depth) {
    if (!view || depth > 18 || DSPhoneLayoutFrozen) return;
    UIView *home = objc_getAssociatedObject(view, DSPhoneHomeKey);
    if (home) {
        DSPhoneLayoutFrozen = YES;
        DSClampingStage = YES;
        objc_setAssociatedObject(view, DSPhoneLiftFrameKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(view, DSPhoneHomeKey, nil, OBJC_ASSOCIATION_ASSIGN);
        view.transform = CGAffineTransformIdentity;
        if (home != view.superview) [home addSubview:view];
        DSClampingStage = NO;
        DSPhoneLayoutFrozen = NO;
    }
    NSArray<UIView *> *subviews = [view.subviews copy];
    for (UIView *subview in subviews) DSPhoneRestoreLifted(subview, depth + 1);
}

static void DSPhoneReapply(UIView *view) {
    if (!view || DSPhoneLayoutFrozen) return;
    NSNumber *scale = objc_getAssociatedObject(view, DSPhoneScaleKey);
    NSValue *center = objc_getAssociatedObject(view, DSPhoneCenterKey);
    if (!scale || !center) return;
    DSPhoneLayoutFrozen = YES;
    view.clipsToBounds = NO;
    view.center = center.CGPointValue;
    view.transform = CGAffineTransformMakeScale(scale.doubleValue, scale.doubleValue);
    DSPhoneLayoutFrozen = NO;
}

static BOOL DSPhoneIsTabBar(UIView *view) {
    if (!view) return NO;
    if ([view isKindOfClass:UITabBar.class]) return YES;
    return DSPhoneClassHas(view, "TabBar");
}

static void DSPhoneResetScaled(UIView *view, NSInteger depth) {
    if (!view || depth > 16) return;
    if (objc_getAssociatedObject(view, DSPhoneScaledKey)) {
        view.transform = CGAffineTransformIdentity;
        objc_setAssociatedObject(view, DSPhoneScaledKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(view, DSPhoneScaleKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(view, DSPhoneCenterKey, nil, OBJC_ASSOCIATION_ASSIGN);
    }
    if ([view isKindOfClass:UIScrollView.class]) return;
    for (UIView *subview in view.subviews) DSPhoneResetScaled(subview, depth + 1);
}

// Put the button grid back before Auto Layout runs, so this pass measures the
// real keys and the 0.72 scale is applied once. Views that are not the grid
// (the Add Number bar, the call header) are left where Phone put them.
static void DSPhoneRestoreNaturalFrames(UIView *view, NSInteger depth) {
    if (!view || depth > 22) return;
    if (objc_getAssociatedObject(view, DSPhoneGridPieceKey)) {
        NSValue *natural = objc_getAssociatedObject(view, DSPhoneNaturalFrameKey);
        if (natural) {
            view.transform = CGAffineTransformIdentity;
            CGRect frame = natural.CGRectValue;
            if (!CGRectEqualToRect(view.frame, frame)) view.frame = frame;
        }
    }
    for (UIView *subview in view.subviews) DSPhoneRestoreNaturalFrames(subview, depth + 1);
}

// Disabled: this used to stretch a full-screen child to the card, which
// distorted Phone. DSPhoneScaleRootIntoCard now lays Phone out in a
// card-shaped box and scales it uniformly to fill the card. Kept as a no-op.
static BOOL DSPhoneIsTabBar(UIView *view);
static void DSPhoneFitTallContent(UIView *root) {
    (void)root;
    // Staged Phone uses one uniform fill scale; never stretch children.
}

// A bar Phone already laid out above the card. Move that bar down to the top
// of the stage. The dial grid is positioned on its own pass.
static void DSPhonePullClippedTop(UIView *root) {
    if (!root) return;
    CGFloat width = CGRectGetWidth(root.bounds);
    CGFloat height = CGRectGetHeight(root.bounds);
    if (width < 80.0 || height < 80.0) return;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view != root && view.superview && !DSPhoneIsTabBar(view) &&
            !objc_getAssociatedObject(view, DSPhoneGridPieceKey)) {
            CGRect inRoot = [view convertRect:view.bounds toView:root];
            BOOL wide = CGRectGetWidth(inRoot) >= width * 0.45;
            BOOL bar = CGRectGetHeight(inRoot) >= 16.0 && CGRectGetHeight(inRoot) <= 180.0;
            if (wide && bar && CGRectGetMinY(inRoot) < 0.0) {
                CGFloat dy = 8.0 - CGRectGetMinY(inRoot);
                view.transform = CGAffineTransformIdentity;
                view.autoresizingMask = UIViewAutoresizingNone;
                view.translatesAutoresizingMaskIntoConstraints = YES;
                CGRect frame = view.frame;
                frame.origin.y += dy;
                view.frame = frame;
                continue;
            }
        }
        if (!DSPhoneIsTabBar(view)) [stack addObjectsFromArray:view.subviews];
    }
}

static NSInteger DSPhoneRoundCount(UIView *view, NSInteger depth) {
    if (!view || depth > 4 || DSPhoneIsTabBar(view)) return 0;
    if ([view isKindOfClass:UIScrollView.class]) return 0;
    NSInteger count = 0;
    for (UIView *subview in view.subviews) {
        CGFloat width = CGRectGetWidth(subview.bounds);
        CGFloat height = CGRectGetHeight(subview.bounds);
        if (width >= 40.0 && height >= 40.0 && fabs(width - height) <= MAX(width, height) * 0.35) {
            count += 1;
        } else if (![subview isKindOfClass:UIScrollView.class] && !DSPhoneIsTabBar(subview)) {
            count += DSPhoneRoundCount(subview, depth + 1);
        }
    }
    return count;
}

// Staged Phone only. Other apps never reach this.
static UIView *DSFindClassView(UIView *root, NSString *name) {
    Class viewClass = NSClassFromString(name);
    if (!viewClass || !root) return nil;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view != root && [view isKindOfClass:viewClass]) return view;
        [stack addObjectsFromArray:view.subviews];
    }
    return nil;
}

// The button grid, not the whole dialer. Ten to sixteen controls is 0–9, *, #,
// and sometimes the call button. A tab bar is not the pad.
static UIView *DSFindButtonGrid(UIView *root) {
    if (!root) return nil;
    UIView *best = nil;
    NSInteger bestCount = 0;
    CGFloat bestArea = 0.0;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view != root && !DSPhoneIsTabBar(view) && ![view isKindOfClass:UIScrollView.class]) {
            NSInteger count = 0;
            for (UIView *subview in view.subviews) {
                if ([subview isKindOfClass:UIControl.class]) count++;
            }
            CGFloat area = CGRectGetWidth(view.bounds) * CGRectGetHeight(view.bounds);
            BOOL tighter = count > bestCount || (count == bestCount && (best == nil || area < bestArea));
            if (count >= 10 && count <= 16 && area > 800.0 && tighter) {
                bestCount = count;
                bestArea = area;
                best = view;
            }
        }
        [stack addObjectsFromArray:view.subviews];
    }
    return best;
}

static UIView *DSFindPhoneKeypadView(UIView *root) {
    for (NSString *name in @[ @"MPPhoneNumberPadView", @"MPKeypadView", @"TPDialerNumberPad", @"TPNumberPad" ]) {
        UIView *found = DSFindClassView(root, name);
        if (found) return found;
    }
    UIView *dialer = DSFindClassView(root, @"PHHandsetDialerView");
    UIView *grid = DSFindButtonGrid(dialer ?: root);
    if (grid) return grid;
    if (dialer) return dialer;
    UIView *best = nil;
    CGFloat area = 0.0;
    DSPhoneFindKeypad(root, 0, &best, &area);
    return best;
}

static UIView *DSPhoneFindTabBar(UIView *view, NSInteger depth);

// Dial-pad controls whose union must fit above the quick bar: square digit
// keys plus the green call button and delete (often wider / not square, and
// sometimes siblings just below the digit grid).
static BOOL DSPhoneIsDialPadControl(UIView *view) {
    if (![view isKindOfClass:UIControl.class]) return NO;
    CGFloat width = CGRectGetWidth(view.bounds);
    CGFloat height = CGRectGetHeight(view.bounds);
    if (width < 28.0 || height < 28.0) return NO;
    // 0–9, *, #: roughly square.
    if (width <= 220.0 && height <= 220.0 &&
        fabs(width - height) <= MAX(width, height) * 0.45) return YES;
    // Green call: wide capsule / large control under the pad.
    if (width >= 56.0 && height >= 40.0 && height <= 120.0 && width <= 340.0 &&
        width >= height * 0.85) return YES;
    // Delete / backspace beside call (when a number is entered).
    if (width >= 36.0 && width <= 120.0 && height >= 28.0 && height <= 72.0) return YES;
    return NO;
}

static void DSPhoneCollectKeyUnion(UIView *view, UIView *root, CGRect *unionRect, NSInteger *count, NSInteger depth) {
    if (!view || !root || !unionRect || !count || depth > 22 || DSPhoneIsTabBar(view)) return;
    if (DSPhoneIsDialPadControl(view)) {
        CGRect rect = [view convertRect:view.bounds toView:root];
        if (*count == 0) *unionRect = rect;
        else *unionRect = CGRectUnion(*unionRect, rect);
        *count += 1;
    }
    for (UIView *subview in view.subviews) DSPhoneCollectKeyUnion(subview, root, unionRect, count, depth + 1);
}

// Tag the grid and everything in it so the header passes (PullClippedTop,
// LiftNumberDisplay) never move a key. Frames are NOT touched: Phone's own
// layout of each button (circle, labels) stays exactly as Phone drew it.
static void DSPhoneMarkGridPieces(UIView *view, NSInteger depth) {
    if (!view || depth > 22 || DSPhoneIsTabBar(view)) return;
    objc_setAssociatedObject(view, DSPhoneGridPieceKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    for (UIView *subview in view.subviews) DSPhoneMarkGridPieces(subview, depth + 1);
}

// Dial-pad controls (digits + call/delete), collected so a grid that also
// holds the header — or call/delete sitting as siblings under the dialer —
// can be lifted control by control (each still one uniform transform).
static void DSPhoneCollectKeys(UIView *view, NSMutableArray<UIView *> *keys, NSInteger depth) {
    if (!view || !keys || depth > 22 || DSPhoneIsTabBar(view)) return;
    if (DSPhoneIsDialPadControl(view)) {
        [keys addObject:view];
        return;
    }
    for (UIView *subview in view.subviews) DSPhoneCollectKeys(subview, keys, depth + 1);
}

// Nudge the typed-number / LCD strip up a little so it isn't cramped against the dial grid.
static void DSPhoneLiftNumberDisplay(UIView *root) {
    if (!root) return;
    CGFloat width = CGRectGetWidth(root.bounds);
    CGFloat height = CGRectGetHeight(root.bounds);
    if (width < 80.0 || height < 80.0) return;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view != root && view.superview && !DSPhoneIsTabBar(view) &&
            !objc_getAssociatedObject(view, DSPhoneGridPieceKey)) {
            CGRect inRoot = [view convertRect:view.bounds toView:root];
            BOOL wide = CGRectGetWidth(inRoot) >= width * 0.35;
            BOOL strip = CGRectGetHeight(inRoot) >= 28.0 && CGRectGetHeight(inRoot) <= 96.0;
            BOOL upper = CGRectGetMinY(inRoot) >= 8.0 && CGRectGetMaxY(inRoot) <= height * 0.42;
            if (wide && strip && upper) {
                view.transform = CGAffineTransformIdentity;
                CGRect frame = view.frame;
                // Lift from the y Phone laid out, once. If the strip still
                // sits where we put it last pass, use the stored natural y.
                NSNumber *written = objc_getAssociatedObject(view, DSPhoneLcdWrittenYKey);
                NSNumber *natural = objc_getAssociatedObject(view, DSPhoneLcdNaturalYKey);
                CGFloat naturalY = frame.origin.y;
                if (written && natural && fabs(frame.origin.y - written.doubleValue) < 0.5) naturalY = natural.doubleValue;
                CGFloat wantY = MAX(4.0, naturalY - DSPhoneNumberDisplayLift);
                objc_setAssociatedObject(view, DSPhoneLcdNaturalYKey, @(naturalY), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(view, DSPhoneLcdWrittenYKey, @(wantY), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if (fabs(frame.origin.y - wantY) >= 0.5) {
                    view.autoresizingMask = UIViewAutoresizingNone;
                    view.translatesAutoresizingMaskIntoConstraints = YES;
                    frame.origin.y = wantY;
                    view.frame = frame;
                }
            }
        }
        if (![view isKindOfClass:UIScrollView.class] && !DSPhoneIsTabBar(view)) {
            [stack addObjectsFromArray:view.subviews];
        }
    }
}

// Typed-number strip (LCD). Outermost view whose class mentions "LCD", sized
// like a strip, not inside the tab bar or a dial key.
static UIView *DSPhoneFindLcdView(UIView *root) {
    if (!root) return nil;
    CGFloat width = CGRectGetWidth(root.bounds);
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSUInteger index = 0;
    while (index < queue.count) {
        UIView *view = queue[index++];
        if (DSPhoneIsTabBar(view)) continue;
        if (view != root) {
            NSString *name = NSStringFromClass(object_getClass(view));
            if ([name rangeOfString:@"LCD"].location != NSNotFound) {
                CGFloat w = CGRectGetWidth(view.bounds);
                CGFloat h = CGRectGetHeight(view.bounds);
                if (w >= width * 0.35 && h >= 20.0 && h <= 180.0) return view;
            }
        }
        if (![view isKindOfClass:UIScrollView.class]) [queue addObjectsFromArray:view.subviews];
    }
    return nil;
}

static const void *DSPhoneLcdPlacedKey = &DSPhoneLcdPlacedKey;
// Card-space strip the system status bar covers at the top of the stage.
static const CGFloat DSPhoneStatusPad = 44.0;

// Staged Phone only. 4.5.646: fit ALL of the dial pad (1–9, *0#, call/delete)
// into the part of the root that is actually VISIBLE in the card.
//
// 4.5.645 measured the fill band in the full-device root (y≈36 → tab bar).
// But the root is bottom-aligned in the card, so its top ~half is clipped:
// the pad was scaled to ~1.25× and only 7–9 / *0# / call showed.
//
// Now: visible band = card window converted into root space, minus the
// status-bar strip and room for the typed-number strip, down to just above
// the tab/quick bar. Each key keeps ONE uniform scale (round circles) limited
// by that band's height. Column centers keep the 4.5.645 side-to-side spread
// (user: "fits side to side perfect"); rows compress to fit. Bottom-aligned
// above the tabs. The LCD is moved into view just above the pad.
static void DSResizePhoneKeypad(UIView *keypad, UIView *root) {
    if (!keypad.superview || !root) return;
    UIView *grid = DSFindButtonGrid(keypad);
    if (!grid) grid = keypad;
    UIView *dialer = DSFindClassView(root, @"PHHandsetDialerView");
    UIView *scope = dialer ?: keypad;
    UIView *lcd = DSPhoneFindLcdView(dialer ?: root);
    // Undo last pass (grid + per-key lift, LCD shift) before measuring, so the
    // natural keys are measured and scaled exactly once.
    NSMutableArray<UIView *> *allKeys = [NSMutableArray array];
    DSPhoneCollectKeys(scope, allKeys, 0);
    for (UIView *key in allKeys) DSPhoneClearGridLift(key);
    DSPhoneClearGridLift(grid);
    grid.transform = CGAffineTransformIdentity;
    if (lcd) lcd.transform = CGAffineTransformIdentity;
    // Keys: visible controls, not inside the LCD (Add Number etc).
    NSMutableArray<UIView *> *keyViews = [NSMutableArray array];
    for (UIView *key in allKeys) {
        if (!key.superview || key.hidden || key.alpha < 0.01) continue;
        if (lcd && [key isDescendantOfView:lcd]) continue;
        [keyViews addObject:key];
    }
    CGRect source = CGRectZero;
    NSInteger keys = 0;
    for (UIView *key in keyViews) {
        CGRect rect = [key convertRect:key.bounds toView:root];
        source = keys == 0 ? rect : CGRectUnion(source, rect);
        keys++;
    }
    if (keys < 9) {
        // Fallback: pad pieces live in the grid only.
        [keyViews removeAllObjects];
        DSPhoneCollectKeys(grid, keyViews, 0);
        source = CGRectZero;
        keys = 0;
        for (UIView *key in keyViews) {
            CGRect rect = [key convertRect:key.bounds toView:root];
            source = keys == 0 ? rect : CGRectUnion(source, rect);
            keys++;
        }
    }
    if (keys < 9) return;
    CGFloat sourceW = CGRectGetWidth(source);
    CGFloat sourceH = CGRectGetHeight(source);
    if (sourceW < 40.0 || sourceH < 40.0) return;
    CGFloat stageW = CGRectGetWidth(root.bounds);
    CGFloat stageH = CGRectGetHeight(root.bounds);
    if (stageW < 80.0 || stageH < 80.0) return;

    // What the card actually shows of the root, in root space.
    CGRect visible = root.bounds;
    UIWindow *window = root.window;
    if (window) {
        CGRect v = CGRectIntersection([root convertRect:window.bounds fromView:window], root.bounds);
        if (!CGRectIsNull(v) && CGRectGetHeight(v) > 120.0 && CGRectGetWidth(v) > 80.0) visible = v;
    }
    CGFloat rootScale = sqrt(root.transform.a * root.transform.a + root.transform.c * root.transform.c);
    if (rootScale < 0.2 || rootScale > 2.0) rootScale = 1.0;
    CGFloat visTop = CGRectGetMinY(visible);
    CGFloat visBottom = CGRectGetMaxY(visible);

    CGFloat limit = visBottom - DSPhoneDialBottomMargin;
    UIView *tab = DSPhoneFindTabBar(root, 0);
    if (tab && tab != root && tab != keypad && ![keypad isDescendantOfView:tab]) {
        CGRect tabInRoot = [tab convertRect:tab.bounds toView:root];
        if (CGRectGetHeight(tabInRoot) > 20.0 && CGRectGetMinY(tabInRoot) > visTop + 120.0 &&
            CGRectGetMinY(tabInRoot) < visBottom + 1.0) {
            limit = CGRectGetMinY(tabInRoot) - DSPhoneDialBottomMargin;
        }
    }
    // Top of the band: below the status-bar strip + room for the LCD.
    CGFloat statusPad = DSPhoneStatusPad / rootScale;
    CGFloat lcdH = 0.0;
    if (lcd) lcdH = MIN(CGRectGetHeight(lcd.bounds), 72.0);
    CGFloat lcdReserve = lcd ? (lcdH + 4.0) : 30.0;
    CGFloat topBound = MAX(visTop, 0.0) + statusPad + lcdReserve;
    if (limit - topBound < 180.0) topBound = MAX(visTop + 8.0, limit - 180.0);
    CGFloat availW = MAX(40.0, CGRectGetWidth(visible) - 8.0);
    CGFloat availH = MAX(40.0, limit - topBound);

    // Column spread (positions only) = 4.5.645 width fill.
    CGFloat sx = availW / sourceW;
    if (sx < 0.45) sx = 0.45;
    if (sx > 1.75) sx = 1.75;
    // Row spread: whole pad height fits the visible band.
    CGFloat sy = availH / sourceH;
    if (sy < 0.35) sy = 0.35;
    if (sy > 1.75) sy = 1.75;
    // Key scale: uniform (round), a hair bigger than the row spread is OK —
    // it only eats into the gaps between rows.
    CGFloat k = MIN(sx, sy * 1.06);
    if (k < 0.32) k = 0.32;

    // Place every key; then shift the envelope so the bottom key sits on the
    // band bottom (just above the tabs) and nothing pokes above the band.
    CGFloat targetX = CGRectGetMidX(visible) - sourceW * sx / 2.0;
    NSUInteger n = keyViews.count;
    CGPoint *wants = (CGPoint *)calloc(MAX(n, (NSUInteger)1), sizeof(CGPoint));
    CGFloat envTop = CGFLOAT_MAX, envBottom = -CGFLOAT_MAX;
    for (NSUInteger i = 0; i < n; i++) {
        UIView *key = keyViews[i];
        CGRect natRoot = [key convertRect:key.bounds toView:root];
        CGPoint c = CGPointMake(targetX + (CGRectGetMidX(natRoot) - CGRectGetMinX(source)) * sx,
                                (CGRectGetMidY(natRoot) - CGRectGetMinY(source)) * sy);
        wants[i] = c;
        envTop = MIN(envTop, c.y - CGRectGetHeight(natRoot) * k / 2.0);
        envBottom = MAX(envBottom, c.y + CGRectGetHeight(natRoot) * k / 2.0);
    }
    CGFloat dy = limit - envBottom;
    if (envTop + dy < topBound - 0.5) {
        // Too tall with the key bump: drop to exact row spread.
        k = MIN(sx, sy);
        envTop = CGFLOAT_MAX; envBottom = -CGFLOAT_MAX;
        for (NSUInteger i = 0; i < n; i++) {
            UIView *key = keyViews[i];
            CGFloat h = CGRectGetHeight(key.bounds);
            envTop = MIN(envTop, wants[i].y - h * k / 2.0);
            envBottom = MAX(envBottom, wants[i].y + h * k / 2.0);
        }
        dy = limit - envBottom;
    }
    CGFloat padTop = envTop + dy;

    for (NSUInteger i = 0; i < n; i++) {
        UIView *key = keyViews[i];
        if (!key.superview) continue;
        for (UIView *ancestor = key.superview; ancestor && ancestor != root; ancestor = ancestor.superview) {
            ancestor.clipsToBounds = NO;
        }
        CGPoint wantRoot = CGPointMake(wants[i].x, wants[i].y + dy);
        CGPoint want = [root convertPoint:wantRoot toView:key.superview];
        CGPoint natural = key.center;
        // Uniform k on X and Y: circles stay circles.
        CGRect lift = CGRectMake(want.x - natural.x, want.y - natural.y, k, k);
        objc_setAssociatedObject(key, DSPhoneGridLiftKey, [NSValue valueWithCGRect:lift], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        DSPhoneApplyGridLift(key, natural);
        DSPhoneMarkGridPieces(key, 0);
    }
    free(wants);

    // Typed number: just above the pad, never under the status bar strip.
    if (lcd && lcd.superview) {
        CGRect nat = [lcd convertRect:lcd.bounds toView:root];
        CGFloat wantTop = padTop - 4.0 - CGRectGetHeight(nat);
        CGFloat minTop = MAX(visTop, 0.0) + statusPad;
        if (wantTop < minTop) wantTop = minTop;
        CGFloat ty = wantTop - CGRectGetMinY(nat);
        for (UIView *ancestor = lcd.superview; ancestor && ancestor != root; ancestor = ancestor.superview) {
            ancestor.clipsToBounds = NO;
        }
        lcd.transform = CGAffineTransformMakeTranslation(0.0, ty);
        objc_setAssociatedObject(lcd, DSPhoneLcdPlacedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        DSPhoneMarkGridPieces(lcd, 0); // header passes leave it alone
    } else {
        DSPhoneLiftNumberDisplay(root);
    }
    DSPhoneWriteFit([NSString stringWithFormat:@"app: phone pad fit646 k=%.2f sx=%.2f sy=%.2f keys=%ld vis=%.0f-%.0f band=%.0f-%.0f padTop=%.0f rootScale=%.2f lcd=%s",
                     k, sx, sy, (long)keys, visTop, visBottom, topBound, limit, padTop, rootScale,
                     lcd ? (object_getClassName(lcd) ?: "?") : "none"],
                    k, padTop, stageH);
}

static void DSAdjustPhoneLayoutForStage(UIView *root) {
    if (!DSIsMobilePhone() || !DSStaged() || !root || !root.superview || DSPhoneLayoutFrozen || DSClampingStage) return;
    // Runs after DSPhoneScaleRootIntoCard. Root.bounds stays the full-device
    // layout box; do not call DSPhoneApplyCardFrame here (would undo fill).
    if (CGRectGetWidth(root.bounds) < 80.0 || CGRectGetHeight(root.bounds) < 80.0) return;
    DSPhoneLayoutFrozen = YES;
    DSClampingStage = YES;
    UIView *keypad = nil;
    @try {
        // setNeedsLayout only. Forcing an immediate layout pass here runs while
        // conversation/layout is still on the stack and is a SIGTRAP (not catchable by @try).
        for (UIView *subview in root.subviews) {
            [subview setNeedsLayout];
        }
        DSPhonePullClippedTop(root);
        keypad = DSFindPhoneKeypadView(root);
    } @catch (NSException *exception) {
        keypad = nil;
    }
    DSClampingStage = NO;
    DSPhoneLayoutFrozen = NO;
    if (!keypad || keypad == root) return;
    // Defer keypad resize off this layout/scene callback turn.
    __weak UIView *weakKeypad = keypad;
    __weak UIView *weakRoot = root;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *strongKeypad = weakKeypad;
        UIView *strongRoot = weakRoot;
        if (!strongKeypad || !strongRoot || !strongKeypad.superview || !strongRoot.superview) return;
        if (!DSIsMobilePhone() || !DSStaged() || DSPhoneLayoutFrozen || DSClampingStage) return;
        DSPhoneLayoutFrozen = YES;
        DSClampingStage = YES;
        @try {
            DSResizePhoneKeypad(strongKeypad, strongRoot);
        } @catch (NSException *exception) {
        }
        DSClampingStage = NO;
        DSPhoneLayoutFrozen = NO;
    });
}

static void DSPhoneFindKeypad(UIView *view, NSInteger depth, UIView **best, CGFloat *bestArea) {
    if (!view || depth > 14 || !best || !bestArea) return;
    if ([view isKindOfClass:UIScrollView.class] || DSPhoneIsTabBar(view)) return;
    if (DSPhoneViewIsKeypad(view) || DSPhoneRoundCount(view, 0) >= 9) {
        CGFloat area = CGRectGetWidth(view.bounds) * CGRectGetHeight(view.bounds);
        if (area > 800.0 && (*best == nil || area < *bestArea)) {
            *best = view;
            *bestArea = area;
        }
    }
    for (UIView *subview in view.subviews) DSPhoneFindKeypad(subview, depth + 1, best, bestArea);
}

static UIView *DSPhoneFindTabBar(UIView *view, NSInteger depth) {
    if (!view || depth > 12) return nil;
    if (DSPhoneIsTabBar(view)) return view;
    if ([view isKindOfClass:UIScrollView.class]) return nil;
    for (UIView *subview in view.subviews) {
        UIView *found = DSPhoneFindTabBar(subview, depth + 1);
        if (found) return found;
    }
    return nil;
}

static void DSPhoneWriteFit(NSString *line, CGFloat scale, CGFloat box, CGFloat band) {
    if (line.length == 0) return;
    static NSString *last = nil;
    if ([last isEqualToString:line]) return;
    last = line;
    DSTrace(line);
    const char *text = [[line stringByAppendingString:@"\n"] UTF8String];
    if (text) {
        DSWriteFile("/var/tmp/com.recreated.dynamicstage.phone-fit", text);
        DSWriteFile("/var/jb/tmp/com.recreated.dynamicstage.phone-fit", text);
    }
    uint64_t state = DSIdentifierHash(NSBundle.mainBundle.bundleIdentifier ?: @"");
    NSUInteger scaleBits = (NSUInteger)lround(scale * 100.0);
    if (scaleBits > 255) scaleBits = 255;
    NSUInteger boxBits = (NSUInteger)lround(box);
    NSUInteger bandBits = (NSUInteger)lround(band);
    if (boxBits > 1023) boxBits = 1023;
    if (bandBits > 1023) bandBits = 1023;
    state |= ((uint64_t)scaleBits) << 32;
    state |= ((uint64_t)boxBits) << 40;
    state |= ((uint64_t)bandBits) << 50;
    static int token = NOTIFY_TOKEN_INVALID;
    if (token == NOTIFY_TOKEN_INVALID) {
        notify_register_check("com.recreated.dynamicstage.phone.fit", &token);
    }
    if (token != NOTIFY_TOKEN_INVALID) notify_set_state(token, state);
    notify_post("com.recreated.dynamicstage.phone.fit");
}

// The digits and Add Number are short labels. A tall spacer under them is the
// empty gap the keys need to move up into, so it does not count as the header.
static void DSPhoneNoteHeader(UIView *view, UIView *host, UIView *pad, CGFloat padTop, CGFloat *bottom, NSInteger depth) {
    if (!view || !host || !bottom || depth > 8 || view == pad || DSPhoneIsTabBar(view)) return;
    if ([view isKindOfClass:UIScrollView.class]) return;
    if (view != host && view.window) {
        CGRect frame = [view convertRect:view.bounds toView:host];
        CGFloat height = CGRectGetHeight(frame);
        CGFloat width = CGRectGetWidth(frame);
        if (CGRectGetMaxY(frame) <= padTop + 2.0 && width > 36.0 && height >= 14.0 && height <= 72.0) {
            *bottom = MAX(*bottom, CGRectGetMaxY(frame));
        }
    }
    for (UIView *subview in view.subviews) {
        DSPhoneNoteHeader(subview, host, pad, padTop, bottom, depth + 1);
    }
}

static void DSPhoneCollectRounds(UIView *view, NSMutableArray<UIView *> *buttons, NSInteger depth) {
    if (!view || !buttons || depth > 6 || DSPhoneIsTabBar(view)) return;
    if ([view isKindOfClass:UIScrollView.class]) return;
    for (UIView *subview in view.subviews) {
        CGFloat width = CGRectGetWidth(subview.bounds);
        CGFloat height = CGRectGetHeight(subview.bounds);
        if (width >= 36.0 && height >= 36.0 && width <= 170.0 && height <= 170.0 &&
            fabs(width - height) <= MAX(width, height) * 0.35) {
            [buttons addObject:subview];
        } else {
            DSPhoneCollectRounds(subview, buttons, depth + 1);
        }
    }
}

// The number keys were being laid out inside the pad, and the pad already
// sits in the bottom half of the card. Put the keys on the card itself,
// starting near the top, and hold that frame when Phone lays them out again.
static void DSPhoneFitCardRoot(UIView *root) {
    UIView *pad = nil;
    CGFloat padArea = 0.0;
    DSPhoneFindKeypad(root, 0, &pad, &padArea);
    if (!pad || pad.hidden || pad.alpha < 0.02 || !pad.window) {
        DSPhoneWriteFit(@"app: phone keypad not found", 0, 0, 0);
        return;
    }
    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    DSPhoneCollectRounds(pad, buttons, 0);
    if (buttons.count < 9) {
        for (UIView *subview in root.subviews) {
            if (objc_getAssociatedObject(subview, DSPhoneLiftFrameKey)) [buttons addObject:subview];
        }
    }
    if (buttons.count < 9) {
        DSPhoneWriteFit([NSString stringWithFormat:@"app: phone keypad %s buttons=%ld",
                         object_getClassName(pad) ?: "?", (long)buttons.count],
                        0, 0, 0);
        return;
    }
    CGFloat rootW = CGRectGetWidth(root.bounds);
    CGFloat rootH = CGRectGetHeight(root.bounds);
    UIView *tab = DSPhoneFindTabBar(root, 0);
    CGFloat tabTop = rootH - 4.0;
    if (tab && tab != root) {
        CGRect tabInRoot = [tab convertRect:tab.bounds toView:root];
        if (CGRectGetMinY(tabInRoot) > 40.0) tabTop = CGRectGetMinY(tabInRoot) - 4.0;
    }
    CGFloat wasTop = CGFLOAT_MAX;
    for (UIView *button in buttons) {
        CGRect inRoot = [button convertRect:button.bounds toView:root];
        wasTop = MIN(wasTop, CGRectGetMinY(inRoot));
    }
    [buttons sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        CGFloat ay = CGRectGetMidY([a convertRect:a.bounds toView:root]);
        CGFloat by = CGRectGetMidY([b convertRect:b.bounds toView:root]);
        if (fabs(ay - by) > 18.0) return ay < by ? NSOrderedAscending : NSOrderedDescending;
        CGFloat ax = CGRectGetMidX([a convertRect:a.bounds toView:root]);
        CGFloat bx = CGRectGetMidX([b convertRect:b.bounds toView:root]);
        if (fabs(ax - bx) < 1.0) return NSOrderedSame;
        return ax < bx ? NSOrderedAscending : NSOrderedDescending;
    }];
    NSInteger gridCount = MIN((NSInteger)buttons.count, 12);
    BOOL hasCall = buttons.count > 12;
    NSInteger rows = hasCall ? 5 : 4;
    NSInteger cols = 3;
    // Hard top. Do not follow the pad, or the keys stay in the lower half.
    CGFloat bandTop = 28.0;
    CGFloat side = 70.0;
    CGFloat gapY = 18.0;
    while (side > 52.0 && bandTop + rows * side + (rows - 1) * gapY > tabTop) side -= 2.0;
    if (bandTop + rows * side + (rows - 1) * gapY > tabTop) {
        gapY = 8.0;
        side = floor((tabTop - bandTop - (rows - 1) * gapY) / rows);
        if (side < 44.0) side = 44.0;
    }
    CGFloat gapX = MAX(22.0, (rootW - 12.0 - cols * side) / (cols + 1));
    CGFloat gridLeft = gapX;

    for (UIView *ancestor = pad; ancestor && ancestor != root.superview; ancestor = ancestor.superview) {
        ancestor.clipsToBounds = NO;
    }
    root.clipsToBounds = NO;
    DSPhoneLayoutFrozen = YES;
    DSClampingStage = YES;
    for (NSInteger index = 0; index < gridCount; index++) {
        UIView *button = buttons[index];
        NSInteger row = index / cols;
        NSInteger col = index % cols;
        CGRect target = CGRectMake(gridLeft + col * (side + gapX),
                                    bandTop + row * (side + gapY),
                                    side, side);
        if (button.superview != root) {
            if (!objc_getAssociatedObject(button, DSPhoneHomeKey) && button.superview) {
                objc_setAssociatedObject(button, DSPhoneHomeKey, button.superview, OBJC_ASSOCIATION_ASSIGN);
            }
            [root addSubview:button];
        }
        button.transform = CGAffineTransformIdentity;
        button.translatesAutoresizingMaskIntoConstraints = YES;
        button.autoresizingMask = UIViewAutoresizingNone;
        button.frame = target;
        objc_setAssociatedObject(button, DSPhoneLiftFrameKey, [NSValue valueWithCGRect:target], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (hasCall) {
        UIView *callButton = buttons[12];
        CGRect target = CGRectMake((rootW - side) * 0.5,
                                    bandTop + 4 * (side + gapY),
                                    side, side);
        if (callButton.superview != root) {
            if (!objc_getAssociatedObject(callButton, DSPhoneHomeKey) && callButton.superview) {
                objc_setAssociatedObject(callButton, DSPhoneHomeKey, callButton.superview, OBJC_ASSOCIATION_ASSIGN);
            }
            [root addSubview:callButton];
        }
        callButton.transform = CGAffineTransformIdentity;
        callButton.translatesAutoresizingMaskIntoConstraints = YES;
        callButton.autoresizingMask = UIViewAutoresizingNone;
        callButton.frame = target;
        objc_setAssociatedObject(callButton, DSPhoneLiftFrameKey, [NSValue valueWithCGRect:target], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    DSClampingStage = NO;
    DSPhoneLayoutFrozen = NO;
    DSPhoneWriteFit([NSString stringWithFormat:@"app: phone keys lifted %s n=%ld from=%.0f top=%.0f side=%.0f",
                     object_getClassName(pad) ?: "?",
                     (long)gridCount, wasTop, bandTop, side],
                    side / 80.0, wasTop, bandTop);
}

static BOOL DSPhoneIsCardRoot(UIView *view) {
    if (!DSIsMobilePhone() || !view || DSPhoneLayoutFrozen || DSClampingStage) return NO;
    UIWindow *window = [view isKindOfClass:UIWindow.class] ? (UIWindow *)view : view.window;
    if (!window || window.rootViewController.view != view) return NO;
    if (DSStaged()) return YES;
    CGFloat screenH = CGRectGetHeight(UIScreen.mainScreen.bounds);
    CGFloat windowH = CGRectGetHeight(window.bounds);
    return screenH > 200.0 && windowH > 80.0 && windowH < screenH * 0.72;
}

static void DSPhoneClearPieceTransforms(UIView *view) {
    if (!DSPhoneIsCardRoot(view)) return;
    // 4.5.644: only clear associated *piece* scales. Never set the card root
    // transform to identity here — that undoes DSPhoneScaleRootIntoCard and
    // leaves an oversized root top-aligned in the card (only dials 1–6 show).
    DSPhoneLayoutFrozen = YES;
    DSPhoneResetScaled(view, 0);
    DSPhoneLayoutFrozen = NO;
}

%hook UIView

- (void)layoutSubviews {
    UIView *view = (UIView *)self;
    DSPhoneClearPieceTransforms(view);
    %orig;
    DSFitPhoneAfterLayout(view);
    if (DSIsMobilePhone() && !DSPhoneLayoutFrozen && objc_getAssociatedObject(view, DSPhoneScaleKey)) {
        DSPhoneReapply(view);
    }
}

- (void)setFrame:(CGRect)frame {
    UIView *view = (UIView *)self;
    if ([view isKindOfClass:UIWindow.class] && DSShouldSkipDynamicStageForBeeper((UIWindow *)view)) {
        %orig(frame);
        return;
    }
    // Lifted dial grid: Phone lays it out at its natural frame. Take that
    // frame with identity transform, then put the uniform scale + lift back.
    if (DSIsMobilePhone() && !DSPhoneLayoutFrozen && DSPhoneHasGridLift(view)) {
        DSPhoneLayoutFrozen = YES;
        view.transform = CGAffineTransformIdentity;
        %orig(frame);
        DSPhoneLayoutFrozen = NO;
        DSPhoneApplyGridLift(view, view.center);
        return;
    }
    CGRect beeperBefore = view.frame;
    CGRect beeperAsked = frame;
    // SpringBoard owns Beeper's card. Do not fit, shift, or hold this frame.
    if (DSBeeperKeepsItsLayout()) {
        DSBeeperNoteQuickBar(@"frame", view, beeperBefore, beeperAsked);
        %orig(beeperAsked);
        return;
    }
    if (DSMessagesInputIsTransitioning(view, frame)) {
        %orig(frame);
        return;
    }
    if (DSStaged() && DSMessagesHoldsReplyBar() && !DSClampingStage) {
        NSString *name = NSStringFromClass(object_getClass(view));
        // The in-card keyboard is the one that takes taps. Hiding it here left
        // no keys at all: SpringBoard never drew a replacement.
        if (!DSNameIsLocalKeyboard(name)) {
            UIWindow *window = [view.superview isKindOfClass:UIWindow.class] ? (UIWindow *)view.superview : nil;
            BOOL root = window && !DSIsKeyboardWindow(window) && window.rootViewController.view == view;
            if (root) frame = DSMessagesHoldFrame(view, frame);
            frame = DSClampedEntryFrame(view, frame);
        }
    }
    // The reply field keeps the frame UIKit gave it. The conversation is moved
    // down to that frame after this returns.
    BOOL inputView = DSStaged() && !DSClampingStage && !DSDroppingStage &&
        DSViewIsCompatibilityInputView(view);
    frame = DSFrameForStagedView(view, frame);
    CGRect fitted = DSFittedStageFrame(view, frame);
    %orig(fitted);
    (void)inputView;
    if (DSIsMobilePhone() && !DSPhoneLayoutFrozen && objc_getAssociatedObject(view, DSPhoneScaleKey)) {
        DSPhoneReapply(view);
    }
}

- (void)setTransform:(CGAffineTransform)transform {
    UIView *view = (UIView *)self;
    if ([view isKindOfClass:UIWindow.class] && DSShouldSkipDynamicStageForBeeper((UIWindow *)view)) {
        %orig(transform);
        return;
    }
    if (DSBeeperKeepsItsLayout()) {
        CGFloat from = view.transform.ty;
        CGFloat to = transform.ty;
        if (fabs(to - from) >= 12.0) {
            NSString *name = DSBeeperShortClass(view);
            DSBeeperDebug([NSString stringWithFormat:@"ty|%@|%.0f", name, round((to - from) / 8.0) * 8.0],
                          [NSString stringWithFormat:@"transform %@ ty %.0f -> %.0f", name, from, to]);
            if (to < from - 8.0) {
                CGRect before = view.frame;
                CGRect after = CGRectOffset(before, 0, to - from);
                DSBeeperNoteQuickBar(@"transform", view, before, after);
            }
        }
    }
    %orig;
}

- (void)setCenter:(CGPoint)center {
    UIView *view = (UIView *)self;
    // Auto Layout moves the lifted dial grid back to its natural center; keep
    // the lift on top of whatever center Phone now wants.
    if (DSIsMobilePhone() && !DSPhoneLayoutFrozen && DSPhoneHasGridLift(view)) {
        DSPhoneLayoutFrozen = YES;
        %orig(center);
        DSPhoneLayoutFrozen = NO;
        DSPhoneApplyGridLift(view, center);
        return;
    }
    %orig(center);
}

- (UIEdgeInsets)safeAreaInsets {
    UIEdgeInsets insets = %orig;
    // The keyboard inset is what pulls Beeper's composer up inside the card.
    // The home indicator is much smaller and stays. Beeper is left alone:
    // SpringBoard already owns that card.
    return insets;
}

- (void)safeAreaInsetsDidChange {
    if (DSBeeperKeepsItsLayout()) {
        UIEdgeInsets insets = self.safeAreaInsets;
        if (insets.bottom > 24.0 || insets.top > 24.0) {
            NSString *name = DSBeeperShortClass((UIView *)self);
            DSBeeperDebug([NSString stringWithFormat:@"safe|%@|%.0f|%.0f", name, round(insets.top), round(insets.bottom)],
                          [NSString stringWithFormat:@"safe area %@ top=%.0f bottom=%.0f h=%.0f",
                           name, insets.top, insets.bottom, CGRectGetHeight(((UIView *)self).bounds)]);
        }
    }
    %orig;
}

- (void)setBounds:(CGRect)bounds {
    UIView *view = (UIView *)self;
    if ([view isKindOfClass:UIWindow.class] && DSShouldSkipDynamicStageForBeeper((UIWindow *)view)) {
        %orig(bounds);
        return;
    }
    if (DSBeeperKeepsItsLayout()) {
        %orig(bounds);
        return;
    }
    if (DSIsMobilePhone() && DSStaged()) {
        UIWindow *owning = [view isKindOfClass:UIWindow.class] ? (UIWindow *)view : view.window;
        if (!DSIsKeyboardWindow(owning)) {
            %orig(bounds);
            return;
        }
    }
    if (DSStaged() && !DSClampingStage && !DSViewIsStageShell(view)) {
        if ([view.superview isKindOfClass:UIWindow.class] &&
            !DSIsKeyboardWindow((UIWindow *)view.superview)) {
            CGRect stage = DSStageBounds();
            CGRect device = [DSStageContext sharedContext].deviceBounds;
            if (CGRectGetWidth(stage) > 80.0 && CGRectGetHeight(stage) > 80.0) {
                BOOL tall = DSFrameIsPhoneTall(bounds, device, stage) ||
                            CGRectGetHeight(bounds) > CGRectGetHeight(stage) + 24.0;
                BOOL wide = DSFrameIsPhoneWide(bounds, device, stage) ||
                            CGRectGetWidth(bounds) > CGRectGetWidth(stage) + 24.0;
                if (tall || wide) {
                    UIView *root = ((UIWindow *)view.superview).rootViewController.view;
                    CGRect dropped = (view == root) ? DSDroppedRectForRoot(view) : CGRectZero;
                    if (wide) {
                        bounds.size.width = CGRectGetWidth(dropped) > 80.0 ? CGRectGetWidth(dropped) : CGRectGetWidth(stage);
                    }
                    if (tall) {
                        bounds.size.height = CGRectGetHeight(dropped) > 80.0 ? CGRectGetHeight(dropped) : CGRectGetHeight(stage);
                    }
                    view.clipsToBounds = YES;
                }
            }
        }
    }
    %orig(bounds);
    if (DSIsMobilePhone() && !DSPhoneLayoutFrozen && objc_getAssociatedObject(view, DSPhoneScaleKey)) {
        DSPhoneReapply(view);
    }
}

- (void)setHidden:(BOOL)hidden {
    %orig;
}

- (void)didMoveToWindow {
    %orig;
}

- (void)didMoveToSuperview {
    %orig;
}

- (void)willMoveToWindow:(UIWindow *)newWindow {
    (void)newWindow;
    %orig;
}

- (void)didAddSubview:(UIView *)subview {
    %orig;
    if (!DSStaged() || !subview || DSIsBeeper()) return;
    NSString *name = NSStringFromClass(object_getClass(subview));
    if (DSNameIsHomeChrome(name)) {
        subview.hidden = YES;
        subview.alpha = 0.0;
        subview.userInteractionEnabled = NO;
        return;
    }
    if (DSNameIsKeyboardRemoteControl(name)) {
        DSLayoutKeyboardRemoteControlView(subview);
        return;
    }
    // Hiding these as they are added removes the keyboard before SpringBoard
    // has drawn one. They stay until that keyboard is on screen.
    if (DSMessagesLocalKeysHidden && DSNameIsLocalKeyboard(name)) {
        subview.hidden = YES;
        subview.alpha = 0.0;
        subview.userInteractionEnabled = NO;
    }
    if (DSMessagesLocalKeysHidden) DSStripKeyboardLayerHostView(subview);
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (DSMessagesKeepsOwnKeys() || !DSMessagesLocalKeysHidden) return %orig;
    UIView *view = (UIView *)self;
    if (DSStaged() && DSViewIsStageShell(view) && ![view isKindOfClass:UIWindow.class]) {
        UIView *hit = %orig;
        if (!hit || hit == view || DSHitViewIsKeyboardChrome(hit)) return nil;
        return hit;
    }
    if (DSStaged() && DSHitViewIsKeyboardChrome(view)) return nil;
    return %orig;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (DSMessagesKeepsOwnKeys() || !DSMessagesLocalKeysHidden) return %orig;
    UIView *view = (UIView *)self;
    if (DSStaged() && DSViewIsStageShell(view) && ![view isKindOfClass:UIWindow.class]) return %orig;
    if (DSStaged() && DSHitViewIsKeyboardChrome(view)) return NO;
    return %orig;
}

%end

%hook UIWindow

- (void)setFrame:(CGRect)frame {
    %orig(frame);
    @try {
        DSProcessWindow((UIWindow *)self);
    } @catch (NSException *exception) {
    }
}

- (void)setBounds:(CGRect)bounds {
    if (DSIsBeeperCard((UIWindow *)self)) {
        %orig(bounds);
        return;
    }
    %orig(bounds);
}

- (void)setTransform:(CGAffineTransform)transform {
    if (DSIsBeeperCard((UIWindow *)self)) {
        %orig(transform);
        return;
    }
    %orig(transform);
}

- (void)setAlpha:(CGFloat)alpha {
    if (DSIsBeeperCard((UIWindow *)self)) {
        %orig(alpha);
        return;
    }
    %orig(alpha);
}

- (void)setWindowLevel:(CGFloat)level {
    if (DSIsBeeperCard((UIWindow *)self)) {
        %orig(level);
        return;
    }
    %orig(level);
}

- (void)setHidden:(BOOL)hidden {
    // This process's remote keyboard window is the size of the card, so a
    // show paints the keys inside the stage. SpringBoard has the phone-width
    // keyboard. A nested show is left alone so this cannot chase itself.
    UIWindow *window = (UIWindow *)self;
    if (DSStaged() && !DSBeeperKeepsItsLayout() && !DSMessagesKeepsOwnKeys() && !hidden && DSIsRemoteKeyboardWindow(window)) {
        static BOOL inside = NO;
        if (!inside) {
            inside = YES;
            DSTraceInputOnce(@"hide-remote-window",
                             [NSString stringWithFormat:@"app hid %@ at %@. cause=this window is the card, and showing it draws the keys inside the stage",
                              NSStringFromClass(object_getClass(window)),
                              NSStringFromCGRect(window.frame)]);
            %orig(YES);
            inside = NO;
            return;
        }
    }
    %orig;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (DSBeeperKeepsItsLayout() || DSMessagesKeepsOwnKeys()) return %orig;
    if (!DSStaged() || !DSWindowIsKeyboardChrome(self)) return %orig;
    UIView *hit = %orig;
    if (DSStagedKeyboardHitBlocksContent(self, hit)) return nil;
    return hit;
}

%end

// UITextEffectsWindow inherits hitTest from UIAutoRotatingWindow, which does
// not call the UIWindow implementation above.
%hook UIAutoRotatingWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (DSBeeperKeepsItsLayout() || DSMessagesKeepsOwnKeys()) return %orig;
    if (!DSStaged() || !DSWindowIsKeyboardChrome((UIWindow *)self)) return %orig;
    // Messages holds the reply bar with the anchor. Refitting this window on a
    // tap clears that and the bar leaves the card.
    UIView *hit = %orig;
    if (DSStagedKeyboardHitBlocksContent((UIWindow *)self, hit)) return nil;
    return hit;
}

%end

// The other staged keyboards sit on the bottom edge of the phone, full width,
// at whatever height the keyboard already has. Messages' own keyboard is
// moved to that same rectangle. The card's position is not used. The reply
// bar and the app strip stay on the bottom of the card.
static NSInteger DSMessagesKeyboardLayoutDepth = 0;
static const CGFloat DSMessagesKeyboardWindowLevel = 9999999.0;

static CGRect DSMessagesPhoneWindowFrame(void) {
    CGRect device = [DSStageContext sharedContext].deviceBounds;
    if (CGRectGetWidth(device) < 300.0 || CGRectGetHeight(device) < 400.0) return CGRectNull;
    return CGRectMake(0.0, 0.0, CGRectGetWidth(device), CGRectGetHeight(device));
}

static void DSUnclipMessagesKeyboard(UIView *view) {
    UIView *cursor = view;
    while (cursor) {
        cursor.clipsToBounds = NO;
        cursor.layer.masksToBounds = NO;
        if ([cursor isKindOfClass:UIWindow.class]) break;
        cursor = cursor.superview;
    }
}

static BOOL DSViewIsMessagesKeySlab(UIView *view) {
    if (![view isKindOfClass:UIView.class]) return NO;
    NSString *name = NSStringFromClass(object_getClass(view));
    return [name hasPrefix:@"UIKeyboard"] || [name hasPrefix:@"UIKB"] || [name hasPrefix:@"TUIKeyboard"];
}

static void DSDockMessagesKeyboardTree(UIView *view, NSInteger depth) {
    if (!view || depth > 12 || !DSMessagesOwnsKeyboard()) return;
    // Leave the key views where UIKit laid them out. Moving UIKeyboard on its
    // own is what left the globe and dictation row off the key grid. The
    // phone-sized window already puts that whole keyboard on the bottom edge.
    if (DSViewIsMessagesKeySlab(view)) {
        if (DSMessagesFieldIsEditing || DSStageKeyboardWanted) {
            view.hidden = YES;
            view.alpha = 0.0;
            view.userInteractionEnabled = NO;
        } else {
            view.userInteractionEnabled = YES;
            view.hidden = NO;
            view.alpha = 1.0;
            DSUnclipMessagesKeyboard(view);
        }
        return;
    }
    for (UIView *subview in view.subviews) {
        DSDockMessagesKeyboardTree(subview, depth + 1);
    }
}

static BOOL DSMessagesInputChromeName(NSString *name) {
    if (name.length == 0) return NO;
    if ([name rangeOfString:@"MessageEntry"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"AppStrip"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"BrowserSwitcher"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"BrowserFooter"].location != NSNotFound) return YES;
    return NO;
}

// Messages parks the input bar and the app strip just off the bottom of the
// phone while it opens a conversation, the app strip, or the camera. A stage
// rewrite in that moment keeps the bar at that frame.
static BOOL DSMessagesInputFrameIsParkedOffScreen(CGRect frame) {
    CGFloat screenH = CGRectGetHeight(UIScreen.mainScreen.bounds);
    if (screenH < 400.0) return NO;
    return CGRectGetMinY(frame) >= screenH - 5.0;
}

static BOOL DSMessagesInputIsTransitioning(UIView *view, CGRect frame) {
    if (!DSStaged() || !DSMessagesOwnsKeyboard() || ![view isKindOfClass:UIView.class]) return NO;
    if (!DSMessagesInputChromeName(NSStringFromClass(object_getClass(view)))) return NO;
    if (DSMessagesInputFrameIsParkedOffScreen(frame)) return YES;
    if (DSMessagesInputFrameIsParkedOffScreen(view.frame)) return YES;
    return NO;
}

static BOOL DSMessagesChromeName(NSString *name) {
    if (name.length == 0) return NO;
    // The app strip only. A wider match pulled the globe up into the card.
    if ([name rangeOfString:@"AppStrip"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"BrowserSwitcher"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"BrowserFooter"].location != NSNotFound) return YES;
    return NO;
}

static BOOL DSMessagesAssistantName(NSString *name) {
    if (name.length == 0) return NO;
    if ([name rangeOfString:@"InputAssistant"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"Dictation"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"InputSwitcher"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"KeyboardDock"].location != NSNotFound) return YES;
    return NO;
}

static UIView *DSFindMessagesKeyboard(UIView *view, NSInteger depth) {
    if (!view || depth > 14) return nil;
    if (DSViewIsMessagesKeySlab(view) && CGRectGetHeight(view.bounds) >= 160.0) return view;
    UIView *best = nil;
    for (UIView *subview in view.subviews) {
        UIView *found = DSFindMessagesKeyboard(subview, depth + 1);
        if (!found) continue;
        if (!best || CGRectGetHeight(found.bounds) > CGRectGetHeight(best.bounds)) best = found;
    }
    return best;
}

// The globe and the microphone were drawn under the keys and again inside
// the card. Sit those loose controls on the bottom edge of the keyboard.
static void DSSeatAssistantOnKeyboard(UIView *root) {
    if (!DSMessagesTyping() || ![root isKindOfClass:UIView.class]) return;
    UIView *keys = DSFindMessagesKeyboard(root, 0);
    if (!keys) return;
    CGRect keysScreen = [keys convertRect:keys.bounds toView:nil];
    if (CGRectGetHeight(keysScreen) < 160.0) return;
    NSMutableArray<UIView *> *loose = [NSMutableArray array];
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view != keys && [view isDescendantOfView:keys]) continue;
        NSString *name = NSStringFromClass(object_getClass(view));
        if (view != root && DSMessagesAssistantName(name) && CGRectGetHeight(view.bounds) >= 18.0 &&
            CGRectGetHeight(view.bounds) <= 80.0) {
            CGRect screen = [view convertRect:view.bounds toView:nil];
            if (!CGRectIntersectsRect(CGRectInset(keysScreen, -4.0, -8.0), screen)) {
                [loose addObject:view];
            }
            continue;
        }
        for (UIView *subview in view.subviews) {
            if (subview != keys && ![subview isDescendantOfView:keys]) [stack addObject:subview];
        }
    }
    for (UIView *view in loose) {
        if (!view.superview) continue;
        CGPoint bottom = [keys convertPoint:CGPointMake(0.0, CGRectGetHeight(keys.bounds)) toView:view.superview];
        CGRect frame = view.frame;
        frame.origin.y = bottom.y - CGRectGetHeight(frame);
        if (fabs(frame.origin.y - view.frame.origin.y) < 1.0) continue;
        view.frame = frame;
    }
}

static void DSCollectMessagesChrome(UIView *view, NSMutableArray<UIView *> *found, NSInteger depth) {
    if (!view || depth > 14) return;
    if (depth > 0 && DSViewIsMessagesKeySlab(view)) return;
    NSString *name = NSStringFromClass(object_getClass(view));
    CGFloat height = CGRectGetHeight(view.bounds);
    CGFloat width = CGRectGetWidth(view.bounds);
    if (depth > 0 && DSMessagesChromeName(name) &&
        ![view isKindOfClass:UIScrollView.class] &&
        height >= 18.0 && height <= 240.0 && width >= 80.0) {
        [found addObject:view];
        return;
    }
    for (UIView *subview in view.subviews) DSCollectMessagesChrome(subview, found, depth + 1);
}

// The full-screen keyboard puts the quick bar on the bottom of the phone.
// Slide that bar back up as one piece so it stays inside the card, under the
// field. Views already inside the card are left where Messages put them.
static void DSKeepMessagesStripInCard(UIView *host) {
    if (![host isKindOfClass:UIView.class] || !DSMessagesOwnsKeyboard()) return;
    NSMutableArray<UIView *> *chrome = [NSMutableArray array];
    DSCollectMessagesChrome(host, chrome, 0);
    if (chrome.count == 0) return;
    for (UIView *view in chrome) {
        if (DSMessagesInputFrameIsParkedOffScreen(view.frame)) return;
        if (view.window) {
            CGRect onScreen = [view convertRect:view.bounds toView:nil];
            if (DSMessagesInputFrameIsParkedOffScreen(onScreen)) return;
        }
    }
    UIWindow *window = host.window;
    CGFloat cardH = CGRectGetHeight(DSStageBounds());
    BOOL typing = DSMessagesTyping() && window &&
        CGRectGetHeight(window.bounds) > cardH + 40.0;
    if (!typing || cardH < 80.0) {
        for (UIView *view in chrome) {
            if (fabs(view.transform.ty) > 0.5) view.transform = CGAffineTransformIdentity;
        }
        return;
    }
    CGFloat lowest = -CGFLOAT_MAX;
    for (UIView *view in chrome) {
        if (!view.superview) continue;
        CGFloat maxY = CGRectGetMaxY([view.superview convertRect:view.frame toView:window]);
        if (maxY > lowest) lowest = maxY;
    }
    if (lowest < -1000.0) return;
    CGFloat delta = cardH - lowest;
    if (delta >= -1.0) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (UIView *view in chrome) {
        CGAffineTransform transform = view.transform;
        transform.ty += delta;
        view.transform = transform;
    }
    [CATransaction commit];
}

static void DSHideDictationInTree(UIView *view, CGFloat cardH, BOOL typing, NSInteger depth) {
    if (!view || depth > 16) return;
    if (depth > 0 && DSViewIsMessagesKeySlab(view) && CGRectGetHeight(view.bounds) >= 160.0) return;
    NSString *name = NSStringFromClass(object_getClass(view));
    if (depth > 0 && DSMessagesAssistantName(name) && CGRectGetHeight(view.bounds) <= 80.0) {
        CGRect screen = view.window ? [view convertRect:view.bounds toView:nil] : view.frame;
        BOOL inCard = CGRectGetMaxY(screen) <= cardH + 24.0 && CGRectGetMinY(screen) > -40.0;
        if (inCard) view.hidden = typing;
        return;
    }
    for (UIView *subview in view.subviews) DSHideDictationInTree(subview, cardH, typing, depth + 1);
}

// Dictation left inside the card is the keyboard's control without the keys.
// Hide it while typing. The one on the keyboard, below the card, stays.
static void DSHideDictationLeftInCard(UIView *root) {
    if (!DSMessagesOwnsKeyboard() || ![root isKindOfClass:UIView.class]) return;
    DSHideDictationInTree(root, CGRectGetHeight(DSStageBounds()), DSMessagesTyping(), 0);
}

static void DSRaiseMessagesKeyboardWindow(UIWindow *window) {
    if (!DSMessagesTyping() || ![window isKindOfClass:UIWindow.class]) return;
    window.clipsToBounds = NO;
    window.layer.masksToBounds = NO;
    window.userInteractionEnabled = YES;
    if (window.hidden) window.hidden = NO;
    if (window.alpha < 0.99) window.alpha = 1.0;
    if (window.windowLevel < DSMessagesKeyboardWindowLevel) {
        window.windowLevel = DSMessagesKeyboardWindowLevel;
        DSTraceFormat(@"app Messages keyboard level %.0f frame %@",
                      window.windowLevel, NSStringFromCGRect(window.frame));
    }
}

%hook UITextEffectsWindow

- (void)layoutSubviews {
    if (DSIsBeeper()) {
        %orig;
        return;
    }
    if (DSMessagesOwnsKeyboard() && DSMessagesKeyboardLayoutDepth > 0) return;
    %orig;
    if (DSMessagesTyping()) {
        DSMessagesKeyboardLayoutDepth += 1;
        DSRaiseMessagesKeyboardWindow((UIWindow *)self);
        DSDockMessagesKeyboardTree((UIView *)self, 0);
        DSKeepMessagesStripInCard((UIView *)self);
        DSHideDictationLeftInCard((UIView *)self);
        DSMessagesKeyboardLayoutDepth -= 1;
        return;
    }
    if (DSStaged()) DSLayoutKeyboardRemoteControlsInTree(self, 0);
}

- (void)setFrame:(CGRect)frame {
    if (DSIsBeeper()) {
        %orig(frame);
        return;
    }
    // Messages' keyboard window is the phone, so the keys can sit on the same
    // bottom edge as the other staged keyboards. The reply bar is pinned back
    // onto the card after layout. Other apps keep the frame UIKit gave them.
    if (DSMessagesTyping()) {
        CGRect phone = DSMessagesPhoneWindowFrame();
        if (!CGRectIsNull(phone)) frame = phone;
    }
    %orig(frame);
    if (DSMessagesTyping()) DSRaiseMessagesKeyboardWindow((UIWindow *)self);
}

- (void)setBounds:(CGRect)bounds {
    if (DSMessagesTyping()) {
        CGRect phone = DSMessagesPhoneWindowFrame();
        if (!CGRectIsNull(phone)) bounds = phone;
    }
    %orig(bounds);
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!DSMessagesOwnsKeyboard()) return %orig;
    UIView *hit = %orig;
    if (!hit || hit == (UIView *)self) return nil;
    // The phone-sized input shell covers the card. A tap that did not land on
    // a key or the app strip has to fall through to the card.
    NSString *name = NSStringFromClass(object_getClass(hit));
    if ([name rangeOfString:@"InputSet"].location != NSNotFound ||
        [name rangeOfString:@"EditingOverlay"].location != NSNotFound) {
        CGRect device = [DSStageContext sharedContext].deviceBounds;
        if (CGRectGetHeight(hit.bounds) > CGRectGetHeight(device) * 0.7) return nil;
    }
    return hit;
}

- (void)didAddSubview:(UIView *)subview {
    %orig;
    if (!DSStaged() || !subview) return;
    if (DSNameIsKeyboardRemoteControl(NSStringFromClass(object_getClass(subview)))) {
        DSLayoutKeyboardRemoteControlView(subview);
    }
}

%end

// These three are the long rectangles in the view debugger. Each one implements
// its own setFrame:, so the UIView hook never sees the call. Force the card
// size before UIKit's implementation runs, and again after every layout.
static void DSShellLayout(UIView *view) {
    if (!DSStaged() || ![view isKindOfClass:UIView.class]) return;
    // Transform only. Resizing the shell from its layout is the conversation
    // push waiting on itself.
    DSTranslateComposersInHost(view);
}

static void DSShellSetBounds(UIView *view, CGRect bounds) {
    (void)bounds;
    DSShellLayout(view);
}

%hook UIInputSetContainerView

- (void)setFrame:(CGRect)frame {
    if (DSIsBeeper()) {
        %orig(frame);
        return;
    }
    %orig(DSMessagesHoldFrame((UIView *)self, DSFrameForStagedView((UIView *)self, frame)));
}

- (void)setBounds:(CGRect)bounds {
    %orig(bounds);
    DSShellSetBounds((UIView *)self, bounds);
}

- (void)layoutSubviews {
    %orig;
    DSShellLayout((UIView *)self);
}

%end

%hook UIInputSetHostView

- (void)setFrame:(CGRect)frame {
    if (DSIsBeeper()) {
        %orig(frame);
        return;
    }
    %orig(DSMessagesHoldFrame((UIView *)self, DSFrameForStagedView((UIView *)self, frame)));
}

- (void)setBounds:(CGRect)bounds {
    %orig(bounds);
    DSShellSetBounds((UIView *)self, bounds);
}

- (void)layoutSubviews {
    %orig;
    DSShellLayout((UIView *)self);
    if (DSMessagesOwnsKeyboard()) DSKeepMessagesStripInCard((UIView *)self);
}

%end

%hook UIEditingOverlayGestureView

- (void)setFrame:(CGRect)frame {
    if (DSIsBeeper()) {
        %orig(frame);
        return;
    }
    %orig(DSMessagesHoldFrame((UIView *)self, DSFrameForStagedView((UIView *)self, frame)));
}

- (void)setBounds:(CGRect)bounds {
    %orig(bounds);
    DSShellSetBounds((UIView *)self, bounds);
}

- (void)layoutSubviews {
    %orig;
    DSShellLayout((UIView *)self);
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (DSStaged()) return NO;
    return %orig;
}

%end

%hook UIKBVisualEffectView

- (UIEdgeInsets)safeAreaInsets {
    if (DSIsBeeper()) return %orig;
    if (DSStaged()) return UIEdgeInsetsZero;
    return %orig;
}

%end

%hook UIKeyboard

- (void)setFrame:(CGRect)frame {
    %orig(frame);
}

- (void)setHidden:(BOOL)hidden {
    if (DSMessagesKeepsOwnKeys()) {
        %orig;
        return;
    }
    // Keys in the text-effects window are the card copy. Keys in the plain
    // remote window are the ones at the bottom of the phone.
    UIView *view = (UIView *)self;
    if (DSIsBeeper()) {
        %orig;
        return;
    }
    if (DSStaged() && !hidden && DSHideKeysInThisWindow(view.window)) {
        static BOOL inside = NO;
        if (!inside) {
            inside = YES;
            %orig(YES);
            inside = NO;
            DSTraceInputOnce(@"hid-card-keys",
                             [NSString stringWithFormat:@"app hid %@ at %@ in %@. cause=this copy is inside the card. SpringBoard draws the phone-width keyboard",
                              NSStringFromClass(object_getClass(view)),
                              NSStringFromCGRect(view.frame),
                              view.window ? NSStringFromClass(object_getClass(view.window)) : @"no window"]);
            return;
        }
    }
    %orig;
}

- (void)didMoveToWindow {
    %orig;
    if (DSIsBeeper()) return;
    if (DSMessagesKeepsOwnKeys() && DSStaged()) {
        static NSInteger logs = 0;
        if (logs < 4) {
            logs += 1;
            UIView *view = (UIView *)self;
            DSTraceFormat(@"app in-card keys %@ hidden=%d",
                          NSStringFromCGRect(view.frame), view.hidden);
        }
        return;
    }
    if (!DSStaged()) return;
    UIView *view = (UIView *)self;
        if (!DSHideKeysInThisWindow(view.window)) return;
    view.alpha = 0.0;
    view.userInteractionEnabled = NO;
    if (!view.hidden) view.hidden = YES;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *view = (UIView *)self;
    if (DSIsBeeper()) return %orig;
    if (DSStaged() && !DSMessagesKeepsOwnKeys() && DSHideKeysInThisWindow(view.window)) return nil;
    return %orig;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *view = (UIView *)self;
    if (DSIsBeeper()) return %orig;
    if (DSStaged() && !DSMessagesKeepsOwnKeys() && DSHideKeysInThisWindow(view.window)) return NO;
    return %orig;
}

%end

%hook UIKeyboardRemoteControlView

- (void)didMoveToWindow {
    %orig;
    if (DSIsBeeper()) return;
    if (DSStaged()) DSLayoutKeyboardRemoteControlView(self);
}

- (void)layoutSubviews {
    %orig;
    if (DSIsBeeper()) return;
    if (DSStaged()) DSLayoutKeyboardRemoteControlView(self);
}

- (void)setFrame:(CGRect)frame {
    if (DSIsBeeper()) {
        %orig(frame);
        return;
    }
    if (DSStaged() && self.superview) {
        CGRect bounds = self.superview.bounds;
        CGFloat band = MIN(340.0, CGRectGetHeight(bounds));
        frame = CGRectMake(0.0, CGRectGetHeight(bounds) - band, CGRectGetWidth(bounds), band);
    }
    %orig;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return %orig;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return %orig;
}

%end

%hook UIKeyboardLayerHostView

- (instancetype)initWithFrame:(CGRect)frame {
    return %orig;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    return %orig;
}

- (void)didMoveToWindow {
    %orig;
    if (DSIsBeeper()) return;
    if (DSStaged() && DSHideKeysInThisWindow(self.window)) DSStripKeyboardLayerHostView(self);
}

- (void)layoutSubviews {
    %orig;
    if (DSIsBeeper()) return;
    if (DSStaged() && DSHideKeysInThisWindow(self.window)) DSStripKeyboardLayerHostView(self);
}

- (void)willMoveToSuperview:(UIView *)newSuperview {
    if (DSIsBeeper()) {
        %orig;
        return;
    }
    UIWindow *destination = newSuperview.window;
    if (DSStaged() && !DSMessagesKeepsOwnKeys() && newSuperview && DSHideKeysInThisWindow(destination)) {
        DSKillHostedKeyboardView(self);
        return;
    }
    %orig;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (DSIsBeeper()) return %orig;
    if (DSStaged() && !DSMessagesKeepsOwnKeys() && DSHideKeysInThisWindow(self.window)) return nil;
    return %orig;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (DSIsBeeper()) return %orig;
    if (DSStaged() && !DSMessagesKeepsOwnKeys() && DSHideKeysInThisWindow(self.window)) return NO;
    return %orig;
}

%end

%hook UIKeyboardWindow

- (void)setUserInteractionEnabled:(BOOL)enabled {
    if (DSIsBeeper()) {
        %orig(enabled);
        return;
    }
    if (DSStaged() && !DSMessagesKeepsOwnKeys()) %orig(NO);
    else %orig;
}

- (void)setHidden:(BOOL)hidden {
    if (DSIsBeeper()) {
        %orig(hidden);
        return;
    }
    if (DSStaged() && !DSMessagesKeepsOwnKeys()) %orig(YES);
    else %orig;
}

- (void)didMoveToWindow {
    %orig;
    if (DSIsBeeper()) return;
    if (DSStaged() && !DSMessagesKeepsOwnKeys()) {
        DSKillHostedKeyboardView(self);
        self.userInteractionEnabled = NO;
        self.hidden = YES;
    }
}

%end

%hook _UIRemoteKeyboardPlaceholderView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (DSIsBeeper()) return %orig;
    if (DSStaged() && !DSMessagesKeepsOwnKeys()) return nil;
    return %orig;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (DSIsBeeper()) return %orig;
    if (DSStaged() && !DSMessagesKeepsOwnKeys()) return NO;
    return %orig;
}

%end

%hook UIKeyboardImpl

// Keys drawn in this process land inside the card. The same answer the other
// staged apps use sends those keys to SpringBoard's keyboard. Reported once,
// so a layout pass cannot post another show.
+ (BOOL)isUsingRemoteKeyboard {
    // This has to be YES while the keyboard is created. Messages turns it on
    // only for the focus that replaces the in-card keyboard. The reply bar is
    // already anchored, so the conversation is not free to slide off the card.
    if (DSMessagesWantsRemoteKeyboard()) {
        DSRemoteImplAsks++;
        DSReportRemotePath(8, YES);
        return YES;
    }
    return %orig;
}

- (BOOL)isUsingRemoteKeyboard {
    if (DSMessagesWantsRemoteKeyboard()) {
        DSRemoteImplAsks++;
        DSReportRemotePath(8, YES);
        return YES;
    }
    return %orig;
}

+ (instancetype)sharedInstance {
    return %orig;
}

- (void)showKeyboard {
    if (DSMessagesOwnsKeyboard()) {
        if (!DSDeliveringStageKey) DSRequestSpringBoardKeyboard(YES);
        return;
    }
    if (DSStaged() && DSMessagesUsesStageKeyboard()) {
        if (!DSDeliveringStageKey) DSRequestSpringBoardKeyboard(YES);
        return;
    }
    %orig;
}

- (void)activate {
    %orig;
}

- (void)hideKeyboard {
    if (DSMessagesOwnsKeyboard()) {
        if (DSStageKeyboardWanted) return;
        %orig;
        return;
    }
    if (DSStaged() && DSMessagesUsesStageKeyboard() && DSStageKeyboardWanted) return;
    %orig;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *view = (UIView *)self;
    if (DSIsBeeper()) return %orig;
    if (DSStaged() && !DSMessagesKeepsOwnKeys() && DSHideKeysInThisWindow(view.window)) return nil;
    return %orig;
}

%end

// Messages moves the whole conversation when it hears a keyboard frame. The
// keys are SpringBoard's, below the card, so the frame inside this process
// has to say the keyboard is not covering the conversation.
// StageDuo rewrites the keyboard frame inside the notification. The height
// becomes what is left after the window, so Messages does not slide the
// thread for a keyboard that is not covering that window. The keys and the
// app strip still belong to Messages.
%hook NSNotificationCenter

- (void)postNotificationName:(NSString *)name object:(id)object userInfo:(NSDictionary *)userInfo {
    // SpringBoard draws the keys below the card. These notes only slide the
    // conversation and composer inside the staged app. Messages is the
    // exception: it has to hear the note so it can build the app strip, with
    // the height reduced the way StageDuo reduces it.
    BOOL keyboardNote = name.length > 0 &&
        ([name isEqualToString:UIKeyboardWillChangeFrameNotification] ||
         [name isEqualToString:UIKeyboardDidChangeFrameNotification] ||
         [name isEqualToString:UIKeyboardWillShowNotification] ||
         [name isEqualToString:UIKeyboardDidShowNotification] ||
         [name isEqualToString:UIKeyboardWillHideNotification] ||
         [name isEqualToString:UIKeyboardDidHideNotification]);
    // Messages lays the reply bar out from this frame. Delivering the phone
    // keyboard height pushes that bar off the bottom of the card.
    if (DSStaged() && keyboardNote) {
        NSValue *endValue = userInfo[UIKeyboardFrameEndUserInfoKey];
        CGRect end = [endValue isKindOfClass:NSValue.class] ? endValue.CGRectValue : CGRectZero;
        NSNumber *local = userInfo[UIKeyboardIsLocalUserInfoKey];
        NSString *kind = @"change";
        if ([name rangeOfString:@"Show"].location != NSNotFound) kind = @"show";
        else if ([name rangeOfString:@"Hide"].location != NSNotFound) kind = @"hide";
        DSShipKeyboardTrace([NSString stringWithFormat:@"kb %@ x=%.1f y=%.1f w=%.1f h=%.1f bundle=%@ local=%@",
                             kind,
                             end.origin.x, end.origin.y, end.size.width, end.size.height,
                             NSBundle.mainBundle.bundleIdentifier ?: @"?",
                             local ?: @"?"]);
        if (DSBeeperKeepsItsLayout()) {
            NSValue *endValue = userInfo[UIKeyboardFrameEndUserInfoKey];
            NSValue *beginValue = userInfo[UIKeyboardFrameBeginUserInfoKey];
            CGRect end = [endValue isKindOfClass:NSValue.class] ? endValue.CGRectValue : CGRectZero;
            CGRect begin = [beginValue isKindOfClass:NSValue.class] ? beginValue.CGRectValue : CGRectZero;
            NSNumber *local = userInfo[UIKeyboardIsLocalUserInfoKey];
            NSNumber *duration = userInfo[UIKeyboardAnimationDurationUserInfoKey];
            DSBeeperRememberKeyboard(end);
            DSBeeperDetailLogFormat(@"APP delivered %@ begin=%@ end=%@ local=%@ dur=%@",
                                    name,
                                    NSStringFromCGRect(begin),
                                    NSStringFromCGRect(end),
                                    local ?: @"?",
                                    duration ?: @"?");
            DSBeeperDetailSnapshot(name);
            %orig;
            return;
        }
        return;
    }
    if (DSIsBeeper() && keyboardNote) {
        NSValue *endValue = userInfo[UIKeyboardFrameEndUserInfoKey];
        CGRect end = [endValue isKindOfClass:NSValue.class] ? endValue.CGRectValue : CGRectZero;
        DSBeeperDetailLogFormat(@"APP heard %@ while not staged end=%@", name, NSStringFromCGRect(end));
    }
    %orig;
}

%end

// Key chrome only. The text-effects window and the reply bar stay where they are.
static void DSHideMessagesLocalKeyTree(UIView *view, NSInteger depth) {
    if (!view || depth > 18) return;
    NSString *name = NSStringFromClass(object_getClass(view));
    if (DSNameIsLocalKeyboard(name)) {
        view.hidden = YES;
        view.alpha = 0.0;
        view.userInteractionEnabled = NO;
        static NSInteger logs = 0;
        if (logs < 6) {
            logs += 1;
            DSTraceFormat(@"app hid keys %@", name);
        }
        return;
    }
    for (UIView *subview in [view.subviews copy]) {
        DSHideMessagesLocalKeyTree(subview, depth + 1);
    }
}

static void DSHideMessagesLocalKeys(void) {
    if (DSIsBeeper()) return;
    DSVisitLiveWindows(^(UIWindow *window) {
        if (DSIsPlainRemoteKeyboardWindow(window)) return;
        DSHideMessagesLocalKeyTree(window, 0);
    });
}

static void DSShowMessagesLocalKeyTree(UIView *view, NSInteger depth) {
    if (!view || depth > 18) return;
    NSString *name = NSStringFromClass(object_getClass(view));
    if (DSNameIsLocalKeyboard(name)) {
        view.hidden = NO;
        view.alpha = 1.0;
        view.userInteractionEnabled = YES;
    }
    for (UIView *subview in [view.subviews copy]) {
        DSShowMessagesLocalKeyTree(subview, depth + 1);
    }
}

static void DSShowMessagesLocalKeys(void) {
    DSVisitLiveWindows(^(UIWindow *window) {
        DSShowMessagesLocalKeyTree(window, 0);
    });
}

// Resigning the field released the only keyboard and the anchor froze the
// reply bar off the card. The field stays. SpringBoard shows the keyboard it
// already uses for the picker. In-card keys stay until that view is on screen.
static void DSPerformMessagesKeyboardHandoff(UIResponder *responder) {
    if (!responder || !DSStaged() || !DSMessagesChatOnScreen) return;
    if (!responder.isFirstResponder || !DSResponderTakesText(responder)) return;
    DSMessagesBarHeld = YES;
    DSMessagesPickerAsked = YES;
    DSPostPickerKeyboard(YES);
    DSTrace(@"app Messages asked SpringBoard for the keyboard");
}

// The conversation push focuses the field on the same turn that updates the
// scene. Asking SpringBoard for a keyboard inside that turn is what spun it.
// This waits until that update has finished. The field is not resigned.
static void DSScheduleMessagesKeyboardHandoff(UIResponder *responder) {
    if (!DSMessagesDrawsOwnKeyboard() || !DSStaged()) return;
    if (DSMessagesKeyboardHosted || DSMessagesHandoffInFlight) return;
    if (!DSMessagesChatOnScreen) return;
    if (CFAbsoluteTimeGetCurrent() < DSMessagesHandoffCooldownUntil) return;
    NSUInteger token = ++DSMessagesHandoffToken;
    CFAbsoluteTime ready = DSMessagesChatReadyAt;
    if (ready <= 0) ready = CFAbsoluteTimeGetCurrent() + 0.45;
    NSTimeInterval delay = ready - CFAbsoluteTimeGetCurrent();
    if (delay < 0.05) delay = 0.05;
    __weak UIResponder *weakField = responder;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (token != DSMessagesHandoffToken) return;
        if (!DSStaged() || !DSMessagesChatOnScreen || DSMessagesKeyboardHosted || DSMessagesHandoffInFlight) return;
        UIResponder *field = weakField;
        if (!field.isFirstResponder || !DSResponderTakesText(field)) field = DSCurrentKeyInput();
        if (!field || !DSResponderTakesText(field) || !field.isFirstResponder) {
            static NSInteger logs = 0;
            if (logs < 3) {
                logs += 1;
                DSTrace(@"app Messages keyboard waits for the field");
            }
            return;
        }
        DSPerformMessagesKeyboardHandoff(field);
    });
}

static void DSReleaseMessagesKeyboardHost(void) {
    if (!DSMessagesDrawsOwnKeyboard()) return;
    if (DSMessagesHandoffDepth > 0) return;
    // Leaving the conversation clears the chat flag first. A field resign while
    // the chat is still up is the in-card keyboard going away, and it must not
    // dismiss the keyboard SpringBoard is showing.
    if (DSMessagesChatOnScreen && DSMessagesPickerAsked) return;
    DSMessagesHandoffToken++;
    DSMessagesRemoteHooks = NO;
    DSMessagesDropsKeyboardNotes = NO;
    DSMessagesBarHeld = NO;
    if (DSMessagesLocalKeysHidden) {
        DSMessagesLocalKeysHidden = NO;
        DSShowMessagesLocalKeys();
    }
    if (DSMessagesPickerAsked) {
        DSMessagesPickerAsked = NO;
        DSPostPickerKeyboard(NO);
    }
    if (!DSMessagesKeyboardHosted) return;
    DSMessagesKeyboardHosted = NO;
    DSClearEntryAnchor();
    DSTrace(@"app released Messages keyboard");
}

static void DSNoteFieldFocused(UIResponder *responder) {
    if (!DSStaged() || !responder) return;
    if (DSMessagesOwnsKeyboard() && DSResponderTakesText(responder)) DSMessagesFieldIsEditing = YES;
    if (DSMessagesUsesStageKeyboard() && !DSMessagesOwnsKeyboard()) DSHoldComposer();
    UIResponder *held = responder;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (DSMessagesOwnsKeyboard()) {
            DSTrace(@"app Messages keeps its keyboard and app strip");
            return;
        }
        if (DSMessagesUsesStageKeyboard() && DSStaged()) {
            // After the remote keyboard has been asked for. Hiding these views
            // on the focus turn is what kept SpringBoard's keyboard at height 0.
            DSMessagesLocalKeysHidden = YES;
            DSHideMessagesLocalKeys();
        }
        UIView *view = [held isKindOfClass:UIView.class] ? (UIView *)held : nil;
        DSTraceInputLayout([NSString stringWithFormat:@"field focused %@", NSStringFromClass(object_getClass(held))], view);
    });
}

%hook UIResponder

- (BOOL)becomeFirstResponder {
    if (DSStaged() && DSResponderTakesText(self)) {
        DSTraceFormat(@"app become %@", NSStringFromClass(self.class));
    }
    DSPrepareMessagesForSpringBoardKeyboard(self);
    BOOL became = %orig;
    if (became && DSStaged() && DSResponderTakesText(self)) {
        DSShipKeyboardTrace([NSString stringWithFormat:@"focus %@ bundle=%@",
                             NSStringFromClass(self.class),
                             NSBundle.mainBundle.bundleIdentifier ?: @"?"]);
        if (DSMessagesUsesStageKeyboard()) DSArmStageKeyboard(self);
        DSNoteFieldFocused(self);
        DSReportRemotePath(9, YES);
        DSRememberKeyboardTarget(self);
    }
    return became;
}

- (BOOL)resignFirstResponder {
    BOOL wasEditing = self.isFirstResponder;
    if (wasEditing && DSStaged() && DSResignIsSystemDeactivation() && !DSResignIsSearchCancel()) {
        DSRememberKeyboardTarget(self);
        DSShipKeyboardTrace(@"kept field during a call");
        return NO;
    }
    if (wasEditing && DSKeepComposer(self)) {
        DSRememberKeyboardTarget(self);
        return NO;
    }
    if (wasEditing && DSStaged()) DSAllowKeyboardHide = YES;
    BOOL resigned = %orig;
    DSAllowKeyboardHide = NO;
    if (wasEditing && resigned && DSStaged() && DSResponderTakesText(self) && !DSDeliveringStageKey) {
        if (DSMessagesOwnsKeyboard()) DSMessagesFieldIsEditing = NO;
        DSReleaseMessagesKeyboardHost();
        DSReleaseComposer();
        DSNoteStageKeyboardResign(self);
    }
    return resigned;
}

%end

%hook UITextField

- (UIView *)inputView {
    if (DSBeeperKeepsItsLayout()) return %orig;
    if (DSMessagesOwnsKeyboard() && DSStageKeyboardWanted) return DSMessagesBlankInputView();
    if (DSStaged() && DSMessagesUsesStageKeyboard() && DSStageKeyboardWanted) {
        return DSMessagesBlankInputView();
    }
    return %orig;
}

- (BOOL)becomeFirstResponder {
    if (DSStaged()) {
        DSTraceFormat(@"app become %@", NSStringFromClass(self.class));
    }
    DSPrepareMessagesForSpringBoardKeyboard(self);
    BOOL became = %orig;
    if (became && DSStaged()) {
        if (DSMessagesUsesStageKeyboard()) DSArmStageKeyboard(self);
        DSNoteFieldFocused(self);
        DSReportRemotePath(9, YES);
        DSRememberKeyboardTarget(self);
    }
    return became;
}

- (BOOL)resignFirstResponder {
    BOOL wasEditing = self.isFirstResponder;
    if (wasEditing && DSStaged() && DSResignIsSystemDeactivation() && !DSResignIsSearchCancel()) {
        DSRememberKeyboardTarget(self);
        DSShipKeyboardTrace(@"kept field during a call");
        return NO;
    }
    if (wasEditing && DSKeepComposer(self)) {
        DSRememberKeyboardTarget(self);
        return NO;
    }
    if (wasEditing && DSStaged()) DSAllowKeyboardHide = YES;
    BOOL resigned = %orig;
    DSAllowKeyboardHide = NO;
    if (wasEditing && resigned && DSStaged() && !DSDeliveringStageKey) {
        if (DSMessagesOwnsKeyboard()) DSMessagesFieldIsEditing = NO;
        DSReleaseMessagesKeyboardHost();
        DSReleaseComposer();
        DSNoteStageKeyboardResign(self);
    }
    return resigned;
}

%end

%hook UITextView

- (UIView *)inputView {
    if (DSBeeperKeepsItsLayout()) return %orig;
    if (DSMessagesOwnsKeyboard() && DSStageKeyboardWanted) return DSMessagesBlankInputView();
    if (DSStaged() && DSMessagesUsesStageKeyboard() && DSStageKeyboardWanted) {
        return DSMessagesBlankInputView();
    }
    return %orig;
}

- (BOOL)becomeFirstResponder {
    if (DSStaged()) {
        DSTraceFormat(@"app become %@", NSStringFromClass(self.class));
    }
    DSPrepareMessagesForSpringBoardKeyboard(self);
    BOOL became = %orig;
    if (became && DSStaged()) {
        if (DSMessagesUsesStageKeyboard()) DSArmStageKeyboard(self);
        DSNoteFieldFocused(self);
        DSReportRemotePath(9, YES);
        DSRememberKeyboardTarget(self);
    }
    return became;
}

- (BOOL)resignFirstResponder {
    BOOL wasEditing = self.isFirstResponder;
    if (wasEditing && DSStaged() && DSResignIsSystemDeactivation() && !DSResignIsSearchCancel()) {
        DSRememberKeyboardTarget(self);
        DSShipKeyboardTrace(@"kept field during a call");
        return NO;
    }
    if (wasEditing && DSKeepComposer(self)) {
        DSRememberKeyboardTarget(self);
        return NO;
    }
    if (wasEditing && DSStaged()) DSAllowKeyboardHide = YES;
    BOOL resigned = %orig;
    DSAllowKeyboardHide = NO;
    if (wasEditing && resigned && DSStaged() && !DSDeliveringStageKey) {
        if (DSMessagesOwnsKeyboard()) DSMessagesFieldIsEditing = NO;
        DSReleaseMessagesKeyboardHost();
        DSReleaseComposer();
        DSNoteStageKeyboardResign(self);
    }
    return resigned;
}

%end

// A keyboard-sized inset on the transcript pushes the thread off the card.
// Scrolling to the latest message is a long jump and has to go through.
%hook UIScrollView

- (void)setContentInset:(UIEdgeInsets)inset {
    if (DSBeeperKeepsItsLayout()) {
        %orig(inset);
        return;
    }
    if (DSStaged() && DSMessagesHoldsReplyBar()) {
        UIEdgeInsets old = self.contentInset;
        BOOL keyboardTop = inset.top > old.top + 140.0;
        BOOL keyboardBottom = inset.bottom > old.bottom + 140.0;
        if (keyboardTop) inset.top = old.top;
        if (keyboardBottom) inset.bottom = old.bottom;
    }
    %orig(inset);
}

%end

// Beeper pins its composer to the keyboard. Messages may move its own bar.
// Beeper's guide stays on the bottom edge of the card.
%hook UILayoutGuide

- (CGRect)layoutFrame {
    CGRect frame = %orig;
    if (DSBeeperKeepsItsLayout()) return frame;
    return frame;
}

%end

%hook UIViewController

- (void)setAdditionalSafeAreaInsets:(UIEdgeInsets)insets {
    if (DSBeeperKeepsItsLayout()) {
        %orig(insets);
        return;
    }
    if (DSStaged() && DSMessagesHoldsReplyBar() &&
        (insets.top > 20.0 || insets.bottom > 20.0)) {
        insets = UIEdgeInsetsZero;
    }
    %orig(insets);
}

%end

#pragma mark - Presentation

// Full screen presentations measure themselves against the screen, so they need
// the same answer the windows now give.
%hook _UIFullscreenPresentationController

- (CGRect)frameOfPresentedViewInContainerView {
    CGRect frame = %orig;
    if (DSBeeperKeepsItsLayout()) return frame;
    if (!DSStaged()) return frame;
    CGRect stage = DSStageBounds();
    frame.origin = CGPointZero;
    frame.size = stage.size;
    return frame;
}

%end

#pragma mark - Per-app fixes

// Twitter pins a container to the portrait screen bounds it captured at launch
// and shows toasts in their own screen-sized window.
%hook TFNPortraitScreenBoundsLockedContainerView

- (void)layoutSubviews {
    if (DSStaged()) self.frame = DSStageBounds();
    %orig;
}

%end

%hook TFNToastWindow

- (void)setFrame:(CGRect)frame {
    if (DSStaged()) frame = DSStageBounds();
    %orig;
}

%end

// TikTok's feed sizes its cells once against the screen and caches the result,
// so it has to be told to measure again after the stage resizes it.
%hook AWEFeedTableView

- (void)layoutSubviews {
    %orig;
    if (!DSStaged()) return;

    NSValue *previous = objc_getAssociatedObject(self, _cmd);
    CGSize size = self.bounds.size;
    if (previous && CGSizeEqualToSize(previous.CGSizeValue, size)) return;
    objc_setAssociatedObject(self, _cmd, [NSValue valueWithCGSize:size], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (previous && [self respondsToSelector:@selector(reloadData)]) {
        [(UITableView *)self reloadData];
    }
}

%end

static CGFloat DSMessagesWidth(CGFloat original) {
    if (!DSStaged()) return original;
    CGFloat width = CGRectGetWidth(DSStageBounds());
    return width > 80.0 ? width : original;
}

static CGFloat DSMessagesHeight(CGFloat original) {
    if (!DSStaged()) return original;
    CGFloat height = CGRectGetHeight(DSStageBounds());
    return height > 80.0 ? height : original;
}

// ChatKit sizes the thread, the column, and previews from these. Phone
// Messages overrides them on CKUIBehaviorPhone, so a hook on the base class
// never runs. Each class that implements a getter is hooked on its own.
typedef CGFloat (*DSBehaviorMsg)(id, SEL);
typedef CGFloat (*DSBehaviorOrientMsg)(id, SEL, NSInteger);

typedef struct {
    Class cls;
    DSBehaviorMsg transcriptWidth;
    DSBehaviorMsg transcriptHeight;
    DSBehaviorMsg columnWidth;
    DSBehaviorOrientMsg columnWidthForOrientation;
    DSBehaviorMsg previewWidth;
} DSBehaviorSlot;

static DSBehaviorSlot DSBehaviorSlots[6];
static int DSBehaviorSlotCount = 0;

static CGFloat DSHookTranscriptWidth(id self, SEL cmd) {
    for (Class cls = object_getClass(self); cls; cls = class_getSuperclass(cls)) {
        for (int i = 0; i < DSBehaviorSlotCount; i++) {
            if (DSBehaviorSlots[i].cls == cls && DSBehaviorSlots[i].transcriptWidth) {
                return DSMessagesWidth(DSBehaviorSlots[i].transcriptWidth(self, cmd));
            }
        }
    }
    return DSMessagesWidth(0);
}

static CGFloat DSHookTranscriptHeight(id self, SEL cmd) {
    for (Class cls = object_getClass(self); cls; cls = class_getSuperclass(cls)) {
        for (int i = 0; i < DSBehaviorSlotCount; i++) {
            if (DSBehaviorSlots[i].cls == cls && DSBehaviorSlots[i].transcriptHeight) {
                return DSMessagesHeight(DSBehaviorSlots[i].transcriptHeight(self, cmd));
            }
        }
    }
    return DSMessagesHeight(0);
}

static CGFloat DSHookColumnWidth(id self, SEL cmd) {
    for (Class cls = object_getClass(self); cls; cls = class_getSuperclass(cls)) {
        for (int i = 0; i < DSBehaviorSlotCount; i++) {
            if (DSBehaviorSlots[i].cls == cls && DSBehaviorSlots[i].columnWidth) {
                return DSMessagesWidth(DSBehaviorSlots[i].columnWidth(self, cmd));
            }
        }
    }
    return DSMessagesWidth(0);
}

static CGFloat DSHookColumnWidthForOrientation(id self, SEL cmd, NSInteger orientation) {
    for (Class cls = object_getClass(self); cls; cls = class_getSuperclass(cls)) {
        for (int i = 0; i < DSBehaviorSlotCount; i++) {
            if (DSBehaviorSlots[i].cls == cls && DSBehaviorSlots[i].columnWidthForOrientation) {
                return DSMessagesWidth(DSBehaviorSlots[i].columnWidthForOrientation(self, cmd, orientation));
            }
        }
    }
    return DSMessagesWidth(0);
}

static CGFloat DSHookPreviewWidth(id self, SEL cmd) {
    CGFloat original = 0;
    BOOL found = NO;
    for (Class cls = object_getClass(self); cls && !found; cls = class_getSuperclass(cls)) {
        for (int i = 0; i < DSBehaviorSlotCount; i++) {
            if (DSBehaviorSlots[i].cls == cls && DSBehaviorSlots[i].previewWidth) {
                original = DSBehaviorSlots[i].previewWidth(self, cmd);
                found = YES;
                break;
            }
        }
    }
    if (!DSStaged()) return original;
    CGFloat width = CGRectGetWidth(DSStageBounds());
    if (width < 80.0) return original;
    return original > 0.0 ? MIN(original, width) : width;
}

static BOOL DSClassImplements(Class cls, SEL sel) {
    if (!cls || !sel) return NO;
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;
    Class supercls = class_getSuperclass(cls);
    if (!supercls) return YES;
    return method != class_getInstanceMethod(supercls, sel);
}

static void DSReplaceMethod(Class cls, SEL sel, IMP hook, IMP *orig) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    IMP previous = method_setImplementation(method, hook);
    if (orig) *orig = previous;
}

static void DSInstallMessagesBehaviorHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *names[] = {
            "CKUIBehavior", "CKUIBehaviorPhone", "CKUIBehaviorPad", "CKUIBehaviorMac", "CKUIBehaviorHUD", NULL
        };
        for (int n = 0; names[n] && DSBehaviorSlotCount < 6; n++) {
            Class cls = objc_getClass(names[n]);
            if (!cls) continue;
            DSBehaviorSlot *slot = &DSBehaviorSlots[DSBehaviorSlotCount];
            memset(slot, 0, sizeof(*slot));
            slot->cls = cls;
            if (DSClassImplements(cls, @selector(maxTranscriptPortraitWidth))) {
                DSReplaceMethod(cls, @selector(maxTranscriptPortraitWidth), (IMP)DSHookTranscriptWidth, (IMP *)&slot->transcriptWidth);
            }
            if (DSClassImplements(cls, @selector(maxTranscriptPortraitHeight))) {
                DSReplaceMethod(cls, @selector(maxTranscriptPortraitHeight), (IMP)DSHookTranscriptHeight, (IMP *)&slot->transcriptHeight);
            }
            if (DSClassImplements(cls, @selector(maxPrimaryColumnWidth))) {
                DSReplaceMethod(cls, @selector(maxPrimaryColumnWidth), (IMP)DSHookColumnWidth, (IMP *)&slot->columnWidth);
            }
            if (DSClassImplements(cls, @selector(maxPrimaryColumnWidthForInterfaceOrientation:))) {
                DSReplaceMethod(cls, @selector(maxPrimaryColumnWidthForInterfaceOrientation:), (IMP)DSHookColumnWidthForOrientation, (IMP *)&slot->columnWidthForOrientation);
            }
            if (DSClassImplements(cls, @selector(previewMaxWidth))) {
                DSReplaceMethod(cls, @selector(previewMaxWidth), (IMP)DSHookPreviewWidth, (IMP *)&slot->previewWidth);
            }
            if (slot->transcriptWidth || slot->transcriptHeight || slot->columnWidth ||
                slot->columnWidthForOrientation || slot->previewWidth) {
                DSBehaviorSlotCount += 1;
            }
        }
    });
}

%hook UICompatibilityInputViewController

- (void)viewWillLayoutSubviews {
    %orig;
}

- (void)viewDidLayoutSubviews {
    %orig;
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
}

%end

// The input window is the keyboard scene. Forcing it to the card draws the
// keys inside the stage and nests that scene update inside the conversation push.
@interface UIInputWindowController : UIViewController
- (void)updateRootViewConstraintsForSceneFrame:(CGRect)sceneFrame bounds:(CGRect)bounds;
- (void)hostAppSceneBoundsChanged;
- (CGRect)_boundsForOrientation:(NSInteger)orientation;
- (CGRect)_defaultInitialViewFrame;
- (CGRect)_viewFrameInWindowForContentOverlayInsetsCalculation;
- (UIEdgeInsets)_viewSafeAreaInsetsFromScene;
@end

%hook UIInputWindowController

- (void)updateRootViewConstraintsForSceneFrame:(CGRect)sceneFrame bounds:(CGRect)bounds {
    %orig(sceneFrame, bounds);
}

- (CGRect)_boundsForOrientation:(NSInteger)orientation {
    return %orig;
}

- (CGRect)_defaultInitialViewFrame {
    return %orig;
}

- (CGRect)_viewFrameInWindowForContentOverlayInsetsCalculation {
    return %orig;
}

- (UIEdgeInsets)_viewSafeAreaInsetsFromScene {
    return %orig;
}

- (void)hostAppSceneBoundsChanged {
    %orig;
}

- (void)updateViewConstraints {
    %orig;
}

- (void)viewDidLayoutSubviews {
    if (DSStaged()) DSTrace(@"app input window laid out");
    %orig;
}

%end

@interface UIInputWindowControllerHosting : NSObject
- (void)updateViewConstraints;
@end

%hook UIInputWindowControllerHosting

- (void)updateViewConstraints {
    %orig;
}

%end

%hook CKMessageEntryView

- (BOOL)shouldShowAppStrip {
    // StageDuo shows this strip with the phone-sized keyboard, under the
    // field. Forcing it on while the field is editing drew it above the field.
    return %orig;
}

- (UIEdgeInsets)safeAreaInsets {
    if (!DSStaged()) return %orig;
    UIEdgeInsets insets = %orig;
    // The inset from the tap is the home indicator. Anything added after that
    // is the keyboard, and it drops the bar down the card.
    if (DSMessagesHoldsReplyBar() && DSEntryAnchorValid &&
        (UIView *)self == DSEntryAnchorView) {
        insets.bottom = DSEntryAnchorBottomInset;
    } else if (DSMessagesHoldsReplyBar() && insets.bottom > 120.0) {
        insets.bottom = 0.0;
    }
    return insets;
}

- (void)setBounds:(CGRect)bounds {
    if (DSMessagesInputIsTransitioning((UIView *)self, CGRectMake(0, 0, CGRectGetWidth(bounds), CGRectGetHeight(bounds)))) {
        %orig(bounds);
        return;
    }
    if (DSStaged() && DSMessagesHoldsReplyBar() &&
        DSEntryAnchorValid && (UIView *)self == DSEntryAnchorView) {
        CGFloat anchorH = CGRectGetHeight(DSEntryAnchorFrame);
        if (anchorH > 20.0 && CGRectGetHeight(bounds) > anchorH + 0.5 && DSEntryHoldOpen()) {
            bounds.size.height = anchorH;
        }
    }
    %orig(bounds);
}

- (void)setCenter:(CGPoint)center {
    if (DSMessagesInputFrameIsParkedOffScreen(CGRectMake(center.x, center.y, 0, 0)) &&
        DSMessagesOwnsKeyboard() && DSStaged()) {
        %orig(center);
        return;
    }
    if (DSStaged() && DSMessagesHoldsReplyBar() &&
        DSEntryAnchorValid && (UIView *)self == DSEntryAnchorView) {
        CGFloat anchorY = CGRectGetMidY(DSEntryAnchorFrame);
        if (center.y > anchorY + 0.5 && DSEntryHoldOpen()) center.y = anchorY;
    }
    %orig(center);
}

- (void)setFrame:(CGRect)frame {
    if (DSMessagesInputIsTransitioning((UIView *)self, frame)) {
        %orig(frame);
        return;
    }
    static NSInteger depth = 0;
    if (depth > 0) {
        %orig(frame);
        return;
    }
    depth += 1;
    %orig(frame);
    if (DSReplyBarMayMove) DSPullMessageBarUp(self);
    depth -= 1;
}

- (void)layoutSubviews {
    static NSInteger layoutDepth = 0;
    if (layoutDepth > 0) {
        %orig;
        return;
    }
    layoutDepth += 1;
    %orig;
    if (DSReplyBarMayMove) DSPullMessageBarUp(self);
    layoutDepth -= 1;
}

%end

// Safari view service lays its navigation bar out from the screen width.
%hook _SFBrowserNavigationBar

- (void)layoutSubviews {
    if (DSStaged()) {
        CGRect frame = self.frame;
        frame.size.width = CGRectGetWidth(DSStageBounds());
        self.frame = frame;
    }
    %orig;
}

%end

#pragma mark - Remote keyboard

// iOS 16 draws a hosted app's keys with UIRemoteKeyboardWindowHosted, which
// lives in that app's scene, so the card shows them. The plain remote keyboard
// window is the one SpringBoard already uses for the picker, on the
// remote-keyboard scene. Nothing here hides a view, moves a window, or talks
// to the arbiter.
%group RemoteKeys

%hook _UIRemoteKeyboards

+ (BOOL)wantsUnassociatedWindowSceneForKeyboardWindow {
    if (DSMessagesWantsRemoteKeyboard()) {
        DSRemoteSceneAsks++;
        DSReportRemotePath(2, YES);
        return YES;
    }
    return %orig;
}

- (Class)keyboardWindowClass {
    Class chosen = %orig;
    if (!DSMessagesWantsRemoteKeyboard()) return chosen;
    Class hosted = objc_getClass("UIRemoteKeyboardWindowHosted");
    Class plain = objc_getClass("UIRemoteKeyboardWindow");
    DSReportRemotePath(1, YES);
    if (plain && hosted && chosen == hosted) return plain;
    return chosen;
}

- (void)addHostedWindowView:(id)view fromPID:(int)pid forScene:(id)scene {
    if (DSMessagesWantsRemoteKeyboard()) {
        DSReportRemotePath(4, YES);
        NSString *viewName = [view isKindOfClass:UIView.class] ? NSStringFromClass([view class]) : @"nil";
        CGRect frame = [view isKindOfClass:UIView.class] ? ((UIView *)view).frame : CGRectZero;
        DSTraceInputOnce(@"install-hosted-keys",
                         [NSString stringWithFormat:@"app installed keyboard view %@ frame=%@ pid=%d. cause=dropping this view left SpringBoard with no keys",
                          viewName, NSStringFromCGRect(frame), pid]);
        (void)scene;
    }
    %orig;
}

%end

%hook UIInputViewSet

- (void)setIsRemoteKeyboard:(BOOL)remote {
    if (DSStaged() && !remote && DSMessagesWantsRemoteKeyboard()) {
        static BOOL inside = NO;
        if (!inside) {
            inside = YES;
            DSReportRemotePath(6, YES);
            %orig(YES);
            inside = NO;
            return;
        }
    }
    %orig;
}

- (BOOL)isRemoteKeyboard {
    if (DSMessagesWantsRemoteKeyboard()) {
        DSReportRemotePath(6, YES);
        return YES;
    }
    return %orig;
}

%end

%end

#pragma mark - Entry point

static void DSInstallRemoteKeyboardHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class remote = objc_getClass("_UIRemoteKeyboards");
        Class inputSet = objc_getClass("UIInputViewSet");
        if (!remote || !inputSet) {
            DSReportRemoteMissing();
            return;
        }
        %init(RemoteKeys);
        DSReportRemoteArmed();
    });
}

static void DSOnSpringBoardKeyboardShown(void) {
    static int token = NOTIFY_TOKEN_INVALID;
    if (token == NOTIFY_TOKEN_INVALID) {
        notify_register_check(kDSKeyboardShownNotification, &token);
    }
    if (token == NOTIFY_TOKEN_INVALID) return;
    uint64_t state = 0;
    notify_get_state(token, &state);
    uint32_t hash = DSIdentifierHash(NSBundle.mainBundle.bundleIdentifier ?: @"");
    if ((uint32_t)state != hash) return;
    BOOL shown = (state & kDSStageStateActiveBit) != 0;
    if (!DSStaged()) return;
    if (DSMessagesOwnsKeyboard()) return;
    if (!DSMessagesDrawsOwnKeyboard()) {
        // SpringBoard has the full keyboard. The copy inside the card can go.
        // Doing this earlier hides the only keys, and SpringBoard never draws any.
        if (shown) {
            // The plain remote window stays. The copy in the text-effects
            // window is the one inside the card.
            if (!DSMessagesLocalKeysHidden) {
                DSMessagesLocalKeysHidden = YES;
                DSHideMessagesLocalKeys();
            }
            DSTrace(@"app Messages keyboard is SpringBoard's, in-card keys hidden, field stays");
            return;
        }
        DSStageKeyboardWanted = NO;
        if (!DSMessagesLocalKeysHidden) return;
        DSMessagesLocalKeysHidden = NO;
        DSShowMessagesLocalKeys();
        DSTrace(@"app Messages keys are back in the card");
        return;
    }
    if (shown) {
        if (!DSMessagesChatOnScreen || !DSMessagesPickerAsked) return;
        if (DSMessagesLocalKeysHidden) return;
        // Drop the frame notes first, so hiding the key chrome cannot slide
        // the reply bar off the card.
        DSMessagesDropsKeyboardNotes = YES;
        DSMessagesLocalKeysHidden = YES;
        DSHideMessagesLocalKeys();
        DSTrace(@"app Messages keys are SpringBoard's");
        return;
    }
    if (!DSMessagesLocalKeysHidden) return;
    DSMessagesLocalKeysHidden = NO;
    DSMessagesDropsKeyboardNotes = NO;
    DSShowMessagesLocalKeys();
    DSTrace(@"app Messages keys are back in the card");
}

static void DSInstallHooks(void) {
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        %init(_ungrouped);
        DSInstallMessagesBehaviorHooks();
        DSInstallRemoteKeyboardHooks();
        DSInstallKeyboardBanishObserver();
        DSInstallSearchCancelHook();
        if (DSIsBeeper()) {
            DSTrace(@"Beeper debug is on. After the card moves, copy the freeze trace from the stage picker.");
        }
        // The stage signal arrives through notify_register_dispatch. A Darwin
        // center observer in this process did not. The letters were recorded
        // in SpringBoard and this process never woke up for them.
        static int inputToken = NOTIFY_TOKEN_INVALID;
        DSCatchUpKeyboardInput();
        notify_register_dispatch(kDSKeyboardInputNotification, &inputToken, dispatch_get_main_queue(), ^(int t) {
            (void)t;
            DSDrainKeyboardInput();
        });
        static int shownToken = NOTIFY_TOKEN_INVALID;
        notify_register_dispatch(kDSKeyboardShownNotification, &shownToken, dispatch_get_main_queue(), ^(int t) {
            (void)t;
            DSOnSpringBoardKeyboardShown();
        });
        DSReportListening();
    });
}

static void DSStartObserving(void) {
    DSStageContext *context = [DSStageContext sharedContext];
    context.stagedHandler = ^{
        DSInstallHooks();
    };
    [context startObserving];
}

// Runs as soon as dyld maps the image, before the Objective-C constructor.
// If this file appears and the ctor line does not, the image loaded and then
// died before %ctor. If neither appears, ElleKit never loaded the image.
__attribute__((constructor(101)))
static void DSImageMapped(void) {
    NSString *identifier = @"";
    @try {
        identifier = NSBundle.mainBundle.bundleIdentifier ?: @"";
    } @catch (NSException *exception) {
    }
    char line[512];
    snprintf(line, sizeof(line), "mapped bundle=%s\n", identifier.UTF8String ?: "?");
    DSWriteFile("/var/tmp/com.recreated.dynamicstage.mapped", line);
    DSWriteFile("/var/jb/tmp/com.recreated.dynamicstage.mapped", line);
}

%ctor {
    @autoreleasepool {
        int reason = 0;
        @try {
            if (DSKillSwitchPresent()) reason = 1;
            else {
                NSString *identifier = NSBundle.mainBundle.bundleIdentifier ?: @"";
                // System processes get this image because the filter names
                // UIKit. They must not hook, notify, or write the shared files.
                if (DSIdentifierIsExcludedFromStage(identifier) || !DSBundleLooksLikeUserApplication()) {
                    return;
                }
                if (![DSPreferences sharedPreferences].enabled) reason = 5;
            }
        } @catch (NSException *exception) {
            reason = 6;
        }
        DSReportCtor(reason);
        NSString *ctorBundle = NSBundle.mainBundle.bundleIdentifier ?: @"";
        if ([ctorBundle isEqualToString:@"com.beeper.chat.ios"]) {
            DSBeeperDetailLogFormat(@"APP ctor build=%s reason=%d bundle=%@",
                                    kDSBuildVersionString, reason, ctorBundle);
        }
        DSTraceFormat(@"app ctor reason=%d bundle=%@", reason, ctorBundle);
        if (reason != 0) return;

        // Hooks have to be in before the first keyboard. Waiting until the
        // stage notification meant UIKit had already chosen the hosted
        // keyboard window, and iOS 16 does not ask again.
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                if (DSIdentifierIsExcludedFromStage(NSBundle.mainBundle.bundleIdentifier ?: @"")) return;
                if (!DSBundleLooksLikeUserApplication()) return;
                DSInstallHooks();
                DSStartObserving();
            } @catch (NSException *exception) {
            }
        });
    }
}
