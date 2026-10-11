package main

import (
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Supported browser and player application names
var targetProcessNames = []string{
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
	"IINA",
}

// Injected Objective-C++ script (evaluated in target process memory via LLDB)
const injectionScript = `(void*)({
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
})`

type TargetProcess struct {
	PID  int
	Name string
}

func findTargetPIDs() []TargetProcess {
	var targets []TargetProcess
	out, err := exec.Command("pgrep", "-l", "-f", "Contents/MacOS/").Output()
	if err != nil {
		return targets
	}

	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, " ", 2)
		if len(parts) < 2 {
			continue
		}
		pidStr := parts[0]
		cmd := strings.TrimSpace(parts[1])

		if strings.HasPrefix(cmd, "/System/") {
			continue
		}

		pid, err := strconv.Atoi(pidStr)
		if err != nil {
			continue
		}

		exe := strings.TrimSpace(strings.Split(cmd, " --")[0])
		exeName := filepath.Base(exe)

		for _, target := range targetProcessNames {
			if (exeName == target || strings.Contains(cmd, "/"+target+".app/")) &&
				!strings.Contains(cmd, "Helper") &&
				!strings.Contains(cmd, "crashpad") &&
				!strings.Contains(cmd, "renderer") {
				targets = append(targets, TargetProcess{PID: pid, Name: target})
				break
			}
		}
	}
	return targets
}

func buildLLDBCommands() string {
	var b strings.Builder
	b.WriteString("expr -l objc++ --\n")
	for _, line := range strings.Split(injectionScript, "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			b.WriteString("//\n")
		} else {
			b.WriteString(line + "\n")
		}
	}
	b.WriteString("\ndetach\nquit\n")
	return b.String()
}

func injectPID(pid int) error {
	// Write temporary LLDB script
	tmpFile, err := os.CreateTemp("", "g9_inject_*.lldb")
	if err != nil {
		return fmt.Errorf("failed to create temp script: %w", err)
	}
	tmpPath := tmpFile.Name()
	defer os.Remove(tmpPath)

	commands := buildLLDBCommands()
	if _, err := tmpFile.WriteString(commands); err != nil {
		tmpFile.Close()
		return fmt.Errorf("failed to write script: %w", err)
	}
	tmpFile.Close()

	// Execute lldb batch mode
	cmd := exec.Command("/usr/bin/lldb", "--batch", "-p", strconv.Itoa(pid), "-s", tmpPath)
	output, err := cmd.CombinedOutput()
	outStr := string(output)

	if err != nil {
		return fmt.Errorf("lldb error (%w): %s", err, outStr)
	}
	if strings.Contains(outStr, "error:") {
		return fmt.Errorf("lldb execution error: %s", outStr)
	}

	return nil
}

func isG9HelperRunning() bool {
	out, err := exec.Command("pgrep", "-f", "HiDPIDisplay").Output()
	return err == nil && strings.TrimSpace(string(out)) != ""
}

func runDaemon() {
	parentPID := os.Getppid()
	isChildOfG9 := false
	if parentPID > 1 {
		out, err := exec.Command("ps", "-p", strconv.Itoa(parentPID), "-o", "comm=").Output()
		if err == nil && strings.Contains(string(out), "HiDPIDisplay") {
			isChildOfG9 = true
		}
	}

	if !isChildOfG9 && !isG9HelperRunning() {
		fmt.Println("[!] G9 Helper (HiDPIDisplay) is not running. Exiting.")
		return
	}

	fmt.Printf("[*] G9 Helper Seamless Fullscreen native daemon started (parent PID %d, child=%v). Monitoring browsers...\n", parentPID, isChildOfG9)

	injectedPIDs := make(map[int]bool)
	failedCounts := make(map[int]int)
	lastAttempt := make(map[int]time.Time)

	ticker := time.NewTicker(1500 * time.Millisecond)
	defer ticker.Stop()

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	for {
		select {
		case <-sigChan:
			fmt.Println("[*] Seamless Fullscreen daemon shutting down.")
			return
		case <-ticker.C:
			// Automatically exit if G9 Helper was closed or quit
			if isChildOfG9 {
				if os.Getppid() != parentPID || syscall.Kill(parentPID, 0) != nil {
					fmt.Println("[*] Parent G9 Helper stopped. Daemon exiting.")
					return
				}
			} else {
				if !isG9HelperRunning() {
					fmt.Println("[*] G9 Helper stopped. Daemon exiting.")
					return
				}
			}

			targets := findTargetPIDs()
			activePIDs := make(map[int]bool)
			for _, t := range targets {
				activePIDs[t.PID] = true
			}

			// Clean up exited PIDs
			for p := range injectedPIDs {
				if !activePIDs[p] {
					delete(injectedPIDs, p)
				}
			}
			for p := range failedCounts {
				if !activePIDs[p] {
					delete(failedCounts, p)
					delete(lastAttempt, p)
				}
			}

			// Process detected targets
			for _, t := range targets {
				if injectedPIDs[t.PID] {
					continue
				}

				fCount := failedCounts[t.PID]
				lastTry := lastAttempt[t.PID]
				if fCount >= 3 && time.Since(lastTry) < 30*time.Second {
					continue
				}

				fmt.Printf("[*] Detected target: %s (PID %d), injecting seamless fullscreen...\n", t.Name, t.PID)
				err := injectPID(t.PID)
				if err == nil {
					injectedPIDs[t.PID] = true
					delete(failedCounts, t.PID)
					delete(lastAttempt, t.PID)
					fmt.Printf("    [+] Successfully injected %s (PID %d)\n", t.Name, t.PID)
				} else {
					failedCounts[t.PID] = fCount + 1
					lastAttempt[t.PID] = time.Now()
					fmt.Fprintf(os.Stderr, "    [!] Injection failed for %s (PID %d) (attempt %d): %v\n", t.Name, t.PID, fCount+1, err)
				}
			}
		}
	}
}

func main() {
	if len(os.Args) > 1 {
		arg := os.Args[1]
		if arg == "--daemon" {
			runDaemon()
			return
		}
		if arg == "--all" {
			targets := findTargetPIDs()
			if len(targets) == 0 {
				fmt.Println("[*] No running target browsers or media players found.")
				return
			}
			for _, t := range targets {
				fmt.Printf("[*] Injecting %s (PID %d)...\n", t.Name, t.PID)
				if err := injectPID(t.PID); err != nil {
					fmt.Fprintf(os.Stderr, "    [!] Error: %v\n", err)
				} else {
					fmt.Printf("    [+] Successfully injected %s (PID %d)\n", t.Name, t.PID)
				}
			}
			return
		}

		pid, err := strconv.Atoi(arg)
		if err == nil {
			if err := injectPID(pid); err != nil {
				fmt.Fprintf(os.Stderr, "[!] Failed to inject PID %d: %v\n", pid, err)
				os.Exit(1)
			}
			fmt.Printf("[+] Seamless fullscreen successfully activated in PID %d\n", pid)
			return
		}
	}

	// Default to daemon mode when invoked with no args or --daemon
	runDaemon()
}
