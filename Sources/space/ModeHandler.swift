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

        // Window swap
        case .swapLeft:         swapWindow(direction: .left)
        case .swapDown:         swapWindow(direction: .down)
        case .swapUp:           swapWindow(direction: .up)
        case .swapRight:        swapWindow(direction: .right)
        case .swapNextWindow:   swapWindowCycle(forward: true)
        case .swapPrevWindow:   swapWindowCycle(forward: false)

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

        let monitors = detectMonitors()
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

        let monitors = detectMonitors()
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

        let monitors = detectMonitors()
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

        raiseWindow(w.windowElement)
        activateApp(pid: w.pid)

        if !isVisible {
            let mon = monitors.first(where: { $0.isMain }) ?? monitors.first!
            modeCurrentMonitorId = mon.id
        } else {
            modeCurrentMonitorId = monitorForWindow(w, monitors: monitors)?.id
        }

        print("  -> wid \(w.wid) \(w.appName): \(w.title)\(isVisible ? "" : " (restored)")")
    }

    // MARK: - Swap

    func swapWindow(direction: Direction) {
        print("  [swap \(direction): not yet implemented]")
    }

    func swapWindowCycle(forward: Bool) {
        print("  [swap \(forward ? "next" : "prev"): not yet implemented]")
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
        let monitors = detectMonitors().sorted { $0.id < $1.id }
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
        let monitors = detectMonitors()
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
        let monitors = detectMonitors()
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
        let monitors = detectMonitors()
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
        let monitors = detectMonitors()
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
