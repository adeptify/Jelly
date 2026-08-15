import AppKit
import Foundation
import SwiftUI
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("BlockEditorUndoTests")
@MainActor
struct BlockEditorUndoTests {
    @Test @MainActor func localTaskCheckboxCompletionIsOneEditorUndoStepWithoutACalendarLink() throws {
        let blockID = BlockID()
        let block = try DocumentBlock.task(id: blockID, text: "先在正文完成")
        let document = BlockDocument(blocks: [block])
        var publications: [BlockDocument] = []
        let session = BlockEditorSession(
            noteID: NoteID(),
            editSessionID: UUID(),
            initialDocument: document,
            initialSelection: reviewCaret(blockID, 0),
            focusRegistry: EditorFocusRegistry(),
            onDocumentChange: { publications.append($0) }
        )
        let completedAt = Date(timeIntervalSince1970: 1_755_000_100)

        #expect(session.toggleTaskCompletion(blockID: blockID, at: completedAt))
        #expect(session.document.blocks[0].taskState?.completedAt == completedAt)
        #expect(publications.count == 1)
        session.undoManager.undo()
        #expect(session.document == document)
        #expect(publications.count == 2)
        session.undoManager.redo()
        #expect(session.document.blocks[0].taskState?.completedAt == completedAt)
        #expect(publications.count == 3)
    }

    @Test func sessionOwnsOneUndoManagerAndTypingUndoRestoresAuthoritativeSnapshot() throws {
        let fixture = undoFixture()
        var published: [BlockDocument] = []
        let session = BlockEditorSession(
            noteID: NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000000701")!),
            editSessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000702")!,
            initialDocument: fixture.document,
            initialSelection: fixture.selection,
            focusRegistry: EditorFocusRegistry(),
            onDocumentChange: { published.append($0) }
        )
        let manager = session.undoManager

        _ = try session.dispatch(.insertText("甲"))
        #expect(session.document.blocks[0].inlineContent.spans.map(\.text).joined() == "a甲")
        #expect(published.count == 1)
        #expect(session.undoManager === manager)

        manager.undo()
        #expect(session.document == fixture.document)
        #expect(session.selection == fixture.selection)
        #expect(published.count == 2)

        manager.redo()
        #expect(session.document.blocks[0].inlineContent.spans.map(\.text).joined() == "a甲")
        #expect(published.count == 3)
    }

    @Test func staleHostDetachCannotClearNewerHostFocusLease() {
        let fixture = undoFixture()
        let registry = EditorFocusRegistry()
        let session = BlockEditorSession(
            noteID: NoteID(), editSessionID: UUID(), initialDocument: fixture.document,
            initialSelection: fixture.selection, focusRegistry: registry, onDocumentChange: { _ in }
        )
        let first = UUID()
        let second = UUID()
        let firstView = BlockEditorTextView()
        let secondView = BlockEditorTextView()

        session.attach(blockID: fixture.blockID, hostToken: first, textView: firstView)
        session.attach(blockID: fixture.blockID, hostToken: second, textView: secondView)
        session.focus(hostToken: second)
        session.detach(hostToken: first)

        #expect(registry.availability != .noFocusedOwner)
        session.detach(hostToken: second)
        #expect(registry.availability == .noFocusedOwner)
    }

    @Test func projectionDoesNotDispatchOrCreateUndo() throws {
        let fixture = undoFixture()
        var published = 0
        let session = BlockEditorSession(
            noteID: NoteID(), editSessionID: UUID(), initialDocument: fixture.document,
            initialSelection: fixture.selection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in published += 1 }
        )
        let view = BlockEditorTextView()
        session.attach(blockID: fixture.blockID, hostToken: UUID(), textView: view)
        session.projectAuthoritativeState()

        #expect(published == 0)
        #expect(session.undoManager.canUndo == false)
        #expect(session.document == fixture.document)
    }

    @Test func resultConsumptionAcceptsOnlyTheCompleteLegalMatrix() throws {
        let fixture = undoFixture()
        let changed = BlockDocument(blocks: [
            .init(id: fixture.blockID, kind: .paragraph, inlineContent: .plain("ab"), taskState: nil, indentLevel: 0)
        ])
        let end = BlockEditorSelection.text(
            anchor: .init(blockID: fixture.blockID, graphemeOffset: 2),
            focus: .init(blockID: fixture.blockID, graphemeOffset: 2),
            preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil)
        )
        let rows: [BlockInputResult] = [
            .init(document: fixture.document, selection: fixture.selection, mutation: .none(.samePosition), effect: .handled, undo: .none),
            .init(document: fixture.document, selection: fixture.selection, mutation: .none(.composingText), effect: .deferToTextSystem, undo: .none),
            .init(document: fixture.document, selection: fixture.selection, mutation: .none(.emptySelection), effect: .writeClipboard(.init(plainText: "a", richBlocks: [])), undo: .none),
            .init(document: fixture.document, selection: fixture.selection, mutation: .none(.samePosition), effect: .handled, undo: .breakCoalescing),
            .init(document: fixture.document, selection: end, mutation: .selectionOnly, effect: .handled, undo: .none),
            .init(document: changed, selection: end, mutation: .document, effect: .handled, undo: .coalesceTyping(fixture.blockID)),
            .init(document: changed, selection: end, mutation: .document, effect: .handled, undo: .atomic(.enter)),
            .init(document: changed, selection: end, mutation: .document, effect: .writeClipboard(.init(plainText: "a", richBlocks: [])), undo: .atomic(.cut))
        ]

        for row in rows {
            let session = makeUndoSession(fixture: fixture)
            _ = try session.consume(row)
        }

        let invalid = BlockInputResult(
            document: changed, selection: end, mutation: .document, effect: .handled, undo: .breakCoalescing
        )
        let session = makeUndoSession(fixture: fixture)
        let before = session.document
        #expect(throws: BlockEditorIntegrationError.illegalResult) {
            try session.consume(invalid)
        }
        #expect(session.document == before)
        #expect(session.undoManager.canUndo == false)
    }

    @Test func failedMandatoryPlainClipboardWritePreventsCutPublicationOrUndo() throws {
        let first = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000743")!)
        let second = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000744")!)
        let document = BlockDocument(blocks: [
            .init(id: first, kind: .paragraph, inlineContent: .plain("甲"), taskState: nil, indentLevel: 0),
            .init(id: second, kind: .paragraph, inlineContent: .plain("乙"), taskState: nil, indentLevel: 0)
        ])
        let crossSelection = BlockEditorSelection.text(
            anchor: .init(blockID: first, graphemeOffset: 0),
            focus: .init(blockID: second, graphemeOffset: 1),
            preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil)
        )
        let cut = try BlockInputReducer.reduce(
            document, selection: crossSelection, command: .cutSelection,
            environment: .init(isComposingText: false, idSource: .random)
        )
        let expectedPlain: String
        guard case let .writeClipboard(payload) = cut.effect else {
            Issue.record("cut must carry one complete clipboard payload")
            return
        }
        expectedPlain = payload.plainText

        var failedCallbacks = 0
        var failedWrites = 0
        let failedSession = BlockEditorSession(
            noteID: NoteID(), editSessionID: UUID(), initialDocument: document,
            initialSelection: crossSelection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in failedCallbacks += 1 }
        )

        #expect(throws: BlockEditorIntegrationError.clipboardWriteFailed) {
            try failedSession.consume(cut, clipboardWriter: { _ in failedWrites += 1; return false })
        }
        #expect(failedWrites == 1)
        #expect(failedSession.document == document)
        #expect(failedSession.selection == crossSelection)
        #expect(failedCallbacks == 0)
        #expect(failedSession.undoManager.canUndo == false)

        let pasteboard = NSPasteboard.withUniqueName()
        let adapter = BlockPasteboardAdapter(
            pasteboard: pasteboard,
            plainTextWriter: { board, text in board.setString(text, forType: .string) },
            customDataWriter: { _, _ in false }
        )
        var successCallbacks = 0
        let successfulSession = BlockEditorSession(
            noteID: NoteID(), editSessionID: UUID(), initialDocument: document,
            initialSelection: crossSelection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in successCallbacks += 1 }
        )

        _ = try successfulSession.consume(cut, clipboardWriter: { adapter.write(payload: $0) })
        #expect(pasteboard.string(forType: .string) == expectedPlain)
        #expect(successfulSession.document == cut.document)
        #expect(successCallbacks == 1)
        #expect(successfulSession.undoManager.canUndo)
    }

    @Test func resultConsumptionAcceptsOnlyEightRowsAndEveryOtherMatrixCellIsSideEffectFree() {
        let fixture = undoFixture()
        let changed = BlockDocument(blocks: [
            .init(id: fixture.blockID, kind: .paragraph, inlineContent: .plain("ab"), taskState: nil, indentLevel: 0)
        ])
        let end = BlockEditorSelection.text(
            anchor: .init(blockID: fixture.blockID, graphemeOffset: 2),
            focus: .init(blockID: fixture.blockID, graphemeOffset: 2),
            preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil)
        )
        let payload = BlockClipboardPayload(plainText: "a", richBlocks: [])
        let mutations: [BlockInputMutation] = [.none(.samePosition), .selectionOnly, .document]
        let effects: [BlockInputEffect] = [.handled, .deferToTextSystem, .writeClipboard(payload)]
        let undos: [BlockUndoDirective] = [.none, .breakCoalescing, .coalesceTyping(fixture.blockID), .atomic(.enter)]
        var legalRows = 0
        var rejectedRows = 0

        for mutation in mutations {
            for effect in effects {
                for undo in undos {
                    let resolvedUndo: BlockUndoDirective
                    if mutation == .document, case .writeClipboard = effect, case .atomic = undo {
                        resolvedUndo = .atomic(.cut)
                    } else {
                        resolvedUndo = undo
                    }
                    let result = BlockInputResult(
                        document: mutation == .document ? changed : fixture.document,
                        selection: mutation == .selectionOnly || mutation == .document ? end : fixture.selection,
                        mutation: mutation, effect: effect, undo: resolvedUndo
                    )
                    let legal = isLegalConsumptionRow(mutation: mutation, effect: effect, undo: resolvedUndo)
                    var callbacks = 0
                    var writes = 0
                    let session = BlockEditorSession(
                        noteID: NoteID(), editSessionID: UUID(), initialDocument: fixture.document,
                        initialSelection: fixture.selection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in callbacks += 1 }
                    )

                    if legal {
                        legalRows += 1
                        do {
                            _ = try session.consume(result, clipboardWriter: { _ in writes += 1; return true })
                        } catch {
                            Issue.record("legal result was rejected: \(mutation), \(effect), \(resolvedUndo)")
                        }
                        let publishes = mutation == .document
                        let usesClipboard: Bool
                        if case .writeClipboard = effect { usesClipboard = true } else { usesClipboard = false }
                        #expect(callbacks == (publishes ? 1 : 0))
                        #expect(writes == (usesClipboard ? 1 : 0))
                        #expect(session.undoManager.canUndo == publishes)
                    } else {
                        rejectedRows += 1
                        #expect(throws: BlockEditorIntegrationError.illegalResult) {
                            try session.consume(result, clipboardWriter: { _ in writes += 1; return true })
                        }
                        #expect(session.document == fixture.document)
                        #expect(session.selection == fixture.selection)
                        #expect(callbacks == 0)
                        #expect(writes == 0)
                        #expect(session.undoManager.canUndo == false)
                    }
                }
            }
        }
        #expect(legalRows == 8)
        #expect(rejectedRows == 28)

        let illegalClipboardAction = BlockInputResult(
            document: changed, selection: end, mutation: .document,
            effect: .writeClipboard(payload), undo: .atomic(.enter)
        )
        let illegalSession = makeUndoSession(fixture: fixture)
        #expect(throws: BlockEditorIntegrationError.illegalResult) {
            try illegalSession.consume(illegalClipboardAction, clipboardWriter: { _ in true })
        }
        #expect(illegalSession.document == fixture.document)
        #expect(illegalSession.undoManager.canUndo == false)
    }

    @Test func hostedProductionEditorFindsNativeTextViewsAndRoutesPointerTypeUndoAndAutosave() throws {
        let first = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000751")!)
        let second = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000752")!)
        let document = BlockDocument(blocks: [
            .init(id: first, kind: .paragraph, inlineContent: .plain("甲👍🏽"), taskState: nil, indentLevel: 0),
            .init(id: second, kind: .paragraph, inlineContent: .plain("乙文"), taskState: nil, indentLevel: 0)
        ])
        let selection = BlockEditorSelection.text(
            anchor: .init(blockID: first, graphemeOffset: 0),
            focus: .init(blockID: first, graphemeOffset: 0),
            preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil)
        )
        let harness = try HostedBlockEditorHarness(document: document, selection: selection)
        defer { harness.close() }
        let firstView = try harness.textView(for: first)
        let secondView = try harness.textView(for: second)
        #expect(firstView === secondView)
        #expect(firstView.attachedSession === secondView.attachedSession)
        let session = try #require(firstView.attachedSession)
        let firstPoint = try #require(firstView.windowPoint(forUTF16Offset: 1))
        let secondPoint = try #require(secondView.windowPoint(forUTF16Offset: 7))
        #expect(firstView.utf16Offset(at: firstView.convert(firstPoint, from: nil)) == 1)
        #expect(secondView.utf16Offset(at: secondView.convert(secondPoint, from: nil)) == 7)

        #expect(firstView.beginPointerSelection(atUTF16Offset: 1))
        #expect(firstView.extendPointerSelection(toUTF16Offset: 7))
        #expect(harness.window.makeFirstResponder(firstView))
        #expect(firstView.selectedRange == .init(location: 1, length: 6))

        #expect(firstView.beginPointerSelection(atUTF16Offset: 1))
        #expect(firstView.extendPointerSelection(toUTF16Offset: 7))
        #expect(firstView.selectedRange == .init(location: 1, length: 6))

        #expect(firstView.beginPointerSelection(atUTF16Offset: 1))
        firstView.insertText("中", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(harness.documents.count == 1)
        #expect(harness.document.blocks[0].inlineContent.spans.map(\.text).joined() == "甲中👍🏽")
        firstView.setMarkedText("pin", selectedRange: .init(location: 3, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        firstView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(harness.documents.count == 1)
        firstView.insertText("拼", replacementRange: .init(location: NSNotFound, length: 0))
        firstView.unmarkText()
        #expect(harness.documents.count == 2)
        #expect(harness.document.blocks[0].inlineContent.spans.map(\.text).joined() == "甲中拼👍🏽")
        #expect(session.undoManager.canUndo)
        let beforeAutosaveView = firstView
        let manager = session.undoManager
        session.autosaveDidResolve(.saving)
        session.autosaveDidResolve(.saved)
        harness.redrawWithEquivalentRoot()
        let redrawnFirstView = try harness.textView(for: first)
        #expect(redrawnFirstView === beforeAutosaveView)
        #expect(redrawnFirstView.attachedSession === session)
        #expect(redrawnFirstView.attachedSession?.undoManager === manager)
        #expect(redrawnFirstView.string == "甲中拼👍🏽\n乙文")

        #expect(harness.registry.routeUndo() == .focusedPerformed)
        #expect(harness.document == document)
    }

    @Test func hostedFormattingButtonsRestoreEditorFocusAndKeepUndoRoutedToSession() throws {
        _ = NSApplication.shared
        let blockID = BlockID()
        let document = BlockDocument(blocks: [reviewBlock(blockID, "a")])
        let selection = BlockEditorSelection.text(
            anchor: .init(blockID: blockID, graphemeOffset: 0),
            focus: .init(blockID: blockID, graphemeOffset: 1),
            preferredColumn: nil,
            typingAttributes: .init(marks: [], linkURL: nil)
        )
        let promptedURL = try #require(URL(string: "https://example.com/focused-link"))
        let promptResponses = LinkPromptResponses([promptedURL, nil])
        let harness = try HostedBlockEditorHarness(
            document: document, selection: selection,
            requestLinkURL: { promptResponses.next() }
        )
        defer { harness.close() }
        var workspaceUndoCalls = 0
        func routeFocusedUndo() -> EditorUndoRouteResult {
            let route = harness.registry.routeUndo()
            if route == .noFocusedOwner { workspaceUndoCalls += 1 }
            return route
        }
        let textView = try harness.textView(for: blockID)
        #expect(harness.window.makeFirstResponder(textView))

        let bold = try harness.formattingButton(identifier: "block-format-bold")
        #expect(harness.window.makeFirstResponder(bold))
        #expect(bold.sendAction(bold.action, to: bold.target))
        #expect(harness.window.firstResponder === textView)
        #expect(harness.registry.availability == .focused(canUndo: true, canRedo: false))
        #expect(routeFocusedUndo() == .focusedPerformed)
        #expect(harness.document == document)
        #expect(workspaceUndoCalls == 0)

        let generalPasteboard = NSPasteboard.general
        generalPasteboard.clearContents()
        defer { generalPasteboard.clearContents() }
        harness.redraw()
        let link = try harness.formattingButton(identifier: "block-format-link")
        #expect(harness.window.makeFirstResponder(link))
        #expect(link.sendAction(link.action, to: link.target))
        #expect(harness.window.firstResponder === textView)
        #expect(harness.document.blocks[0].inlineContent.spans.allSatisfy { $0.linkURL == promptedURL })
        #expect(routeFocusedUndo() == .focusedPerformed)
        #expect(harness.document == document)
        #expect(workspaceUndoCalls == 0)

        generalPasteboard.clearContents()
        harness.redraw()
        let cancelLink = try harness.formattingButton(identifier: "block-format-link")
        #expect(harness.window.makeFirstResponder(cancelLink))
        #expect(cancelLink.sendAction(cancelLink.action, to: cancelLink.target))
        #expect(harness.window.firstResponder === textView)
        #expect(routeFocusedUndo() == .focusedUnavailable)
        #expect(harness.document == document)
        #expect(workspaceUndoCalls == 0)
    }

    @Test func hostedLinkButtonRemovesTheLinkAtItsCollapsedCaretWithoutPromptingAgain() throws {
        _ = NSApplication.shared
        let blockID = BlockID()
        let document = BlockDocument(blocks: [reviewBlock(blockID, "link target")])
        let selection = BlockEditorSelection.text(
            anchor: .init(blockID: blockID, graphemeOffset: 0),
            focus: .init(blockID: blockID, graphemeOffset: 11),
            preferredColumn: nil,
            typingAttributes: .init(marks: [], linkURL: nil)
        )
        let url = try #require(URL(string: "https://example.com/collapsed-removal"))
        var promptCount = 0
        let harness = try HostedBlockEditorHarness(
            document: document,
            selection: selection,
            requestLinkURL: {
                promptCount += 1
                return url
            }
        )
        defer { harness.close() }

        var linkButton = try harness.formattingButton(identifier: "block-format-link")
        #expect(linkButton.sendAction(linkButton.action, to: linkButton.target))
        #expect(promptCount == 1)
        #expect(harness.document.blocks[0].inlineContent.spans.contains { $0.linkURL == url })

        harness.redraw()
        linkButton = try harness.formattingButton(identifier: "block-format-link")
        #expect(linkButton.sendAction(linkButton.action, to: linkButton.target))
        #expect(promptCount == 1)
        #expect(harness.document == document)
    }

    @Test func hostedInlineStyleButtonsReallyRemoveTheStyleOnTheSecondClick() throws {
        _ = NSApplication.shared
        for identifier in ["block-format-bold", "block-format-italic", "block-format-code"] {
            let blockID = BlockID()
            let document = BlockDocument(blocks: [reviewBlock(blockID, "styled text")])
            let selection = BlockEditorSelection.text(
                anchor: .init(blockID: blockID, graphemeOffset: 0),
                focus: .init(blockID: blockID, graphemeOffset: 11),
                preferredColumn: nil,
                typingAttributes: .init(marks: [], linkURL: nil)
            )
            let harness = try HostedBlockEditorHarness(document: document, selection: selection)
            defer { harness.close() }

            var button = try harness.formattingButton(identifier: identifier)
            #expect(button.sendAction(button.action, to: button.target))
            #expect(harness.document != document, Comment(rawValue: identifier))

            harness.redraw()
            button = try harness.formattingButton(identifier: identifier)
            #expect(button.sendAction(button.action, to: button.target))
            #expect(harness.document == document, Comment(rawValue: identifier))
        }
    }

    @Test func imeMultiUpdateInsertAndUnmarkCommitExactlyOnceWithChineseAndEmoji() {
        let fixture = undoFixture()
        var callbacks = 0
        let session = BlockEditorSession(
            noteID: NoteID(), editSessionID: UUID(), initialDocument: fixture.document,
            initialSelection: fixture.selection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in callbacks += 1 }
        )
        let view = BlockEditorTextView()
        let hostToken = UUID()
        session.attach(blockID: fixture.blockID, hostToken: hostToken, textView: view)
        session.focus(hostToken: hostToken)

        view.setMarkedText("zh", selectedRange: .init(location: 2, length: 0), replacementRange: .init(location: 1, length: 0))
        view.setMarkedText("zho", selectedRange: .init(location: 3, length: 0), replacementRange: .init(location: 1, length: 0))
        #expect(session.document == fixture.document)
        view.insertText("中🙂", replacementRange: .init(location: 1, length: 0))
        #expect(session.document.blocks[0].inlineContent.spans.map(\.text).joined() == "a中🙂")
        #expect(callbacks == 1)
        view.unmarkText()
        #expect(session.document.blocks[0].inlineContent.spans.map(\.text).joined() == "a中🙂")
        #expect(callbacks == 1)

        view.setMarkedText("拼音🙂", selectedRange: .init(location: 4, length: 0), replacementRange: .init(location: 2, length: 0))
        view.unmarkText()
        #expect(session.document.blocks[0].inlineContent.spans.map(\.text).joined() == "a中拼音🙂🙂")
        #expect(callbacks == 2)
        view.unmarkText()
        #expect(callbacks == 2)
    }

    @Test func imeCancelRestoresOriginalReverseSelectionNotItsReplacementRange() {
        let fixture = undoFixture()
        let original = BlockEditorSelection.text(
            anchor: .init(blockID: fixture.blockID, graphemeOffset: 1),
            focus: .init(blockID: fixture.blockID, graphemeOffset: 0),
            preferredColumn: nil, typingAttributes: .init(marks: [.bold], linkURL: nil)
        )
        var callbacks = 0
        let session = BlockEditorSession(
            noteID: NoteID(), editSessionID: UUID(), initialDocument: fixture.document,
            initialSelection: original, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in callbacks += 1 }
        )
        let view = BlockEditorTextView()
        let token = UUID()
        session.attach(blockID: fixture.blockID, hostToken: token, textView: view)
        view.setMarkedText("pinyin", selectedRange: .init(location: 5, length: 0), replacementRange: .init(location: 1, length: 0))
        view.cancelOperation(nil)

        #expect(session.document == fixture.document)
        #expect(session.selection == original)
        #expect(callbacks == 0)
        #expect(session.undoManager.canUndo == false)
    }

    @Test func compositionTerminalTokensSuppressOnlyLateDuplicatesAndActiveDetachRestoresBaseline() {
        let fixture = undoFixture()
        var callbacks = 0
        let session = BlockEditorSession(noteID: NoteID(), editSessionID: UUID(), initialDocument: fixture.document, initialSelection: fixture.selection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in callbacks += 1 })
        let view = BlockEditorTextView()
        let token = UUID()
        session.attach(blockID: fixture.blockID, hostToken: token, textView: view)

        view.setMarkedText("zh", selectedRange: .init(location: 2, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        view.insertText("中", replacementRange: .init(location: NSNotFound, length: 0))
        view.insertText("中", replacementRange: .init(location: NSNotFound, length: 0))
        view.unmarkText()
        #expect(session.document.blocks[0].inlineContent.spans.map(\.text).joined() == "a中")
        #expect(callbacks == 1)
        view.insertText("x", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(session.document.blocks[0].inlineContent.spans.map(\.text).joined() == "a中x")
        #expect(callbacks == 2)

        let independent = BlockEditorSession(noteID: NoteID(), editSessionID: UUID(), initialDocument: fixture.document, initialSelection: fixture.selection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in })
        let independentView = BlockEditorTextView()
        let independentToken = UUID()
        independent.attach(blockID: fixture.blockID, hostToken: independentToken, textView: independentView)
        independentView.setMarkedText("zh", selectedRange: .init(location: 2, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        independentView.insertText("中", replacementRange: .init(location: NSNotFound, length: 0))
        independentView.beginNativeInputEvent()
        independentView.insertText("中", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(independent.document.blocks[0].inlineContent.spans.map(\.text).joined() == "a中中")

        let detaching = BlockEditorSession(noteID: NoteID(), editSessionID: UUID(), initialDocument: fixture.document, initialSelection: fixture.selection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in })
        let composingView = BlockEditorTextView()
        let composingToken = UUID()
        detaching.attach(blockID: fixture.blockID, hostToken: composingToken, textView: composingView)
        composingView.setMarkedText("p", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        detaching.detach(hostToken: composingToken)
        #expect(detaching.isComposing == false)
        #expect(detaching.document == fixture.document)
        let replacement = BlockEditorTextView()
        let replacementToken = UUID()
        detaching.attach(blockID: fixture.blockID, hostToken: replacementToken, textView: replacement)
        replacement.insertText("新", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(detaching.document.blocks[0].inlineContent.spans.map(\.text).joined() == "a新")

        var unmarkCallbacks = 0
        let unmarkSession = BlockEditorSession(noteID: NoteID(), editSessionID: UUID(), initialDocument: fixture.document, initialSelection: fixture.selection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in unmarkCallbacks += 1 })
        let unmarkView = BlockEditorTextView()
        let unmarkToken = UUID()
        unmarkSession.attach(blockID: fixture.blockID, hostToken: unmarkToken, textView: unmarkView)
        unmarkView.setMarkedText("拼", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        unmarkView.unmarkText()
        unmarkView.insertText("拼", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(unmarkSession.document.blocks[0].inlineContent.spans.map(\.text).joined() == "a拼")
        #expect(unmarkCallbacks == 1)

        let cancelSession = BlockEditorSession(noteID: NoteID(), editSessionID: UUID(), initialDocument: fixture.document, initialSelection: fixture.selection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in })
        let cancelView = BlockEditorTextView()
        let cancelToken = UUID()
        cancelSession.attach(blockID: fixture.blockID, hostToken: cancelToken, textView: cancelView)
        cancelView.setMarkedText("p", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        cancelView.cancelOperation(nil)
        cancelView.insertText("p", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(cancelSession.document == fixture.document)
        cancelView.insertText("x", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(cancelSession.document.blocks[0].inlineContent.spans.map(\.text).joined() == "ax")
    }

    @Test func replacementHostLeaseRejectsStaleFocusSelectionAndComposition() {
        let fixture = undoFixture()
        let registry = EditorFocusRegistry()
        let session = BlockEditorSession(noteID: NoteID(), editSessionID: UUID(), initialDocument: fixture.document, initialSelection: fixture.selection, focusRegistry: registry, onDocumentChange: { _ in })
        let first = UUID()
        let second = UUID()
        let staleView = BlockEditorTextView()
        let activeView = BlockEditorTextView()
        session.attach(blockID: fixture.blockID, hostToken: first, textView: staleView)
        session.attach(blockID: fixture.blockID, hostToken: second, textView: activeView)
        session.focus(hostToken: first)
        #expect(registry.availability == .noFocusedOwner)
        staleView.setMarkedText("p", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        staleView.applyAuthoritativeProjection(text: "a", selectedRange: .init(location: 0, length: 0))
        session.updateNativeSelection(blockID: fixture.blockID, range: .init(location: 0, length: 0), hostToken: first)
        #expect(session.selection == fixture.selection)
        #expect(session.isComposing == false)
        session.focus(hostToken: second)
        #expect(registry.availability != .noFocusedOwner)
        session.detach(hostToken: first)
        #expect(registry.availability != .noFocusedOwner)
        activeView.insertText("甲", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(session.document.blocks[0].inlineContent.spans.map(\.text).joined() == "a甲")
    }

    @Test func dragUsesStableRootsPreservesClosuresAndRejectsInsideClosureDrop() {
        let root = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000711")!)
        let child = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000712")!)
        let moving = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000713")!)
        let document = BlockDocument(blocks: [
            .init(id: root, kind: .bullet, inlineContent: .plain("父"), taskState: nil, indentLevel: 0),
            .init(id: child, kind: .bullet, inlineContent: .plain("子"), taskState: nil, indentLevel: 1),
            .init(id: moving, kind: .bullet, inlineContent: .plain("移动"), taskState: nil, indentLevel: 0)
        ])
        let selection = BlockEditorSelection.text(anchor: .init(blockID: root, graphemeOffset: 0), focus: .init(blockID: root, graphemeOffset: 0), preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil))
        var callbacks = 0
        let session = BlockEditorSession(noteID: NoteID(), editSessionID: UUID(), initialDocument: document, initialSelection: selection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in callbacks += 1 })
        let drag = BlockDragCoordinator(session: session)

        #expect(drag.move(roots: [moving], before: root))
        #expect(session.document.blocks.map(\.id) == [moving, root, child])
        #expect(callbacks == 1)
        #expect(drag.move(roots: [root], before: child))
        #expect(session.document.blocks.map(\.id) == [moving, root, child])
        #expect(callbacks == 1)
    }

    @Test func dragMoveDownCrossesTheNextRootInsteadOfDroppingAtItsOriginalPosition() {
        let ids = (0..<3).map { value in BlockID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 720 + value))!) }
        let document = BlockDocument(blocks: ids.enumerated().map { index, id in
            .init(id: id, kind: .paragraph, inlineContent: .plain("\(index)"), taskState: nil, indentLevel: 0)
        })
        let selection = BlockEditorSelection.text(anchor: .init(blockID: ids[0], graphemeOffset: 0), focus: .init(blockID: ids[0], graphemeOffset: 0), preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil))
        var callbacks = 0
        let session = BlockEditorSession(noteID: NoteID(), editSessionID: UUID(), initialDocument: document, initialSelection: selection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in callbacks += 1 })

        #expect(BlockDragCoordinator(session: session).moveDown(roots: [ids[0]]))
        #expect(session.document.blocks.map(\.id) == [ids[1], ids[0], ids[2]])
        #expect(callbacks == 1)
    }

    @Test func dragDocumentEdgesAreNoopsAndRootNormalizationIgnoresDescendantsAndStaleIDs() {
        let ids = (0..<4).map { value in BlockID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 730 + value))!) }
        let document = BlockDocument(blocks: [
            .init(id: ids[0], kind: .bullet, inlineContent: .plain("A"), taskState: nil, indentLevel: 0),
            .init(id: ids[1], kind: .bullet, inlineContent: .plain("A-child"), taskState: nil, indentLevel: 1),
            .init(id: ids[2], kind: .bullet, inlineContent: .plain("B"), taskState: nil, indentLevel: 0),
            .init(id: ids[3], kind: .bullet, inlineContent: .plain("C"), taskState: nil, indentLevel: 0)
        ])
        let selection = BlockEditorSelection.text(anchor: .init(blockID: ids[0], graphemeOffset: 0), focus: .init(blockID: ids[0], graphemeOffset: 0), preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil))
        var callbacks = 0
        let session = BlockEditorSession(noteID: NoteID(), editSessionID: UUID(), initialDocument: document, initialSelection: selection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in callbacks += 1 })
        let drag = BlockDragCoordinator(session: session)

        #expect(drag.moveUp(roots: [ids[0]]))
        #expect(session.document == document)
        #expect(drag.moveDown(roots: [ids[3]]))
        #expect(session.document == document)
        #expect(callbacks == 0)
        #expect(session.undoManager.canUndo == false)

        #expect(drag.moveUp(roots: [ids[2]]))
        #expect(session.document.blocks.map(\.id) == [ids[2], ids[0], ids[1], ids[3]])
        #expect(callbacks == 1)
        #expect(drag.move(roots: [ids[1], ids[0]], before: ids[3]))
        #expect(session.document.blocks.map(\.id) == [ids[2], ids[0], ids[1], ids[3]])
        #expect(drag.move(roots: [BlockID()], before: nil) == false)
    }

    @Test func dragKeyboardAlternativesNormalizeUnsortedRootsAndKeepSelectionIDsStable() {
        let ids = (0..<5).map { value in BlockID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 760 + value))!) }
        let document = BlockDocument(blocks: [
            .init(id: ids[0], kind: .bullet, inlineContent: .plain("A"), taskState: nil, indentLevel: 0),
            .init(id: ids[1], kind: .bullet, inlineContent: .plain("A-child"), taskState: nil, indentLevel: 1),
            .init(id: ids[2], kind: .bullet, inlineContent: .plain("B"), taskState: nil, indentLevel: 0),
            .init(id: ids[3], kind: .bullet, inlineContent: .plain("B-child"), taskState: nil, indentLevel: 1),
            .init(id: ids[4], kind: .bullet, inlineContent: .plain("C"), taskState: nil, indentLevel: 0)
        ])
        let selected = BlockEditorSelection.blocks(anchor: ids[2], focus: ids[3])
        var callbacks = 0
        let session = BlockEditorSession(noteID: NoteID(), editSessionID: UUID(), initialDocument: document, initialSelection: selected, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in callbacks += 1 })
        let drag = BlockDragCoordinator(session: session)

        #expect(drag.moveUp(roots: [ids[3], ids[2], BlockID()]))
        #expect(session.document.blocks.map(\.id) == [ids[2], ids[3], ids[0], ids[1], ids[4]])
        #expect(session.selection == selected)
        #expect(callbacks == 1)
        #expect(session.undoManager.canUndo)
    }

    @Test func sessionOwnsForwardAndReverseCrossHostPointerAndShiftSelectionProjections() {
        let first = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000741")!)
        let second = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000742")!)
        let document = BlockDocument(blocks: [
            .init(id: first, kind: .paragraph, inlineContent: .plain("甲👍🏽"), taskState: nil, indentLevel: 0),
            .init(id: second, kind: .paragraph, inlineContent: .plain("乙文"), taskState: nil, indentLevel: 0)
        ])
        let caret = BlockEditorSelection.text(
            anchor: .init(blockID: first, graphemeOffset: 0),
            focus: .init(blockID: first, graphemeOffset: 0),
            preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil)
        )
        let session = BlockEditorSession(
            noteID: NoteID(), editSessionID: UUID(), initialDocument: document, initialSelection: caret,
            focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in }
        )
        let firstToken = UUID()
        let secondToken = UUID()
        let firstView = BlockEditorTextView()
        let secondView = BlockEditorTextView()
        session.attach(blockID: first, hostToken: firstToken, textView: firstView)
        session.attach(blockID: second, hostToken: secondToken, textView: secondView)
        #expect(firstView.string == "甲👍🏽")
        #expect(secondView.string == "乙文")

        #expect(firstView.beginPointerSelection(atUTF16Offset: 1))
        #expect(secondView.extendPointerSelection(toUTF16Offset: 1))
        #expect(session.selection == .text(
            anchor: .init(blockID: first, graphemeOffset: 1),
            focus: .init(blockID: second, graphemeOffset: 1),
            preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil)
        ))
        #expect(BlockSelectionController(selection: session.selection).projectedRange(for: first, document: document) == .init(location: 1, length: 4))
        #expect(BlockSelectionController(selection: session.selection).projectedRange(for: second, document: document) == .init(location: 0, length: 1))
        #expect(firstView.selectedRange == .init(location: 1, length: 4))
        #expect(secondView.selectedRange == .init(location: 0, length: 1))

        #expect(firstView.extendSelectionWithShift(toUTF16Offset: 1))
        #expect(session.selection == .text(
            anchor: .init(blockID: first, graphemeOffset: 1),
            focus: .init(blockID: first, graphemeOffset: 1),
            preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil)
        ))
        #expect(secondView.beginPointerSelection(atUTF16Offset: 1))
        #expect(firstView.extendPointerSelection(toUTF16Offset: 1))
        #expect(firstView.selectedRange == .init(location: 1, length: 4))
        #expect(secondView.selectedRange == .init(location: 0, length: 1))
    }

    @Test func crossHostSelectionRoutesCopyCutDeleteFormattingAndLinkOnceEach() throws {
        let first = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000745")!)
        let second = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000746")!)
        let document = BlockDocument(blocks: [
            .init(id: first, kind: .paragraph, inlineContent: .plain("甲"), taskState: nil, indentLevel: 0),
            .init(id: second, kind: .paragraph, inlineContent: .plain("乙"), taskState: nil, indentLevel: 0)
        ])
        let selection = BlockEditorSelection.text(
            anchor: .init(blockID: first, graphemeOffset: 0),
            focus: .init(blockID: second, graphemeOffset: 1),
            preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil)
        )

        func session(counter: CallbackCounter) -> BlockEditorSession {
            BlockEditorSession(
                noteID: NoteID(), editSessionID: UUID(), initialDocument: document,
                initialSelection: selection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in counter.value += 1 }
            )
        }

        let copyCallbacks = CallbackCounter()
        let copy = session(counter: copyCallbacks)
        #expect(try copy.dispatch(.copySelection).commandHandled)
        #expect(copyCallbacks.value == 0)
        #expect(copy.undoManager.canUndo == false)

        let cutCallbacks = CallbackCounter()
        let cut = session(counter: cutCallbacks)
        #expect(try cut.dispatch(.cutSelection).commandHandled)
        #expect(cutCallbacks.value == 1)
        #expect(cut.undoManager.canUndo)

        let deleteCallbacks = CallbackCounter()
        let delete = session(counter: deleteCallbacks)
        #expect(try delete.dispatch(.deleteSelection).commandHandled)
        #expect(deleteCallbacks.value == 1)
        #expect(delete.undoManager.canUndo)

        let formatCallbacks = CallbackCounter()
        let format = session(counter: formatCallbacks)
        #expect(try format.dispatch(.toggleInlineMark(.bold)).commandHandled)
        #expect(formatCallbacks.value == 1)
        #expect(format.undoManager.canUndo)

        let linkCallbacks = CallbackCounter()
        let link = session(counter: linkCallbacks)
        #expect(try link.dispatch(.setLink(URL(string: "https://example.com/path"))).commandHandled)
        #expect(linkCallbacks.value == 1)
        #expect(link.undoManager.canUndo)
    }

    @Test func hostedProductionDropHandlerDecodesPrivateStableIDsAndKeepsNoopAtomic() async throws {
        let ids = (0..<3).map { value in BlockID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 770 + value))!) }
        let document = BlockDocument(blocks: ids.enumerated().map { index, id in
            .init(id: id, kind: .paragraph, inlineContent: .plain("\(index)"), taskState: nil, indentLevel: 0)
        })
        let selection = BlockEditorSelection.text(anchor: .init(blockID: ids[0], graphemeOffset: 0), focus: .init(blockID: ids[0], graphemeOffset: 0), preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil))
        let harness = try HostedBlockEditorHarness(document: document, selection: selection)
        defer { harness.close() }
        let session = try #require(harness.textView(for: ids[0]).attachedSession)
        let handler = BlockDragDropHandler(session: session)
        let payload = try handler.payloadData(for: [ids[2]])
        let provider = handler.itemProvider(for: [ids[2]])

        #expect(handler.performDrop(provider: provider, before: ids[0]))
        for _ in 0..<8 { await Task.yield() }
        #expect(harness.document.blocks.map(\.id) == [ids[2], ids[0], ids[1]])
        #expect(harness.documents.count == 1)
        #expect(session.undoManager.canUndo)
        let endProvider = handler.itemProvider(for: [ids[0]])
        #expect(handler.performDrop(provider: endProvider, before: nil))
        for _ in 0..<8 { await Task.yield() }
        #expect(harness.document.blocks.map(\.id) == [ids[2], ids[1], ids[0]])
        #expect(harness.documents.count == 2)
        #expect(handler.performDrop(data: payload, before: ids[2]))
        #expect(harness.documents.count == 2)
        #expect(handler.performDrop(data: Data("corrupt".utf8), before: ids[0]) == false)
    }

    @Test func productionContinuousEditorOmitsBlockDragHandlesButKeepsStructuralCommands() throws {
        let ids = (0..<3).map { value in BlockID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 780 + value))!) }
        let document = BlockDocument(blocks: ids.enumerated().map { index, id in
            .init(id: id, kind: .paragraph, inlineContent: .plain("\(index)"), taskState: nil, indentLevel: 0)
        })
        let selection = BlockEditorSelection.text(anchor: .init(blockID: ids[0], graphemeOffset: 0), focus: .init(blockID: ids[0], graphemeOffset: 0), preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil))
        let harness = try HostedBlockEditorHarness(document: document, selection: selection)
        defer { harness.close() }
        let session = try #require(harness.textView(for: ids[0]).attachedSession)
        #expect(harness.blockHandleCount == 0)
        #expect(try session.dispatch(.enter).commandHandled)
        #expect(harness.document.blocks.count == 4)
        #expect(session.undoManager.canUndo)
    }

    @Test func hostedContinuousTextViewExposesOneStableReadableAccessibilitySurface() throws {
        let textID = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000790")!)
        let dividerID = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000791")!)
        let document = BlockDocument(blocks: [
            .init(id: textID, kind: .paragraph, inlineContent: .plain("正文"), taskState: nil, indentLevel: 0),
            .init(id: dividerID, kind: .divider, inlineContent: .plain(""), taskState: nil, indentLevel: 0)
        ])
        let selection = reviewCaret(textID, 0)
        let harness = try HostedBlockEditorHarness(document: document, selection: selection)
        defer { harness.close() }
        let textView = try harness.textView(for: textID)
        let dividerView = try harness.textView(for: dividerID)
        #expect(textView === dividerView)
        #expect(textView.accessibilityIdentifier() == "continuous-block-editor")
        #expect(textView.accessibilityRole() == .textArea)
        #expect(textView.accessibilityLabel() == "笔记正文")
        #expect(textView.accessibilityValue() == "正文\n")
    }

    @Test func crossBlockMovementTransfersFirstResponderAndNSNotFoundTargetsSessionCaret() throws {
        _ = NSApplication.shared
        let first = BlockID(), second = BlockID()
        let document = BlockDocument(blocks: [
            reviewBlock(first, "a"), reviewBlock(second, "b")
        ])
        let cases: [(Selector, BlockID, Int, BlockID, String)] = [
            (#selector(NSResponder.moveRight(_:)), first, 1, second, "Xb"),
            (#selector(NSResponder.moveLeft(_:)), second, 0, first, "aX"),
            (#selector(NSResponder.moveDown(_:)), first, 1, second, "bX"),
            (#selector(NSResponder.moveUp(_:)), second, 0, first, "Xa")
        ]

        for (selector, sourceID, offset, destinationID, expectedText) in cases {
            let selection = reviewCaret(sourceID, offset)
            let session = BlockEditorSession(
                noteID: NoteID(), editSessionID: UUID(), initialDocument: document,
                initialSelection: selection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in }
            )
            let firstView = BlockEditorTextView(frame: .init(x: 0, y: 50, width: 180, height: 40))
            let secondView = BlockEditorTextView(frame: .init(x: 0, y: 0, width: 180, height: 40))
            session.attach(blockID: first, hostToken: UUID(), textView: firstView)
            session.attach(blockID: second, hostToken: UUID(), textView: secondView)
            let container = NSView(frame: .init(x: 0, y: 0, width: 200, height: 100))
            container.addSubview(firstView)
            container.addSubview(secondView)
            let window = NSWindow(
                contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false
            )
            window.contentView = container
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            let sourceView = sourceID == first ? firstView : secondView
            let destinationView = destinationID == first ? firstView : secondView
            #expect(window.makeFirstResponder(sourceView))

            sourceView.doCommand(by: selector)

            guard case let .text(anchor, focus, _, _) = session.selection else {
                Issue.record("movement must leave a text caret")
                continue
            }
            #expect(anchor == focus)
            #expect(focus.blockID == destinationID)
            #expect(window.firstResponder === destinationView)
            destinationView.insertText("X", replacementRange: .init(location: NSNotFound, length: 0))
            #expect(reviewText(session.document, destinationID) == expectedText)
        }
    }

    @Test func crossBlockPointerAndShiftSelectionsStayAuthoritativeForTypeIMEDeleteCopyFormatAndLink() throws {
        let first = BlockID(), second = BlockID()
        let document = BlockDocument(blocks: [reviewBlock(first, "ab"), reviewBlock(second, "cd")])

        let typed = reviewCrossSession(document: document, selection: reviewCaret(first, 0))
        #expect(typed.firstView.beginPointerSelection(atUTF16Offset: 1))
        #expect(typed.secondView.extendPointerSelection(toUTF16Offset: 1))
        typed.secondView.insertText("X", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(typed.session.document.blocks.map(reviewText) == ["aXd"])
        #expect(typed.counter.value == 1)

        let ime = reviewCrossSession(document: document, selection: reviewCaret(second, 1))
        #expect(ime.secondView.beginPointerSelection(atUTF16Offset: 1))
        #expect(ime.firstView.extendPointerSelection(toUTF16Offset: 1))
        ime.firstView.setMarkedText(
            "zhong", selectedRange: .init(location: 5, length: 0),
            replacementRange: .init(location: NSNotFound, length: 0)
        )
        ime.firstView.insertText("中🙂", replacementRange: .init(location: NSNotFound, length: 0))
        ime.firstView.unmarkText()
        #expect(ime.session.document.blocks.map(reviewText) == ["a中🙂d"])
        #expect(ime.counter.value == 1)

        let deleted = reviewCrossSession(document: document, selection: reviewCaret(first, 1))
        #expect(deleted.secondView.extendSelectionWithShift(toUTF16Offset: 1))
        deleted.secondView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(deleted.session.document.blocks.map(reviewText) == ["ad"])

        let copied = reviewCrossSession(document: document, selection: reviewCaret(second, 1))
        #expect(copied.firstView.extendSelectionWithShift(toUTF16Offset: 1))
        copied.firstView.copy(nil)
        #expect(NSPasteboard.general.string(forType: .string) == "b\nc")
        #expect(copied.session.document == document)

        let formatted = reviewCrossSession(document: document, selection: reviewCaret(first, 1))
        #expect(formatted.secondView.extendSelectionWithShift(toUTF16Offset: 1))
        #expect(formatted.session.dispatchTextCommand(.toggleInlineMark(.bold)))
        let formattedSpans = formatted.session.document.blocks.flatMap(\.inlineContent.spans)
        #expect(formattedSpans.filter { $0.marks.contains(.bold) }.map(\.text).joined() == "bc")
        #expect(formattedSpans.filter { !$0.marks.contains(.bold) }.map(\.text).joined() == "ad")

        let linked = reviewCrossSession(document: document, selection: reviewCaret(second, 1))
        #expect(linked.firstView.extendSelectionWithShift(toUTF16Offset: 1))
        let url = try #require(URL(string: "https://example.com/cross"))
        #expect(linked.session.dispatchTextCommand(.setLink(url)))
        let linkedSpans = linked.session.document.blocks.flatMap(\.inlineContent.spans)
        #expect(linkedSpans.filter { $0.linkURL == url }.map(\.text).joined() == "bc")
        #expect(linkedSpans.filter { $0.linkURL == nil }.map(\.text).joined() == "ad")

        let cut = reviewCrossSession(document: document, selection: reviewCaret(first, 1))
        #expect(cut.secondView.extendSelectionWithShift(toUTF16Offset: 1))
        cut.secondView.cut(nil)
        #expect(cut.session.document.blocks.map(reviewText) == ["ad"])
        #expect(cut.counter.value == 1)
    }

    @Test func hostedPointerAndShiftTransferFocusToTheEndpointBeforeTypeAndIMECommit() throws {
        let first = BlockID(), second = BlockID()
        let document = BlockDocument(blocks: [reviewBlock(first, "ab"), reviewBlock(second, "cd")])

        let pointer = try HostedBlockEditorHarness(document: document, selection: reviewCaret(first, 1))
        defer { pointer.close() }
        let pointerFirst = try pointer.textView(for: first)
        let pointerSecond = try pointer.textView(for: second)
        #expect(pointerFirst === pointerSecond)
        #expect(pointerFirst.beginPointerSelection(atUTF16Offset: 1))
        #expect(pointerFirst.extendPointerSelection(toUTF16Offset: 4))
        #expect(pointer.window.makeFirstResponder(pointerFirst))
        pointerSecond.insertText("X", replacementRange: .init(location: NSNotFound, length: 0))
        #expect(pointer.document.blocks.map(reviewText) == ["aXd"])
        #expect(pointer.documents.count == 1)

        let shift = try HostedBlockEditorHarness(document: document, selection: reviewCaret(second, 1))
        defer { shift.close() }
        let shiftFirst = try shift.textView(for: first)
        let shiftSecond = try shift.textView(for: second)
        #expect(shiftFirst === shiftSecond)
        #expect(shiftSecond.beginPointerSelection(atUTF16Offset: 4))
        #expect(shiftSecond.extendPointerSelection(toUTF16Offset: 1))
        #expect(shift.window.makeFirstResponder(shiftSecond))
        shiftFirst.setMarkedText(
            "zhong", selectedRange: .init(location: 5, length: 0),
            replacementRange: .init(location: NSNotFound, length: 0)
        )
        shiftFirst.insertText("中🙂", replacementRange: .init(location: NSNotFound, length: 0))
        shiftFirst.unmarkText()
        #expect(shift.document.blocks.map(reviewText) == ["a中🙂d"])
        #expect(shift.documents.count == 1)
    }

    @Test func realFirstResponderTransitionsReleaseFocusAndDelayedOldResignCannotClearNewOwner() {
        _ = NSApplication.shared
        let first = BlockID(), second = BlockID()
        let registry = EditorFocusRegistry()
        let session = BlockEditorSession(
            noteID: NoteID(), editSessionID: UUID(),
            initialDocument: .init(blocks: [reviewBlock(first, "a"), reviewBlock(second, "b")]),
            initialSelection: reviewCaret(first, 0), focusRegistry: registry, onDocumentChange: { _ in }
        )
        let firstView = BlockEditorTextView(frame: .init(x: 0, y: 80, width: 160, height: 35))
        let secondView = BlockEditorTextView(frame: .init(x: 0, y: 40, width: 160, height: 35))
        let firstToken = UUID(), secondToken = UUID()
        session.attach(blockID: first, hostToken: firstToken, textView: firstView)
        session.attach(blockID: second, hostToken: secondToken, textView: secondView)
        let calendarButton = NSButton(frame: .init(x: 180, y: 80, width: 100, height: 30))
        let handle = BlockSelectionHandleView(frame: .init(x: 180, y: 40, width: 20, height: 20))
        handle.configure(
            blockID: first, index: 0, total: 2, session: session,
            dragHandler: BlockDragDropHandler(session: session)
        )
        let container = NSView(frame: .init(x: 0, y: 0, width: 300, height: 130))
        [firstView, secondView, calendarButton, handle].forEach(container.addSubview)
        let window = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        #expect(window.makeFirstResponder(firstView))
        #expect(registry.availability != .noFocusedOwner)
        #expect(window.makeFirstResponder(calendarButton))
        #expect(registry.availability == .noFocusedOwner)

        #expect(window.makeFirstResponder(firstView))
        #expect(window.makeFirstResponder(secondView))
        #expect(registry.availability != .noFocusedOwner)

        #expect(window.makeFirstResponder(handle))
        #expect(registry.availability == .noFocusedOwner)
    }

    @Test func redoThenTypingStartsFreshTypingRecordAcrossSelectionAutosaveAndAtomicBoundaries() throws {
        let fixture = undoFixture()
        var callbacks = 0
        let session = BlockEditorSession(
            noteID: NoteID(), editSessionID: UUID(), initialDocument: fixture.document,
            initialSelection: fixture.selection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in callbacks += 1 }
        )
        _ = try session.dispatch(.insertTextApplyingMarkdownShortcut("x"))
        session.undoManager.undo()
        session.undoManager.redo()
        session.autosaveDidResolve(.saving)
        session.autosaveDidResolve(.saved)
        _ = try session.dispatch(.insertTextApplyingMarkdownShortcut("y"))
        #expect(reviewText(session.document.blocks[0]) == "axy")
        let afterYSelection = session.selection
        session.undoManager.undo()
        #expect(reviewText(session.document.blocks[0]) == "ax")
        session.undoManager.redo()
        #expect(reviewText(session.document.blocks[0]) == "axy")
        #expect(session.selection == afterYSelection)

        _ = try session.dispatch(.enter)
        let afterEnter = session.document
        session.undoManager.undo()
        #expect(reviewText(session.document.blocks[0]) == "axy")
        session.undoManager.redo()
        #expect(session.document == afterEnter)
        #expect(callbacks == 9)
    }

    @Test func editorKeyKeepsEquivalentRedrawButReplacesSessionForEitherIdentityChangeOrRecovery() throws {
        _ = NSApplication.shared
        let registry = EditorFocusRegistry()
        let firstID = BlockID(), secondID = BlockID(), thirdID = BlockID()
        let noteA = NoteID(), noteB = NoteID()
        let editA = UUID(), editB = UUID(), editC = UUID()
        func root(_ note: NoteID, _ edit: UUID, _ id: BlockID, _ value: String) -> BlockEditorView {
            BlockEditorView(
                noteID: note, editSessionID: edit,
                initialDocument: .init(blocks: [reviewBlock(id, value)]),
                initialSelection: reviewCaret(id, 0), focusRegistry: registry, onDocumentChange: { _ in }
            )
        }
        let hosting = NSHostingView(rootView: root(noteA, editA, firstID, "old"))
        hosting.frame = .init(x: 0, y: 0, width: 420, height: 220)
        let window = NSWindow(contentRect: hosting.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        let oldView = try #require(reviewTextViews(in: hosting).first)
        let oldSession = try #require(oldView.attachedSession)
        #expect(window.makeFirstResponder(oldView))
        oldSession.autosaveDidResolve(.saved)

        hosting.rootView = root(noteA, editA, firstID, "ignored redraw")
        hosting.layoutSubtreeIfNeeded()
        #expect(try #require(reviewTextViews(in: hosting).first?.attachedSession) === oldSession)
        #expect(reviewTextViews(in: hosting).first?.string == "old")

        hosting.rootView = root(noteA, editB, secondID, "recovered")
        hosting.layoutSubtreeIfNeeded()
        let recovered = try #require(reviewTextViews(in: hosting).first)
        #expect(recovered.attachedSession !== oldSession)
        #expect(recovered.string == "recovered")
        #expect(registry.availability == .noFocusedOwner)

        let recoveredSession = try #require(recovered.attachedSession)
        hosting.rootView = root(noteB, editC, thirdID, "other note")
        hosting.layoutSubtreeIfNeeded()
        let other = try #require(reviewTextViews(in: hosting).first)
        #expect(other.attachedSession !== recoveredSession)
        #expect(other.string == "other note")
    }

    @Test func keyboardAccessibilityAndDragUseTheSameForwardReverseMultiRootSelection() throws {
        let ids = (0..<5).map { _ in BlockID() }
        let document = BlockDocument(blocks: [
            reviewBlock(ids[0], "A", kind: .bullet),
            reviewBlock(ids[1], "A-child", kind: .bullet, indent: 1),
            reviewBlock(ids[2], "B", kind: .bullet),
            reviewBlock(ids[3], "B-child", kind: .bullet, indent: 1),
            reviewBlock(ids[4], "C", kind: .bullet)
        ])
        for reverse in [false, true] {
            let selected: BlockEditorSelection = reverse
                ? .blocks(anchor: ids[4], focus: ids[2])
                : .blocks(anchor: ids[2], focus: ids[4])
            for keyboard in [false, true] {
                let session = BlockEditorSession(
                    noteID: NoteID(), editSessionID: UUID(), initialDocument: document,
                    initialSelection: selected, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in }
                )
                let handler = BlockDragDropHandler(session: session)
                #expect(handler.dragRoots(startingAt: ids[2]) == [ids[2], ids[3], ids[4]])
                let handle = BlockSelectionHandleView()
                handle.configure(blockID: ids[2], index: 2, total: 5, session: session, dragHandler: handler)
                if keyboard {
                    let event = try #require(NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                        isARepeat: false, keyCode: 126
                    ))
                    handle.keyDown(with: event)
                } else {
                    #expect(handle.performAccessibilityAction(named: "Move Up"))
                }
                #expect(session.document.blocks.map(\.id) == [ids[2], ids[3], ids[4], ids[0], ids[1]])
                #expect(session.selection == selected)
            }
        }
    }
}

@MainActor
private func reviewCrossSession(
    document: BlockDocument,
    selection: BlockEditorSelection
) -> (session: BlockEditorSession, firstView: BlockEditorTextView, secondView: BlockEditorTextView, counter: CallbackCounter) {
    let counter = CallbackCounter()
    let session = BlockEditorSession(
        noteID: NoteID(), editSessionID: UUID(), initialDocument: document,
        initialSelection: selection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in counter.value += 1 }
    )
    let firstView = BlockEditorTextView(), secondView = BlockEditorTextView()
    session.attach(blockID: document.blocks[0].id, hostToken: UUID(), textView: firstView)
    session.attach(blockID: document.blocks[1].id, hostToken: UUID(), textView: secondView)
    return (session, firstView, secondView, counter)
}

private func reviewBlock(
    _ id: BlockID, _ value: String, kind: BlockKind = .paragraph, indent: Int = 0
) -> DocumentBlock {
    .init(
        id: id, kind: kind, inlineContent: .plain(value),
        taskState: kind == .task ? .init(completedAt: nil) : nil,
        indentLevel: indent
    )
}

private func reviewCaret(_ id: BlockID, _ offset: Int) -> BlockEditorSelection {
    .text(
        anchor: .init(blockID: id, graphemeOffset: offset),
        focus: .init(blockID: id, graphemeOffset: offset),
        preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil)
    )
}

private func reviewText(_ block: DocumentBlock) -> String {
    block.inlineContent.spans.map(\.text).joined()
}

private func reviewText(_ document: BlockDocument, _ id: BlockID) -> String {
    document.blocks.first(where: { $0.id == id }).map(reviewText) ?? ""
}

@MainActor
private func reviewTextViews(in view: NSView) -> [ContinuousBlockEditorTextView] {
    let own = (view as? ContinuousBlockEditorTextView).map { [$0] } ?? []
    return own + view.subviews.flatMap(reviewTextViews(in:))
}

@MainActor
private func makeUndoSession(fixture: (document: BlockDocument, selection: BlockEditorSelection, blockID: BlockID)) -> BlockEditorSession {
    BlockEditorSession(
        noteID: NoteID(), editSessionID: UUID(), initialDocument: fixture.document,
        initialSelection: fixture.selection, focusRegistry: EditorFocusRegistry(), onDocumentChange: { _ in }
    )
}

private func undoFixture() -> (document: BlockDocument, selection: BlockEditorSelection, blockID: BlockID) {
    let blockID = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000700")!)
    let document = BlockDocument(blocks: [
        .init(id: blockID, kind: .paragraph, inlineContent: .plain("a"), taskState: nil, indentLevel: 0)
    ])
    return (document, .text(
        anchor: .init(blockID: blockID, graphemeOffset: 1),
        focus: .init(blockID: blockID, graphemeOffset: 1),
        preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil)
    ), blockID)
}

private func isLegalConsumptionRow(
    mutation: BlockInputMutation,
    effect: BlockInputEffect,
    undo: BlockUndoDirective
) -> Bool {
    switch (mutation, effect, undo) {
    case (.none, .handled, .none),
         (.none, .deferToTextSystem, .none),
         (.none, .writeClipboard, .none),
         (.none, .handled, .breakCoalescing),
         (.selectionOnly, .handled, .none),
         (.document, .handled, .coalesceTyping),
         (.document, .handled, .atomic),
         (.document, .writeClipboard, .atomic(.cut)):
        true
    default:
        false
    }
}

@MainActor
private final class CallbackCounter {
    var value = 0
}

@MainActor
private final class HostedBlockEditorHarness {
    private final class DocumentSink {
        var documents: [BlockDocument] = []
    }

    let registry = EditorFocusRegistry()
    let window: NSWindow
    private let hostingView: NSHostingView<HostedBlockEditorRoot>
    private let session: BlockEditorSession
    private let sink: DocumentSink
    private let initialDocument: BlockDocument
    private let initialSelection: BlockEditorSelection
    private let noteID: NoteID
    private let editSessionID: UUID
    private let requestLinkURL: () -> URL?

    var documents: [BlockDocument] { sink.documents }
    var document: BlockDocument { sink.documents.last ?? initialDocument }
    var blockHandleCount: Int { handleDescendants(of: hostingView).count }

    init(
        document: BlockDocument,
        selection: BlockEditorSelection,
        requestLinkURL: @escaping () -> URL? = { nil }
    ) throws {
        _ = NSApplication.shared
        initialDocument = document
        initialSelection = selection
        let noteID = NoteID()
        let editSessionID = UUID()
        self.noteID = noteID
        self.editSessionID = editSessionID
        self.requestLinkURL = requestLinkURL
        let sink = DocumentSink()
        self.sink = sink
        session = BlockEditorSession(
            noteID: noteID,
            editSessionID: editSessionID,
            initialDocument: document,
            initialSelection: selection,
            focusRegistry: registry,
            onDocumentChange: { [sink] in sink.documents.append($0) }
        )
        hostingView = NSHostingView(rootView: HostedBlockEditorRoot(
            session: session,
            requestLinkURL: requestLinkURL
        ))
        window = NSWindow(
            contentRect: .init(x: 80, y: 80, width: 520, height: 360),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        redraw()
        guard descendants(of: hostingView).count == 1 else {
            throw HostedHarnessError.missingTextViews
        }
    }

    func textView(for blockID: BlockID) throws -> ContinuousBlockEditorTextView {
        guard initialDocument.blocks.contains(where: { $0.id == blockID }),
              let textView = descendants(of: hostingView).first else {
            throw HostedHarnessError.missingTextViews
        }
        return textView
    }

    func handle(for blockID: BlockID) throws -> BlockSelectionHandleView {
        guard let handle = handleDescendants(of: hostingView).first(where: { $0.representedBlockID == blockID }) else {
            throw HostedHarnessError.missingTextViews
        }
        return handle
    }

    func formattingButton(identifier: String) throws -> NSButton {
        guard let button = buttonDescendants(of: hostingView).first(where: {
            $0.accessibilityIdentifier() == identifier
        }) else { throw HostedHarnessError.missingFormattingButton }
        return button
    }

    func mouseDown(_ view: ContinuousBlockEditorTextView, at point: NSPoint, modifiers: NSEvent.ModifierFlags = []) throws {
        let event = try mouseEvent(type: .leftMouseDown, location: point, modifiers: modifiers)
        view.mouseDown(with: event)
    }

    func mouseDown(_ view: NSView, at point: NSPoint, modifiers: NSEvent.ModifierFlags = []) throws {
        let event = try mouseEvent(type: .leftMouseDown, location: point, modifiers: modifiers)
        view.mouseDown(with: event)
    }

    func mouseDragged(_ view: ContinuousBlockEditorTextView, to point: NSPoint) throws {
        let event = try mouseEvent(type: .leftMouseDragged, location: point)
        view.mouseDragged(with: event)
    }

    func keyDown(_ view: NSView, keyCode: UInt16) throws {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ) else { throw HostedHarnessError.couldNotCreateEvent }
        view.keyDown(with: event)
    }

    func redraw() {
        hostingView.frame = window.contentView?.bounds ?? .zero
        hostingView.needsLayout = true
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
    }

    func redrawWithEquivalentRoot() {
        hostingView.rootView = makeRoot()
        redraw()
    }

    func close() { window.orderOut(nil) }

    func centerWindowPoint(of view: NSView) -> NSPoint {
        view.convert(.init(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    }

    private func mouseEvent(
        type: NSEvent.EventType,
        location: NSPoint,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ) else { throw HostedHarnessError.couldNotCreateEvent }
        return event
    }

    private func makeRoot() -> HostedBlockEditorRoot {
        HostedBlockEditorRoot(
            session: session,
            requestLinkURL: requestLinkURL
        )
    }

    private func descendants(of view: NSView) -> [ContinuousBlockEditorTextView] {
        let own = (view as? ContinuousBlockEditorTextView).map { [$0] } ?? []
        return own + view.subviews.flatMap(descendants(of:))
    }

    private func handleDescendants(of view: NSView) -> [BlockSelectionHandleView] {
        let own = (view as? BlockSelectionHandleView).map { [$0] } ?? []
        return own + view.subviews.flatMap(handleDescendants(of:))
    }

    private func buttonDescendants(of view: NSView) -> [NSButton] {
        let own = (view as? NSButton).map { [$0] } ?? []
        return own + view.subviews.flatMap(buttonDescendants(of:))
    }
}

@MainActor
private struct HostedBlockEditorRoot: View {
    @ObservedObject var session: BlockEditorSession
    let requestLinkURL: () -> URL?

    var body: some View {
        VStack(spacing: 0) {
            ContinuousBlockEditorRepresentable(
                session: session,
                appearance: CalendarTheme.light
            )
            BlockFormattingBar(session: session, requestLinkURL: requestLinkURL)
        }
    }
}

private enum HostedHarnessError: Error {
    case missingTextViews
    case missingFormattingButton
    case couldNotCreateEvent
}

@MainActor
private final class LinkPromptResponses {
    private var values: [URL?]

    init(_ values: [URL?]) { self.values = values }

    func next() -> URL? {
        guard values.isEmpty == false else { return nil }
        return values.removeFirst()
    }
}
