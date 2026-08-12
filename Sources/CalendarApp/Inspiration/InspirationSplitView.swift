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
            HStack(spacing: 10) {
                Text("灵光")
                    .font(.system(size: 17, weight: .semibold))
                Spacer(minLength: 0)
                Button(action: onToggleInbox) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
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
                .padding(.bottom, 10)

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
                .background(
                    theme.canvas.opacity(0.78),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.subtleBorder.opacity(0.5), lineWidth: 0.5)
                }
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
            .background(theme.elevatedSurface)
        }
        .background(theme.elevatedSurface)
        .foregroundStyle(theme.primaryText)
        .onAppear {
            model.alignSelection(with: visibleItemIDs)
        }
        .onChange(of: visibleItemIDs) { _, ids in
            model.alignSelection(with: ids)
        }
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

    private var visibleItemIDs: [InspirationID] {
        items.map(\.id)
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
                .background(
                    theme.canvas.opacity(0.78),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("按分类筛选；也可管理分类")
        .accessibilityLabel("筛选灵感分类")
    }

    @ViewBuilder
    private func rows(_ items: [Inspiration], empty: String) -> some View {
        if items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: scope == .archived ? "archivebox" : "lightbulb")
                    .font(.system(size: 20))
                Text(empty).font(.caption)
            }
            .foregroundStyle(theme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else {
            ForEach(items) { item in
                Button {
                    onSelect(item.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rowTitle(item))
                            .lineLimit(1)
                            .font(.system(
                                size: 13,
                                weight: model.selectedID == item.id ? .semibold : .regular
                            ))
                            .foregroundStyle(theme.primaryText)
                        if let preview = rowPreview(item) {
                            Text(preview)
                                .lineLimit(1)
                                .font(.system(size: 11))
                                .foregroundStyle(theme.secondaryText)
                        }
                        Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 10))
                            .foregroundStyle(theme.secondaryText.opacity(0.82))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background {
                        if model.selectedID == item.id {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(theme.rangePreviewFill)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .listRowInsets(.init(top: 2, leading: 8, bottom: 2, trailing: 8))
                .listRowBackground(Color.clear)
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

    private func rowPreview(_ item: Inspiration) -> String? {
        if let domain = item.resolvedMetadata?.domain, !domain.isEmpty { return domain }
        if item.resolvedMetadata?.title != nil,
           let url = item.rawURL?.absoluteString {
            return url
        }
        return nil
    }
}

struct InspirationCaptureView: View {
    @Bindable var model: InspirationViewModel
    var isFocused: FocusState<Bool>.Binding
    var onCaptured: (InspirationID) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.controlAccent)
            TextField("记下一闪而过的想法，或粘贴链接", text: $model.captureText)
                .textFieldStyle(.plain)
                .focused(isFocused)
                .onSubmit { capture() }
            Button {
                capture()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(canCapture ? theme.controlAccent : theme.secondaryText.opacity(0.38))
            }
            .buttonStyle(.plain)
            .disabled(!canCapture)
            .help("收下这条灵感")
            .accessibilityLabel("收下灵感")
            .accessibilityIdentifier("inspiration-capture-action")
        }
        .padding(.horizontal, 11)
        .frame(height: 36)
        .background(theme.canvas.opacity(0.84), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(theme.subtleBorder.opacity(0.58), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("灵感快速捕获")
    }

    private var canCapture: Bool {
        !model.captureText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

enum InspirationDetailAction: String, CaseIterable {
    case primary = "inspiration-primary-action"
    case archive = "inspiration-archive-action"
    case copyLink = "inspiration-copy-link-action"
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
            VStack(alignment: .leading, spacing: 0) {
                detailToolbar(inspiration)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        contentSection(inspiration)
                        if let metadata = inspiration.resolvedMetadata {
                            sourceSection(inspiration, metadata: metadata)
                        }
                        statusSection
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.top, 30)
                    .padding(.bottom, 36)
                }
                detailActions(inspiration)
            }
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

    private func detailToolbar(_ inspiration: Inspiration) -> some View {
        HStack(spacing: 10) {
            if showsInboxButton {
                Button(action: onToggleInbox) {
                    Image(systemName: "sidebar.left")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("显示灵感列表")
                .accessibilityLabel("显示灵感列表")
            }
            Text("灵光详情")
                .font(.system(size: 17, weight: .semibold))
            Spacer(minLength: 12)
            categoryMenu(inspiration)
        }
        .padding(.horizontal, 20)
        .frame(height: CalendarTheme.toolbarHeight)
        .background(theme.canvas)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.separator.opacity(0.7)).frame(height: 0.5)
        }
    }

    private func categoryMenu(_ inspiration: Inspiration) -> some View {
        Menu {
            ForEach(sortedCategories, id: \.id) { category in
                Button {
                    Task { _ = try? await model.changeSelectedCategory(to: category.id) }
                } label: {
                    HStack {
                        Text(category.name)
                        if category.id == inspiration.categoryID { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            Label(categoryName(for: inspiration.categoryID), systemImage: "tag")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(theme.elevatedSurface.opacity(0.82), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("分类会与日历和笔记共用")
        .accessibilityLabel("灵光分类：\(categoryName(for: inspiration.categoryID))")
    }

    private func contentSection(_ inspiration: Inspiration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("内容")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                Spacer(minLength: 12)
                Text(inspiration.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
            }
            Text(primaryContent(inspiration))
                .font(.system(size: 18, weight: .regular))
                .lineSpacing(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("inspiration-content")
        }
    }

    private func sourceSection(
        _ inspiration: Inspiration,
        metadata: SourceMetadata
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
                .overlay(theme.separator.opacity(0.7))
                .padding(.vertical, 24)
            Text("来源")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "link")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.controlAccent)
                    .frame(width: 30, height: 30)
                    .background(theme.controlAccent.opacity(0.11), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(metadata.title ?? inspiration.rawURL?.absoluteString ?? "链接")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        if let domain = metadata.domain, !domain.isEmpty {
                            Text(domain)
                        }
                        Text(metadata.fetchStatus.presentationTitle)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 12)
                if inspiration.rawURL != nil, metadata.fetchStatus == .failed {
                    Button("重试") { Task { await model.retrySelectedMetadata() } }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12, weight: .medium))
                }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let status = model.statusMessage {
            Text(status)
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.top, 18)
        }
        if let deleteStatus {
            Text(deleteStatus)
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.top, 8)
        }
    }

    private func detailActions(_ inspiration: Inspiration) -> some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    if let noteID = try? await model.convertSelectedToNote() {
                        onOpenNote(noteID)
                    }
                }
            } label: {
                Label(
                    model.selectedPrimaryActionTitle,
                    systemImage: model.selectedConvertedNoteID == nil
                        ? "note.text.badge.plus"
                        : "arrow.up.right"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.controlAccent)
            .controlSize(.regular)
            .accessibilityLabel(model.selectedPrimaryActionTitle)
            .accessibilityIdentifier(InspirationDetailAction.primary.rawValue)

            Button(inspiration.lifecycle == .archived ? "恢复" : "归档") {
                Task {
                    if inspiration.lifecycle == .archived {
                        _ = try? await model.restoreSelected()
                    } else {
                        _ = try? await model.archiveSelected()
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .accessibilityIdentifier(InspirationDetailAction.archive.rawValue)

            if let url = inspiration.rawURL {
                Button("复制链接") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .accessibilityIdentifier(InspirationDetailAction.copyLink.rawValue)
            }

            Spacer(minLength: 0)

            if inspiration.lifecycle == .archived {
                Button("永久删除…", role: .destructive) {
                    do {
                        pendingPermanentDelete = try model.permanentDeleteRequest(for: inspiration.id)
                        deleteStatus = nil
                    } catch {
                        deleteStatus = "无法生成删除影响预览。"
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(theme.error)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 20)
        .frame(height: 58)
        .background(theme.elevatedSurface.opacity(0.82))
        .overlay(alignment: .top) {
            Rectangle().fill(theme.separator.opacity(0.7)).frame(height: 0.5)
        }
    }

    private var sortedCategories: [CalendarCategory] {
        store.calendarState.categories.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func categoryName(for id: UUID) -> String {
        store.calendarState.categories[id]?.name ?? "未分类"
    }

    private func primaryContent(_ inspiration: Inspiration) -> String {
        if let text = inspiration.rawText, !text.isEmpty { return text }
        if let url = inspiration.rawURL { return url.absoluteString }
        return "（没有可显示的内容）"
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
