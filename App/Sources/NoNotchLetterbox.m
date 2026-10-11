#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

static void Swizzle(Class cls, SEL origSel, SEL newSel) {
    if (!cls || !origSel || !newSel) return;
    Method orig = class_getInstanceMethod(cls, origSel);
    Method newM = class_getInstanceMethod(cls, newSel);
    if (orig && newM) {
        method_exchangeImplementations(orig, newM);
    }
}

// Fullscreen window level: layer 100 sits above WindowServer Menubar (24),
// status items (25), and desktop notch overlays (26), while remaining
// below popup/context menus (101).
static const NSInteger kSeamlessFullScreenWindowLevel = 100;

#pragma mark - NSScreen (NoNotch)

@interface NSScreen (NoNotch)
- (NSEdgeInsets)nn_safeAreaInsets;
- (NSRect)nn_notchFrame;
- (NSRect)nn_notchFrameForSpace:(uint64_t)space;
- (NSRect)nn_safeAreaFrame;
- (NSRect)nn_auxiliaryTopLeftArea;
- (NSRect)nn_auxiliaryTopRightArea;
- (double)nn_zeroDouble;
- (BOOL)nn_falseBool;
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
- (double)nn_zeroDouble {
    return 0.0;
}
- (BOOL)nn_falseBool {
    return NO;
}
@end

#pragma mark - NSView (NoNotch)

@interface NSView (NoNotch)
- (NSEdgeInsets)nn_viewSafeAreaInsets;
@end

@implementation NSView (NoNotch)
- (NSEdgeInsets)nn_viewSafeAreaInsets {
    return NSEdgeInsetsZero;
}
@end

#pragma mark - NSWindow (NoNotch)

@interface NSWindow (NoNotch)
- (NSRect)nn_frameForFullScreenMode;
- (NSRect)nn_frameForFullScreenModeInRect:(NSRect)r;
- (NSRect)nn_enforceFullScreenRestrictionForFrame:(NSRect)r;
- (void)nn_setLevel:(NSInteger)level;
- (NSTitlebarSeparatorStyle)nn_titlebarSeparatorStyle;
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
        [self nn_setLevel:kSeamlessFullScreenWindowLevel];
    } else {
        [self nn_setLevel:level];
    }
}
- (NSTitlebarSeparatorStyle)nn_titlebarSeparatorStyle {
    return NSTitlebarSeparatorStyleNone;
}
@end

#pragma mark - Init & Swizzling

__attribute__((constructor))
static void InitNoNotch(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 1. NSScreen notch, safe area, and menubar height bypass
        Swizzle([NSScreen class], @selector(safeAreaInsets), @selector(nn_safeAreaInsets));
        Swizzle([NSScreen class], @selector(_notchFrame), @selector(nn_notchFrame));
        Swizzle([NSScreen class], @selector(_notchFrameForSpace:), @selector(nn_notchFrameForSpace:));
        Swizzle([NSScreen class], @selector(_safeAreaFrame), @selector(nn_safeAreaFrame));
        Swizzle([NSScreen class], @selector(auxiliaryTopLeftArea), @selector(nn_auxiliaryTopLeftArea));
        Swizzle([NSScreen class], @selector(auxiliaryTopRightArea), @selector(nn_auxiliaryTopRightArea));
        Swizzle([NSScreen class], sel_registerName("_layoutMenuBarHeight"), @selector(nn_zeroDouble));
        Swizzle([NSScreen class], sel_registerName("_restingMenuBarHeight"), @selector(nn_zeroDouble));
        Swizzle([NSScreen class], sel_registerName("_revealedMenuBarHeight"), @selector(nn_zeroDouble));
        Swizzle([NSScreen class], sel_registerName("_layoutForcingRevealedMenuBarHeight"), @selector(nn_falseBool));

        // 2. NSView safe area bypass (ensures web views compute zero top margin)
        Swizzle([NSView class], @selector(safeAreaInsets), @selector(nn_viewSafeAreaInsets));

        // 3. NSWindow fullscreen frame, level elevation, and titlebar separator removal
        Swizzle([NSWindow class], @selector(_frameForFullScreenMode), @selector(nn_frameForFullScreenMode));
        Swizzle([NSWindow class], @selector(_frameForFullScreenModeInRect:), @selector(nn_frameForFullScreenModeInRect:));
        Swizzle([NSWindow class], @selector(_enforceFullScreenRestrictionForFrame:), @selector(nn_enforceFullScreenRestrictionForFrame:));
        Swizzle([NSWindow class], @selector(setLevel:), @selector(nn_setLevel:));
        Swizzle([NSWindow class], @selector(titlebarSeparatorStyle), @selector(nn_titlebarSeparatorStyle));

        // 4. AppKit titlebar hairline separator elimination
        // Prevents AppKit from drawing 1-pixel bottom separators under titlebar / menu bar
        Class themeFrame = objc_getClass("NSThemeFrame");
        if (themeFrame) {
            Method m = class_getInstanceMethod([NSScreen class], @selector(nn_falseBool));
            if (m) {
                SEL sel = sel_registerName("_needsTitlebarSeparator");
                Method orig = class_getInstanceMethod(themeFrame, sel);
                if (orig) method_setImplementation(orig, method_getImplementation(m));
            }
        }

        Class titlebarContainer = objc_getClass("NSTitlebarContainerView");
        if (titlebarContainer) {
            Method m = class_getInstanceMethod([NSScreen class], @selector(nn_falseBool));
            if (m) {
                SEL s1 = sel_registerName("drawsBottomSeparator");
                SEL s2 = sel_registerName("drawsBottomDividerWhenTransparent");
                SEL s3 = sel_registerName("drawsDecorationView");
                Method orig1 = class_getInstanceMethod(titlebarContainer, s1);
                Method orig2 = class_getInstanceMethod(titlebarContainer, s2);
                Method orig3 = class_getInstanceMethod(titlebarContainer, s3);
                if (orig1) method_setImplementation(orig1, method_getImplementation(m));
                if (orig2) method_setImplementation(orig2, method_getImplementation(m));
                if (orig3) method_setImplementation(orig3, method_getImplementation(m));
            }
        }

        // 5. NSCGSDisplay (AppKit low-level display cache)
        Class cgsDisplay = objc_getClass("NSCGSDisplay");
        if (cgsDisplay) {
            Method zeroRectM = class_getInstanceMethod([NSScreen class], @selector(nn_notchFrame));
            Method zeroDblM = class_getInstanceMethod([NSScreen class], @selector(nn_zeroDouble));
            if (zeroRectM) {
                Method orig = class_getInstanceMethod(cgsDisplay, sel_registerName("notchFrame"));
                if (orig) method_setImplementation(orig, method_getImplementation(zeroRectM));
            }
            if (zeroDblM) {
                Method orig = class_getInstanceMethod(cgsDisplay, sel_registerName("revealedMenuBarHeight"));
                if (orig) method_setImplementation(orig, method_getImplementation(zeroDblM));
            }
        }

        // 6. Notification listeners to elevate window above WindowServer Menubar (layer 24)
        // and eliminate any titlebar separator style on fullscreen entry
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillEnterFullScreenNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            if ([note.object isKindOfClass:[NSWindow class]]) {
                NSWindow *w = (NSWindow *)note.object;
                [w setLevel:kSeamlessFullScreenWindowLevel];
                if ([w respondsToSelector:@selector(setTitlebarSeparatorStyle:)]) {
                    [w setTitlebarSeparatorStyle:NSTitlebarSeparatorStyleNone];
                }
            }
        }];

        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidEnterFullScreenNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            if ([note.object isKindOfClass:[NSWindow class]]) {
                NSWindow *w = (NSWindow *)note.object;
                [w setLevel:kSeamlessFullScreenWindowLevel];
                if ([w respondsToSelector:@selector(setTitlebarSeparatorStyle:)]) {
                    [w setTitlebarSeparatorStyle:NSTitlebarSeparatorStyleNone];
                }
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

        NSLog(@"[NoNotchLetterbox] Universal notch bypass (v3 - seamless borderless) successfully activated in %s (PID %d)", getprogname(), getpid());
    });
}
