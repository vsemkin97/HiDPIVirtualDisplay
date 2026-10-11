//
//  SeamlessFullscreenManager.swift
//  HiDPIDisplay (G9 Helper)
//
//  Universal notch bypass manager for browsers and media players.
//  Injects NoNotchLetterbox.dylib via launcher wrapper scripts so fullscreen video
//  (YouTube, Netflix, etc.) takes 100% of the display with 0 black bar under the wide Menu Bar.
//

import Foundation
import AppKit

class SeamlessFullscreenManager {
    static let shared = SeamlessFullscreenManager()

    private let kEnabledKey = "enableSeamlessFullscreen"
    private var isRunning = false
    private var fseventStream: FSEventStreamRef?

    // Known target applications
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

    var isEnabled: Bool {
        get {
            // Default to true if notch menu bar is enabled
            if UserDefaults.standard.object(forKey: kEnabledKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: kEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: kEnabledKey)
            if newValue {
                applyToAllDetectedApps()
            } else {
                revertAllDetectedApps()
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

        if isEnabled {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.applyToAllDetectedApps()
            }
        }

        startDirectoryWatcher()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        stopDirectoryWatcher()
    }

    // MARK: - Resource Paths

    private var helperDylibURL: URL? {
        if let bundleURL = Bundle.main.url(forResource: "NoNotchLetterbox", withExtension: "dylib") {
            return bundleURL
        }
        let installed = URL(fileURLWithPath: "/Applications/G9 Helper.app/Contents/Resources/NoNotchLetterbox.dylib")
        if FileManager.default.fileExists(atPath: installed.path) {
            return installed
        }
        let fallback = URL(fileURLWithPath: "/tmp/NoNotchLetterbox_all.dylib")
        if FileManager.default.fileExists(atPath: fallback.path) {
            return fallback
        }
        return nil
    }

    // MARK: - Target App Detection

    func findInstalledTargetApps() -> [URL] {
        var results: [URL] = []
        for bundleId in targetBundleIdentifiers {
            if let urls = LSCopyApplicationURLsForBundleIdentifier(bundleId as CFString, nil)?.takeRetainedValue() as? [URL] {
                results.append(contentsOf: urls)
            }
        }
        // Also check common static paths
        let commonPaths = [
            "/Applications/Google Chrome Dev.app",
            "/Applications/Google Chrome.app",
            "/Applications/Brave Browser.app",
            "/Applications/Microsoft Edge.app",
            "/Applications/Arc.app",
            "/Applications/VLC.app",
            "/Applications/IINA.app"
        ]
        for p in commonPaths {
            let url = URL(fileURLWithPath: p)
            if FileManager.default.fileExists(atPath: p) && !results.contains(url) {
                results.append(url)
            }
        }
        return results
    }

    // MARK: - Patching

    func isAppPatched(appURL: URL) -> Bool {
        guard let execURL = mainExecutableURL(for: appURL) else { return false }
        let realURL = execURL.deletingPathExtension().appendingPathExtension("real")
        guard FileManager.default.fileExists(atPath: realURL.path) else { return false }

        // Check if execURL is a wrapper script containing DYLD_INSERT_LIBRARIES
        if let content = try? String(contentsOf: execURL, encoding: .utf8) {
            return content.contains("DYLD_INSERT_LIBRARIES") && content.contains("NoNotchLetterbox.dylib")
        }
        return false
    }

    @discardableResult
    func applyPatch(to appURL: URL) -> Bool {
        guard let sourceDylib = helperDylibURL else {
            NSLog("[SeamlessFullscreenManager] ERROR: Helper dylib not found")
            return false
        }
        guard let execURL = mainExecutableURL(for: appURL) else {
            NSLog("[SeamlessFullscreenManager] ERROR: Could not find main executable for %@", appURL.path)
            return false
        }

        let fm = FileManager.default
        let execName = execURL.lastPathComponent
        let execDir = execURL.deletingLastPathComponent()
        let realURL = execDir.appendingPathComponent("\(execName).real")
        let backupURL = execDir.appendingPathComponent("\(execName).original")

        // Clean up any stale in-app Frameworks dylib from previous versions
        let staleDylib = appURL.appendingPathComponent("Contents/Frameworks/NoNotchLetterbox.dylib")
        if fm.fileExists(atPath: staleDylib.path) {
            try? fm.removeItem(at: staleDylib)
        }

        if isAppPatched(appURL: appURL) {
            return true
        }

        do {
            if !fm.fileExists(atPath: realURL.path) {
                if fm.fileExists(atPath: backupURL.path) {
                    // Restore from untouched stock backup if available
                    try fm.copyItem(at: backupURL, to: realURL)
                    if fm.fileExists(atPath: execURL.path) {
                        try fm.removeItem(at: execURL)
                    }
                } else {
                    try fm.copyItem(at: execURL, to: backupURL)
                    try fm.moveItem(at: execURL, to: realURL)
                }
            }

            // Ensure real binary is signed ad-hoc (removes restrict/library-validation flags so DYLD_INSERT_LIBRARIES works)
            let signProc = Process()
            signProc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            signProc.arguments = ["-f", "-s", "-", realURL.path]
            try? signProc.run()
            signProc.waitUntilExit()

            // Create wrapper launcher script
            let scriptContent = """
            #!/bin/bash
            DIR="$(dirname "$0")"
            export DYLD_INSERT_LIBRARIES="\(sourceDylib.path)"
            exec "$DIR/\(execName).real" "$@"

            """

            try scriptContent.write(to: execURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: execURL.path)

            NSLog("[SeamlessFullscreenManager] Successfully installed launcher wrapper for %@", appURL.lastPathComponent)
            return true
        } catch {
            NSLog("[SeamlessFullscreenManager] Failed to apply wrapper to %@: %@", appURL.lastPathComponent, error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func revertPatch(from appURL: URL) -> Bool {
        guard let execURL = mainExecutableURL(for: appURL) else { return false }
        let fm = FileManager.default
        let execName = execURL.lastPathComponent
        let execDir = execURL.deletingLastPathComponent()
        let realURL = execDir.appendingPathComponent("\(execName).real")
        let backupURL = execDir.appendingPathComponent("\(execName).original")
        let staleDylib = appURL.appendingPathComponent("Contents/Frameworks/NoNotchLetterbox.dylib")

        if fm.fileExists(atPath: staleDylib.path) {
            try? fm.removeItem(at: staleDylib)
        }

        let sourceBinary = fm.fileExists(atPath: realURL.path) ? realURL : (fm.fileExists(atPath: backupURL.path) ? backupURL : nil)
        guard let restoreURL = sourceBinary else { return false }

        do {
            if fm.fileExists(atPath: execURL.path) {
                try fm.removeItem(at: execURL)
            }
            try fm.moveItem(at: restoreURL, to: execURL)
            if fm.fileExists(atPath: realURL.path) && restoreURL != realURL {
                try? fm.removeItem(at: realURL)
            }
            NSLog("[SeamlessFullscreenManager] Reverted wrapper for %@", appURL.lastPathComponent)
            return true
        } catch {
            NSLog("[SeamlessFullscreenManager] Failed to revert wrapper for %@: %@", appURL.lastPathComponent, error.localizedDescription)
            return false
        }
    }

    func applyToAllDetectedApps() {
        let apps = findInstalledTargetApps()
        for app in apps {
            if !isAppPatched(appURL: app) {
                NSLog("[SeamlessFullscreenManager] Auto-applying notch bypass to %@", app.lastPathComponent)
                applyPatch(to: app)
            }
        }
    }

    func revertAllDetectedApps() {
        let apps = findInstalledTargetApps()
        for app in apps {
            if isAppPatched(appURL: app) {
                NSLog("[SeamlessFullscreenManager] Reverting notch bypass from %@", app.lastPathComponent)
                revertPatch(from: app)
            }
        }
    }

    private func mainExecutableURL(for appURL: URL) -> URL? {
        let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: infoPlistURL),
              let execName = dict["CFBundleExecutable"] as? String else {
            return nil
        }
        return appURL.appendingPathComponent("Contents/MacOS/\(execName)")
    }

    // MARK: - Directory Watcher (Auto-Reapply on App Updates)

    private func startDirectoryWatcher() {
        let pathsToWatch = ["/Applications"] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
            guard let clientInfo = clientCallBackInfo else { return }
            let manager = Unmanaged<SeamlessFullscreenManager>.fromOpaque(clientInfo).takeUnretainedValue()
            if manager.isEnabled {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) {
                    manager.applyToAllDetectedApps()
                }
            }
        }

        fseventStream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            3.0,
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        )

        if let stream = fseventStream {
            FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            FSEventStreamStart(stream)
            NSLog("[SeamlessFullscreenManager] /Applications watcher started")
        }
    }

    private func stopDirectoryWatcher() {
        if let stream = fseventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            fseventStream = nil
        }
    }
}
