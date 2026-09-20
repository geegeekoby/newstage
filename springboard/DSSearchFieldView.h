#import <UIKit/UIKit.h>

@class DSSearchFieldView;

@protocol DSSearchFieldDelegate <NSObject>
- (void)searchField:(DSSearchFieldView *)field didChangeText:(NSString *)text;
- (void)searchFieldDidCancel:(DSSearchFieldView *)field;
@end

// The stage's search field: translucent plate, leading magnifier, trailing clear
// button once there is text.
@interface DSSearchFieldView : UIView

@property (nonatomic, weak) id<DSSearchFieldDelegate> delegate;
@property (nonatomic, assign) BOOL darkMode;
@property (nonatomic, readonly, copy) NSString *text;

- (void)clearText;

@end
