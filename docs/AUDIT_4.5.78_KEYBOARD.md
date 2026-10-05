# Audit: 4.5.78 baseline — bottom stage & keyboard

Repo reset to commit **`6bf6751` (4.5.78)**. This document lists what still relates to **bottom half**, **second stack slot**, or **invisible keyboard** behavior, and what was fixed on top of the reset.

## Runtime model in 4.5.78

| Setting | Value |
|--------|--------|
| `kDSMaxStackSlots` | **1** (`shared/DSConstants.h`) |
| Second card / “bottom stage” slot | **Not created** at runtime (`_stackSlotCount` stays 1) |
| Card on **bottom half** | Valid — `_primaryHalf == 0`, single `_container` / slot 0 |

So “bottom stage keyboard bug” in 4.5.78 usually means: **one card snapped to the bottom half**, not a second stack slot.

## Files with dual-stack / bottom-keyboard code (dormant but present)

These are **still in the 4.5.78 tree** for historical dual-stack; they do not run when `_stackSlotCount == 1` **if gated correctly**:

| File | What remains |
|------|----------------|
| `springboard/DSStageManager.m` | `_topContainer`, `_topSceneHost`, `ensureTopStackInfrastructure`, `slotOnBottomHalf`, companion lift, `keyboardBand*` / `clearHostedKeyboardBands`, `noteHostedAppKeyboard` in-scene stall |
| `springboard/DSStageContainerView.*` | `keyboardBandHeight`, band layout, hit-test pass-through band |
| `springboard/DSSceneHost.*` | `keyboardClipHeight` (comment mentions “bottom stage”) |
| `springboard/DSStageShelfView.m` | `_bottomBundle` (shelf UI; not keyboard) |
| `springboard/DSKeyboardVisibility.m` | `keyboardBand` heuristic for window census (not card band) |
| `app/Tweak.xm` | Remote keyboard / bottom-slab detection for staged apps |

No `docs/STAGE_KEYBOARD.md` in 4.5.78 (added in later releases).

## Bug: dual-stack keyboard logic with one card

Several paths used **`_stackSlotCount >= kDSMaxStackSlots`**. With **`kDSMaxStackSlots == 1`** and **`_stackSlotCount == 1`**, that is **always true**, so:

- **Companion off-screen lift** could move the unused `_topContainer` while typing on the bottom half.
- **Top-half “ignore keyboard”** used `_stackSlotCount < kDSMaxStackSlots`, which is **never true** → top-half single card did not skip lift as intended.
- **`slotOnBottomHalf`** / **`slotOwningKeyboardSource`** behaved like dual-stack for UIKit notifications.

**Fix (4.5.125):** `isDualStackActive` → `_stackSlotCount > 1`; keyboard paths use that instead of `>= kDSMaxStackSlots`. Single-card SpringBoard keyboard attribution returns **slot 0**.

## Invisible keyboard on bottom half (still 4.5.78 behavior)

These are **intentional in 4.5.78**, not “leftover” from later versions:

1. **`noteKeyboardFrame:`** early return when keys are still drawn **inside the app scene** (`hostedAppKeys && !_keyboardDrawnOutside`) — card does not lift until SpringBoard draws keys.
2. **`noteHostedAppKeyboard:`** waits for **`springBoardIsDrawingKeyboard`** before delayed lift; logs “keyboard stays in the scene…”.
3. **`keyboardBandHeight`** is only **cleared**, never set anywhere in the repo — band UI is inert but **`keyboardClipHeight`** can still track band if band were set externally.

If bottom-half typing still looks invisible after 4.5.125, the next lever is **lift-only / always reach `noteKeyboardFrame`** (4.5.121+), not re-enabling dual-stack band paths.

## Not present in 4.5.78 (removed by reset)

Nothing from **4.5.79–4.5.124** remains in the tree after hard reset, including: split host, drop outline, `isSplitApplication:`, `STAGE_KEYBOARD.md`, CONTRIBUTING keyboard guards, second-slot shelf “Below” flows from 4.5.108, etc.

## Why 4.5.126 bottom half still looked like the old bug

4.5.126 added a **second card and shelf UI**, not a new keyboard stack. **`noteHostedAppKeyboard` / `noteKeyboardFrame` are shared** for slot 0 and slot 1.

The **top half often looked fine** because **`noteKeyboardFrame`** clears the keyboard when the lifting card sits on the **top half** (no lift). That is a **different rule**, not proof that keyboard code was rewritten per half.

The **bottom half** still ran the **4.5.78 lift path** (wait for keys outside the scene, band/extend hooks). Resetting to 4.5.78 and gating with **`isDualStackActive`** did not remove that behavior.

**4.5.127** finishes the **lift-only** port in `DSStageManager` (no scene extend on attach/swap, no band clears in the manager). Card **`keyboardBandHeight`** in `DSStageContainerView` is unused when the manager never sets it.

## Recommended next steps (if bottom half still fails on device)

1. Test **4.5.127** on bottom-half single card and dual-stack bottom slot after dock restore.
2. If still broken: capture `keyboard-stage.log` and check whether `DSRaiseKeyboardWindowAboveStage` / visible UIKeyboard frame lag attribution.
3. Only re-enable scene band/clip keyboard design together with explicit tests — not `>= kDSMaxStackSlots` gating.
