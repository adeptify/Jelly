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
}

enum BackupRecoveryPolicy {
    /// Keep the command's enablement identical to `WorkspaceStore.restore`.
    /// A failure phase must not advertise a restore that the store will reject
    /// before it can inspect the selected backup.
    static func allowsRestore(from phase: WorkspaceStorePhase) -> Bool {
        switch phase {
        case .ready, .externalSourceChanged, .opaquePrimaryLoadFailed, .needsRelationshipRepair:
            true
        case .notLoaded, .loading, .mutating, .parkedCommitUncertain, .parkedJournalCleanup,
             .loadFailed, .unreadablePrimaryLoadFailed:
            false
        }
    }

    static func actions(for phase: WorkspaceStorePhase) -> [BackupRecoveryAction] {
        switch phase {
        case let .parkedCommitUncertain(transactionID):
            [.retryPendingCommit(transactionID)]
        case let .parkedJournalCleanup(identity, step):
            [.retryJournalCleanup(identity, step)]
        case .opaquePrimaryLoadFailed:
            [.exportRawRecoveryCopy]
        case .notLoaded, .loading, .ready, .mutating, .needsRelationshipRepair,
             .externalSourceChanged, .loadFailed, .unreadablePrimaryLoadFailed:
            []
        }
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

    static func message(for status: JournalResolutionStatus) -> String {
        switch status {
        case .clean:
            "草稿清理已完成。"
        case .cleanupPending:
            "草稿清理仍未完成；请稍后继续清理。"
        }
    }

    static func cleanupDetail(for status: JournalResolutionStatus) -> String? {
        guard case let .cleanupPending(identity, step) = status else { return nil }
        return "记录：\(identity.noteID.rawValue.uuidString)，步骤：\(cleanupStepName(step))。"
    }

    private static func cleanupSuffix(for status: JournalResolutionStatus) -> String {
        guard case .cleanupPending = status else { return "" }
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
        }
    }
}
