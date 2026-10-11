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
            if cmd.startswith("/System/"):
                continue
            exe = cmd.split(" --")[0].strip()
            exe_name = os.path.basename(exe)
            for target in TARGET_PROCESS_NAMES:
                # Target the main executable only, avoiding Helper / renderer processes
                if (exe_name == target or f"/{target}.app/" in cmd) and "Helper" not in cmd and "crashpad" not in cmd and "renderer" not in cmd:
                    try:
                        pids.append((int(pid_str), target))
                    except ValueError:
                        pass
                    break
    except Exception:
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
        BOOL (*fn_addMethod)(void*, SEL, void*, const char*) = (BOOL(*)(void*, SEL, void*, const char*))class_addMethod;
        void (*fn_exchange)(void*, void*) = (void(*)(void*, void*))method_exchangeImplementations;
        char* (*fn_strstr)(const char*, const char*) = (char*(*)(const char*, const char*))dlsym((void*)-2, "strstr");

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

        // 1. Companion controller: eliminate 1-px baseline separator & blackout curtain
        hook("_NSFullScreenMenuBarCompanionController", "_shouldDrawBaselineForEffectiveReveal:",
             (id)^(id _self, double r) { return (BOOL)0; });
        hook("_NSFullScreenMenuBarCompanionController", "needsOpaqueBackstop",
             (id)^(id _self) { return (BOOL)0; });
        hook("_NSFullScreenMenuBarCompanionController", "setNeedsOpaqueBackstop:",
             (id)^(id _self, BOOL flag) { /* no-op: never show blackout curtain */ });

        // 2. Titlebar hairline separator elimination
        hook("NSThemeFrame", "_needsTitlebarSeparator",
             (id)^(id _self) { return (BOOL)0; });
        hook("NSTitlebarContainerView", "drawsBottomSeparator",
             (id)^(id _self) { return (BOOL)0; });
        hook("NSTitlebarContainerView", "drawsBottomDividerWhenTransparent",
             (id)^(id _self) { return (BOOL)0; });
        hook("NSTitlebarContainerView", "drawsDecorationView",
             (id)^(id _self) { return (BOOL)0; });
        hook("_NSTitlebarDecorationView", "drawsBottomSeparator",
             (id)^(id _self) { return (BOOL)0; });
        hook("_NSTitlebarDecorationView", "setDrawsBottomSeparator:",
             (id)^(id _self, BOOL flag) { /* no-op */ });
        hook("_NSTitlebarDecorationView", "_updateBottomSeparatorLayer",
             (id)^(id _self) { /* no-op */ });
        hook("NSToolbarFullScreenWindow", "hasShadow",
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

        // 6. Safe setLevel: swizzle via method_exchangeImplementations and objc_msgSend
        void *clsWindow = fn_getClass("NSWindow");
        SEL sSetLevel = fn_sel("setLevel:");
        SEL sOrigSetLevel = fn_sel("__g9_orig_setLevel:");

        id blkLevel = (id)^(id _self, long lvl) {
            SEL (*f_sel)(const char*) = (SEL(*)(const char*))dlsym((void*)-2, "sel_registerName");
            long mask = ((long(*)(id, SEL))objc_msgSend)(_self, f_sel("styleMask"));
            long targetLvl = (mask & (1 << 14)) ? 100 : lvl;
            ((void(*)(id, SEL, long))objc_msgSend)(_self, f_sel("__g9_orig_setLevel:"), targetLvl);
        };

        void *newImp = fn_blockImp(blkLevel);
        if (fn_addMethod(clsWindow, sOrigSetLevel, newImp, "v@:q")) {
            void *m1 = fn_getMethod(clsWindow, sSetLevel);
            void *m2 = fn_getMethod(clsWindow, sOrigSetLevel);
            if (m1 && m2) fn_exchange(m1, m2);
        }

        // 7. Fullscreen lifecycle observers via NSNotificationCenter (zero private method interference)
        id g9_nc = ((id(*)(id, SEL))objc_msgSend)((id)fn_getClass("NSNotificationCenter"), fn_sel("defaultCenter"));
        id g9_opQueue = ((id(*)(id, SEL))objc_msgSend)((id)fn_getClass("NSOperationQueue"), fn_sel("mainQueue"));
        id g9_noteEnter = ((id(*)(id, SEL, const char*))objc_msgSend)((id)fn_getClass("NSString"), fn_sel("stringWithUTF8String:"), "NSWindowDidEnterFullScreenNotification");
        id g9_noteExit = ((id(*)(id, SEL, const char*))objc_msgSend)((id)fn_getClass("NSString"), fn_sel("stringWithUTF8String:"), "NSWindowDidExitFullScreenNotification");

        id g9_blkEnter = (id)^(id g9_note) {
            void* (*f_getClass)(const char*) = (void*(*)(const char*))dlsym((void*)-2, "objc_getClass");
            SEL (*f_sel)(const char*) = (SEL(*)(const char*))dlsym((void*)-2, "sel_registerName");
            char* (*f_strstr)(const char*, const char*) = (char*(*)(const char*, const char*))dlsym((void*)-2, "strstr");

            id g9_targetWin = ((id(*)(id, SEL))objc_msgSend)(g9_note, f_sel("object"));
            if (g9_targetWin) {
                ((void(*)(id, SEL, long))objc_msgSend)(g9_targetWin, f_sel("setLevel:"), 100);
                ((void(*)(id, SEL))objc_msgSend)(g9_targetWin, f_sel("orderFrontRegardless"));
            }

            // Hide companion & overlay windows that cause the 1-pixel seam
            id g9_curApp = ((id(*)(id, SEL))objc_msgSend)((id)f_getClass("NSApplication"), f_sel("sharedApplication"));
            if (g9_curApp) {
                id g9_allWins = ((id(*)(id, SEL))objc_msgSend)(g9_curApp, f_sel("windows"));
                if (g9_allWins) {
                    unsigned long g9_numWins = ((unsigned long(*)(id, SEL))objc_msgSend)(g9_allWins, f_sel("count"));
                    for (unsigned long g9_i = 0; g9_i < g9_numWins; g9_i++) {
                        id g9_curW = ((id(*)(id, SEL, unsigned long))objc_msgSend)(g9_allWins, f_sel("objectAtIndex:"), g9_i);
                        if (g9_curW) {
                            id g9_cName = ((id(*)(id, SEL))objc_msgSend)(g9_curW, f_sel("className"));
                            const char *g9_cStr = g9_cName ? (const char*)((id(*)(id, SEL))objc_msgSend)(g9_cName, f_sel("UTF8String")) : 0;
                            if (g9_cStr && (f_strstr(g9_cStr, "NSToolbarFullScreenWindow") || f_strstr(g9_cStr, "NativeWidgetMacOverlayNSWindow"))) {
                                ((void(*)(id, SEL, SEL, id, BOOL))objc_msgSend)(
                                    g9_curW,
                                    f_sel("performSelectorOnMainThread:withObject:waitUntilDone:"),
                                    f_sel("orderOut:"),
                                    nil,
                                    NO
                                );
                            }
                        }
                    }
                }
            }
        };

        id g9_blkExit = (id)^(id g9_note) {
            SEL (*f_sel)(const char*) = (SEL(*)(const char*))dlsym((void*)-2, "sel_registerName");
            id g9_targetWin = ((id(*)(id, SEL))objc_msgSend)(g9_note, f_sel("object"));
            if (g9_targetWin) {
                ((void(*)(id, SEL, long))objc_msgSend)(g9_targetWin, f_sel("setLevel:"), 0);
            }
        };

        ((void(*)(id, SEL, id, id, id, id))objc_msgSend)(g9_nc, fn_sel("addObserverForName:object:queue:usingBlock:"), g9_noteEnter, nil, g9_opQueue, g9_blkEnter);
        ((void(*)(id, SEL, id, id, id, id))objc_msgSend)(g9_nc, fn_sel("addObserverForName:object:queue:usingBlock:"), g9_noteExit, nil, g9_opQueue, g9_blkExit);

        // 8. Elevate any currently active fullscreen windows and hide overlay seams right now
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
                            ((void(*)(id, SEL, long))objc_msgSend)(w, sSetLevel, 100);
                            ((void(*)(id, SEL))objc_msgSend)(w, fn_sel("orderFrontRegardless"));
                        }
                        id cNameObj = ((id(*)(id, SEL))objc_msgSend)(w, fn_sel("className"));
                        const char *cNameStr = cNameObj ? (const char*)((id(*)(id, SEL))objc_msgSend)(cNameObj, fn_sel("UTF8String")) : 0;
                        if (cNameStr && (fn_strstr(cNameStr, "NSToolbarFullScreenWindow") || fn_strstr(cNameStr, "NativeWidgetMacOverlayNSWindow"))) {
                            ((void(*)(id, SEL, SEL, id, BOOL))objc_msgSend)(
                                w,
                                fn_sel("performSelectorOnMainThread:withObject:waitUntilDone:"),
                                fn_sel("orderOut:"),
                                nil,
                                NO
                            );
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

def run_daemon():
    import time
    print("[*] G9 Helper Seamless Fullscreen daemon started. Monitoring browsers and media players...", flush=True)
    injected_pids = set()
    failed_counts = {}
    while True:
        try:
            targets = find_target_pids()
            active_pids = {pid for pid, _ in targets}
            injected_pids.intersection_update(active_pids)
            for p in list(failed_counts.keys()):
                if p not in active_pids:
                    del failed_counts[p]

            for pid, name in targets:
                if pid not in injected_pids:
                    f_count, last_try = failed_counts.get(pid, (0, 0))
                    now = time.time()
                    if f_count >= 3 and (now - last_try) < 30.0:
                        continue

                    print(f"[*] Detected target: {name} (PID {pid}), injecting seamless fullscreen...", flush=True)
                    if inject_pid(pid):
                        injected_pids.add(pid)
                        if pid in failed_counts:
                            del failed_counts[pid]
                        print(f"    [+] Successfully injected {name} (PID {pid})", flush=True)
                    else:
                        failed_counts[pid] = (f_count + 1, now)
                        print(f"    [!] Injection failed for {name} (PID {pid}) (attempt {f_count + 1})", file=sys.stderr, flush=True)
        except Exception as e:
            print(f"[!] Daemon error: {e}", file=sys.stderr, flush=True)
        time.sleep(1.5)

def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--daemon":
        run_daemon()
        return

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
