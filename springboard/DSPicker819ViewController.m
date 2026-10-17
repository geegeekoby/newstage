// 4.5.819 picker819: the 4.5.817 redesigned picker, boot-safe.
// It is never built at SpringBoard launch: the classic picker is built as
// always and, on the first real show of a picker after SpringBoard has stayed
// up, hosts this one as a child (DSAppPickerViewController -activate819).
// No background threads: icons load lazily on the main queue, one per turn.
//  - one LaunchServices load per stage open (-loadApps819); search filters in memory
//  - Suggested row: pins first, then frequency x recency (half-life 3 days)
//  - A-Z list with the section index; a selection tick while scrubbing it
//  - scored, accent/case-insensitive search (exact > prefix > word prefix >
//    initials > substring > bundle id)
//  - iOS 16 material background, SF Symbols, springs (Reduce Motion: none)
//  - long-press menu: open on top / bottom card, full screen, pin, hide
//  - VoiceOver custom actions, Dynamic Type
// Keys: the same DSSearchFieldView (SpringBoard's own keyboard path).
// Store: /var/mobile/.dynamicstage-picker819.plist, written on change only.
// Off: picker819-off / core819-off (crash latch picker819) -> classic picker.
#import "DSAppPickerViewController.h"
#import "DSSearchFieldView.h"
#import "DSPreferences.h"
#import "DSStageDebug.h"
#import "DSDiagnostics.h"
#import "DSConstants.h"
#import "DSPrivate.h"

static NSString *const kDS819StorePath = @"/var/mobile/.dynamicstage-picker819.plist";

#pragma mark - Store

@interface DSPicker819Store : NSObject
+ (instancetype)shared;
- (void)noteOpened:(NSString *)bundleIdentifier;
- (double)scoreFor:(NSString *)bundleIdentifier now:(CFAbsoluteTime)now;
- (NSArray<NSString *> *)scoredIdentifiers;
@property (nonatomic, readonly) NSArray<NSString *> *pins;
@property (nonatomic, readonly) NSSet<NSString *> *hidden;
- (void)setPinned:(BOOL)pinned for:(NSString *)bundleIdentifier;
- (void)setHidden:(BOOL)hidden for:(NSString *)bundleIdentifier;
@end

@implementation DSPicker819Store {
    NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *_uses;   // id -> @[count, lastOpen]
    NSMutableArray<NSString *> *_pins;
    NSMutableSet<NSString *> *_hidden;
    BOOL _savePending;
}

+ (instancetype)shared {
    static DSPicker819Store *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [DSPicker819Store new]; });
    return store;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kDS819StorePath];
        _uses = [NSMutableDictionary dictionary];
        NSDictionary *u = [d[@"uses"] isKindOfClass:NSDictionary.class] ? d[@"uses"] : nil;
        for (NSString *k in u) {
            NSArray *v = u[k];
            if ([k isKindOfClass:NSString.class] && [v isKindOfClass:NSArray.class] && v.count == 2) _uses[k] = v;
        }
        _pins = [NSMutableArray array];
        for (id k in ([d[@"pins"] isKindOfClass:NSArray.class] ? d[@"pins"] : @[])) if ([k isKindOfClass:NSString.class]) [_pins addObject:k];
        _hidden = [NSMutableSet set];
        for (id k in ([d[@"hidden"] isKindOfClass:NSArray.class] ? d[@"hidden"] : @[])) if ([k isKindOfClass:NSString.class]) [_hidden addObject:k];
        if (!d) {
            // First run: seed pins from the classic picker's settings.
            for (NSString *k in [DSPreferences sharedPreferences].pinnedApplications ?: @[]) if (k.length && ![_pins containsObject:k]) [_pins addObject:k];
        }
    }
    return self;
}

- (NSArray<NSString *> *)pins { return [_pins copy]; }
- (NSSet<NSString *> *)hidden { return [_hidden copy]; }

- (void)save {
    // Written on change only; several changes in one turn are one write.
    if (_savePending) return;
    _savePending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_savePending = NO;
        NSDictionary *d = @{ @"uses": [self->_uses copy], @"pins": [self->_pins copy], @"hidden": self->_hidden.allObjects ?: @[], @"v": @1 };
        @try { [d writeToFile:kDS819StorePath atomically:YES]; } @catch (NSException *exception) {}
    });
}

- (void)noteOpened:(NSString *)bundleIdentifier {
    if (!bundleIdentifier.length) return;
    // Trim to the 60 most recent apps so the file stays small.
    if (_uses.count > 80) {
        NSArray *keys = [_uses keysSortedByValueUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
            return [b[1] compare:a[1]];
        }];
        for (NSUInteger i = 60; i < keys.count; i++) [_uses removeObjectForKey:keys[i]];
    }
    NSInteger n = [_uses[bundleIdentifier][0] integerValue];
    _uses[bundleIdentifier] = @[ @(MIN(n + 1, 9999)), @(CFAbsoluteTimeGetCurrent()) ];
    [self save];
}

- (double)scoreFor:(NSString *)bundleIdentifier now:(CFAbsoluteTime)now {
    NSArray *v = _uses[bundleIdentifier];
    if (!v) return 0.0;
    double n = [v[0] doubleValue];
    double ageDays = MAX(0.0, (now - [v[1] doubleValue]) / 86400.0);
    return (1.0 + log2(1.0 + n)) * pow(0.5, ageDays / 3.0);
}

- (NSArray<NSString *> *)scoredIdentifiers {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    return [_uses.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        double sa = [self scoreFor:a now:now], sb = [self scoreFor:b now:now];
        return sa > sb ? NSOrderedAscending : (sa < sb ? NSOrderedDescending : NSOrderedSame);
    }];
}

- (void)setPinned:(BOOL)pinned for:(NSString *)bundleIdentifier {
    if (!bundleIdentifier.length || pinned == [_pins containsObject:bundleIdentifier]) return;
    if (pinned) [_pins insertObject:bundleIdentifier atIndex:0]; else [_pins removeObject:bundleIdentifier];
    [self save];
}

- (void)setHidden:(BOOL)hidden for:(NSString *)bundleIdentifier {
    if (!bundleIdentifier.length || hidden == [_hidden containsObject:bundleIdentifier]) return;
    if (hidden) [_hidden addObject:bundleIdentifier]; else [_hidden removeObject:bundleIdentifier];
    [self save];
}

@end

#pragma mark - Icons (cached; loaded off the main thread)

static NSCache<NSString *, UIImage *> *DS819IconCache(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 400; });
    return cache;
}

static void DS819LoadIcon(NSString *bundleIdentifier, void (^done)(UIImage *icon)) {
    // Main thread only, one icon per main-queue turn, with the same call the
    // classic picker makes (DSAppLibrary -iconForBundleIdentifier:, cached).
    if (!bundleIdentifier.length) return;
    UIImage *hit = [DS819IconCache() objectForKey:bundleIdentifier];
    if (hit) { done(hit); return; }
    static NSMutableSet *pending;
    if (!pending) pending = [NSMutableSet set];
    if ([pending containsObject:bundleIdentifier]) return;
    [pending addObject:bundleIdentifier];
    dispatch_async(dispatch_get_main_queue(), ^{
        [pending removeObject:bundleIdentifier];
        UIImage *icon = nil;
        @try { icon = [[DSAppLibrary sharedLibrary] iconForBundleIdentifier:bundleIdentifier]; } @catch (NSException *exception) {}
        if (!icon) return;
        [DS819IconCache() setObject:icon forKey:bundleIdentifier];
        done(icon);
    });
}

static BOOL DS819Motion(void) { return !UIAccessibilityIsReduceMotionEnabled(); }

static void DS819Spring(void (^animations)(void)) {
    if (!DS819Motion()) { animations(); return; }
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:animations completion:nil];
}

#pragma mark - Suggested tile

@interface DS819Tile : UIControl
@property (nonatomic, strong) DSAppEntry *entry;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UIImageView *badge;
@end

@implementation DS819Tile
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _iconView = [UIImageView new];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.layer.cornerCurve = kCACornerCurveContinuous;
        _iconView.layer.cornerRadius = 13.0;
        _iconView.clipsToBounds = YES;
        _iconView.backgroundColor = UIColor.tertiarySystemFillColor;
        [self addSubview:_iconView];
        _nameLabel = [UILabel new];
        _nameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        _nameLabel.adjustsFontForContentSizeCategory = YES;
        _nameLabel.textAlignment = NSTextAlignmentCenter;
        _nameLabel.textColor = UIColor.labelColor;
        _nameLabel.numberOfLines = 1;
        [self addSubview:_nameLabel];
        _badge = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"pin.fill"]];
        _badge.tintColor = UIColor.systemOrangeColor;
        _badge.hidden = YES;
        [self addSubview:_badge];
        self.isAccessibilityElement = YES;
        self.accessibilityTraits = UIAccessibilityTraitButton;
        [self addTarget:self action:@selector(down) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
        [self addTarget:self action:@selector(up) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
    }
    return self;
}
- (void)down { DS819Spring(^{ self.iconView.transform = CGAffineTransformMakeScale(0.9, 0.9); }); }
- (void)up { DS819Spring(^{ self.iconView.transform = CGAffineTransformIdentity; }); }
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = CGRectGetWidth(self.bounds);
    CGFloat side = MIN(56.0, w - 12.0);
    CGAffineTransform t = _iconView.transform;
    _iconView.transform = CGAffineTransformIdentity;
    _iconView.frame = CGRectMake((w - side) / 2.0, 4.0, side, side);
    _iconView.transform = t;
    CGFloat lh = ceil(_nameLabel.font.lineHeight);
    _nameLabel.frame = CGRectMake(0, 4.0 + side + 5.0, w, lh);
    _badge.frame = CGRectMake(CGRectGetMaxX(_iconView.frame) - 10.0, 0, 16.0, 16.0);
}
@end

#pragma mark - Picker

@interface DSAppPickerViewController (Classic819)
- (void)copyLogsTapped;
@end

@interface DSPicker819ViewController : DSAppPickerViewController <UITableViewDataSource, UITableViewDelegate, DSSearchFieldDelegate, UIContextMenuInteractionDelegate>
@end

@implementation DSPicker819ViewController {
    UIVisualEffectView *_material;
    UIView *_solid;
    DSSearchFieldView *_searchField;
    UIButton *_logsButton;
    UITableView *_table;
    UIView *_header;
    UILabel *_suggestedLabel;
    NSMutableArray<DS819Tile *> *_tiles;
    UILabel *_emptyLabel;

    NSArray<DSAppEntry *> *_all;          // visible, not hidden, A-Z
    NSArray<DSAppEntry *> *_hiddenApps;
    NSArray<DSAppEntry *> *_suggested;
    NSArray<NSString *> *_letters;
    NSArray<NSArray<DSAppEntry *> *> *_sections;
    NSArray<DSAppEntry *> *_results;
    NSDictionary<NSString *, NSArray<NSString *> *> *_folded;   // id -> @[name, initials, words joined by space]
    NSString *_query;
    NSInteger _lastIndex;
    NSInteger _tileCap;
    UISelectionFeedbackGenerator *_tick;
    UIImpactFeedbackGenerator *_impact;
}

- (void)viewDidLoad {
    // The classic viewDidLoad is not run: none of its views exist here.
    self.view.backgroundColor = UIColor.clearColor;
    _query = @"";
    _lastIndex = -1;
    _tiles = [NSMutableArray array];
    _tick = [UISelectionFeedbackGenerator new];
    _impact = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];

    _material = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
    _material.frame = self.view.bounds;
    _material.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _material.userInteractionEnabled = NO;
    [self.view addSubview:_material];
    _solid = [[UIView alloc] initWithFrame:self.view.bounds];
    _solid.autoresizingMask = _material.autoresizingMask;
    _solid.backgroundColor = UIColor.systemBackgroundColor;
    _solid.userInteractionEnabled = NO;
    [self.view addSubview:_solid];

    _table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _table.backgroundColor = UIColor.clearColor;
    _table.dataSource = self;
    _table.delegate = self;
    _table.rowHeight = UITableViewAutomaticDimension;
    _table.estimatedRowHeight = 52.0;
    _table.separatorInset = UIEdgeInsetsMake(0, 62.0, 0, 0);
    _table.sectionIndexColor = UIColor.systemBlueColor;
    _table.sectionIndexBackgroundColor = UIColor.clearColor;
    _table.keyboardDismissMode = UIScrollViewKeyboardDismissModeNone;   // keys stay on SpringBoard's path
    _table.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    if ([_table respondsToSelector:@selector(setSectionHeaderTopPadding:)]) [_table setValue:@0.0 forKey:@"sectionHeaderTopPadding"];
    [_table registerClass:UITableViewCell.class forCellReuseIdentifier:@"app"];
    [self.view addSubview:_table];

    _searchField = [[DSSearchFieldView alloc] initWithFrame:CGRectZero];
    _searchField.delegate = self;
    [self.view addSubview:_searchField];

    _logsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_logsButton setImage:[UIImage systemImageNamed:@"doc.on.clipboard"] forState:UIControlStateNormal];
    _logsButton.accessibilityLabel = @"Copy Logs";
    [_logsButton addTarget:self action:@selector(copyLogsTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_logsButton];

    _header = [UIView new];
    _suggestedLabel = [UILabel new];
    _suggestedLabel.text = @"Suggested";
    _suggestedLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    _suggestedLabel.adjustsFontForContentSizeCategory = YES;
    _suggestedLabel.textColor = UIColor.secondaryLabelColor;
    _suggestedLabel.accessibilityTraits = UIAccessibilityTraitHeader;
    [_header addSubview:_suggestedLabel];

    _emptyLabel = [UILabel new];
    _emptyLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _emptyLabel.adjustsFontForContentSizeCategory = YES;
    _emptyLabel.textColor = UIColor.secondaryLabelColor;
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.numberOfLines = 0;

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(a11yChanged) name:UIAccessibilityReduceTransparencyStatusDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(a11yChanged) name:UIContentSizeCategoryDidChangeNotification object:nil];
    [self applyAppearance819];
    [self reloadContent];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)a11yChanged {
    [self applyAppearance819];
    [self layoutHeader];
    [_table reloadData];
}

- (void)applyAppearance819 {
    if (!self.isViewLoaded) return;
    self.view.overrideUserInterfaceStyle = self.darkMode ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
    _searchField.darkMode = self.darkMode;
    BOOL solid = UIAccessibilityIsReduceTransparencyEnabled();
    _solid.hidden = !solid;
    _material.hidden = solid;
}

- (void)setDarkMode:(BOOL)darkMode {
    [super setDarkMode:darkMode];
    [self applyAppearance819];
}

- (void)viewDidLayoutSubviews {
    CGFloat w = CGRectGetWidth(self.view.bounds), h = CGRectGetHeight(self.view.bounds);
    CGFloat y = kDSStageRimGrabBand + 8.0;
    _searchField.frame = CGRectMake(kDSContentInset, y, w - kDSContentInset * 2.0 - 40.0, kDSSearchFieldHeight);
    _logsButton.frame = CGRectMake(w - kDSContentInset - 36.0, y, 36.0, kDSSearchFieldHeight);
    y += kDSSearchFieldHeight + 6.0;
    CGRect tf = CGRectMake(0, y, w, MAX(0.0, h - y));
    if (!CGRectEqualToRect(_table.frame, tf)) {
        _table.frame = tf;
        [self layoutHeader];
    }
}

#pragma mark Data

- (BOOL)entryUnavailable:(DSAppEntry *)e {
    return [self.unavailableBundleIdentifiers containsObject:e.bundleIdentifier];
}

static NSString *DS819Fold(NSString *s) {
    return [s stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch locale:nil] ?: @"";
}

- (void)reloadContent {
    // From memory: the app list is read by -loadApps819 (once per stage open).
    [self rebuildFromLibrary];
}

- (void)loadApps819 {
    [[DSAppLibrary sharedLibrary] reload];
    [self rebuildFromLibrary];
}

- (void)rebuildFromLibrary {
    DSAppLibrary *library = [DSAppLibrary sharedLibrary];
    DSPreferences *prefs = [DSPreferences sharedPreferences];
    NSSet *hidden = [DSPicker819Store shared].hidden;
    NSMutableArray *all = [NSMutableArray array], *hid = [NSMutableArray array];
    NSMutableDictionary *folded = [NSMutableDictionary dictionary];
    for (DSAppEntry *e in library.applications) {
        if (!e.bundleIdentifier.length || [prefs isApplicationDisabled:e.bundleIdentifier]) continue;
        NSString *name = DS819Fold(e.displayName ?: @"");
        NSMutableString *initials = [NSMutableString string];
        for (NSString *word in [name componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet]) {
            if (word.length) [initials appendString:[word substringToIndex:1]];
        }
        folded[e.bundleIdentifier] = @[ name, initials, DS819Fold(e.bundleIdentifier) ];
        [([hidden containsObject:e.bundleIdentifier] ? hid : all) addObject:e];
    }
    _all = all;
    _hiddenApps = hid;
    _folded = folded;
    [self rebuildBrowse];
    [self applyQuery:_query animated:NO];
}

- (void)rebuildBrowse {
    // Sections A-Z, then #.
    NSMutableDictionary<NSString *, NSMutableArray *> *by = [NSMutableDictionary dictionary];
    for (DSAppEntry *e in _all) {
        NSString *f = _folded[e.bundleIdentifier][0];
        unichar c = f.length ? [f.uppercaseString characterAtIndex:0] : '#';
        NSString *key = (c >= 'A' && c <= 'Z') ? [NSString stringWithCharacters:&c length:1] : @"#";
        if (!by[key]) by[key] = [NSMutableArray array];
        [by[key] addObject:e];
    }
    NSMutableArray *letters = [[by.allKeys sortedArrayUsingSelector:@selector(compare:)] mutableCopy];
    if ([letters containsObject:@"#"]) { [letters removeObject:@"#"]; [letters addObject:@"#"]; }
    NSMutableArray *sections = [NSMutableArray array];
    for (NSString *l in letters) [sections addObject:by[l]];
    _letters = letters;
    _sections = sections;

    // Suggested: pins, then frequency x recency, then the classic recents.
    DSPicker819Store *store = [DSPicker819Store shared];
    NSMutableArray *ids = [NSMutableArray arrayWithArray:store.pins];
    [ids addObjectsFromArray:store.scoredIdentifiers];
    [ids addObjectsFromArray:[DSPreferences sharedPreferences].recentApplications ?: @[]];
    NSMutableDictionary *byId = [NSMutableDictionary dictionary];
    for (DSAppEntry *e in _all) byId[e.bundleIdentifier] = e;
    NSMutableArray *sug = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSInteger cap = [self tileCount];
    _tileCap = cap;
    for (NSString *bid in ids) {
        if ((NSInteger)sug.count >= cap) break;
        DSAppEntry *e = byId[bid];
        if (!e || [seen containsObject:bid]) continue;
        [seen addObject:bid];
        [sug addObject:e];
    }
    _suggested = sug;
}

- (NSInteger)tileCount {
    CGFloat w = CGRectGetWidth(_table.bounds) ?: CGRectGetWidth(self.view.bounds);
    NSInteger n = (NSInteger)floor((w - kDSContentInset * 2.0) / 84.0);
    return MAX(4, MIN(6, n));
}

- (NSArray<DSAppEntry *> *)searchFor:(NSString *)query {
    NSString *q = DS819Fold([query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
    if (!q.length) return @[];
    NSString *spaced = [@" " stringByAppendingString:q];
    NSMutableArray *hits = [NSMutableArray array];
    NSMutableDictionary *score = [NSMutableDictionary dictionary];
    NSArray *pool = [_all arrayByAddingObjectsFromArray:_hiddenApps];   // hidden apps still found by search
    for (DSAppEntry *e in pool) {
        NSArray *f = _folded[e.bundleIdentifier];
        NSString *name = f[0], *initials = f[1], *bid = f[2];
        NSInteger s = 0;
        if ([name isEqualToString:q]) s = 100;
        else if ([name hasPrefix:q]) s = 80;
        else if ([[@" " stringByAppendingString:name] rangeOfString:spaced].location != NSNotFound) s = 60;
        else if (q.length >= 2 && [initials hasPrefix:q]) s = 50;
        else if ([name rangeOfString:q].location != NSNotFound) s = 30;
        else if (q.length >= 3 && [bid rangeOfString:q].location != NSNotFound) s = 10;
        if (!s) continue;
        if ([_hiddenApps containsObject:e]) s -= 5;
        score[e.bundleIdentifier] = @(s);
        [hits addObject:e];
    }
    [hits sortUsingComparator:^NSComparisonResult(DSAppEntry *a, DSAppEntry *b) {
        NSInteger sa = [score[a.bundleIdentifier] integerValue], sb = [score[b.bundleIdentifier] integerValue];
        if (sa != sb) return sa > sb ? NSOrderedAscending : NSOrderedDescending;
        return [a.displayName localizedStandardCompare:b.displayName];
    }];
    return hits;
}

- (BOOL)searching { return _query.length > 0; }

- (void)applyQuery:(NSString *)query animated:(BOOL)animated {
    BOOL was = [self searching];
    _query = query ?: @"";
    _results = [self searching] ? [self searchFor:_query] : @[];
    BOOL modeChange = was != [self searching];
    void (^apply)(void) = ^{
        [self layoutHeader];
        [self->_table reloadData];
        [self updateEmpty];
    };
    if (animated && modeChange && DS819Motion()) {
        [UIView transitionWithView:_table duration:0.25 options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowUserInteraction animations:apply completion:nil];
    } else {
        apply();
    }
}

- (void)updateEmpty {
    BOOL empty = [self searching] ? _results.count == 0 : (_all.count == 0 && _suggested.count == 0);
    _emptyLabel.text = [self searching] ? [NSString stringWithFormat:@"No apps for \u201C%@\u201D", _query] : @"No apps";
    _table.backgroundView = empty ? _emptyLabel : nil;
}

#pragma mark Header (Suggested row)

- (void)layoutHeader {
    if (!_table) return;
    if ([self searching] || _suggested.count == 0) {
        if (_table.tableHeaderView) _table.tableHeaderView = nil;
        return;
    }
    CGFloat w = CGRectGetWidth(_table.bounds);
    if (w < 1.0) return;
    if (_tileCap != [self tileCount]) [self rebuildBrowse];
    CGFloat lh = ceil(_suggestedLabel.font.lineHeight);
    _suggestedLabel.frame = CGRectMake(kDSContentInset, 6.0, w - kDSContentInset * 2.0, lh);
    NSInteger n = [self tileCount];
    while ((NSInteger)_tiles.count < n) {
        DS819Tile *t = [DS819Tile new];
        [t addTarget:self action:@selector(tileTapped:) forControlEvents:UIControlEventTouchUpInside];
        [t addInteraction:[[UIContextMenuInteraction alloc] initWithDelegate:self]];
        [_header addSubview:t];
        [_tiles addObject:t];
    }
    CGFloat tileW = floor((w - kDSContentInset * 2.0) / n);
    CGFloat tileH = 4.0 + 56.0 + 5.0 + ceil([UIFont preferredFontForTextStyle:UIFontTextStyleCaption1].lineHeight) + 6.0;
    NSSet *pins = [NSSet setWithArray:[DSPicker819Store shared].pins];
    for (NSInteger i = 0; i < (NSInteger)_tiles.count; i++) {
        DS819Tile *t = _tiles[i];
        DSAppEntry *e = i < (NSInteger)_suggested.count && i < n ? _suggested[i] : nil;
        t.hidden = e == nil;
        if (!e) continue;
        t.entry = e;
        t.frame = CGRectMake(kDSContentInset + i * tileW, 6.0 + lh + 6.0, tileW, tileH);
        t.nameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        t.nameLabel.text = e.displayName;
        t.badge.hidden = ![pins containsObject:e.bundleIdentifier];
        BOOL off = [self entryUnavailable:e];
        t.alpha = off ? 0.4 : 1.0;
        t.accessibilityLabel = e.displayName;
        t.accessibilityHint = off ? @"Already on the stage" : @"Opens on this card";
        t.accessibilityTraits = UIAccessibilityTraitButton | (off ? UIAccessibilityTraitNotEnabled : 0);
        t.accessibilityCustomActions = [self a11yActionsFor:e];
        t.iconView.image = [DS819IconCache() objectForKey:e.bundleIdentifier];
        if (!t.iconView.image) {
            __weak DS819Tile *wt = t;
            DS819LoadIcon(e.bundleIdentifier, ^(UIImage *icon) { if (wt.entry == e) wt.iconView.image = icon; });
        }
    }
    CGRect hf = CGRectMake(0, 0, w, 6.0 + lh + 6.0 + tileH + 6.0);
    if (!CGRectEqualToRect(_header.frame, hf) || _table.tableHeaderView != _header) {
        _header.frame = hf;
        _table.tableHeaderView = _header;
    }
}

- (void)tileTapped:(DS819Tile *)tile {
    [self open:tile.entry from:tile];
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return [self searching] ? 1 : (NSInteger)_sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if ([self searching]) return (NSInteger)_results.count;
    return section < (NSInteger)_sections.count ? (NSInteger)_sections[section].count : 0;
}

- (DSAppEntry *)entryAt:(NSIndexPath *)ip {
    if ([self searching]) return ip.row < (NSInteger)_results.count ? _results[ip.row] : nil;
    if (ip.section >= (NSInteger)_sections.count) return nil;
    NSArray *s = _sections[ip.section];
    return ip.row < (NSInteger)s.count ? s[ip.row] : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if ([self searching]) return _results.count ? @"Top Hits" : nil;
    return section < (NSInteger)_letters.count ? _letters[section] : nil;
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if (![view isKindOfClass:UITableViewHeaderFooterView.class]) return;
    UITableViewHeaderFooterView *hv = (UITableViewHeaderFooterView *)view;
    UIBackgroundConfiguration *bg = [UIBackgroundConfiguration clearConfiguration];
    bg.visualEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
    hv.backgroundConfiguration = bg;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"app" forIndexPath:ip];
    DSAppEntry *e = [self entryAt:ip];
    BOOL off = [self entryUnavailable:e];
    BOOL hid = [_hiddenApps containsObject:e];
    BOOL pinned = [[DSPicker819Store shared].pins containsObject:e.bundleIdentifier];
    UIListContentConfiguration *c = [UIListContentConfiguration cellConfiguration];
    c.text = e.displayName;
    c.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    c.textProperties.adjustsFontForContentSizeCategory = YES;
    c.textProperties.color = off ? UIColor.tertiaryLabelColor : UIColor.labelColor;
    if (off) c.secondaryText = @"On stage";
    else if (hid) c.secondaryText = @"Hidden";
    c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    UIImage *icon = [DS819IconCache() objectForKey:e.bundleIdentifier];
    c.image = icon ?: [UIImage systemImageNamed:@"app.dashed"];
    c.imageProperties.maximumSize = CGSizeMake(34.0, 34.0);
    c.imageProperties.reservedLayoutSize = CGSizeMake(34.0, 34.0);
    c.imageProperties.cornerRadius = 8.0;
    c.imageProperties.tintColor = UIColor.tertiaryLabelColor;
    cell.contentConfiguration = c;
    cell.backgroundConfiguration = [UIBackgroundConfiguration clearConfiguration];
    UIImageView *acc = nil;
    if (pinned || hid) {
        acc = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:pinned ? @"pin.fill" : @"eye.slash"]];
        acc.tintColor = pinned ? UIColor.systemOrangeColor : UIColor.tertiaryLabelColor;
    }
    cell.accessoryView = acc;
    cell.accessibilityHint = off ? @"Already on the stage" : @"Opens on this card";
    cell.accessibilityTraits = UIAccessibilityTraitButton | (off ? UIAccessibilityTraitNotEnabled : 0);
    cell.accessibilityCustomActions = [self a11yActionsFor:e];
    if (!icon && e.bundleIdentifier.length) {
        __weak UITableView *wt = tableView;
        DS819LoadIcon(e.bundleIdentifier, ^(UIImage *img) {
            UITableView *t = wt;
            if (!t) return;
            NSMutableArray *again = [NSMutableArray array];
            for (NSIndexPath *vis in t.indexPathsForVisibleRows) {
                if ([[self entryAt:vis].bundleIdentifier isEqualToString:e.bundleIdentifier]) [again addObject:vis];
            }
            if (!again.count) return;
            if ([t respondsToSelector:@selector(reconfigureRowsAtIndexPaths:)]) [t performSelector:@selector(reconfigureRowsAtIndexPaths:) withObject:again];
            else [t reloadRowsAtIndexPaths:again withRowAnimation:UITableViewRowAnimationNone];
        });
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    [self open:[self entryAt:ip] from:[tableView cellForRowAtIndexPath:ip]];
}

- (NSArray<NSString *> *)sectionIndexTitlesForTableView:(UITableView *)tableView {
    return [self searching] ? nil : _letters;
}

- (NSInteger)tableView:(UITableView *)tableView sectionForSectionIndexTitle:(NSString *)title atIndex:(NSInteger)index {
    if (index != _lastIndex) {
        _lastIndex = index;
        [_tick selectionChanged];   // a tick per letter while scrubbing
        [_tick prepare];
    }
    return index;
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    _lastIndex = -1;
    [_tick prepare];
}

#pragma mark Actions

- (void)open:(DSAppEntry *)e from:(UIView *)view {
    if (!e || [self entryUnavailable:e]) return;
    [[DSPicker819Store shared] noteOpened:e.bundleIdentifier];
    [self.delegate appPicker:self didSelectEntry:e fromView:view];
}

- (void)openFull:(DSAppEntry *)e from:(UIView *)view {
    if (!e || [self entryUnavailable:e]) return;
    [[DSPicker819Store shared] noteOpened:e.bundleIdentifier];
    [_impact impactOccurred];
    [self.delegate appPicker:self didHoldEntry:e fromView:view];
}

- (void)open:(DSAppEntry *)e slot:(NSInteger)slot here:(BOOL)here from:(UIView *)view {
    if (!e || [self entryUnavailable:e]) return;
    if (here || ![self.delegate respondsToSelector:@selector(appPicker:didChooseEntry:slot819:fromView:)]) { [self open:e from:view]; return; }
    [[DSPicker819Store shared] noteOpened:e.bundleIdentifier];
    [self.delegate appPicker:self didChooseEntry:e slot819:slot fromView:view];
}

- (void)togglePin:(DSAppEntry *)e {
    DSPicker819Store *s = [DSPicker819Store shared];
    [s setPinned:![s.pins containsObject:e.bundleIdentifier] for:e.bundleIdentifier];
    [self rebuildBrowse];
    [self applyQuery:_query animated:NO];
}

- (void)toggleHide:(DSAppEntry *)e {
    DSPicker819Store *s = [DSPicker819Store shared];
    BOOL hide = ![s.hidden containsObject:e.bundleIdentifier];
    [s setHidden:hide for:e.bundleIdentifier];
    if (hide) [s setPinned:NO for:e.bundleIdentifier];
    // Re-split the loaded list (no LaunchServices walk).
    NSMutableArray *all = [NSMutableArray arrayWithArray:_all], *hid = [NSMutableArray arrayWithArray:_hiddenApps];
    if (hide) { [all removeObject:e]; [hid addObject:e]; } else { [hid removeObject:e]; [all addObject:e]; }
    [all sortUsingComparator:^NSComparisonResult(DSAppEntry *a, DSAppEntry *b) { return [a.displayName localizedStandardCompare:b.displayName]; }];
    _all = all;
    _hiddenApps = hid;
    [self rebuildBrowse];
    [self applyQuery:_query animated:YES];
}

- (NSArray<NSDictionary *> *)slotChoices {
    if (![self.delegate respondsToSelector:@selector(appPickerSlotChoices819:)]) return @[];
    return [self.delegate appPickerSlotChoices819:self] ?: @[];
}

- (UIMenu *)menuFor:(DSAppEntry *)e view:(UIView *)view {
    __weak typeof(self) ws = self;
    NSMutableArray *open = [NSMutableArray array];
    BOOL off = [self entryUnavailable:e];
    for (NSDictionary *choice in [self slotChoices]) {
        NSInteger slot = [choice[@"slot"] integerValue];
        BOOL here = [choice[@"here"] boolValue];
        NSString *title = choice[@"title"];
        BOOL upper = [title rangeOfString:@"Top"].location != NSNotFound;
        UIAction *a = [UIAction actionWithTitle:title image:[UIImage systemImageNamed:upper ? @"rectangle.tophalf.inset.filled" : @"rectangle.bottomhalf.inset.filled"]
                                     identifier:nil handler:^(UIAction *x) { [ws open:e slot:slot here:here from:view]; }];
        if (off) a.attributes = UIMenuElementAttributesDisabled;
        [open addObject:a];
    }
    if (!open.count) {
        UIAction *a = [UIAction actionWithTitle:@"Open" image:[UIImage systemImageNamed:@"rectangle.inset.filled"] identifier:nil handler:^(UIAction *x) { [ws open:e from:view]; }];
        if (off) a.attributes = UIMenuElementAttributesDisabled;
        [open addObject:a];
    }
    UIAction *full = [UIAction actionWithTitle:@"Open Full Screen" image:[UIImage systemImageNamed:@"arrow.up.left.and.arrow.down.right"] identifier:nil handler:^(UIAction *x) { [ws openFull:e from:view]; }];
    if (off) full.attributes = UIMenuElementAttributesDisabled;
    [open addObject:full];
    BOOL pinned = [[DSPicker819Store shared].pins containsObject:e.bundleIdentifier];
    BOOL hidden = [[DSPicker819Store shared].hidden containsObject:e.bundleIdentifier];
    NSMutableArray *manage = [NSMutableArray array];
    if (!hidden) {
        [manage addObject:[UIAction actionWithTitle:pinned ? @"Unpin" : @"Pin to Suggested" image:[UIImage systemImageNamed:pinned ? @"pin.slash" : @"pin"] identifier:nil handler:^(UIAction *x) { [ws togglePin:e]; }]];
    }
    UIAction *hide = [UIAction actionWithTitle:hidden ? @"Show in Picker" : @"Hide from Picker" image:[UIImage systemImageNamed:hidden ? @"eye" : @"eye.slash"] identifier:nil handler:^(UIAction *x) { [ws toggleHide:e]; }];
    if (!hidden) hide.attributes = UIMenuElementAttributesDestructive;
    [manage addObject:hide];
    return [UIMenu menuWithTitle:e.displayName ?: @"" children:@[
        [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:open],
        [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:manage],
    ]];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip point:(CGPoint)point {
    DSAppEntry *e = [self entryAt:ip];
    if (!e) return nil;
    __weak typeof(self) ws = self;
    __weak UITableView *wt = tableView;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *suggested) {
        return [ws menuFor:e view:[wt cellForRowAtIndexPath:ip]];
    }];
}

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    DS819Tile *tile = [interaction.view isKindOfClass:DS819Tile.class] ? (DS819Tile *)interaction.view : nil;
    DSAppEntry *e = tile.entry;
    if (!e) return nil;
    __weak typeof(self) ws = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *suggested) {
        return [ws menuFor:e view:tile];
    }];
}

- (NSArray<UIAccessibilityCustomAction *> *)a11yActionsFor:(DSAppEntry *)e {
    if (!e) return @[];
    __weak typeof(self) ws = self;
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *choice in [self slotChoices]) {
        NSInteger slot = [choice[@"slot"] integerValue];
        BOOL here = [choice[@"here"] boolValue];
        [out addObject:[[UIAccessibilityCustomAction alloc] initWithName:choice[@"title"] actionHandler:^BOOL(UIAccessibilityCustomAction *a) { [ws open:e slot:slot here:here from:nil]; return YES; }]];
    }
    [out addObject:[[UIAccessibilityCustomAction alloc] initWithName:@"Open Full Screen" actionHandler:^BOOL(UIAccessibilityCustomAction *a) { [ws openFull:e from:nil]; return YES; }]];
    BOOL pinned = [[DSPicker819Store shared].pins containsObject:e.bundleIdentifier];
    BOOL hidden = [[DSPicker819Store shared].hidden containsObject:e.bundleIdentifier];
    if (!hidden) [out addObject:[[UIAccessibilityCustomAction alloc] initWithName:pinned ? @"Unpin" : @"Pin to Suggested" actionHandler:^BOOL(UIAccessibilityCustomAction *a) { [ws togglePin:e]; return YES; }]];
    [out addObject:[[UIAccessibilityCustomAction alloc] initWithName:hidden ? @"Show in Picker" : @"Hide from Picker" actionHandler:^BOOL(UIAccessibilityCustomAction *a) { [ws toggleHide:e]; return YES; }]];
    return out;
}

#pragma mark Public API (same as the classic picker)

- (void)setUnavailableBundleIdentifiers:(NSSet<NSString *> *)ids {
    [super setUnavailableBundleIdentifiers:ids];
    if (!self.isViewLoaded) return;
    [self layoutHeader];
    [_table reloadData];
}

- (void)resetScrollPosition {
    [_table setContentOffset:CGPointZero animated:NO];
}

- (void)dismissKeyboard { [_searchField endEditing:YES]; }
- (void)reassertSearchEditing { [_searchField reassertEditing]; }
- (void)restartSearchEditing { [_searchField restartEditing]; }
- (BOOL)searchFieldIsEditing { return [_searchField isEditingNow]; }
- (NSString *)searchEditingDebugSummary { return [_searchField editingDebugSummary] ?: @"fr=?"; }

#pragma mark Search field (same hand-offs as the classic picker)

- (void)searchField:(DSSearchFieldView *)field didChangeText:(NSString *)text {
    [self applyQuery:text animated:YES];
    [_table setContentOffset:CGPointZero animated:NO];
}

- (void)searchFieldDidCancel:(DSSearchFieldView *)field {
    [self applyQuery:@"" animated:YES];
}

- (void)searchFieldNeedsKeyWindow:(DSSearchFieldView *)field {
    if ([self.delegate respondsToSelector:@selector(appPickerNeedsKeyWindowForSearch:)]) [self.delegate appPickerNeedsKeyWindowForSearch:self];
}

- (void)searchFieldDidEndEditing:(DSSearchFieldView *)field {
    if ([self.delegate respondsToSelector:@selector(appPickerDidEndSearch:)]) [self.delegate appPickerDidEndSearch:self];
}

- (BOOL)searchFieldShouldWaitBeforeEditing:(DSSearchFieldView *)field {
    if (![self.delegate respondsToSelector:@selector(appPickerShouldWaitBeforeSearchEditing:)]) return NO;
    return [self.delegate appPickerShouldWaitBeforeSearchEditing:self];
}

@end

