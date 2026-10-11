//
//  SeamlessFullscreenServer.swift
//  G9 Helper
//
//  Lightweight local server + window controller for seamless borderless fullscreen
//  without macOS notch letterboxing (no black bars, no monitor resets).
//

import Foundation
import Network
import AppKit
import CoreGraphics

private let skyLightHandle: UnsafeMutableRawPointer? = {
    dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
}()

private let mainCidFunc: (@convention(c) () -> Int32)? = {
    guard let h = skyLightHandle, let sym = dlsym(h, "CGSMainConnectionID") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) () -> Int32).self)
}()

private let setLevelFunc: (@convention(c) (Int32, Int32, Int32) -> CGError)? = {
    guard let h = skyLightHandle, let sym = dlsym(h, "CGSSetWindowLevel") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (Int32, Int32, Int32) -> CGError).self)
}()

private let moveWindowFunc: (@convention(c) (Int32, Int32, UnsafePointer<CGPoint>) -> CGError)? = {
    guard let h = skyLightHandle, let sym = dlsym(h, "SLSMoveWindow") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (Int32, Int32, UnsafePointer<CGPoint>) -> CGError).self)
}()

private let setTransformFunc: (@convention(c) (Int32, Int32, CGAffineTransform) -> CGError)? = {
    guard let h = skyLightHandle, let sym = dlsym(h, "SLSSetWindowTransform") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (Int32, Int32, CGAffineTransform) -> CGError).self)
}()

struct SavedWindowState {
    let wid: Int32
    let bounds: CGRect
    let level: Int32
}

class SeamlessFullscreenServer {
    static let shared = SeamlessFullscreenServer()

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.hidpi.seamless_fullscreen", qos: .userInteractive)
    private var savedState: SavedWindowState?
    private var isExpanded = false

    func start(port: UInt16 = 28999) {
        do {
            let params = NWParameters.tcp
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)

            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    debugLog("SeamlessFS: Listening on 127.0.0.1:\(port)")
                case .failed(let err):
                    debugLog("SeamlessFS: Listener failed: \(err)")
                default:
                    break
                }
            }

            listener?.start(queue: queue)
        } catch {
            debugLog("SeamlessFS: Error starting listener: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard let self = self, let data = data, error == nil else {
                connection.cancel()
                return
            }

            let requestStr = String(data: data, encoding: .utf8) ?? ""
            let response = self.processRequest(requestStr)

            connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ _ in
                connection.cancel()
            }))
        }
    }

    private func processRequest(_ req: String) -> String {
        let isEnter = req.contains("state=enter") || req.contains("/fullscreen/enter")
        let isExit = req.contains("state=exit") || req.contains("/fullscreen/exit")

        if isEnter {
            DispatchQueue.main.async { [weak self] in
                self?.enterSeamlessFullscreen()
            }
        } else if isExit {
            DispatchQueue.main.async { [weak self] in
                self?.exitSeamlessFullscreen()
            }
        }

        let body = "{\"status\":\"ok\",\"expanded\":\(isEnter ? "true" : "false")}"
        return "HTTP/1.1 200 OK\r\n" +
               "Access-Control-Allow-Origin: *\r\n" +
               "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" +
               "Access-Control-Allow-Headers: Content-Type\r\n" +
               "Content-Type: application/json\r\n" +
               "Content-Length: \(body.utf8.count)\r\n" +
               "Connection: close\r\n\r\n" +
               body
    }

    func enterSeamlessFullscreen() {
        guard let cid = mainCidFunc?() else { return }

        // Find the frontmost browser window
        let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let browserKeywords = ["Chrome", "Chromium", "Brave", "Arc", "Edge", "Safari", "Firefox"]

        guard let targetInfo = windowList.first(where: { info in
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any] else { return false }
            var bounds = CGRect.zero
            CGRectMakeWithDictionaryRepresentation(boundsDict as CFDictionary, &bounds)
            return browserKeywords.contains(where: { owner.contains($0) }) && bounds.width > 800
        }) else {
            debugLog("SeamlessFS: Target browser window not found")
            return
        }

        guard let wid = targetInfo[kCGWindowNumber as String] as? Int32 else { return }
        var bounds = CGRect.zero
        if let boundsDict = targetInfo[kCGWindowBounds as String] as? [String: Any] {
            CGRectMakeWithDictionaryRepresentation(boundsDict as CFDictionary, &bounds)
        }

        savedState = SavedWindowState(wid: wid, bounds: bounds, level: 0)

        // Find which screen contains this window
        let targetCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(targetCenter) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let screenH = screen.frame.size.height

        // Typical browser tab strip + address bar height
        let toolbarH: CGFloat = 80.0

        debugLog("SeamlessFS: Expanding window \(wid) on screen \(screen.localizedName) (bounds: \(bounds), screenH: \(screenH))")

        // 1. Raise above Menu Bar and Dock
        _ = setLevelFunc?(cid, wid, 1000)

        // 2. Shift window up so tabs and URL bar are pushed off-screen
        var targetPoint = CGPoint(x: screen.frame.origin.x, y: screen.frame.origin.y - toolbarH)
        _ = moveWindowFunc?(cid, wid, &targetPoint)

        // 3. Scale window vertically so the bottom reaches the bottom of the screen
        let visibleH = bounds.size.height - toolbarH
        let scaleY = screenH / max(visibleH, 1.0)
        let transform = CGAffineTransform(scaleX: 1.0, y: scaleY)
        _ = setTransformFunc?(cid, wid, transform)

        isExpanded = true
        debugLog("SeamlessFS: Window expanded seamlessly to 100% display area")
    }

    func exitSeamlessFullscreen() {
        guard let state = savedState, let cid = mainCidFunc?() else { return }
        debugLog("SeamlessFS: Restoring window \(state.wid) to original bounds: \(state.bounds)")

        // 1. Reset scale transform
        _ = setTransformFunc?(cid, state.wid, .identity)

        // 2. Restore window position
        var origP = state.bounds.origin
        _ = moveWindowFunc?(cid, state.wid, &origP)

        // 3. Restore window level
        _ = setLevelFunc?(cid, state.wid, state.level)

        savedState = nil
        isExpanded = false
        debugLog("SeamlessFS: Restored successfully")
    }
}
