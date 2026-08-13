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
    @Test func productionEditorCheckboxPersistsOneSharedCompletionToLinkedCalendarItem() async throws {
        _ = NSApplication.shared
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let blockID = BlockID()
        var note = Note.empty(id: NoteID(), categoryID: calendar.uncategorizedID, now: .distantPast)
        note.document = .init(blocks: [try .task(id: blockID, text: "正文勾选后同步")])
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let day = CalendarDate(year: 2026, month: 8, day: 18)!
        let item = try CalendarItem(
            id: UUID(),
            kind: .task,
            title: "正文勾选后同步",
            categoryID: calendar.uncategorizedID,
            schedule: try .init(startDate: day, endDate: day, startTime: nil, endTime: nil),
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        _ = try await store.sendWorkspace(.scheduleTaskBlock(.init(
            noteID: note.id,
            blockID: blockID,
            item: item
        )))

        let editSessionID = UUID()
        let autosave = NoteAutosaveCoordinator(
            store: store,
            scheduler: ImmediateTaskBlockScheduler()
        )
        let persisted = try #require(store.state.notes[note.id])
        try autosave.beginSession(
            persisted,
            linkedTaskBlockLinks: Set(store.state.taskBlockLinks),
            editSessionID: editSessionID,
            activeHostToken: UUID()
        )
        var finalizer: NoteNativeInputFinalizer?
        let host = NSHostingView(rootView: NoteEditorView(
            identity: .init(noteID: note.id, editSessionID: editSessionID),
            note: persisted,
            focusRegistry: EditorFocusRegistry(),
            autosave: autosave,
            store: store,
            categories: Array(calendar.categories.values),
            onDocumentCommitted: { _ in },
            onTitleCommitted: { _ in },
            onCategoryChanged: { _ in },
            onRequestMarkdownImport: {},
            onRequestMarkdownExport: {},
            sessionSink: { _ in },
            nativeFinalizerHook: Binding(get: { finalizer }, set: { finalizer = $0 })
        ))
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        #expect(await waitForTaskBlock {
            host.layoutSubtreeIfNeeded()
            return taskBlockDescendants(of: host, as: NSButton.self).contains {
                $0.accessibilityIdentifier() == "task-block-checkbox-\(blockID.rawValue.uuidString)"
            }
        })
        let checkbox = try #require(taskBlockDescendants(of: host, as: NSButton.self).first {
            $0.accessibilityIdentifier() == "task-block-checkbox-\(blockID.rawValue.uuidString)"
        })

        checkbox.performClick(checkbox)

        #expect(await waitForTaskBlock {
            store.state.notes[note.id]?.document.blocks.first(where: { $0.id == blockID })?
                .taskState?.completedAt != nil
        })
        let blockCompletion = try #require(
            store.state.notes[note.id]?.document.blocks.first(where: { $0.id == blockID })?
                .taskState?.completedAt
        )
        #expect(store.calendarState.items[item.id]?.completedAt == blockCompletion)
        window.orderOut(nil)
    }

    @Test func schedulingImmediatelyAfterConvertingToTaskFlushesTheLiveDraftFirst() async throws {
        _ = NSApplication.shared
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let blockID = BlockID()
        var note = Note.empty(id: NoteID(), categoryID: calendar.uncategorizedID, now: .distantPast)
        note.document = .init(blocks: [.init(
            id: blockID,
            kind: .paragraph,
            inlineContent: .plain("马上安排"),
            taskState: nil,
            indentLevel: 0
        )])
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let persisted = try #require(store.state.notes[note.id])
        let autosave = NoteAutosaveCoordinator(
            store: store,
            scheduler: SuspendedTaskBlockScheduler()
        )
        let editSessionID = UUID()
        try autosave.beginSession(
            persisted,
            linkedTaskBlockLinks: [],
            editSessionID: editSessionID,
            activeHostToken: UUID()
        )
        let liveDocument = BlockDocument(blocks: [try .task(id: blockID, text: "马上安排")])
        _ = try autosave.update(document: liveDocument)
        var didSchedule = false
        let host = NSHostingView(rootView: TaskBlockScheduleSheet(
            store: store,
            noteID: note.id,
            blockID: blockID,
            now: .distantPast,
            prepareForMutation: {
                switch await autosave.flushLatest() {
                case .clean, .persisted: true
                case .protectedOnly, .unsafeLatestUnprotected: false
                }
            },
            onCancel: {},
            onScheduled: { didSchedule = true }
        ))
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
        }
        host.layoutSubtreeIfNeeded()
        #expect(store.state.notes[note.id]?.document.blocks.first?.kind == .paragraph)
        let returnKey = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))
        #expect(window.performKeyEquivalent(with: returnKey))

        #expect(await waitForTaskBlock {
            store.state.taskBlockLinks.contains { $0.noteID == note.id && $0.blockID == blockID }
        })
        #expect(await waitForTaskBlock { didSchedule })
        #expect(autosave.statusMessage == nil)
    }

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
            onOpenItem: { _ in }
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
private final class ImmediateTaskBlockScheduler: NoteAutosaveScheduling {
    func sleep(milliseconds: UInt64) async throws {}
}

@MainActor
private final class SuspendedTaskBlockScheduler: NoteAutosaveScheduling {
    func sleep(milliseconds: UInt64) async throws {
        try await Task.sleep(for: .seconds(30))
    }
}

@MainActor
private func waitForTaskBlock(
    timeout: Duration = .seconds(1),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

@MainActor
private func taskBlockDescendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
    var result = (view as? T).map { [$0] } ?? []
    for child in view.subviews {
        result.append(contentsOf: taskBlockDescendants(of: child, as: type))
    }
    return result
}
