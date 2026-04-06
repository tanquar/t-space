import Foundation
import AppKit
import ApplicationServices

/// Global reference for C callback
private var globalDaemon: SpaceDaemon?

extension CGEvent {
    /// Get the character string from a keyboard event
    var keyboardCharString: String? {
        let maxLen = 4
        var chars = [UniChar](repeating: 0, count: maxLen)
        var length = 0
        self.keyboardGetUnicodeString(maxStringLength: maxLen, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}

/// Daemon mode: watch for focus changes and display reconfigurations.
class SpaceDaemon {
    let state: SpaceState
    var observers: [pid_t: AXObserver] = [:]
    var knownPids: Set<pid_t> = []
    var suppressUntil: Date = .distantPast
    var displayDebounceTimer: DispatchWorkItem?

    init(state: SpaceState) {
        self.state = state
    }

    func run() {
        requireAccessibility()
        globalDaemon = self
        print("t-space daemon started. Watching for focus changes...")

        // Watch for app activations
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.handleAppActivated(app)
        }

        // Watch for new app launches
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.registerObserver(for: app)
        }

        // Watch for app terminations
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.removeObserver(for: app.processIdentifier)
        }

        // Display reconfiguration: debounce 700ms then restore
        CGDisplayRegisterReconfigurationCallback({ displayId, flags, _ in
            guard let daemon = globalDaemon else { return }

            let flagStrs: [String] = {
                var s: [String] = []
                if flags.contains(.beginConfigurationFlag) { s.append("begin") }
                if flags.contains(.movedFlag) { s.append("moved") }
                if flags.contains(.setMainFlag) { s.append("setMain") }
                if flags.contains(.setModeFlag) { s.append("setMode") }
                if flags.contains(.addFlag) { s.append("add") }
                if flags.contains(.removeFlag) { s.append("remove") }
                if flags.contains(.enabledFlag) { s.append("enabled") }
                if flags.contains(.disabledFlag) { s.append("disabled") }
                if flags.contains(.mirrorFlag) { s.append("mirror") }
                if flags.rawValue & 0x00000080 != 0 { s.append("unmirror") }
                if flags.contains(.desktopShapeChangedFlag) { s.append("desktopShapeChanged") }
                return s
            }()
            let ts = ISO8601DateFormatter().string(from: Date())
            print("[\(ts)] Display \(displayId): \(flagStrs.joined(separator: ", "))")

            // Skip begin events (they come in pairs: begin then actual change)
            if flags.contains(.beginConfigurationFlag) { return }

            // Debounce: reset timer on each event, fire 700ms after last event
            daemon.scheduleRestore()
        }, nil)

        // Register observers for all running apps
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            registerObserver(for: app)
        }

        // Global key event tap (Cmd+Tab interception)
        setupEventTap()

        // NSApplication is required for system notifications
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.run()
    }

    // MARK: - Display Reconfiguration

    /// Schedule board restoration with 700ms debounce.
    func scheduleRestore() {
        suppressUntil = Date().addingTimeInterval(2)

        displayDebounceTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.doRestore()
        }
        displayDebounceTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    /// Restore all boards on available monitors.
    /// Does NOT update board.monitorId.
    private func doRestore() {
        // Clear monitor cache
        let cacheFile = NSHomeDirectory() + "/.t-space-monitors.json"
        try? FileManager.default.removeItem(atPath: cacheFile)

        let monitors = detectMonitors()
        let availableIds = Set(monitors.map(\.id))
        let expectedIds = Set(state.boards.values.map(\.monitorId))
        let missing = expectedIds.subtracting(availableIds)

        print("Restoring boards (monitors: \(availableIds.sorted()), missing: \(missing.sorted()))...")

        let windows = state.assignWids(detectWindows())

        for (name, layout) in state.boards.sorted(by: { $0.key < $1.key }) {
            let targetExists = monitors.first(where: { $0.id == layout.monitorId }) != nil
            let targetMonitor = monitors.first(where: { $0.id == layout.monitorId })
                ?? monitors.first(where: { $0.isMain })
                ?? monitors.first
            guard let monitor = targetMonitor else { continue }

            if targetExists {
                print("  .\(name) -> @\(layout.monitorId)")
            } else {
                print("  .\(name) -> @\(monitor.id) (temporary, waiting for @\(layout.monitorId))")
            }

            guard let spec = parseTileArgs(layout.definition.components(separatedBy: " ")) else { continue }
            let frames = resolveTileFrames(spec: spec, within: monitor.usableFrame)
            let movedCgIds = placeWindows(frames: frames, state: state, windows: windows, preferCgId: true)

            for cgId in movedCgIds.reversed() {
                if let w = state.resolveByCgId(cgId, in: windows) {
                    raiseWindow(w.windowElement)
                }
            }
            let focusCgId = layout.lastFocusedCgId ?? layout.cgWindowIds.first
            if let cgId = focusCgId, let w = state.resolveByCgId(cgId, in: windows) {
                activateApp(pid: w.pid)
                raiseWindow(w.windowElement)
            }
        }

        suppressUntil = .distantPast
        print("Restore complete.")
    }

    // MARK: - Focus Change

    private func registerObserver(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard !knownPids.contains(pid) else { return }
        knownPids.insert(pid)

        var observer: AXObserver?
        let result = AXObserverCreate(pid, { (observer, element, notification, refcon) in
            guard let refcon = refcon else { return }
            let daemon = Unmanaged<SpaceDaemon>.fromOpaque(refcon).takeUnretainedValue()
            daemon.handleFocusChange(element: element)
        }, &observer)

        guard result == .success, let obs = observer else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        AXObserverAddNotification(obs, appElement, kAXFocusedWindowChangedNotification as CFString, selfPtr)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)

        observers[pid] = obs
    }

    private func removeObserver(for pid: pid_t) {
        observers.removeValue(forKey: pid)
        knownPids.remove(pid)
    }

    private func handleAppActivated(_ app: NSRunningApplication) {
        registerObserver(for: app)

        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
              let focusedWindow = focusedRef else {
            return
        }
        handleFocusChange(element: focusedWindow as! AXUIElement)
    }

    private func handleFocusChange(element: AXUIElement) {
        if Date() < suppressUntil { return }
        if isInMode { return }  // Don't auto-restore while in mode

        var cgWinId: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &cgWinId) == .success else { return }

        let monitors = detectMonitors()
        let windows = state.assignWids(detectWindows())

        guard let window = windows.first(where: { $0.cgWindowId == Int(cgWinId) }) else { return }

        let isVisible = monitors.contains { mon in
            let rect = CGRect(origin: window.position, size: window.size)
            let overlap = mon.frame.intersection(rect)
            return overlap.width > rect.width * 0.3 && overlap.height > rect.height * 0.3
        }

        if !isVisible {
            print("Auto-restore: wid \(window.wid) (\(window.appName))")
            executeShow(
                args: ["\(window.wid)"],
                state: state,
                windows: windows,
                monitors: monitors
            )
        }
    }

    // MARK: - Event Tap & Modal Mode

    private var isInMode = false
    private var modeWindowList: [WindowInfo] = []
    private var modeCurrentIndex: Int = 0
    private var modeCurrentMonitorId: Int?  // tracks actual current monitor
    private var eventTap: CFMachPort?

    private func setupEventTap() {
        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let daemon = Unmanaged<SpaceDaemon>.fromOpaque(refcon).takeUnretainedValue()

                // Re-enable tap if macOS disabled it (timeout)
                if type == .tapDisabledByTimeout {
                    if let t = daemon.eventTap {
                        CGEvent.tapEnable(tap: t, enable: true)
                        print("Event tap re-enabled (was disabled by timeout)")
                    }
                    return Unmanaged.passUnretained(event)
                }

                return daemon.handleKeyEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("Failed to create event tap. Check Accessibility permissions.")
            return
        }

        self.eventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("Event tap installed.")
    }

    private func handleKeyEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // In mode: consume keyUp to avoid leaking to apps
        if isInMode && type != .keyDown {
            return nil
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let isOptHeld = flags.contains(.maskAlternate)

        // --- keyDown handling ---

        // Option+Tab: enter/cycle mode
        if keycode == 48 && isOptHeld {  // Tab = 48
            if !isInMode {
                enterMode()
                return nil
            } else {
                // Cycle next in mode
                let isShift = flags.contains(.maskShift)
                cycleWindow(forward: !isShift)
                return nil
            }
        }

        // While in input sub-mode, accumulate text
        if isInMode && isInputMode {
            return handleInputKey(keycode: keycode, flags: flags, event: event)
        }

        // While in mode, look up command by keycode
        if isInMode {
            let isShift = flags.contains(.maskShift)
            if let cmd = lookupCommand(keycode: keycode, shift: isShift) {
                executeCommand(cmd)
                return nil
            }

            // Unknown key: exit mode, pass through
            print("  [key \(keycode) → exit]")
            exitMode(confirmed: false)
            return Unmanaged.passUnretained(event)
        }

        // Not in mode: pass through
        return Unmanaged.passUnretained(event)
    }

    private func enterMode() {
        isInMode = true
        modeCurrentIndex = -1
        print("MODE ENTER")
        // Load window list async to avoid blocking the event tap
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isInMode else { return }
            self.modeWindowList = self.state.assignWids(detectWindows())
            print("  (\(self.modeWindowList.count) windows loaded)")
        }
    }

    // MARK: - Commands & Keybindings

    /// Input buffer for commands that need text (t, s, ., @, -, /)
    private var inputBuffer: String = ""
    private var inputPrompt: String = ""  // what initiated the input ("t", "s", ".", "@", "-", "/")

    var isInputMode: Bool { !inputPrompt.isEmpty }

    /// Named commands (decoupled from keybindings)
    enum Command: String, CaseIterable {
        // Window focus (h/j/k/l)
        case focusLeft = "focus-left"
        case focusDown = "focus-down"
        case focusUp = "focus-up"
        case focusRight = "focus-right"
        case focusNextWindow = "focus-next-window"       // n
        case focusPrevWindow = "focus-prev-window"       // p

        // Window swap (H/J/K/L)
        case swapLeft = "swap-left"
        case swapDown = "swap-down"
        case swapUp = "swap-up"
        case swapRight = "swap-right"
        case swapNextWindow = "swap-next-window"         // N
        case swapPrevWindow = "swap-prev-window"         // P

        // Monitor ([/])
        case focusNextMonitor = "focus-next-monitor"
        case focusPrevMonitor = "focus-prev-monitor"

        // Resize (r/R/c/C)
        case growHeight = "grow-height"
        case shrinkHeight = "shrink-height"
        case growWidth = "grow-width"
        case shrinkWidth = "shrink-width"

        // Board on current monitor (i/o/I/O)
        case showNextBoardOnMonitor = "show-next-board-on-monitor"
        case showPrevBoardOnMonitor = "show-prev-board-on-monitor"
        case showFirstBoardOnMonitor = "show-first-board-on-monitor"
        case showLastBoardOnMonitor = "show-last-board-on-monitor"

        // Window action
        case hideWindow = "hide-window"                  // d

        // UI / input
        case listWindows = "list-windows"                // w
        case listMonitors = "list-monitors"              // m
        case listBoards = "list-boards"                  // b
        case inputTile = "input-tile"                    // t
        case inputShow = "input-show"                    // s
        case inputBoard = "input-board"                  // .
        case inputMonitor = "input-monitor"              // @
        case inputSplitH = "input-split-h"               // -
        case inputSplitV = "input-split-v"               // /

        // Select by number
        case selectWindow1 = "select-window-1"
        case selectWindow2 = "select-window-2"
        case selectWindow3 = "select-window-3"
        case selectWindow4 = "select-window-4"
        case selectWindow5 = "select-window-5"
        case selectWindow6 = "select-window-6"
        case selectWindow7 = "select-window-7"
        case selectWindow8 = "select-window-8"
        case selectWindow9 = "select-window-9"

        // Mode
        case cancel = "cancel"
    }

    /// Keybinding: (keycode, shift) → command
    struct KeyBinding {
        let keycode: Int64
        let shift: Bool
        let command: Command
    }

    static let defaultBindings: [KeyBinding] = [
        // vi focus (lowercase)
        .init(keycode: 4,  shift: false, command: .focusLeft),
        .init(keycode: 38, shift: false, command: .focusDown),
        .init(keycode: 40, shift: false, command: .focusUp),
        .init(keycode: 37, shift: false, command: .focusRight),
        // vi swap (uppercase)
        .init(keycode: 4,  shift: true,  command: .swapLeft),
        .init(keycode: 38, shift: true,  command: .swapDown),
        .init(keycode: 40, shift: true,  command: .swapUp),
        .init(keycode: 37, shift: true,  command: .swapRight),

        // cycle windows
        .init(keycode: 45, shift: false, command: .focusNextWindow),  // n
        .init(keycode: 35, shift: false, command: .focusPrevWindow),  // p
        .init(keycode: 48, shift: false, command: .focusNextWindow),  // Tab
        .init(keycode: 48, shift: true,  command: .focusPrevWindow),  // Shift+Tab
        // swap windows
        .init(keycode: 45, shift: true,  command: .swapNextWindow),   // N
        .init(keycode: 35, shift: true,  command: .swapPrevWindow),   // P

        // monitor
        .init(keycode: 33, shift: false, command: .focusNextMonitor), // [
        .init(keycode: 30, shift: false, command: .focusPrevMonitor), // ]

        // resize
        .init(keycode: 15, shift: false, command: .growHeight),       // r
        .init(keycode: 15, shift: true,  command: .shrinkHeight),     // R
        .init(keycode: 8,  shift: false, command: .growWidth),        // c
        .init(keycode: 8,  shift: true,  command: .shrinkWidth),      // C

        // boards on current monitor
        .init(keycode: 34, shift: false, command: .showNextBoardOnMonitor),  // i
        .init(keycode: 31, shift: false, command: .showPrevBoardOnMonitor),  // o
        .init(keycode: 34, shift: true,  command: .showFirstBoardOnMonitor), // I
        .init(keycode: 31, shift: true,  command: .showLastBoardOnMonitor),  // O

        // hide
        .init(keycode: 2,  shift: false, command: .hideWindow),       // d

        // UI
        .init(keycode: 13, shift: false, command: .listWindows),      // w
        .init(keycode: 46, shift: false, command: .listMonitors),     // m
        .init(keycode: 11, shift: false, command: .listBoards),       // b

        // input commands
        .init(keycode: 17, shift: false, command: .inputTile),        // t
        .init(keycode: 1,  shift: false, command: .inputShow),        // s
        .init(keycode: 47, shift: false, command: .inputBoard),       // . (period)
        .init(keycode: 27, shift: false, command: .inputSplitH),      // -
        .init(keycode: 44, shift: false, command: .inputSplitV),      // /
        .init(keycode: 19, shift: true,  command: .inputMonitor),     // @ (Shift+2)

        // number select
        .init(keycode: 18, shift: false, command: .selectWindow1),
        .init(keycode: 19, shift: false, command: .selectWindow2),
        .init(keycode: 20, shift: false, command: .selectWindow3),
        .init(keycode: 21, shift: false, command: .selectWindow4),
        .init(keycode: 23, shift: false, command: .selectWindow5),
        .init(keycode: 22, shift: false, command: .selectWindow6),
        .init(keycode: 26, shift: false, command: .selectWindow7),
        .init(keycode: 28, shift: false, command: .selectWindow8),
        .init(keycode: 25, shift: false, command: .selectWindow9),

        // cancel
        .init(keycode: 53, shift: false, command: .cancel),           // Escape
    ]

    /// Look up command for a key event
    private func lookupCommand(keycode: Int64, shift: Bool) -> Command? {
        // Prefer shift-specific match, then non-shift
        SpaceDaemon.defaultBindings.first { $0.keycode == keycode && $0.shift == shift }?.command
    }

    /// Execute a named command.
    private func executeCommand(_ cmd: Command) {
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

    enum Direction { case left, down, up, right }

    private func navigate(direction: Direction) {
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

                // Filter by monitor
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

    private func cycleWindow(forward: Bool) {
        guard !modeWindowList.isEmpty else { return }

        let monitors = detectMonitors()
        let curMonId = modeCurrentMonitorId

        // Collect indices on the same monitor
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

    private func selectWindow(wid: Int) {
        if let idx = modeWindowList.firstIndex(where: { $0.wid == wid }) {
            modeCurrentIndex = idx
            focusCurrentWindow()
        } else {
            print("  wid \(wid) not found")
        }
    }

    /// Focus the currently selected window.
    /// If the window is off-screen (retreat area), restore it to monitor center.
    private func focusCurrentWindow() {
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
            // Restore to default monitor full screen
            let mon = monitors.first(where: { $0.isMain }) ?? monitors.first!
            moveWindow(w.windowElement, to: mon.usableFrame)
            state.clearHidden(w.cgWindowId)
            state.save()
        }

        raiseWindow(w.windowElement)
        activateApp(pid: w.pid)

        // Update current monitor tracking
        if !isVisible {
            let mon = monitors.first(where: { $0.isMain }) ?? monitors.first!
            modeCurrentMonitorId = mon.id
        } else {
            modeCurrentMonitorId = monitorForWindow(w, monitors: monitors)?.id
        }

        print("  -> wid \(w.wid) \(w.appName): \(w.title)\(isVisible ? "" : " (restored)")")
    }

    private func swapWindow(direction: Direction) {
        print("  [swap \(direction): not yet implemented]")
    }

    private func swapWindowCycle(forward: Bool) {
        print("  [swap \(forward ? "next" : "prev"): not yet implemented]")
    }

    private func resizeCurrentWindow(dw: CGFloat, dh: CGFloat) {
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

    private func cycleBoardOnMonitor(forward: Bool) {
        let monitors = detectMonitors()
        let currentMonId = getCurrentMonitorId(monitors: monitors)
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

    private func showBoardOnMonitor(first: Bool) {
        let monitors = detectMonitors()
        let currentMonId = getCurrentMonitorId(monitors: monitors)
        let boardNames = state.boards.filter { $0.value.monitorId == currentMonId }.keys.sorted()
        guard !boardNames.isEmpty else { return }

        let boardName = first ? boardNames.first! : boardNames.last!
        print("  board .\(boardName) on @\(currentMonId)")
        let windows = state.assignWids(detectWindows())
        modeWindowList = windows
        executeShow(args: [".\(boardName)"], state: state, windows: windows, monitors: monitors)
    }

    private func getCurrentMonitorId(monitors: [MonitorInfo]) -> Int {
        if modeCurrentIndex >= 0 && modeCurrentIndex < modeWindowList.count {
            let w = modeWindowList[modeCurrentIndex]
            return monitorForWindow(w, monitors: monitors)?.id ?? 1
        }
        return monitors.first(where: { $0.isMain })?.id ?? 1
    }

    private func printWindowList() {
        for w in modeWindowList {
            let marker = (modeWindowList.firstIndex(where: { $0.cgWindowId == w.cgWindowId }) == modeCurrentIndex) ? ">" : " "
            print("  \(marker) \(w.wid) \(w.appName): \(w.title)")
        }
    }

    private func printMonitorList() {
        let monitors = detectMonitors()
        for m in monitors {
            print("  @\(m.id) \(m.name) \(Int(m.frame.width))x\(Int(m.frame.height))")
        }
    }

    private func printBoardList() {
        for (name, layout) in state.boards.sorted(by: { $0.key < $1.key }) {
            print("  .\(name) @\(layout.monitorId) [\(layout.cgWindowIds.count) windows]")
        }
    }

    // MARK: - Input Sub-mode

    private func startInput(_ prompt: String) {
        inputPrompt = prompt
        inputBuffer = ""
        print("  \(prompt)")
    }

    private func handleInputKey(keycode: Int64, flags: CGEventFlags, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Enter (keycode 36): submit
        if keycode == 36 {
            submitInput()
            return nil
        }

        // Escape: cancel input
        if keycode == 53 {
            inputPrompt = ""
            inputBuffer = ""
            print("  (input cancelled)")
            return nil
        }

        // Backspace (keycode 51): delete last char
        if keycode == 51 {
            if !inputBuffer.isEmpty {
                inputBuffer.removeLast()
                print("  \(inputPrompt)\(inputBuffer)")
            }
            return nil
        }

        // Accumulate character
        if let chars = event.keyboardCharString {
            inputBuffer += chars
            print("  \(inputPrompt)\(inputBuffer)")
        }

        return nil
    }

    private func submitInput() {
        let input = inputBuffer
        let prompt = inputPrompt
        inputPrompt = ""
        inputBuffer = ""

        guard !input.isEmpty else {
            print("  (empty input)")
            return
        }

        print("  execute: \(prompt)\(input)")

        let monitors = detectMonitors()
        let windows = state.assignWids(detectWindows())
        modeWindowList = windows

        switch prompt {
        case "tile":
            let args = input.components(separatedBy: " ")
            executeTile(spec: parseTileArgs(args)!, state: state, windows: windows, monitors: monitors)
        case "show":
            executeShow(args: input.components(separatedBy: " "), state: state, windows: windows, monitors: monitors)
        case ".":
            // .name or .name@N
            if input.contains("@") {
                let parts = input.components(separatedBy: "@")
                executeShow(args: [".\(parts[0])", "@\(parts[1])"], state: state, windows: windows, monitors: monitors)
            } else {
                executeShow(args: [".\(input)"], state: state, windows: windows, monitors: monitors)
            }
        case "@":
            // @N or @N.board
            if input.contains(".") {
                let parts = input.components(separatedBy: ".")
                executeShow(args: [".\(parts[1])", "@\(parts[0])"], state: state, windows: windows, monitors: monitors)
            } else {
                executeShow(args: ["@\(input)"], state: state, windows: windows, monitors: monitors)
            }
        case "-", "/":
            print("  [split: not yet implemented]")
        default:
            break
        }
    }

    private func cycleMonitor(forward: Bool) {
        let monitors = detectMonitors().sorted { $0.id < $1.id }
        guard monitors.count > 1 else { return }

        // Find current monitor from current window
        let currentMonId: Int
        if modeCurrentIndex >= 0 && modeCurrentIndex < modeWindowList.count {
            let w = modeWindowList[modeCurrentIndex]
            currentMonId = monitorForWindow(w, monitors: monitors)?.id ?? monitors[0].id
        } else {
            currentMonId = monitors[0].id
        }

        let ids = monitors.map(\.id)
        guard let idx = ids.firstIndex(of: currentMonId) else { return }
        let nextIdx = forward ? (idx + 1) % ids.count : (idx - 1 + ids.count) % ids.count
        let nextMonId = ids[nextIdx]

        // Focus first window on that monitor
        if let w = modeWindowList.first(where: { monitorForWindow($0, monitors: monitors)?.id == nextMonId }) {
            modeCurrentIndex = modeWindowList.firstIndex(where: { $0.cgWindowId == w.cgWindowId }) ?? modeCurrentIndex
            print("  monitor @\(nextMonId) -> wid \(w.wid) \(w.appName)")
        } else {
            print("  monitor @\(nextMonId) -> (no windows)")
        }
    }


    private func hideCurrentWindow() {
        guard modeCurrentIndex >= 0 && modeCurrentIndex < modeWindowList.count else { return }
        let w = modeWindowList[modeCurrentIndex]
        let monitors = detectMonitors()
        state.recordHidden(w, monitors: monitors)
        hideWindow(w.windowElement, monitors: monitors)
        state.save()
        print("  hide wid \(w.wid) \(w.appName)")
        // Move to next window
        cycleWindow(forward: true)
    }

    private func exitMode(confirmed: Bool) {
        if confirmed && modeCurrentIndex >= 0 && modeCurrentIndex < modeWindowList.count {
            let w = modeWindowList[modeCurrentIndex]
            print("MODE EXIT -> wid \(w.wid) \(w.appName)")
        } else {
            print("MODE EXIT (cancelled)")
        }
        isInMode = false
        modeWindowList = []
        modeCurrentIndex = -1
        modeCurrentMonitorId = nil
    }

    // MARK: - Helpers

    private func requireAccessibility() {
        if !AXIsProcessTrusted() {
            print("Accessibility permission required.")
            print("  System Settings > Privacy & Security > Accessibility")
            exit(1)
        }
    }
}
