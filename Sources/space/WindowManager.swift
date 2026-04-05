import AppKit
import ApplicationServices

struct WindowInfo {
    let wid: Int             // 1-based sequential (for user interaction)
    let cgWindowId: Int      // CGWindowID (stable within session, for persistence)
    let pid: pid_t
    let windowElement: AXUIElement
    let appId: String
    let appName: String
    let title: String
    let position: CGPoint
    let size: CGSize
}

/// Private API to get CGWindowID from AXUIElement
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Raise a window to the front
func raiseWindow(_ element: AXUIElement) {
    AXUIElementPerformAction(element, kAXRaiseAction as CFString)
}

/// Activate (focus) an application by pid
func activateApp(pid: pid_t) {
    if let app = NSRunningApplication(processIdentifier: pid) {
        app.activate()
    }
}

/// Hide all on-screen windows on a monitor except the given CGWindowIDs.
/// Uses CGWindowList to find ALL windows (including unmanaged ones like Chrome PWAs).
func hideAllExcept(_ keepCgIds: Set<Int>, onMonitor monitor: MonitorInfo, monitors: [MonitorInfo]) {
    guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
        return
    }

    for info in windowList {
        guard let cgId = info[kCGWindowNumber as String] as? Int,
              let pid = info[kCGWindowOwnerPID as String] as? Int32,
              let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
              let x = bounds["X"], let y = bounds["Y"],
              let w = bounds["Width"], let h = bounds["Height"] else {
            continue
        }

        // Skip windows we want to keep
        if keepCgIds.contains(cgId) { continue }

        // Skip tiny windows
        if w < 50 || h < 50 { continue }

        // Skip windows not on the target monitor
        let center = CGPoint(x: x + w / 2, y: y + h / 2)
        guard monitor.frame.contains(center) else { continue }

        // Skip windows at layer != 0 (menu bar, dock, etc.)
        if let layer = info[kCGWindowLayer as String] as? Int, layer != 0 { continue }

        // Hide via AXUIElement
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else {
            continue
        }

        for axWindow in axWindows {
            var winId: CGWindowID = 0
            if _AXUIElementGetWindow(axWindow, &winId) == .success, Int(winId) == cgId {
                hideWindow(axWindow, monitors: monitors)
                break
            }
        }
    }
}

/// Hide a window by moving to the bottom-right corner of all monitors.
/// macOS clamps ~30px visible. Size is not changed.
func hideWindow(_ element: AXUIElement, monitors: [MonitorInfo]) {
    let maxX = monitors.map { $0.frame.maxX }.max() ?? 0
    let maxY = monitors.map { $0.frame.maxY }.max() ?? 0

    var point = CGPoint(x: maxX - 1, y: maxY - 1)
    if let posValue = AXValueCreate(.cgPoint, &point) {
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posValue)
    }
}

/// Move and resize a window.
/// Order: size → position → size (AeroSpace approach).
/// Setting position can cause macOS to auto-adjust size, so size is set again after.
func moveWindow(_ element: AXUIElement, to frame: CGRect) {
    var point = CGPoint(x: frame.origin.x, y: frame.origin.y)
    var size = CGSize(width: frame.width, height: frame.height)

    // 1. Size first
    if let sizeValue = AXValueCreate(.cgSize, &size) {
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
    }
    // 2. Position
    if let posValue = AXValueCreate(.cgPoint, &point) {
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posValue)
    }
    // 3. Size again (position change may have altered size)
    if let sizeValue = AXValueCreate(.cgSize, &size) {
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
    }
}

func detectWindows() -> [WindowInfo] {
    var windows: [WindowInfo] = []

    let apps = NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular
    }

    for app in apps {
        let pid = app.processIdentifier
        let appId = app.bundleIdentifier ?? "unknown"
        let appName = app.localizedName ?? "unknown"
        let appElement = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &windowsRef
        )
        guard result == .success, let axWindows = windowsRef as? [AXUIElement] else {
            continue
        }

        for axWindow in axWindows {
            let title = axStringAttribute(axWindow, kAXTitleAttribute) ?? ""
            // Skip windows with no title (menus, popups, etc.)
            if title.isEmpty { continue }

            // Get stable CGWindowID
            var cgWinId: CGWindowID = 0
            let axResult = _AXUIElementGetWindow(axWindow, &cgWinId)
            if axResult != .success { continue }

            let pos = axPositionAttribute(axWindow) ?? .zero
            let size = axSizeAttribute(axWindow) ?? .zero

            // Skip tiny windows (system widgets, status items, etc.)
            if size.width < 50 || size.height < 50 { continue }

            windows.append(WindowInfo(
                wid: 0,  // assigned below
                cgWindowId: Int(cgWinId),
                pid: pid,
                windowElement: axWindow,
                appId: appId,
                appName: appName,
                title: title,
                position: pos,
                size: size
            ))
        }
    }

    // Supplement with windows found via CGWindowList but missed by AX enumeration
    // (e.g., Chrome PWAs, accessory apps with visible windows)
    let knownCgIds = Set(windows.map(\.cgWindowId))
    if let cgList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
        for info in cgList {
            guard let cgId = info[kCGWindowNumber as String] as? Int,
                  !knownCgIds.contains(cgId),
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let bw = bounds["Width"], let bh = bounds["Height"],
                  bw >= 50, bh >= 50,
                  let ownerName = info[kCGWindowOwnerName as String] as? String else {
                continue
            }

            // Try to get AXUIElement for this window
            let appElement = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let axWindows = windowsRef as? [AXUIElement] else {
                continue
            }

            for axWindow in axWindows {
                var winId: CGWindowID = 0
                if _AXUIElementGetWindow(axWindow, &winId) == .success, Int(winId) == cgId {
                    let axTitle = axStringAttribute(axWindow, kAXTitleAttribute) ?? ""
                    let title = axTitle.isEmpty ? (info[kCGWindowName as String] as? String ?? ownerName) : axTitle
                    let pos = axPositionAttribute(axWindow) ?? .zero
                    let size = axSizeAttribute(axWindow) ?? .zero
                    let appId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown"

                    windows.append(WindowInfo(
                        wid: 0,
                        cgWindowId: cgId,
                        pid: pid,
                        windowElement: axWindow,
                        appId: appId,
                        appName: ownerName,
                        title: title,
                        position: pos,
                        size: size
                    ))
                    break
                }
            }
        }
    }

    // Assign 1-based sequential wids
    return windows.enumerated().map { (i, w) in
        WindowInfo(wid: i + 1, cgWindowId: w.cgWindowId, pid: w.pid,
                   windowElement: w.windowElement, appId: w.appId,
                   appName: w.appName, title: w.title,
                   position: w.position, size: w.size)
    }
}

/// Determine which monitor a window belongs to based on its center point
func monitorForWindow(_ window: WindowInfo, monitors: [MonitorInfo]) -> MonitorInfo? {
    let center = CGPoint(
        x: window.position.x + window.size.width / 2,
        y: window.position.y + window.size.height / 2
    )
    // Find the monitor whose frame contains the window center
    return monitors.first { $0.frame.contains(center) }
        // Fallback: find the monitor with the most overlap
        ?? monitors.max(by: { a, b in
            let overlapA = a.frame.intersection(windowRect(window)).width
                         * a.frame.intersection(windowRect(window)).height
            let overlapB = b.frame.intersection(windowRect(window)).width
                         * b.frame.intersection(windowRect(window)).height
            return overlapA < overlapB
        })
}

private func windowRect(_ w: WindowInfo) -> CGRect {
    CGRect(origin: w.position, size: w.size)
}


// MARK: - AX Helpers

private func axStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard result == .success else { return nil }
    return value as? String
}

private func axPositionAttribute(_ element: AXUIElement) -> CGPoint? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(
        element, kAXPositionAttribute as CFString, &value
    )
    guard result == .success, let axValue = value else { return nil }
    var point = CGPoint.zero
    AXValueGetValue(axValue as! AXValue, .cgPoint, &point)
    return point
}

private func axSizeAttribute(_ element: AXUIElement) -> CGSize? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(
        element, kAXSizeAttribute as CFString, &value
    )
    guard result == .success, let axValue = value else { return nil }
    var size = CGSize.zero
    AXValueGetValue(axValue as! AXValue, .cgSize, &size)
    return size
}
