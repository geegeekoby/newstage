#import <UIKit/UIKit.h>

// Keeps the keyboard of a staged app off the card and on the display.
//
// A keyboard is never drawn by the app that asked for it. UIKit draws it into a scene
// of its own - one scene for the whole device, owned by the keyboard arbiter running
// in SpringBoard - and the app's scene is given a proxy layer standing in for it.
// Whoever hosts the app's scene hosts that proxy layer too, which is why a keyboard
// normally appears inside the app: the app is full screen, so "inside the app" and
// "on the bottom edge of the display" are the same place.
//
// On the stage they are not the same place at all. The card is a small rectangle in
// the corner, so the proxy layer draws the keyboard inside the card, shrunk and
// clipped. So the stage does what iPad multitasking does: it refuses the proxy layer
// in the card and hosts the keyboard's own scene itself, in a window the size of the
// display. The keyboard then comes up where every other keyboard on the phone comes
// up, at its ordinary size, and the card moves up out of its way.
@interface DSKeyboardHost : NSObject

+ (instancetype)sharedHost;

// Finds every class in SpringBoard that decides whether a scene view may draw the
// keyboard layer, and takes over the decision. Safe to call more than once: a class
// loaded after the first pass - a framework SpringBoard opens on demand - is picked up
// by the next one.
//
// Nothing else here works without it. Taking the keyboard out of the card is what makes
// room to put it on the display, and hosting the keyboard's scene while the card is
// still drawing it would only be two claims on one keyboard. So on a build where this
// finds nothing, the stage leaves the keyboard exactly where it found it.
+ (void)refuseTheKeyboardLayerWhereverItIsOffered;

// Writes down what this firmware's scene-hosting classes can be told about keyboards.
// Nothing here reads it: it is for the person holding the phone, because a keyboard in
// the card looks the same whether the refusal above failed or was never possible.
+ (void)surveyTheKeyboardLevers;

// Which way the arbiter is currently putting the keyboard's scene on screen.
- (void)noteHowTheKeyboardIsPresented;

@property (nonatomic, assign) BOOL keyboardLayerCanBeRefused;

// The arbiter, handed over from the hook on it. It owns the keyboard's scene, and
// taking it from here means never having to guess at the name of the class that
// holds it.
- (void)noteArbiter:(id)arbiter;

// An app went onto the stage inside `window`: from now on its keyboard belongs to
// the display rather than to the card.
- (void)takeOverKeyboardForApplication:(NSString *)bundleIdentifier stageWindow:(UIWindow *)window;

// The stage closed, or the app on it went away.
- (void)standDown;

// The keyboard as the arbiter describes it, in display points, and who raised it.
// CGRectZero when there is none on screen. Only the staged app's keyboard is moved;
// SpringBoard's own - the stage's search field, Spotlight - is already in the right
// place and is left alone.
- (void)setKeyboardFrame:(CGRect)frame source:(NSString *)source;

// The card has gone off screen - put away or tucked into the corner - so whatever was
// hosted on the display goes with it. The takeover stays armed: the app is still on the
// stage and its keyboard still belongs out here when the card comes back.
- (void)keyboardIsNoLongerOnScreen;

// Answered by the hook on SpringBoard's scene views. YES means "this view is the
// stage's card, and the keyboard is not to be drawn in it".
+ (BOOL)shouldRefuseKeyboardLayerInView:(UIView *)view;

@end
