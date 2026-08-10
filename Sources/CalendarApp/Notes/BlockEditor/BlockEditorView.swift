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
    private let requestLinkURL: () -> URL?

    init(
        noteID: NoteID,
        editSessionID: UUID,
        initialDocument: BlockDocument,
        initialSelection: BlockEditorSelection,
        focusRegistry: EditorFocusRegistry,
        onDocumentChange: @escaping (BlockDocument) -> Void,
        requestLinkURL: @escaping () -> URL? = { BlockLinkPrompt.requestURL() }
    ) {
        key = .init(noteID: noteID, editSessionID: editSessionID)
        self.initialDocument = initialDocument
        self.initialSelection = initialSelection
        self.focusRegistry = focusRegistry
        self.onDocumentChange = onDocumentChange
        self.requestLinkURL = requestLinkURL
    }

    var body: some View {
        BlockEditorSessionHost(
            key: key,
            initialDocument: initialDocument,
            initialSelection: initialSelection,
            focusRegistry: focusRegistry,
            onDocumentChange: onDocumentChange,
            requestLinkURL: requestLinkURL
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
    private let requestLinkURL: () -> URL?

    init(
        key: BlockEditorKey,
        initialDocument: BlockDocument,
        initialSelection: BlockEditorSelection,
        focusRegistry: EditorFocusRegistry,
        onDocumentChange: @escaping (BlockDocument) -> Void,
        requestLinkURL: @escaping () -> URL?
    ) {
        _session = StateObject(wrappedValue: BlockEditorSession(
            noteID: key.noteID,
            editSessionID: key.editSessionID,
            initialDocument: initialDocument,
            initialSelection: initialSelection,
            focusRegistry: focusRegistry,
            onDocumentChange: onDocumentChange
        ))
        self.requestLinkURL = requestLinkURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if session.showsInlineFormattingControls {
                BlockFormattingControls(session: session, requestLinkURL: requestLinkURL)
            }
            ForEach(Array(session.document.blocks.enumerated()), id: \.element.id) { index, block in
                let dragHandler = BlockDragDropHandler(session: session)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    BlockDragHandle(
                        blockID: block.id,
                        index: index,
                        total: session.document.blocks.count,
                        session: session,
                        dragHandler: dragHandler
                    )
                    BlockEditorTextViewRepresentable(blockID: block.id, session: session)
                        .frame(minHeight: rowHeight(for: block.kind))
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier(block.id.rawValue.uuidString)
                }
                .onDrop(
                    of: [BlockDragDropHandler.pasteboardType],
                    delegate: BlockEditorDropDelegate(handler: dragHandler, before: block.id)
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
                .accessibilityLabel("移动到文档末尾")
                .onDrop(
                    of: [BlockDragDropHandler.pasteboardType],
                    delegate: BlockEditorDropDelegate(handler: BlockDragDropHandler(session: session), before: nil)
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("结构化笔记编辑器")
    }

    private func rowHeight(for kind: BlockKind) -> CGFloat {
        switch kind {
        case .heading1: 38
        case .heading2: 34
        case .heading3: 30
        case .divider: 22
        case .paragraph, .bullet, .ordered, .task, .quote, .code, .link: 26
        }
    }
}

private struct BlockFormattingControls: View {
    @ObservedObject var session: BlockEditorSession
    let requestLinkURL: () -> URL?

    var body: some View {
        HStack(spacing: 6) {
            formattingButton("B", identifier: "block-format-bold", help: "粗体") {
                _ = session.dispatchTextCommand(.toggleInlineMark(.bold))
            }
            formattingButton("I", identifier: "block-format-italic", help: "斜体") {
                _ = session.dispatchTextCommand(.toggleInlineMark(.italic))
            }
            formattingButton("</>", identifier: "block-format-code", help: "行内代码") {
                _ = session.dispatchTextCommand(.toggleInlineMark(.code))
            }
            formattingButton("Link", identifier: "block-format-link", help: "添加或移除链接") {
                toggleLink()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("文本格式")
    }

    private func formattingButton(
        _ title: String,
        identifier: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        BlockFormattingButtonRepresentable(
            title: title,
            identifier: identifier,
            help: help,
            action: { session.performAuxiliaryControlAction(action) }
        )
        .frame(minWidth: 30, minHeight: 24)
    }

    private func toggleLink() {
        if session.selectionContainsLink {
            _ = session.dispatchTextCommand(.setLink(nil))
            return
        }
        if let clipboardValue = NSPasteboard.general.string(forType: .string),
           let clipboardURL = URL(string: clipboardValue),
           BlockURLValidator.isValid(clipboardURL) {
            _ = session.dispatchTextCommand(.setLink(clipboardURL))
            return
        }
        guard let url = requestLinkURL(),
              BlockURLValidator.isValid(url) else { return }
        _ = session.dispatchTextCommand(.setLink(url))
    }
}

@MainActor
private enum BlockLinkPrompt {
    static func requestURL() -> URL? {
        let field = NSTextField(string: "https://")
        field.frame = .init(x: 0, y: 0, width: 280, height: 24)
        let alert = NSAlert()
        alert.messageText = "添加链接"
        alert.informativeText = "输入所选文本要打开的完整网址。"
        alert.accessoryView = field
        alert.addButton(withTitle: "应用")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return URL(string: field.stringValue)
    }
}

private struct BlockFormattingButtonRepresentable: NSViewRepresentable {
    let title: String
    let identifier: String
    let help: String
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.performAction))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.toolTip = help
        button.setAccessibilityIdentifier(identifier)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        nsView.title = title
        nsView.toolTip = help
        nsView.setAccessibilityIdentifier(identifier)
        context.coordinator.action = action
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func performAction() { action() }
    }
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
