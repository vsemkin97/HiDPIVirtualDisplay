#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

static void Swizzle(Class cls, SEL origSel, SEL newSel) {
    Method orig = class_getInstanceMethod(cls, origSel);
    Method newM = class_getInstanceMethod(cls, newSel);
    if (orig && newM) {
        method_exchangeImplementations(orig, newM);
    }
}

@interface NSScreen (NoNotch)
- (NSEdgeInsets)nn_safeAreaInsets;
- (NSRect)nn_notchFrame;
- (NSRect)nn_notchFrameForSpace:(uint64_t)space;
- (NSRect)nn_safeAreaFrame;
- (NSRect)nn_auxiliaryTopLeftArea;
- (NSRect)nn_auxiliaryTopRightArea;
@end

@implementation NSScreen (NoNotch)
- (NSEdgeInsets)nn_safeAreaInsets {
    return NSEdgeInsetsZero;
}
- (NSRect)nn_notchFrame {
    return NSZeroRect;
}
- (NSRect)nn_notchFrameForSpace:(uint64_t)space {
    return NSZeroRect;
}
- (NSRect)nn_safeAreaFrame {
    return [self frame];
}
- (NSRect)nn_auxiliaryTopLeftArea {
    return NSZeroRect;
}
- (NSRect)nn_auxiliaryTopRightArea {
    return NSZeroRect;
}
@end

@interface NSWindow (NoNotch)
- (NSRect)nn_frameForFullScreenMode;
- (NSRect)nn_frameForFullScreenModeInRect:(NSRect)r;
- (NSRect)nn_enforceFullScreenRestrictionForFrame:(NSRect)r;
- (void)nn_setLevel:(NSInteger)level;
@end

@implementation NSWindow (NoNotch)
- (NSRect)nn_frameForFullScreenMode {
    NSScreen *s = [self screen];
    if (!s) s = [NSScreen mainScreen];
    return s ? [s frame] : [self frame];
}
- (NSRect)nn_frameForFullScreenModeInRect:(NSRect)r {
    NSScreen *s = [self screen];
    if (!s) s = [NSScreen mainScreen];
    return s ? [s frame] : r;
}
- (NSRect)nn_enforceFullScreenRestrictionForFrame:(NSRect)r {
    return r;
}
- (void)nn_setLevel:(NSInteger)level {
    if (self.styleMask & NSWindowStyleMaskFullScreen) {
        // WindowServer Menubar is at layer 24 (NSMainMenuWindowLevel).
        // Elevate fullscreen window to layer 25 so video draws over the black bar.
        [self nn_setLevel:NSMainMenuWindowLevel + 1];
    } else {
        [self nn_setLevel:level];
    }
}
@end

__attribute__((constructor))
static void InitNoNotch(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 1. NSScreen notch & safe area bypass (scalar uint64_t space argument, no ARC)
        Swizzle([NSScreen class], @selector(safeAreaInsets), @selector(nn_safeAreaInsets));
        Swizzle([NSScreen class], @selector(_notchFrame), @selector(nn_notchFrame));
        Swizzle([NSScreen class], @selector(_notchFrameForSpace:), @selector(nn_notchFrameForSpace:));
        Swizzle([NSScreen class], @selector(_safeAreaFrame), @selector(nn_safeAreaFrame));
        Swizzle([NSScreen class], @selector(auxiliaryTopLeftArea), @selector(nn_auxiliaryTopLeftArea));
        Swizzle([NSScreen class], @selector(auxiliaryTopRightArea), @selector(nn_auxiliaryTopRightArea));

        // 2. NSWindow fullscreen frame & window level overrides
        Swizzle([NSWindow class], @selector(_frameForFullScreenMode), @selector(nn_frameForFullScreenMode));
        Swizzle([NSWindow class], @selector(_frameForFullScreenModeInRect:), @selector(nn_frameForFullScreenModeInRect:));
        Swizzle([NSWindow class], @selector(_enforceFullScreenRestrictionForFrame:), @selector(nn_enforceFullScreenRestrictionForFrame:));
        Swizzle([NSWindow class], @selector(setLevel:), @selector(nn_setLevel:));

        // 3. Notification listeners to elevate window above WindowServer Menubar (layer 24)
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillEnterFullScreenNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            if ([note.object isKindOfClass:[NSWindow class]]) {
                NSWindow *w = (NSWindow *)note.object;
                [w setLevel:NSMainMenuWindowLevel + 1];
            }
        }];

        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidEnterFullScreenNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            if ([note.object isKindOfClass:[NSWindow class]]) {
                NSWindow *w = (NSWindow *)note.object;
                [w setLevel:NSMainMenuWindowLevel + 1];
                [w orderFrontRegardless];
            }
        }];

        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidExitFullScreenNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            if ([note.object isKindOfClass:[NSWindow class]]) {
                NSWindow *w = (NSWindow *)note.object;
                [w setLevel:NSNormalWindowLevel];
            }
        }];

        NSLog(@"[NoNotchLetterbox] Universal notch bypass (layer-elevation) successfully activated in %s (PID %d)", getprogname(), getpid());
    });
}
