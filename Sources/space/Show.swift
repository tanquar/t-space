import Foundation
import CoreGraphics

/// Execute show: tile windows + hide others on monitor + focus.
func executeShow(
    args: [String],
    state: SpaceState,
    windows: [WindowInfo],
    monitors: [MonitorInfo]
) {
    // show @2 (focus-only)
    if args.count == 1 && args[0].hasPrefix("@") {
        guard let monitorId = Int(args[0].dropFirst()),
              monitors.first(where: { $0.id == monitorId }) != nil else {
            print("Monitor not found.")
            return
        }
        let onMonitor = windows.filter { monitorForWindow($0, monitors: monitors)?.id == monitorId }
        if let first = onMonitor.first {
            focusWindow(first.windowElement, pid: first.pid)
            print("Focus -> \(first.appName) on @\(monitorId)")
        } else {
            print("No windows on @\(monitorId)")
        }
        return
    }

    // show <wid> — single window: restore its board, position, or just focus
    if args.count == 1, let wid = Int(args[0]),
       let window = state.resolveByWid(wid, in: windows) {
        // Has a saved board? Restore the whole board
        if let hiddenState = state.hidden[window.cgWindowId],
           let boardName = hiddenState.boardName,
           let layout = state.boards[boardName] {
            executeShowBoard(
                boardName: boardName,
                layout: layout,
                monitorId: nil,
                state: state,
                windows: windows,
                monitors: monitors
            )
            return
        }

        // Determine target frame
        let isVisible = isWindowVisible(window, monitors: monitors)
        var targetFrame: CGRect
        if isVisible {
            targetFrame = CGRect(origin: window.position, size: window.size)
        } else {
            let hiddenState = state.hidden[window.cgWindowId]
            targetFrame = restoreFrame(hiddenState: hiddenState, window: window, monitors: monitors)
            moveWindow(window.windowElement, to: targetFrame)
        }

        // Hide other windows on the target monitor
        // Re-read window position after potential move
        let currentWindow = isVisible ? window : WindowInfo(
            wid: window.wid, cgWindowId: window.cgWindowId, pid: window.pid,
            windowElement: window.windowElement, appId: window.appId,
            appName: window.appName, title: window.title,
            position: CGPoint(x: targetFrame.origin.x, y: targetFrame.origin.y),
            size: CGSize(width: targetFrame.width, height: targetFrame.height)
        )
        let targetMon = monitorForWindow(currentWindow, monitors: monitors)
            ?? monitors.first(where: { $0.isMain }) ?? monitors.first
        if let mon = targetMon {
            let showSet: Set<Int> = [window.cgWindowId]
            hideOthers(showCgIds: showSet, monitorId: mon.id,
                       state: state, windows: windows, monitors: monitors)
        }

        state.clearHidden(window.cgWindowId)
        state.save()
        focusWindow(window.windowElement, pid: window.pid)
        return
    }

    // show .dev [@2] — named board
    if args[0].hasPrefix(".") && !args[0].contains("/") {
        let boardName = String(args[0].dropFirst())
        if let layout = state.boards[boardName] {
            var monitorId: Int?
            for arg in args.dropFirst() {
                if arg.hasPrefix("@") { monitorId = Int(arg.dropFirst()) }
            }
            executeShowBoard(
                boardName: boardName,
                layout: layout,
                monitorId: monitorId,
                state: state,
                windows: windows,
                monitors: monitors
            )
            return
        }
    }

    // show 1 2 @2 [.name] — ad-hoc
    guard let spec = parseTileArgs(args) else {
        if args[0].hasPrefix(".") {
            print("Board '.\(String(args[0].dropFirst()))' not found.")
        } else {
            print("Invalid show specification.")
        }
        return
    }

    guard let monitor = resolveMonitor(spec: spec, monitors: monitors) else {
        print("No monitors found.")
        return
    }

    // Collect CGWindowIDs to show
    let showCgIds = collectCgIds(spec: spec, state: state, windows: windows)

    // Hide non-target windows on this monitor
    hideOthers(showCgIds: showCgIds, monitorId: monitor.id,
               state: state, windows: windows, monitors: monitors)

    // Tile
    let frames = resolveTileFrames(spec: spec, within: monitor.usableFrame)
    let movedCgIds = placeWindows(frames: frames, state: state, windows: windows)

    // Raise and focus first
    raiseAndFocus(movedCgIds: movedCgIds, state: state, windows: windows)

    // Save board if named
    if let boardName = spec.boardName {
        state.boards[boardName] = BoardLayout(
            cgWindowIds: movedCgIds,
            definition: buildDefinition(spec: spec, state: state, windows: windows),
            monitorId: monitor.id,
            lastFocusedCgId: movedCgIds.first,
            childBoards: nil
        )
        state.save()
    }

    print("\nShowing on @\(monitor.id)")
}

/// Show a named board
private func executeShowBoard(
    boardName: String,
    layout: BoardLayout,
    monitorId: Int?,
    state: SpaceState,
    windows: [WindowInfo],
    monitors: [MonitorInfo]
) {
    let targetMonitorId = monitorId ?? layout.monitorId
    guard let monitor = monitors.first(where: { $0.id == targetMonitorId }) else {
        print("Monitor @\(targetMonitorId) not found.")
        return
    }

    if monitorId != nil {
        state.boards[boardName]?.monitorId = targetMonitorId
    }

    // Expand all CGWindowIDs (including nested)
    let allCgIds: [Int]
    if let children = layout.childBoards {
        allCgIds = children.flatMap { state.resolveToWindowCgIds(".\($0)", windows: windows) }
    } else {
        allCgIds = layout.cgWindowIds
    }
    let showCgIds = Set(allCgIds)

    // Hide non-target windows on this monitor
    hideOthers(showCgIds: showCgIds, monitorId: targetMonitorId,
               state: state, windows: windows, monitors: monitors)

    // Also hide windows from other boards on this monitor
    for (otherName, otherLayout) in state.boards {
        if otherName == boardName { continue }
        if otherLayout.monitorId != targetMonitorId { continue }
        for cgId in otherLayout.cgWindowIds {
            if showCgIds.contains(cgId) { continue }
            if let w = state.resolveByCgId(cgId, in: windows) {
                state.recordHidden(w, monitors: monitors)
                hideWindow(w.windowElement, monitors: monitors)
            }
        }
    }

    // Re-tile using saved definition
    guard let spec = parseTileArgs(layout.definition.components(separatedBy: " ")) else {
        print("Invalid layout: \(layout.definition)")
        return
    }

    let frames = resolveTileFrames(spec: spec, within: monitor.usableFrame)
    let movedCgIds = placeWindows(frames: frames, state: state, windows: windows, preferCgId: true)

    // Raise and focus
    let focusCgId = layout.lastFocusedCgId ?? allCgIds.first
    raiseAndFocus(movedCgIds: movedCgIds, focusCgId: focusCgId,
                  state: state, windows: windows)

    if let cgId = focusCgId {
        state.boards[boardName]?.lastFocusedCgId = cgId
    }

    state.save()
    print("\nShowing .\(boardName) on @\(targetMonitorId)")
}

// MARK: - Helpers

/// Collect all CGWindowIDs referenced by a TileSpec.
private func collectCgIds(spec: TileSpec, state: SpaceState, windows: [WindowInfo]) -> Set<Int> {
    var cgIds: Set<Int> = []
    for column in spec.columns {
        for row in column.rows {
            for item in row.items {
                if item.ref == "_" { continue }
                cgIds.formUnion(state.resolveToWindowCgIds(item.ref, windows: windows))
            }
        }
    }
    return cgIds
}

/// Hide windows on a monitor that are not in the show set.
/// Also hides unmanaged windows (Chrome PWAs, etc.) via CGWindowList.
private func hideOthers(
    showCgIds: Set<Int>,
    monitorId: Int,
    state: SpaceState,
    windows: [WindowInfo],
    monitors: [MonitorInfo]
) {
    // Hide managed windows
    for window in windows {
        if showCgIds.contains(window.cgWindowId) { continue }
        guard let wMon = monitorForWindow(window, monitors: monitors),
              wMon.id == monitorId else { continue }
        state.recordHidden(window, monitors: monitors)
        hideWindow(window.windowElement, monitors: monitors)
    }

    // Hide unmanaged windows on the same monitor
    if let monitor = monitors.first(where: { $0.id == monitorId }) {
        hideAllExcept(showCgIds, onMonitor: monitor, monitors: monitors)
    }

    // Clear hidden state for windows being shown
    for cgId in showCgIds {
        state.clearHidden(cgId)
    }
}

/// Check if a window is reasonably visible on any monitor.
private func isWindowVisible(_ window: WindowInfo, monitors: [MonitorInfo]) -> Bool {
    let rect = CGRect(origin: window.position, size: window.size)
    return monitors.contains { mon in
        let overlap = mon.frame.intersection(rect)
        return overlap.width > rect.width * 0.3 && overlap.height > rect.height * 0.3
    }
}

/// Determine a visible frame for restoring a window.
/// Uses saved position if visible, otherwise fills the default monitor.
private func restoreFrame(
    hiddenState: HiddenWindowState?,
    window: WindowInfo,
    monitors: [MonitorInfo]
) -> CGRect {
    if let hs = hiddenState, hs.hasPosition {
        let saved = CGRect(x: hs.x, y: hs.y, width: hs.width, height: hs.height)
        let isVisible = monitors.contains { mon in
            let overlap = mon.frame.intersection(saved)
            return overlap.width > saved.width * 0.3 && overlap.height > saved.height * 0.3
        }
        if isVisible { return saved }
    }

    // Fill default monitor
    let mon = monitors.first(where: { $0.isMain }) ?? monitors.first!
    return mon.usableFrame
}

/// Raise windows and focus the first (or a specific one).
private func raiseAndFocus(
    movedCgIds: [Int],
    focusCgId: Int? = nil,
    state: SpaceState,
    windows: [WindowInfo]
) {
    for cgId in movedCgIds.reversed() {
        if let w = state.resolveByCgId(cgId, in: windows) {
            raiseWindow(w.windowElement)
        }
    }
    let target = focusCgId ?? movedCgIds.first
    if let cgId = target, let w = state.resolveByCgId(cgId, in: windows) {
        focusWindow(w.windowElement, pid: w.pid)
    }
}
