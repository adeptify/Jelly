import CalendarDomain
import Foundation
import Testing
import WorkspaceDomain

@Suite("WorkspaceCategoryCommandTests")
struct WorkspaceCategoryCommandTests {
    @Test func createCategoryCanonicalizesThroughCalendarAndIncrementsOnce() throws {
        let workspace = try Task4Fixture.workspace()
        let category = CalendarCategory(
            id: Task4Fixture.extraCategoryID,
            name: "  学习  ",
            colorHex: "#aabbcc",
            sortIndex: 99,
            createdAt: Task4Fixture.now,
            updatedAt: Task4Fixture.now
        )

        let result = try WorkspaceReducer.reduce(
            workspace,
            command: .createCategory(category),
            now: Task4Fixture.later
        )
        let state = try #require(result.change).state

        #expect(state.revision == workspace.revision + 1)
        #expect(state.calendar.categories[category.id]?.name == "学习")
        #expect(state.calendar.categories[category.id]?.colorHex == "#AABBCC")
        #expect(state.calendar.categories[category.id]?.sortIndex == 2)
        #expect(result.change?.changedNoteIDs.isEmpty == true)
    }

    @Test func updateAndReorderCategoryAreSingleWorkspaceTransactions() throws {
        let workspace = try Task4Fixture.workspace()
        let stored = try #require(workspace.calendar.categories[Task4Fixture.workCategoryID])
        var proposed = stored
        proposed.name = "项目"
        proposed.colorHex = "#abcdef"
        proposed.sortIndex = 99

        let updated = try WorkspaceReducer.reduce(
            workspace,
            command: .updateCategory(proposed),
            now: Task4Fixture.later
        )
        let updatedState = try #require(updated.change).state
        #expect(updatedState.revision == 6)
        #expect(updatedState.calendar.categories[stored.id]?.name == "项目")
        #expect(updatedState.calendar.categories[stored.id]?.sortIndex == stored.sortIndex)

        let reordered = try WorkspaceReducer.reduce(
            updatedState,
            command: .reorderCategories([Task4Fixture.workCategoryID, Task4Fixture.uncategorizedID]),
            now: Task4Fixture.latest
        )
        let reorderedState = try #require(reordered.change).state
        #expect(reorderedState.revision == 7)
        #expect(reorderedState.calendar.categories[Task4Fixture.workCategoryID]?.sortIndex == 0)
        #expect(reorderedState.calendar.categories[Task4Fixture.uncategorizedID]?.sortIndex == 1)
    }

    @Test func deleteCategoryMigratesEveryWorkspaceReferenceAtomically() throws {
        var workspace = try Task4Fixture.workspace()
        workspace.calendar.items[Task4Fixture.itemID]?.categoryID = Task4Fixture.workCategoryID
        workspace.calendar.recurrence.series[Task4Fixture.seriesID]?.categoryID = Task4Fixture.workCategoryID
        let key = OccurrenceKey(seriesID: Task4Fixture.seriesID, originalDate: Task4Fixture.day)
        workspace.calendar.recurrence.exceptions[key] = .modified(
            Task4Fixture.occurrenceOverride(notes: "")
        )
        if case var .modified(override) = workspace.calendar.recurrence.exceptions[key] {
            override.categoryID = Task4Fixture.workCategoryID
            workspace.calendar.recurrence.exceptions[key] = .modified(override)
        }
        workspace.notes = workspace.notes.mapValues { note in
            var note = note
            note.categoryID = Task4Fixture.workCategoryID
            return note
        }
        workspace.inspirations = workspace.inspirations.mapValues { inspiration in
            var inspiration = inspiration
            inspiration.categoryID = Task4Fixture.workCategoryID
            return inspiration
        }

        let result = try WorkspaceReducer.reduce(
            workspace,
            command: .deleteCategory(Task4Fixture.workCategoryID),
            now: Task4Fixture.later
        )
        let change = try #require(result.change)
        let state = change.state

        #expect(state.revision == 6)
        #expect(state.calendar.categories[Task4Fixture.workCategoryID] == nil)
        #expect(state.calendar.items.values.allSatisfy { $0.categoryID == Task4Fixture.uncategorizedID })
        #expect(state.calendar.recurrence.series.values.allSatisfy { $0.categoryID == Task4Fixture.uncategorizedID })
        #expect(state.notes.values.allSatisfy { $0.categoryID == Task4Fixture.uncategorizedID })
        #expect(state.inspirations.values.allSatisfy { $0.categoryID == Task4Fixture.uncategorizedID })
        #expect(change.changedNoteIDs == Set(workspace.notes.keys))
        #expect(state.notes.values.allSatisfy { output in
            output.revision == (workspace.notes[output.id]?.revision ?? -1) + 1
        })
        guard case let .modified(override) = state.calendar.recurrence.exceptions[key] else {
            Issue.record("修改例外应被保留")
            return
        }
        #expect(override.categoryID == Task4Fixture.uncategorizedID)
    }

    @Test func invalidCategoryMutationThrowsAndLeavesAllReferencesUntouched() throws {
        let workspace = try Task4Fixture.workspace()
        #expect(throws: WorkspaceReducerError.calendarFailure(.protectedCategory)) {
            try WorkspaceReducer.reduce(
                workspace,
                command: .deleteCategory(Task4Fixture.uncategorizedID),
                now: Task4Fixture.later
            )
        }
        #expect(workspace.revision == 5)
        #expect(workspace.calendar.categories.count == 2)
        #expect(workspace.notes.count == 2)
        #expect(workspace.inspirations.count == 1)
    }

    @Test func identicalCategoryUpdateAndCurrentOrderAreTypedNoChange() throws {
        let workspace = try Task4Fixture.workspace()
        let category = try #require(workspace.calendar.categories[Task4Fixture.workCategoryID])
        let update = try WorkspaceReducer.reduce(
            workspace,
            command: .updateCategory(category),
            now: Task4Fixture.later
        )
        #expect(update == .noChange(.identical))

        let reorder = try WorkspaceReducer.reduce(
            workspace,
            command: .reorderCategories([Task4Fixture.uncategorizedID, Task4Fixture.workCategoryID]),
            now: Task4Fixture.later
        )
        #expect(reorder == .noChange(.identical))
        #expect(workspace.revision == 5)
    }
}
