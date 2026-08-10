import Foundation

public enum NoteDraftField: String, Codable, Hashable, Sendable {
    case title
    case document
    case categoryID
    case archivedAt
}

public enum LinkedTaskBlockDeletionDisposition: String, Codable, Equatable, Sendable {
    case keepCalendarItem
    case deleteCalendarItem
}

/// Namespaces a journal generation so a Task 5 legacy record can never collide
/// with a live editor session that happens to use the same UUID bytes.
public enum DraftJournalSessionID: Hashable, Codable, Sendable {
    case editor(UUID)
    case legacyTask5
}

public struct DraftJournalIdentity: Hashable, Codable, Sendable {
    public let noteID: NoteID
    public let editSessionID: DraftJournalSessionID

    public init(noteID: NoteID, editSessionID: DraftJournalSessionID) {
        self.noteID = noteID
        self.editSessionID = editSessionID
    }
}

public struct DraftJournalIdentityAndGeneration: Hashable, Codable, Sendable {
    public let identity: DraftJournalIdentity
    public let draftGeneration: UInt64

    public init(identity: DraftJournalIdentity, draftGeneration: UInt64) {
        self.identity = identity
        self.draftGeneration = draftGeneration
    }
}

/// A durable, non-authorizing identity for one exact bare journal record.
///
/// The token can be decoded or forged, so it never grants permission to save
/// a draft.  Persistence uses it solely as a compare-and-discard key under the
/// journal lock; Store-issued `ProtectedNoteDraft` is the authorization for a
/// live commit and deliberately remains inside CalendarApp.
public struct DraftRecoveryToken: Hashable, Codable, Sendable {
    public let identityAndGeneration: DraftJournalIdentityAndGeneration
    public let noteSnapshotChecksum: String
    public let journalChecksum: String

    public init(
        identityAndGeneration: DraftJournalIdentityAndGeneration,
        noteSnapshotChecksum: String,
        journalChecksum: String
    ) {
        self.identityAndGeneration = identityAndGeneration
        self.noteSnapshotChecksum = noteSnapshotChecksum
        self.journalChecksum = journalChecksum
    }
}

public struct NoteDraftSubmission: Equatable, Sendable {
    public let noteID: NoteID
    public let editSessionID: UUID
    public let baseNoteRevision: Int64
    public let baseNoteSnapshotChecksum: String
    public let baseSnapshot: Note
    public let baseLinkedTaskBlockLinks: Set<TaskBlockCalendarLink>
    public let draftGeneration: UInt64
    public let snapshot: Note
    public let noteSnapshotChecksum: String
    public let modifiedFields: Set<NoteDraftField>
    public let linkedBlockDeletionDispositions: [BlockID: LinkedTaskBlockDeletionDisposition]

    public init(
        noteID: NoteID,
        editSessionID: UUID,
        baseNoteRevision: Int64,
        baseNoteSnapshotChecksum: String,
        baseSnapshot: Note,
        baseLinkedTaskBlockLinks: Set<TaskBlockCalendarLink>,
        draftGeneration: UInt64,
        snapshot: Note,
        noteSnapshotChecksum: String,
        modifiedFields: Set<NoteDraftField>,
        linkedBlockDeletionDispositions: [BlockID: LinkedTaskBlockDeletionDisposition]
    ) {
        self.noteID = noteID
        self.editSessionID = editSessionID
        self.baseNoteRevision = baseNoteRevision
        self.baseNoteSnapshotChecksum = baseNoteSnapshotChecksum
        self.baseSnapshot = baseSnapshot
        self.baseLinkedTaskBlockLinks = baseLinkedTaskBlockLinks
        self.draftGeneration = draftGeneration
        self.snapshot = snapshot
        self.noteSnapshotChecksum = noteSnapshotChecksum
        self.modifiedFields = modifiedFields
        self.linkedBlockDeletionDispositions = linkedBlockDeletionDispositions
    }
}

public struct PersistableDraftContext: Equatable, Sendable {
    public let noteID: NoteID
    public let editSessionID: DraftJournalSessionID
    public let draftGeneration: UInt64
    public let noteSnapshotChecksum: String
    public let persistedNoteRevision: Int64

    public init(
        noteID: NoteID,
        editSessionID: DraftJournalSessionID,
        draftGeneration: UInt64,
        noteSnapshotChecksum: String,
        persistedNoteRevision: Int64
    ) {
        self.noteID = noteID
        self.editSessionID = editSessionID
        self.draftGeneration = draftGeneration
        self.noteSnapshotChecksum = noteSnapshotChecksum
        self.persistedNoteRevision = persistedNoteRevision
    }
}

public struct DraftJournalEntry: Codable, Equatable, Sendable {
    public let noteID: NoteID
    public let editSessionID: DraftJournalSessionID
    public let baseWorkspaceRevision: Int64
    public let baseNoteRevision: Int64
    public let draftGeneration: UInt64
    public let noteSnapshot: Note
    public let updatedAt: Date
    public let noteSnapshotChecksum: String
    public let journalChecksum: String

    public init(
        noteID: NoteID,
        editSessionID: DraftJournalSessionID,
        baseWorkspaceRevision: Int64,
        baseNoteRevision: Int64,
        draftGeneration: UInt64,
        noteSnapshot: Note,
        updatedAt: Date,
        noteSnapshotChecksum: String,
        journalChecksum: String
    ) {
        self.noteID = noteID
        self.editSessionID = editSessionID
        self.baseWorkspaceRevision = baseWorkspaceRevision
        self.baseNoteRevision = baseNoteRevision
        self.draftGeneration = draftGeneration
        self.noteSnapshot = noteSnapshot
        self.updatedAt = updatedAt
        self.noteSnapshotChecksum = noteSnapshotChecksum
        self.journalChecksum = journalChecksum
    }
}

public struct PersistedDraftReceipt: Codable, Equatable, Sendable {
    public let noteID: NoteID
    public let editSessionID: DraftJournalSessionID
    public let draftGeneration: UInt64
    public let noteSnapshotChecksum: String
    public let persistedNoteRevision: Int64

    public init(
        noteID: NoteID,
        editSessionID: DraftJournalSessionID,
        draftGeneration: UInt64,
        noteSnapshotChecksum: String,
        persistedNoteRevision: Int64
    ) {
        self.noteID = noteID
        self.editSessionID = editSessionID
        self.draftGeneration = draftGeneration
        self.noteSnapshotChecksum = noteSnapshotChecksum
        self.persistedNoteRevision = persistedNoteRevision
    }
}
