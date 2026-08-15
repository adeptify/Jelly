import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("WorkspaceSearchIndexTests")
@MainActor
struct WorkspaceSearchIndexTests {
    @Test func noteSearchReadsChineseEnglishAndLinkFromDomainContent() throws {
        let category = makeEmptyState().uncategorizedID
        let url = try #require(URL(string: "https://example.com/jelly-editor"))
        let note = Note(
            id: NoteID(),
            title: "中文验收标题",
            document: .init(blocks: [
                .init(
                    id: BlockID(),
                    kind: .paragraph,
                    inlineContent: .init(spans: [
                        .init(text: "流畅记录 mixed language "),
                        .init(text: "官方链接", linkURL: url)
                    ]),
                    taskState: nil,
                    indentLevel: 0
                )
            ]),
            categoryID: category,
            archivedAt: nil,
            revision: 1,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        var state = WorkspaceState.empty(calendar: makeEmptyState())
        state.revision = 1
        state.notes[note.id] = note
        let index = WorkspaceSearchIndex()
        try index.rebuild(from: state)

        for query in ["中文验收", "流畅记录", "mixed language", "jelly-editor"] {
            #expect(try index.search(
                query: query,
                kind: .note,
                includeArchived: false,
                in: state
            ).map(\.objectID) == [.note(note.id)])
        }
    }

    @Test func rebuildAndSearchDropsMissingIDs() throws {
        let category = makeEmptyState().uncategorizedID
        let note = Note(
            id: NoteID(),
            title: "可搜索笔记",
            document: .init(blocks: [
                .init(id: BlockID(), kind: .paragraph, inlineContent: .plain("正文"), taskState: nil, indentLevel: 0)
            ]),
            categoryID: category,
            archivedAt: nil,
            revision: 1,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        var state = WorkspaceState.empty(calendar: makeEmptyState())
        state.revision = 2
        state.notes[note.id] = note
        let index = WorkspaceSearchIndex()
        try index.rebuild(from: state)
        let hits = try index.search(query: "可搜索", kind: .note, includeArchived: false, in: state)
        #expect(hits.count == 1)

        state.notes.removeValue(forKey: note.id)
        state.revision = 3
        let afterDelete = try index.search(query: "可搜索", kind: .note, includeArchived: false, in: state)
        #expect(afterDelete.isEmpty)
    }

    @Test func globalSearchIncludesCalendarTitlesAndNotes() throws {
        var calendar = makeEmptyState()
        var item = try makeItem(categoryID: calendar.uncategorizedID, title: "提交季度复盘")
        item.notes = "带上销售数据"
        calendar.items[item.id] = item
        var state = WorkspaceState.empty(calendar: calendar)
        state.revision = 1
        let index = WorkspaceSearchIndex()

        #expect(try index.search(
            query: "季度复盘",
            kind: nil,
            includeArchived: false,
            in: state
        ).map(\.objectID) == [.calendarItem(item.id)])
        #expect(try index.search(
            query: "销售数据",
            kind: .calendarItem,
            includeArchived: false,
            in: state
        ).map(\.objectID) == [.calendarItem(item.id)])
    }

    @Test func oneThousandRecordsProduceFirstSearchResultsWithinOneHundredMilliseconds() throws {
        let calendar = makeEmptyState()
        var state = WorkspaceState.empty(calendar: calendar)
        for index in 0..<1_000 {
            let note = Note(
                id: NoteID(),
                title: index == 999 ? "唯一命中的验收笔记" : "普通笔记 \(index)",
                document: .init(blocks: [
                    .init(
                        id: BlockID(),
                        kind: .paragraph,
                        inlineContent: .plain("用于全局搜索性能门禁的正文 \(index)"),
                        taskState: nil,
                        indentLevel: 0
                    )
                ]),
                categoryID: calendar.uncategorizedID,
                archivedAt: nil,
                revision: 1,
                createdAt: .distantPast,
                updatedAt: .distantPast
            )
            state.notes[note.id] = note
        }
        state.revision = 1
        let index = WorkspaceSearchIndex()
        let clock = ContinuousClock()
        let start = clock.now

        let results = try index.search(
            query: "唯一命中",
            kind: nil,
            includeArchived: false,
            in: state
        )
        let elapsed = start.duration(to: clock.now)

        #expect(results.count == 1)
        #expect(elapsed < .milliseconds(100))
    }
}
