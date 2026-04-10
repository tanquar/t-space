import Foundation
import CoreGraphics

struct MonitorInfo {
    let id: Int                     // User-facing stable numeric ID (assigned by registry)
    let stableKey: String           // Persistent identity key (vendor:model:serial or vendor:model:label)
    let displayId: CGDirectDisplayID
    let frame: CGRect               // Full display bounds (includes menu bar)
    let usableFrame: CGRect         // Excludes menu bar (top ~25px on main) and Dock
    let isMain: Bool
    let name: String                // Human-readable, may include position label for same-model groups
}

/// Raw per-display info before stableKey computation and numeric ID assignment.
struct RawMonitor {
    let displayId: CGDirectDisplayID
    let frame: CGRect
    let usableFrame: CGRect
    let isMain: Bool
    let name: String                // Base name (shared across same-model monitors)
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
}

/// Raw detection: query CG + system_profiler. No stableKey or numeric ID here.
func detectMonitorsRaw() -> [RawMonitor] {
    var displayIds = [CGDirectDisplayID](repeating: 0, count: 16)
    var displayCount: UInt32 = 0
    CGGetActiveDisplayList(16, &displayIds, &displayCount)

    let nameMap = systemProfilerDisplayNames()
    let menuBarHeights = detectMenuBarHeights()

    return (0..<Int(displayCount)).map { i in
        let did = displayIds[i]
        let bounds = CGDisplayBounds(did)
        let isMain = CGDisplayIsMain(did) != 0
        let res = "\(Int(bounds.width))x\(Int(bounds.height))"

        let name = nameMap[res]
            ?? (isMain ? "Built-in" : "Display-\(i + 1)")

        let menuBarHeight = menuBarHeights[originKey(bounds.origin)] ?? 0
        let usable = CGRect(
            x: bounds.origin.x,
            y: bounds.origin.y + menuBarHeight,
            width: bounds.width,
            height: bounds.height - menuBarHeight
        )

        return RawMonitor(
            displayId: did,
            frame: bounds,
            usableFrame: usable,
            isMain: isMain,
            name: name,
            vendor: CGDisplayVendorNumber(did),
            model: CGDisplayModelNumber(did),
            serial: CGDisplaySerialNumber(did)
        )
    }
}

/// Compute stableKey and position label for each monitor.
/// Same-model monitors without a serial are distinguished by arrangement position.
func computeStableKeys(_ raws: [RawMonitor]) -> [(raw: RawMonitor, key: String, label: String)] {
    // Group by vendor:model. Serials are used directly when non-zero.
    // For same-model groups with serial==0, we assign position labels from origin.
    var result: [(RawMonitor, String, String)] = []

    // Group indices by vendor:model:name (name is included so "Built-in" vs "DELL" stay separated
    // even if vendor numbers happen to collide).
    let groupKey: (RawMonitor) -> String = { "\($0.vendor):\($0.model):\($0.name)" }
    let groups = Dictionary(grouping: raws.indices, by: { groupKey(raws[$0]) })

    for raw in raws {
        let gKey = groupKey(raw)
        let group = groups[gKey] ?? []
        let sameModelRaws = group.map { raws[$0] }

        // If serial is unique within the group, use it
        let serialsInGroup = sameModelRaws.map(\.serial)
        let useSerial = raw.serial != 0 && serialsInGroup.filter { $0 == raw.serial }.count == 1

        let label: String
        if useSerial {
            label = ""
        } else if sameModelRaws.count == 1 {
            label = ""
        } else if sameModelRaws.count == 2 {
            let a = sameModelRaws[0], b = sameModelRaws[1]
            let dx = abs(a.frame.origin.x - b.frame.origin.x)
            let dy = abs(a.frame.origin.y - b.frame.origin.y)
            if dx >= dy {
                label = raw.frame.origin.x <= min(a.frame.origin.x, b.frame.origin.x) ? "Left" : "Right"
            } else {
                label = raw.frame.origin.y <= min(a.frame.origin.y, b.frame.origin.y) ? "Top" : "Bottom"
            }
        } else {
            // 3+ monitors: sort by (y, x) reading order and label A, B, C, ...
            let sorted = sameModelRaws.sorted { lhs, rhs in
                if lhs.frame.origin.y != rhs.frame.origin.y {
                    return lhs.frame.origin.y < rhs.frame.origin.y
                }
                return lhs.frame.origin.x < rhs.frame.origin.x
            }
            let idx = sorted.firstIndex(where: { $0.displayId == raw.displayId }) ?? 0
            label = String(UnicodeScalar(65 + idx)!)  // A, B, C, ...
        }

        let key: String
        if useSerial {
            key = "\(raw.vendor):\(raw.model):\(raw.serial):\(raw.name)"
        } else {
            key = "\(raw.vendor):\(raw.model):\(raw.name):\(label)"
        }
        result.append((raw, key, label))
    }
    return result
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

/// Registry that assigns and persists stable numeric IDs to monitors.
/// User-facing @1, @2 refer to these IDs. Cache is invalidated on display reconfiguration.
class MonitorRegistry {
    private let state: SpaceState
    private var cache: [MonitorInfo] = []
    private var dirty: Bool = true

    init(state: SpaceState) {
        self.state = state
    }

    /// Mark the cache as stale. Next `current()` call will rebuild.
    func invalidate() {
        dirty = true
    }

    /// Return current monitors, rebuilding from CG if cache is dirty.
    func current() -> [MonitorInfo] {
        if dirty { rebuild() }
        return cache
    }

    private func rebuild() {
        let raws = detectMonitorsRaw()
        let keyed = computeStableKeys(raws)

        var changed = false
        var newInfos: [MonitorInfo] = []
        for (raw, key, label) in keyed {
            let id: Int
            if let existing = state.monitorIds[key] {
                id = existing
            } else {
                id = state.nextMonitorId
                state.monitorIds[key] = id
                state.nextMonitorId += 1
                changed = true
                print("  [monitor] new @\(id) \(key)")
            }
            let displayName = label.isEmpty ? raw.name : "\(raw.name) \(label)"
            newInfos.append(MonitorInfo(
                id: id,
                stableKey: key,
                displayId: raw.displayId,
                frame: raw.frame,
                usableFrame: raw.usableFrame,
                isMain: raw.isMain,
                name: displayName
            ))
        }
        // Stable sort by numeric id for deterministic ordering
        newInfos.sort { $0.id < $1.id }
        cache = newInfos
        if changed { state.save() }
        dirty = false
    }
}

