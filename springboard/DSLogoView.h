#import <UIKit/UIKit.h>

// The mark: a squircle with a curved arrow sweeping up out of the bottom-right
// corner, which is exactly the gesture the tweak is built around. Drawn with
// Core Graphics so nothing has to ship as an image asset.
@interface DSLogoView : UIView

@property (nonatomic, strong) UIColor *markColor;    // the squircle
@property (nonatomic, strong) UIColor *arrowColor;   // the arrow inside it

+ (UIImage *)logoImageWithSize:(CGSize)size
                     markColor:(UIColor *)markColor
                    arrowColor:(UIColor *)arrowColor;

@end
