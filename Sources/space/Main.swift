import Foundation

@main
struct SpaceCLI {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())

        if args.isEmpty {
            printHelp()
            return
        }

        switch args[0] {
        case "help", "-h", "--help":
            printHelp()
        case "daemon":
            let state = SpaceState.load()
            let daemon = SpaceDaemon(state: state)
            daemon.run()
        case "debug-menubar":
            // Local one-shot, no daemon required
            debugMenuBar()
        default:
            // Forward to daemon via IPC
            forwardToDaemon(args)
        }
    }

    static func forwardToDaemon(_ args: [String]) {
        do {
            let resp = try ipcClient(IPC.Request(argv: args))
            if !resp.out.isEmpty { print(resp.out) }
            if !resp.err.isEmpty {
                FileHandle.standardError.write(Data((resp.err + "\n").utf8))
            }
            exit(Int32(resp.code))
        } catch {
            FileHandle.standardError.write(Data("daemon not running. start with: space daemon\n".utf8))
            exit(1)
        }
    }

    static func printHelp() {
        print("t-space - window manager")
        print("")
        print("Usage: space <command> [args...]")
        print("")
        print("All commands except `daemon` are forwarded to a running daemon via")
        print("~/.t-space.sock. Start the daemon first with `space daemon`.")
        print("")
        print("Commands:")
        print("  daemon                 Run the daemon (state owner; required for other commands)")
        print("  ls                     List monitors, windows, and boards")
        print("  ls monitors            List monitors")
        print("  ls windows             List windows")
        print("  ls boards              List boards")
        print("")
        print("  tile <wids...> [@N]    Tile windows (no focus change)")
        print("  tile <wids...> .name   Tile + save as board")
        print("  tile .name = .a .b     Composite board")
        print("")
        print("  show <wids...> [@N]    Tile + hide others + focus")
        print("  show .name [@N]        Show a saved board")
        print("  show @N                Focus window on monitor")
        print("")
        print("Layout syntax:")
        print("  1 2                    Horizontal split")
        print("  1 2 / 3                Row split: [1|2] / [3]")
        print("  1 - 2 / 3              Column split: [1] | [2/3]")
        print("  1:w30 - 2:h40 / 3      Width/height: 30% col, 40% row")
        print("  1:w60h40               Combined width+height")
        print("  1 2 /70 3              Row height: top 70%")
        print("  _                      Empty slot")
    }

}
