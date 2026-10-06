#import <UIKit/UIKit.h>

// 4.5.651: touch catcher for the stage rim.
//
// Why it exists: a touch is routed to a process by the window server BEFORE
// UIKit's hitTest runs. It looks at the layers on screen; a SpringBoard view
// that draws nothing (clear background) does not count there, so a touch on
// the transparent rim band went to the app drawn underneath (the full-screen
// app outside the stage, or the hosted app's own layer inside the card edge)
// and SpringBoard's pan never heard about it. Only the 3pt outline line itself
// was "solid", which is why the rim worked sometimes and was hard to grab.
//
// A catcher is an invisible strip that the window server treats as solid
// (near-zero alpha fill plus hitTestsAsOpaque where the build has it), laid
// exactly over the rim band. It does not do any gesture work itself: hitTest
// hands the touch to `touchOwner` (the view whose recognizers own the rim),
// except for a visible control of the card under the point.
@interface DSRimCatcherView : UIView
@property (nonatomic, weak) UIView *touchOwner;
// Optional: a card whose visible controls (the + button) keep their taps.
@property (nonatomic, weak) UIView *controlsView;
@property (nonatomic, copy) NSString *catcherName; // for the log, e.g. "main-outer"
@end

#ifdef __cplusplus
extern "C" {
#endif
// Creates the four strips (top, bottom, left, right) as subviews of `parent`.
NSArray<DSRimCatcherView *> *DSMakeRimCatchers(UIView *parent, NSString *name, UIView *owner);
// Lays the four strips over the ring between `outerRect` and `innerRect`
// (both in parent coordinates). Parts on the home bar, below `cutBottomY`
// (parent coordinates, CGFLOAT_MAX for none) or with no area are hidden.
void DSLayoutRimCatchers(NSArray<DSRimCatcherView *> *strips, UIView *parent, CGRect outerRect, CGRect innerRect, CGFloat cutBottomY, BOOL enabled);
// Same, and no strip covers `avoidWindowRect` (window coordinates; the other
// split card's interior, which must keep reaching its own app).
void DSLayoutRimCatchersAvoiding(NSArray<DSRimCatcherView *> *strips, UIView *parent, CGRect outerRect, CGRect innerRect, CGFloat cutBottomY, BOOL enabled, CGRect avoidWindowRect);
// Rate-limited diagnostics line: "SpringBoard: rim651 <text>".
void DSRimLog(NSString *text);
#ifdef __cplusplus
}
#endif
