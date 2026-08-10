import AppKit
import Foundation
import WorkspaceDomain

@MainActor
final class BlockEditorTextView: NSTextView, NSTextViewDelegate {
    private weak var editorSession: BlockEditorSession?
    private var blockID: BlockID?
    private var hostToken: UUID?
    private var applyingProjection = false
    private var markedCandidate: String?
    private var markedCompositionToken: UInt?
    private(set) var projectedAccessibilitySelected = false
    // NSTextContainer does not keep the legacy text system alive by itself.
    // The host must retain this chain for the lifetime of the native view.
    private let ownedTextStorage: NSTextStorage
    private let ownedLayoutManager: NSLayoutManager
    private let ownedTextContainer: NSTextContainer

    convenience init() {
        self.init(frame: .zero)
    }

    convenience override init(frame frameRect: NSRect) {
        let textSystem = Self.makeTextSystem()
        self.init(frame: frameRect, textSystem: textSystem)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        let textSystem = Self.makeTextSystem()
        ownedTextStorage = textSystem.storage
        ownedLayoutManager = textSystem.layoutManager
        ownedTextContainer = textSystem.container
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    private init(frame frameRect: NSRect, textSystem: TextSystem) {
        ownedTextStorage = textSystem.storage
        ownedLayoutManager = textSystem.layoutManager
        ownedTextContainer = textSystem.container
        super.init(frame: frameRect, textContainer: textSystem.container)
        configure()
    }

    required init?(coder: NSCoder) {
        let textSystem = Self.makeTextSystem()
        ownedTextStorage = textSystem.storage
        ownedLayoutManager = textSystem.layoutManager
        ownedTextContainer = textSystem.container
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isRichText = false
        allowsUndo = false // The session has the one authoritative UndoManager.
        drawsBackground = false
        isHorizontallyResizable = false
        isVerticallyResizable = true
        textContainer?.widthTracksTextView = true
        textContainerInset = .init(width: 0, height: 4)
        setAccessibilityRole(.textArea)
        delegate = self
    }

    private struct TextSystem {
        let storage: NSTextStorage
        let layoutManager: NSLayoutManager
        let container: NSTextContainer
    }

    private static func makeTextSystem() -> TextSystem {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: .zero)
        layoutManager.addTextContainer(container)
        return .init(storage: storage, layoutManager: layoutManager, container: container)
    }

    func install(session: BlockEditorSession, blockID: BlockID, hostToken: UUID) {
        editorSession = session
        self.blockID = blockID
        self.hostToken = hostToken
        setAccessibilityIdentifier(blockID.rawValue.uuidString)
    }

    func applyAuthoritativeProjection(text: String, selectedRange: NSRange, isSelected: Bool = false) {
        guard !applyingProjection else { return }
        applyingProjection = true
        defer { applyingProjection = false }
        textStorage?.setAttributedString(NSAttributedString(string: text))
        setAccessibilityValue(text)
        setAccessibilitySelected(isSelected)
        projectedAccessibilitySelected = isSelected
        let length = (text as NSString).length
        guard selectedRange.location != NSNotFound,
              selectedRange.location >= 0,
              selectedRange.location <= length,
              selectedRange.length >= 0,
              selectedRange.location <= length - selectedRange.length else { return }
        self.selectedRange = selectedRange
    }

    var attachedSession: BlockEditorSession? { editorSession }
    var representedBlockID: BlockID? { blockID }

    /// This is the host-side pointer seam used by both AppKit mouse events and
    /// the hosted production harness. It always bridges native UTF-16 first.
    @discardableResult
    func beginPointerSelection(atUTF16Offset utf16Offset: Int, extendingWithShift: Bool = false) -> Bool {
        guard let position = bridgedPosition(utf16Offset: utf16Offset), let hostToken else { return false }
        if extendingWithShift {
            return editorSession?.extendSelectionWithShift(to: position, hostToken: hostToken) ?? false
        }
        return editorSession?.beginPointerSelection(at: position, hostToken: hostToken) ?? false
    }

    @discardableResult
    func extendPointerSelection(toUTF16Offset utf16Offset: Int) -> Bool {
        guard let position = bridgedPosition(utf16Offset: utf16Offset), let hostToken else { return false }
        return editorSession?.extendPointerSelection(to: position, hostToken: hostToken) ?? false
    }

    @discardableResult
    func extendSelectionWithShift(toUTF16Offset utf16Offset: Int) -> Bool {
        beginPointerSelection(atUTF16Offset: utf16Offset, extendingWithShift: true)
    }

    override func mouseDown(with event: NSEvent) {
        if !applyingProjection, let offset = utf16Offset(at: convert(event.locationInWindow, from: nil)) {
            let handled = beginPointerSelection(
                atUTF16Offset: offset,
                extendingWithShift: event.modifierFlags.contains(.shift)
            )
            if handled {
                // Our projection has already placed the native caret/range. Letting
                // NSTextView run its own tracker now would report a one-host range
                // through the delegate and erase a cross-host selection.
                window?.makeFirstResponder(self)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if !applyingProjection,
           editorSession?.extendPointerSelection(atWindowPoint: event.locationInWindow, in: window) == true {
            return
        }
        super.mouseDragged(with: event)
    }

    override func keyDown(with event: NSEvent) {
        beginNativeInputEvent()
        super.keyDown(with: event)
    }

    /// AppKit calls `keyDown` before a new ordinary input event. Keeping this
    /// seam explicit lets hosted event tests distinguish that event from a late
    /// duplicate terminal callback emitted by the same IME composition.
    func beginNativeInputEvent() {
        if let hostToken { editorSession?.beginNativeInputEvent(hostToken: hostToken) }
    }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder, let hostToken { editorSession?.focus(hostToken: hostToken) }
        return becameFirstResponder
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !applyingProjection, let blockID, let hostToken else { return }
        editorSession?.updateNativeSelection(blockID: blockID, range: selectedRange, hostToken: hostToken)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if !applyingProjection, let blockID, let hostToken {
            markedCompositionToken = editorSession?.beginComposition(
                blockID: blockID, replacementRange: replacementRange, hostToken: hostToken
            )
            if markedCompositionToken != nil { markedCandidate = Self.string(from: string) }
        }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard !applyingProjection, let value = Self.string(from: insertString) else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        guard let editorSession, let blockID, let hostToken else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        _ = editorSession.dispatchInsertText(value, blockID: blockID, replacementRange: replacementRange, hostToken: hostToken)
        editorSession.projectAuthoritativeState()
        if editorSession.isComposing == false {
            markedCandidate = nil
            markedCompositionToken = nil
        }
    }

    override func unmarkText() {
        if let hostToken, editorSession?.isComposing == true {
            let value = markedCandidate ?? ""
            markedCandidate = nil
            markedCompositionToken = nil
            editorSession?.commitComposition(value, hostToken: hostToken)
            return
        }
        super.unmarkText()
    }

    override func cancelOperation(_ sender: Any?) {
        if let hostToken, editorSession?.isComposing == true {
            let terminalValue = markedCandidate
            markedCandidate = nil
            markedCompositionToken = nil
            editorSession?.cancelComposition(hostToken: hostToken, terminalValue: terminalValue)
            return
        }
        if editorSession?.handleSlashSelector(#selector(NSResponder.cancelOperation(_:))) == true { return }
        super.cancelOperation(sender)
    }

    override func doCommand(by selector: Selector) {
        // IME owns every structural key while a candidate is marked.
        if editorSession?.isComposing == true {
            // The input context supplies terminal candidate text through insertText or
            // unmarkText. Calling NSTextView's structural selector here would mutate its
            // transient storage a second time before that terminal transition.
            return
        }
        if editorSession?.handleSlashSelector(selector) == true { return }
        if let command = Self.command(for: selector), let editorSession {
            if let outcome = editorSession.dispatchTextCommandOutcome(command) {
                if outcome.commandHandled { return }
                super.doCommand(by: selector)
                return
            }
            editorSession.projectAuthoritativeState()
            return
        }
        super.doCommand(by: selector)
    }

    override func copy(_ sender: Any?) {
        if editorSession?.copy() == true { return }
        super.copy(sender)
    }

    override func cut(_ sender: Any?) {
        if let editorSession {
            _ = editorSession.cut()
            editorSession.projectAuthoritativeState()
            return
        }
        super.cut(sender)
    }

    override func paste(_ sender: Any?) {
        if let editorSession {
            _ = editorSession.paste()
            editorSession.projectAuthoritativeState()
            return
        }
        super.paste(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard editorSession?.isComposing != true,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              let character = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch character {
        case "b":
            _ = editorSession?.dispatchTextCommandOutcome(.toggleInlineMark(.bold))
            editorSession?.projectAuthoritativeState()
            return true
        case "i":
            _ = editorSession?.dispatchTextCommandOutcome(.toggleInlineMark(.italic))
            editorSession?.projectAuthoritativeState()
            return true
        case "c" where event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift):
            _ = editorSession?.dispatchTextCommandOutcome(.toggleInlineMark(.code))
            editorSession?.projectAuthoritativeState()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    private static func command(for selector: Selector) -> BlockInputCommand? {
        switch selector.description {
        case "insertNewline:": .enter
        case "insertLineBreak:": .softBreak
        case "deleteBackward:": .backspace
        case "insertTab:": .indent
        case "insertBacktab:": .outdent
        case "moveLeft:": .moveHorizontal(.backward, extending: false)
        case "moveRight:": .moveHorizontal(.forward, extending: false)
        case "moveUp:": .moveVertical(.up, extending: false)
        case "moveDown:": .moveVertical(.down, extending: false)
        case "moveLeftAndModifySelection:": .moveHorizontal(.backward, extending: true)
        case "moveRightAndModifySelection:": .moveHorizontal(.forward, extending: true)
        case "moveUpAndModifySelection:": .moveVertical(.up, extending: true)
        case "moveDownAndModifySelection:": .moveVertical(.down, extending: true)
        default: nil
        }
    }

    private static func string(from value: Any) -> String? {
        if let text = value as? String { return text }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }

    func utf16Offset(at point: NSPoint) -> Int? {
        guard !string.isEmpty else { return 0 }
        let origin = textContainerOrigin
        let containerPoint = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = ownedLayoutManager.glyphIndex(for: containerPoint, in: ownedTextContainer)
        let character = ownedLayoutManager.characterIndexForGlyph(at: glyph)
        return min(max(character, 0), string.utf16.count)
    }

    func windowPoint(forUTF16Offset utf16Offset: Int) -> NSPoint? {
        guard utf16Offset >= 0, utf16Offset < string.utf16.count else { return nil }
        ownedLayoutManager.ensureLayout(for: ownedTextContainer)
        let glyph = ownedLayoutManager.glyphIndexForCharacter(at: utf16Offset)
        let rect = ownedLayoutManager.boundingRect(forGlyphRange: .init(location: glyph, length: 1), in: ownedTextContainer)
        guard !rect.isEmpty else { return nil }
        let origin = textContainerOrigin
        let local = NSPoint(x: origin.x + rect.midX, y: origin.y + rect.midY)
        return convert(local, to: nil)
    }

    private func bridgedPosition(utf16Offset: Int) -> BlockTextPosition? {
        guard let editorSession, let blockID else { return nil }
        return try? BlockSelectionBridge.graphemePosition(
            blockID: blockID, utf16Offset: utf16Offset, document: editorSession.document
        )
    }
}
