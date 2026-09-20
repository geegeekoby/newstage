#import "DSStageContext.h"
#import "DSPreferences.h"
#import "DSConstants.h"
#import <notify.h>

@implementation DSStageContext {
    CGRect _deviceBounds;
    BOOL _resolvedDeviceBounds;
    int _stateToken;
    int _keyboardToken;
    uint64_t _publishedKeyboardHeight;
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
    if (_keyboardToken == NOTIFY_TOKEN_INVALID) return;

    CGFloat height = 0.0;
    if (![notification.name isEqualToString:UIKeyboardWillHideNotification]) {
        CGRect keyboard = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
        // The frame is in this app's own coordinates, so it is measured against this
        // app's own window: only the part of the keyboard that is inside it counts. A
        // keyboard on its way out is reported at full height sitting below the bottom.
        height = CGRectGetHeight(keyboard);
        CGFloat windowHeight = [self ownWindowHeight];
        if (windowHeight > 0.0) {
            CGFloat visible = windowHeight - CGRectGetMinY(keyboard);
            height = MAX(MIN(visible, height), 0.0);
        }
    }

    uint64_t published = _staged ? (uint64_t)round(height) : 0;
    if (published == _publishedKeyboardHeight) return;
    _publishedKeyboardHeight = published;

    notify_set_state(_keyboardToken, published);
    notify_post(kDSKeyboardHeightNotification);
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
    } else {
        uint64_t published = 0;
        if (_stateToken != NOTIFY_TOKEN_INVALID &&
            notify_get_state(_stateToken, &published) == NOTIFY_STATUS_OK) {
            uint32_t staged = (uint32_t)published;
            active = (published & kDSStageStateActiveBit) != 0;
            isUs = staged != 0 && staged == DSIdentifierHash(identifier);
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
        if (_publishedKeyboardHeight != 0 && _keyboardToken != NOTIFY_TOKEN_INVALID) {
            _publishedKeyboardHeight = 0;
            notify_set_state(_keyboardToken, 0);
            notify_post(kDSKeyboardHeightNotification);
        }
        return;
    }
    _padMode = [preferences launchTypeForApplication:identifier] == DSLaunchTypePad &&
               ![preferences landscapeDisabledForApplication:identifier];

    if (!wasStaged && self.stagedHandler) self.stagedHandler();
}

- (CGRect)liveStageBounds {
    CGRect bounds = [self sceneBounds];
    if (CGRectIsEmpty(bounds)) return _stageBounds;
    _stageBounds = bounds;
    return bounds;
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

- (void)applyGeometryChange {
    dispatch_async(dispatch_get_main_queue(), ^{
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
