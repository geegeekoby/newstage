#import "DSKeyboardHost.h"
#import "DSStageWindow.h"
#import "DSPrivate.h"
#import "DSConstants.h"
#import "DSDiagnostics.h"
#import <objc/runtime.h>
#import <objc/message.h>

static id DSIvarValue(id object, NSString *name) {
    if (!object || name.length == 0) return nil;
    Ivar ivar = class_getInstanceVariable([object class], name.UTF8String);
    if (!ivar) return nil;
    @try {
        return object_getIvar(object, ivar);
    } @catch (NSException *exception) {
        return nil;
    }
}

// The window the keyboard is hosted in covers the whole display, because the keyboard
// scene is laid out against the whole display. Only the part of it the keyboard is
// actually occupying may take a touch; everything else has to fall through to the card
// and the home screen behind it.
@interface DSKeyboardHostWindow : UIWindow
@property (nonatomic, assign) CGRect liveFrame;
@end

@implementation DSKeyboardHostWindow

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (CGRectIsEmpty(_liveFrame)) return NO;
    return CGRectContainsPoint(_liveFrame, [self convertPoint:point toWindow:nil]);
}

@end

@implementation DSKeyboardHost {
    __weak id _arbiter;
    FBScene *_keyboardScene;
    FBSceneHostManager *_hostManager;
    UIView *_hostView;
    DSKeyboardHostWindow *_window;
    __weak UIWindow *_stageWindow;
    // Armed from the moment an app goes on the stage, not from the moment a keyboard
    // arrives: the card is asked whether it may draw the keyboard layer before anyone
    // here hears that a keyboard exists, and answering "yes, for now" once is enough
    // to put the keyboard in the card for the rest of its life.
    BOOL _armed;
    BOOL _hostingFailed;
    BOOL _notedSceneFrame;
    NSString *_bundleIdentifier;
    CGRect _keyboardFrame;
}

+ (instancetype)sharedHost {
    static DSKeyboardHost *host;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        host = [[DSKeyboardHost alloc] init];
    });
    return host;
}

- (void)noteArbiter:(id)arbiter {
    if (_arbiter == arbiter) return;
    _arbiter = arbiter;
    _keyboardScene = nil;
}

#pragma mark - The keyboard's own scene

// The arbiter creates one scene for the keyboard and keeps it for the life of the
// device. Its name is asked for rather than assumed, and the ivar is the fallback,
// because a scene that cannot be found here means the keyboard cannot be moved and
// the stage has to leave it where it was.
- (FBScene *)keyboardScene {
    if (_keyboardScene) return _keyboardScene;

    id arbiter = _arbiter;
    if (!arbiter) return nil;

    FBScene *scene = nil;
    for (NSString *name in @[ @"keyboardScene", @"scene" ]) {
        SEL selector = NSSelectorFromString(name);
        if (![arbiter respondsToSelector:selector]) continue;
        @try {
            scene = ((id (*)(id, SEL))objc_msgSend)(arbiter, selector);
        } @catch (NSException *exception) {
            scene = nil;
        }
        if (scene) break;
    }
    if (!scene) scene = DSIvarValue(arbiter, @"_scene");

    if (![scene respondsToSelector:@selector(hostManagerForRequester:)]) {
        DSDiagnosticsRecord(@"SpringBoard: the keyboard arbiter here has no scene the stage can host");
        return nil;
    }

    _keyboardScene = scene;
    DSDiagnosticsRecordFormat(@"SpringBoard: the keyboard's own scene is %@",
                              [scene respondsToSelector:@selector(identifier)] ? scene.identifier : @"unnamed");
    return _keyboardScene;
}

#pragma mark - Arming

- (void)takeOverKeyboardForApplication:(NSString *)bundleIdentifier stageWindow:(UIWindow *)window {
    _stageWindow = window;
    if (_armed && [_bundleIdentifier isEqualToString:bundleIdentifier]) return;
    _bundleIdentifier = [bundleIdentifier copy];
    _armed = YES;
    _hostingFailed = NO;
    // Whatever SpringBoard has opened since it started is scanned again here: the class
    // that draws a hosted app is not necessarily loaded when a phone finishes booting.
    if (!_keyboardLayerCanBeRefused) [DSKeyboardHost refuseTheKeyboardLayerWhereverItIsOffered];
    DSDiagnosticsRecordFormat(@"SpringBoard: %@'s keyboard now belongs to the display, not to the card",
                              bundleIdentifier);
}

- (void)standDown {
    _stageWindow = nil;
    _bundleIdentifier = nil;
    if (!_armed) return;
    _armed = NO;
    _hostingFailed = NO;
    _keyboardFrame = CGRectZero;
    [self tearDownHosting];
}

+ (BOOL)shouldRefuseKeyboardLayerInView:(UIView *)view {
    return [[DSKeyboardHost sharedHost] refusesKeyboardLayerInView:view];
}

#pragma mark - Taking over the decision

// Which class asks the question has moved between iOS versions, and there has never
// been only one of them, so they are found rather than named. The original answer is
// kept per class and given back for every view that is not the stage's card.
static NSMapTable *DSKeyboardLayerOriginals(void) {
    static NSMapTable *originals;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        originals = [NSMapTable strongToStrongObjectsMapTable];
    });
    return originals;
}

static BOOL DSCanShowKeyboardLayer(id self, SEL _cmd) {
    @try {
        if ([self isKindOfClass:UIView.class] && [DSKeyboardHost shouldRefuseKeyboardLayerInView:self]) {
            return NO;
        }
    } @catch (NSException *exception) {
    }

    // The most derived class that was replaced owns the answer that was there before.
    for (Class candidate = object_getClass(self); candidate; candidate = class_getSuperclass(candidate)) {
        NSValue *stored = [DSKeyboardLayerOriginals() objectForKey:candidate];
        if (!stored) continue;
        IMP original = (IMP)stored.pointerValue;
        if (!original) break;
        return ((BOOL (*)(id, SEL))original)(self, _cmd);
    }
    return YES;
}

+ (void)refuseTheKeyboardLayerWhereverItIsOffered {
    SEL selector = @selector(_canShowKeyboardLayer);
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return;

    NSMutableArray<NSString *> *patched = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        Class candidate = classes[i];
        const char *rawName = class_getName(candidate);
        if (!rawName) continue;
        // Cheap test first, because this walks every class in SpringBoard: a class that
        // does not answer the question at all, by itself or by inheritance, is skipped
        // without allocating anything. The handful left are checked properly, since the
        // answer has to be replaced in the class that declares it and nowhere else.
        if (!class_getInstanceMethod(candidate, selector)) continue;
        if ([DSKeyboardLayerOriginals() objectForKey:candidate]) continue;

        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(candidate, &methodCount);
        if (!methods) continue;
        for (unsigned int j = 0; j < methodCount; j++) {
            if (method_getName(methods[j]) != selector) continue;
            IMP original = method_setImplementation(methods[j], (IMP)DSCanShowKeyboardLayer);
            [DSKeyboardLayerOriginals() setObject:[NSValue valueWithPointer:(void *)original]
                                           forKey:candidate];
            [patched addObject:@(rawName)];
            break;
        }
        free(methods);
    }
    free(classes);

    if (patched.count == 0) {
        if (![DSKeyboardHost sharedHost].keyboardLayerCanBeRefused) {
            DSDiagnosticsRecord(@"SpringBoard: nothing here decides whether a scene view draws the "
                                 "keyboard, so a staged app's keyboard stays in the card");
        }
        return;
    }
    [DSKeyboardHost sharedHost].keyboardLayerCanBeRefused = YES;
    DSDiagnosticsRecordFormat(@"SpringBoard: the keyboard can be refused in %@",
                              [patched componentsJoinedByString:@", "]);
}

- (BOOL)refusesKeyboardLayerInView:(UIView *)view {
    if (!_armed || _hostingFailed || !_keyboardLayerCanBeRefused) return NO;
    UIWindow *stage = _stageWindow;
    if (!stage || !view) return NO;

    // Only the card. Every other scene view in SpringBoard - the app switcher's
    // cards, the app behind the stage, anything a future build puts on screen -
    // keeps its keyboard, because taking one away from a view the stage does not own
    // is a keyboard nobody can get back.
    for (UIView *candidate = view; candidate; candidate = candidate.superview) {
        if (candidate == stage) return YES;
    }
    return NO;
}

#pragma mark - Hosting

- (void)setKeyboardFrame:(CGRect)frame source:(NSString *)source {
    if (!_armed || !_keyboardLayerCanBeRefused || _hostingFailed) return;

    // A keyboard going away is taken at its word whoever reports it. The arbiter does
    // not always name the process a keyboard is leaving on behalf of, and a keyboard
    // window left up over a keyboard that has gone is a slab of dead keys on the
    // display - much worse than putting one away a moment early.
    if (CGRectIsEmpty(frame)) {
        [self keyboardIsNoLongerOnScreen];
        return;
    }

    // Anything else, though, has to be the keyboard of the app in the card. The
    // keyboard SpringBoard raises for its own text fields - the stage's search field,
    // Spotlight - is drawn by SpringBoard in this process, already at the bottom of the
    // display and already above the card. There is nothing to move.
    if (_bundleIdentifier.length == 0 || ![source isEqualToString:_bundleIdentifier]) return;
    if (CGRectEqualToRect(frame, _keyboardFrame)) return;
    _keyboardFrame = frame;
    [self showKeyboardInOwnWindow];
}

- (void)keyboardIsNoLongerOnScreen {
    _keyboardFrame = CGRectZero;
    [self hideWindow];
}

- (void)showKeyboardInOwnWindow {
    FBScene *scene = [self keyboardScene];
    if (!scene) {
        [self giveUpHosting:@"there is no keyboard scene on this build"];
        return;
    }

    if (!_hostView) {
        @try {
            _hostManager = [scene hostManagerForRequester:kDSKeyboardRequester];
            if (![_hostManager respondsToSelector:@selector(hostViewForRequester:enableAndOrderFront:)]) {
                [self giveUpHosting:@"the keyboard scene will not give out a host view here"];
                return;
            }
            _hostView = [_hostManager hostViewForRequester:kDSKeyboardRequester enableAndOrderFront:YES];
        } @catch (NSException *exception) {
            [self giveUpHosting:[NSString stringWithFormat:@"hosting the keyboard threw %@", exception.name ?: @"?"]];
            return;
        }
        if (!_hostView) {
            [self giveUpHosting:@"hosting the keyboard gave back no view"];
            return;
        }
        DSDiagnosticsRecordFormat(@"SpringBoard: the keyboard is now drawn on the display at %@",
                                  NSStringFromCGRect(_keyboardFrame));
    }

    DSKeyboardHostWindow *window = [self window];
    _hostView.frame = [self hostViewFrameForScene:scene inWindow:window];
    if (_hostView.superview != window.rootViewController.view) {
        [window.rootViewController.view addSubview:_hostView];
    }
    window.liveFrame = _keyboardFrame;
    window.hidden = NO;
}

// A scene's host view is that scene's own rectangle, and the keyboard's scene is laid
// out against the whole display: the keyboard sits at the bottom of it with nothing
// above. So the host view is given the display, and the keyboard lands where it would
// in any other app.
//
// Measured rather than assumed, though, because the whole point of hosting the keyboard
// here is that its size stops depending on the card. A scene that turns out to be the
// keyboard and no more is placed at the keyboard's own frame instead, and either way
// what the scene said is written down once - it is the one number that would explain a
// keyboard coming up the wrong size.
- (CGRect)hostViewFrameForScene:(FBScene *)scene inWindow:(UIWindow *)window {
    CGRect display = window.bounds;
    CGRect sceneFrame = CGRectZero;
    @try {
        sceneFrame = scene.settings.frame;
    } @catch (NSException *exception) {
        return display;
    }

    if (!_notedSceneFrame) {
        _notedSceneFrame = YES;
        DSDiagnosticsRecordFormat(@"SpringBoard: the keyboard's scene is %@ against a display of %@",
                                  NSStringFromCGRect(sceneFrame), NSStringFromCGRect(display));
    }

    if (CGRectIsEmpty(sceneFrame)) return display;
    if (CGRectGetHeight(sceneFrame) >= CGRectGetHeight(display) - 1.0) return display;
    return CGRectMake(CGRectGetMinX(_keyboardFrame), CGRectGetMinY(_keyboardFrame),
                      CGRectGetWidth(sceneFrame), CGRectGetHeight(sceneFrame));
}

- (void)hideWindow {
    _window.liveFrame = CGRectZero;
    _window.hidden = YES;
}

// A keyboard the stage has taken out of the card and then failed to put anywhere is
// worse than a keyboard in the card, so the takeover is abandoned rather than retried:
// the card starts drawing its own keyboard again from the next one onwards, and the
// reason is written down.
- (void)giveUpHosting:(NSString *)reason {
    if (_hostingFailed) return;
    _hostingFailed = YES;
    [self tearDownHosting];
    DSDiagnosticsRecordFormat(@"SpringBoard: the keyboard is back in the card - %@", reason);
}

- (void)tearDownHosting {
    [self hideWindow];
    @try {
        if ([_hostManager respondsToSelector:@selector(disableHostingForRequester:)]) {
            [_hostManager disableHostingForRequester:kDSKeyboardRequester];
        }
    } @catch (NSException *exception) {
    }
    [_hostView removeFromSuperview];
    _hostView = nil;
    _hostManager = nil;
    _window = nil;
}

- (DSKeyboardHostWindow *)window {
    if (_window) return _window;

    UIWindowScene *windowScene = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
            if ([candidate isKindOfClass:UIWindowScene.class]) {
                windowScene = (UIWindowScene *)candidate;
                break;
            }
        }
    }

    DSKeyboardHostWindow *window = windowScene
        ? [[DSKeyboardHostWindow alloc] initWithWindowScene:windowScene]
        : [[DSKeyboardHostWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    window.frame = UIScreen.mainScreen.bounds;
    // The same portrait-locked, status-bar-free root the card has: a keyboard that
    // rotated with the device while the card could not would be rotating on its own.
    window.rootViewController = [[DSStageRootViewController alloc] init];
    window.backgroundColor = UIColor.clearColor;
    window.opaque = NO;
    // Above the card, so a keyboard is never behind the app that asked for it, and
    // below the status bar and system alerts.
    window.windowLevel = UIWindowLevelStatusBar - 0.5;
    window.hidden = YES;
    _window = window;
    return _window;
}

@end
