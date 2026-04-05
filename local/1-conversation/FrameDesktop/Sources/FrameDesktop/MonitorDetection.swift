import AppKit

struct MonitorInfo {
    let name: String
    let frame: CGRect  // screen frame in global coordinates
}

/// Detect connected monitors and return them with display names.
/// Uses CGDisplay + NSScreen to get both name and frame.
func detectMonitors() -> [MonitorInfo] {
    var monitors: [MonitorInfo] = []

    for screen in NSScreen.screens {
        let name = screen.localizedName
        let frame = screen.frame
        monitors.append(MonitorInfo(name: name, frame: frame))
    }

    return monitors
}

/// Find the best monitor for a workspace placement using the fallback chain.
/// Returns the monitor frame if a matching monitor is found.
func resolveMonitor(placements: [PlacementConfig], monitors: [MonitorInfo]) -> (PlacementConfig, CGRect)? {
    for placement in placements {
        if let monitor = monitors.first(where: {
            $0.name.localizedCaseInsensitiveContains(placement.virtualMonitor)
        }) {
            return (placement, monitor.frame)
        }
    }
    return nil
}
