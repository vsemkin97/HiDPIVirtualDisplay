//
//  SeamlessFullscreenManager.swift
//  HiDPIDisplay (G9 Helper)
//
//  Universal in-memory notch bypass manager for browsers and media players.
//  Injects seamless fullscreen hooks dynamically into process memory via LLDB
//  so fullscreen video (YouTube, Netflix, etc.) takes 100% of the display with 0 black bar
//  and 0 separator line, while keeping binaries on disk 100% factory original (preserving Keychain & code signatures).
//

import Foundation
import AppKit

class SeamlessFullscreenManager {
    static let shared = SeamlessFullscreenManager()

    private let kEnabledKey = "enableSeamlessFullscreen"
    private var isRunning = false
    private var launchObserver: NSObjectProtocol?

    // Known target application bundle identifiers
    private let targetBundleIdentifiers: [String] = [
        "com.google.Chrome.dev",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "org.chromium.Chromium",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser", // Arc
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "org.videolan.vlc",
        "com.colliderli.iina"
    ]

    private let targetNames: [String] = [
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

    var isEnabled: Bool {
        get {
            // Default to true if Notch Menu Bar is enabled
            if UserDefaults.standard.object(forKey: kEnabledKey) == nil {
                return UserDefaults.standard.bool(forKey: "enableNotchMenuBar")
            }
            return UserDefaults.standard.bool(forKey: kEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: kEnabledKey)
            if newValue {
                applyToAllDetectedApps()
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        self.isEnabled = enabled
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        NSLog("[SeamlessFullscreenManager] Starting manager (enabled=%@)", isEnabled ? "YES" : "NO")

        // Clean up any stale wrapper scripts or modified binaries from older builds
        cleanupLegacyWrappers()

        if isEnabled {
            applyToAllDetectedApps()
        }

        // Watch for application launches to automatically inject hooks into memory
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: OperationQueue.main
        ) { [weak self] note in
            guard let self = self, self.isEnabled else { return }
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                let bundleId = app.bundleIdentifier ?? ""
                let name = app.localizedName ?? ""
                if self.targetBundleIdentifiers.contains(bundleId) || self.targetNames.contains(name) {
                    NSLog("[SeamlessFullscreenManager] Detected launch of %@ (PID %d), injecting...", name, app.processIdentifier)
                    // Slight delay to allow AppKit window infrastructure to initialize
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.0) {
                        self.applyToPID(app.processIdentifier)
                    }
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let observer = launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            launchObserver = nil
        }
    }

    // MARK: - Resource Paths

    private var injectScriptURL: URL? {
        if let bundleURL = Bundle.main.url(forResource: "inject_seamless_fullscreen", withExtension: "py") {
            return bundleURL
        }
        let installed = URL(fileURLWithPath: "/Applications/G9 Helper.app/Contents/Resources/inject_seamless_fullscreen.py")
        if FileManager.default.fileExists(atPath: installed.path) {
            return installed
        }
        let devPath = URL(fileURLWithPath: "/Users/vladislav/РАБстол/HiDPIVirtualDisplay-add/clean_version/App/Resources/inject_seamless_fullscreen.py")
        if FileManager.default.fileExists(atPath: devPath.path) {
            return devPath
        }
        return nil
    }

    // MARK: - In-Memory Injection

    func applyToPID(_ pid: pid_t) {
        guard let script = injectScriptURL else {
            NSLog("[SeamlessFullscreenManager] ERROR: inject_seamless_fullscreen.py not found")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = [script.path, String(pid)]
            proc.environment = [
                "PYTHONPATH": "/Library/Developer/CommandLineTools/Library/PrivateFrameworks/LLDB.framework/Resources/Python",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
            ]
            do {
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    NSLog("[SeamlessFullscreenManager] Successfully injected into PID %d", pid)
                } else {
                    NSLog("[SeamlessFullscreenManager] Injection exited with status %d for PID %d", proc.terminationStatus, pid)
                }
            } catch {
                NSLog("[SeamlessFullscreenManager] Failed to launch injector for PID %d: %@", pid, error.localizedDescription)
            }
        }
    }

    func applyToAllDetectedApps() {
        guard let script = injectScriptURL else {
            NSLog("[SeamlessFullscreenManager] ERROR: inject_seamless_fullscreen.py not found")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            proc.arguments = [script.path, "--all"]
            proc.environment = [
                "PYTHONPATH": "/Library/Developer/CommandLineTools/Library/PrivateFrameworks/LLDB.framework/Resources/Python",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"
            ]
            do {
                try proc.run()
                proc.waitUntilExit()
                NSLog("[SeamlessFullscreenManager] Completed scan and injection for running apps")
            } catch {
                NSLog("[SeamlessFullscreenManager] Failed to run injector scan: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Legacy Cleanup

    private func cleanupLegacyWrappers() {
        let fm = FileManager.default
        let checkDirs = [
            "/Applications/Google Chrome Dev.app/Contents/MacOS",
            "/Applications/Google Chrome.app/Contents/MacOS",
            "/Applications/Brave Browser.app/Contents/MacOS",
            "/Applications/Microsoft Edge.app/Contents/MacOS",
            "/Applications/Arc.app/Contents/MacOS"
        ]

        for dir in checkDirs {
            guard fm.fileExists(atPath: dir) else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for f in files {
                if f.hasSuffix(".real") {
                    let baseName = (f as NSString).deletingPathExtension
                    let realPath = (dir as NSString).appendingPathComponent(f)
                    let execPath = (dir as NSString).appendingPathComponent(baseName)
                    let origPath = (dir as NSString).appendingPathComponent("\(baseName).original")

                    NSLog("[SeamlessFullscreenManager] Restoring genuine binary for %@", baseName)
                    try? fm.removeItem(atPath: execPath)
                    if fm.fileExists(atPath: origPath) {
                        try? fm.moveItem(atPath: origPath, toPath: execPath)
                        try? fm.removeItem(atPath: realPath)
                    } else {
                        try? fm.moveItem(atPath: realPath, toPath: execPath)
                    }
                }
            }
        }
    }
}
