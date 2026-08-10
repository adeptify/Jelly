import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("WorkspaceSearchIndexTests")
@MainActor
struct WorkspaceSearchIndexTests {
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
}
