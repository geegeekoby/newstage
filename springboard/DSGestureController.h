#import <UIKit/UIKit.h>

@class DSGestureController;

@protocol DSGestureControllerDelegate <NSObject>
- (BOOL)gestureControllerShouldBegin:(DSGestureController *)controller atPoint:(CGPoint)point;
- (void)gestureControllerDidBegin:(DSGestureController *)controller;
- (void)gestureController:(DSGestureController *)controller didUpdateTranslation:(CGPoint)translation;
- (void)gestureController:(DSGestureController *)controller didEndWithTranslation:(CGPoint)translation velocity:(CGPoint)velocity;
- (void)gestureControllerDidCancel:(DSGestureController *)controller;
@end

// Owns the bottom right pull that summons the stage. Two modes, matching the
// stock tweak's Misc setting: "System" rides alongside the iOS home gesture and
// suppresses it for the hot corner, "Pan" is the standalone legacy recogniser.
@interface DSGestureController : NSObject

@property (nonatomic, weak) id<DSGestureControllerDelegate> delegate;
@property (nonatomic, readonly, getter=isTracking) BOOL tracking;

- (void)install;
- (void)invalidate;
- (void)reloadPreferences;

// Hot corner in screen coordinates, also consulted by the home gesture
// suppression hook.
+ (CGRect)triggerRect;
+ (BOOL)isPointInTriggerRect:(CGPoint)point;

@end
