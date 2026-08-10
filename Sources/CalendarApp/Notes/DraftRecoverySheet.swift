import SwiftUI
import WorkspaceDomain

/// Presents a single reviewed draft-recovery candidate with the three contract
/// actions. Stale tokens refresh rather than inventing success.
struct DraftRecoverySheet: View {
    let candidate: DraftRecoveryCandidate
    let statusMessage: String?
    let onRestoreAsCurrent: () -> Void
    let onKeepPersisted: () -> Void
    let onSaveAsNew: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("草稿恢复")
                .font(.title2.weight(.semibold))
            Text(statusMessage ?? "检测到可恢复的本地草稿。请选择如何处理。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("当前磁盘版本") {
                recoveryPreview(
                    title: candidate.persisted?.title ?? "（无磁盘正文）",
                    bodyText: bodyPreview(candidate.persisted?.document)
                )
            }
            GroupBox("受保护草稿") {
                recoveryPreview(
                    title: candidate.draft.title.isEmpty ? "（无标题）" : candidate.draft.title,
                    bodyText: bodyPreview(candidate.draft.document)
                )
            }

            HStack {
                Button("保留磁盘版本", action: onKeepPersisted)
                Spacer()
                Button("另存为新笔记", action: onSaveAsNew)
                Button("恢复为当前版本") {
                    onRestoreAsCurrent()
                }
                .keyboardShortcut(.defaultAction)
            }
            Button("稍后处理", action: onDismiss)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 420)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("草稿恢复")
    }

    private func recoveryPreview(title: String, bodyText: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(bodyText)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(4)
    }

    private func bodyPreview(_ document: BlockDocument?) -> String {
        guard let document else { return "（空）" }
        let text = document.blocks
            .flatMap(\.inlineContent.spans)
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "（空）" : text
    }
}

/// Presentation helper that maps Store phase → sheet models without owning recovery.
@MainActor
enum DraftRecoveryPresentation {
    static func candidates(from store: WorkspaceStore) -> [DraftRecoveryCandidate] {
        if case let .needsDraftRecovery(candidates) = store.phase {
            return candidates
        }
        return []
    }

    static func statusMessage(for store: WorkspaceStore) -> String? {
        switch store.phase {
        case .needsDraftRecovery:
            return "请在继续编辑前处理已保护的草稿。"
        case .reconcilingDraftRecovery, .resolvingDraftRecovery:
            return "正在核对草稿恢复状态…"
        default:
            return nil
        }
    }
}
