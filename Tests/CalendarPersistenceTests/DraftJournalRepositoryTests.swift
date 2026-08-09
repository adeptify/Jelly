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
}

extension WorkspacePersistenceFixtures {
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
}
