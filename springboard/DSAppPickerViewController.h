#import <UIKit/UIKit.h>
#import "DSAppLibrary.h"

@class DSAppPickerViewController;

@protocol DSAppPickerDelegate <NSObject>
// `view` is the tapped plate, used as the source geometry for the launch zoom.
- (void)appPicker:(DSAppPickerViewController *)picker didSelectEntry:(DSAppEntry *)entry fromView:(UIView *)view;
// Held down long enough for the fill to complete: hand the app the whole screen.
- (void)appPicker:(DSAppPickerViewController *)picker didHoldEntry:(DSAppEntry *)entry fromView:(UIView *)view;
@optional
- (void)appPickerNeedsKeyWindowForSearch:(DSAppPickerViewController *)picker;
@end

// What the stage shows when no app is loaded: a search field, a two column
// "Recently Opened" grid (with pinned apps first) and the full app library
// underneath, all in one scroll view clipped by the card.
@interface DSAppPickerViewController : UIViewController

@property (nonatomic, weak) id<DSAppPickerDelegate> delegate;
@property (nonatomic, assign) BOOL darkMode;

- (void)reloadContent;
- (void)resetScrollPosition;
- (void)dismissKeyboard;
- (BOOL)isSearching;

// Where an app's plate currently sits, so the stage can zoom an app back into
// it when it is dismissed. CGRectNull when the app has no visible plate.
- (CGRect)plateFrameForBundleIdentifier:(NSString *)bundleIdentifier inView:(UIView *)view;

@end
