import Foundation
import WorkspaceDomain

public struct WorkspaceLoadProvenance: Equatable, Sendable {
    public let sourceSchema: Int
    public let sourceBytesSHA256: String
    public let sourceByteCount: Int

    public init(sourceSchema: Int, sourceBytesSHA256: String, sourceByteCount: Int) {
        self.sourceSchema = sourceSchema
        self.sourceBytesSHA256 = sourceBytesSHA256
        self.sourceByteCount = sourceByteCount
    }
}

public struct WorkspaceLoadResult: Equatable, Sendable {
    public let state: WorkspaceState
    public let provenance: WorkspaceLoadProvenance
    public let consistencyIssues: [WorkspaceConsistencyIssue]

    public init(
        state: WorkspaceState,
        provenance: WorkspaceLoadProvenance,
        consistencyIssues: [WorkspaceConsistencyIssue]
    ) {
        self.state = state
        self.provenance = provenance
        self.consistencyIssues = consistencyIssues
    }
}

public struct WorkspaceSaveReceipt: Equatable, Sendable {
    public let workspaceRevision: Int64
    public let persistedDraft: PersistedDraftReceipt?

    public init(workspaceRevision: Int64, persistedDraft: PersistedDraftReceipt?) {
        self.workspaceRevision = workspaceRevision
        self.persistedDraft = persistedDraft
    }
}

public enum WorkspacePersistenceError: Error, Equatable, Sendable {
    case invalidDocument
    case unsupportedSchema(Int)
    case invalidWorkspace
    case atomicWriteFailed
    case sourceChanged
    case missingDocument
    case invalidManifest
    case invalidSnapshot
    case invalidJournal
    case invalidDraftContext
    case invalidRestoreCapability
    case restoreBindingMismatch
    case rollbackWriteFailed
}

public struct WorkspaceDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var state: WorkspaceState

    public init(schemaVersion: Int = currentSchemaVersion, state: WorkspaceState) {
        self.schemaVersion = schemaVersion
        self.state = state
    }
}
