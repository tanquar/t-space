import Foundation
import CoreGraphics

struct MonitorInfo {
    let id: Int
    let displayId: CGDirectDisplayID
    let frame: CGRect       // Full display bounds (includes menu bar)
    let usableFrame: CGRect // Excludes menu bar (top ~25px on main) and Dock
    let isMain: Bool
    let name: String
}

func detectMonitors() -> [MonitorInfo] {
    var displayIds = [CGDirectDisplayID](repeating: 0, count: 16)
    var displayCount: UInt32 = 0
    CGGetActiveDisplayList(16, &displayIds, &displayCount)

    // Get display names from system_profiler
    let nameMap = systemProfilerDisplayNames()

    let menuBarHeights = detectMenuBarHeights()

    return (0..<Int(displayCount)).map { i in
        let did = displayIds[i]
        let bounds = CGDisplayBounds(did)
        let isMain = CGDisplayIsMain(did) != 0
        let res = "\(Int(bounds.width))x\(Int(bounds.height))"

        // Match by resolution (system_profiler reports "UI Looks like" resolution)
        let name = nameMap[res]
            ?? (isMain ? "Built-in" : "Display-\(i + 1)")

        // Find menu bar height for this monitor by matching origin
        let menuBarHeight = menuBarHeights[originKey(bounds.origin)] ?? 0

        let usable = CGRect(
            x: bounds.origin.x,
            y: bounds.origin.y + menuBarHeight,
            width: bounds.width,
            height: bounds.height - menuBarHeight
        )

        return MonitorInfo(
            id: i + 1,
            displayId: did,
            frame: bounds,
            usableFrame: usable,
            isMain: isMain,
            name: name
        )
    }
}

/// Get display names, using a cache file to avoid slow system_profiler calls.
/// Cache is invalidated when the number of displays changes.
private func systemProfilerDisplayNames() -> [String: String] {
    let cacheFile = NSHomeDirectory() + "/.t-space-monitors.json"

    // Try cache first
    if let data = try? Data(contentsOf: URL(fileURLWithPath: cacheFile)),
       let cached = try? JSONDecoder().decode([String: String].self, from: data),
       !cached.isEmpty {
        return cached
    }

    let result = fetchDisplayNames()

    // Save cache
    if let data = try? JSONEncoder().encode(result) {
        try? data.write(to: URL(fileURLWithPath: cacheFile))
    }

    return result
}

private func fetchDisplayNames() -> [String: String] {
    var result: [String: String] = [:]

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    process.arguments = ["SPDisplaysDataType"]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return result }

        // Parse display entries
        // Format:
        //   DisplayName:
        //     ...
        //     UI Looks like: WxH @ ...Hz
        //     Resolution: WxH ...   (for built-in)
        var currentName: String?

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Display name line: starts with a name, ends with ":"
            // Indented exactly 8 spaces in system_profiler output
            if line.hasPrefix("        ") && !line.hasPrefix("          ")
                && trimmed.hasSuffix(":") && !trimmed.contains(" Looks like")
                && !trimmed.hasPrefix("Display Type")
                && !trimmed.hasPrefix("Resolution")
                && !trimmed.hasPrefix("Mirror")
                && !trimmed.hasPrefix("Online")
                && !trimmed.hasPrefix("Rotation")
                && !trimmed.hasPrefix("Connection")
                && !trimmed.hasPrefix("Automatically") {
                currentName = String(trimmed.dropLast()) // remove ":"
            }

            // "UI Looks like: 2560 x 2880 @ 60.00Hz"
            if trimmed.hasPrefix("UI Looks like:"), let name = currentName {
                if let res = parseProfilerResolution(trimmed) {
                    result[res] = name
                }
            }

            // Built-in display has "Resolution: 2880 x 1864 Retina" but no "UI Looks like"
            // and "Main Display: Yes"
            if trimmed.hasPrefix("Resolution:") && !trimmed.contains("@"), let name = currentName {
                if let res = parseProfilerResolution(trimmed) {
                    // Don't overwrite if already set by "UI Looks like"
                    if result[res] == nil {
                        result[res] = name
                    }
                }
            }
        }
    } catch {
        // Fallback: no names available
    }

    return result
}

/// Parse resolution from system_profiler lines like:
/// "UI Looks like: 2560 x 2880 @ 60.00Hz"
/// "Resolution: 2880 x 1864 Retina"
private func parseProfilerResolution(_ line: String) -> String? {
    guard let colonRange = line.range(of: ": ") else { return nil }
    let after = String(line[colonRange.upperBound...])

    // Extract "W x H" pattern
    let parts = after.components(separatedBy: " ")
    guard parts.count >= 3, parts[1] == "x",
          let w = Int(parts[0]), let h = Int(parts[2]) else { return nil }

    return "\(w)x\(h)"
}

/// Detect menu bar height for each monitor.
/// Returns a map of monitor origin -> menu bar height.
/// Key for menu bar lookup: "x,y" string from monitor origin
private func originKey(_ point: CGPoint) -> String {
    "\(Int(point.x)),\(Int(point.y))"
}

private func detectMenuBarHeights() -> [String: CGFloat] {
    var result: [String: CGFloat] = [:]

    guard let windowList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly], kCGNullWindowID
    ) as? [[String: Any]] else {
        return result
    }

    // Find "Menubar" windows owned by "Window Server" at layer 24
    for entry in windowList {
        let layer = entry[kCGWindowLayer as String] as? Int ?? 0
        let name = entry[kCGWindowName as String] as? String ?? ""
        let ownerName = entry[kCGWindowOwnerName as String] as? String ?? ""

        if layer == 24 && ownerName == "Window Server" && name == "Menubar" {
            if let bounds = entry[kCGWindowBounds as String] as? [String: Any],
               let x = (bounds["X"] as? NSNumber)?.doubleValue,
               let y = (bounds["Y"] as? NSNumber)?.doubleValue,
               let height = (bounds["Height"] as? NSNumber)?.doubleValue {
                result[originKey(CGPoint(x: x, y: y))] = CGFloat(height)
            }
        }
    }

    return result
}

/// Debug: print menu bar detection info
func debugMenuBar() {
    let heights = detectMenuBarHeights()
    print("Menu bar heights: \(heights)")

    guard let windowList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly], kCGNullWindowID
    ) as? [[String: Any]] else {
        print("  (could not get window list)")
        return
    }

    // Show all windows at layer 25 (menu bar level)
    for entry in windowList {
        let layer = entry[kCGWindowLayer as String] as? Int ?? 0
        if layer >= 24 && layer <= 26 {
            let name = entry[kCGWindowName as String] as? String ?? "(none)"
            let owner = entry[kCGWindowOwnerName as String] as? String ?? "(none)"
            let bounds = entry[kCGWindowBounds as String] as? [String: Any] ?? [:]
            print("  layer=\(layer) owner=\(owner) name=\(name) bounds=\(bounds)")
        }
    }
}

func listMonitors() {
    let monitors = detectMonitors()
    print("id  name             resolution       origin           usable               main")
    for m in monitors {
        let main = m.isMain ? "*" : ""
        let res = "\(Int(m.frame.width))x\(Int(m.frame.height))"
        let origin = "(\(Int(m.frame.origin.x)),\(Int(m.frame.origin.y)))"
        let usable = "(\(Int(m.usableFrame.origin.x)),\(Int(m.usableFrame.origin.y))) \(Int(m.usableFrame.width))x\(Int(m.usableFrame.height))"
        let id = "\(m.id)".padding(toLength: 4, withPad: " ", startingAt: 0)
        let name = m.name.padding(toLength: 17, withPad: " ", startingAt: 0)
        let resCol = res.padding(toLength: 17, withPad: " ", startingAt: 0)
        let originCol = origin.padding(toLength: 17, withPad: " ", startingAt: 0)
        let usableCol = usable.padding(toLength: 28, withPad: " ", startingAt: 0)
        print("\(id)\(name)\(resCol)\(originCol)\(usableCol)\(main)")
    }
}
