#import "DSIntroDemoView.h"
#import "DSLogoView.h"

static const CGFloat kDSDemoAspect = 19.5 / 9.0;

// One row of the fake app content behind the stage.
static UIView *DSDemoBar(CGFloat inset, CGFloat height, UIColor *color) {
    UIView *bar = [[UIView alloc] initWithFrame:CGRectZero];
    bar.backgroundColor = color;
    bar.layer.cornerRadius = height / 2.0;
    bar.accessibilityIdentifier = [NSString stringWithFormat:@"%.2f", inset];
    return bar;
}

@implementation DSIntroDemoView {
    UIView *_device;
    UIView *_hostApp;
    NSArray<UIView *> *_hostBars;
    UIView *_stage;
    UIView *_stageGrabber;
    NSArray<UIView *> *_stageCells;
    UIView *_stageApp;
    DSLogoView *_stageAppMark;
    UIView *_finger;

    DSIntroDemo _demo;
    NSTimer *_loop;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = NO;
        [self build];
    }
    return self;
}

- (void)dealloc {
    [_loop invalidate];
}

- (void)build {
    _device = [[UIView alloc] initWithFrame:CGRectZero];
    _device.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
    _device.layer.cornerCurve = kCACornerCurveContinuous;
    _device.layer.borderWidth = 2.0;
    _device.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
    _device.clipsToBounds = YES;
    [self addSubview:_device];

    _hostApp = [[UIView alloc] initWithFrame:CGRectZero];
    _hostApp.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
    _hostApp.layer.cornerCurve = kCACornerCurveContinuous;
    _hostApp.clipsToBounds = YES;
    [_device addSubview:_hostApp];

    NSMutableArray *bars = [NSMutableArray array];
    UIColor *accent = [UIColor colorWithRed:0.31 green:0.55 blue:1.0 alpha:1.0];
    [bars addObject:DSDemoBar(0.0, 0.0, accent)];
    for (NSUInteger index = 0; index < 5; index++) {
        [bars addObject:DSDemoBar(0.0, 0.0, [UIColor colorWithWhite:1.0 alpha:index % 2 ? 0.14 : 0.22])];
    }
    for (UIView *bar in bars) [_hostApp addSubview:bar];
    _hostBars = bars;

    _stage = [[UIView alloc] initWithFrame:CGRectZero];
    _stage.backgroundColor = [UIColor colorWithWhite:0.26 alpha:0.96];
    _stage.layer.cornerCurve = kCACornerCurveContinuous;
    _stage.clipsToBounds = YES;
    [_device addSubview:_stage];

    _stageGrabber = [[UIView alloc] initWithFrame:CGRectZero];
    _stageGrabber.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.38];
    [_stage addSubview:_stageGrabber];

    NSMutableArray *cells = [NSMutableArray array];
    for (NSUInteger index = 0; index < 6; index++) {
        UIView *cell = [[UIView alloc] initWithFrame:CGRectZero];
        cell.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.16];
        cell.layer.cornerCurve = kCACornerCurveContinuous;
        [_stage addSubview:cell];
        [cells addObject:cell];
    }
    _stageCells = cells;

    _stageApp = [[UIView alloc] initWithFrame:CGRectZero];
    _stageApp.backgroundColor = [UIColor colorWithRed:0.35 green:0.36 blue:0.94 alpha:1.0];
    _stageApp.layer.cornerCurve = kCACornerCurveContinuous;
    _stageApp.alpha = 0.0;
    [_stage addSubview:_stageApp];

    _stageAppMark = [[DSLogoView alloc] initWithFrame:CGRectZero];
    _stageAppMark.markColor = [UIColor colorWithWhite:1.0 alpha:0.92];
    _stageAppMark.arrowColor = [UIColor colorWithRed:0.35 green:0.36 blue:0.94 alpha:1.0];
    [_stageApp addSubview:_stageAppMark];

    _finger = [[UIView alloc] initWithFrame:CGRectZero];
    _finger.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.9];
    _finger.layer.shadowColor = UIColor.blackColor.CGColor;
    _finger.layer.shadowOpacity = 0.4;
    _finger.layer.shadowRadius = 6.0;
    _finger.alpha = 0.0;
    [self addSubview:_finger];
}

#pragma mark - Layout

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat height = CGRectGetHeight(self.bounds);
    CGFloat deviceHeight = height;
    CGFloat deviceWidth = deviceHeight / kDSDemoAspect;
    if (deviceWidth > CGRectGetWidth(self.bounds) * 0.62) {
        deviceWidth = CGRectGetWidth(self.bounds) * 0.62;
        deviceHeight = deviceWidth * kDSDemoAspect;
    }
    _device.frame = CGRectMake((CGRectGetWidth(self.bounds) - deviceWidth) / 2.0,
                               (height - deviceHeight) / 2.0,
                               deviceWidth,
                               deviceHeight);
    _device.layer.cornerRadius = deviceWidth * 0.14;

    CGFloat pad = deviceWidth * 0.045;
    _hostApp.frame = CGRectInset(_device.bounds, pad, pad);
    _hostApp.layer.cornerRadius = _device.layer.cornerRadius - pad;

    CGFloat barInset = CGRectGetWidth(_hostApp.bounds) * 0.09;
    CGFloat y = CGRectGetHeight(_hostApp.bounds) * 0.085;
    for (NSUInteger index = 0; index < _hostBars.count; index++) {
        UIView *bar = _hostBars[index];
        CGFloat barHeight = index == 0 ? CGRectGetHeight(_hostApp.bounds) * 0.2
                                       : CGRectGetHeight(_hostApp.bounds) * 0.045;
        bar.frame = CGRectMake(barInset, y, CGRectGetWidth(_hostApp.bounds) - barInset * 2.0, barHeight);
        bar.layer.cornerRadius = index == 0 ? barHeight * 0.14 : barHeight / 2.0;
        y += barHeight + CGRectGetHeight(_hostApp.bounds) * 0.032;
    }

    [self layoutStageForProgress:[self stageProgressForDemo:_demo] instant:YES];
    CGFloat fingerSide = deviceWidth * 0.17;
    _finger.bounds = CGRectMake(0, 0, fingerSide, fingerSide);
    _finger.layer.cornerRadius = fingerSide / 2.0;
}

// 0 = parked off the bottom edge, 1 = overlay resting height, 2 = split view.
- (CGFloat)stageProgressForDemo:(DSIntroDemo)demo {
    switch (demo) {
        case DSIntroDemoPick: return 1.0;
        case DSIntroDemoSplit: return 2.0;
        case DSIntroDemoFullscreen: return 1.0;
        case DSIntroDemoPutAway: return 1.0;
        default: return 0.0;
    }
}

// Overlay is a card inset on three sides; Split View goes edge to edge. Same
// rule as the real stage, scaled down to the mock device.
- (CGRect)stageFrameForProgress:(CGFloat)progress {
    CGRect host = _hostApp.frame;
    CGFloat inset = CGRectGetWidth(host) * 0.023;
    CGFloat split = MIN(MAX(progress - 1.0, 0.0), 1.0);
    CGFloat sideInset = inset * (1.0 - split);
    CGFloat height = CGRectGetHeight(host) * 0.5 - inset + inset * split;
    CGFloat visible = MIN(progress, 1.0);
    CGFloat top = CGRectGetMaxY(host) - sideInset - height * visible;
    return CGRectMake(CGRectGetMinX(host) + sideInset,
                      top,
                      CGRectGetWidth(host) - sideInset * 2.0,
                      height);
}

- (void)layoutStageForProgress:(CGFloat)progress instant:(BOOL)instant {
    CGRect frame = [self stageFrameForProgress:progress];
    _stage.frame = frame;
    _stage.layer.cornerRadius = CGRectGetWidth(frame) * 0.09;

    CGFloat grabberWidth = CGRectGetWidth(frame) * 0.16;
    _stageGrabber.frame = CGRectMake((CGRectGetWidth(frame) - grabberWidth) / 2.0, 5.0, grabberWidth, 3.0);
    _stageGrabber.layer.cornerRadius = 1.5;

    CGFloat inset = CGRectGetWidth(frame) * 0.07;
    CGFloat cellHeight = CGRectGetHeight(frame) * 0.1;
    CGFloat cellGap = CGRectGetHeight(frame) * 0.045;
    CGFloat gridWidth = (CGRectGetWidth(frame) - inset * 2.0 - cellGap) / 2.0;
    CGFloat cellY = 14.0;
    [_stageCells enumerateObjectsUsingBlock:^(UIView *cell, NSUInteger index, BOOL *stop) {
        if (index < 4) {
            CGFloat column = index % 2;
            CGFloat row = index / 2;
            cell.frame = CGRectMake(inset + column * (gridWidth + cellGap),
                                    cellY + row * (cellHeight + cellGap),
                                    gridWidth,
                                    cellHeight);
        } else {
            CGFloat row = index - 4;
            cell.frame = CGRectMake(inset,
                                    cellY + 2 * (cellHeight + cellGap) + cellGap * 1.6 + row * (cellHeight + cellGap),
                                    CGRectGetWidth(frame) - inset * 2.0,
                                    cellHeight);
        }
        cell.layer.cornerRadius = cellHeight * 0.3;
    }];

    _stageApp.frame = CGRectMake(0, 10.0, CGRectGetWidth(frame), CGRectGetHeight(frame) - 10.0);
    _stageApp.layer.cornerRadius = _stage.layer.cornerRadius * 0.6;
    CGFloat markSide = CGRectGetWidth(frame) * 0.28;
    _stageAppMark.frame = CGRectMake((CGRectGetWidth(_stageApp.bounds) - markSide) / 2.0,
                                     (CGRectGetHeight(_stageApp.bounds) - markSide) / 2.0,
                                     markSide,
                                     markSide);

    // In split view the app behind gives up the bottom half.
    CGFloat hostVisible = progress <= 1.0 ? 1.0 : 1.0 - (progress - 1.0) * 0.5;
    CGRect deviceInner = CGRectInset(_device.bounds, CGRectGetWidth(_device.bounds) * 0.045, CGRectGetWidth(_device.bounds) * 0.045);
    CGRect hostFrame = deviceInner;
    hostFrame.size.height = CGRectGetHeight(deviceInner) * hostVisible - (progress > 1.0 ? 3.0 : 0.0);
    _hostApp.frame = hostFrame;
}

#pragma mark - Playback

- (void)stop {
    [_loop invalidate];
    _loop = nil;
    [_stage.layer removeAllAnimations];
    [_finger.layer removeAllAnimations];
}

- (void)playDemo:(DSIntroDemo)demo {
    [self stop];
    _demo = demo;
    [self setNeedsLayout];
    [self layoutIfNeeded];

    if (demo == DSIntroDemoNone) {
        _finger.alpha = 0.0;
        _stageApp.alpha = 0.0;
        [self layoutStageForProgress:0.0 instant:YES];
        [self playIdle];
        return;
    }

    [self runCycle];
    _loop = [NSTimer scheduledTimerWithTimeInterval:4.4 repeats:YES block:^(NSTimer *timer) {
        [self runCycle];
    }];
}

// Landing page: the mark breathes so the page is not dead still.
- (void)playIdle {
    _stageApp.alpha = 0.0;
    [UIView animateWithDuration:1.9
                          delay:0.0
                        options:UIViewAnimationOptionRepeat | UIViewAnimationOptionAutoreverse | UIViewAnimationOptionCurveEaseInOut
                     animations:^{
        self->_hostApp.transform = CGAffineTransformMakeScale(0.985, 0.985);
    }
                     completion:nil];
}

- (void)runCycle {
    switch (_demo) {
        case DSIntroDemoPull: [self runPullCycle]; break;
        case DSIntroDemoPick: [self runPickCycle]; break;
        case DSIntroDemoSplit: [self runSplitCycle]; break;
        case DSIntroDemoFullscreen: [self runFullscreenCycle]; break;
        case DSIntroDemoPutAway: [self runPutAwayCycle]; break;
        default: break;
    }
}

- (CGPoint)cornerFingerPoint {
    CGRect host = [self convertRect:_hostApp.bounds fromView:_hostApp];
    return CGPointMake(CGRectGetMaxX(host) - CGRectGetWidth(host) * 0.12, CGRectGetMaxY(host) + 2.0);
}

- (void)runPullCycle {
    _stageApp.alpha = 0.0;
    [self layoutStageForProgress:0.0 instant:YES];

    CGPoint start = [self cornerFingerPoint];
    _finger.center = start;
    _finger.alpha = 0.0;
    _finger.transform = CGAffineTransformMakeScale(0.7, 0.7);

    [UIView animateWithDuration:0.22 animations:^{
        self->_finger.alpha = 1.0;
        self->_finger.transform = CGAffineTransformIdentity;
    }];

    [UIView animateWithDuration:1.0
                          delay:0.22
         usingSpringWithDamping:0.9
          initialSpringVelocity:0.2
                        options:0
                     animations:^{
        self->_finger.center = CGPointMake(start.x, start.y - CGRectGetHeight(self->_hostApp.bounds) * 0.42);
        [self layoutStageForProgress:1.0 instant:NO];
    }
                     completion:nil];

    [UIView animateWithDuration:0.3
                          delay:1.4
                        options:0
                     animations:^{
        self->_finger.alpha = 0.0;
        self->_finger.transform = CGAffineTransformMakeScale(0.7, 0.7);
    }
                     completion:nil];

    [UIView animateWithDuration:0.55
                          delay:3.4
         usingSpringWithDamping:0.9
          initialSpringVelocity:0.0
                        options:0
                     animations:^{
        [self layoutStageForProgress:0.0 instant:NO];
    }
                     completion:nil];
}

- (void)runPickCycle {
    _stageApp.alpha = 0.0;
    [self layoutStageForProgress:1.0 instant:YES];
    for (UIView *cell in _stageCells) cell.alpha = 1.0;

    UIView *target = _stageCells.firstObject;
    CGPoint tap = [self convertPoint:CGPointMake(CGRectGetMidX(target.bounds), CGRectGetMidY(target.bounds)) fromView:target];
    _finger.center = tap;
    _finger.transform = CGAffineTransformMakeScale(0.7, 0.7);

    [UIView animateWithDuration:0.25 delay:0.35 options:0 animations:^{
        self->_finger.alpha = 1.0;
        self->_finger.transform = CGAffineTransformIdentity;
    } completion:nil];

    [UIView animateWithDuration:0.16 delay:0.75 options:0 animations:^{
        target.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.34];
        self->_finger.transform = CGAffineTransformMakeScale(0.82, 0.82);
    } completion:nil];

    [UIView animateWithDuration:0.5 delay:0.95 usingSpringWithDamping:0.85 initialSpringVelocity:0.0 options:0 animations:^{
        self->_finger.alpha = 0.0;
        self->_stageApp.alpha = 1.0;
        for (UIView *cell in self->_stageCells) cell.alpha = 0.0;
        target.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.16];
    } completion:nil];

    [UIView animateWithDuration:0.4 delay:3.5 options:0 animations:^{
        self->_stageApp.alpha = 0.0;
        for (UIView *cell in self->_stageCells) cell.alpha = 1.0;
    } completion:nil];
}

- (void)runSplitCycle {
    _stageApp.alpha = 1.0;
    for (UIView *cell in _stageCells) cell.alpha = 0.0;
    [self layoutStageForProgress:1.0 instant:YES];

    CGPoint start = [self cornerFingerPoint];
    _finger.center = CGPointMake(start.x, start.y - CGRectGetHeight(_hostApp.bounds) * 0.42);
    _finger.transform = CGAffineTransformIdentity;

    [UIView animateWithDuration:0.22 delay:0.3 options:0 animations:^{
        self->_finger.alpha = 1.0;
    } completion:nil];

    [UIView animateWithDuration:0.8 delay:0.55 usingSpringWithDamping:0.86 initialSpringVelocity:0.0 options:0 animations:^{
        self->_finger.center = CGPointMake(start.x, start.y - CGRectGetHeight(self->_hostApp.bounds) * 0.72);
        [self layoutStageForProgress:2.0 instant:NO];
    } completion:nil];

    [UIView animateWithDuration:0.25 delay:1.45 options:0 animations:^{
        self->_finger.alpha = 0.0;
    } completion:nil];

    [UIView animateWithDuration:0.6 delay:3.5 usingSpringWithDamping:0.88 initialSpringVelocity:0.0 options:0 animations:^{
        [self layoutStageForProgress:1.0 instant:NO];
    } completion:nil];
}

// Holding a plate rather than tapping it hands the app the whole screen.
- (void)runFullscreenCycle {
    _stageApp.alpha = 0.0;
    [self layoutStageForProgress:1.0 instant:YES];
    _hostApp.alpha = 1.0;
    for (UIView *cell in _stageCells) cell.alpha = 1.0;

    UIView *target = _stageCells.firstObject;
    CGPoint hold = [self convertPoint:CGPointMake(CGRectGetMidX(target.bounds), CGRectGetMidY(target.bounds)) fromView:target];
    _finger.center = hold;
    _finger.transform = CGAffineTransformMakeScale(0.7, 0.7);

    [UIView animateWithDuration:0.22 delay:0.3 options:0 animations:^{
        self->_finger.alpha = 1.0;
        self->_finger.transform = CGAffineTransformIdentity;
    } completion:nil];

    // The plate deepening under the finger is the hold's own feedback.
    [UIView animateWithDuration:0.6 delay:0.55 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        target.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.42];
        self->_finger.transform = CGAffineTransformMakeScale(0.86, 0.86);
    } completion:nil];

    [UIView animateWithDuration:0.65 delay:1.25 usingSpringWithDamping:0.9 initialSpringVelocity:0.0 options:0 animations:^{
        self->_finger.alpha = 0.0;
        self->_hostApp.alpha = 0.0;
        for (UIView *cell in self->_stageCells) cell.alpha = 0.0;
        self->_stageApp.alpha = 1.0;
        self->_stage.frame = self->_hostApp.frame;
        self->_stageApp.frame = self->_stage.bounds;
        self->_stageApp.layer.cornerRadius = self->_stage.layer.cornerRadius;
        self->_stageGrabber.alpha = 0.0;
        CGFloat markSide = CGRectGetWidth(self->_stage.bounds) * 0.3;
        self->_stageAppMark.frame = CGRectMake((CGRectGetWidth(self->_stage.bounds) - markSide) / 2.0,
                                               (CGRectGetHeight(self->_stage.bounds) - markSide) / 2.0,
                                               markSide, markSide);
    } completion:nil];

    [UIView animateWithDuration:0.5 delay:3.5 options:0 animations:^{
        self->_stageGrabber.alpha = 1.0;
        self->_hostApp.alpha = 1.0;
        self->_stageApp.alpha = 0.0;
        target.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.16];
        for (UIView *cell in self->_stageCells) cell.alpha = 1.0;
        [self layoutStageForProgress:1.0 instant:NO];
    } completion:nil];
}

// Two ways out: swipe up inside the stage to drop the app and get the picker
// back, then drag the stage itself down to put it away.
- (void)runPutAwayCycle {
    _stageApp.alpha = 1.0;
    for (UIView *cell in _stageCells) cell.alpha = 0.0;
    [self layoutStageForProgress:1.0 instant:YES];

    CGRect stage = [self convertRect:_stage.bounds fromView:_stage];
    CGPoint bottom = CGPointMake(CGRectGetMidX(stage), CGRectGetMaxY(stage) - 6.0);
    _finger.center = bottom;
    _finger.transform = CGAffineTransformMakeScale(0.7, 0.7);

    [UIView animateWithDuration:0.2 delay:0.25 options:0 animations:^{
        self->_finger.alpha = 1.0;
        self->_finger.transform = CGAffineTransformIdentity;
    } completion:nil];

    // Swipe up: the app shrinks into its plate and the picker comes back.
    [UIView animateWithDuration:0.55 delay:0.5 usingSpringWithDamping:0.88 initialSpringVelocity:0.0 options:0 animations:^{
        self->_finger.center = CGPointMake(bottom.x, bottom.y - CGRectGetHeight(stage) * 0.3);
        self->_stageApp.alpha = 0.0;
        for (UIView *cell in self->_stageCells) cell.alpha = 1.0;
    } completion:nil];

    [UIView animateWithDuration:0.2 delay:1.15 options:0 animations:^{
        self->_finger.alpha = 0.0;
    } completion:nil];

    // Drag down from the top of the stage: it leaves, the app behind stays.
    [UIView animateWithDuration:0.2 delay:1.6 options:0 animations:^{
        self->_finger.center = CGPointMake(CGRectGetMidX(stage), CGRectGetMinY(stage) + 8.0);
        self->_finger.alpha = 1.0;
    } completion:nil];

    [UIView animateWithDuration:0.6 delay:1.9 usingSpringWithDamping:0.95 initialSpringVelocity:0.0 options:0 animations:^{
        self->_finger.center = CGPointMake(CGRectGetMidX(stage), CGRectGetMaxY(stage) + 10.0);
        [self layoutStageForProgress:0.0 instant:NO];
    } completion:nil];

    [UIView animateWithDuration:0.25 delay:2.6 options:0 animations:^{
        self->_finger.alpha = 0.0;
    } completion:nil];
}

@end
