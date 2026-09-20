// Classes this dylib reaches into. The UIKit ones are private; the rest belong
// to third-party apps that hard-code portrait phone geometry and need a nudge
// once the stage resizes them.
//
// Every hook on these is safe to compile against a class that is not present at
// runtime: Logos simply skips the group.

#import <UIKit/UIKit.h>

@interface UITextEffectsWindow : UIWindow
- (CGRect)_boundsForInterfaceOrientation:(NSInteger)orientation;
@end

@interface UIInputSetHostView : UIView
@end

@interface UIInputResponderController : UIViewController
- (CGRect)_sceneBounds;
@end

@interface _UIFullscreenPresentationController : UIPresentationController
@end

// Twitter
@interface TFNPortraitScreenBoundsLockedContainerView : UIView
@end

@interface TFNToastWindow : UIWindow
@end

// TikTok
@interface AWEFeedTableView : UITableView
@end

// Messages
@interface CKMessageEntryView : UIView
@end

// Safari view service
@interface _SFBrowserNavigationBar : UIView
@end

@interface UIScreen (DSAppPrivate)
- (CGRect)_referenceBounds;
- (CGRect)applicationFrame;
@end

@interface UIWindow (DSAppPrivate)
- (CGRect)_boundsForInterfaceOrientation:(NSInteger)orientation;
- (CGRect)_referenceBounds;
- (CGRect)_sceneBounds;
- (BOOL)_shouldResizeWithScene;
- (BOOL)_shouldAdjustSizeClassesAndResizeWindow;
- (BOOL)_windowOwnsInterfaceOrientation;
- (BOOL)_transformLayerRotationsAreEnabled;
- (void)_sceneBoundsDidChange;
@end

@interface UIApplication (DSAppPrivate)
- (CGRect)_applicationFrameForInterfaceOrientation:(NSInteger)orientation
                              usingStatusbarHeight:(CGFloat)height
                                   ignoreStatusBar:(BOOL)ignore;
- (CGRect)_applicationFrameWithoutOverscanForInterfaceOrientation:(NSInteger)orientation
                                             usingStatusbarHeight:(CGFloat)height
                                                  ignoreStatusBar:(BOOL)ignore;
@end
