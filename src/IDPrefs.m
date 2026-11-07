/*
 * IDPrefs.m - the Dock settings window.
 *
 * Copyright (c) 2026 The pd-instadock authors
 *
 * SPDX-License-Identifier: MPL-2.0 OR BSD-2-Clause
 */

#import "IDDock.h"

#define PREF_W 560
#define PREF_SIDE 28
#define PREF_ROW 30
#define PREF_HEADER 38
#define PREF_LABEL_W 190

// section headings and slider labels are drawn here, the controls are subviews
@interface IDPrefsView : NSView {
@public
    NSMutableArray *texts; // @[ text, NSValue point, NSNumber heading ]
}
@end

@implementation IDPrefsView

- (BOOL)isFlipped
{
    return YES;
}

- (void)dealloc
{
    [texts release];
    [super dealloc];
}

- (void)drawRect:(NSRect)dirty
{
    if (getenv("ID_PREFS") != NULL)
        NSLog(@"Dock: settings draw %@ in %@", NSStringFromRect(dirty), NSStringFromRect([self bounds]));
    BOOL dark = [[NSAppearance currentDrawingAppearance] _isDark];
    NSColor *color = dark ? [NSColor colorWithCalibratedWhite:0.95 alpha:1] : [NSColor colorWithCalibratedWhite:0.1 alpha:1];

    [(dark ? [NSColor colorWithCalibratedWhite:0.14 alpha:1] : [NSColor colorWithCalibratedWhite:0.965 alpha:1]) setFill];
    NSRectFill([self bounds]);
    for (NSArray *t in texts) {
        BOOL heading = [t[2] boolValue];
        NSFont *font = [NSFont fontWithName:heading ? @"Inter-Medium" : @"Inter-Regular" size:heading ? 13.5 : 13]
                           ?: [NSFont systemFontOfSize:13];
        NSPoint p = [t[1] pointValue];

        if (heading) {
            [[NSColor colorWithCalibratedWhite:dark ? 1 : 0 alpha:0.1] setFill];
            NSRectFill(NSMakeRect(PREF_SIDE, p.y - 8, NSWidth([self bounds]) - 2 * PREF_SIDE, 1));
        }
        [t[0] drawAtPoint:p withAttributes:@{ NSFontAttributeName: font,
                                              NSForegroundColorAttributeName: heading ? color : [color colorWithAlphaComponent:0.8] }];
    }
}

@end

@implementation IDPrefsController

- (instancetype)initWithController:(IDController *)controller
{
    if ((self = [super init]) == nil)
        return nil;
    _controller = controller;
    _appButtons = [[NSMutableArray alloc] init];
    _stackButtons = [[NSMutableArray alloc] init];
    return self;
}

- (void)dealloc
{
    [_window release];
    [_appButtons release];
    [_stackButtons release];
    [super dealloc];
}

- (NSArray *)stackChoices
{
    NSString *home = NSHomeDirectory();

    return @[ @[ L("Applications"), @"/Applications" ], @[ L("Downloads"), [home stringByAppendingPathComponent:@"Downloads"] ],
              @[ L("Documents"), [home stringByAppendingPathComponent:@"Documents"] ],
              @[ L("Desktop"), [home stringByAppendingPathComponent:@"Desktop"] ], @[ L("Home"), home ] ];
}

- (void)text:(NSString *)text at:(NSPoint)p heading:(BOOL)heading in:(IDPrefsView *)view
{
    [view->texts addObject:@[ text, [NSValue valueWithPoint:p], @(heading) ]];
}

- (NSSlider *)sliderAt:(CGFloat)y min:(double)lo max:(double)hi action:(SEL)action in:(NSView *)view
{
    NSSlider *slider = [[[NSSlider alloc] initWithFrame:NSMakeRect(PREF_SIDE + PREF_LABEL_W, y, PREF_W - 2 * PREF_SIDE - PREF_LABEL_W, 24)] autorelease];

    [slider setMinValue:lo];
    [slider setMaxValue:hi];
    [slider setContinuous:YES];
    [slider setTarget:self];
    [slider setAction:action];
    [view addSubview:slider];
    return slider;
}

- (NSButton *)checkbox:(NSString *)title frame:(NSRect)frame action:(SEL)action in:(NSView *)view
{
    NSButton *button = [[[NSButton alloc] initWithFrame:frame] autorelease];

    [button setButtonType:NSSwitchButton];
    [button setTitle:title];
    [button setTarget:self];
    [button setAction:action];
    [view addSubview:button];
    return button;
}

- (void)build
{
    NSArray *apps = [_controller installedApps];
    NSArray *stacks = [self stackChoices];
    CGFloat y = 24, colW = (PREF_W - 2 * PREF_SIDE) / 2;
    NSUInteger rows = ([apps count] + 1) / 2;
    CGFloat height = 24 + PREF_HEADER + 4 * PREF_ROW + PREF_HEADER + 2 * PREF_ROW + PREF_HEADER + rows * PREF_ROW + PREF_HEADER +
                     ((([stacks count] + 1) / 2) * PREF_ROW) + 24;
    IDPrefsView *view = [[[IDPrefsView alloc] initWithFrame:NSMakeRect(0, 0, PREF_W, height)] autorelease];

    view->texts = [[NSMutableArray alloc] init];
    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, PREF_W, height)
                                          styleMask:NSTitledWindowMask | NSClosableWindowMask
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    [_window setTitle:L("Dock Settings")];
    [_window setReleasedWhenClosed:NO];
    [_window setDelegate:self];
    [_window setContentView:view];

    [self text:L("Appearance") at:NSMakePoint(PREF_SIDE, y) heading:YES in:view];
    y += PREF_HEADER - 8;
    [self text:L("Size") at:NSMakePoint(PREF_SIDE, y + 3) heading:NO in:view];
    _size = [self sliderAt:y min:32 max:72 action:@selector(sizeChanged:) in:view];
    y += PREF_ROW;
    _magnify = [self checkbox:L("Magnification") frame:NSMakeRect(PREF_SIDE - 2, y, PREF_LABEL_W, 24) action:@selector(magnifyChanged:) in:view];
    _magnified = [self sliderAt:y min:32 max:128 action:@selector(magnifiedChanged:) in:view];
    y += PREF_ROW;
    [self text:L("Liquid glass") at:NSMakePoint(PREF_SIDE, y + 3) heading:NO in:view];
    _glass = [self sliderAt:y min:0 max:100 action:@selector(glassChanged:) in:view];
    y += PREF_ROW + PREF_ROW;

    [self text:L("Behaviour") at:NSMakePoint(PREF_SIDE, y) heading:YES in:view];
    y += PREF_HEADER - 8;
    _autohide = [self checkbox:L("Automatically hide and show the Dock") frame:NSMakeRect(PREF_SIDE - 2, y, PREF_W - 2 * PREF_SIDE, 24)
                        action:@selector(autohideChanged:) in:view];
    y += PREF_ROW;
    _indicators = [self checkbox:L("Show indicators for open applications") frame:NSMakeRect(PREF_SIDE - 2, y, PREF_W - 2 * PREF_SIDE, 24)
                          action:@selector(indicatorsChanged:) in:view];
    y += PREF_ROW + 8;

    [self text:L("Applications in the Dock") at:NSMakePoint(PREF_SIDE, y) heading:YES in:view];
    y += PREF_HEADER - 8;
    for (NSUInteger i = 0; i < [apps count]; i++) {
        NSString *path = apps[i];
        NSString *name = [[NSBundle bundleWithPath:path] objectForInfoDictionaryKey:@"CFBundleName"] ?: [[path lastPathComponent] stringByDeletingPathExtension];
        NSButton *box;

        if ([[path lastPathComponent] isEqualToString:@"Finder.app"])
            name = L("Files");
        box = [self checkbox:name frame:NSMakeRect(PREF_SIDE - 2 + (i % 2) * colW, y + (i / 2) * PREF_ROW, colW - 8, 24)
                      action:@selector(appChanged:) in:view];
        [box setTag:(NSInteger)i];
        if (i == 0)
            [box setEnabled:NO];
        [_appButtons addObject:@[ box, path ]];
    }
    y += rows * PREF_ROW + 8;

    [self text:L("Folders (Stacks)") at:NSMakePoint(PREF_SIDE, y) heading:YES in:view];
    y += PREF_HEADER - 8;
    for (NSUInteger i = 0; i < [stacks count]; i++) {
        NSButton *box = [self checkbox:stacks[i][0] frame:NSMakeRect(PREF_SIDE - 2 + (i % 2) * colW, y + (i / 2) * PREF_ROW, colW - 8, 24)
                                action:@selector(stackChanged:) in:view];

        [_stackButtons addObject:@[ box, stacks[i][1] ]];
    }
    [_window center];
}

- (void)refresh
{
    IDSettings s = _controller->settings;
    NSArray *pinned = [_controller pinnedApps], *stacks = [_controller stacks];

    if (_window == nil)
        return;
    [_size setDoubleValue:s.tile];
    [_magnify setState:s.magnify ? NSOnState : NSOffState];
    [_magnified setMinValue:s.tile];
    [_magnified setDoubleValue:s.magnified];
    [_magnified setEnabled:s.magnify];
    [_glass setDoubleValue:s.glass * 100];
    [_autohide setState:s.autohide ? NSOnState : NSOffState];
    [_indicators setState:s.indicators ? NSOnState : NSOffState];
    for (NSArray *pair in _appButtons)
        [(NSButton *)pair[0] setState:[pinned containsObject:pair[1]] ? NSOnState : NSOffState];
    for (NSArray *pair in _stackButtons)
        [(NSButton *)pair[0] setState:[stacks containsObject:pair[1]] ? NSOnState : NSOffState];
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

- (void)sizeChanged:(NSSlider *)sender
{
    [self apply:@"TileSize" value:@(round([sender doubleValue]))];
}

- (void)magnifiedChanged:(NSSlider *)sender
{
    [self apply:@"MagnifiedSize" value:@(round([sender doubleValue]))];
}

- (void)magnifyChanged:(NSButton *)sender
{
    [self apply:@"Magnify" value:@([sender state] == NSOnState)];
}

- (void)glassChanged:(NSSlider *)sender
{
    [self apply:@"Glass" value:@(round([sender doubleValue]) / 100)];
}

- (void)autohideChanged:(NSButton *)sender
{
    [self apply:@"AutoHide" value:@([sender state] == NSOnState)];
}

- (void)indicatorsChanged:(NSButton *)sender
{
    [self apply:@"ShowIndicators" value:@([sender state] == NSOnState)];
}

- (void)appChanged:(NSButton *)sender
{
    NSMutableArray *pinned = [[[_controller pinnedApps] mutableCopy] autorelease];
    NSString *path = _appButtons[(NSUInteger)[sender tag]][1];

    if ([sender state] == NSOnState && ![pinned containsObject:path])
        [pinned addObject:path];
    else if ([sender state] != NSOnState)
        [pinned removeObject:path];
    [_controller setPinnedApps:pinned];
}

- (void)stackChanged:(NSButton *)sender
{
    NSMutableArray *stacks = [[[_controller stacks] mutableCopy] autorelease];

    // a new stack goes last, the others keep the order they were dragged into
    for (NSArray *pair in _stackButtons) {
        BOOL on = [(NSButton *)pair[0] state] == NSOnState;

        if (on && ![stacks containsObject:pair[1]]) {
            [[NSFileManager defaultManager] createDirectoryAtPath:pair[1] withIntermediateDirectories:YES attributes:nil error:NULL];
            [stacks addObject:pair[1]];
        } else if (!on) {
            [stacks removeObject:pair[1]];
        }
    }
    [_controller setStacks:stacks];
}

@end
