#import "DSLogoView.h"

// Traces the arrow on a 100x100 canvas so callers can draw it at any size.
static UIBezierPath *DSArrowPath(CGFloat side) {
    CGFloat u = side / 100.0;
    UIBezierPath *path = [UIBezierPath bezierPath];

    // Tail: starts low on the right, sweeps left and then turns upward.
    [path moveToPoint:CGPointMake(84.0 * u, 90.0 * u)];
    [path addCurveToPoint:CGPointMake(50.0 * u, 46.0 * u)
            controlPoint1:CGPointMake(58.0 * u, 82.0 * u)
            controlPoint2:CGPointMake(50.0 * u, 66.0 * u)];
    [path addLineToPoint:CGPointMake(50.0 * u, 34.0 * u)];

    // Head.
    [path addLineToPoint:CGPointMake(32.0 * u, 34.0 * u)];
    [path addLineToPoint:CGPointMake(50.0 * u, 13.0 * u)];
    [path addLineToPoint:CGPointMake(68.0 * u, 34.0 * u)];
    [path addLineToPoint:CGPointMake(58.0 * u, 34.0 * u)];

    [path addLineToPoint:CGPointMake(58.0 * u, 46.0 * u)];
    [path addCurveToPoint:CGPointMake(78.0 * u, 73.0 * u)
            controlPoint1:CGPointMake(58.0 * u, 60.0 * u)
            controlPoint2:CGPointMake(64.0 * u, 68.0 * u)];
    [path closePath];
    return path;
}

@implementation DSLogoView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        self.userInteractionEnabled = NO;
        _markColor = UIColor.whiteColor;
        _arrowColor = UIColor.blackColor;
    }
    return self;
}

- (void)setMarkColor:(UIColor *)markColor {
    _markColor = markColor;
    [self setNeedsDisplay];
}

- (void)setArrowColor:(UIColor *)arrowColor {
    _arrowColor = arrowColor;
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    CGFloat side = MIN(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds));
    CGRect square = CGRectMake((CGRectGetWidth(self.bounds) - side) / 2.0,
                               (CGRectGetHeight(self.bounds) - side) / 2.0,
                               side, side);

    UIBezierPath *squircle = [UIBezierPath bezierPathWithRoundedRect:square cornerRadius:side * 0.42];
    [self.markColor setFill];
    [squircle fill];

    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, CGRectGetMinX(square), CGRectGetMinY(square));
    [self.arrowColor setFill];
    [DSArrowPath(side) fill];
    CGContextRestoreGState(context);
}

+ (UIImage *)logoImageWithSize:(CGSize)size
                     markColor:(UIColor *)markColor
                    arrowColor:(UIColor *)arrowColor {
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    DSLogoView *view = [[DSLogoView alloc] initWithFrame:CGRectMake(0, 0, size.width, size.height)];
    view.markColor = markColor ?: UIColor.whiteColor;
    view.arrowColor = arrowColor ?: UIColor.blackColor;
    [view drawRect:view.bounds];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

@end
