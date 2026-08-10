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
    let clock: @Sendable () -> Date

    @State private var viewModel: NotesWorkspaceViewModel
    @State private var autosave: NoteAutosaveCoordinator
    @State private var closeBridge: NoteCloseProtectionBridge
    @State private var editorIdentity: NoteEditorIdentity?
    @State private var nativeFinalizer: NoteNativeInputFinalizer?
    @State private var showCategoryManager = false
    @State private var browserCollapsed = false
    @State private var recoveryCandidate: DraftRecoveryCandidate?
    @State private var importDiagnostics: [BlockMarkdownDiagnostic] = []
    @State private var pendingImportPlan: NoteMarkdownImportPlan?
    @State private var statusBanner: String?
    @State private var activeEditorSession: BlockEditorSession?

    init(
        store: WorkspaceStore,
        focusRegistry: EditorFocusRegistry,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.focusRegistry = focusRegistry
        self.clock = clock
        let autosave = NoteAutosaveCoordinator(store: store)
        let viewModel = NotesWorkspaceViewModel(store: store, autosave: autosave, clock: clock)
        _autosave = State(initialValue: autosave)
        _viewModel = State(initialValue: viewModel)
        _closeBridge = State(initialValue: NoteCloseProtectionBridge(coordinator: autosave))
    }

    var body: some View {
        HSplitView {
            if !browserCollapsed {
                NoteBrowserView(
                    viewModel: viewModel,
                    onSelect: { await selectNote($0) },
                    onCreate: { await createNote() },
                    onShowCategoryManager: { showCategoryManager = true }
                )
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
            }

            editorColumn
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .topLeading) {
            Button {
                browserCollapsed.toggle()
            } label: {
                Image(systemName: browserCollapsed ? "sidebar.left" : "sidebar.squares.left")
            }
            .buttonStyle(.borderless)
            .padding(8)
            .accessibilityLabel(browserCollapsed ? "显示笔记列表" : "隐藏笔记列表")
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
        .onAppear {
            refreshRecoveryPresentation()
        }
        .onChange(of: store.statePublicationGeneration) { _, _ in
            refreshRecoveryPresentation()
            syncEditorNoteIfNeeded()
        }
        .onChange(of: store.phase) { _, _ in
            refreshRecoveryPresentation()
        }
        .background(NotesWindowCloseMonitor(bridge: closeBridge, finalizer: nativeFinalizer))
    }

    @ViewBuilder
    private var editorColumn: some View {
        if let identity = editorIdentity, let note = store.state.notes[identity.noteID] {
            NoteEditorView(
                identity: identity,
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
                onPermanentDelete: { Task { await permanentDeleteSelected() } },
                nativeFinalizerHook: $nativeFinalizer
            )
        } else {
            ContentUnavailableView(
                "选择或新建笔记",
                systemImage: "note.text",
                description: Text("左侧列表选择一篇笔记，或点击新建。")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sortedCategories: [CalendarCategory] {
        Array(store.calendarState.categories.values).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func selectNote(_ noteID: NoteID) async {
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
        editorIdentity = .init(noteID: noteID, editSessionID: sessionID)
        statusBanner = nil
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
            editorIdentity = .init(noteID: selected, editSessionID: UUID())
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
            editorIdentity = .init(noteID: selected, editSessionID: UUID())
        } else {
            editorIdentity = nil
        }
    }

    private func permanentDeleteSelected() async {
        guard let noteID = viewModel.selectedNoteID else { return }
        do {
            let preview = try viewModel.permanentDeletePreview(for: noteID)
            let authorization = PermanentDeleteAuthorization(
                subject: preview.subject,
                sourceWorkspaceRevision: preview.sourceWorkspaceRevision,
                impactChecksum: preview.checksum
            )
            _ = try await viewModel.permanentlyDelete(noteID, authorization: authorization)
            if let selected = viewModel.selectedNoteID {
                editorIdentity = .init(noteID: selected, editSessionID: UUID())
            } else {
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
                editorIdentity = .init(noteID: noteID, editSessionID: UUID())
            } else if let noteID = viewModel.selectedNoteID ?? store.state.notes.keys.first {
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
        if store.state.notes[identity.noteID] == nil {
            editorIdentity = nil
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
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = (note.title.isEmpty ? "note" : note.title) + ".md"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let markdown = try NoteMarkdownCommands.exportMarkdown(from: note.document)
                    try NoteMarkdownCommands.writeExport(markdown: markdown, to: url)
                    statusBanner = "Markdown 已导出。"
                } catch {
                    statusBanner = "导出失败。"
                }
            }
        }
    }
}

extension DraftRecoveryCandidate: Identifiable {
    var id: DraftRecoveryToken { token }
}

/// Placeholder host for future AppKit windowShouldClose wiring (Task 10D).
/// Close truth is enforced through `NoteCloseProtectionBridge` unit tests and
/// the production delegate installed when Notes is feature-activated.
private struct NotesWindowCloseMonitor: NSViewRepresentable {
    let bridge: NoteCloseProtectionBridge
    let finalizer: NoteNativeInputFinalizer?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
