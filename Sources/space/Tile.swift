import Foundation
import CoreGraphics

// MARK: - Data Structures

/// A single item in a tile layout
struct TileItem {
    let ref: String          // wid, ".board", or "_"
    let widthPercent: Int?   // :wN → width percent (item width within row, or column width)
    let heightPercent: Int?  // :hN → height percent (row height within column)
}

/// A row within a column (items laid out horizontally)
struct TileRow {
    let items: [TileItem]
    let heightPercent: Int?  // /N on the preceding separator
}

/// A column (rows laid out vertically)
struct TileColumn {
    let rows: [TileRow]
    let widthPercent: Int?   // from first item's :wN or -=N
}

/// Full tile specification
struct TileSpec {
    let columns: [TileColumn]
    let boardName: String?
    let monitorId: Int?
    let isComposite: Bool
    let childBoardNames: [String]
}

// MARK: - Parsing

/// Parse tile/show args into a TileSpec.
///
/// Precedence: `-` (column separator) < `/` (row separator) < items
///
/// Examples:
///   1 2                → one column, one row: [1|2]
///   1 2 / 3            → one column, two rows: [1|2] / [3]
///   1 2 /70 3          → one column: [1|2](70%) / [3](30%)
///   1 - 2 / 3 4        → two columns: [1] | [2 / [3|4]]
///   1:w30 - 2 / 3 4    → two columns: [1](w30%) | [2 / [3|4]](w70%)
///   1 - 2:h40 / 3      → two columns: [1] | [2(h40%) / 3(h60%)]
///
/// Special args:
///   @N    → monitor
///   .name → board name (single, without =)
///   =     → composite board syntax
///   _     → empty slot
func parseTileArgs(_ args: [String]) -> TileSpec? {
    // Check for = syntax (composite board)
    if let eqIdx = args.firstIndex(of: "=") {
        return parseComposite(args: args, eqIdx: eqIdx)
    }

    var boardName: String?
    var monitorId: Int?
    var dotCount = 0
    var atCount = 0

    // First pass: extract @monitor and .board, collect layout tokens
    var layoutTokens: [String] = []
    for arg in args {
        if arg.hasPrefix("@") {
            atCount += 1
            if atCount > 1 { print("Error: multiple @ not allowed"); return nil }
            monitorId = Int(arg.dropFirst())
        } else if arg.hasPrefix(".") && arg != "." {
            dotCount += 1
            if dotCount > 1 { print("Error: multiple . without = not allowed"); return nil }
            boardName = String(arg.dropFirst())
        } else {
            layoutTokens.append(arg)
        }
    }

    guard let columns = parseLayout(layoutTokens) else { return nil }

    return TileSpec(columns: columns, boardName: boardName, monitorId: monitorId,
                    isComposite: false, childBoardNames: [])
}

/// Parse layout tokens into columns.
/// Split by `-` first (columns), then by `/` (rows within each column).
private func parseLayout(_ tokens: [String]) -> [TileColumn]? {
    if tokens.isEmpty { return nil }

    // Split tokens by `-` into column groups
    var columnGroups: [[String]] = [[]]
    var columnWidths: [Int?] = [nil]

    for token in tokens {
        if token == "-" {
            columnGroups.append([])
            columnWidths.append(nil)
        } else if token.hasPrefix("-=") || token.hasPrefix("-w") {
            // -=30 or -w30: column separator with width
            let numStr = String(token.dropFirst(2))
            columnGroups.append([])
            columnWidths.append(Int(numStr))
        } else {
            columnGroups[columnGroups.count - 1].append(token)
        }
    }

    // Parse each column group into rows
    var columns: [TileColumn] = []
    for (i, group) in columnGroups.enumerated() {
        if group.isEmpty { continue }

        let rows = parseRows(group)
        if rows.isEmpty { continue }

        // Column width: from -=N, or from first item's :wN
        var colWidth = columnWidths[i]
        if colWidth == nil {
            // Check if the first item in the first row has a :wN
            if let firstItem = rows.first?.items.first, let w = firstItem.widthPercent {
                colWidth = w
            }
        }

        columns.append(TileColumn(rows: rows, widthPercent: colWidth))
    }

    return columns.isEmpty ? nil : columns
}

/// Parse tokens within a column into rows (split by `/` or `/N`).
private func parseRows(_ tokens: [String]) -> [TileRow] {
    var rows: [TileRow] = []
    var currentItems: [TileItem] = []
    var nextRowHeight: Int?

    for token in tokens {
        if token == "/" {
            if !currentItems.isEmpty {
                rows.append(TileRow(items: currentItems, heightPercent: nextRowHeight))
                currentItems = []
                nextRowHeight = nil
            }
            continue
        }

        if token.hasPrefix("/"), let h = Int(token.dropFirst()) {
            // /70 → flush current row with this height, or set height for next row if no items yet
            if !currentItems.isEmpty {
                rows.append(TileRow(items: currentItems, heightPercent: h))
                currentItems = []
                nextRowHeight = nil
            } else {
                nextRowHeight = h
            }
            continue
        }

        currentItems.append(parseItem(token))
    }

    if !currentItems.isEmpty {
        rows.append(TileRow(items: currentItems, heightPercent: nextRowHeight))
    }

    return rows
}

/// Parse a single item token: `ref`, `ref:wN`, `ref:hN`, `ref:wNhM`, `ref:N`
private func parseItem(_ token: String) -> TileItem {
    let parts = token.split(separator: ":", maxSplits: 1)
    let ref = String(parts[0])

    if parts.count > 1 {
        let modifier = String(parts[1])
        var width: Int?
        var height: Int?

        // Parse combined modifiers: w60h40, h40w60, w60, h40, or bare number
        var remaining = modifier[...]
        while !remaining.isEmpty {
            if remaining.hasPrefix("w") {
                remaining = remaining.dropFirst()
                let digits = remaining.prefix(while: \.isNumber)
                if let n = Int(digits) { width = n }
                remaining = remaining.dropFirst(digits.count)
            } else if remaining.hasPrefix("h") {
                remaining = remaining.dropFirst()
                let digits = remaining.prefix(while: \.isNumber)
                if let n = Int(digits) { height = n }
                remaining = remaining.dropFirst(digits.count)
            } else if let n = Int(modifier) {
                // bare :N → width percent (backwards compat)
                width = n
                break
            } else {
                break
            }
        }

        return TileItem(ref: ref, widthPercent: width, heightPercent: height)
    }

    return TileItem(ref: ref, widthPercent: nil, heightPercent: nil)
}

/// Parse composite: `tile .main = .dev .web @2`
private func parseComposite(args: [String], eqIdx: Int) -> TileSpec? {
    let left = Array(args[..<eqIdx])
    guard left.count == 1, left[0].hasPrefix(".") else {
        print("Error: left of = must be a single .name")
        return nil
    }
    let boardName = String(left[0].dropFirst())

    let right = Array(args[(eqIdx + 1)...])
    var layoutTokens: [String] = []
    var monitorId: Int?
    var atCount = 0
    var childBoards: [String] = []

    for arg in right {
        if arg.hasPrefix("@") {
            atCount += 1
            if atCount > 1 { print("Error: multiple @ not allowed"); return nil }
            monitorId = Int(arg.dropFirst())
        } else {
            if arg.hasPrefix(".") { childBoards.append(String(arg.dropFirst())) }
            layoutTokens.append(arg)
        }
    }

    guard let columns = parseLayout(layoutTokens) else { return nil }

    return TileSpec(columns: columns, boardName: boardName, monitorId: monitorId,
                    isComposite: true, childBoardNames: childBoards)
}

// MARK: - Frame Resolution

/// Calculate absolute frames for each ref in a tile spec.
func resolveTileFrames(spec: TileSpec, within bounds: CGRect) -> [(String, CGRect)] {
    // Distribute column widths
    let colWidths = distributePixels(
        total: Int(bounds.width),
        percents: spec.columns.map(\.widthPercent)
    )

    var result: [(String, CGRect)] = []
    var xOffset: CGFloat = 0

    for (colIndex, column) in spec.columns.enumerated() {
        let colWidth = CGFloat(colWidths[colIndex])

        // Distribute row heights within this column
        // Use item's heightPercent if the row doesn't have one
        let rowPercents: [Int?] = column.rows.map { row in
            if let h = row.heightPercent { return h }
            // Single-item row: use the item's :hN if present
            if row.items.count == 1, let h = row.items[0].heightPercent { return h }
            return nil
        }
        let rowHeights = distributePixels(
            total: Int(bounds.height),
            percents: rowPercents
        )

        var yOffset: CGFloat = 0

        for (rowIndex, row) in column.rows.enumerated() {
            let rowHeight = CGFloat(rowHeights[rowIndex])

            // Distribute item widths within this row
            let itemWidths = distributePixels(
                total: Int(colWidth),
                percents: row.items.map(\.widthPercent)
            )

            var itemXOffset: CGFloat = 0

            for (itemIndex, item) in row.items.enumerated() {
                let itemWidth = CGFloat(itemWidths[itemIndex])

                let frame = CGRect(
                    x: bounds.origin.x + xOffset + itemXOffset,
                    y: bounds.origin.y + yOffset,
                    width: itemWidth,
                    height: rowHeight
                )
                result.append((item.ref, frame))
                itemXOffset += itemWidth
            }

            yOffset += rowHeight
        }

        xOffset += colWidth
    }

    return result
}

/// Distribute total pixels among items, giving remainder to the last item.
private func distributePixels(total: Int, percents: [Int?]) -> [Int] {
    let specifiedSum = percents.compactMap({ $0 }).reduce(0, +)
    let unspecifiedCount = percents.filter({ $0 == nil }).count
    let autoPercent = unspecifiedCount > 0 ? (100 - specifiedSum) / unspecifiedCount : 0

    var sizes = percents.map { pct -> Int in
        let p = pct ?? autoPercent
        return total * p / 100
    }

    let usedPixels = sizes.reduce(0, +)
    if !sizes.isEmpty {
        sizes[sizes.count - 1] += total - usedPixels
    }

    return sizes
}

// MARK: - Helpers

/// Resolve monitor from spec or default to main.
func resolveMonitor(spec: TileSpec, monitors: [MonitorInfo]) -> MonitorInfo? {
    if let mid = spec.monitorId, let m = monitors.first(where: { $0.id == mid }) {
        return m
    }
    return monitors.first(where: { $0.isMain }) ?? monitors.first
}

/// Place windows into frames. Returns CGWindowIDs of moved windows.
/// When `preferCgId` is true, numeric refs are resolved as cgWindowIds first (for definition replay).
func placeWindows(
    frames: [(String, CGRect)],
    state: SpaceState,
    windows: [WindowInfo],
    preferCgId: Bool = false
) -> [Int] {
    var movedCgIds: [Int] = []
    for (ref, frame) in frames {
        if ref == "_" { continue }

        let cgIds = state.resolveToWindowCgIds(ref, windows: windows, preferCgId: preferCgId)

        if cgIds.isEmpty {
            print("  \(ref): not found")
        } else if cgIds.count == 1 {
            if let w = state.resolveByCgId(cgIds[0], in: windows) {
                moveWindow(w.windowElement, to: frame)
                movedCgIds.append(w.cgWindowId)
                print("  \(w.wid) -> (\(Int(frame.origin.x)),\(Int(frame.origin.y))) \(Int(frame.width))x\(Int(frame.height))")
            }
        } else {
            // Board ref with multiple windows — sub-tile horizontally within this frame
            let subItems = cgIds.map { TileItem(ref: "\($0)", widthPercent: nil, heightPercent: nil) }
            let subSpec = TileSpec(
                columns: [TileColumn(rows: [TileRow(items: subItems, heightPercent: nil)], widthPercent: nil)],
                boardName: nil, monitorId: nil,
                isComposite: false, childBoardNames: []
            )
            let subFrames = resolveTileFrames(spec: subSpec, within: frame)
            for (subRef, subFrame) in subFrames {
                if let cgId = Int(subRef), let w = state.resolveByCgId(cgId, in: windows) {
                    moveWindow(w.windowElement, to: subFrame)
                    movedCgIds.append(w.cgWindowId)
                    print("  \(w.wid) -> (\(Int(subFrame.origin.x)),\(Int(subFrame.origin.y))) \(Int(subFrame.width))x\(Int(subFrame.height))")
                }
            }
        }
    }
    return movedCgIds
}

/// Build definition string from a TileSpec, converting wids to cgWindowIds for stability.
func buildDefinition(spec: TileSpec, state: SpaceState, windows: [WindowInfo]) -> String {
    spec.columns.map { column in
        column.rows.enumerated().map { (rowIndex, row) in
            let itemStr = row.items.map { item in
                var ref = item.ref
                if let wid = Int(ref), let w = state.resolveByWid(wid, in: windows) {
                    ref = "\(w.cgWindowId)"
                }
                var modifier = ""
                if let w = item.widthPercent { modifier += "w\(w)" }
                if let h = item.heightPercent { modifier += "h\(h)" }
                return modifier.isEmpty ? ref : "\(ref):\(modifier)"
            }.joined(separator: " ")

            // Preserve row height as /N
            if let h = row.heightPercent {
                if rowIndex == 0 {
                    // First row: append /N after items (before the / separator)
                    return "\(itemStr) /\(h)"
                } else {
                    // Subsequent rows: prepend /N
                    return "/\(h) \(itemStr)"
                }
            }
            return itemStr
        }.joined(separator: " / ")
    }.joined(separator: " - ")
}

/// Execute tile: position windows, hide others on the monitor. No focus change.
func executeTile(spec: TileSpec, state: SpaceState, windows: [WindowInfo], monitors: [MonitorInfo]) {
    guard let monitor = resolveMonitor(spec: spec, monitors: monitors) else {
        print("No monitors found.")
        return
    }

    let frames = resolveTileFrames(spec: spec, within: monitor.usableFrame)
    let movedCgIds = placeWindows(frames: frames, state: state, windows: windows)
    let movedSet = Set(movedCgIds)

    // Hide other windows on this monitor (managed + unmanaged)
    for window in windows {
        if movedSet.contains(window.cgWindowId) { continue }
        guard let wMon = monitorForWindow(window, monitors: monitors),
              wMon.id == monitor.id else { continue }
        state.recordHidden(window, monitors: monitors)
        hideWindow(window.windowElement, monitors: monitors)
    }
    hideAllExcept(movedSet, onMonitor: monitor, monitors: monitors)

    // Clear hidden state for windows that are now visible
    for cgId in movedCgIds {
        state.clearHidden(cgId)
    }

    // Save board if named
    if let boardName = spec.boardName {
        state.boards[boardName] = BoardLayout(
            cgWindowIds: movedCgIds,
            definition: buildDefinition(spec: spec, state: state, windows: windows),
            monitorId: monitor.id,
            lastFocusedCgId: movedCgIds.first,
            childBoards: spec.isComposite ? spec.childBoardNames : nil
        )
        state.save()
        print("Board .\(boardName) @\(monitor.id)")
    }

    print("\nMoved \(movedCgIds.count) windows")
}
