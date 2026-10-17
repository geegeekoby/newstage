#import <unistd.h>
#import <QuartzCore/QuartzCore.h>
#import "DSAppPickerViewController.h"
#import "DSAppCellContentView.h"
#import "DSSearchFieldView.h"
#import "DSPreferences.h"
#import "DSStageManager.h"
#import "DSStageDebug.h"
#import "DSCrashLog.h"
#import "DSDiagnostics.h"
#import "DSKeyboardVisibility.h"

// A plain UIScrollView refuses to cancel a touch that started on a UIControl,
// so a drag that begins on an app row never scrolls. This one lets the row
// keep a tap and still gives a vertical drag to the scroll.
@interface DSPickerScrollView : UIScrollView
@end

@implementation DSPickerScrollView

- (BOOL)touchesShouldCancelInContentView:(UIView *)view {
    return YES;
}

@end
#import "DSConstants.h"
#import <AudioToolbox/AudioToolbox.h>

// How long the plate has to be held before the app opens fullscreen instead of
// on the stage.
static const NSTimeInterval kDSHoldDuration = 0.55;

@interface DSAppPickerViewController () <UIScrollViewDelegate, DSSearchFieldDelegate, DSAppPickerDelegate>
- (void)loadApps819;
@end

@implementation DSAppPickerViewController {
    UIScrollView *_scrollView;
    UIScrollView *_recentStrip;
    DSSearchFieldView *_searchField;
    UILabel *_recentsHeader;
    UILabel *_libraryHeader;
    UILabel *_emptyLabel;
    NSMutableArray<DSAppCellContentView *> *_recentCells;
    NSMutableArray<DSAppCellContentView *> *_libraryCells;

    NSArray<DSAppEntry *> *_recents;
    NSArray<DSAppEntry *> *_library;
    NSString *_query;
    BOOL _noReload819;
    DSAppPickerViewController *_child819;   // 4.5.819 picker819, built on first show

    DSAppCellContentView *_heldCell;
    NSTimer *_holdTimer;
    UIImpactFeedbackGenerator *_feedback;
    UIButton *_copyLogs;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    _recentCells = [NSMutableArray array];
    _libraryCells = [NSMutableArray array];
    _query = @"";
    _feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];

    _scrollView = [[DSPickerScrollView alloc] initWithFrame:self.view.bounds];
    _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scrollView.showsVerticalScrollIndicator = NO;
    _scrollView.alwaysBounceVertical = YES;
    _scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    _scrollView.delaysContentTouches = YES;
    _scrollView.canCancelContentTouches = YES;
    _scrollView.directionalLockEnabled = YES;
    _scrollView.delegate = self;
    if (@available(iOS 11.0, *)) _scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self.view addSubview:_scrollView];

    _recentStrip = [[DSPickerScrollView alloc] initWithFrame:CGRectZero];
    _recentStrip.showsHorizontalScrollIndicator = NO;
    _recentStrip.showsVerticalScrollIndicator = NO;
    _recentStrip.alwaysBounceHorizontal = YES;
    _recentStrip.alwaysBounceVertical = NO;
    _recentStrip.delaysContentTouches = YES;
    _recentStrip.canCancelContentTouches = YES;
    _recentStrip.clipsToBounds = NO;
    _recentStrip.directionalLockEnabled = YES;
    [_scrollView addSubview:_recentStrip];

    _searchField = [[DSSearchFieldView alloc] initWithFrame:CGRectZero];
    _searchField.delegate = self;
    [_scrollView addSubview:_searchField];

    _copyLogs = [UIButton buttonWithType:UIButtonTypeSystem];
    [_copyLogs setTitle:@"Copy Logs" forState:UIControlStateNormal];
    _copyLogs.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    [_copyLogs addTarget:self action:@selector(copyLogsTapped) forControlEvents:UIControlEventTouchUpInside];
    [_scrollView addSubview:_copyLogs];

    _recentsHeader = [self sectionHeaderWithText:@"Recent"];
    [_scrollView addSubview:_recentsHeader];

    _libraryHeader = [self sectionHeaderWithText:@"App Library"];
    [_scrollView addSubview:_libraryHeader];

    _emptyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _emptyLabel.font = [UIFont systemFontOfSize:15.0];
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.numberOfLines = 0;
    _emptyLabel.hidden = YES;
    [_scrollView addSubview:_emptyLabel];

    [self reloadContent];
}

- (void)copyLogsTapped {
    @try {
        NSMutableString *text = [NSMutableString string];
        NSString *geometry = [[DSStageManager sharedManager] stageGeometryDebugSummary];
        [text appendFormat:@"%@\n--- log ---\n%@\n--- trace ---\n%@\n--- crash ---\n%@\n--- diagnostics ---\n%@\n--- kbvis768 ---\n%@",
         geometry ?: @"",
         DSLogDump() ?: @"",
         DSTraceRead() ?: @"",
         DSCrashLogRead() ?: @"",
         DSDiagnosticsRead() ?: @"",
         DSKbVis768Read() ?: @""];
        UIPasteboard.generalPasteboard.string = text;
        [_copyLogs setTitle:@"Copied" forState:UIControlStateNormal];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self->_copyLogs setTitle:@"Copy Logs" forState:UIControlStateNormal];
        });
    } @catch (NSException *exception) {
        [_copyLogs setTitle:@"Copy failed" forState:UIControlStateNormal];
    }
}

- (UILabel *)sectionHeaderWithText:(NSString *)text {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    label.text = text;
    return label;
}

#pragma mark - Content

- (void)reloadContent {
    if (_child819) { [_child819 reloadContent]; return; }
    DSAppLibrary *library = [DSAppLibrary sharedLibrary];
    // 4.5.819 search819: a keystroke filters the list already loaded (the
    // whole LaunchServices walk ran on every key). Off: search819-off.
    if (!(_noReload819 && library.applications.count > 0 && DS819On("search819"))) [library reload];
    _noReload819 = NO;

    if (_query.length > 0) {
        _recents = @[];
        _library = [library applicationsMatchingSearch:_query];
    } else {
        // Recently opened apps lead. Pinned apps only fill slots that are still
        // empty, so a new launch shows up instead of staying behind the defaults.
        NSMutableArray<DSAppEntry *> *grid = [NSMutableArray array];
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        NSInteger rows = MAX([DSPreferences sharedPreferences].pinnedRows, 1);
        NSInteger capacity = rows * 2;
        for (DSAppEntry *entry in [library recentApplicationsLimitedTo:capacity]) {
            if (grid.count >= (NSUInteger)capacity) break;
            if (entry.bundleIdentifier.length == 0 || [seen containsObject:entry.bundleIdentifier]) continue;
            [seen addObject:entry.bundleIdentifier];
            [grid addObject:entry];
        }
        for (DSAppEntry *entry in [library pinnedApplications]) {
            if (grid.count >= (NSUInteger)capacity) break;
            if (entry.bundleIdentifier.length == 0 || [seen containsObject:entry.bundleIdentifier]) continue;
            [seen addObject:entry.bundleIdentifier];
            [grid addObject:entry];
        }
        if (grid.count > (NSUInteger)capacity) {
            grid = [[grid subarrayWithRange:NSMakeRange(0, capacity)] mutableCopy];
        }
        _recents = grid;
        _library = library.applications;
    }

    [self rebuildCells];
    [self applyAppearance];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
}

- (void)rebuildCells {
    [self reconcileCells:_recentCells toCount:_recents.count parent:_recentStrip chipStyle:YES];
    [self reconcileCells:_libraryCells toCount:_library.count parent:_scrollView chipStyle:NO];

    DSAppLibrary *library = [DSAppLibrary sharedLibrary];
    [_recentCells enumerateObjectsUsingBlock:^(DSAppCellContentView *cell, NSUInteger index, BOOL *stop) {
        DSAppEntry *entry = self->_recents[index];
        cell.entry = entry;
        cell.showsNowPlaying = [library isNowPlayingApplication:entry.bundleIdentifier];
        cell.unavailable = [self->_unavailableBundleIdentifiers containsObject:entry.bundleIdentifier];
    }];
    [_libraryCells enumerateObjectsUsingBlock:^(DSAppCellContentView *cell, NSUInteger index, BOOL *stop) {
        DSAppEntry *entry = self->_library[index];
        cell.entry = entry;
        cell.showsNowPlaying = [library isNowPlayingApplication:entry.bundleIdentifier];
        cell.unavailable = [self->_unavailableBundleIdentifiers containsObject:entry.bundleIdentifier];
    }];

    _recentsHeader.hidden = _recents.count == 0;
    _libraryHeader.hidden = _library.count == 0;
    _emptyLabel.hidden = !(_library.count == 0 && _recents.count == 0);
    _emptyLabel.text = _query.length > 0
        ? [NSString stringWithFormat:@"No apps match \u201c%@\u201d", _query]
        : @"No apps are available on the stage. Check Application Behaviors in Settings.";
}

- (void)reconcileCells:(NSMutableArray<DSAppCellContentView *> *)cells
             toCount:(NSUInteger)count
              parent:(UIView *)parent
           chipStyle:(BOOL)chipStyle {
    while (cells.count > count) {
        [cells.lastObject removeFromSuperview];
        [cells removeLastObject];
    }
    while (cells.count < count) {
        DSAppCellContentView *cell = [[DSAppCellContentView alloc] initWithFrame:CGRectZero];
        [cell addTarget:self action:@selector(cellTouchDown:) forControlEvents:UIControlEventTouchDown];
        [cell addTarget:self action:@selector(cellTapped:) forControlEvents:UIControlEventTouchUpInside];
        [cell addTarget:self action:@selector(cellTouchCancelled:)
       forControlEvents:UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
        [parent addSubview:cell];
        [cells addObject:cell];
    }
    for (DSAppCellContentView *cell in cells) {
        if (cell.superview != parent) {
            [cell removeFromSuperview];
            [parent addSubview:cell];
        }
        cell.chipStyle = chipStyle;
    }
}

#pragma mark - Layout

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat width = CGRectGetWidth(self.view.bounds);
    CGFloat contentWidth = width - kDSContentInset * 2.0;
    // The card's outer band is the drag rim. Search starts below it.
    CGFloat y = kDSStageRimGrabBand + 8.0;

    _searchField.frame = CGRectMake(kDSContentInset, y, contentWidth, kDSSearchFieldHeight);
    y += kDSSearchFieldHeight + 8.0;
    _copyLogs.frame = CGRectMake(kDSContentInset, y, contentWidth, 36.0);
    y += 36.0 + 8.0;

    _recentStrip.hidden = _recentsHeader.hidden;
    if (!_recentsHeader.hidden) {
        _recentsHeader.frame = CGRectMake(kDSContentInset, y, contentWidth, kDSSectionHeaderHeight);
        y += kDSSectionHeaderHeight;
        _recentStrip.frame = CGRectMake(0.0, y, width, kDSRecentStripHeight);
        CGFloat chipGap = 4.0;
        [_recentCells enumerateObjectsUsingBlock:^(DSAppCellContentView *cell, NSUInteger index, BOOL *stop) {
            cell.frame = CGRectMake(kDSContentInset + index * (kDSRecentChipWidth + chipGap),
                                    0.0,
                                    kDSRecentChipWidth,
                                    kDSRecentStripHeight);
        }];
        CGFloat stripWidth = kDSContentInset * 2.0;
        if (_recentCells.count > 0) {
            stripWidth = kDSContentInset + _recentCells.count * kDSRecentChipWidth + (_recentCells.count - 1) * chipGap + kDSContentInset;
        }
        _recentStrip.contentSize = CGSizeMake(MAX(stripWidth, width), kDSRecentStripHeight);
        y += kDSRecentStripHeight;
    }

    if (!_libraryHeader.hidden) {
        _libraryHeader.frame = CGRectMake(kDSContentInset, y, contentWidth, kDSSectionHeaderHeight);
        y += kDSSectionHeaderHeight;
        [_libraryCells enumerateObjectsUsingBlock:^(DSAppCellContentView *cell, NSUInteger index, BOOL *stop) {
            cell.frame = CGRectMake(kDSContentInset,
                                    y + index * (kDSCellHeight + kDSCellGap),
                                    contentWidth,
                                    kDSCellHeight);
        }];
        if (_libraryCells.count > 0) {
            y += _libraryCells.count * kDSCellHeight + (_libraryCells.count - 1) * kDSCellGap;
        }
    }

    if (!_emptyLabel.hidden) {
        _emptyLabel.frame = CGRectMake(kDSContentInset + 16.0, y + 30.0, contentWidth - 32.0, 60.0);
        y += 110.0;
    }

    _scrollView.contentSize = CGSizeMake(width, y + 12.0);
}

- (void)applyAppearance {
    UIColor *headerColor = self.darkMode ? [UIColor colorWithWhite:1.0 alpha:0.5]
                                         : [UIColor colorWithWhite:0.0 alpha:0.45];
    _recentsHeader.textColor = headerColor;
    _libraryHeader.textColor = headerColor;
    _emptyLabel.textColor = headerColor;
    _searchField.darkMode = self.darkMode;
    for (DSAppCellContentView *cell in _recentCells) cell.darkMode = self.darkMode;
    for (DSAppCellContentView *cell in _libraryCells) cell.darkMode = self.darkMode;
}

- (void)setDarkMode:(BOOL)darkMode {
    _darkMode = darkMode;
    if (_child819) _child819.darkMode = darkMode;
    if (self.isViewLoaded) [self applyAppearance];
}

- (void)resetScrollPosition {
    if (_child819) { [_child819 resetScrollPosition]; return; }
    [_scrollView setContentOffset:CGPointZero animated:NO];
}

- (void)dismissKeyboard {
    if (_child819) { [_child819 dismissKeyboard]; return; }
    [_searchField endEditing:YES];
}

- (void)reassertSearchEditing {
    if (_child819) { [_child819 reassertSearchEditing]; return; }
    [_searchField reassertEditing];
}

- (void)restartSearchEditing {
    if (_child819) { [_child819 restartSearchEditing]; return; }
    [_searchField restartEditing];
}

- (BOOL)searchFieldIsEditing {
    if (_child819) return [_child819 searchFieldIsEditing];
    return [_searchField isEditingNow];
}

- (NSString *)searchEditingDebugSummary {
    if (_child819) return [_child819 searchEditingDebugSummary];
    return [_searchField editingDebugSummary] ?: @"fr=?";
}

#pragma mark - Search field

- (void)searchField:(DSSearchFieldView *)field didChangeText:(NSString *)text {
    _query = text ?: @"";
    _noReload819 = YES;
    [self reloadContent];
    [_scrollView setContentOffset:CGPointZero animated:NO];
}

- (void)searchFieldDidCancel:(DSSearchFieldView *)field {
    _query = @"";
    _noReload819 = YES;
    [self reloadContent];
}

- (void)searchFieldNeedsKeyWindow:(DSSearchFieldView *)field {
    if ([self.delegate respondsToSelector:@selector(appPickerNeedsKeyWindowForSearch:)]) {
        [self.delegate appPickerNeedsKeyWindowForSearch:self];
    }
}

- (void)searchFieldDidEndEditing:(DSSearchFieldView *)field {
    if ([self.delegate respondsToSelector:@selector(appPickerDidEndSearch:)]) {
        [self.delegate appPickerDidEndSearch:self];
    }
}

- (BOOL)searchFieldShouldWaitBeforeEditing:(DSSearchFieldView *)field {
    if (![self.delegate respondsToSelector:@selector(appPickerShouldWaitBeforeSearchEditing:)]) return NO;
    return [self.delegate appPickerShouldWaitBeforeSearchEditing:self];
}

#pragma mark - Selection and hold

- (void)setUnavailableBundleIdentifiers:(NSSet<NSString *> *)unavailableBundleIdentifiers {
    if (_child819) _child819.unavailableBundleIdentifiers = unavailableBundleIdentifiers;
    _unavailableBundleIdentifiers = [unavailableBundleIdentifiers copy];
    for (NSArray<DSAppCellContentView *> *group in @[ _recentCells, _libraryCells ]) {
        for (DSAppCellContentView *cell in group) {
            cell.unavailable = [self->_unavailableBundleIdentifiers containsObject:cell.entry.bundleIdentifier];
        }
    }
}

- (void)cellTouchDown:(DSAppCellContentView *)cell {
    if (cell.unavailable) return;
    [self cancelHold];
    _heldCell = cell;
    [_feedback prepare];
    [cell setHoldProgress:1.0 animated:YES duration:kDSHoldDuration];
    _holdTimer = [NSTimer scheduledTimerWithTimeInterval:kDSHoldDuration repeats:NO block:^(NSTimer *timer) {
        [self commitHold];
    }];
}

- (void)cellTouchCancelled:(DSAppCellContentView *)cell {
    [self cancelHold];
}

- (void)cellTapped:(DSAppCellContentView *)cell {
    BOOL committed = _holdTimer == nil && _heldCell == cell;
    [self cancelHold];
    if (committed) return;   // the hold already took the app fullscreen
    if (!cell.entry || cell.unavailable) return;
    [self.delegate appPicker:self didSelectEntry:cell.entry fromView:cell];
}

- (void)commitHold {
    DSAppCellContentView *cell = _heldCell;
    [_holdTimer invalidate];
    _holdTimer = nil;
    if (!cell.entry || cell.unavailable) return;

    [_feedback impactOccurred];
    [cell setHoldProgress:0.0 animated:YES duration:0.2];
    [self.delegate appPicker:self didHoldEntry:cell.entry fromView:cell];
}

- (void)cancelHold {
    [_holdTimer invalidate];
    _holdTimer = nil;
    [_heldCell setHoldProgress:0.0 animated:YES duration:0.18];
    _heldCell = nil;
}

#pragma mark - 4.5.819 picker819 (boot-safe host)

// Base class: nothing to load (the redesigned picker overrides it).
- (void)loadApps819 {
}

// Rules: never at SpringBoard launch (only after "stayed up"), main thread
// only, picker819-off / core819-off / crash latch / hang latch respected.
// Hang latch: /var/mobile/.dynamicstage-picker819-opening is written before
// the first build and removed once that build has been drawn; finding it
// left over from an earlier SpringBoard means that start never got there,
// so picker819 latches off (-crashed) and the classic picker stays.
- (void)activate819 {
    if (![self isMemberOfClass:DSAppPickerViewController.class]) return;
    if (_child819) { [_child819 loadApps819]; return; }   // one app-list read per stage open
    if (![NSThread isMainThread] || !DSStayedUp819 || !self.isViewLoaded) return;
    static BOOL refused = NO, markedThisBoot = NO;
    if (refused || !DS819On("picker819")) return;
    static const char *marker = "/var/mobile/.dynamicstage-picker819-opening";
    static const char *crashed = "/var/mobile/.dynamicstage-picker819-crashed";
    if (access(crashed, F_OK) == 0) {
        refused = YES;
        DSDiagnosticsRecord(@"SpringBoard: picker819 latched off (delete /var/mobile/.dynamicstage-picker819-crashed to allow it): classic picker");
        return;
    }
    if (!markedThisBoot && access(marker, F_OK) == 0) {
        unlink(marker);
        FILE *f = fopen(crashed, "w");
        if (f) fclose(f);
        refused = YES;
        DSDiagnosticsRecord(@"SpringBoard: picker819 HANG LATCH: an earlier SpringBoard never finished showing the new picker; latched off, classic picker");
        return;
    }
    if (!DS809Latched("picker819")) return;
    Class cls = NSClassFromString(@"DSPicker819ViewController");
    if (!cls) { refused = YES; return; }
    if (!markedThisBoot) {
        markedThisBoot = YES;
        FILE *f = fopen(marker, "w");
        if (f) fclose(f);
    }
    @try {
        DSAppPickerViewController *child = [cls new];
        child.delegate = self;
        child.darkMode = self.darkMode;
        child.unavailableBundleIdentifiers = self.unavailableBundleIdentifiers;
        [self addChildViewController:child];
        child.view.frame = self.view.bounds;
        child.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.view addSubview:child.view];
        [child didMoveToParentViewController:self];
        _child819 = child;
        _scrollView.hidden = YES;
        [_searchField endEditing:YES];
        [child loadApps819];
        DSDiagnosticsRecord(@"SpringBoard: picker819 new picker built on first show (off: picker819-off)");
        dispatch_async(dispatch_get_main_queue(), ^{
            [CATransaction begin];
            [CATransaction setCompletionBlock:^{
                unlink(marker);
                DSDiagnosticsRecord(@"SpringBoard: picker819 first show drawn, hang marker cleared");
            }];
            [CATransaction commit];
        });
    } @catch (NSException *exception) {
        refused = YES;
        DSDiagnosticsRecordFormat(@"SpringBoard: picker819 build failed (%@): classic picker", exception.reason ?: @"?");
    }
}

// The new picker reports through this one, so the stage sees the same picker
// object it created (slotForPicker: etc.).
- (void)appPicker:(DSAppPickerViewController *)picker didSelectEntry:(DSAppEntry *)entry fromView:(UIView *)view {
    [self.delegate appPicker:self didSelectEntry:entry fromView:view];
}
- (void)appPicker:(DSAppPickerViewController *)picker didHoldEntry:(DSAppEntry *)entry fromView:(UIView *)view {
    [self.delegate appPicker:self didHoldEntry:entry fromView:view];
}
- (void)appPickerNeedsKeyWindowForSearch:(DSAppPickerViewController *)picker {
    if ([self.delegate respondsToSelector:@selector(appPickerNeedsKeyWindowForSearch:)]) [self.delegate appPickerNeedsKeyWindowForSearch:self];
}
- (void)appPickerDidEndSearch:(DSAppPickerViewController *)picker {
    if ([self.delegate respondsToSelector:@selector(appPickerDidEndSearch:)]) [self.delegate appPickerDidEndSearch:self];
}
- (BOOL)appPickerShouldWaitBeforeSearchEditing:(DSAppPickerViewController *)picker {
    if (![self.delegate respondsToSelector:@selector(appPickerShouldWaitBeforeSearchEditing:)]) return NO;
    return [self.delegate appPickerShouldWaitBeforeSearchEditing:self];
}
- (NSArray<NSDictionary *> *)appPickerSlotChoices819:(DSAppPickerViewController *)picker {
    if (![self.delegate respondsToSelector:@selector(appPickerSlotChoices819:)]) return @[];
    return [self.delegate appPickerSlotChoices819:self];
}
- (void)appPicker:(DSAppPickerViewController *)picker didChooseEntry:(DSAppEntry *)entry slot819:(NSInteger)slot fromView:(UIView *)view {
    if ([self.delegate respondsToSelector:@selector(appPicker:didChooseEntry:slot819:fromView:)]) [self.delegate appPicker:self didChooseEntry:entry slot819:slot fromView:view];
    else [self.delegate appPicker:self didSelectEntry:entry fromView:view];
}

#pragma mark - UIScrollViewDelegate

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    [self cancelHold];
}

@end
