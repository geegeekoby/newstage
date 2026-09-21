#import <CoreGraphics/CoreGraphics.h>

// Walks every on-screen UIWindow (window scenes first, then UIApplication.windows)
// and returns the frame of a visible UIKeyboard in screen coordinates, or
// CGRectNull when none is on the display.
CGRect DSVisibleKeyboardFrameOnScreen(void);
