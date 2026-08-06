import AppKit
import CalendarDomain
import CalendarPersistence
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct BackupCommands: Commands {
    let store: CalendarStore
    let backupService: BackupService

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
        store.phase == .ready || store.phase == .loadFailed
    }

    private func exportBackup() {
        guard store.phase == .ready else { return }

        let panel = NSSavePanel()
        panel.title = "导出 Jelly 备份"
        panel.message = "导出可用于本应用恢复的完整日历备份。"
        panel.nameFieldStringValue = "Jelly备份-\(backupTimestamp()).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let stateSnapshot = store.state
        Task { @MainActor in
            do {
                try await backupService.export(state: stateSnapshot, to: destination)
                showInformation(
                    title: "备份已导出",
                    message: "已保存到：\n\(destination.path)"
                )
            } catch {
                showError(
                    title: "无法导出备份",
                    message: "备份没有写入。请确认目标位置可写后重试。"
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
        Task { @MainActor in
            await validateAndRestore(source: source)
        }
    }

    private func validateAndRestore(source: URL) async {
        let restored: CalendarState
        do {
            restored = try await backupService.validatedState(from: source)
        } catch {
            showError(
                title: "备份文件无法恢复",
                message: "该文件不是有效的 Jelly 备份，当前数据没有被修改。"
            )
            return
        }

        let rollbackURL: URL
        do {
            rollbackURL = try makeRollbackURL()
        } catch {
            showError(
                title: "无法准备恢复",
                message: "无法创建本地回滚位置，当前数据没有被修改。"
            )
            return
        }

        guard confirmRestore(restored: restored, rollbackURL: rollbackURL) else { return }

        do {
            try await store.restore(
                from: source,
                using: backupService,
                rollbackURL: rollbackURL
            )
            showInformation(
                title: "备份已恢复",
                message: "恢复前的数据已保留在：\n\(rollbackURL.path)"
            )
        } catch {
            showError(
                title: "恢复备份失败",
                message: "当前本地文件没有被替换。请检查备份和磁盘空间后重试。"
            )
        }
    }

    private func confirmRestore(restored: CalendarState, rollbackURL: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "确认恢复备份？"
        let currentSummary: String
        if store.phase == .loadFailed {
            currentSummary = "当前数据无法读取"
        } else {
            currentSummary = BackupStateSummary(state: store.state).description
        }
        let backupSummary = BackupStateSummary(state: restored).description
        let unreadablePrimaryNotice = store.phase == .loadFailed
            ? "\n当前数据无法读取；其原始字节仍会完整保留到该回滚文件。"
            : ""
        alert.informativeText = """
        \(currentSummary) → \(backupSummary)

        恢复会替换完整当前日历，包括分类、事项、重复系列、单次例外和完成记录。
        恢复前的当前内容会先原样保留到：
        \(rollbackURL.path)\(unreadablePrimaryNotice)
        """
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func makeRollbackURL() throws -> URL {
        let fileManager = FileManager.default
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let rollbackDirectory = applicationSupport
            .appendingPathComponent("PersonalCalendar", isDirectory: true)
            .appendingPathComponent("Rollbacks", isDirectory: true)
        return rollbackDirectory.appendingPathComponent(
            "restore-\(backupTimestamp())-\(UUID().uuidString).json"
        )
    }

    private func backupTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func showInformation(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "知道了")
        alert.runModal()
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

    var description: String {
        "分类 \(categories) 个，事项 \(items) 项，重复系列 \(series) 个"
    }
}
