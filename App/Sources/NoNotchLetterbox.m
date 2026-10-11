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

static NSHashTable *gFullScreenWindows = nil;

static inline BOOL IsFullScreenWindow(NSWindow *w) {
    if (!w) return NO;
    if (w.styleMask & NSWindowStyleMaskFullScreen) return YES;
    if (gFullScreenWindows && [gFullScreenWindows containsObject:w]) return YES;
    NSScreen *s = [w screen] ?: [NSScreen mainScreen];
    if (s) {
        NSRect wf = [w frame];
        NSRect sf = [s frame];
        // If window covers the screen height (allowing 10pt tolerance for dock/margins),
        // it is a fullscreen window (such as Chromium's BrowserNativeWidgetWindow).
        if (wf.size.height >= sf.size.height - 10.0 && wf.size.width >= sf.size.width - 10.0) {
            return YES;
        }
    }
    return NO;
}

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
- (void)nn_setFrame:(NSRect)frameRect display:(BOOL)flag;
- (void)nn_orderFrontRegardless;
- (NSTitlebarSeparatorStyle)nn_titlebarSeparatorStyle;
@end

@implementation NSWindow (NoNotch)
- (NSRect)nn_frameForFullScreenMode {
    NSScreen *s = [self screen] ?: [NSScreen mainScreen];
    if (!s) return [self frame];
    return [s frame];
}
- (NSRect)nn_frameForFullScreenModeInRect:(NSRect)r {
    return [self nn_frameForFullScreenMode];
}
- (NSRect)nn_enforceFullScreenRestrictionForFrame:(NSRect)r {
    return r;
}
- (void)nn_setLevel:(NSInteger)level {
    if (IsFullScreenWindow(self)) {
        [self nn_setLevel:kSeamlessFullScreenWindowLevel];
    } else {
        [self nn_setLevel:level];
    }
}
- (void)nn_setFrame:(NSRect)frameRect display:(BOOL)flag {
    [self nn_setFrame:frameRect display:flag];
    if (IsFullScreenWindow(self)) {
        if (!gFullScreenWindows) {
            gFullScreenWindows = [[NSHashTable weakObjectsHashTable] retain];
        }
        [gFullScreenWindows addObject:self];
        [self nn_setLevel:kSeamlessFullScreenWindowLevel];
        [self nn_orderFrontRegardless];
    }
}
- (void)nn_orderFrontRegardless {
    if (IsFullScreenWindow(self)) {
        [self nn_setLevel:kSeamlessFullScreenWindowLevel];
    }
    [self nn_orderFrontRegardless];
}
- (NSTitlebarSeparatorStyle)nn_titlebarSeparatorStyle {
    return NSTitlebarSeparatorStyleNone;
}
@end

#pragma mark - Init & Swizzling

static BOOL nn_falseWithDouble(id self, SEL _cmd, double val) {
    return NO;
}

static BOOL nn_falseNoArgs(id self, SEL _cmd) {
    return NO;
}

__attribute__((constructor))
static void InitNoNotch(void) {
    unsetenv("DYLD_INSERT_LIBRARIES");
    const char *prog = getprogname();
    if (prog && (strstr(prog, "Helper") || strstr(prog, "crashpad") || strstr(prog, "renderer"))) {
        return;
    }

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gFullScreenWindows = [[NSHashTable weakObjectsHashTable] retain];

        // 1. NSScreen notch, safe area, and menubar height bypass
        Swizzle([NSScreen class], @selector(safeAreaInsets), @selector(nn_safeAreaInsets));
        Swizzle([NSScreen class], @selector(_notchFrame), @selector(nn_notchFrame));
        Swizzle([NSScreen class], @selector(_notchFrameForSpace:), @selector(nn_notchFrameForSpace:));
        Swizzle([NSScreen class], @selector(_safeAreaFrame), @selector(nn_safeAreaFrame));
        Swizzle([NSScreen class], @selector(auxiliaryTopLeftArea), @selector(nn_auxiliaryTopLeftArea));
        Swizzle([NSScreen class], @selector(auxiliaryTopRightArea), @selector(nn_auxiliaryTopRightArea));

        // 2. NSView safe area bypass (ensures web views compute zero top margin)
        Swizzle([NSView class], @selector(safeAreaInsets), @selector(nn_viewSafeAreaInsets));

        // 3. NSWindow fullscreen frame, level elevation, orderFront, and titlebar separator removal
        Swizzle([NSWindow class], @selector(_frameForFullScreenMode), @selector(nn_frameForFullScreenMode));
        Swizzle([NSWindow class], @selector(_frameForFullScreenModeInRect:), @selector(nn_frameForFullScreenModeInRect:));
        Swizzle([NSWindow class], @selector(_enforceFullScreenRestrictionForFrame:), @selector(nn_enforceFullScreenRestrictionForFrame:));
        Swizzle([NSWindow class], @selector(setLevel:), @selector(nn_setLevel:));
        Swizzle([NSWindow class], @selector(setFrame:display:), @selector(nn_setFrame:display:));
        Swizzle([NSWindow class], @selector(orderFrontRegardless), @selector(nn_orderFrontRegardless));
        Swizzle([NSWindow class], @selector(titlebarSeparatorStyle), @selector(nn_titlebarSeparatorStyle));

        // 4. AppKit FullScreen companion controller baseline and backstop elimination
        // Kills the 1-pixel baseline separator line and opaque curtain drawn below the fullscreen menu bar
        Class companion = objc_getClass("_NSFullScreenMenuBarCompanionController");
        if (companion) {
            SEL sBaseline = sel_registerName("_shouldDrawBaselineForEffectiveReveal:");
            SEL sBackstop = sel_registerName("needsOpaqueBackstop");
            Method m1 = class_getInstanceMethod(companion, sBaseline);
            Method m2 = class_getInstanceMethod(companion, sBackstop);
            if (m1) method_setImplementation(m1, (IMP)nn_falseWithDouble);
            if (m2) method_setImplementation(m2, (IMP)nn_falseNoArgs);
        }

        // 5. AppKit titlebar hairline separator elimination
        Class themeFrame = objc_getClass("NSThemeFrame");
        if (themeFrame) {
            SEL sel = sel_registerName("_needsTitlebarSeparator");
            Method orig = class_getInstanceMethod(themeFrame, sel);
            if (orig) method_setImplementation(orig, (IMP)nn_falseNoArgs);
        }

        Class titlebarContainer = objc_getClass("NSTitlebarContainerView");
        if (titlebarContainer) {
            SEL s1 = sel_registerName("drawsBottomSeparator");
            SEL s2 = sel_registerName("drawsBottomDividerWhenTransparent");
            SEL s3 = sel_registerName("drawsDecorationView");
            Method orig1 = class_getInstanceMethod(titlebarContainer, s1);
            Method orig2 = class_getInstanceMethod(titlebarContainer, s2);
            Method orig3 = class_getInstanceMethod(titlebarContainer, s3);
            if (orig1) method_setImplementation(orig1, (IMP)nn_falseNoArgs);
            if (orig2) method_setImplementation(orig2, (IMP)nn_falseNoArgs);
            if (orig3) method_setImplementation(orig3, (IMP)nn_falseNoArgs);
        }

        // 5. Notification listeners to elevate window above WindowServer Menubar (layer 24)
        // and eliminate any titlebar separator style on fullscreen entry
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillEnterFullScreenNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            if ([note.object isKindOfClass:[NSWindow class]]) {
                NSWindow *w = (NSWindow *)note.object;
                [gFullScreenWindows addObject:w];
                [w nn_setLevel:kSeamlessFullScreenWindowLevel];
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
                [gFullScreenWindows addObject:w];
                [w nn_setLevel:kSeamlessFullScreenWindowLevel];
                if ([w respondsToSelector:@selector(setTitlebarSeparatorStyle:)]) {
                    [w setTitlebarSeparatorStyle:NSTitlebarSeparatorStyleNone];
                }
                [w nn_orderFrontRegardless];
            }
        }];

        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidExitFullScreenNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            if ([note.object isKindOfClass:[NSWindow class]]) {
                NSWindow *w = (NSWindow *)note.object;
                [gFullScreenWindows removeObject:w];
                [w nn_setLevel:NSNormalWindowLevel];
            }
        }];

        NSLog(@"[NoNotchLetterbox] Universal notch bypass (v4 - seamless geometry & level elevation) successfully activated in %s (PID %d)", getprogname(), getpid());
    });
}
