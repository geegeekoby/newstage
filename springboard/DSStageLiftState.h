#import <CoreGraphics/CoreGraphics.h>
#import <objc/objc.h>

// One slot's card, saved before the keyboard lift. The lifted origin
// (resting Y minus the lift) is never written here.
typedef struct {
    BOOL hasRestingFrame;
    CGFloat baseCardY;
    CGFloat baseCardH;
    CGFloat baseRestMaxY;
    BOOL keyboardFrozen;
    CGFloat frozenKeysY;
    CGFloat frozenKeysH;
} DSLiftSlotState;

void DSResetLiftSlots(void);
DSLiftSlotState *DSLiftSlotAt(NSInteger slot);
