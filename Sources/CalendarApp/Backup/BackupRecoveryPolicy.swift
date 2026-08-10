import CalendarPersistence
import Foundation
import WorkspaceDomain

/// Backup commands are the durable recovery surface.  The policy deliberately
/// carries the Store-issued IDs forward rather than recreating an operation
/// from UI state, so retry always reconciles the exact parked transaction.
enum BackupRecoveryAction: Equatable {
    case exportRawRecoveryCopy
    case retryPendingCommit(UUID)
    case retryJournalCleanup(DraftJournalIdentity, JournalCleanupStep)
    case draftRecoveryRequired([DraftRecoveryToken])
}

enum BackupRecoveryPolicy {
    /// Keep the command's enablement identical to `WorkspaceStore.restore`.
    /// A failure phase must not advertise a restore that the store will reject
    /// before it can inspect the selected backup.
    static func allowsRestore(
        from phase: WorkspaceStorePhase,
        journalReconciliationRequired: Bool
    ) -> Bool {
        guard journalReconciliationRequired == false else { return false }
        return switch phase {
        case .ready, .externalSourceChanged, .opaquePrimaryLoadFailed, .needsRelationshipRepair:
            true
        case .notLoaded, .loading, .mutating, .resolvingDraftRecovery, .reconcilingDraftRecovery, .parkedCommitUncertain, .parkedJournalCleanup,
             .needsDraftRecovery, .loadFailed, .unreadablePrimaryLoadFailed:
            false
        }
    }

    static func actions(
        for phase: WorkspaceStorePhase,
        rawRecoveryAvailable: Bool = false
    ) -> [BackupRecoveryAction] {
        var actions: [BackupRecoveryAction] = switch phase {
        case let .parkedCommitUncertain(transactionID):
            [.retryPendingCommit(transactionID)]
        case let .parkedJournalCleanup(identity, step):
            [.retryJournalCleanup(identity, step)]
        case let .needsDraftRecovery(candidates):
            [.draftRecoveryRequired(candidates.map(\.token))]
        case .notLoaded, .loading, .ready, .mutating, .resolvingDraftRecovery, .reconcilingDraftRecovery, .needsRelationshipRepair,
             .externalSourceChanged, .opaquePrimaryLoadFailed, .loadFailed, .unreadablePrimaryLoadFailed:
            []
        }
        if case .parkedCommitUncertain = phase { return actions }
        if rawRecoveryAvailable, actions.contains(.exportRawRecoveryCopy) == false {
            actions.append(.exportRawRecoveryCopy)
        }
        return actions
    }

    static func allowsReadOnlyBackup(from phase: WorkspaceStorePhase) -> Bool {
        switch phase {
        case .ready, .needsDraftRecovery:
            true
        case .notLoaded, .loading, .mutating, .resolvingDraftRecovery, .reconcilingDraftRecovery, .parkedCommitUncertain, .parkedJournalCleanup,
             .needsRelationshipRepair, .externalSourceChanged, .opaquePrimaryLoadFailed,
             .unreadablePrimaryLoadFailed, .loadFailed:
            false
        }
    }

    static func pendingCommitMenuTitle(for phase: WorkspaceStorePhase) -> String? {
        guard case .parkedCommitUncertain = phase else { return nil }
        return "继续确认未完成操作"
    }

    static func message(for outcome: PendingCommitRetryOutcome) -> String {
        switch outcome {
        case let .committed(operation, journal):
            let suffix = cleanupSuffix(for: journal)
            switch operation {
            case .save: return "此前保存已确认。\(suffix)"
            case let .restore(outcome):
                return "此前恢复已确认。\(rollbackMessage(for: outcome.rollback))\(suffix)"
            }
        case let .notCommitted(_, journal, artifacts):
            if let rollback = artifacts.rollback {
                return "已确认此前恢复没有替换当前数据。\(rollbackMessage(for: rollback))\(cleanupSuffix(for: journal))"
            }
            return "已确认此前保存没有写入磁盘，当前输入仍保留。\(cleanupSuffix(for: journal))"
        case let .sourceChanged(_, journal, artifacts):
            if let rollback = artifacts.rollback {
                return "恢复期间本地数据发生变化，当前数据未覆盖外部内容。\(rollbackMessage(for: rollback))\(cleanupSuffix(for: journal))"
            }
            return "保存期间本地数据发生变化，当前输入未覆盖外部内容。\(cleanupSuffix(for: journal))"
        case let .stillPending(_, artifacts):
            if let rollback = artifacts.rollback {
                return "恢复结果仍未确认，当前数据是否已替换仍未知；请稍后再次确认。\(rollbackMessage(for: rollback))"
            }
            return "保存结果仍未确认；请稍后再次确认。"
        }
    }

    static func retryTitle(for outcome: PendingCommitRetryOutcome) -> String {
        switch outcome {
        case let .committed(operation, _):
            if case .restore = operation { return "恢复确认结果" }
            return "保存确认结果"
        case let .notCommitted(_, _, artifacts), let .sourceChanged(_, _, artifacts),
             let .stillPending(_, artifacts):
            return artifacts.rollback == nil ? "保存确认结果" : "恢复确认结果"
        }
    }

    static func message(
        for status: JournalResolutionStatus,
        completing step: JournalCleanupStep? = nil
    ) -> String {
        switch status {
        case .clean:
            return step.map(isRecoveryStep) == true
                ? "草稿恢复记录已处理。"
                : "草稿清理已完成。"
        case let .cleanupPending(_, step) where isRecoveryStep(step):
            return "草稿恢复记录仍未丢弃；请稍后继续处理。"
        case .cleanupPending:
            return "草稿清理仍未完成；请稍后继续清理。"
        }
    }

    static func cleanupDetail(for status: JournalResolutionStatus) -> String? {
        guard case let .cleanupPending(identity, step) = status else { return nil }
        return "记录：\(identity.noteID.rawValue.uuidString)，步骤：\(cleanupStepName(step))。"
    }

    private static func cleanupSuffix(for status: JournalResolutionStatus) -> String {
        guard case let .cleanupPending(_, step) = status else { return "" }
        if isRecoveryStep(step) { return " 草稿恢复记录仍未丢弃，请在草稿恢复流程中继续处理。" }
        return " 草稿清理仍未完成，请继续清理。"
    }

    private static func rollbackMessage(for rollback: WorkspaceRollbackArtifact) -> String {
        switch rollback {
        case let .file(url, _): "恢复前的数据已保留在：\n\(url.path)"
        case .nonePreviousSourceAbsent: "恢复前没有可回滚的主数据文件。"
        }
    }

    private static func cleanupStepName(_ step: JournalCleanupStep) -> String {
        switch step {
        case .record: "记录保存回执"
        case .acknowledge: "确认草稿回执"
        case .unbind: "解除草稿绑定"
        case .clear: "清除草稿记录"
        case .discardRecovery: "丢弃已审阅草稿恢复记录"
        case .markRecoveryCompletion: "记录草稿恢复主保存结果"
        case .discardRecoveryCompletion: "丢弃已完成草稿恢复记录"
        case .abandonRecoveryCompletion: "释放未完成草稿恢复记录"
        }
    }

    private static func isRecoveryStep(_ step: JournalCleanupStep) -> Bool {
        switch step {
        case .discardRecovery, .markRecoveryCompletion, .discardRecoveryCompletion, .abandonRecoveryCompletion:
            true
        case .record, .acknowledge, .unbind, .clear:
            false
        }
    }
}
