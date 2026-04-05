import Foundation
import AppKit
import ApplicationServices

/// Global reference for C callback
private var globalDaemon: SpaceDaemon?

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
    private var eventTap: CFMachPort?
    private static let syntheticMarker: Int64 = 0x7370_6163  // "spac" in hex

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
        let isCmdHeld = flags.contains(.maskCommand)

        // Option release → exit mode
        let isOptHeld = flags.contains(.maskAlternate)
        if type == .flagsChanged && !isOptHeld && isInMode {
            exitMode(confirmed: true)
            return nil
        }

        guard type == .keyDown else {
            // Pass through keyUp and other flagsChanged
            if isInMode { return nil }
            return Unmanaged.passUnretained(event)
        }

        // --- keyDown handling ---

        // Option+Tab: enter/cycle mode
        let isOptHeld = flags.contains(.maskAlternate)
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

        // While in mode, handle keys
        if isInMode {
            // Escape: cancel immediately (even if Cmd held)
            if keycode == 53 {
                exitMode(confirmed: false)
                return nil
            }

            // All other keys: pass through, stay in mode
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

    private func cycleWindow(forward: Bool) {
        guard !modeWindowList.isEmpty else { return }
        if forward {
            modeCurrentIndex = (modeCurrentIndex + 1) % modeWindowList.count
        } else {
            modeCurrentIndex = (modeCurrentIndex - 1 + modeWindowList.count) % modeWindowList.count
        }
        let w = modeWindowList[modeCurrentIndex]
        print("  -> wid \(w.wid) \(w.appName): \(w.title)")
    }

    private func selectWindow(wid: Int) {
        if let w = modeWindowList.first(where: { $0.wid == wid }) {
            print("  => wid \(w.wid) \(w.appName): \(w.title)")
        } else {
            print("  => wid \(wid) not found")
        }
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
