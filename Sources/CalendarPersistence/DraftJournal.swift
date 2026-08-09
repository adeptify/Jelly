import Foundation
import WorkspaceDomain

public struct StoredDraftJournalRecord: Codable, Equatable, Sendable {
    public let entry: DraftJournalEntry
    public let pendingReceipt: PersistedDraftReceipt?
    public let savedReceipt: PersistedDraftReceipt?
    public let recordChecksum: String

    public init(
        entry: DraftJournalEntry,
        pendingReceipt: PersistedDraftReceipt?,
        savedReceipt: PersistedDraftReceipt?,
        recordChecksum: String
    ) {
        self.entry = entry
        self.pendingReceipt = pendingReceipt
        self.savedReceipt = savedReceipt
        self.recordChecksum = recordChecksum
    }

    public var identity: DraftJournalIdentity {
        .init(noteID: entry.noteID, editSessionID: entry.editSessionID)
    }
}

public struct DraftJournalEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var records: [StoredDraftJournalRecord]
    public var envelopeChecksum: String

    public init(schemaVersion: Int, records: [StoredDraftJournalRecord], envelopeChecksum: String) {
        self.schemaVersion = schemaVersion
        self.records = records
        self.envelopeChecksum = envelopeChecksum
    }
}

public enum DraftJournalBindingResult: Equatable, Sendable {
    case bound
    case supersededByNewerDraft
}

public enum DraftJournal {
    public static func entryChecksum(for entry: DraftJournalEntry) throws -> String {
        try persistenceSHA256(WorkspaceDocumentCodec.canonicalPersistentData(EntryChecksumInput(entry: entry)))
    }

    static func recordChecksum(
        entry: DraftJournalEntry,
        pendingReceipt: PersistedDraftReceipt?,
        savedReceipt: PersistedDraftReceipt?
    ) throws -> String {
        try persistenceSHA256(WorkspaceDocumentCodec.canonicalPersistentData(
            RecordChecksumInput(
                entry: entry,
                pendingReceipt: pendingReceipt,
                savedReceipt: savedReceipt
            )
        ))
    }

    static func envelopeChecksum(records: [StoredDraftJournalRecord]) throws -> String {
        try persistenceSHA256(WorkspaceDocumentCodec.canonicalPersistentData(
            EnvelopeChecksumInput(schemaVersion: DraftJournalEnvelope.currentSchemaVersion, records: records)
        ))
    }

    static func canonicalRecords(_ records: [StoredDraftJournalRecord]) -> [StoredDraftJournalRecord] {
        records.sorted { lhs, rhs in
            let left = canonicalIdentityKey(lhs.identity)
            let right = canonicalIdentityKey(rhs.identity)
            return left < right
        }
    }

    static func canonicalIdentityKey(_ identity: DraftJournalIdentity) -> String {
        let session: String
        switch identity.editSessionID {
        case .legacyTask5:
            session = "0:legacyTask5"
        case let .editor(id):
            session = "1:\(id.uuidString.lowercased())"
        }
        return "\(identity.noteID.rawValue.uuidString.lowercased()):\(session)"
    }

    private struct EntryChecksumInput: Codable {
        let noteID: NoteID
        let editSessionID: DraftJournalSessionID
        let baseWorkspaceRevision: Int64
        let baseNoteRevision: Int64
        let draftGeneration: UInt64
        let noteSnapshot: Note
        let updatedAt: Date
        let noteSnapshotChecksum: String

        init(entry: DraftJournalEntry) {
            noteID = entry.noteID
            editSessionID = entry.editSessionID
            baseWorkspaceRevision = entry.baseWorkspaceRevision
            baseNoteRevision = entry.baseNoteRevision
            draftGeneration = entry.draftGeneration
            noteSnapshot = entry.noteSnapshot
            updatedAt = entry.updatedAt
            noteSnapshotChecksum = entry.noteSnapshotChecksum
        }
    }

    private struct RecordChecksumInput: Codable {
        let entry: DraftJournalEntry
        let pendingReceipt: PersistedDraftReceipt?
        let savedReceipt: PersistedDraftReceipt?
    }

    private struct EnvelopeChecksumInput: Codable {
        let schemaVersion: Int
        let records: [StoredDraftJournalRecord]
    }
}
