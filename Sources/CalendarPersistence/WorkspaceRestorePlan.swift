import Foundation
import WorkspaceDomain

public struct WorkspaceRestoreRequest: Equatable, Sendable {
    public let sourceURL: URL
    public let rollbackDirectoryURL: URL

    public init(sourceURL: URL, rollbackDirectoryURL: URL) {
        self.sourceURL = sourceURL
        self.rollbackDirectoryURL = rollbackDirectoryURL
    }
}

public struct PreparedWorkspaceRestore: Equatable, Sendable {
    public let rawSourceData: Data
    public let provenance: WorkspaceLoadProvenance
    public let content: WorkspaceContentSnapshot
    public let sourceRevisionHighWatermark: Int64
    public let sourceNoteRevisions: [NoteID: Int64]
    public let rollbackURL: URL

    public init(
        rawSourceData: Data,
        provenance: WorkspaceLoadProvenance,
        content: WorkspaceContentSnapshot,
        sourceRevisionHighWatermark: Int64,
        sourceNoteRevisions: [NoteID: Int64],
        rollbackURL: URL
    ) {
        self.rawSourceData = rawSourceData
        self.provenance = provenance
        self.content = content
        self.sourceRevisionHighWatermark = sourceRevisionHighWatermark
        self.sourceNoteRevisions = sourceNoteRevisions
        self.rollbackURL = rollbackURL
    }
}
