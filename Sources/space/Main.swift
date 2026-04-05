import Foundation
import AppKit

@main
struct SpaceCLI {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())

        if args.isEmpty {
            printHelp()
            return
        }

        let state = SpaceState.load()

        switch args[0] {
        case "debug-menubar":
            debugMenuBar()
        case "ls":
            handleLs(Array(args.dropFirst()), state: state)
        case "tile":
            requireAccessibility()
            handleTile(Array(args.dropFirst()), state: state)
        case "show":
            requireAccessibility()
            handleShow(Array(args.dropFirst()), state: state)
        case "daemon":
            let daemon = SpaceDaemon(state: state)
            daemon.run()
        default:
            print("Unknown command: \(args[0])")
            printHelp()
        }
    }

    static func printHelp() {
        print("t-space - window manager")
        print("")
        print("Usage: space <command> [args...]")
        print("")
        print("Commands:")
        print("  ls                      List windows")
        print("  ls boards               List boards")
        print("  ls monitors             List monitors")
        print("")
        print("  tile <wids...> [@N]     Tile windows (no focus change)")
        print("  tile <wids...> .name    Tile + save as board")
        print("  tile .name = .a .b      Composite board")
        print("")
        print("  show <wids...> [@N]     Tile + hide others + focus")
        print("  show .name [@N]         Show a saved board")
        print("  show @N                 Focus window on monitor")
        print("")
        print("Layout:")
        print("  1 2                     Horizontal split")
        print("  1 2 / 3                 Row split: [1|2] / [3]")
        print("  1 - 2 / 3              Column split: [1] | [2/3]")
        print("  1:w30 - 2:h40 / 3      Width/height: 30% col, 40% row")
        print("  1:w60h40               Combined width+height")
        print("  1 2 /70 3              Row height: top 70%")
        print("  _                      Empty slot")
        print("")
        print("  daemon                 Watch focus changes, auto-restore hidden windows")
    }

    // MARK: - ls

    static func handleLs(_ args: [String], state: SpaceState) {
        let subcommand = args.first ?? "all"

        switch subcommand {
        case "monitors", "m":
            if args.contains("--refresh") {
                let cacheFile = NSHomeDirectory() + "/.t-space-monitors.json"
                try? FileManager.default.removeItem(atPath: cacheFile)
                print("Monitor cache cleared.")
            }
            listMonitors()
        case "windows", "w":
            requireAccessibility()
            listWindowsWithState(state)
        case "boards", "b":
            listBoards(state)
        case "all":
            listMonitors()
            print("")
            requireAccessibility()
            listWindowsWithState(state)
            if !state.boards.isEmpty {
                print("")
                listBoards(state)
            }
        default:
            print("Unknown: ls \(subcommand)")
        }
    }

    static func listWindowsWithState(_ state: SpaceState) {
        let monitors = detectMonitors()
        let windows = state.assignWids(detectWindows())
        print("wid @   board  app              title")
        for w in windows {
            let mon = monitorForWindow(w, monitors: monitors)
            let monId = mon.map { "@\($0.id)" } ?? "?"
            let board = state.boardForWindow(w.cgWindowId).map { ".\($0)" } ?? "-"

            let id = "\(w.wid)".padding(toLength: 4, withPad: " ", startingAt: 0)
            let monCol = monId.padding(toLength: 4, withPad: " ", startingAt: 0)
            let boardCol = board.padding(toLength: 7, withPad: " ", startingAt: 0)
            let app = w.appName.padding(toLength: 17, withPad: " ", startingAt: 0)
            print("\(id)\(monCol)\(boardCol)\(app)\(w.title)")
        }
        print("\n\(windows.count) windows")
    }

    static func listBoards(_ state: SpaceState) {
        if state.boards.isEmpty {
            print("No boards defined.")
            return
        }
        // Reverse map: cgWindowId -> wid
        var cgToWid: [Int: Int] = [:]
        for (wid, cgId) in state.widMap {
            cgToWid[cgId] = wid
        }

        print("board    @   windows")
        for (name, layout) in state.boards.sorted(by: { $0.key < $1.key }) {
            let boardName = ".\(name)".padding(toLength: 9, withPad: " ", startingAt: 0)
            let monCol = "@\(layout.monitorId)".padding(toLength: 4, withPad: " ", startingAt: 0)
            let wids: String
            if let children = layout.childBoards {
                wids = children.map { ".\($0)" }.joined(separator: " ")
            } else {
                wids = layout.cgWindowIds.map { cgToWid[$0].map(String.init) ?? "?" }.joined(separator: " ")
            }
            print("\(boardName)\(monCol)\(wids)")
        }
    }

    // MARK: - tile

    static func handleTile(_ args: [String], state: SpaceState) {
        guard !args.isEmpty else {
            print("Usage: space tile <wids...> [@monitor] [.board]")
            print("       space tile .board = .board1 .board2 [@monitor]")
            return
        }

        guard let spec = parseTileArgs(args) else {
            return
        }

        let monitors = detectMonitors()
        let windows = state.assignWids(detectWindows())
        executeTile(spec: spec, state: state, windows: windows, monitors: monitors)
    }

    // MARK: - show

    static func handleShow(_ args: [String], state: SpaceState) {
        guard !args.isEmpty else {
            print("Usage: space show <wids/boards...> [@monitor] [.board]")
            print("       space show .board [@monitor]")
            print("       space show @monitor")
            return
        }

        let monitors = detectMonitors()
        let windows = state.assignWids(detectWindows())
        executeShow(args: args, state: state, windows: windows, monitors: monitors)
    }

    // MARK: - Helpers

    static func requireAccessibility() {
        if !AXIsProcessTrusted() {
            print("Accessibility permission required.")
            print("  System Settings > Privacy & Security > Accessibility")
            exit(1)
        }
    }
}
