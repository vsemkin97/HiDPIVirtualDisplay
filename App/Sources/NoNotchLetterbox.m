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
- (NSRect)nn_notchFrameForSpace:(id)space;
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
- (NSRect)nn_notchFrameForSpace:(id)space {
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
@end

@implementation NSWindow (NoNotch)
- (NSRect)nn_frameForFullScreenMode {
    NSScreen *s = self.screen ?: [NSScreen screens].firstObject;
    return s ? [s frame] : [self frame];
}
- (NSRect)nn_frameForFullScreenModeInRect:(NSRect)r {
    NSScreen *s = self.screen ?: [NSScreen screens].firstObject;
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
        @autoreleasepool {
            Swizzle([NSScreen class], @selector(safeAreaInsets), @selector(nn_safeAreaInsets));
            Swizzle([NSScreen class], @selector(_notchFrame), @selector(nn_notchFrame));
            Swizzle([NSScreen class], @selector(_notchFrameForSpace:), @selector(nn_notchFrameForSpace:));
            Swizzle([NSScreen class], @selector(_safeAreaFrame), @selector(nn_safeAreaFrame));
            Swizzle([NSScreen class], @selector(auxiliaryTopLeftArea), @selector(nn_auxiliaryTopLeftArea));
            Swizzle([NSScreen class], @selector(auxiliaryTopRightArea), @selector(nn_auxiliaryTopRightArea));
            Swizzle([NSWindow class], @selector(_frameForFullScreenMode), @selector(nn_frameForFullScreenMode));
            Swizzle([NSWindow class], @selector(_frameForFullScreenModeInRect:), @selector(nn_frameForFullScreenModeInRect:));
            Swizzle([NSWindow class], @selector(_enforceFullScreenRestrictionForFrame:), @selector(nn_enforceFullScreenRestrictionForFrame:));
            NSLog(@"[NoNotchLetterbox] Universal notch bypass successfully activated in %s (PID %d)", getprogname(), getpid());
        }
    });
}
