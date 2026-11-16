/*
 * IDDesktop.m - the desktop: its picture, and the items of ~/Desktop on it as Finder shows them on macOS.
 *
 * Copyright (c) 2026 The pd-instadock authors
 *
 * SPDX-License-Identifier: MPL-2.0 OR BSD-2-Clause
 */

#import "IDDock.h"
#include <fcntl.h>
#include <math.h>
#include <unistd.h>

#ifndef O_EVTONLY
#define O_EVTONLY 0x8000 // Darwin's open for event notifications only, which keeps no volume busy
#endif

BOOL IDZipItems(NSArray *paths, NSString *archive);

// the ways the desktop can keep its items in order, as Finder's Sort By names them
static NSString * const SortNone = @"none";
static NSString * const SortName = @"name";
static NSString * const SortKind = @"kind";
static NSString * const SortModified = @"modified";
static NSString * const SortCreated = @"created";
static NSString * const SortSize = @"size";

#define ID_LINE 15        // a label line's height, in points
#define ID_MARGIN 14      // between the grid and the screen's right edge
#define ID_MENU_BAR 24    // when the screen does not say how much the menu bar takes

@interface IDDesktopItem : NSObject {
@public
    NSString *name;
    NSString *path;
    NSImage *icon;
    BOOL directory, app;
    NSDate *modified, *created;
    unsigned long long size;
    NSString *kind;
    NSInteger column, row;  // its cell, -1 while it has none
    BOOL selected;
    NSArray *lines;         // the label, wrapped and cut for the cell
    CGFloat linesWidth;     // what the lines were made for
}
@end

@implementation IDDesktopItem

- (void)dealloc
{
    [name release];
    [path release];
    [icon release];
    [modified release];
    [created release];
    [kind release];
    [lines release];
    [super dealloc];
}

// what Finder shows: the name, an app's without its extension
- (NSString *)title
{
    return app ? [name stringByDeletingPathExtension] : name;
}

@end

@implementation IDDesktopWindow

// the desktop takes the keyboard when it is clicked, as Finder's desktop does, for renaming and the arrows
- (BOOL)canBecomeKeyWindow
{
    return YES;
}

- (BOOL)canBecomeMainWindow
{
    return NO;
}

@end

#pragma mark - the desktop view

@implementation IDDesktopView

// the part of the picture under a screen rectangle, in the picture's own points
NSRect IDPictureRect(NSImage *picture, NSRect screen, NSRect region)
{
    NSSize size = [picture size];
    CGFloat scale = MAX(NSWidth(screen) / size.width, NSHeight(screen) / size.height);
    NSPoint origin = NSMakePoint((size.width - NSWidth(screen) / scale) / 2, (size.height - NSHeight(screen) / scale) / 2);

    return NSMakeRect(origin.x + (NSMinX(region) - NSMinX(screen)) / scale, origin.y + (NSMinY(region) - NSMinY(screen)) / scale,
                      NSWidth(region) / scale, NSHeight(region) / scale);
}

- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame]) != nil) {
        icons = [[NSMutableArray alloc] init];
        infoPanels = [[NSMutableArray alloc] init];
        folder = [[NSHomeDirectory() stringByAppendingPathComponent:@"Desktop"] copy];
        watchFD = -1;
        iconSize = 64;
        sortBy = [SortNone copy];
    }
    return self;
}

- (BOOL)acceptsFirstResponder
{
    return YES;
}

// a click that brings the desktop forward also selects, as on macOS
- (BOOL)acceptsFirstMouse:(NSEvent *)event
{
    return YES;
}

#pragma mark preferences

- (void)readPreferences
{
    id size = [controller pref:@"DesktopIconSize"], label = [controller pref:@"DesktopLabelPosition"];
    id sort = [controller pref:@"DesktopSortBy"];

    iconSize = [size respondsToSelector:@selector(doubleValue)] ? MIN(MAX(round([size doubleValue]), 16), 128) : 64;
    labelRight = [label isKindOfClass:[NSString class]] && [label isEqualToString:@"right"];
    [sortBy release];
    sortBy = [([sort isKindOfClass:[NSString class]] ? sort : SortNone) copy];
}

// where each item stood, by name, so the desktop comes back as it was left
- (void)savePositions
{
    NSMutableDictionary *cells = [NSMutableDictionary dictionary];

    for (IDDesktopItem *item in icons)
        if (item->column >= 0)
            [cells setObject:@[ @(item->column), @(item->row) ] forKey:item->name];
    [controller writeSetting:@"DesktopPositions" value:cells];
}

#pragma mark the folder

- (NSString *)kindOf:(NSString *)path directory:(BOOL)directory
{
    NSString *ext = [[path pathExtension] lowercaseString];

    if ([ext isEqualToString:@"app"])
        return IDLocalized(@"Application");
    if (directory)
        return IDLocalized(@"Folder");
    if ([ext length] == 0)
        return IDLocalized(@"Document");
    return [NSString stringWithFormat:IDLocalized(@"%@ document"), [ext uppercaseString]];
}

// the folder's items as they are now; the ones already shown keep their cell, their icon and their selection
- (void)reload
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *names = [fm contentsOfDirectoryAtPath:folder error:NULL];
    NSMutableDictionary *old = [NSMutableDictionary dictionary];
    NSMutableArray *now = [NSMutableArray array];

    for (IDDesktopItem *item in icons)
        [old setObject:item forKey:item->name];
    for (NSString *name in names) {
        NSString *path = [folder stringByAppendingPathComponent:name];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
        IDDesktopItem *item = [old objectForKey:name];
        BOOL directory = [[attrs fileType] isEqualToString:NSFileTypeDirectory];
        NSDate *modified = [attrs fileModificationDate];

        // hidden files, as Finder hides them, and a folder's custom icon file
        if ([name hasPrefix:@"."] || [name isEqualToString:@"Icon\r"] || attrs == nil)
            continue;
        if (item == nil) {
            item = [[[IDDesktopItem alloc] init] autorelease];
            item->name = [name copy];
            item->path = [path copy];
            item->column = item->row = -1;
        }
        // a changed file may have a new icon
        if (item->icon == nil || ![modified isEqual:item->modified]) {
            [item->icon release];
            item->icon = [[[NSWorkspace sharedWorkspace] iconForFile:path] retain];
        }
        [item->modified release];
        item->modified = [modified retain];
        [item->created release];
        item->created = [([attrs objectForKey:NSFileCreationDate] ?: modified) retain];
        item->directory = directory;
        item->app = [[[name pathExtension] lowercaseString] isEqualToString:@"app"];
        item->size = directory ? 0 : [attrs fileSize];
        [item->kind release];
        item->kind = [[self kindOf:path directory:directory] retain];
        [now addObject:item];
    }
    if (editing != nil && ![now containsObject:editing])
        [self endEditing:NO];
    [icons setArray:now];
    if (anchor != nil && ![icons containsObject:anchor])
        anchor = nil;
    // before the window has the screen's size the saved cells would not fit and be given away
    if (placed)
        [self arrange];
    [self setNeedsDisplay:YES];
}

- (void)folderChanged
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(reload) object:nil];
    [self performSelector:@selector(reload) withObject:nil afterDelay:0.05];
}

// kqueue tells when an item is added, removed or renamed; a folder that is itself moved or removed is
// made again and watched anew
- (void)startWatching
{
    [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
    if (watch != NULL) {
        dispatch_source_cancel(watch);
        dispatch_release(watch);
        watch = NULL;
    }
    watchFD = open([folder fileSystemRepresentation], O_RDONLY | O_EVTONLY);
    if (watchFD < 0) {
        NSLog(@"Dock: cannot watch %@", folder);
        [self reload];
        return;
    }
    int fd = watchFD;
    watch = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd,
                                   DISPATCH_VNODE_WRITE | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME |
                                   DISPATCH_VNODE_EXTEND | DISPATCH_VNODE_LINK | DISPATCH_VNODE_REVOKE,
                                   dispatch_get_main_queue());
    dispatch_source_set_event_handler(watch, ^{
        unsigned long what = dispatch_source_get_data(watch);

        if (what & (DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE))
            [self performSelector:@selector(startWatching) withObject:nil afterDelay:0.2];
        else
            [self folderChanged];
    });
    dispatch_source_set_cancel_handler(watch, ^{ close(fd); });
    dispatch_resume(watch);
    [self reload];
}

#pragma mark the grid

- (NSSize)cellSize
{
    return labelRight ? NSMakeSize(iconSize + 150, MAX(iconSize, 2 * ID_LINE) + 12)
                      : NSMakeSize(MAX(iconSize + 42, 76), iconSize + 12 + 2 * ID_LINE + 4);
}

// the grid fills the screen below the menu bar and above the dock, column by column from the top right
- (void)measure
{
    NSRect b = [self bounds];
    NSScreen *screen = [[self window] screen] ?: [NSScreen mainScreen];
    NSRect frame = [screen frame], visible = [screen visibleFrame];
    CGFloat top = NSMaxY(frame) - NSMaxY(visible), bottom = [controller dockReserve];

    if (top < 1 || top > 60)
        top = ID_MENU_BAR;
    cell = [self cellSize];
    area = NSMakeRect(ID_MARGIN, bottom + 4, NSWidth(b) - 2 * ID_MARGIN, NSHeight(b) - top - 6 - bottom - 4);
    columns = MAX(1, (NSInteger)floor(NSWidth(area) / cell.width));
    rows = MAX(1, (NSInteger)floor(NSHeight(area) / cell.height));
}

- (NSRect)rectOfCell:(NSInteger)column row:(NSInteger)row
{
    return NSMakeRect(NSMaxX(area) - (column + 1) * cell.width, NSMaxY(area) - (row + 1) * cell.height, cell.width, cell.height);
}

// Finder's order: case aside, and numbers by their value, so "file 9" comes before "file 10"
static NSComparisonResult natural(NSString *a, NSString *b)
{
    return [a compare:b options:NSCaseInsensitiveSearch | NSNumericSearch];
}

static NSComparisonResult byName(IDDesktopItem *a, IDDesktopItem *b)
{
    return natural([a title], [b title]);
}

- (NSArray *)sorted:(NSString *)key
{
    return [icons sortedArrayUsingComparator:^NSComparisonResult(IDDesktopItem *a, IDDesktopItem *b) {
        NSComparisonResult r = NSOrderedSame;

        if ([key isEqualToString:SortKind])
            r = natural(a->kind, b->kind);
        else if ([key isEqualToString:SortModified])
            r = [b->modified compare:a->modified]; // newest first, as Finder
        else if ([key isEqualToString:SortCreated])
            r = [b->created compare:a->created];
        else if ([key isEqualToString:SortSize])
            r = a->size == b->size ? NSOrderedSame : a->size > b->size ? NSOrderedAscending : NSOrderedDescending;
        return r != NSOrderedSame ? r : byName(a, b);
    }];
}

// the items in the order they stand, down each column, the columns from the right
- (NSArray *)inPlaceOrder
{
    return [icons sortedArrayUsingComparator:^NSComparisonResult(IDDesktopItem *a, IDDesktopItem *b) {
        NSInteger ia = a->column < 0 ? NSIntegerMax : a->column * 100000 + a->row;
        NSInteger ib = b->column < 0 ? NSIntegerMax : b->column * 100000 + b->row;

        return ia < ib ? NSOrderedAscending : ia > ib ? NSOrderedDescending : byName(a, b);
    }];
}

- (void)fill:(NSArray *)order
{
    NSInteger i = 0;

    for (IDDesktopItem *item in order) {
        item->column = i / rows;
        item->row = i % rows;
        i++;
    }
}

// with an order, every item takes the next cell; without one, each keeps its cell and a new item takes the
// first free one, as on a Mac
- (void)arrange
{
    [self measure];
    if (![sortBy isEqualToString:SortNone]) {
        [self fill:[self sorted:sortBy]];
    } else {
        NSDictionary *saved = [controller pref:@"DesktopPositions"];
        NSMutableSet *taken = [NSMutableSet set];
        NSInteger next = 0;

        if (![saved isKindOfClass:[NSDictionary class]])
            saved = nil;
        for (IDDesktopItem *item in icons) {
            NSArray *cellOf = [saved objectForKey:item->name];

            if (item->column < 0 && [cellOf isKindOfClass:[NSArray class]] && [cellOf count] == 2) {
                item->column = [[cellOf objectAtIndex:0] integerValue];
                item->row = [[cellOf objectAtIndex:1] integerValue];
            }
            // a cell off this screen, or one another item holds already
            if (item->column >= columns || item->row >= rows || item->column < 0 || item->row < 0 ||
                [taken containsObject:@(item->column * 100000 + item->row)])
                item->column = item->row = -1;
            else
                [taken addObject:@(item->column * 100000 + item->row)];
        }
        for (IDDesktopItem *item in [self sorted:SortName]) {
            if (item->column >= 0)
                continue;
            while ([taken containsObject:@((next / rows) * 100000 + next % rows)])
                next++;
            item->column = next / rows;
            item->row = next % rows;
            [taken addObject:@(item->column * 100000 + item->row)];
        }
    }
    for (IDDesktopItem *item in icons) {
        [item->lines release];
        item->lines = nil;
    }
    [self savePositions];
}

- (void)layoutIcons
{
    placed = YES;
    [self arrange];
    [self setNeedsDisplay:YES];
}

#pragma mark geometry of an item

- (NSFont *)labelFont
{
    return [NSFont systemFontOfSize:12];
}

- (CGFloat)labelWidth
{
    return labelRight ? cell.width - iconSize - 14 : cell.width - 6;
}

static CGFloat widthOf(NSString *s, NSDictionary *attrs)
{
    return ceil([s sizeWithAttributes:attrs].width);
}

// the longest end of a string that still fits with an ellipsis in the middle, as Finder cuts a long name
static NSString *cutMiddle(NSString *s, CGFloat width, NSDictionary *attrs)
{
    NSUInteger n = [s length];

    if (widthOf(s, attrs) <= width)
        return s;
    for (NSUInteger keep = n - 1; keep > 1; keep--) {
        NSUInteger head = (keep + 1) / 2, tail = keep - head;
        NSString *t = [NSString stringWithFormat:@"%@…%@", [s substringToIndex:head], [s substringFromIndex:n - tail]];

        if (widthOf(t, attrs) <= width)
            return t;
    }
    return @"…";
}

// up to two lines: the first breaks after a space or a dash when it can, the second is cut in the middle
- (NSArray *)linesFor:(IDDesktopItem *)item
{
    NSDictionary *attrs = @{ NSFontAttributeName : [self labelFont] };
    NSString *title = [item title];
    CGFloat width = [self labelWidth];
    NSUInteger n = [title length], fit = 0, breakAt = 0;

    if (item->lines != nil && item->linesWidth == width)
        return item->lines;
    [item->lines release];
    item->linesWidth = width;
    if (widthOf(title, attrs) <= width) {
        item->lines = [@[ title ] retain];
        return item->lines;
    }
    while (fit < n && widthOf([title substringToIndex:fit + 1], attrs) <= width)
        fit++;
    for (NSUInteger i = fit; i > fit / 3 && i > 0; i--) {
        unichar c = [title characterAtIndex:i - 1];

        if (c == ' ' || c == '-' || c == '_') {
            breakAt = i;
            break;
        }
    }
    if (breakAt == 0)
        breakAt = MAX(fit, (NSUInteger)1);
    NSString *first = [[title substringToIndex:breakAt] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *rest = [[title substringFromIndex:breakAt] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    item->lines = [([rest length] ? @[ first, cutMiddle(rest, width, attrs) ] : @[ first ]) retain];
    return item->lines;
}

- (NSRect)iconRectFor:(IDDesktopItem *)item
{
    NSRect c = [self rectOfCell:item->column row:item->row];

    if (labelRight)
        return NSMakeRect(NSMinX(c) + 4, floor(NSMidY(c) - iconSize / 2), iconSize, iconSize);
    return NSMakeRect(floor(NSMidX(c) - iconSize / 2), NSMaxY(c) - 4 - iconSize, iconSize, iconSize);
}

// one rectangle per label line, each as wide as its text
- (NSArray *)lineRectsFor:(IDDesktopItem *)item
{
    NSDictionary *attrs = @{ NSFontAttributeName : [self labelFont] };
    NSArray *lines = [self linesFor:item];
    NSRect icon = [self iconRectFor:item];
    NSMutableArray *rects = [NSMutableArray array];
    CGFloat y = labelRight ? floor(NSMidY(icon) + [lines count] * ID_LINE / 2.0) : NSMinY(icon) - 3;

    for (NSString *line in lines) {
        CGFloat w = widthOf(line, attrs) + 8;
        CGFloat x = labelRight ? NSMaxX(icon) + 6 : floor(NSMidX(icon) - w / 2);

        y -= ID_LINE;
        [rects addObject:[NSValue valueWithRect:NSMakeRect(x, y, w, ID_LINE)]];
    }
    return rects;
}

- (NSRect)labelRectFor:(IDDesktopItem *)item
{
    NSRect r = NSZeroRect;

    for (NSValue *v in [self lineRectsFor:item])
        r = NSIsEmptyRect(r) ? [v rectValue] : NSUnionRect(r, [v rectValue]);
    return r;
}

// what an item covers on screen, its selection's backgrounds included
- (NSRect)boundsOf:(IDDesktopItem *)item
{
    return NSInsetRect(NSUnionRect(NSInsetRect([self iconRectFor:item], -5, -5), [self labelRectFor:item]), -3, -3);
}

- (IDDesktopItem *)itemAt:(NSPoint)p
{
    for (IDDesktopItem *item in [icons reverseObjectEnumerator]) {
        if (item->column < 0)
            continue;
        if (NSPointInRect(p, NSInsetRect([self iconRectFor:item], 2, 2)))
            return item;
        for (NSValue *v in [self lineRectsFor:item])
            if (NSPointInRect(p, [v rectValue]))
                return item;
    }
    return nil;
}

- (void)redraw:(IDDesktopItem *)item
{
    if (item != nil && item->column >= 0)
        [self setNeedsDisplayInRect:[self boundsOf:item]];
}

#pragma mark drawing

// whether the cut items are still what the pasteboard holds, asked once per drawing
- (BOOL)cutIsCurrent
{
    return cutPaths != nil && [[NSPasteboard generalPasteboard] changeCount] == cutChange;
}

- (NSColor *)selectionColor
{
    // the accent blue while the desktop has the keyboard, grey when another app has it, as Finder shows it
    if ([[self window] isKeyWindow])
        return [NSColor colorWithCalibratedRed:0.04 green:0.39 blue:0.88 alpha:1];
    return [NSColor colorWithCalibratedWhite:0.55 alpha:0.85];
}

- (void)drawItem:(IDDesktopItem *)item cut:(BOOL)cut
{
    NSRect icon = [self iconRectFor:item];
    NSArray *lines = [self linesFor:item], *rects = [self lineRectsFor:item];
    NSShadow *shadow = [[[NSShadow alloc] init] autorelease];
    NSMutableDictionary *attrs = [NSMutableDictionary dictionaryWithObject:[self labelFont] forKey:NSFontAttributeName];
    CGFloat alpha = cut && [cutPaths containsObject:item->path] ? 0.5 : 1;

    if (item->selected) {
        [[NSColor colorWithCalibratedWhite:0 alpha:0.28] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(icon, -4, -4) xRadius:5 yRadius:5] fill];
    }
    [item->icon drawInRect:icon fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:alpha];
    if (item == editing)
        return;
    if (item->selected) {
        [[self selectionColor] setFill];
        for (NSValue *v in rects)
            [[NSBezierPath bezierPathWithRoundedRect:[v rectValue] xRadius:4 yRadius:4] fill];
        [attrs setObject:[NSColor whiteColor] forKey:NSForegroundColorAttributeName];
    } else {
        // white text over any picture, with the soft dark shadow macOS gives desktop labels
        [shadow setShadowColor:[NSColor colorWithCalibratedWhite:0 alpha:0.75]];
        [shadow setShadowOffset:NSMakeSize(0, -1)];
        [shadow setShadowBlurRadius:2];
        [attrs setObject:shadow forKey:NSShadowAttributeName];
        [attrs setObject:[NSColor colorWithCalibratedWhite:1 alpha:alpha] forKey:NSForegroundColorAttributeName];
    }
    for (NSUInteger i = 0; i < [lines count]; i++) {
        NSRect r = [[rects objectAtIndex:i] rectValue];

        [[lines objectAtIndex:i] drawAtPoint:NSMakePoint(NSMinX(r) + 4, NSMinY(r) + 0.5) withAttributes:attrs];
    }
}

- (void)drawRect:(NSRect)dirty
{
    NSRect bounds = [self bounds];
    BOOL cut = [self cutIsCurrent];

    [[NSColor colorWithCalibratedRed:0.85 green:0.47 blue:0.35 alpha:1] setFill];
    NSRectFill(dirty);
    if (picture != nil && [picture size].width > 0 && [picture size].height > 0)
        [picture drawInRect:dirty fromRect:IDPictureRect(picture, bounds, dirty) operation:NSCompositeCopy fraction:1];
    for (IDDesktopItem *item in icons)
        if (item->column >= 0 && NSIntersectsRect(dirty, [self boundsOf:item]))
            [self drawItem:item cut:cut];
    if (banding && !NSIsEmptyRect(band)) {
        [[NSColor colorWithCalibratedWhite:1 alpha:0.18] setFill];
        NSRectFillUsingOperation(band, NSCompositeSourceOver);
        [[NSColor colorWithCalibratedWhite:1 alpha:0.55] setStroke];
        [NSBezierPath strokeRect:NSInsetRect(band, 0.5, 0.5)];
    }
}

#pragma mark selection

- (NSArray *)selection
{
    NSMutableArray *list = [NSMutableArray array];

    for (IDDesktopItem *item in [self inPlaceOrder])
        if (item->selected)
            [list addObject:item];
    return list;
}

- (NSArray *)selectedPaths
{
    return [[self selection] valueForKey:@"path"];
}

- (void)select:(IDDesktopItem *)item on:(BOOL)on
{
    if (item->selected != on) {
        item->selected = on;
        [self redraw:item];
    }
}

- (void)selectOnly:(IDDesktopItem *)only
{
    for (IDDesktopItem *item in icons)
        [self select:item on:item == only];
    anchor = only;
}

- (void)selectAll:(id)sender
{
    for (IDDesktopItem *item in icons)
        [self select:item on:YES];
}

- (void)selectNamed:(NSString *)name
{
    for (IDDesktopItem *item in icons)
        if ([item->name isEqualToString:name])
            [self selectOnly:item];
}

// the rubber band: what it touches is selected, with Command or Shift it flips what was selected before
- (void)trackBandFrom:(NSEvent *)down
{
    NSPoint start = [self convertPoint:[down locationInWindow] fromView:nil];
    BOOL toggle = ([down modifierFlags] & (NSCommandKeyMask | NSShiftKeyMask)) != 0;
    NSMutableSet *before = [NSMutableSet set];

    for (IDDesktopItem *item in icons)
        if (item->selected)
            [before addObject:item];
    if (!toggle)
        [self selectOnly:nil];
    banding = YES;
    band = NSZeroRect;
    for (;;) {
        NSEvent *e = [[self window] nextEventMatchingMask:NSLeftMouseDraggedMask | NSLeftMouseUpMask];
        NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];
        NSRect old = band;

        band = NSMakeRect(MIN(p.x, start.x), MIN(p.y, start.y), fabs(p.x - start.x), fabs(p.y - start.y));
        [self setNeedsDisplayInRect:NSInsetRect(NSUnionRect(old, band), -2, -2)];
        for (IDDesktopItem *item in icons) {
            BOOL inside = item->column >= 0 &&
                          (NSIntersectsRect(band, [self iconRectFor:item]) || NSIntersectsRect(band, [self labelRectFor:item]));
            BOOL was = toggle && [before containsObject:item];

            [self select:item on:inside ? !was : was];
        }
        // the tracking loop takes the events itself, so it draws what changed itself too
        [self displayIfNeeded];
        if ([e type] == NSLeftMouseUp)
            break;
    }
    banding = NO;
    [self setNeedsDisplayInRect:NSInsetRect(band, -2, -2)];
    band = NSZeroRect;
}

- (void)mouseDown:(NSEvent *)event
{
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    IDDesktopItem *item = [self itemAt:p];
    NSUInteger mods = [event modifierFlags];

    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(renameSelected:) object:nil];
    [controller closePopup];
    if (editing != nil)
        [self endEditing:YES];
    if ([[self window] isKeyWindow] == NO)
        [[self window] makeKeyWindow];
    [[self window] makeFirstResponder:self];
    if (item == nil) {
        [self trackBandFrom:event];
        return;
    }
    if ([event clickCount] >= 2 && !(mods & (NSCommandKeyMask | NSShiftKeyMask))) {
        [self openItems:nil];
        return;
    }
    if (mods & NSCommandKeyMask) {
        [self select:item on:!item->selected];
        anchor = item;
    } else if (mods & NSShiftKeyMask) {
        [self select:item on:YES];
        anchor = item;
    } else if (!item->selected) {
        [self selectOnly:item];
    } else {
        anchor = item;
        // a second click on the name of the only selected item renames it, after a pause, as Finder does
        if ([[self selection] count] == 1 && NSPointInRect(p, [self labelRectFor:item]) &&
            [event timestamp] - lastClickTime > 0.5)
            [self performSelector:@selector(renameSelected:) withObject:nil afterDelay:0.6];
    }
    lastClickTime = [event timestamp];
}

#pragma mark the keyboard

- (IDDesktopItem *)neighbourOf:(IDDesktopItem *)from dx:(NSInteger)dx dy:(NSInteger)dy
{
    IDDesktopItem *best = nil;
    CGFloat bestDistance = INFINITY;
    NSRect a = [self iconRectFor:from];

    for (IDDesktopItem *item in icons) {
        NSRect b;
        CGFloat along, across;

        if (item == from || item->column < 0)
            continue;
        b = [self iconRectFor:item];
        along = dx != 0 ? (NSMidX(b) - NSMidX(a)) * dx : (NSMidY(b) - NSMidY(a)) * dy;
        across = dx != 0 ? fabs(NSMidY(b) - NSMidY(a)) : fabs(NSMidX(b) - NSMidX(a));
        if (along <= 1)
            continue;
        if (along + 3 * across < bestDistance) {
            bestDistance = along + 3 * across;
            best = item;
        }
    }
    return best;
}

- (void)moveSelectionBy:(NSInteger)dx dy:(NSInteger)dy extend:(BOOL)extend
{
    IDDesktopItem *from = anchor ?: [[self selection] lastObject], *to;

    if (from == nil) {
        // nothing selected: the arrows start at the first item, as in Finder
        to = [[self inPlaceOrder] firstObject];
    } else {
        to = [self neighbourOf:from dx:dx dy:dy];
    }
    if (to == nil)
        return;
    if (extend)
        [self select:to on:YES];
    else
        [self selectOnly:to];
    anchor = to;
}

// typing selects the first item whose name starts with what was typed in the last second
- (void)typeSelect:(NSString *)chars at:(NSTimeInterval)time
{
    NSString *prefix = time - typedAt < 1 ? [typed stringByAppendingString:chars] : chars;

    [typed release];
    typed = [prefix copy];
    typedAt = time;
    for (IDDesktopItem *item in [self sorted:SortName]) {
        if ([[item title] compare:prefix options:NSCaseInsensitiveSearch
                            range:NSMakeRange(0, MIN([prefix length], [[item title] length]))] != NSOrderedSame)
            continue;
        [self selectOnly:item];
        return;
    }
}

- (BOOL)handleKey:(NSEvent *)event
{
    NSString *chars = [event charactersIgnoringModifiers];
    unichar c = [chars length] ? [chars characterAtIndex:0] : 0;
    NSUInteger mods = [event modifierFlags] & (NSCommandKeyMask | NSShiftKeyMask | NSAlternateKeyMask | NSControlKeyMask);
    BOOL cmd = (mods & NSCommandKeyMask) != 0, shift = (mods & NSShiftKeyMask) != 0;
    BOOL some = [[self selection] count] > 0;

    if (cmd) {
        switch (c) {
        case 'a': [self selectAll:nil]; return YES;
        case 'c': if (some) [self copyItems:nil]; return YES;
        case 'x': if (some) [self cutItems:nil]; return YES;
        case 'v': [self pasteItems:nil]; return YES;
        case 'd': if (some) [self duplicateItems:nil]; return YES;
        case 'i': if (some) [self getInfo:nil]; return YES;
        case 'o': if (some) [self openItems:nil]; return YES;
        case 'n': case 'N': if (shift) [self newFolder:nil]; return shift;
        case NSDeleteCharacter: case NSBackspaceCharacter: if (some) [self moveToTrash:nil]; return YES;
        case NSDownArrowFunctionKey: if (some) [self openItems:nil]; return YES;
        }
        return NO;
    }
    switch (c) {
    case NSLeftArrowFunctionKey: [self moveSelectionBy:-1 dy:0 extend:shift]; return YES;
    case NSRightArrowFunctionKey: [self moveSelectionBy:1 dy:0 extend:shift]; return YES;
    case NSUpArrowFunctionKey: [self moveSelectionBy:0 dy:1 extend:shift]; return YES;
    case NSDownArrowFunctionKey: [self moveSelectionBy:0 dy:-1 extend:shift]; return YES;
    case NSCarriageReturnCharacter: case NSEnterCharacter: case '\n':
        if ([[self selection] count] == 1)
            [self renameSelected:nil];
        return YES;
    case 27: [self selectOnly:nil]; return YES;
    }
    if (mods == 0 && c >= ' ' && c < 0xF700) {
        [self typeSelect:[event characters] at:[event timestamp]];
        return YES;
    }
    return NO;
}

- (void)keyDown:(NSEvent *)event
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(renameSelected:) object:nil];
    if (![self handleKey:event])
        [super keyDown:event];
}

// the Dock has no main menu, so the desktop takes its own Command keys
- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    if ([[self window] firstResponder] == self && ([event modifierFlags] & NSCommandKeyMask) && [self handleKey:event])
        return YES;
    return [super performKeyEquivalent:event];
}

- (void)windowKeyChanged:(NSNotification *)note
{
    for (IDDesktopItem *item in icons)
        if (item->selected)
            [self redraw:item];
}

- (void)viewDidMoveToWindow
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if ([self window] == nil)
        return;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowKeyChanged:)
                                                 name:NSWindowDidBecomeKeyNotification object:[self window]];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowKeyChanged:)
                                                 name:NSWindowDidResignKeyNotification object:[self window]];
}

#pragma mark renaming in place

- (void)renameSelected:(id)sender
{
    NSArray *selection = [self selection];
    IDDesktopItem *item = [selection count] == 1 ? [selection objectAtIndex:0] : nil;
    NSRect label, field;
    NSString *title;

    if (item == nil || item->column < 0 || editing != nil)
        return;
    editing = item;
    title = [item title];
    label = [self labelRectFor:item];
    field = labelRight ? NSMakeRect(NSMinX(label), floor(NSMidY(label) - 10), [self labelWidth] + 8, 20)
                       : NSMakeRect(floor(NSMidX([self iconRectFor:item]) - (cell.width + 30) / 2), NSMaxY(label) - 20, cell.width + 30, 20);
    editor = [[NSTextField alloc] initWithFrame:field];
    [editor setStringValue:title];
    [editor setFont:[self labelFont]];
    [editor setAlignment:labelRight ? NSLeftTextAlignment : NSCenterTextAlignment];
    [editor setBezeled:NO];
    [editor setDrawsBackground:YES];
    [editor setBackgroundColor:[NSColor textBackgroundColor]];
    [editor setTextColor:[NSColor textColor]];
    [editor setFocusRingType:NSFocusRingTypeNone];
    [editor setDelegate:self];
    [self addSubview:editor];
    [self redraw:item];
    [[self window] makeKeyWindow];
    [[self window] makeFirstResponder:editor];
    // the name is selected without its extension, as Finder does
    NSText *text = [[self window] fieldEditor:YES forObject:editor];
    NSString *ext = [title pathExtension];
    NSUInteger length = [ext length] && !item->directory ? [title length] - [ext length] - 1 : [title length];
    [text setSelectedRange:NSMakeRange(0, length)];
}

// a new name a file can take: not empty, without a slash, and not one another item has
- (NSString *)checkedName:(NSString *)typedName for:(IDDesktopItem *)item
{
    NSString *name = [typedName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if ([name length] == 0 || [name rangeOfString:@"/"].location != NSNotFound || [name hasPrefix:@"."])
        return nil;
    if (item->app && ![[[name pathExtension] lowercaseString] isEqualToString:@"app"])
        name = [name stringByAppendingPathExtension:@"app"];
    return name;
}

- (void)endEditing:(BOOL)commit
{
    IDDesktopItem *item = editing;
    NSString *typedName = [[[editor stringValue] copy] autorelease];

    if (item == nil)
        return;
    editing = nil;
    [editor setDelegate:nil];
    [editor removeFromSuperview];
    [editor autorelease];
    editor = nil;
    [[self window] makeFirstResponder:self];
    [self redraw:item];
    if (!commit || [typedName isEqualToString:[item title]])
        return;

    NSString *name = [self checkedName:typedName for:item];
    NSString *to = name ? [folder stringByAppendingPathComponent:name] : nil;
    NSError *error = nil;

    if (to == nil || [[NSFileManager defaultManager] fileExistsAtPath:to]) {
        NSAlert *alert = [[[NSAlert alloc] init] autorelease];

        [alert setMessageText:to == nil ? IDLocalized(@"This name can't be used.")
                                        : [NSString stringWithFormat:IDLocalized(@"The name “%@” is already taken."), name]];
        [alert setInformativeText:IDLocalized(@"Please choose a different name.")];
        [alert addButtonWithTitle:IDLocalized(@"OK")];
        [NSApp activateIgnoringOtherApps:YES];
        [alert runModal];
        return;
    }
    if (![[NSFileManager defaultManager] moveItemAtPath:item->path toPath:to error:&error]) {
        NSLog(@"Dock: cannot rename %@: %@", item->path, error);
        return;
    }
    // the item keeps its cell and selection under its new name
    NSString *oldName = item->name;
    item->name = [name copy];
    [oldName release];
    [item->path release];
    item->path = [to copy];
    [item->lines release];
    item->lines = nil;
    [self savePositions];
    [self reload];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command
{
    if (command == @selector(cancelOperation:)) {
        [self endEditing:NO];
        return YES;
    }
    if (command == @selector(insertNewline:) || command == @selector(insertTab:) || command == @selector(insertBacktab:)) {
        [self endEditing:YES];
        return YES;
    }
    return NO;
}

- (void)controlTextDidEndEditing:(NSNotification *)note
{
    if (editing != nil)
        [self endEditing:YES];
}

#pragma mark file operations

// a free name in the folder: "name", then "name 2", "name 3", the extension kept, as Finder numbers copies
- (NSString *)freeName:(NSString *)name in:(NSString *)dir
{
    NSString *ext = [name pathExtension], *base = [name stringByDeletingPathExtension];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *candidate = name;

    for (NSUInteger i = 2; [fm fileExistsAtPath:[dir stringByAppendingPathComponent:candidate]]; i++) {
        candidate = [NSString stringWithFormat:@"%@ %lu", base, (unsigned long)i];
        if ([ext length])
            candidate = [candidate stringByAppendingPathExtension:ext];
    }
    return candidate;
}

- (void)openItems:(id)sender
{
    for (NSString *path in [self selectedPaths])
        [controller openPath:path];
}

- (void)openWith:(NSMenuItem *)sender
{
    NSString *app = [sender representedObject];

    for (NSString *path in [self selectedPaths])
        [[NSWorkspace sharedWorkspace] openFile:path withApplication:app];
}

- (void)openWithOther:(id)sender
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];

    [panel setCanChooseFiles:YES];
    [panel setCanChooseDirectories:NO];
    [panel setAllowsMultipleSelection:NO];
    [panel setDirectory:@"/Applications"];
    [panel setAllowedFileTypes:@[ @"app" ]];
    [panel setTitle:IDLocalized(@"Choose an Application")];
    [NSApp activateIgnoringOtherApps:YES];
    if ([panel runModal] != NSOKButton)
        return;
    for (NSString *path in [self selectedPaths])
        [[NSWorkspace sharedWorkspace] openFile:path withApplication:[[panel URL] path]];
}

- (void)moveToTrash:(id)sender
{
    NSMutableArray *urls = [NSMutableArray array];

    for (NSString *path in [self selectedPaths])
        [urls addObject:[NSURL fileURLWithPath:path]];
    if ([urls count] == 0)
        return;
    [[NSWorkspace sharedWorkspace] recycleURLs:urls completionHandler:^(NSDictionary *moved, NSError *error) {
        if (error != nil)
            NSLog(@"Dock: moving to the Trash failed: %@", error);
    }];
}

- (void)copyItems:(id)sender
{
    NSArray *paths = [self selectedPaths];
    NSPasteboard *pb = [NSPasteboard generalPasteboard];

    if ([paths count] == 0)
        return;
    [pb declareTypes:@[ NSFilenamesPboardType, NSStringPboardType ] owner:nil];
    [pb setPropertyList:paths forType:NSFilenamesPboardType];
    [pb setString:[[paths valueForKey:@"lastPathComponent"] componentsJoinedByString:@"\r"] forType:NSStringPboardType];
    [cutPaths release];
    cutPaths = nil;
}

// cut files stay where they are, dimmed, until they are pasted somewhere, then they move
- (void)cutItems:(id)sender
{
    NSArray *paths = [self selectedPaths];

    if ([paths count] == 0)
        return;
    [self copyItems:sender];
    cutPaths = [paths copy];
    cutChange = [[NSPasteboard generalPasteboard] changeCount];
    for (IDDesktopItem *item in icons)
        [self redraw:item];
}

- (NSArray *)pastedPaths
{
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    id list = [[pb types] containsObject:NSFilenamesPboardType] ? [pb propertyListForType:NSFilenamesPboardType] : nil;

    return [list isKindOfClass:[NSArray class]] ? list : nil;
}

- (void)pasteItems:(id)sender
{
    NSArray *paths = [self pastedPaths];
    BOOL move = cutPaths != nil && [[NSPasteboard generalPasteboard] changeCount] == cutChange;
    NSString *dir = [[folder copy] autorelease];
    NSMutableArray *targets = [NSMutableArray array];

    if ([paths count] == 0)
        return;
    for (NSString *from in paths) {
        NSString *name = [from lastPathComponent];

        // cut and pasted where it already is: nothing to do
        if (move && [[from stringByDeletingLastPathComponent] isEqualToString:dir])
            continue;
        name = [self freeName:name in:dir];
        [targets addObject:@[ from, [dir stringByAppendingPathComponent:name] ]];
    }
    if (move) {
        [cutPaths release];
        cutPaths = nil;
        [[NSPasteboard generalPasteboard] clearContents];
    }
    // a large copy must not hold the desktop, the folder's watch shows each item as it lands
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        NSFileManager *fm = [[[NSFileManager alloc] init] autorelease];

        for (NSArray *pair in targets) {
            NSError *error = nil;
            BOOL ok = move ? [fm moveItemAtPath:pair[0] toPath:pair[1] error:&error]
                           : [fm copyItemAtPath:pair[0] toPath:pair[1] error:&error];

            if (!ok)
                NSLog(@"Dock: cannot %@ %@ to %@: %@", move ? @"move" : @"copy", pair[0], pair[1], error);
        }
        [pool release];
    });
    for (IDDesktopItem *item in icons)
        [self redraw:item];
}

// "name copy", "name copy 2", as Finder names a duplicate
- (NSString *)copyName:(NSString *)name
{
    NSString *ext = [name pathExtension], *base = [name stringByDeletingPathExtension];
    NSFileManager *fm = [NSFileManager defaultManager];

    for (NSUInteger i = 1;; i++) {
        NSString *candidate = i == 1 ? [NSString stringWithFormat:IDLocalized(@"%@ copy"), base]
                                     : [NSString stringWithFormat:IDLocalized(@"%@ copy %lu"), base, (unsigned long)i];

        if ([ext length])
            candidate = [candidate stringByAppendingPathExtension:ext];
        if (![fm fileExistsAtPath:[folder stringByAppendingPathComponent:candidate]])
            return candidate;
    }
}

- (void)duplicateItems:(id)sender
{
    NSString *last = nil;

    for (IDDesktopItem *item in [self selection]) {
        NSString *name = [self copyName:item->name];
        NSError *error = nil;

        if ([[NSFileManager defaultManager] copyItemAtPath:item->path toPath:[folder stringByAppendingPathComponent:name] error:&error])
            last = name;
        else
            NSLog(@"Dock: cannot duplicate %@: %@", item->path, error);
    }
    [self reload];
    if (last != nil)
        [self selectNamed:last];
}

- (void)newFolder:(id)sender
{
    NSString *name = [self freeName:IDLocalized(@"untitled folder") in:folder];
    NSError *error = nil;

    if (![[NSFileManager defaultManager] createDirectoryAtPath:[folder stringByAppendingPathComponent:name]
                                   withIntermediateDirectories:NO attributes:nil error:&error]) {
        NSLog(@"Dock: cannot make a folder on the desktop: %@", error);
        return;
    }
    [self reload];
    [self selectNamed:name];
    [self renameSelected:nil];
}

// one item makes "name.zip", more make "Archive.zip", beside them, as the Archive Utility does
- (void)compressItems:(id)sender
{
    NSArray *paths = [self selectedPaths];
    NSString *base, *archive;

    if ([paths count] == 0)
        return;
    base = [paths count] == 1 ? [[[paths objectAtIndex:0] lastPathComponent] stringByAppendingPathExtension:@"zip"]
                              : [IDLocalized(@"Archive") stringByAppendingPathExtension:@"zip"];
    archive = [[folder stringByAppendingPathComponent:[self freeName:base in:folder]] retain];
    [paths retain];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

        if (!IDZipItems(paths, archive))
            NSLog(@"Dock: compressing to %@ failed", archive);
        [paths release];
        [archive release];
        [pool release];
    });
}

#pragma mark get info

static NSString *sizeText(unsigned long long bytes)
{
    NSString *unit = IDLocalized(@"bytes");
    double v = bytes;

    if (bytes >= 1000) {
        NSArray *units = @[ @"KB", @"MB", @"GB", @"TB" ];
        NSUInteger i = 0;

        v /= 1000;
        while (v >= 1000 && i + 1 < [units count]) {
            v /= 1000;
            i++;
        }
        // decimal units, as Finder counts since macOS 10.6
        return [NSString stringWithFormat:IDLocalized(@"%@ %@ (%@ bytes)"), [NSString stringWithFormat:v < 10 ? @"%.1f" : @"%.0f", v],
                                          units[i], [NSNumberFormatter localizedStringFromNumber:@(bytes) numberStyle:NSNumberFormatterDecimalStyle]];
    }
    return [NSString stringWithFormat:@"%llu %@", bytes, unit];
}

static unsigned long long treeSize(NSString *path)
{
    NSFileManager *fm = [[[NSFileManager alloc] init] autorelease];
    NSDirectoryEnumerator *e = [fm enumeratorAtPath:path];
    unsigned long long total = 0;

    for (NSString *sub in e) {
        NSDictionary *attrs = [e fileAttributes];

        (void)sub;
        if ([[attrs fileType] isEqualToString:NSFileTypeRegular])
            total += [attrs fileSize];
    }
    return total;
}

- (NSTextField *)infoLabel:(NSString *)text frame:(NSRect)frame bold:(BOOL)bold right:(BOOL)right
{
    NSTextField *label = [[[NSTextField alloc] initWithFrame:frame] autorelease];

    [label setStringValue:text ?: @""];
    [label setEditable:NO];
    [label setSelectable:!right];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [label setFont:bold ? [NSFont boldSystemFontOfSize:13] : [NSFont systemFontOfSize:right ? 11 : 12]];
    [label setTextColor:right ? [NSColor secondaryLabelColor] : [NSColor labelColor]];
    [label setAlignment:right ? NSRightTextAlignment : NSLeftTextAlignment];
    [[label cell] setLineBreakMode:NSLineBreakByTruncatingMiddle];
    return label;
}

- (void)showInfoFor:(IDDesktopItem *)item
{
    NSRect frame = NSMakeRect(0, 0, 300, 250);
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:frame styleMask:NSTitledWindowMask | NSClosableWindowMask
                                                  backing:NSBackingStoreBuffered defer:NO];
    NSView *content = [panel contentView];
    NSDateFormatter *dates = [[[NSDateFormatter alloc] init] autorelease];
    NSImageView *iconView = [[[NSImageView alloc] initWithFrame:NSMakeRect(16, 170, 64, 64)] autorelease];
    NSTextField *sizeField;
    NSArray *fields;
    CGFloat y = 130;

    [dates setDateStyle:NSDateFormatterLongStyle];
    [dates setTimeStyle:NSDateFormatterShortStyle];
    [panel setTitle:[NSString stringWithFormat:IDLocalized(@"%@ Info"), [item title]]];
    [panel setReleasedWhenClosed:NO];
    [panel setDelegate:(id)self];
    [panel setHidesOnDeactivate:NO];
    [iconView setImage:item->icon];
    [iconView setImageScaling:NSImageScaleProportionallyUpOrDown];
    [content addSubview:iconView];
    [content addSubview:[self infoLabel:[item title] frame:NSMakeRect(90, 206, 194, 20) bold:YES right:NO]];
    [content addSubview:[self infoLabel:item->kind frame:NSMakeRect(90, 186, 194, 18) bold:NO right:NO]];

    fields = @[ @[ IDLocalized(@"Kind:"), item->kind ],
              @[ IDLocalized(@"Size:"), item->directory ? IDLocalized(@"Calculating…") : sizeText(item->size) ],
              @[ IDLocalized(@"Where:"), folder ],
              @[ IDLocalized(@"Created:"), [dates stringFromDate:item->created] ?: @"" ],
              @[ IDLocalized(@"Modified:"), [dates stringFromDate:item->modified] ?: @"" ] ];
    sizeField = nil;
    for (NSArray *row in fields) {
        NSTextField *value = [self infoLabel:row[1] frame:NSMakeRect(96, y, 188, 18) bold:NO right:NO];

        [content addSubview:[self infoLabel:row[0] frame:NSMakeRect(8, y, 84, 18) bold:NO right:YES]];
        [content addSubview:value];
        if (sizeField == nil && row == fields[1])
            sizeField = value;
        y -= 22;
    }
    if (item->directory) {
        NSString *path = [[item->path copy] autorelease];

        [sizeField retain];
        [path retain];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
            unsigned long long total = treeSize(path);

            dispatch_async(dispatch_get_main_queue(), ^{
                [sizeField setStringValue:sizeText(total)];
                [sizeField release];
            });
            [path release];
            [pool release];
        });
    }
    [infoPanels addObject:panel];
    [panel release];
    // each new panel a little down from the last, as Finder places them
    NSRect screen = [[NSScreen mainScreen] visibleFrame];
    [panel setFrameTopLeftPoint:NSMakePoint(NSMinX(screen) + 80 + 24 * ([infoPanels count] - 1),
                                            NSMaxY(screen) - 60 - 24 * ([infoPanels count] - 1))];
    [NSApp activateIgnoringOtherApps:YES];
    [panel makeKeyAndOrderFront:nil];
}

- (void)getInfo:(id)sender
{
    for (IDDesktopItem *item in [self selection])
        [self showInfoFor:item];
}

- (void)windowWillClose:(NSNotification *)note
{
    id panel = [note object];

    if ([infoPanels containsObject:panel]) {
        [panel setDelegate:nil];
        [[panel retain] autorelease];
        [infoPanels removeObject:panel];
    }
}

#pragma mark arranging

- (void)sortBy:(NSMenuItem *)sender
{
    [sortBy release];
    sortBy = [[sender representedObject] copy];
    [controller writeSetting:@"DesktopSortBy" value:sortBy];
    [self layoutIcons];
}

// the items packed into the grid in the order they stand, or once by a key; the order stays off after it
- (void)cleanUp:(id)sender
{
    NSString *key = [sender respondsToSelector:@selector(representedObject)] ? [sender representedObject] : nil;

    [self measure];
    [self fill:key != nil ? [self sorted:key] : [self inPlaceOrder]];
    [self savePositions];
    for (IDDesktopItem *item in icons) {
        [item->lines release];
        item->lines = nil;
    }
    [self setNeedsDisplay:YES];
}

- (void)setIconSize:(NSMenuItem *)sender
{
    iconSize = [[sender representedObject] doubleValue];
    [controller writeSetting:@"DesktopIconSize" value:@(iconSize)];
    [self layoutIcons];
}

- (void)setLabelPosition:(NSMenuItem *)sender
{
    labelRight = [[sender representedObject] isEqualToString:@"right"];
    [controller writeSetting:@"DesktopLabelPosition" value:[sender representedObject]];
    [self layoutIcons];
}

#pragma mark menus

static NSMenuItem *addItem(NSMenu *menu, NSString *title, SEL action, id target, id object)
{
    NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:@""];

    [item setTarget:target];
    [item setRepresentedObject:object];
    return item;
}

static NSMenu *addSubmenu(NSMenu *menu, NSString *title)
{
    NSMenuItem *item = [menu addItemWithTitle:title action:NULL keyEquivalent:@""];
    NSMenu *sub = [[[NSMenu alloc] initWithTitle:title] autorelease];

    [item setSubmenu:sub];
    return sub;
}

// a name in quotes for a menu item, or the number of items when there are several
- (NSString *)menuTitle:(NSString *)format plural:(NSString *)plural
{
    NSArray *selection = [self selection];

    if ([selection count] == 1)
        return [NSString stringWithFormat:IDLocalized(format), [[selection objectAtIndex:0] title]];
    return [NSString stringWithFormat:IDLocalized(plural), (unsigned long)[selection count]];
}

- (NSMenu *)openWithMenu:(NSString *)path
{
    NSMenu *menu = [[[NSMenu alloc] initWithTitle:@""] autorelease];
    NSWorkspace *ws = [NSWorkspace sharedWorkspace];
    NSURL *url = [NSURL fileURLWithPath:path];
    NSString *defaultApp = [[ws URLForApplicationToOpenURL:url] path];
    NSMutableArray *apps = [NSMutableArray array];

    for (NSURL *app in [ws URLsForApplicationsToOpenURL:url])
        if ([app path] && ![[app path] isEqualToString:defaultApp] && ![apps containsObject:[app path]])
            [apps addObject:[app path]];
    if (defaultApp != nil) {
        NSString *title = [NSString stringWithFormat:IDLocalized(@"%@ (default)"),
                                                     [[defaultApp lastPathComponent] stringByDeletingPathExtension]];
        NSMenuItem *item = addItem(menu, title, @selector(openWith:), self, defaultApp);

        [item setImage:[self smallIcon:defaultApp]];
        if ([apps count])
            [menu addItem:[NSMenuItem separatorItem]];
    }
    for (NSString *app in apps)
        [addItem(menu, [[app lastPathComponent] stringByDeletingPathExtension], @selector(openWith:), self, app)
            setImage:[self smallIcon:app]];
    if ([menu numberOfItems])
        [menu addItem:[NSMenuItem separatorItem]];
    addItem(menu, IDLocalized(@"Other…"), @selector(openWithOther:), self, nil);
    return menu;
}

- (NSImage *)smallIcon:(NSString *)path
{
    NSImage *image = [[[[NSWorkspace sharedWorkspace] iconForFile:path] copy] autorelease];

    [image setSize:NSMakeSize(16, 16)];
    return image;
}

// Finder's item menu, for the selection the click landed on
- (NSMenu *)itemMenu
{
    NSMenu *menu = [[[NSMenu alloc] initWithTitle:@""] autorelease];
    NSArray *selection = [self selection];
    BOOL one = [selection count] == 1;
    IDDesktopItem *first = [selection firstObject];

    addItem(menu, IDLocalized(@"Open"), @selector(openItems:), self, nil);
    if (one && !first->app && !first->directory)
        [[menu addItemWithTitle:IDLocalized(@"Open With") action:NULL keyEquivalent:@""] setSubmenu:[self openWithMenu:first->path]];
    [menu addItem:[NSMenuItem separatorItem]];
    addItem(menu, IDLocalized(@"Move to Trash"), @selector(moveToTrash:), self, nil);
    [menu addItem:[NSMenuItem separatorItem]];
    addItem(menu, IDLocalized(@"Get Info"), @selector(getInfo:), self, nil);
    if (one)
        addItem(menu, IDLocalized(@"Rename"), @selector(renameSelected:), self, nil);
    addItem(menu, [self menuTitle:@"Compress “%@”" plural:@"Compress %lu Items"], @selector(compressItems:), self, nil);
    addItem(menu, IDLocalized(@"Duplicate"), @selector(duplicateItems:), self, nil);
    [menu addItem:[NSMenuItem separatorItem]];
    addItem(menu, [self menuTitle:@"Cut “%@”" plural:@"Cut %lu Items"], @selector(cutItems:), self, nil);
    addItem(menu, [self menuTitle:@"Copy “%@”" plural:@"Copy %lu Items"], @selector(copyItems:), self, nil);
    return menu;
}

// the desktop's own menu, as Finder gives it on macOS, with the wallpaper and displays items the dock had
- (NSMenu *)desktopMenu
{
    NSMenu *menu = [[[NSMenu alloc] initWithTitle:@""] autorelease];
    NSUInteger pasted = [[self pastedPaths] count];
    NSMenu *sort, *clean, *size, *label;

    addItem(menu, IDLocalized(@"New Folder"), @selector(newFolder:), self, nil);
    [menu addItem:[NSMenuItem separatorItem]];
    if (pasted > 0) {
        NSString *title = pasted == 1 ? [NSString stringWithFormat:IDLocalized(@"Paste “%@”"),
                                                                   [[[self pastedPaths] objectAtIndex:0] lastPathComponent]]
                                      : [NSString stringWithFormat:IDLocalized(@"Paste %lu Items"), (unsigned long)pasted];

        addItem(menu, title, @selector(pasteItems:), self, nil);
        [menu addItem:[NSMenuItem separatorItem]];
    }
    addItem(menu, IDLocalized(@"Change Wallpaper…"), @selector(showWallpaperSettings:), controller, nil);
    [menu addItem:[NSMenuItem separatorItem]];

    sort = addSubmenu(menu, IDLocalized(@"Sort By"));
    for (NSArray *pair in @[ @[ SortNone, @"None" ], @[ SortName, @"Name" ], @[ SortKind, @"Kind" ],
                             @[ SortModified, @"Date Modified" ], @[ SortCreated, @"Date Created" ], @[ SortSize, @"Size" ] ]) {
        NSMenuItem *item = addItem(sort, IDLocalized(pair[1]), @selector(sortBy:), self, pair[0]);

        [item setState:[sortBy isEqualToString:pair[0]] ? NSOnState : NSOffState];
        if (pair[0] == SortNone)
            [sort addItem:[NSMenuItem separatorItem]];
    }
    // with an order set, Finder keeps the items in it, so Clean Up has nothing to do
    [addItem(menu, IDLocalized(@"Clean Up"), @selector(cleanUp:), self, nil) setEnabled:[sortBy isEqualToString:SortNone]];
    clean = addSubmenu(menu, IDLocalized(@"Clean Up By"));
    for (NSArray *pair in @[ @[ SortName, @"Name" ], @[ SortKind, @"Kind" ], @[ SortModified, @"Date Modified" ],
                             @[ SortCreated, @"Date Created" ], @[ SortSize, @"Size" ] ])
        addItem(clean, IDLocalized(pair[1]), @selector(cleanUp:), self, pair[0]);
    [menu addItem:[NSMenuItem separatorItem]];

    size = addSubmenu(menu, IDLocalized(@"Icon Size"));
    for (NSNumber *n in @[ @32, @48, @64, @80, @96, @128 ])
        [addItem(size, [NSString stringWithFormat:IDLocalized(@"%d pt"), [n intValue]], @selector(setIconSize:), self, n)
            setState:(int)iconSize == [n intValue] ? NSOnState : NSOffState];
    label = addSubmenu(menu, IDLocalized(@"Label Position"));
    [addItem(label, IDLocalized(@"Bottom"), @selector(setLabelPosition:), self, @"bottom") setState:labelRight ? NSOffState : NSOnState];
    [addItem(label, IDLocalized(@"Right"), @selector(setLabelPosition:), self, @"right") setState:labelRight ? NSOnState : NSOffState];
    [menu addItem:[NSMenuItem separatorItem]];
    addItem(menu, IDLocalized(@"Display Settings…"), @selector(showDisplaySettings:), controller, nil);
    return menu;
}

// AppKit opens it on a right click: over an item the item's menu, with that item selected when it was not
- (NSMenu *)menuForEvent:(NSEvent *)event
{
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    IDDesktopItem *item = [self itemAt:p];

    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(renameSelected:) object:nil];
    [controller closePopup];
    if (editing != nil)
        [self endEditing:YES];
    [[self window] makeFirstResponder:self];
    if (item == nil)
        return [self desktopMenu];
    if (!item->selected)
        [self selectOnly:item];
    return [self itemMenu];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (watch != NULL) {
        dispatch_source_cancel(watch);
        dispatch_release(watch);
    }
    [icons release];
    [infoPanels release];
    [folder release];
    [sortBy release];
    [cutPaths release];
    [typed release];
    [picture release];
    [super dealloc];
}

@end
