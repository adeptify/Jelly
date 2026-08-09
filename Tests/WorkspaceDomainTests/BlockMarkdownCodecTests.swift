import Foundation
import Testing
import WorkspaceDomain

private enum ContinuationToken {
    static let soft = "<!--jelly:continue-soft:v1-->"
    static let hard = "<!--jelly:continue-hard:v1-->"
    static let reservedPrefix = "<!--jelly:continue-"
}

@Suite("BlockMarkdownCodecTests")
struct BlockMarkdownCodecTests {
    @Test(arguments: BlockMarkdownFixture.all)
    func roundTripPreservesSupportedStructure(_ fixture: BlockMarkdownFixture) throws {
        let imported = try BlockMarkdownCodec.importMarkdown(
            fixture.markdown,
            idSource: fixture.ids,
            checkedTaskCompletedAt: fixture.checkedTaskCompletedAt
        )

        #expect(imported.diagnostics == [])
        #expect(imported.document == fixture.document)
        #expect(try BlockMarkdownCodec.exportMarkdown(imported.document) == fixture.canonicalMarkdown)
    }

    @Test func checkedTasksUseOneInjectedTimestampAndUncheckedTasksStayNil() throws {
        let completedAt = Date(timeIntervalSince1970: 1_786_320_400)
        let result = try BlockMarkdownCodec.importMarkdown(
            "- [x] 第一项\n- [ ] 第二项\n- [X] 第三项",
            idSource: .fixed(Self.ids(count: 3, start: 100)),
            checkedTaskCompletedAt: completedAt
        )

        #expect(result.document.blocks.map(\.taskState?.completedAt) == [completedAt, nil, completedAt])
        #expect(try BlockMarkdownCodec.exportMarkdown(result.document) == "- [x] 第一项\n- [ ] 第二项\n- [x] 第三项")
    }

    @Test func exportingCompletedTimestampAndReimportingUsesInjectedTimestampInstead() throws {
        let originalCompletion = Date(timeIntervalSince1970: 1_786_320_400)
        let importedCompletion = Date(timeIntervalSince1970: 1_786_420_400)
        let noteID = NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000000901")!)
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000902")!
        let original = BlockDocument(blocks: [
            .init(
                id: Self.ids(count: 1, start: 101)[0],
                kind: .task,
                inlineContent: .plain("已完成"),
                taskState: .init(completedAt: originalCompletion),
                indentLevel: 0,
                codeInfoString: nil
            )
        ])
        let markdown = try BlockMarkdownCodec.exportMarkdown(original)
        let reimported = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(Self.ids(count: 1, start: 101)),
            checkedTaskCompletedAt: importedCompletion
        ).document
        let originalNote = Note(
            id: noteID,
            title: "完成状态",
            document: original,
            categoryID: categoryID,
            archivedAt: nil,
            revision: 1,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let reimportedNote = Note(
            id: noteID,
            title: "完成状态",
            document: reimported,
            categoryID: categoryID,
            archivedAt: nil,
            revision: 1,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )

        #expect(markdown == "- [x] 已完成")
        #expect(reimported.blocks[0].taskState?.completedAt == importedCompletion)
        #expect(reimported.blocks[0].taskState?.completedAt != originalCompletion)
        #expect(try WorkspaceChecksum.noteSnapshotChecksum(originalNote) != WorkspaceChecksum.noteSnapshotChecksum(reimportedNote))
    }

    @Test func codeInfoUsesTildeFenceWhenItContainsBacktickAndExtendsDelimiterRuns() throws {
        let result = try BlockMarkdownCodec.importMarkdown(
            "~~~swift`dialect\nlet marker = ~~~\n~~~~~\n",
            idSource: .fixed(Self.ids(count: 1, start: 200)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(result.document.blocks[0].codeInfoString == "swift`dialect")
        #expect(result.document.blocks[0].inlineContent == .plain("let marker = ~~~"))
        #expect(try BlockMarkdownCodec.exportMarkdown(result.document) == "~~~~swift`dialect\nlet marker = ~~~\n~~~~")
    }

    @Test func codeInfoStringSurvivesMarkdownModelMarkdownModelRoundTrip() throws {
        let completionTime = Date(timeIntervalSince1970: 1_786_320_400)
        let first = try BlockMarkdownCodec.importMarkdown(
            "```swift linenums=1\nlet fence = ```\n```",
            idSource: .fixed(Self.ids(count: 1, start: 250)),
            checkedTaskCompletedAt: completionTime
        ).document
        let exported = try BlockMarkdownCodec.exportMarkdown(first)
        let second = try BlockMarkdownCodec.importMarkdown(
            exported,
            idSource: .fixed(Self.ids(count: 1, start: 251)),
            checkedTaskCompletedAt: completionTime
        ).document

        #expect(exported == "````swift linenums=1\nlet fence = ```\n````")
        #expect(second.blocks[0].codeInfoString == "swift linenums=1")
        #expect(second.blocks[0].inlineContent == first.blocks[0].inlineContent)
    }

    @Test func unsupportedMarkdownProducesLineDiagnosticWithoutDroppingCharacters() throws {
        let markdown = "| 标题 |\n| --- |\n| 内容 |"
        let result = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(Self.ids(count: 1, start: 300)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(result.document.blocks == [
            .init(
                id: Self.ids(count: 1, start: 300)[0],
                kind: .paragraph,
                inlineContent: .plain(markdown),
                taskState: nil,
                indentLevel: 0,
                codeInfoString: nil
            )
        ])
        #expect(result.diagnostics == [.init(lineNumber: 1, message: "不支持的 Markdown 表格已保留为正文")])
    }

    @Test func deeperListIndentClampsAtThreeAndKeepsExcessSpacesAsText() throws {
        let markdown = "- 一级\n    - 二级\n        - 三级\n            - 四级\n                - 五级"
        let result = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(Self.ids(count: 5, start: 400)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(result.document.blocks.map(\.indentLevel) == [0, 1, 2, 3, 3])
        #expect(result.document.blocks[4].inlineContent == .plain("    五级"))
        #expect(try BlockMarkdownCodec.exportMarkdown(result.document) == "- 一级\n    - 二级\n        - 三级\n            - 四级\n            -     五级")
    }

    @Test func importDegradesOrphanedListToDiagnosedValidatedParagraph() throws {
        let source = "    - orphan"
        let result = try BlockMarkdownCodec.importMarkdown(
            source,
            idSource: .fixed(Self.ids(count: 1, start: 500)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(result.document.blocks == [
            .init(
                id: Self.ids(count: 1, start: 500)[0],
                kind: .paragraph,
                inlineContent: .plain(source),
                taskState: nil,
                indentLevel: 0
            )
        ])
        #expect(result.diagnostics == [.init(lineNumber: 1, message: "孤立的列表缩进已保留为正文")])
        try BlockDocumentValidator.validate(result.document)
        #expect(try BlockMarkdownCodec.exportMarkdown(result.document) == "\\    - orphan")
    }

    @Test func paragraphExportEscapesLeadingBlockSyntaxForKindRoundTrip() throws {
        let document = BlockDocument(blocks: [
            .init(id: Self.ids(count: 1, start: 510)[0], kind: .paragraph, inlineContent: .plain("# 不是标题"), taskState: nil, indentLevel: 0),
            .init(id: Self.ids(count: 1, start: 511)[0], kind: .paragraph, inlineContent: .plain("正文\n---"), taskState: nil, indentLevel: 0)
        ])
        let markdown = try BlockMarkdownCodec.exportMarkdown(document)
        let reimported = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(Self.ids(count: 3, start: 510)),
            checkedTaskCompletedAt: .distantPast
        ).document

        #expect(markdown == "\\# 不是标题\n\n正文\(ContinuationToken.soft)\n---")
        #expect(reimported == document)
    }

    @Test func inlineLinkMarksAndParagraphKindSurviveRoundTrip() throws {
        let url = URL(string: "https://example.com/important")!
        let content = InlineContent(spans: [.init(text: "重要", marks: [.bold], linkURL: url)])
        let document = BlockDocument(blocks: [
            .init(id: Self.ids(count: 1, start: 520)[0], kind: .paragraph, inlineContent: content, taskState: nil, indentLevel: 0),
            .init(id: Self.ids(count: 1, start: 521)[0], kind: .link, inlineContent: content, taskState: nil, indentLevel: 0)
        ])
        let markdown = try BlockMarkdownCodec.exportMarkdown(document)
        let reimported = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(Self.ids(count: 2, start: 520)),
            checkedTaskCompletedAt: .distantPast
        ).document

        #expect(markdown == "\\[**重要**](https://example.com/important)\n\n[**重要**](https://example.com/important)")
        #expect(reimported == document)
    }

    @Test func exportUsesContinuationTokensAndNeverLeavesTrailingWhitespace() throws {
        let document = BlockDocument(blocks: [
            .init(
                id: Self.ids(count: 1, start: 530)[0],
                kind: .paragraph,
                inlineContent: .plain("a  \nb "),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let markdown = try BlockMarkdownCodec.exportMarkdown(document)
        let reimported = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(Self.ids(count: 1, start: 530)),
            checkedTaskCompletedAt: .distantPast
        ).document

        #expect(markdown == "a\(ContinuationToken.hard)\nb")
        #expect(!markdown.components(separatedBy: "\n").contains { line in
            line.hasSuffix(" ") || line.hasSuffix("\t")
        })
        #expect(reimported.blocks[0].inlineContent == .plain("a  \nb"))
    }

    @Test func exportRemovesTrailingWhitespaceFromEveryNonCodeBlockKind() throws {
        let document = BlockDocument(blocks: [
            .init(id: Self.ids(count: 1, start: 535)[0], kind: .heading1, inlineContent: .plain("标题 "), taskState: nil, indentLevel: 0),
            .init(id: Self.ids(count: 1, start: 536)[0], kind: .bullet, inlineContent: .plain("项目\t"), taskState: nil, indentLevel: 0),
            .init(id: Self.ids(count: 1, start: 537)[0], kind: .quote, inlineContent: .plain("引用 "), taskState: nil, indentLevel: 0)
        ])
        let markdown = try BlockMarkdownCodec.exportMarkdown(document)

        #expect(markdown == "# 标题\n\n- 项目\n\n> 引用")
        #expect(!markdown.components(separatedBy: "\n").contains { line in
            line.hasSuffix(" ") || line.hasSuffix("\t")
        })
    }

    @Test func escapedInlineLinkDelimitersKeepLinkBlockAndCombinedMarks() throws {
        let url = URL(string: "https://example.com/escapes")!
        let document = BlockDocument(blocks: [
            .init(
                id: Self.ids(count: 1, start: 560)[0],
                kind: .link,
                inlineContent: .init(spans: [.init(text: "A]B)\\C", marks: [.bold, .italic], linkURL: url)]),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let markdown = try BlockMarkdownCodec.exportMarkdown(document)
        let reimported = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(Self.ids(count: 1, start: 560)),
            checkedTaskCompletedAt: .distantPast
        ).document

        #expect(markdown == "[***A\\]B\\)\\\\C***](https://example.com/escapes)")
        #expect(reimported == document)
    }

    @Test func quoteHardBreakUsesSharedInlineNormalizationForRoundTrip() throws {
        let document = BlockDocument(blocks: [
            .init(
                id: Self.ids(count: 1, start: 570)[0],
                kind: .quote,
                inlineContent: .plain("a  \nb"),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let markdown = try BlockMarkdownCodec.exportMarkdown(document)
        let reimported = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(Self.ids(count: 1, start: 570)),
            checkedTaskCompletedAt: .distantPast
        ).document

        #expect(markdown == "> a\(ContinuationToken.hard)\n> b")
        #expect(reimported == document)
    }

    @Test(arguments: MultilineProseFixture.all)
    func everySupportedProseKindRoundTripsSoftAndHardLineBreaks(_ fixture: MultilineProseFixture) throws {
        let markdown = try BlockMarkdownCodec.exportMarkdown(fixture.document)
        let reimported = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed([fixture.document.blocks[0].id, BlockID(), BlockID()]),
            checkedTaskCompletedAt: .distantPast
        ).document

        #expect(markdown == fixture.canonicalMarkdown)
        #expect(reimported == fixture.document)
    }

    @Test func linkLabelsPreserveBoundaryWhitespaceAndMultilineCombinedMarks() throws {
        let url = URL(string: "https://example.com/labels")!
        let document = BlockDocument(blocks: [
            .init(
                id: Self.ids(count: 1, start: 620)[0],
                kind: .link,
                inlineContent: .init(spans: [.init(text: "A ", linkURL: url)]),
                taskState: nil,
                indentLevel: 0
            ),
            .init(
                id: Self.ids(count: 1, start: 621)[0],
                kind: .link,
                inlineContent: .init(spans: [.init(text: " A\nB ", marks: [.bold, .italic], linkURL: url)]),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let markdown = try BlockMarkdownCodec.exportMarkdown(document)
        let reimported = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(Self.ids(count: 2, start: 620)),
            checkedTaskCompletedAt: .distantPast
        ).document

        #expect(markdown == "[A ](https://example.com/labels)\n\n[*** A\(ContinuationToken.soft)\nB ***](https://example.com/labels)")
        #expect(reimported == document)
    }

    @Test(arguments: ContinuationParityFixture.all)
    func continuationTokenParityDistinguishesActiveAndLiteralTokens(_ fixture: ContinuationParityFixture) throws {
        let result = try BlockMarkdownCodec.importMarkdown(
            fixture.markdown,
            idSource: .fixed(Self.ids(count: 1, start: 700)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(result.diagnostics == [])
        #expect(result.document.blocks == [
            .init(
                id: Self.ids(count: 1, start: 700)[0],
                kind: .paragraph,
                inlineContent: .plain(fixture.expectedText),
                taskState: nil,
                indentLevel: 0
            )
        ])
    }

    @Test(arguments: LiteralContinuationExportFixture.all)
    func exportEscapesLiteralContinuationTokensWithoutChangingTheirModelText(_ fixture: LiteralContinuationExportFixture) throws {
        let document = BlockDocument(blocks: [
            .init(
                id: Self.ids(count: 1, start: 710)[0],
                kind: .paragraph,
                inlineContent: .plain(fixture.modelText),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let markdown = try BlockMarkdownCodec.exportMarkdown(document)
        let reimported = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(Self.ids(count: 1, start: 710)),
            checkedTaskCompletedAt: .distantPast
        ).document

        #expect(markdown == fixture.canonicalMarkdown)
        #expect(reimported == document)
    }

    @Test func malformedContinuationPrefixesRemainVerbatimAndAreDiagnosed() throws {
        let malformed = "A<!--jelly:continue-soft:v1--> \nB\nC\(ContinuationToken.reservedPrefix)x-->"
        let result = try BlockMarkdownCodec.importMarkdown(
            malformed,
            idSource: .fixed(Self.ids(count: 1, start: 720)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(result.document.blocks[0].inlineContent == .plain(malformed))
        #expect(result.diagnostics.map(\.lineNumber) == [1, 3])

        let mixed = try BlockMarkdownCodec.importMarkdown(
            "A\(ContinuationToken.reservedPrefix)x-->\(ContinuationToken.soft)",
            idSource: .fixed(Self.ids(count: 1, start: 721)),
            checkedTaskCompletedAt: .distantPast
        )
        #expect(mixed.document.blocks[0].inlineContent == .plain("A\(ContinuationToken.reservedPrefix)x-->\n"))
        #expect(mixed.diagnostics.map(\.lineNumber) == [1])
    }

    @Test(arguments: UnmarkedBoundaryFixture.all)
    func unmarkedBoundariesDoNotGuessContinuationFromTheNextLine(_ fixture: UnmarkedBoundaryFixture) throws {
        let result = try BlockMarkdownCodec.importMarkdown(
            fixture.markdown,
            checkedTaskCompletedAt: .distantPast
        )

        #expect(result.document.blocks.map(\.kind) == [fixture.leadingKind, fixture.followingKind])
    }

    @Test func noMarkerHeadingThenParagraphAndMultilineLinkRemainSeparateBlocks() throws {
        let paragraphResult = try BlockMarkdownCodec.importMarkdown(
            "# 标题\n正文",
            idSource: .fixed(Self.ids(count: 2, start: 730)),
            checkedTaskCompletedAt: .distantPast
        )
        let linkResult = try BlockMarkdownCodec.importMarkdown(
            "# 标题\n[A\nB](https://example.com/multiline)",
            idSource: .fixed(Self.ids(count: 2, start: 732)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(paragraphResult.document.blocks.map(\.kind) == [.heading1, .paragraph])
        #expect(paragraphResult.document.blocks.map(\.inlineContent) == [.plain("标题"), .plain("正文")])
        #expect(linkResult.document.blocks.map(\.kind) == [.heading1, .link])
        guard linkResult.document.blocks.count == 2 else { return }
        #expect(linkResult.document.blocks[1].inlineContent.spans == [.init(text: "A\nB", linkURL: URL(string: "https://example.com/multiline")!)])
    }

    @Test func markedContinuationConsumesBlankAndEveryBlockMarkerAsCurrentContent() throws {
        let markers = [
            "# heading", "## heading", "### heading", "- bullet", "1. ordered", "- [x] task",
            "> quote", "```swift", "---", "[link](https://example.com/link)", "| unsupported |"
        ]
        for marker in markers {
            let result = try BlockMarkdownCodec.importMarkdown(
                "# first\(ContinuationToken.soft)\n\(marker)",
                checkedTaskCompletedAt: .distantPast
            )
            #expect(result.document.blocks.count == 1)
            #expect(result.document.blocks[0].kind == .heading1)
            #expect(result.diagnostics == [])
        }

        let blankResult = try BlockMarkdownCodec.importMarkdown(
            "# first\(ContinuationToken.soft)\n\(ContinuationToken.soft)\nlast",
            idSource: .fixed(Self.ids(count: 1, start: 740)),
            checkedTaskCompletedAt: .distantPast
        )
        #expect(blankResult.document.blocks == [
            .init(
                id: Self.ids(count: 1, start: 740)[0],
                kind: .heading1,
                inlineContent: .plain("first\n\nlast"),
                taskState: nil,
                indentLevel: 0
            )
        ])
    }

    @Test(arguments: ProseContinuationWhitespaceFixture.all)
    func proseContinuationEncodingPreservesContentWhitespaceBeforeEveryBlockPrefix(
        _ fixture: ProseContinuationWhitespaceFixture
    ) throws {
        let document = fixture.document(id: Self.ids(count: 1, start: 760)[0])
        let markdown = try BlockMarkdownCodec.exportMarkdown(document)
        let reimported = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(Self.ids(count: 1, start: 760)),
            checkedTaskCompletedAt: .distantPast
        ).document

        #expect(markdown == fixture.canonicalMarkdown)
        #expect(reimported == document)
        #expect(!markdown.components(separatedBy: "\n").contains { $0.hasSuffix(" ") || $0.hasSuffix("\t") })
    }

    @Test func blankWithoutItsOwnContinuationTokenEndsParagraphQuoteAndMultilineLink() throws {
        let paragraph = try BlockMarkdownCodec.importMarkdown(
            "A\(ContinuationToken.soft)\n\n# B",
            idSource: .fixed(Self.ids(count: 2, start: 800)),
            checkedTaskCompletedAt: .distantPast
        )
        let quote = try BlockMarkdownCodec.importMarkdown(
            "> A\(ContinuationToken.soft)\n\n> B",
            idSource: .fixed(Self.ids(count: 2, start: 802)),
            checkedTaskCompletedAt: .distantPast
        )
        let malformedLink = try BlockMarkdownCodec.importMarkdown(
            "[A\n\nB](https://example.com/blank)",
            idSource: .fixed(Self.ids(count: 2, start: 804)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(paragraph.document.blocks.map(\.kind) == [.paragraph, .heading1])
        #expect(paragraph.document.blocks.map(\.inlineContent) == [.plain("A\n"), .plain("B")])
        #expect(quote.document.blocks.map(\.kind) == [.quote, .quote])
        #expect(quote.document.blocks.map(\.inlineContent) == [.plain("A\n"), .plain("B")])
        #expect(malformedLink.document.blocks.map(\.kind) == [.paragraph, .paragraph])
        #expect(malformedLink.document.blocks.map(\.inlineContent) == [.plain("[A"), .plain("B](https://example.com/blank)")])
        #expect(malformedLink.diagnostics.map(\.lineNumber) == [1])
    }

    @Test func standaloneLinkTerminalContinuationConsumesExactlyItsNextPhysicalLine() throws {
        let url = URL(string: "https://example.com/continued")!
        let continued = try BlockMarkdownCodec.importMarkdown(
            "[A](https://example.com/continued)\(ContinuationToken.soft)\n# next\n正文",
            idSource: .fixed(Self.ids(count: 3, start: 810)),
            checkedTaskCompletedAt: .distantPast
        )
        let eof = try BlockMarkdownCodec.importMarkdown(
            "[A](https://example.com/continued)\(ContinuationToken.soft)",
            idSource: .fixed(Self.ids(count: 1, start: 812)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(continued.document.blocks.map(\.kind) == [.link, .paragraph])
        #expect(continued.document.blocks[0].inlineContent.spans == [.init(text: "A\n# next", linkURL: url)])
        #expect(continued.document.blocks[1].inlineContent == .plain("正文"))
        #expect(eof.document.blocks == [
            .init(
                id: Self.ids(count: 1, start: 812)[0],
                kind: .link,
                inlineContent: .init(spans: [.init(text: "A\n", linkURL: url)]),
                taskState: nil,
                indentLevel: 0
            )
        ])
    }

    @Test func multilineInlineCodePreservesRawCodeTextWhileEncodingItsLineBreak() throws {
        let document = BlockDocument(blocks: [
            .init(
                id: Self.ids(count: 1, start: 820)[0],
                kind: .paragraph,
                inlineContent: .init(spans: [.init(text: "a*\nB", marks: [.code])]),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let markdown = try BlockMarkdownCodec.exportMarkdown(document)
        let reimported = try BlockMarkdownCodec.importMarkdown(
            markdown,
            idSource: .fixed(Self.ids(count: 1, start: 820)),
            checkedTaskCompletedAt: .distantPast
        ).document

        #expect(markdown == "`a*\(ContinuationToken.soft)\nB`")
        #expect(reimported == document)
    }

    @Test func unmarkedListAndTaskSiblingChildParentTransitionsKeepAllIndentLevels() throws {
        let result = try BlockMarkdownCodec.importMarkdown(
            "- root\n    - [ ] child task\n        1. grandchild\n            - [x] deep task\n            - deep sibling\n        1. parent sibling\n    - [ ] root child sibling\n- root sibling",
            idSource: .fixed(Self.ids(count: 8, start: 750)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(result.diagnostics == [])
        #expect(result.document.blocks.map(\.kind) == [.bullet, .task, .ordered, .task, .bullet, .ordered, .task, .bullet])
        #expect(result.document.blocks.map(\.indentLevel) == [0, 1, 2, 3, 3, 2, 1, 0])
        #expect(result.document.blocks.map(\.taskState?.completedAt) == [nil, nil, nil, .distantPast, nil, nil, nil, nil])
    }

    @Test func backtickFenceInfoIsDiagnosedAndPreservedAsParagraph() throws {
        let source = "```swift`dialect\nlet value = 1\n```"
        let result = try BlockMarkdownCodec.importMarkdown(
            source,
            idSource: .fixed(Self.ids(count: 1, start: 540)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(result.document.blocks == [
            .init(
                id: Self.ids(count: 1, start: 540)[0],
                kind: .paragraph,
                inlineContent: .plain(source),
                taskState: nil,
                indentLevel: 0
            )
        ])
        #expect(result.diagnostics == [.init(lineNumber: 1, message: "不支持的代码围栏信息已保留为正文")])
        try BlockDocumentValidator.validate(result.document)
    }

    @Test func importDegradesNULCodeInfoToDiagnosedValidatedParagraph() throws {
        let source = "```swift\u{0000}\nlet value = 1\n```"
        let result = try BlockMarkdownCodec.importMarkdown(
            source,
            idSource: .fixed(Self.ids(count: 1, start: 550)),
            checkedTaskCompletedAt: .distantPast
        )

        #expect(result.document.blocks == [
            .init(
                id: Self.ids(count: 1, start: 550)[0],
                kind: .paragraph,
                inlineContent: .plain(source),
                taskState: nil,
                indentLevel: 0
            )
        ])
        #expect(result.diagnostics == [.init(lineNumber: 1, message: "无效的代码围栏信息已保留为正文")])
        try BlockDocumentValidator.validate(result.document)
    }

    private static func ids(count: Int, start: Int) -> [BlockID] {
        (0..<count).map { offset in
            let value = start + offset
            let string = String(format: "00000000-0000-0000-0000-%012d", value)
            return BlockID(UUID(uuidString: string)!)
        }
    }
}

struct ContinuationParityFixture: Sendable {
    let name: String
    let markdown: String
    let expectedText: String

    static let all: [ContinuationParityFixture] = [
        .init(name: "zero backslashes activates token", markdown: "A\(ContinuationToken.soft)\nB", expectedText: "A\nB"),
        .init(name: "one backslash keeps token literal", markdown: "A\\\(ContinuationToken.soft)\nB", expectedText: "A\(ContinuationToken.soft)\nB"),
        .init(name: "two backslashes activates token", markdown: "A" + String(repeating: "\\", count: 2) + ContinuationToken.soft + "\nB", expectedText: "A\\\nB"),
        .init(name: "three backslashes keeps token literal", markdown: "A" + String(repeating: "\\", count: 3) + ContinuationToken.soft + "\nB", expectedText: "A\\\(ContinuationToken.soft)\nB")
    ]
}

struct LiteralContinuationExportFixture: Sendable {
    let name: String
    let modelText: String
    let canonicalMarkdown: String

    static let all: [LiteralContinuationExportFixture] = [
        .init(name: "literal token", modelText: "A\(ContinuationToken.soft)", canonicalMarkdown: "A\\\(ContinuationToken.soft)"),
        .init(name: "literal token after one backslash", modelText: "A\\\(ContinuationToken.soft)", canonicalMarkdown: "A" + String(repeating: "\\", count: 3) + ContinuationToken.soft),
        .init(name: "hard break after literal backslash", modelText: "A\\\nB", canonicalMarkdown: "A" + String(repeating: "\\", count: 2) + ContinuationToken.soft + "\nB")
    ]
}

struct UnmarkedBoundaryFixture: Sendable {
    let name: String
    let markdown: String
    let leadingKind: BlockKind
    let followingKind: BlockKind

    private struct Leading {
        let name: String
        let markdown: String
        let kind: BlockKind
    }

    private struct Following {
        let name: String
        let markdown: String
        let kind: BlockKind
    }

    static let all: [UnmarkedBoundaryFixture] = {
        let leading = [
            Leading(name: "heading 1", markdown: "# first", kind: .heading1),
            Leading(name: "heading 2", markdown: "## first", kind: .heading2),
            Leading(name: "heading 3", markdown: "### first", kind: .heading3),
            Leading(name: "bullet", markdown: "- first", kind: .bullet),
            Leading(name: "ordered", markdown: "1. first", kind: .ordered),
            Leading(name: "task", markdown: "- [ ] first", kind: .task),
            Leading(name: "link", markdown: "[first](https://example.com/first)", kind: .link)
        ]
        let following = [
            Following(name: "bare paragraph", markdown: "正文", kind: .paragraph),
            Following(name: "heading 1", markdown: "# next", kind: .heading1),
            Following(name: "heading 2", markdown: "## next", kind: .heading2),
            Following(name: "heading 3", markdown: "### next", kind: .heading3),
            Following(name: "bullet", markdown: "- next", kind: .bullet),
            Following(name: "ordered", markdown: "1. next", kind: .ordered),
            Following(name: "task", markdown: "- [ ] next", kind: .task),
            Following(name: "quote", markdown: "> next", kind: .quote),
            Following(name: "code", markdown: "```swift\nlet value = 1\n```", kind: .code),
            Following(name: "divider", markdown: "---", kind: .divider),
            Following(name: "single line link", markdown: "[next](https://example.com/next)", kind: .link),
            Following(name: "multiline link", markdown: "[next\nlabel](https://example.com/next)", kind: .link),
            Following(name: "unsupported raw text", markdown: "| raw |", kind: .paragraph),
            Following(name: "blank then paragraph", markdown: "\n正文", kind: .paragraph)
        ]
        return leading.flatMap { leading in
            following.map { following in
                .init(
                    name: "\(leading.name) then \(following.name)",
                    markdown: "\(leading.markdown)\n\(following.markdown)",
                    leadingKind: leading.kind,
                    followingKind: following.kind
                )
            }
        }
    }()
}

struct MultilineProseFixture: Sendable {
    let name: String
    let document: BlockDocument
    let canonicalMarkdown: String

    private static let content = InlineContent.plain("a\nb  \nc\n")
    private static let linkURL = URL(string: "https://example.com/multiline")!

    private static func id(_ value: Int) -> BlockID {
        let string = String(format: "00000000-0000-0000-0000-%012d", value)
        return BlockID(UUID(uuidString: string)!)
    }

    static let all: [MultilineProseFixture] = [
        .init(
            name: "paragraph",
            document: .init(blocks: [.init(id: id(600), kind: .paragraph, inlineContent: content, taskState: nil, indentLevel: 0)]),
            canonicalMarkdown: "a\(ContinuationToken.soft)\nb\(ContinuationToken.hard)\nc\(ContinuationToken.soft)"
        ),
        .init(
            name: "heading 1",
            document: .init(blocks: [.init(id: id(601), kind: .heading1, inlineContent: content, taskState: nil, indentLevel: 0)]),
            canonicalMarkdown: "# a\(ContinuationToken.soft)\nb\(ContinuationToken.hard)\nc\(ContinuationToken.soft)"
        ),
        .init(
            name: "heading 2",
            document: .init(blocks: [.init(id: id(602), kind: .heading2, inlineContent: content, taskState: nil, indentLevel: 0)]),
            canonicalMarkdown: "## a\(ContinuationToken.soft)\nb\(ContinuationToken.hard)\nc\(ContinuationToken.soft)"
        ),
        .init(
            name: "heading 3",
            document: .init(blocks: [.init(id: id(603), kind: .heading3, inlineContent: content, taskState: nil, indentLevel: 0)]),
            canonicalMarkdown: "### a\(ContinuationToken.soft)\nb\(ContinuationToken.hard)\nc\(ContinuationToken.soft)"
        ),
        .init(
            name: "bullet",
            document: .init(blocks: [.init(id: id(604), kind: .bullet, inlineContent: content, taskState: nil, indentLevel: 0)]),
            canonicalMarkdown: "- a\(ContinuationToken.soft)\nb\(ContinuationToken.hard)\nc\(ContinuationToken.soft)"
        ),
        .init(
            name: "ordered",
            document: .init(blocks: [.init(id: id(605), kind: .ordered, inlineContent: content, taskState: nil, indentLevel: 0)]),
            canonicalMarkdown: "1. a\(ContinuationToken.soft)\nb\(ContinuationToken.hard)\nc\(ContinuationToken.soft)"
        ),
        .init(
            name: "task",
            document: .init(blocks: [.init(id: id(606), kind: .task, inlineContent: content, taskState: .init(completedAt: .distantPast), indentLevel: 0)]),
            canonicalMarkdown: "- [x] a\(ContinuationToken.soft)\nb\(ContinuationToken.hard)\nc\(ContinuationToken.soft)"
        ),
        .init(
            name: "quote",
            document: .init(blocks: [.init(id: id(607), kind: .quote, inlineContent: content, taskState: nil, indentLevel: 0)]),
            canonicalMarkdown: "> a\(ContinuationToken.soft)\n> b\(ContinuationToken.hard)\n> c\(ContinuationToken.soft)"
        ),
        .init(
            name: "link",
            document: .init(blocks: [.init(id: id(608), kind: .link, inlineContent: .init(spans: [.init(text: "a\nb  \nc\n", linkURL: linkURL)]), taskState: nil, indentLevel: 0)]),
            canonicalMarkdown: "[a\(ContinuationToken.soft)\nb\(ContinuationToken.hard)\nc](https://example.com/multiline)\(ContinuationToken.soft)"
        )
    ]
}

struct ProseContinuationWhitespaceFixture: Sendable {
    let name: String
    let kind: BlockKind
    let modelText: String
    let encodedContent: String

    private static let linkURL = URL(string: "https://example.com/whitespace")!

    static let all: [ProseContinuationWhitespaceFixture] = {
        let kinds: [(String, BlockKind)] = [
            ("paragraph", .paragraph),
            ("heading 1", .heading1),
            ("heading 2", .heading2),
            ("heading 3", .heading3),
            ("bullet", .bullet),
            ("ordered", .ordered),
            ("task", .task),
            ("quote", .quote),
            ("link", .link)
        ]
        let whitespaceCases: [(String, String, String)] = [
            ("empty first line", "\na", "\(ContinuationToken.soft)\na"),
            ("one ASCII space", "a \nb", "a \(ContinuationToken.soft)\nb"),
            ("two ASCII spaces hard break", "a  \nb", "a\(ContinuationToken.hard)\nb"),
            ("three ASCII spaces", "a   \nb", "a \(ContinuationToken.hard)\nb"),
            ("one tab", "a\t\nb", "a\t\(ContinuationToken.soft)\nb"),
            ("two tabs", "a\t\t\nb", "a\t\t\(ContinuationToken.soft)\nb"),
            ("mixed tab then hard break", "a \t  \nb", "a \t\(ContinuationToken.hard)\nb")
        ]
        return kinds.flatMap { kind in
            whitespaceCases.map { whitespace in
                .init(
                    name: "\(kind.0) \(whitespace.0)",
                    kind: kind.1,
                    modelText: whitespace.1,
                    encodedContent: whitespace.2
                )
            }
        }
    }()

    func document(id: BlockID) -> BlockDocument {
        let inlineContent: InlineContent
        if kind == .link {
            inlineContent = .init(spans: [.init(text: modelText, linkURL: Self.linkURL)])
        } else {
            inlineContent = .plain(modelText)
        }
        return .init(blocks: [
            .init(
                id: id,
                kind: kind,
                inlineContent: inlineContent,
                taskState: kind == .task ? .init(completedAt: nil) : nil,
                indentLevel: 0
            )
        ])
    }

    var canonicalMarkdown: String {
        switch kind {
        case .paragraph:
            encodedContent
        case .heading1:
            "# \(encodedContent)"
        case .heading2:
            "## \(encodedContent)"
        case .heading3:
            "### \(encodedContent)"
        case .bullet:
            "- \(encodedContent)"
        case .ordered:
            "1. \(encodedContent)"
        case .task:
            "- [ ] \(encodedContent)"
        case .quote:
            encodedContent
                .components(separatedBy: "\n")
                .map { "> \($0)" }
                .joined(separator: "\n")
        case .link:
            "[\(encodedContent)](\(Self.linkURL.absoluteString))"
        case .code, .divider:
            fatalError("Fixture only supports prose block kinds")
        }
    }
}

struct BlockMarkdownFixture: Sendable {
    let name: String
    let markdown: String
    let canonicalMarkdown: String
    let document: BlockDocument
    let blockIDs: [BlockID]
    let checkedTaskCompletedAt: Date

    var ids: BlockIDSource { .fixed(blockIDs) }

    static let all: [BlockMarkdownFixture] = [
        fixture(
            name: "inline prose with Chinese soft break and inline link",
            markdown: "原始 **加粗**、*斜体*、`代码` 与 [链接](https://example.com/a)\n第二行",
            canonicalMarkdown: "原始 **加粗**、*斜体*、`代码` 与 [链接](https://example.com/a)\(ContinuationToken.soft)\n第二行",
            blocks: [
                .init(
                    kind: .paragraph,
                    content: .init(spans: [
                        .init(text: "原始 "),
                        .init(text: "加粗", marks: [.bold]),
                        .init(text: "、"),
                        .init(text: "斜体", marks: [.italic]),
                        .init(text: "、"),
                        .init(text: "代码", marks: [.code]),
                        .init(text: " 与 "),
                        .init(text: "链接", linkURL: URL(string: "https://example.com/a")!),
                        .init(text: "\n第二行")
                    ]),
                    taskState: nil,
                    indent: 0,
                    codeInfoString: nil
                )
            ]
        ),
        fixture(
            name: "three heading levels",
            markdown: "# 一级\n\n## 二级\n\n### 三级",
            canonicalMarkdown: "# 一级\n\n## 二级\n\n### 三级",
            blocks: [
                .init(kind: .heading1, content: .plain("一级"), taskState: nil, indent: 0, codeInfoString: nil),
                .init(kind: .heading2, content: .plain("二级"), taskState: nil, indent: 0, codeInfoString: nil),
                .init(kind: .heading3, content: .plain("三级"), taskState: nil, indent: 0, codeInfoString: nil)
            ]
        ),
        fixture(
            name: "nested bullet ordered and task blocks",
            markdown: "- 一级\n    1. 二级\n        - [ ] 未完成\n            - [x] 已完成",
            canonicalMarkdown: "- 一级\n    1. 二级\n        - [ ] 未完成\n            - [x] 已完成",
            blocks: [
                .init(kind: .bullet, content: .plain("一级"), taskState: nil, indent: 0, codeInfoString: nil),
                .init(kind: .ordered, content: .plain("二级"), taskState: nil, indent: 1, codeInfoString: nil),
                .init(kind: .task, content: .plain("未完成"), taskState: .init(completedAt: nil), indent: 2, codeInfoString: nil),
                .init(kind: .task, content: .plain("已完成"), taskState: .init(completedAt: completionTime), indent: 3, codeInfoString: nil)
            ]
        ),
        fixture(
            name: "quote with soft break",
            markdown: "> 第一行\n> 第二行",
            canonicalMarkdown: "> 第一行\(ContinuationToken.soft)\n> 第二行",
            blocks: [
                .init(kind: .quote, content: .plain("第一行\n第二行"), taskState: nil, indent: 0, codeInfoString: nil)
            ]
        ),
        fixture(
            name: "code fence with complete info string",
            markdown: "```swift linenums=1\nlet value = 1\nprint(value)\n```",
            canonicalMarkdown: "```swift linenums=1\nlet value = 1\nprint(value)\n```",
            blocks: [
                .init(kind: .code, content: .plain("let value = 1\nprint(value)"), taskState: nil, indent: 0, codeInfoString: "swift linenums=1")
            ]
        ),
        fixture(
            name: "divider",
            markdown: "---",
            canonicalMarkdown: "---",
            blocks: [
                .init(kind: .divider, content: .plain(""), taskState: nil, indent: 0, codeInfoString: nil)
            ]
        ),
        fixture(
            name: "link block",
            markdown: "[规范](https://example.com/spec)",
            canonicalMarkdown: "[规范](https://example.com/spec)",
            blocks: [
                .init(kind: .link, content: .init(spans: [.init(text: "规范", linkURL: URL(string: "https://example.com/spec")!)]), taskState: nil, indent: 0, codeInfoString: nil)
            ]
        ),
        fixture(
            name: "escaped markers remain literal",
            markdown: "\\*不是斜体\\* 与 \\[方括号\\] 和 \\`反引号\\`",
            canonicalMarkdown: "\\*不是斜体\\* 与 \\[方括号\\] 和 \\`反引号\\`",
            blocks: [
                .init(kind: .paragraph, content: .plain("*不是斜体* 与 [方括号] 和 `反引号`"), taskState: nil, indent: 0, codeInfoString: nil)
            ]
        ),
        fixture(
            name: "long code delimiter run",
            markdown: "````swift\nlet fence = ```\n````",
            canonicalMarkdown: "````swift\nlet fence = ```\n````",
            blocks: [
                .init(kind: .code, content: .plain("let fence = ```"), taskState: nil, indent: 0, codeInfoString: "swift")
            ]
        )
    ]

    private static let completionTime = Date(timeIntervalSince1970: 1_786_320_400)

    private struct ExpectedBlock: Sendable {
        let kind: BlockKind
        let content: InlineContent
        let taskState: TaskBlockState?
        let indent: Int
        let codeInfoString: String?
    }

    private static func fixture(
        name: String,
        markdown: String,
        canonicalMarkdown: String,
        blocks: [ExpectedBlock]
    ) -> BlockMarkdownFixture {
        let blockIDs = (0..<blocks.count).map { offset in
            BlockID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 10 + offset))!)
        }
        return BlockMarkdownFixture(
            name: name,
            markdown: markdown,
            canonicalMarkdown: canonicalMarkdown,
            document: .init(blocks: zip(blockIDs, blocks).map { id, block in
                .init(
                    id: id,
                    kind: block.kind,
                    inlineContent: block.content,
                    taskState: block.taskState,
                    indentLevel: block.indent,
                    codeInfoString: block.codeInfoString
                )
            }),
            blockIDs: blockIDs,
            checkedTaskCompletedAt: completionTime
        )
    }
}
