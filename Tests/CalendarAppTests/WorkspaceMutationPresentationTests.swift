import CalendarDomain
import CalendarPersistence
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("WorkspaceMutationPresentationTests")
@MainActor
struct WorkspaceMutationPresentationTests {
    @Test func definiteSaveFailureKeepsAnEditorOpenAndProvidesATruthfulMessage() async throws {
        let state = makeEmptyState()
        let (store, repository) = try await makeReadyStore(initialState: state)
        let item = try makeItem(categoryID: state.uncategorizedID, title: "不应丢失的草稿")
        await repository.failNextSave()

        let outcome = try await store.sendCalendar(.createItem(item), undoLabel: "新建事项")
        let presentation = WorkspaceMutationOutcomePresenter.presentation(for: outcome)

        #expect(presentation.allowsDismissal == false)
        #expect(presentation.recoveryAction == nil)
        #expect(presentation.message == "没有保存到磁盘，已保留当前输入；请重试。")
    }

    @Test func pendingCommitKeepsTheExactTransactionTokenForRecovery() {
        let transactionID = UUID()
        let artifacts = WorkspacePendingCommitArtifacts()

        let presentation = WorkspaceMutationOutcomePresenter.presentation(for: .commitPending(
            transactionID: transactionID,
            artifacts: artifacts
        ))

        #expect(presentation.allowsDismissal == false)
        #expect(presentation.recoveryAction == .retryPendingCommit(transactionID, artifacts))
        #expect(presentation.message == "保存结果尚未确认，当前输入仍保留；请在恢复菜单中继续确认。")
    }

    @Test func journalCleanupPendingKeepsItsExactIdentityForRecovery() {
        let identity = DraftJournalIdentity(noteID: NoteID(UUID()), editSessionID: .editor(UUID()))
        let receipt = WorkspaceSaveReceipt(workspaceRevision: 4, persistedDraft: nil)

        let presentation = WorkspaceMutationOutcomePresenter.presentation(for: .committed(
            receipt,
            journal: .cleanupPending(identity: identity, step: .clear)
        ))

        #expect(presentation.allowsDismissal == false)
        #expect(presentation.recoveryAction == .retryJournalCleanup(identity, .clear, .mayDismiss))
        #expect(presentation.message == "内容已写入，但草稿清理尚未完成；请在恢复菜单中继续清理。")
    }

    @Test func failedSaveWithJournalCleanupNeverClaimsThatContentWasWritten() {
        let identity = DraftJournalIdentity(noteID: NoteID(UUID()), editSessionID: .editor(UUID()))
        let outcome = WorkspaceTransactionOutcome.notCommitted(
            transactionID: UUID(),
            journal: .cleanupPending(identity: identity, step: .unbind),
            artifacts: .init()
        )

        let presentation = WorkspaceMutationOutcomePresenter.presentation(for: outcome)

        #expect(presentation.allowsDismissal == false)
        #expect(presentation.recoveryAction == .retryJournalCleanup(
            identity,
            .unbind,
            .retain("没有保存到磁盘，已保留当前输入；请重试。")
        ))
        #expect(presentation.message == "没有保存到磁盘，已保留当前输入；草稿清理也需要继续完成。")
    }

    @Test func cleanupRetryKeepsNotCommittedAndSourceChangedEditorsOpenButMayDismissCommittedContent() throws {
        let identity = DraftJournalIdentity(noteID: NoteID(UUID()), editSessionID: .editor(UUID()))
        let cleanup = JournalResolutionStatus.cleanupPending(identity: identity, step: .unbind)
        let notCommitted = WorkspaceMutationOutcomePresenter.presentation(for: WorkspaceTransactionOutcome.notCommitted(
            transactionID: UUID(), journal: cleanup, artifacts: .init()
        ))
        let sourceChanged = WorkspaceMutationOutcomePresenter.presentation(for: .externalSourceChanged(
            transactionID: UUID(), reason: .externalBytesChanged, journal: cleanup, artifacts: .init()
        ))
        let committed = WorkspaceMutationOutcomePresenter.presentation(for: .committed(
            .init(workspaceRevision: 4, persistedDraft: nil), journal: cleanup
        ))

        let notCommittedClean = WorkspaceMutationOutcomePresenter.presentation(
            for: .clean, after: try #require(notCommitted.recoveryAction)
        )
        let sourceChangedClean = WorkspaceMutationOutcomePresenter.presentation(
            for: .clean, after: try #require(sourceChanged.recoveryAction)
        )
        let committedClean = WorkspaceMutationOutcomePresenter.presentation(
            for: .clean, after: try #require(committed.recoveryAction)
        )

        #expect(notCommittedClean.allowsDismissal == false)
        #expect(notCommittedClean.recoveryAction == nil)
        #expect(notCommittedClean.message == "没有保存到磁盘，已保留当前输入；请重试。")
        #expect(sourceChangedClean.allowsDismissal == false)
        #expect(sourceChangedClean.recoveryAction == nil)
        #expect(sourceChangedClean.message == "检测到本地数据已在外部变化，当前输入未保存；请先恢复或重新载入。")
        #expect(committedClean.allowsDismissal == true)
    }

    @Test func cleanupRetryUsesTheReturnedIdentityAndStepInsteadOfTheCapturedStep() throws {
        let previousIdentity = DraftJournalIdentity(noteID: NoteID(UUID()), editSessionID: .editor(UUID()))
        let replacementIdentity = DraftJournalIdentity(noteID: NoteID(UUID()), editSessionID: .editor(UUID()))
        let initial = WorkspaceMutationOutcomePresenter.presentation(for: WorkspaceTransactionOutcome.notCommitted(
            transactionID: UUID(),
            journal: .cleanupPending(identity: previousIdentity, step: .record),
            artifacts: .init()
        ))
        let retried = WorkspaceMutationOutcomePresenter.presentation(
            for: .cleanupPending(identity: replacementIdentity, step: .clear),
            after: try #require(initial.recoveryAction)
        )

        #expect(retried.allowsDismissal == false)
        #expect(retried.message == "没有保存到磁盘，已保留当前输入；草稿清理也需要继续完成。")
        #expect(retried.recoveryAction == .retryJournalCleanup(
            replacementIdentity,
            .clear,
            .retain("没有保存到磁盘，已保留当前输入；请重试。")
        ))
    }

    @Test func pendingAndReconciledRestorePresentTheExactRollbackTruth() {
        let transactionID = UUID()
        let pending = WorkspaceMutationOutcomePresenter.presentation(for: .commitPending(
            transactionID: transactionID,
            artifacts: .init(rollback: .nonePreviousSourceAbsent)
        ))
        #expect(pending.allowsDismissal == false)
        #expect(pending.message == "恢复结果尚未确认，当前数据是否已替换仍未知；请在恢复菜单中继续确认。")
        #expect(pending.recoveryAction == .retryPendingCommit(transactionID, .init(rollback: .nonePreviousSourceAbsent)))

        let rollbackURL = URL(fileURLWithPath: "/tmp/jelly-restore-rollback.json")
        let reconciled = WorkspaceMutationOutcomePresenter.presentation(for: .committed(
            .restore(.init(
                receipt: .init(workspaceRevision: 8, persistedDraft: nil),
                rollback: .file(rollbackURL, .init(sha256: "hash", byteCount: 4))
            )),
            journal: .clean
        ))
        #expect(reconciled.allowsDismissal == true)
        #expect(reconciled.message == "此前恢复已确认。恢复前的数据已保留在：\n/tmp/jelly-restore-rollback.json")
    }

    @Test func directPendingRestoreWithAFileReportsItsPathAndIdentity() {
        let transactionID = UUID()
        let rollbackURL = URL(fileURLWithPath: "/tmp/jelly-pending-restore-rollback.json")
        let artifacts = WorkspacePendingCommitArtifacts(rollback: .file(
            rollbackURL,
            .init(sha256: "pending-restore-hash", byteCount: 8)
        ))

        let pending = WorkspaceMutationOutcomePresenter.restorePresentation(for: .commitPending(
            transactionID: transactionID,
            artifacts: artifacts
        ))

        #expect(pending.allowsDismissal == false)
        #expect(pending.recoveryAction == .retryPendingCommit(transactionID, artifacts))
        #expect(pending.message == """
        恢复结果尚未确认，当前数据是否已替换仍未知；请在恢复菜单中继续确认。

        恢复前的数据已保留在：
        /tmp/jelly-pending-restore-rollback.json
        校验：pending-restore-hash（8 字节）
        """)
    }

    @Test func directPendingRestoreWithAnAbsentPrimaryReportsNoRollbackFile() {
        let transactionID = UUID()
        let artifacts = WorkspacePendingCommitArtifacts(rollback: .nonePreviousSourceAbsent)

        let pending = WorkspaceMutationOutcomePresenter.restorePresentation(for: .commitPending(
            transactionID: transactionID,
            artifacts: artifacts
        ))

        #expect(pending.allowsDismissal == false)
        #expect(pending.recoveryAction == .retryPendingCommit(transactionID, artifacts))
        #expect(pending.message == """
        恢复结果尚未确认，当前数据是否已替换仍未知；请在恢复菜单中继续确认。

        恢复前没有可回滚的主数据文件。
        """)
    }

    @Test func directRestoreOutcomesKeepRecoveryArtifactsAndNeverUseEditSaveWording() {
        let transactionID = UUID()
        let rollbackURL = URL(fileURLWithPath: "/tmp/jelly-direct-restore-rollback.json")
        let fileArtifacts = WorkspacePendingCommitArtifacts(
            rollback: .file(rollbackURL, .init(sha256: "restore-hash", byteCount: 8))
        )
        let absentArtifacts = WorkspacePendingCommitArtifacts(rollback: .nonePreviousSourceAbsent)

        let restored = WorkspaceMutationOutcomePresenter.restorePresentation(for: .restored(.init(
            receipt: .init(workspaceRevision: 3, persistedDraft: nil),
            rollback: .file(rollbackURL, .init(sha256: "restore-hash", byteCount: 8))
        )))
        #expect(restored.allowsDismissal)
        #expect(restored.message == "恢复完成。恢复前的数据已保留在：\n/tmp/jelly-direct-restore-rollback.json")

        let notCommitted = WorkspaceMutationOutcomePresenter.restorePresentation(for: .notCommitted(
            transactionID: transactionID, journal: .clean, artifacts: fileArtifacts
        ))
        #expect(notCommitted.allowsDismissal == false)
        #expect(notCommitted.message == "恢复没有提交，当前数据没有被替换。恢复前的数据已保留在：\n/tmp/jelly-direct-restore-rollback.json")

        let sourceChanged = WorkspaceMutationOutcomePresenter.restorePresentation(for: .externalSourceChanged(
            transactionID: transactionID, reason: .externalBytesChanged, journal: .clean, artifacts: absentArtifacts
        ))
        #expect(sourceChanged.allowsDismissal == false)
        #expect(sourceChanged.message == "恢复期间本地数据发生变化，当前数据未覆盖外部内容。恢复前没有可回滚的主数据文件。")

        let blocked = WorkspaceMutationOutcomePresenter.restorePresentation(for: .persistenceBlocked(
            transactionID: nil, reason: .unreadablePrimary, journal: .clean
        ))
        #expect(blocked.allowsDismissal == false)
        #expect(blocked.message == "恢复未开始：本地数据暂时无法读取，原始字节也不可用。")
        #expect(WorkspaceMutationOutcomePresenter.restorePresentation(for: .persistenceBlocked(
            transactionID: nil, reason: .opaqueInvalidPrimary, journal: .clean
        )).message == "恢复未开始：本地数据无法解析；请先导出原始恢复副本。")
        #expect(WorkspaceMutationOutcomePresenter.restorePresentation(for: .persistenceBlocked(
            transactionID: nil, reason: .loadFailed, journal: .clean
        )).message == "恢复未开始：本地数据加载失败；请先恢复或重新载入。")
        let conflict = WorkspaceMutationOutcomePresenter.restorePresentation(for: .conflict(.noteMissing(NoteID(UUID()))))
        #expect(conflict.allowsDismissal == false)
        #expect(conflict.message == "恢复与当前工作空间状态冲突，当前数据没有被替换。")
        #expect(WorkspaceMutationOutcomePresenter.restorePresentation(for: .draftSuperseded).message ==
            "已有更新的编辑版本，恢复没有覆盖它。")
        #expect(WorkspaceMutationOutcomePresenter.restorePresentation(for: .noChange(.identical, journal: .clean)).message ==
            "恢复内容与当前工作空间相同，当前数据没有被替换。")
    }
}
