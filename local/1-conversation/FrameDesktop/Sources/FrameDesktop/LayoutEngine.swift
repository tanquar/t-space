import Foundation

// MARK: - Resolve slots to absolute coordinates

func resolveSlots(
    workspace: WorkspaceConfig,
    placement: PlacementConfig,
    monitorFrame: CGRect,
    boardIndex: Int = 0
) -> [ResolvedSlot] {
    guard boardIndex < workspace.boards.count else { return [] }

    // Workspace rect within monitor
    let wsLeft = parsePercent(placement.left) ?? 0
    let wsTop = parsePercent(placement.top) ?? 0
    let wsWidth = parsePercent(placement.width) ?? 1
    let wsHeight = parsePercent(placement.height) ?? 1

    let wsRect = CGRect(
        x: monitorFrame.origin.x + monitorFrame.width * wsLeft,
        y: monitorFrame.origin.y + monitorFrame.height * wsTop,
        width: monitorFrame.width * wsWidth,
        height: monitorFrame.height * wsHeight
    )

    let board = workspace.boards[boardIndex]

    return board.slots.map { slot in
        let slotLeft = parsePercent(slot.left) ?? 0
        let slotTop = parsePercent(slot.top) ?? 0
        let slotWidth = parsePercent(slot.width) ?? 1
        let slotHeight = parsePercent(slot.height) ?? 1

        let frame = CGRect(
            x: wsRect.origin.x + wsRect.width * slotLeft,
            y: wsRect.origin.y + wsRect.height * slotTop,
            width: wsRect.width * slotWidth,
            height: wsRect.height * slotHeight
        )

        return ResolvedSlot(
            appId: slot.appId,
            titleMatch: slot.titleMatch,
            frame: frame
        )
    }
}

// MARK: - Match windows to slots

struct SlotAssignment {
    let slot: ResolvedSlot
    let window: WindowInfo
}

func matchWindowsToSlots(windows: [WindowInfo], slots: [ResolvedSlot]) -> [SlotAssignment] {
    var assignments: [SlotAssignment] = []
    var usedWindows: Set<Int> = []  // indices of matched windows

    for slot in slots {
        guard let appId = slot.appId else { continue }

        for (i, window) in windows.enumerated() {
            if usedWindows.contains(i) { continue }

            // Match app ID
            guard window.appId == appId else { continue }

            // Match title if specified
            if let titleMatch = slot.titleMatch, !titleMatch.isEmpty {
                guard window.title.localizedCaseInsensitiveContains(titleMatch) else {
                    continue
                }
            }

            assignments.append(SlotAssignment(slot: slot, window: window))
            usedWindows.insert(i)
            break  // one window per slot for now
        }
    }

    return assignments
}
