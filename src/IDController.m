/*
 * IDController.m - the dock's windows, its items, the running apps and the preferences.
 *
 * Copyright (c) 2026 The pd-instadock authors
 *
 * SPDX-License-Identifier: MPL-2.0 OR BSD-2-Clause
 */

#import "IDDock.h"
#include <math.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// libproc, which the SDK ships without its header
int proc_listallpids(void *buffer, int buffersize);
int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
#define ID_PIDPATH_MAX 4096

static NSString * const DesktopPictures = @"/System/Library/Desktop Pictures";
static NSString * const FinderPath = @"/System/Library/CoreServices/Finder.app";

IDPixels IDRenderPixels(NSSize points, CGFloat scale, void (^draw)(void))
{
    int w = (int)ceil(points.width * scale), h = (int)ceil(points.height * scale);
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h bitsPerSample:8
                                                                samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                                                                 colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:w * 4
                                                                   bitsPerPixel:32];
    NSAffineTransform *transform = [NSAffineTransform transform];
    IDPixels pixels = { w, h, w * 4, malloc((size_t)w * h * 4) };

    memset([rep bitmapData], 0, (size_t)w * h * 4);
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
    [transform scaleBy:scale];
    [transform concat];
    draw();
    [[NSGraphicsContext currentContext] flushGraphics];
    [NSGraphicsContext restoreGraphicsState];
    for (int y = 0; y < h; y++)
        memcpy(pixels.px + (size_t)y * pixels.stride, [rep bitmapData] + (size_t)y * [rep bytesPerRow], (size_t)w * 4);
    [rep release];
    return pixels;
}

NSString *IDLocalized(NSString *key)
{
    return [[NSBundle mainBundle] localizedStringForKey:key value:key table:nil];
}

static NSString *trashPath(void)
{
    return [NSHomeDirectory() stringByAppendingPathComponent:@".Trash"];
}

#pragma mark - items

@implementation IDItem

+ (IDItem *)itemWithKind:(IDItemKind)kind path:(NSString *)path
{
    IDItem *item = [[[IDItem alloc] init] autorelease];

    item->kind = kind;
    item->path = [path copy];
    return item;
}

- (void)dealloc
{
    for (int i = 0; i < levelCount; i++)
        free(levels[i].px);
    [self forgetBadgeLevels];
    [path release];
    [label release];
    [icon release];
    [badge release];
    [pids release];
    [super dealloc];
}

// an image drawn once into a 256 pixel bitmap, then halved twice
static int makeLevels(NSImage *image, IDPixels levels[3])
{
    if (image == nil)
        return 0;
    levels[0] = IDRenderPixels(NSMakeSize(256, 256), 1, ^{
        [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
        [image drawInRect:NSMakeRect(0, 0, 256, 256) fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1];
    });
    levels[1] = IDHalve(&levels[0]);
    levels[2] = IDHalve(&levels[1]);
    return 3;
}

- (void)makeLevels
{
    if (levelCount == 0)
        levelCount = makeLevels(icon, levels);
}

- (void)makeBadgeLevels
{
    if (badgeLevelCount == 0)
        badgeLevelCount = makeLevels(badge, badgeLevels);
}

- (void)forgetBadgeLevels
{
    for (int i = 0; i < badgeLevelCount; i++)
        free(badgeLevels[i].px);
    badgeLevelCount = 0;
}

- (NSString *)bundleExecutable
{
    return [[NSBundle bundleWithPath:path] executablePath];
}

@end

#pragma mark - the desktop picture

// fills the screen with the picture, cropped to keep its aspect like macOS's fill mode
@interface IDDesktopView : NSView {
@public
    NSImage *picture;
}
@end

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

- (void)drawRect:(NSRect)dirty
{
    NSRect bounds = [self bounds];

    [[NSColor colorWithCalibratedRed:0.85 green:0.47 blue:0.35 alpha:1] setFill];
    NSRectFill(bounds);
    if (picture == nil || [picture size].width <= 0 || [picture size].height <= 0)
        return;
    [picture drawInRect:bounds fromRect:IDPictureRect(picture, bounds, bounds) operation:NSCompositeCopy fraction:1];
}

@end

#pragma mark - the controller

@implementation IDController

#pragma mark preferences

- (id)pref:(NSString *)key
{
    return [(id)CFPreferencesCopyAppValue((CFStringRef)key, IDDomain) autorelease];
}

- (void)writeSetting:(NSString *)key value:(id)value
{
    CFPreferencesSetAppValue((CFStringRef)key, (CFPropertyListRef)value, IDDomain);
    CFPreferencesAppSynchronize(IDDomain);
}

static CGFloat number(id value, CGFloat fallback, CGFloat lo, CGFloat hi)
{
    if (![value respondsToSelector:@selector(doubleValue)])
        return fallback;
    return MIN(MAX([value doubleValue], lo), hi);
}

static BOOL flag(id value, BOOL fallback)
{
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

- (IDSettings)readSettings
{
    IDSettings s;

    CFPreferencesAppSynchronize(IDDomain);
    s.tile = round(number([self pref:@"TileSize"], 52, 32, 72));
    s.magnified = round(number([self pref:@"MagnifiedSize"], 84, s.tile, 128));
    s.magnify = flag([self pref:@"Magnify"], YES);
    s.autohide = flag([self pref:@"AutoHide"], NO);
    s.indicators = flag([self pref:@"ShowIndicators"], YES);
    s.glass = number([self pref:@"Glass"], 0.7, 0, 1);
    return s;
}

- (NSArray *)stringsFor:(NSString *)key
{
    id value = [self pref:key];
    NSMutableArray *result = [NSMutableArray array];

    if (![value isKindOfClass:[NSArray class]])
        return nil;
    for (id entry in value) {
        if ([entry isKindOfClass:[NSString class]] && ![result containsObject:entry])
            [result addObject:entry];
    }
    return result;
}

- (NSArray *)pinnedApps
{
    NSArray *apps = [self stringsFor:@"PersistentApps"];
    NSFileManager *fm = [NSFileManager defaultManager];

    if (apps == nil) {
        NSMutableArray *defaults = [NSMutableArray array];

        for (NSString *app in @[ FinderPath, @"/Applications/Prizma.app", @"/Applications/Text Editor.app",
                                 @"/Applications/Calculator.app", @"/Applications/Image Viewer.app", @"/Applications/Settings.app",
                                 @"/Applications/Utilities/Terminal.app", @"/Applications/Utilities/Activity.app" ]) {
            if ([fm fileExistsAtPath:app])
                [defaults addObject:app];
        }
        apps = defaults;
    }
    // Finder always leads, as on macOS
    if (![apps containsObject:FinderPath] || ![[apps firstObject] isEqualToString:FinderPath]) {
        NSMutableArray *fixed = [[apps mutableCopy] autorelease];

        [fixed removeObject:FinderPath];
        [fixed insertObject:FinderPath atIndex:0];
        apps = fixed;
    }
    return apps;
}

- (void)setPinnedApps:(NSArray *)apps
{
    [self writeSetting:@"PersistentApps" value:apps];
    [self itemsChanged];
}

- (NSArray *)stacks
{
    NSArray *stacks = [self stringsFor:@"PersistentStacks"];

    if (stacks == nil) {
        NSMutableArray *defaults = [NSMutableArray arrayWithObject:@"/Applications"];
        NSString *downloads = [NSHomeDirectory() stringByAppendingPathComponent:@"Downloads"];
        NSString *documents = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];

        if ([[NSFileManager defaultManager] fileExistsAtPath:downloads])
            [defaults addObject:downloads];
        else if ([[NSFileManager defaultManager] fileExistsAtPath:documents])
            [defaults addObject:documents];
        stacks = defaults;
    }
    return stacks;
}

- (void)setStacks:(NSArray *)stacks
{
    [self writeSetting:@"PersistentStacks" value:stacks];
    [self itemsChanged];
}

#pragma mark icons

- (NSImage *)resourceIcon:(NSString *)name
{
    NSString *png = [[NSBundle mainBundle] pathForResource:name ofType:@"png"];

    return png ? [[[NSImage alloc] initWithContentsOfFile:png] autorelease] : nil;
}

// HSB to a colour by hand, PD's colorWithCalibratedHue: ignores saturation and brightness
static NSColor *hsb(CGFloat h, CGFloat s, CGFloat v)
{
    CGFloat c = v * s, x = c * (1 - fabs(fmod(h * 6, 2) - 1)), m = v - c, r = 0, g = 0, b = 0;
    int sector = (int)(h * 6) % 6;

    switch (sector) {
    case 0: r = c, g = x; break;
    case 1: r = x, g = c; break;
    case 2: g = c, b = x; break;
    case 3: g = x, b = c; break;
    case 4: r = x, b = c; break;
    default: r = c, b = x; break;
    }
    return [NSColor colorWithCalibratedRed:r + m green:g + m blue:b + m alpha:1];
}

// an app without an icon gets a tile of its own colour with its initial
- (NSImage *)letterIcon:(NSString *)name
{
    NSBitmapImageRep *rep = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:256 pixelsHigh:256 bitsPerSample:8
                                                                samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                                                                 colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:256 * 4
                                                                   bitsPerPixel:32] autorelease];
    NSImage *image = [[[NSImage alloc] initWithSize:NSMakeSize(256, 256)] autorelease];
    NSString *letter = [name length] ? [[name substringToIndex:1] uppercaseString] : @"?";
    NSFont *font = [NSFont systemFontOfSize:136 weight:NSFontWeightMedium];
    NSDictionary *attributes = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: [NSColor whiteColor] };
    CGFloat hue = (CGFloat)([name hash] % 360) / 360;
    NSRect tile = NSMakeRect(20, 20, 216, 216);
    NSSize size;

    // drawn into a bitmap: an image drawn with lockFocus crashes Onyx2D's resampling
    memset([rep bitmapData], 0, 256 * 256 * 4);
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
    [hsb(hue, 0.62, 0.80) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:tile xRadius:50 yRadius:50] fill];
    [hsb(hue, 0.45, 0.95) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(20, 120, 216, 116) xRadius:50 yRadius:50] fill];
    NSRectFill(NSMakeRect(20, 120, 216, 40));
    [[NSColor colorWithCalibratedWhite:1 alpha:0.35] setStroke];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(tile, 1, 1) xRadius:49 yRadius:49] stroke];
    size = [letter sizeWithAttributes:attributes];
    [letter drawAtPoint:NSMakePoint(128 - size.width / 2, 128 - size.height / 2) withAttributes:attributes];
    [[NSGraphicsContext currentContext] flushGraphics];
    [NSGraphicsContext restoreGraphicsState];
    [image addRepresentation:rep];
    return image;
}

- (NSImage *)loadIconForPath:(NSString *)path
{
    NSString *ext = [[path pathExtension] lowercaseString];
    NSString *name = [path lastPathComponent];
    BOOL directory = NO;
    NSImage *image = nil;

    [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&directory];
    if ([ext isEqualToString:@"app"]) {
        // the sharper renders this dock ships win over the apps' own
        NSDictionary *own = @{ @"Finder.app": @"files", @"Calculator.app": @"calculator", @"Settings.app": @"settings",
                               @"Terminal.app": @"terminal", @"Maps.app": @"maps", @"Web.app": @"web" };
        NSBundle *bundle = [NSBundle bundleWithPath:path];
        NSString *file = [bundle objectForInfoDictionaryKey:@"CFBundleIconFile"];

        if (own[name] != nil)
            image = [self resourceIcon:own[name]];
        if (image == nil && [file length] > 0) {
            NSString *full = [[bundle resourcePath] stringByAppendingPathComponent:file];

            if ([[full pathExtension] length] == 0)
                full = [full stringByAppendingPathExtension:@"png"];
            image = [[[NSImage alloc] initWithContentsOfFile:full] autorelease];
        }
        if (image == nil)
            image = [self letterIcon:[self labelForPath:path]];
    } else if (directory) {
        NSDictionary *folders = @{ @"Downloads": @"folder-download", @"Documents": @"folder-documents", @"Pictures": @"folder-pictures",
                                   @"Music": @"folder-music", @"Movies": @"folder-videos", @"Videos": @"folder-videos",
                                   @"Desktop": @"user-desktop" };

        if ([path isEqualToString:NSHomeDirectory()])
            image = [self resourceIcon:@"user-home"];
        else if (folders[name] != nil)
            image = [self resourceIcon:folders[name]];
        if (image == nil)
            image = [self resourceIcon:@"folder"];
    } else if ([@[ @"png", @"jpg", @"jpeg", @"gif", @"tif", @"tiff", @"bmp" ] containsObject:ext]) {
        // a picture is its own icon
        image = [[[NSImage alloc] initWithContentsOfFile:path] autorelease];
    }
    if (image == nil)
        image = [[NSWorkspace sharedWorkspace] iconForFile:path];
    return image;
}

- (NSImage *)iconForPath:(NSString *)path
{
    NSImage *image = iconCache[path];

    if (image == nil && (image = [self loadIconForPath:path]) != nil)
        iconCache[path] = image;
    return image;
}

- (NSString *)labelForPath:(NSString *)path
{
    NSBundle *bundle = [[path pathExtension] isEqualToString:@"app"] ? [NSBundle bundleWithPath:path] : nil;
    NSString *name = [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: [bundle objectForInfoDictionaryKey:@"CFBundleName"];

    if ([path isEqualToString:FinderPath])
        return L("Files");
    if ([path isEqualToString:NSHomeDirectory()])
        return L("Home");
    return [name length] ? name : [path lastPathComponent];
}

#pragma mark running apps

// a bundle the dock shows when it runs: a regular app, not an agent like the menu bar or this dock
- (BOOL)isRegularApp:(NSString *)bundlePath
{
    NSNumber *cached = bundleCache[bundlePath];

    if (cached == nil) {
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"Contents/Info.plist"]];
        BOOL regular = info != nil && !flag(info[@"LSUIElement"], NO) && !flag(info[@"LSBackgroundOnly"], NO);

        cached = @(regular);
        bundleCache[bundlePath] = cached;
    }
    return [cached boolValue];
}

// every running app bundle with its processes
- (NSDictionary *)runningBundles
{
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    int count = proc_listallpids(NULL, 0);
    pid_t *pids, me = getpid();

    if (count <= 0)
        return result;
    pids = calloc((size_t)count + 32, sizeof(pid_t));
    count = proc_listallpids(pids, (int)(((size_t)count + 32) * sizeof(pid_t)));
    for (int i = 0; i < count; i++) {
        char buffer[ID_PIDPATH_MAX];
        NSString *exe, *macos, *contents, *bundle;

        if (pids[i] <= 0 || pids[i] == me || proc_pidpath(pids[i], buffer, sizeof(buffer)) <= 0)
            continue;
        exe = [NSString stringWithUTF8String:buffer];
        macos = [exe stringByDeletingLastPathComponent];
        contents = [macos stringByDeletingLastPathComponent];
        if (![[macos lastPathComponent] isEqualToString:@"MacOS"] || ![[contents lastPathComponent] isEqualToString:@"Contents"])
            continue;
        bundle = [contents stringByDeletingLastPathComponent];
        if (![self isRegularApp:bundle])
            continue;
        if (result[bundle] == nil)
            result[bundle] = [NSMutableArray array];
        [result[bundle] addObject:@(pids[i])];
    }
    free(pids);
    return result;
}

#pragma mark the item list

- (IDItem *)reuse:(NSArray *)old kind:(IDItemKind)kind path:(NSString *)path
{
    for (IDItem *item in old) {
        if (item->kind == kind && (path == nil || [item->path isEqualToString:path]))
            return item;
    }
    return [IDItem itemWithKind:kind path:path];
}

- (NSUInteger)trashCount
{
    NSUInteger n = 0;

    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:trashPath() error:NULL]) {
        if (![name hasPrefix:@"."])
            n++;
    }
    return n;
}

// a stack shows its newest item over the folder
- (void)updateStackBadge:(IDItem *)item
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *newest = nil;
    NSDate *when = nil;
    NSImage *badge;

    for (NSString *name in [fm contentsOfDirectoryAtPath:item->path error:NULL]) {
        NSString *full = [item->path stringByAppendingPathComponent:name];
        NSDate *date = [[fm attributesOfItemAtPath:full error:NULL] fileModificationDate];

        if ([name hasPrefix:@"."])
            continue;
        if (newest == nil || (date != nil && [date compare:when] == NSOrderedDescending)) {
            newest = full;
            when = date;
        }
    }
    badge = newest ? [self iconForPath:newest] : nil;
    if (badge != item->badge) {
        [item forgetBadgeLevels];
        [item->badge release];
        item->badge = [badge retain];
    }
}

- (void)rebuildItems
{
    NSArray *old = [[items copy] autorelease];
    NSDictionary *running = [self runningBundles];
    NSArray *pinned = [self pinnedApps];
    NSMutableArray *list = [NSMutableArray array];

    for (NSString *bundle in [running allKeys]) {
        if (![pinned containsObject:bundle] && ![extraRunning containsObject:bundle])
            [extraRunning addObject:bundle];
    }
    for (NSString *bundle in [[extraRunning copy] autorelease]) {
        if (running[bundle] == nil || [pinned containsObject:bundle])
            [extraRunning removeObject:bundle];
    }

    for (NSString *path in pinned) {
        IDItem *item = [self reuse:old kind:IDItemApp path:path];

        item->pinned = YES;
        [list addObject:item];
    }
    for (NSString *path in extraRunning) {
        IDItem *item = [self reuse:old kind:IDItemApp path:path];

        item->pinned = NO;
        [list addObject:item];
    }
    [list addObject:[self reuse:old kind:IDItemSeparator path:nil]];
    for (NSString *path in [self stacks]) {
        IDItem *item = [self reuse:old kind:IDItemStack path:path];

        [self updateStackBadge:item];
        [list addObject:item];
    }
    {
        IDItem *trash = [self reuse:old kind:IDItemTrash path:trashPath()];

        trash->count = [self trashCount];
        [list addObject:trash];
    }

    for (IDItem *item in list) {
        NSArray *pids = item->kind == IDItemApp ? running[item->path] : nil;

        if (item->label == nil)
            item->label = [(item->kind == IDItemTrash ? L("Trash") : [self labelForPath:item->path]) copy];
        if (item->icon == nil && item->kind != IDItemSeparator)
            item->icon = [(item->kind == IDItemTrash ? [self resourceIcon:@"trash"] : [self iconForPath:item->path]) retain];
        [item->pids release];
        item->pids = [pids retain];
        item->running = [pids count] > 0;
    }
    [items setArray:list];
}

- (CGFloat)restWidth
{
    CGFloat w = 2 * ID_PAD_X - ID_GAP;

    for (IDItem *item in items)
        w += (item->kind == IDItemSeparator ? ID_SEP_W : settings.tile) + ID_GAP;
    return w;
}

#pragma mark windows

- (CGFloat)scale
{
    NSScreen *screen = [NSScreen mainScreen];
    CGFloat s = [screen respondsToSelector:@selector(backingScaleFactor)] ? [screen backingScaleFactor] : 1;

    return s >= 1 ? s : 1;
}

// the blurred desktop picture under the overlay, at half its pixel size
- (void)renderBackdrop
{
    NSRect screen = [[NSScreen mainScreen] frame];
    NSRect region = [overlay frame];
    NSImage *image = ((IDDesktopView *)desktopView)->picture;
    CGFloat scale = [self scale] * 0.5;
    int w = (int)ceil(NSWidth(region) * scale), h = (int)ceil(NSHeight(region) * scale);
    NSBitmapImageRep *rep;
    NSGraphicsContext *context;
    IDPixels pixels;

    if (w <= 0 || h <= 0)
        return;
    rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h bitsPerSample:8 samplesPerPixel:4
                                                    hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
                                                 bytesPerRow:w * 4 bitsPerPixel:32];
    context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:context];
    [[NSColor colorWithCalibratedRed:0.85 green:0.47 blue:0.35 alpha:1] setFill];
    NSRectFill(NSMakeRect(0, 0, w, h));
    if (image != nil && [image size].width > 0 && [image size].height > 0)
        [image drawInRect:NSMakeRect(0, 0, w, h) fromRect:IDPictureRect(image, screen, region) operation:NSCompositeSourceOver fraction:1];
    [context flushGraphics];
    [NSGraphicsContext restoreGraphicsState];

    pixels.w = w;
    pixels.h = h;
    pixels.stride = w * 4;
    pixels.px = malloc((size_t)pixels.stride * h);
    for (int y = 0; y < h; y++)
        memcpy(pixels.px + (size_t)y * pixels.stride, [rep bitmapData] + (size_t)y * [rep bytesPerRow], (size_t)w * 4);
    [rep release];
    IDBlur(&pixels, MAX(2, (int)round(9 * scale)));
    [dockView setBackdrop:pixels scale:scale];
}

// a dock window that is replaced is closed, not just ordered out: the window server keeps an ordered out
// window and shows a dock-level one again when it lays them out after a screen change
static void retire(NSWindow *window)
{
    if (window == nil)
        return;
    [window setReleasedWhenClosed:NO];
    [window orderOut:nil];
    [window close];
    [window autorelease];
}

// a borderless, clear window for the dock around a view it already has
- (NSWindow *)dockWindow:(NSRect)frame level:(NSInteger)level view:(NSView *)view
{
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame styleMask:NSBorderlessWindowMask
                                                     backing:NSBackingStoreBuffered defer:NO];

    [window setLevel:level];
    [window setOpaque:NO];
    [window setBackgroundColor:[NSColor clearColor]];
    [view retain];
    [view removeFromSuperview];
    [view setFrame:NSMakeRect(0, 0, NSWidth(frame), NSHeight(frame))];
    [window setContentView:view];
    [view release];
    return window;
}

- (void)placeWindows
{
    NSRect screen = [[NSScreen mainScreen] frame];
    CGFloat T = settings.tile, M = settings.magnify ? MAX(settings.magnified, T) : T;
    CGFloat w = [self restWidth], h = ID_PAD_TOP + T + ID_PAD_BOTTOM;
    CGFloat extra = ceil((M - T) * 1.7) + ID_SHADOW + 70;
    NSRect inputFrame, overlayFrame;
    BOOL out = !settings.autohide || shown;
    // with auto-hide nothing reserves the bottom edge, so maximised windows keep their size
    NSInteger level = settings.autohide ? NSStatusWindowLevel : NSDockWindowLevel;

    if (NSWidth(screen) < 100)
        return;
    inputFrame = out ? NSMakeRect(floor(NSMidX(screen) - w / 2), NSMinY(screen) + ID_SCREEN_GAP, ceil(w), h)
                     : NSMakeRect(floor(NSMidX(screen) - w / 2), NSMinY(screen), ceil(w), 3);
    overlayFrame.size = NSMakeSize(ceil(w + 2 * extra), ceil(ID_SHADOW + h + MAX(M - T + ID_LABEL + 10, T * 1.7)));
    overlayFrame.origin = NSMakePoint(floor(NSMidX(screen) - NSWidth(overlayFrame) / 2), NSMinY(screen) + ID_SCREEN_GAP - ID_SHADOW);

    // a dock window that changes size is made anew: a layer surface resized in place keeps being placed
    // by its old size for a while, and the pointer then misses the tiles, as PD's own Dock notes
    if (input == nil || !NSEqualRects([input frame], inputFrame) || [input level] != level) {
        NSWindow *old = input;

        input = [self dockWindow:inputFrame level:level view:inputView];
        [input setAcceptsMouseMovedEvents:YES];
        [inputView resetTracking];
        [input orderFront:nil];
        retire(old);
    }
    if (overlay == nil || !NSEqualRects([overlay frame], overlayFrame)) {
        NSWindow *old = overlay;

        overlay = [self dockWindow:overlayFrame level:NSStatusWindowLevel view:dockView];
        [overlay setIgnoresMouseEvents:YES];
        [self renderBackdrop];
        [dockView layoutItems];
        dockView->lastContent = NSZeroRect;
        [overlay orderFront:nil];
        retire(old);
    }
    [dockView layoutItems];
    [dockView setNeedsDisplay:YES];
}

- (void)placeDesktop:(id)sender
{
    NSRect screen = [[NSScreen mainScreen] frame];

    if (NSWidth(screen) < 100) {
        [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(placeDesktop:) userInfo:nil repeats:NO];
        return;
    }
    [self closePopup];
    [desktop setFrame:screen display:YES];
    [desktop orderFront:nil];
    [self placeWindows];
}

- (NSImage *)chosenPicture
{
    NSString *path = [picture isAbsolutePath] ? picture
                                              : [[DesktopPictures stringByAppendingPathComponent:picture] stringByAppendingPathExtension:@"jpg"];
    NSImage *image = [[[NSImage alloc] initWithContentsOfFile:path] autorelease];

    if (image == nil)
        NSLog(@"Dock: no desktop picture at %@", path);
    return image;
}

- (void)makeWindows
{
    NSRect frame = NSMakeRect(0, 0, 1024, 768);
    IDDesktopView *view;

    desktop = [[NSWindow alloc] initWithContentRect:frame styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
    [desktop setLevel:NSDesktopWindowLevel];
    view = [[IDDesktopView alloc] initWithFrame:frame];
    view->picture = [[self chosenPicture] retain];
    [view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [desktop setContentView:view];
    desktopView = view;

    dockView = [[IDDockView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
    dockView->controller = self;
    dockView->items = [items retain];
    dockView->settings = settings;
    dockView->pointerX = NAN;
    inputView = [[IDInputView alloc] initWithFrame:NSMakeRect(0, 0, 100, 60)];
    inputView->controller = self;
}

#pragma mark changes

- (void)itemsChanged
{
    [self rebuildItems];
    [self placeWindows];
    [prefs refresh];
}

- (void)settingsChanged
{
    dockView->settings = settings;
    if (!settings.autohide)
        shown = YES;
    [self placeWindows];
    [self startAnimating];
    [prefs refresh];
}

// field by field, the padding between them is never written
static BOOL sameSettings(IDSettings a, IDSettings b)
{
    return a.tile == b.tile && a.magnified == b.magnified && a.magnify == b.magnify && a.autohide == b.autohide &&
           a.indicators == b.indicators && a.glass == b.glass;
}

- (void)tick:(NSTimer *)timer
{
    IDSettings now = [self readSettings];
    NSString *chosen;
    NSDictionary *running;
    NSArray *pinned;
    BOOL listChanged = NO;

    ticks++;
    if (getenv("ID_TRACE") != NULL && ticks % 5 == 0)
        NSLog(@"Dock: screen %@ input %@ overlay %@", NSStringFromRect([[NSScreen mainScreen] frame]), NSStringFromRect([input frame]),
              NSStringFromRect([overlay frame]));
    CFPreferencesAppSynchronize(IDDomain);
    chosen = [self pref:@"DesktopPicture"] ?: @"Sunset";
    if (![chosen isEqualToString:picture]) {
        IDDesktopView *view = (IDDesktopView *)desktopView;

        [picture release];
        picture = [chosen copy];
        [view->picture release];
        view->picture = [[self chosenPicture] retain];
        [view setNeedsDisplay:YES];
        [self renderBackdrop];
    }
    if (!sameSettings(now, settings)) {
        settings = now;
        [self settingsChanged];
    }

    // a new or vanished unpinned app changes the list, anything else only the dots
    running = [self runningBundles];
    pinned = [self pinnedApps];
    for (NSString *bundle in running) {
        if (![pinned containsObject:bundle] && ![extraRunning containsObject:bundle])
            listChanged = YES;
    }
    for (NSString *bundle in extraRunning) {
        if (running[bundle] == nil)
            listChanged = YES;
    }
    if (listChanged && dockView->dragging == nil) {
        [self itemsChanged];
        [self startAnimating];
        return;
    }
    for (IDItem *item in items) {
        if (item->kind == IDItemApp) {
            NSArray *pids = running[item->path];
            BOOL on = [pids count] > 0;

            [item->pids release];
            item->pids = [pids retain];
            if (on != item->running) {
                item->running = on;
                [dockView setNeedsDisplay:YES];
            }
        } else if (item->kind == IDItemTrash) {
            NSUInteger n = [self trashCount];

            if (n != item->count) {
                item->count = n;
                [dockView setNeedsDisplay:YES];
            }
        } else if (item->kind == IDItemStack && ticks % 5 == 0) {
            NSImage *before = item->badge;

            [self updateStackBadge:item];
            if (before != item->badge)
                [dockView setNeedsDisplay:YES];
        }
    }
}

- (void)animate:(NSTimer *)timer
{
    static double total, last;
    static int frames;
    double t0 = [NSDate timeIntervalSinceReferenceDate] * 1000;
    BOOL busy = [dockView step];

    // ID_PROFILE: the whole frame, drawing and handing it to the compositor, and the time between frames
    if (getenv("ID_PROFILE") != NULL) {
        [overlay displayIfNeeded];
        total += [NSDate timeIntervalSinceReferenceDate] * 1000 - t0;
        if (++frames == 10) {
            fprintf(stderr, "Dock: whole frame %.1f ms, frame to frame %.1f ms, overlay %gx%g\n", total / 10, (t0 - last) / 10,
                    NSWidth([overlay frame]), NSHeight([overlay frame]));
            total = 0;
            frames = 0;
            last = t0;
        }
    }
    animation = nil;
    // the next frame right after this one, at most sixty a second
    if (busy) {
        double spent = [NSDate timeIntervalSinceReferenceDate] - t0 / 1000;

        animation = [NSTimer scheduledTimerWithTimeInterval:MAX(0.001, 1.0 / 60 - spent) target:self selector:@selector(animate:)
                                                   userInfo:nil repeats:NO];
    }
}

- (void)startAnimating
{
    if (animation == nil)
        animation = [NSTimer scheduledTimerWithTimeInterval:0.001 target:self selector:@selector(animate:) userInfo:nil repeats:NO];
}

#pragma mark auto-hide

- (void)hideNow:(NSTimer *)timer
{
    hideTimer = nil;
    if (!settings.autohide || inside || popup != nil || dockView->dragging != nil)
        return;
    shown = NO;
    [self placeWindows];
    [self startAnimating];
}

- (void)scheduleHide
{
    [hideTimer invalidate];
    hideTimer = nil;
    if (settings.autohide)
        hideTimer = [NSTimer scheduledTimerWithTimeInterval:0.7 target:self selector:@selector(hideNow:) userInfo:nil repeats:NO];
}

#pragma mark pointer

- (void)pointerEntered
{
    inside = YES;
    [hideTimer invalidate];
    hideTimer = nil;
    [popup cancelClose];
    if (settings.autohide && !shown) {
        shown = YES;
        [self placeWindows];
    }
    [self startAnimating];
}

- (void)pointerExited
{
    inside = NO;
    dockView->hover = nil;
    if (popup != nil)
        [popup scheduleClose];
    else
        [self scheduleHide];
    [self startAnimating];
}

- (void)pointerMovedTo:(NSPoint)p
{
    IDItem *item;

    if (!inside)
        [self pointerEntered];
    dockView->pointerX = p.x;
    // an event only notes where the pointer is, the next frame draws it: drawing for every event let
    // the events queue up behind the drawing, and the dock trailed the pointer
    item = [dockView itemAtX:p.x];
    dockView->hover = item;
    [self startAnimating];
}

- (void)pressedAt:(NSPoint)p
{
    BOOL hadPopup = popup != nil;
    IDItem *item = [dockView itemAtX:p.x];

    // a second click on the tile that opened a stack closes it
    if (hadPopup && [popup contentView] != nil && [[popup contentView] isKindOfClass:[IDStackView class]] &&
        item != nil && [((IDStackView *)[popup contentView])->folder isEqualToString:item->path]) {
        [self closePopup];
        dockView->pressed = nil;
        return;
    }
    [self closePopup];
    pressPoint = p;
    dockView->pressed = item;
    [dockView setNeedsDisplay:YES];
}

- (BOOL)canDrag:(IDItem *)item
{
    return item != nil && (item->kind == IDItemApp || item->kind == IDItemStack);
}

- (BOOL)canRemove:(IDItem *)item
{
    if (item->kind == IDItemApp)
        return item->pinned && ![item->path isEqualToString:FinderPath];
    return item->kind == IDItemStack;
}

// moves the dragged tile inside its own group: the apps after Finder, or the stacks
- (BOOL)item:(IDItem *)item sharesGroupWith:(IDItem *)dragged
{
    if (item->kind != dragged->kind)
        return NO;
    return !(item->kind == IDItemApp && [item->path isEqualToString:FinderPath]);
}

- (void)reorderDragged:(CGFloat)x
{
    IDItem *dragged = dockView->dragging;
    NSUInteger from = [items indexOfObject:dragged], to = NSNotFound, last = NSNotFound;
    NSMutableArray *rest = [[items mutableCopy] autorelease];
    NSMutableDictionary *before = [NSMutableDictionary dictionary];

    [rest removeObject:dragged];
    for (NSUInteger i = 0; i < [rest count]; i++) {
        IDItem *item = rest[i];

        if (![self item:item sharesGroupWith:dragged])
            continue;
        last = i;
        if (to == NSNotFound && x < item->center)
            to = i;
    }
    if (to == NSNotFound)
        to = last == NSNotFound ? from : last + 1;
    if (to == from)
        return;
    for (IDItem *item in items)
        before[[NSValue valueWithPointer:item]] = @(item->center + item->offset);
    [rest insertObject:dragged atIndex:to];
    [items setArray:rest];
    [dockView layoutItems];
    for (IDItem *item in items)
        item->offset = [before[[NSValue valueWithPointer:item]] doubleValue] - item->center;
    [self startAnimating];
}

- (void)draggedTo:(NSPoint)p
{
    IDItem *item = dockView->pressed;

    if (dockView->dragging == nil) {
        if (![self canDrag:item] || hypot(p.x - pressPoint.x, p.y - pressPoint.y) < 6)
            return;
        dockView->dragging = item;
        dockView->pressed = nil;
        dockView->hover = nil;
    }
    item = dockView->dragging;
    dockView->dragX = p.x;
    dockView->dragY = p.y;
    {
        NSRect bar = [dockView barRect];
        IDItem *trash = [items lastObject];
        BOOL overTrash = trash != nil && fabs(p.x - trash->center) < settings.tile * 0.6 && p.y < NSMaxY(bar) + 10;

        dockView->dragRemoves = [self canRemove:item] && (p.y > NSMaxY(bar) + settings.tile * 0.9 || overTrash);
        if (!dockView->dragRemoves && p.y < NSMaxY(bar) + settings.tile * 0.9)
            [self reorderDragged:p.x];
    }
    [self startAnimating];
}

- (void)removeItem:(IDItem *)item
{
    if (item->kind == IDItemApp) {
        NSMutableArray *apps = [[[self pinnedApps] mutableCopy] autorelease];

        [apps removeObject:item->path];
        [self setPinnedApps:apps];
    } else if (item->kind == IDItemStack) {
        NSMutableArray *stacks = [[[self stacks] mutableCopy] autorelease];

        [stacks removeObject:item->path];
        [self setStacks:stacks];
    }
}

- (void)saveOrder
{
    NSMutableArray *apps = [NSMutableArray array], *stacks = [NSMutableArray array];

    for (IDItem *item in items) {
        if (item->kind == IDItemApp && (item->pinned || item == dockView->dragging))
            [apps addObject:item->path];
        else if (item->kind == IDItemStack)
            [stacks addObject:item->path];
    }
    [self writeSetting:@"PersistentApps" value:apps];
    [self writeSetting:@"PersistentStacks" value:stacks];
}

- (void)releasedAt:(NSPoint)p
{
    IDItem *dragged = dockView->dragging, *pressed = dockView->pressed;

    dockView->dragging = nil;
    dockView->pressed = nil;
    if (dragged != nil) {
        if (dockView->dragRemoves)
            [self removeItem:dragged];
        else
            [self saveOrder];
        dockView->dragRemoves = NO;
        [self itemsChanged];
    } else if (pressed != nil && [dockView itemAtX:p.x] == pressed && p.y >= 0) {
        [self activate:pressed];
    }
    [dockView setNeedsDisplay:YES];
    [self startAnimating];
    if (!inside)
        [self scheduleHide];
}

#pragma mark actions

// where a popup opens: over the tile at rest, just above the bar, whatever the tiles are doing now
- (NSRect)popupAnchorFor:(IDItem *)item
{
    NSRect frame = [overlay frame];
    CGFloat top = NSMinY(frame) + ID_SHADOW + dockView->barHeight;
    CGFloat x = item != nil ? item->restCenter : dockView->barRestLeft + dockView->barRestWidth / 2;

    return NSMakeRect(NSMinX(frame) + x - 1, top - 1, 2, 1);
}

- (void)showPopupWithView:(NSView *)view above:(IDItem *)item
{
    IDPopup *window = [[IDPopup alloc] initWithContent:view controller:self above:[self popupAnchorFor:item]];

    [self closePopup];
    popup = window;
    if ([view isKindOfClass:[IDMenuView class]])
        ((IDMenuView *)view)->popup = window;
    else
        ((IDStackView *)view)->popup = window;
    dockView->hover = nil;
    [popup show];
    [dockView invalidateContent];
    [self startAnimating];
}

- (void)showStack:(IDItem *)item
{
    IDStackView *view = [[[IDStackView alloc] initWithFolder:item->path controller:self] autorelease];

    view->trash = item->kind == IDItemTrash;
    [self showPopupWithView:view above:item];
}

- (void)openPath:(NSString *)path
{
    BOOL directory = NO;

    [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&directory];
    if ([[path pathExtension] isEqualToString:@"app"]) {
        [[NSWorkspace sharedWorkspace] launchApplication:path];
    } else if (directory) {
        // Finder opens at home and cannot be pointed at a folder yet
        [[NSWorkspace sharedWorkspace] launchApplication:FinderPath];
    } else {
        [[NSWorkspace sharedWorkspace] openFile:path];
    }
}

- (void)activate:(IDItem *)item
{
    switch (item->kind) {
    case IDItemApp:
        // nothing can bring another app's windows forward yet, a hop shows the click arrived
        if (!item->running) {
            [[NSWorkspace sharedWorkspace] launchApplication:item->path];
            item->bounceStart = [NSDate timeIntervalSinceReferenceDate];
        } else {
            item->bounceStart = [NSDate timeIntervalSinceReferenceDate] - 6.0 + 0.62;
        }
        [self startAnimating];
        break;
    case IDItemStack:
    case IDItemTrash:
        [[NSFileManager defaultManager] createDirectoryAtPath:trashPath() withIntermediateDirectories:YES attributes:nil error:NULL];
        [self showStack:item];
        break;
    default:
        break;
    }
}

- (void)closePopup
{
    IDPopup *old = popup;

    if (old == nil)
        return;
    popup = nil;
    [old cancelClose];
    retire(old);
    [dockView invalidateContent];
    [self startAnimating];
    if (!inside)
        [self scheduleHide];
}

- (void)quit:(IDItem *)item
{
    for (NSNumber *pid in item->pids)
        kill([pid intValue], SIGTERM);
}

- (void)forceQuit:(IDItem *)item
{
    for (NSNumber *pid in item->pids)
        kill([pid intValue], SIGKILL);
}

- (void)togglePinned:(IDItem *)item
{
    NSMutableArray *apps = [[[self pinnedApps] mutableCopy] autorelease];

    if ([apps containsObject:item->path])
        [apps removeObject:item->path];
    else
        [apps addObject:item->path];
    [self setPinnedApps:apps];
}

- (void)openItem:(IDItem *)item
{
    [self activate:item];
}

- (void)removeFromDock:(IDItem *)item
{
    [self removeItem:item];
}

- (void)openInFiles:(IDItem *)item
{
    [self openPath:item->path];
}

- (void)toggleMagnify:(id)sender
{
    [self writeSetting:@"Magnify" value:@(!settings.magnify)];
    [self tick:nil];
}

- (void)toggleAutohide:(id)sender
{
    [self writeSetting:@"AutoHide" value:@(!settings.autohide)];
    [self tick:nil];
}

- (void)emptyTrash:(id)sender
{
    NSFileManager *fm = [NSFileManager defaultManager];

    for (NSString *name in [fm contentsOfDirectoryAtPath:trashPath() error:NULL])
        [fm removeItemAtPath:[trashPath() stringByAppendingPathComponent:name] error:NULL];
    [self tick:nil];
}

- (void)confirmEmptyTrash:(IDItem *)item
{
    NSString *question = [NSString stringWithFormat:L("Delete %lu items for good?"), (unsigned long)item->count];
    NSArray *entries = @[ [IDMenuEntry header:question],
                          [IDMenuEntry title:L("Empty Trash") action:@selector(emptyTrash:) target:self object:nil],
                          [IDMenuEntry title:L("Cancel") action:NULL target:nil object:nil] ];

    ((IDMenuEntry *)entries[1])->destructive = YES;
    [self showMenu:entries above:item];
}

- (void)showMenu:(NSArray *)entries above:(IDItem *)item
{
    NSSize size = [IDMenuView sizeForEntries:entries];
    IDMenuView *view = [[[IDMenuView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)] autorelease];

    view->entries = [entries retain];
    view->highlighted = -1;
    [self showPopupWithView:view above:item];
}

- (void)rightClickAt:(NSPoint)p
{
    IDItem *item = [dockView itemAtX:p.x];
    NSMutableArray *entries = [NSMutableArray array];
    IDMenuEntry *entry;

    [self closePopup];
    dockView->pressed = nil;
    if (item == nil || item->kind == IDItemSeparator) {
        entry = [IDMenuEntry title:L("Magnification") action:@selector(toggleMagnify:) target:self object:nil];
        entry->checked = settings.magnify;
        [entries addObject:entry];
        entry = [IDMenuEntry title:L("Automatically hide the Dock") action:@selector(toggleAutohide:) target:self object:nil];
        entry->checked = settings.autohide;
        [entries addObject:entry];
        [entries addObject:[IDMenuEntry separator]];
        [entries addObject:[IDMenuEntry title:L("Dock Settings…") action:@selector(showPrefs:) target:self object:nil]];
        [self showMenu:entries above:nil];
        return;
    }
    [entries addObject:[IDMenuEntry header:item->label]];
    if (item->kind == IDItemApp) {
        if (!item->running)
            [entries addObject:[IDMenuEntry title:L("Open") action:@selector(openItem:) target:self object:item]];
        if (![item->path isEqualToString:FinderPath]) {
            entry = [IDMenuEntry title:L("Keep in Dock") action:@selector(togglePinned:) target:self object:item];
            entry->checked = item->pinned;
            [entries addObject:entry];
        }
        if (item->running) {
            [entries addObject:[IDMenuEntry separator]];
            [entries addObject:[IDMenuEntry title:L("Quit") action:@selector(quit:) target:self object:item]];
            entry = [IDMenuEntry title:L("Force Quit") action:@selector(forceQuit:) target:self object:item];
            entry->destructive = YES;
            [entries addObject:entry];
        }
    } else if (item->kind == IDItemStack) {
        [entries addObject:[IDMenuEntry title:L("Open") action:@selector(openItem:) target:self object:item]];
        [entries addObject:[IDMenuEntry title:L("Open in Files") action:@selector(openInFiles:) target:self object:item]];
        [entries addObject:[IDMenuEntry separator]];
        [entries addObject:[IDMenuEntry title:L("Remove from Dock") action:@selector(removeFromDock:) target:self object:item]];
    } else if (item->kind == IDItemTrash) {
        [entries addObject:[IDMenuEntry title:L("Open") action:@selector(openItem:) target:self object:item]];
        if (item->count > 0) {
            [entries addObject:[IDMenuEntry separator]];
            entry = [IDMenuEntry title:L("Empty Trash…") action:@selector(confirmEmptyTrash:) target:self object:item];
            entry->destructive = YES;
            [entries addObject:entry];
        }
    }
    [self showMenu:entries above:item];
}

- (void)showPrefs:(id)sender
{
    if (prefs == nil)
        prefs = [[IDPrefsController alloc] initWithController:self];
    [prefs show];
}

- (NSImage *)desktopPicture
{
    return ((IDDesktopView *)desktopView)->picture;
}

// every app a user could keep in the dock
- (NSArray *)installedApps
{
    NSMutableArray *apps = [NSMutableArray arrayWithObject:FinderPath];
    NSFileManager *fm = [NSFileManager defaultManager];

    for (NSString *dir in @[ @"/Applications", @"/Applications/Utilities" ]) {
        for (NSString *name in [[fm contentsOfDirectoryAtPath:dir error:NULL] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]) {
            NSString *path = [dir stringByAppendingPathComponent:name];

            if ([[name pathExtension] isEqualToString:@"app"] && [self isRegularApp:path])
                [apps addObject:path];
        }
    }
    return apps;
}

#pragma mark start

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    items = [[NSMutableArray alloc] init];
    iconCache = [[NSMutableDictionary alloc] init];
    bundleCache = [[NSMutableDictionary alloc] init];
    extraRunning = [[NSMutableArray alloc] init];
    settings = [self readSettings];
    shown = !settings.autohide;
    picture = [([self pref:@"DesktopPicture"] ?: @"Sunset") copy];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(placeDesktop:)
                                                 name:NSApplicationDidChangeScreenParametersNotification object:nil];
    [self rebuildItems];
    [self makeWindows];
    [self placeDesktop:nil];
    [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    if (getenv("ID_PREFS") != NULL)
        [self performSelector:@selector(showPrefs:) withObject:nil afterDelay:3];
    if (getenv("ID_DEMO") != NULL)
        [NSTimer scheduledTimerWithTimeInterval:3 target:self selector:@selector(demo:) userInfo:nil repeats:NO];
}

// ID_DEMO: a pointer that sweeps the bar for six seconds, to measure the frame time without a mouse
- (void)demo:(NSTimer *)timer
{
    static NSTimeInterval start;
    NSTimeInterval t;
    NSRect bar = [dockView barRect];

    if (timer != nil && start == 0) {
        start = [NSDate timeIntervalSinceReferenceDate];
        inside = YES;
        [NSTimer scheduledTimerWithTimeInterval:1.0 / 60 target:self selector:@selector(demo:) userInfo:nil repeats:YES];
        return;
    }
    t = [NSDate timeIntervalSinceReferenceDate] - start;
    if (t > 6) {
        [timer invalidate];
        [self pointerExited];
        return;
    }
    [self pointerMovedTo:NSMakePoint(NSMinX(bar) + NSWidth(bar) * (0.5 + 0.45 * sin(t * 1.3)), NSMidY(bar))];
}

@end
