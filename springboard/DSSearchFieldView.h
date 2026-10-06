#import <UIKit/UIKit.h>

@class DSSearchFieldView;

@protocol DSSearchFieldDelegate <NSObject>
- (void)searchField:(DSSearchFieldView *)field didChangeText:(NSString *)text;
- (void)searchFieldDidCancel:(DSSearchFieldView *)field;
@optional
- (void)searchFieldNeedsKeyWindow:(DSSearchFieldView *)field;
- (void)searchFieldDidEndEditing:(DSSearchFieldView *)field;
// YES while the stage card is still opening; editing is deferred until it lands.
- (BOOL)searchFieldShouldWaitBeforeEditing:(DSSearchFieldView *)field;
@end

// 4.5.650: absolute time of the last user tap on any stage search field
// (0 = never). The stage manager restarts its keyboard check for a tap that
// is newer than the check already running.
#ifdef __cplusplus
extern "C" {
#endif
CFAbsoluteTime DSSearchFieldLastUserTap(void);
#ifdef __cplusplus
}
#endif

// The stage's search field: translucent plate, leading magnifier, trailing clear
// button once there is text.
@interface DSSearchFieldView : UIView

@property (nonatomic, weak) id<DSSearchFieldDelegate> delegate;
@property (nonatomic, assign) BOOL darkMode;
@property (nonatomic, readonly, copy) NSString *text;

- (void)clearText;
// Asks the text field to edit again. Used when the keyboard did not appear.
- (void)reassertEditing;
// Ends editing and starts it again. reloadInputViews does not raise a keyboard
// that never appeared.
- (void)restartEditing;
// Read-only. fr/win/key/att for the diagnostics log.
- (NSString *)editingDebugSummary;

@end
