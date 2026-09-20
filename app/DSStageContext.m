#import "DSStageContext.h"
#import "DSPreferences.h"
#import "DSConstants.h"
#import <notify.h>

@implementation DSStageContext {
    CGRect _deviceBounds;
    BOOL _resolvedDeviceBounds;
}

+ (instancetype)sharedContext {
    static DSStageContext *shared;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        shared = [[DSStageContext alloc] init];
    });
    return shared;
}

- (void)startObserving {
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

    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:kDSSharedStatePath];
    NSString *hosted = state[@"stage"];
    BOOL active = [state[@"active"] boolValue];
    BOOL isUs = identifier.length > 0 && [hosted isEqualToString:identifier];

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
