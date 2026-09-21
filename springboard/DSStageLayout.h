#import <CoreGraphics/CoreGraphics.h>
#import "DSConstants.h"

// Pure geometry for the stage card. No UIKit, no SpringBoard — only the numbers
// traced from the stock tweak's walkthrough on a 430×932pt display.

typedef NS_ENUM(NSInteger, DSStageLayoutMode) {
    DSStageLayoutModeClosed = 0,
    DSStageLayoutModeOverlay,
    DSStageLayoutModeSplit,
};

struct DSStageLayoutContext {
    CGRect screen;
    CGFloat splitLine;
    CGFloat displayRadius;
};

struct DSStageLayoutContext DSStageLayoutContextMake(CGRect screen, CGFloat displayRadius);

CGRect DSStageRestingFrame(struct DSStageLayoutContext ctx, DSStageLayoutMode mode);
CGRect DSStageTypingFrame(struct DSStageLayoutContext ctx,
                          DSStageLayoutMode mode,
                          CGFloat keyboardHeight,
                          CGFloat headroomAboveKeyboard);
CGFloat DSStagePickerLiftForKeyboard(CGRect keyboardFrame, CGRect restingCardFrame, CGFloat inset);

// Stack slot 0 = bottom card, slot 1 = top card (above slot 0). `count` is 1 or 2.
CGRect DSStageStackSlotFrame(CGRect combinedCardFrame, NSInteger slot, NSInteger count, CGFloat gap);
