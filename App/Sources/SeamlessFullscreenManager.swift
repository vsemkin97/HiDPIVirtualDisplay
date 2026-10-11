//
//  SeamlessFullscreenManager.swift
//  HiDPIDisplay (G9 Helper)
//
//  Universal notch bypass manager for browsers and media players.
//  Injects NoNotchLetterbox.dylib load commands so fullscreen video (YouTube, Netflix, etc.)
//  takes 100% of the display with 0 black bar under the wide Menu Bar.
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
        // Fallback to /tmp during local testing/build
        let fallback = URL(fileURLWithPath: "/tmp/NoNotchLetterbox_all.dylib")
        if FileManager.default.fileExists(atPath: fallback.path) {
            return fallback
        }
        return nil
    }

    private var insertDylibToolURL: URL? {
        if let bundleURL = Bundle.main.url(forResource: "insert_dylib", withExtension: nil) {
            return bundleURL
        }
        let fallback = URL(fileURLWithPath: "/tmp/insert_dylib_universal")
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
        // Run otool -L to see if NoNotchLetterbox.dylib is referenced
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
        process.arguments = ["-L", execURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                return output.contains("NoNotchLetterbox.dylib")
            }
        } catch {
            NSLog("[SeamlessFullscreenManager] otool error: %@", error.localizedDescription)
        }
        return false
    }

    @discardableResult
    func applyPatch(to appURL: URL) -> Bool {
        guard let sourceDylib = helperDylibURL,
              let insertDylib = insertDylibToolURL else {
            NSLog("[SeamlessFullscreenManager] ERROR: Helper tools or dylib not found")
            return false
        }
        guard let execURL = mainExecutableURL(for: appURL) else {
            NSLog("[SeamlessFullscreenManager] ERROR: Could not find main executable for %@", appURL.path)
            return false
        }

        let fm = FileManager.default
        let frameworksDir = appURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let targetDylibURL = frameworksDir.appendingPathComponent("NoNotchLetterbox.dylib")
        let backupExecURL = execURL.deletingPathExtension().appendingPathExtension("original")
        let tempExecURL = execURL.deletingPathExtension().appendingPathExtension("patching_tmp")

        do {
            if !fm.fileExists(atPath: frameworksDir.path) {
                try fm.createDirectory(at: frameworksDir, withIntermediateDirectories: true, attributes: nil)
            }

            // Copy dylib into app's Frameworks folder
            if fm.fileExists(atPath: targetDylibURL.path) {
                try fm.removeItem(at: targetDylibURL)
            }
            try fm.copyItem(at: sourceDylib, to: targetDylibURL)

            // Save original binary backup if not present
            if !fm.fileExists(atPath: backupExecURL.path) {
                try fm.copyItem(at: execURL, to: backupExecURL)
                NSLog("[SeamlessFullscreenManager] Created backup at %@", backupExecURL.path)
            }

            // Prepare working copy to avoid busy file locks
            if fm.fileExists(atPath: tempExecURL.path) {
                try fm.removeItem(at: tempExecURL)
            }
            try fm.copyItem(at: backupExecURL, to: tempExecURL)

            // Run insert_dylib
            let insertProc = Process()
            insertProc.executableURL = insertDylib
            insertProc.arguments = [
                "--inplace",
                "--all-yes",
                "--no-strip-codesig",
                "@executable_path/../Frameworks/NoNotchLetterbox.dylib",
                tempExecURL.path
            ]
            try insertProc.run()
            insertProc.waitUntilExit()

            guard insertProc.terminationStatus == 0 else {
                NSLog("[SeamlessFullscreenManager] insert_dylib failed with status %d", insertProc.terminationStatus)
                try? fm.removeItem(at: tempExecURL)
                return false
            }

            // Re-sign ad-hoc
            let signProc = Process()
            signProc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            signProc.arguments = ["-f", "-s", "-", tempExecURL.path]
            try signProc.run()
            signProc.waitUntilExit()

            // Atomically replace executable
            _ = try fm.replaceItemAt(execURL, withItemAt: tempExecURL)

            NSLog("[SeamlessFullscreenManager] Successfully patched %@", appURL.lastPathComponent)
            return true
        } catch {
            NSLog("[SeamlessFullscreenManager] Failed to patch %@: %@", appURL.lastPathComponent, error.localizedDescription)
            try? fm.removeItem(at: tempExecURL)
            return false
        }
    }

    @discardableResult
    func revertPatch(from appURL: URL) -> Bool {
        guard let execURL = mainExecutableURL(for: appURL) else { return false }
        let fm = FileManager.default
        let backupExecURL = execURL.deletingPathExtension().appendingPathExtension("original")
        let targetDylibURL = appURL.appendingPathComponent("Contents/Frameworks/NoNotchLetterbox.dylib")

        guard fm.fileExists(atPath: backupExecURL.path) else {
            return false
        }

        do {
            _ = try fm.replaceItemAt(execURL, withItemAt: backupExecURL)
            if fm.fileExists(atPath: targetDylibURL.path) {
                try fm.removeItem(at: targetDylibURL)
            }
            NSLog("[SeamlessFullscreenManager] Reverted %@", appURL.lastPathComponent)
            return true
        } catch {
            NSLog("[SeamlessFullscreenManager] Failed to revert %@: %@", appURL.lastPathComponent, error.localizedDescription)
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
