import AppKit
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("BlockEditorAccessibilityTests")
@MainActor
struct BlockEditorAccessibilityTests {
    @Test func pasteboardRetainsAllCharactersInPlainFallbackAndDropsUnsupportedStyling() throws {
        let text = "甲\u{FFFC}乙"
        let attributed = NSMutableAttributedString(string: text)
        attributed.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), range: .init(location: 0, length: attributed.length))
        let adapter = BlockPasteboardAdapter(pasteboard: .withUniqueName())

        try adapter.write(attributedString: attributed)
        let payload = try #require(adapter.readPayload())
        #expect(payload.fallbackPlainText == text)
        #expect(payload.fallbackPlainText == attributed.string)
    }

    @Test func accessibilityDescriptionUsesStableBlockIdentityAndDeterministicPosition() {
        let first = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000801")!)
        let second = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000802")!)
        let description = BlockAccessibilityDescriptor(
            blockID: second, index: 1, totalCount: 2, kind: .paragraph, value: "内容", isSelected: true
        )

        #expect(description.identifier == second.rawValue.uuidString)
        #expect(description.positionAnnouncement == "第 2 项，共 2 项")
        #expect(description.role == .textArea)
        #expect(description.isSelected)
        #expect(description.reorderActions == ["Move Up", "Move Down"])
        #expect(first != second)
    }

    @Test func slashMenuDismissalDoesNotReopenForSameRevision() {
        let id = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000803")!)
        var menu = BlockSlashMenuState.open(blockID: id, queryRange: 0..<2, query: "he", revision: 3)
        menu.dismiss(revision: 3)

        #expect(menu.shouldOpen(blockID: id, queryRange: 0..<2, query: "he", revision: 3) == false)
        #expect(menu.shouldOpen(blockID: id, queryRange: 0..<3, query: "hea", revision: 4))
    }

    @Test func richAttributedPasteSplitsPhysicalLinesAndInvalidCustomDataFallsBackToFullString() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let adapter = BlockPasteboardAdapter(pasteboard: pasteboard)
        let attributed = NSAttributedString(string: "甲\r\n乙\n丙")
        try adapter.write(attributedString: attributed)
        let rich = try #require(adapter.readPayload())
        guard case let .richText(blocks, fallbackPlainText) = rich else {
            Issue.record("expected v1 rich payload")
            return
        }
        #expect(blocks.map { $0.inlineContent.spans.map(\.text).joined() } == ["甲", "乙", "丙"])
        #expect(fallbackPlainText == attributed.string)

        pasteboard.clearContents()
        _ = pasteboard.setString("完整回退文本", forType: .string)
        _ = pasteboard.setData(Data("{\"version\":2,\"plainText\":\"错误\",\"blocks\":[]}".utf8), forType: BlockPasteboardAdapter.privateType)
        #expect(adapter.readPayload() == .plainText("完整回退文本"))
    }

    @Test func plainPasteboardFailureBlocksPublicationWhileCustomFailureRetainsMandatoryPlainText() {
        let payload = BlockClipboardPayload(plainText: "完整文本", richBlocks: [])
        let plainFailureBoard = NSPasteboard.withUniqueName()
        let plainFailure = BlockPasteboardAdapter(
            pasteboard: plainFailureBoard,
            plainTextWriter: { _, _ in false },
            customDataWriter: { _, _ in true }
        )
        #expect(plainFailure.write(payload: payload) == false)
        #expect(plainFailureBoard.string(forType: .string) == nil)

        let customFailureBoard = NSPasteboard.withUniqueName()
        let customFailure = BlockPasteboardAdapter(
            pasteboard: customFailureBoard,
            plainTextWriter: { board, text in board.setString(text, forType: .string) },
            customDataWriter: { _, _ in false }
        )
        #expect(customFailure.write(payload: payload))
        #expect(customFailureBoard.string(forType: .string) == "完整文本")
    }

    @Test func pasteboardCorruptInvalidAndUnsafeRichDataFallBackWithoutIDsOrUnsupportedStyles() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let adapter = BlockPasteboardAdapter(pasteboard: pasteboard)
        let attributed = NSMutableAttributedString(string: "甲\u{FFFC}乙")
        attributed.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), range: .init(location: 0, length: attributed.length))
        attributed.addAttribute(.foregroundColor, value: NSColor.systemRed, range: .init(location: 0, length: attributed.length))
        attributed.addAttribute(.link, value: try #require(URL(string: "https://example.com/%00")), range: .init(location: 0, length: attributed.length))
        try adapter.write(attributedString: attributed)
        let rich = try #require(adapter.readPayload())
        guard case let .richText(blocks, fallback) = rich else {
            Issue.record("expected private v1 payload")
            return
        }
        #expect(fallback == attributed.string)
        #expect(blocks[0].inlineContent.spans.map(\.text).joined() == "甲\u{FFFC}乙")
        #expect(blocks[0].inlineContent.spans.allSatisfy { !$0.marks.contains(.code) && $0.linkURL == nil })
        let encoded = try #require(pasteboard.data(forType: BlockPasteboardAdapter.privateType))
        #expect(!String(decoding: encoded, as: UTF8.self).contains("00000000-0000-0000-0000-000000000809"))

        pasteboard.clearContents()
        _ = pasteboard.setString("完整普通回退", forType: .string)
        _ = pasteboard.setData(Data("not JSON".utf8), forType: BlockPasteboardAdapter.privateType)
        #expect(adapter.readPayload() == .plainText("完整普通回退"))

        let validPayload = BlockClipboardPayload(
            plainText: "有效普通文本",
            richBlocks: [.init(kind: .paragraph, inlineContent: .plain("有效普通文本"), indentLevel: 0, codeInfoString: nil)]
        )
        #expect(adapter.write(payload: validPayload))
        let validData = try #require(pasteboard.data(forType: BlockPasteboardAdapter.privateType))
        var envelope = try #require(JSONSerialization.jsonObject(with: validData) as? [String: Any])
        var blockDTOs = try #require(envelope["blocks"] as? [[String: Any]])
        blockDTOs[0]["indentLevel"] = -1
        envelope["blocks"] = blockDTOs
        let invalidData = try JSONSerialization.data(withJSONObject: envelope)
        pasteboard.clearContents()
        _ = pasteboard.setString("有效普通文本", forType: .string)
        _ = pasteboard.setData(invalidData, forType: BlockPasteboardAdapter.privateType)
        #expect(adapter.readPayload() == .plainText("有效普通文本"))
    }

    @Test func externalRTFPasteUsesSupportedInlineMarksAndPreservesPlainFallback() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let adapter = BlockPasteboardAdapter(pasteboard: pasteboard)
        let attributed = NSMutableAttributedString(string: "粗体\n普通")
        attributed.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: .init(location: 0, length: 2))
        attributed.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: .init(location: 0, length: attributed.length))
        let rtf = try attributed.data(
            from: .init(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        pasteboard.clearContents()
        _ = pasteboard.setString(attributed.string, forType: .string)
        _ = pasteboard.setData(rtf, forType: .rtf)

        let payload = try #require(adapter.readPayload())
        guard case let .richText(blocks, fallback) = payload else {
            Issue.record("external RTF should not be downgraded while supported spans exist")
            return
        }
        #expect(fallback == "粗体\n普通")
        #expect(blocks.map { $0.inlineContent.spans.map(\.text).joined() } == ["粗体", "普通"])
        #expect(blocks[0].inlineContent.spans.allSatisfy { $0.marks.contains(.bold) })
        #expect(blocks.allSatisfy { $0.kind == .paragraph })
    }

    @Test func selectorMatrixDefersCompositionAndRoutesSupportedCommandsOnce() {
        let id = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000804")!)
        let document = BlockDocument(blocks: [.init(id: id, kind: .paragraph, inlineContent: .plain("甲"), taskState: nil, indentLevel: 0)])
        let selection = BlockEditorSelection.text(anchor: .init(blockID: id, graphemeOffset: 1), focus: .init(blockID: id, graphemeOffset: 1), preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil))
        let session = BlockEditorSession(noteID: NoteID(), editSessionID: UUID(), initialDocument: document, initialSelection: selection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in })
        let view = BlockEditorTextView()
        let hostToken = UUID()
        session.attach(blockID: id, hostToken: hostToken, textView: view)
        view.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        #expect(session.selection == .text(anchor: .init(blockID: id, graphemeOffset: 0), focus: .init(blockID: id, graphemeOffset: 0), preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil)))
        view.setMarkedText("p", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: 0, length: 0))
        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(session.document == document)
    }

    @Test func slashStateOpensOnlyForLeadingCollapsedParagraphAndCompositionClosesIt() throws {
        let id = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000805")!)
        let document = BlockDocument(blocks: [.init(id: id, kind: .paragraph, inlineContent: .plain(""), taskState: nil, indentLevel: 0)])
        let selection = BlockEditorSelection.text(anchor: .init(blockID: id, graphemeOffset: 0), focus: .init(blockID: id, graphemeOffset: 0), preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil))
        let session = BlockEditorSession(noteID: NoteID(), editSessionID: UUID(), initialDocument: document, initialSelection: selection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in })
        _ = try session.dispatch(.insertText("/he"))
        #expect(session.slashMenuState?.blockID == id)
        #expect(session.slashMenuState?.query == "he")

        let view = BlockEditorTextView()
        let hostToken = UUID()
        session.attach(blockID: id, hostToken: hostToken, textView: view)
        view.setMarkedText("p", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: 3, length: 0))
        #expect(session.slashMenuState == nil)
        view.cancelOperation(nil)
        #expect(session.slashMenuState?.query == "he")
    }

    @Test func slashDismissalIsRevisionBoundAndStaleConfirmationCannotDispatch() throws {
        let id = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000806")!)
        let document = BlockDocument(blocks: [.init(id: id, kind: .paragraph, inlineContent: .plain(""), taskState: nil, indentLevel: 0)])
        let selection = BlockEditorSelection.text(anchor: .init(blockID: id, graphemeOffset: 0), focus: .init(blockID: id, graphemeOffset: 0), preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil))
        let session = BlockEditorSession(noteID: NoteID(), editSessionID: UUID(), initialDocument: document, initialSelection: selection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in })
        _ = try session.dispatch(.insertText("/h"))
        let opened = try #require(session.slashMenuState)
        session.dismissSlashMenu(expected: opened)
        #expect(session.slashMenuState == nil)
        #expect(session.confirmSlash(kind: .heading1, expected: opened) == false)
        _ = try session.dispatch(.insertText("e"))
        #expect(session.slashMenuState?.query == "he")
        let current = try #require(session.slashMenuState)
        #expect(session.confirmSlash(kind: .heading1, expected: current))
        #expect(session.document.blocks[0].kind == .heading1)
        #expect(session.document.blocks[0].inlineContent.spans.map(\.text).joined() == "")
    }

    @Test func slashTextViewSelectorsClampConfirmAndDismissExactlyOnce() throws {
        let id = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000807")!)
        let document = BlockDocument(blocks: [.init(id: id, kind: .paragraph, inlineContent: .plain(""), taskState: nil, indentLevel: 0)])
        let selection = BlockEditorSelection.text(anchor: .init(blockID: id, graphemeOffset: 0), focus: .init(blockID: id, graphemeOffset: 0), preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil))
        var callbacks = 0
        let session = BlockEditorSession(noteID: NoteID(), editSessionID: UUID(), initialDocument: document, initialSelection: selection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in callbacks += 1 })
        let view = BlockEditorTextView()
        session.attach(blockID: id, hostToken: UUID(), textView: view)
        _ = try session.dispatch(.insertText("/q"))
        let opened = try #require(session.slashMenuState)
        #expect(opened.selectedIndex == 0)
        view.doCommand(by: #selector(NSResponder.moveDown(_:)))
        let movedDown = try #require(session.slashMenuState)
        #expect(movedDown.selectedIndex == 1)
        view.doCommand(by: #selector(NSResponder.moveUp(_:)))
        let movedUp = try #require(session.slashMenuState)
        #expect(movedUp.selectedIndex == 0)
        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(session.document.blocks[0].kind == .paragraph)
        #expect(session.document.blocks[0].inlineContent.spans.map(\.text).joined() == "")
        #expect(callbacks == 2)
        #expect(session.undoManager.canUndo)
        #expect(session.confirmSlash(kind: .heading1, expected: movedUp) == false)
        #expect(callbacks == 2)

        let dismissSession = BlockEditorSession(noteID: NoteID(), editSessionID: UUID(), initialDocument: document, initialSelection: selection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in })
        let dismissView = BlockEditorTextView()
        dismissSession.attach(blockID: id, hostToken: UUID(), textView: dismissView)
        _ = try dismissSession.dispatch(.insertText("/keep"))
        dismissView.cancelOperation(nil)
        #expect(dismissSession.slashMenuState == nil)
        #expect(dismissSession.document.blocks[0].inlineContent.spans.map(\.text).joined() == "/keep")
        #expect(dismissSession.handleSlashSelector(#selector(NSResponder.cancelOperation(_:))) == false)
    }

    @Test func slashNeverOpensForCompositionPartialNonleadingSelectionOrNonparagraph() throws {
        let id = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000808")!)
        let textSelection = BlockEditorSelection.text(anchor: .init(blockID: id, graphemeOffset: 0), focus: .init(blockID: id, graphemeOffset: 0), preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil))
        let nonleading = BlockEditorSession(
            noteID: NoteID(), editSessionID: UUID(),
            initialDocument: .init(blocks: [.init(id: id, kind: .paragraph, inlineContent: .plain("x/partial"), taskState: nil, indentLevel: 0)]),
            initialSelection: .text(anchor: .init(blockID: id, graphemeOffset: 9), focus: .init(blockID: id, graphemeOffset: 9), preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil)),
            focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in }
        )
        let nonleadingView = BlockEditorTextView()
        let nonleadingToken = UUID()
        nonleading.attach(blockID: id, hostToken: nonleadingToken, textView: nonleadingView)
        nonleading.updateNativeSelection(blockID: id, range: .init(location: 9, length: 0), hostToken: nonleadingToken)
        #expect(nonleading.slashMenuState == nil)

        let selectionSession = BlockEditorSession(
            noteID: NoteID(), editSessionID: UUID(),
            initialDocument: .init(blocks: [.init(id: id, kind: .paragraph, inlineContent: .plain("/partial"), taskState: nil, indentLevel: 0)]),
            initialSelection: textSelection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in }
        )
        let selectionView = BlockEditorTextView()
        let selectionToken = UUID()
        selectionSession.attach(blockID: id, hostToken: selectionToken, textView: selectionView)
        selectionSession.updateNativeSelection(blockID: id, range: .init(location: 0, length: 1), hostToken: selectionToken)
        #expect(selectionSession.slashMenuState == nil)

        let headingSession = BlockEditorSession(
            noteID: NoteID(), editSessionID: UUID(),
            initialDocument: .init(blocks: [.init(id: id, kind: .heading1, inlineContent: .plain("/title"), taskState: nil, indentLevel: 0)]),
            initialSelection: textSelection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in }
        )
        let headingView = BlockEditorTextView()
        let headingToken = UUID()
        headingSession.attach(blockID: id, hostToken: headingToken, textView: headingView)
        headingSession.updateNativeSelection(blockID: id, range: .init(location: 6, length: 0), hostToken: headingToken)
        #expect(headingSession.slashMenuState == nil)

        let composition = BlockEditorSession(noteID: NoteID(), editSessionID: UUID(), initialDocument: .init(blocks: [.init(id: id, kind: .paragraph, inlineContent: .plain(""), taskState: nil, indentLevel: 0)]), initialSelection: textSelection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in })
        let compositionView = BlockEditorTextView()
        let compositionToken = UUID()
        composition.attach(blockID: id, hostToken: compositionToken, textView: compositionView)
        _ = try composition.dispatch(.insertText("/compose"))
        compositionView.setMarkedText("p", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: 8, length: 0))
        let before = composition.document
        compositionView.doCommand(by: #selector(NSResponder.moveDown(_:)))
        compositionView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        compositionView.cancelOperation(nil)
        #expect(composition.document == before)
        #expect(composition.slashMenuState?.query == "compose")
    }

    @Test func textViewRoutesEveryStructuralAndMovementSelectorWithoutDuplicatePublication() {
        let structural: [(Selector, Bool)] = [
            (#selector(NSResponder.insertNewline(_:)), true),
            (#selector(NSResponder.insertLineBreak(_:)), true),
            (#selector(NSResponder.deleteBackward(_:)), true),
            (#selector(NSResponder.insertTab(_:)), false),
            (#selector(NSResponder.insertBacktab(_:)), false)
        ]
        for (selector, mutates) in structural {
            let fixture = selectorFixture(selection: 1..<1)
            fixture.view.doCommand(by: selector)
            #expect(fixture.counter.value == (mutates ? 1 : 0))
            #expect(fixture.counter.value <= 1)
        }

        let movements: [Selector] = [
            #selector(NSResponder.moveLeft(_:)),
            #selector(NSResponder.moveRight(_:)),
            #selector(NSResponder.moveUp(_:)),
            #selector(NSResponder.moveDown(_:)),
            #selector(NSResponder.moveLeftAndModifySelection(_:)),
            #selector(NSResponder.moveRightAndModifySelection(_:)),
            #selector(NSResponder.moveUpAndModifySelection(_:)),
            #selector(NSResponder.moveDownAndModifySelection(_:))
        ]
        for selector in movements {
            let fixture = selectorFixture(selection: 1..<1)
            fixture.view.doCommand(by: selector)
            #expect(fixture.counter.value == 0)
            #expect(fixture.session.undoManager.canUndo == false)
        }
    }

    @Test func textViewRoutesInsertClipboardAndSupportedFormattingShortcutsExactlyOnce() throws {
        let selectedInsert = selectorFixture(selection: 0..<1)
        selectedInsert.view.insertText("Z", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(selectedInsert.counter.value == 1)
        #expect(selectedInsert.session.document.blocks[0].inlineContent.spans.map(\.text).joined() == "Zbc")

        let explicitInsert = selectorFixture(selection: 0..<0)
        explicitInsert.view.insertText("Z", replacementRange: .init(location: 1, length: 1))
        #expect(explicitInsert.counter.value == 1)
        #expect(explicitInsert.session.document.blocks[0].inlineContent.spans.map(\.text).joined() == "aZc")

        let copy = selectorFixture(selection: 0..<1)
        copy.view.copy(nil)
        #expect(copy.counter.value == 0)
        #expect(copy.session.undoManager.canUndo == false)

        let cut = selectorFixture(selection: 0..<1)
        cut.view.cut(nil)
        #expect(cut.counter.value == 1)
        #expect(cut.session.undoManager.canUndo)

        NSPasteboard.general.clearContents()
        _ = NSPasteboard.general.setString("粘", forType: .string)
        let paste = selectorFixture(selection: 1..<1)
        paste.view.paste(nil)
        #expect(paste.counter.value == 1)
        #expect(paste.session.undoManager.canUndo)

        for (key, modifiers) in [("b", NSEvent.ModifierFlags.command), ("i", .command), ("c", [.command, .shift])] {
            let formatting = selectorFixture(selection: 0..<1)
            #expect(formatting.view.performKeyEquivalent(with: try keyEvent(characters: key, modifiers: modifiers)))
            #expect(formatting.counter.value == 1)
            #expect(formatting.session.undoManager.canUndo)
        }
    }

    @Test func composingDefersEverySensitiveSelectorThenCommitsOnlyAtTerminalTransition() throws {
        let fixture = selectorFixture(selection: 1..<1)
        let before = fixture.session.document
        fixture.view.setMarkedText("pin", selectedRange: .init(location: 3, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        let composingSelectors: [Selector] = [
            #selector(NSResponder.insertNewline(_:)),
            #selector(NSResponder.insertLineBreak(_:)),
            #selector(NSResponder.deleteBackward(_:)),
            #selector(NSResponder.insertTab(_:)),
            #selector(NSResponder.insertBacktab(_:)),
            #selector(NSResponder.moveLeft(_:)),
            #selector(NSResponder.moveRight(_:)),
            #selector(NSResponder.moveUp(_:)),
            #selector(NSResponder.moveDown(_:)),
            #selector(NSResponder.moveLeftAndModifySelection(_:)),
            #selector(NSResponder.moveRightAndModifySelection(_:)),
            #selector(NSResponder.moveUpAndModifySelection(_:)),
            #selector(NSResponder.moveDownAndModifySelection(_:))
        ]
        for selector in composingSelectors {
            fixture.view.doCommand(by: selector)
            #expect(fixture.session.document == before)
            #expect(fixture.counter.value == 0)
        }
        #expect(fixture.session.handleSlashSelector(#selector(NSResponder.insertNewline(_:))) == false)
        fixture.view.insertText("中", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(fixture.counter.value == 1)
        #expect(fixture.session.document.blocks[0].inlineContent.spans.map(\.text).joined() == "a中bc")
        fixture.view.unmarkText()
        #expect(fixture.counter.value == 1)

        fixture.view.setMarkedText("x", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        fixture.view.cancelOperation(nil)
        #expect(fixture.counter.value == 1)
        #expect(fixture.session.document.blocks[0].inlineContent.spans.map(\.text).joined() == "a中bc")
    }

    @Test func installedTextViewRejectsInvalidBridgeEmptyPasteAndCutWithoutNativeStorageBypass() {
        let fixture = selectorFixture(selection: 1..<1)
        let original = fixture.session.document
        fixture.view.applyAuthoritativeProjection(text: "abc", selectedRange: .init(location: 0, length: 1))
        fixture.view.insertText("X", replacementRange: .init(location: 99, length: 0))
        #expect(fixture.session.document == original)
        #expect(fixture.view.string == "abc")
        #expect(fixture.counter.value == 0)

        NSPasteboard.general.clearContents()
        fixture.view.paste(nil)
        #expect(fixture.session.document == original)
        #expect(fixture.view.string == "abc")
        fixture.view.cut(nil)
        #expect(fixture.session.document == original)
        #expect(fixture.view.string == "abc")
        #expect(fixture.counter.value == 0)
    }
}

@MainActor
private final class SelectorCounter { var value = 0 }

@MainActor
private func selectorFixture(selection range: Range<Int>) -> (session: BlockEditorSession, view: BlockEditorTextView, counter: SelectorCounter) {
    let id = BlockID()
    let document = BlockDocument(blocks: [.init(id: id, kind: .paragraph, inlineContent: .plain("abc"), taskState: nil, indentLevel: 0)])
    let selection = BlockEditorSelection.text(
        anchor: .init(blockID: id, graphemeOffset: range.lowerBound),
        focus: .init(blockID: id, graphemeOffset: range.upperBound),
        preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil)
    )
    let counter = SelectorCounter()
    let session = BlockEditorSession(noteID: NoteID(), editSessionID: UUID(), initialDocument: document, initialSelection: selection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in counter.value += 1 })
    let view = BlockEditorTextView()
    session.attach(blockID: id, hostToken: UUID(), textView: view)
    return (session, view, counter)
}

private func keyEvent(characters: String, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: 0
    ))
}
