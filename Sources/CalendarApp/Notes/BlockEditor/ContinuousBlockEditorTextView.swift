import AppKit
import Foundation
import WorkspaceDomain

@MainActor
final class ContinuousBlockEditorTextView: NSTextView, NSTextViewDelegate {
    private weak var editorSession: BlockEditorSession?
    private var hostToken: UUID?
    private var applyingProjection = false
    private var executingComposingTextSystemCommand = false
    private var projectedDocumentIsVisiblyEmpty = true
    private var currentProjection: BlockDocumentTextProjection?
    private var finishingComposition = false
    private var markedCandidate: String?
    private var pointerAnchorUTF16Offset: Int?
    private let ownedTextStorage: NSTextStorage
    private let ownedLayoutManager: NSLayoutManager
    private let ownedTextContainer: NSTextContainer
    private(set) var fullProjectionApplyCount = 0
    private(set) var diffProjectionApplyCount = 0

    convenience init() { self.init(frame: .zero) }

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

    var authoritativeUndoManager: UndoManager? { editorSession?.undoManager }
    var attachedSession: BlockEditorSession? { editorSession }
    var isPresentingEmptyDocumentPlaceholder: Bool {
        projectedDocumentIsVisiblyEmpty && !hasMarkedText()
    }

    func install(session: BlockEditorSession, hostToken: UUID) {
        editorSession = session
        self.hostToken = hostToken
        setAccessibilityIdentifier("continuous-block-editor")
    }

    func apply(
        diff: BlockDocumentProjectionDiff?,
        projection: BlockDocumentTextProjection,
        selectedRange: NSRange
    ) {
        guard !applyingProjection else { return }
        applyingProjection = true
        defer { applyingProjection = false }
        currentProjection = projection
        projectedDocumentIsVisiblyEmpty = projection.document.blocks.allSatisfy { block in
            block.kind == .paragraph && block.inlineContent.spans.allSatisfy(\.text.isEmpty)
        }

        if let diff,
           !finishingComposition,
           !hasMarkedText(),
           NSMaxRange(diff.oldRange) <= (textStorage?.length ?? 0) {
            textStorage?.replaceCharacters(in: diff.oldRange, with: diff.replacement)
            if textStorage?.string == projection.attributedString.string {
                diffProjectionApplyCount += 1
            } else {
                textStorage?.setAttributedString(projection.attributedString)
                fullProjectionApplyCount += 1
            }
        } else if textStorage?.string != projection.attributedString.string {
            textStorage?.setAttributedString(projection.attributedString)
            fullProjectionApplyCount += 1
        }
        setAccessibilityValue(try? projection.plainText(
            in: .init(location: 0, length: projection.attributedString.length)
        ))
        if isValid(selectedRange, length: projection.attributedString.length) {
            self.selectedRange = selectedRange
            restoreAuthoritativeAttributes(
                projection: projection,
                changedBlockIDs: diff?.changedBlockIDs ?? Set(projection.segments.map(\.blockID)),
                selectedRange: selectedRange
            )
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isPresentingEmptyDocumentPlaceholder {
            ("开始写点什么…" as NSString).draw(
                at: textContainerOrigin,
                withAttributes: [
                    .font: BlockTextStyle.baseFont(for: .paragraph),
                    .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.72)
                ]
            )
        }
        drawStructuralDecorations()
    }

    private func drawStructuralDecorations() {
        guard let projectedDocument = currentProjection?.document else { return }
        let color = NSColor.secondaryLabelColor.withAlphaComponent(0.82)
        var orderedIndex = 0
        for (index, block) in projectedDocument.blocks.enumerated() {
            if block.kind == .ordered {
                orderedIndex = index > 0 && projectedDocument.blocks[index - 1].kind == .ordered
                    ? orderedIndex + 1
                    : 1
            } else {
                orderedIndex = 0
            }
            let line = lineFragmentRect(forBlockAt: index)
            let baseline = NSPoint(x: textContainerOrigin.x + 1, y: line.minY + textContainerOrigin.y)
            switch block.kind {
            case .bullet:
                ("•" as NSString).draw(at: baseline, withAttributes: markerAttributes(color: color))
            case .ordered:
                ("\(orderedIndex)." as NSString).draw(at: baseline, withAttributes: markerAttributes(color: color))
            case .task:
                break
            case .quote:
                color.setFill()
                NSBezierPath(rect: .init(
                    x: textContainerOrigin.x + 4,
                    y: line.minY + textContainerOrigin.y,
                    width: 2,
                    height: max(18, line.height)
                )).fill()
            case .divider:
                color.withAlphaComponent(0.48).setStroke()
                let path = NSBezierPath()
                let y = line.midY + textContainerOrigin.y
                path.move(to: .init(x: textContainerOrigin.x, y: y))
                path.line(to: .init(x: max(textContainerOrigin.x, bounds.width - textContainerOrigin.x), y: y))
                path.lineWidth = 1
                path.stroke()
            case .paragraph, .heading1, .heading2, .heading3, .code, .link:
                break
            }
        }
    }

    private func lineFragmentRect(forBlockAt index: Int) -> NSRect {
        guard let projection = currentProjection,
              projection.document.blocks.indices.contains(index) else {
            return .init(x: 0, y: 0, width: bounds.width, height: 24)
        }
        let location = projection.segments[index].displayRange.location
        guard ownedLayoutManager.numberOfGlyphs > 0, (textStorage?.length ?? 0) > 0 else {
            return .init(x: 0, y: 0, width: bounds.width, height: 24)
        }
        let characterIndex = min(location, max(0, (textStorage?.length ?? 1) - 1))
        let glyphIndex = ownedLayoutManager.glyphIndexForCharacter(at: characterIndex)
        return ownedLayoutManager.lineFragmentUsedRect(
            forGlyphAt: min(glyphIndex, max(0, ownedLayoutManager.numberOfGlyphs - 1)),
            effectiveRange: nil
        )
    }

    private func markerAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: color
        ]
    }

    func measuredContentHeight(for width: CGFloat) -> CGFloat {
        ownedTextContainer.containerSize = .init(
            width: max(1, width - textContainerInset.width * 2),
            height: .greatestFiniteMagnitude
        )
        ownedLayoutManager.ensureLayout(for: ownedTextContainer)
        return ceil(ownedLayoutManager.usedRect(for: ownedTextContainer).height)
            + textContainerInset.height * 2
    }

    func utf16Offset(at point: NSPoint) -> Int? {
        guard !string.isEmpty else { return 0 }
        let origin = textContainerOrigin
        let containerPoint = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = ownedLayoutManager.glyphIndex(for: containerPoint, in: ownedTextContainer)
        return min(
            max(ownedLayoutManager.characterIndexForGlyph(at: glyph), 0),
            string.utf16.count
        )
    }

    func windowPoint(forUTF16Offset offset: Int) -> NSPoint? {
        guard offset >= 0, offset < string.utf16.count else { return nil }
        ownedLayoutManager.ensureLayout(for: ownedTextContainer)
        let glyph = ownedLayoutManager.glyphIndexForCharacter(at: offset)
        let rect = ownedLayoutManager.boundingRect(
            forGlyphRange: .init(location: glyph, length: 1),
            in: ownedTextContainer
        )
        guard !rect.isEmpty else { return nil }
        let origin = textContainerOrigin
        return convert(.init(x: origin.x + rect.midX, y: origin.y + rect.midY), to: nil)
    }

    func taskCheckboxFrame(for blockID: BlockID) -> NSRect? {
        guard let projection = currentProjection,
              let index = projection.document.blocks.firstIndex(where: { $0.id == blockID }),
              projection.document.blocks[index].kind == .task else { return nil }
        let block = projection.document.blocks[index]
        let line = lineFragmentRect(forBlockAt: index)
        return .init(
            x: textContainerOrigin.x + CGFloat(block.indentLevel * 20),
            y: textContainerOrigin.y + line.minY + max(0, (line.height - 18) / 2),
            width: 18,
            height: 18
        )
    }

    @discardableResult
    func beginPointerSelection(atUTF16Offset offset: Int) -> Bool {
        guard offset >= 0 else { return false }
        do {
            pointerAnchorUTF16Offset = offset
            try editorSession?.adoptNativeSelection(
                .init(location: offset, length: 0),
                direction: .forward,
                typingAttributes: editorSession?.currentTypingAttributes ?? .init(marks: [], linkURL: nil)
            )
            return editorSession != nil
        } catch {
            pointerAnchorUTF16Offset = nil
            return false
        }
    }

    @discardableResult
    func extendPointerSelection(toUTF16Offset offset: Int) -> Bool {
        guard let anchor = pointerAnchorUTF16Offset, offset >= 0 else { return false }
        let range = NSRange(location: min(anchor, offset), length: max(anchor, offset) - min(anchor, offset))
        do {
            try editorSession?.adoptNativeSelection(
                range,
                direction: offset >= anchor ? .forward : .reverse,
                typingAttributes: editorSession?.currentTypingAttributes ?? .init(marks: [], linkURL: nil)
            )
            return editorSession != nil
        } catch {
            return false
        }
    }

    @discardableResult
    func extendSelectionWithShift(toUTF16Offset offset: Int) -> Bool {
        do {
            try editorSession?.extendNativeSelection(
                toUTF16Offset: offset,
                typingAttributes: editorSession?.currentTypingAttributes ?? .init(marks: [], linkURL: nil)
            )
            return editorSession != nil
        } catch {
            return false
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1,
              let offset = utf16Offset(at: convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }
        let handled = event.modifierFlags.contains(.shift)
            ? extendSelectionWithShift(toUTF16Offset: offset)
            : beginPointerSelection(atUTF16Offset: offset)
        if handled {
            window?.makeFirstResponder(self)
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let offset = utf16Offset(at: convert(event.locationInWindow, from: nil)),
              extendPointerSelection(toUTF16Offset: offset) else {
            super.mouseDragged(with: event)
            return
        }
    }

    override func mouseUp(with event: NSEvent) {
        pointerAnchorUTF16Offset = nil
        super.mouseUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if let hostToken { editorSession?.beginNativeInputEvent(hostToken: hostToken) }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let hostToken { editorSession?.focus(hostToken: hostToken) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, let hostToken { editorSession?.blur(hostToken: hostToken) }
        return result
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !applyingProjection, !finishingComposition, editorSession?.isComposing != true else { return }
        try? editorSession?.adoptNativeSelection(
            selectedRange,
            direction: .forward,
            typingAttributes: editorSession?.currentTypingAttributes ?? .init(marks: [], linkURL: nil)
        )
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard !applyingProjection, let editorSession, let hostToken else {
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
            return
        }
        guard editorSession.beginContinuousComposition(
            replacementRange: replacementRange,
            hostToken: hostToken
        ) != nil else {
            editorSession.projectAuthoritativeState()
            return
        }
        markedCandidate = Self.string(from: string)
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        if executingComposingTextSystemCommand {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        guard !applyingProjection,
              let value = Self.string(from: insertString),
              let editorSession,
              let hostToken else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        finishingComposition = editorSession.isComposing
        let handled = editorSession.dispatchNativeReplacement(
            range: replacementRange,
            replacement: value,
            hostToken: hostToken
        )
        markedCandidate = nil
        finishingComposition = false
        if !handled { editorSession.projectAuthoritativeState() }
    }

    override func unmarkText() {
        guard let editorSession, let hostToken, editorSession.isComposing else {
            super.unmarkText()
            return
        }
        finishingComposition = true
        editorSession.commitComposition(markedCandidate ?? "", hostToken: hostToken)
        markedCandidate = nil
        finishingComposition = false
    }

    override func cancelOperation(_ sender: Any?) {
        if let editorSession, let hostToken, editorSession.isComposing {
            finishingComposition = true
            editorSession.cancelComposition(hostToken: hostToken, terminalValue: markedCandidate)
            markedCandidate = nil
            finishingComposition = false
            return
        }
        if editorSession?.handleSlashSelector(#selector(NSResponder.cancelOperation(_:))) == true { return }
        super.cancelOperation(sender)
    }

    override func doCommand(by selector: Selector) {
        if editorSession?.isComposing == true {
            executingComposingTextSystemCommand = true
            defer { executingComposingTextSystemCommand = false }
            super.doCommand(by: selector)
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
        if editorSession != nil {
            editorSession?.projectAuthoritativeState()
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
        case "i":
            _ = editorSession?.dispatchTextCommandOutcome(.toggleInlineMark(.italic))
        case "c" where event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift):
            _ = editorSession?.dispatchTextCommandOutcome(.toggleInlineMark(.code))
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }

    private func configure() {
        isRichText = true
        allowsUndo = false
        drawsBackground = false
        isEditable = true
        isSelectable = true
        isHorizontallyResizable = false
        isVerticallyResizable = true
        textContainer?.widthTracksTextView = true
        textContainerInset = .init(width: 0, height: 8)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("笔记正文")
        setAccessibilityPlaceholderValue("开始写点什么…")
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
        let container = NSTextContainer(size: .zero)
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        return .init(storage: storage, layoutManager: layoutManager, container: container)
    }

    private func isValid(_ range: NSRange, length: Int) -> Bool {
        range.location != NSNotFound
            && range.location >= 0
            && range.length >= 0
            && range.location <= length
            && range.location <= length - range.length
    }

    private func restoreAuthoritativeAttributes(
        projection: BlockDocumentTextProjection,
        changedBlockIDs: Set<BlockID>,
        selectedRange: NSRange
    ) {
        guard let textStorage, projection.attributedString.length > 0 else { return }
        var ranges = projection.segments.compactMap { segment in
            changedBlockIDs.contains(segment.blockID) && segment.displayRange.length > 0
                ? segment.displayRange
                : nil
        }
        let selectionStart = max(0, selectedRange.location - 1)
        let selectionEnd = min(
            projection.attributedString.length,
            NSMaxRange(selectedRange) + 1
        )
        if selectionEnd > selectionStart {
            ranges.append(.init(location: selectionStart, length: selectionEnd - selectionStart))
        }
        textStorage.beginEditing()
        let available = NSRange(location: 0, length: min(
            textStorage.length,
            projection.attributedString.length
        ))
        for proposedRange in ranges {
            let range = NSIntersectionRange(proposedRange, available)
            guard range.location != NSNotFound, range.length > 0 else { continue }
            textStorage.setAttributes([:], range: range)
            projection.attributedString.enumerateAttributes(in: range, options: []) {
                attributes, attributeRange, _ in
                textStorage.setAttributes(attributes, range: attributeRange)
            }
        }
        textStorage.endEditing()
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
}
