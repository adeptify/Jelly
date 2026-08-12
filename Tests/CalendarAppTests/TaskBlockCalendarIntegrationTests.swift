import AppKit
import CalendarDomain
import Foundation
import SwiftUI
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

    @Test func unlinkFromBlockPreservesBothObjects() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let blockID = BlockID()
        var note = Note.empty(id: NoteID(), categoryID: calendar.uncategorizedID, now: .distantPast)
        note.document = .init(blocks: [try .task(id: blockID, text: "保留两端")])
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let item = try CalendarItem(
            id: UUID(), kind: .task, title: "保留两端", categoryID: calendar.uncategorizedID,
            schedule: try CalendarSchedule(
                startDate: CalendarDate(year: 2026, month: 8, day: 17)!,
                endDate: CalendarDate(year: 2026, month: 8, day: 17)!,
                startTime: nil,
                endTime: nil
            ),
            completedAt: nil, createdAt: .distantPast, updatedAt: .distantPast
        )
        _ = try await store.sendWorkspace(
            .scheduleTaskBlock(.init(noteID: note.id, blockID: blockID, item: item))
        )

        let outcome = try await TaskBlockCalendarIntegration.unlinkFromBlock(
            store: store,
            noteID: note.id,
            blockID: blockID
        )

        #expect({ if case .committed = outcome { true } else { false } }())
        #expect(store.state.taskBlockLinks.isEmpty)
        #expect(store.state.notes[note.id]?.document.blocks.contains { $0.id == blockID } == true)
        #expect(store.calendarState.items[item.id] != nil)
    }

    @Test func schedulingDefaultsToTheLocalCivilDayInsteadOfABuildDate() {
        let instant = Date(timeIntervalSince1970: 1_754_998_200)
        let zone = TimeZone(secondsFromGMT: 8 * 60 * 60)!

        #expect(
            TaskBlockScheduleDefaults.day(now: instant, timeZone: zone)
                == CalendarDate.localDay(containing: instant, in: zone)
        )
    }

    @Test func scheduleFactoryCopiesTheExactTaskTitleAndCompletion() throws {
        let calendar = makeEmptyState()
        let blockID = BlockID()
        let completedAt = Date(timeIntervalSince1970: 1_754_998_100)
        let createdAt = Date(timeIntervalSince1970: 1_754_998_200)
        let itemID = UUID()
        var note = Note.empty(id: NoteID(), categoryID: calendar.uncategorizedID, now: .distantPast)
        note.document = .init(blocks: [try .task(
            id: blockID,
            text: "已经完成的复盘",
            completedAt: completedAt
        )])

        let item = try TaskBlockScheduleDefaults.makeItem(
            id: itemID,
            note: note,
            blockID: blockID,
            selectedDate: createdAt,
            timeZone: TimeZone(secondsFromGMT: 8 * 60 * 60)!,
            createdAt: createdAt
        )

        #expect(item.id == itemID)
        #expect(item.title == "已经完成的复盘")
        #expect(item.completedAt == completedAt)
        #expect(item.categoryID == note.categoryID)
    }

    @Test func linkedTaskUsesTheUnambiguousUnlinkLabel() async throws {
        _ = NSApplication.shared
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let noteID = NoteID()
        let blockID = BlockID()
        var note = Note.empty(id: noteID, categoryID: calendar.uncategorizedID, now: .distantPast)
        note.document = .init(blocks: [try .task(id: blockID, text: "写复盘")])
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let item = try CalendarItem(
            id: UUID(),
            kind: .task,
            title: "写复盘",
            categoryID: calendar.uncategorizedID,
            schedule: try CalendarSchedule(
                startDate: CalendarDate(year: 2026, month: 8, day: 12)!,
                endDate: CalendarDate(year: 2026, month: 8, day: 12)!,
                startTime: nil,
                endTime: nil
            ),
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        _ = try await store.sendWorkspace(.scheduleTaskBlock(.init(
            noteID: noteID,
            blockID: blockID,
            item: item
        )))

        let host = NSHostingView(rootView: TaskBlockCalendarBadge(
            store: store,
            noteID: noteID,
            blockID: blockID,
            onSchedule: {},
            onUnlink: {},
            onOpenItem: { _ in },
            onToggleCompletion: {}
        ))
        host.frame = .init(x: 0, y: 0, width: 420, height: 80)
        host.layoutSubtreeIfNeeded()

        let hasNamedButton = taskBlockDescendants(of: host, as: NSButton.self).contains {
            $0.title == "解除任务联动" || $0.accessibilityLabel() == "解除任务联动"
        }
        let hasVisibleLabel = taskBlockDescendants(of: host, as: NSTextField.self).contains {
            $0.stringValue == "解除任务联动" || $0.accessibilityLabel() == "解除任务联动"
        }
        #expect(hasNamedButton || hasVisibleLabel)
    }
}

@MainActor
private func taskBlockDescendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
    var result = (view as? T).map { [$0] } ?? []
    for child in view.subviews {
        result.append(contentsOf: taskBlockDescendants(of: child, as: type))
    }
    return result
}
