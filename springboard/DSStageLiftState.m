#import "DSStageLiftState.h"

static DSLiftSlotState gLiftSlots[4];

void DSResetLiftSlots(void) {
    for (int i = 0; i < 4; i++) {
        gLiftSlots[i].hasRestingFrame = NO;
        gLiftSlots[i].baseCardY = 0;
        gLiftSlots[i].baseCardH = 0;
        gLiftSlots[i].baseRestMaxY = 0;
        gLiftSlots[i].keyboardFrozen = NO;
        gLiftSlots[i].frozenKeysY = 0;
        gLiftSlots[i].frozenKeysH = 0;
    }
}

DSLiftSlotState *DSLiftSlotAt(NSInteger slot) {
    if (slot < 0 || slot > 3) return &gLiftSlots[0];
    return &gLiftSlots[slot];
}
