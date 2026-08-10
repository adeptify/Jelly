import CalendarDomain
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("CalendarNoteIntegrationTests")
@MainActor
struct CalendarNoteIntegrationTests {
    @Test func createPrimaryNoteLinksItemAndKeepsNoteBodyIndependent() async throws {
        let calendar = try makeStateWithOneItem()
        let item = try #require(calendar.items.values.first)
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let model = CalendarNoteIntegrationModel(target: .item(item.id), store: store)
        #expect(try await model.createPrimaryNote())
        let primary = try #require(model.primaryNote)
        #expect(store.state.notes[primary.id] != nil)
        #expect(store.calendarState.items[item.id]?.notes == item.notes)
    }

    @Test func addingExistingNoteToLegacyTextRequiresExplicitChoice() async throws {
        var calendar = makeEmptyState()
        var item = try makeItem(categoryID: calendar.uncategorizedID)
        item.notes = "旧随记正文"
        calendar.items[item.id] = item
        let note = Note.empty(id: NoteID(), categoryID: calendar.uncategorizedID, now: .distantPast)
        var workspace = WorkspaceState.empty(calendar: calendar)
        workspace.notes[note.id] = note
        let store = WorkspaceStore(
            initialState: workspace,
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        // Restore note into store via command because InMemory may reseed from calendar-only.
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let model = CalendarNoteIntegrationModel(target: .item(item.id), store: store)
        #expect(model.hasLegacyMarkdown)
        #expect(try await model.chooseExistingPrimary(note.id) == false)
        #expect(model.presentedSheet == .legacyNotesResolution(note.id))
        #expect(store.state.calendarNoteRelations.baselines[.item(item.id)]?.primaryNoteID == nil)
    }

    @Test func attachReferenceAndDetachPreserveBothObjects() async throws {
        let calendar = try makeStateWithOneItem()
        let item = try #require(calendar.items.values.first)
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let noteA = Note.empty(id: NoteID(), categoryID: calendar.uncategorizedID, now: .distantPast)
        let noteB = Note.empty(id: NoteID(), categoryID: calendar.uncategorizedID, now: .distantPast)
        _ = try await store.sendWorkspace(.createNote(.init(note: noteA)))
        _ = try await store.sendWorkspace(.createNote(.init(note: noteB)))
        let model = CalendarNoteIntegrationModel(target: .item(item.id), store: store)
        #expect(try await model.chooseExistingPrimary(noteA.id))
        #expect(try await model.attachReference(noteB.id))
        #expect(model.referenceNotes.map(\.id).contains(noteB.id))
        #expect(try await model.detach(noteB.id))
        #expect(store.state.notes[noteB.id] != nil)
        #expect(store.calendarState.items[item.id] != nil)
    }

    @Test func scheduleNoteOnCalendarCreatesNonRecurringPrimaryLink() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let note = Note.empty(id: NoteID(), categoryID: calendar.uncategorizedID, now: .distantPast)
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let day = CalendarDate(year: 2026, month: 8, day: 12)!
        let item = try CalendarItem(
            id: UUID(),
            kind: .task,
            title: "来自笔记",
            categoryID: calendar.uncategorizedID,
            schedule: try CalendarSchedule(startDate: day, endDate: day, startTime: nil, endTime: nil),
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let model = CalendarNoteIntegrationModel(target: .item(item.id), store: store)
        #expect(try await model.scheduleNoteOnCalendar(noteID: note.id, item: item))
        #expect(store.calendarState.items[item.id] != nil)
        #expect(store.state.calendarNoteRelations.baselines[.item(item.id)]?.primaryNoteID == note.id)
    }
}
