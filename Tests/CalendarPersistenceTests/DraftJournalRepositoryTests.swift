import Foundation
import Testing
@testable import CalendarPersistence
@testable import WorkspaceDomain

@Suite("DraftJournalRepositoryTests")
struct DraftJournalRepositoryTests {
    @Test func recordsArePartitionedByNoteAndNamespacedSessionGeneration() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let state = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 4)
        let first = try #require(state.notes.values.first)
        let second = Note(
            id: NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000006d02")!),
            title: first.title,
            document: first.document,
            categoryID: first.categoryID,
            archivedAt: first.archivedAt,
            revision: first.revision,
            createdAt: first.createdAt,
            updatedAt: first.updatedAt
        )
        let editorID = UUID(uuidString: "00000000-0000-0000-0000-000000006d03")!
        let journal = DraftJournalRepository(fileURL: directory.file("draft-journal.json"))
        let firstEntry = try makeDraftEntry(
            note: first,
            session: .editor(editorID),
            generation: 6
        )
        let secondEntry = try makeDraftEntry(
            note: second,
            session: .editor(editorID),
            generation: 1
        )

        try await journal.persist(firstEntry)
        try await journal.persist(secondEntry)
        try await journal.persist(try makeDraftEntry(note: first, session: .editor(editorID), generation: 5))

        let envelope = try #require(try await journal.current())
        #expect(envelope.records.count == 2)
        #expect(envelope.records.first { $0.identity.noteID == first.id }?.entry.draftGeneration == 6)
        #expect(envelope.records.first { $0.identity.noteID == second.id }?.entry.draftGeneration == 1)
        #expect(envelope.records == DraftJournal.canonicalRecords(envelope.records))
    }

    @Test func sameNoteDifferentSessionUUIDBytesCannotCollideWithLegacyTask5() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let state = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 4)
        let note = try #require(state.notes.values.first)
        let uuid = UUID(uuidString: "00000000-0000-0000-0000-000000006d04")!
        let journal = DraftJournalRepository(fileURL: directory.file("draft-journal.json"))

        try await journal.persist(try makeDraftEntry(note: note, session: .legacyTask5, generation: 1))
        try await journal.persist(try makeDraftEntry(note: note, session: .editor(uuid), generation: 1))

        let records = try #require(try await journal.current()).records
        #expect(records.count == 2)
        #expect(Set(records.map(\.identity.editSessionID)) == Set([.legacyTask5, .editor(uuid)]))
    }

    @Test func rebaseBindRecordAndClearOnlyTouchTheExactIdentityAndGeneration() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let state = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 4)
        let base = try #require(state.notes.values.first)
        let session = DraftJournalSessionID.editor(UUID(uuidString: "00000000-0000-0000-0000-000000006d05")!)
        let journal = DraftJournalRepository(fileURL: directory.file("draft-journal.json"))
        let entry = try makeDraftEntry(note: base, session: session, generation: 3)
        try await journal.persist(entry)
        var final = base
        final.revision = 5
        final.title = "最终合并候选"
        let receipt = PersistedDraftReceipt(
            noteID: final.id,
            editSessionID: session,
            draftGeneration: 3,
            noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(final),
            persistedNoteRevision: 5
        )

        #expect(try await journal.rebaseAndBind(
            expected: .init(identity: .init(noteID: final.id, editSessionID: session), draftGeneration: 3),
            finalCandidateNote: final,
            receipt: receipt
        ) == .bound)
        #expect(try await journal.record(receipt))
        #expect(try await journal.clear(receipt))
        #expect(try await journal.current()?.records.isEmpty == true)
    }

    @Test func newerGenerationSupersedesWithoutOverwritingItOrSavingOlderBinding() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let state = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 4)
        let note = try #require(state.notes.values.first)
        let session = DraftJournalSessionID.editor(UUID())
        let journal = DraftJournalRepository(fileURL: directory.file("draft-journal.json"))
        try await journal.persist(try makeDraftEntry(note: note, session: session, generation: 4))
        var final = note
        final.revision = 5
        let receipt = PersistedDraftReceipt(
            noteID: note.id,
            editSessionID: session,
            draftGeneration: 3,
            noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(final),
            persistedNoteRevision: 5
        )

        #expect(try await journal.rebaseAndBind(
            expected: .init(identity: .init(noteID: note.id, editSessionID: session), draftGeneration: 3),
            finalCandidateNote: final,
            receipt: receipt
        ) == .supersededByNewerDraft)
        #expect(try await journal.current()?.records.first?.entry.draftGeneration == 4)
        #expect(try await journal.current()?.records.first?.pendingReceipt == nil)
    }

    @Test func validTask5LegacyPendingReceiptMigratesToTheLegacyNamespace() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let state = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 4)
        let note = try #require(state.notes.values.first)
        let entry = try makeLegacyEntry(note: note, generation: 2)
        let receipt = LegacyReceipt(
            noteID: note.id,
            draftGeneration: 2,
            noteSnapshotChecksum: entry.noteSnapshotChecksum,
            persistedNoteRevision: note.revision
        )
        let bytes = try legacyRecordData(entry: entry, pending: receipt, saved: nil)
        let url = directory.file("draft-journal.json")
        try bytes.write(to: url)

        let migrated = try #require(try await DraftJournalRepository(fileURL: url).current())
        let record = try #require(migrated.records.first)
        #expect(record.identity.editSessionID == .legacyTask5)
        #expect(record.pendingReceipt == PersistedDraftReceipt(
            noteID: note.id,
            editSessionID: .legacyTask5,
            draftGeneration: 2,
            noteSnapshotChecksum: entry.noteSnapshotChecksum,
            persistedNoteRevision: note.revision
        ))
        #expect(try Data(contentsOf: url) != bytes)
    }

    @Test func validTask5LegacySavedReceiptMigratesToTheSameLegacyNamespace() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let state = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 4)
        let note = try #require(state.notes.values.first)
        let entry = try makeLegacyEntry(note: note, generation: 2)
        let receipt = LegacyReceipt(
            noteID: note.id,
            draftGeneration: 2,
            noteSnapshotChecksum: entry.noteSnapshotChecksum,
            persistedNoteRevision: note.revision
        )
        let url = directory.file("draft-journal.json")
        try legacyRecordData(entry: entry, pending: nil, saved: receipt).write(to: url)

        let record = try #require(try await DraftJournalRepository(fileURL: url).current()?.records.first)
        #expect(record.identity.editSessionID == .legacyTask5)
        #expect(record.savedReceipt?.editSessionID == .legacyTask5)
    }

    @Test func legacyMigrationWriteFailurePreservesExactLegacyBytesForPendingAndSavedReceipt() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let state = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 4)
        let note = try #require(state.notes.values.first)
        let entry = try makeLegacyEntry(note: note, generation: 2)
        let receipt = LegacyReceipt(
            noteID: note.id,
            draftGeneration: 2,
            noteSnapshotChecksum: entry.noteSnapshotChecksum,
            persistedNoteRevision: note.revision
        )
        for (name, pending, saved) in [("pending", Optional(receipt), LegacyReceipt?.none), ("saved", LegacyReceipt?.none, Optional(receipt))] {
            let url = directory.file("\(name).json")
            let bytes = try legacyRecordData(entry: entry, pending: pending, saved: saved)
            try bytes.write(to: url)
            let journal = DraftJournalRepository(fileURL: url, writer: DraftJournalAlwaysFailingWriter())

            await #expect(throws: WorkspacePersistenceError.atomicWriteFailed) { _ = try await journal.current() }
            #expect(try Data(contentsOf: url) == bytes)
        }
    }

    @Test func malformedJournalIsInvalidRatherThanAbsent() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("draft-journal.json")
        try Data("not-a-journal".utf8).write(to: url)

        await #expect(throws: WorkspacePersistenceError.invalidJournal) {
            _ = try await DraftJournalRepository(fileURL: url).current()
        }
    }

    @Test func exactUnbindAcknowledgeAndClearAreDurablePerIdentity() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let state = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 4)
        let note = try #require(state.notes.values.first)
        let session = DraftJournalSessionID.editor(UUID())
        let entry = try makeDraftEntry(note: note, session: session, generation: 2)
        let receipt = PersistedDraftReceipt(
            noteID: note.id,
            editSessionID: session,
            draftGeneration: 2,
            noteSnapshotChecksum: entry.noteSnapshotChecksum,
            persistedNoteRevision: note.revision
        )
        let journal = DraftJournalRepository(fileURL: directory.file("draft-journal.json"))
        try await journal.persist(entry)
        #expect(try await journal.rebaseAndBind(
            expected: .init(
                identity: .init(noteID: entry.noteID, editSessionID: entry.editSessionID),
                draftGeneration: 2
            ),
            finalCandidateNote: note,
            receipt: receipt
        ) == .bound)
        #expect(try await journal.unbindPending(receipt))
        #expect(try await journal.current()?.records.first?.pendingReceipt == nil)
        #expect(try await journal.acknowledgeAlreadyPersisted(receipt))
        #expect(try await journal.current()?.records.first?.savedReceipt == receipt)
        #expect(try await journal.clear(receipt))
        #expect(try await journal.current()?.records.isEmpty == true)
    }

    @Test func failedAtomicRebaseAndBindPreservesTheExactPreviousJournalBytes() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let url = directory.file("draft-journal.json")
        let state = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 4)
        let note = try #require(state.notes.values.first)
        let session = DraftJournalSessionID.editor(UUID())
        let entry = try makeDraftEntry(note: note, session: session, generation: 2)
        try await DraftJournalRepository(fileURL: url).persist(entry)
        let before = try Data(contentsOf: url)
        let receipt = PersistedDraftReceipt(
            noteID: note.id,
            editSessionID: session,
            draftGeneration: 2,
            noteSnapshotChecksum: entry.noteSnapshotChecksum,
            persistedNoteRevision: note.revision
        )
        let failing = DraftJournalRepository(fileURL: url, writer: DraftJournalAlwaysFailingWriter())

        await #expect(throws: WorkspacePersistenceError.atomicWriteFailed) {
            _ = try await failing.rebaseAndBind(
                expected: .init(
                    identity: .init(noteID: entry.noteID, editSessionID: entry.editSessionID),
                    draftGeneration: 2
                ),
                finalCandidateNote: note,
                receipt: receipt
            )
        }
        #expect(try Data(contentsOf: url) == before)
    }
}

private func makeDraftEntry(
    note: Note,
    session: DraftJournalSessionID,
    generation: UInt64
) throws -> DraftJournalEntry {
    let checksum = try WorkspaceChecksum.noteSnapshotChecksum(note)
    let unsigned = DraftJournalEntry(
        noteID: note.id,
        editSessionID: session,
        baseWorkspaceRevision: max(0, note.revision - 1),
        baseNoteRevision: max(0, note.revision - 1),
        draftGeneration: generation,
        noteSnapshot: note,
        updatedAt: .distantPast,
        noteSnapshotChecksum: checksum,
        journalChecksum: ""
    )
    return DraftJournalEntry(
        noteID: unsigned.noteID,
        editSessionID: unsigned.editSessionID,
        baseWorkspaceRevision: unsigned.baseWorkspaceRevision,
        baseNoteRevision: unsigned.baseNoteRevision,
        draftGeneration: unsigned.draftGeneration,
        noteSnapshot: unsigned.noteSnapshot,
        updatedAt: unsigned.updatedAt,
        noteSnapshotChecksum: unsigned.noteSnapshotChecksum,
        journalChecksum: try DraftJournal.entryChecksum(for: unsigned)
    )
}

private struct LegacyEntry: Codable {
    let noteID: NoteID
    let baseWorkspaceRevision: Int64
    let baseNoteRevision: Int64
    let draftGeneration: UInt64
    let noteSnapshot: Note
    let updatedAt: Date
    let noteSnapshotChecksum: String
    let journalChecksum: String
}

private struct LegacyReceipt: Codable {
    let noteID: NoteID
    let draftGeneration: UInt64
    let noteSnapshotChecksum: String
    let persistedNoteRevision: Int64
}

private struct LegacyRecord: Codable {
    let entry: LegacyEntry
    let pendingReceipt: LegacyReceipt?
    let savedReceipt: LegacyReceipt?
    let recordChecksum: String
}

private func makeLegacyEntry(note: Note, generation: UInt64) throws -> LegacyEntry {
    let checksum = try WorkspaceChecksum.noteSnapshotChecksum(note)
    let unsigned = LegacyEntry(
        noteID: note.id,
        baseWorkspaceRevision: max(0, note.revision - 1),
        baseNoteRevision: max(0, note.revision - 1),
        draftGeneration: generation,
        noteSnapshot: note,
        updatedAt: .distantPast,
        noteSnapshotChecksum: checksum,
        journalChecksum: ""
    )
    return LegacyEntry(
        noteID: unsigned.noteID,
        baseWorkspaceRevision: unsigned.baseWorkspaceRevision,
        baseNoteRevision: unsigned.baseNoteRevision,
        draftGeneration: unsigned.draftGeneration,
        noteSnapshot: unsigned.noteSnapshot,
        updatedAt: unsigned.updatedAt,
        noteSnapshotChecksum: unsigned.noteSnapshotChecksum,
        journalChecksum: try persistenceSHA256(WorkspaceDocumentCodec.canonicalPersistentData(
            LegacyEntryChecksumInput(unsigned)
        ))
    )
}

private func legacyRecordData(
    entry: LegacyEntry,
    pending: LegacyReceipt?,
    saved: LegacyReceipt?
) throws -> Data {
    let unsigned = LegacyRecord(entry: entry, pendingReceipt: pending, savedReceipt: saved, recordChecksum: "")
    let record = LegacyRecord(
        entry: entry,
        pendingReceipt: pending,
        savedReceipt: saved,
        recordChecksum: try persistenceSHA256(WorkspaceDocumentCodec.canonicalPersistentData(
            LegacyRecordChecksumInput(unsigned)
        ))
    )
    return try WorkspaceDocumentCodec.canonicalPersistentData(record)
}

private struct LegacyEntryChecksumInput: Codable {
    let noteID: NoteID
    let baseWorkspaceRevision: Int64
    let baseNoteRevision: Int64
    let draftGeneration: UInt64
    let noteSnapshot: Note
    let updatedAt: Date
    let noteSnapshotChecksum: String

    init(_ entry: LegacyEntry) {
        noteID = entry.noteID
        baseWorkspaceRevision = entry.baseWorkspaceRevision
        baseNoteRevision = entry.baseNoteRevision
        draftGeneration = entry.draftGeneration
        noteSnapshot = entry.noteSnapshot
        updatedAt = entry.updatedAt
        noteSnapshotChecksum = entry.noteSnapshotChecksum
    }
}

private struct LegacyRecordChecksumInput: Codable {
    let entry: LegacyEntry
    let pendingReceipt: LegacyReceipt?
    let savedReceipt: LegacyReceipt?

    init(_ record: LegacyRecord) {
        entry = record.entry
        pendingReceipt = record.pendingReceipt
        savedReceipt = record.savedReceipt
    }
}

private final class DraftJournalAlwaysFailingWriter: AtomicFileWriting, @unchecked Sendable {
    func replaceAtomically(data: Data, at destination: URL) throws {
        throw WorkspacePersistenceInjectedFailure.requested
    }
}
