import CalendarDomain
import Foundation
import Testing
import WorkspaceDomain

@Suite("TaskBlockCalendarLinkTests")
struct TaskBlockCalendarLinkTests {
    @Test func scheduleTaskBlockCreatesItemPrimaryAndOneToOneLinkAtomically() throws {
        var workspace = try Task4Fixture.workspaceWithoutItem()
        workspace.notes[Task4Fixture.noteID] = Task4Fixture.note(
            id: Task4Fixture.noteID,
            title: "任务笔记",
            revision: 3,
            task: true
        )
        let item = try Task4Fixture.item(id: Task4Fixture.itemID, title: "安排任务")

        let result = try WorkspaceReducer.reduce(
            workspace,
            command: .scheduleTaskBlock(.init(
                noteID: Task4Fixture.noteID,
                blockID: Task4Fixture.taskBlockID,
                item: item
            )),
            now: Task4Fixture.later
        )
        let change = try #require(result.change)
        let state = change.state
        #expect(state.calendar.items[item.id] == item)
        #expect(state.calendarNoteRelations.baselines[.item(item.id)]?.primaryNoteID == Task4Fixture.noteID)
        #expect(state.taskBlockLinks == [.init(
            noteID: Task4Fixture.noteID,
            blockID: Task4Fixture.taskBlockID,
            calendarItemID: item.id
        )])
        #expect(state.revision == 6)
        #expect(change.changedNoteIDs.isEmpty)
    }

    @Test func repeatedScheduleReschedulesExistingItemAndPreservesUniqueLinkAndPrimary() throws {
        let workspace = try Task4Fixture.workspaceWithLinkedTask()
        var rescheduled = try #require(workspace.calendar.items[Task4Fixture.itemID])
        rescheduled.schedule = try CalendarSchedule(
            startDate: Task4Fixture.day.addingDays(3),
            endDate: Task4Fixture.day.addingDays(3),
            startTime: nil,
            endTime: nil
        )
        rescheduled.title = "不应覆盖现有事项标题"
        rescheduled.notes = "不应覆盖现有事项随记"

        let result = try WorkspaceReducer.reduce(
            workspace,
            command: .scheduleTaskBlock(.init(
                noteID: Task4Fixture.noteID,
                blockID: Task4Fixture.taskBlockID,
                item: rescheduled
            )),
            now: Task4Fixture.later
        )
        let change = try #require(result.change)
        #expect(change.state.calendar.items[Task4Fixture.itemID]?.schedule == rescheduled.schedule)
        #expect(change.state.calendar.items[Task4Fixture.itemID]?.title == workspace.calendar.items[Task4Fixture.itemID]?.title)
        #expect(change.state.calendar.items[Task4Fixture.itemID]?.notes == workspace.calendar.items[Task4Fixture.itemID]?.notes)
        #expect(change.state.taskBlockLinks == workspace.taskBlockLinks)
        #expect(change.state.taskBlockLinks.count == 1)
        #expect(change.state.calendarNoteRelations.baselines[.item(Task4Fixture.itemID)]?.primaryNoteID == Task4Fixture.noteID)
        #expect(change.state.notes[Task4Fixture.noteID]?.revision == workspace.notes[Task4Fixture.noteID]?.revision)
        #expect(change.state.revision == workspace.revision + 1)
        #expect(change.changedNoteIDs.isEmpty)
    }

    @Test func repeatedIdenticalScheduleIsTypedNoChange() throws {
        let workspace = try Task4Fixture.workspaceWithLinkedTask()
        let existing = try #require(workspace.calendar.items[Task4Fixture.itemID])

        let result = try WorkspaceReducer.reduce(
            workspace,
            command: .scheduleTaskBlock(.init(
                noteID: Task4Fixture.noteID,
                blockID: Task4Fixture.taskBlockID,
                item: existing
            )),
            now: Task4Fixture.later
        )

        #expect(result == .noChange(.identical))
        #expect(workspace.revision == 5)
        #expect(workspace.taskBlockLinks.count == 1)
    }

    @Test func explicitUnlinkPreservesTheBlockItemCompletionAndPrimaryNote() throws {
        let workspace = try Task4Fixture.workspaceWithLinkedTask(completedAt: Task4Fixture.completedAt)

        let result = try WorkspaceReducer.reduce(
            workspace,
            command: .unlinkTaskBlock(
                noteID: Task4Fixture.noteID,
                blockID: Task4Fixture.taskBlockID
            ),
            now: Task4Fixture.latest
        )

        let change = try #require(result.change)
        #expect(change.state.taskBlockLinks.isEmpty)
        #expect(change.state.calendar.items[Task4Fixture.itemID]?.completedAt == Task4Fixture.completedAt)
        #expect(change.state.notes[Task4Fixture.noteID]?.document.blocks.first?.taskState?.completedAt == Task4Fixture.completedAt)
        #expect(change.state.calendarNoteRelations.baselines[.item(Task4Fixture.itemID)]?.primaryNoteID == Task4Fixture.noteID)
        #expect(change.state.revision == workspace.revision + 1)
        #expect(change.changedNoteIDs.isEmpty)
    }

    @Test func repeatedScheduleRejectsBlockOrItemEndpointCollisionsAtomically() throws {
        let workspace = try Task4Fixture.workspaceWithLinkedTask()
        let differentItem = try Task4Fixture.item(id: Task4Fixture.otherItemID, title: "另一个事项")
        #expect(throws: WorkspaceReducerError.duplicateTaskBlockLink) {
            try WorkspaceReducer.reduce(
                workspace,
                command: .scheduleTaskBlock(.init(
                    noteID: Task4Fixture.noteID,
                    blockID: Task4Fixture.taskBlockID,
                    item: differentItem
                )),
                now: Task4Fixture.later
            )
        }

        var differentBlockWorkspace = workspace
        differentBlockWorkspace.notes[Task4Fixture.otherNoteID] = Task4Fixture.note(
            id: Task4Fixture.otherNoteID,
            title: "另一任务",
            revision: 2,
            task: true
        )
        let existingItem = try #require(workspace.calendar.items[Task4Fixture.itemID])
        #expect(throws: WorkspaceReducerError.duplicateTaskBlockLink) {
            try WorkspaceReducer.reduce(
                differentBlockWorkspace,
                command: .scheduleTaskBlock(.init(
                    noteID: Task4Fixture.otherNoteID,
                    blockID: Task4Fixture.otherTaskBlockID,
                    item: existingItem
                )),
                now: Task4Fixture.later
            )
        }
        #expect(workspace.calendar.items[Task4Fixture.otherItemID] == nil)
        #expect(workspace.taskBlockLinks.count == 1)
        #expect(workspace.revision == 5)
    }

    @Test func scheduleTaskBlockRejectsUnknownNonTaskDuplicateAndCompletionMismatchAtomically() throws {
        var workspace = try Task4Fixture.workspaceWithoutItem()
        let paragraphItem = try Task4Fixture.item(id: Task4Fixture.itemID, title: "错误")
        #expect(throws: WorkspaceReducerError.taskBlockMissingOrNotTask) {
            try WorkspaceReducer.reduce(
                workspace,
                command: .scheduleTaskBlock(.init(
                    noteID: Task4Fixture.noteID,
                    blockID: Task4Fixture.paragraphBlockID,
                    item: paragraphItem
                )),
                now: Task4Fixture.later
            )
        }

        workspace.notes[Task4Fixture.noteID] = Task4Fixture.note(
            id: Task4Fixture.noteID, title: "任务", revision: 3, task: true
        )
        workspace.calendar.items[Task4Fixture.itemID] = try Task4Fixture.item(id: Task4Fixture.itemID, title: "冲突")
        #expect(throws: WorkspaceReducerError.calendarFailure(.invalidState)) {
            try WorkspaceReducer.reduce(
                workspace,
                command: .scheduleTaskBlock(.init(
                    noteID: Task4Fixture.noteID,
                    blockID: Task4Fixture.taskBlockID,
                    item: try Task4Fixture.item(id: Task4Fixture.itemID, title: "重复")
                )),
                now: Task4Fixture.later
            )
        }

        var mismatched = try Task4Fixture.workspaceWithoutItem()
        mismatched.notes[Task4Fixture.noteID] = Task4Fixture.note(
            id: Task4Fixture.noteID, title: "完成任务", revision: 3,
            task: true, completedAt: Task4Fixture.completedAt
        )
        #expect(throws: WorkspaceReducerError.taskCompletionMismatch) {
            try WorkspaceReducer.reduce(
                mismatched,
                command: .scheduleTaskBlock(.init(
                    noteID: Task4Fixture.noteID,
                    blockID: Task4Fixture.taskBlockID,
                    item: try Task4Fixture.item(id: Task4Fixture.itemID, title: "未完成")
                )),
                now: Task4Fixture.later
            )
        }
        #expect(mismatched.revision == 5)
        #expect(mismatched.calendar.items.isEmpty)
    }

    @Test func completionFromEitherEndpointSynchronizesAndRepeatedCompletePreservesFirstTimestamp() throws {
        var workspace = try Task4Fixture.workspaceWithLinkedTask()
        let first = try WorkspaceReducer.reduce(
            workspace,
            command: .setTaskCompletion(
                .calendarItem(Task4Fixture.itemID),
                value: .complete(ifTransitioningAt: Task4Fixture.completedAt)
            ),
            now: Task4Fixture.later
        )
        workspace = try #require(first.change).state
        #expect(workspace.revision == 6)
        #expect(workspace.calendar.items[Task4Fixture.itemID]?.completedAt == Task4Fixture.completedAt)
        #expect(workspace.notes[Task4Fixture.noteID]?.document.blocks[0].taskState?.completedAt == Task4Fixture.completedAt)
        #expect(workspace.notes[Task4Fixture.noteID]?.revision == 4)

        let repeated = try WorkspaceReducer.reduce(
            workspace,
            command: .setTaskCompletion(
                .taskBlock(noteID: Task4Fixture.noteID, blockID: Task4Fixture.taskBlockID),
                value: .complete(ifTransitioningAt: Task4Fixture.latest)
            ),
            now: Task4Fixture.latest
        )
        #expect(repeated == .noChange(.identical))
        #expect(workspace.calendar.items[Task4Fixture.itemID]?.completedAt == Task4Fixture.completedAt)

        let incomplete = try WorkspaceReducer.reduce(
            workspace,
            command: .setTaskCompletion(
                .taskBlock(noteID: Task4Fixture.noteID, blockID: Task4Fixture.taskBlockID),
                value: .incomplete
            ),
            now: Task4Fixture.latest
        )
        let incompleteState = try #require(incomplete.change).state
        #expect(incompleteState.calendar.items[Task4Fixture.itemID]?.completedAt == nil)
        #expect(incompleteState.notes[Task4Fixture.noteID]?.document.blocks[0].taskState?.completedAt == nil)
        #expect(incompleteState.revision == 7)
    }

    @Test func genericDraftCannotChangeRetainedLinkedTaskCompletion() throws {
        let workspace = try Task4Fixture.workspaceWithLinkedTask()
        let base = try #require(workspace.notes[Task4Fixture.noteID])
        let link = try #require(workspace.taskBlockLinks.first)
        var submitted = base
        submitted.document.blocks[0].taskState?.completedAt = Task4Fixture.completedAt
        #expect(throws: WorkspaceReducerError.linkedTaskCompletionRequiresTaskCommand) {
            try WorkspaceReducer.reduce(
                workspace,
                command: .updateNote(try Task4Fixture.submission(
                    base: base, submitted: submitted, baseLinks: [link]
                )),
                now: Task4Fixture.later
            )
        }
        #expect(workspace.calendar.items[Task4Fixture.itemID]?.completedAt == nil)
    }

    @Test func removingOrChangingLinkedTaskRequiresExactDispositionKeys() throws {
        let workspace = try Task4Fixture.workspaceWithLinkedTask()
        let base = try #require(workspace.notes[Task4Fixture.noteID])
        let link = try #require(workspace.taskBlockLinks.first)
        var removed = base
        removed.document.blocks = [DocumentBlock(
            id: Task4Fixture.paragraphBlockID,
            kind: .paragraph,
            inlineContent: .plain("保留正文"),
            taskState: nil,
            indentLevel: 0
        )]
        #expect(throws: WorkspaceReducerError.invalidLinkedBlockDispositions) {
            try WorkspaceReducer.reduce(
                workspace,
                command: .updateNote(try Task4Fixture.submission(
                    base: base, submitted: removed, baseLinks: [link]
                )),
                now: Task4Fixture.later
            )
        }
        #expect(throws: WorkspaceReducerError.invalidLinkedBlockDispositions) {
            try WorkspaceReducer.reduce(
                workspace,
                command: .updateNote(try Task4Fixture.submission(
                    base: base,
                    submitted: removed,
                    baseLinks: [link],
                    dispositions: [
                        Task4Fixture.taskBlockID: .keepCalendarItem,
                        Task4Fixture.otherTaskBlockID: .keepCalendarItem
                    ]
                )),
                now: Task4Fixture.later
            )
        }

        var changedKind = base
        changedKind.document.blocks[0].kind = .paragraph
        changedKind.document.blocks[0].taskState = nil
        let changed = try WorkspaceReducer.reduce(
            workspace,
            command: .updateNote(try Task4Fixture.submission(
                base: base,
                submitted: changedKind,
                baseLinks: [link],
                dispositions: [Task4Fixture.taskBlockID: .keepCalendarItem]
            )),
            now: Task4Fixture.later
        )
        let changedState = try #require(changed.change).state
        #expect(changedState.taskBlockLinks.isEmpty)
        #expect(changedState.calendar.items[Task4Fixture.itemID] != nil)
        #expect(changedState.calendarNoteRelations.baselines[.item(Task4Fixture.itemID)]?.primaryNoteID == Task4Fixture.noteID)
    }

    @Test func deleteItemDispositionRemovesItemRelationAndLinkButPreservesNote() throws {
        let workspace = try Task4Fixture.workspaceWithLinkedTask(completedAt: Task4Fixture.completedAt)
        let base = try #require(workspace.notes[Task4Fixture.noteID])
        let link = try #require(workspace.taskBlockLinks.first)
        var submitted = base
        submitted.document.blocks = [DocumentBlock(
            id: Task4Fixture.paragraphBlockID,
            kind: .paragraph,
            inlineContent: .plain("任务完成后留正文"),
            taskState: nil,
            indentLevel: 0
        )]
        let result = try WorkspaceReducer.reduce(
            workspace,
            command: .updateNote(try Task4Fixture.submission(
                base: base,
                submitted: submitted,
                baseLinks: [link],
                dispositions: [Task4Fixture.taskBlockID: .deleteCalendarItem]
            )),
            now: Task4Fixture.later
        )
        let state = try #require(result.change).state
        #expect(state.notes[Task4Fixture.noteID] != nil)
        #expect(state.calendar.items[Task4Fixture.itemID] == nil)
        #expect(state.calendarNoteRelations.baselines[.item(Task4Fixture.itemID)] == nil)
        #expect(state.taskBlockLinks.isEmpty)
    }

    @Test func primaryChangeWithLinkedTaskRequiresExplicitUnlinkAndPreservesCompletion() throws {
        let workspace = try Task4Fixture.workspaceWithLinkedTask(completedAt: Task4Fixture.completedAt)
        #expect(throws: WorkspaceReducerError.linkedTaskDispositionRequired) {
            try WorkspaceReducer.reduce(
                workspace,
                command: .attachPrimaryNote(.init(
                    scope: .item(Task4Fixture.itemID), noteID: Task4Fixture.otherNoteID,
                    legacyResolution: nil, replacing: .detachOldPrimary,
                    linkedTaskDisposition: nil
                )),
                now: Task4Fixture.later
            )
        }

        let result = try WorkspaceReducer.reduce(
            workspace,
            command: .attachPrimaryNote(.init(
                scope: .item(Task4Fixture.itemID), noteID: Task4Fixture.otherNoteID,
                legacyResolution: nil, replacing: .detachOldPrimary,
                linkedTaskDisposition: .unlinkPreservingCompletion
            )),
            now: Task4Fixture.later
        )
        let state = try #require(result.change).state
        #expect(state.taskBlockLinks.isEmpty)
        #expect(state.calendar.items[Task4Fixture.itemID]?.completedAt == Task4Fixture.completedAt)
        #expect(state.notes[Task4Fixture.noteID]?.document.blocks[0].taskState?.completedAt == Task4Fixture.completedAt)
        #expect(state.calendarNoteRelations.baselines[.item(Task4Fixture.itemID)]?.primaryNoteID == Task4Fixture.otherNoteID)
    }

    @Test func concurrentLinkAddAtAffectedBlockConflicts() throws {
        var baseWorkspace = try Task4Fixture.workspace()
        baseWorkspace.notes[Task4Fixture.noteID] = Task4Fixture.note(
            id: Task4Fixture.noteID, title: "任务", revision: 3, task: true
        )
        let base = try #require(baseWorkspace.notes[Task4Fixture.noteID])
        var current = baseWorkspace
        current.calendarNoteRelations.baselines[.item(Task4Fixture.itemID)] = .init(
            primaryNoteID: Task4Fixture.noteID, referenceNoteIDs: []
        )
        current.taskBlockLinks = [.init(
            noteID: Task4Fixture.noteID,
            blockID: Task4Fixture.taskBlockID,
            calendarItemID: Task4Fixture.itemID
        )]
        current.revision += 1
        var submitted = base
        submitted.document.blocks[0].inlineContent = .plain("被修改")
        let result = try WorkspaceReducer.reduce(
            current,
            command: .updateNote(try Task4Fixture.submission(base: base, submitted: submitted)),
            now: Task4Fixture.later
        )
        #expect(Task4Fixture.conflictingFields(result) == [.document])
    }
}
