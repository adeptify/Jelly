import CalendarDomain
import Foundation
import Testing
@testable import CalendarPersistence
@testable import WorkspaceDomain

@Suite("DraftJournalRepositoryTests")
struct DraftJournalRepositoryTests {
    @Test func laterGenerationReceiptCannotOverwriteOrClearNewerJournalEntry() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let journal = DraftJournalRepository(fileURL: directory.file("draft-journal.json"))
        let generationFive = try WorkspacePersistenceFixtures.draftEntry(generation: 5)
        let generationSix = try WorkspacePersistenceFixtures.draftEntry(generation: 6)
        try await journal.persist(generationFive)
        try await journal.persist(generationSix)
        let staleReceipt = PersistedDraftReceipt(
            noteID: generationFive.noteID,
            draftGeneration: 5,
            noteSnapshotChecksum: generationFive.noteSnapshotChecksum,
            persistedNoteRevision: 9
        )

        try await journal.record(staleReceipt)
        try await journal.clear(ifMatching: staleReceipt)

        let record = try #require(try await journal.current())
        #expect(record.entry.draftGeneration == 6)
        #expect(record.savedReceipt == nil)
    }

    @Test func matchingReceiptIsDurableAndCanBeReadBackForRestartReconciliation() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("draft-journal.json")
        let entry = try WorkspacePersistenceFixtures.draftEntry(generation: 7)
        let receipt = PersistedDraftReceipt(
            noteID: entry.noteID,
            draftGeneration: entry.draftGeneration,
            noteSnapshotChecksum: entry.noteSnapshotChecksum,
            persistedNoteRevision: 7
        )
        let journal = DraftJournalRepository(fileURL: url)
        try await journal.persist(entry)
        try await journal.bindPending(receipt)
        try await journal.record(receipt)

        let reopened = DraftJournalRepository(fileURL: url)
        let record = try #require(try await reopened.current())
        #expect(record.entry == entry)
        #expect(record.savedReceipt == receipt)
    }

    @Test func corruptedJournalEnvelopeIsRejectedBeforeRecoveryComparison() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("draft-journal.json")
        try Data(#"{"entry":{},"savedReceipt":null,"recordChecksum":"wrong"}"#.utf8).write(to: url)

        await #expect(throws: WorkspacePersistenceError.invalidJournal) {
            _ = try await DraftJournalRepository(fileURL: url).current()
        }
    }

    @Test func receiptWithOnlyPersistedRevisionChangedCannotReplaceMatchingReceipt() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let entry = try WorkspacePersistenceFixtures.draftEntry(generation: 8)
        let correct = PersistedDraftReceipt(
            noteID: entry.noteID,
            draftGeneration: entry.draftGeneration,
            noteSnapshotChecksum: entry.noteSnapshotChecksum,
            persistedNoteRevision: 8
        )
        let wrongRevision = PersistedDraftReceipt(
            noteID: entry.noteID,
            draftGeneration: entry.draftGeneration,
            noteSnapshotChecksum: entry.noteSnapshotChecksum,
            persistedNoteRevision: 9
        )
        let journal = DraftJournalRepository(fileURL: directory.file("journal.json"))
        try await journal.persist(entry)
        try await journal.bindPending(correct)
        try await journal.record(correct)
        try await journal.record(wrongRevision)

        #expect(try await journal.current()?.savedReceipt == correct)
    }

    @Test func everyReceiptFieldMustMatchBeforeTheFirstReceiptBecomesDurable() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let entry = try WorkspacePersistenceFixtures.draftEntry(generation: 10)
        let invalidReceipts = [
            PersistedDraftReceipt(
                noteID: NoteID(),
                draftGeneration: entry.draftGeneration,
                noteSnapshotChecksum: entry.noteSnapshotChecksum,
                persistedNoteRevision: entry.noteSnapshot.revision
            ),
            PersistedDraftReceipt(
                noteID: entry.noteID,
                draftGeneration: entry.draftGeneration + 1,
                noteSnapshotChecksum: entry.noteSnapshotChecksum,
                persistedNoteRevision: entry.noteSnapshot.revision
            ),
            PersistedDraftReceipt(
                noteID: entry.noteID,
                draftGeneration: entry.draftGeneration,
                noteSnapshotChecksum: "wrong-checksum",
                persistedNoteRevision: entry.noteSnapshot.revision
            ),
            PersistedDraftReceipt(
                noteID: entry.noteID,
                draftGeneration: entry.draftGeneration,
                noteSnapshotChecksum: entry.noteSnapshotChecksum,
                persistedNoteRevision: entry.noteSnapshot.revision + 1
            )
        ]

        for (index, receipt) in invalidReceipts.enumerated() {
            let journal = DraftJournalRepository(fileURL: directory.file("journal-\(index).json"))
            try await journal.persist(entry)
            try await journal.record(receipt)
            #expect(try await journal.current()?.savedReceipt == nil)
        }
    }

    @Test func journalClearFailureLeavesDurableReceiptForRestartReconciliation() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let writer = WorkspacePersistenceFailOnceWriter()
        let url = directory.file("journal.json")
        let entry = try WorkspacePersistenceFixtures.draftEntry(generation: 9)
        let receipt = PersistedDraftReceipt(
            noteID: entry.noteID,
            draftGeneration: entry.draftGeneration,
            noteSnapshotChecksum: entry.noteSnapshotChecksum,
            persistedNoteRevision: 9
        )
        let journal = DraftJournalRepository(fileURL: url, writer: writer)
        try await journal.persist(entry)
        try await journal.bindPending(receipt)
        try await journal.record(receipt)
        writer.failNextWrite = true

        await #expect(throws: WorkspacePersistenceError.atomicWriteFailed) {
            try await journal.clear(ifMatching: receipt)
        }
        #expect(try await DraftJournalRepository(fileURL: url).current()?.savedReceipt == receipt)
    }

    @Test func unrelatedCalendarSavePreservesReceiptAndTitleOnlyDraftRejectsTheStaleReceipt() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let entry = try WorkspacePersistenceFixtures.draftEntry(generation: 11)
        let receipt = PersistedDraftReceipt(
            noteID: entry.noteID,
            draftGeneration: entry.draftGeneration,
            noteSnapshotChecksum: entry.noteSnapshotChecksum,
            persistedNoteRevision: entry.noteSnapshot.revision
        )
        let calendarJournalURL = directory.file("calendar-journal.json")
        let calendarJournal = DraftJournalRepository(fileURL: calendarJournalURL)
        try await calendarJournal.persist(entry)
        try await calendarJournal.bindPending(receipt)
        try await calendarJournal.record(receipt)

        let initial = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var calendarOnly = initial
        calendarOnly.revision = 2
        let unrelatedCategoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000599")!
        calendarOnly.calendar.categories[unrelatedCategoryID] = .init(
            id: unrelatedCategoryID,
            name: "不相关日历更新",
            colorHex: "#336699",
            sortIndex: 1,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let repository = JSONWorkspaceRepository(
            documentURL: directory.file("calendar-v1.json"),
            seed: { initial }
        )
        _ = try await repository.load()
        _ = try await repository.save(calendarOnly)
        #expect(try await DraftJournalRepository(fileURL: calendarJournalURL).current()?.savedReceipt == receipt)

        var changedNote = entry.noteSnapshot
        changedNote.title = "仅标题变化"
        changedNote.revision += 1
        let changedChecksum = try WorkspaceChecksum.noteSnapshotChecksum(changedNote)
        let unsigned = DraftJournalEntry(
            noteID: changedNote.id,
            baseWorkspaceRevision: entry.baseWorkspaceRevision,
            baseNoteRevision: entry.baseNoteRevision,
            draftGeneration: entry.draftGeneration,
            noteSnapshot: changedNote,
            updatedAt: entry.updatedAt,
            noteSnapshotChecksum: changedChecksum,
            journalChecksum: ""
        )
        let titleOnlyEntry = DraftJournalEntry(
            noteID: unsigned.noteID,
            baseWorkspaceRevision: unsigned.baseWorkspaceRevision,
            baseNoteRevision: unsigned.baseNoteRevision,
            draftGeneration: unsigned.draftGeneration,
            noteSnapshot: unsigned.noteSnapshot,
            updatedAt: unsigned.updatedAt,
            noteSnapshotChecksum: unsigned.noteSnapshotChecksum,
            journalChecksum: try DraftJournal.entryChecksum(for: unsigned)
        )
        let titleJournal = DraftJournalRepository(fileURL: directory.file("title-journal.json"))
        try await titleJournal.persist(entry)
        try await titleJournal.persist(titleOnlyEntry)
        try await titleJournal.record(receipt)

        let titleRecord = try #require(try await titleJournal.current())
        #expect(titleRecord.entry == titleOnlyEntry)
        #expect(titleRecord.savedReceipt == nil)
    }

    @Test func reducerAllocatedRevisionBindsTheExactPendingReceiptBeforeRecordAndClear() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let initial = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 3)
        let base = try #require(initial.notes.values.first)
        var submitted = base
        submitted.title = "由 reducer 分配 revision"
        let draftGeneration: UInt64 = 42
        let submission = NoteDraftSubmission(
            noteID: base.id,
            editSessionID: UUID(),
            baseNoteRevision: base.revision,
            baseNoteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(base),
            baseSnapshot: base,
            baseLinkedTaskBlockLinks: [],
            draftGeneration: draftGeneration,
            snapshot: submitted,
            noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(submitted),
            modifiedFields: [.title],
            linkedBlockDeletionDispositions: [:]
        )
        let reduction = try WorkspaceReducer.reduce(
            initial,
            command: .updateNote(submission),
            now: Date(timeIntervalSince1970: 10)
        )
        let candidate = try #require(reduction.change?.state)
        let candidateNote = try #require(candidate.notes[base.id])
        #expect(candidateNote.revision == 4)
        let entry = try WorkspacePersistenceFixtures.draftEntry(
            baseWorkspaceRevision: initial.revision,
            baseNoteRevision: base.revision,
            draftGeneration: draftGeneration,
            snapshot: submitted
        )
        let receipt = PersistedDraftReceipt(
            noteID: base.id,
            draftGeneration: draftGeneration,
            noteSnapshotChecksum: entry.noteSnapshotChecksum,
            persistedNoteRevision: candidateNote.revision
        )
        let journal = DraftJournalRepository(fileURL: directory.file("journal.json"))
        try await journal.persist(entry)
        for wrong in [
            PersistedDraftReceipt(noteID: NoteID(), draftGeneration: receipt.draftGeneration, noteSnapshotChecksum: receipt.noteSnapshotChecksum, persistedNoteRevision: receipt.persistedNoteRevision),
            PersistedDraftReceipt(noteID: receipt.noteID, draftGeneration: receipt.draftGeneration + 1, noteSnapshotChecksum: receipt.noteSnapshotChecksum, persistedNoteRevision: receipt.persistedNoteRevision),
            PersistedDraftReceipt(noteID: receipt.noteID, draftGeneration: receipt.draftGeneration, noteSnapshotChecksum: "wrong", persistedNoteRevision: receipt.persistedNoteRevision),
            PersistedDraftReceipt(noteID: receipt.noteID, draftGeneration: receipt.draftGeneration, noteSnapshotChecksum: receipt.noteSnapshotChecksum, persistedNoteRevision: entry.baseNoteRevision)
        ] {
            #expect(try await journal.bindPending(wrong) == false)
        }
        #expect(try await journal.bindPending(receipt) == true)

        let bound = try #require(try await journal.current())
        #expect(bound.pendingReceipt == receipt)
        #expect(bound.savedReceipt == nil)
        for wrong in [
            PersistedDraftReceipt(noteID: NoteID(), draftGeneration: receipt.draftGeneration, noteSnapshotChecksum: receipt.noteSnapshotChecksum, persistedNoteRevision: receipt.persistedNoteRevision),
            PersistedDraftReceipt(noteID: receipt.noteID, draftGeneration: receipt.draftGeneration + 1, noteSnapshotChecksum: receipt.noteSnapshotChecksum, persistedNoteRevision: receipt.persistedNoteRevision),
            PersistedDraftReceipt(noteID: receipt.noteID, draftGeneration: receipt.draftGeneration, noteSnapshotChecksum: "wrong", persistedNoteRevision: receipt.persistedNoteRevision),
            PersistedDraftReceipt(noteID: receipt.noteID, draftGeneration: receipt.draftGeneration, noteSnapshotChecksum: receipt.noteSnapshotChecksum, persistedNoteRevision: receipt.persistedNoteRevision + 1)
        ] {
            #expect(try await journal.record(wrong) == false)
            #expect(try await journal.current()?.savedReceipt == nil)
        }
        #expect(try await journal.record(receipt) == true)
        #expect(try await journal.current()?.pendingReceipt == nil)
        #expect(try await journal.current()?.savedReceipt == receipt)
        #expect(try await journal.clear(ifMatching: receipt) == true)
        #expect(try await journal.current() == nil)
    }

    @Test func reducerCurrentRevisionFiveCanBindAndRecordTheFinalRevisionSixReceipt() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let initial = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 5)
        let base = try #require(initial.notes.values.first)
        var submitted = base
        submitted.title = "revision six candidate"
        let submission = NoteDraftSubmission(
            noteID: base.id,
            editSessionID: UUID(),
            baseNoteRevision: base.revision,
            baseNoteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(base),
            baseSnapshot: base,
            baseLinkedTaskBlockLinks: [],
            draftGeneration: 43,
            snapshot: submitted,
            noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(submitted),
            modifiedFields: [.title],
            linkedBlockDeletionDispositions: [:]
        )
        let reduction = try WorkspaceReducer.reduce(
            initial,
            command: .updateNote(submission),
            now: Date(timeIntervalSince1970: 11)
        )
        let candidate = try #require(reduction.change?.state)
        let candidateNote = try #require(candidate.notes[base.id])
        #expect(candidateNote.revision == 6)
        let entry = try WorkspacePersistenceFixtures.draftEntry(
            baseWorkspaceRevision: initial.revision,
            baseNoteRevision: base.revision,
            draftGeneration: submission.draftGeneration,
            snapshot: submitted
        )
        let receipt = PersistedDraftReceipt(
            noteID: base.id,
            draftGeneration: submission.draftGeneration,
            noteSnapshotChecksum: entry.noteSnapshotChecksum,
            persistedNoteRevision: candidateNote.revision
        )
        let journal = DraftJournalRepository(fileURL: directory.file("journal.json"))
        try await journal.persist(entry)
        try await journal.bindPending(receipt)
        try await journal.record(receipt)

        #expect(try await journal.current()?.savedReceipt == receipt)
    }
}

final class WorkspacePersistenceFailOnceWriter: AtomicFileWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = false

    var failNextWrite: Bool {
        get { lock.withLock { shouldFail } }
        set { lock.withLock { shouldFail = newValue } }
    }

    func replaceAtomically(data: Data, at destination: URL) throws {
        let fails = lock.withLock {
            defer { shouldFail = false }
            return shouldFail
        }
        if fails { throw WorkspacePersistenceInjectedFailure.requested }
        try FoundationAtomicFileWriter().replaceAtomically(data: data, at: destination)
    }
}

extension WorkspacePersistenceFixtures {
    static func draftEntry(
        baseWorkspaceRevision: Int64,
        baseNoteRevision: Int64,
        draftGeneration: UInt64,
        snapshot: Note
    ) throws -> DraftJournalEntry {
        let checksum = try WorkspaceChecksum.noteSnapshotChecksum(snapshot)
        let unsigned = DraftJournalEntry(
            noteID: snapshot.id,
            baseWorkspaceRevision: baseWorkspaceRevision,
            baseNoteRevision: baseNoteRevision,
            draftGeneration: draftGeneration,
            noteSnapshot: snapshot,
            updatedAt: Date(timeIntervalSince1970: 0),
            noteSnapshotChecksum: checksum,
            journalChecksum: ""
        )
        return DraftJournalEntry(
            noteID: unsigned.noteID,
            baseWorkspaceRevision: unsigned.baseWorkspaceRevision,
            baseNoteRevision: unsigned.baseNoteRevision,
            draftGeneration: unsigned.draftGeneration,
            noteSnapshot: unsigned.noteSnapshot,
            updatedAt: unsigned.updatedAt,
            noteSnapshotChecksum: unsigned.noteSnapshotChecksum,
            journalChecksum: try DraftJournal.entryChecksum(for: unsigned)
        )
    }

    static func draftEntry(generation: UInt64) throws -> DraftJournalEntry {
        let note = try workspaceWithOneNote(revision: Int64(generation)).notes.values.first!
        let checksum = try WorkspaceChecksum.noteSnapshotChecksum(note)
        let unsigned = DraftJournalEntry(
            noteID: note.id,
            baseWorkspaceRevision: 0,
            baseNoteRevision: 0,
            draftGeneration: generation,
            noteSnapshot: note,
            updatedAt: Date(timeIntervalSince1970: 0),
            noteSnapshotChecksum: checksum,
            journalChecksum: ""
        )
        return DraftJournalEntry(
            noteID: unsigned.noteID,
            baseWorkspaceRevision: unsigned.baseWorkspaceRevision,
            baseNoteRevision: unsigned.baseNoteRevision,
            draftGeneration: unsigned.draftGeneration,
            noteSnapshot: unsigned.noteSnapshot,
            updatedAt: unsigned.updatedAt,
            noteSnapshotChecksum: unsigned.noteSnapshotChecksum,
            journalChecksum: try DraftJournal.entryChecksum(for: unsigned)
        )
    }

    static func multiMarkDraftEntry() throws -> DraftJournalEntry {
        let note = try workspaceWithMultiMarkNote().notes.values.first!
        let checksum = try WorkspaceChecksum.noteSnapshotChecksum(note)
        let unsigned = DraftJournalEntry(
            noteID: note.id,
            baseWorkspaceRevision: 1,
            baseNoteRevision: 1,
            draftGeneration: 10,
            noteSnapshot: note,
            updatedAt: Date(timeIntervalSince1970: 0),
            noteSnapshotChecksum: checksum,
            journalChecksum: ""
        )
        return DraftJournalEntry(
            noteID: unsigned.noteID,
            baseWorkspaceRevision: unsigned.baseWorkspaceRevision,
            baseNoteRevision: unsigned.baseNoteRevision,
            draftGeneration: unsigned.draftGeneration,
            noteSnapshot: unsigned.noteSnapshot,
            updatedAt: unsigned.updatedAt,
            noteSnapshotChecksum: unsigned.noteSnapshotChecksum,
            journalChecksum: try DraftJournal.entryChecksum(for: unsigned)
        )
    }
}
