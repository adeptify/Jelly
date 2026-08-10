import CalendarPersistence
import Foundation
import WorkspaceDomain

/// The single policy boundary between a typed Workspace transaction result and
/// a calendar editor's visible state.  Callers must not infer success from the
/// absence of an error: several persistence outcomes are non-throwing but must
/// keep the user's draft open and expose the exact recovery token.
enum WorkspaceCleanupRecoveryDisposition: Equatable {
    /// The main transaction has completed.  A clean journal retry may now
    /// dismiss the UI that initiated it.
    case mayDismiss
    /// The main transaction did not complete.  Journal cleanup only releases
    /// bookkeeping and must not turn a failed edit into a saved edit.
    case retain(String)
}

enum WorkspaceRecoveryAction: Equatable {
    case retryPendingCommit(UUID, WorkspacePendingCommitArtifacts)
    case retryJournalCleanup(DraftJournalIdentity, JournalCleanupStep, WorkspaceCleanupRecoveryDisposition)
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
        case let .retryJournalCleanup(identity, _, disposition):
            return presentation(for: await store.retryJournalCleanup(identity), after: disposition)
        }
    }

    static func presentation(for outcome: WorkspaceTransactionOutcome) -> WorkspaceMutationPresentation {
        switch outcome {
        case let .committed(_, journal), let .noChange(_, journal):
            return presentation(for: journal, after: .mayDismiss)
        case let .restored(outcome):
            return .init(
                allowsDismissal: true,
                message: "恢复完成。\(rollbackMessage(for: outcome.rollback))",
                recoveryAction: nil
            )
        case .conflict:
            return .retain("当前数据已被其他操作改变，未覆盖你的输入；请检查后重试。")
        case .draftSuperseded:
            return .retain("已有更新的编辑版本，当前输入未覆盖它。")
        case let .commitPending(transactionID, artifacts):
            let message = artifacts.rollback == nil
                ? "保存结果尚未确认，当前输入仍保留；请在恢复菜单中继续确认。"
                : "恢复结果尚未确认，当前数据是否已替换仍未知；请在恢复菜单中继续确认。"
            return .retain(
                message,
                recoveryAction: .retryPendingCommit(transactionID, artifacts)
            )
        case let .notCommitted(_, journal, _):
            return failedSavePresentation(
                journal: journal,
                message: "没有保存到磁盘，已保留当前输入；请重试。"
            )
        case let .externalSourceChanged(_, _, journal, _):
            return failedSavePresentation(
                journal: journal,
                message: "检测到本地数据已在外部变化，当前输入未保存；请先恢复或重新载入。"
            )
        case let .persistenceBlocked(_, reason, journal):
            let message = switch reason {
            case .opaqueInvalidPrimary:
                "本地数据无法解析，当前输入未保存；请先导出原始恢复副本。"
            case .unreadablePrimary:
                "本地数据暂时无法读取，原始字节也不可用；当前输入未保存。"
            case .loadFailed:
                "本地数据加载失败，当前输入未保存；请先恢复或重新载入。"
            }
            return failedSavePresentation(journal: journal, message: message)
        }
    }

    /// Restore is a replacement operation, so terminal failures must never
    /// borrow the editor's "save" wording. The rollback artifact is part of
    /// the user-visible truth of that replacement attempt.
    static func restorePresentation(for outcome: WorkspaceTransactionOutcome) -> WorkspaceMutationPresentation {
        switch outcome {
        case let .restored(restored):
            return .init(
                allowsDismissal: true,
                message: "恢复完成。\(rollbackMessage(for: restored.rollback))",
                recoveryAction: nil
            )
        case let .commitPending(transactionID, artifacts):
            return .retain(
                "恢复结果尚未确认，当前数据是否已替换仍未知；请在恢复菜单中继续确认。\n\n\(pendingRollbackMessage(for: artifacts.rollback))",
                recoveryAction: .retryPendingCommit(transactionID, artifacts)
            )
        case let .notCommitted(_, journal, artifacts):
            return failedSavePresentation(
                journal: journal,
                message: "恢复没有提交，当前数据没有被替换。\(rollbackMessage(for: artifacts.rollback))"
            )
        case let .externalSourceChanged(_, _, journal, artifacts):
            return failedSavePresentation(
                journal: journal,
                message: "恢复期间本地数据发生变化，当前数据未覆盖外部内容。\(rollbackMessage(for: artifacts.rollback))"
            )
        case let .persistenceBlocked(_, reason, journal):
            let message = switch reason {
            case .opaqueInvalidPrimary:
                "恢复未开始：本地数据无法解析；请先导出原始恢复副本。"
            case .unreadablePrimary:
                "恢复未开始：本地数据暂时无法读取，原始字节也不可用。"
            case .loadFailed:
                "恢复未开始：本地数据加载失败；请先恢复或重新载入。"
            }
            return failedSavePresentation(journal: journal, message: message)
        case .conflict:
            return .retain("恢复与当前工作空间状态冲突，当前数据没有被替换。")
        case .draftSuperseded:
            return .retain("已有更新的编辑版本，恢复没有覆盖它。")
        case .committed, .noChange:
            return .retain("恢复内容与当前工作空间相同，当前数据没有被替换。")
        }
    }

    static func presentation(for outcome: PendingCommitRetryOutcome) -> WorkspaceMutationPresentation {
        switch outcome {
        case let .committed(operation, journal):
            switch operation {
            case .save:
                return presentation(
                    for: journal,
                    after: .mayDismiss,
                    successMessage: "此前保存已确认。",
                    cleanMessage: "此前保存已确认。"
                )
            case let .restore(outcome):
                let message = "此前恢复已确认。\(rollbackMessage(for: outcome.rollback))"
                return presentation(
                    for: journal,
                    after: .mayDismiss,
                    successMessage: message,
                    cleanMessage: message
                )
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

    static func presentation(
        for status: JournalResolutionStatus,
        after disposition: WorkspaceCleanupRecoveryDisposition,
        successMessage: String = "内容已写入，但草稿清理尚未完成；请在恢复菜单中继续清理。",
        cleanMessage: String? = nil
    ) -> WorkspaceMutationPresentation {
        switch status {
        case .clean:
            switch disposition {
            case .mayDismiss:
                return .init(allowsDismissal: true, message: cleanMessage, recoveryAction: nil)
            case let .retain(message):
                return .retain(message)
            }
        case let .cleanupPending(identity, step):
            let message: String
            switch disposition {
            case .mayDismiss:
                message = successMessage
            case let .retain(terminalMessage):
                message = messageWithCleanupPending(terminalMessage)
            }
            return .retain(
                message,
                recoveryAction: .retryJournalCleanup(identity, step, disposition)
            )
        }
    }

    /// Reuse the disposition attached to the exact visible recovery action.
    /// This is intentionally separate from a bare `JournalResolutionStatus`:
    /// `.clean` only means cleanup is clean, not that the original mutation
    /// saved successfully.
    static func presentation(
        for status: JournalResolutionStatus,
        after action: WorkspaceRecoveryAction
    ) -> WorkspaceMutationPresentation {
        guard case let .retryJournalCleanup(_, _, disposition) = action else {
            return .retain("恢复操作类型不匹配，当前输入仍保留。", recoveryAction: action)
        }
        return presentation(for: status, after: disposition)
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
            messageWithCleanupPending(message),
            recoveryAction: .retryJournalCleanup(identity, step, .retain(message))
        )
    }

    private static func messageWithCleanupPending(_ terminalMessage: String) -> String {
        let replacement = terminalMessage.replacingOccurrences(
            of: "；请重试。", with: "；草稿清理也需要继续完成。"
        )
        return replacement == terminalMessage
            ? "\(terminalMessage) 草稿清理也需要继续完成。"
            : replacement
    }

    private static func rollbackMessage(for rollback: WorkspaceRollbackArtifact?) -> String {
        guard let rollback else { return "恢复前的数据是否已保留仍未知。" }
        return rollbackMessage(for: rollback)
    }

    private static func rollbackMessage(for rollback: WorkspaceRollbackArtifact) -> String {
        return switch rollback {
        case let .file(url, _):
            "恢复前的数据已保留在：\n\(url.path)"
        case .nonePreviousSourceAbsent:
            "恢复前没有可回滚的主数据文件。"
        }
    }

    private static func pendingRollbackMessage(for rollback: WorkspaceRollbackArtifact?) -> String {
        guard let rollback else { return "恢复前的数据是否已保留仍未知。" }
        return switch rollback {
        case let .file(url, identity):
            "恢复前的数据已保留在：\n\(url.path)\n校验：\(identity.sha256)（\(identity.byteCount) 字节）"
        case .nonePreviousSourceAbsent:
            "恢复前没有可回滚的主数据文件。"
        }
    }
}
