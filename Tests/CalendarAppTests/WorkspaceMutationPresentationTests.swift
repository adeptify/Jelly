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
}
