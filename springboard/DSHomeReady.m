#import "DSHomeReady.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static BOOL DSHomeScreenLooksReady(void) {
    Class iconClass = objc_getClass("SBIconController");
    if (iconClass == Nil) return NO;
    if (![iconClass respondsToSelector:@selector(sharedInstance)]) return NO;

    id icons = ((id (*)(id, SEL))objc_msgSend)(iconClass, @selector(sharedInstance));
    if (!icons) return NO;

    UIApplication *application = UIApplication.sharedApplication;
    if (!application) return NO;
    if (application.windows.count == 0) return NO;

    return YES;
}

static void DSPollHomeScreen(void (^ready)(void), NSInteger tries) {
    if (DSHomeScreenLooksReady() || tries >= 20) {
        ready();
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        DSPollHomeScreen(ready, tries + 1);
    });
}

void DSWhenHomeScreenIsReady(void (^ready)(void)) {
    if (!ready) return;

    static dispatch_once_t token;
    dispatch_once(&token, ^{
        void (^callback)(void) = [ready copy];
        // Home screen first. Jailbreak userspace reboot is not a respring: classes
        // and the icon controller are still coming up when ADFLaunching returns.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            DSPollHomeScreen(callback, 0);
        });
    });
}
