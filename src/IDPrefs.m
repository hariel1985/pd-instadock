/*
 * IDPrefs.m - the Dock settings window: a live preview of the dock over the desktop picture, then its
 * appearance, its behaviour and what it holds.
 *
 * Copyright (c) 2026 The pd-instadock authors
 *
 * SPDX-License-Identifier: MPL-2.0 OR BSD-2-Clause
 */

#import "IDDock.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

void IDDrawShadow(NSRect r, CGFloat radius, CGFloat spread, CGFloat strength);

#define PREF_W 640
#define PREF_SIDE 28
#define PREF_PREVIEW 200
#define PREF_SPACE 22   // between sections
#define PREF_HEADING 20 // a section heading and its gap to what follows
#define PREF_ROW 48
#define PREF_LABEL_W 120
#define PREF_TILE 76
#define PREF_COLUMNS 7
#define PREF_CELL_H 84
#define PREF_ICON 40
#define SLIDER_VALUE_W 52

#pragma mark - looks

static BOOL isDark(void)
{
    return [[NSAppearance currentDrawingAppearance] _isDark];
}

static NSColor *windowColor(void)
{
    return isDark() ? [NSColor colorWithCalibratedRed:0.114 green:0.118 blue:0.133 alpha:1] : [NSColor colorWithCalibratedWhite:0.95 alpha:1];
}

static NSColor *cardColor(void)
{
    return isDark() ? [NSColor colorWithCalibratedRed:0.149 green:0.157 blue:0.176 alpha:1] : [NSColor whiteColor];
}

static NSColor *lineColor(void)
{
    return [NSColor colorWithCalibratedWhite:isDark() ? 1 : 0 alpha:isDark() ? 0.07 : 0.09];
}

static NSColor *textColor(void)
{
    return [NSColor colorWithCalibratedWhite:isDark() ? 0.95 : 0.1 alpha:1];
}

static NSColor *secondaryColor(void)
{
    return [NSColor colorWithCalibratedWhite:isDark() ? 0.66 : 0.42 alpha:1];
}

static NSColor *accentColor(void)
{
    return [NSColor colorWithCalibratedRed:0.30 green:0.55 blue:1 alpha:1];
}

static NSFont *uiFont(CGFloat size, BOOL medium)
{
    return [NSFont systemFontOfSize:size weight:medium ? NSFontWeightMedium : NSFontWeightRegular];
}

static NSDictionary *textAttributes(CGFloat size, BOOL medium, NSColor *color)
{
    return @{ NSFontAttributeName: uiFont(size, medium), NSForegroundColorAttributeName: color };
}

// cuts a string to a width with an ellipsis at its end
static NSString *truncated(NSString *text, NSDictionary *attributes, CGFloat width)
{
    if ([text sizeWithAttributes:attributes].width <= width)
        return text;
    for (NSUInteger n = [text length] - 1; n > 1; n--) {
        NSString *s = [[text substringToIndex:n] stringByAppendingString:@"…"];

        if ([s sizeWithAttributes:attributes].width <= width)
            return s;
    }
    return @"…";
}

// a rectangle measured from the top of a view that is not flipped
static NSRect fromTop(NSView *view, CGFloat x, CGFloat y, CGFloat w, CGFloat h)
{
    return NSMakeRect(x, NSHeight([view bounds]) - y - h, w, h);
}

// a round mark, filled with a tick when on, an empty ring when off
static void drawCheck(NSRect circle, BOOL on, NSColor *fill)
{
    NSBezierPath *path;

    if (!on) {
        [secondaryColor() setStroke];
        path = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(circle, 0.75, 0.75)];
        [path setLineWidth:1.5];
        [path stroke];
        return;
    }
    [fill setFill];
    [[NSBezierPath bezierPathWithOvalInRect:circle] fill];
    path = [NSBezierPath bezierPath];
    [path moveToPoint:NSMakePoint(NSMinX(circle) + NSWidth(circle) * 0.28, NSMinY(circle) + NSHeight(circle) * 0.50)];
    [path lineToPoint:NSMakePoint(NSMinX(circle) + NSWidth(circle) * 0.44, NSMinY(circle) + NSHeight(circle) * 0.34)];
    [path lineToPoint:NSMakePoint(NSMinX(circle) + NSWidth(circle) * 0.73, NSMinY(circle) + NSHeight(circle) * 0.66)];
    [path setLineWidth:MAX(1.5, NSWidth(circle) * 0.11)];
    [path setLineCapStyle:NSRoundLineCapStyle];
    [path setLineJoinStyle:NSRoundLineJoinStyle];
    [[NSColor whiteColor] setStroke];
    [path stroke];
}

#pragma mark - controls

// a track with a knob and the value beside it, whole numbers only
@interface IDSlider : NSView {
@public
    double value, minValue, maxValue;
    BOOL enabled;
    NSString *format; // the value as text, from a whole number
    id target;
    SEL action;
}
- (void)setValue:(double)v min:(double)lo max:(double)hi enabled:(BOOL)on;
@end

@implementation IDSlider

- (void)dealloc
{
    [format release];
    [super dealloc];
}

- (BOOL)isOpaque
{
    return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event
{
    return YES;
}

- (void)setValue:(double)v min:(double)lo max:(double)hi enabled:(BOOL)on
{
    if (v == value && lo == minValue && hi == maxValue && on == enabled)
        return;
    value = v, minValue = lo, maxValue = hi, enabled = on;
    [self setNeedsDisplay:YES];
}

- (NSRect)track
{
    NSRect b = [self bounds];

    return NSMakeRect(10, floor(NSMidY(b)) - 2, NSWidth(b) - SLIDER_VALUE_W - 20, 4);
}

- (void)drawRect:(NSRect)dirty
{
    NSRect b = [self bounds], track = [self track];
    CGFloat t = maxValue > minValue ? (value - minValue) / (maxValue - minValue) : 0;
    CGFloat x = NSMinX(track) + MIN(MAX(t, 0), 1) * NSWidth(track), alpha = enabled ? 1 : 0.4;
    NSRect knob = NSMakeRect(round(x) - 9, NSMidY(track) - 9, 18, 18);
    NSString *text = [NSString stringWithFormat:format, (int)round(value)];
    NSDictionary *attributes = textAttributes(13, NO, [secondaryColor() colorWithAlphaComponent:alpha]);
    NSSize size = [text sizeWithAttributes:attributes];

    [cardColor() setFill];
    NSRectFill(b);
    [[NSColor colorWithCalibratedWhite:isDark() ? 1 : 0 alpha:(isDark() ? 0.14 : 0.12) * alpha] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:track xRadius:2 yRadius:2] fill];
    [[accentColor() colorWithAlphaComponent:alpha] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(NSMinX(track), NSMinY(track), x - NSMinX(track), NSHeight(track))
                                     xRadius:2 yRadius:2] fill];
    IDDrawShadow(knob, 9, 2, 0.3 * alpha);
    [[NSColor colorWithCalibratedWhite:enabled ? 1 : 0.75 alpha:1] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:knob] fill];
    [[NSColor colorWithCalibratedWhite:0 alpha:0.12] setStroke];
    [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(knob, 0.5, 0.5)] stroke];
    [text drawAtPoint:NSMakePoint(NSMaxX(b) - size.width, floor(NSMidY(b) - size.height / 2)) withAttributes:attributes];
}

- (void)follow:(NSEvent *)event
{
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    NSRect track = [self track];
    double t = (p.x - NSMinX(track)) / NSWidth(track), v;

    if (!enabled)
        return;
    v = round(minValue + MIN(MAX(t, 0), 1) * (maxValue - minValue));
    if (v != value) {
        value = v;
        [self setNeedsDisplay:YES];
        [NSApp sendAction:action to:target from:self];
    }
}

- (void)mouseDown:(NSEvent *)event
{
    [self follow:event];
}

- (void)mouseDragged:(NSEvent *)event
{
    [self follow:event];
}

@end

// an on and off switch
@interface IDSwitch : NSView {
@public
    BOOL on;
    id target;
    SEL action;
}
- (void)setOn:(BOOL)value;
@end

@implementation IDSwitch

- (BOOL)isOpaque
{
    return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event
{
    return YES;
}

- (void)setOn:(BOOL)value
{
    if (value != on) {
        on = value;
        [self setNeedsDisplay:YES];
    }
}

- (void)drawRect:(NSRect)dirty
{
    NSRect b = [self bounds];
    NSRect track = NSMakeRect(0, floor((NSHeight(b) - 26) / 2), 44, 26);
    NSRect knob = NSMakeRect(NSMinX(track) + (on ? 21 : 3), NSMinY(track) + 3, 20, 20);

    [cardColor() setFill];
    NSRectFill(b);
    [(on ? accentColor() : [NSColor colorWithCalibratedWhite:isDark() ? 0.29 : 0.8 alpha:1]) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:track xRadius:13 yRadius:13] fill];
    IDDrawShadow(knob, 10, 1.5, 0.3);
    [[NSColor whiteColor] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:knob] fill];
}

- (void)mouseUp:(NSEvent *)event
{
    if (!NSPointInRect([self convertPoint:[event locationInWindow] fromView:nil], [self bounds]))
        return;
    on = !on;
    [self setNeedsDisplay:YES];
    [NSApp sendAction:action to:target from:self];
}

@end

// a card that is chosen or not: a picture, a title, a line about it and a round mark
@interface IDChoice : NSView {
@public
    NSString *title, *detail;
    int glyph; // 0 a screen with the dock gone, 1 a tile with a dot under it
    BOOL on;
    id target;
    SEL action;
}
- (void)setOn:(BOOL)value;
@end

@implementation IDChoice

- (void)dealloc
{
    [title release];
    [detail release];
    [super dealloc];
}

- (BOOL)isOpaque
{
    return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event
{
    return YES;
}

- (void)setOn:(BOOL)value
{
    if (value != on) {
        on = value;
        [self setNeedsDisplay:YES];
    }
}

- (void)drawGlyph:(NSRect)g
{
    NSColor *color = [NSColor colorWithCalibratedWhite:isDark() ? 0.8 : 0.35 alpha:1];
    NSBezierPath *path;

    [color setStroke];
    [color setFill];
    if (glyph == 0) {
        path = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(NSMinX(g) + 2, NSMinY(g) + 7, 18, 13) xRadius:2 yRadius:2];
        [path setLineWidth:1.6];
        [path stroke];
        // where the dock was, dashed
        for (int i = 0; i < 3; i++)
            NSRectFill(NSMakeRect(NSMinX(g) + 5 + i * 4.5, NSMinY(g) + 2, 2.5, 1.6));
    } else {
        path = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(NSMinX(g) + 4, NSMinY(g) + 7, 14, 14) xRadius:3.5 yRadius:3.5];
        [path setLineWidth:1.6];
        [path stroke];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(NSMidX(g) - 1.6, NSMinY(g) + 1, 3.2, 3.2)] fill];
    }
}

- (void)drawRect:(NSRect)dirty
{
    NSRect b = [self bounds], card = NSInsetRect(b, 0.75, 0.75);
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:card xRadius:10 yRadius:10];
    CGFloat textW = NSWidth(b) - 48 - 44;

    [windowColor() setFill];
    NSRectFill(b);
    [cardColor() setFill];
    [shape fill];
    if (on) {
        [[accentColor() colorWithAlphaComponent:0.12] setFill];
        [shape fill];
    }
    [(on ? accentColor() : lineColor()) setStroke];
    [shape setLineWidth:1.5];
    [shape stroke];

    [self drawGlyph:fromTop(self, 14, 15, 22, 22)];
    [title drawAtPoint:fromTop(self, 48, 14, textW, 17).origin withAttributes:textAttributes(13, YES, textColor())];
    // wrapped by hand: drawInRect puts a short text at the bottom of the rectangle
    {
        NSDictionary *attributes = textAttributes(12, NO, secondaryColor());
        NSMutableString *line = [NSMutableString string];
        CGFloat y = 34;

        for (NSString *word in [detail componentsSeparatedByString:@" "]) {
            NSString *longer = [line length] ? [NSString stringWithFormat:@"%@ %@", line, word] : word;

            if ([line length] && [longer sizeWithAttributes:attributes].width > textW) {
                [line drawAtPoint:fromTop(self, 48, y, textW, 15).origin withAttributes:attributes];
                [line setString:word];
                y += 15;
            } else {
                [line setString:longer];
            }
        }
        [line drawAtPoint:fromTop(self, 48, y, textW, 15).origin withAttributes:attributes];
    }
    drawCheck(fromTop(self, NSWidth(b) - 32, 14, 18, 18), on, accentColor());
}

- (void)mouseUp:(NSEvent *)event
{
    if (!NSPointInRect([self convertPoint:[event locationInWindow] fromView:nil], [self bounds]))
        return;
    on = !on;
    [self setNeedsDisplay:YES];
    [NSApp sendAction:action to:target from:self];
}

@end

// icons that are in the dock or not, a click puts one in or takes it out
@interface IDIconGrid : NSView {
@public
    NSArray *paths, *labels, *icons;
    NSArray *chosen;  // the paths in the dock
    NSString *locked; // always in the dock
    NSInteger clicked;
    id target;
    SEL action;
}
+ (CGFloat)heightFor:(NSUInteger)count;
- (void)setChosen:(NSArray *)value;
@end

@implementation IDIconGrid

+ (CGFloat)heightFor:(NSUInteger)count
{
    return ((count + PREF_COLUMNS - 1) / PREF_COLUMNS) * PREF_CELL_H;
}

- (void)dealloc
{
    [paths release];
    [labels release];
    [icons release];
    [chosen release];
    [locked release];
    [super dealloc];
}

- (BOOL)isOpaque
{
    return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event
{
    return YES;
}

- (void)setChosen:(NSArray *)value
{
    if ([value isEqualToArray:chosen])
        return;
    [chosen release];
    chosen = [value copy];
    [self setNeedsDisplay:YES];
}

- (NSRect)cellRect:(NSUInteger)i
{
    CGFloat w = NSWidth([self bounds]) / PREF_COLUMNS;

    return fromTop(self, floor((i % PREF_COLUMNS) * w), (i / PREF_COLUMNS) * PREF_CELL_H, floor(w), PREF_CELL_H);
}

- (void)drawRect:(NSRect)dirty
{
    [cardColor() setFill];
    NSRectFill([self bounds]);
    [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
    for (NSUInteger i = 0; i < [paths count]; i++) {
        NSRect cell = [self cellRect:i];
        NSRect icon = NSMakeRect(floor(NSMidX(cell) - PREF_ICON / 2), NSMaxY(cell) - 10 - PREF_ICON, PREF_ICON, PREF_ICON);
        BOOL in = [chosen containsObject:paths[i]], fixed = [paths[i] isEqualToString:locked];
        NSDictionary *attributes = textAttributes(11, NO, in ? textColor() : secondaryColor());
        NSString *label = truncated(labels[i], attributes, NSWidth(cell) - 8);
        NSSize size = [label sizeWithAttributes:attributes];

        if (in) {
            [[accentColor() colorWithAlphaComponent:isDark() ? 0.10 : 0.08] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(cell, 2, 2) xRadius:8 yRadius:8] fill];
        }
        if (icons[i] != [NSNull null])
            [icons[i] drawInRect:icon fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:in ? 1 : 0.35];
        if (in) {
            NSRect badge = NSMakeRect(NSMaxX(icon) - 9, NSMaxY(icon) - 9, 16, 16);

            [cardColor() setFill];
            [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(badge, -2, -2)] fill];
            drawCheck(badge, YES, fixed ? [NSColor colorWithCalibratedWhite:0.45 alpha:1] : accentColor());
        }
        [label drawAtPoint:NSMakePoint(floor(NSMidX(cell) - size.width / 2), NSMinY(cell) + 9) withAttributes:attributes];
    }
}

- (void)mouseUp:(NSEvent *)event
{
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];

    for (NSUInteger i = 0; i < [paths count]; i++) {
        if (NSPointInRect(p, [self cellRect:i]) && ![paths[i] isEqualToString:locked]) {
            clicked = (NSInteger)i;
            [NSApp sendAction:action to:target from:self];
            return;
        }
    }
}

@end

#pragma mark - the preview

// the dock's own drawing over the bottom of the desktop picture, scaled down to fit. While it is live the
// pointer magnifies it like the real one, and when the pointer is elsewhere the second app shows how
// magnification looks; otherwise it is a still picture of the dock at rest, drawn again only when a setting
// changes. The chip in its corner switches between the two.
@interface IDPreviewDock : IDDockView {
@public
    IDSettings real; // the settings as they are, before scaling
    CGFloat k;       // preview points per screen point
    BOOL live;
    id target;       // told when the chip switches live on or off
    SEL action;
    CGFloat mouseX;  // NAN while the pointer is elsewhere
    NSTrackingRectTag tracking;
    BOOL framePending;
    NSTimeInterval lastFrame;
}
- (void)place;
- (void)pointerAt:(NSEvent *)event;
- (void)pointerX:(CGFloat)x;
- (void)resetTracking;
@end

@implementation IDPreviewDock

- (BOOL)isOpaque
{
    return YES;
}

- (BOOL)acceptsFirstResponder
{
    return YES;
}

- (void)resetTracking
{
    if (tracking != 0)
        [self removeTrackingRect:tracking];
    tracking = [self addTrackingRect:[self bounds] owner:self userData:NULL assumeInside:NO];
}

- (void)place
{
    IDItem *demo = nil;
    NSUInteger apps = 0;

    settings = real;
    settings.tile = round(real.tile * k);
    settings.magnified = round(MAX(real.magnified, real.tile) * k);
    hide = real.autohide && isnan(mouseX) ? 0.55 : 0;
    pointerX = NAN;
    zoom = 0;
    hover = nil;
    [self layoutItems];
    if (hide > 0 || !live)
        return;
    if (!isnan(mouseX)) {
        pointerX = mouseX;
    } else if (settings.magnify) {
        for (IDItem *item in items) {
            if (item->kind == IDItemApp && ++apps <= 2)
                demo = item;
        }
        pointerX = demo != nil ? demo->restCenter : NAN;
    }
    if (isnan(pointerX))
        return;
    zoom = settings.magnify ? 1 : 0;
    [self layoutItems];
    hover = [self itemAtX:pointerX];
}

- (void)pointerAt:(NSEvent *)event
{
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    CGFloat x = live && NSPointInRect(p, [self bounds]) ? p.x : NAN;

    if (x == mouseX || (isnan(x) && isnan(mouseX)))
        return;
    [self pointerX:x];
}

// the pointer only moves the state, a frame at most 60 times a second draws it, so events never queue up
// behind drawing
- (void)pointerX:(CGFloat)x
{
    mouseX = x;
    if (!framePending) {
        // the next frame is due a 60th of a second after the last one began, not after this event
        NSTimeInterval wait = lastFrame + 1.0 / 60 - [NSDate timeIntervalSinceReferenceDate];

        framePending = YES;
        [self performSelector:@selector(nextFrame) withObject:nil afterDelay:MAX(wait, 0)];
    }
}

- (void)nextFrame
{
    NSTimeInterval start = [NSDate timeIntervalSinceReferenceDate];

    framePending = NO;
    [self place];
    [self display];
    if (getenv("ID_PROFILE") != NULL)
        fprintf(stderr, "Dock: preview frame %.1f ms with flushing, %.1f ms since the last one\n",
                ([NSDate timeIntervalSinceReferenceDate] - start) * 1000, (start - lastFrame) * 1000);
    lastFrame = start;
}

- (void)mouseMoved:(NSEvent *)event
{
    [self pointerAt:event];
}

- (void)mouseEntered:(NSEvent *)event
{
    [self pointerAt:event];
}

- (void)mouseExited:(NSEvent *)event
{
    [self pointerX:NAN];
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event
{
    return YES;
}

// the chip in the upper left corner: the words and a small switch
- (NSRect)chipRect
{
    NSSize size = [L("Live preview") sizeWithAttributes:textAttributes(11, YES, [NSColor whiteColor])];
    CGFloat h = 26;

    return NSMakeRect(14, NSHeight([self bounds]) - 12 - h, ceil(size.width) + 9 + 8 + 28 + 6, h);
}

- (void)drawRect:(NSRect)dirty
{
    NSRect chip = [self chipRect];
    NSDictionary *attributes = textAttributes(11, YES, [NSColor colorWithCalibratedWhite:1 alpha:live ? 1 : 0.85]);
    NSString *text = L("Live preview");
    NSSize size = [text sizeWithAttributes:attributes];
    NSRect track = NSMakeRect(NSMaxX(chip) - 6 - 28, NSMidY(chip) - 8, 28, 16);
    NSRect knob = NSMakeRect(NSMinX(track) + (live ? 14 : 2), NSMinY(track) + 2, 12, 12);

    [super drawRect:dirty];
    [[NSColor colorWithCalibratedWhite:0 alpha:0.45] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:chip xRadius:8 yRadius:8] fill];
    [text drawAtPoint:NSMakePoint(NSMinX(chip) + 9, floor(NSMidY(chip) - size.height / 2)) withAttributes:attributes];
    [(live ? accentColor() : [NSColor colorWithCalibratedWhite:1 alpha:0.3]) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:track xRadius:8 yRadius:8] fill];
    [[NSColor whiteColor] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:knob] fill];
}

- (void)mouseDown:(NSEvent *)event
{
    if (!NSPointInRect([self convertPoint:[event locationInWindow] fromView:nil], NSInsetRect([self chipRect], -4, -4)))
        return;
    live = !live;
    mouseX = NAN;
    if (live)
        [self pointerAt:event];
    [self place];
    [self setNeedsDisplay:YES];
    [NSApp sendAction:action to:target from:self];
}

@end

#pragma mark - the window

// headings, cards, row labels and lines are drawn here, the controls are subviews
@interface IDPrefsView : NSView {
@public
    NSMutableArray *drawings; // blocks, in order
    IDPreviewDock *preview;
}
@end

@implementation IDPrefsView

- (BOOL)isFlipped
{
    return YES;
}

- (BOOL)isOpaque
{
    return YES;
}

- (void)dealloc
{
    [drawings release];
    [super dealloc];
}

- (void)drawRect:(NSRect)dirty
{
    if (getenv("ID_PREFS") != NULL)
        NSLog(@"Dock: settings draw %@ in %@", NSStringFromRect(dirty), NSStringFromRect([self bounds]));
    [windowColor() setFill];
    NSRectFill([self bounds]);
    // NSRectFill copies, and a see-through line would let the screen behind the window show
    [lineColor() setFill];
    NSRectFillUsingOperation(NSMakeRect(0, PREF_PREVIEW, NSWidth([self bounds]), 1), NSCompositeSourceOver);
    for (void (^draw)(void) in drawings)
        draw();
}

- (void)mouseMoved:(NSEvent *)event
{
    [preview pointerAt:event];
}

@end

@implementation IDPrefsController

- (instancetype)initWithController:(IDController *)controller
{
    if ((self = [super init]) == nil)
        return nil;
    _controller = controller;
    return self;
}

- (void)dealloc
{
    [_window release];
    [_previewKey release];
    [_previewPicture release];
    [super dealloc];
}

- (NSArray *)stackChoices
{
    NSString *home = NSHomeDirectory();

    return @[ @[ L("Applications"), @"/Applications" ], @[ L("Downloads"), [home stringByAppendingPathComponent:@"Downloads"] ],
              @[ L("Documents"), [home stringByAppendingPathComponent:@"Documents"] ],
              @[ L("Desktop"), [home stringByAppendingPathComponent:@"Desktop"] ], @[ L("Home"), home ] ];
}

- (void)draw:(void (^)(void))block in:(IDPrefsView *)view
{
    [view->drawings addObject:[[block copy] autorelease]];
}

- (void)heading:(NSString *)text at:(CGFloat)y in:(IDPrefsView *)view
{
    NSString *upper = [text uppercaseString];

    [self draw:^{
        [upper drawAtPoint:NSMakePoint(PREF_SIDE + 4, y) withAttributes:textAttributes(11.5, YES, secondaryColor())];
    } in:view];
}

- (void)card:(NSRect)r in:(IDPrefsView *)view
{
    [self draw:^{
        NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 0.5, 0.5) xRadius:10 yRadius:10];

        [cardColor() setFill];
        [shape fill];
        [lineColor() setStroke];
        [shape stroke];
    } in:view];
}

- (void)divider:(NSRect)r in:(IDPrefsView *)view
{
    [self draw:^{
        [lineColor() setFill];
        NSRectFillUsingOperation(r, NSCompositeSourceOver);
    } in:view];
}

- (void)label:(NSString *)text at:(NSPoint)p size:(CGFloat)size secondary:(BOOL)secondary in:(IDPrefsView *)view
{
    [self draw:^{
        [text drawAtPoint:p withAttributes:textAttributes(size, NO, secondary ? secondaryColor() : textColor())];
    } in:view];
}

- (IDSlider *)slider:(NSRect)frame format:(NSString *)format action:(SEL)action in:(NSView *)view
{
    IDSlider *slider = [[[IDSlider alloc] initWithFrame:frame] autorelease];

    slider->format = [format copy];
    slider->enabled = YES;
    slider->target = self;
    slider->action = action;
    [view addSubview:slider];
    return slider;
}

- (IDChoice *)choice:(NSRect)frame title:(NSString *)title detail:(NSString *)detail glyph:(int)glyph action:(SEL)action
                  in:(NSView *)view
{
    IDChoice *choice = [[[IDChoice alloc] initWithFrame:frame] autorelease];

    choice->title = [title copy];
    choice->detail = [detail copy];
    choice->glyph = glyph;
    choice->target = self;
    choice->action = action;
    [view addSubview:choice];
    return choice;
}

- (IDIconGrid *)grid:(NSRect)frame paths:(NSArray *)paths labels:(NSArray *)labels action:(SEL)action in:(NSView *)view
{
    IDIconGrid *grid = [[[IDIconGrid alloc] initWithFrame:frame] autorelease];
    NSMutableArray *icons = [NSMutableArray array];

    for (NSString *path in paths)
        [icons addObject:[_controller iconForPath:path] ?: (id)[NSNull null]];
    grid->paths = [paths copy];
    grid->labels = [labels copy];
    grid->icons = [icons copy];
    grid->target = self;
    grid->action = action;
    [view addSubview:grid];
    return grid;
}

- (void)build
{
    NSArray *apps = [_controller installedApps], *stacks = [self stackChoices];
    NSMutableArray *appLabels = [NSMutableArray array], *stackPaths = [NSMutableArray array], *stackLabels = [NSMutableArray array];
    CGFloat inner = PREF_W - 2 * PREF_SIDE, rowX = PREF_SIDE + 16, controlX = rowX + PREF_LABEL_W;
    CGFloat controlW = PREF_W - PREF_SIDE - 16 - controlX, tileW = floor((inner - 10) / 2), y, top, h;
    IDPrefsView *view = [[[IDPrefsView alloc] initWithFrame:NSMakeRect(0, 0, PREF_W, 2000)] autorelease];
    NSString *hint = L("Click an icon to add or remove it");

    for (NSString *path in apps)
        [appLabels addObject:[_controller labelForPath:path]];
    for (NSArray *stack in stacks) {
        [stackLabels addObject:stack[0]];
        [stackPaths addObject:stack[1]];
    }
    view->drawings = [[NSMutableArray alloc] init];

    _preview = [[[IDPreviewDock alloc] initWithFrame:NSMakeRect(0, 0, PREF_W, PREF_PREVIEW)] autorelease];
    _preview->controller = _controller;
    _preview->live = [[(id)CFPreferencesCopyAppValue(CFSTR("LivePreview"), IDDomain) autorelease] boolValue];
    _preview->target = self;
    _preview->action = @selector(liveChanged:);
    _preview->mouseX = NAN;
    _preview->pointerX = NAN;
    [view addSubview:_preview];
    view->preview = _preview;

    // appearance: a card of three rows
    y = PREF_PREVIEW + PREF_SPACE;
    [self heading:L("Appearance") at:y in:view];
    top = y + PREF_HEADING;
    [self card:NSMakeRect(PREF_SIDE, top, inner, 3 * PREF_ROW) in:view];
    [self label:L("Size") at:NSMakePoint(rowX, top + 15) size:13 secondary:NO in:view];
    _size = [self slider:NSMakeRect(controlX, top + 10, controlW, 28) format:L("%d pt") action:@selector(sizeChanged:) in:view];
    [self divider:NSMakeRect(rowX, top + PREF_ROW, inner - 16, 1) in:view];
    [self label:L("Magnification") at:NSMakePoint(rowX, top + PREF_ROW + 15) size:13 secondary:NO in:view];
    _magnify = [[[IDSwitch alloc] initWithFrame:NSMakeRect(controlX, top + PREF_ROW + 11, 44, 26)] autorelease];
    _magnify->target = self;
    _magnify->action = @selector(magnifyChanged:);
    [view addSubview:_magnify];
    _magnified = [self slider:NSMakeRect(controlX + 56, top + PREF_ROW + 10, controlW - 56, 28) format:L("%d pt")
                       action:@selector(magnifiedChanged:) in:view];
    [self divider:NSMakeRect(rowX, top + 2 * PREF_ROW, inner - 16, 1) in:view];
    [self label:L("Liquid glass") at:NSMakePoint(rowX, top + 2 * PREF_ROW + 15) size:13 secondary:NO in:view];
    _glass = [self slider:NSMakeRect(controlX, top + 2 * PREF_ROW + 10, controlW, 28) format:@"%d%%" action:@selector(glassChanged:) in:view];

    // behaviour: two cards side by side
    y = top + 3 * PREF_ROW + PREF_SPACE;
    [self heading:L("Behaviour") at:y in:view];
    top = y + PREF_HEADING;
    _autohide = [self choice:NSMakeRect(PREF_SIDE, top, tileW, PREF_TILE) title:L("Auto-hide")
                      detail:L("Takes no room, the pointer brings it back") glyph:0 action:@selector(autohideChanged:) in:view];
    _indicators = [self choice:NSMakeRect(PREF_W - PREF_SIDE - tileW, top, tileW, PREF_TILE) title:L("Running indicators")
                        detail:L("A dot under open applications") glyph:1 action:@selector(indicatorsChanged:) in:view];

    // what the dock holds: apps, then folders
    y = top + PREF_TILE + PREF_SPACE;
    [self heading:L("Dock contents") at:y in:view];
    {
        NSDictionary *attributes = textAttributes(12, NO, secondaryColor());
        CGFloat w = [hint sizeWithAttributes:attributes].width;

        [self label:hint at:NSMakePoint(PREF_W - PREF_SIDE - 4 - w, y - 0.5) size:12 secondary:YES in:view];
    }
    top = y + PREF_HEADING;
    h = 12 + 18 + [IDIconGrid heightFor:[apps count]] + 10 + 1 + 10 + 18 + [IDIconGrid heightFor:[stackPaths count]] + 10;
    [self card:NSMakeRect(PREF_SIDE, top, inner, h) in:view];
    y = top + 12;
    [self label:L("Applications") at:NSMakePoint(PREF_SIDE + 16, y) size:12 secondary:NO in:view];
    y += 18;
    _apps = [self grid:NSMakeRect(PREF_SIDE + 10, y, inner - 20, [IDIconGrid heightFor:[apps count]]) paths:apps labels:appLabels
                action:@selector(appClicked:) in:view];
    _apps->locked = [[apps firstObject] copy];
    y += [IDIconGrid heightFor:[apps count]] + 10;
    [self divider:NSMakeRect(PREF_SIDE + 16, y, inner - 32, 1) in:view];
    y += 11;
    [self label:L("Folders") at:NSMakePoint(PREF_SIDE + 16, y) size:12 secondary:NO in:view];
    y += 18;
    _stacks = [self grid:NSMakeRect(PREF_SIDE + 10, y, inner - 20, [IDIconGrid heightFor:[stackPaths count]]) paths:stackPaths
                  labels:stackLabels action:@selector(stackClicked:) in:view];
    y = top + h + 26;

    [view setFrameSize:NSMakeSize(PREF_W, y)];
    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, PREF_W, y)
                                          styleMask:NSTitledWindowMask | NSClosableWindowMask
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    [_window setTitle:L("Dock Settings")];
    [_window setReleasedWhenClosed:NO];
    [_window setDelegate:self];
    [_window setAcceptsMouseMovedEvents:YES];
    [_window setContentView:view];
    [_window makeFirstResponder:_preview];
    [_preview resetTracking];
    [_window center];
}

// the blurred and the sharp desktop picture under the bottom of the screen, at the preview's scale
- (void)renderPreviewBackdrop
{
    NSImage *picture = [_controller desktopPicture];
    NSRect screen = [[NSScreen mainScreen] frame], bounds = [_preview bounds];
    CGFloat scale = [_window respondsToSelector:@selector(backingScaleFactor)] ? [_window backingScaleFactor] : 1;
    NSSize seen = NSMakeSize(NSWidth(bounds) / _preview->k, NSHeight(bounds) / _preview->k);
    NSRect region = NSMakeRect(NSMidX(screen) - seen.width / 2, NSMinY(screen), seen.width, seen.height);
    IDPixels sharp, half;

    scale = scale >= 1 ? scale : 1;
    sharp = IDRenderPixels(bounds.size, scale, ^{
        [[NSColor colorWithCalibratedRed:0.85 green:0.47 blue:0.35 alpha:1] setFill];
        NSRectFill(bounds);
        if (picture != nil && [picture size].width > 0 && [picture size].height > 0)
            [picture drawInRect:bounds fromRect:IDPictureRect(picture, screen, region) operation:NSCompositeSourceOver fraction:1];
    });
    // the same blur as the dock's, measured on the screen
    half = IDHalve(&sharp);
    free(_preview->under.px);
    _preview->under = sharp;
    IDBlur(&half, MAX(2, (int)round(9 * _preview->k * scale * 0.5)));
    [_preview setBackdrop:half scale:scale * 0.5];
}

// the preview draws copies of the dock's items, so its layout leaves the dock's alone
- (void)updatePreview
{
    NSArray *live = _controller->items;
    NSMutableString *key = [NSMutableString string];
    NSUInteger tiles = 0, separators = 0;
    CGFloat widest, k;

    for (IDItem *item in live)
        [key appendFormat:@"%d %@ %d %lu %p\n", item->kind, item->path, item->running, (unsigned long)item->count, item->badge];
    if (![key isEqualToString:_previewKey]) {
        NSMutableArray *copies = [NSMutableArray array];

        for (IDItem *item in live) {
            IDItem *twin = [IDItem itemWithKind:item->kind path:item->path];

            twin->label = [item->label copy];
            twin->icon = [item->icon retain];
            twin->badge = [item->badge retain];
            twin->running = item->running;
            twin->pinned = item->pinned;
            twin->count = item->count;
            [copies addObject:twin];
            if (item->kind == IDItemSeparator)
                separators++;
            else
                tiles++;
        }
        [_preview->items release];
        _preview->items = [copies retain];
        [_previewKey release];
        _previewKey = [key copy];
    } else {
        for (IDItem *item in live) {
            if (item->kind == IDItemSeparator)
                separators++;
            else
                tiles++;
        }
    }
    // a scale that fits the largest dock, so the size slider shows in the preview
    widest = 2 * ID_PAD_X + tiles * (72 + ID_GAP) + separators * (ID_SEP_W + ID_GAP) - ID_GAP + (128 - 72) * 2.3;
    k = MIN(0.75, (PREF_W - 40) / widest);
    if (fabs(k - _preview->k) > 0.001 || [_controller desktopPicture] != _previewPicture) {
        _preview->k = k;
        [_previewPicture release];
        _previewPicture = [[_controller desktopPicture] retain];
        [self renderPreviewBackdrop];
    }
    _preview->real = _controller->settings;
    [_preview place];
    [_preview setNeedsDisplay:YES];
}

- (void)refresh
{
    IDSettings s = _controller->settings;

    if (_window == nil)
        return;
    [_size setValue:s.tile min:32 max:72 enabled:YES];
    [_magnify setOn:s.magnify];
    [_magnified setValue:MAX(s.magnified, s.tile) min:s.tile max:128 enabled:s.magnify];
    [_glass setValue:round(s.glass * 100) min:0 max:100 enabled:YES];
    [_autohide setOn:s.autohide];
    [_indicators setOn:s.indicators];
    [_apps setChosen:[_controller pinnedApps]];
    [_stacks setChosen:[_controller stacks]];
    [self updatePreview];
}

- (void)show
{
    if (_window == nil)
        [self build];
    [self refresh];
    [NSApp activateIgnoringOtherApps:YES];
    [_window makeKeyAndOrderFront:nil];
    // the first frame can go out before the compositor has configured the new window, and is lost
    [self performSelector:@selector(redisplay) withObject:nil afterDelay:0.25];
    [self performSelector:@selector(redisplay) withObject:nil afterDelay:1];
    if (getenv("ID_DEMO") != NULL)
        [NSTimer scheduledTimerWithTimeInterval:8 target:self selector:@selector(demo:) userInfo:nil repeats:NO];
}

// ID_DEMO: after the dock's own sweep, a pointer sweeps the preview for six seconds
- (void)demo:(NSTimer *)timer
{
    static NSTimeInterval start;
    NSTimeInterval t;

    if (start == 0) {
        start = [NSDate timeIntervalSinceReferenceDate];
        _preview->live = YES;
        [NSTimer scheduledTimerWithTimeInterval:1.0 / 120 target:self selector:@selector(demo:) userInfo:nil repeats:YES];
        return;
    }
    t = [NSDate timeIntervalSinceReferenceDate] - start;
    if (t > 6) {
        [timer invalidate];
        [_preview pointerX:NAN];
        return;
    }
    [_preview pointerX:NSWidth([_preview bounds]) * (0.5 + 0.4 * sin(t * 1.4))];
}

// a closed window is not shown again, a new one is built: the window server does not always show a
// toplevel that was closed and ordered in again
- (void)windowWillClose:(NSNotification *)note
{
    [_window setDelegate:nil];
    [_window autorelease];
    _window = nil;
    _preview = nil;
    [_previewKey release];
    _previewKey = nil;
    [_previewPicture release];
    _previewPicture = nil;
}

- (void)redisplay
{
    [[_window contentView] setNeedsDisplay:YES];
    [_window display];
}

- (void)apply:(NSString *)key value:(id)value
{
    [_controller writeSetting:key value:value];
    [_controller performSelector:@selector(tick:) withObject:nil];
}

// only remembered, the dock itself does not use it
- (void)liveChanged:(IDPreviewDock *)sender
{
    [_controller writeSetting:@"LivePreview" value:@(sender->live)];
}

- (void)sizeChanged:(IDSlider *)sender
{
    [self apply:@"TileSize" value:@(sender->value)];
}

- (void)magnifiedChanged:(IDSlider *)sender
{
    [self apply:@"MagnifiedSize" value:@(sender->value)];
}

- (void)glassChanged:(IDSlider *)sender
{
    [self apply:@"Glass" value:@(sender->value / 100)];
}

- (void)magnifyChanged:(IDSwitch *)sender
{
    [self apply:@"Magnify" value:@(sender->on)];
}

- (void)autohideChanged:(IDChoice *)sender
{
    [self apply:@"AutoHide" value:@(sender->on)];
}

- (void)indicatorsChanged:(IDChoice *)sender
{
    [self apply:@"ShowIndicators" value:@(sender->on)];
}

- (void)appClicked:(IDIconGrid *)sender
{
    NSMutableArray *pinned = [[[_controller pinnedApps] mutableCopy] autorelease];
    NSString *path = sender->paths[(NSUInteger)sender->clicked];

    if ([pinned containsObject:path])
        [pinned removeObject:path];
    else
        [pinned addObject:path];
    [_controller setPinnedApps:pinned];
}

- (void)stackClicked:(IDIconGrid *)sender
{
    NSMutableArray *stacks = [[[_controller stacks] mutableCopy] autorelease];
    NSString *path = sender->paths[(NSUInteger)sender->clicked];

    // a new stack goes last, the others keep the order they were dragged into
    if ([stacks containsObject:path]) {
        [stacks removeObject:path];
    } else {
        [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:NULL];
        [stacks addObject:path];
    }
    [_controller setStacks:stacks];
}

@end
