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
        case "a>":
            addWindowAdjacentTo(input: input, direction: .right, monitors: monitors, windows: windows)
        case "a<":
            addWindowAdjacentTo(input: input, direction: .left, monitors: monitors, windows: windows)
        case "e↓":
            addWindowAdjacentTo(input: input, direction: .below, monitors: monitors, windows: windows)
        case "e↑":
            addWindowAdjacentTo(input: input, direction: .above, monitors: monitors, windows: windows)
        default:
            break
        }
    }

    enum AddDirection { case left, right, above, below }

    private func addWindowAdjacentTo(input: String, direction: AddDirection, monitors: [MonitorInfo], windows: [WindowInfo]) {
        guard modeCurrentIndex >= 0 && modeCurrentIndex < modeWindowList.count else {
            print("  no focused window")
            return
        }
        let focused = modeWindowList[modeCurrentIndex]
        let focusedFrame = CGRect(origin: focused.position, size: focused.size)

        // Resolve the target (wid, .board, or _)
        let targetCgIds = state.resolveToWindowCgIds(input, windows: windows)

        // Calculate frames: split the focused window's frame
        let newFocusedFrame: CGRect
        let newTargetFrame: CGRect

        switch direction {
        case .right:
            let halfW = focusedFrame.width / 2
            newFocusedFrame = CGRect(x: focusedFrame.minX, y: focusedFrame.minY, width: halfW, height: focusedFrame.height)
            newTargetFrame = CGRect(x: focusedFrame.minX + halfW, y: focusedFrame.minY, width: focusedFrame.width - halfW, height: focusedFrame.height)
        case .left:
            let halfW = focusedFrame.width / 2
            newFocusedFrame = CGRect(x: focusedFrame.minX + halfW, y: focusedFrame.minY, width: focusedFrame.width - halfW, height: focusedFrame.height)
            newTargetFrame = CGRect(x: focusedFrame.minX, y: focusedFrame.minY, width: halfW, height: focusedFrame.height)
        case .below:
            let halfH = focusedFrame.height / 2
            newFocusedFrame = CGRect(x: focusedFrame.minX, y: focusedFrame.minY, width: focusedFrame.width, height: halfH)
            newTargetFrame = CGRect(x: focusedFrame.minX, y: focusedFrame.minY + halfH, width: focusedFrame.width, height: focusedFrame.height - halfH)
        case .above:
            let halfH = focusedFrame.height / 2
            newFocusedFrame = CGRect(x: focusedFrame.minX, y: focusedFrame.minY + halfH, width: focusedFrame.width, height: focusedFrame.height - halfH)
            newTargetFrame = CGRect(x: focusedFrame.minX, y: focusedFrame.minY, width: focusedFrame.width, height: halfH)
        }

        // Resize focused window
        moveWindow(focused.windowElement, to: newFocusedFrame)

        // Place target window(s)
        if input == "_" {
            print("  empty slot at \(direction)")
        } else if targetCgIds.count == 1, let w = state.resolveByCgId(targetCgIds[0], in: windows) {
            moveWindow(w.windowElement, to: newTargetFrame)
            raiseWindow(w.windowElement)
            print("  added wid \(w.wid) \(w.appName) to \(direction)")
        } else if targetCgIds.count > 1 {
            // Multiple windows: sub-tile in the target frame
            let isHorizontal = (direction == .left || direction == .right)
            for (i, cgId) in targetCgIds.enumerated() {
                guard let w = state.resolveByCgId(cgId, in: windows) else { continue }
                let subFrame: CGRect
                if isHorizontal {
                    let h = newTargetFrame.height / CGFloat(targetCgIds.count)
                    subFrame = CGRect(x: newTargetFrame.minX, y: newTargetFrame.minY + h * CGFloat(i), width: newTargetFrame.width, height: h)
                } else {
                    let w2 = newTargetFrame.width / CGFloat(targetCgIds.count)
                    subFrame = CGRect(x: newTargetFrame.minX + w2 * CGFloat(i), y: newTargetFrame.minY, width: w2, height: newTargetFrame.height)
                }
                moveWindow(w.windowElement, to: subFrame)
                raiseWindow(w.windowElement)
            }
            print("  added \(targetCgIds.count) windows to \(direction)")
        } else {
            print("  '\(input)' not found")
        }
    }
}
