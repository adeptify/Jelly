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
        #expect(presentation.recoveryAction == .retryJournalCleanup(identity, .clear))
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
        #expect(presentation.recoveryAction == .retryJournalCleanup(identity, .unbind))
        #expect(presentation.message == "没有保存到磁盘，已保留当前输入；草稿清理也需要继续完成。")
    }
}
