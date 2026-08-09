import Foundation
import Testing
import WorkspaceDomain

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

    private static func ids(count: Int, start: Int) -> [BlockID] {
        (0..<count).map { offset in
            let value = start + offset
            let string = String(format: "00000000-0000-0000-0000-%012d", value)
            return BlockID(UUID(uuidString: string)!)
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
            canonicalMarkdown: "原始 **加粗**、*斜体*、`代码` 与 [链接](https://example.com/a)\n第二行",
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
            canonicalMarkdown: "> 第一行\n> 第二行",
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
