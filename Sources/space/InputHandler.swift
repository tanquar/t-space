import Foundation
import CoreGraphics

/// Handles input sub-mode: text accumulation and command execution.
extension SpaceDaemon {

    func startInput(_ prompt: String) {
        inputPrompt = prompt
        inputBuffer = ""
        print("  \(prompt)")
    }

    func handleInputKey(keycode: Int64, flags: CGEventFlags, event: CGEvent) -> Unmanaged<CGEvent>? {
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
            if let spec = parseTileArgs(input.components(separatedBy: " ")) {
                executeTile(spec: spec, state: state, windows: windows, monitors: monitors)
            }
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
}
