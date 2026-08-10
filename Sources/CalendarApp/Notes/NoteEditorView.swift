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
    var onPermanentDelete: () -> Void
    var nativeFinalizerHook: Binding<NoteNativeInputFinalizer?>

    @State private var title: String
    @State private var titleOwnerID = UUID()
    @State private var titleCoordinator: NoteTitleTextField.Coordinator?
    @State private var editorSession: BlockEditorSession?

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
        onPermanentDelete: @escaping () -> Void = {},
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
        self.onPermanentDelete = onPermanentDelete
        self.nativeFinalizerHook = nativeFinalizerHook
        _title = State(initialValue: note.title)
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

                Menu("更多") {
                    Button("导入 Markdown…", action: onRequestMarkdownImport)
                    Button("导出 Markdown…", action: onRequestMarkdownExport)
                    Divider()
                    if note.archivedAt == nil {
                        Button("归档", action: onArchive)
                    }
                    Button("永久删除…", role: .destructive, action: onPermanentDelete)
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
                    onDocumentChange: { document in
                        _ = try? autosave.update(document: document)
                        onDocumentCommitted(document)
                    },
                    sessionSink: { editorSession = $0 }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .id(identity)
        .onAppear { installNativeFinalizer() }
        .onChange(of: identity) { _, _ in installNativeFinalizer() }
        .onDisappear {
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
