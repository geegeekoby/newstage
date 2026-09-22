#import "DSStageLayout.h"

struct DSStageLayoutContext DSStageLayoutContextMake(CGRect screen, CGFloat displayRadius) {
    struct DSStageLayoutContext ctx;
    ctx.screen = screen;
    ctx.splitLine = floor(CGRectGetHeight(screen) * kDSSplitRatio);
    ctx.displayRadius = displayRadius;
    return ctx;
}

CGRect DSStageRestingFrame(struct DSStageLayoutContext ctx, DSStageLayoutMode mode) {
    CGFloat w = CGRectGetWidth(ctx.screen);
    CGFloat h = CGRectGetHeight(ctx.screen);
    CGFloat top = ctx.splitLine + kDSStageInset;

    switch (mode) {
        case DSStageLayoutModeSplit:
            return CGRectMake(0, top, w, h - top);
        case DSStageLayoutModeOverlay:
            return CGRectMake(kDSStageInset, top, w - kDSStageInset * 2.0, h - top - kDSStageInset);
        default:
            return CGRectMake(kDSStageInset, h, w - kDSStageInset * 2.0, h - top - kDSStageInset);
    }
}

CGRect DSStageTypingFrame(struct DSStageLayoutContext ctx,
                          DSStageLayoutMode mode,
                          CGFloat keyboardHeight,
                          CGFloat headroomAboveKeyboard) {
    if (keyboardHeight < kDSKeyboardPresentHeight) {
        return DSStageRestingFrame(ctx, mode);
    }

    CGRect resting = DSStageRestingFrame(ctx, mode);
    CGFloat keyboardTop = CGRectGetHeight(ctx.screen) - keyboardHeight;
    CGFloat lift = CGRectGetMaxY(resting) - keyboardTop;
    if (lift < 0.0) lift = 0.0;

    CGRect expanded = CGRectOffset(resting, 0.0, -lift);
    expanded.origin.x = 0.0;
    expanded.size.width = CGRectGetWidth(ctx.screen);
    expanded.size.height = CGRectGetHeight(ctx.screen) - expanded.origin.y;

    CGFloat minY = headroomAboveKeyboard;
    if (CGRectGetMinY(expanded) < minY) {
        expanded.origin.y = minY;
        expanded.size.height = MAX(keyboardTop - minY, 180.0);
    }
    return expanded;
}

CGFloat DSStagePickerLiftForKeyboard(CGRect keyboardFrame, CGRect restingCardFrame, CGFloat inset) {
    if (CGRectIsEmpty(keyboardFrame)) return 0.0;
    CGFloat overlap = CGRectGetMaxY(restingCardFrame) - CGRectGetMinY(keyboardFrame) + inset;
    return MAX(overlap, 0.0);
}

CGRect DSStageStackSlotFrame(CGRect combinedCardFrame, NSInteger slot, NSInteger count, CGFloat gap) {
    if (count <= 1) return combinedCardFrame;
    CGFloat height = (CGRectGetHeight(combinedCardFrame) - gap) / 2.0;
    if (slot == 1) {
        return CGRectMake(combinedCardFrame.origin.x,
                          combinedCardFrame.origin.y,
                          combinedCardFrame.size.width,
                          height);
    }
    return CGRectMake(combinedCardFrame.origin.x,
                      combinedCardFrame.origin.y + height + gap,
                      combinedCardFrame.size.width,
                      height);
}

CGRect DSStageStackHalfScreenFrame(CGRect screen, NSInteger slot, CGFloat gap, CGFloat inset) {
    CGFloat width = CGRectGetWidth(screen);
    CGFloat height = CGRectGetHeight(screen);
    CGFloat innerWidth = width - inset * 2.0;
    CGFloat usableHeight = height - inset * 2.0 - gap;
    CGFloat slotHeight = floor(usableHeight * 0.5);
    if (slot == 1) {
        return CGRectMake(inset, inset, innerWidth, slotHeight);
    }
    return CGRectMake(inset, inset + slotHeight + gap, innerWidth, slotHeight);
}
