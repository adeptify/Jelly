import Foundation
import WorkspaceDomain

public struct WorkspaceRestorePreview: Equatable, Sendable {
    public let sourceURL: URL
    public let rawSourceData: Data
    public let sourceIdentity: WorkspaceRawSourceIdentity
    public let loadResult: WorkspaceLoadResult
    public let sourceNoteRevisions: [NoteID: Int64]

    public init(
        sourceURL: URL,
        rawSourceData: Data,
        sourceIdentity: WorkspaceRawSourceIdentity,
        loadResult: WorkspaceLoadResult,
        sourceNoteRevisions: [NoteID: Int64]
    ) {
        self.sourceURL = sourceURL
        self.rawSourceData = rawSourceData
        self.sourceIdentity = sourceIdentity
        self.loadResult = loadResult
        self.sourceNoteRevisions = sourceNoteRevisions
    }
}

public struct PreparedWorkspaceRestore: Equatable, Sendable {
    public let rawSourceData: Data
    public let provenance: WorkspaceLoadProvenance
    public let content: WorkspaceContentSnapshot
    public let sourceRevisionHighWatermark: Int64
    public let sourceNoteRevisions: [NoteID: Int64]
    let capabilityID: UUID
    let rollbackURL: URL

    init(
        preview: WorkspaceRestorePreview,
        rollbackURL: URL,
        capabilityID: UUID
    ) {
        rawSourceData = preview.rawSourceData
        provenance = preview.loadResult.provenance
        content = WorkspaceContentSnapshot(state: preview.loadResult.state)
        sourceRevisionHighWatermark = preview.loadResult.state.revision
        sourceNoteRevisions = preview.sourceNoteRevisions
        self.rollbackURL = rollbackURL
        self.capabilityID = capabilityID
    }
}
