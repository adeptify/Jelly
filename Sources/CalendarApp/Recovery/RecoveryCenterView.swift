import SwiftUI
import WorkspaceDomain

@MainActor
@Observable final class RecoveryCenterViewModel {
    private let store: WorkspaceStore
    private(set) var draftCandidates: [DraftRecoveryCandidate] = []
    private(set) var phaseDescription: String = ""
    private(set) var hasRawRecovery = false
    private(set) var statusMessage: String?

    init(store: WorkspaceStore) {
        self.store = store
        refresh()
    }

    func refresh() {
        hasRawRecovery = store.hasRawRecoverySource
        switch store.phase {
        case let .needsDraftRecovery(candidates):
            draftCandidates = candidates
            phaseDescription = "需要处理 \(candidates.count) 条受保护草稿"
        case .ready:
            draftCandidates = []
            phaseDescription = "工作空间就绪"
        case .reconcilingDraftRecovery, .resolvingDraftRecovery:
            phaseDescription = "正在核对草稿恢复状态"
            draftCandidates = []
        case .loadFailed, .opaquePrimaryLoadFailed:
            phaseDescription = "加载失败"
        case .unreadablePrimaryLoadFailed:
            phaseDescription = "主文件不可读"
        case .externalSourceChanged:
            phaseDescription = "检测到外部数据变化"
        case .notLoaded, .loading:
            phaseDescription = "尚未加载"
        case .mutating, .parkedCommitUncertain:
            phaseDescription = "正在保存或等待确认"
        case .parkedJournalCleanup:
            phaseDescription = "草稿清理待确认"
        case .needsRelationshipRepair:
            phaseDescription = "部分内容关联需要修复"
        }
    }

    func resolve(_ candidate: DraftRecoveryCandidate, action: DraftRecoveryAction) async {
        do {
            _ = try await store.resolveDraftRecovery(candidate.token, action: action)
            statusMessage = nil
            refresh()
        } catch {
            statusMessage = "恢复操作未完成或已过期。"
            refresh()
        }
    }
}

struct RecoveryCenterView: View {
    @State private var model: RecoveryCenterViewModel
    let store: WorkspaceStore

    init(store: WorkspaceStore) {
        self.store = store
        _model = State(initialValue: RecoveryCenterViewModel(store: store))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("恢复与备份")
                .font(.title2.weight(.semibold))
            Text(model.phaseDescription)
                .foregroundStyle(.secondary)

            if model.hasRawRecovery {
                Label("可导出原始恢复副本", systemImage: "doc.badge.arrow.up")
                    .font(.caption)
            }

            if model.draftCandidates.isEmpty {
                ContentUnavailableView(
                    "没有待处理草稿",
                    systemImage: "checkmark.shield",
                    description: Text("当前没有需要你确认的未保存内容。完整备份可从“文件”菜单导出或恢复。")
                )
            } else {
                List(model.draftCandidates) { candidate in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(candidate.draft.title.isEmpty ? "无标题草稿" : candidate.draft.title)
                            .font(.headline)
                        Text(candidate.updatedAt.formatted())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("使用退出前版本") {
                                Task { await model.resolve(candidate, action: .restoreAsCurrent) }
                            }
                            Button("使用当前版本") {
                                Task { await model.resolve(candidate, action: .keepPersisted) }
                            }
                            Button("两个版本都保留") {
                                Task {
                                    await model.resolve(
                                        candidate,
                                        action: .saveAsNew(
                                            noteID: NoteID(),
                                            blockIDs: candidate.draft.document.blocks.map(\.id)
                                        )
                                    )
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            if let status = model.statusMessage {
                Text(status).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 360)
        .onChange(of: store.statePublicationGeneration) { _, _ in model.refresh() }
        .onChange(of: store.phase) { _, _ in model.refresh() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("恢复与备份")
    }
}
