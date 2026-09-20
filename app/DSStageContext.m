#import "DSStageContext.h"
#import "DSAppPrivate.h"
#import "DSPreferences.h"
#import "DSConstants.h"
#import <notify.h>
#import <objc/runtime.h>

@implementation DSStageContext {
    // Written by refresh and by the getter, which reads it from the scene. Declared
    // here because the getter below replaces the one that would have synthesised it.
    CGRect _stageBounds;
    CGRect _deviceBounds;
    BOOL _resolvedDeviceBounds;
    int _stateToken;
    int _keyboardToken;
    uint64_t _publishedKeyboardHeight;
    // How tall the card is, as SpringBoard last said. The band below it starts there.
    CGFloat _cardHeight;
    // Set while a keyboard is on its way out, when it has to be left to animate down
    // out of the band rather than being held in it.
    BOOL _keyboardLeaving;
}

+ (instancetype)sharedContext {
    static DSStageContext *shared;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        shared = [[DSStageContext alloc] init];
    });
    return shared;
}

+ (BOOL)processIsStagedNow {
    NSString *identifier = NSBundle.mainBundle.bundleIdentifier;
    if (identifier.length == 0) return NO;

    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:kDSSharedStatePath];
    if (state) {
        return [state[@"active"] boolValue] && [state[@"stage"] isEqualToString:identifier];
    }

    int token = NOTIFY_TOKEN_INVALID;
    if (notify_register_check(kDSStageGeometryNotification, &token) != NOTIFY_STATUS_OK) return NO;
    uint64_t published = 0;
    BOOL staged = notify_get_state(token, &published) == NOTIFY_STATUS_OK &&
                  (published & kDSStageStateActiveBit) != 0 &&
                  (uint32_t)published == DSIdentifierHash(identifier);
    notify_cancel(token);
    return staged;
}

- (void)startObserving {
    // Registered as a check so the notification's state can be read even where
    // the sandbox will not let this process near the state file.
    _stateToken = NOTIFY_TOKEN_INVALID;
    notify_register_check(kDSStageGeometryNotification, &_stateToken);

    [self refresh];

    int token = 0;
    notify_register_dispatch(kDSStageGeometryNotification, &token, dispatch_get_main_queue(), ^(int t) {
        [self refresh];
        [self applyGeometryChange];
    });
    notify_register_dispatch(kDSAppInfoChangedNotification, &token, dispatch_get_main_queue(), ^(int t) {
        [[DSPreferences sharedPreferences] reload];
        [self refresh];
    });

    [self observeOwnKeyboard];

    NSArray<NSString *> *suffixes = @[ @".left", @".right", @".reset" ];
    for (NSString *suffix in suffixes) {
        NSString *name = [kDSRotateNotificationPrefix stringByAppendingString:suffix];
        int rotateToken = 0;
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

#pragma mark - Telling the stage about the keyboard

// This process is the only one that can see its own keyboard: it is drawn inside
// this app's window, which on the stage is the card, and nothing about it leaves
// the process. So the height is published, and SpringBoard makes the window that
// much taller than the card and lets the bottom band of it through underneath -
// the keyboard ends up below the card, on the bottom edge of the display, the size
// it would be if this app were full screen.
- (void)observeOwnKeyboard {
    _keyboardToken = NOTIFY_TOKEN_INVALID;
    notify_register_check(kDSKeyboardHeightNotification, &_keyboardToken);

    for (NSString *name in @[ UIKeyboardWillChangeFrameNotification,
                              UIKeyboardWillShowNotification,
                              UIKeyboardWillHideNotification ]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name
                                                       object:nil
                                                        queue:NSOperationQueue.mainQueue
                                                   usingBlock:^(NSNotification *notification) {
            [self publishKeyboardHeightFrom:notification];
        }];
    }
}

- (void)publishKeyboardHeightFrom:(NSNotification *)notification {
    _keyboardLeaving = [notification.name isEqualToString:UIKeyboardWillHideNotification];

    if (_keyboardLeaving) {
        [self publishKeyboardTop:0.0 height:0.0];
        return;
    }

    // What UIKit says it is about to do, which is the best that is known this early:
    // the frame is in this scene's own coordinates, which is what SpringBoard wants.
    CGRect keyboard = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    [self publishKeyboardTop:CGRectGetMinY(keyboard) height:CGRectGetHeight(keyboard)];

    // Then what it actually did, once it has done it. A keyboard is laid out over
    // several frames and moves again whenever the scene is resized underneath it, and
    // the card is cut to fit wherever it ends up - so the measurement is repeated and
    // republished until it settles.
    for (NSNumber *delay in @[ @0.05, @0.2, @0.45, @0.9 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                [self republishMeasuredKeyboard];
            } @catch (NSException *exception) {
            }
        });
    }
}

// The keyboard as it is on screen right now, in this scene's coordinates, read from
// the window it is drawn in. This is the number that matters: everything else is a
// request, and a request that was not honoured is exactly how the keyboard ended up
// inside the card in every build before this one.
- (BOOL)measuredKeyboardTop:(CGFloat *)outTop height:(CGFloat *)outHeight {
    Class effectsClass = objc_getClass("UITextEffectsWindow");
    if (!effectsClass) return NO;

    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (window.hidden || window.alpha < 0.01) continue;
        if (![window isKindOfClass:effectsClass]) continue;

        UIView *host = DSInputSetHostViewIn(window);
        if (!host || CGRectGetHeight(host.bounds) < kDSKeyboardPresentHeight) continue;

        CGRect inWindow = [host convertRect:host.bounds toView:nil];
        if (outTop) *outTop = CGRectGetMinY(inWindow) + CGRectGetMinY(window.frame);
        if (outHeight) *outHeight = CGRectGetHeight(inWindow);
        return YES;
    }
    return NO;
}

- (void)republishMeasuredKeyboard {
    if (_keyboardLeaving) return;
    CGFloat top = 0.0;
    CGFloat height = 0.0;
    if (![self measuredKeyboardTop:&top height:&height]) return;
    [self publishKeyboardTop:top height:height];
}

- (void)publishKeyboardTop:(CGFloat)top height:(CGFloat)height {
    if (_keyboardToken == NOTIFY_TOKEN_INVALID) return;

    if (!_staged || height < kDSKeyboardPresentHeight) {
        top = 0.0;
        height = 0.0;
    }

    uint64_t published = MIN((uint64_t)MAX(round(height), 0.0), kDSKeyboardStateHeightMask);
    if (published > 0) {
        uint64_t line = MIN((uint64_t)MAX(round(top), 0.0), kDSKeyboardStateHeightMask);
        published |= line << kDSKeyboardStateTopShift;
    }
    if (published == _publishedKeyboardHeight) return;
    _publishedKeyboardHeight = published;

    notify_set_state(_keyboardToken, published);
    notify_post(kDSKeyboardHeightNotification);

    // Said again by name, because the shared state above is written by a sandboxed
    // process into a notification SpringBoard created, and being refused that is
    // indistinguishable from never having raised a keyboard. Posting is allowed to
    // anyone, so the height also arrives as which name was posted - and where the
    // state cannot be read, the card's own height stands in for the line.
    uint64_t step = ((uint64_t)round(height) + kDSKeyboardHeightStep / 2) / kDSKeyboardHeightStep;
    if (step >= kDSKeyboardHeightSteps) step = kDSKeyboardHeightSteps - 1;
    notify_post([NSString stringWithFormat:@"%s%llu", kDSKeyboardHeightStepNotificationPrefix, step].UTF8String);
}

// The window the keyboard came up in. On the stage that is the card plus whatever
// room SpringBoard has already made below it for the keyboard, so it is read live
// rather than taken from the published stage rectangle, which can be a layout behind.
// Zero when there is nothing to read, in which case the keyboard's own height stands.
- (CGFloat)ownWindowHeight {
    UIWindow *window = UIApplication.sharedApplication.keyWindow;
    if (!window) {
        for (UIWindow *candidate in UIApplication.sharedApplication.windows) {
            if (candidate.hidden || CGRectIsEmpty(candidate.bounds)) continue;
            window = candidate;
            break;
        }
    }
    return window ? CGRectGetHeight(window.bounds) : 0.0;
}

#pragma mark - Geometry

- (CGRect)deviceBounds {
    if (_resolvedDeviceBounds) return _deviceBounds;

    // nativeBounds is the panel in pixels and is never rewritten by the hooks
    // below, so it is the one honest source for the real display size.
    UIScreen *screen = UIScreen.mainScreen;
    CGRect native = screen.nativeBounds;
    CGFloat scale = screen.nativeScale > 0 ? screen.nativeScale : screen.scale;
    if (scale <= 0 || CGRectIsEmpty(native)) return CGRectMake(0, 0, 390, 844);

    _deviceBounds = CGRectMake(0, 0,
                               round(CGRectGetWidth(native) / scale),
                               round(CGRectGetHeight(native) / scale));
    _resolvedDeviceBounds = YES;
    return _deviceBounds;
}

- (void)refresh {
    DSPreferences *preferences = [DSPreferences sharedPreferences];
    NSString *identifier = NSBundle.mainBundle.bundleIdentifier;
    BOOL wasStaged = _staged;

    BOOL active = NO;
    BOOL isUs = NO;

    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:kDSSharedStatePath];
    if (state) {
        active = [state[@"active"] boolValue];
        isUs = identifier.length > 0 && [state[@"stage"] isEqualToString:identifier];
        _cardHeight = [state[@"cardHeight"] doubleValue];
    } else {
        uint64_t published = 0;
        if (_stateToken != NOTIFY_TOKEN_INVALID &&
            notify_get_state(_stateToken, &published) == NOTIFY_STATUS_OK) {
            uint32_t staged = (uint32_t)published;
            active = (published & kDSStageStateActiveBit) != 0;
            isUs = staged != 0 && staged == DSIdentifierHash(identifier);
            _cardHeight = (CGFloat)((published >> kDSStageStateCardHeightShift) & kDSStageStateCardHeightMask);
        }
    }

    _staged = active && isUs && preferences.enabled;

    CGRect bounds = [self sceneBounds];
    _stageBounds = CGRectIsEmpty(bounds) ? self.deviceBounds : bounds;

    if (!_staged) {
        _quarterTurns = 0;
        _padMode = NO;
        // Off the stage, whatever was said about a keyboard no longer applies, and a
        // stale height would leave the card shaped for one.
        [self publishKeyboardTop:0.0 height:0.0];
        return;
    }
    _padMode = [preferences launchTypeForApplication:identifier] == DSLaunchTypePad &&
               ![preferences landscapeDisabledForApplication:identifier];

    if (!wasStaged) {
        // So SpringBoard can write down that this app has the tweak's own code inside
        // it. Without that, an app whose dylib never loaded looks exactly like one
        // that loaded and never saw a keyboard: both are silent.
        notify_post(kDSStagedAppCheckedInNotification);
        if (self.stagedHandler) self.stagedHandler();
    }
}

// Read from the scene every time rather than from the last refresh. The scene grows
// by the height of the keyboard the moment a keyboard goes up in it, and every hook
// in this dylib that answers a question about size answers with this - so a value one
// layout old is the card's height, which is how the keyboard ended up inside the card
// in every build before 1.4.4. Off the main thread the last known value stands, since
// asking UIKit for its scenes from another thread is not allowed.
- (CGRect)stageBounds {
    if (NSThread.isMainThread) {
        CGRect bounds = [self sceneBounds];
        if (!CGRectIsEmpty(bounds)) _stageBounds = bounds;
    }
    return CGRectIsEmpty(_stageBounds) ? self.deviceBounds : _stageBounds;
}

// The scene's coordinate space follows the frame SpringBoard hands us and is not
// something this dylib rewrites, so it stays trustworthy.
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

static UIView *DSInputSetHostViewIn(UIView *view) {
    Class hostClass = objc_getClass("UIInputSetHostView");
    if (!hostClass) return nil;
    if ([view isKindOfClass:hostClass]) return view;
    for (UIView *subview in view.subviews) {
        UIView *found = DSInputSetHostViewIn(subview);
        if (found) return found;
    }
    return nil;
}

// The scene has been resized under a keyboard that is already up, so UIKit is asked
// to place it again - it is placed against the bottom of the window, and the window
// is not the size it was. Where it lands is then measured and published, because that
// is what the card is cut to.
- (void)nudgeKeyboardPlacement {
    @try {
        Class controllerClass = objc_getClass("UIInputResponderController");
        if ([controllerClass respondsToSelector:@selector(activeInputResponderController)]) {
            UIInputResponderController *controller = [controllerClass activeInputResponderController];
            if ([controller respondsToSelector:@selector(reloadPlacement)]) [controller reloadPlacement];
        }
    } @catch (NSException *exception) {
    }
    @try {
        [self republishMeasuredKeyboard];
    } @catch (NSException *exception) {
    }
}

- (void)applyGeometryChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Twice: once now, and once after UIKit has taken the new window size, since
        // the first can arrive before the window it is measuring against has grown.
        [self nudgeKeyboardPlacement];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self nudgeKeyboardPlacement];
        });
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            [window setNeedsLayout];
            [window.rootViewController.view setNeedsLayout];
            if (self->_quarterTurns == 0) {
                window.transform = CGAffineTransformIdentity;
            } else {
                window.transform = CGAffineTransformMakeRotation(self->_quarterTurns == 1 ? M_PI_2 : -M_PI_2);
            }
            [window layoutIfNeeded];
        }
    });
}

@end
