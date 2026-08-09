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
        }
    }

    private var canRestore: Bool {
        switch store.phase {
        case .ready, .loadFailed, .opaquePrimaryLoadFailed, .unreadablePrimaryLoadFailed,
             .needsRelationshipRepair, .externalSourceChanged:
            true
        case .notLoaded, .loading, .mutating, .parkedCommitUncertain, .parkedJournalCleanup:
            false
        }
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
            guard case let .restored(restored) = outcome else {
                showError(title: "恢复备份失败", message: "恢复没有提交，当前数据没有被替换。")
                return
            }
            showInformation(title: "备份已恢复", message: rollbackMessage(for: restored.rollback))
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
