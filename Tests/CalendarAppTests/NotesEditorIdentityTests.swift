import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("NotesEditorIdentityTests")
struct NotesEditorIdentityTests {
    @Test func editorIdentityChangesOnlyWithNoteOrEditSession() {
        let noteID = NoteID()
        let sessionA = UUID()
        let sessionB = UUID()
        let first = NoteEditorIdentity(noteID: noteID, editSessionID: sessionA)
        let same = NoteEditorIdentity(noteID: noteID, editSessionID: sessionA)
        let reopened = NoteEditorIdentity(noteID: noteID, editSessionID: sessionB)
        let otherNote = NoteEditorIdentity(noteID: NoteID(), editSessionID: sessionA)
        #expect(first == same)
        #expect(first != reopened)
        #expect(first != otherNote)
    }

    @Test @MainActor
    func selectionFlushGateUsesPersistedEvidenceOnly() async throws {
        let calendar = makeEmptyState()
        let note = Note.empty(id: NoteID(), categoryID: calendar.uncategorizedID, now: Date(timeIntervalSince1970: 1))
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let autosave = NoteAutosaveCoordinator(store: store, scheduler: ImmediateNotesTestScheduler())
        try autosave.beginSession(
            note,
            linkedTaskBlockLinks: [],
            editSessionID: UUID(),
            activeHostToken: UUID()
        )
        _ = try autosave.update(title: "编辑中")
        let bridge = NoteCloseProtectionBridge(coordinator: autosave)
        let before = await bridge.decision(for: .selection)
        #expect(before == .keepOpen || before == .allow)
        let evidence = await autosave.flushLatest()
        if case .persisted = evidence {
            #expect(await bridge.decision(for: .selection) == .allow)
        }
    }
}

@MainActor
private final class ImmediateNotesTestScheduler: NoteAutosaveScheduling {
    func sleep(milliseconds: UInt64) async throws {}
}
