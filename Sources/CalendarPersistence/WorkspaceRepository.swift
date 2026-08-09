import Foundation
import WorkspaceDomain

public protocol WorkspaceRepository: Sendable {
    func load() async throws -> WorkspaceLoadResult
    func save(_ state: WorkspaceState, draft: PersistableDraftContext?) async throws -> WorkspaceSaveReceipt
    func verifyPersistedDraft(_ context: PersistableDraftContext) async throws
        -> WorkspaceDraftPersistenceVerification
    func prepareRestore(
        _ preview: WorkspaceRestorePreview,
        rollbackDirectoryURL: URL
    ) async throws -> PreparedWorkspaceRestore
    func discardPreparedRestore(_ prepared: PreparedWorkspaceRestore) async -> Bool
    func commitRestore(
        _ prepared: PreparedWorkspaceRestore,
        state: WorkspaceState
    ) async throws -> WorkspaceRestoreOutcome
    func currentDocumentData() async throws -> Data
    func reloadCurrentSourceAfterExternalChange() async throws -> WorkspaceReloadedSource
    func currentRawRecoveryData() async throws -> WorkspaceRawRecoveryArtifact
    func reconcilePendingCommit() async throws -> WorkspaceCommitReconciliation
}
