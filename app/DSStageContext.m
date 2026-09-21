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

    // The notification first and the file second. Both are written together, but an
    // app is sandboxed and the file is in SpringBoard's preferences directory, so the
    // notification is the one that arrives everywhere.
    uint64_t published = 0;
    if (_stateToken != NOTIFY_TOKEN_INVALID &&
        notify_get_state(_stateToken, &published) == NOTIFY_STATUS_OK && published != 0) {
        uint32_t staged = (uint32_t)published;
        active = (published & kDSStageStateActiveBit) != 0;
        isUs = staged != 0 && staged == DSIdentifierHash(identifier);
    } else {
        NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:kDSSharedStatePath];
        if (state) {
            active = [state[@"active"] boolValue];
            isUs = identifier.length > 0 && [state[@"stage"] isEqualToString:identifier];
        }
    }

    _staged = active && isUs && preferences.enabled;

    CGRect bounds = [self sceneBounds];
    _stageBounds = CGRectIsEmpty(bounds) ? self.deviceBounds : bounds;

    if (!_staged) {
        _quarterTurns = 0;
        _padMode = NO;
        return;
    }
    _padMode = [preferences launchTypeForApplication:identifier] == DSLaunchTypePad &&
               ![preferences landscapeDisabledForApplication:identifier];

    if (!wasStaged && self.stagedHandler) self.stagedHandler();
}

// Read from the scene every time rather than from the last refresh: the card is resized
// under the app whenever the stage changes shape, and every hook in this dylib that
// answers a question about size answers with this. Off the main thread the last known
// value stands, since asking UIKit for its scenes from another thread is not allowed.
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

- (void)applyGeometryChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class effects = objc_getClass("UITextEffectsWindow");
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            // Never the window a keyboard is drawn in: that one belongs to the display
            // and to whatever SpringBoard is doing with it, not to the card.
            if (effects != Nil && [window isKindOfClass:effects]) continue;
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
