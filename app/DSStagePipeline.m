#import "DSStagePipeline.h"

static inline NSString *DSBundleID(void) {
    return NSBundle.mainBundle.bundleIdentifier ?: @"";
}

static inline BOOL DSIsSpringBoard(void) {
    return [DSBundleID() isEqualToString:@"com.apple.springboard"];
}

static inline BOOL DSIsBeeper(void) {
    return [DSBundleID() isEqualToString:@"com.beeper.chat.ios"];
}

static inline BOOL DSIsMessages(void) {
    return [DSBundleID() isEqualToString:@"com.apple.MobileSMS"];
}

static inline BOOL DSIsKeyboardWindow(UIWindow *window) {
    if (![window isKindOfClass:UIWindow.class]) return NO;
    NSString *name = NSStringFromClass(window.class);
    if ([name containsString:@"UIRemoteKeyboardWindow"]) return YES;
    if ([name containsString:@"UITextEffectsWindow"]) return YES;
    if ([name containsString:@"SBMedusaHostedKeyboardWindow"]) return YES;
    return NO;
}

static inline BOOL DSIsSystemOverlay(UIWindow *window) {
    return window.windowLevel >= UIWindowLevelStatusBar;
}

static inline BOOL DSIsStageWindow(UIWindow *window) {
    return [NSStringFromClass(window.class) containsString:@"DSStageWindow"];
}

static inline BOOL DSIsStagedCardWindow(UIWindow *window) {
    CGRect frame = window.frame;
    CGRect screen = UIScreen.mainScreen.bounds;
    if (frame.origin.y > 0.0 &&
        frame.size.height < screen.size.height - 50.0 &&
        frame.size.width <= screen.size.width) {
        return YES;
    }
    return NO;
}

typedef NS_ENUM(NSInteger, DSAppProfile) {
    DSProfileGeneric = 0,
    DSProfileBeeper,
    DSProfileMessages
};

static inline DSAppProfile DSCurrentProfile(void) {
    if (DSIsMessages()) return DSProfileMessages;
    if (DSIsBeeper()) return DSProfileMessages;
    return DSProfileGeneric;
}

typedef NS_ENUM(NSInteger, DSKeyboardMode) {
    DSKeyboardNone = 0,
    DSKeyboardUIKitInApp,
    DSKeyboardSpringBoardHosted,
    DSKeyboardRemote,
    DSKeyboardMedusa,
    DSKeyboardStaged
};

static inline DSKeyboardMode DSKeyboardModeForWindow(UIWindow *window) {
    NSString *name = NSStringFromClass(window.class);
    if ([name containsString:@"SBMedusaHostedKeyboardWindow"]) return DSKeyboardMedusa;
    if ([name containsString:@"UIRemoteKeyboardWindow"]) return DSKeyboardRemote;
    if ([name containsString:@"UITextEffectsWindow"]) return DSKeyboardUIKitInApp;
    return DSKeyboardNone;
}

static UIWindow *gDSStageWindow;

static void DSEnsureStageWindow(void) {
    // The real stage window already exists in SpringBoard at level 998.
    // Allocating another one inside Beeper puts a full-screen window over its keyboard.
    if (!DSIsSpringBoard()) return;
    if (gDSStageWindow) return;
    gDSStageWindow = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    gDSStageWindow.windowLevel = UIWindowLevelNormal + 998.0;
    gDSStageWindow.hidden = NO;
    gDSStageWindow.backgroundColor = UIColor.clearColor;
    gDSStageWindow.userInteractionEnabled = NO;
}

// 4.5.655: write a layer property only when it differs. This runs from every
// UIWindow setFrame: in every injected app, staged or not, and the plain writes
// (cornerRadius 0, identity transform) dirtied the window layer each time.
static void DSSetWindowCorner(UIWindow *window, CGFloat radius, BOOL masks) {
    CALayer *layer = window.layer;
    if (fabs(layer.cornerRadius - radius) > 0.01) layer.cornerRadius = radius;
    if (masks && !layer.masksToBounds) layer.masksToBounds = YES;
}

static void DSSetWindowIdentity(UIWindow *window) {
    if (!CGAffineTransformIsIdentity(window.transform)) window.transform = CGAffineTransformIdentity;
}

static void DSApplyTransformsToWindow(UIWindow *window, DSAppProfile profile) {
    if (DSIsSystemOverlay(window)) return;
    if (DSIsStageWindow(window)) return;
    if (DSIsKeyboardWindow(window)) return;

    switch (profile) {
        case DSProfileBeeper:
            if (DSIsStagedCardWindow(window)) {
                DSSetWindowCorner(window, 16.0, YES);
                DSSetWindowIdentity(window);
            } else {
                DSSetWindowCorner(window, 0.0, NO);
                DSSetWindowIdentity(window);
            }
            break;
        case DSProfileMessages:
            DSSetWindowCorner(window, DSIsStagedCardWindow(window) ? 16.0 : 0.0, NO);
            DSSetWindowIdentity(window);
            break;
        case DSProfileGeneric:
        default:
            if (DSIsStagedCardWindow(window)) {
                DSSetWindowCorner(window, 18.0, YES);
                DSSetWindowIdentity(window);
            } else {
                DSSetWindowCorner(window, 0.0, NO);
                DSSetWindowIdentity(window);
            }
            break;
    }
}

static BOOL DSShouldSkipDynamicStageForBeeperKeyboard(UIWindow *window) {
    if (!DSIsBeeper()) return NO;
    DSKeyboardMode mode = DSKeyboardModeForWindow(window);
    if (mode == DSKeyboardUIKitInApp ||
        mode == DSKeyboardRemote ||
        mode == DSKeyboardMedusa) {
        return YES;
    }
    return NO;
}

// Beeper's staged card. SpringBoard sets its frame and the keyboard lift.
// Dynamic Stage must not replace that geometry with its own transform.
BOOL DSShouldSkipDynamicStageForBeeper(UIWindow *window) {
    if (!DSIsBeeper() || ![window isKindOfClass:UIWindow.class]) return NO;
    if (DSIsKeyboardWindow(window)) return NO;
    CGRect frame = window.frame;
    CGFloat screenH = CGRectGetHeight(UIScreen.mainScreen.bounds);
    BOOL cardHeight = CGRectGetHeight(frame) > 80.0 && CGRectGetHeight(frame) < screenH - 100.0;
    if (!cardHeight) return NO;
    return YES;
}

void DSProcessWindow(UIWindow *window) {
    if (![window isKindOfClass:UIWindow.class]) return;
    if (DSShouldSkipDynamicStageForBeeper(window)) return;
    DSEnsureStageWindow();
    DSAppProfile profile = DSCurrentProfile();
    if (DSIsSystemOverlay(window)) return;
    if (DSIsStageWindow(window)) return;
    if (DSIsKeyboardWindow(window)) {
        if (DSShouldSkipDynamicStageForBeeperKeyboard(window)) return;
        if (profile == DSProfileMessages) return;
        return;
    }
    DSApplyTransformsToWindow(window, profile);
}
