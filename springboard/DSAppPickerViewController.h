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
- (void)appPickerDidEndSearch:(DSAppPickerViewController *)picker;
- (BOOL)appPickerShouldWaitBeforeSearchEditing:(DSAppPickerViewController *)picker;
// 4.5.817 picker817: the long-press menu's card choices, each
// @{@"slot": NSNumber, @"title": NSString, @"here": NSNumber(BOOL)}.
- (NSArray<NSDictionary *> *)appPickerSlotChoices817:(DSAppPickerViewController *)picker;
- (void)appPicker:(DSAppPickerViewController *)picker didChooseEntry:(DSAppEntry *)entry slot817:(NSInteger)slot fromView:(UIView *)view;
@end

// What the stage shows when no app is loaded: a search field, a two column
// "Recently Opened" grid (with pinned apps first) and the full app library
// underneath, all in one scroll view clipped by the card.
@interface DSAppPickerViewController : UIViewController

@property (nonatomic, weak) id<DSAppPickerDelegate> delegate;
@property (nonatomic, assign) BOOL darkMode;
// Apps already on a stage, including ones minimized into a corner.
@property (nonatomic, copy) NSSet<NSString *> *unavailableBundleIdentifiers;

- (void)reloadContent;
- (void)resetScrollPosition;
- (void)dismissKeyboard;
- (void)reassertSearchEditing;
- (void)restartSearchEditing;
// 4.5.720: the search field is the first responder.
- (BOOL)searchFieldIsEditing;
- (NSString *)searchEditingDebugSummary;

@end

// 4.5.817 picker817: the redesigned picker when picker817 is on (and not
// crash-latched), else the classic one above. Off: picker817-off.
FOUNDATION_EXTERN DSAppPickerViewController *DSNewAppPicker817(void);
