import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("TaskBlockCompletionPresentationTests")
struct TaskBlockCompletionPresentationTests {
    @Test func removingALinkedTaskRequiresAChoiceButOrdinaryBlocksDoNot() throws {
        let noteID = NoteID()
        let linkedID = BlockID()
        let ordinaryID = BlockID()
        let before = BlockDocument(blocks: [
            try .task(id: linkedID, text: "已关联"),
            .init(
                id: ordinaryID,
                kind: .paragraph,
                inlineContent: .plain("普通正文"),
                taskState: nil,
                indentLevel: 0
            )
        ])
        let after = BlockDocument(blocks: [])
        let links: Set<TaskBlockCalendarLink> = [
            .init(noteID: noteID, blockID: linkedID, calendarItemID: UUID())
        ]

        #expect(TaskBlockDeletionConfirmation.requiredLinkedBlocks(
            noteID: noteID,
            before: before,
            after: after,
            links: links
        ) == [linkedID])
    }
}
