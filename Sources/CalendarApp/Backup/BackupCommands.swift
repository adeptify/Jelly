import AppKit
import CalendarDomain
import CalendarPersistence
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WorkspaceDomain

@MainActor
struct BackupCommands: Commands {
    let store: WorkspaceStore
    let rollbackDirectory: URL

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button("导出备份…", action: exportBackup)
                .disabled(store.phase != .ready)
            Button("恢复备份…", action: chooseBackupToRestore)
                .disabled(!canRestore)
            if case .exportRawRecoveryCopy? = BackupRecoveryPolicy.actions(for: store.phase).first {
                Divider()
                Button("导出原始恢复副本…", action: exportRawRecoveryCopy)
            }
            if case let .retryPendingCommit(transactionID)? = BackupRecoveryPolicy.actions(for: store.phase).first {
                Divider()
                Button("继续确认未完成保存", action: { retryPendingCommit(transactionID) })
            }
            if case let .retryJournalCleanup(identity, step)? = BackupRecoveryPolicy.actions(for: store.phase).first {
                Divider()
                Button("继续清理草稿记录", action: { retryJournalCleanup(identity, step: step) })
            }
        }
    }

    private var canRestore: Bool {
        BackupRecoveryPolicy.allowsRestore(from: store.phase)
    }

    private func exportBackup() {
        guard store.phase == .ready else { return }
        let panel = NSSavePanel()
        panel.title = "导出 Jelly 备份"
        panel.message = "导出可用于本应用恢复的完整工作空间备份。"
        panel.nameFieldStringValue = "Jelly备份-\(backupTimestamp()).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { @MainActor in
            do {
                try await store.exportBackup(to: destination)
                showInformation(title: "备份已导出", message: "已保存到：\n\(destination.path)")
            } catch {
                showError(title: "无法导出备份", message: "备份没有写入。请确认目标位置可写后重试。")
            }
        }
    }

    private func exportRawRecoveryCopy() {
        guard BackupRecoveryPolicy.actions(for: store.phase).contains(.exportRawRecoveryCopy) else { return }
        let panel = NSSavePanel()
        panel.title = "导出 Jelly 原始恢复副本"
        panel.message = "此副本保留当前无法解析或读取的原始数据，仅用于后续恢复分析。"
        panel.nameFieldStringValue = "Jelly原始恢复副本-\(backupTimestamp()).bin"
        panel.allowedContentTypes = [.data]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { @MainActor in
            do {
                let artifact = try await store.exportRawRecoveryCopy(to: destination)
                showInformation(
                    title: "原始恢复副本已导出",
                    message: "已保存到：\n\(destination.path)\n\n校验：\(artifact.identity.sha256)（\(artifact.identity.byteCount) 字节）"
                )
            } catch {
                showError(
                    title: "无法导出原始恢复副本",
                    message: "原始数据没有写入目标位置。请确认目标位置可写后重试。"
                )
            }
        }
    }

    private func retryPendingCommit(_ transactionID: UUID) {
        Task { @MainActor in
            do {
                let outcome = try await store.retryPendingCommit(transactionID)
                let message = BackupRecoveryPolicy.message(for: outcome) + artifactMessage(for: outcome)
                switch outcome {
                case .committed:
                    showInformation(title: "保存确认结果", message: message)
                case .notCommitted, .sourceChanged, .stillPending:
                    showError(title: "保存确认结果", message: message)
                }
            } catch {
                showError(
                    title: "无法确认此前保存",
                    message: "未能继续确认这次保存；当前数据没有被新的操作覆盖。"
                )
            }
        }
    }

    private func retryJournalCleanup(_ identity: DraftJournalIdentity, step: JournalCleanupStep) {
        Task { @MainActor in
            let status = await store.retryJournalCleanup(identity)
            let message = BackupRecoveryPolicy.message(for: status)
            switch status {
            case .clean:
                showInformation(title: "草稿清理结果", message: message)
            case .cleanupPending:
                showError(
                    title: "草稿清理结果",
                    message: "\(message)\n\n记录：\(identity.noteID.rawValue.uuidString)，步骤：\(step.displayName)。"
                )
            }
        }
    }

    private func chooseBackupToRestore() {
        guard canRestore else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 Jelly 备份"
        panel.message = "选择此前由 Jelly 导出的备份文件。"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let source = panel.url else { return }
        Task { @MainActor in await inspectConfirmAndRestore(source: source) }
    }

    private func inspectConfirmAndRestore(source: URL) async {
        let preview: WorkspaceRestorePreview
        do {
            preview = try await store.inspectRestoreSource(at: source)
        } catch {
            showError(title: "备份文件无法恢复", message: "该文件不是有效的 Jelly 备份，当前数据没有被修改。")
            return
        }
        guard confirmRestore(preview.loadResult.state.calendar) else { return }
        do {
            let outcome = try await store.restore(preview, rollbackDirectoryURL: rollbackDirectory)
            switch outcome {
            case let .restored(restored):
                showInformation(title: "备份已恢复", message: rollbackMessage(for: restored.rollback))
            default:
                let presentation = WorkspaceMutationOutcomePresenter.presentation(for: outcome)
                showError(
                    title: "恢复确认结果",
                    message: presentation.message ?? "恢复没有完成；当前数据是否已替换尚未确认。"
                )
            }
        } catch {
            showError(title: "恢复备份失败", message: "当前本地文件没有被替换。请检查备份和磁盘空间后重试。")
        }
    }

    private func confirmRestore(_ restored: CalendarState) -> Bool {
        let alert = NSAlert()
        alert.messageText = "确认恢复备份？"
        let currentSummary = store.phase == .ready
            ? BackupStateSummary(state: store.calendarState).description
            : "当前数据需要恢复或修复"
        alert.informativeText = """
        \(currentSummary) → \(BackupStateSummary(state: restored).description)

        恢复会替换完整当前工作空间，包括日历、分类、笔记、灵感及其关系。恢复前内容会由工作空间恢复流程保留为回滚证据。
        """
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func rollbackMessage(for artifact: WorkspaceRollbackArtifact) -> String {
        switch artifact {
        case let .file(url, _): "恢复前的数据已保留在：\n\(url.path)"
        case .nonePreviousSourceAbsent: "恢复完成；此前没有可回滚的主数据文件。"
        }
    }

    private func artifactMessage(for outcome: PendingCommitRetryOutcome) -> String {
        let artifacts: WorkspacePendingCommitArtifacts?
        switch outcome {
        case .committed:
            artifacts = nil
        case let .notCommitted(_, _, value), let .sourceChanged(_, _, value), let .stillPending(_, value):
            artifacts = value
        }
        guard let rollback = artifacts?.rollback else { return "" }
        return "\n\n\(rollbackMessage(for: rollback))"
    }

    private func backupTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func showInformation(title: String, message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.alertStyle = .informational; alert.addButton(withTitle: "好"); alert.runModal()
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.alertStyle = .warning; alert.addButton(withTitle: "知道了"); alert.runModal()
    }
}

private extension JournalCleanupStep {
    var displayName: String {
        switch self {
        case .record: "记录保存回执"
        case .acknowledge: "确认草稿回执"
        case .unbind: "解除草稿绑定"
        case .clear: "清除草稿记录"
        }
    }
}

private struct BackupStateSummary {
    let categories: Int
    let items: Int
    let series: Int

    init(state: CalendarState) {
        categories = state.categories.count
        items = state.items.count
        series = state.recurrence.series.count
    }

    var description: String { "分类 \(categories) 个，事项 \(items) 项，重复系列 \(series) 个" }
}
