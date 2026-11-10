/*
 * IDDockView.m - lays out and draws the dock: glass bar, tiles, magnification and labels.
 *
 * Copyright (c) 2026 The pd-instadock authors
 *
 * SPDX-License-Identifier: MPL-2.0 OR BSD-2-Clause
 */

#import "IDDock.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

// tiles further than this many rest tiles from the pointer keep their size
#define ID_REACH 2.6
// the bar's shadow
#define ID_SHADOW_SPREAD 16
#define ID_SHADOW_FALL 4
// a launched app bounces until it shows up, at most this long
#define ID_BOUNCE_TIME 6.0

static NSFont *labelFont(void)
{
    return [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium];
}

static NSDictionary *labelAttributes(void)
{
    return @{ NSFontAttributeName: labelFont(), NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:1 alpha:0.96] };
}

// a soft rounded shadow, a stack of faint fills growing outwards
void IDDrawShadow(NSRect r, CGFloat radius, CGFloat spread, CGFloat strength)
{
    int steps = 4;

    for (int i = 0; i < steps; i++) {
        CGFloat k = (CGFloat)(i + 1) / steps;
        NSRect s = NSOffsetRect(NSInsetRect(r, -spread * k, -spread * k), 0, -spread * 0.35);

        [[NSColor colorWithCalibratedWhite:0 alpha:strength / steps * (1.15 - k)] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:s xRadius:radius + spread * k yRadius:radius + spread * k] fill];
    }
}

// the dark pill behind a label
void IDDrawPill(NSString *text, NSPoint bottomCenter)
{
    NSDictionary *attributes = labelAttributes();
    NSSize size = [text sizeWithAttributes:attributes];
    NSRect pill = NSMakeRect(floor(bottomCenter.x - size.width / 2 - 11), floor(bottomCenter.y), ceil(size.width) + 22, ceil(size.height) + 9);

    IDDrawShadow(pill, 8, 6, 0.25);
    [[NSColor colorWithCalibratedRed:0.10 green:0.10 blue:0.12 alpha:0.86] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:8 yRadius:8] fill];
    [[NSColor colorWithCalibratedWhite:1 alpha:0.14] setStroke];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(pill, 0.5, 0.5) xRadius:7.5 yRadius:7.5] stroke];
    [text drawAtPoint:NSMakePoint(NSMinX(pill) + 11, NSMinY(pill) + floor((NSHeight(pill) - size.height) / 2) + 0.5)
        withAttributes:attributes];
}

@implementation IDDockView

- (BOOL)isOpaque
{
    return NO;
}

- (void)dealloc
{
    free(back.px);
    free(canvas.px);
    free(base.px);
    free(pill.px);
    [pillText release];
    free(under.px);
    [items release];
    [super dealloc];
}

- (void)setBackdrop:(IDPixels)pixels scale:(CGFloat)scale
{
    free(back.px);
    back = pixels;
    backScale = scale;
    baseKey[0] = -1;
    [self setNeedsDisplay:YES];
}

- (CGFloat)hideDistance
{
    return barHeight + ID_SHADOW + ID_SCREEN_GAP + 6;
}

- (void)layoutItems
{
    CGFloat T = settings.tile, M = settings.magnify ? MAX(settings.magnified, T) : T;
    CGFloat x = 0, newLeft, shift = 0, reach = T * ID_REACH;
    NSUInteger n = [items count], j = 0;
    CGFloat lefts[n + 1], widths[n + 1];

    barHeight = ID_PAD_TOP + T + ID_PAD_BOTTOM;
    for (IDItem *item in items) {
        CGFloat w = item->kind == IDItemSeparator ? ID_SEP_W : T;

        item->restCenter = x + w / 2;
        x += w + ID_GAP;
    }
    barRestWidth = n ? x - ID_GAP + 2 * ID_PAD_X : 2 * ID_PAD_X;
    barRestLeft = floor((NSWidth([self bounds]) - barRestWidth) / 2);
    for (IDItem *item in items)
        item->restCenter += barRestLeft + ID_PAD_X;

    // sizes from the distance to the pointer at rest, a raised cosine
    x = 0;
    for (NSUInteger i = 0; i < n; i++) {
        IDItem *item = items[i];
        CGFloat w;

        if (item->kind == IDItemSeparator) {
            w = ID_SEP_W;
        } else {
            CGFloat d = isnan(pointerX) ? reach : fabs(item->restCenter - pointerX);
            CGFloat f = d < reach ? 0.5 * (1 + cos(M_PI * d / reach)) : 0;

            w = T + (M - T) * f * zoom;
        }
        item->size = w;
        lefts[i] = x;
        widths[i] = w;
        x += w + ID_GAP;
    }
    // the point under the pointer stays under it, so the dock grows away from it on both sides
    if (n > 0 && !isnan(pointerX) && zoom > 0) {
        CGFloat slotLeft;

        for (j = 0; j + 1 < n; j++) {
            IDItem *item = items[j];
            CGFloat restW = item->kind == IDItemSeparator ? ID_SEP_W : T;

            if (pointerX < item->restCenter + restW / 2 + ID_GAP / 2)
                break;
        }
        {
            IDItem *item = items[j];
            CGFloat restW = item->kind == IDItemSeparator ? ID_SEP_W : T;
            CGFloat t;

            slotLeft = item->restCenter - restW / 2 - ID_GAP / 2;
            t = (pointerX - slotLeft) / (restW + ID_GAP);
            t = MIN(MAX(t, 0), 1);
            newLeft = lefts[j] - ID_GAP / 2 + t * (widths[j] + ID_GAP);
            shift = pointerX - newLeft - (barRestLeft + ID_PAD_X);
        }
    }
    for (NSUInteger i = 0; i < n; i++) {
        IDItem *item = items[i];

        item->center = barRestLeft + ID_PAD_X + lefts[i] + widths[i] / 2 + shift;
    }
}

- (BOOL)step
{
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    BOOL busy = NO;
    // an open popup sits just above the bar, the tiles stay at rest under it
    CGFloat zoomTo = (controller->inside && !isnan(pointerX) && settings.magnify && dragging == nil && controller->popup == nil) ? 1 : 0;
    CGFloat hideTo = (settings.autohide && !controller->shown) ? 1 : 0;

    if (fabs(zoom - zoomTo) > 0.002) {
        zoom += (zoomTo - zoom) * 0.28;
        busy = YES;
    } else {
        zoom = zoomTo;
    }
    if (fabs(hide - hideTo) > 0.002) {
        hide += (hideTo - hide) * 0.22;
        busy = YES;
    } else {
        hide = hideTo;
    }
    for (IDItem *item in items) {
        if (fabs(item->offset) > 0.3) {
            item->offset *= 0.72;
            busy = YES;
        } else {
            item->offset = 0;
        }
        if (item->bounceStart > 0) {
            if (item->running || now - item->bounceStart > ID_BOUNCE_TIME)
                item->bounceStart = 0;
            else
                busy = YES;
        }
    }
    if (zoom == 0 && zoomTo == 0)
        pointerX = NAN;
    [self layoutItems];
    [self invalidateContent];
    return busy;
}

// the bar with its shadow, and everything above it up to the top: magnified tiles, labels, a dragged tile
- (void)invalidateContent
{
    NSRect bar = [self barRect], content;

    content = NSMakeRect(NSMinX(bar) - 90, 0, NSWidth(bar) + 180, NSHeight([self bounds]));
    if (dragging != nil)
        content = NSUnionRect(content, NSMakeRect(dragX - settings.tile, 0, 2 * settings.tile, NSHeight([self bounds])));
    content = NSIntersectionRect(NSIntegralRect(content), [self bounds]);
    [self setNeedsDisplayInRect:NSUnionRect(content, lastContent)];
    lastContent = content;
}

- (CGFloat)barY
{
    return ID_SHADOW - hide * [self hideDistance];
}

- (NSRect)barRect
{
    IDItem *first = [items firstObject], *last = [items lastObject];
    CGFloat left = first ? first->center - first->size / 2 - ID_PAD_X : barRestLeft;
    CGFloat right = last ? last->center + last->size / 2 + ID_PAD_X : barRestLeft + barRestWidth;

    return NSMakeRect(floor(left), [self barY], ceil(right - floor(left)), barHeight);
}

- (CGFloat)bounceForItem:(IDItem *)item
{
    NSTimeInterval t;

    if (item->bounceStart <= 0)
        return 0;
    t = [NSDate timeIntervalSinceReferenceDate] - item->bounceStart;
    // a hop every 0.62 s, a little lower each time
    return fabs(sin(t * M_PI / 0.62)) * settings.tile * 0.42 * MAX(0.35, 1 - t / ID_BOUNCE_TIME);
}

- (NSRect)iconRectForItem:(IDItem *)item
{
    CGFloat x = item->center + item->offset - item->size / 2;
    CGFloat y = [self barY] + ID_PAD_BOTTOM + [self bounceForItem:item];

    return NSMakeRect(x, y, item->size, item->size);
}

- (IDItem *)itemAtX:(CGFloat)x
{
    for (IDItem *item in items) {
        CGFloat half = item->size / 2 + ID_GAP / 2;

        if (item->kind != IDItemSeparator && x >= item->center - half && x < item->center + half)
            return item;
    }
    return nil;
}

- (CGFloat)pixelScale
{
    CGFloat scale = 1;

    if ([[self window] respondsToSelector:@selector(backingScaleFactor)])
        scale = [[self window] backingScaleFactor];
    return scale >= 1 ? scale : 1;
}

// ID_PROFILE: the average time of the parts of a frame, every 10 frames, on stderr
static double profile[5];
static int profileFrames;

static double now_ms(void)
{
    return [NSDate timeIntervalSinceReferenceDate] * 1000;
}

#define PILL_MARGIN 8

// the hovered tile's label with room for its shadow, nil when no label shows
- (NSString *)pillText
{
    if (dragging == nil && hover != nil && pressed == nil && controller->popup == nil && hide == 0)
        return hover->label;
    return nil;
}

- (NSRect)pillRect
{
    NSSize size = [[self pillText] sizeWithAttributes:labelAttributes()];
    NSRect icon = [self iconRectForItem:hover];
    CGFloat w = ceil(size.width) + 22 + 2 * PILL_MARGIN, h = ceil(size.height) + 9 + 2 * PILL_MARGIN;

    return NSMakeRect(floor(NSMidX(icon) - w / 2), floor(NSMaxY(icon) + 10 - PILL_MARGIN), w, h);
}

// the icon rectangle as it is drawn: a pressed tile sinks a little
- (NSRect)drawnRectForItem:(IDItem *)item
{
    NSRect r = [self iconRectForItem:item];

    return item == pressed ? NSInsetRect(r, item->size * 0.04, item->size * 0.04) : r;
}

// the glass and the tiles into the window-sized canvas, then onto the screen as one bitmap
- (void)drawGlass:(NSRect)bar
{
    CGFloat scale = [self pixelScale];
    NSRect bounds = [self bounds];
    int w = (int)ceil(NSWidth(bounds) * scale), h = (int)ceil(NSHeight(bounds) * scale);
    IDGlassShape shape;
    int x0, y0, x1, y1;
    NSBitmapImageRep *rep;
    unsigned char *plane;
    NSRect clip;
    double tg;

    if (back.px == NULL || w <= 0 || h <= 0)
        return;
    if (canvas.w != w || canvas.h != h) {
        free(canvas.px);
        canvas.w = w;
        canvas.h = h;
        canvas.stride = w * 4;
        canvas.px = calloc((size_t)canvas.stride, (size_t)h);
        free(base.px);
        base = canvas;
        base.px = malloc((size_t)canvas.stride * h);
        baseKey[0] = -1;
    }
    clip = NSInsetRect(NSOffsetRect(bar, 0, -ID_SHADOW_FALL), -ID_SHADOW_SPREAD - 2, -ID_SHADOW_SPREAD - 2);
    // over a picture the whole view is one bitmap, the picture included
    if (under.px != NULL && under.w == w && under.h == h)
        clip = bounds;
    for (IDItem *item in items) {
        if (item->kind != IDItemSeparator && item != dragging)
            clip = NSUnionRect(clip, NSInsetRect([self drawnRectForItem:item], -1, -1));
    }
    if ([self pillText] != nil)
        clip = NSUnionRect(clip, [self pillRect]);
    clip = NSIntersectionRect(clip, bounds);
    if (NSIsEmptyRect(clip))
        return;
    x0 = (int)floor(NSMinX(clip) * scale);
    x1 = (int)ceil(NSMaxX(clip) * scale);
    y0 = (int)floor((NSHeight(bounds) - NSMaxY(clip)) * scale);
    y1 = (int)ceil((NSHeight(bounds) - NSMinY(clip)) * scale);
    x0 = MAX(x0, 0), y0 = MAX(y0, 0), x1 = MIN(x1, w), y1 = MIN(y1, h);
    tg = now_ms();
    for (int y = y0; y < y1; y++)
        memset(canvas.px + (size_t)y * canvas.stride + 4 * x0, 0, (size_t)(x1 - x0) * 4);

    shape.x = NSMinX(bar) * scale;
    shape.y = (NSHeight(bounds) - NSMaxY(bar)) * scale;
    shape.w = NSWidth(bar) * scale;
    shape.h = NSHeight(bar) * scale;
    shape.radius = MIN(barHeight * 0.36, 26) * scale;
    shape.bezel = MIN(barHeight * 0.32, 18) * scale;
    shape.refraction = (6 + 16 * settings.glass) * scale;
    shape.specular = 0.45 + 0.55 * settings.glass;
    shape.saturation = 1.5;
    shape.shadow = dark ? 0.42 : 0.26;
    shape.shadowSpread = ID_SHADOW_SPREAD * scale;
    shape.shadowOffset = ID_SHADOW_FALL * scale;
    if (dark) {
        shape.tint = 0.34;
        shape.tintR = 0.09, shape.tintG = 0.09, shape.tintB = 0.11;
    } else {
        shape.tint = 0.16;
        shape.tintR = 1, shape.tintG = 1, shape.tintB = 1;
    }
    {
        float key[5] = { shape.y, shape.h, dark, settings.glass, w };

        if (memcmp(key, baseKey, sizeof(key)) != 0) {
            IDGlassBase(&base, &back, (float)(backScale / scale), &shape);
            memcpy(baseKey, key, sizeof(key));
        }
    }
    IDGlassRender(&canvas, &base, &shape);

    for (IDItem *item in items) {
        NSRect r;

        if (item->kind == IDItemSeparator || item == dragging)
            continue;
        [item makeLevels];
        r = [self drawnRectForItem:item];
        IDBlitIcon(&canvas, item->levels, item->levelCount, NSMinX(r) * scale, (NSHeight(bounds) - NSMaxY(r)) * scale,
                   NSWidth(r) * scale, item == pressed ? 0.8 : 1);
        if (item->badge != nil) {
            NSRect b = NSMakeRect(NSMaxX(r) - r.size.width * 0.52, NSMinY(r) + r.size.height * 0.02, r.size.width * 0.5, r.size.height * 0.5);

            [item makeBadgeLevels];
            IDBlitIcon(&canvas, item->badgeLevels, item->badgeLevelCount, NSMinX(b) * scale, (NSHeight(bounds) - NSMaxY(b)) * scale,
                       NSWidth(b) * scale, 1);
        }
    }

    // the label: drawn by AppKit only when it changes, copied every frame
    if ([self pillText] != nil) {
        NSString *text = [self pillText];
        NSRect r = [self pillRect];

        if (pill.px == NULL || ![text isEqualToString:pillText] || pillDark != dark || pillScale != scale) {
            free(pill.px);
            pill = IDRenderPixels(r.size, scale, ^{
                IDDrawPill(text, NSMakePoint(NSWidth(r) / 2, PILL_MARGIN));
            });
            [pillText release];
            pillText = [text copy];
            pillDark = dark;
            pillScale = scale;
        }
        IDBlitPixels(&canvas, &pill, (int)round(NSMinX(r) * scale), (int)round((NSHeight(bounds) - NSMaxY(r)) * scale));
    }

    if (under.px != NULL && under.w == w && under.h == h)
        IDPutUnder(&canvas, &under, x0, y0, x1, y1);
    profile[4] += now_ms() - tg;
    plane = canvas.px + (size_t)y0 * canvas.stride + 4 * x0;
    rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:&plane pixelsWide:x1 - x0 pixelsHigh:y1 - y0
                                               bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                                              colorSpaceName:NSDeviceRGBColorSpace bitmapFormat:0
                                                 bytesPerRow:canvas.stride bitsPerPixel:32];
    [rep setSize:NSMakeSize((x1 - x0) / scale, (y1 - y0) / scale)];
    // the area was cleared, so the canvas replaces it outright
    [[NSGraphicsContext currentContext] setCompositingOperation:NSCompositeCopy];
    [rep drawInRect:NSMakeRect(x0 / scale, NSHeight(bounds) - y1 / scale, (x1 - x0) / scale, (y1 - y0) / scale)];
    [[NSGraphicsContext currentContext] setCompositingOperation:NSCompositeSourceOver];
    [rep release];
}

- (void)drawRunningDot:(NSRect)icon
{
    NSRect dot = NSMakeRect(floor(NSMidX(icon)) - 2, [self barY] + 3, 4, 4);

    [[NSColor colorWithCalibratedWhite:dark ? 1 : 0 alpha:0.12] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(dot, -2, -2)] fill];
    [[NSColor colorWithCalibratedWhite:dark ? 1 : 0.08 alpha:dark ? 0.9 : 0.8] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
}

- (void)drawCount:(NSUInteger)count onIcon:(NSRect)icon
{
    NSString *text = count > 99 ? @"99+" : [NSString stringWithFormat:@"%lu", (unsigned long)count];
    NSFont *font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    NSDictionary *attributes = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: [NSColor whiteColor] };
    NSSize size = [text sizeWithAttributes:attributes];
    CGFloat h = 18, w = MAX(h, ceil(size.width) + 10);
    NSRect badge = NSMakeRect(NSMaxX(icon) - w + 4, NSMaxY(icon) - h + 2, w, h);

    IDDrawShadow(badge, h / 2, 3, 0.3);
    [[NSColor colorWithCalibratedRed:0.95 green:0.27 blue:0.23 alpha:1] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:badge xRadius:h / 2 yRadius:h / 2] fill];
    [text drawAtPoint:NSMakePoint(NSMidX(badge) - size.width / 2, NSMidY(badge) - size.height / 2) withAttributes:attributes];
}

- (void)drawRect:(NSRect)dirty
{
    NSRect bar = [self barRect];
    NSGraphicsContext *context = [NSGraphicsContext currentContext];
    double t0 = now_ms(), t1, t2, t3;

    // over a picture the glass's bitmap covers the whole view
    if (under.px == NULL) {
        [[NSColor clearColor] setFill];
        NSRectFill(dirty);
    }
    if (hide >= 1)
        return;
    dark = [[NSAppearance currentDrawingAppearance] _isDark];
    [context setImageInterpolation:NSImageInterpolationHigh];

    t1 = now_ms();
    [self drawGlass:bar];
    t2 = now_ms();

    for (IDItem *item in items) {
        NSRect r = [self iconRectForItem:item];

        if (item->kind == IDItemSeparator) {
            CGFloat x = floor(NSMidX(r)) + 0.5;
            NSBezierPath *line = [NSBezierPath bezierPath];

            [line moveToPoint:NSMakePoint(x, NSMinY(bar) + 10)];
            [line lineToPoint:NSMakePoint(x, NSMaxY(bar) - 10)];
            [line setLineWidth:1];
            [[NSColor colorWithCalibratedWhite:dark ? 1 : 0 alpha:dark ? 0.22 : 0.16] setStroke];
            [line stroke];
            continue;
        }
        if (item == dragging)
            continue;
        r = [self drawnRectForItem:item];
        if (item->kind == IDItemTrash && item->count > 0)
            [self drawCount:item->count onIcon:r];
        if (item->running && settings.indicators)
            [self drawRunningDot:r];
    }

    t3 = now_ms();
    if (getenv("ID_PROFILE") != NULL) {
        profile[0] += t1 - t0;
        profile[1] += t2 - t1;
        profile[2] += t3 - t2;
        if (++profileFrames == 10) {
            fprintf(stderr, "Dock: frame ms: clear %.1f glass+tiles %.1f (computing %.1f) marks %.1f, since last report %.0f ms\n",
                    profile[0] / 10, profile[1] / 10, profile[4] / 10, profile[2] / 10, t3 - profile[3]);
            profile[0] = profile[1] = profile[2] = profile[4] = 0;
            profile[3] = t3;
            profileFrames = 0;
        }
    }
    if (dragging != nil) {
        CGFloat s = settings.tile * 1.08;
        NSRect r = NSMakeRect(dragX - s / 2, dragY - s / 2, s, s);

        r.origin.y = MIN(r.origin.y, NSHeight([self bounds]) - s - 2);
        [dragging->icon drawInRect:r fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:dragRemoves ? 0.45 : 0.92];
        if (dragRemoves)
            IDDrawPill(L("Remove"), NSMakePoint(NSMidX(r), MIN(NSMaxY(r) + 6, NSHeight([self bounds]) - 30)));
    }
}

@end

@implementation IDInputView

- (BOOL)acceptsFirstMouse:(NSEvent *)event
{
    return YES;
}

- (BOOL)isOpaque
{
    return NO;
}

- (void)drawRect:(NSRect)dirty
{
    [[NSColor clearColor] setFill];
    NSRectFill([self bounds]);
}

- (void)resetTracking
{
    if (tracking != 0)
        [self removeTrackingRect:tracking];
    tracking = [self addTrackingRect:[self bounds] owner:self userData:NULL assumeInside:NO];
}

// the overlay is centred over this window, both hang from the same screen edge
- (NSPoint)overlayPoint:(NSEvent *)event
{
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    NSRect mine = [[self window] frame], theirs = [controller->overlay frame];

    return NSMakePoint(p.x + NSMinX(mine) - NSMinX(theirs), p.y + NSMinY(mine) - NSMinY(theirs));
}

- (void)mouseEntered:(NSEvent *)event
{
    [controller pointerEntered];
}

- (void)mouseExited:(NSEvent *)event
{
    [controller pointerExited];
}

- (void)mouseMoved:(NSEvent *)event
{
    [controller pointerMovedTo:[self overlayPoint:event]];
}

- (void)mouseDown:(NSEvent *)event
{
    if ([event modifierFlags] & NSControlKeyMask)
        [controller rightClickAt:[self overlayPoint:event]];
    else
        [controller pressedAt:[self overlayPoint:event]];
}

- (void)mouseDragged:(NSEvent *)event
{
    [controller draggedTo:[self overlayPoint:event]];
}

- (void)mouseUp:(NSEvent *)event
{
    [controller releasedAt:[self overlayPoint:event]];
}

- (void)rightMouseDown:(NSEvent *)event
{
    [controller rightClickAt:[self overlayPoint:event]];
}

@end
