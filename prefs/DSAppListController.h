#import "DSListController.h"

// "Application Behaviors": every installed app, searchable, each row pushing its
// own behaviour page.
@interface DSAppListController : DSListController <UISearchResultsUpdating, UISearchBarDelegate>
@end
