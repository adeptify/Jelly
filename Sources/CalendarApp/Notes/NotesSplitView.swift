import AppKit
import CalendarDomain
import SwiftUI
import UniformTypeIdentifiers
import WorkspaceDomain

/// Production Notes module host. Keeps one autosave coordinator and one
/// ViewModel for the module lifetime (AppShell host token).
@MainActor
struct NotesSplitView: View {
    let store: WorkspaceStore
    let focusRegistry: EditorFocusRegistry
    let transitionCoordinator: WorkspaceRouteTransitionCoordinator?
    @ObservedObject var deepLinkRouter: WorkspaceDeepLinkRouter
    @ObservedObject var newItemRouter: WorkspaceNewItemRouter
    let searchIndex: WorkspaceSearchIndex
    let terminationCoordinator: NotesApplicationTerminationCoordinator?
    let clock: @Sendable () -> Date

    @State private var viewModel: NotesWorkspaceViewModel
    @State private var autosave: NoteAutosaveCoordinator
    @State private var closeBridge: NoteCloseProtectionBridge
    @State private var editorIdentity: NoteEditorIdentity?
    @State private var editorInitialFocus: NoteInitialFocus?
    @State private var nativeFinalizer: NoteNativeInputFinalizer?
    @State private var showCategoryManager = false
    @State private var browserCollapsed = false
    @State private var recoveryCandidate: DraftRecoveryCandidate?
    @State private var importDiagnostics: [BlockMarkdownDiagnostic] = []
    @State private var pendingImportPlan: NoteMarkdownImportPlan?
    @State private var statusBanner: String?
    @State private var activeEditorSession: BlockEditorSession?
    @State private var pendingPermanentDelete: PendingNotePermanentDelete?
    @State private var availableWidth: CGFloat = .infinity

    enum NotesAdaptiveLayoutMode: Equatable {
        case browserOnly
        case editorOnly
        case split
    }

    init(
        store: WorkspaceStore,
        focusRegistry: EditorFocusRegistry,
        transitionCoordinator: WorkspaceRouteTransitionCoordinator? = nil,
        deepLinkRouter: WorkspaceDeepLinkRouter = WorkspaceDeepLinkRouter(),
        newItemRouter: WorkspaceNewItemRouter = WorkspaceNewItemRouter(),
        searchIndex: WorkspaceSearchIndex = WorkspaceSearchIndex(),
        terminationCoordinator: NotesApplicationTerminationCoordinator? = nil,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.focusRegistry = focusRegistry
        self.transitionCoordinator = transitionCoordinator
        self.deepLinkRouter = deepLinkRouter
        self.newItemRouter = newItemRouter
        self.searchIndex = searchIndex
        self.terminationCoordinator = terminationCoordinator
        self.clock = clock
        let autosave = NoteAutosaveCoordinator(store: store)
        let viewModel = NotesWorkspaceViewModel(
            store: store,
            autosave: autosave,
            searchIndex: searchIndex,
            clock: clock
        )
        _autosave = State(initialValue: autosave)
        _viewModel = State(initialValue: viewModel)
        _closeBridge = State(initialValue: NoteCloseProtectionBridge(coordinator: autosave))
    }

    var body: some View {
        GeometryReader { proxy in
            notesContent(mode: NotesAdaptiveLayout.mode(
                width: proxy.size.width,
                browserCollapsed: browserCollapsed
            ))
            .onAppear { availableWidth = proxy.size.width }
            .onChange(of: proxy.size.width) { _, width in availableWidth = width }
        }
        .overlay(alignment: .top) {
            if let statusBanner {
                Text(statusBanner)
                    .padding(8)
                    .background(.yellow.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(.top, 8)
            }
        }
        .sheet(item: $recoveryCandidate) { candidate in
            DraftRecoverySheet(
                candidate: candidate,
                statusMessage: DraftRecoveryPresentation.statusMessage(for: store),
                onRestoreAsCurrent: {
                    Task { await resolveRecovery(candidate, action: .restoreAsCurrent) }
                },
                onKeepPersisted: {
                    Task { await resolveRecovery(candidate, action: .keepPersisted) }
                },
                onSaveAsNew: {
                    Task {
                        let newID = NoteID()
                        let blockIDs = candidate.draft.document.blocks.map(\.id)
                        await resolveRecovery(
                            candidate,
                            action: .saveAsNew(noteID: newID, blockIDs: blockIDs)
                        )
                    }
                },
                onDismiss: { recoveryCandidate = nil }
            )
        }
        .sheet(isPresented: $showCategoryManager) {
            CategoryManagerView(store: store)
        }
        .confirmationDialog(
            "导入 Markdown",
            isPresented: Binding(
                get: { pendingImportPlan != nil },
                set: { if !$0 { pendingImportPlan = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("替换当前正文") { applyPendingImport(.replace) }
            Button("追加到末尾") { applyPendingImport(.append) }
            Button("取消", role: .cancel) { pendingImportPlan = nil }
        } message: {
            if let plan = pendingImportPlan, !plan.result.diagnostics.isEmpty {
                Text(plan.result.diagnostics.map(\.message).joined(separator: "\n"))
            } else {
                Text("选择如何应用导入的 Markdown。")
            }
        }
        .confirmationDialog(
            "永久删除这篇笔记？",
            isPresented: Binding(
                get: { pendingPermanentDelete != nil },
                set: { if !$0 { pendingPermanentDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("永久删除", role: .destructive) {
                guard let request = pendingPermanentDelete else { return }
                pendingPermanentDelete = nil
                Task { await confirmPermanentDelete(request) }
            }
            Button("取消", role: .cancel) { pendingPermanentDelete = nil }
        } message: {
            if let request = pendingPermanentDelete {
                Text(request.preview.effects.isEmpty
                    ? "删除后无法恢复。"
                    : "删除后无法恢复，并会解除 \(request.preview.effects.count) 条关联。")
            }
        }
        .onAppear {
            registerRouteBridge()
            refreshRecoveryPresentation()
            consumeNoteDeepLink(deepLinkRouter.pendingRequest)
            consumeNoteNewItemRequest(newItemRouter.pendingRequest)
        }
        .onChange(of: editorIdentity) { _, _ in
            registerRouteBridge()
        }
        .onChange(of: store.statePublicationGeneration) { _, _ in
            refreshRecoveryPresentation()
            syncEditorNoteIfNeeded()
        }
        .onChange(of: store.phase) { _, _ in
            refreshRecoveryPresentation()
        }
        .onChange(of: deepLinkRouter.pendingRequest) { _, request in
            consumeNoteDeepLink(request)
        }
        .onChange(of: newItemRouter.pendingRequest) { _, request in
            consumeNoteNewItemRequest(request)
        }
        .background(NotesWindowCloseMonitor(bridge: closeBridge, finalizer: nativeFinalizer))
    }

    @ViewBuilder
    private func notesContent(mode: NotesAdaptiveLayoutMode) -> some View {
        switch mode {
        case .browserOnly:
            browserColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .editorOnly:
            editorColumn(showsBrowserButton: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .split:
            HSplitView {
                browserColumn
                    .frame(minWidth: 248, idealWidth: 280, maxWidth: 340)
                editorColumn(showsBrowserButton: false)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var browserColumn: some View {
        NoteBrowserView(
            viewModel: viewModel,
            categories: sortedCategories,
            onSelect: { await selectNote($0) },
            onCreate: { await createNote() },
            onToggleBrowser: { browserCollapsed = true },
            onShowCategoryManager: { showCategoryManager = true }
        )
    }

    @ViewBuilder
    private func editorColumn(showsBrowserButton: Bool) -> some View {
        if let identity = editorIdentity, let note = store.state.notes[identity.noteID] {
            NoteEditorView(
                identity: identity,
                initialFocus: editorInitialFocus,
                note: note,
                focusRegistry: focusRegistry,
                autosave: autosave,
                store: store,
                categories: sortedCategories,
                onDocumentCommitted: { _ in },
                onTitleCommitted: { _ in },
                onCategoryChanged: { categoryID in
                    _ = try? autosave.update(categoryID: categoryID)
                },
                onRequestMarkdownImport: importMarkdown,
                onRequestMarkdownExport: exportMarkdown,
                onArchive: { Task { await archiveSelected() } },
                onRestore: { Task { await restoreSelected() } },
                onPermanentDelete: requestPermanentDeleteSelected,
                onOpenCalendarItem: openCalendarItem,
                showsBrowserButton: showsBrowserButton,
                onToggleBrowser: { browserCollapsed = false },
                sessionSink: { session in
                    if let session {
                        activeEditorSession = session
                    } else if activeEditorSession?.noteID == identity.noteID,
                              activeEditorSession?.editSessionID == identity.editSessionID {
                        activeEditorSession = nil
                    }
                },
                nativeFinalizerHook: $nativeFinalizer
            )
            .id(identity)
        } else {
            VStack(spacing: 0) {
                if showsBrowserButton {
                    HStack {
                        Button { browserCollapsed = false } label: {
                            Image(systemName: "sidebar.left")
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .help("显示笔记列表")
                        .accessibilityLabel("显示笔记列表")
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .frame(height: CalendarTheme.toolbarHeight)
                }
                ContentUnavailableView(
                    "选择或新建笔记",
                    systemImage: "note.text",
                    description: Text("打开笔记列表进行选择，或新建一篇笔记。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var sortedCategories: [CalendarCategory] {
        Array(store.calendarState.categories.values).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func registerRouteBridge() {
        transitionCoordinator?.attachNotesCloseBridge(closeBridge, finalizer: nativeFinalizer)
        terminationCoordinator?.updateDecision {
            await closeBridge.decision(for: .termination, finalizer: nativeFinalizer)
        }
    }

    private func selectNote(_ noteID: NoteID, initialFocus: NoteInitialFocus? = nil) async {
        let decision = await closeBridge.decision(for: .selection, finalizer: nativeFinalizer)
        guard decision == .allow else {
            statusBanner = "请先完成当前笔记的保存。"
            return
        }
        let sessionID = UUID()
        let host = UUID()
        guard (try? await viewModel.select(noteID, editSessionID: sessionID, activeHostToken: host)) == true else {
            return
        }
        editorInitialFocus = initialFocus
        editorIdentity = .init(noteID: noteID, editSessionID: sessionID)
        if NotesAdaptiveLayout.isCompact(width: availableWidth) { browserCollapsed = true }
        statusBanner = nil
    }

    private func openCalendarItem(_ itemID: UUID) {
        guard let transitionCoordinator else { return }
        Task {
            guard await transitionCoordinator.requestActivation(.calendar) else { return }
            deepLinkRouter.request(.calendarItem(itemID))
        }
    }

    private func consumeNoteDeepLink(_ request: WorkspaceDeepLinkRequest?) {
        guard let request,
              case let .note(noteID) = request.target,
              store.state.notes[noteID] != nil,
              deepLinkRouter.consume(request.id, target: request.target) != nil else { return }
        Task { await selectNote(noteID, initialFocus: .bodyStart) }
    }

    private func consumeNoteNewItemRequest(_ request: WorkspaceNewItemRequest?) {
        guard let request,
              request.route == .notes,
              newItemRouter.consume(request.id, route: .notes) != nil else { return }
        Task { await createNote() }
    }

    private func createNote() async {
        let decision = await closeBridge.decision(for: .selection, finalizer: nativeFinalizer)
        guard decision == .allow else {
            statusBanner = "请先完成当前笔记的保存。"
            return
        }
        let note = Note.empty(id: NoteID(), categoryID: store.calendarState.uncategorizedID, now: clock())
        guard (try? await viewModel.create(note)) == true else { return }
        if let selected = viewModel.selectedNoteID {
            editorInitialFocus = .title
            editorIdentity = .init(noteID: selected, editSessionID: UUID())
            if NotesAdaptiveLayout.isCompact(width: availableWidth) { browserCollapsed = true }
            if let created = store.state.notes[selected] {
                try? autosave.beginSession(
                    created,
                    linkedTaskBlockLinks: Set(store.state.taskBlockLinks.filter { $0.noteID == selected }),
                    editSessionID: editorIdentity!.editSessionID,
                    activeHostToken: UUID()
                )
            }
        }
    }

    private func archiveSelected() async {
        guard let noteID = viewModel.selectedNoteID else { return }
        let decision = await closeBridge.decision(for: .archive, finalizer: nativeFinalizer)
        guard decision == .allow else {
            statusBanner = "归档前需要完成主文件保存。"
            return
        }
        _ = try? await viewModel.archive(noteID)
        if let selected = viewModel.selectedNoteID {
            editorInitialFocus = nil
            editorIdentity = .init(noteID: selected, editSessionID: UUID())
        } else {
            editorInitialFocus = nil
            editorIdentity = nil
        }
    }

    private func restoreSelected() async {
        guard let noteID = viewModel.selectedNoteID else { return }
        do {
            _ = try await viewModel.restore(noteID)
            if let selected = viewModel.selectedNoteID {
                editorInitialFocus = nil
                editorIdentity = .init(noteID: selected, editSessionID: UUID())
            }
        } catch {
            statusBanner = "恢复笔记未完成。"
        }
    }

    private func requestPermanentDeleteSelected() {
        guard let noteID = viewModel.selectedNoteID else { return }
        do {
            let preview = try viewModel.permanentDeletePreview(for: noteID)
            pendingPermanentDelete = .init(noteID: noteID, preview: preview)
        } catch {
            statusBanner = "无法生成删除影响预览。"
        }
    }

    private func confirmPermanentDelete(_ request: PendingNotePermanentDelete) async {
        do {
            let authorization = PermanentDeleteAuthorization(
                subject: request.preview.subject,
                sourceWorkspaceRevision: request.preview.sourceWorkspaceRevision,
                impactChecksum: request.preview.checksum
            )
            _ = try await viewModel.permanentlyDelete(request.noteID, authorization: authorization)
            if let selected = viewModel.selectedNoteID {
                editorInitialFocus = nil
                editorIdentity = .init(noteID: selected, editSessionID: UUID())
            } else {
                editorInitialFocus = nil
                editorIdentity = nil
            }
        } catch {
            statusBanner = "永久删除未完成。"
        }
    }

    private func resolveRecovery(
        _ candidate: DraftRecoveryCandidate,
        action: DraftRecoveryAction
    ) async {
        do {
            _ = try await store.resolveDraftRecovery(candidate.token, action: action)
            recoveryCandidate = nil
            // Recovery and save-as-new always create a new editor key.
            if case let .saveAsNew(noteID, _) = action {
                editorInitialFocus = nil
                editorIdentity = .init(noteID: noteID, editSessionID: UUID())
            } else if let noteID = viewModel.selectedNoteID ?? store.state.notes.keys.first {
                editorInitialFocus = nil
                editorIdentity = .init(noteID: noteID, editSessionID: UUID())
            }
        } catch {
            statusBanner = "草稿恢复操作已过期，请重新选择。"
            refreshRecoveryPresentation()
        }
    }

    private func refreshRecoveryPresentation() {
        recoveryCandidate = DraftRecoveryPresentation.candidates(from: store).first
    }

    private func syncEditorNoteIfNeeded() {
        guard let identity = editorIdentity else { return }
        guard let note = store.state.notes[identity.noteID] else {
            editorInitialFocus = nil
            editorIdentity = nil
            return
        }
        guard let activeEditorSession,
              activeEditorSession.document != note.document,
              autosave.canReplaceSessionWithPersistedStoreSnapshot
        else { return }
        // A route transition has already sealed native input and proved the
        // current editor generation. Re-keying avoids stale undo/autosave
        // bases after Calendar changes the same Task Block document.
        let replacement = NoteEditorIdentity(noteID: note.id, editSessionID: UUID())
        do {
            try autosave.beginSession(
                note,
                linkedTaskBlockLinks: Set(store.state.taskBlockLinks.filter { $0.noteID == note.id }),
                editSessionID: replacement.editSessionID,
                activeHostToken: UUID()
            )
            editorInitialFocus = nil
            editorIdentity = replacement
            statusBanner = nil
        } catch {
            statusBanner = "笔记已在其他页面更新，请完成当前输入后重试。"
        }
    }

    private func importMarkdown() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.text, .plainText]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let markdown = try String(contentsOf: url, encoding: .utf8)
                    let plan = try NoteMarkdownCommands.planImport(
                        markdown: markdown,
                        mode: .replace,
                        checkedTaskCompletedAt: clock()
                    )
                    importDiagnostics = plan.result.diagnostics
                    pendingImportPlan = plan
                } catch {
                    statusBanner = "无法读取 Markdown 文件。"
                }
            }
        }
    }

    private func applyPendingImport(_ mode: BlockDocumentIngestMode) {
        guard let plan = pendingImportPlan else { return }
        pendingImportPlan = nil
        guard let session = activeEditorSession ?? nil else {
            // Fall back through autosave document update when session sink not yet wired.
            let document = plan.result.document
            switch mode {
            case .replace:
                _ = try? autosave.update(document: document)
            case .append:
                if let current = viewModel.selectedNote?.document {
                    let merged = BlockDocument(
                        schemaVersion: current.schemaVersion,
                        blocks: current.blocks + document.blocks
                    )
                    _ = try? autosave.update(document: merged)
                } else {
                    _ = try? autosave.update(document: document)
                }
            }
            statusBanner = importDiagnostics.isEmpty ? nil : "已导入（含诊断）。"
            return
        }
        do {
            _ = try session.dispatch(.applyDocumentBlocks(blocks: plan.result.document.blocks, mode: mode))
            statusBanner = importDiagnostics.isEmpty ? nil : "已导入（含诊断）。"
        } catch {
            statusBanner = "导入被拒绝：文档或 ID 无效。"
        }
    }

    private func exportMarkdown() {
        guard let note = viewModel.selectedNote else { return }
        let matchingSession: BlockEditorSession?
        if let editorIdentity,
           editorIdentity.noteID == note.id,
           let activeEditorSession,
           activeEditorSession.noteID == note.id,
           activeEditorSession.editSessionID == editorIdentity.editSessionID {
            matchingSession = activeEditorSession
        } else {
            matchingSession = nil
        }
        guard matchingSession?.terminallyFinalizeNativeComposition() != false else {
            statusBanner = "请先完成当前输入，再导出 Markdown。"
            return
        }
        let liveSnapshot = matchingSession.map {
            NoteMarkdownLiveSnapshot(
                noteID: $0.noteID,
                editSessionID: $0.editSessionID,
                document: $0.document
            )
        }
        let document = NoteMarkdownExportSource.document(
            persistedNoteID: note.id,
            persistedDocument: note.document,
            editorIdentity: editorIdentity,
            liveSnapshot: liveSnapshot
        )
        let markdown: String
        do {
            markdown = try NoteMarkdownCommands.exportMarkdown(from: document)
        } catch {
            statusBanner = "导出失败。"
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = (note.title.isEmpty ? "note" : note.title) + ".md"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try NoteMarkdownCommands.writeExport(markdown: markdown, to: url)
                    statusBanner = "Markdown 已导出。"
                } catch {
                    statusBanner = "导出失败。"
                }
            }
        }
    }
}

enum NotesAdaptiveLayout {
    static let compactThreshold: CGFloat = 760

    static func isCompact(width: CGFloat) -> Bool {
        width < compactThreshold
    }

    static func mode(
        width: CGFloat,
        browserCollapsed: Bool
    ) -> NotesSplitView.NotesAdaptiveLayoutMode {
        if browserCollapsed { return .editorOnly }
        return isCompact(width: width) ? .browserOnly : .split
    }
}

extension DraftRecoveryCandidate: Identifiable {
    var id: DraftRecoveryToken { token }
}

private struct PendingNotePermanentDelete {
    let noteID: NoteID
    let preview: PermanentDeletePreview
}
