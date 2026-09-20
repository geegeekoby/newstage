#import <UIKit/UIKit.h>

// The table header on the root page: a blurred, slowly drifting wallpaper crop
// with the wordmark stacked over it and the package version underneath.
@interface DSBannerHeaderView : UIView

- (instancetype)initWithBundle:(NSBundle *)bundle;

@property (nonatomic, readonly) CGFloat preferredHeight;

// Called from scrollViewDidScroll: so the artwork parallaxes and the wordmark
// fades out as the list is pulled up, like the stock banner does.
- (void)updateForContentOffset:(CGPoint)offset;

@end
