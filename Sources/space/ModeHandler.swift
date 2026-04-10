import Foundation
import CoreGraphics
import AppKit

/// Handles modal mode: window navigation, board switching, resize, etc.
extension SpaceDaemon {

    /// Execute a named command.
    func executeCommand(_ cmd: Command) {
        switch cmd {
        // Window focus
        case .focusLeft:        navigate(direction: .left)
        case .focusDown:        navigate(direction: .down)
        case .focusUp:          navigate(direction: .up)
        case .focusRight:       navigate(direction: .right)
        case .focusNextWindow:  cycleWindow(forward: true)
        case .focusPrevWindow:  cycleWindow(forward: false)

        // Jump to edge
        case .focusEdgeLeft:    focusEdge(direction: .left)
        case .focusEdgeDown:    focusEdge(direction: .down)
        case .focusEdgeUp:      focusEdge(direction: .up)
        case .focusEdgeRight:   focusEdge(direction: .right)
        case .focusLastWindow:  focusEndWindow(last: true)
        case .focusFirstWindow: focusEndWindow(last: false)

        // Swap prefix
        case .swapPrefix:       enterSwapMode()

        // Monitor
        case .focusNextMonitor: cycleMonitor(forward: true)
        case .focusPrevMonitor: cycleMonitor(forward: false)

        // Resize
        case .growHeight:       resizeCurrentWindow(dw: 0, dh: 50)
        case .shrinkHeight:     resizeCurrentWindow(dw: 0, dh: -50)
        case .growWidth:        resizeCurrentWindow(dw: 50, dh: 0)
        case .shrinkWidth:      resizeCurrentWindow(dw: -50, dh: 0)

        // Board
        case .showNextBoardOnMonitor:  cycleBoardOnMonitor(forward: true)
        case .showPrevBoardOnMonitor:  cycleBoardOnMonitor(forward: false)
        case .showFirstBoardOnMonitor: showBoardOnMonitor(first: true)
        case .showLastBoardOnMonitor:  showBoardOnMonitor(first: false)

        // Window action
        case .hideWindow:       hideCurrentWindow()

        // UI
        case .listWindows:      printWindowList()
        case .listMonitors:     printMonitorList()
        case .listBoards:       printBoardList()

        // Input mode
        case .inputTile:        startInput("tile")
        case .inputShow:        startInput("show")
        case .inputBoard:       startInput(".")
        case .inputMonitor:     startInput("@")
        case .inputSplitH:      startInput("-")
        case .inputSplitV:      startInput("/")
        case .inputAddRight:    startInput("a>")
        case .inputAddLeft:     startInput("a<")
        case .inputAddBelow:    startInput("e↓")
        case .inputAddAbove:    startInput("e↑")

        // Number select
        case .selectWindow1:    selectWindow(wid: 1)
        case .selectWindow2:    selectWindow(wid: 2)
        case .selectWindow3:    selectWindow(wid: 3)
        case .selectWindow4:    selectWindow(wid: 4)
        case .selectWindow5:    selectWindow(wid: 5)
        case .selectWindow6:    selectWindow(wid: 6)
        case .selectWindow7:    selectWindow(wid: 7)
        case .selectWindow8:    selectWindow(wid: 8)
        case .selectWindow9:    selectWindow(wid: 9)

        // Mode
        case .cancel:           exitMode(confirmed: false)
        }
    }

    // MARK: - Navigation

    enum Direction { case left, down, up, right }

    func navigate(direction: Direction) {
        guard !modeWindowList.isEmpty else { return }

        let current: WindowInfo?
        if modeCurrentIndex >= 0 && modeCurrentIndex < modeWindowList.count {
            current = modeWindowList[modeCurrentIndex]
        } else {
            current = modeWindowList.first
        }
        guard let cur = current else { return }

        let monitors = self.monitors.current()
        let curMonId = monitorForWindow(cur, monitors: monitors)?.id

        let curCenter = CGPoint(
            x: cur.position.x + cur.size.width / 2,
            y: cur.position.y + cur.size.height / 2
        )

        // Try same monitor first, then all monitors
        for sameMonitorOnly in [true, false] {
            var bestIndex = -1
            var bestDist = CGFloat.infinity

            for (i, w) in modeWindowList.enumerated() {
                if w.cgWindowId == cur.cgWindowId { continue }

                if sameMonitorOnly {
                    let wMonId = monitorForWindow(w, monitors: monitors)?.id
                    if wMonId != curMonId { continue }
                }

                let center = CGPoint(
                    x: w.position.x + w.size.width / 2,
                    y: w.position.y + w.size.height / 2
                )
                let dx = center.x - curCenter.x
                let dy = center.y - curCenter.y

                let inDirection: Bool
                switch direction {
                case .left:  inDirection = dx < -50
                case .right: inDirection = dx > 50
                case .up:    inDirection = dy < -50
                case .down:  inDirection = dy > 50
                }

                if inDirection {
                    let dist = sqrt(dx * dx + dy * dy)
                    if dist < bestDist {
                        bestDist = dist
                        bestIndex = i
                    }
                }
            }

            if bestIndex >= 0 {
                modeCurrentIndex = bestIndex
                focusCurrentWindow()
                return
            }
        }

        print("  \(direction) -> (no window)")
    }

    func cycleWindow(forward: Bool) {
        guard !modeWindowList.isEmpty else { return }

        let monitors = self.monitors.current()
        let curMonId = modeCurrentMonitorId

        let sameMonIndices = modeWindowList.indices.filter { i in
            curMonId != nil && monitorForWindow(modeWindowList[i], monitors: monitors)?.id == curMonId
        }

        let indices = sameMonIndices.count > 1 ? sameMonIndices : Array(modeWindowList.indices)
        guard !indices.isEmpty else { return }

        let currentPos = indices.firstIndex(of: modeCurrentIndex) ?? -1
        let nextPos: Int
        if forward {
            nextPos = (currentPos + 1) % indices.count
        } else {
            nextPos = (currentPos - 1 + indices.count) % indices.count
        }
        modeCurrentIndex = indices[nextPos]
        focusCurrentWindow()
    }

    func selectWindow(wid: Int) {
        if let idx = modeWindowList.firstIndex(where: { $0.wid == wid }) {
            modeCurrentIndex = idx
            focusCurrentWindow()
        } else {
            print("  wid \(wid) not found")
        }
    }

    /// Focus the currently selected window.
    /// If off-screen, restore to default monitor full screen.
    func focusCurrentWindow() {
        guard modeCurrentIndex >= 0 && modeCurrentIndex < modeWindowList.count else { return }
        let w = modeWindowList[modeCurrentIndex]
        suppressUntil = Date().addingTimeInterval(1)

        let monitors = self.monitors.current()
        let isVisible = monitors.contains { mon in
            let rect = CGRect(origin: w.position, size: w.size)
            let overlap = mon.frame.intersection(rect)
            return overlap.width > rect.width * 0.3 && overlap.height > rect.height * 0.3
        }

        if !isVisible {
            let mon = monitors.first(where: { $0.isMain }) ?? monitors.first!
            moveWindow(w.windowElement, to: mon.usableFrame)
            state.clearHidden(w.cgWindowId)
            state.save()
        }

        focusWindow(w.windowElement, pid: w.pid)

        if !isVisible {
            let mon = monitors.first(where: { $0.isMain }) ?? monitors.first!
            modeCurrentMonitorId = mon.id
        } else {
            modeCurrentMonitorId = monitorForWindow(w, monitors: monitors)?.id
        }

        print("  -> wid \(w.wid) \(w.appName): \(w.title)\(isVisible ? "" : " (restored)")")
    }

    // MARK: - Jump to Edge

    func focusEdge(direction: Direction) {
        guard !modeWindowList.isEmpty else { return }

        let monitors = self.monitors.current()
        let curMonId = modeCurrentMonitorId

        let onMonitor = modeWindowList.filter { w in
            curMonId != nil && monitorForWindow(w, monitors: monitors)?.id == curMonId
        }
        guard !onMonitor.isEmpty else { return }

        let target: WindowInfo?
        switch direction {
        case .left:  target = onMonitor.min(by: { $0.position.x < $1.position.x })
        case .right: target = onMonitor.max(by: { $0.position.x < $1.position.x })
        case .up:    target = onMonitor.min(by: { $0.position.y < $1.position.y })
        case .down:  target = onMonitor.max(by: { $0.position.y < $1.position.y })
        }

        if let t = target, let idx = modeWindowList.firstIndex(where: { $0.cgWindowId == t.cgWindowId }) {
            modeCurrentIndex = idx
            focusCurrentWindow()
        }
    }

    func focusEndWindow(last: Bool) {
        guard !modeWindowList.isEmpty else { return }

        let monitors = self.monitors.current()
        let curMonId = modeCurrentMonitorId

        let indices = modeWindowList.indices.filter { i in
            curMonId != nil && monitorForWindow(modeWindowList[i], monitors: monitors)?.id == curMonId
        }
        guard !indices.isEmpty else { return }

        modeCurrentIndex = last ? indices.last! : indices.first!
        focusCurrentWindow()
    }

    // MARK: - Swap Mode

    func enterSwapMode() {
        swapPending = true
        print("  swap: waiting for direction (h/j/k/l/n/p)...")
    }

    func handleSwapKey(keycode: Int64, shift: Bool) -> Bool {
        swapPending = false

        if shift {
            // Shift: swap with edge window
            switch keycode {
            case 4:  performSwapEdge(direction: .left);  return true   // H
            case 38: performSwapEdge(direction: .down);  return true   // J
            case 40: performSwapEdge(direction: .up);    return true   // K
            case 37: performSwapEdge(direction: .right); return true   // L
            case 45: performSwapEnd(last: true);  return true          // N
            case 35: performSwapEnd(last: false); return true          // P
            default: break
            }
        } else {
            // No shift: swap with adjacent window
            switch keycode {
            case 4:  performSwap(direction: .left);  return true   // h
            case 38: performSwap(direction: .down);  return true   // j
            case 40: performSwap(direction: .up);    return true   // k
            case 37: performSwap(direction: .right); return true   // l
            case 45: performSwapCycle(forward: true);  return true // n
            case 35: performSwapCycle(forward: false); return true // p
            default: break
            }
        }

        print("  swap cancelled")
        return false
    }

    private func performSwap(direction: Direction) {
        guard modeCurrentIndex >= 0 && modeCurrentIndex < modeWindowList.count else { return }
        let cur = modeWindowList[modeCurrentIndex]

        let monitors = self.monitors.current()
        let curMonId = monitorForWindow(cur, monitors: monitors)?.id
        let curCenter = CGPoint(x: cur.position.x + cur.size.width / 2, y: cur.position.y + cur.size.height / 2)

        var bestIndex = -1
        var bestDist = CGFloat.infinity

        for (i, w) in modeWindowList.enumerated() {
            if w.cgWindowId == cur.cgWindowId { continue }
            if monitorForWindow(w, monitors: monitors)?.id != curMonId { continue }

            let center = CGPoint(x: w.position.x + w.size.width / 2, y: w.position.y + w.size.height / 2)
            let dx = center.x - curCenter.x
            let dy = center.y - curCenter.y

            let inDir: Bool
            switch direction {
            case .left:  inDir = dx < -50
            case .right: inDir = dx > 50
            case .up:    inDir = dy < -50
            case .down:  inDir = dy > 50
            }

            if inDir {
                let dist = sqrt(dx * dx + dy * dy)
                if dist < bestDist { bestDist = dist; bestIndex = i }
            }
        }

        if bestIndex >= 0 {
            doSwap(aIndex: modeCurrentIndex, bIndex: bestIndex)
        } else {
            print("  swap \(direction): no target")
        }
    }

    private func performSwapCycle(forward: Bool) {
        guard modeCurrentIndex >= 0 && modeCurrentIndex < modeWindowList.count else { return }

        let monitors = self.monitors.current()
        let curMonId = modeCurrentMonitorId

        let indices = modeWindowList.indices.filter { i in
            curMonId != nil && monitorForWindow(modeWindowList[i], monitors: monitors)?.id == curMonId
        }
        guard indices.count > 1 else { return }

        let currentPos = indices.firstIndex(of: modeCurrentIndex) ?? 0
        let nextPos = forward ? (currentPos + 1) % indices.count : (currentPos - 1 + indices.count) % indices.count
        doSwap(aIndex: modeCurrentIndex, bIndex: indices[nextPos])
    }

    private func performSwapEdge(direction: Direction) {
        guard modeCurrentIndex >= 0 && modeCurrentIndex < modeWindowList.count else { return }
        let cur = modeWindowList[modeCurrentIndex]

        let monitors = self.monitors.current()
        let curMonId = monitorForWindow(cur, monitors: monitors)?.id

        let onMonitor = modeWindowList.enumerated().filter { (_, w) in
            w.cgWindowId != cur.cgWindowId && monitorForWindow(w, monitors: monitors)?.id == curMonId
        }
        guard !onMonitor.isEmpty else { return }

        let target: (offset: Int, element: WindowInfo)?
        switch direction {
        case .left:  target = onMonitor.min(by: { $0.element.position.x < $1.element.position.x })
        case .right: target = onMonitor.max(by: { $0.element.position.x < $1.element.position.x })
        case .up:    target = onMonitor.min(by: { $0.element.position.y < $1.element.position.y })
        case .down:  target = onMonitor.max(by: { $0.element.position.y < $1.element.position.y })
        }

        if let t = target {
            doSwap(aIndex: modeCurrentIndex, bIndex: t.offset)
        }
    }

    private func performSwapEnd(last: Bool) {
        guard modeCurrentIndex >= 0 && modeCurrentIndex < modeWindowList.count else { return }

        let monitors = self.monitors.current()
        let curMonId = modeCurrentMonitorId

        let indices = modeWindowList.indices.filter { i in
            i != modeCurrentIndex && curMonId != nil && monitorForWindow(modeWindowList[i], monitors: monitors)?.id == curMonId
        }
        guard !indices.isEmpty else { return }

        let targetIdx = last ? indices.last! : indices.first!
        doSwap(aIndex: modeCurrentIndex, bIndex: targetIdx)
    }

    private func doSwap(aIndex: Int, bIndex: Int) {
        let a = modeWindowList[aIndex]
        let b = modeWindowList[bIndex]

        let aFrame = CGRect(origin: a.position, size: a.size)
        let bFrame = CGRect(origin: b.position, size: b.size)

        moveWindow(a.windowElement, to: bFrame)
        moveWindow(b.windowElement, to: aFrame)

        // Focus follows the original window
        modeCurrentIndex = bIndex
        focusCurrentWindow()
        print("  swapped wid \(a.wid) <-> wid \(b.wid)")
    }

    // MARK: - Resize

    func resizeCurrentWindow(dw: CGFloat, dh: CGFloat) {
        guard modeCurrentIndex >= 0 && modeCurrentIndex < modeWindowList.count else { return }
        let w = modeWindowList[modeCurrentIndex]
        let newFrame = CGRect(
            x: w.position.x, y: w.position.y,
            width: max(100, w.size.width + dw),
            height: max(100, w.size.height + dh)
        )
        moveWindow(w.windowElement, to: newFrame)
        print("  resize wid \(w.wid) → \(Int(newFrame.width))x\(Int(newFrame.height))")
    }

    // MARK: - Monitor

    func cycleMonitor(forward: Bool) {
        let monitors = self.monitors.current().sorted { $0.id < $1.id }
        guard monitors.count > 1 else { return }

        let currentMonId: Int
        if let mid = modeCurrentMonitorId {
            currentMonId = mid
        } else if modeCurrentIndex >= 0 && modeCurrentIndex < modeWindowList.count {
            currentMonId = monitorForWindow(modeWindowList[modeCurrentIndex], monitors: monitors)?.id ?? monitors[0].id
        } else {
            currentMonId = monitors[0].id
        }

        let ids = monitors.map(\.id)
        guard let idx = ids.firstIndex(of: currentMonId) else { return }
        let nextIdx = forward ? (idx + 1) % ids.count : (idx - 1 + ids.count) % ids.count
        let nextMonId = ids[nextIdx]

        modeCurrentMonitorId = nextMonId

        if let w = modeWindowList.first(where: { monitorForWindow($0, monitors: monitors)?.id == nextMonId }) {
            modeCurrentIndex = modeWindowList.firstIndex(where: { $0.cgWindowId == w.cgWindowId }) ?? modeCurrentIndex
            focusCurrentWindow()
        } else {
            print("  monitor @\(nextMonId) -> (no windows)")
        }
    }

    // MARK: - Board

    func cycleBoardOnMonitor(forward: Bool) {
        let monitors = self.monitors.current()
        let currentMonId = modeCurrentMonitorId ?? getCurrentMonitorId(monitors: monitors)
        let boardNames = state.boards.filter { $0.value.monitorId == currentMonId }.keys.sorted()
        guard !boardNames.isEmpty else {
            print("  [no boards on @\(currentMonId)]")
            return
        }

        var currentIdx = -1
        if modeCurrentIndex >= 0 && modeCurrentIndex < modeWindowList.count {
            let w = modeWindowList[modeCurrentIndex]
            if let name = state.boardForWindow(w.cgWindowId),
               let idx = boardNames.firstIndex(of: name) {
                currentIdx = idx
            }
        }

        let nextIdx: Int
        if currentIdx < 0 { nextIdx = 0 }
        else if forward { nextIdx = (currentIdx + 1) % boardNames.count }
        else { nextIdx = (currentIdx - 1 + boardNames.count) % boardNames.count }

        let boardName = boardNames[nextIdx]
        print("  board .\(boardName) on @\(currentMonId)")
        let windows = state.assignWids(detectWindows())
        modeWindowList = windows
        executeShow(args: [".\(boardName)"], state: state, windows: windows, monitors: monitors)
    }

    func showBoardOnMonitor(first: Bool) {
        let monitors = self.monitors.current()
        let currentMonId = modeCurrentMonitorId ?? getCurrentMonitorId(monitors: monitors)
        let boardNames = state.boards.filter { $0.value.monitorId == currentMonId }.keys.sorted()
        guard !boardNames.isEmpty else { return }

        let boardName = first ? boardNames.first! : boardNames.last!
        print("  board .\(boardName) on @\(currentMonId)")
        let windows = state.assignWids(detectWindows())
        modeWindowList = windows
        executeShow(args: [".\(boardName)"], state: state, windows: windows, monitors: monitors)
    }

    func getCurrentMonitorId(monitors: [MonitorInfo]) -> Int {
        if modeCurrentIndex >= 0 && modeCurrentIndex < modeWindowList.count {
            let w = modeWindowList[modeCurrentIndex]
            return monitorForWindow(w, monitors: monitors)?.id ?? 1
        }
        return monitors.first(where: { $0.isMain })?.id ?? 1
    }

    // MARK: - Window Actions

    func hideCurrentWindow() {
        guard modeCurrentIndex >= 0 && modeCurrentIndex < modeWindowList.count else { return }
        let w = modeWindowList[modeCurrentIndex]
        let monitors = self.monitors.current()
        state.recordHidden(w, monitors: monitors)
        hideWindow(w.windowElement, monitors: monitors)
        state.save()
        print("  hide wid \(w.wid) \(w.appName)")
        cycleWindow(forward: true)
    }

    // MARK: - UI

    func printWindowList() {
        for w in modeWindowList {
            let marker = (modeWindowList.firstIndex(where: { $0.cgWindowId == w.cgWindowId }) == modeCurrentIndex) ? ">" : " "
            print("  \(marker) \(w.wid) \(w.appName): \(w.title)")
        }
    }

    func printMonitorList() {
        let monitors = self.monitors.current()
        for m in monitors {
            print("  @\(m.id) \(m.name) \(Int(m.frame.width))x\(Int(m.frame.height))")
        }
    }

    func printBoardList() {
        for (name, layout) in state.boards.sorted(by: { $0.key < $1.key }) {
            print("  .\(name) @\(layout.monitorId) [\(layout.cgWindowIds.count) windows]")
        }
    }
}
