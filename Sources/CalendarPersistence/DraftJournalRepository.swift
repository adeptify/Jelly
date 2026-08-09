import Foundation
import WorkspaceDomain

public actor DraftJournalRepository {
    private let fileURL: URL
    private let writer: any AtomicFileWriting

    public init(fileURL: URL, writer: any AtomicFileWriting = FoundationAtomicFileWriter()) {
        self.fileURL = fileURL
        self.writer = writer
    }

    public func current() throws -> DraftJournalEnvelope? {
        try readValidatedAndMigrateLegacyIfNeeded()
    }

    public func persist(_ entry: DraftJournalEntry) throws {
        guard isValid(entry) else { throw WorkspacePersistenceError.invalidJournal }
        var envelope = try readValidatedAndMigrateLegacyIfNeeded() ?? emptyEnvelope()
        let identity = DraftJournalIdentity(noteID: entry.noteID, editSessionID: entry.editSessionID)
        if let index = envelope.records.firstIndex(where: { $0.identity == identity }),
           envelope.records[index].entry.draftGeneration > entry.draftGeneration {
            return
        }
        let record = try makeRecord(entry: entry, pendingReceipt: nil, savedReceipt: nil)
        if let index = envelope.records.firstIndex(where: { $0.identity == identity }) {
            envelope.records[index] = record
        } else {
            envelope.records.append(record)
        }
        try write(envelope)
    }

    public func rebaseAndBind(
        expected: DraftJournalIdentityAndGeneration,
        finalCandidateNote: Note,
        receipt: PersistedDraftReceipt
    ) throws -> DraftJournalBindingResult {
        var envelope = try requireEnvelope()
        guard receipt.noteID == expected.identity.noteID,
              receipt.editSessionID == expected.identity.editSessionID,
              receipt.draftGeneration == expected.draftGeneration,
              finalCandidateNote.id == expected.identity.noteID,
              let index = envelope.records.firstIndex(where: { $0.identity == expected.identity })
        else { throw WorkspacePersistenceError.invalidJournal }
        let current = envelope.records[index]
        if current.entry.draftGeneration > expected.draftGeneration {
            return .supersededByNewerDraft
        }
        guard current.entry.draftGeneration == expected.draftGeneration,
              current.pendingReceipt == nil,
              current.savedReceipt == nil,
              receipt.persistedNoteRevision == finalCandidateNote.revision
        else { throw WorkspacePersistenceError.invalidJournal }
        let checksum = try WorkspaceChecksum.noteSnapshotChecksum(finalCandidateNote)
        guard receipt.noteSnapshotChecksum == checksum else { throw WorkspacePersistenceError.invalidJournal }
        let unsigned = DraftJournalEntry(
            noteID: current.entry.noteID,
            editSessionID: current.entry.editSessionID,
            baseWorkspaceRevision: current.entry.baseWorkspaceRevision,
            baseNoteRevision: current.entry.baseNoteRevision,
            draftGeneration: current.entry.draftGeneration,
            noteSnapshot: finalCandidateNote,
            updatedAt: current.entry.updatedAt,
            noteSnapshotChecksum: checksum,
            journalChecksum: ""
        )
        let rebound = DraftJournalEntry(
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
        envelope.records[index] = try makeRecord(entry: rebound, pendingReceipt: receipt, savedReceipt: nil)
        try write(envelope)
        return .bound
    }

    @discardableResult
    public func record(_ receipt: PersistedDraftReceipt) throws -> Bool {
        var envelope = try requireEnvelope()
        let identity = DraftJournalIdentity(noteID: receipt.noteID, editSessionID: receipt.editSessionID)
        guard let index = envelope.records.firstIndex(where: { $0.identity == identity }),
              envelope.records[index].pendingReceipt == receipt,
              envelope.records[index].savedReceipt == nil
        else { return false }
        envelope.records[index] = try makeRecord(
            entry: envelope.records[index].entry,
            pendingReceipt: nil,
            savedReceipt: receipt
        )
        try write(envelope)
        return true
    }

    @discardableResult
    public func unbindPending(_ receipt: PersistedDraftReceipt) throws -> Bool {
        var envelope = try requireEnvelope()
        let identity = DraftJournalIdentity(noteID: receipt.noteID, editSessionID: receipt.editSessionID)
        guard let index = envelope.records.firstIndex(where: { $0.identity == identity }),
              envelope.records[index].pendingReceipt == receipt,
              envelope.records[index].savedReceipt == nil
        else { return false }
        envelope.records[index] = try makeRecord(
            entry: envelope.records[index].entry,
            pendingReceipt: nil,
            savedReceipt: nil
        )
        try write(envelope)
        return true
    }

    @discardableResult
    public func acknowledgeAlreadyPersisted(_ receipt: PersistedDraftReceipt) throws -> Bool {
        var envelope = try requireEnvelope()
        let identity = DraftJournalIdentity(noteID: receipt.noteID, editSessionID: receipt.editSessionID)
        guard let index = envelope.records.firstIndex(where: { $0.identity == identity }),
              envelope.records[index].pendingReceipt == nil,
              envelope.records[index].savedReceipt == nil,
              isCompatible(receipt, with: envelope.records[index].entry)
        else { return false }
        envelope.records[index] = try makeRecord(
            entry: envelope.records[index].entry,
            pendingReceipt: nil,
            savedReceipt: receipt
        )
        try write(envelope)
        return true
    }

    @discardableResult
    public func clear(_ receipt: PersistedDraftReceipt) throws -> Bool {
        var envelope = try requireEnvelope()
        let identity = DraftJournalIdentity(noteID: receipt.noteID, editSessionID: receipt.editSessionID)
        guard let index = envelope.records.firstIndex(where: { $0.identity == identity }),
              envelope.records[index].savedReceipt == receipt,
              envelope.records[index].pendingReceipt == nil
        else { return false }
        envelope.records.remove(at: index)
        try write(envelope)
        return true
    }

    private func requireEnvelope() throws -> DraftJournalEnvelope {
        guard let envelope = try readValidatedAndMigrateLegacyIfNeeded() else {
            throw WorkspacePersistenceError.invalidJournal
        }
        return envelope
    }

    private func emptyEnvelope() -> DraftJournalEnvelope {
        DraftJournalEnvelope(
            schemaVersion: DraftJournalEnvelope.currentSchemaVersion,
            records: [],
            envelopeChecksum: ""
        )
    }

    private func readValidatedAndMigrateLegacyIfNeeded() throws -> DraftJournalEnvelope? {
        switch noFollowFileProbe(at: fileURL) {
        case .confirmedAbsent:
            return nil
        case .unreadableUnknown:
            throw WorkspacePersistenceError.invalidJournal
        case let .bytes(rawData):
            if let envelope = try? decodeEnvelope(rawData) { return envelope }
            let legacy = try decodeLegacy(rawData)
            let migrated = try legacy.map(migratedEnvelope(from:)) ?? emptyEnvelope()
            try write(migrated)
            return migrated
        }
    }

    private func decodeEnvelope(_ rawData: Data) throws -> DraftJournalEnvelope {
        let envelope: DraftJournalEnvelope
        do {
            envelope = try JSONDecoder.workspaceDeterministic.decode(DraftJournalEnvelope.self, from: rawData)
        } catch {
            throw WorkspacePersistenceError.invalidJournal
        }
        guard envelope.schemaVersion == DraftJournalEnvelope.currentSchemaVersion,
              envelope.records == DraftJournal.canonicalRecords(envelope.records),
              Set(envelope.records.map(\.identity)).count == envelope.records.count,
              envelope.records.allSatisfy(isValid),
              envelope.envelopeChecksum == (try? DraftJournal.envelopeChecksum(records: envelope.records))
        else { throw WorkspacePersistenceError.invalidJournal }
        return envelope
    }

    private func decodeLegacy(_ rawData: Data) throws -> LegacyRecord? {
        let record: LegacyRecord?
        do {
            record = try JSONDecoder.workspaceDeterministic.decode(LegacyRecord?.self, from: rawData)
        } catch {
            throw WorkspacePersistenceError.invalidJournal
        }
        guard let record else { return nil }
        guard record.entry.noteID == record.entry.noteSnapshot.id,
              record.entry.noteSnapshotChecksum
                == (try? WorkspaceChecksum.noteSnapshotChecksum(record.entry.noteSnapshot)),
              record.entry.journalChecksum == (try? legacyEntryChecksum(record.entry)),
              record.recordChecksum == (try? legacyRecordChecksum(record)),
              record.pendingReceipt.map({ isCompatible($0, with: record.entry) }) ?? true,
              record.savedReceipt.map({ isCompatible($0, with: record.entry) }) ?? true,
              !(record.pendingReceipt != nil && record.savedReceipt != nil)
        else { throw WorkspacePersistenceError.invalidJournal }
        return record
    }

    private func migratedEnvelope(from legacy: LegacyRecord) throws -> DraftJournalEnvelope {
        let unsigned = DraftJournalEntry(
            noteID: legacy.entry.noteID,
            editSessionID: .legacyTask5,
            baseWorkspaceRevision: legacy.entry.baseWorkspaceRevision,
            baseNoteRevision: legacy.entry.baseNoteRevision,
            draftGeneration: legacy.entry.draftGeneration,
            noteSnapshot: legacy.entry.noteSnapshot,
            updatedAt: legacy.entry.updatedAt,
            noteSnapshotChecksum: legacy.entry.noteSnapshotChecksum,
            journalChecksum: ""
        )
        let entry = DraftJournalEntry(
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
        let pending = legacy.pendingReceipt.map { receipt in
            PersistedDraftReceipt(
                noteID: receipt.noteID,
                editSessionID: .legacyTask5,
                draftGeneration: receipt.draftGeneration,
                noteSnapshotChecksum: receipt.noteSnapshotChecksum,
                persistedNoteRevision: receipt.persistedNoteRevision
            )
        }
        let saved = legacy.savedReceipt.map { receipt in
            PersistedDraftReceipt(
                noteID: receipt.noteID,
                editSessionID: .legacyTask5,
                draftGeneration: receipt.draftGeneration,
                noteSnapshotChecksum: receipt.noteSnapshotChecksum,
                persistedNoteRevision: receipt.persistedNoteRevision
            )
        }
        let record = try makeRecord(entry: entry, pendingReceipt: pending, savedReceipt: saved)
        let records = DraftJournal.canonicalRecords([record])
        return DraftJournalEnvelope(
            schemaVersion: DraftJournalEnvelope.currentSchemaVersion,
            records: records,
            envelopeChecksum: try DraftJournal.envelopeChecksum(records: records)
        )
    }

    private func write(_ envelope: DraftJournalEnvelope) throws {
        let records = DraftJournal.canonicalRecords(envelope.records)
        let normalized = DraftJournalEnvelope(
            schemaVersion: DraftJournalEnvelope.currentSchemaVersion,
            records: records,
            envelopeChecksum: try DraftJournal.envelopeChecksum(records: records)
        )
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try writer.replaceAtomically(
                data: WorkspaceDocumentCodec.canonicalPersistentData(normalized),
                at: fileURL
            )
        } catch {
            throw WorkspacePersistenceError.atomicWriteFailed
        }
    }

    private func makeRecord(
        entry: DraftJournalEntry,
        pendingReceipt: PersistedDraftReceipt?,
        savedReceipt: PersistedDraftReceipt?
    ) throws -> StoredDraftJournalRecord {
        StoredDraftJournalRecord(
            entry: entry,
            pendingReceipt: pendingReceipt,
            savedReceipt: savedReceipt,
            recordChecksum: try DraftJournal.recordChecksum(
                entry: entry,
                pendingReceipt: pendingReceipt,
                savedReceipt: savedReceipt
            )
        )
    }

    private func isValid(_ record: StoredDraftJournalRecord) -> Bool {
        isValid(record.entry)
            && record.recordChecksum == (try? DraftJournal.recordChecksum(
                entry: record.entry,
                pendingReceipt: record.pendingReceipt,
                savedReceipt: record.savedReceipt
            ))
            && record.pendingReceipt.map({ isCompatible($0, with: record.entry) }) ?? true
            && record.savedReceipt.map({ isCompatible($0, with: record.entry) }) ?? true
            && !(record.pendingReceipt != nil && record.savedReceipt != nil)
    }

    private func isValid(_ entry: DraftJournalEntry) -> Bool {
        entry.noteID == entry.noteSnapshot.id
            && entry.noteSnapshotChecksum == (try? WorkspaceChecksum.noteSnapshotChecksum(entry.noteSnapshot))
            && entry.journalChecksum == (try? DraftJournal.entryChecksum(for: entry))
    }

    private nonisolated func isCompatible(
        _ receipt: PersistedDraftReceipt,
        with entry: DraftJournalEntry
    ) -> Bool {
        receipt.noteID == entry.noteID
            && receipt.editSessionID == entry.editSessionID
            && receipt.draftGeneration == entry.draftGeneration
            && receipt.noteSnapshotChecksum == entry.noteSnapshotChecksum
            && receipt.persistedNoteRevision > entry.baseNoteRevision
    }

    private nonisolated func isCompatible(
        _ receipt: LegacyReceipt,
        with entry: LegacyEntry
    ) -> Bool {
        receipt.noteID == entry.noteID
            && receipt.draftGeneration == entry.draftGeneration
            && receipt.noteSnapshotChecksum == entry.noteSnapshotChecksum
            && receipt.persistedNoteRevision > entry.baseNoteRevision
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

    private nonisolated func legacyEntryChecksum(_ entry: LegacyEntry) throws -> String {
        try persistenceSHA256(WorkspaceDocumentCodec.canonicalPersistentData(LegacyEntryChecksumInput(entry)))
    }

    private nonisolated func legacyRecordChecksum(_ record: LegacyRecord) throws -> String {
        try persistenceSHA256(WorkspaceDocumentCodec.canonicalPersistentData(LegacyRecordChecksumInput(record)))
    }
}
