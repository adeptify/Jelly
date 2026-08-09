import CalendarPersistence
import Foundation
import WorkspaceDomain

/// The single policy boundary between a typed Workspace transaction result and
/// a calendar editor's visible state.  Callers must not infer success from the
/// absence of an error: several persistence outcomes are non-throwing but must
/// keep the user's draft open and expose the exact recovery token.
enum WorkspaceRecoveryAction: Equatable {
    case retryPendingCommit(UUID, WorkspacePendingCommitArtifacts)
    case retryJournalCleanup(DraftJournalIdentity, JournalCleanupStep)
}

struct WorkspaceMutationPresentation: Equatable {
    let allowsDismissal: Bool
    let message: String?
    let recoveryAction: WorkspaceRecoveryAction?

    static let saved = WorkspaceMutationPresentation(
        allowsDismissal: true,
        message: nil,
        recoveryAction: nil
    )

    static func retain(
        _ message: String,
        recoveryAction: WorkspaceRecoveryAction? = nil
    ) -> WorkspaceMutationPresentation {
        .init(allowsDismissal: false, message: message, recoveryAction: recoveryAction)
    }
}

enum WorkspaceMutationOutcomePresenter {
    @MainActor
    static func retry(
        _ action: WorkspaceRecoveryAction,
        in store: WorkspaceStore
    ) async -> WorkspaceMutationPresentation {
        switch action {
        case let .retryPendingCommit(transactionID, _):
            do {
                return presentation(for: try await store.retryPendingCommit(transactionID))
            } catch {
                return .retain(message(for: error), recoveryAction: action)
            }
        case let .retryJournalCleanup(identity, _):
            return presentation(for: await store.retryJournalCleanup(identity))
        }
    }

    static func presentation(for outcome: WorkspaceTransactionOutcome) -> WorkspaceMutationPresentation {
        switch outcome {
        case let .committed(_, journal), let .noChange(_, journal):
            return presentation(for: journal)
        case .restored:
            return .saved
        case .conflict:
            return .retain("当前数据已被其他操作改变，未覆盖你的输入；请检查后重试。")
        case .draftSuperseded:
            return .retain("已有更新的编辑版本，当前输入未覆盖它。")
        case let .commitPending(transactionID, artifacts):
            return .retain(
                "保存结果尚未确认，当前输入仍保留；请在恢复菜单中继续确认。",
                recoveryAction: .retryPendingCommit(transactionID, artifacts)
            )
        case let .notCommitted(_, journal, _):
            return failedSavePresentation(
                journal: journal,
                message: "没有保存到磁盘，已保留当前输入；请重试。"
            )
        case .externalSourceChanged:
            return .retain("检测到本地数据已在外部变化，当前输入未保存；请先恢复或重新载入。")
        case .persistenceBlocked:
            return .retain("本地数据暂时无法安全读取，当前输入未保存；请先导出原始恢复副本。")
        }
    }

    static func presentation(for outcome: PendingCommitRetryOutcome) -> WorkspaceMutationPresentation {
        switch outcome {
        case let .committed(operation, journal):
            let settled = presentation(for: journal)
            guard settled.recoveryAction == nil else { return settled }
            switch operation {
            case .save:
                return .init(allowsDismissal: true, message: "此前保存已确认。", recoveryAction: nil)
            case .restore:
                return .init(allowsDismissal: true, message: "此前恢复已确认。", recoveryAction: nil)
            }
        case let .notCommitted(_, journal, _):
            return failedSavePresentation(
                journal: journal,
                message: "已确认此前保存没有写入磁盘，当前输入仍保留。"
            )
        case let .sourceChanged(_, journal, _):
            return failedSavePresentation(
                journal: journal,
                message: "保存期间本地数据发生变化，当前输入未覆盖外部内容。"
            )
        case let .stillPending(transactionID, artifacts):
            return .retain(
                "保存结果仍未确认，当前输入仍保留；请稍后再次确认。",
                recoveryAction: .retryPendingCommit(transactionID, artifacts)
            )
        }
    }

    static func presentation(for status: JournalResolutionStatus) -> WorkspaceMutationPresentation {
        switch status {
        case .clean:
            return .saved
        case let .cleanupPending(identity, step):
            return .retain(
                "内容已写入，但草稿清理尚未完成；请在恢复菜单中继续清理。",
                recoveryAction: .retryJournalCleanup(identity, step)
            )
        }
    }

    static func message(for error: Error) -> String {
        switch error {
        case WorkspaceStoreError.frozen:
            "日历当前不能安全写入，当前输入未保存。"
        case WorkspaceStoreError.nothingToUndo, WorkspaceStoreError.nothingToRedo:
            "当前没有可执行的撤销操作。"
        case WorkspacePersistenceError.invalidDocument, WorkspacePersistenceError.atomicWriteFailed,
             WorkspacePersistenceError.commitUncertain, WorkspacePersistenceError.invalidDraftContext:
            "保存失败，当前输入仍保留；请重试。"
        default:
            "操作没有完成，当前输入仍保留；请重试。"
        }
    }

    private static func failedSavePresentation(
        journal: JournalResolutionStatus,
        message: String
    ) -> WorkspaceMutationPresentation {
        guard case let .cleanupPending(identity, step) = journal else {
            return .retain(message)
        }
        return .retain(
            message.replacingOccurrences(of: "；请重试。", with: "；草稿清理也需要继续完成。"),
            recoveryAction: .retryJournalCleanup(identity, step)
        )
    }
}
