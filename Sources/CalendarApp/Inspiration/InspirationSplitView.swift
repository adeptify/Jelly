import AppKit
import CalendarDomain
import SwiftUI
import WorkspaceDomain

struct InspirationSplitView: View {
    let store: WorkspaceStore
    @ObservedObject var newItemRouter: WorkspaceNewItemRouter
    let transitionCoordinator: WorkspaceRouteTransitionCoordinator?
    let deepLinkRouter: WorkspaceDeepLinkRouter?
    @State private var model: InspirationViewModel
    @State private var showCategoryManager = false
    @FocusState private var captureFocused: Bool
    @State private var inboxCollapsed = false
    @State private var availableWidth: CGFloat = .infinity

    init(
        store: WorkspaceStore,
        newItemRouter: WorkspaceNewItemRouter = WorkspaceNewItemRouter(),
        transitionCoordinator: WorkspaceRouteTransitionCoordinator? = nil,
        deepLinkRouter: WorkspaceDeepLinkRouter? = nil,
        searchIndex: WorkspaceSearchIndex = WorkspaceSearchIndex()
    ) {
        self.store = store
        self.newItemRouter = newItemRouter
        self.transitionCoordinator = transitionCoordinator
        self.deepLinkRouter = deepLinkRouter
        _model = State(initialValue: InspirationViewModel(store: store, searchIndex: searchIndex))
    }

    var body: some View {
        GeometryReader { proxy in
            inspirationContent(mode: NotesAdaptiveLayout.mode(
                width: proxy.size.width,
                browserCollapsed: inboxCollapsed
            ))
            .onAppear { availableWidth = proxy.size.width }
            .onChange(of: proxy.size.width) { _, width in availableWidth = width }
        }
        .sheet(isPresented: $showCategoryManager) {
            CategoryManagerView(store: store)
        }
        .onChange(of: store.statePublicationGeneration) { _, _ in
            model.refresh()
        }
        .onAppear { consumeNewItemRequest(newItemRouter.pendingRequest) }
        .onChange(of: newItemRouter.pendingRequest) { _, request in
            consumeNewItemRequest(request)
        }
    }

    @ViewBuilder
    private func inspirationContent(mode: NotesSplitView.NotesAdaptiveLayoutMode) -> some View {
        switch mode {
        case .browserOnly:
            inboxColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .editorOnly:
            detailColumn(showsInboxButton: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .split:
            HSplitView {
                inboxColumn
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
                detailColumn(showsInboxButton: false)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var inboxColumn: some View {
        InspirationInboxView(
            model: model,
            categories: store.calendarState.categories.values.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            },
            captureFocused: $captureFocused,
            onSelect: { id in
                model.select(id)
                if NotesAdaptiveLayout.isCompact(width: availableWidth) { inboxCollapsed = true }
            },
            onCaptured: { _ in
                if NotesAdaptiveLayout.isCompact(width: availableWidth) { inboxCollapsed = true }
            },
            onToggleInbox: { inboxCollapsed = true },
            onShowCategoryManager: { showCategoryManager = true }
        )
    }

    private func detailColumn(showsInboxButton: Bool) -> some View {
        InspirationDetailView(
            model: model,
            store: store,
            showsInboxButton: showsInboxButton,
            onToggleInbox: { inboxCollapsed = false },
            onOpenNote: openNote
        )
    }

    private func consumeNewItemRequest(_ request: WorkspaceNewItemRequest?) {
        guard let request,
              request.route == .inspiration,
              newItemRouter.consume(request.id, route: .inspiration) != nil else { return }
        captureFocused = true
    }

    private func openNote(_ noteID: NoteID) {
        guard let transitionCoordinator, let deepLinkRouter else { return }
        Task {
            guard await transitionCoordinator.requestActivation(.notes) else { return }
            deepLinkRouter.request(.note(noteID))
        }
    }
}

struct InspirationInboxView: View {
    @Bindable var model: InspirationViewModel
    let categories: [CalendarCategory]
    var captureFocused: FocusState<Bool>.Binding
    let onSelect: (InspirationID) -> Void
    let onCaptured: (InspirationID) -> Void
    let onToggleInbox: () -> Void
    let onShowCategoryManager: () -> Void
    @State private var scope: InspirationInboxScope = .pending
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("灵感收件箱")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Button(action: onToggleInbox) {
                    Image(systemName: "sidebar.left")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.secondaryText)
                .help("隐藏灵感列表")
                .accessibilityLabel("隐藏灵感列表")
            }
            .padding(.horizontal, 14)
            .frame(height: CalendarTheme.toolbarHeight)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.separator.opacity(0.7)).frame(height: 0.5)
            }

            InspirationCaptureView(model: model, isFocused: captureFocused) { id in
                scope = .pending
                onCaptured(id)
            }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                    TextField("搜索内容、标题或域名", text: $model.searchText)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("搜索灵感")
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(theme.canvas.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
                categoryMenu
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Picker("灵感范围", selection: $scope) {
                ForEach(InspirationInboxScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .tint(theme.controlAccent)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            List {
                rows(items, empty: scope.emptyMessage)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(theme.elevatedSurface)
        .foregroundStyle(theme.primaryText)
        .onChange(of: model.selected?.lifecycle) { _, lifecycle in
            guard let lifecycle else { return }
            scope = .preferred(
                lifecycle: lifecycle,
                isConverted: model.selectedConvertedNoteID != nil
            )
        }
        .onChange(of: model.selectedConvertedNoteID) { _, noteID in
            guard model.selected?.lifecycle == .active else { return }
            scope = noteID == nil ? .pending : .converted
        }
    }

    private var items: [Inspiration] {
        switch scope {
        case .pending: model.pending
        case .converted: model.converted
        case .archived: model.archived
        }
    }

    private var categoryMenu: some View {
        Menu {
            Button("全部分类") { model.categoryFilterID = nil }
            ForEach(categories) { category in
                Button(category.name) { model.categoryFilterID = category.id }
            }
            Divider()
            Button("管理分类…", action: onShowCategoryManager)
        } label: {
            Image(systemName: model.categoryFilterID == nil
                ? "line.3.horizontal.decrease.circle"
                : "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(model.categoryFilterID == nil ? theme.secondaryText : theme.controlAccent)
                .frame(width: 30, height: 30)
                .background(theme.canvas.opacity(0.78), in: RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("按分类筛选；也可管理分类")
        .accessibilityLabel("筛选灵感分类")
    }

    @ViewBuilder
    private func rows(_ items: [Inspiration], empty: String) -> some View {
        if items.isEmpty {
            Text(empty).font(.caption).foregroundStyle(.secondary)
        } else {
            ForEach(items) { item in
                Button {
                    onSelect(item.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rowTitle(item)).lineLimit(1)
                        Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(model.selectedID == item.id ? theme.rangePreviewFill : Color.clear)
                .listRowSeparator(.hidden)
                .accessibilityLabel(rowTitle(item))
                .accessibilityAddTraits(model.selectedID == item.id ? .isSelected : [])
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
    var isFocused: FocusState<Bool>.Binding
    var onCaptured: (InspirationID) -> Void = { _ in }

    var body: some View {
        HStack {
            TextField("粘贴文字或链接，回车捕获", text: $model.captureText)
                .textFieldStyle(.roundedBorder)
                .focused(isFocused)
                .onSubmit { capture() }
            Button("捕获") {
                capture()
            }
            .disabled(model.captureText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("灵感快速捕获")
    }

    private func capture() {
        Task {
            if let id = try? await model.capture(model.captureText) { onCaptured(id) }
        }
    }
}

enum InspirationInboxScope: String, CaseIterable, Identifiable {
    case pending
    case converted
    case archived

    var id: Self { self }
    var title: String {
        switch self {
        case .pending: "待处理"
        case .converted: "已成笔记"
        case .archived: "归档"
        }
    }
    var emptyMessage: String {
        switch self {
        case .pending: "暂无待处理灵感"
        case .converted: "还没有转成笔记的灵感"
        case .archived: "归档为空"
        }
    }

    static func preferred(
        lifecycle: InspirationLifecycle,
        isConverted: Bool
    ) -> InspirationInboxScope {
        if lifecycle == .archived { return .archived }
        return isConverted ? .converted : .pending
    }
}

struct InspirationDetailView: View {
    @Bindable var model: InspirationViewModel
    let store: WorkspaceStore
    var showsInboxButton = false
    var onToggleInbox: () -> Void = {}
    var onOpenNote: (NoteID) -> Void = { _ in }
    @State private var pendingPermanentDelete: InspirationPermanentDeleteRequest?
    @State private var deleteStatus: String?
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        if let inspiration = model.selected {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    if showsInboxButton {
                        Button(action: onToggleInbox) {
                            Image(systemName: "sidebar.left").frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .help("显示灵感列表")
                        .accessibilityLabel("显示灵感列表")
                    }
                    Text("灵感详情").font(.title3.weight(.semibold))
                    Spacer()
                    Text(inspiration.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
                Picker("分类", selection: Binding(
                    get: { inspiration.categoryID },
                    set: { categoryID in
                        Task { _ = try? await model.changeSelectedCategory(to: categoryID) }
                    }
                )) {
                    ForEach(store.calendarState.categories.values.sorted {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }, id: \.id) { category in
                        Text(category.name).tag(category.id)
                    }
                }
                .frame(maxWidth: 220, alignment: .leading)
                .accessibilityLabel("灵感分类")
                GroupBox("原始内容") {
                    if let text = inspiration.rawText {
                        Text(text).textSelection(.enabled)
                    } else if let url = inspiration.rawURL {
                        Text(url.absoluteString).textSelection(.enabled)
                    } else {
                        Text("（无原始内容）").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let metadata = inspiration.resolvedMetadata {
                    GroupBox("来源元数据") {
                        Text(metadata.title ?? "（无标题）")
                        Text(metadata.domain ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("状态：\(metadata.fetchStatus.presentationTitle)")
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
                    Button(model.selectedPrimaryActionTitle) {
                        Task {
                            if let noteID = try? await model.convertSelectedToNote() {
                                onOpenNote(noteID)
                            }
                        }
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
            .background(theme.canvas)
            .foregroundStyle(theme.primaryText)
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
            VStack(spacing: 0) {
                if showsInboxButton {
                    HStack {
                        Button(action: onToggleInbox) { Image(systemName: "sidebar.left").frame(width: 28, height: 28) }
                            .buttonStyle(.plain)
                            .help("显示灵感列表")
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .frame(height: CalendarTheme.toolbarHeight)
                }
                ContentUnavailableView("选择一条灵感", systemImage: "lightbulb", description: Text("打开灵感列表进行选择，或捕获一条新灵感。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(theme.canvas)
        }
    }
}

extension MetadataFetchStatus {
    var presentationTitle: String {
        switch self {
        case .notRequested: "未请求"
        case .loading: "获取中…"
        case .succeeded: "已获取"
        case .failed: "获取失败"
        }
    }
}
