import Foundation
import WorkspaceDomain

/// Durable intent for one recovery main-file save.  This is persistence
/// metadata rather than WorkspaceDomain behavior; the only recovery identity
/// exposed by WorkspaceDomain remains `DraftRecoveryToken`.
public enum DraftRecoveryCompletionAction: String, Codable, Equatable, Sendable {
    case restoreAsCurrent
    case saveAsNew
}

public enum DraftRecoveryCompletionState: String, Codable, Equatable, Sendable {
    case pending
    case committed
}

/// Exact main-file identity observed immediately before the recovery save
/// begins.  It distinguishes an unwritten recovery from a different writer
/// advancing (or rolling back) the workspace after a durable marker exists.
public struct DraftRecoverySourceIdentity: Codable, Equatable, Sendable {
    public let workspaceRevision: Int64
    public let workspaceChecksum: String

    public init(workspaceRevision: Int64, workspaceChecksum: String) {
        self.workspaceRevision = workspaceRevision
        self.workspaceChecksum = workspaceChecksum
    }
}

public struct DraftRecoveryResultIdentity: Codable, Equatable, Sendable {
    public let noteID: NoteID
    public let noteSnapshotChecksum: String
    public let noteRevision: Int64
    public let workspaceRevision: Int64

    public init(
        noteID: NoteID,
        noteSnapshotChecksum: String,
        noteRevision: Int64,
        workspaceRevision: Int64
    ) {
        self.noteID = noteID
        self.noteSnapshotChecksum = noteSnapshotChecksum
        self.noteRevision = noteRevision
        self.workspaceRevision = workspaceRevision
    }
}

public struct DraftRecoveryCompletion: Codable, Equatable, Sendable {
    public let token: DraftRecoveryToken
    public let action: DraftRecoveryCompletionAction
    public let source: DraftRecoverySourceIdentity
    public let result: DraftRecoveryResultIdentity
    public let state: DraftRecoveryCompletionState

    public init(
        token: DraftRecoveryToken,
        action: DraftRecoveryCompletionAction,
        source: DraftRecoverySourceIdentity,
        result: DraftRecoveryResultIdentity,
        state: DraftRecoveryCompletionState
    ) {
        self.token = token
        self.action = action
        self.source = source
        self.result = result
        self.state = state
    }

    public func withState(_ state: DraftRecoveryCompletionState) -> DraftRecoveryCompletion {
        .init(token: token, action: action, source: source, result: result, state: state)
    }
}

public struct StoredDraftJournalRecord: Codable, Equatable, Sendable {
    public let entry: DraftJournalEntry
    public let pendingReceipt: PersistedDraftReceipt?
    public let savedReceipt: PersistedDraftReceipt?
    public let recoveryCompletion: DraftRecoveryCompletion?
    public let recordChecksum: String

    public init(
        entry: DraftJournalEntry,
        pendingReceipt: PersistedDraftReceipt?,
        savedReceipt: PersistedDraftReceipt?,
        recoveryCompletion: DraftRecoveryCompletion? = nil,
        recordChecksum: String
    ) {
        self.entry = entry
        self.pendingReceipt = pendingReceipt
        self.savedReceipt = savedReceipt
        self.recoveryCompletion = recoveryCompletion
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

public enum DraftJournalProtectionResult: Equatable, Sendable {
    case protected(DraftRecoveryToken)
    case superseded(currentGeneration: UInt64)
    case busy(currentGeneration: UInt64)
}

/// Result of an exact recovery compare-and-transition. A stale token is
/// durable evidence that the caller must rescan; it is not a failed write.
public enum DraftJournalExactTransitionResult: Equatable, Sendable {
    case applied
    case staleOrMissing
}

public enum DraftJournal {
    public static func recoverySourceIdentity(for state: WorkspaceState) throws -> DraftRecoverySourceIdentity {
        .init(
            workspaceRevision: state.revision,
            workspaceChecksum: persistenceSHA256(try WorkspaceDocumentCodec.encode(state))
        )
    }

    public static func entryChecksum(for entry: DraftJournalEntry) throws -> String {
        try persistenceSHA256(WorkspaceDocumentCodec.canonicalPersistentData(EntryChecksumInput(entry: entry)))
    }

    static func recordChecksum(
        entry: DraftJournalEntry,
        pendingReceipt: PersistedDraftReceipt?,
        savedReceipt: PersistedDraftReceipt?,
        recoveryCompletion: DraftRecoveryCompletion?
    ) throws -> String {
        try persistenceSHA256(WorkspaceDocumentCodec.canonicalPersistentData(
            RecordChecksumInput(
                entry: entry,
                pendingReceipt: pendingReceipt,
                savedReceipt: savedReceipt,
                recoveryCompletion: recoveryCompletion
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
        let recoveryCompletion: DraftRecoveryCompletion?
    }

    private struct EnvelopeChecksumInput: Codable {
        let schemaVersion: Int
        let records: [StoredDraftJournalRecord]
    }
}
