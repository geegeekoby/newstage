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
#import <fcntl.h>
#import <unistd.h>

// ---- 4.5.823 style823 ----------------------------------------------------------
// The classic picker, restyled in place (no second view controller, no new
// hook / ctor / +load / %init). Nothing changes at SpringBoard launch: the
// picker is built with the stage window in its plain 822 look, and the new look
// is switched on from reloadContent (the stage's existing show path) only once
// SpringBoard's own "stayed up, boot guard cleared" has run (DSStayedUp823).
// Main thread only, no new plist, no app-list or icon reads beyond what 822
// already does (typing filters the cached list instead of re-reading it).
// Hang marker: /var/mobile/.dynamicstage-style823-showing is written just before
// the first styled layout and removed on the next main-queue turn (drawn). If a
// later SpringBoard start finds it, style823-crashed is written (latched off).
// Off: style823-off (exact 822 look, also live), core823-off; crash latch style823.
static NSString *const kDS823Marker = @"/var/mobile/.dynamicstage-style823-showing";
static BOOL DS823LatchedLocal = NO;

static BOOL DSStyle823Allowed(void) {
    if (!NSThread.isMainThread || !DSStayedUp823 || DS823LatchedLocal) return NO;
    if (!DS823On("style823")) return NO;
    static BOOL checkedMarker = NO;
    if (!checkedMarker) {
        checkedMarker = YES;
        if (access(kDS823Marker.fileSystemRepresentation, F_OK) == 0) {
            unlink(kDS823Marker.fileSystemRepresentation);
            int fd = open("/var/mobile/.dynamicstage-style823-crashed", O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (fd >= 0) close(fd);
            DS823LatchedLocal = YES;
            DSDiagnosticsRecord(@"SpringBoard: style823 hang marker found from an earlier start: style823 latched off (delete /var/mobile/.dynamicstage-style823-crashed to allow it again)");
            return NO;
        }
    }
    return YES;
}

static BOOL DS823ReduceTransparency(void) { return UIAccessibilityIsReduceTransparencyEnabled(); }
static BOOL DS823ReduceMotion(void) { return UIAccessibilityIsReduceMotionEnabled(); }

// How long the plate has to be held before the app opens fullscreen instead of
// on the stage.
static const NSTimeInterval kDSHoldDuration = 0.55;

@interface DSAppPickerViewController () <UIScrollViewDelegate, DSSearchFieldDelegate>
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

    DSAppCellContentView *_heldCell;
    NSTimer *_holdTimer;
    UIImpactFeedbackGenerator *_feedback;
    UIButton *_copyLogs;

    // 4.5.823 style823
    BOOL _s823;
    BOOL _s823Typing;
    UIView *_bg823;
    UIImageView *_sugIcon823;
    UIImageView *_libIcon823;
    NSMutableArray<UIView *> *_letterHeaders823;
    NSArray<NSString *> *_letterTitles823;
    NSArray<NSNumber *> *_letterStarts823;
}

#pragma mark - 4.5.823 style823

- (UIView *)s823PillWithText:(NSString *)text {
    UIView *pill;
    if (DS823ReduceTransparency()) {
        pill = [[UIView alloc] initWithFrame:CGRectZero];
        pill.backgroundColor = self.darkMode ? [UIColor colorWithWhite:0.18 alpha:1.0] : [UIColor colorWithWhite:0.92 alpha:1.0];
    } else {
        UIVisualEffectView *fx = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
        pill = fx;
    }
    pill.layer.cornerRadius = 9.0;
    pill.layer.cornerCurve = kCACornerCurveContinuous;
    pill.clipsToBounds = YES;
    pill.userInteractionEnabled = NO;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.tag = 823;
    label.text = text;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleFootnote] scaledFontForFont:[UIFont systemFontOfSize:13.0 weight:UIFontWeightBold] maximumPointSize:18.0];
    label.textColor = self.darkMode ? [UIColor colorWithWhite:1.0 alpha:0.75] : [UIColor colorWithWhite:0.0 alpha:0.6];
    UIView *host = [pill isKindOfClass:UIVisualEffectView.class] ? ((UIVisualEffectView *)pill).contentView : pill;
    [host addSubview:label];
    return pill;
}

- (void)s823ApplyBackground {
    [_bg823 removeFromSuperview];
    _bg823 = nil;
    if (!_s823) return;
    if (DS823ReduceTransparency()) {
        _bg823 = [[UIView alloc] initWithFrame:self.view.bounds];
        _bg823.backgroundColor = self.darkMode ? [UIColor colorWithWhite:0.11 alpha:1.0] : [UIColor colorWithWhite:0.96 alpha:1.0];
    } else {
        _bg823 = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:self.darkMode ? UIBlurEffectStyleSystemMaterialDark : UIBlurEffectStyleSystemMaterialLight]];
        _bg823.frame = self.view.bounds;
    }
    _bg823.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _bg823.userInteractionEnabled = NO;
    [self.view insertSubview:_bg823 atIndex:0];
}

- (UIImageView *)s823Symbol:(NSString *)name {
    UIImageView *iv = [[UIImageView alloc] initWithImage:[[UIImage systemImageNamed:name]
        imageWithConfiguration:[UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleFootnote scale:UIImageSymbolScaleMedium]]];
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.userInteractionEnabled = NO;
    return iv;
}

// Called from reloadContent (the existing show path); cheap when nothing to do.
- (void)s823Update {
    BOOL want = DSStyle823Allowed();
    if (want == _s823) return;
    if (want) {
        static BOOL markedOnce = NO;
        if (!markedOnce) {
            markedOnce = YES;
            DSFeature699MarkTrying("style823");
            int fd = open(kDS823Marker.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (fd >= 0) close(fd);
            // Drawn: the layout below commits with this run-loop turn; the
            // marker goes on the next main-queue turn (no timer).
            dispatch_async(dispatch_get_main_queue(), ^{
                unlink(kDS823Marker.fileSystemRepresentation);
                DSDiagnosticsRecord(@"SpringBoard: style823 first styled picker drawn (hang marker cleared)");
            });
        }
        DSFeature719MarkAction("style823");
        _s823 = YES;
        _letterHeaders823 = [NSMutableArray array];
        _sugIcon823 = [self s823Symbol:@"star.fill"];
        _libIcon823 = [self s823Symbol:@"square.grid.2x2.fill"];
        [_scrollView addSubview:_sugIcon823];
        [_scrollView addSubview:_libIcon823];
        UIFont *hf = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:15.0 weight:UIFontWeightBold] maximumPointSize:20.0];
        _recentsHeader.font = hf;
        _libraryHeader.font = hf;
        _recentsHeader.text = @"Suggested";
        _libraryHeader.text = @"All Apps";
        [_copyLogs setImage:[UIImage systemImageNamed:@"doc.on.doc"] forState:UIControlStateNormal];
        _copyLogs.titleLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleFootnote] scaledFontForFont:[UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold] maximumPointSize:17.0];
        _copyLogs.layer.cornerRadius = 15.0;
        _copyLogs.layer.cornerCurve = kCACornerCurveContinuous;
        _emptyLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCallout] scaledFontForFont:[UIFont systemFontOfSize:15.0] maximumPointSize:20.0];
        _searchField.style823 = YES;
        DSDiagnosticsRecord(@"SpringBoard: style823 picker restyled (blur, capsule search, Suggested tiles, A-Z sections)");
    } else {
        // style823-off (or latched) while running: back to the exact 822 look.
        _s823 = NO;
        [_sugIcon823 removeFromSuperview]; _sugIcon823 = nil;
        [_libIcon823 removeFromSuperview]; _libIcon823 = nil;
        for (UIView *v in _letterHeaders823) [v removeFromSuperview];
        _letterHeaders823 = nil; _letterTitles823 = nil; _letterStarts823 = nil;
        _recentsHeader.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
        _libraryHeader.font = _recentsHeader.font;
        _recentsHeader.text = @"Recent";
        _libraryHeader.text = @"App Library";
        [_copyLogs setImage:nil forState:UIControlStateNormal];
        _copyLogs.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
        _copyLogs.layer.cornerRadius = 0.0;
        _copyLogs.backgroundColor = nil;
        _emptyLabel.font = [UIFont systemFontOfSize:15.0];
        _searchField.style823 = NO;
        self.view.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
        for (DSAppCellContentView *cell in _recentCells) { cell.style823 = NO; cell.transform = CGAffineTransformIdentity; }
        for (DSAppCellContentView *cell in _libraryCells) { cell.style823 = NO; cell.transform = CGAffineTransformIdentity; }
    }
    [self s823ApplyBackground];
}

// A-Z groups over the (already sorted) list; letters only, diacritics folded.
- (void)s823BuildLetters {
    for (UIView *v in _letterHeaders823) [v removeFromSuperview];
    [_letterHeaders823 removeAllObjects];
    _letterTitles823 = nil;
    _letterStarts823 = nil;
    if (!_s823 || _query.length > 0 || _library.count == 0) return;
    NSMutableArray *titles = [NSMutableArray array], *starts = [NSMutableArray array];
    NSString *last = nil;
    for (NSUInteger i = 0; i < _library.count; i++) {
        NSString *name = _library[i].displayName ?: @"";
        NSString *letter = @"#";
        if (name.length > 0) {
            NSString *first = [[name substringWithRange:[name rangeOfComposedCharacterSequenceAtIndex:0]]
                stringByFoldingWithOptions:NSDiacriticInsensitiveSearch | NSCaseInsensitiveSearch locale:nil].uppercaseString;
            unichar ch = first.length ? [first characterAtIndex:0] : '#';
            if (ch >= 'A' && ch <= 'Z') letter = [NSString stringWithCharacters:&ch length:1];
        }
        if ([letter isEqualToString:last]) continue;
        if ([titles containsObject:letter]) { last = letter; continue; }
        last = letter;
        [titles addObject:letter];
        [starts addObject:@(i)];
        UIView *pill = [self s823PillWithText:letter];
        [_scrollView addSubview:pill];
        [_letterHeaders823 addObject:pill];
    }
    _letterTitles823 = titles;
    _letterStarts823 = starts;
}

- (void)s823Layout {
    CGFloat width = CGRectGetWidth(self.view.bounds);
    CGFloat inset = 18.0;
    CGFloat contentWidth = width - inset * 2.0;
    CGFloat y = kDSStageRimGrabBand + 10.0;
    CGFloat searchH = MAX(44.0, ceil(_searchField.style823 ? 44.0 : kDSSearchFieldHeight));
    _searchField.frame = CGRectMake(inset, y, contentWidth, searchH);
    y += searchH + 10.0;
    CGFloat logsW = MIN(contentWidth, 132.0);
    _copyLogs.frame = CGRectMake(width - inset - logsW, y, logsW, 30.0);
    _copyLogs.backgroundColor = self.darkMode ? [UIColor colorWithWhite:1.0 alpha:0.08] : [UIColor colorWithWhite:0.0 alpha:0.05];
    y += 30.0 + 12.0;
    CGFloat headerH = MAX(26.0, ceil(_recentsHeader.font.lineHeight) + 6.0);
    CGFloat sym = 18.0;

    _recentStrip.hidden = _recentsHeader.hidden;
    _sugIcon823.hidden = _recentsHeader.hidden;
    if (!_recentsHeader.hidden) {
        _sugIcon823.frame = CGRectMake(inset, y + (headerH - sym) / 2.0, sym, sym);
        _recentsHeader.frame = CGRectMake(inset + sym + 6.0, y, contentWidth - sym - 6.0, headerH);
        y += headerH + 6.0;
        CGFloat tileW = 86.0, gap = 10.0;
        CGFloat tileH = MAX(112.0, 84.0 + ceil(_recentCells.firstObject ? 2.0 * [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1] scaledValueForValue:15.0] : 30.0));
        _recentStrip.frame = CGRectMake(0.0, y, width, tileH);
        [_recentCells enumerateObjectsUsingBlock:^(DSAppCellContentView *cell, NSUInteger index, BOOL *stop) {
            cell.frame = CGRectMake(inset + index * (tileW + gap), 0.0, tileW, tileH);
        }];
        CGFloat stripWidth = inset * 2.0 + (_recentCells.count ? _recentCells.count * tileW + (_recentCells.count - 1) * gap : 0.0);
        _recentStrip.contentSize = CGSizeMake(MAX(stripWidth, width), tileH);
        y += tileH + 16.0;
    }

    _libIcon823.hidden = _libraryHeader.hidden;
    if (!_libraryHeader.hidden) {
        _libraryHeader.text = _query.length > 0 ? @"Results" : @"All Apps";
        _libIcon823.frame = CGRectMake(inset, y + (headerH - sym) / 2.0, sym, sym);
        _libraryHeader.frame = CGRectMake(inset + sym + 6.0, y, contentWidth - sym - 6.0, headerH);
        y += headerH + 4.0;
        CGFloat rowH = MAX(54.0, ceil([[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledValueForValue:54.0]));
        CGFloat gap = 6.0;
        NSUInteger next = 0;
        for (NSUInteger i = 0; i < _libraryCells.count; i++) {
            if (next < _letterStarts823.count && _letterStarts823[next].unsignedIntegerValue == i) {
                UIView *pill = _letterHeaders823[next];
                UILabel *label = [pill viewWithTag:823];
                CGFloat ph = MAX(22.0, ceil(label.font.lineHeight) + 6.0);
                pill.frame = CGRectMake(inset, y + 6.0, MAX(30.0, ph + 8.0), ph);
                label.frame = pill.bounds;
                y += ph + 12.0;
                next++;
            }
            _libraryCells[i].frame = CGRectMake(inset, y, contentWidth, rowH);
            y += rowH + gap;
        }
    }

    if (!_emptyLabel.hidden) {
        _emptyLabel.frame = CGRectMake(inset + 16.0, y + 30.0, contentWidth - 32.0, 80.0);
        y += 130.0;
    }
    _scrollView.contentSize = CGSizeMake(width, y + 16.0);
}

- (void)s823Press:(DSAppCellContentView *)cell down:(BOOL)down {
    if (!_s823 || !cell) return;
    CGAffineTransform t = down ? CGAffineTransformMakeScale(0.95, 0.95) : CGAffineTransformIdentity;
    if (DS823ReduceMotion()) { cell.transform = CGAffineTransformIdentity; return; }
    [UIView animateWithDuration:down ? 0.18 : 0.42 delay:0.0 usingSpringWithDamping:down ? 1.0 : 0.55 initialSpringVelocity:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ cell.transform = t; } completion:nil];
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
    @try { [self s823Update]; } @catch (NSException *exception) {}
    DSAppLibrary *library = [DSAppLibrary sharedLibrary];
    // 4.5.823: while typing, filter the list already loaded (no per-key reload).
    if (!(_s823 && _s823Typing)) [library reload];

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
        // 4.5.823: Suggested = pins first, then recents (same data, same capacity).
        NSArray<DSAppEntry *> *firstList = _s823 ? [library pinnedApplications] : [library recentApplicationsLimitedTo:capacity];
        NSArray<DSAppEntry *> *secondList = _s823 ? [library recentApplicationsLimitedTo:capacity] : [library pinnedApplications];
        for (DSAppEntry *entry in firstList) {
            if (grid.count >= (NSUInteger)capacity) break;
            if (entry.bundleIdentifier.length == 0 || [seen containsObject:entry.bundleIdentifier]) continue;
            [seen addObject:entry.bundleIdentifier];
            [grid addObject:entry];
        }
        for (DSAppEntry *entry in secondList) {
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

    for (DSAppCellContentView *cell in _recentCells) cell.style823 = _s823;
    for (DSAppCellContentView *cell in _libraryCells) cell.style823 = _s823;
    [self s823BuildLetters];

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
    if (_s823) { [self s823Layout]; return; }

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
    if (_s823) {
        // Follows the stage's dark / light.
        self.view.overrideUserInterfaceStyle = self.darkMode ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
        UIColor *tint = self.darkMode ? [UIColor colorWithWhite:1.0 alpha:0.9] : [UIColor colorWithWhite:0.0 alpha:0.8];
        _recentsHeader.textColor = tint;
        _libraryHeader.textColor = tint;
        _sugIcon823.tintColor = UIColor.systemYellowColor;
        _libIcon823.tintColor = headerColor;
        if ([_bg823 isKindOfClass:UIVisualEffectView.class]) {
            ((UIVisualEffectView *)_bg823).effect = [UIBlurEffect effectWithStyle:self.darkMode ? UIBlurEffectStyleSystemMaterialDark : UIBlurEffectStyleSystemMaterialLight];
        } else if (_bg823) {
            _bg823.backgroundColor = self.darkMode ? [UIColor colorWithWhite:0.11 alpha:1.0] : [UIColor colorWithWhite:0.96 alpha:1.0];
        }
        for (UIView *pill in _letterHeaders823) {
            UILabel *label = [pill viewWithTag:823];
            label.textColor = self.darkMode ? [UIColor colorWithWhite:1.0 alpha:0.75] : [UIColor colorWithWhite:0.0 alpha:0.6];
        }
    }
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

- (void)reassertSearchEditing {
    [_searchField reassertEditing];
}

- (void)restartSearchEditing {
    [_searchField restartEditing];
}

- (BOOL)searchFieldIsEditing {
    return [_searchField isEditingNow];
}

- (NSString *)searchEditingDebugSummary {
    return [_searchField editingDebugSummary] ?: @"fr=?";
}

#pragma mark - Search field

- (void)searchField:(DSSearchFieldView *)field didChangeText:(NSString *)text {
    _query = text ?: @"";
    _s823Typing = YES;
    @try { [self reloadContent]; } @finally { _s823Typing = NO; }
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
    [self s823Press:cell down:YES];
    _heldCell = cell;
    [_feedback prepare];
    [cell setHoldProgress:1.0 animated:YES duration:kDSHoldDuration];
    _holdTimer = [NSTimer scheduledTimerWithTimeInterval:kDSHoldDuration repeats:NO block:^(NSTimer *timer) {
        [self commitHold];
    }];
}

- (void)cellTouchCancelled:(DSAppCellContentView *)cell {
    [self s823Press:cell down:NO];
    [self cancelHold];
}

- (void)cellTapped:(DSAppCellContentView *)cell {
    BOOL committed = _holdTimer == nil && _heldCell == cell;
    [self s823Press:cell down:NO];
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

#pragma mark - UIScrollViewDelegate

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    [self s823Press:_heldCell down:NO];
    [self cancelHold];
}

@end
