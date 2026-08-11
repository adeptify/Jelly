import Foundation
import WorkspaceDomain

/// Shared command helpers for Task Block ↔ CalendarItem completion and unlink.
@MainActor
enum TaskBlockCalendarIntegration {
    static func completeFromCalendar(
        store: WorkspaceStore,
        itemID: UUID,
        at date: Date
    ) async throws -> WorkspaceTransactionOutcome {
        try await store.sendWorkspace(
            .setTaskCompletion(.calendarItem(itemID), value: .complete(ifTransitioningAt: date)),
            undoLabel: "完成事项"
        )
    }

    static func completeFromBlock(
        store: WorkspaceStore,
        noteID: NoteID,
        blockID: BlockID,
        at date: Date
    ) async throws -> WorkspaceTransactionOutcome {
        try await store.sendWorkspace(
            .setTaskCompletion(
                .taskBlock(noteID: noteID, blockID: blockID),
                value: .complete(ifTransitioningAt: date)
            ),
            undoLabel: "完成待办"
        )
    }

    static func reopenFromCalendar(
        store: WorkspaceStore,
        itemID: UUID
    ) async throws -> WorkspaceTransactionOutcome {
        try await store.sendWorkspace(
            .setTaskCompletion(.calendarItem(itemID), value: .incomplete),
            undoLabel: "重开事项"
        )
    }

    static func reopenFromBlock(
        store: WorkspaceStore,
        noteID: NoteID,
        blockID: BlockID
    ) async throws -> WorkspaceTransactionOutcome {
        try await store.sendWorkspace(
            .setTaskCompletion(
                .taskBlock(noteID: noteID, blockID: blockID),
                value: .incomplete
            ),
            undoLabel: "重开待办"
        )
    }

    static func unlinkFromBlock(
        store: WorkspaceStore,
        noteID: NoteID,
        blockID: BlockID
    ) async throws -> WorkspaceTransactionOutcome {
        try await store.sendWorkspace(
            .unlinkTaskBlock(noteID: noteID, blockID: blockID),
            undoLabel: "取消待办日历关联"
        )
    }

    static func link(for store: WorkspaceStore, noteID: NoteID, blockID: BlockID) -> TaskBlockCalendarLink? {
        store.state.taskBlockLinks.first { $0.noteID == noteID && $0.blockID == blockID }
    }
}
