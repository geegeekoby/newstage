#import "DSListController.h"

// "Pinned Applications": the pinned set in the order the stage shows it, draggable
// to reorder, plus the rest of the library underneath to pin from.
@interface DSPinnedAppsListController : DSListController <UISearchResultsUpdating, UISearchBarDelegate>
@end
