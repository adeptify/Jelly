import CalendarDomain
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("TaskBlockCalendarIntegrationTests")
@MainActor
struct TaskBlockCalendarIntegrationTests {
    @Test func scheduleTaskBlockCreatesNonRecurringItemAndSharedCompletion() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let blockID = BlockID()
        var note = Note.empty(id: NoteID(), categoryID: calendar.uncategorizedID, now: .distantPast)
        note.document = .init(blocks: [try .task(id: blockID, text: "写测试")])
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))

        let day = CalendarDate(year: 2026, month: 8, day: 15)!
        let item = try CalendarItem(
            id: UUID(),
            kind: .task,
            title: "写测试",
            categoryID: calendar.uncategorizedID,
            schedule: try CalendarSchedule(startDate: day, endDate: day, startTime: nil, endTime: nil),
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let outcome = try await store.sendWorkspace(
            .scheduleTaskBlock(.init(noteID: note.id, blockID: blockID, item: item))
        )
        #expect({ if case .committed = outcome { return true }; return false }())
        #expect(store.state.taskBlockLinks.contains(where: {
            $0.noteID == note.id && $0.blockID == blockID && $0.calendarItemID == item.id
        }))

        let completedAt = Date(timeIntervalSince1970: 1_754_200_000)
        _ = try await TaskBlockCalendarIntegration.completeFromCalendar(
            store: store, itemID: item.id, at: completedAt
        )
        #expect(store.calendarState.items[item.id]?.completedAt == completedAt)
        let block = try #require(store.state.notes[note.id]?.document.blocks.first { $0.id == blockID })
        #expect(block.taskState?.completedAt == completedAt)
    }

    @Test func completionFromBlockUsesExactInjectedTimestamp() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let blockID = BlockID()
        var note = Note.empty(id: NoteID(), categoryID: calendar.uncategorizedID, now: .distantPast)
        note.document = .init(blocks: [try .task(id: blockID, text: "双向完成")])
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let day = CalendarDate(year: 2026, month: 8, day: 16)!
        let item = try CalendarItem(
            id: UUID(), kind: .task, title: "双向完成", categoryID: calendar.uncategorizedID,
            schedule: try CalendarSchedule(startDate: day, endDate: day, startTime: nil, endTime: nil),
            completedAt: nil, createdAt: .distantPast, updatedAt: .distantPast
        )
        _ = try await store.sendWorkspace(
            .scheduleTaskBlock(.init(noteID: note.id, blockID: blockID, item: item))
        )
        let completedAt = Date(timeIntervalSince1970: 1_754_300_000)
        _ = try await TaskBlockCalendarIntegration.completeFromBlock(
            store: store, noteID: note.id, blockID: blockID, at: completedAt
        )
        #expect(store.calendarState.items[item.id]?.completedAt == completedAt)
        #expect(store.state.notes[note.id]?.document.blocks.first { $0.id == blockID }?.taskState?.completedAt == completedAt)
    }
}
