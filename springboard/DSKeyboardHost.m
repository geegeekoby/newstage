#import "DSKeyboardHost.h"
#import "DSStageWindow.h"
#import "DSPrivate.h"
#import "DSConstants.h"
#import "DSDiagnostics.h"
#import <objc/runtime.h>
#import <objc/message.h>

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
    __weak id _stagedAppScene;
    FBSceneHostManager *_hostManager;
    UIScenePresenter *_presenter;
    UIView *_hostView;
    CALayer *_proxyLayer;
    CALayer *_proxyLayerHome;
    CGRect _proxyLayerHomeFrame;
    BOOL _layerHuntQueued;
    BOOL _notedLayerHunt;
    BOOL _notedGiveUp;
    NSString *_whyNot;
    BOOL _askedForHostedKeyboard;
    BOOL _waitingOnTheArbiter;
    long long _presentationModeBefore;
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

// A scene, whatever it is called here. On this firmware the only thing every scene has
// in common is that it can be asked to present itself; the class that used to host one -
// FBSceneHostManager - does not exist on iOS 16 at all, which is what the log on the
// phone said and what left the keyboard nowhere.
static BOOL DSLooksLikeAScene(id object) {
    if (!object) return NO;
    if (![object respondsToSelector:@selector(identifier)]) return NO;
    return [object respondsToSelector:@selector(uiPresentationManager)] ||
           [object respondsToSelector:@selector(hostManagerForRequester:)];
}

static NSString *DSSceneName(id scene) {
    if (![scene respondsToSelector:@selector(identifier)]) return @"unnamed";
    @try {
        NSString *identifier = ((NSString * (*)(id, SEL))objc_msgSend)(scene, @selector(identifier));
        return identifier.length > 0 ? identifier : @"unnamed";
    } @catch (NSException *exception) {
        return @"unnamed";
    }
}

// The keyboard's scene, found by looking rather than by knowing the name of the thing
// that holds it. The arbiter is asked for its ivars, and any of them that turn out to be
// a scene, or to hold one, are candidates; the one whose name mentions a keyboard wins,
// and every name found is written down either way. Selector names move between releases
// and the guesses that were in here were all wrong on this build - what an object is
// actually holding does not move.
static id DSSceneHeldBy(id object, NSInteger depth, NSMutableSet *visited, NSMutableArray<NSString *> *names) {
    if (!object || depth < 0) return nil;
    NSValue *box = [NSValue valueWithNonretainedObject:object];
    if ([visited containsObject:box]) return nil;
    [visited addObject:box];

    id fallback = nil;
    for (Class candidate = object_getClass(object); candidate; candidate = class_getSuperclass(candidate)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(candidate, &count);
        if (!ivars) continue;

        for (unsigned int i = 0; i < count; i++) {
            const char *encoding = ivar_getTypeEncoding(ivars[i]);
            if (!encoding || encoding[0] != '@') continue;

            id value = nil;
            @try {
                value = object_getIvar(object, ivars[i]);
            } @catch (NSException *exception) {
                continue;
            }
            if (!value) continue;

            if (DSLooksLikeAScene(value)) {
                NSString *name = DSSceneName(value);
                [names addObject:name];
                if ([name rangeOfString:@"keyboard" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    free(ivars);
                    return value;
                }
                if (!fallback) fallback = value;
                continue;
            }

            // One level in: a keyboard scene is as likely to be held by something the
            // arbiter owns as by the arbiter itself.
            if (depth > 0) {
                id found = DSSceneHeldBy(value, depth - 1, visited, names);
                if (found) {
                    free(ivars);
                    return found;
                }
            }
        }
        free(ivars);
    }
    return fallback;
}

// The layer in a tree that is the size of the keyboard, and the ones that were passed over
// on the way to it. A keyboard is the full width of the display and a good part of its
// height, and nothing else in a card is that shape, so the size is enough to know it by -
// which matters, because the class it arrives as is not something to count on.
static CALayer *DSLayerTheSizeOfTheKeyboard(CALayer *root, CGSize wanted, NSMutableArray<NSString *> *seen) {
    if (wanted.height < 80.0 || wanted.width < 80.0) return nil;

    CALayer *best = nil;
    CGFloat bestScore = CGFLOAT_MAX;
    NSMutableArray<CALayer *> *queue = [NSMutableArray arrayWithObject:root];

    while (queue.count > 0) {
        CALayer *layer = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (layer.sublayers.count > 0) [queue addObjectsFromArray:layer.sublayers];

        CGSize size = layer.bounds.size;
        if (size.height < 80.0 || size.width < 80.0) continue;

        // Something that draws content of its own. The layers of an ordinary view
        // hierarchy - the card's own backdrop, its grabber - draw nothing and are not
        // candidates however close their size.
        BOOL drawsSomething = layer.contents != nil || [layer isKindOfClass:objc_getClass("CALayerHost")];
        if (!drawsSomething) continue;

        if (seen.count < 24) {
            [seen addObject:[NSString stringWithFormat:@"%@ %.0fx%.0f", NSStringFromClass([layer class]),
                                                      size.width, size.height]];
        }

        CGFloat score = fabs(size.width - wanted.width) + fabs(size.height - wanted.height);
        if (score < bestScore) {
            bestScore = score;
            best = layer;
        }
    }

    // Close enough to be the keyboard and not something else: a card is 430 points wide
    // at most and a keyboard is 300 tall, so the next thing down in size is nowhere near.
    return bestScore <= 140.0 ? best : nil;
}

// An object one of these is holding, chosen by the name of its class. Used to reach the
// things whose accessors have no name this can count on but whose classes say plainly
// what they are - a keyboard proxy layer manager among them.
static id DSHeldObjectNamedLike(id object, NSArray<NSString *> *words) {
    for (Class candidate = object_getClass(object); candidate && candidate != NSObject.class;
         candidate = class_getSuperclass(candidate)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(candidate, &count);
        if (!ivars) continue;
        for (unsigned int i = 0; i < count; i++) {
            const char *encoding = ivar_getTypeEncoding(ivars[i]);
            if (!encoding || encoding[0] != '@') continue;

            id value = nil;
            @try {
                value = object_getIvar(object, ivars[i]);
            } @catch (NSException *exception) {
                continue;
            }
            if (!value) continue;

            NSString *name = NSStringFromClass([value class]);
            for (NSString *word in words) {
                if ([name rangeOfString:word options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
                free(ivars);
                return value;
            }
        }
        free(ivars);
    }
    return nil;
}

// The methods of an object that take nothing, give something back, and are named after
// one of these words. Tried in turn when the name of the one that matters is unknown.
static NSArray<NSString *> *DSSelectorsNamedLike(id object, NSArray<NSString *> *words) {
    NSMutableArray<NSString *> *found = [NSMutableArray array];
    for (Class candidate = object_getClass(object); candidate && candidate != NSObject.class;
         candidate = class_getSuperclass(candidate)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(candidate, &count);
        if (!methods) continue;
        for (unsigned int i = 0; i < count; i++) {
            if (method_getNumberOfArguments(methods[i]) != 2) continue;
            char type[16] = {0};
            method_getReturnType(methods[i], type, sizeof(type));
            if (type[0] != '@') continue;

            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            if ([name hasPrefix:@"set"] || [name hasPrefix:@"remove"] ||
                [name hasPrefix:@"invalidate"] || [name hasPrefix:@"dealloc"]) continue;
            for (NSString *word in words) {
                if ([name rangeOfString:word options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
                [found addObject:name];
                break;
            }
        }
        free(methods);
    }
    return found;
}

// Every scene FrontBoard is holding, by name, written down once. This is the part of the
// keyboard that cannot be worked out from here: whether a hosted keyboard on this
// firmware is a scene of its own, and if so what it is called. The names in the log
// answer that, and the one that looks like a keyboard is used when the arbiter will not
// hand one over.
static FBScene *DSKeyboardSceneFromSceneManager(void) {
    Class managerClass = objc_getClass("FBSceneManager");
    if (![managerClass respondsToSelector:@selector(sharedInstance)]) return nil;
    id manager = ((id (*)(id, SEL))objc_msgSend)(managerClass, @selector(sharedInstance));

    NSArray *scenes = nil;
    for (NSString *name in @[ @"scenes", @"allScenes" ]) {
        SEL selector = NSSelectorFromString(name);
        if (![manager respondsToSelector:selector]) continue;
        @try {
            scenes = ((NSArray * (*)(id, SEL))objc_msgSend)(manager, selector);
        } @catch (NSException *exception) {
            scenes = nil;
        }
        if (scenes.count > 0) break;
    }

    FBScene *keyboard = nil;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (FBScene *scene in scenes) {
        if (!DSLooksLikeAScene(scene)) continue;
        NSString *identifier = DSSceneName(scene);
        [names addObject:identifier];
        if (!keyboard && [identifier rangeOfString:@"keyboard"
                                           options:NSCaseInsensitiveSearch].location != NSNotFound) {
            keyboard = scene;
        }
    }

    // Neither accessor exists on every build, so the scenes the manager is holding are
    // looked for in what it owns as well.
    if (names.count == 0) {
        keyboard = DSSceneHeldBy(manager, 2, [NSMutableSet set], names);
    }

    static BOOL noted = NO;
    if (!noted) {
        noted = YES;
        NSString *list = names.count > 0 ? [names componentsJoinedByString:@" "]
                                        : @"nothing FrontBoard will admit to";
        DSDiagnosticsRecordFormat(@"SpringBoard: the scenes here are %@", list);
    }
    return keyboard;
}

// A scene's layer reaches a host view as a layer host pointing at a context in the
// process that drew it. No context anywhere in the view means there is nothing on the
// other end: the view is in the right place and the right size and will draw nothing,
// which on screen is a keyboard that never appears - worse than a keyboard in the card.
static BOOL DSHostViewIsShowingSomething(UIView *view) {
    if (!view) return NO;

    NSMutableArray<CALayer *> *layers = [NSMutableArray arrayWithObject:view.layer];
    for (NSUInteger index = 0; index < layers.count && index < 64; index++) {
        CALayer *layer = layers[index];
        @try {
            if ([layer respondsToSelector:@selector(contextId)]) {
                uint32_t contextId = ((uint32_t (*)(id, SEL))objc_msgSend)(layer, @selector(contextId));
                if (contextId != 0) return YES;
            }
        } @catch (NSException *exception) {
        }
        if (layer.contents) return YES;
        if (layer.sublayers.count > 0) [layers addObjectsFromArray:layer.sublayers];
    }
    return NO;
}

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
        if (DSLooksLikeAScene(scene)) break;
        scene = nil;
    }

    // What the arbiter is holding, whatever it calls it. This is the route that matters
    // on iOS 16: the arbiter has updateKeyboardSceneSettings and a keyboard scene
    // presentation mode, so a keyboard scene is in there somewhere, but none of the
    // names it used to be reachable by are.
    if (!scene) {
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        scene = DSSceneHeldBy(arbiter, 2, [NSMutableSet set], names);
        if (names.count > 0) {
            DSDiagnosticsRecordFormat(@"SpringBoard: the keyboard arbiter is holding %@",
                                      [names componentsJoinedByString:@" "]);
        } else {
            DSDiagnosticsRecordFormat(@"SpringBoard: the keyboard arbiter (%@) is holding no scene at all",
                                      NSStringFromClass([arbiter class]));
        }
    }
    if (!scene) scene = DSKeyboardSceneFromSceneManager();

    if (!DSLooksLikeAScene(scene)) {
        DSDiagnosticsRecord(@"SpringBoard: nothing here owns a keyboard scene the stage could present");
        return nil;
    }

    _keyboardScene = scene;
    DSDiagnosticsRecordFormat(@"SpringBoard: the keyboard's own scene is %@", DSSceneName(scene));
    return _keyboardScene;
}

#pragma mark - Arming

- (void)takeOverKeyboardForApplication:(NSString *)bundleIdentifier stageWindow:(UIWindow *)window {
    _stageWindow = window;
    if (_armed && [_bundleIdentifier isEqualToString:bundleIdentifier]) return;
    _bundleIdentifier = [bundleIdentifier copy];
    _armed = YES;
    _hostingFailed = NO;
    _notedGiveUp = NO;
    // Whatever SpringBoard has opened since it started is scanned again here: the class
    // that draws a hosted app is not necessarily loaded when a phone finishes booting.
    if (!_keyboardLayerCanBeRefused) [DSKeyboardHost refuseTheKeyboardLayerWhereverItIsOffered];
    DSDiagnosticsRecordFormat(@"SpringBoard: %@'s keyboard now belongs to the display, not to the card",
                              bundleIdentifier);
}

- (void)noteStagedAppScene:(id)scene {
    _stagedAppScene = scene;
}

- (void)standDown {
    _stageWindow = nil;
    _bundleIdentifier = nil;
    _stagedAppScene = nil;
    if (!_armed) return;
    _armed = NO;
    _hostingFailed = NO;
    _keyboardFrame = CGRectZero;
    [self putTheKeyboardModeBack];
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

// What this firmware actually offers. All of the above rests on one private method
// existing, and from outside the phone the two possible failures look identical: a
// keyboard in the card because the refusal did not work, and a keyboard in the card
// because there was never anything here to refuse it with. So the classes that host a
// scene are asked what they can be told about keyboards, once, and the answer is
// written down. The names on their own are enough to say which of them could stand in.
+ (void)surveyTheKeyboardLevers {
    NSArray<NSString *> *names = @[ @"FBSceneManager", @"FBSceneHostManager", @"FBSceneHostView",
                                    @"UIScenePresentationManager", @"UIScenePresenter",
                                    @"_UISceneLayerHostContainerView", @"SBSceneView",
                                    @"SBDeviceApplicationSceneView", @"SBAppViewController",
                                    @"_UIKeyboardArbiter" ];
    NSMutableArray<NSString *> *missing = [NSMutableArray array];

    for (NSString *name in names) {
        Class candidate = objc_getClass(name.UTF8String);
        if (!candidate) {
            [missing addObject:name];
            continue;
        }

        NSMutableArray<NSString *> *found = [NSMutableArray array];
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(candidate, &methodCount);
        if (methods) {
            for (unsigned int i = 0; i < methodCount; i++) {
                NSString *selector = NSStringFromSelector(method_getName(methods[i]));
                if ([selector rangeOfString:@"eyboard"].location == NSNotFound) continue;
                [found addObject:selector];
            }
            free(methods);
        }
        if (found.count == 0) continue;

        // In pieces, because a line of the log is clipped and the name of the one
        // selector that turns out to matter is as likely to be at the end of this list
        // as at the front. The list for the keyboard arbiter alone runs past the clip.
        NSMutableString *line = [NSMutableString string];
        NSUInteger part = 1;
        for (NSString *selector in found) {
            if (line.length + selector.length + 1 > 280) {
                DSDiagnosticsRecordFormat(@"SpringBoard: %@ knows (%lu) %@", name, (unsigned long)part++, line);
                line = [NSMutableString string];
            }
            if (line.length > 0) [line appendString:@" "];
            [line appendString:selector];
        }
        if (line.length > 0) {
            DSDiagnosticsRecordFormat(@"SpringBoard: %@ knows (%lu) %@", name, (unsigned long)part, line);
        }
    }

    if (missing.count > 0) {
        DSDiagnosticsRecordFormat(@"SpringBoard: not on this firmware - %@",
                                  [missing componentsJoinedByString:@", "]);
    }
    [[DSKeyboardHost sharedHost] noteHowTheKeyboardIsPresented];
}

// The arbiter decides how the keyboard's scene is put on screen, and it can be asked
// which way that currently is. The number on its own says nothing; the same number seen
// with a keyboard in an app and again with one in the stage is the difference between a
// keyboard this can move and a keyboard it cannot.
- (void)noteHowTheKeyboardIsPresented {
    id arbiter = _arbiter;
    if (!arbiter) return;
    SEL mode = NSSelectorFromString(@"keyboardScenePresentationMode");
    if (![arbiter respondsToSelector:mode]) return;
    @try {
        long long value = ((long long (*)(id, SEL))objc_msgSend)(arbiter, mode);
        DSDiagnosticsRecordFormat(@"SpringBoard: the keyboard's scene is presented in mode %lld", value);
    } @catch (NSException *exception) {
    }
}

- (BOOL)refusesKeyboardLayerInView:(UIView *)view {
    if (!_armed || _hostingFailed || !_keyboardLayerCanBeRefused) return NO;
    UIWindow *stage = _stageWindow;
    if (!stage || !view) return NO;

    // Only the card. Every other scene view in SpringBoard - the app switcher's
    // cards, the app behind the stage, anything a future build puts on screen -
    // keeps its keyboard, because taking one away from a view the stage does not own
    // is a keyboard nobody can get back.
    BOOL isTheCard = NO;
    for (UIView *candidate = view; candidate; candidate = candidate.superview) {
        if (candidate == stage) {
            isTheCard = YES;
            break;
        }
    }
    if (!isTheCard) return NO;

    // A keyboard already on the display is refused here, because two claims on one
    // keyboard is a keyboard in both places or in neither.
    if (_hostView && !_proxyLayer) return YES;

    // Otherwise the card is allowed its keyboard layer and the layer is taken off it
    // afterwards. Refusing first is what kept the keyboard off the screen entirely on
    // this firmware: nothing here will draw a keyboard nobody has asked to host, so
    // refusing it in the one place that was drawing it left it nowhere. Being asked this
    // question is also the signal that a keyboard layer is about to exist, which is the
    // moment to go looking for one.
    [self takeTheKeyboardLayerSoon];
    return NO;
}

// Once, on the next turn of the runloop: the layer does not exist yet while the question
// is being asked, and the question is asked several times per keyboard.
- (void)takeTheKeyboardLayerSoon {
    if (_layerHuntQueued) return;
    _layerHuntQueued = YES;
    __weak __typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) host = weakSelf;
        if (!host) return;
        host->_layerHuntQueued = NO;
        if (!host->_armed || host->_hostingFailed) return;
        if (CGRectIsEmpty(host->_keyboardFrame)) return;
        [host takeAFreshKeyboardLayerIfTheCardHasOne];
        [host showKeyboardInOwnWindow];
    });
}

// The card was allowed its keyboard layer, so when the keyboard changes - a different
// keyboard, an accessory view appearing, a language switch - the app may draw a new layer
// in the card rather than reusing the one the stage borrowed. Left alone that is a
// keyboard on the display and another in the card at once, so the new one is taken and
// the old one goes back where it came from.
- (void)takeAFreshKeyboardLayerIfTheCardHasOne {
    UIWindow *stage = _stageWindow;
    if (!stage || !_hostView || !_proxyLayer) return;

    NSMutableArray<NSString *> *seen = [NSMutableArray array];
    CALayer *fresh = DSLayerTheSizeOfTheKeyboard(stage.layer, _keyboardFrame.size, seen);
    if (!fresh || fresh == _proxyLayer) return;

    [self giveBackTheKeyboardLayer];
    _proxyLayer = fresh;
    _proxyLayerHome = fresh.superlayer;
    _proxyLayerHomeFrame = fresh.frame;
    [_hostView.layer addSublayer:fresh];
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
    // The next keyboard is a new attempt: what could not be found for this one is not a
    // reason to leave every keyboard after it in the card.
    _hostingFailed = NO;

    // A borrowed layer is given back as soon as the keyboard it was drawing has gone, so
    // the next keyboard is the app's to draw and the stage starts again from nothing. A
    // hosted scene is left alone: that one is the keyboard's own and it costs a round trip
    // through another process to set up again.
    if (_proxyLayer) {
        [self giveBackTheKeyboardLayer];
        [_hostView removeFromSuperview];
        _hostView = nil;
    }
}

// A borrowed layer belongs to the app's scene, not to the stage, and it goes back exactly
// where it was found: a keyboard borrowed and not returned is an app that never draws one
// again.
- (void)giveBackTheKeyboardLayer {
    CALayer *borrowed = _proxyLayer;
    CALayer *home = _proxyLayerHome;
    CGRect homeFrame = _proxyLayerHomeFrame;
    _proxyLayer = nil;
    _proxyLayerHome = nil;
    if (!borrowed) return;

    [borrowed removeFromSuperlayer];
    if (!home) return;
    borrowed.frame = homeFrame;
    [home addSublayer:borrowed];
}

- (void)showKeyboardInOwnWindow {
    if (!_hostView) {
        _whyNot = nil;
        UIView *view = [self viewShowingTheKeyboard];
        if (!view) {
            if (_waitingOnTheArbiter) return;
            [self giveUpHosting:_whyNot ?: @"the keyboard could not be put on the display"];
            return;
        }
        _hostView = view;
        DSDiagnosticsRecordFormat(@"SpringBoard: the keyboard is now drawn on the display at %@",
                                  NSStringFromCGRect(_keyboardFrame));
    }

    DSKeyboardHostWindow *window = [self window];
    _hostView.frame = [self hostViewFrameForScene:_keyboardScene inWindow:window];
    _proxyLayer.frame = CGRectOffset(_keyboardFrame, -CGRectGetMinX(_hostView.frame),
                                     -CGRectGetMinY(_hostView.frame));
    if (_hostView.superview != window.rootViewController.view) {
        [window.rootViewController.view addSubview:_hostView];
    }
    window.liveFrame = _keyboardFrame;
    window.hidden = NO;
    @try {
        if ([_presenter respondsToSelector:@selector(activate)]) [_presenter activate];
    } @catch (NSException *exception) {
    }
    [self checkTheKeyboardActuallyArrived];
}

// Every step above can succeed and still leave nothing on screen: the scene hands out a
// host view whether or not it has a layer to put in it, and a keyboard that has been
// taken out of the card and not drawn anywhere is the one outcome worse than the problem
// this is here to fix - the card lifts out of the way of a keyboard that is not there,
// and there is no way to type.
//
// So it is checked, once the layer has had a beat to arrive, and if there is nothing on
// the other end the takeover is abandoned and the card gets its keyboard back.
- (void)checkTheKeyboardActuallyArrived {
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) host = weakSelf;
        if (!host || host->_hostingFailed || !host->_armed) return;
        if (CGRectIsEmpty(host->_keyboardFrame) || !host->_hostView) return;
        if (DSHostViewIsShowingSomething(host->_hostView)) return;
        [host giveUpHosting:@"the keyboard's scene had nothing to draw"];
    });
}

// Why a route could not be the one. Every route is written down rather than only the
// first, because the first is the one that has already been explained three times and
// the last is the one that has not.
- (void)note:(NSString *)reason {
    if (reason.length == 0) return;
    _whyNot = _whyNot.length > 0 ? [NSString stringWithFormat:@"%@, then %@", _whyNot, reason] : reason;
}

// The keyboard, on the display, by whichever route this firmware has. Each one records
// why it could not be the one, and the card only gets the keyboard back when they have
// all been tried.
- (UIView *)viewShowingTheKeyboard {
    // The layer in the card comes first, because it is the only one of these that does
    // not depend on the phone agreeing to host a keyboard it has no reason to host. The
    // keyboard is already drawn, in the card, at the wrong size: this takes that layer
    // and puts it on the display at the right one.
    UIView *view = [self viewShowingTheStolenKeyboardLayer];
    if (view) return view;

    FBScene *scene = [self keyboardScene];
    if (scene) {
        view = [self viewShowingScene:scene];
        if (view) return view;
    } else {
        [self note:@"there is no keyboard scene on this build"];
    }

    // The keyboard's scene has no presentation manager because nothing is presenting it:
    // the arbiter says the keyboard is in mode 0, the app draws its own, and the hosted
    // scene is a shell waiting to be asked for. So it is asked for.
    if (scene && [self askTheArbiterToHostTheKeyboard]) return nil;

    return [self viewShowingTheKeyboardProxyLayer];
}

// The keyboard's layer, taken out of the card.
//
// The app draws its keyboard into its own scene, as a layer of its own, and the card
// hosts that scene. Which is why the keyboard appears in the card, shrunk: it is a layer
// in a tree the card is scaling. It is also why it can simply be moved. The layer is
// found by its size - the arbiter says how big the keyboard is, in display points, and in
// the scene's own tree it is that size exactly, whatever the card is doing to it - and
// once it is in the stage's own window it is at the size the phone intended.
- (UIView *)viewShowingTheStolenKeyboardLayer {
    UIWindow *stage = _stageWindow;
    if (!stage || CGRectIsEmpty(_keyboardFrame)) {
        [self note:@"there is no card to take a keyboard layer from"];
        return nil;
    }

    NSMutableArray<NSString *> *seen = [NSMutableArray array];
    CALayer *keyboard = DSLayerTheSizeOfTheKeyboard(stage.layer, _keyboardFrame.size, seen);
    if (!keyboard) {
        // Only when there is nothing, and only once per keyboard: what the card is
        // holding is the answer to why the keyboard cannot be found in it.
        if (!_notedLayerHunt) {
            _notedLayerHunt = YES;
            [self recordNames:seen under:[NSString stringWithFormat:@"looking for a %@ keyboard the card holds",
                                                                   NSStringFromCGSize(_keyboardFrame.size)]];
        }
        [self note:@"the card has no layer the size of the keyboard"];
        return nil;
    }

    UIView *carrier = [[UIView alloc] initWithFrame:_keyboardFrame];
    carrier.userInteractionEnabled = NO;
    _proxyLayer = keyboard;
    // Kept, so the layer can be given back exactly where it was found: a keyboard that
    // has been borrowed and not returned is an app that never draws one again.
    _proxyLayerHome = keyboard.superlayer;
    _proxyLayerHomeFrame = keyboard.frame;
    [carrier.layer addSublayer:keyboard];
    DSDiagnosticsRecordFormat(@"SpringBoard: the keyboard's own layer (%@, %@) came out of the card",
                              NSStringFromClass([keyboard class]), NSStringFromCGRect(_proxyLayerHomeFrame));
    return carrier;
}

// A view showing someone else's scene. There are two ways to ask for one and which of
// them exists depends on the firmware: iOS 16 presents a scene, and every version before
// it hosted one. The old way was all this had, which is why the keyboard went nowhere on
// a phone where FBSceneHostManager is not a class at all.
- (UIView *)viewShowingScene:(FBScene *)scene {
    @try {
        if ([scene respondsToSelector:@selector(uiPresentationManager)]) {
            UIScenePresentationManager *presentation = scene.uiPresentationManager;
            if (!presentation) {
                [self note:@"the keyboard's scene has no presentation manager"];
            } else {
                UIView *view = [self viewFromPresentationManager:presentation];
                if (view) return view;
            }
        }

        if ([scene respondsToSelector:@selector(hostManagerForRequester:)]) {
            _hostManager = [scene hostManagerForRequester:kDSKeyboardRequester];
            if (![_hostManager respondsToSelector:@selector(hostViewForRequester:enableAndOrderFront:)]) {
                [self note:@"the keyboard scene will not give out a host view here"];
                return nil;
            }
            return [_hostManager hostViewForRequester:kDSKeyboardRequester enableAndOrderFront:YES];
        }
    } @catch (NSException *exception) {
        [self note:[NSString stringWithFormat:@"showing the keyboard threw %@", exception.name ?: @"?"]];
    }
    return nil;
}

// Mode 0 is the keyboard as an iPhone has always drawn it: by the app, in the app's own
// scene, with a proxy layer where the card can see it. The arbiter can be told to present
// the keyboard's scene instead, which is what an iPad does when two apps share the
// display, and that is the state the stage needs. What the number for it is cannot be
// known from here, so each one is tried and the phone is asked afterwards whether the
// scene became presentable; whatever it was set to is put back if none of them do.
- (BOOL)askTheArbiterToHostTheKeyboard {
    id arbiter = _arbiter;
    SEL read = NSSelectorFromString(@"keyboardScenePresentationMode");
    SEL write = NSSelectorFromString(@"setKeyboardScenePresentationMode:");
    if (![arbiter respondsToSelector:read] || ![arbiter respondsToSelector:write]) {
        [self note:@"the arbiter will not say how the keyboard is presented"];
        return NO;
    }
    if (_askedForHostedKeyboard) return NO;

    long long current = 0;
    @try {
        current = ((long long (*)(id, SEL))objc_msgSend)(arbiter, read);
    } @catch (NSException *exception) {
        return NO;
    }
    _presentationModeBefore = current;
    _askedForHostedKeyboard = YES;

    for (long long mode = 1; mode <= 3; mode++) {
        if (mode == current) continue;
        @try {
            ((void (*)(id, SEL, long long))objc_msgSend)(arbiter, write, mode);
        } @catch (NSException *exception) {
            continue;
        }
        id presentation = nil;
        @try {
            presentation = [_keyboardScene respondsToSelector:@selector(uiPresentationManager)]
                ? _keyboardScene.uiPresentationManager
                : nil;
        } @catch (NSException *exception) {
        }
        DSDiagnosticsRecordFormat(@"SpringBoard: asked for the keyboard in mode %lld and its scene %@",
                                  mode, presentation ? @"now has a presentation manager"
                                                     : @"still has none");
        if (presentation) {
            _waitingOnTheArbiter = NO;
            return NO;  // The caller tries again immediately; the scene is ready now.
        }
    }

    // Asking is not answering: a scene starts being presented across processes, which
    // takes longer than the call. One more look in a moment, and if it is still nothing
    // the phone goes back to the keyboard it had.
    _waitingOnTheArbiter = YES;
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) host = weakSelf;
        if (!host) return;
        host->_waitingOnTheArbiter = NO;
        if (!host->_armed || host->_hostingFailed || CGRectIsEmpty(host->_keyboardFrame)) {
            [host putTheKeyboardModeBack];
            return;
        }
        [host showKeyboardInOwnWindow];
        if (!host->_hostView) [host putTheKeyboardModeBack];
    });
    return YES;
}

- (void)putTheKeyboardModeBack {
    if (!_askedForHostedKeyboard) return;
    _askedForHostedKeyboard = NO;
    id arbiter = _arbiter;
    SEL write = NSSelectorFromString(@"setKeyboardScenePresentationMode:");
    if (![arbiter respondsToSelector:write]) return;
    @try {
        ((void (*)(id, SEL, long long))objc_msgSend)(arbiter, write, _presentationModeBefore);
    } @catch (NSException *exception) {
    }
}

// The keyboard as the card sees it. The app's scene carries a proxy layer standing in for
// the keyboard - that is what the card was told not to draw - and the presentation of that
// scene is built with a keyboard proxy layer manager, by the name of its own initialiser.
// If the layer can be had from there it can be put on the display directly, which needs no
// scene of the keyboard's own and no arbiter's permission.
- (UIView *)viewShowingTheKeyboardProxyLayer {
    id scene = _stagedAppScene;
    if (![scene respondsToSelector:@selector(uiPresentationManager)]) {
        [self note:@"the staged app's scene cannot be asked about its keyboard"];
        return nil;
    }

    id presentation = nil;
    @try {
        presentation = ((id (*)(id, SEL))objc_msgSend)(scene, @selector(uiPresentationManager));
    } @catch (NSException *exception) {
    }
    if (!presentation) {
        [self note:@"the staged app's scene is not presented here either"];
        return nil;
    }

    id proxy = DSHeldObjectNamedLike(presentation, @[ @"keyboard", @"proxy" ]);
    if (!proxy) {
        [self recordWhatIsHeldBy:presentation];
        [self note:@"nothing here holds the keyboard's proxy layer"];
        return nil;
    }

    static BOOL noted = NO;
    if (!noted) {
        noted = YES;
        [self recordEverything:proxy under:[NSString stringWithFormat:@"the %@ has",
                                                                     NSStringFromClass([proxy class])]];
    }

    // Anything it will hand over that is a layer or a view is the keyboard: the names are
    // not known, so the ones that mention a keyboard, a proxy or a layer are tried.
    for (NSString *name in DSSelectorsNamedLike(proxy, @[ @"keyboard", @"proxy", @"layer", @"view" ])) {
        id result = nil;
        @try {
            result = ((id (*)(id, SEL))objc_msgSend)(proxy, NSSelectorFromString(name));
        } @catch (NSException *exception) {
            continue;
        }
        if ([result isKindOfClass:UIView.class]) {
            DSDiagnosticsRecordFormat(@"SpringBoard: the keyboard came from %@ as a %@",
                                      name, NSStringFromClass([result class]));
            return result;
        }
        if ([result isKindOfClass:CALayer.class]) {
            // The carrier covers the display, like a hosted scene's view does, and the
            // layer sits in it wherever the arbiter says the keyboard is.
            UIView *carrier = [[UIView alloc] initWithFrame:_keyboardFrame];
            _proxyLayer = result;
            [carrier.layer addSublayer:result];
            DSDiagnosticsRecordFormat(@"SpringBoard: the keyboard came from %@ as a %@ layer",
                                      name, NSStringFromClass([result class]));
            return carrier;
        }
    }

    [self note:@"the keyboard's proxy layer manager would not give out a layer"];
    return nil;
}

// The presentation manager makes the presenter, and what that is called is the one thing
// left that this cannot know from here: the name it had - createPresenterWithIdentifier: -
// is not on this firmware, and neither is the UIScenePresenter class, which means the
// presenter is only ever reached through a protocol and a factory whose name moved. So it
// is looked for: every method of the manager that makes something with "presenter" in its
// name is tried, in the order most likely to be a factory, and whichever hands back an
// object that owns a view wins. Every method it has is written to the log the first time
// through, so a build where none of them work still says why.
- (UIView *)viewFromPresentationManager:(id)presentation {
    NSMutableArray<NSString *> *factories = [NSMutableArray array];
    NSMutableArray<NSString *> *everything = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *takesAnObject = [NSMutableDictionary dictionary];

    for (Class candidate = object_getClass(presentation); candidate && candidate != NSObject.class;
         candidate = class_getSuperclass(candidate)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(candidate, &count);
        if (!methods) continue;
        for (unsigned int i = 0; i < count; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            [everything addObject:name];

            if ([name rangeOfString:@"resenter" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
            if ([name hasPrefix:@"set"] || [name hasPrefix:@"remove"] || [name hasPrefix:@"invalidate"]) continue;

            unsigned int arguments = method_getNumberOfArguments(methods[i]);
            if (arguments > 3) continue;
            if (arguments == 3) {
                // Only an object argument is safe to guess at, and the guess is the
                // requester's name, which is what every one of these has ever wanted.
                char type[16] = {0};
                method_getArgumentType(methods[i], 2, type, sizeof(type));
                if (type[0] != '@') continue;
                takesAnObject[name] = @YES;
            }
            [factories addObject:name];
        }
        free(methods);
    }

    static BOOL noted = NO;
    if (!noted) {
        noted = YES;
        [self recordNames:everything under:[NSString stringWithFormat:@"%@ has", NSStringFromClass([presentation class])]];
    }

    // A name that says it makes something comes first; a plain accessor is a last resort.
    [factories sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSInteger (^rank)(NSString *) = ^NSInteger(NSString *name) {
            if ([name rangeOfString:@"create" options:NSCaseInsensitiveSearch].location != NSNotFound) return 0;
            if ([name hasPrefix:@"new"] || [name hasPrefix:@"_new"]) return 1;
            if ([name rangeOfString:@"make" options:NSCaseInsensitiveSearch].location != NSNotFound) return 2;
            return 3;
        };
        NSInteger left = rank(a), right = rank(b);
        if (left != right) return left < right ? NSOrderedAscending : NSOrderedDescending;
        return [a compare:b];
    }];

    for (NSString *name in factories) {
        SEL selector = NSSelectorFromString(name);
        id presenter = nil;
        @try {
            if (takesAnObject[name]) {
                presenter = ((id (*)(id, SEL, id))objc_msgSend)(presentation, selector, kDSKeyboardRequester);
            } else {
                presenter = ((id (*)(id, SEL))objc_msgSend)(presentation, selector);
            }
        } @catch (NSException *exception) {
            continue;
        }
        if (![presenter respondsToSelector:@selector(presentationView)]) continue;

        UIView *view = nil;
        @try {
            view = ((UIView * (*)(id, SEL))objc_msgSend)(presenter, @selector(presentationView));
        } @catch (NSException *exception) {
            continue;
        }
        if (![view isKindOfClass:UIView.class]) continue;

        _presenter = presenter;
        DSDiagnosticsRecordFormat(@"SpringBoard: the keyboard is presented through %@, which gave back a %@",
                                  name, NSStringFromClass([view class]));
        // Activated once it is in a window, not here: an activated presenter with
        // nowhere to draw is the keyboard going missing all over again.
        return view;
    }

    // The manager is initialised with a keyboard proxy layer manager, by the name of its
    // own initialiser, and a proxy for the keyboard's layer is exactly what is wanted
    // here. If no presenter can be had, whatever it is holding is written down instead.
    [self recordWhatIsHeldBy:presentation];

    [self giveUpHosting:factories.count > 0
        ? @"none of the keyboard scene's presenters would give out a view"
        : @"the keyboard's presentation manager has no way to make a presenter"];
    return nil;
}

// What an object is holding, and what those things can do. Only worth the log when the
// named routes have all failed, which is where it is called from.
- (void)recordWhatIsHeldBy:(id)object {
    static NSMutableSet<NSString *> *already = nil;
    if (!already) already = [NSMutableSet set];
    NSString *owner = NSStringFromClass([object class]);
    if ([already containsObject:owner]) return;
    [already addObject:owner];

    for (Class candidate = object_getClass(object); candidate && candidate != NSObject.class;
         candidate = class_getSuperclass(candidate)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(candidate, &count);
        if (!ivars) continue;
        for (unsigned int i = 0; i < count; i++) {
            const char *encoding = ivar_getTypeEncoding(ivars[i]);
            if (!encoding || encoding[0] != '@') continue;

            id value = nil;
            @try {
                value = object_getIvar(object, ivars[i]);
            } @catch (NSException *exception) {
                continue;
            }
            if (!value) continue;

            NSString *name = NSStringFromClass([value class]);
            if ([name rangeOfString:@"keyboard" options:NSCaseInsensitiveSearch].location == NSNotFound &&
                [name rangeOfString:@"proxy" options:NSCaseInsensitiveSearch].location == NSNotFound &&
                [name rangeOfString:@"layer" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;

            NSMutableArray<NSString *> *selectors = [NSMutableArray array];
            for (Class inner = [value class]; inner && inner != NSObject.class; inner = class_getSuperclass(inner)) {
                unsigned int methodCount = 0;
                Method *methods = class_copyMethodList(inner, &methodCount);
                if (!methods) continue;
                for (unsigned int j = 0; j < methodCount; j++) {
                    [selectors addObject:NSStringFromSelector(method_getName(methods[j]))];
                }
                free(methods);
            }
            [self recordNames:selectors under:[NSString stringWithFormat:@"its %@ has", name]];
        }
        free(ivars);
    }
}

// Everything an object can be asked, for the log. The last resort of a keyboard that will
// not appear: the name of the method that would have worked is in here somewhere.
- (void)recordEverything:(id)object under:(NSString *)heading {
    NSMutableArray<NSString *> *selectors = [NSMutableArray array];
    for (Class candidate = object_getClass(object); candidate && candidate != NSObject.class;
         candidate = class_getSuperclass(candidate)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(candidate, &count);
        if (!methods) continue;
        for (unsigned int i = 0; i < count; i++) {
            [selectors addObject:NSStringFromSelector(method_getName(methods[i]))];
        }
        free(methods);
    }
    [self recordNames:selectors under:heading];
}

// A list of names, in pieces, because one line of the log is clipped and these run long.
- (void)recordNames:(NSArray<NSString *> *)names under:(NSString *)heading {
    NSMutableString *line = [NSMutableString string];
    NSUInteger part = 1;
    for (NSString *name in names) {
        if (line.length + name.length + 1 > 280) {
            DSDiagnosticsRecordFormat(@"SpringBoard: %@ (%lu) %@", heading, (unsigned long)part++, line);
            line = [NSMutableString string];
        }
        if (line.length > 0) [line appendString:@" "];
        [line appendString:name];
    }
    if (line.length > 0) {
        DSDiagnosticsRecordFormat(@"SpringBoard: %@ (%lu) %@", heading, (unsigned long)part, line);
    }
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
    // Said once. Giving up is now per keyboard rather than for the rest of the session -
    // a keyboard the stage could not find one moment may be there the next - and a line
    // in the log for every one of them would push everything else out of it.
    if (_notedGiveUp) {
        [self tearDownHosting];
        [_stageWindow setNeedsLayout];
        [_stageWindow layoutIfNeeded];
        return;
    }
    _notedGiveUp = YES;
    [self tearDownHosting];
    // The card was told it could not draw the keyboard while that answer still stood.
    // It does not stand any more, so the card is asked to lay out again and the keyboard
    // comes back for the one that is up rather than for the next one - the difference
    // between a field that cannot be typed into and one that can.
    [_stageWindow setNeedsLayout];
    [_stageWindow layoutIfNeeded];
    DSDiagnosticsRecordFormat(@"SpringBoard: the keyboard is back in the card - %@", reason);
}

- (void)tearDownHosting {
    [self hideWindow];
    [self giveBackTheKeyboardLayer];
    _notedLayerHunt = NO;
    @try {
        if ([_presenter respondsToSelector:@selector(deactivate)]) [_presenter deactivate];
        if ([_presenter respondsToSelector:@selector(invalidate)]) [_presenter invalidate];
    } @catch (NSException *exception) {
    }
    _presenter = nil;
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
