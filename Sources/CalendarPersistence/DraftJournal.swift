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

    private struct EntryChecksumInput: Codable {
        let noteID: NoteID
        let baseWorkspaceRevision: Int64
        let baseNoteRevision: Int64
        let draftGeneration: UInt64
        let noteSnapshot: Note
        let updatedAt: Date
        let noteSnapshotChecksum: String

        init(entry: DraftJournalEntry) {
            noteID = entry.noteID
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
}
