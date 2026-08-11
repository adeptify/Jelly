import AppKit
import SwiftUI
import WorkspaceDomain

struct InspirationSplitView: View {
    let store: WorkspaceStore
    @State private var model: InspirationViewModel
    @State private var showCategoryManager = false

    init(store: WorkspaceStore) {
        self.store = store
        _model = State(initialValue: InspirationViewModel(store: store))
    }

    var body: some View {
        HSplitView {
            InspirationInboxView(model: model)
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            InspirationDetailView(model: model, store: store)
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("分类") { showCategoryManager = true }
            }
        }
        .sheet(isPresented: $showCategoryManager) {
            CategoryManagerView(store: store)
        }
        .onChange(of: store.statePublicationGeneration) { _, _ in
            model.refresh()
        }
    }
}

struct InspirationInboxView: View {
    @Bindable var model: InspirationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InspirationCaptureView(model: model)
                .padding(12)
            List {
                Section("待处理") {
                    rows(model.pending, empty: "暂无待处理灵感")
                }
                Section("已形成笔记") {
                    rows(model.converted, empty: "尚未转成笔记")
                }
                Section("已归档") {
                    rows(model.archived, empty: "归档为空")
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private func rows(_ items: [Inspiration], empty: String) -> some View {
        if items.isEmpty {
            Text(empty).font(.caption).foregroundStyle(.secondary)
        } else {
            ForEach(items) { item in
                Button {
                    model.select(item.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rowTitle(item)).lineLimit(1)
                        Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .listRowBackground(
                    model.selectedID == item.id ? Color.accentColor.opacity(0.12) : Color.clear
                )
            }
        }
    }

    private func rowTitle(_ item: Inspiration) -> String {
        if let title = item.resolvedMetadata?.title, !title.isEmpty { return title }
        if let text = item.rawText, !text.isEmpty { return text }
        return item.rawURL?.absoluteString ?? "灵感"
    }
}

struct InspirationCaptureView: View {
    @Bindable var model: InspirationViewModel

    var body: some View {
        HStack {
            TextField("粘贴文字或链接，回车捕获", text: $model.captureText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { _ = try? await model.capture(model.captureText) } }
            Button("捕获") {
                Task { _ = try? await model.capture(model.captureText) }
            }
            .disabled(model.captureText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("灵感快速捕获")
    }
}

struct InspirationDetailView: View {
    @Bindable var model: InspirationViewModel
    let store: WorkspaceStore
    @State private var pendingPermanentDelete: InspirationPermanentDeleteRequest?
    @State private var deleteStatus: String?

    var body: some View {
        if let inspiration = model.selected {
            VStack(alignment: .leading, spacing: 12) {
                Text("灵感详情").font(.title3.weight(.semibold))
                GroupBox("原始内容") {
                    if let text = inspiration.rawText {
                        Text(text).textSelection(.enabled)
                    } else if let url = inspiration.rawURL {
                        Text(url.absoluteString).textSelection(.enabled)
                    } else {
                        Text("（无原始内容）").foregroundStyle(.secondary)
                    }
                }
                if let metadata = inspiration.resolvedMetadata {
                    GroupBox("来源元数据") {
                        Text(metadata.title ?? "（无标题）")
                        Text(metadata.domain ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("状态：\(metadata.fetchStatus.rawValue)")
                            .font(.caption2)
                    }
                }
                if let status = model.statusMessage {
                    Text(status).font(.caption).foregroundStyle(.orange)
                }
                if let deleteStatus {
                    Text(deleteStatus).font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("转成笔记") {
                        Task { _ = try? await model.convertSelectedToNote() }
                    }
                    if inspiration.rawURL != nil,
                       inspiration.resolvedMetadata?.fetchStatus == .failed {
                        Button("重试元数据") {
                            Task { await model.retrySelectedMetadata() }
                        }
                    }
                    Button(inspiration.lifecycle == .archived ? "恢复" : "归档") {
                        Task {
                            if inspiration.lifecycle == .archived {
                                _ = try? await model.restoreSelected()
                            } else {
                                _ = try? await model.archiveSelected()
                            }
                        }
                    }
                    if inspiration.lifecycle == .archived {
                        Button("永久删除…", role: .destructive) {
                            do {
                                pendingPermanentDelete = try model.permanentDeleteRequest(for: inspiration.id)
                                deleteStatus = nil
                            } catch {
                                deleteStatus = "无法生成删除影响预览。"
                            }
                        }
                    }
                    if let url = inspiration.rawURL {
                        Button("复制链接") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        }
                    }
                }
                Spacer()
            }
            .padding(20)
            .confirmationDialog(
                "永久删除这条灵感？",
                isPresented: Binding(
                    get: { pendingPermanentDelete != nil },
                    set: { if !$0 { pendingPermanentDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("永久删除", role: .destructive) {
                    guard let request = pendingPermanentDelete else { return }
                    pendingPermanentDelete = nil
                    Task {
                        let authorization = PermanentDeleteAuthorization(
                            subject: request.preview.subject,
                            sourceWorkspaceRevision: request.preview.sourceWorkspaceRevision,
                            impactChecksum: request.preview.checksum
                        )
                        do {
                            let deleted = try await model.permanentlyDelete(
                                request,
                                authorization: authorization
                            )
                            if !deleted { deleteStatus = "删除影响已变化，请重新确认。" }
                        } catch {
                            deleteStatus = "永久删除未完成，原始灵感仍然保留。"
                        }
                    }
                }
                Button("取消", role: .cancel) { pendingPermanentDelete = nil }
            } message: {
                if let request = pendingPermanentDelete {
                    Text(request.preview.effects.isEmpty
                        ? "删除后无法恢复。"
                        : "删除后无法恢复，并会把 \(request.preview.effects.count) 条笔记来源关系改为“原始灵感已删除”。")
                }
            }
        } else {
            ContentUnavailableView("选择一条灵感", systemImage: "lightbulb", description: Text("左侧列表选择，或在上方捕获。"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
