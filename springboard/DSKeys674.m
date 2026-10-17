// 4.5.674 keys674: the empty band under the composer of a staged app that has
// no DynamicStage app dylib in it (Beeper on NathanLR, where App Store apps
// are not injected).
//
// A staged app's scene is shown in the card by UIKit's scene layer host
// (_UISceneLayerHostContainerView, inside SpringBoard's app view). Besides the
// app's own layers, that host can also show the app's keyboard layer, and it
// asks itself -_canShowKeyboardLayer before it does. On the phone's full
// screen that is right: the keyboard layer sits at the bottom of the app's
// scene, which is the bottom of the screen. In a 420x458 card the bottom of
// the app's scene is the bottom of the card, while the keys themselves are
// shown by SpringBoard's keyboard host at the bottom of the phone. An app
// without our dylib (nothing inside it moves its keyboard) then keeps its
// keyboard layer in the card under its composer: the band.
//
// keys674 answers NO to -_canShowKeyboardLayer for the scene host of a staged
// app without the dylib, so the card never shows that app's keyboard layer;
// the keys stay where they are now (SpringBoard's keyboard host). Apps with
// the dylib (Messages, Phone, injected Messenger / Signal / Beeper) keep the
// 4.5.664 keyboard handling untouched unless /var/mobile/.dynamicstage-keys674-all
// exists. Kill file: /var/mobile/.dynamicstage-keys674-off.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import "DSDiagnostics.h"
#import "DSStageManager.h"

static BOOL (*DSKeys674OrigCanShow)(id, SEL) = NULL;
static BOOL DSKeys674Installed = NO;

static BOOL DSKeys674FileCached(NSString *path, CFAbsoluteTime *checkedAt, BOOL *value) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - *checkedAt > 2.0 || now < *checkedAt) {
        *value = [[NSFileManager defaultManager] fileExistsAtPath:path];
        *checkedAt = now;
    }
    return *value;
}

static BOOL DSKeys674Off(void) {
    static CFAbsoluteTime at = 0;
    static BOOL value = NO;
    return DSKeys674FileCached(@"/var/mobile/.dynamicstage-keys674-off", &at, &value);
}

static BOOL DSKeys674All(void) {
    static CFAbsoluteTime at = 0;
    static BOOL value = NO;
    return DSKeys674FileCached(@"/var/mobile/.dynamicstage-keys674-all", &at, &value);
}

BOOL DSKeys674Active(void) {
    return DSKeys674Installed && !DSKeys674Off();
}

static void DSKeys674Note(NSString *key, NSString *line) {
    static NSMutableDictionary<NSString *, NSString *> *last = nil;
    if (!last) last = [NSMutableDictionary dictionary];
    if (key.length == 0 || line.length == 0) return;
    if ([last[key] isEqualToString:line]) return;
    if (last.count > 32) [last removeAllObjects];
    last[key] = line;
    DSDiagnosticsRecordFormat(@"SpringBoard: keys674 %@", line);
}

static NSString *DSKeys674SceneIdentifier(id host) {
    @try {
        if (![host respondsToSelector:@selector(scene)]) return nil;
        id scene = ((id (*)(id, SEL))objc_msgSend)(host, @selector(scene));
        if (![scene respondsToSelector:@selector(identifier)]) return nil;
        id identifier = ((id (*)(id, SEL))objc_msgSend)(scene, @selector(identifier));
        return [identifier isKindOfClass:NSString.class] ? identifier : nil;
    } @catch (NSException *exception) {
        return nil;
    }
}

static BOOL DSKeys674CanShowKeyboardLayer(id self, SEL _cmd) {
    BOOL original = DSKeys674OrigCanShow ? DSKeys674OrigCanShow(self, _cmd) : YES;
    if (!original || ![NSThread isMainThread] || DSKeys674Off()) return original;
    @try {
        NSString *identifier = DSKeys674SceneIdentifier(self);
        if (identifier.length == 0) return original;
        DSStageManager *manager = [DSStageManager sharedManager];
        NSString *bundle = [manager keys674HostedBundleForSceneIdentifier:identifier];
        if (bundle.length == 0) return original;
        // 4.5.683: an always-full-screen app shows its OWN keyboard inside the
        // card (the 430x931 scene puts it at the scene bottom, which the card shows).
        if ([manager respondsToSelector:@selector(phoneSize683ActiveForBundle:)] && [manager phoneSize683ActiveForBundle:bundle]) {
            DSKeys674Note([@"683." stringByAppendingString:bundle],
                          [NSString stringWithFormat:@"%@ (%@): phonesize683 keeps UIKit's answer (YES): the app's own keyboard layer is drawn inside its card", bundle, identifier]);
            return original;
        }
        BOOL dylib = [manager keys671AppHasDylib:bundle];
        if (dylib && !DSKeys674All()) {
            DSKeys674Note([@"keep." stringByAppendingString:bundle],
                          [NSString stringWithFormat:@"%@ has the app dylib: its card keeps UIKit's keyboard layer answer (YES), 4.5.664 handling unchanged", bundle]);
            return original;
        }
        DSKeys674Note([@"no." stringByAppendingString:bundle],
                      [NSString stringWithFormat:@"%@ (%@) %@: its card's scene host (%@) asked whether it can show the app's keyboard layer, UIKit said YES, keys674 answers NO "
                       @"(no keyboard layer inside the card; the keys stay in SpringBoard's keyboard host at the bottom of the phone)",
                       bundle, identifier, dylib ? @"has the app dylib (keys674-all file)" : @"has no DynamicStage app dylib",
                       NSStringFromClass(object_getClass(self))]);
        // 4.5.680: record the time (the earliest sign of this app's keyboard).
        if ([manager respondsToSelector:@selector(phoneSize680KeyboardLayerAskedFor:at:)]) {
            [manager phoneSize680KeyboardLayerAskedFor:bundle at:CACurrentMediaTime()];
        }
        return NO;
    } @catch (NSException *exception) {
        return original;
    }
}

void DSKeys674Install(void) {
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        Class cls = objc_getClass("_UISceneLayerHostContainerView");
        SEL sel = NSSelectorFromString(@"_canShowKeyboardLayer");
        if (!cls || !class_getInstanceMethod(cls, sel)) {
            DSDiagnosticsRecordFormat(@"SpringBoard: keys674 not available on this iOS (%@ %@): nothing changed",
                                      cls ? @"_UISceneLayerHostContainerView has no" : @"no _UISceneLayerHostContainerView,",
                                      @"-_canShowKeyboardLayer");
            return;
        }
        MSHookMessageEx(cls, sel, (IMP)DSKeys674CanShowKeyboardLayer, (IMP *)&DSKeys674OrigCanShow);
        DSKeys674Installed = DSKeys674OrigCanShow != NULL;
        DSDiagnosticsRecordFormat(@"SpringBoard: keys674 %@: staged apps without the DynamicStage app dylib get no keyboard layer inside their card "
                                  @"(off: /var/mobile/.dynamicstage-keys674-off, every staged app: /var/mobile/.dynamicstage-keys674-all)%@",
                                  DSKeys674Installed ? @"on" : @"hook failed",
                                  DSKeys674Off() ? @" - currently OFF by the kill file" : @"");
    });
}
