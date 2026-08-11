import AppKit
import CalendarDomain
import SwiftUI
import WorkspaceDomain

struct NoteEditorIdentity: Hashable, Sendable {
    let noteID: NoteID
    let editSessionID: UUID
}

/// Right-hand Notes editor surface. Ordinary Store publications keep the same
/// `EditorKey`; selection changes and recovery/save-as-new mint a new one.
struct NoteEditorView: View {
    let identity: NoteEditorIdentity
    let note: Note
    let focusRegistry: EditorFocusRegistry
    let autosave: NoteAutosaveCoordinator
    let store: WorkspaceStore
    let categories: [CalendarCategory]
    var onDocumentCommitted: (BlockDocument) -> Void
    var onTitleCommitted: (String) -> Void
    var onCategoryChanged: (UUID) -> Void
    var onRequestMarkdownImport: () -> Void
    var onRequestMarkdownExport: () -> Void
    var onArchive: () -> Void
    var onRestore: () -> Void
    var onPermanentDelete: () -> Void
    var onOpenCalendarItem: (UUID) -> Void
    var sessionSink: (BlockEditorSession?) -> Void
    var nativeFinalizerHook: Binding<NoteNativeInputFinalizer?>

    @State private var title: String
    @State private var titleOwnerID = UUID()
    @State private var titleCoordinator: NoteTitleTextField.Coordinator?
    @State private var editorSession: BlockEditorSession?
    @State private var showCalendarLinks = false
    @State private var showScheduleSheet = false
    @State private var lastAcceptedDocument: BlockDocument
    @State private var pendingLinkedTaskDeletion: PendingLinkedTaskDeletion?

    init(
        identity: NoteEditorIdentity,
        note: Note,
        focusRegistry: EditorFocusRegistry,
        autosave: NoteAutosaveCoordinator,
        store: WorkspaceStore,
        categories: [CalendarCategory],
        onDocumentCommitted: @escaping (BlockDocument) -> Void,
        onTitleCommitted: @escaping (String) -> Void,
        onCategoryChanged: @escaping (UUID) -> Void,
        onRequestMarkdownImport: @escaping () -> Void,
        onRequestMarkdownExport: @escaping () -> Void,
        onArchive: @escaping () -> Void = {},
        onRestore: @escaping () -> Void = {},
        onPermanentDelete: @escaping () -> Void = {},
        onOpenCalendarItem: @escaping (UUID) -> Void = { _ in },
        sessionSink: @escaping (BlockEditorSession?) -> Void,
        nativeFinalizerHook: Binding<NoteNativeInputFinalizer?>
    ) {
        self.identity = identity
        self.note = note
        self.focusRegistry = focusRegistry
        self.autosave = autosave
        self.store = store
        self.categories = categories
        self.onDocumentCommitted = onDocumentCommitted
        self.onTitleCommitted = onTitleCommitted
        self.onCategoryChanged = onCategoryChanged
        self.onRequestMarkdownImport = onRequestMarkdownImport
        self.onRequestMarkdownExport = onRequestMarkdownExport
        self.onArchive = onArchive
        self.onRestore = onRestore
        self.onPermanentDelete = onPermanentDelete
        self.onOpenCalendarItem = onOpenCalendarItem
        self.sessionSink = sessionSink
        self.nativeFinalizerHook = nativeFinalizerHook
        _title = State(initialValue: note.title)
        _lastAcceptedDocument = State(initialValue: note.document)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                NoteTitleTextField(
                    title: $title,
                    focusRegistry: focusRegistry,
                    ownerID: titleOwnerID,
                    onCommit: { value in
                        title = value
                        onTitleCommitted(value)
                    },
                    onEditingChanged: { value in
                        title = value
                        _ = try? autosave.update(title: value)
                    },
                    coordinatorSink: { titleCoordinator = $0 }
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("安排到日历…") { showScheduleSheet = true }
                    .accessibilityLabel("从笔记安排到日历")

                Button("日历关系") { showCalendarLinks = true }
                    .popover(isPresented: $showCalendarLinks) {
                        NoteCalendarLinksPopover(
                            store: store,
                            noteID: identity.noteID,
                            onOpenItem: onOpenCalendarItem
                        )
                    }

                Menu("更多") {
                    Button("导入 Markdown…", action: onRequestMarkdownImport)
                    Button("导出 Markdown…", action: onRequestMarkdownExport)
                    Divider()
                    if note.archivedAt == nil {
                        Button("归档", action: onArchive)
                    } else {
                        Button("恢复", action: onRestore)
                        Button("永久删除…", role: .destructive, action: onPermanentDelete)
                    }
                }
                .accessibilityLabel("笔记更多操作")
            }

            if let status = autosave.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel(status)
            }

            Picker("分类", selection: Binding(
                get: { note.categoryID },
                set: { onCategoryChanged($0) }
            )) {
                ForEach(categories, id: \.id) { category in
                    Text(category.name).tag(category.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220, alignment: .leading)
            .accessibilityLabel("笔记分类")

            ScrollView {
                BlockEditorView(
                    noteID: identity.noteID,
                    editSessionID: identity.editSessionID,
                    initialDocument: note.document,
                    initialSelection: defaultSelection(in: note.document),
                    focusRegistry: focusRegistry,
                    onDocumentChange: handleDocumentChange,
                    sessionSink: {
                        editorSession = $0
                        sessionSink($0)
                    },
                    taskCalendarContext: .init(
                        store: store,
                        onOpenItem: onOpenCalendarItem
                    )
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .sheet(isPresented: $showScheduleSheet) {
            NoteScheduleSheet(
                store: store,
                noteID: identity.noteID,
                onCancel: { showScheduleSheet = false },
                onScheduled: { itemID in
                    showScheduleSheet = false
                    onOpenCalendarItem(itemID)
                }
            )
        }
        .confirmationDialog(
            "删除已关联待办？",
            isPresented: Binding(
                get: { pendingLinkedTaskDeletion != nil },
                set: { if !$0 { cancelLinkedTaskDeletion() } }
            ),
            titleVisibility: .visible
        ) {
            Button("保留独立日历事项") {
                confirmLinkedTaskDeletion(.keepCalendarItem)
            }
            Button("一起删除", role: .destructive) {
                confirmLinkedTaskDeletion(.deleteCalendarItem)
            }
            Button("取消", role: .cancel) {
                cancelLinkedTaskDeletion()
            }
        } message: {
            let count = pendingLinkedTaskDeletion?.blockIDs.count ?? 0
            Text(count > 1
                ? "这次删除包含 \(count) 个已关联待办。请选择对应日历事项的处理方式。"
                : "这个待办已关联日历事项。请选择日历事项的处理方式。")
        }
        .onAppear { installNativeFinalizer() }
        .onChange(of: identity) { _, _ in installNativeFinalizer() }
        .onDisappear {
            sessionSink(nil)
            if nativeFinalizerHook.wrappedValue != nil {
                // Only clear when this identity still owns the hook.
                nativeFinalizerHook.wrappedValue = nil
            }
        }
    }

    private func installNativeFinalizer() {
        nativeFinalizerHook.wrappedValue = { [titleCoordinator, editorSession] permit, accept in
            // Title field first — at most one focused field-editor may consume.
            if let titleCoordinator, titleCoordinator.terminallyFinalizeNativeComposition() == false {
                return false
            }
            if let editorSession, editorSession.terminallyFinalizeNativeComposition() == false {
                return false
            }
            let edit = NoteNativeInputEdit(
                title: titleCoordinator?.field?.stringValue,
                document: editorSession?.document
            )
            // No pending candidate after successful unmark is still success.
            if edit.title == nil, edit.document == nil {
                return true
            }
            return accept(permit, edit)
        }
    }

    private func handleDocumentChange(_ document: BlockDocument) {
        guard pendingLinkedTaskDeletion == nil else { return }
        let linkedBlocks = TaskBlockDeletionConfirmation.requiredLinkedBlocks(
            noteID: identity.noteID,
            before: lastAcceptedDocument,
            after: document,
            links: store.state.taskBlockLinks
        )
        guard !linkedBlocks.isEmpty else {
            acceptDocument(document, dispositions: [:])
            return
        }
        pendingLinkedTaskDeletion = .init(document: document, blockIDs: linkedBlocks)
    }

    private func confirmLinkedTaskDeletion(_ disposition: LinkedTaskBlockDeletionDisposition) {
        guard let pending = pendingLinkedTaskDeletion else { return }
        pendingLinkedTaskDeletion = nil
        acceptDocument(
            pending.document,
            dispositions: Dictionary(uniqueKeysWithValues: pending.blockIDs.map { ($0, disposition) })
        )
    }

    private func cancelLinkedTaskDeletion() {
        guard pendingLinkedTaskDeletion != nil else { return }
        pendingLinkedTaskDeletion = nil
        editorSession?.undoManager.undo()
    }

    private func acceptDocument(
        _ document: BlockDocument,
        dispositions: [BlockID: LinkedTaskBlockDeletionDisposition]
    ) {
        do {
            _ = try autosave.update(
                document: document,
                linkedBlockDeletionDispositions: dispositions
            )
            lastAcceptedDocument = document
            onDocumentCommitted(document)
        } catch {
            editorSession?.autosaveDidResolve(.failed("无法保存这次正文修改。"))
        }
    }

    private func defaultSelection(in document: BlockDocument) -> BlockEditorSelection {
        let block = document.blocks.first ?? DocumentBlock(
            id: BlockID(),
            kind: .paragraph,
            inlineContent: .plain(""),
            taskState: nil,
            indentLevel: 0
        )
        return .text(
            anchor: .init(blockID: block.id, graphemeOffset: 0),
            focus: .init(blockID: block.id, graphemeOffset: 0),
            preferredColumn: nil,
            typingAttributes: .init(marks: [], linkURL: nil)
        )
    }
}

private struct PendingLinkedTaskDeletion {
    let document: BlockDocument
    let blockIDs: [BlockID]
}
