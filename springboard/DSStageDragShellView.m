#import "DSStageDragShellView.h"
#import "DSStageContainerView.h"
#import "DSRimCatcherView.h"
#import "DSConstants.h"

@implementation DSStageDragShellView {
    CAShapeLayer *_outlineLayer;
    CAShapeLayer *_pulseLayer;
    CGFloat _outlineSide;
    NSArray<DSRimCatcherView *> *_catchers;
    CGRect _catcherAvoid;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.clipsToBounds = NO;
        self.layer.masksToBounds = NO;
        _outlineLayer = [CAShapeLayer layer];
        _outlineLayer.fillColor = UIColor.clearColor.CGColor;
        _outlineLayer.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;
        _outlineLayer.lineWidth = 3.0;
        _outlineLayer.shadowOpacity = 0.0;
        [self.layer addSublayer:_outlineLayer];
        _pulseLayer = [CAShapeLayer layer];
        _pulseLayer.fillColor = UIColor.clearColor.CGColor;
        _pulseLayer.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.95].CGColor;
        _pulseLayer.lineWidth = 1.5;
        _pulseLayer.opacity = 0.0;
        [self.layer addSublayer:_pulseLayer];
        // 4.5.651: the band just outside the card wins the touch over the app
        // drawn under the stage (see DSRimCatcherView.h).
        _catchers = DSMakeRimCatchers(self, @"main-outer", self);
        _catcherAvoid = CGRectNull;
    }
    return self;
}

- (void)layoutRimCatchers {
    if (!_cardView || _cardView.superview != self || _cardView.hidden) {
        DSLayoutRimCatchers(_catchers, self, CGRectZero, CGRectZero, CGFLOAT_MAX, NO);
        return;
    }
    // frame includes the card's lift / side translation.
    CGRect card = _cardView.frame;
    CGFloat cut = CGFLOAT_MAX;
    if (_cardView.keyboardBandHeight > 1.0) cut = CGRectGetMaxY(card) - _cardView.keyboardBandHeight;
    DSLayoutRimCatchersAvoiding(_catchers, self, CGRectInset(card, -kDSRimOuterCatch, -kDSRimOuterCatch), card, cut, YES, _catcherAvoid);
}

- (void)setRimCatcherAvoidRect:(CGRect)windowRect {
    _catcherAvoid = windowRect;
    [self layoutRimCatchers];
}

static UIBezierPath *DSShellBottomRim(CGRect rect, CGFloat radius) {
    CGFloat r = MIN(radius, MIN(CGRectGetWidth(rect), CGRectGetHeight(rect)) * 0.5);
    CGFloat minX = CGRectGetMinX(rect);
    CGFloat maxX = CGRectGetMaxX(rect);
    CGFloat maxY = CGRectGetMaxY(rect);
    CGFloat midY = CGRectGetMidY(rect);
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(minX, midY)];
    [path addLineToPoint:CGPointMake(minX, maxY - r)];
    [path addArcWithCenter:CGPointMake(minX + r, maxY - r) radius:r startAngle:M_PI endAngle:M_PI_2 clockwise:YES];
    [path addLineToPoint:CGPointMake(maxX - r, maxY)];
    [path addArcWithCenter:CGPointMake(maxX - r, maxY - r) radius:r startAngle:M_PI_2 endAngle:0 clockwise:YES];
    [path addLineToPoint:CGPointMake(maxX, midY)];
    return path;
}

static UIBezierPath *DSShellTopRim(CGRect rect, CGFloat radius) {
    CGFloat r = MIN(radius, MIN(CGRectGetWidth(rect), CGRectGetHeight(rect)) * 0.5);
    CGFloat minX = CGRectGetMinX(rect);
    CGFloat maxX = CGRectGetMaxX(rect);
    CGFloat minY = CGRectGetMinY(rect);
    CGFloat midY = CGRectGetMidY(rect);
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(minX, midY)];
    [path addLineToPoint:CGPointMake(minX, minY + r)];
    [path addArcWithCenter:CGPointMake(minX + r, minY + r) radius:r startAngle:M_PI endAngle:-M_PI_2 clockwise:NO];
    [path addLineToPoint:CGPointMake(maxX - r, minY)];
    [path addArcWithCenter:CGPointMake(maxX - r, minY + r) radius:r startAngle:-M_PI_2 endAngle:0 clockwise:NO];
    [path addLineToPoint:CGPointMake(maxX, midY)];
    return path;
}

- (void)refreshOutline {
    if (!_cardView) return;
    CGRect rim = CGRectInset(_cardView.frame, -1.0, -1.0);
    CGFloat radius = _cardView.cornerRadius + 1.0;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    // A border on the card's own corner curve. A bezier path stayed circular
    // and was the outline left outside a square fill.
    _outlineLayer.path = nil;
    _outlineLayer.frame = rim;
    _outlineLayer.cornerRadius = radius;
    _outlineLayer.cornerCurve = kCACornerCurveContinuous;
    _outlineLayer.borderWidth = 3.0;
    _outlineLayer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;
    _outlineLayer.masksToBounds = NO;
    UIBezierPath *half = nil;
    if (_rimHalf == 1) half = DSShellBottomRim(rim, radius);
    else if (_rimHalf == 2) half = DSShellTopRim(rim, radius);
    _pulseLayer.frame = self.bounds;
    _pulseLayer.path = half.CGPath;
    [CATransaction commit];
    [self layoutRimCatchers];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self refreshOutline];
}

- (void)setRimHalf:(NSInteger)rimHalf {
    if (_rimHalf == rimHalf) return;
    _rimHalf = rimHalf;
    [self setNeedsLayout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (rimHalf == 0) {
        [_pulseLayer removeAnimationForKey:@"rimPulse"];
        _pulseLayer.opacity = 0.0;
    } else {
        _pulseLayer.opacity = 1.0;
        if (![_pulseLayer animationForKey:@"rimPulse"]) {
            CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
            pulse.fromValue = @0.2;
            pulse.toValue = @1.0;
            pulse.duration = 0.55;
            pulse.autoreverses = YES;
            pulse.repeatCount = HUGE_VALF;
            [_pulseLayer addAnimation:pulse forKey:@"rimPulse"];
        }
    }
    [CATransaction commit];
    [self layoutIfNeeded];
}

- (void)setGhostRed:(BOOL)red {
    (void)red;
    _outlineLayer.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;
    _outlineLayer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;
    _outlineLayer.shadowOpacity = 0.0;
}

- (void)setOutlineLift:(CGFloat)offset {
    [self setOutlineShiftX:_outlineSide lift:offset];
}

- (void)setOutlineShiftX:(CGFloat)side lift:(CGFloat)offset {
    _outlineSide = side;
    CATransform3D shift = CATransform3DMakeTranslation(side, -offset, 0.0);
    _outlineLayer.transform = shift;
    _pulseLayer.transform = shift;
    [self layoutRimCatchers];
}

- (CGRect)outlineFrame {
    return _outlineLayer.frame;
}

- (void)clearOutline {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _outlineLayer.path = nil;
    _outlineLayer.borderWidth = 0.0;
    _pulseLayer.path = nil;
    _pulseLayer.opacity = 0.0;
    [CATransaction commit];
    DSLayoutRimCatchers(_catchers, self, CGRectZero, CGRectZero, CGFLOAT_MAX, NO);
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    (void)event;
    // The card slides on a transform, so a drop onto the keyboard or a lift
    // sits outside this shell. The touch still belongs to that card.
    BOOL inShell = CGRectContainsPoint(CGRectInset(self.bounds, -8.0, -8.0), point);
    BOOL inCard = NO;
    if (_cardView) {
        CGRect reach = CGRectInset(_cardView.frame, -36.0, -36.0);
        inCard = CGRectContainsPoint(reach, point);
    }
    if (!inShell && !inCard) return NO;
    if (self.rejectsWindowPoint) {
        CGPoint windowPoint = [self convertPoint:point toView:nil];
        if (self.rejectsWindowPoint(windowPoint)) return NO;
    }
    return YES;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.userInteractionEnabled || self.hidden || self.alpha < 0.01) return nil;
    if (![self pointInside:point withEvent:event]) return nil;

    // 4.5.651: the rim strips first (they are what the window server routed
    // this touch to SpringBoard for).
    for (DSRimCatcherView *strip in _catchers) {
        if (strip.hidden) continue;
        UIView *hit = [strip hitTest:[self convertPoint:point toView:strip] withEvent:event];
        if (hit) return hit;
    }
    if (_cardView && CGRectContainsPoint(_cardView.frame, point)) {
        CGPoint inCard = [self convertPoint:point toView:_cardView];
        return [_cardView hitTest:inCard withEvent:event];
    }
    return self;
}

@end
