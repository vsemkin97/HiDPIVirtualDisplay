#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

static void Swizzle(Class cls, SEL origSel, SEL newSel) {
    if (!cls) return;
    Method orig = class_getInstanceMethod(cls, origSel);
    Method newM = class_getInstanceMethod([NSObject class], newSel);
    if (!orig || !newM) return;
    IMP newIMP = method_getImplementation(newM);
    const char *types = method_getTypeEncoding(orig);
    class_addMethod(cls, newSel, newIMP, types);
    Method added = class_getInstanceMethod(cls, newSel);
    if (added) {
        method_exchangeImplementations(orig, added);
    }
}

@interface NSObject (NoNotchHelpers)
- (NSEdgeInsets)nn_zeroEdgeInsets;
- (NSRect)nn_zeroRect;
- (NSRect)nn_zeroRectForSpace:(uint64_t)space;
- (double)nn_zeroDouble;
- (BOOL)nn_falseBool;
- (void)nn_noopWithBool:(BOOL)b;
@end

@implementation NSObject (NoNotchHelpers)
- (NSEdgeInsets)nn_zeroEdgeInsets { return NSEdgeInsetsZero; }
- (NSRect)nn_zeroRect { return NSZeroRect; }
- (NSRect)nn_zeroRectForSpace:(uint64_t)space { return NSZeroRect; }
- (double)nn_zeroDouble { return 0.0; }
- (BOOL)nn_falseBool { return NO; }
- (void)nn_noopWithBool:(BOOL)b { }
@end

@interface NSScreen (NoNotchCustom)
- (NSRect)nn_safeAreaFrame;
@end

@implementation NSScreen (NoNotchCustom)
- (NSRect)nn_safeAreaFrame {
    return [self frame];
}
@end

@interface NSWindow (NoNotchCustom)
- (NSRect)nn_frameForFullScreenMode;
- (NSRect)nn_frameForFullScreenModeInRect:(NSRect)r;
- (NSRect)nn_enforceFullScreenRestrictionForFrame:(NSRect)r;
@end

@implementation NSWindow (NoNotchCustom)
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
@end

__attribute__((constructor))
static void InitNoNotch(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 1. NSScreen notch & safe area overrides
        Swizzle([NSScreen class], @selector(safeAreaInsets), @selector(nn_zeroEdgeInsets));
        Swizzle([NSScreen class], @selector(_notchFrame), @selector(nn_zeroRect));
        Swizzle([NSScreen class], @selector(_notchFrameForSpace:), @selector(nn_zeroRectForSpace:));
        Swizzle([NSScreen class], @selector(_safeAreaFrame), @selector(nn_safeAreaFrame));
        Swizzle([NSScreen class], @selector(auxiliaryTopLeftArea), @selector(nn_zeroRect));
        Swizzle([NSScreen class], @selector(auxiliaryTopRightArea), @selector(nn_zeroRect));
        Swizzle([NSScreen class], sel_registerName("_revealedMenuBarHeight"), @selector(nn_zeroDouble));
        Swizzle([NSScreen class], sel_registerName("_layoutForcingRevealedMenuBarHeight"), @selector(nn_falseBool));

        // 2. NSCGSDisplay (AppKit low-level display cache)
        Class cgsDisplay = objc_getClass("NSCGSDisplay");
        if (cgsDisplay) {
            Swizzle(cgsDisplay, sel_registerName("notchFrame"), @selector(nn_zeroRect));
            Swizzle(cgsDisplay, sel_registerName("revealedMenuBarHeight"), @selector(nn_zeroDouble));
        }

        // 3. NSWindow full screen framing
        Swizzle([NSWindow class], @selector(_frameForFullScreenMode), @selector(nn_frameForFullScreenMode));
        Swizzle([NSWindow class], @selector(_frameForFullScreenModeInRect:), @selector(nn_frameForFullScreenModeInRect:));
        Swizzle([NSWindow class], @selector(_enforceFullScreenRestrictionForFrame:), @selector(nn_enforceFullScreenRestrictionForFrame:));

        // 4. _NSFullScreenSpace (prevents space from keeping menu bar reserved)
        Class fsSpace = objc_getClass("_NSFullScreenSpace");
        if (fsSpace) {
            Swizzle(fsSpace, sel_registerName("alwaysReservesSpaceForMenuBarInFullScreen"), @selector(nn_falseBool));
        }

        // 5. _NSFullScreenContentController
        Class fsContent = objc_getClass("_NSFullScreenContentController");
        if (fsContent) {
            Swizzle(fsContent, sel_registerName("reservesSpaceForMenuBarInFullScreen"), @selector(nn_falseBool));
            Swizzle(fsContent, sel_registerName("hasAlwaysVisibleMenuBar"), @selector(nn_falseBool));
            Swizzle(fsContent, sel_registerName("visibleMenuBarAllowedInFullScreen"), @selector(nn_falseBool));
        }

        // 6. _NSFullScreenMenuBarCompanionController (blackout curtain & toolbar)
        Class fsCompanion = objc_getClass("_NSFullScreenMenuBarCompanionController");
        if (fsCompanion) {
            Swizzle(fsCompanion, sel_registerName("needsOpaqueBackstop"), @selector(nn_falseBool));
            Swizzle(fsCompanion, sel_registerName("effectiveAutohideHeight"), @selector(nn_zeroDouble));
            Swizzle(fsCompanion, sel_registerName("_visibleWindowHeight"), @selector(nn_zeroDouble));
            Swizzle(fsCompanion, sel_registerName("desiredWindowHeight"), @selector(nn_zeroDouble));
        }

        // 7. Presentation instances (prevents setting always visible menu bar)
        Class mbPres = objc_getClass("NSMenuBarPresentationInstance");
        if (mbPres) {
            Swizzle(mbPres, sel_registerName("_setHasAlwaysVisibleMenuBar:"), @selector(nn_noopWithBool:));
        }
        Class hiPres = objc_getClass("NSHIPresentationInstance");
        if (hiPres) {
            Swizzle(hiPres, sel_registerName("setHasAlwaysVisibleMenuBar:"), @selector(nn_noopWithBool:));
        }

        NSLog(@"[NoNotchLetterbox] Universal notch bypass (v2 complete) successfully activated in %s (PID %d)", getprogname(), getpid());
    });
}
