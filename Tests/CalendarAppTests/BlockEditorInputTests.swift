import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("BlockEditorInputTests")
struct BlockEditorInputTests {
    @Test(arguments: UnicodeFixture.all)
    func insertionAndBackspaceRespectGraphemeBoundaries(_ fixture: UnicodeFixture) throws {
        let id = blockID(1)
        let document = doc([block(id, .paragraph, fixture.text)])
        let insertion = try reduce(document, caret(id, fixture.count), .insertText("好"))
        #expect(text(insertion.document.blocks[0]) == fixture.text + "好")
        #expect(insertion.selection == caret(id, fixture.count + 1))
        #expect(insertion.undo == .coalesceTyping(id))

        let deletion = try reduce(document, caret(id, fixture.count), .backspace)
        #expect(text(deletion.document.blocks[0]) == String(fixture.text.dropLast()))
        #expect(deletion.selection == caret(id, fixture.count - 1))
        #expect(deletion.undo == .atomic(.backspace))
    }

    @Test(arguments: UnicodeFixture.all)
    func splitDeleteFormatLinkAndPasteShareGraphemeOffsets(_ fixture: UnicodeFixture) throws {
        let id = blockID(240), next = blockID(241)
        let original = fixture.text + fixture.text
        let document = doc([block(id, .paragraph, original)])

        let split = try reduce(document, caret(id, 1), .enter, ids: [next])
        #expect(split.document.blocks.map(text) == [fixture.text, fixture.text])

        let selected = textSelection(id, 0, id, 1)
        let deleted = try reduce(document, selected, .deleteSelection)
        #expect(text(deleted.document.blocks[0]) == fixture.text)

        let formatted = try reduce(document, selected, .toggleInlineMark(.bold))
        #expect(formatted.document.blocks[0].inlineContent.spans.first(where: { !$0.text.isEmpty })?.marks == [.bold])

        let url = URL(string: "https://example.com/unicode")!
        let linked = try reduce(document, selected, .setLink(url))
        #expect(linked.document.blocks[0].inlineContent.spans.first(where: { !$0.text.isEmpty })?.linkURL == url)

        let pasted = try reduce(document, caret(id, 1), .replaceSelection(.plainText(fixture.text)))
        #expect(text(pasted.document.blocks[0]) == fixture.text + fixture.text + fixture.text)
        #expect(pasted.selection == caret(id, 2, attributes: attributesAt(pasted.document, id, 2)))
    }

    @Test func directionAndOriginalSpanBoundariesSurviveFormatting() throws {
        let id = blockID(2)
        let zero = InlineSpan(text: "", marks: [.italic])
        let document = doc([DocumentBlock(
            id: id,
            kind: .paragraph,
            inlineContent: .init(spans: [
                .init(text: "甲", marks: [.bold]), zero,
                .init(text: "乙", marks: [.bold]),
                .init(text: "丙")
            ]),
            taskState: nil,
            indentLevel: 0
        )])
        let reverse = BlockEditorSelection.text(
            anchor: .init(blockID: id, graphemeOffset: 3),
            focus: .init(blockID: id, graphemeOffset: 1),
            preferredColumn: 9,
            typingAttributes: .init(marks: [], linkURL: nil)
        )
        let result = try reduce(document, reverse, .toggleInlineMark(.italic))
        #expect(result.mutation == .document)
        #expect(result.selection == caret(id, 1, attributes: attributesAt(result.document, id, 1)))
        #expect(result.document.blocks[0].inlineContent.spans.contains(zero))
        #expect(result.document.blocks[0].inlineContent.spans.first?.marks == [.bold])
        #expect(result.undo == .atomic(.formatting))
    }

    @Test func invalidSelectionsAndDocumentsThrowTypedErrorsWithoutIDs() throws {
        let id = blockID(3)
        let duplicate = doc([block(id, .paragraph, "甲"), block(id, .paragraph, "乙")])
        #expect(throws: BlockInputError.invalidInputDocument) {
            try reduce(duplicate, caret(id, 0), .insertText("x"), ids: [blockID(90)])
        }
        let valid = doc([block(id, .paragraph, "甲")])
        for selection in [caret(blockID(99), 0), caret(id, -1), caret(id, 2)] {
            #expect(throws: BlockInputError.invalidSelection) {
                try reduce(valid, selection, .enter, ids: [blockID(90)])
            }
        }
        let divider = blockID(4)
        #expect(throws: BlockInputError.invalidSelection) {
            try reduce(doc([block(divider, .divider, "")]), caret(divider, 1), .enter)
        }
    }

    @Test(arguments: EnterFixture.all)
    func enterMatrix(_ fixture: EnterFixture) throws {
        let original = fixture.document
        let result = try reduce(original, fixture.selection, .enter, ids: fixture.ids)
        #expect(result.document == fixture.expected)
        #expect(result.selection == fixture.expectedSelection)
        #expect(result.undo == .atomic(.enter))
    }

    @Test func enterCoversEveryKindAtStartMiddleEndAndEmpty() throws {
        let next = blockID(250)
        for kind in allBlockKinds {
            let id = blockID(249)
            if kind == .divider {
                let result = try reduce(doc([validBlock(id, kind, "")]), caret(id, 0), .enter, ids: [next])
                #expect(result.document.blocks.map(\.kind) == [.divider, .paragraph])
                continue
            }
            for offset in 0...2 {
                let original = validBlock(id, kind, "甲乙", completed: .distantPast, codeInfo: kind == .code ? "swift" : nil)
                let result = try reduce(doc([original]), caret(id, offset), .enter, ids: [next])
                #expect(result.document.blocks.count == 2, Comment(rawValue: "kind=\(kind) offset=\(offset)"))
                #expect(result.document.blocks[0].id == id)
                #expect(result.document.blocks[1].id == next)
                #expect(text(result.document.blocks[0]).count == offset)
                #expect(text(result.document.blocks[1]).count == 2 - offset)
            }

            let empty = try reduce(
                doc([validBlock(id, kind, "", codeInfo: kind == .code ? "swift" : nil)]),
                caret(id, 0),
                .enter,
                ids: [next]
            )
            if [.heading1, .heading2, .heading3, .bullet, .ordered, .task, .quote, .link].contains(kind) {
                #expect(empty.document.blocks.map(\.kind) == [.paragraph], Comment(rawValue: "empty kind=\(kind)"))
                #expect(empty.document.blocks[0].id == id)
            } else {
                #expect(empty.document.blocks.count == 2, Comment(rawValue: "empty kind=\(kind)"))
            }
        }
    }

    @Test func enterWithNonemptySelectionUsesOneAtomicFullDeletionFallbackForEveryTextKind() throws {
        let fallback = blockID(252), next = blockID(253)
        for kind in allBlockKinds where kind != .divider {
            let id = blockID(251)
            let document = doc([validBlock(id, kind, "甲", codeInfo: kind == .code ? "swift" : nil)])
            let result = try reduce(document, textSelection(id, 0, id, 1), .enter, ids: [fallback, next])
            #expect(result.document.blocks.map(\.id) == [fallback, next], Comment(rawValue: "kind=\(kind)"))
            #expect(result.document.blocks.map(\.kind) == [.paragraph, .paragraph])
            #expect(result.undo == .atomic(.enter))
        }
    }

    @Test func softBreakAndBackspaceCoverEveryKindAndEmptyShape() throws {
        for kind in allBlockKinds {
            let id = blockID(254)
            let emptyDocument = doc([validBlock(id, kind, "", codeInfo: kind == .code ? "swift" : nil)])
            let emptyBackspace = try reduce(emptyDocument, caret(id, 0), .backspace)
            if kind == .paragraph {
                #expect(emptyBackspace.mutation == .none(.documentBoundary))
            } else {
                #expect(emptyBackspace.document.blocks[0].kind == .paragraph, Comment(rawValue: "empty kind=\(kind)"))
                #expect(emptyBackspace.document.blocks[0].id == id)
            }

            let soft = try reduce(emptyDocument, caret(id, 0), .softBreak)
            if kind == .divider {
                #expect(soft.mutation == .none(.unsupportedBlockKind))
                continue
            }
            #expect(text(soft.document.blocks[0]) == "\n", Comment(rawValue: "soft kind=\(kind)"))

            let nonempty = doc([validBlock(id, kind, "甲乙", codeInfo: kind == .code ? "swift" : nil)])
            let backspace = try reduce(nonempty, caret(id, 2), .backspace)
            #expect(text(backspace.document.blocks[0]) == "甲", Comment(rawValue: "backspace kind=\(kind)"))
        }
    }

    @Test func codeSoftBreakAndDividerNoChangeAreExplicit() throws {
        let code = blockID(20)
        let codeDoc = doc([block(code, .code, "print(1)", codeInfo: "swift")])
        let soft = try reduce(codeDoc, caret(code, 5), .softBreak)
        #expect(text(soft.document.blocks[0]) == "print\n(1)")
        #expect(soft.document.blocks[0].codeInfoString == "swift")
        #expect(soft.undo == .atomic(.softBreak))

        let divider = blockID(21)
        let dividerDoc = doc([block(divider, .divider, "")])
        let unchanged = try reduce(dividerDoc, caret(divider, 0), .softBreak)
        #expect(unchanged.mutation == .none(.unsupportedBlockKind))
        #expect(unchanged.effect == .handled)
        #expect(unchanged.undo == .none)
    }

    @Test func crossBlockForwardAndReverseDeleteAreEquivalent() throws {
        let a = blockID(30), b = blockID(31), c = blockID(32)
        let document = doc([block(a, .paragraph, "甲乙"), block(b, .quote, "中"), block(c, .paragraph, "丙丁")])
        let forward = textSelection(a, 1, c, 1)
        let reverse = textSelection(c, 1, a, 1)
        let first = try reduce(document, forward, .deleteSelection)
        let second = try reduce(document, reverse, .deleteSelection)
        #expect(first == second)
        #expect(first.document.blocks.map(text) == ["甲丁"])
        #expect(first.document.blocks[0].id == a)
        #expect(first.selection == caret(a, 1, attributes: attributesAt(first.document, a, 1)))
        #expect(first.undo == .atomic(.deletion))
    }

    @Test func fullBlockDeletionConsumesExactlyOneFallbackIDAndIncludesDescendants() throws {
        let a = blockID(40), child = blockID(41), fallback = blockID(42)
        let document = doc([
            block(a, .bullet, "root", indent: 0),
            block(child, .task, "child", indent: 1)
        ])
        let selection = BlockEditorSelection.blocks(anchor: a, focus: a)
        let result = try reduce(document, selection, .deleteSelection, ids: [fallback])
        #expect(result.document == doc([block(fallback, .paragraph, "")]))
        #expect(result.selection == caret(fallback, 0))
        #expect(result.undo == .atomic(.deletion))
    }

    @Test func fullTextDeletionAlsoConsumesExactlyOneFallbackID() throws {
        let a = blockID(43), b = blockID(44), fallback = blockID(45)
        let document = doc([block(a, .heading1, "甲"), block(b, .quote, "乙")])
        let result = try reduce(document, textSelection(a, 0, b, 1), .deleteSelection, ids: [fallback])
        #expect(result.document == doc([block(fallback, .paragraph, "")]))
        #expect(result.selection == caret(fallback, 0))
    }

    @Test func copyAndCutHaveExactClipboardAndUndoSemantics() throws {
        let a = blockID(50), b = blockID(51), fallback = blockID(52)
        let document = doc([block(a, .paragraph, "甲"), block(b, .quote, "乙")])
        let selection = BlockEditorSelection.blocks(anchor: b, focus: a)
        let copied = try reduce(document, selection, .copySelection)
        #expect(copied.document == document)
        #expect(copied.mutation == .none(.samePosition))
        #expect(copied.effect == .writeClipboard(.init(
            plainText: "甲\n乙",
            richBlocks: [.init(kind: .paragraph, inlineContent: .plain("甲"), indentLevel: 0, codeInfoString: nil),
                         .init(kind: .quote, inlineContent: .plain("乙"), indentLevel: 0, codeInfoString: nil)]
        )))
        #expect(copied.undo == .none)

        let cut = try reduce(document, selection, .cutSelection, ids: [fallback])
        #expect(cut.document.blocks == [block(fallback, .paragraph, "")])
        #expect(cut.effect == copied.effect)
        #expect(cut.undo == .atomic(.cut))
    }

    @Test func collapsedCopyAndEmptyPasteAreTypedNoChanges() throws {
        let id = blockID(60)
        let document = doc([block(id, .paragraph, "甲")])
        for command in [BlockInputCommand.copySelection, .replaceSelection(.plainText(""))] {
            let result = try reduce(document, caret(id, 0), command)
            #expect(result.document == document)
            #expect(result.mutation == .none(.emptySelection))
            #expect(result.effect == .handled)
            #expect(result.undo == .none)
        }
    }

    @Test func plainPasteNormalizesPhysicalLinesAndPreservesTrailingEmpties() throws {
        let id = blockID(70), n1 = blockID(71), n2 = blockID(72), n3 = blockID(73)
        let document = doc([block(id, .paragraph, "甲丁")])
        let result = try reduce(
            document,
            textSelection(id, 1, id, 1),
            .replaceSelection(.plainText("乙\r\n\r丙\n")),
            ids: [n1, n2, n3]
        )
        #expect(result.document.blocks.map(text) == ["甲乙", "", "丙", "丁"])
        #expect(result.document.blocks.map(\.id) == [id, n1, n2, n3])
        #expect(result.selection == caret(n3, 0, attributes: attributesAt(result.document, n3, 0)))
        #expect(result.undo == .atomic(.paste))
    }

    @Test func richPasteFallsBackAtomicallyBeforeConsumingIDs() throws {
        let id = blockID(80), next = blockID(81)
        let invalid = BlockPasteBlock(
            kind: .link,
            inlineContent: .plain("bad"),
            indentLevel: 0,
            codeInfoString: nil
        )
        let result = try reduce(
            doc([block(id, .paragraph, "甲")]),
            caret(id, 1),
            .replaceSelection(.richText(blocks: [invalid], fallbackPlainText: "\n乙")),
            ids: [next]
        )
        #expect(result.document.blocks.map(text) == ["甲", "乙"])
        #expect(result.document.blocks.map(\.id) == [id, next])
    }

    @Test func richSameBlockReplacementOwnsIDsAndTaskCompletionDeterministically() throws {
        let id = blockID(90), pasted = blockID(91), suffix = blockID(92)
        let completed = Date(timeIntervalSince1970: 10)
        let document = doc([block(id, .task, "甲乙丙", completed: completed)])
        let payload = BlockPastePayload.richText(blocks: [
            .init(kind: .task, inlineContent: .plain("中"), indentLevel: 0, codeInfoString: nil)
        ], fallbackPlainText: "中")
        let result = try reduce(document, textSelection(id, 1, id, 2), .replaceSelection(payload), ids: [pasted, suffix])
        #expect(result.document.blocks.map(\.id) == [id, pasted, suffix])
        #expect(result.document.blocks.map(text) == ["甲", "中", "丙"])
        #expect(result.document.blocks[0].taskState?.completedAt == completed)
        #expect(result.document.blocks[1].taskState?.completedAt == nil)
        #expect(result.document.blocks[2].taskState?.completedAt == nil)
        #expect(result.undo == .atomic(.paste))
    }

    @Test func richOffsetZeroReplacementLeavesOriginalCompletedTaskIDOnSoleSuffix() throws {
        let id = blockID(93), pastedID = blockID(94)
        let completed = Date(timeIntervalSince1970: 11)
        let document = doc([block(id, .task, "甲乙", completed: completed)])
        let payload = BlockPastePayload.richText(blocks: [
            .init(kind: .paragraph, inlineContent: .plain("新"), indentLevel: 0, codeInfoString: nil)
        ], fallbackPlainText: "新")
        let result = try reduce(document, textSelection(id, 0, id, 1), .replaceSelection(payload), ids: [pastedID])
        #expect(result.document.blocks.map(\.id) == [pastedID, id])
        #expect(result.document.blocks.map(text) == ["新", "乙"])
        #expect(result.document.blocks[1].kind == .task)
        #expect(result.document.blocks[1].taskState?.completedAt == completed)
    }

    @Test func richWholeBlockReplacementReusesOriginalIDForFirstPaste() throws {
        let id = blockID(95), second = blockID(96)
        let payload = BlockPastePayload.richText(blocks: [
            .init(kind: .quote, inlineContent: .plain("甲"), indentLevel: 0, codeInfoString: nil),
            .init(kind: .paragraph, inlineContent: .plain("乙"), indentLevel: 0, codeInfoString: nil)
        ], fallbackPlainText: "甲\n乙")
        let result = try reduce(doc([block(id, .paragraph, "旧")]), textSelection(id, 0, id, 1), .replaceSelection(payload), ids: [second])
        #expect(result.document.blocks.map(\.id) == [id, second])
        #expect(result.document.blocks.map(\.kind) == [.quote, .paragraph])
    }

    @Test func pasteParserValidatesRichPayloadByFirstIndexedError() throws {
        let valid = BlockPasteBlock(kind: .paragraph, inlineContent: .plain("ok"), indentLevel: 0, codeInfoString: nil)
        let invalid = BlockPasteBlock(kind: .quote, inlineContent: .plain("bad"), indentLevel: 2, codeInfoString: nil)
        #expect(throws: BlockPasteParserError.invalidIndent(index: 1)) {
            try BlockPasteParser.parse(.richText(blocks: [valid, invalid], fallbackPlainText: "fallback"))
        }
        #expect(try BlockPasteParser.parse(.plainText("a\r\nb\r")) == .plainLines(["a", "b", ""]))
    }

    @Test func markdownAndSlashConversionsAreExplicitAndPreserveID() throws {
        let id = blockID(100)
        let heading = try reduce(doc([block(id, .paragraph, "## 标题")]), caret(id, 3), .applyMarkdownShortcut)
        #expect(heading.document.blocks[0].id == id)
        #expect(heading.document.blocks[0].kind == .heading2)
        #expect(text(heading.document.blocks[0]) == "标题")

        let code = try reduce(doc([block(id, .paragraph, "```swift ")]), caret(id, 9), .applyMarkdownShortcut)
        #expect(code.document.blocks[0].kind == .code)
        #expect(code.document.blocks[0].codeInfoString == "swift")
        #expect(text(code.document.blocks[0]) == "")

        let slash = try reduce(doc([block(id, .paragraph, "/todo")]), caret(id, 5), .applySlashConversion(.task))
        #expect(slash.document.blocks[0].id == id)
        #expect(slash.document.blocks[0].kind == .task)
        #expect(text(slash.document.blocks[0]) == "")
    }

    @Test func compositionDefersEveryStructuralCommandWithoutMutation() throws {
        let id = blockID(110)
        let document = doc([block(id, .paragraph, "甲")])
        let commands: [BlockInputCommand] = [
            .insertText("乙"), .enter, .softBreak, .backspace,
            .moveHorizontal(.forward, extending: false),
            .moveVertical(.down, extending: false),
            .applyMarkdownShortcut, .applySlashConversion(.heading1)
        ]
        for command in commands {
            let result = try reduce(document, caret(id, 1), command, composing: true, ids: [blockID(111)])
            #expect(result.document == document)
            #expect(result.selection == caret(id, 1))
            #expect(result.mutation == .none(.composingText))
            #expect(result.effect == .deferToTextSystem)
            #expect(result.undo == .none)
        }
    }

    @Test func linkValidationIsAtomicAndLinkBlockDowngradesWhenLastURLIsRemoved() throws {
        let id = blockID(120)
        let url = URL(string: "https://example.com/a")!
        let document = doc([DocumentBlock(id: id, kind: .link, inlineContent: .init(spans: [
            .init(text: "链接", linkURL: url)
        ]), taskState: nil, indentLevel: 0)])
        #expect(throws: BlockInputError.invalidLink) {
            try reduce(document, textSelection(id, 0, id, 2), .setLink(URL(string: "mailto:test@example.com")!))
        }
        let removed = try reduce(document, textSelection(id, 0, id, 2), .setLink(nil))
        #expect(removed.document.blocks[0].kind == .paragraph)
        #expect(text(removed.document.blocks[0]) == "链接")
        #expect(removed.undo == .atomic(.link))
    }

    @Test func collapsedFormattingChangesOnlyTypingAttributes() throws {
        let id = blockID(130)
        let document = doc([block(id, .paragraph, "甲")])
        let result = try reduce(document, caret(id, 1), .toggleInlineMark(.bold))
        #expect(result.document == document)
        #expect(result.mutation == .selectionOnly)
        #expect(result.selection == caret(id, 1, attributes: .init(marks: [.bold], linkURL: nil)))
        #expect(result.undo == .none)
    }

    @Test func horizontalMovementCollapsesRangesAndClearsPreferredColumn() throws {
        let a = blockID(140), b = blockID(141)
        let document = doc([block(a, .paragraph, "甲"), block(b, .paragraph, "乙")])
        let reverse = BlockEditorSelection.text(
            anchor: .init(blockID: b, graphemeOffset: 1),
            focus: .init(blockID: a, graphemeOffset: 0),
            preferredColumn: 7,
            typingAttributes: .init(marks: [.bold], linkURL: nil)
        )
        let backward = try reduce(document, reverse, .moveHorizontal(.backward, extending: false))
        #expect(backward.selection == caret(a, 0, attributes: attributesAt(document, a, 0)))
        let forward = try reduce(document, reverse, .moveHorizontal(.forward, extending: false))
        #expect(forward.selection == caret(b, 1, attributes: attributesAt(document, b, 1)))
        #expect(forward.mutation == .selectionOnly)
        #expect(forward.undo == .none)
    }

    @Test func verticalMovementKeepsOriginalPreferredColumnAcrossShortLine() throws {
        let id = blockID(150)
        let document = doc([block(id, .paragraph, "1234\n甲\nabcde")])
        let down = try reduce(document, caret(id, 4), .moveVertical(.down, extending: false))
        #expect(down.selection == .text(
            anchor: .init(blockID: id, graphemeOffset: 6),
            focus: .init(blockID: id, graphemeOffset: 6),
            preferredColumn: 4,
            typingAttributes: attributesAt(document, id, 6)
        ))
        let again = try reduce(document, down.selection, .moveVertical(.down, extending: false))
        #expect(again.selection == .text(
            anchor: .init(blockID: id, graphemeOffset: 11),
            focus: .init(blockID: id, graphemeOffset: 11),
            preferredColumn: 4,
            typingAttributes: attributesAt(document, id, 11)
        ))
    }

    @Test func listIndentMovesRootAndDescendantsAndRequiresParent() throws {
        let parent = blockID(160), root = blockID(161), child = blockID(162)
        let document = doc([
            block(parent, .ordered, "p", indent: 0),
            block(root, .bullet, "r", indent: 0),
            block(child, .task, "c", indent: 1)
        ])
        let result = try reduce(document, BlockEditorSelection.blocks(anchor: root, focus: root), .indent)
        #expect(result.document.blocks.map(\.indentLevel) == [0, 1, 2])
        #expect(result.undo == .atomic(.indentation))

        let noParent = doc([block(root, .bullet, "r", indent: 0)])
        let unchanged = try reduce(noParent, caret(root, 0), .indent)
        #expect(unchanged.mutation == .none(.missingListParent))
    }

    @Test func codeIndentAndOutdentOperateOnSelectedLogicalLines() throws {
        let id = blockID(170)
        let document = doc([block(id, .code, "a\n  b\nc")])
        let indented = try reduce(document, textSelection(id, 0, id, 5), .indent)
        #expect(text(indented.document.blocks[0]) == "    a\n      b\nc")
        let outdented = try reduce(indented.document, indented.selection, .outdent)
        #expect(text(outdented.document.blocks[0]) == "a\n  b\nc")
    }

    @Test func stableIDDragMovesRootClosuresAndDeduplicatesDescendants() throws {
        let a = blockID(180), child = blockID(181), b = blockID(182), c = blockID(183)
        let document = doc([
            block(a, .bullet, "a", indent: 0),
            block(child, .task, "child", indent: 1),
            block(b, .paragraph, "b"),
            block(c, .paragraph, "c")
        ])
        let result = try reduce(document, caret(b, 0), .moveBlockRoots([child, a], before: nil))
        #expect(result.document.blocks.map(\.id) == [b, c, a, child])
        #expect(result.undo == .atomic(.drag))

        #expect(throws: BlockInputError.invalidMove) {
            try reduce(document, caret(b, 0), .moveBlockRoots([a, a], before: nil))
        }
        let same = try reduce(document, caret(b, 0), .moveBlockRoots([a], before: b))
        #expect(same.mutation == .none(.samePosition))
        #expect(same.undo == .none)
    }

    @Test func deterministicIDErrorsAreTypedAndCandidateValidationIsAtomic() throws {
        let id = blockID(190)
        let document = doc([block(id, .paragraph, "甲")])
        #expect(throws: BlockInputError.insufficientBlockIDs) {
            try reduce(document, caret(id, 1), .enter)
        }
        #expect(throws: BlockInputError.duplicateBlockID(id)) {
            try reduce(document, caret(id, 1), .enter, ids: [id])
        }
        let duplicate = blockID(191)
        #expect(throws: BlockInputError.duplicateBlockID(duplicate)) {
            try reduce(document, caret(id, 1), .replaceSelection(.plainText("a\nb\nc")), ids: [duplicate, duplicate])
        }
    }
}

struct UnicodeFixture: Sendable, CustomTestStringConvertible {
    let label: String
    let text: String
    var count: Int { text.count }
    var testDescription: String { label }

    static let all: [UnicodeFixture] = [
        .init(label: "ASCII", text: "A"),
        .init(label: "Chinese", text: "中"),
        .init(label: "combining", text: "e\u{301}"),
        .init(label: "flag", text: "🇨🇳"),
        .init(label: "skin tone", text: "👍🏽"),
        .init(label: "ZWJ family", text: "👨‍👩‍👧‍👦")
    ]
}

struct EnterFixture: Sendable, CustomTestStringConvertible {
    let label: String
    let document: BlockDocument
    let selection: BlockEditorSelection
    let ids: [BlockID]
    let expected: BlockDocument
    let expectedSelection: BlockEditorSelection
    var testDescription: String { label }

    static let all: [EnterFixture] = {
        let next = blockID(209)
        return [
            split("paragraph", .paragraph, "甲乙", 1, .paragraph, nil, next),
            split("heading", .heading2, "甲乙", 1, .paragraph, nil, next),
            split("bullet", .bullet, "甲乙", 1, .bullet, nil, next, indent: 0),
            split("ordered", .ordered, "甲乙", 1, .ordered, nil, next, indent: 0),
            split("task", .task, "甲乙", 1, .task, nil, next, indent: 0, completed: .distantPast),
            split("quote", .quote, "甲乙", 1, .quote, nil, next),
            split("code", .code, "甲乙", 1, .code, "swift", next),
            emptyExit("empty heading", .heading1),
            emptyExit("empty list", .bullet),
            emptyExit("empty task", .task),
            emptyExit("empty quote", .quote),
            dividerEnter(next)
        ]
    }()

    private static func split(
        _ label: String,
        _ leftKind: BlockKind,
        _ value: String,
        _ offset: Int,
        _ rightKind: BlockKind,
        _ info: String?,
        _ next: BlockID,
        indent: Int = 0,
        completed: Date? = nil
    ) -> EnterFixture {
        let id = blockID(200)
        let left = block(id, leftKind, "甲", indent: indent, completed: completed, codeInfo: info)
        let right = block(next, rightKind, "乙", indent: indent, codeInfo: info)
        return .init(label: label, document: doc([block(id, leftKind, value, indent: indent, completed: completed, codeInfo: info)]), selection: caret(id, offset), ids: [next], expected: doc([left, right]), expectedSelection: caret(next, 0))
    }

    private static func emptyExit(_ label: String, _ kind: BlockKind) -> EnterFixture {
        let id = blockID(220)
        return .init(label: label, document: doc([block(id, kind, "")]), selection: caret(id, 0), ids: [], expected: doc([block(id, .paragraph, "")]), expectedSelection: caret(id, 0))
    }

    private static func dividerEnter(_ next: BlockID) -> EnterFixture {
        let id = blockID(230)
        return .init(label: "divider", document: doc([block(id, .divider, "")]), selection: caret(id, 0), ids: [next], expected: doc([block(id, .divider, ""), block(next, .paragraph, "")]), expectedSelection: caret(next, 0))
    }
}

private func blockID(_ value: Int) -> BlockID {
    BlockID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!)
}

private func block(
    _ id: BlockID,
    _ kind: BlockKind,
    _ text: String,
    indent: Int = 0,
    completed: Date? = nil,
    codeInfo: String? = nil
) -> DocumentBlock {
    .init(
        id: id,
        kind: kind,
        inlineContent: .plain(text),
        taskState: kind == .task ? .init(completedAt: completed) : nil,
        indentLevel: indent,
        codeInfoString: codeInfo
    )
}

private let allBlockKinds: [BlockKind] = [
    .paragraph, .heading1, .heading2, .heading3, .bullet, .ordered,
    .task, .quote, .code, .divider, .link
]

private func validBlock(
    _ id: BlockID,
    _ kind: BlockKind,
    _ text: String,
    completed: Date? = nil,
    codeInfo: String? = nil
) -> DocumentBlock {
    if kind == .link {
        return .init(
            id: id,
            kind: .link,
            inlineContent: .init(spans: [.init(text: text, linkURL: URL(string: "https://example.com/block")!)]),
            taskState: nil,
            indentLevel: 0
        )
    }
    return block(id, kind, text, completed: completed, codeInfo: codeInfo)
}

private func doc(_ blocks: [DocumentBlock]) -> BlockDocument { .init(blocks: blocks) }
private func text(_ block: DocumentBlock) -> String { block.inlineContent.spans.map(\.text).joined() }
private func caret(
    _ id: BlockID,
    _ offset: Int,
    attributes: BlockTypingAttributes = .init(marks: [], linkURL: nil)
) -> BlockEditorSelection {
    .text(
        anchor: .init(blockID: id, graphemeOffset: offset),
        focus: .init(blockID: id, graphemeOffset: offset),
        preferredColumn: nil,
        typingAttributes: attributes
    )
}

private func textSelection(_ a: BlockID, _ ao: Int, _ f: BlockID, _ fo: Int) -> BlockEditorSelection {
    .text(
        anchor: .init(blockID: a, graphemeOffset: ao),
        focus: .init(blockID: f, graphemeOffset: fo),
        preferredColumn: nil,
        typingAttributes: .init(marks: [], linkURL: nil)
    )
}

private func reduce(
    _ document: BlockDocument,
    _ selection: BlockEditorSelection,
    _ command: BlockInputCommand,
    composing: Bool = false,
    ids: [BlockID] = []
) throws -> BlockInputResult {
    try BlockInputReducer.reduce(
        document,
        selection: selection,
        command: command,
        environment: .init(isComposingText: composing, idSource: .fixed(ids))
    )
}

private func attributesAt(_ document: BlockDocument, _ id: BlockID, _ offset: Int) -> BlockTypingAttributes {
    let block = document.blocks.first { $0.id == id }!
    let spans = block.inlineContent.spans
    var cursor = 0
    let target = offset > 0 ? offset - 1 : offset
    for span in spans where !span.text.isEmpty {
        let count = span.text.count
        if target >= cursor && target < cursor + count {
            return .init(marks: span.marks, linkURL: span.linkURL)
        }
        cursor += count
    }
    return .init(marks: [], linkURL: nil)
}
