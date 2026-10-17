#import "DSStageContainerView.h"
#import "DSRimCatcherView.h"
#import "DSStageDebug.h"
#import "DSDiagnostics.h"
#import "DSConstants.h"
#import <QuartzCore/QuartzCore.h>
FOUNDATION_EXPORT BOOL DSStage742MessagesStaged(void);

static const CGFloat kDSDragAffordanceHeight = 36.0;

// ---- 4.5.703 native703 ---------------------------------------------------------
// System look: a 1 pt hairline outline in the system's light / dark tone instead
// of the 3 pt white rim, a soft shadow drawn from a fixed shadowPath (no offscreen
// pass, rebuilt only when the card's size or radius changes), the minimised icon
// with the iOS app-icon corner (22.37 % of its side, continuous). No tune file.
// Off: /var/mobile/.dynamicstage-native703-off (crash latch native703-trying/-crashed).
static BOOL DSNative703IsDark = YES;

BOOL DSNative703On(void) {
    return DSFeature699On("native703");
}

void DSNative703SetDark(BOOL dark) {
    DSNative703IsDark = dark;
}

CGFloat DSNative703OutlineWidth(void) {
    return DSNative703On() ? 1.0 : 3.0;
}

CGColorRef DSNative703OutlineColor(void) {
    static CGColorRef legacy = NULL, dark = NULL, light = NULL;
    if (!legacy) {
        legacy = CGColorRetain([UIColor colorWithWhite:1.0 alpha:0.28].CGColor);
        dark = CGColorRetain([UIColor colorWithWhite:1.0 alpha:0.20].CGColor);
        light = CGColorRetain([UIColor colorWithWhite:0.0 alpha:0.12].CGColor);
    }
    if (!DSNative703On()) return legacy;
    return DSNative703IsDark ? dark : light;
}

CGFloat DSNative703IconRadius(CGFloat side) {
    if (!DSNative703On() || !(side > 1.0)) return 9.0;
    return round(side * 0.2237 * 2.0) / 2.0;
}

static void DSApplyRoundedClip(UIView *view, CGFloat radius) {
    if (!view || radius < 1.0) return;
    view.clipsToBounds = YES;
    view.layer.masksToBounds = YES;
    view.layer.cornerRadius = radius;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
                               kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
}

// A continuous mask, the same curve as the rim. A circular path cut deeper
// than that rim, so the card looked rounder than its outline.
static void DSRebuildRoundedMask(UIView *view, CGFloat radius) {
    if (!view) return;
    CGRect bounds = view.bounds;
    if (radius < 1.0 || CGRectGetWidth(bounds) < 2.0 || CGRectGetHeight(bounds) < 2.0) {
        view.layer.mask = nil;
        return;
    }
    CALayer *mask = view.layer.mask ?: [CALayer layer];
    if ([mask isKindOfClass:CAShapeLayer.class]) {
        mask = [CALayer layer];
    }
    mask.frame = bounds;
    mask.backgroundColor = UIColor.blackColor.CGColor;
    mask.cornerRadius = radius;
    mask.cornerCurve = kCACornerCurveContinuous;
    if (view.layer.mask != mask) view.layer.mask = mask;
}

static void DSRoundBlurFill(UIVisualEffectView *backdrop, CGFloat radius) {
    DSApplyRoundedClip(backdrop, radius);
    for (UIView *subview in backdrop.subviews) {
        NSString *name = NSStringFromClass(subview.class);
        if ([name rangeOfString:@"Backdrop"].location == NSNotFound) continue;
        DSApplyRoundedClip(subview, radius);
    }
}

// ---- 4.5.705 perf705 -------------------------------------------------------------
// The content view and the blur already clip with masksToBounds + the same
// continuous cornerRadius on all four corners. The extra CALayer mask on each
// (same frame, same radius, same curve) cut exactly the same shape, but a layer
// mask forces an offscreen render pass of everything under it - for the content
// view that is the live hosted scene, every frame the app draws, on both cards.
// perf705 drops the two masks and skips per-layout work whose inputs did not
// change. Off: /var/mobile/.dynamicstage-perf705-off (crash latch perf705).
BOOL DSPerf705On(void) {
    // Asked per view in the host rounding walks: 0.5 s cache over the
    // switch reader (which itself re-checks the off file every 2 s).
    static volatile CFAbsoluteTime at = 0;
    static volatile BOOL value = NO;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - at > 0.5 || now < at) {
        value = DSFeature699On("perf705");
        at = now;
    }
    return value;
}

static const CGFloat kDSGrabberWidth = 124.0;
static const CGFloat kDSGrabberPillHeight = 5.0;

@implementation DSStageContainerView {
    BOOL _realKb814Unclipped;
    UIView *_shadowView;
    UIVisualEffectView *_backdrop;
    UIView *_contentView;
    UIView *_grabber;
    UIView *_grabberPill;
    UIView *_cornerGrip;
    UIView *_edgeGrip;
    UIButton *_stackAddButton;
    BOOL _applyingKeyboardBand;
    BOOL _clipsContents;
    CGSize _native703PathSize;
    CGFloat _native703PathRadius;
    NSArray<DSRimCatcherView *> *_rimCatchers;
    CGFloat _perf705BlurRadius;
    NSUInteger _perf705BlurSubviews;
    BOOL _held706;
    CADisplayLink *_vel752Link;
    CGPoint _vel752Pos[2];
    CFTimeInterval _vel752At[2];
    NSUInteger _vel752Count;
    CGPoint _vel752Velocity;
    BOOL _vel752Have;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _cornerRadius = kDSFallbackDisplayCornerRadius;
        _clipsContents = YES;

        // The card clips its contents, which kills its own shadow, so the drop
        // shadow lives on a sibling underneath.
        _shadowView = [[UIView alloc] initWithFrame:CGRectZero];
        _shadowView.backgroundColor = UIColor.clearColor;
        _shadowView.layer.shadowColor = UIColor.blackColor.CGColor;
        _shadowView.layer.shadowOpacity = 0.28;
        _shadowView.layer.shadowRadius = 24.0;
        _shadowView.layer.shadowOffset = CGSizeMake(0, -4);
        _shadowView.layer.cornerCurve = kCACornerCurveContinuous;
        _shadowView.userInteractionEnabled = NO;

        _backdrop = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThickMaterialDark]];
        [self addSubview:_backdrop];

        _contentView = [[UIView alloc] initWithFrame:CGRectZero];
        _contentView.backgroundColor = UIColor.clearColor;
        _contentView.clipsToBounds = YES;
        [self addSubview:_contentView];

        // The card is dragged by this. It has to be a view of its own, sitting
        // above the content: a drag that lands on the app grid belongs to the
        // grid's own scrolling, and the card would never see it. Being visible is
        // the other half of the job - there is otherwise nothing to say the card
        // can be moved at all.
        _grabber = [[UIView alloc] initWithFrame:CGRectZero];
        _grabber.backgroundColor = UIColor.clearColor;
        [self addSubview:_grabber];

        _grabberPill = [[UIView alloc] initWithFrame:CGRectZero];
        _grabberPill.layer.cornerRadius = kDSGrabberPillHeight / 2.0;
        _grabberPill.layer.cornerCurve = kCACornerCurveContinuous;
        _grabberPill.hidden = YES;
        _grabberPill.userInteractionEnabled = NO;
        [_grabber addSubview:_grabberPill];

        // The corner, for the same reason the grabber above is a view: a touch that
        // lands on a hosted app is delivered to that app's own process, and a gesture
        // recogniser on this side is never asked about it. While the card holds the app
        // grid the corner could be a rectangle the recogniser tested the start of a drag
        // against, because the grid is SpringBoard's own view. The moment the card held
        // an app instead, taking hold of the corner stopped working at all.
        //
        // Only while an app is on the stage, though: there is no reason to hold back a
        // piece of the app grid the grid could be using.
        _cornerGrip = [[UIView alloc] initWithFrame:CGRectZero];
        _cornerGrip.backgroundColor = UIColor.clearColor;
        _cornerGrip.userInteractionEnabled = NO;
        [self addSubview:_cornerGrip];

        // The same thing, up the right-hand edge and well clear of the bottom of the
        // display. The corner is a few points from the home gesture's own territory, and
        // the phone hands those drags to the home gesture often enough to be worth a
        // second place to start the same one - the log on the device caught the system
        // taking a corner drag away mid-gesture and going home with it.
        _edgeGrip = [[UIView alloc] initWithFrame:CGRectZero];
        _edgeGrip.backgroundColor = UIColor.clearColor;
        _edgeGrip.userInteractionEnabled = NO;
        [self addSubview:_edgeGrip];

        _stackAddButton = [UIButton buttonWithType:UIButtonTypeSystem];
        if (@available(iOS 13.0, *)) {
            UIImage *plus = [UIImage systemImageNamed:@"plus.circle.fill"];
            [_stackAddButton setImage:plus forState:UIControlStateNormal];
        } else {
            [_stackAddButton setTitle:@"+" forState:UIControlStateNormal];
        }
        _stackAddButton.tintColor = [UIColor colorWithWhite:1.0 alpha:0.85];
        _stackAddButton.hidden = YES;
        _stackAddButton.accessibilityLabel = @"Add stage";
        [_stackAddButton addTarget:self action:@selector(stackAddTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_stackAddButton];

        self.backgroundColor = UIColor.clearColor;
        self.clipsToBounds = YES;
        self.layer.masksToBounds = YES;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.cornerRadius = _cornerRadius;

        self.darkMode = YES;

        // 4.5.651: the band just inside the card edge wins the touch over the
        // hosted app's own layer (see DSRimCatcherView.h). The strips hand
        // the touch to this card, exactly like the old band check below, so
        // the card's own pans (or the drag shell's) take it.
        _rimCatchers = DSMakeRimCatchers(self, @"card-inner", self);
        for (DSRimCatcherView *strip in _rimCatchers) strip.controlsView = self;
    }
    return self;
}

- (void)layoutRimCatchers {
    DSPerfCount(DSPerfCounterRimLayouts);
    CGRect bounds = self.bounds;
    CGFloat cut = _keyboardBandHeight > 1.0 ? CGRectGetHeight(bounds) - _keyboardBandHeight : CGFLOAT_MAX;
    // 4.5.731 rim731: no rim catcher inside the card (they took taps at the
    // app's edges); the grab is the band outside the card. Off: -rim731-off.
    DSLayoutRimCatchers(_rimCatchers, self, bounds, CGRectInset(bounds, kDSRimInnerCatch, kDSRimInnerCatch), cut,
                        !self.hidden && !DS809Latched("rim731"));
}

- (NSString *)rimCatcherName {
    return _rimCatchers.firstObject.catcherName;
}

- (void)setRimCatcherName:(NSString *)name {
    // 4.5.741 log741: no static NSString C array (its "left" entry came out as
    // garbage on device, "top-outer-\u00eb\u00c1", which cut the log line short).
    NSString *(^sides741)(NSUInteger) = ^NSString *(NSUInteger k) { switch (k) { case 0: return @"top"; case 1: return @"bottom"; case 2: return @"left"; default: return @"right"; } };
    for (NSUInteger i = 0; i < _rimCatchers.count && i < 4; i++) {
        _rimCatchers[i].catcherName = [NSString stringWithFormat:@"%@-%@", name, sides741((NSUInteger)i)];
    }
}

- (void)willMoveToSuperview:(UIView *)superview {
    [super willMoveToSuperview:superview];
    if (superview && _shadowView.superview != superview) {
        [superview insertSubview:_shadowView belowSubview:self];
    } else if (!superview) {
        [_shadowView removeFromSuperview];
    }
}

- (void)layoutSubviews {
    DS_PERF_BEGIN();
    [self layoutSubviews697];
    DS_PERF_END(DSPerfBucketCardLayout);
}

- (void)layoutSubviews697 {
    [super layoutSubviews];
    // 4.5.697: the content view's rounded mask layer is reused. Clearing it
    // here and building a new one in applyCardCornerClip on every pass made
    // the hosted app (under the mask) render again each drag frame.
    BOOL keepMask = DSPerf697On();
    CGRect bounds = self.bounds;
    CGFloat band = MIN(MAX(_keyboardBandHeight, 0.0), CGRectGetHeight(bounds));
    CGFloat appHeight = CGRectGetHeight(bounds) - band;
    BOOL pinHost = !_applyingKeyboardBand && _keyboardBandLayoutHandler != nil;
    if (band > 1.0) {
        // Pin the host at the full card height before the content view shrinks.
        // Otherwise autoresizing hands the app a shorter scene and it draws the
        // keyboard up into the opening.
        if (pinHost) {
            _applyingKeyboardBand = YES;
            _keyboardBandLayoutHandler();
            _applyingKeyboardBand = NO;
        }
        _backdrop.frame = CGRectMake(0.0, 0.0, CGRectGetWidth(bounds), MAX(appHeight, 0.0));
        self.clipsToBounds = NO;
        self.layer.masksToBounds = NO;
        self.opaque = NO;
        _contentView.clipsToBounds = !_realKb814Unclipped;   // 4.5.814: the host's mask clips instead
        _contentView.opaque = NO;
        if (!keepMask) _contentView.layer.mask = nil;
        _contentView.frame = CGRectMake(0.0, 0.0, CGRectGetWidth(bounds), MAX(appHeight, 0.0));
        _contentView.layer.cornerRadius = _cornerRadius;
        _contentView.layer.cornerCurve = kCACornerCurveContinuous;
        _contentView.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
        self.layer.cornerRadius = 0.0;
        if (pinHost) {
            _applyingKeyboardBand = YES;
            _keyboardBandLayoutHandler();
            _applyingKeyboardBand = NO;
        }
    } else {
        _backdrop.frame = bounds;
        // The keyboard is a SpringBoard window above this card. The card must
        // not clip it. The app itself stays inside the content view.
        self.clipsToBounds = _clipsContents && !_realKb814Unclipped;
        self.layer.masksToBounds = _clipsContents && !_realKb814Unclipped;
        // The hosted scene ignores a clip on this card. The content view has to
        // carry the same continuous corner, or the app stays a square.
        // 4.5.814 realkb814: no clip here; the Messages host's own mask (card + keyboard) clips.
        _contentView.clipsToBounds = !_realKb814Unclipped;
        _contentView.layer.masksToBounds = !_realKb814Unclipped;
        if (_realKb814Unclipped) _contentView.layer.mask = nil;
        if (!keepMask) _contentView.layer.mask = nil;
        _contentView.layer.cornerRadius = _cornerRadius;
        _contentView.layer.cornerCurve = kCACornerCurveContinuous;
        _contentView.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
        self.layer.cornerRadius = _clipsContents ? _cornerRadius : 0.0;
        _contentView.frame = bounds;
        if (pinHost) {
            _applyingKeyboardBand = YES;
            _keyboardBandLayoutHandler();
            _applyingKeyboardBand = NO;
        }
    }

    _grabber.frame = CGRectMake((CGRectGetWidth(bounds) - kDSGrabberWidth) / 2.0,
                                0.0,
                                kDSGrabberWidth,
                                kDSDragAffordanceHeight);
    _grabberPill.hidden = YES;
    _grabberPill.alpha = 0.0;
    _grabberPill.frame = CGRectZero;

    // Narrower than the zone the pan recogniser will accept a drag from, because while
    // an app is on the stage this is a piece of that app being held back: a thumb's
    // worth is enough to take hold of the corner, and the rest stays the app's.
    CGRect grip = [self cornerGripRect];
    CGFloat gripWidth = MIN(88.0, CGRectGetWidth(grip));
    CGFloat gripHeight = MIN(56.0, CGRectGetHeight(grip));
    _cornerGrip.frame = CGRectMake(CGRectGetMaxX(grip) - gripWidth,
                                   CGRectGetMaxY(grip) - gripHeight,
                                   gripWidth,
                                   gripHeight);

    _edgeGrip.frame = [self edgeGripRect];

    CGFloat addSide = 36.0;
    _stackAddButton.frame = CGRectMake(CGRectGetWidth(bounds) - addSide - 8.0,
                                       4.0,
                                       addSide,
                                       addSide);
    _stackAddButton.hidden = !_showsStackAddButton;
    // 4.5.705 perf705: the four views are re-raised only when they are not
    // already the top four in this order (same end state, no subview churn).
    NSArray<UIView *> *subs = self.subviews;
    NSUInteger n = subs.count;
    BOOL ordered = DSPerf705On() && n >= 4 && subs[n - 4] == _cornerGrip && subs[n - 3] == _edgeGrip &&
                   subs[n - 2] == _stackAddButton && subs[n - 1] == _grabber;
    if (!ordered) {
        [self bringSubviewToFront:_cornerGrip];
        [self bringSubviewToFront:_edgeGrip];
        [self bringSubviewToFront:_stackAddButton];
        [self bringSubviewToFront:_grabber];
    }
    [self layoutRimCatchers];

    [self applyCardCornerClip];
    [self updateShadow];
}

// The keyboard is a separate window above the stage. Turning this clip off
// left the picker as a square plate with the rounded outline floating outside it.
- (BOOL)realKb814Unclipped { return _realKb814Unclipped; }
- (void)setRealKb814Unclipped:(BOOL)on {
    if (_realKb814Unclipped == on) return;
    _realKb814Unclipped = on;
    [self applyCardCornerClip];
    [self setNeedsLayout];
}

- (void)applyCardCornerClip {
    CGFloat radius = _cornerRadius;
    if (radius < 20.0) radius = 20.0;
    _cornerRadius = radius;
    if (_realKb814Unclipped) {
        // 4.5.814 realkb814: the Messages host draws outside the card (its
        // keyboard); its own mask is the card's rounded rect + the keyboard.
        self.clipsToBounds = NO;
        self.layer.masksToBounds = NO;
        _contentView.clipsToBounds = NO;
        _contentView.layer.masksToBounds = NO;
        _contentView.layer.mask = nil;
        return;
    }
    self.opaque = NO;
    self.clipsToBounds = YES;
    self.layer.masksToBounds = YES;
    self.layer.cornerRadius = radius;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
                               kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    DSPerfCount(DSPerfCounterClipPasses);
    if (DSPerf705On()) {
        // 4.5.705 perf705: clip only (see DSPerf705On). The masks go.
        DSApplyRoundedClip(_contentView, radius);
        DSApplyRoundedClip(_backdrop, radius);
        if (_contentView.layer.mask || _backdrop.layer.mask) {
            DSFeature699MarkTrying("perf705");
            _contentView.layer.mask = nil;
            _backdrop.layer.mask = nil;
        }
        // The blur's inner views are rounded again only when it is shown and
        // the radius or its subviews changed (a class-name walk per layout before).
        NSUInteger count = _backdrop.subviews.count;
        if (!_backdrop.hidden && (fabs(_perf705BlurRadius - radius) > 0.01 || _perf705BlurSubviews != count)) {
            _perf705BlurRadius = radius;
            _perf705BlurSubviews = count;
            DSPerfCount(DSPerfCounterClipWalks);
            DSRoundBlurFill(_backdrop, radius);
        }
        return;
    }
    DSApplyRoundedClip(_contentView, radius);
    DSRebuildRoundedMask(_contentView, radius);
    DSRoundBlurFill(_backdrop, radius);
    DSRebuildRoundedMask(_backdrop, radius);
    DSPerfCount(DSPerfCounterClipWalks);
    DSPerfCount(DSPerfCounterMaskRebuilds);
    DSPerfCount(DSPerfCounterMaskRebuilds);
}

- (void)stackAddTapped {
    if (_stackAddHandler) _stackAddHandler();
}

- (void)setShowsMinimizeButton:(BOOL)showsMinimizeButton {
    (void)showsMinimizeButton;
    _showsMinimizeButton = NO;
}

- (void)setShowsStackAddButton:(BOOL)showsStackAddButton {
    _showsStackAddButton = showsStackAddButton;
    _stackAddButton.hidden = !showsStackAddButton;
}

// ---- 4.5.751 pos751: one position owner per card ---------------------------------
// Every move of a card (drag, drag end, minimise, restore, tuck, split layout,
// keyboard lift / slide, spring back) ends in this view's setFrame: / setCenter:
// / setTransform:, whichever path asked for it. Here a new animated move first
// takes over from the one in flight: the card's model is set to where it is
// drawn right now (its presentation), the old position / size / transform
// animations on this card only are removed, and the new move starts from
// there. No jump to the old target, and no two moves fighting over one card.
// Same springs and durations: the new move's own animation is untouched.
// Off: /var/mobile/.dynamicstage-pos751-off, master core751-off (crash latch pos751).
static BOOL DSPos751On(void) {
    return DSFeature699On("core751") && DSFeature699On("pos751");
}

static BOOL DSPos752On(const char *name);
static NSUInteger DSPos751Moves = 0;

- (void)pos751TakeOverFromPresentation:(NSString *)what {
    if (!DSPos751On()) return;
    if ([UIView inheritedAnimationDuration] <= 0.0) return;   // only an animated move takes over
    CALayer *layer = self.layer;
    NSArray<NSString *> *keys = layer.animationKeys;
    if (keys.count == 0) return;
    BOOL moving = NO;
    for (NSString *k in keys) {
        if ([k hasPrefix:@"position"] || [k hasPrefix:@"bounds"] || [k hasPrefix:@"transform"]) { moving = YES; break; }
    }
    if (!moving) return;
    CALayer *shown = layer.presentationLayer;
    if (!shown) return;
    DSFeature719MarkAction("pos751");
    _vel752Have = NO;
    if (DSPos752On("vel752")) {
        // vel752: speed of the card right now, from its last two drawn samples.
        if (_vel752Count >= 2) {
            CFTimeInterval dt = _vel752At[1] - _vel752At[0];
            if (dt > 0.001 && dt < 0.1) {
                _vel752Velocity = CGPointMake((_vel752Pos[1].x - _vel752Pos[0].x) / dt, (_vel752Pos[1].y - _vel752Pos[0].y) / dt);
                _vel752Have = YES;
            }
        }
    }
    if (DSPos752On("shadow752")) {
        // shadow752: the shadow is taken over in the same step, so it never
        // runs ahead of or behind the card.
        CALayer *sl = _shadowView.layer;
        CALayer *ss = sl.presentationLayer;
        if (ss) {
            CGPoint sp = ss.position; CGRect sb = ss.bounds; CATransform3D st = ss.transform;
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            sl.position = sp; sl.bounds = sb; sl.transform = st;
            for (NSString *k in [sl.animationKeys copy]) {
                if ([k hasPrefix:@"position"] || [k hasPrefix:@"bounds"] || [k hasPrefix:@"transform"]) [sl removeAnimationForKey:k];
            }
            [CATransaction commit];
            DSFeature719MarkAction("shadow752");
        }
    }
    DSPos751Moves += 1;
    CGPoint position = shown.position;
    CGRect bounds = shown.bounds;
    CATransform3D transform = shown.transform;
    [UIView performWithoutAnimation:^{
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        layer.position = position;
        layer.bounds = bounds;
        layer.transform = transform;
        for (NSString *k in [layer.animationKeys copy]) {
            if ([k hasPrefix:@"position"] || [k hasPrefix:@"bounds"] || [k hasPrefix:@"transform"]) [layer removeAnimationForKey:k];
        }
        [CATransaction commit];
    }];
    if (DSPos751Moves == 1 || DSPos751Moves % 50 == 0) {
        DSDiagnosticsRecordFormat(@"SpringBoard: pos751 card move taken over from its current place (%@, %lu so far)",
                                  what, (unsigned long)DSPos751Moves);
    }
}

// ---- 4.5.752 core752 -------------------------------------------------------------
// Finishes pos751. Master off: /var/mobile/.dynamicstage-core752-off returns to
// 4.5.751. Each part has its own off file and crash latch: shadow752, vel752,
// same752. A staged Messages card keeps exactly the 751 behaviour.
static BOOL DSPos752On(const char *name) {
    if (!DSPos751On() || !DSFeature699On("core752") || !DSFeature699On(name)) return NO;
    return !DSStage742MessagesStaged();
}

// 4.5.754: master core754-off returns to 753. vel754-off (crash latch vel754).
static BOOL DSPos754On(const char *name) {
    return DSPos752On("vel752") && DSFeature699On("core754") && DSFeature699On(name);
}

// vel752 sampler: while a card has a move running, note where it is drawn on
// each screen frame (two samples kept). Stops itself when the move ends.
- (void)vel752StartSampling {
    if (_vel752Link || !DSPos752On("vel752")) return;
    _vel752Count = 0;
    _vel752Link = [CADisplayLink displayLinkWithTarget:self selector:@selector(vel752Sample:)];
    [_vel752Link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)vel752Sample:(CADisplayLink *)link {
    BOOL moving = NO;
    BOOL vel754 = DSPos754On("vel754");
    for (NSString *k in self.layer.animationKeys) {
        if ([k hasPrefix:@"position"] || (vel754 && [k hasPrefix:@"transform"])) { moving = YES; break; }
    }
    CALayer *shown = self.layer.presentationLayer;
    if (!moving || !shown || !self.window || !DSPos752On("vel752")) {
        [_vel752Link invalidate];
        _vel752Link = nil;
        _vel752Count = 0;
        return;
    }
    _vel752Pos[0] = _vel752Pos[1]; _vel752At[0] = _vel752At[1];
    CGPoint at = shown.position;
    if (vel754) {
        // 4.5.754 vel754: the keyboard lift / slide moves the card by its
        // transform; its translation is part of where the card is drawn.
        at.x += shown.transform.m41;
        at.y += shown.transform.m42;
    }
    _vel752Pos[1] = at; _vel752At[1] = CACurrentMediaTime();
    if (_vel752Count < 2) _vel752Count += 1;
}

- (void)removeFromSuperview {
    [_vel752Link invalidate];
    _vel752Link = nil;
    [super removeFromSuperview];
}

// vel752: the new move's spring starts at the card's current speed (its
// component along the new move), not from standstill. Only spring position
// animations just added by this move are touched; their duration and damping
// stay as the caller set them.
static void DSVel752Apply(CALayer *layer, CGPoint v, BOOL transforms) {
    for (NSString *k in [layer.animationKeys copy]) {
        BOOL isTransform = [k isEqualToString:@"transform"];
        if (![k hasPrefix:@"position"] && !(transforms && isTransform)) continue;
        CAAnimation *a = [layer animationForKey:k];
        if (![a isKindOfClass:[CASpringAnimation class]]) continue;
        CASpringAnimation *sp = (CASpringAnimation *)a;
        if (![sp.fromValue isKindOfClass:[NSValue class]] || ![sp.toValue isKindOfClass:[NSValue class]]) continue;
        CGPoint f, t;
        if (isTransform) {
            // 4.5.754 vel754: a transform spring; its translation is the move.
            if (strcmp([sp.fromValue objCType], @encode(CATransform3D)) != 0 || strcmp([sp.toValue objCType], @encode(CATransform3D)) != 0) continue;
            CATransform3D ft = [sp.fromValue CATransform3DValue], tt = [sp.toValue CATransform3DValue];
            f = CGPointMake(ft.m41, ft.m42); t = CGPointMake(tt.m41, tt.m42);
        } else {
            if (strcmp([sp.fromValue objCType], @encode(CGPoint)) != 0) continue;
            f = [sp.fromValue CGPointValue]; t = [sp.toValue CGPointValue];
        }
        CGFloat dx = t.x - f.x, dy = t.y - f.y, d2 = dx * dx + dy * dy;
        if (d2 < 1.0) continue;
        CGFloat iv = (v.x * dx + v.y * dy) / d2;
        if (!isfinite(iv)) continue;
        iv = MAX(-30.0, MIN(30.0, iv));
        if (fabs(iv - sp.initialVelocity) < 0.01) continue;
        CASpringAnimation *copy = [sp copy];
        copy.initialVelocity = iv;
        [layer addAnimation:copy forKey:k];
    }
}

static NSUInteger DSVel752Count = 0;

- (void)pos752AfterMove {
    if ([UIView inheritedAnimationDuration] <= 0.0) return;
    @try {
        if (_vel752Have && DSPos752On("vel752")) {
            _vel752Have = NO;
            BOOL tf = DSPos754On("vel754");
            DSFeature719MarkAction("vel752");
            if (tf) DSFeature719MarkAction("vel754");
            DSVel752Apply(self.layer, _vel752Velocity, tf);
            if (DSPos752On("shadow752")) DSVel752Apply(_shadowView.layer, _vel752Velocity, tf);
            DSVel752Count += 1;
            if (DSVel752Count == 1 || DSVel752Count % 50 == 0) {
                DSDiagnosticsRecordFormat(@"SpringBoard: vel752 move continued at %.0f,%.0f pt/s (%lu so far)",
                                          _vel752Velocity.x, _vel752Velocity.y, (unsigned long)DSVel752Count);
            }
        }
        [self vel752StartSampling];
    } @catch (NSException *exception) {}
}

// same752: a layout pass inside an animation that sets the target the card is
// already moving to does not restart that move.
static NSUInteger DSSame752Count = 0;
static void DSSame752Note(void) {
    DSFeature719MarkAction("same752");
    DSSame752Count += 1;
    if (DSSame752Count == 1 || DSSame752Count % 100 == 0) {
        DSDiagnosticsRecordFormat(@"SpringBoard: same752 kept a running move (same target, %lu so far)", (unsigned long)DSSame752Count);
    }
}

- (BOOL)same752Animated {
    return [UIView inheritedAnimationDuration] > 0.0 && DSPos752On("same752");
}

- (void)setFrame:(CGRect)frame {
    if ([self same752Animated] && CGAffineTransformIsIdentity(self.transform) && CGRectEqualToRect(frame, self.frame)) {
        DSSame752Note();
        return;
    }
    @try { [self pos751TakeOverFromPresentation:@"frame"]; } @catch (NSException *exception) {}
    [super setFrame:frame];
    [self updateShadow];
    [self pos752AfterMove];
}

- (void)setCenter:(CGPoint)center {
    if ([self same752Animated] && CGPointEqualToPoint(center, self.center)) {
        DSSame752Note();
        return;
    }
    @try { [self pos751TakeOverFromPresentation:@"center"]; } @catch (NSException *exception) {}
    [super setCenter:center];
    [self updateShadow];
    [self pos752AfterMove];
}

- (void)setTransform:(CGAffineTransform)transform {
    if ([self same752Animated] && CGAffineTransformEqualToTransform(transform, self.transform)) {
        DSSame752Note();
        return;
    }
    @try { [self pos751TakeOverFromPresentation:@"transform"]; } @catch (NSException *exception) {}
    [super setTransform:transform];
    // shadow752: the keyboard lift / slide moves the card by its transform;
    // the shadow now follows it in the same animation.
    if (DSPos752On("shadow752")) [self updateShadow];
    // 4.5.754 vel754: a keyboard (transform) move also carries its speed over.
    if (DSPos754On("vel754")) [self pos752AfterMove];
}

- (void)updateShadow {
    DSPerfCount(DSPerfCounterShadowUpdates);
    CGRect frame = self.frame;
    if (_keyboardBandHeight > 1.0) {
        frame.size.height = MAX(CGRectGetHeight(frame) - _keyboardBandHeight, 0.0);
    }
    if (DSPos752On("shadow752")) {
        // shadow752: same size, centre and transform as the card (less the
        // keyboard band at its bottom), so a transformed card keeps its shadow.
        CGAffineTransform t = self.transform;
        CGRect b = self.bounds;
        CGFloat band = _keyboardBandHeight > 1.0 ? _keyboardBandHeight : 0.0;
        CGRect sb = CGRectMake(0, 0, CGRectGetWidth(b), MAX(CGRectGetHeight(b) - band, 0.0));
        CGAffineTransform lin = t; lin.tx = 0; lin.ty = 0;
        CGPoint off = CGPointApplyAffineTransform(CGPointMake(0, -band / 2.0), lin);
        if (!CGAffineTransformEqualToTransform(_shadowView.transform, t)) _shadowView.transform = t;
        _shadowView.bounds = sb;
        _shadowView.center = CGPointMake(self.center.x + off.x, self.center.y + off.y);
    } else {
        if (!CGAffineTransformIsIdentity(_shadowView.transform)) _shadowView.transform = CGAffineTransformIdentity;
        _shadowView.frame = frame;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _shadowView.layer.cornerRadius = _cornerRadius;
    if (DSNative703On()) {
        // 4.5.703 native703: a soft Stage-Manager-like shadow from a shadowPath.
        CGSize size = _shadowView.bounds.size;
        if (size.width >= 2.0 && size.height >= 2.0 &&
            (fabs(size.width - _native703PathSize.width) > 0.25 || fabs(size.height - _native703PathSize.height) > 0.25 ||
             fabs(_cornerRadius - _native703PathRadius) > 0.25 || !_shadowView.layer.shadowPath)) {
            _native703PathSize = size;
            _native703PathRadius = _cornerRadius;
            _shadowView.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_shadowView.bounds cornerRadius:_cornerRadius].CGPath;
            DSFeature699MarkTrying("native703");
        }
        // 4.5.706 polish706: a held card's shadow is a little deeper (setHeld706:).
        float wantOpacity = _held706 ? 0.24f : 0.16f;
        if (_shadowView.layer.shadowOpacity != wantOpacity) {
            _shadowView.layer.shadowOpacity = wantOpacity;
            _shadowView.layer.shadowRadius = _held706 ? 26.0 : 18.0;
            _shadowView.layer.shadowOffset = CGSizeMake(0.0, _held706 ? 12.0 : 6.0);
        }
        [CATransaction commit];
        _shadowView.alpha = self.alpha;
        return;
    }
    if (_shadowView.layer.shadowPath) {
        _shadowView.layer.shadowPath = NULL;
        _shadowView.layer.shadowRadius = 24.0;
        _shadowView.layer.shadowOffset = CGSizeMake(0, -4);
        _native703PathSize = CGSizeZero;
    }
    // 4.5.698 perf698: this view has no fill and no content, so its shadow
    // never drew anything, but a layer shadow without a shadowPath still
    // costs an offscreen render pass every frame the card moves or animates.
    // Opacity 0 = the same picture with no pass. perf698 off = 0.28 again.
    {
        BOOL perf698 = DSPerf698On();
        float want = perf698 ? 0.0f : 0.28f;
        if (_shadowView.layer.shadowOpacity != want) {
            _shadowView.layer.shadowOpacity = want;
            if (perf698) DSPerf698MarkTrying();
        }
    }
    [CATransaction commit];
    _shadowView.alpha = self.alpha;
}

- (void)setAlpha:(CGFloat)alpha {
    [super setAlpha:alpha];
    _shadowView.alpha = alpha;
}

- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];
    _shadowView.hidden = hidden;
}

#pragma mark - Configuration

- (UIView *)contentView {
    return _contentView;
}

- (void)setCornerRadius:(CGFloat)cornerRadius {
    // 4.5.697: the stage pan sets the same radius on every frame (twice). Each
    // set was a full card relayout (mask, clip, rim catchers, shadow).
    if (fabs(cornerRadius - _cornerRadius) < 0.01 && DSPerf697On()) return;
    // 4.5.698 anim698: dragging a card toward a bottom corner rounds it a bit
    // more on every frame (the radius follows the corner approach). Each new
    // radius was a full card relayout: mask, clips, blur fill, rim catchers,
    // shadow. Only the corner radius changes, so set it on the layers that
    // carry it and skip the relayout. Same final values as layoutSubviews
    // (radius clamped to 20 like applyCardCornerClip). Not while the keyboard
    // band is open (that layout rounds only the top corners).
    if (DSAnim698On() && _keyboardBandHeight <= 1.0 && _clipsContents &&
        CGRectGetWidth(self.bounds) >= 2.0 && CGRectGetHeight(self.bounds) >= 2.0 &&
        (_contentView.layer.mask || DSPerf705On()) && fabs(CGRectGetWidth(_contentView.bounds) - CGRectGetWidth(self.bounds)) < 0.5 &&
        fabs(CGRectGetHeight(_contentView.bounds) - CGRectGetHeight(self.bounds)) < 0.5) {
        CGFloat r = MAX(cornerRadius, 20.0);
        if (fabs(r - _cornerRadius) < 0.01) return;
        _cornerRadius = r;
        DSAnim698MarkTrying();
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.layer.cornerRadius = r;
        _contentView.layer.cornerRadius = r;
        _contentView.layer.mask.cornerRadius = r;
        _backdrop.layer.cornerRadius = r;
        _backdrop.layer.mask.cornerRadius = r;
        for (UIView *subview in _backdrop.subviews) {
            if (subview.layer.cornerRadius > 0.5) subview.layer.cornerRadius = r;
        }
        _perf705BlurRadius = r;
        _shadowView.layer.cornerRadius = r;
        [CATransaction commit];
        return;
    }
    _cornerRadius = cornerRadius;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.layer.cornerRadius = cornerRadius;
    _contentView.layer.cornerRadius = cornerRadius;
    _contentView.layer.cornerCurve = kCACornerCurveContinuous;
    [CATransaction commit];
    [self updateShadow];
    [self setNeedsLayout];
}

- (void)resetRoundedGeometry {
    if (_cornerRadius < 20.0) _cornerRadius = 20.0;
    _keyboardBandHeight = 0.0;
    [self setClipsContents:YES];
    self.layer.mask = nil;
    [self setNeedsLayout];
    [self layoutIfNeeded];
}

- (void)stopMotion {
    [self removeMotionFromView:self depth:0];
    [_shadowView.layer removeAllAnimations];
}

- (void)removeMotionFromView:(UIView *)view depth:(NSInteger)depth {
    if (!view || depth > 5) return;
    [view.layer removeAllAnimations];
    for (UIView *subview in view.subviews) {
        [self removeMotionFromView:subview depth:depth + 1];
    }
}

- (void)setDarkMode:(BOOL)darkMode {
    _darkMode = darkMode;
    UIBlurEffectStyle style = darkMode ? UIBlurEffectStyleSystemThickMaterialDark
                                       : UIBlurEffectStyleSystemThickMaterialLight;
    _backdrop.effect = [UIBlurEffect effectWithStyle:style];
    _grabberPill.backgroundColor = darkMode ? [UIColor colorWithWhite:1.0 alpha:0.34]
                                            : [UIColor colorWithWhite:0.0 alpha:0.26];
    if (@available(iOS 13.0, *)) {
        self.overrideUserInterfaceStyle = darkMode ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
    }
}

- (void)setClipsContents:(BOOL)clips {
    // Callers pass NO while a keyboard is up. That window is not inside this
    // card, and clearing the clip is what squared the fill after Beeper.
    (void)clips;
    _clipsContents = YES;
    [self applyCardCornerClip];
}

- (void)setKeyboardBandHeight:(CGFloat)keyboardBandHeight {
    CGFloat height = MAX(keyboardBandHeight, 0.0);
    if (fabs(_keyboardBandHeight - height) < 0.5) return;
    _keyboardBandHeight = height;
    [self setNeedsLayout];
    [self layoutIfNeeded];
    [self updateShadow];
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.userInteractionEnabled || self.hidden || self.alpha < 0.01) return nil;
    if (![self pointInside:point withEvent:event]) return nil;
    if (_keyboardBandHeight > 1.0 &&
        point.y >= CGRectGetHeight(self.bounds) - _keyboardBandHeight) {
        return nil;
    }
    // 4.5.651: the rim strips first (window-server catchers).
    for (DSRimCatcherView *strip in _rimCatchers) {
        if (strip.hidden) continue;
        UIView *hit = [strip hitTest:[self convertPoint:point toView:strip] withEvent:event];
        if (hit) return hit;
    }
    // The outer band is the drag rim. A hosted scene that is still the size of
    // the screen sits on top of that band and swallows the touch, so the rim
    // never starts a drag. Claiming the band here keeps it above the app.
    CGFloat band731 = DS809Latched("rim731") ? 0.0 : kDSStageRimGrabBand;   // 4.5.731 rim731
    CGRect interior = CGRectInset(self.bounds, band731, band731);
    if (band731 > 0.0 && CGRectGetWidth(interior) >= 40.0 && CGRectGetHeight(interior) >= 40.0 &&
        !CGRectContainsPoint(interior, point)) {
        // The + button reaches into the band; it keeps its tap.
        if (!_stackAddButton.hidden && _stackAddButton.userInteractionEnabled &&
            CGRectContainsPoint(_stackAddButton.frame, point)) {
            return _stackAddButton;
        }
        return self;
    }
    UIView *hit = [super hitTest:point withEvent:event];
    if (!_passThroughToHost) return hit;
    if (!hit) return nil;
    if (hit == _grabber || [hit isDescendantOfView:_grabber]) return hit;
    if (hit == _stackAddButton || [hit isDescendantOfView:_stackAddButton]) return hit;
    return nil;
}

- (void)setBackdropHidden:(BOOL)hidden {
    if (_backdrop.hidden != hidden) {
        DSPerfCount(DSPerfCounterBlurToggles);
        // 4.5.705 perf705: shown again = round its inner views at the next clip pass.
        if (!hidden) _perf705BlurSubviews = NSUIntegerMax;
    }
    _backdrop.hidden = hidden;
    if (!hidden && DSPerf705On()) [self setNeedsLayout];
}

// 4.5.706 polish706: picked up = the shadow grows a little (deeper, softer,
// further down), put down = it settles back. Shadow layer only: the card's
// frame, transform and size are never touched.
- (void)setHeld706:(BOOL)held {
    if (_held706 == held) return;
    _held706 = held;
    if (!DSNative703On()) return;
    CALayer *layer = _shadowView.layer;
    float opacity = held ? 0.24f : 0.16f;
    CGFloat radius = held ? 26.0 : 18.0;
    CGSize offset = CGSizeMake(0.0, held ? 12.0 : 6.0);
    BOOL reduce = UIAccessibilityIsReduceMotionEnabled();
    if (!reduce && self.window && !self.hidden) {
        CFTimeInterval duration = held ? 0.18 : 0.30;
        CAMediaTimingFunction *curve = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        NSDictionary *from = @{ @"shadowOpacity" : @(layer.presentationLayer ? layer.presentationLayer.shadowOpacity : layer.shadowOpacity),
                                @"shadowRadius" : @(layer.presentationLayer ? layer.presentationLayer.shadowRadius : layer.shadowRadius),
                                @"shadowOffset" : [NSValue valueWithCGSize:layer.presentationLayer ? layer.presentationLayer.shadowOffset : layer.shadowOffset] };
        for (NSString *key in from) {
            CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:key];
            animation.fromValue = from[key];
            animation.duration = duration;
            animation.timingFunction = curve;
            [layer addAnimation:animation forKey:[@"held706-" stringByAppendingString:key]];
        }
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.shadowOpacity = opacity;
    layer.shadowRadius = radius;
    layer.shadowOffset = offset;
    [CATransaction commit];
}

- (BOOL)held706 {
    return _held706;
}

- (BOOL)perf705BlurVisible {
    return _backdrop && !_backdrop.hidden && !self.hidden && self.alpha > 0.01;
}

- (BOOL)perf705HasMask {
    return _contentView.layer.mask != nil || _backdrop.layer.mask != nil;
}

// Deep enough and wide enough to be found with a thumb, and in the corner the
// stage came out of so sending it back there is the same movement reversed.
- (CGRect)cornerGripRect {
    CGRect bounds = self.bounds;
    CGFloat width = MIN(kDSTriggerWidth + 28.0, CGRectGetWidth(bounds));
    // Deep, because a thumb reaching the bottom right corner of the card lands above it
    // as often as on it: on the phone the drags that missed were starting twenty and
    // thirty points high.
    CGFloat height = MIN(72.0, CGRectGetHeight(bounds));
    return CGRectMake(CGRectGetWidth(bounds) - width,
                      CGRectGetHeight(bounds) - height,
                      width,
                      height);
}

// The whole right side of the card, under the top buttons. A swipe that starts
// here and moves inward leaves the app and brings the picker back.
- (CGRect)edgeGripRect {
    CGRect bounds = self.bounds;
    CGFloat width = 44.0;
    CGFloat top = 46.0;
    if (top > CGRectGetHeight(bounds)) top = 0.0;
    return CGRectMake(CGRectGetWidth(bounds) - width, top, width, CGRectGetHeight(bounds) - top);
}

- (void)applyKeyboardShift {
    // A transform rather than a new frame: the card's resting frame belongs to
    // whichever state it is in, and the keyboard is only borrowing the space.
    CGAffineTransform shift = CGAffineTransformMakeTranslation(_sideOffset, -_liftOffset);
    self.transform = shift;
    _shadowView.transform = shift;
    if (_liftDidChangeHandler) _liftDidChangeHandler();
}

- (void)setLiftOffset:(CGFloat)offset {
    if (_drag702Frozen && fabs(offset - _liftOffset) > 0.01) return;
    _liftOffset = offset;
    [self applyKeyboardShift];
}

// 4.5.755 spring755: both keyboard offsets in one transform write, so a hide
// is one spring back (two writes made pos751 take over twice).
- (void)setLiftOffset:(CGFloat)lift sideOffset:(CGFloat)side {
    if (_drag702Frozen && (fabs(lift - _liftOffset) > 0.01 || fabs(side - _sideOffset) > 0.01)) return;
    if (fabs(lift - _liftOffset) <= 0.01 && fabs(side - _sideOffset) <= 0.01) return;
    _liftOffset = lift;
    _sideOffset = side;
    [self applyKeyboardShift];
}

- (void)setSideOffset:(CGFloat)offset {
    if (_drag702Frozen && fabs(offset - _sideOffset) > 0.01) return;
    _sideOffset = offset;
    [self applyKeyboardShift];
}

- (void)setHostingApp:(BOOL)hostingApp {
    _hostingApp = hostingApp;
    _cornerGrip.userInteractionEnabled = NO;
    _edgeGrip.userInteractionEnabled = NO;
    (void)hostingApp;
}

@end
