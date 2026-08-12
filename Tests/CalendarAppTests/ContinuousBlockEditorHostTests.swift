import AppKit
import Foundation
import SwiftUI
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("ContinuousBlockEditorHostTests")
struct ContinuousBlockEditorHostTests {
    @Test @MainActor func productionTwentyBlockDocumentCreatesOneEditableTextViewAndOneUndoOwner() throws {
        _ = NSApplication.shared
        let blocks = (0..<20).map {
            continuousBlock(id: $0 + 1, text: "第\($0 + 1)段")
        }
        var capturedSession: BlockEditorSession?
        let root = BlockEditorView(
            noteID: NoteID(),
            editSessionID: UUID(),
            initialDocument: .init(blocks: blocks),
            initialSelection: continuousCaret(blocks[0].id, 0),
            focusRegistry: EditorFocusRegistry(),
            onDocumentChange: { _ in },
            sessionSink: { capturedSession = $0 }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = .init(x: 0, y: 0, width: 640, height: 800)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let textViews = continuousDescendants(of: hosting, as: ContinuousBlockEditorTextView.self)
        let session = try #require(capturedSession)
        let textView = try #require(textViews.first)
        #expect(textViews.count == 1)
        #expect(textView.isEditable)
        #expect(textView.authoritativeUndoManager === session.undoManager)
        #expect(textView.string == blocks.map(continuousText).joined(separator: "\n"))
        #expect(continuousDescendants(of: hosting, as: BlockEditorTextView.self).isEmpty)
        window.orderOut(nil)
    }

    @Test @MainActor func nativeHostGrowsWithTextKitContentWithoutCreatingANestedScrollView() {
        let text = (0..<30).map { "第\($0)行连续正文" }.joined(separator: "\n")
        let block = continuousBlock(id: 25, text: text)
        let fixture = continuousFixture(blocks: [block], selection: continuousCaret(block.id, 0))
        fixture.host.frame = .init(x: 0, y: 0, width: 220, height: 80)
        fixture.host.layoutSubtreeIfNeeded()

        #expect(fixture.host.intrinsicContentSize.height > 300)
        #expect(fixture.view.enclosingScrollView == nil)
        #expect(continuousDescendants(of: fixture.host, as: NSScrollView.self).isEmpty)
    }

    @Test @MainActor func emptyDocumentHasOnePresentationOnlyPlaceholderThatCompositionHides() {
        let block = continuousBlock(id: 26, text: "")
        let fixture = continuousFixture(blocks: [block], selection: continuousCaret(block.id, 0))

        #expect(fixture.view.isPresentingEmptyDocumentPlaceholder)
        #expect(fixture.view.string.isEmpty)
        #expect(continuousText(fixture.session.document.blocks[0]).isEmpty)

        fixture.view.setMarkedText(
            "pin",
            selectedRange: .init(location: 3, length: 0),
            replacementRange: .init(location: NSNotFound, length: 0)
        )
        #expect(fixture.view.isPresentingEmptyDocumentPlaceholder == false)
        #expect(continuousText(fixture.session.document.blocks[0]).isEmpty)
        fixture.view.cancelOperation(nil)
        #expect(fixture.view.isPresentingEmptyDocumentPlaceholder)
    }

    @Test @MainActor func nativeCrossThreeBlockSelectionRoundTripsWithReverseDirection() throws {
        let blocks = [
            continuousBlock(id: 30, text: "甲乙"),
            continuousBlock(id: 31, text: "丙丁"),
            continuousBlock(id: 32, text: "戊己")
        ]
        let fixture = continuousFixture(blocks: blocks, selection: continuousCaret(blocks[0].id, 0))
        let attributes = BlockTypingAttributes(marks: [.bold], linkURL: nil)

        try fixture.session.adoptNativeSelection(
            .init(location: 1, length: 5),
            direction: .reverse,
            typingAttributes: attributes
        )

        #expect(fixture.session.selection == .text(
            anchor: .init(blockID: blocks[2].id, graphemeOffset: 0),
            focus: .init(blockID: blocks[0].id, graphemeOffset: 1),
            preferredColumn: nil,
            typingAttributes: attributes
        ))
        #expect(fixture.view.selectedRange == .init(location: 1, length: 5))
    }

    @Test @MainActor func nativeEnterSoftBreakAndBoundaryBackspaceUseTheExistingReducer() throws {
        let first = continuousBlock(id: 40, text: "甲乙")
        let second = continuousBlock(id: 41, text: "丙")
        let fixture = continuousFixture(
            blocks: [first, second],
            selection: continuousCaret(first.id, 1)
        )

        fixture.view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(fixture.session.document.blocks.count == 3)
        #expect(fixture.session.document.blocks.map(continuousText) == ["甲", "乙", "丙"])

        fixture.view.doCommand(by: #selector(NSResponder.insertLineBreak(_:)))
        #expect(fixture.session.document.blocks.map(continuousText) == ["甲", "\n乙", "丙"])

        fixture.view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(fixture.session.document.blocks.map(continuousText) == ["甲", "乙", "丙"])
        #expect(fixture.session.undoManager.canUndo)
    }

    @Test @MainActor func horizontalMovementCrossesStructuralNewlineAndLastCharacterDeletionKeepsOneBlock() throws {
        let first = continuousBlock(id: 45, text: "甲")
        let second = continuousBlock(id: 46, text: "乙")
        let fixture = continuousFixture(
            blocks: [first, second],
            selection: continuousCaret(first.id, 1)
        )

        fixture.view.doCommand(by: #selector(NSResponder.moveRight(_:)))
        #expect(fixture.session.selection == continuousCaret(second.id, 0))
        #expect(fixture.view.selectedRange == .init(location: 2, length: 0))
        fixture.view.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        #expect(fixture.session.selection == continuousCaret(first.id, 1))

        let only = continuousBlock(id: 47, text: "字")
        let single = continuousFixture(blocks: [only], selection: continuousCaret(only.id, 1))
        single.view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(single.session.document.blocks.count == 1)
        #expect(continuousText(single.session.document.blocks[0]).isEmpty)
        #expect(single.view.string.isEmpty)
    }

    @Test @MainActor func ordinaryKeystrokeAppliesOneBoundedDiffWithoutASecondFullProjection() {
        let block = continuousBlock(id: 48, text: "原")
        let fixture = continuousFixture(blocks: [block], selection: continuousCaret(block.id, 1))
        #expect(fixture.view.fullProjectionApplyCount == 1)
        #expect(fixture.view.diffProjectionApplyCount == 0)

        fixture.view.insertText("文", replacementRange: .init(location: NSNotFound, length: 0))

        #expect(fixture.view.string == "原文")
        #expect(fixture.view.fullProjectionApplyCount == 1)
        #expect(fixture.view.diffProjectionApplyCount == 1)
        #expect(fixture.view.textStorage?.attribute(
            .jellyBlockID,
            at: 0,
            effectiveRange: nil
        ) as? String == block.id.rawValue.uuidString)
        #expect(fixture.view.textStorage?.attribute(
            .jellyBlockKind,
            at: 0,
            effectiveRange: nil
        ) as? String == BlockKind.paragraph.rawValue)
    }

    @Test @MainActor func markedCandidatesPublishOnlyOnceAtTerminalCommitAndUndoOnce() throws {
        let block = continuousBlock(id: 50, text: "")
        var publications: [BlockDocument] = []
        let fixture = continuousFixture(
            blocks: [block],
            selection: continuousCaret(block.id, 0),
            onDocumentChange: { publications.append($0) }
        )

        fixture.view.setMarkedText(
            "n",
            selectedRange: .init(location: 1, length: 0),
            replacementRange: .init(location: NSNotFound, length: 0)
        )
        fixture.view.setMarkedText(
            "ni🙂",
            selectedRange: .init(location: 4, length: 0),
            replacementRange: .init(location: NSNotFound, length: 0)
        )
        fixture.view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        fixture.view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(publications.isEmpty)
        #expect(continuousText(fixture.session.document.blocks[0]).isEmpty)

        fixture.view.insertText("你🙂", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(publications.count == 1)
        #expect(continuousText(fixture.session.document.blocks[0]) == "你🙂")
        #expect(fixture.session.undoManager.canUndo)
        fixture.session.undoManager.undo()
        #expect(continuousText(fixture.session.document.blocks[0]).isEmpty)
    }

    @Test @MainActor func cancellingMarkedTextRestoresTheAuthoritativeProjectionWithoutPublishing() throws {
        let block = continuousBlock(id: 60, text: "原文")
        var publicationCount = 0
        let fixture = continuousFixture(
            blocks: [block],
            selection: continuousCaret(block.id, 2),
            onDocumentChange: { _ in publicationCount += 1 }
        )
        fixture.view.setMarkedText(
            "候选",
            selectedRange: .init(location: 2, length: 0),
            replacementRange: .init(location: NSNotFound, length: 0)
        )

        fixture.view.cancelOperation(nil)

        #expect(publicationCount == 0)
        #expect(fixture.view.string == "原文")
        #expect(continuousText(fixture.session.document.blocks[0]) == "原文")
    }

    @Test @MainActor func unmarkCommitsTheLatestChineseEmojiCandidateExactlyOnce() throws {
        let block = continuousBlock(id: 61, text: "")
        var publicationCount = 0
        let fixture = continuousFixture(
            blocks: [block],
            selection: continuousCaret(block.id, 0),
            onDocumentChange: { _ in publicationCount += 1 }
        )
        fixture.view.setMarkedText(
            "中文🙂",
            selectedRange: .init(location: 4, length: 0),
            replacementRange: .init(location: NSNotFound, length: 0)
        )

        fixture.view.unmarkText()

        #expect(publicationCount == 1)
        #expect(continuousText(fixture.session.document.blocks[0]) == "中文🙂")
        #expect(fixture.session.undoManager.canUndo)
    }

    @Test @MainActor func documentEdgeFocusUsesTheFirstAndLastCaretAndAddsOneParagraphAfterDivider() throws {
        let first = continuousBlock(id: 70, text: "开头")
        let last = continuousBlock(id: 71, text: "结尾")
        let fixture = continuousFixture(blocks: [first, last], selection: continuousCaret(first.id, 1))

        fixture.session.focusDocumentEnd()
        #expect(fixture.session.selection == continuousCaret(last.id, 2))
        fixture.session.focusDocumentStart()
        #expect(fixture.session.selection == continuousCaret(first.id, 0))

        let divider = DocumentBlock(
            id: BlockID(),
            kind: .divider,
            inlineContent: .plain(""),
            taskState: nil,
            indentLevel: 0
        )
        let dividerFixture = continuousFixture(
            blocks: [first, divider],
            selection: continuousCaret(first.id, 0)
        )
        dividerFixture.session.focusDocumentEnd()
        #expect(dividerFixture.session.document.blocks.count == 3)
        #expect(dividerFixture.session.document.blocks.last?.kind == .paragraph)
        dividerFixture.session.focusDocumentEnd()
        #expect(dividerFixture.session.document.blocks.count == 3)
    }
}

@MainActor
private func continuousFixture(
    blocks: [DocumentBlock],
    selection: BlockEditorSelection,
    onDocumentChange: @escaping (BlockDocument) -> Void = { _ in }
) -> (session: BlockEditorSession, host: ContinuousBlockEditorHostView, view: ContinuousBlockEditorTextView) {
    let session = BlockEditorSession(
        noteID: NoteID(),
        editSessionID: UUID(),
        initialDocument: .init(blocks: blocks),
        initialSelection: selection,
        focusRegistry: EditorFocusRegistry(),
        onDocumentChange: onDocumentChange
    )
    let host = ContinuousBlockEditorHostView(appearance: CalendarTheme.light)
    session.attach(host: host, hostToken: UUID())
    return (session, host, host.textView)
}

private func continuousBlock(id: Int, text: String) -> DocumentBlock {
    .init(
        id: BlockID(UUID(uuidString: String(format: "00000000-0000-0000-0002-%012d", id))!),
        kind: .paragraph,
        inlineContent: .plain(text),
        taskState: nil,
        indentLevel: 0
    )
}

private func continuousText(_ block: DocumentBlock) -> String {
    block.inlineContent.spans.map(\.text).joined()
}

private func continuousCaret(_ blockID: BlockID, _ offset: Int) -> BlockEditorSelection {
    .text(
        anchor: .init(blockID: blockID, graphemeOffset: offset),
        focus: .init(blockID: blockID, graphemeOffset: offset),
        preferredColumn: nil,
        typingAttributes: .init(marks: [], linkURL: nil)
    )
}

@MainActor
private func continuousDescendants<T: NSView>(of root: NSView, as type: T.Type) -> [T] {
    var result = root as? T == nil ? [] : [root as! T]
    for child in root.subviews {
        result.append(contentsOf: continuousDescendants(of: child, as: type))
    }
    return result
}
