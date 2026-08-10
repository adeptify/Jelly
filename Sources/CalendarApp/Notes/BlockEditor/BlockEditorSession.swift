import AppKit
import Combine
import Foundation
import WorkspaceDomain

enum BlockEditorSaveStatus: Equatable, Sendable {
    case idle
    case saving
    case saved
    case failed(String)
}

struct BlockEditorDispatchOutcome: Equatable, Sendable {
    let result: BlockInputResult
    let commandHandled: Bool
}

@MainActor
protocol BlockEditorSessionContract: AnyObject {
    var noteID: NoteID { get }
    var editSessionID: UUID { get }
    var undoManager: UndoManager { get }
    var document: BlockDocument { get }
    var selection: BlockEditorSelection { get }
    func attach(blockID: BlockID, hostToken: UUID, textView: BlockEditorTextView)
    func detach(hostToken: UUID)
    func dispatch(_ command: BlockInputCommand) throws -> BlockEditorDispatchOutcome
    func autosaveDidResolve(_ status: BlockEditorSaveStatus)
}

enum BlockEditorIntegrationError: Error, Equatable, Sendable {
    case illegalResult
    case clipboardWriteFailed
}

@MainActor
final class BlockEditorSession: ObservableObject, BlockEditorSessionContract {
    let noteID: NoteID
    let editSessionID: UUID
    let undoManager: UndoManager
    @Published private(set) var document: BlockDocument
    @Published private(set) var selection: BlockEditorSelection
    @Published private(set) var saveStatus: BlockEditorSaveStatus = .idle
    @Published private(set) var slashMenuState: BlockSlashMenuState?

    private let focusRegistry: EditorFocusRegistry
    private let onDocumentChange: (BlockDocument) -> Void
    private let pasteboardAdapter: BlockPasteboardAdapter
    private let selectionController: BlockSelectionController
    private var hosts: [UUID: HostLease] = [:]
    private var activeHostTokens: [BlockID: UUID] = [:]
    private var typingRecord: TypingUndoRecord?
    private var composition: CompositionBaseline?
    private var compositionGeneration: UInt = 0
    private var terminalComposition: TerminalComposition?
    private var isProjecting = false
    private var editorRevision: UInt = 0
    private var dismissedSlash: DismissedSlash?

    init(
        noteID: NoteID,
        editSessionID: UUID,
        initialDocument: BlockDocument,
        initialSelection: BlockEditorSelection,
        focusRegistry: EditorFocusRegistry,
        onDocumentChange: @escaping (BlockDocument) -> Void
    ) {
        self.noteID = noteID
        self.editSessionID = editSessionID
        document = initialDocument
        selection = initialSelection
        self.focusRegistry = focusRegistry
        self.onDocumentChange = onDocumentChange
        undoManager = UndoManager()
        pasteboardAdapter = BlockPasteboardAdapter()
        selectionController = BlockSelectionController(selection: initialSelection)
    }

    func attach(blockID: BlockID, hostToken: UUID, textView: BlockEditorTextView) {
        if let replacedToken = activeHostTokens[blockID], replacedToken != hostToken {
            if composition?.hostToken == replacedToken {
                cancelComposition(hostToken: replacedToken)
            }
            hosts.removeValue(forKey: replacedToken)
            focusRegistry.clear(ownerID: replacedToken)
        }
        hosts[hostToken] = HostLease(blockID: blockID, token: hostToken, textView: textView)
        activeHostTokens[blockID] = hostToken
        textView.install(session: self, blockID: blockID, hostToken: hostToken)
        projectAuthoritativeState()
    }

    func detach(hostToken: UUID) {
        guard let lease = hosts[hostToken] else { return }
        if composition?.hostToken == hostToken { cancelComposition(hostToken: hostToken) }
        hosts.removeValue(forKey: hostToken)
        if activeHostTokens[lease.blockID] == hostToken { activeHostTokens[lease.blockID] = nil }
        focusRegistry.clear(ownerID: hostToken)
    }

    func focus(hostToken: UUID) {
        guard isActiveHost(hostToken) else { return }
        focusRegistry.register(undoManager, ownerID: hostToken)
    }

    func blur(hostToken: UUID) {
        focusRegistry.clear(ownerID: hostToken)
    }

    func dispatch(_ command: BlockInputCommand) throws -> BlockEditorDispatchOutcome {
        let result = try BlockInputReducer.reduce(
            document,
            selection: selection,
            command: command,
            environment: .init(isComposingText: composition != nil, idSource: .random)
        )
        return try consume(result)
    }

    func autosaveDidResolve(_ status: BlockEditorSaveStatus) {
        saveStatus = status
    }

    func projectAuthoritativeState() {
        guard !isProjecting else { return }
        isProjecting = true
        defer { isProjecting = false }
        for lease in hosts.values {
            guard let view = lease.textView else { continue }
            guard let block = document.blocks.first(where: { $0.id == lease.blockID }) else { continue }
            let text = Self.text(block)
            let range = BlockSelectionController(selection: selection).projectedRange(for: lease.blockID, document: document)
                ?? .init(location: text.utf16.count, length: 0)
            view.applyAuthoritativeProjection(
                block: block,
                selectedRange: range,
                isSelected: isSelectionIncluding(blockID: lease.blockID)
            )
        }
    }

    var showsInlineFormattingControls: Bool {
        guard let range = normalizedFormattingRange(), range.start != range.end else { return false }
        return document.blocks[range.lowerIndex...range.upperIndex].allSatisfy {
            $0.kind != .code && $0.kind != .divider
        }
    }

    var selectionContainsLink: Bool {
        guard let range = normalizedFormattingRange(), range.start != range.end else { return false }
        for index in range.lowerIndex...range.upperIndex {
            let block = document.blocks[index]
            let lower = index == range.lowerIndex ? range.start.graphemeOffset : 0
            let upper = index == range.upperIndex ? range.end.graphemeOffset : Self.text(block).count
            var cursor = 0
            for span in block.inlineContent.spans {
                let spanEnd = cursor + span.text.count
                if upper > cursor, lower < spanEnd,
                   let link = span.linkURL, BlockURLValidator.isValid(link) {
                    return true
                }
                cursor = spanEnd
            }
        }
        return false
    }

    @discardableResult
    func beginComposition(blockID: BlockID, replacementRange: NSRange, hostToken: UUID) -> UInt? {
        if let composition {
            return composition.hostToken == hostToken ? composition.token : nil
        }
        guard isActiveHost(hostToken), hosts[hostToken]?.blockID == blockID else { return nil }
        guard let replacement = compositionSelection(blockID: blockID, replacementRange: replacementRange) else { return nil }
        slashMenuState = nil
        terminalComposition = nil
        compositionGeneration &+= 1
        composition = .init(
            document: document,
            originalSelection: selection,
            replacementSelection: replacement,
            blockID: blockID,
            hostToken: hostToken,
            token: compositionGeneration
        )
        return compositionGeneration
    }

    func commitComposition(_ value: String, hostToken: UUID) {
        guard let baseline = composition, baseline.hostToken == hostToken else { return }
        composition = nil
        terminalComposition = .init(token: baseline.token, hostToken: hostToken, value: value)
        document = baseline.document
        applySelection(baseline.replacementSelection, incrementingRevision: false, project: false)
        do { _ = try dispatch(.insertTextApplyingMarkdownShortcut(value)) } catch { projectAuthoritativeState() }
    }

    func cancelComposition(hostToken: UUID, terminalValue: String? = nil) {
        guard let baseline = composition, baseline.hostToken == hostToken else { return }
        composition = nil
        terminalComposition = .init(token: baseline.token, hostToken: hostToken, value: terminalValue)
        document = baseline.document
        applySelection(baseline.originalSelection, incrementingRevision: false, project: true)
    }

    var isComposing: Bool { composition != nil }

    /// Force the live IME candidate into the authoritative document through the
    /// same commit path as `unmarkText`. Returns false only when a live host
    /// still reports a composition that could not be committed.
    @discardableResult
    func terminallyFinalizeNativeComposition() -> Bool {
        guard let composition else { return true }
        guard let lease = hosts[composition.hostToken],
              let textView = lease.textView else {
            cancelComposition(hostToken: composition.hostToken)
            return true
        }
        if textView.hasMarkedText() {
            textView.unmarkText()
        } else if isComposing {
            // Marked buffer already cleared but session still holds composition.
            commitComposition(textView.string, hostToken: composition.hostToken)
        }
        projectAuthoritativeState()
        return !isComposing
    }

    var slashOptions: [BlockKind] {
        [.paragraph, .heading1, .heading2, .heading3, .bullet, .ordered, .task, .quote, .code, .divider]
    }

    func moveSlashSelection(by delta: Int, expected: BlockSlashMenuState) {
        guard slashMenuState == expected else { return }
        slashMenuState?.moveSelection(by: delta, count: slashOptions.count)
    }

    func confirmSlash(kind: BlockKind, expected: BlockSlashMenuState) -> Bool {
        guard slashMenuState == expected, composition == nil else { return false }
        slashMenuState = nil
        do { return try dispatch(.applySlashConversion(kind)).commandHandled } catch { return false }
    }

    func dismissSlashMenu(expected: BlockSlashMenuState) {
        guard slashMenuState == expected else { return }
        dismissedSlash = .init(
            blockID: expected.blockID,
            queryRange: expected.queryRange,
            query: expected.query,
            revision: editorRevision
        )
        slashMenuState = nil
    }

    func handleSlashSelector(_ selector: Selector) -> Bool {
        guard let state = slashMenuState, composition == nil else { return false }
        switch selector.description {
        case "moveUp:":
            moveSlashSelection(by: -1, expected: state)
        case "moveDown:":
            moveSlashSelection(by: 1, expected: state)
        case "insertNewline:":
            return confirmSlash(kind: slashOptions[state.selectedIndex], expected: state)
        case "cancelOperation:":
            dismissSlashMenu(expected: state)
        default:
            return false
        }
        return true
    }

    func dispatchInsertText(_ value: String, blockID: BlockID, replacementRange: NSRange, hostToken: UUID) -> Bool {
        if consumeTerminalDuplicate(value: value, hostToken: hostToken) { return true }
        if composition != nil {
            commitComposition(value, hostToken: hostToken)
            return true
        }
        guard isActiveHost(hostToken),
              let selected = compositionSelection(blockID: blockID, replacementRange: replacementRange) else { return false }
        applySelection(selected, incrementingRevision: false, project: false)
        do { return try dispatch(.insertTextApplyingMarkdownShortcut(value)).commandHandled } catch { return false }
    }

    func beginNativeInputEvent(hostToken: UUID) {
        guard terminalComposition?.hostToken == hostToken else { return }
        terminalComposition = nil
    }

    func dispatchTextCommand(_ command: BlockInputCommand) -> Bool {
        dispatchTextCommandOutcome(command)?.commandHandled ?? false
    }

    func dispatchTextCommandOutcome(_ command: BlockInputCommand) -> BlockEditorDispatchOutcome? {
        guard composition == nil else { return nil }
        return try? dispatch(command)
    }

    func copy() -> Bool { dispatchTextCommand(.copySelection) }
    func cut() -> Bool { dispatchTextCommand(.cutSelection) }
    func paste() -> Bool {
        guard let payload = pasteboardAdapter.readPayload() else { return false }
        return dispatchTextCommand(.replaceSelection(payload))
    }

    func updateNativeSelection(blockID: BlockID, range: NSRange, hostToken: UUID) {
        guard composition == nil, isActiveHost(hostToken), hosts[hostToken]?.blockID == blockID,
              let bridged = try? BlockSelectionBridge.graphemeRange(blockID: blockID, nsRange: range, document: document) else {
            return
        }
        let attributes: BlockTypingAttributes
        if case let .text(_, _, _, current) = selection { attributes = current }
        else { attributes = .init(marks: [], linkURL: nil) }
        closeTypingCoalescing()
        applySelection(
            .text(anchor: bridged.start, focus: bridged.end, preferredColumn: nil, typingAttributes: attributes),
            incrementingRevision: true,
            project: false
        )
    }

    /// Starts a document-owned selection from a concrete host position. Hosts
    /// never concatenate NSRanges: the session retains the stable-ID endpoints.
    @discardableResult
    func beginPointerSelection(at position: BlockTextPosition, hostToken: UUID) -> Bool {
        guard isAttached(position: position, hostToken: hostToken) else { return false }
        let attributes: BlockTypingAttributes
        if case let .text(_, _, _, current) = selection { attributes = current }
        else { attributes = .init(marks: [], linkURL: nil) }
        closeTypingCoalescing()
        selectionController.beginPointer(at: position, attributes: attributes)
        applySyntheticSelection()
        return true
    }

    /// Extends a pointer drag into another attached text host while preserving
    /// the starting anchor and its document direction.
    @discardableResult
    func extendPointerSelection(to position: BlockTextPosition, hostToken: UUID) -> Bool {
        guard isAttached(position: position, hostToken: hostToken) else { return false }
        selectionController.extendPointer(to: position)
        applySyntheticSelection()
        return true
    }

    /// Shift uses the same anchored extension semantics as a pointer drag.
    @discardableResult
    func extendSelectionWithShift(to position: BlockTextPosition, hostToken: UUID) -> Bool {
        guard isAttached(position: position, hostToken: hostToken) else { return false }
        selectionController.extendWithShift(to: position)
        applySyntheticSelection()
        return true
    }

    @discardableResult
    func beginBlockSelection(blockID: BlockID) -> Bool {
        guard document.blocks.contains(where: { $0.id == blockID }) else { return false }
        closeTypingCoalescing()
        selectionController.beginBlockSelection(at: blockID)
        applySyntheticSelection()
        return true
    }

    @discardableResult
    func extendBlockSelection(to blockID: BlockID) -> Bool {
        guard document.blocks.contains(where: { $0.id == blockID }) else { return false }
        closeTypingCoalescing()
        selectionController.extendBlockSelection(to: blockID)
        applySyntheticSelection()
        return true
    }

    /// Auxiliary controls temporarily become first responder while they run.
    /// Always restore the authoritative selection endpoint afterwards so the
    /// editor's UndoManager remains the focused command owner, including when
    /// a modal action is cancelled without producing a reducer mutation.
    func performAuxiliaryControlAction(_ action: () -> Void) {
        action()
        focusSelectionEndpoint()
    }

    @discardableResult
    func extendPointerSelection(atWindowPoint point: NSPoint, in window: NSWindow?) -> Bool {
        guard let window else { return false }
        for lease in hosts.values {
            guard let textView = lease.textView, textView.window === window else { continue }
            let localPoint = textView.convert(point, from: nil)
            guard textView.bounds.contains(localPoint),
                  let utf16Offset = textView.utf16Offset(at: localPoint),
                  let position = try? BlockSelectionBridge.graphemePosition(
                      blockID: lease.blockID, utf16Offset: utf16Offset, document: document
                  ) else { continue }
            return extendPointerSelection(to: position, hostToken: lease.token)
        }
        return false
    }

    /// The sole production boundary where reducer outcomes gain AppKit side effects.
    /// Keeping it internal lets the exhaustive matrix verify the exact same path as
    /// `dispatch(_:)`, rather than introducing a test-only alternate implementation.
    func consume(
        _ result: BlockInputResult,
        clipboardWriter: ((BlockClipboardPayload) -> Bool)? = nil
    ) throws -> BlockEditorDispatchOutcome {
        switch (result.mutation, result.effect, result.undo) {
        case (.none, .handled, .none):
            return .init(result: result, commandHandled: true)
        case (.none, .deferToTextSystem, .none):
            return .init(result: result, commandHandled: false)
        case let (.none, .writeClipboard(payload), .none):
            try writeClipboard(payload, using: clipboardWriter)
            return .init(result: result, commandHandled: true)
        case (.none, .handled, .breakCoalescing):
            closeTypingCoalescing()
            return .init(result: result, commandHandled: true)
        case (.selectionOnly, .handled, .none):
            closeTypingCoalescing()
            applySelection(result.selection, incrementingRevision: true, project: true)
            focusSelectionEndpoint()
            return .init(result: result, commandHandled: true)
        case let (.document, .handled, .coalesceTyping(blockID)):
            let before = Snapshot(document: document, selection: selection)
            let after = Snapshot(document: result.document, selection: result.selection)
            registerTypingUndo(before: before, after: after, blockID: blockID)
            applyDocument(after)
            return .init(result: result, commandHandled: true)
        case let (.document, .handled, .atomic(action)):
            let before = Snapshot(document: document, selection: selection)
            let after = Snapshot(document: result.document, selection: result.selection)
            closeTypingCoalescing()
            registerAtomicUndo(before: before, after: after, action: action)
            applyDocument(after)
            return .init(result: result, commandHandled: true)
        case let (.document, .writeClipboard(payload), .atomic(.cut)):
            let before = Snapshot(document: document, selection: selection)
            let after = Snapshot(document: result.document, selection: result.selection)
            try writeClipboard(payload, using: clipboardWriter)
            closeTypingCoalescing()
            registerAtomicUndo(before: before, after: after, action: .cut)
            applyDocument(after)
            return .init(result: result, commandHandled: true)
        default:
            throw BlockEditorIntegrationError.illegalResult
        }
    }

    private func writeClipboard(
        _ payload: BlockClipboardPayload,
        using writer: ((BlockClipboardPayload) -> Bool)?
    ) throws {
        guard (writer?(payload) ?? pasteboardAdapter.write(payload: payload)) else {
            throw BlockEditorIntegrationError.clipboardWriteFailed
        }
    }

    private func registerTypingUndo(before: Snapshot, after: Snapshot, blockID: BlockID) {
        let canContinue: Bool
        if let record = typingRecord,
           record.blockID == blockID,
           record.after.selection == before.selection,
           Self.isContinuousCaret(before.selection, in: blockID) {
            record.after = after
            canContinue = true
        } else {
            canContinue = false
        }
        guard !canContinue else { return }
        closeTypingCoalescing()
        let record = TypingUndoRecord(before: before, after: after, blockID: blockID)
        typingRecord = record
        undoManager.registerUndo(withTarget: self) { target in
            target.restoreTyping(record)
        }
        undoManager.setActionName("输入")
    }

    private func closeTypingCoalescing() { typingRecord = nil }

    private func registerAtomicUndo(before: Snapshot, after: Snapshot, action: BlockUndoAction) {
        undoManager.registerUndo(withTarget: self) { target in
            target.restore(snapshot: before, inverse: after)
        }
        undoManager.setActionName(action.undoName)
    }

    private func restoreTyping(_ record: TypingUndoRecord) {
        closeTypingCoalescing()
        let inverse = Snapshot(document: document, selection: selection)
        applyDocument(record.before)
        undoManager.registerUndo(withTarget: self) { target in
            target.restore(snapshot: record.after, inverse: record.before)
        }
        _ = inverse // Documents the inverse capture that keeps snapshot restoration symmetric.
    }

    private func restore(snapshot: Snapshot, inverse: Snapshot) {
        closeTypingCoalescing()
        applyDocument(snapshot)
        undoManager.registerUndo(withTarget: self) { target in
            target.restore(snapshot: inverse, inverse: snapshot)
        }
    }

    private func applyDocument(_ snapshot: Snapshot) {
        document = snapshot.document
        selection = snapshot.selection
        selectionController.setSelection(snapshot.selection)
        editorRevision &+= 1
        refreshSlashMenu()
        projectAuthoritativeState()
        onDocumentChange(document)
    }

    private func refreshSlashMenu() {
        guard composition == nil,
              case let .text(anchor, focus, _, _) = selection,
              anchor == focus,
              let block = document.blocks.first(where: { $0.id == anchor.blockID }),
              block.kind == .paragraph else {
            slashMenuState = nil
            return
        }
        let text = Self.text(block)
        guard anchor.graphemeOffset >= 0, anchor.graphemeOffset <= text.count else {
            slashMenuState = nil
            return
        }
        let prefix = String(text.prefix(anchor.graphemeOffset))
        guard prefix.hasPrefix("/"), !prefix.dropFirst().contains(where: { $0.isNewline }) else {
            slashMenuState = nil
            return
        }
        let queryRange = 0..<prefix.count
        let query = String(prefix.dropFirst())
        if let dismissedSlash,
           dismissedSlash.blockID == block.id,
           dismissedSlash.queryRange == queryRange,
           dismissedSlash.query == query,
           dismissedSlash.revision == editorRevision {
            slashMenuState = nil
            return
        }
        if let existing = slashMenuState,
           existing.blockID == block.id,
           existing.queryRange == queryRange,
           existing.query == query { return }
        slashMenuState = .open(blockID: block.id, queryRange: queryRange, query: query, revision: editorRevision)
    }

    private func compositionSelection(blockID: BlockID, replacementRange: NSRange) -> BlockEditorSelection? {
        let range: BlockTextRange
        if replacementRange.location == NSNotFound {
            guard case let .text(anchor, focus, _, _) = selection,
                  focus.blockID == blockID else { return nil }
            range = .init(start: anchor, end: focus)
        } else {
            guard let bridged = try? BlockSelectionBridge.graphemeRange(
                blockID: blockID, nsRange: replacementRange, document: document
            ) else { return nil }
            range = bridged
        }
        let attributes: BlockTypingAttributes
        if case let .text(_, _, _, current) = selection { attributes = current }
        else { attributes = .init(marks: [], linkURL: nil) }
        return .text(anchor: range.start, focus: range.end, preferredColumn: nil, typingAttributes: attributes)
    }

    private static func text(_ block: DocumentBlock) -> String { block.inlineContent.spans.map(\.text).joined() }

    private func normalizedFormattingRange() -> (
        lowerIndex: Int,
        upperIndex: Int,
        start: BlockTextPosition,
        end: BlockTextPosition
    )? {
        guard case let .text(anchor, focus, _, _) = selection,
              let anchorIndex = document.blocks.firstIndex(where: { $0.id == anchor.blockID }),
              let focusIndex = document.blocks.firstIndex(where: { $0.id == focus.blockID }) else { return nil }
        if anchorIndex < focusIndex || (anchorIndex == focusIndex && anchor.graphemeOffset <= focus.graphemeOffset) {
            return (anchorIndex, focusIndex, anchor, focus)
        }
        return (focusIndex, anchorIndex, focus, anchor)
    }

    private func isAttached(position: BlockTextPosition, hostToken: UUID) -> Bool {
        guard isActiveHost(hostToken), hosts[hostToken]?.blockID == position.blockID else { return false }
        return (try? BlockSelectionBridge.utf16Offset(position: position, document: document)) != nil
    }

    private func applySyntheticSelection() {
        applySelection(selectionController.selection, incrementingRevision: true, project: true)
        focusSelectionEndpoint()
    }

    private func applySelection(_ newSelection: BlockEditorSelection, incrementingRevision: Bool, project: Bool) {
        selection = newSelection
        selectionController.setSelection(newSelection)
        if incrementingRevision { editorRevision &+= 1 }
        refreshSlashMenu()
        if project { projectAuthoritativeState() }
    }

    private func focusSelectionEndpoint() {
        guard case let .text(_, focus, _, _) = selection,
              let token = activeHostTokens[focus.blockID],
              let view = hosts[token]?.textView,
              let window = view.window,
              window.firstResponder !== view else { return }
        _ = window.makeFirstResponder(view)
    }

    private func isActiveHost(_ hostToken: UUID) -> Bool {
        guard let lease = hosts[hostToken] else { return false }
        return activeHostTokens[lease.blockID] == hostToken
    }

    private func consumeTerminalDuplicate(value: String, hostToken: UUID) -> Bool {
        guard let terminal = terminalComposition else { return false }
        terminalComposition = nil
        return terminal.hostToken == hostToken && terminal.value == value
    }

    private func isSelectionIncluding(blockID: BlockID) -> Bool {
        switch selection {
        case let .blocks(anchor, focus):
            let ids = document.blocks.map(\.id)
            guard let anchorIndex = ids.firstIndex(of: anchor),
                  let focusIndex = ids.firstIndex(of: focus),
                  let blockIndex = ids.firstIndex(of: blockID) else { return false }
            return min(anchorIndex, focusIndex) <= blockIndex && blockIndex <= max(anchorIndex, focusIndex)
        case let .text(anchor, focus, _, _):
            if anchor == focus { return false }
            let ids = document.blocks.map(\.id)
            guard let anchorIndex = ids.firstIndex(of: anchor.blockID),
                  let focusIndex = ids.firstIndex(of: focus.blockID),
                  let blockIndex = ids.firstIndex(of: blockID) else { return false }
            let lower = min(anchorIndex, focusIndex)
            let upper = max(anchorIndex, focusIndex)
            if lower < blockIndex && blockIndex < upper { return true }
            if anchor.blockID == focus.blockID, anchor.blockID == blockID { return anchor.graphemeOffset != focus.graphemeOffset }
            return blockIndex == lower || blockIndex == upper
        }
    }

    private static func isContinuousCaret(_ selection: BlockEditorSelection, in blockID: BlockID) -> Bool {
        guard case let .text(anchor, focus, _, _) = selection else { return false }
        return anchor == focus && anchor.blockID == blockID
    }
}

private extension BlockUndoAction {
    var undoName: String {
        switch self {
        case .enter: "换行"
        case .softBreak: "软换行"
        case .documentIngest: "导入文档"
        case .backspace, .deletion: "删除"
        case .indentation: "缩进"
        case .conversion: "转换"
        case .formatting: "格式"
        case .link: "链接"
        case .cut: "剪切"
        case .paste: "粘贴"
        case .drag: "移动 Block"
        }
    }
}

@MainActor
private final class HostLease {
    let blockID: BlockID
    let token: UUID
    weak var textView: BlockEditorTextView?

    init(blockID: BlockID, token: UUID, textView: BlockEditorTextView) {
        self.blockID = blockID
        self.token = token
        self.textView = textView
    }
}

private struct Snapshot: Equatable {
    let document: BlockDocument
    let selection: BlockEditorSelection
}

@MainActor
private final class TypingUndoRecord {
    let before: Snapshot
    var after: Snapshot
    let blockID: BlockID

    init(before: Snapshot, after: Snapshot, blockID: BlockID) {
        self.before = before
        self.after = after
        self.blockID = blockID
    }
}

private struct CompositionBaseline {
    let document: BlockDocument
    let originalSelection: BlockEditorSelection
    let replacementSelection: BlockEditorSelection
    let blockID: BlockID
    let hostToken: UUID
    let token: UInt
}

private struct TerminalComposition {
    let token: UInt
    let hostToken: UUID
    let value: String?
}

private struct DismissedSlash {
    let blockID: BlockID
    let queryRange: Range<Int>
    let query: String
    let revision: UInt
}
