import Foundation

/// Command dispatcher invoked by the daemon's IPC handler.
/// Returns an IPC.Response. All commands run on the main thread.

func runCommand(argv: [String], daemon: SpaceDaemon) -> IPC.Response {
    guard let cmd = argv.first else {
        return IPC.Response(out: "", err: "no command", code: 1)
    }

    switch cmd {
    case "ls":
        return runLs(args: Array(argv.dropFirst()), daemon: daemon)
    case "tile":
        return runTile(args: Array(argv.dropFirst()), daemon: daemon)
    case "show":
        return runShow(args: Array(argv.dropFirst()), daemon: daemon)
    default:
        return IPC.Response(out: "", err: "unknown command: \(cmd)", code: 1)
    }
}

// MARK: - ls

private func runLs(args: [String], daemon: SpaceDaemon) -> IPC.Response {
    let sub = args.first ?? "all"
    let state = daemon.state

    switch sub {
    case "monitors", "m":
        return IPC.Response(out: renderMonitorList(daemon: daemon), err: "", code: 0)
    case "windows", "w":
        return IPC.Response(out: renderWindowList(daemon: daemon), err: "", code: 0)
    case "boards", "b":
        return IPC.Response(out: renderBoardList(state: state), err: "", code: 0)
    case "all":
        var parts = [renderMonitorList(daemon: daemon), renderWindowList(daemon: daemon)]
        if !state.boards.isEmpty {
            parts.append(renderBoardList(state: state))
        }
        return IPC.Response(out: parts.joined(separator: "\n\n"), err: "", code: 0)
    default:
        return IPC.Response(out: "", err: "Unknown: ls \(sub)", code: 1)
    }
}

// MARK: - tile

private func runTile(args: [String], daemon: SpaceDaemon) -> IPC.Response {
    guard !args.isEmpty else {
        return IPC.Response(
            out: "",
            err: """
            Usage: space tile <wids...> [@monitor] [.board]
                   space tile .board = .board1 .board2 [@monitor]
            """,
            code: 1
        )
    }

    guard let spec = parseTileArgs(args) else {
        return IPC.Response(out: "", err: "invalid tile spec", code: 1)
    }

    let monitors = daemon.monitors.current()
    let windows = daemon.state.assignWids(detectWindows())

    let captured = withCapturedStdout {
        executeTile(spec: spec, state: daemon.state, windows: windows, monitors: monitors)
    }
    return IPC.Response(out: captured, err: "", code: 0)
}

// MARK: - show

private func runShow(args: [String], daemon: SpaceDaemon) -> IPC.Response {
    guard !args.isEmpty else {
        return IPC.Response(
            out: "",
            err: """
            Usage: space show <wids/boards...> [@monitor] [.board]
                   space show .board [@monitor]
                   space show @monitor
            """,
            code: 1
        )
    }

    let monitors = daemon.monitors.current()
    let windows = daemon.state.assignWids(detectWindows())

    let captured = withCapturedStdout {
        executeShow(args: args, state: daemon.state, windows: windows, monitors: monitors)
    }
    return IPC.Response(out: captured, err: "", code: 0)
}

// MARK: - Renderers

func renderMonitorList(daemon: SpaceDaemon) -> String {
    let monitors = daemon.monitors.current()
    var lines: [String] = []
    lines.append("id  name             resolution       origin           usable                       main  stableKey")
    for m in monitors {
        let main = m.isMain ? "*" : " "
        let res = "\(Int(m.frame.width))x\(Int(m.frame.height))"
        let origin = "(\(Int(m.frame.origin.x)),\(Int(m.frame.origin.y)))"
        let usable = "(\(Int(m.usableFrame.origin.x)),\(Int(m.usableFrame.origin.y))) \(Int(m.usableFrame.width))x\(Int(m.usableFrame.height))"
        let id = "\(m.id)".padding(toLength: 4, withPad: " ", startingAt: 0)
        let name = m.name.padding(toLength: 17, withPad: " ", startingAt: 0)
        let resCol = res.padding(toLength: 17, withPad: " ", startingAt: 0)
        let originCol = origin.padding(toLength: 17, withPad: " ", startingAt: 0)
        let usableCol = usable.padding(toLength: 29, withPad: " ", startingAt: 0)
        lines.append("\(id)\(name)\(resCol)\(originCol)\(usableCol)\(main)     \(m.stableKey)")
    }
    return lines.joined(separator: "\n")
}

func renderWindowList(daemon: SpaceDaemon) -> String {
    let monitors = daemon.monitors.current()
    let windows = daemon.state.assignWids(detectWindows())
    var lines: [String] = []
    lines.append("wid @   board  app              title")
    for w in windows {
        let mon = monitorForWindow(w, monitors: monitors)
        let monId = mon.map { "@\($0.id)" } ?? "?"
        let board = daemon.state.boardForWindow(w.cgWindowId).map { ".\($0)" } ?? "-"

        let id = "\(w.wid)".padding(toLength: 4, withPad: " ", startingAt: 0)
        let monCol = monId.padding(toLength: 4, withPad: " ", startingAt: 0)
        let boardCol = board.padding(toLength: 7, withPad: " ", startingAt: 0)
        let app = w.appName.padding(toLength: 17, withPad: " ", startingAt: 0)
        lines.append("\(id)\(monCol)\(boardCol)\(app)\(w.title)")
    }
    lines.append("")
    lines.append("\(windows.count) windows")
    return lines.joined(separator: "\n")
}

func renderBoardList(state: SpaceState) -> String {
    if state.boards.isEmpty {
        return "No boards defined."
    }
    var cgToWid: [Int: Int] = [:]
    for (wid, cgId) in state.widMap {
        cgToWid[cgId] = wid
    }

    var lines: [String] = []
    lines.append("board    @   windows")
    for (name, layout) in state.boards.sorted(by: { $0.key < $1.key }) {
        let boardName = ".\(name)".padding(toLength: 9, withPad: " ", startingAt: 0)
        let monCol = "@\(layout.monitorId)".padding(toLength: 4, withPad: " ", startingAt: 0)
        let wids: String
        if let children = layout.childBoards {
            wids = children.map { ".\($0)" }.joined(separator: " ")
        } else {
            wids = layout.cgWindowIds.map { cgToWid[$0].map(String.init) ?? "?" }.joined(separator: " ")
        }
        lines.append("\(boardName)\(monCol)\(wids)")
    }
    return lines.joined(separator: "\n")
}
