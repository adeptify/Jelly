import AppKit
import SwiftUI
import WorkspaceDomain

@MainActor
struct BlockEditorView: View {
    private let key: BlockEditorKey
    private let initialDocument: BlockDocument
    private let initialSelection: BlockEditorSelection
    private let focusRegistry: EditorFocusRegistry
    private let onDocumentChange: (BlockDocument) -> Void
    private let sessionSink: ((BlockEditorSession) -> Void)?
    private let taskCalendarContext: TaskBlockCalendarContext?

    init(
        noteID: NoteID,
        editSessionID: UUID,
        initialDocument: BlockDocument,
        initialSelection: BlockEditorSelection,
        focusRegistry: EditorFocusRegistry,
        onDocumentChange: @escaping (BlockDocument) -> Void,
        sessionSink: ((BlockEditorSession) -> Void)? = nil,
        taskCalendarContext: TaskBlockCalendarContext? = nil
    ) {
        key = .init(noteID: noteID, editSessionID: editSessionID)
        self.initialDocument = initialDocument
        self.initialSelection = initialSelection
        self.focusRegistry = focusRegistry
        self.onDocumentChange = onDocumentChange
        self.sessionSink = sessionSink
        self.taskCalendarContext = taskCalendarContext
    }

    var body: some View {
        BlockEditorSessionHost(
            key: key,
            initialDocument: initialDocument,
            initialSelection: initialSelection,
            focusRegistry: focusRegistry,
            onDocumentChange: onDocumentChange,
            sessionSink: sessionSink,
            taskCalendarContext: taskCalendarContext
        )
        .id(key)
    }
}

private struct BlockEditorKey: Hashable {
    let noteID: NoteID
    let editSessionID: UUID
}

@MainActor
private struct BlockEditorSessionHost: View {
    @StateObject private var session: BlockEditorSession
    private let sessionSink: ((BlockEditorSession) -> Void)?
    private let taskCalendarContext: TaskBlockCalendarContext?
    @State private var scheduleRequest: TaskBlockScheduleRequest?
    @Environment(\.colorScheme) private var colorScheme

    init(
        key: BlockEditorKey,
        initialDocument: BlockDocument,
        initialSelection: BlockEditorSelection,
        focusRegistry: EditorFocusRegistry,
        onDocumentChange: @escaping (BlockDocument) -> Void,
        sessionSink: ((BlockEditorSession) -> Void)?,
        taskCalendarContext: TaskBlockCalendarContext?
    ) {
        _session = StateObject(wrappedValue: BlockEditorSession(
            noteID: key.noteID,
            editSessionID: key.editSessionID,
            initialDocument: initialDocument,
            initialSelection: initialSelection,
            focusRegistry: focusRegistry,
            onDocumentChange: onDocumentChange
        ))
        self.sessionSink = sessionSink
        self.taskCalendarContext = taskCalendarContext
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ContinuousBlockEditorRepresentable(
                session: session,
                appearance: CalendarTheme.appearance(for: colorScheme)
            )
            .frame(minHeight: 80)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("continuous-block-editor-host")
            if let taskCalendarContext, let blockID = session.focusedTaskBlockID {
                TaskBlockCalendarBadge(
                    store: taskCalendarContext.store,
                    noteID: session.noteID,
                    blockID: blockID,
                    onSchedule: {
                        scheduleRequest = .init(blockID: blockID)
                    },
                    onUnlink: {
                        Task {
                            _ = try? await TaskBlockCalendarIntegration.unlinkFromBlock(
                                store: taskCalendarContext.store,
                                noteID: session.noteID,
                                blockID: blockID
                            )
                        }
                    },
                    onOpenItem: taskCalendarContext.onOpenItem,
                    onToggleCompletion: {
                        toggleTaskCompletion(blockID: blockID, context: taskCalendarContext)
                    }
                )
            }
            if let state = session.slashMenuState {
                BlockSlashMenu(
                    state: state,
                    options: session.slashOptions,
                    onChoose: { _ = session.confirmSlash(kind: $0, expected: state) },
                    onDismiss: { session.dismissSlashMenu(expected: state) }
                )
            }
            Color.clear
                .frame(height: 20)
                .contentShape(Rectangle())
                .accessibilityLabel("定位到文档末尾")
                .onTapGesture { session.focusDocumentEnd() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("结构化笔记编辑器")
        .onAppear { sessionSink?(session) }
        .onChange(of: session.document) { _, _ in sessionSink?(session) }
        .sheet(item: $scheduleRequest) { request in
            if let taskCalendarContext {
                TaskBlockScheduleSheet(
                    store: taskCalendarContext.store,
                    noteID: session.noteID,
                    blockID: request.blockID,
                    now: taskCalendarContext.now(),
                    onCancel: { scheduleRequest = nil },
                    onScheduled: { scheduleRequest = nil }
                )
            }
        }
    }

    private func toggleTaskCompletion(blockID: BlockID, context: TaskBlockCalendarContext) {
        Task {
            guard let link = TaskBlockCalendarIntegration.link(
                for: context.store,
                noteID: session.noteID,
                blockID: blockID
            ), let item = context.store.calendarState.items[link.calendarItemID] else { return }
            if item.completedAt == nil {
                _ = try? await TaskBlockCalendarIntegration.completeFromBlock(
                    store: context.store,
                    noteID: session.noteID,
                    blockID: blockID,
                    at: context.now()
                )
            } else {
                _ = try? await TaskBlockCalendarIntegration.reopenFromBlock(
                    store: context.store,
                    noteID: session.noteID,
                    blockID: blockID
                )
            }
        }
    }

}

private struct TaskBlockScheduleRequest: Identifiable {
    let id = UUID()
    let blockID: BlockID
}

private struct BlockDragHandle: View {
    let blockID: BlockID
    let index: Int
    let total: Int
    let session: BlockEditorSession
    let dragHandler: BlockDragDropHandler
    @State private var isHovered = false

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .opacity(isHovered ? 1 : 0.45)
            .onHover { isHovered = $0 }
            .overlay {
                BlockSelectionHandleRepresentable(
                    blockID: blockID,
                    index: index,
                    total: total,
                    session: session,
                    dragHandler: dragHandler
                )
            }
    }
}

private struct BlockSelectionHandleRepresentable: NSViewRepresentable {
    let blockID: BlockID
    let index: Int
    let total: Int
    let session: BlockEditorSession
    let dragHandler: BlockDragDropHandler

    func makeNSView(context: Context) -> BlockSelectionHandleView {
        let view = BlockSelectionHandleView()
        view.configure(
            blockID: blockID,
            index: index,
            total: total,
            session: session,
            dragHandler: dragHandler
        )
        return view
    }

    func updateNSView(_ nsView: BlockSelectionHandleView, context: Context) {
        nsView.configure(
            blockID: blockID,
            index: index,
            total: total,
            session: session,
            dragHandler: dragHandler
        )
    }
}

@MainActor
final class BlockSelectionHandleView: NSView, NSDraggingSource {
    private var blockID: BlockID?
    private var index = 0
    private var total = 0
    private weak var session: BlockEditorSession?
    private var dragHandler: BlockDragDropHandler?

    override var acceptsFirstResponder: Bool { true }
    var representedBlockID: BlockID? { blockID }

    func configure(
        blockID: BlockID,
        index: Int,
        total: Int,
        session: BlockEditorSession,
        dragHandler: BlockDragDropHandler
    ) {
        self.blockID = blockID
        self.index = index
        self.total = total
        self.session = session
        self.dragHandler = dragHandler
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("移动 Block")
        setAccessibilityValue("第 \(index + 1) 项，共 \(total) 项")
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Move Up") { [weak self] in
                self?.performAccessibilityAction(named: "Move Up") ?? false
            },
            NSAccessibilityCustomAction(name: "Move Down") { [weak self] in
                self?.performAccessibilityAction(named: "Move Down") ?? false
            }
        ])
    }

    override func mouseDown(with event: NSEvent) {
        guard let blockID else { return }
        if event.modifierFlags.contains(.shift) {
            _ = session?.extendBlockSelection(to: blockID)
        } else {
            _ = session?.beginBlockSelection(blockID: blockID)
        }
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let blockID,
              let dragHandler,
              let data = try? dragHandler.payloadData(for: dragHandler.dragRoots(startingAt: blockID)) else { return }
        let item = NSPasteboardItem()
        item.setData(data, forType: .init(BlockDragDropHandler.pasteboardType))
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        draggingItem.setDraggingFrame(bounds, contents: self)
        _ = beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func keyDown(with event: NSEvent) {
        guard blockID != nil, session != nil else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 126:
            _ = move(by: -1)
        case 125:
            _ = move(by: 1)
        default:
            super.keyDown(with: event)
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation { .move }

    @discardableResult
    func performAccessibilityAction(named name: String) -> Bool {
        switch name {
        case "Move Up": move(by: -1)
        case "Move Down": move(by: 1)
        default: false
        }
    }

    private func move(by delta: Int) -> Bool {
        guard let blockID, let session, let dragHandler else { return false }
        let roots = dragHandler.dragRoots(startingAt: blockID)
        if delta < 0 { return BlockDragCoordinator(session: session).moveUp(roots: roots) }
        return BlockDragCoordinator(session: session).moveDown(roots: roots)
    }
}

private struct BlockEditorDropDelegate: DropDelegate {
    let handler: BlockDragDropHandler
    let before: BlockID?

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [BlockDragDropHandler.pasteboardType]).first else { return false }
        return handler.performDrop(provider: provider, before: before)
    }
}

struct BlockAccessibilityDescriptor {
    let blockID: BlockID
    let index: Int
    let totalCount: Int
    let kind: BlockKind
    let value: String
    let isSelected: Bool

    var identifier: String { blockID.rawValue.uuidString }
    var positionAnnouncement: String { "第 \(index + 1) 项，共 \(totalCount) 项" }
    var role: NSAccessibility.Role { kind == .divider ? .splitter : .textArea }
    var reorderActions: [String] { ["Move Up", "Move Down"] }
}
