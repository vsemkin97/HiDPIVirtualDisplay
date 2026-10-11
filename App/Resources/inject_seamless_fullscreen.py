#!/usr/bin/python3
#
# inject_seamless_fullscreen.py
# In-memory seamless fullscreen injector for browsers and media players.
# Eliminates notch letterbox blackout bar and 1-pixel separator line
# without touching binaries on disk or breaking Apple code signatures / Keychain.
#

import sys
import os
import subprocess

# If not running under system Apple Python, re-exec once to ensure compatibility with Apple's LLDB framework
if "CommandLineTools" not in sys.executable and not os.environ.get("_INJECTOR_REEXEC"):
    os.environ["_INJECTOR_REEXEC"] = "1"
    os.execv("/usr/bin/python3", ["/usr/bin/python3"] + sys.argv)



# Ensure LLDB python module is in sys.path
lldb_paths = [
    "/Library/Developer/CommandLineTools/Library/PrivateFrameworks/LLDB.framework/Resources/Python",
    "/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks/LLDB.framework/Resources/Python"
]
for p in lldb_paths:
    if os.path.exists(p) and p not in sys.path:
        sys.path.insert(0, p)

try:
    import lldb
except ImportError:
    print("[!] Failed to import lldb python module. Please ensure Xcode Command Line Tools are installed.", file=sys.stderr)
    sys.exit(1)

TARGET_PROCESS_NAMES = [
    "Google Chrome",
    "Google Chrome Dev",
    "Google Chrome Canary",
    "Google Chrome Beta",
    "Chromium",
    "Brave Browser",
    "Microsoft Edge",
    "Arc",
    "Opera",
    "Vivaldi",
    "VLC",
    "IINA"
]

def find_target_pids():
    pids = []
    try:
        out = subprocess.check_output(["pgrep", "-l", "-f", "Contents/MacOS/"]).decode("utf-8")
        for line in out.strip().split("\n"):
            if not line:
                continue
            parts = line.split(None, 1)
            if len(parts) < 2:
                continue
            pid_str, cmd = parts[0], parts[1]
            for target in TARGET_PROCESS_NAMES:
                # Target the main executable only, avoiding Helper / renderer processes
                if target in cmd and "Helper" not in cmd and "crashpad" not in cmd and "renderer" not in cmd:
                    try:
                        pids.append((int(pid_str), target))
                    except ValueError:
                        pass
                    break
    except Exception as e:
        pass
    return pids

def inject_pid(pid):
    debugger = lldb.SBDebugger.Create()
    debugger.SetAsync(False)
    target = debugger.CreateTargetWithFileAndArch(None, None)
    error = lldb.SBError()
    process = target.AttachToProcessWithID(debugger.GetListener(), pid, error)
    if not error.Success():
        print(f"[!] Attach to PID {pid} failed: {error}", file=sys.stderr)
        return False

    options = lldb.SBExpressionOptions()
    options.SetLanguage(lldb.eLanguageTypeObjC_plus_plus)
    options.SetIgnoreBreakpoints(True)

    script = """
    (void*)({
        struct MyRect { double x, y, w, h; };
        struct MyInsets { double top, left, bottom, right; };

        void* (*fn_getClass)(const char*) = (void*(*)(const char*))objc_getClass;
        SEL (*fn_sel)(const char*) = (SEL(*)(const char*))sel_registerName;
        void* (*fn_getMethod)(void*, SEL) = (void*(*)(void*, SEL))class_getInstanceMethod;
        void* (*fn_getImp)(void*) = (void*(*)(void*))method_getImplementation;
        void* (*fn_setImp)(void*, void*) = (void*(*)(void*, void*))method_setImplementation;
        void* (*fn_blockImp)(id) = (void*(*)(id))imp_implementationWithBlock;

        auto hook = [&](const char *clsName, const char *selName, id blk) {
            void *cls = fn_getClass(clsName);
            if (cls) {
                SEL s = fn_sel(selName);
                void *meth = fn_getMethod(cls, s);
                if (meth) {
                    void *imp = fn_blockImp(blk);
                    if (imp) fn_setImp(meth, imp);
                }
            }
        };

        // 1. Companion controller: eliminate 1-px baseline separator & backstop curtain
        hook("_NSFullScreenMenuBarCompanionController", "_shouldDrawBaselineForEffectiveReveal:",
             (id)^(id _self, double r) { return (BOOL)0; });
        hook("_NSFullScreenMenuBarCompanionController", "needsOpaqueBackstop",
             (id)^(id _self) { return (BOOL)0; });

        // 2. Titlebar hairline separator elimination
        hook("NSThemeFrame", "_needsTitlebarSeparator",
             (id)^(id _self) { return (BOOL)0; });
        hook("NSTitlebarContainerView", "drawsBottomSeparator",
             (id)^(id _self) { return (BOOL)0; });
        hook("NSTitlebarContainerView", "drawsBottomDividerWhenTransparent",
             (id)^(id _self) { return (BOOL)0; });
        hook("NSTitlebarContainerView", "drawsDecorationView",
             (id)^(id _self) { return (BOOL)0; });

        // 3. NSScreen safe area & notch bypass (zero safe area insets and zero notch rects)
        hook("NSScreen", "safeAreaInsets",
             (id)^(id _self) {
                 MyInsets z = {0, 0, 0, 0};
                 return z;
             });
        hook("NSScreen", "_notchFrame",
             (id)^(id _self) {
                 MyRect z = {0, 0, 0, 0};
                 return z;
             });
        hook("NSScreen", "_notchFrameForSpace:",
             (id)^(id _self, unsigned long long sp) {
                 MyRect z = {0, 0, 0, 0};
                 return z;
             });
        hook("NSScreen", "_safeAreaFrame",
             (id)^(id _self) {
                 return ((MyRect(*)(id, SEL))objc_msgSend)(_self, fn_sel("frame"));
             });
        hook("NSScreen", "auxiliaryTopLeftArea",
             (id)^(id _self) {
                 MyRect z = {0, 0, 0, 0};
                 return z;
             });
        hook("NSScreen", "auxiliaryTopRightArea",
             (id)^(id _self) {
                 MyRect z = {0, 0, 0, 0};
                 return z;
             });

        // 4. NSView safe area insets
        hook("NSView", "safeAreaInsets",
             (id)^(id _self) {
                 MyInsets z = {0, 0, 0, 0};
                 return z;
             });

        // 5. NSWindow fullscreen frame & titlebar separator style
        hook("NSWindow", "_frameForFullScreenMode",
             (id)^(id _self) {
                 id s = ((id(*)(id, SEL))objc_msgSend)(_self, fn_sel("screen"));
                 if (!s) s = ((id(*)(id, SEL))objc_msgSend)((id)fn_getClass("NSScreen"), fn_sel("mainScreen"));
                 if (s) return ((MyRect(*)(id, SEL))objc_msgSend)(s, fn_sel("frame"));
                 return ((MyRect(*)(id, SEL))objc_msgSend)(_self, fn_sel("frame"));
             });
        hook("NSWindow", "_frameForFullScreenModeInRect:",
             (id)^(id _self, MyRect r) {
                 id s = ((id(*)(id, SEL))objc_msgSend)(_self, fn_sel("screen"));
                 if (!s) s = ((id(*)(id, SEL))objc_msgSend)((id)fn_getClass("NSScreen"), fn_sel("mainScreen"));
                 if (s) return ((MyRect(*)(id, SEL))objc_msgSend)(s, fn_sel("frame"));
                 return r;
             });
        hook("NSWindow", "_enforceFullScreenRestrictionForFrame:",
             (id)^(id _self, MyRect r) {
                 return r;
             });
        hook("NSWindow", "titlebarSeparatorStyle",
             (id)^(id _self) {
                 return (long)0;
             });

        // 6. Hook setLevel: to automatically elevate fullscreen windows to layer 100
        void *clsWindow = fn_getClass("NSWindow");
        SEL sLevel = fn_sel("setLevel:");
        void *mLevel = fn_getMethod(clsWindow, sLevel);
        if (mLevel) {
            void *origSetLevel = fn_getImp(mLevel);
            id blkLevel = (id)^(id _self, long lvl) {
                long mask = ((long(*)(id, SEL))objc_msgSend)(_self, fn_sel("styleMask"));
                if (mask & (1 << 14)) { // NSWindowStyleMaskFullScreen
                    ((void(*)(id, SEL, long))origSetLevel)(_self, sLevel, 100);
                } else {
                    ((void(*)(id, SEL, long))origSetLevel)(_self, sLevel, lvl);
                }
            };
            void *newImp = fn_blockImp(blkLevel);
            fn_setImp(mLevel, newImp);
        }

        // 7. Elevate any currently active fullscreen windows right now
        id app = ((id(*)(id, SEL))objc_msgSend)((id)fn_getClass("NSApplication"), fn_sel("sharedApplication"));
        if (app) {
            id windows = ((id(*)(id, SEL))objc_msgSend)(app, fn_sel("windows"));
            if (windows) {
                unsigned long winCount = ((unsigned long(*)(id, SEL))objc_msgSend)(windows, fn_sel("count"));
                for (unsigned long idx = 0; idx < winCount; idx++) {
                    id w = ((id(*)(id, SEL, unsigned long))objc_msgSend)(windows, fn_sel("objectAtIndex:"), idx);
                    if (w) {
                        long mask = ((long(*)(id, SEL))objc_msgSend)(w, fn_sel("styleMask"));
                        if (mask & (1 << 14)) {
                            ((void(*)(id, SEL, long))objc_msgSend)(w, sLevel, 100);
                            ((void(*)(id, SEL))objc_msgSend)(w, fn_sel("orderFrontRegardless"));
                        }
                    }
                }
            }
        }

        (void*)1;
    })
    """

    val = target.EvaluateExpression(script, options)
    err = val.GetError()
    if not err.Success():
        print(f"[!] Evaluation error on PID {pid}: {err}", file=sys.stderr)
        process.Detach()
        return False

    process.Detach()
    return True

def main():
    if len(sys.argv) > 1 and sys.argv[1] != "--all":
        try:
            pid = int(sys.argv[1])
            success = inject_pid(pid)
            if success:
                print(f"[+] Seamless fullscreen successfully activated in PID {pid}")
            sys.exit(0 if success else 1)
        except ValueError:
            print(f"[!] Invalid PID: {sys.argv[1]}", file=sys.stderr)
            sys.exit(1)

    targets = find_target_pids()
    if not targets:
        print("[*] No running target browsers or media players found.")
        sys.exit(0)

    for pid, name in targets:
        print(f"[*] Injecting seamless fullscreen into {name} (PID {pid})...")
        if inject_pid(pid):
            print(f"    [+] Successfully injected {name} (PID {pid})")
        else:
            print(f"    [!] Failed to inject {name} (PID {pid})", file=sys.stderr)

if __name__ == "__main__":
    main()
