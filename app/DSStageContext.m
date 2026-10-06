#import "DSStageContext.h"
#import "DSAppPrivate.h"
#import "DSPreferences.h"
#import "DSConstants.h"
#import "DSStageDebug.h"
#import <notify.h>
#import <objc/runtime.h>

static BOOL DSHardwareRead = NO;
static CGFloat DSGeometryGrownHeight = 0;

// 4.5.654: the bundle identifier never changes inside a process. The size
// getters below used to ask NSBundle for it on every call.
static NSString *DSContextBundleID(void) {
    static NSString *identifier = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        identifier = [NSBundle.mainBundle.bundleIdentifier copy];
    });
    return identifier;
}

// 4.5.654: how long the card size read from notifyd is trusted before
// -stageBounds asks notifyd again. Every notify_get_state is a synchronous
// round trip to notifyd. The geometry hooks (UIScreen / UIWindow bounds, the
// UIView frame fit) call -stageBounds many times per layout, so a staged app
// was making 2 (first slot) or 3 (second slot) blocking notifyd calls per
// query, and with two stages both apps did it at once. Fresh reads still
// happen on every geometry / peer notification, every _sceneBoundsDidChange,
// the 1.5 s probe, and at least every 0.25 s while the app is laying out.
static const CFAbsoluteTime kDSNotedCardMaxAge = 0.25;

BOOL DSIsReadingHardwareDisplay(void) {
    return DSHardwareRead;
}

static CGRect DSCardRectFromState(NSDictionary *state, NSString *identifier) {
    if (![state isKindOfClass:NSDictionary.class]) return CGRectZero;
    CGRect rect = CGRectZero;
    NSDictionary *frames = state[@"frames"];
    if ([frames isKindOfClass:NSDictionary.class] && identifier.length) {
        id value = frames[identifier];
        if ([value isKindOfClass:NSString.class]) rect = CGRectFromString((NSString *)value);
    }
    if (CGRectGetWidth(rect) < 80.0 || CGRectGetHeight(rect) < 80.0) {
        rect = CGRectMake(0.0, 0.0, [state[@"width"] doubleValue], [state[@"height"] doubleValue]);
    }
    if (CGRectGetWidth(rect) < 80.0 || CGRectGetHeight(rect) < 80.0) return CGRectZero;
    return rect;
}

@implementation DSStageContext {
    // Written by refresh and by the getter, which reads it from the scene. Declared
    // here because the getter below replaces the one that would have synthesised it.
    CGRect _stageBounds;
    CGRect _deviceBounds;
    BOOL _resolvedDeviceBounds;
    int _stateToken;
    int _peerToken;
    int _cardToken;
    int _cardPeerToken;
    // 4.5.654: last card size read from notifyd, and when (main thread only).
    CGRect _notedCard;
    CFAbsoluteTime _notedAt;
    // 4.5.654: a layout pass is already queued (main thread only). The
    // geometry and peer notifications arrive as a pair, and each used to
    // queue its own full layoutIfNeeded of every window.
    BOOL _geometryPending;
}

+ (instancetype)sharedContext {
    static DSStageContext *shared;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        shared = [[DSStageContext alloc] init];
    });
    return shared;
}

static BOOL DSNotifyRead(int token, NSString *identifier, BOOL *known) {
    if (known) *known = NO;
    if (token == NOTIFY_TOKEN_INVALID) return NO;
    uint64_t published = 0;
    if (notify_get_state(token, &published) != NOTIFY_STATUS_OK) return NO;
    if (known) *known = YES;
    if (identifier.length == 0 || published == 0) return NO;
    if ((published & kDSStageStateActiveBit) == 0) return NO;
    uint32_t staged = (uint32_t)published;
    return staged != 0 && staged == DSIdentifierHash(identifier);
}

static BOOL DSNotifyNamesUs(int token, NSString *identifier) {
    return DSNotifyRead(token, identifier, NULL);
}

static BOOL DSFileNamesUs(NSDictionary *state, NSString *identifier) {
    if (!state || identifier.length == 0) return NO;
    NSArray *stages = state[@"stages"];
    if ([stages isKindOfClass:NSArray.class] && [stages containsObject:identifier]) return YES;
    return [state[@"active"] boolValue] && [state[@"stage"] isEqualToString:identifier];
}

+ (BOOL)processIsStagedNow {
    NSString *identifier = NSBundle.mainBundle.bundleIdentifier;
    if (identifier.length == 0) return NO;

    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:kDSSharedStatePath];
    if (DSFileNamesUs(state, identifier)) return YES;

    int token = NOTIFY_TOKEN_INVALID;
    int peer = NOTIFY_TOKEN_INVALID;
    BOOL named = NO;
    if (notify_register_check(kDSStageGeometryNotification, &token) == NOTIFY_STATUS_OK) {
        named = DSNotifyNamesUs(token, identifier);
        notify_cancel(token);
    }
    if (!named && notify_register_check(kDSStagePeerNotification, &peer) == NOTIFY_STATUS_OK) {
        named = DSNotifyNamesUs(peer, identifier);
        notify_cancel(peer);
    }
    return named;
}

- (void)startObserving {
    // Registered as a check so the notification's state can be read even where
    // the sandbox will not let this process near the state file.
    _stateToken = NOTIFY_TOKEN_INVALID;
    _peerToken = NOTIFY_TOKEN_INVALID;
    _cardToken = NOTIFY_TOKEN_INVALID;
    _cardPeerToken = NOTIFY_TOKEN_INVALID;
    notify_register_check(kDSStageGeometryNotification, &_stateToken);
    notify_register_check(kDSStagePeerNotification, &_peerToken);
    notify_register_check(kDSStageCardSizeNotification, &_cardToken);
    notify_register_check(kDSStageCardSizePeerNotification, &_cardPeerToken);

    [self refresh];

    // Zero is a valid token, so an unset out-parameter has to be the invalid
    // one. Starting at zero makes the registration reuse a token this process
    // does not own, and the app never hears that it was put on the stage.
    int token = NOTIFY_TOKEN_INVALID;
    notify_register_dispatch(kDSStageGeometryNotification, &token, dispatch_get_main_queue(), ^(int t) {
        [self refresh];
        [self applyGeometryChange];
    });
    int peerWatch = NOTIFY_TOKEN_INVALID;
    notify_register_dispatch(kDSStagePeerNotification, &peerWatch, dispatch_get_main_queue(), ^(int t) {
        [self refresh];
        [self applyGeometryChange];
    });
    int infoToken = NOTIFY_TOKEN_INVALID;
    notify_register_dispatch(kDSAppInfoChangedNotification, &infoToken, dispatch_get_main_queue(), ^(int t) {
        [[DSPreferences sharedPreferences] reload];
        [self refresh];
    });

    // The post can land before this process is listening. Reading the state
    // again covers that without depending on the notification arriving.
    __weak DSStageContext *weakSelf = self;
    for (NSNumber *delay in @[ @0.3, @0.9, @1.8, @3.5 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakSelf refresh];
        });
    }
    [self scheduleProbe];

    NSArray<NSString *> *suffixes = @[ @".left", @".right", @".reset" ];
    for (NSString *suffix in suffixes) {
        NSString *name = [kDSRotateNotificationPrefix stringByAppendingString:suffix];
        int rotateToken = NOTIFY_TOKEN_INVALID;
        notify_register_dispatch(name.UTF8String, &rotateToken, dispatch_get_main_queue(), ^(int t) {
            if (!self.staged) return;
            if ([suffix isEqualToString:@".reset"]) {
                self->_quarterTurns = 0;
            } else {
                NSInteger delta = [suffix isEqualToString:@".right"] ? 1 : -1;
                self->_quarterTurns = ((self->_quarterTurns + delta) % 4 + 4) % 4;
            }
            [self applyGeometryChange];
        });
    }
}

#pragma mark - Geometry

- (CGRect)deviceBounds {
    if (_resolvedDeviceBounds) return _deviceBounds;

    // nativeBounds is the panel in pixels. The Messages hook rewrites it for
    // ChatKit, so this read has to see the real panel.
    UIScreen *screen = UIScreen.mainScreen;
    DSHardwareRead = YES;
    CGRect native = screen.nativeBounds;
    CGFloat scale = screen.nativeScale > 0 ? screen.nativeScale : screen.scale;
    DSHardwareRead = NO;
    if (scale <= 0 || CGRectIsEmpty(native)) return CGRectMake(0, 0, 390, 844);

    _deviceBounds = CGRectMake(0, 0,
                               round(CGRectGetWidth(native) / scale),
                               round(CGRectGetHeight(native) / scale));
    _resolvedDeviceBounds = YES;
    return _deviceBounds;
}

- (void)refresh {
    DSPreferences *preferences = [DSPreferences sharedPreferences];
    NSString *identifier = DSContextBundleID();
    BOOL wasStaged = _staged;

    // Either hosted app counts. The geometry notification carries one of them and
    // the peer notification carries the other. The file is only a fallback for a
    // process that cannot read those states.
    BOOL primaryKnown = NO;
    BOOL peerKnown = NO;
    BOOL namedByNotify = DSNotifyRead(_stateToken, identifier, &primaryKnown) ||
                         DSNotifyRead(_peerToken, identifier, &peerKnown);
    BOOL notifyKnown = primaryKnown || peerKnown;
    // 4.5.655: the file is only consulted when notifyd had no state for us
    // (both uses below are behind !notifyKnown). Reading it anyway meant a
    // plist read on the main thread of every injected app every 0.35 s while
    // unstaged, including the app being swiped into the switcher.
    NSDictionary *fileState = notifyKnown ? nil : [NSDictionary dictionaryWithContentsOfFile:kDSSharedStatePath];
    BOOL fileKnown = fileState != nil;
    BOOL isUs = namedByNotify;
    // Notify wins. A stale file must not put the card size back after
    // SpringBoard has cleared the stage bit.
    if (!isUs && !notifyKnown && fileKnown) isUs = DSFileNamesUs(fileState, identifier);
    // An app that is already running misses the stage notification. The card
    // is about half the screen; a full-screen scene is not. After Split
    // closes, SpringBoard has already cleared the stage bit. A scene that is
    // still the old card must not keep the screen hooks on, or Messages keeps
    // laying the reply bar out at 426 by 460.
    if (!isUs && !notifyKnown && !fileKnown) isUs = [self sceneLooksLikeStageCard];

    _staged = isUs && preferences.enabled;

    if (!_staged) {
        _notedCard = CGRectZero;
        _notedAt = 0;
        _quarterTurns = 0;
        _padMode = NO;
        _stageBounds = self.deviceBounds;
        if (wasStaged) {
            DSGeometryGrownHeight = 0.0;
            DSLogAppend([NSString stringWithFormat:@"[SCENE] %@ left the stage, screen %@",
                                                   identifier ?: @"?",
                                                   NSStringFromCGRect(self.deviceBounds)]);
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([DSStageContext sharedContext].staged) return;
                DSRestoreAfterLeavingStage();
            });
        }
        return;
    }

    // The notify state is updated with the file. Prefer it: a sandboxed app
    // often cannot read the file, and a stale file must not put the half
    // height back over the tall one.
    CGRect published = [self noteCardFromNotify];
    if (CGRectIsEmpty(published)) published = [self publishedCardBounds];
    CGRect bounds = CGRectIsEmpty(published) ? [self sceneBounds] : published;
    BOOL sizeChanged = fabs(CGRectGetWidth(bounds) - CGRectGetWidth(_stageBounds)) > 1.0 ||
                       fabs(CGRectGetHeight(bounds) - CGRectGetHeight(_stageBounds)) > 1.0;
    _stageBounds = CGRectIsEmpty(bounds) ? self.deviceBounds : bounds;
    _padMode = [preferences launchTypeForApplication:identifier] == DSLaunchTypePad &&
               ![preferences landscapeDisabledForApplication:identifier];

    if (!wasStaged && self.stagedHandler) self.stagedHandler();
    if (sizeChanged || !wasStaged) [self applyGeometryChange];
}

// Read from the scene every time rather than from the last refresh: the card is resized
// under the app whenever the stage changes shape, and every hook in this dylib that
// answers a question about size answers with this. Off the main thread the last known
// value stands, since asking UIKit for its scenes from another thread is not allowed.
// SpringBoard writes the card's size under this app's bundle. The scene itself
// often stays the full display, which is why Messages keeps its reply bar at
// the bottom of the screen.
- (CGRect)cardRectFromNotifyForIdentifier:(NSString *)identifier {
    int token = NOTIFY_TOKEN_INVALID;
    if (DSNotifyNamesUs(_stateToken, identifier)) token = _cardToken;
    else if (DSNotifyNamesUs(_peerToken, identifier)) token = _cardPeerToken;
    if (token == NOTIFY_TOKEN_INVALID) return CGRectZero;
    uint64_t state = 0;
    if (notify_get_state(token, &state) != NOTIFY_STATUS_OK || state == 0) return CGRectZero;
    CGFloat width = (CGFloat)(state & 0xFFFFFFFFULL);
    CGFloat height = (CGFloat)(state >> 32);
    if (width < 80.0 || height < 80.0) return CGRectZero;
    return CGRectMake(0.0, 0.0, width, height);
}

// 4.5.654: read the card size from notifyd now and remember it. Only the
// main thread keeps the cache; another thread just gets the read.
- (CGRect)noteCardFromNotify {
    CGRect card = [self cardRectFromNotifyForIdentifier:DSContextBundleID()];
    if (NSThread.isMainThread) {
        _notedCard = card;
        _notedAt = CFAbsoluteTimeGetCurrent();
    }
    return card;
}

- (CGRect)publishedCardBounds {
    NSString *identifier = DSContextBundleID();
    CGRect rect = DSCardRectFromState([NSDictionary dictionaryWithContentsOfFile:kDSStageCardPath], identifier);
    if (CGRectIsEmpty(rect)) {
        rect = DSCardRectFromState([NSDictionary dictionaryWithContentsOfFile:kDSSharedStatePath], identifier);
    }
    if (CGRectIsEmpty(rect)) rect = [self cardRectFromNotifyForIdentifier:identifier];
    if (CGRectGetWidth(rect) < 80.0 || CGRectGetHeight(rect) < 80.0) return CGRectZero;
    CGRect device = self.deviceBounds;
    // A card that only clears the home indicator is still a card. Treating
    // anything over 92% of the phone as full screen left the reply field
    // under the clip, which is the bottom of the conversation.
    if (CGRectGetHeight(rect) > CGRectGetHeight(device) - 8.0 &&
        CGRectGetWidth(rect) > CGRectGetWidth(device) - 8.0) {
        return CGRectZero;
    }
    return CGRectMake(0.0, 0.0, CGRectGetWidth(rect), CGRectGetHeight(rect));
}

- (CGRect)stageBounds {
    if (!_staged) return self.deviceBounds;
    if (NSThread.isMainThread && _staged) {
        // The notify state is the size SpringBoard just published. The plist
        // is not read here: a transcript asks for this on every bubble, and
        // that read is a sandbox denial that never returns to the run loop.
        // 4.5.654: nor is notifyd asked on every call. The size read at most
        // 0.25 s ago (or by the last notification / scene resize) is used.
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        CGRect noted = _notedCard;
        if (_notedAt <= 0 || now < _notedAt || now - _notedAt >= kDSNotedCardMaxAge) {
            noted = [self noteCardFromNotify];
        }
        if (CGRectGetWidth(noted) >= 80.0 && CGRectGetHeight(noted) >= 80.0) {
            BOOL changed = fabs(CGRectGetWidth(noted) - CGRectGetWidth(_stageBounds)) > 1.0 ||
                           fabs(CGRectGetHeight(noted) - CGRectGetHeight(_stageBounds)) > 1.0;
            if (changed || CGRectIsEmpty(_stageBounds)) {
                _stageBounds = CGRectMake(0.0, 0.0, CGRectGetWidth(noted), CGRectGetHeight(noted));
                if (changed) [self applyGeometryChange];
            }
        } else {
            static CFAbsoluteTime lastRead = 0;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (CGRectIsEmpty(_stageBounds) || now - lastRead > 0.5) {
                lastRead = now;
                CGRect published = [self publishedCardBounds];
                if (!CGRectIsEmpty(published)) {
                    _stageBounds = published;
                } else {
                    CGRect bounds = [self sceneBounds];
                    if (!CGRectIsEmpty(bounds)) _stageBounds = bounds;
                }
            }
        }
    }
    return CGRectIsEmpty(_stageBounds) ? self.deviceBounds : _stageBounds;
}

// The scene's coordinate space follows the frame SpringBoard hands us and is not
// something this dylib rewrites, so it stays trustworthy.
- (void)scheduleProbe {
    __weak DSStageContext *weakSelf = self;
    NSTimeInterval delay = self.staged ? 1.5 : 0.35;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        DSStageContext *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf refresh];
        [strongSelf scheduleProbe];
    });
}

// Portrait card on this phone is about 420 by 458. Full screen, in either
// orientation, still has one side as long as the display.
- (BOOL)sceneLooksLikeStageCard {
    CGRect bounds = [self sceneBounds];
    CGRect device = [self deviceBounds];
    if (CGRectIsEmpty(bounds) || CGRectIsEmpty(device)) return NO;
    CGFloat longSide = MAX(CGRectGetWidth(device), CGRectGetHeight(device));
    CGFloat shortSide = MIN(CGRectGetWidth(device), CGRectGetHeight(device));
    CGFloat sceneLong = MAX(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    CGFloat sceneShort = MIN(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    return sceneShort > shortSide * 0.75 && sceneShort < shortSide * 1.15 &&
           sceneLong > longSide * 0.35 && sceneLong < longSide * 0.65;
}

- (CGRect)sceneBounds {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            CGRect bounds = ((UIWindowScene *)scene).coordinateSpace.bounds;
            if (!CGRectIsEmpty(bounds)) return CGRectMake(0, 0, CGRectGetWidth(bounds), CGRectGetHeight(bounds));
        }
    }
    return CGRectZero;
}

static BOOL DSContextWindowIsKeyboard(UIWindow *window) {
    if (![window isKindOfClass:UIWindow.class]) return NO;
    NSString *name = NSStringFromClass(object_getClass(window));
    if ([name rangeOfString:@"Keyboard"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"TextEffects"].location != NSNotFound) return YES;
    if ([name rangeOfString:@"InputSet"].location != NSNotFound) return YES;
    return NO;
}

// The height this process last grew to because the card was uncovered. A
// later publish of the half size shrinks back only what this grew.
static NSInteger DSApplyingGeometry = 0;

// The root can grow while the list inside it stays at the old half. That list
// is the view the finger scrolls, so it has to take the new height too.
static void DSGrowFilledDescendants(UIView *view, CGFloat previousHeight, CGFloat height, CGFloat width, NSInteger depth) {
    if (!view || depth > 8) return;
    for (UIView *child in [view.subviews copy]) {
        if ([child isKindOfClass:UIWindow.class] && DSContextWindowIsKeyboard((UIWindow *)child)) continue;
        CGFloat childH = CGRectGetHeight(child.bounds);
        CGFloat childW = CGRectGetWidth(child.bounds);
        BOOL filled = childH > 120.0 && childW > width * 0.65 && fabs(childH - previousHeight) < 40.0;
        if (filled) {
            CGRect frame = child.frame;
            frame.origin.x = 0.0;
            frame.size.width = width;
            CGFloat nextH = height - CGRectGetMinY(frame);
            if (nextH < 80.0) nextH = height;
            frame.size.height = nextH;
            if (fabs(CGRectGetHeight(frame) - childH) > 1.0 || fabs(CGRectGetWidth(frame) - childW) > 1.0) {
                child.frame = frame;
            }
            DSGrowFilledDescendants(child, previousHeight, CGRectGetHeight(child.bounds), width, depth + 1);
            continue;
        }
        if ([child isKindOfClass:UIScrollView.class]) continue;
        DSGrowFilledDescendants(child, previousHeight, height, width, depth + 1);
    }
}

- (void)applyGeometryChange {
    // 4.5.654: one queued pass at a time. The pass reads the current stage
    // when it runs, so a second request before it runs adds nothing.
    BOOL main = NSThread.isMainThread;
    if (main) {
        if (_geometryPending) return;
        _geometryPending = YES;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (main) self->_geometryPending = NO;
        if (!self.staged || DSApplyingGeometry > 0) return;
        CGRect stage = self.stageBounds;
        CGFloat stageW = CGRectGetWidth(stage);
        CGFloat stageH = CGRectGetHeight(stage);
        if (stageW < 80.0 || stageH < 80.0) return;
        Class effects = objc_getClass("UITextEffectsWindow");
        CGRect device = self.deviceBounds;
        DSApplyingGeometry += 1;
        @try {
            for (UIWindow *window in UIApplication.sharedApplication.windows) {
                // Never the window a keyboard is drawn in: that one belongs to the display
                // and to whatever SpringBoard is doing with it, not to the card.
                if (effects != Nil && [window isKindOfClass:effects]) continue;
                if (DSContextWindowIsKeyboard(window)) continue;
                UIView *root = window.rootViewController.view;
                CGFloat rootH = root ? CGRectGetHeight(root.bounds) : CGRectGetHeight(window.bounds);
                BOOL growing = stageH > rootH + 24.0;
                BOOL shrinkingBack = DSGeometryGrownHeight > 80.0 && stageH + 24.0 < DSGeometryGrownHeight;
                if (growing || shrinkingBack) {
                    // Do not set the window frame. That call reaches back into
                    // SpringBoard's scene update, and a split opening underneath
                    // it safe-modes SpringBoard. The scene size is already the
                    // card. The views inside the window are what were stuck at
                    // the old half.
                    (void)device;
                    if (root) {
                        CGRect rootWant = CGRectMake(0.0, 0.0, stageW, stageH);
                        root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                        if (fabs(CGRectGetWidth(root.bounds) - stageW) > 1.0 ||
                            fabs(CGRectGetHeight(root.bounds) - stageH) > 1.0) {
                            root.frame = rootWant;
                        }
                        DSGrowFilledDescendants(root, rootH, stageH, stageW, 0);
                    }
                    if (growing) DSGeometryGrownHeight = stageH;
                    if (shrinkingBack) DSGeometryGrownHeight = 0.0;
                    DSLogAppend([NSString stringWithFormat:@"[SCENE] app %@ layout H=%.0f window=%@ root=%@",
                                                           NSBundle.mainBundle.bundleIdentifier ?: @"?",
                                                           stageH,
                                                           NSStringFromCGRect(window.bounds),
                                                           root ? NSStringFromCGRect(root.bounds) : @"none"]);
                }
                [window setNeedsLayout];
                [root setNeedsLayout];
                if (self->_quarterTurns == 0) {
                    window.transform = CGAffineTransformIdentity;
                } else {
                    window.transform = CGAffineTransformMakeRotation(self->_quarterTurns == 1 ? M_PI_2 : -M_PI_2);
                }
                [window layoutIfNeeded];
            }
        } @finally {
            DSApplyingGeometry -= 1;
        }
        DSRelayoutStagedMessageInput();
    });
}

@end
