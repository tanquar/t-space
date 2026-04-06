import Foundation
import CoreGraphics

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

let defaultBindings: [KeyBinding] = [
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
func lookupCommand(keycode: Int64, shift: Bool) -> Command? {
    defaultBindings.first { $0.keycode == keycode && $0.shift == shift }?.command
}
