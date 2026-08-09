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
    }

    @Test func parkedJournalExposesTheExactIdentityAndStep() {
        let identity = DraftJournalIdentity(noteID: NoteID(UUID()), editSessionID: .editor(UUID()))

        #expect(BackupRecoveryPolicy.actions(for: .parkedJournalCleanup(identity, .unbind)) == [
            .retryJournalCleanup(identity, .unbind)
        ])
        #expect(BackupRecoveryPolicy.message(for: .cleanupPending(identity: identity, step: .unbind)) ==
            "草稿清理仍未完成；请稍后继续清理。")
    }

    @Test func opaqueAndUnreadablePrimaryExposeRawRecoveryCopyButNotWrites() {
        #expect(BackupRecoveryPolicy.actions(for: .opaquePrimaryLoadFailed) == [.exportRawRecoveryCopy])
        #expect(BackupRecoveryPolicy.actions(for: .unreadablePrimaryLoadFailed) == [.exportRawRecoveryCopy])
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
}
