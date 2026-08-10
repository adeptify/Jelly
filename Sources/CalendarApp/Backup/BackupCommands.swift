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
                .disabled(!BackupRecoveryPolicy.allowsReadOnlyBackup(from: store.phase))
            if canRestore {
                Button("恢复备份…", action: chooseBackupToRestore)
            }
            if recoveryActions.contains(.exportRawRecoveryCopy) {
                Divider()
                Button("导出原始恢复副本…", action: exportRawRecoveryCopy)
            }
            if let transactionID = pendingCommitTransactionID,
               let title = BackupRecoveryPolicy.pendingCommitMenuTitle(for: store.phase) {
                Divider()
                Button(title, action: { retryPendingCommit(transactionID) })
            }
            if let (identity, step) = journalCleanupAction {
                Divider()
                Button(journalCleanupTitle(for: step), action: { retryJournalCleanup(identity, step: step) })
            }
            if let tokens = draftRecoveryTokens {
                Divider()
                ForEach(Array(tokens.enumerated()), id: \.element) { offset, token in
                    Button("导出草稿恢复副本 \(offset + 1)…", action: {
                        exportDraftRecoveryMarkdown(token, ordinal: offset + 1)
                    })
                }
                Button("需先处理草稿恢复", action: { showDraftRecoveryRequired(tokens) })
            }
        }
    }

    private var canRestore: Bool {
        BackupRecoveryPolicy.allowsRestore(
            from: store.phase,
            journalReconciliationRequired: store.hasUnresolvedJournalReconciliation
        )
    }

    private var recoveryActions: [BackupRecoveryAction] {
        BackupRecoveryPolicy.actions(
            for: store.phase,
            rawRecoveryAvailable: store.hasRawRecoverySource
        )
    }

    private var pendingCommitTransactionID: UUID? {
        for case let .retryPendingCommit(transactionID) in recoveryActions {
            return transactionID
        }
        return nil
    }

    private var journalCleanupAction: (DraftJournalIdentity, JournalCleanupStep)? {
        for case let .retryJournalCleanup(identity, step) in recoveryActions {
            return (identity, step)
        }
        return nil
    }

    private var draftRecoveryTokens: [DraftRecoveryToken]? {
        for case let .draftRecoveryRequired(tokens) in recoveryActions {
            return tokens
        }
        return nil
    }

    private func exportBackup() {
        guard BackupRecoveryPolicy.allowsReadOnlyBackup(from: store.phase) else { return }
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
        guard recoveryActions.contains(.exportRawRecoveryCopy) else { return }
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

    private func exportDraftRecoveryMarkdown(_ token: DraftRecoveryToken, ordinal: Int) {
        guard case .needsDraftRecovery = store.phase else { return }
        let panel = NSSavePanel()
        panel.title = "导出草稿恢复副本"
        panel.message = "导出当前第 \(ordinal) 条草稿恢复记录的只读 Markdown 副本；这不会确认、保存或丢弃该记录。"
        panel.nameFieldStringValue = "Jelly草稿恢复-\(ordinal)-\(backupTimestamp()).md"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let markdown = try store.draftRecoveryMarkdown(token)
            let data = Data(markdown.utf8)
            try FoundationAtomicFileWriter().replaceAtomically(data: data, at: destination)
            guard try Data(contentsOf: destination) == data else {
                throw WorkspacePersistenceError.atomicWriteFailed
            }
            showInformation(title: "草稿恢复副本已导出", message: "已保存到：\n\(destination.path)\n\n恢复记录仍未被确认或丢弃。")
        } catch {
            showError(title: "无法导出草稿恢复副本", message: "副本没有写入，恢复记录保持不变。请确认目标位置可写后重试。")
        }
    }

    private func retryPendingCommit(_ transactionID: UUID) {
        Task { @MainActor in
            do {
                let outcome = try await store.retryPendingCommit(transactionID)
                let message = BackupRecoveryPolicy.message(for: outcome)
                let title = BackupRecoveryPolicy.retryTitle(for: outcome)
                switch outcome {
                case .committed:
                    showInformation(title: title, message: message)
                case .notCommitted, .sourceChanged, .stillPending:
                    showError(title: title, message: message)
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
            let message = BackupRecoveryPolicy.message(for: status, completing: step)
            let title = journalCleanupTitle(for: step)
            switch status {
            case .clean:
                showInformation(title: title, message: message)
            case .cleanupPending:
                let detail = BackupRecoveryPolicy.cleanupDetail(for: status) ?? ""
                showError(
                    title: title,
                    message: "\(message)\n\n\(detail)"
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
                let presentation = WorkspaceMutationOutcomePresenter.restorePresentation(for: outcome)
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

    private func backupTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func journalCleanupTitle(for step: JournalCleanupStep) -> String {
        switch step {
        case .discardRecovery, .markRecoveryCompletion, .discardRecoveryCompletion, .abandonRecoveryCompletion:
            "草稿恢复处理结果"
        case .record, .acknowledge, .unbind, .clear:
            "草稿清理结果"
        }
    }

    private func showDraftRecoveryRequired(_ tokens: [DraftRecoveryToken]) {
        showError(
            title: "需要先处理草稿恢复",
            message: "检测到 \(tokens.count) 条受保护草稿。请先在草稿恢复流程中选择恢复、另存为新笔记或保留当前内容；备份恢复和重新载入会在此之前保持锁定。"
        )
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
