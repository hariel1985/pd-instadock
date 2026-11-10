/*
 * IDPopup.m - popups above the dock: the context menus and the stacks.
 *
 * Copyright (c) 2026 The pd-instadock authors
 *
 * SPDX-License-Identifier: MPL-2.0 OR BSD-2-Clause
 */

#import "IDDock.h"

// room around the panel for its shadow and the compositor's blur inset
#define POP_MARGIN 18
#define POP_RADIUS 13

#define MENU_ROW 27
#define MENU_HEADER 26
#define MENU_SEP 11
#define MENU_PAD 6

#define STACK_CELL_W 100
#define STACK_CELL_H 104
#define STACK_ICON 60
#define STACK_TITLE 40
#define STACK_FOOTER 38
#define STACK_MAX 24

void IDDrawShadow(NSRect r, CGFloat radius, CGFloat spread, CGFloat strength);

static NSFont *uiFont(CGFloat size, BOOL medium)
{
    return [NSFont systemFontOfSize:size weight:medium ? NSFontWeightMedium : NSFontWeightRegular];
}

static BOOL isDark(void)
{
    return [[NSAppearance currentDrawingAppearance] _isDark];
}

static NSColor *textColor(void)
{
    return isDark() ? [NSColor colorWithCalibratedWhite:0.96 alpha:1] : [NSColor colorWithCalibratedWhite:0.08 alpha:1];
}

static NSColor *accentColor(void)
{
    return [NSColor colorWithCalibratedRed:0.20 green:0.47 blue:0.96 alpha:1];
}

// the frosted panel every popup draws behind its content
static void drawPanel(NSRect bounds)
{
    NSRect panel = NSInsetRect(bounds, POP_MARGIN, POP_MARGIN);
    BOOL dark = isDark();

    [[NSColor clearColor] setFill];
    NSRectFill(bounds);
    IDDrawShadow(panel, POP_RADIUS, 14, 0.35);
    [(dark ? [NSColor colorWithCalibratedRed:0.13 green:0.13 blue:0.15 alpha:0.80] : [NSColor colorWithCalibratedWhite:0.97 alpha:0.80]) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:panel xRadius:POP_RADIUS yRadius:POP_RADIUS] fill];
    // light along the top edge, the same glass as the dock
    [[NSColor colorWithCalibratedWhite:1 alpha:dark ? 0.16 : 0.7] setStroke];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(panel, 0.5, 0.5) xRadius:POP_RADIUS - 0.5 yRadius:POP_RADIUS - 0.5] stroke];
}

// cuts a string to a width with an ellipsis in the middle
static NSString *fitted(NSString *text, NSDictionary *attributes, CGFloat width)
{
    NSUInteger keep;

    if ([text sizeWithAttributes:attributes].width <= width)
        return text;
    for (keep = [text length]; keep > 2; keep--) {
        NSUInteger head = (keep + 1) / 2, tail = keep / 2;
        NSString *s = [NSString stringWithFormat:@"%@…%@", [text substringToIndex:head], [text substringFromIndex:[text length] - tail]];

        if ([s sizeWithAttributes:attributes].width <= width)
            return s;
    }
    return @"…";
}

@implementation IDPopup

// made where it will be shown: a popup moved after it is made is placed by its old position for a while
- (instancetype)initWithContent:(NSView *)view controller:(IDController *)owner above:(NSRect)anchor
{
    NSRect screen = [[NSScreen mainScreen] frame];
    NSRect frame = [view frame];

    frame.origin.x = floor(NSMidX(anchor) - NSWidth(frame) / 2);
    frame.origin.x = MAX(NSMinX(screen) + 4 - POP_MARGIN, MIN(frame.origin.x, NSMaxX(screen) - 4 + POP_MARGIN - NSWidth(frame)));
    frame.origin.y = NSMaxY(anchor) + 6 - POP_MARGIN;

    self = [super initWithContentRect:frame styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
    if (self == nil)
        return nil;
    controller = owner;
    [self setLevel:NSPopUpMenuWindowLevel];
    [self setOpaque:NO];
    [self setBackgroundColor:[NSColor clearColor]];
    [self setAcceptsMouseMovedEvents:YES];
    [self setContentView:view];
    [self _setBackgroundBlurInset:POP_MARGIN radius:POP_RADIUS];
    [view addTrackingRect:[view bounds] owner:self userData:NULL assumeInside:NO];
    return self;
}

- (void)dealloc
{
    [closeTimer invalidate];
    [super dealloc];
}

- (BOOL)canBecomeKeyWindow
{
    return NO;
}

- (void)show
{
    [self orderFront:nil];
}

- (void)closeNow:(NSTimer *)timer
{
    closeTimer = nil;
    if (controller->popup == self)
        [controller closePopup];
}

- (void)scheduleClose
{
    [closeTimer invalidate];
    closeTimer = [NSTimer scheduledTimerWithTimeInterval:0.9 target:self selector:@selector(closeNow:) userInfo:nil repeats:NO];
}

- (void)cancelClose
{
    [closeTimer invalidate];
    closeTimer = nil;
}

- (void)mouseEntered:(NSEvent *)event
{
    [self cancelClose];
}

- (void)mouseExited:(NSEvent *)event
{
    [self scheduleClose];
}

@end

@implementation IDMenuEntry

+ (IDMenuEntry *)title:(NSString *)title action:(SEL)action target:(id)target object:(id)object
{
    IDMenuEntry *entry = [[[IDMenuEntry alloc] init] autorelease];

    entry->title = [title copy];
    entry->action = action;
    entry->target = target;
    entry->object = [object retain];
    return entry;
}

+ (IDMenuEntry *)separator
{
    IDMenuEntry *entry = [[[IDMenuEntry alloc] init] autorelease];

    entry->separator = YES;
    return entry;
}

+ (IDMenuEntry *)header:(NSString *)title
{
    IDMenuEntry *entry = [[[IDMenuEntry alloc] init] autorelease];

    entry->title = [title copy];
    entry->header = YES;
    return entry;
}

- (void)dealloc
{
    [title release];
    [object release];
    [super dealloc];
}

- (CGFloat)height
{
    return separator ? MENU_SEP : (header ? MENU_HEADER : MENU_ROW);
}

@end

@implementation IDMenuView

+ (NSSize)sizeForEntries:(NSArray *)entries
{
    CGFloat w = 190, h = 2 * MENU_PAD;
    NSDictionary *attributes = @{ NSFontAttributeName: uiFont(13, YES) };

    for (IDMenuEntry *entry in entries) {
        h += [entry height];
        if (entry->title != nil)
            w = MAX(w, ceil([entry->title sizeWithAttributes:attributes].width) + 58);
    }
    return NSMakeSize(MIN(w, 360) + 2 * POP_MARGIN, h + 2 * POP_MARGIN);
}

- (void)dealloc
{
    [entries release];
    [super dealloc];
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event
{
    return YES;
}

- (NSRect)rectForEntry:(NSUInteger)index
{
    CGFloat y = NSMaxY([self bounds]) - POP_MARGIN - MENU_PAD;

    for (NSUInteger i = 0; i <= index && i < [entries count]; i++) {
        IDMenuEntry *entry = entries[i];

        y -= [entry height];
        if (i == index)
            return NSMakeRect(POP_MARGIN + MENU_PAD, y, NSWidth([self bounds]) - 2 * (POP_MARGIN + MENU_PAD), [entry height]);
    }
    return NSZeroRect;
}

- (void)drawRect:(NSRect)dirty
{
    drawPanel([self bounds]);
    for (NSUInteger i = 0; i < [entries count]; i++) {
        IDMenuEntry *entry = entries[i];
        NSRect r = [self rectForEntry:i];
        NSColor *color = textColor();
        NSDictionary *attributes;
        NSSize size;

        if (entry->separator) {
            [[NSColor colorWithCalibratedWhite:isDark() ? 1 : 0 alpha:0.12] setFill];
            NSRectFill(NSMakeRect(NSMinX(r) + 8, floor(NSMidY(r)), NSWidth(r) - 16, 1));
            continue;
        }
        if (entry->header) {
            attributes = @{ NSFontAttributeName: uiFont(11.5, YES),
                            NSForegroundColorAttributeName: [color colorWithAlphaComponent:0.55] };
            [fitted(entry->title, attributes, NSWidth(r) - 20) drawAtPoint:NSMakePoint(NSMinX(r) + 10, NSMinY(r) + 5) withAttributes:attributes];
            continue;
        }
        if ((NSInteger)i == highlighted) {
            [(entry->destructive ? [NSColor colorWithCalibratedRed:0.90 green:0.25 blue:0.22 alpha:1] : accentColor()) setFill];
            [[NSBezierPath bezierPathWithRoundedRect:r xRadius:7 yRadius:7] fill];
            color = [NSColor whiteColor];
        } else if (entry->destructive) {
            color = [NSColor colorWithCalibratedRed:0.92 green:0.30 blue:0.26 alpha:1];
        }
        attributes = @{ NSFontAttributeName: uiFont(13, NO), NSForegroundColorAttributeName: color };
        size = [entry->title sizeWithAttributes:attributes];
        if (entry->checked)
            [@"✓" drawAtPoint:NSMakePoint(NSMinX(r) + 10, NSMidY(r) - size.height / 2) withAttributes:attributes];
        [fitted(entry->title, attributes, NSWidth(r) - 40) drawAtPoint:NSMakePoint(NSMinX(r) + 28, floor(NSMidY(r) - size.height / 2) + 0.5)
                                                       withAttributes:attributes];
    }
}

- (NSInteger)entryAt:(NSEvent *)event
{
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];

    for (NSUInteger i = 0; i < [entries count]; i++) {
        IDMenuEntry *entry = entries[i];

        if (!entry->separator && !entry->header && NSPointInRect(p, [self rectForEntry:i]))
            return (NSInteger)i;
    }
    return -1;
}

- (void)mouseMoved:(NSEvent *)event
{
    NSInteger i = [self entryAt:event];

    [popup cancelClose];
    if (i != highlighted) {
        highlighted = i;
        [self setNeedsDisplay:YES];
    }
}

- (void)mouseExited:(NSEvent *)event
{
    highlighted = -1;
    [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)event
{
}

- (void)mouseUp:(NSEvent *)event
{
    NSInteger i = [self entryAt:event];
    IDMenuEntry *entry;

    if (i < 0)
        return;
    entry = [[entries[(NSUInteger)i] retain] autorelease];
    [[self retain] autorelease];
    [popup->controller closePopup];
    if (entry->target != nil && entry->action != NULL)
        [entry->target performSelector:entry->action withObject:entry->object];
}

@end

@implementation IDStackView

- (instancetype)initWithFolder:(NSString *)path controller:(IDController *)controller
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *found = [NSMutableArray array], *images = [NSMutableArray array];
    NSArray *names = [[fm contentsOfDirectoryAtPath:path error:NULL] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    NSInteger rows;
    NSSize size;

    for (NSString *name in names) {
        if ([name hasPrefix:@"."])
            continue;
        [found addObject:[path stringByAppendingPathComponent:name]];
        if ([found count] == STACK_MAX)
            break;
    }
    for (NSString *item in found)
        [images addObject:[controller iconForPath:item] ?: [NSNull null]];
    columns = MIN(5, MAX(3, (NSInteger)ceil(sqrt((double)[found count]))));
    rows = MAX(1, ((NSInteger)[found count] + columns - 1) / columns);
    size = NSMakeSize(columns * STACK_CELL_W + 24 + 2 * POP_MARGIN, rows * STACK_CELL_H + STACK_TITLE + STACK_FOOTER + 2 * POP_MARGIN);
    if ((self = [super initWithFrame:NSMakeRect(0, 0, size.width, size.height)]) == nil)
        return nil;
    folder = [path copy];
    paths = [found copy];
    icons = [images copy];
    highlighted = -1;
    return self;
}

- (void)dealloc
{
    [folder release];
    [paths release];
    [icons release];
    [super dealloc];
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event
{
    return YES;
}

- (NSRect)cellRect:(NSInteger)i
{
    NSInteger row = i / columns, col = i % columns;
    CGFloat top = NSMaxY([self bounds]) - POP_MARGIN - STACK_TITLE;

    return NSMakeRect(POP_MARGIN + 12 + col * STACK_CELL_W, top - (row + 1) * STACK_CELL_H, STACK_CELL_W, STACK_CELL_H);
}

- (NSRect)footerRect
{
    return NSMakeRect(POP_MARGIN + 12, POP_MARGIN + 6, NSWidth([self bounds]) - 2 * POP_MARGIN - 24, STACK_FOOTER - 12);
}

- (void)drawRect:(NSRect)dirty
{
    NSColor *color = textColor();
    NSDictionary *title = @{ NSFontAttributeName: uiFont(14, YES), NSForegroundColorAttributeName: color };
    NSDictionary *name = @{ NSFontAttributeName: uiFont(11.5, NO), NSForegroundColorAttributeName: color };
    NSString *heading = trash ? L("Trash") : [folder lastPathComponent];

    drawPanel([self bounds]);
    [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
    [heading drawAtPoint:NSMakePoint(POP_MARGIN + 20, NSMaxY([self bounds]) - POP_MARGIN - 28) withAttributes:title];

    if ([paths count] == 0) {
        NSString *empty = L("This folder is empty");
        NSSize s = [empty sizeWithAttributes:name];

        [empty drawAtPoint:NSMakePoint(NSMidX([self bounds]) - s.width / 2, NSMidY([self cellRect:0]) - s.height / 2)
            withAttributes:@{ NSFontAttributeName: uiFont(12.5, NO), NSForegroundColorAttributeName: [color colorWithAlphaComponent:0.6] }];
    }
    for (NSInteger i = 0; i < (NSInteger)[paths count]; i++) {
        NSRect cell = [self cellRect:i];
        NSRect icon = NSMakeRect(NSMidX(cell) - STACK_ICON / 2, NSMaxY(cell) - STACK_ICON - 8, STACK_ICON, STACK_ICON);
        NSString *label = fitted([[paths[i] lastPathComponent] stringByDeletingPathExtension], name, STACK_CELL_W - 10);
        NSSize s = [label sizeWithAttributes:name];

        if (i == highlighted) {
            [[NSColor colorWithCalibratedWhite:isDark() ? 1 : 0 alpha:0.10] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(cell, 4, 2) xRadius:10 yRadius:10] fill];
        }
        if (icons[i] != [NSNull null])
            [icons[i] drawInRect:icon fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1];
        [label drawAtPoint:NSMakePoint(floor(NSMidX(cell) - s.width / 2), NSMinY(icon) - s.height - 6) withAttributes:name];
    }

    {
        NSRect footer = [self footerRect];
        NSString *open = !trash ? L("Open in Files") : (confirming ? L("Click again to delete for good") : L("Empty Trash"));
        NSDictionary *attributes = @{ NSFontAttributeName: uiFont(12.5, YES),
                                      NSForegroundColorAttributeName: highlighted == -2 ? [NSColor whiteColor] : accentColor() };
        NSSize s = [open sizeWithAttributes:attributes];

        [[NSColor colorWithCalibratedWhite:isDark() ? 1 : 0 alpha:0.10] setFill];
        NSRectFill(NSMakeRect(NSMinX(footer), NSMaxY(footer) + 5, NSWidth(footer), 1));
        if (highlighted == -2) {
            [accentColor() setFill];
            [[NSBezierPath bezierPathWithRoundedRect:footer xRadius:7 yRadius:7] fill];
        }
        [open drawAtPoint:NSMakePoint(NSMidX(footer) - s.width / 2, NSMidY(footer) - s.height / 2) withAttributes:attributes];
    }
}

- (NSInteger)cellAt:(NSEvent *)event
{
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];

    if (NSPointInRect(p, [self footerRect]))
        return -2;
    for (NSInteger i = 0; i < (NSInteger)[paths count]; i++) {
        if (NSPointInRect(p, NSInsetRect([self cellRect:i], 4, 2)))
            return i;
    }
    return -1;
}

- (void)mouseMoved:(NSEvent *)event
{
    NSInteger i = [self cellAt:event];

    [popup cancelClose];
    if (i != highlighted) {
        highlighted = i;
        [self setNeedsDisplay:YES];
    }
}

- (void)mouseDown:(NSEvent *)event
{
}

- (void)mouseUp:(NSEvent *)event
{
    NSInteger i = [self cellAt:event];
    IDController *controller = popup->controller;
    NSString *path;

    if (i == -1)
        return;
    if (i == -2 && trash) {
        if ([paths count] == 0)
            return;
        if (!confirming) {
            confirming = YES;
            [self setNeedsDisplay:YES];
            return;
        }
        [[self retain] autorelease];
        [controller closePopup];
        [controller emptyTrash:nil];
        return;
    }
    path = i == -2 ? [[folder retain] autorelease] : [[paths[(NSUInteger)i] retain] autorelease];
    [[self retain] autorelease];
    [controller closePopup];
    [controller openPath:path];
}

@end
