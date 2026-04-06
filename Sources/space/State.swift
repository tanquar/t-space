import Foundation

/// Layout for one monitor within a board
struct MonitorLayout: Codable {
    var cgWindowIds: [Int]        // CGWindowIDs in layout order (stable)
    var definition: String        // tile args (e.g. "1 2 / 3")
    var monitorId: Int            // target monitor
    var lastFocusedCgId: Int?     // last focused CGWindowID
}

/// A board: one or more monitor layouts
struct BoardLayout: Codable {
    var layouts: [MonitorLayout]
    var childBoards: [String]?    // nested board names (e.g. ["dev", "web"])

    // Convenience: primary (first) layout
    var monitorId: Int { layouts[0].monitorId }
    var cgWindowIds: [Int] { layouts.flatMap(\.cgWindowIds) }
    var definition: String { layouts[0].definition }
    var lastFocusedCgId: Int? {
        get { layouts[0].lastFocusedCgId }
        set { layouts[0].lastFocusedCgId = newValue }
    }

    /// Create a single-monitor board (current behavior)
    init(cgWindowIds: [Int], definition: String, monitorId: Int,
         lastFocusedCgId: Int?, childBoards: [String]? = nil) {
        self.layouts = [MonitorLayout(
            cgWindowIds: cgWindowIds, definition: definition,
            monitorId: monitorId, lastFocusedCgId: lastFocusedCgId
        )]
        self.childBoards = childBoards
    }
}

/// Saved state for a hidden window
struct HiddenWindowState: Codable {
    let x: Double, y: Double
    let width: Double, height: Double
    let boardName: String?        // board it belonged to (nil = standalone)
    let hasPosition: Bool         // false = was already off-screen, place naturally
}

/// Persisted state
struct PersistedState: Codable {
    var boards: [String: BoardLayout] = [:]
    var widMap: [Int: Int] = [:]           // wid -> cgWindowId
    var nextWid: Int = 1
    var hidden: [Int: HiddenWindowState] = [:]  // cgWindowId -> saved state
}

/// Runtime state for the window manager
class SpaceState {
    var boards: [String: BoardLayout] = [:]
    var widMap: [Int: Int] = [:]
    var nextWid: Int = 1
    var hidden: [Int: HiddenWindowState] = [:]

    /// Assign stable wids to windows. Existing mappings are preserved.
    func assignWids(_ windows: [WindowInfo]) -> [WindowInfo] {
        var cgToWid: [Int: Int] = [:]
        for (wid, cgId) in widMap {
            cgToWid[cgId] = wid
        }

        let liveCgIds = Set(windows.map(\.cgWindowId))
        widMap = widMap.filter { liveCgIds.contains($0.value) }

        var result: [WindowInfo] = []
        for w in windows {
            let wid: Int
            if let existing = cgToWid[w.cgWindowId] {
                wid = existing
            } else {
                wid = nextWid
                nextWid += 1
                widMap[wid] = w.cgWindowId
                cgToWid[w.cgWindowId] = wid
            }
            result.append(WindowInfo(
                wid: wid, cgWindowId: w.cgWindowId, pid: w.pid,
                windowElement: w.windowElement, appId: w.appId,
                appName: w.appName, title: w.title,
                position: w.position, size: w.size
            ))
        }

        save()
        return result.sorted { $0.wid < $1.wid }
    }

    /// Record a window's state before hiding it.
    /// If already recorded, only update boardName (don't overwrite position with retreat coords).
    func recordHidden(_ window: WindowInfo, monitors: [MonitorInfo]) {
        let board = boardForWindow(window.cgWindowId)

        // Already recorded? Only update board membership, keep original position.
        if var existing = hidden[window.cgWindowId] {
            existing = HiddenWindowState(
                x: existing.x, y: existing.y,
                width: existing.width, height: existing.height,
                boardName: board ?? existing.boardName,
                hasPosition: existing.hasPosition
            )
            hidden[window.cgWindowId] = existing
            return
        }

        // Check if the window is currently off-screen (retreat area or stray)
        let isOnScreen = monitors.contains { mon in
            let windowRect = CGRect(origin: window.position, size: window.size)
            let overlap = mon.frame.intersection(windowRect)
            return overlap.width > 50 && overlap.height > 50
        }

        hidden[window.cgWindowId] = HiddenWindowState(
            x: Double(window.position.x), y: Double(window.position.y),
            width: Double(window.size.width), height: Double(window.size.height),
            boardName: board, hasPosition: isOnScreen
        )
    }

    /// Remove a window from hidden state (it's being restored)
    func clearHidden(_ cgWindowId: Int) {
        hidden.removeValue(forKey: cgWindowId)
    }

    /// Resolve wid (1-based) to WindowInfo
    func resolveByWid(_ wid: Int, in windows: [WindowInfo]) -> WindowInfo? {
        windows.first { $0.wid == wid }
    }

    /// Resolve CGWindowID to WindowInfo
    func resolveByCgId(_ cgId: Int, in windows: [WindowInfo]) -> WindowInfo? {
        windows.first { $0.cgWindowId == cgId }
    }

    /// Resolve a user arg (wid, cgWindowId, or .board) to CGWindowIDs.
    /// When `preferCgId` is true (definition replay), try cgWindowId first.
    func resolveToWindowCgIds(_ arg: String, windows: [WindowInfo], preferCgId: Bool = false) -> [Int] {
        if let num = Int(arg) {
            if preferCgId {
                // Replay mode: cgWindowId first (definitions store cgWindowIds)
                if let w = resolveByCgId(num, in: windows) { return [w.cgWindowId] }
                if let w = resolveByWid(num, in: windows) { return [w.cgWindowId] }
            } else {
                // User input mode: wid first
                if let w = resolveByWid(num, in: windows) { return [w.cgWindowId] }
                if let w = resolveByCgId(num, in: windows) { return [w.cgWindowId] }
            }
            return []
        }
        if arg.hasPrefix("."), let board = boards[String(arg.dropFirst())] {
            if let children = board.childBoards {
                return children.flatMap { resolveToWindowCgIds(".\($0)", windows: windows) }
            }
            return board.cgWindowIds
        }
        return []
    }

    /// Find which board a window belongs to (non-nested only)
    func boardForWindow(_ cgWindowId: Int) -> String? {
        boards.first { $0.value.childBoards == nil && $0.value.cgWindowIds.contains(cgWindowId) }?.key
    }

    // MARK: - Persistence

    private static let stateFilePath = NSHomeDirectory() + "/.t-space-state.json"

    func save() {
        let persisted = PersistedState(
            boards: boards, widMap: widMap, nextWid: nextWid, hidden: hidden
        )
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.stateFilePath))
    }

    static func load() -> SpaceState {
        let state = SpaceState()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: stateFilePath)),
              let persisted = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            return state
        }
        state.boards = persisted.boards
        state.widMap = persisted.widMap
        state.nextWid = persisted.nextWid
        state.hidden = persisted.hidden
        return state
    }
}
