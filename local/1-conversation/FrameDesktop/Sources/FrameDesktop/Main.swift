import Foundation
import AppKit

// MARK: - Main

@main
struct FrameDesktop {
    static func main() {
        let configPath = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : NSHomeDirectory() + "/.framedesktop.json"

        // Load config
        let config: Config
        do {
            config = try loadConfig(from: configPath)
        } catch {
            print("Error loading config from \(configPath): \(error)")
            print("Usage: FrameDesktop [config-path]")
            print("Default: ~/.framedesktop.json")
            exit(1)
        }

        // Check accessibility permission
        let trusted = AXIsProcessTrusted()
        if !trusted {
            print("⚠ Accessibility permission required.")
            print("  Go to System Settings → Privacy & Security → Accessibility")
            print("  and add this application.")
            exit(1)
        }

        // Detect monitors
        let monitors = detectMonitors()
        print("Detected monitors:")
        for m in monitors {
            print("  \(m.name): \(Int(m.frame.width))x\(Int(m.frame.height)) at (\(Int(m.frame.origin.x)), \(Int(m.frame.origin.y)))")
        }

        // List windows
        let windows = listAllWindows()
        print("\nDetected windows: \(windows.count)")
        for w in windows {
            print("  [\(w.appId)] \(w.title)")
        }

        // Resolve and assign
        var totalAssigned = 0
        for workspace in config.workspaces {
            guard let (placement, monitorFrame) = resolveMonitor(
                placements: workspace.placements,
                monitors: monitors
            ) else {
                print("\nWorkspace '\(workspace.name)': no matching monitor found, skipping")
                continue
            }

            print("\nWorkspace '\(workspace.name)' → \(placement.virtualMonitor)")

            let slots = resolveSlots(
                workspace: workspace,
                placement: placement,
                monitorFrame: monitorFrame
            )

            let assignments = matchWindowsToSlots(windows: windows, slots: slots)

            for assignment in assignments {
                print("  Moving [\(assignment.window.appId)] '\(assignment.window.title)'")
                print("    → \(Int(assignment.slot.frame.origin.x)),\(Int(assignment.slot.frame.origin.y)) \(Int(assignment.slot.frame.width))x\(Int(assignment.slot.frame.height))")
                moveWindow(assignment.window.windowElement, to: assignment.slot.frame)
                totalAssigned += 1
            }
        }

        print("\nDone. Assigned \(totalAssigned) windows.")
    }
}
