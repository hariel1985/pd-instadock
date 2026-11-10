/*
 * IDDock.h - the classes of InstaDock, the PureDarwin dock.
 *
 * Copyright (c) 2026 The pd-instadock authors
 *
 * SPDX-License-Identifier: MPL-2.0 OR BSD-2-Clause
 */

#import <AppKit/AppKit.h>
#include <sys/types.h>
#include "IDGlass.h"

@interface NSWindow (PDBlur)
- (void)_setBackgroundBlurInset:(CGFloat)inset radius:(CGFloat)radius;
@end

// shared preferences with the PD Settings app, which writes TileSize, Magnify and DesktopPicture
#define IDDomain CFSTR("org.puredarwin.Dock")

// sizes in points
#define ID_GAP 8
#define ID_PAD_X 10
#define ID_PAD_TOP 8
#define ID_PAD_BOTTOM 11
#define ID_SEP_W 13
#define ID_SCREEN_GAP 8
#define ID_SHADOW 20
#define ID_LABEL 40

typedef enum {
    IDItemApp,
    IDItemStack,
    IDItemTrash,
    IDItemSeparator,
} IDItemKind;

@interface IDItem : NSObject {
@public
    IDItemKind kind;
    NSString *path;
    NSString *label;
    NSImage *icon;
    NSImage *badge; // a stack's newest item, drawn over its folder
    NSArray *pids;
    BOOL pinned;
    BOOL running;
    NSUInteger count; // what the trash holds
    // layout, in the overlay's points
    CGFloat restCenter;
    CGFloat center;
    CGFloat size;
    CGFloat offset;      // eases to zero after a reorder, so tiles glide into place
    NSTimeInterval bounceStart;
    IDPixels levels[3]; // the icon at 256, 128 and 64 pixels, for drawing it in the glass canvas
    int levelCount;
    IDPixels badgeLevels[3];
    int badgeLevelCount;
}
+ (IDItem *)itemWithKind:(IDItemKind)kind path:(NSString *)path;
- (NSString *)bundleExecutable;
- (void)makeLevels;
- (void)makeBadgeLevels;
- (void)forgetBadgeLevels;
@end

typedef struct {
    CGFloat tile;      // 32..72
    CGFloat magnified; // tile..128
    BOOL magnify;
    BOOL autohide;
    BOOL indicators;
    CGFloat glass;     // 0..1, refraction and rim light
} IDSettings;

@class IDController;

// draws the whole dock: the glass bar, tiles, labels; it never takes the pointer
@interface IDDockView : NSView {
@public
    IDController *controller;
    NSArray *items;
    IDSettings settings;
    CGFloat barRestLeft, barRestWidth, barHeight;
    CGFloat pointerX;   // NAN when the pointer is not over the bar
    CGFloat zoom;       // 0..1, eases in and out with the pointer
    CGFloat hide;       // 0 shown .. 1 hidden below the screen edge
    IDItem *hover;
    IDItem *pressed;
    IDItem *dragging;
    CGFloat dragX, dragY;
    BOOL dragRemoves;
    IDPixels back;      // the blurred desktop picture behind this window, rows top down
    CGFloat backScale;  // backdrop pixels per point
    IDPixels canvas;    // the glass, at the window's pixel size
    IDPixels base;      // the glass's flat look over the whole window, remade when what it depends on changes
    float baseKey[5];
    BOOL dark;
    NSRect lastContent; // what the last frame drew, so the next one repaints only that and its own
    IDPixels pill;      // the hovered tile's label, drawn once and then copied into the canvas
    NSString *pillText;
    BOOL pillDark;
    CGFloat pillScale;
    IDPixels under;     // when set, an opaque picture of the canvas's size the dock is drawn over, as in the settings preview
}
- (void)layoutItems;
- (BOOL)step; // advances the animations, YES while one is still running
- (IDItem *)itemAtX:(CGFloat)x;
- (NSRect)barRect;
- (NSRect)iconRectForItem:(IDItem *)item;
- (void)setBackdrop:(IDPixels)pixels scale:(CGFloat)scale;
- (void)invalidateContent;
@end

// a transparent window over the bar at rest, the only one the compositor gives the pointer to
@interface IDInputView : NSView {
@public
    IDController *controller;
    NSTrackingRectTag tracking;
}
- (void)resetTracking;
@end

// a borderless popup above the dock: context menus and stacks
@interface IDPopup : NSWindow {
@public
    IDController *controller;
    NSTimer *closeTimer;
}
- (instancetype)initWithContent:(NSView *)view controller:(IDController *)controller above:(NSRect)anchor;
- (void)show;
- (void)scheduleClose;
- (void)cancelClose;
@end

@interface IDMenuEntry : NSObject {
@public
    NSString *title;
    SEL action;
    id target;
    id object;
    BOOL checked;
    BOOL separator;
    BOOL destructive;
    BOOL header;
}
+ (IDMenuEntry *)title:(NSString *)title action:(SEL)action target:(id)target object:(id)object;
+ (IDMenuEntry *)separator;
+ (IDMenuEntry *)header:(NSString *)title;
@end

@interface IDMenuView : NSView {
@public
    NSArray *entries;
    NSInteger highlighted;
    IDPopup *popup;
}
+ (NSSize)sizeForEntries:(NSArray *)entries;
@end

@interface IDStackView : NSView {
@public
    NSString *folder;
    NSArray *paths;
    NSArray *icons;
    NSInteger highlighted;
    IDPopup *popup;
    NSInteger columns;
    BOOL trash;      // the footer empties the trash instead of opening the folder
    BOOL confirming; // the footer asks once more before emptying
}
- (instancetype)initWithFolder:(NSString *)folder controller:(IDController *)controller;
@end

@class IDSlider, IDSwitch, IDChoice, IDIconGrid, IDPreviewDock;

@interface IDPrefsController : NSObject <NSWindowDelegate> {
    IDController *_controller;
    NSWindow *_window;
    IDPreviewDock *_preview;
    NSString *_previewKey;  // what the preview's copies of the items were made from
    NSImage *_previewPicture;
    IDSlider *_size, *_magnified, *_glass;
    IDSwitch *_magnify;
    IDChoice *_autohide, *_indicators;
    IDIconGrid *_apps, *_stacks;
}
- (instancetype)initWithController:(IDController *)controller;
- (void)show;
- (void)refresh;
@end

@interface IDController : NSObject {
@public
    NSWindow *desktop;
    NSView *desktopView;
    NSWindow *overlay;
    IDDockView *dockView;
    NSWindow *input;
    IDInputView *inputView;
    NSMutableArray *items;
    IDSettings settings;
    NSString *picture;
    unsigned pictureLoads; // the newest desktop picture load, older ones that finish later are dropped
    NSTimer *animation;
    NSTimer *hideTimer;
    IDPopup *popup;
    IDPrefsController *prefs;
    BOOL shown; // with auto-hide, whether the dock is out
    BOOL inside;
    NSPoint pressPoint;
    NSMutableDictionary *iconCache;
    NSMutableDictionary *bundleCache;
    NSMutableArray *extraRunning; // running apps that are not pinned, in the order they appeared
    NSUInteger ticks;
}
- (NSImage *)iconForPath:(NSString *)path;
- (NSImage *)resourceIcon:(NSString *)name;
- (NSString *)labelForPath:(NSString *)path;
- (NSImage *)desktopPicture;
- (void)startAnimating;
- (void)itemsChanged;
- (void)settingsChanged;
- (void)writeSetting:(NSString *)key value:(id)value;
- (NSArray *)pinnedApps;
- (NSArray *)stacks;
- (void)setPinnedApps:(NSArray *)apps;
- (void)setStacks:(NSArray *)stacks;
- (void)openPath:(NSString *)path;
- (void)closePopup;
- (void)showPrefs:(id)sender;
- (void)emptyTrash:(id)sender;
- (NSArray *)installedApps;

// from the input view, in the overlay's coordinates
- (void)pointerMovedTo:(NSPoint)p;
- (void)pointerEntered;
- (void)pointerExited;
- (void)pressedAt:(NSPoint)p;
- (void)draggedTo:(NSPoint)p;
- (void)releasedAt:(NSPoint)p;
- (void)rightClickAt:(NSPoint)p;
@end

NSString *IDLocalized(NSString *key);
// the part of the picture under a screen rectangle, in the picture's own points
NSRect IDPictureRect(NSImage *picture, NSRect screen, NSRect region);
// AppKit drawing into premultiplied pixels, points scaled to pixels
IDPixels IDRenderPixels(NSSize points, CGFloat scale, void (^draw)(void));
#define L(s) IDLocalized(@s)
