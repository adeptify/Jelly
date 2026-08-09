import Foundation
import WorkspaceDomain

public protocol WorkspaceRepository: Sendable {
    func load() async throws -> WorkspaceLoadResult
    func save(_ state: WorkspaceState, draft: PersistableDraftContext?) async throws -> WorkspaceSaveReceipt
    func prepareRestore(_ request: WorkspaceRestoreRequest) async throws -> PreparedWorkspaceRestore
    func commitRestore(
        _ prepared: PreparedWorkspaceRestore,
        state: WorkspaceState
    ) async throws -> WorkspaceSaveReceipt
    func currentDocumentData() async throws -> Data
    func reconcilePendingCommit() async throws -> WorkspaceCommitReconciliation
}
