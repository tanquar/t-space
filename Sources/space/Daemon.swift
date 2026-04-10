import Foundation
import AppKit
import ApplicationServices

/// Global reference for C callback
private var globalDaemon: SpaceDaemon?

extension CGEvent {
    var keyboardCharString: String? {
        let maxLen = 4
        var chars = [UniChar](repeating: 0, count: maxLen)
        var length = 0
        self.keyboardGetUnicodeString(maxStringLength: maxLen, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}

/// Daemon mode: watch for focus changes, display reconfigurations, and key events.
class SpaceDaemon {
    let state: SpaceState
    let monitors: MonitorRegistry
    private var ipcServer: IPCServer?
    var observers: [pid_t: AXObserver] = [:]
    var knownPids: Set<pid_t> = []
    var suppressUntil: Date = .distantPast
    var displayDebounceTimer: DispatchWorkItem?

    // Mode state (accessed by ModeHandler/InputHandler extensions)
    var isInMode = false
    var modeWindowList: [WindowInfo] = []
    var modeCurrentIndex: Int = -1
    var modeCurrentMonitorId: Int?
    var inputBuffer: String = ""
    var inputPrompt: String = ""
    var isInputMode: Bool { !inputPrompt.isEmpty }
    var swapPending: Bool = false

    private var eventTap: CFMachPort?

    init(state: SpaceState) {
        self.state = state
        self.monitors = MonitorRegistry(state: state)
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

            if flags.contains(.beginConfigurationFlag) { return }
            daemon.monitors.invalidate()
            daemon.scheduleRestore()
        }, nil)

        // Register observers for all running apps
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            registerObserver(for: app)
        }

        setupEventTap()

        // Start IPC server for CLI clients
        ipcServer = IPCServer { [weak self] req in
            guard let self = self else {
                return IPC.Response(out: "", err: "daemon shutting down", code: 1)
            }
            return runCommand(argv: req.argv, daemon: self)
        }
        do {
            try ipcServer?.start()
        } catch {
            print("IPC server failed to start: \(error)")
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.run()
    }

    // MARK: - Display Reconfiguration

    func scheduleRestore() {
        suppressUntil = Date().addingTimeInterval(2)

        displayDebounceTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.doRestore()
        }
        displayDebounceTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func doRestore() {
        let monitors = self.monitors.current()
        let availableIds = Set(monitors.map(\.id))
        let expectedIds = Set(state.boards.values.map(\.monitorId))
        let missing = expectedIds.subtracting(availableIds)

        print("Restoring boards (monitors: \(availableIds.sorted()), missing: \(missing.sorted()))...")

        let windows = state.assignWids(detectWindows())

        for (name, layout) in state.boards.sorted(by: { $0.key < $1.key }) {
            let targetMonitor = monitors.first(where: { $0.id == layout.monitorId })
                ?? monitors.first(where: { $0.isMain })
                ?? monitors.first
            guard let monitor = targetMonitor else { continue }

            let targetExists = monitors.first(where: { $0.id == layout.monitorId }) != nil
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
                focusWindow(w.windowElement, pid: w.pid)
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
        if isInMode { return }

        var cgWinId: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &cgWinId) == .success else { return }

        let monitors = self.monitors.current()
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

    // MARK: - Event Tap

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

        // In mode: consume keyUp/flagsChanged to avoid leaking to apps
        if isInMode && type != .keyDown {
            return nil
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let isOptHeld = flags.contains(.maskAlternate)

        // Option+Tab: enter mode or cycle
        if keycode == 48 && isOptHeld {
            if !isInMode {
                enterMode()
                return nil
            } else {
                let isShift = flags.contains(.maskShift)
                cycleWindow(forward: !isShift)
                return nil
            }
        }

        // Swap sub-mode (x + next key)
        if isInMode && swapPending {
            let isShift = flags.contains(.maskShift)
            _ = handleSwapKey(keycode: keycode, shift: isShift)
            return nil
        }

        // Input sub-mode
        if isInMode && isInputMode {
            return handleInputKey(keycode: keycode, flags: flags, event: event)
        }

        // Command lookup
        if isInMode {
            let isShift = flags.contains(.maskShift)
            if let cmd = lookupCommand(keycode: keycode, shift: isShift) {
                executeCommand(cmd)
                return nil
            }

            // Unknown key: exit mode, consume event
            print("  [key \(keycode) → exit]")
            exitMode(confirmed: false)
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    func enterMode() {
        isInMode = true
        modeCurrentIndex = -1
        modeCurrentMonitorId = nil
        print("MODE ENTER")

        // Detect currently focused window before async load
        let focusedCgId = detectFocusedWindowCgId()

        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isInMode else { return }
            self.modeWindowList = self.state.assignWids(detectWindows())

            // Set initial selection to the currently focused window
            if let cgId = focusedCgId,
               let idx = self.modeWindowList.firstIndex(where: { $0.cgWindowId == cgId }) {
                self.modeCurrentIndex = idx
                let w = self.modeWindowList[idx]
                let monitors = self.monitors.current()
                self.modeCurrentMonitorId = monitorForWindow(w, monitors: monitors)?.id
                print("  (\(self.modeWindowList.count) windows, active: wid \(w.wid) \(w.appName))")
            } else {
                print("  (\(self.modeWindowList.count) windows)")
            }
        }
    }

    /// Get the CGWindowID of the currently focused window
    private func detectFocusedWindowCgId() -> Int? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return nil }

        var cgWinId: CGWindowID = 0
        guard _AXUIElementGetWindow(focused as! AXUIElement, &cgWinId) == .success else { return nil }
        return Int(cgWinId)
    }

    func exitMode(confirmed: Bool) {
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
        inputPrompt = ""
        inputBuffer = ""
        swapPending = false
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
