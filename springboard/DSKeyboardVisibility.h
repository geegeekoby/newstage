#import <CoreGraphics/CoreGraphics.h>

// Walks every on-screen UIWindow (window scenes first, then UIApplication.windows)
// and returns the frame of a visible UIKeyboard in screen coordinates, or
// CGRectNull when none is on the display.
CGRect DSVisibleKeyboardFrameOnScreen(void);

// Unhides SpringBoard's own keyboard window when it actually contains keys, and
// keeps it above the stage. Returns YES when a keyboard is on the display.
BOOL DSRevealSpringBoardKeyboard(void);

// Shows the staged app's keyboard context in SpringBoard's remote keyboard
// window, above the stage. Pass 0 to put that window away.
void DSHostKeyboardContext(unsigned int contextID);
