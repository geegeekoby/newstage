#import "DSAppPickerViewController.h"
#import "DSAppCellContentView.h"
#import "DSSearchFieldView.h"
#import "DSCrashReports.h"
#import "DSDiagnostics.h"
#import "DSPreferences.h"
#import "DSConstants.h"
#import <AudioToolbox/AudioToolbox.h>

// How long the plate has to be held before the app opens fullscreen instead of
// on the stage.
static const NSTimeInterval kDSHoldDuration = 0.55;

@interface DSAppPickerViewController () <UIScrollViewDelegate, DSSearchFieldDelegate>
@end

@implementation DSAppPickerViewController {
    UIScrollView *_scrollView;
    DSSearchFieldView *_searchField;
    UILabel *_recentsHeader;
    UILabel *_libraryHeader;
    UILabel *_emptyLabel;
    NSMutableArray<DSAppCellContentView *> *_recentCells;
    NSMutableArray<DSAppCellContentView *> *_libraryCells;

    NSArray<DSAppEntry *> *_recents;
    NSArray<DSAppEntry *> *_library;
    NSString *_query;

    DSAppCellContentView *_heldCell;
    NSTimer *_holdTimer;
    UIImpactFeedbackGenerator *_feedback;

    UILabel *_crashNotice;
    NSString *_crashSummary;
    UILabel *_logNotice;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    _recentCells = [NSMutableArray array];
    _libraryCells = [NSMutableArray array];
    _query = @"";
    _feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];

    _scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scrollView.showsVerticalScrollIndicator = NO;
    _scrollView.alwaysBounceVertical = YES;
    _scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    _scrollView.delaysContentTouches = NO;
    _scrollView.delegate = self;
    if (@available(iOS 11.0, *)) _scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self.view addSubview:_scrollView];

    _searchField = [[DSSearchFieldView alloc] initWithFrame:CGRectZero];
    _searchField.delegate = self;
    [_scrollView addSubview:_searchField];

    _recentsHeader = [self sectionHeaderWithText:@"Recently Opened"];
    [_scrollView addSubview:_recentsHeader];

    _libraryHeader = [self sectionHeaderWithText:@"App Library"];
    [_scrollView addSubview:_libraryHeader];

    _emptyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _emptyLabel.font = [UIFont systemFontOfSize:15.0];
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.numberOfLines = 0;
    _emptyLabel.hidden = YES;
    [_scrollView addSubview:_emptyLabel];

    [self installCrashNotice];
    [self installLogNotice];
    [self reloadContent];
}

// The settings page runs inside Settings, so when it fails there is nothing left on
// screen to say why. This is the one place the tweak still has that the user is
// looking at, so the last crash is shown here, and tapping it puts the whole line on
// the clipboard - a report that can be pasted rather than described.
//
// Red only when the fault is in this tweak's own code. A crash another tweak caused is
// still worth knowing about, since the reader is sitting in front of the thing that
// crashed, but printing it in the colour of a fault here is how a bystander gets blamed.
- (void)installCrashNotice {
    BOOL ours = NO;
    _crashSummary = DSLastCrashSummary(&ours);
    if (_crashSummary.length == 0) return;

    _crashNotice = [[UILabel alloc] initWithFrame:CGRectZero];
    _crashNotice.text = [@"Tap to copy this crash report\n" stringByAppendingString:_crashSummary];
    _crashNotice.font = [UIFont systemFontOfSize:11.0];
    _crashNotice.textColor = ours ? [UIColor colorWithRed:0.85 green:0.25 blue:0.2 alpha:1.0]
                                  : [UIColor colorWithWhite:1.0 alpha:0.45];
    // The whole report goes on the clipboard; what is shown is as much of it as can be
    // spared from a card that is mostly meant to be a list of apps.
    _crashNotice.numberOfLines = 4;
    _crashNotice.lineBreakMode = NSLineBreakByTruncatingTail;
    _crashNotice.userInteractionEnabled = YES;
    [_crashNotice addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                              action:@selector(copyCrashNotice)]];
    [_scrollView addSubview:_crashNotice];
}

- (void)copyCrashNotice {
    if (_crashSummary.length == 0) return;
    UIPasteboard.generalPasteboard.string = _crashSummary;
    _crashNotice.text = @"Copied - paste it wherever you are reporting this";
    [_feedback impactOccurred];
}

// The stage writes down what it did - which gesture opened it, whether the keyboard
// could be taken out of the card, why an app did not appear - and until 1.5.0 that was
// read back on a page inside Settings. The page is a plist now, with no code of its own
// to read a file with, so the log is offered here instead: one line at the top of the
// card, and a tap puts the whole thing on the clipboard.
- (void)installLogNotice {
    _logNotice = [[UILabel alloc] initWithFrame:CGRectZero];
    _logNotice.text = @"Tap to copy the stage's log";
    _logNotice.font = [UIFont systemFontOfSize:11.0];
    _logNotice.textColor = [UIColor colorWithWhite:1.0 alpha:0.4];
    _logNotice.userInteractionEnabled = YES;
    [_logNotice addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                            action:@selector(copyLog)]];
    [_scrollView addSubview:_logNotice];
}

- (void)copyLog {
    NSString *log = DSDiagnosticsRead();
    UIPasteboard.generalPasteboard.string = log.length > 0 ? log : @"the stage has not written anything down yet";
    _logNotice.text = log.length > 0 ? @"Copied - paste it wherever you are reporting this"
                                     : @"Nothing has been written down yet";
    [_feedback impactOccurred];
}

- (UILabel *)sectionHeaderWithText:(NSString *)text {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.font = [UIFont systemFontOfSize:kDSHeaderFontSize weight:UIFontWeightRegular];
    label.text = text;
    return label;
}

#pragma mark - Content

- (void)reloadContent {
    DSAppLibrary *library = [DSAppLibrary sharedLibrary];
    [library reload];

    if (_query.length > 0) {
        _recents = @[];
        _library = [library applicationsMatchingSearch:_query];
    } else {
        // Pinned apps lead the grid, then the most recent stage apps fill it out.
        NSMutableArray<DSAppEntry *> *grid = [NSMutableArray array];
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        for (DSAppEntry *entry in [library pinnedApplications]) {
            if ([seen containsObject:entry.bundleIdentifier]) continue;
            [seen addObject:entry.bundleIdentifier];
            [grid addObject:entry];
        }
        NSInteger rows = MAX([DSPreferences sharedPreferences].pinnedRows, 1);
        NSInteger capacity = rows * 2;
        for (DSAppEntry *entry in [library recentApplicationsLimitedTo:capacity]) {
            if (grid.count >= (NSUInteger)capacity) break;
            if ([seen containsObject:entry.bundleIdentifier]) continue;
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

- (CGRect)plateFrameForBundleIdentifier:(NSString *)bundleIdentifier inView:(UIView *)view {
    if (bundleIdentifier.length == 0) return CGRectNull;
    for (NSArray<DSAppCellContentView *> *group in @[ _recentCells, _libraryCells ]) {
        for (DSAppCellContentView *cell in group) {
            if (cell.hidden) continue;
            if (![cell.entry.bundleIdentifier isEqualToString:bundleIdentifier]) continue;
            CGRect frame = [cell convertRect:cell.bounds toView:view];
            // Plates scrolled out of the stage are no use as a zoom target.
            if (!CGRectIntersectsRect(frame, view.bounds)) return CGRectNull;
            return frame;
        }
    }
    return CGRectNull;
}

- (void)rebuildCells {
    [self reconcileCells:_recentCells toCount:_recents.count];
    [self reconcileCells:_libraryCells toCount:_library.count];

    DSAppLibrary *library = [DSAppLibrary sharedLibrary];
    [_recentCells enumerateObjectsUsingBlock:^(DSAppCellContentView *cell, NSUInteger index, BOOL *stop) {
        DSAppEntry *entry = self->_recents[index];
        cell.entry = entry;
        cell.showsNowPlaying = [library isNowPlayingApplication:entry.bundleIdentifier];
    }];
    [_libraryCells enumerateObjectsUsingBlock:^(DSAppCellContentView *cell, NSUInteger index, BOOL *stop) {
        DSAppEntry *entry = self->_library[index];
        cell.entry = entry;
        cell.showsNowPlaying = [library isNowPlayingApplication:entry.bundleIdentifier];
    }];

    _recentsHeader.hidden = _recents.count == 0;
    _libraryHeader.hidden = _library.count == 0;
    _emptyLabel.hidden = !(_library.count == 0 && _recents.count == 0);
    _emptyLabel.text = _query.length > 0
        ? [NSString stringWithFormat:@"No apps match \u201c%@\u201d", _query]
        : @"No apps are available on the stage. Check Application Behaviors in Settings.";
}

- (void)reconcileCells:(NSMutableArray<DSAppCellContentView *> *)cells toCount:(NSUInteger)count {
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
        [_scrollView addSubview:cell];
        [cells addObject:cell];
    }
}

#pragma mark - Layout

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat width = CGRectGetWidth(self.view.bounds);
    CGFloat contentWidth = width - kDSContentInset * 2.0;
    CGFloat y = kDSSearchFieldTop;

    if (_crashNotice) {
        CGFloat height = [_crashNotice sizeThatFits:CGSizeMake(contentWidth, CGFLOAT_MAX)].height;
        _crashNotice.frame = CGRectMake(kDSContentInset, y, contentWidth, height);
        y += height + 8.0;
    }

    if (_logNotice) {
        CGFloat height = [_logNotice sizeThatFits:CGSizeMake(contentWidth, CGFLOAT_MAX)].height;
        _logNotice.frame = CGRectMake(kDSContentInset, y, contentWidth, height);
        y += height + 8.0;
    }

    _searchField.frame = CGRectMake(kDSContentInset, y, contentWidth, kDSSearchFieldHeight);
    y += kDSSearchFieldHeight;

    if (!_recentsHeader.hidden) {
        // The header text is centred in its own band rather than sitting on top
        // of the section, which is what puts equal air above and below it.
        _recentsHeader.frame = CGRectMake(kDSContentInset, y, contentWidth, kDSSectionHeaderHeight);
        y += kDSSectionHeaderHeight;

        CGFloat columnWidth = (contentWidth - kDSCellGap) / 2.0;
        [_recentCells enumerateObjectsUsingBlock:^(DSAppCellContentView *cell, NSUInteger index, BOOL *stop) {
            NSUInteger column = index % 2;
            NSUInteger row = index / 2;
            cell.frame = CGRectMake(kDSContentInset + column * (columnWidth + kDSCellGap),
                                    y + row * (kDSCellHeight + kDSCellGap),
                                    columnWidth,
                                    kDSCellHeight);
        }];
        NSUInteger rows = (_recents.count + 1) / 2;
        if (rows > 0) y += rows * kDSCellHeight + (rows - 1) * kDSCellGap;
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
    if (self.isViewLoaded) [self applyAppearance];
}

- (void)resetScrollPosition {
    [_scrollView setContentOffset:CGPointZero animated:NO];
}

- (void)dismissKeyboard {
    [_searchField endEditing:YES];
}

- (BOOL)isSearching {
    return _query.length > 0;
}

#pragma mark - Search field

- (void)searchField:(DSSearchFieldView *)field didChangeText:(NSString *)text {
    _query = text ?: @"";
    [self reloadContent];
    [_scrollView setContentOffset:CGPointZero animated:NO];
}

- (void)searchFieldDidCancel:(DSSearchFieldView *)field {
    _query = @"";
    [self reloadContent];
}

- (void)searchFieldNeedsKeyWindow:(DSSearchFieldView *)field {
    if ([self.delegate respondsToSelector:@selector(appPickerNeedsKeyWindowForSearch:)]) {
        [self.delegate appPickerNeedsKeyWindowForSearch:self];
    }
}

#pragma mark - Selection and hold

- (void)cellTouchDown:(DSAppCellContentView *)cell {
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
    if (!cell.entry) return;
    [self.delegate appPicker:self didSelectEntry:cell.entry fromView:cell];
}

- (void)commitHold {
    DSAppCellContentView *cell = _heldCell;
    [_holdTimer invalidate];
    _holdTimer = nil;
    if (!cell.entry) return;

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

#pragma mark - UIScrollViewDelegate

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    [self cancelHold];
}

@end
