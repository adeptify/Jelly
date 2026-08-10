import CalendarPersistence
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("BackupRecoveryPolicyTests")
struct BackupRecoveryPolicyTests {
    @Test func parkedCommitExposesTheExactTransactionAndTruthfulTerminalMessages() {
        let transactionID = UUID()
        let artifacts = WorkspacePendingCommitArtifacts()

        #expect(BackupRecoveryPolicy.actions(for: .parkedCommitUncertain(transactionID)) == [
            .retryPendingCommit(transactionID)
        ])
        #expect(BackupRecoveryPolicy.message(for: .committed(.save(
            .init(workspaceRevision: 2, persistedDraft: nil)
        ), journal: .clean)) == "此前保存已确认。")
        #expect(BackupRecoveryPolicy.message(for: .notCommitted(
            transactionID: transactionID, journal: .clean, artifacts: artifacts
        )) == "已确认此前保存没有写入磁盘，当前输入仍保留。")
        #expect(BackupRecoveryPolicy.message(for: .sourceChanged(
            transactionID: transactionID, journal: .clean, artifacts: artifacts
        )) == "保存期间本地数据发生变化，当前输入未覆盖外部内容。")
        #expect(BackupRecoveryPolicy.message(for: .stillPending(
            transactionID: transactionID, artifacts: artifacts
        )) == "保存结果仍未确认；请稍后再次确认。")
        #expect(BackupRecoveryPolicy.message(for: .committed(.restore(.init(
            receipt: .init(workspaceRevision: 3, persistedDraft: nil),
            rollback: .nonePreviousSourceAbsent
        )), journal: .clean)) == "此前恢复已确认。恢复前没有可回滚的主数据文件。")
    }

    @Test func pendingCommitMenuUsesAnOperationNeutralLabelWithoutLosingTheTransaction() {
        let transactionID = UUID()
        let phase = WorkspaceStorePhase.parkedCommitUncertain(transactionID)

        #expect(BackupRecoveryPolicy.actions(for: phase) == [.retryPendingCommit(transactionID)])
        #expect(BackupRecoveryPolicy.pendingCommitMenuTitle(for: phase) == "继续确认未完成操作")
        #expect(BackupRecoveryPolicy.pendingCommitMenuTitle(for: .ready) == nil)
    }

    @Test func parkedJournalExposesTheExactIdentityAndStep() {
        let identity = DraftJournalIdentity(noteID: NoteID(UUID()), editSessionID: .editor(UUID()))

        #expect(BackupRecoveryPolicy.actions(for: .parkedJournalCleanup(identity, .unbind)) == [
            .retryJournalCleanup(identity, .unbind)
        ])
        #expect(BackupRecoveryPolicy.message(for: .cleanupPending(identity: identity, step: .unbind)) ==
            "草稿清理仍未完成；请稍后继续清理。")
    }

    @Test func onlyOpaquePrimaryExposesRawRecoveryCopy() {
        #expect(BackupRecoveryPolicy.actions(for: .opaquePrimaryLoadFailed) == [.exportRawRecoveryCopy])
        #expect(BackupRecoveryPolicy.actions(for: .unreadablePrimaryLoadFailed) == [])
    }

    @Test func restoreAvailabilityMatchesTheStoreRecoveryContract() {
        #expect(BackupRecoveryPolicy.allowsRestore(from: .ready))
        #expect(BackupRecoveryPolicy.allowsRestore(from: .externalSourceChanged(.externalBytesChanged)))
        #expect(BackupRecoveryPolicy.allowsRestore(from: .opaquePrimaryLoadFailed))
        #expect(BackupRecoveryPolicy.allowsRestore(from: .needsRelationshipRepair))
        #expect(!BackupRecoveryPolicy.allowsRestore(from: .loadFailed))
        #expect(!BackupRecoveryPolicy.allowsRestore(from: .unreadablePrimaryLoadFailed))
        #expect(!BackupRecoveryPolicy.allowsRestore(from: .parkedCommitUncertain(UUID())))
    }

    @Test func restoreRetriesDescribeRestoreRatherThanSaveAndUseReturnedCleanupToken() {
        let transactionID = UUID()
        let rollback = URL(fileURLWithPath: "/tmp/jelly-policy-restore.json")
        let artifacts = WorkspacePendingCommitArtifacts(
            rollback: .file(rollback, .init(sha256: "hash", byteCount: 4))
        )
        #expect(BackupRecoveryPolicy.message(for: .notCommitted(
            transactionID: transactionID, journal: .clean, artifacts: artifacts
        )) == "已确认此前恢复没有替换当前数据。恢复前的数据已保留在：\n/tmp/jelly-policy-restore.json")
        #expect(BackupRecoveryPolicy.message(for: .sourceChanged(
            transactionID: transactionID, journal: .clean, artifacts: .init(rollback: .nonePreviousSourceAbsent)
        )) == "恢复期间本地数据发生变化，当前数据未覆盖外部内容。恢复前没有可回滚的主数据文件。")
        #expect(BackupRecoveryPolicy.retryTitle(for: .notCommitted(
            transactionID: transactionID, journal: .clean, artifacts: artifacts
        )) == "恢复确认结果")
        #expect(BackupRecoveryPolicy.retryTitle(for: .stillPending(
            transactionID: transactionID, artifacts: .init()
        )) == "保存确认结果")

        let returnedIdentity = DraftJournalIdentity(noteID: NoteID(UUID()), editSessionID: .editor(UUID()))
        #expect(BackupRecoveryPolicy.cleanupDetail(for: .cleanupPending(identity: returnedIdentity, step: .clear)) ==
            "记录：\(returnedIdentity.noteID.rawValue.uuidString)，步骤：清除草稿记录。")
    }
}
