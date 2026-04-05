import AppKit
import ApplicationServices

// MARK: - Window info from Accessibility API

struct WindowInfo {
    let pid: pid_t
    let windowElement: AXUIElement
    let appId: String
    let title: String
    let position: CGPoint
    let size: CGSize
}

// MARK: - List all windows

func listAllWindows() -> [WindowInfo] {
    var windows: [WindowInfo] = []

    let runningApps = NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular
    }

    for app in runningApps {
        let pid = app.processIdentifier
        let appId = app.bundleIdentifier ?? "unknown"
        let appElement = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let axWindows = windowsRef as? [AXUIElement] else {
            continue
        }

        for axWindow in axWindows {
            let title = getStringAttribute(axWindow, kAXTitleAttribute) ?? ""
            guard let pos = getPositionAttribute(axWindow),
                  let size = getSizeAttribute(axWindow) else {
                continue
            }

            windows.append(WindowInfo(
                pid: pid,
                windowElement: axWindow,
                appId: appId,
                title: title,
                position: pos,
                size: size
            ))
        }
    }

    return windows
}

// MARK: - Move and resize a window

func moveWindow(_ window: AXUIElement, to frame: CGRect) {
    var point = CGPoint(x: frame.origin.x, y: frame.origin.y)
    var size = CGSize(width: frame.width, height: frame.height)

    if let posValue = AXValueCreate(.cgPoint, &point) {
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
    }
    if let sizeValue = AXValueCreate(.cgSize, &size) {
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    }
}

// MARK: - AX Helpers

private func getStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard result == .success else { return nil }
    return value as? String
}

private func getPositionAttribute(_ element: AXUIElement) -> CGPoint? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value)
    guard result == .success, let axValue = value else { return nil }
    var point = CGPoint.zero
    AXValueGetValue(axValue as! AXValue, .cgPoint, &point)
    return point
}

private func getSizeAttribute(_ element: AXUIElement) -> CGSize? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value)
    guard result == .success, let axValue = value else { return nil }
    var size = CGSize.zero
    AXValueGetValue(axValue as! AXValue, .cgSize, &size)
    return size
}
