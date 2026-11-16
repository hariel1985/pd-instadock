/*
 * IDSwitcher.m - the application switcher, macOS's Command-Tab.
 *
 * Copyright (c) 2026 The pd-instadock authors
 *
 * SPDX-License-Identifier: MPL-2.0 OR BSD-2-Clause
 */

/*
 * The compositor's window manager (pdwm) owns the keys: Command-Tab starts a
 * switch and takes the keyboard until Command is let go. It posts what happens
 * as the state of one Darwin notification, so a Dock that wakes late still
 * reads the latest of it: the session, the steps taken (Tab forward, Shift-Tab
 * back), what is asked (browse, switch, cancel, quit, hide) and a count of
 * the Q and H presses. The Dock keeps the order the apps were last used in
 * from the compositor's focus notification, draws the switcher, and switches
 * through NSRunningApplication, which asks the chosen app's own AppKit to come
 * forward, hide or quit.
 */

#import "IDDock.h"
#include <dispatch/dispatch.h>
#include <limits.h>

#if __has_include(<notify.h>)
#include <notify.h>
#else
#define NOTIFY_STATUS_OK 0
uint32_t notify_register_dispatch(const char *name, int *out_token, dispatch_queue_t queue, void (^handler)(int token));
uint32_t notify_register_check(const char *name, int *out_token);
uint32_t notify_get_state(int token, uint64_t *state64);
#endif

#define FOCUS_NOTIFICATION "org.puredarwin.wm.focus"
#define SWITCHER_NOTIFICATION "org.puredarwin.switcher"

enum {
    SwitcherBrowse = 1,
    SwitcherCommit = 2,
    SwitcherCancel = 3,
    SwitcherQuit = 4,
    SwitcherHide = 5,
};

// sizes in points, at their largest; a long row is made smaller to fit the screen
#define SW_ICON 112
#define SW_CELL 132
#define SW_PAD 18
#define SW_LABEL 34
#define SW_MARGIN 18 // room around the panel for its shadow and the compositor's blur
#define SW_RADIUS 24
// a quick Command-Tab switches without the switcher flashing up
#define SW_SHOW_DELAY 0.14

void IDDrawShadow(NSRect r, CGFloat radius, CGFloat spread, CGFloat strength);

@interface IDSwitcher ()
- (NSInteger)indexAt:(NSPoint)p;
- (void)pointerAt:(NSPoint)p;
- (void)clickAt:(NSPoint)p;
@end

@interface IDSwitcherView : NSView {
@public
    IDSwitcher *switcher;
}
@end

@interface IDSwitcherWindow : NSWindow
@end

@implementation IDSwitcherWindow

// the keys stay with the compositor's grab, the app in front keeps its key window
- (BOOL)canBecomeKeyWindow
{
    return NO;
}

- (BOOL)canBecomeMainWindow
{
    return NO;
}

@end

static BOOL isDark(void)
{
    return [[NSAppearance currentDrawingAppearance] _isDark];
}

@implementation IDSwitcherView

- (BOOL)isFlipped
{
    return NO;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event
{
    return YES;
}

- (void)drawRect:(NSRect)dirty
{
    IDSwitcher *s = switcher;
    NSRect bounds = [self bounds], panel = NSInsetRect(bounds, SW_MARGIN, SW_MARGIN);
    BOOL dark = isDark();
    NSUInteger n = [s->apps count];
    CGFloat cell = s->cell, icon = cell * SW_ICON / SW_CELL;

    [[NSColor clearColor] setFill];
    NSRectFill(bounds);
    IDDrawShadow(panel, SW_RADIUS, 16, 0.38);
    [(dark ? [NSColor colorWithCalibratedRed:0.13 green:0.13 blue:0.15 alpha:0.90] : [NSColor colorWithCalibratedWhite:0.97 alpha:0.92]) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:panel xRadius:SW_RADIUS yRadius:SW_RADIUS] fill];
    // light along the edge, the same glass as the dock's popups
    [[NSColor colorWithCalibratedWhite:1 alpha:dark ? 0.16 : 0.7] setStroke];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(panel, 0.5, 0.5) xRadius:SW_RADIUS - 0.5 yRadius:SW_RADIUS - 0.5] stroke];

    for (NSUInteger i = 0; i < n; i++) {
        NSRect c = [s cellRect:i];
        NSImage *image = [s->controller iconForPath:s->apps[i]];
        NSRect r = NSMakeRect(floor(NSMidX(c) - icon / 2), floor(NSMidY(c) - icon / 2), icon, icon);

        if ((NSInteger)i == s->selected) {
            [[NSColor colorWithCalibratedWhite:dark ? 1 : 0 alpha:dark ? 0.20 : 0.13] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(c, 2, 2) xRadius:cell * 0.17 yRadius:cell * 0.17] fill];
        }
        [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
        [image drawInRect:r fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1];
    }
    if (s->selected >= 0 && (NSUInteger)s->selected < n) {
        NSRect c = [s cellRect:s->selected];
        NSDictionary *attributes = @{ NSFontAttributeName: [NSFont systemFontOfSize:15 weight:NSFontWeightMedium],
                                      NSForegroundColorAttributeName: dark ? [NSColor colorWithCalibratedWhite:0.96 alpha:1]
                                                                           : [NSColor colorWithCalibratedWhite:0.08 alpha:1] };
        NSString *name = [s->controller labelForPath:s->apps[s->selected]];
        NSSize size = [name sizeWithAttributes:attributes];
        CGFloat x = NSMidX(c) - size.width / 2;

        // the name sits under its icon, kept inside the panel
        x = MAX(NSMinX(panel) + 12, MIN(x, NSMaxX(panel) - 12 - size.width));
        [name drawAtPoint:NSMakePoint(floor(x), floor(NSMinY(panel) + (SW_PAD + SW_LABEL - size.height) / 2)) withAttributes:attributes];
    }
}

- (void)mouseMoved:(NSEvent *)event
{
    [switcher pointerAt:[self convertPoint:[event locationInWindow] fromView:nil]];
}

- (void)mouseDragged:(NSEvent *)event
{
    [self mouseMoved:event];
}

- (void)mouseDown:(NSEvent *)event
{
    [switcher clickAt:[self convertPoint:[event locationInWindow] fromView:nil]];
}

@end

@implementation IDSwitcher

- (instancetype)initWithController:(IDController *)owner
{
    int token;
    uint64_t pid = 0;

    if ((self = [super init]) == nil)
        return nil;
    controller = owner;
    recent = [[NSMutableArray alloc] init];
    selected = -1;
    if (notify_register_dispatch(FOCUS_NOTIFICATION, &token, dispatch_get_main_queue(), ^(int t) {
            uint64_t state = 0;

            notify_get_state(t, &state);
            [self focused:(pid_t)state];
        }) == NOTIFY_STATUS_OK) {
        // the app in front before the Dock started
        notify_get_state(token, &pid);
        [self focused:(pid_t)pid];
    }
    notify_register_dispatch(SWITCHER_NOTIFICATION, &token, dispatch_get_main_queue(), ^(int t) {
        uint64_t state = 0;

        notify_get_state(t, &state);
        [self switcherState:state];
    });
    return self;
}

#pragma mark the order apps were used in

- (void)used:(NSString *)bundle
{
    if (bundle == nil)
        return;
    [recent removeObject:bundle];
    [recent insertObject:bundle atIndex:0];
}

- (void)focused:(pid_t)pid
{
    if (pid > 0)
        [self used:[controller bundleForPid:pid]];
}

// the lowest pid of an app's processes, the one that started first
static int firstPid(NSArray *pids)
{
    int low = INT_MAX;

    for (NSNumber *pid in pids)
        low = MIN(low, [pid intValue]);
    return low;
}

// the running apps, the most recently used first, then the others in the order they started
- (NSArray *)orderedApps
{
    NSDictionary *running = [controller runningBundles];
    NSMutableArray *result = [NSMutableArray array];
    NSArray *rest;

    // apps that quit leave the order
    for (NSString *bundle in [[recent copy] autorelease]) {
        if (running[bundle] == nil)
            [recent removeObject:bundle];
    }
    [result addObjectsFromArray:recent];
    rest = [[running allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        int x = firstPid(running[a]), y = firstPid(running[b]);

        return x < y ? NSOrderedAscending : x > y ? NSOrderedDescending : NSOrderedSame;
    }];
    for (NSString *bundle in rest) {
        if (![result containsObject:bundle])
            [result addObject:bundle];
    }
    return result;
}

- (NSArray *)applicationsOf:(NSString *)bundle
{
    NSMutableArray *result = [NSMutableArray array];

    for (NSNumber *pid in [controller runningBundles][bundle]) {
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:[pid intValue]];

        if (app != nil)
            [result addObject:app];
    }
    return result;
}

#pragma mark the session

static NSInteger wrap(NSInteger i, NSInteger n)
{
    return n > 0 ? ((i % n) + n) % n : -1;
}

- (void)finish
{
    done = session;
    [showTimer invalidate];
    showTimer = nil;
    [refreshTimer invalidate];
    refreshTimer = nil;
    if (window != nil) {
        [window orderOut:nil];
        [window close];
        [window autorelease];
        window = nil;
    }
    // the window owned the view
    view = nil;
    [screenUsed release];
    screenUsed = nil;
    [apps release];
    apps = nil;
    selected = -1;
}

- (void)switchTo:(NSString *)bundle
{
    // as from the Dock: the app comes forward with its windows, a hidden one shows them again
    for (NSRunningApplication *app in [self applicationsOf:bundle])
        [app activateWithOptions:NSApplicationActivateAllWindows];
    [self used:bundle];
}

- (void)switcherState:(uint64_t)state
{
    uint32_t id = (uint32_t)(state >> 32);
    unsigned actions = (unsigned)(state >> 24) & 0xff, phase = (unsigned)(state >> 16) & 0xff;
    NSInteger n;

    steps = (int16_t)(state & 0xffff);
    if (id == 0 || id == done)
        return;
    if (id != session) {
        [self finish];
        session = id;
        offset = 0;
        lastActions = 0;
        apps = [[self orderedApps] retain];
    }
    n = (NSInteger)[apps count];
    if (n == 0) {
        [self finish];
        return;
    }
    selected = wrap(steps + offset, n);
    switch (phase) {
    case SwitcherCommit:
        [self switchTo:apps[selected]];
        [self finish];
        return;
    case SwitcherCancel:
        [self finish];
        return;
    case SwitcherQuit:
    case SwitcherHide:
        if (actions != lastActions) {
            lastActions = actions;
            for (NSRunningApplication *app in [self applicationsOf:apps[selected]]) {
                if (phase == SwitcherQuit)
                    [app terminate];
                else
                    [app hide];
            }
        }
        [self show:nil];
        break;
    default:
        if (window == nil && showTimer == nil)
            showTimer = [NSTimer scheduledTimerWithTimeInterval:SW_SHOW_DELAY target:self selector:@selector(show:)
                                                       userInfo:nil repeats:NO];
        break;
    }
    [view setNeedsDisplay:YES];
}

// an app that quit leaves the row, the one chosen stays chosen
- (void)refresh:(NSTimer *)timer
{
    NSArray *now = [self orderedApps];
    NSString *chosen = selected >= 0 && (NSUInteger)selected < [apps count] ? apps[selected] : nil;
    NSInteger index;

    if ([now isEqualToArray:apps])
        return;
    if ([now count] == 0) {
        [self finish];
        return;
    }
    index = chosen ? (NSInteger)[now indexOfObject:chosen] : NSNotFound;
    if (index == NSNotFound)
        index = MIN(MAX(selected, 0), (NSInteger)[now count] - 1);
    [apps release];
    apps = [now retain];
    selected = index;
    offset = index - steps;
    [self layout];
}

#pragma mark the window

- (NSScreen *)pointerScreen
{
    NSPoint p = [NSEvent mouseLocation];

    for (NSScreen *screen in [NSScreen screens]) {
        if (NSPointInRect(p, [screen frame]))
            return screen;
    }
    return [NSScreen mainScreen];
}

- (NSRect)cellRect:(NSUInteger)i
{
    return NSMakeRect(SW_MARGIN + SW_PAD + i * cell, SW_MARGIN + SW_PAD + SW_LABEL, cell, cell);
}

- (void)layout
{
    NSRect screen = [screenUsed frame], frame;
    NSUInteger n = [apps count];
    CGFloat fit = (NSWidth(screen) - 2 * (SW_MARGIN + SW_PAD) - 60) / MAX(n, 1);

    cell = floor(MAX(48, MIN(SW_CELL, fit)));
    frame.size = NSMakeSize(n * cell + 2 * (SW_MARGIN + SW_PAD), cell + SW_LABEL + 2 * SW_PAD + 2 * SW_MARGIN);
    frame.origin = NSMakePoint(floor(NSMidX(screen) - NSWidth(frame) / 2), floor(NSMidY(screen) - NSHeight(frame) / 2));
    if (window != nil && !NSEqualRects([window frame], frame)) {
        // a window that changes size is made anew, a resized layer surface keeps its old place for a while
        [window orderOut:nil];
        [window close];
        [window autorelease];
        window = nil;
        view = nil;
    }
    if (window == nil) {
        window = [[IDSwitcherWindow alloc] initWithContentRect:frame styleMask:NSBorderlessWindowMask
                                                       backing:NSBackingStoreBuffered defer:NO];
        [window setReleasedWhenClosed:NO];
        [window setLevel:NSPopUpMenuWindowLevel];
        [window setOpaque:NO];
        [window setBackgroundColor:[NSColor clearColor]];
        [window setAcceptsMouseMovedEvents:YES];
        [window _setBackgroundBlurInset:SW_MARGIN radius:SW_RADIUS];
        view = [[[IDSwitcherView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(frame), NSHeight(frame))] autorelease];
        view->switcher = self;
        [window setContentView:view];
        [window orderFront:nil];
    }
    [view setNeedsDisplay:YES];
}

- (void)show:(NSTimer *)timer
{
    [showTimer invalidate];
    showTimer = nil;
    if (apps == nil)
        return;
    if (window == nil) {
        [screenUsed release];
        screenUsed = [[self pointerScreen] retain];
    }
    [self layout];
    if (refreshTimer == nil)
        refreshTimer = [NSTimer scheduledTimerWithTimeInterval:0.4 target:self selector:@selector(refresh:) userInfo:nil repeats:YES];
}

- (NSInteger)indexAt:(NSPoint)p
{
    for (NSUInteger i = 0; i < [apps count]; i++) {
        if (NSPointInRect(p, [self cellRect:i]))
            return (NSInteger)i;
    }
    return -1;
}

// the pointer chooses too, and Tab goes on from what it chose
- (void)pointerAt:(NSPoint)p
{
    NSInteger index = [self indexAt:p];

    if (index < 0 || index == selected)
        return;
    selected = index;
    offset = index - steps;
    [view setNeedsDisplay:YES];
}

- (void)clickAt:(NSPoint)p
{
    NSInteger index = [self indexAt:p];

    if (index < 0)
        return;
    [self switchTo:apps[index]];
    [self finish];
}

@end
