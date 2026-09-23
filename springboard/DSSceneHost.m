#import "DSSceneHost.h"
#import "DSConstants.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

@implementation DSSceneHost {
    UIView *_containerView;
    UIView *_hostedView;
    BOOL _hostingApp;
    BOOL _clipsContents;
    CGFloat _cornerRadius;
    CGFloat _liftOffset;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.clipsToBounds = YES;
        self.layer.masksToBounds = YES;
        self.layer.cornerCurve = kCACornerCurveContinuous;

        _containerView = [[UIView alloc] initWithFrame:CGRectZero];
        _containerView.backgroundColor = UIColor.clearColor;
        _containerView.clipsToBounds = YES;
        [self addSubview:_containerView];

        _cornerRadius = kDSFallbackDisplayCornerRadius;
        self.layer.cornerRadius = _cornerRadius;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGRect bounds = self.bounds;
    _containerView.frame = bounds;

    if (_hostedView) {
        _hostedView.frame = bounds;
    }

    if (_clipsContents) {
        self.layer.cornerRadius = _cornerRadius;
        _containerView.layer.cornerRadius = 0.0;
    } else {
        self.layer.cornerRadius = 0.0;
        _containerView.layer.cornerRadius = _cornerRadius;
        _containerView.layer.cornerCurve = kCACornerCurveContinuous;
    }

    if (_liftOffset > 0.0) {
        CGAffineTransform lift = CGAffineTransformMakeTranslation(0.0, -_liftOffset);
        self.transform = lift;
        _containerView.transform = lift;
    } else {
        self.transform = CGAffineTransformIdentity;
        _containerView.transform = CGAffineTransformIdentity;
    }
}

- (void)setHostedView:(UIView *)view {
    if (_hostedView) {
        [_hostedView removeFromSuperview];
    }
    _hostedView = view;
    if (view) {
        [_containerView addSubview:view];
        [self setNeedsLayout];
    }
}

- (UIView *)hostedView {
    return _hostedView;
}

- (void)setClipsContents:(BOOL)clips {
    _clipsContents = clips;
    self.clipsToBounds = clips;
    self.layer.masksToBounds = clips;
    _containerView.clipsToBounds = YES;
    [self setNeedsLayout];
}

- (void)setCornerRadius:(CGFloat)cornerRadius {
    _cornerRadius = cornerRadius;
    [self setNeedsLayout];
}

- (void)setLiftOffset:(CGFloat)offset {
    _liftOffset = offset;
    [self setNeedsLayout];
}

- (void)setHostingApp:(BOOL)hostingApp {
    _hostingApp = hostingApp;

    if (hostingApp) {
        _containerView.userInteractionEnabled = YES;
    } else {
        _containerView.userInteractionEnabled = NO;
    }
}

- (BOOL)hostingApp {
    return _hostingApp;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!_hostingApp) {
        return [super hitTest:point withEvent:event];
    }

    UIView *hit = [super hitTest:point withEvent:event];
    if (!hit) return nil;

    if (hit == _containerView || [hit isDescendantOfView:_containerView]) {
        return hit;
    }

    return nil;
}

- (void)setFrame:(CGRect)frame {
    [super setFrame:frame];
    [self setNeedsLayout];
}

- (void)setCenter:(CGPoint)center {
    [super setCenter:center];
    [self setNeedsLayout];
}

@end
