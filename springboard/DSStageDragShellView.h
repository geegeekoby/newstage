#import <UIKit/UIKit.h>

@class DSStageContainerView;

// Transparent bezel around the stage card. Touches on the band hit this view so
// drags are not stolen by a hosted app; touches on the card go to the card.
@interface DSStageDragShellView : UIView

@property (nonatomic, weak) DSStageContainerView *cardView;
// 0 keeps the full rim. 1 pulses its bottom half, 2 pulses its top half.
@property (nonatomic, assign) NSInteger rimHalf;
// The bezel is wider than the gap between stages. Points on the other card
// must fall through, or a grab on the lower stage moves the upper one.
@property (nonatomic, copy) BOOL (^rejectsWindowPoint)(CGPoint windowPoint);

- (void)setGhostRed:(BOOL)red;
// The card translates inside this shell. The stroke has to go with it.
- (void)setOutlineLift:(CGFloat)offset;
- (void)setOutlineShiftX:(CGFloat)side lift:(CGFloat)offset;
// Removes the stroke. A terminated card was leaving this outline on screen.
- (void)clearOutline;
// The rim's frame in this shell. It has to match the card.
- (CGRect)outlineFrame;
// Moves the stroke onto the card without laying out the hosted scene.
// Laying that scene out from a keyboard shift is the SIGTRAP.
- (void)refreshOutline;
// 4.5.651: window rect the outer rim strips must leave alone (the other split
// card's interior); CGRectNull for none. Re-lays the strips.
- (void)setRimCatcherAvoidRect:(CGRect)windowRect;

@end
