import Foundation
import Testing
import Combine
import CalendarPersistence
import WorkspaceDomain
@testable import CalendarApp

@Suite("DraftJournalCoordinatorTests")
@MainActor
struct DraftJournalCoordinatorTests {
    @Test func journalEntryIsBuiltBeforeQueueingWithTheCapturedClock() throws {
        let note = Note.empty(id: NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000006021")!), categoryID: UUID(), now: .distantPast)
        let entry = try DraftJournalCoordinator.entry(
            submission: submission(for: note), workspaceRevision: 9,
            clock: { Date(timeIntervalSince1970: 42) }
        )
        #expect(entry.updatedAt == Date(timeIntervalSince1970: 42))
        #expect(entry.noteID == note.id)
        #expect(entry.draftGeneration == 3)
    }

    @Test func focusedButUnavailableEditorConsumesWorkspaceUndoFallback() {
        let registry = EditorFocusRegistry()
        let owner = UUID()
        let manager = UndoManager()
        registry.register(manager, ownerID: owner)
        #expect(registry.routeUndo() == .focusedUnavailable)
        registry.clear(ownerID: UUID())
        #expect(registry.routeRedo() == .focusedUnavailable)
        registry.clear(ownerID: owner)
        #expect(registry.routeUndo() == .noFocusedOwner)
    }

    @Test func releasedFocusedManagerReturnsToWorkspaceFallback() {
        let registry = EditorFocusRegistry()
        var manager: UndoManager? = UndoManager()
        registry.register(manager!, ownerID: UUID())
        manager = nil
        #expect(registry.routeUndo() == .noFocusedOwner)
    }

    @Test func staleBlurFromPreviousOwnerCannotClearTheNewFocusedEditor() {
        let registry = EditorFocusRegistry()
        let firstOwner = UUID()
        let secondOwner = UUID()
        let firstManager = UndoManager()
        let secondManager = UndoManager()
        registry.register(firstManager, ownerID: firstOwner)
        registry.register(secondManager, ownerID: secondOwner)

        registry.clear(ownerID: firstOwner)

        #expect(registry.routeUndo() == .focusedUnavailable)
        registry.clear(ownerID: secondOwner)
        #expect(registry.routeRedo() == .noFocusedOwner)
    }

    @Test func focusedEditorOwnsUndoAndRedoAvailabilityUntilItIsCleared() {
        let registry = EditorFocusRegistry()
        let owner = UUID()
        let manager = UndoManager()
        let target = FocusUndoTarget()
        target.manager = manager
        registry.register(manager, ownerID: owner)
        manager.registerUndo(withTarget: target) { $0.performUndo() }

        #expect(registry.canUndo)
        #expect(registry.canRedo == false)
        #expect(registry.routeUndo() == .focusedPerformed)
        #expect(target.count == 1)
        #expect(registry.canUndo == false)
        #expect(registry.canRedo)
        #expect(registry.routeRedo() == .focusedPerformed)
        #expect(target.count == 2)

        registry.clear(ownerID: owner)
        #expect(registry.canUndo == false)
        #expect(registry.canRedo == false)
    }

    @Test func focusAvailabilityPublishesForRegisterUndoRedoAndClear() async {
        let registry = EditorFocusRegistry()
        let manager = UndoManager()
        let target = FocusUndoTarget()
        target.manager = manager
        let owner = UUID()
        var observedAvailability: [(Bool, Bool)] = []
        let observation = registry.availabilityPublisher.sink { availability in
            observedAvailability.append(availability)
        }
        defer { observation.cancel() }

        registry.register(manager, ownerID: owner)
        manager.registerUndo(withTarget: target) { $0.performUndo() }
        NotificationCenter.default.post(name: .NSUndoManagerCheckpoint, object: manager)
        await Task.yield()
        _ = registry.routeUndo()
        await Task.yield()
        registry.clear(ownerID: owner)

        #expect(observedAvailability.contains { $0.0 && !$0.1 })
        #expect(observedAvailability.contains { !$0.0 && $0.1 })
        #expect(observedAvailability.last.map { $0 == (false, false) } == true)
    }

    @Test func focusAvailabilityAlsoSendsStandardObservableObjectChanges() async {
        let registry = EditorFocusRegistry()
        let manager = UndoManager()
        let target = FocusUndoTarget()
        target.manager = manager
        let owner = UUID()
        var changeCount = 0
        let observation = registry.objectWillChange.sink { _ in changeCount += 1 }
        defer { observation.cancel() }

        registry.register(manager, ownerID: owner)
        manager.registerUndo(withTarget: target) { $0.performUndo() }
        NotificationCenter.default.post(name: .NSUndoManagerCheckpoint, object: manager)
        await Task.yield()
        _ = registry.routeUndo()
        await Task.yield()
        _ = registry.routeRedo()
        await Task.yield()
        registry.clear(ownerID: owner)
        var releasedManager: UndoManager? = UndoManager()
        registry.register(releasedManager!, ownerID: UUID())
        releasedManager = nil
        #expect(registry.routeUndo() == .noFocusedOwner)

        #expect(changeCount >= 6)
    }

    @Test func boundReceiptIsRecordedThenClearedForItsExactIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-journal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = Note.empty(id: NoteID(UUID()), categoryID: UUID(), now: .distantPast)
        let submission = submission(for: note)
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        let entry = try DraftJournalCoordinator.entry(submission: submission, workspaceRevision: 0, clock: { .distantPast })
        try await journal.persist(entry)
        var persisted = note
        persisted.revision = 1
        let receipt = PersistedDraftReceipt(
            noteID: note.id, editSessionID: .editor(submission.editSessionID), draftGeneration: submission.draftGeneration,
            noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(persisted), persistedNoteRevision: 1
        )
        #expect(try await journal.rebaseAndBind(expected: .init(identity: .init(noteID: note.id, editSessionID: receipt.editSessionID), draftGeneration: 3), finalCandidateNote: persisted, receipt: receipt) == .bound)

        #expect(await DraftJournalCoordinator.recordAndClear(receipt, journal: journal) == .clean)
        #expect(try await journal.current()?.records.isEmpty == true)
    }

    @Test func recordFailureReturnsTypedCleanupWithoutClearingTheBoundEntry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jelly-6b-journal-fail-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = SwitchableJournalWriter()
        let note = Note.empty(id: NoteID(UUID()), categoryID: UUID(), now: .distantPast)
        let submission = submission(for: note)
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"), writer: writer)
        try await journal.persist(try DraftJournalCoordinator.entry(submission: submission, workspaceRevision: 0, clock: { .distantPast }))
        var persisted = note; persisted.revision = 1
        let receipt = PersistedDraftReceipt(noteID: note.id, editSessionID: .editor(submission.editSessionID), draftGeneration: 3, noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(persisted), persistedNoteRevision: 1)
        _ = try await journal.rebaseAndBind(expected: .init(identity: .init(noteID: note.id, editSessionID: receipt.editSessionID), draftGeneration: 3), finalCandidateNote: persisted, receipt: receipt)
        writer.shouldFail = true

        #expect(await DraftJournalCoordinator.recordAndClear(receipt, journal: journal) == .cleanupPending(identity: .init(noteID: note.id, editSessionID: receipt.editSessionID), step: .record))
        #expect(try await journal.current()?.records.first?.pendingReceipt == receipt)
    }

    private func submission(for note: Note) -> NoteDraftSubmission {
        NoteDraftSubmission(
            noteID: note.id, editSessionID: UUID(uuidString: "00000000-0000-0000-0000-000000006022")!,
            baseNoteRevision: note.revision,
            baseNoteSnapshotChecksum: (try? WorkspaceChecksum.noteSnapshotChecksum(note)) ?? "",
            baseSnapshot: note, baseLinkedTaskBlockLinks: [], draftGeneration: 3,
            snapshot: note, noteSnapshotChecksum: (try? WorkspaceChecksum.noteSnapshotChecksum(note)) ?? "",
            modifiedFields: [], linkedBlockDeletionDispositions: [:]
        )
    }
}

@MainActor
private final class FocusUndoTarget: NSObject {
    var count = 0
    weak var manager: UndoManager?

    func performUndo() {
        count += 1
        manager?.registerUndo(withTarget: self) { $0.performRedo() }
    }

    func performRedo() {
        count += 1
        manager?.registerUndo(withTarget: self) { $0.performUndo() }
    }
}

private final class SwitchableJournalWriter: AtomicFileWriting, @unchecked Sendable {
    var shouldFail = false
    func replaceAtomically(data: Data, at destination: URL) throws {
        if shouldFail { throw WorkspacePersistenceError.atomicWriteFailed }
        try FoundationAtomicFileWriter().replaceAtomically(data: data, at: destination)
    }
}
