import CalendarDomain
import Foundation
import Testing
import WorkspaceDomain

@Suite("WorkspaceUndoReducerTests")
struct WorkspaceUndoReducerTests {
    @Test func reverseConflictsWhenATouchedFieldChangedLater() throws {
        let initial = WorkspaceState.empty(calendar: .empty(
            uncategorizedID: UUID(uuidString: "00000000-0000-0000-0000-000000006011")!,
            now: .distantPast
        ))
        var changed = initial
        let item = try CalendarItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000006012")!, kind: .task,
            title: "original", categoryID: initial.calendar.uncategorizedID,
            schedule: .init(startDate: .init(year: 2026, month: 8, day: 10)!, endDate: .init(year: 2026, month: 8, day: 10)!, startTime: nil, endTime: nil),
            completedAt: nil, createdAt: .distantPast, updatedAt: .distantPast
        )
        changed.calendar.items[item.id] = item
        changed.revision = 1
        let record = try #require(WorkspaceUndoReducer.record(before: initial, after: changed, label: "创建"))
        var late = changed
        late.calendar.items[item.id]?.title = "later"

        #expect(throws: WorkspaceUndoReducerError.conflict) {
            _ = try WorkspaceUndoReducer.apply(record, direction: .undo, to: late, noteRevisionHighWatermarks: [:])
        }
    }

    @Test func calendarUndoPreservesAnUnrelatedLaterNoteEdit() throws {
        let category = UUID(uuidString: "00000000-0000-0000-0000-000000006013")!
        let noteID = NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000006014")!)
        var initial = WorkspaceState.empty(calendar: .empty(uncategorizedID: category, now: .distantPast))
        initial.notes[noteID] = .empty(id: noteID, categoryID: category, now: .distantPast)
        var changed = initial
        let item = try CalendarItem(
            id: UUID(), kind: .task, title: "calendar", categoryID: category,
            schedule: .init(startDate: .init(year: 2026, month: 8, day: 10)!, endDate: .init(year: 2026, month: 8, day: 10)!, startTime: nil, endTime: nil),
            completedAt: nil, createdAt: .distantPast, updatedAt: .distantPast
        )
        changed.calendar.items[item.id] = item
        changed.revision = 1
        let record = try #require(WorkspaceUndoReducer.record(before: initial, after: changed, label: "calendar"))
        var later = changed
        later.notes[noteID]?.title = "later draft"
        later.notes[noteID]?.revision = 2
        later.revision = 2

        let result = try WorkspaceUndoReducer.apply(record, direction: .undo, to: later, noteRevisionHighWatermarks: [noteID: 2])

        #expect(result.candidate.calendar.items[item.id] == nil)
        #expect(result.candidate.notes[noteID]?.title == "later draft")
        #expect(result.candidate.notes[noteID]?.revision == 2)
    }

    @Test func deleteUndoRejectsSameIDRecreationWithDifferentIncarnation() throws {
        let category = UUID()
        let id = NoteID(UUID())
        var before = WorkspaceState.empty(calendar: .empty(uncategorizedID: category, now: .distantPast))
        var original = Note.empty(id: id, categoryID: category, now: .distantPast)
        original.revision = 1
        before.notes[id] = original
        var after = before
        after.notes.removeValue(forKey: id)
        after.revision = 2
        let record = try #require(WorkspaceUndoReducer.record(before: before, after: after, label: "delete"))
        var recreated = after
        var replacement = original
        replacement.revision = 9
        recreated.notes[id] = replacement
        recreated.revision = 9

        #expect(throws: WorkspaceUndoReducerError.conflict) {
            _ = try WorkspaceUndoReducer.apply(record, direction: .undo, to: recreated, noteRevisionHighWatermarks: [id: 9])
        }
    }

    @Test func titleUndoPreservesALaterEditToAnUntouchedNoteField() throws {
        let firstCategory = UUID()
        let secondCategory = UUID()
        let id = NoteID(UUID())
        var before = WorkspaceState.empty(calendar: .empty(uncategorizedID: firstCategory, now: .distantPast))
        before.calendar.categories[secondCategory] = CalendarCategory(
            id: secondCategory, name: "second", colorHex: "#007AFF", sortIndex: 1,
            createdAt: .distantPast, updatedAt: .distantPast
        )
        let original = Note.empty(id: id, categoryID: firstCategory, now: .distantPast)
        before.notes[id] = original
        var afterTitle = before
        afterTitle.revision = 1
        afterTitle.notes[id]?.title = "changed title"
        afterTitle.notes[id]?.revision = 1
        let record = try #require(WorkspaceUndoReducer.record(before: before, after: afterTitle, label: "title"))
        var laterCategory = afterTitle
        laterCategory.revision = 2
        laterCategory.notes[id]?.categoryID = secondCategory
        laterCategory.notes[id]?.revision = 2

        let application = try WorkspaceUndoReducer.apply(record, direction: .undo, to: laterCategory, noteRevisionHighWatermarks: [id: 2])

        #expect(application.candidate.notes[id]?.title == original.title)
        #expect(application.candidate.notes[id]?.categoryID == secondCategory)
    }

    @Test func scheduleUndoPreservesALaterCompletionOnTheSameCalendarItem() throws {
        let category = UUID()
        let itemID = UUID()
        let firstDate = try #require(CalendarDate(year: 2026, month: 8, day: 10))
        let secondDate = try #require(CalendarDate(year: 2026, month: 8, day: 11))
        var before = WorkspaceState.empty(calendar: .empty(uncategorizedID: category, now: .distantPast))
        let original = try CalendarItem(
            id: itemID, kind: .task, title: "task", categoryID: category,
            schedule: .init(startDate: firstDate, endDate: firstDate, startTime: nil, endTime: nil),
            completedAt: nil, createdAt: .distantPast, updatedAt: .distantPast
        )
        before.calendar.items[itemID] = original
        var afterSchedule = before
        afterSchedule.revision = 1
        afterSchedule.calendar.items[itemID]?.schedule = try .init(startDate: secondDate, endDate: secondDate, startTime: nil, endTime: nil)
        let record = try #require(WorkspaceUndoReducer.record(before: before, after: afterSchedule, label: "reschedule"))
        var laterCompletion = afterSchedule
        laterCompletion.revision = 2
        laterCompletion.calendar.items[itemID]?.completedAt = Date(timeIntervalSinceReferenceDate: 123)

        let application = try WorkspaceUndoReducer.apply(record, direction: .undo, to: laterCompletion, noteRevisionHighWatermarks: [:])

        #expect(application.candidate.calendar.items[itemID]?.schedule.startDate == firstDate)
        #expect(application.candidate.calendar.items[itemID]?.completedAt == Date(timeIntervalSinceReferenceDate: 123))
    }

    @Test func categoryNameUndoPreservesALaterColorChange() throws {
        let uncategorized = UUID()
        let category = UUID()
        var before = WorkspaceState.empty(calendar: .empty(uncategorizedID: uncategorized, now: .distantPast))
        before.calendar.categories[category] = .init(
            id: category, name: "before", colorHex: "#007AFF", sortIndex: 1,
            createdAt: .distantPast, updatedAt: .distantPast
        )
        var afterName = before
        afterName.revision = 1
        afterName.calendar.categories[category]?.name = "after"
        let record = try #require(WorkspaceUndoReducer.record(before: before, after: afterName, label: "rename category"))
        var laterColor = afterName
        laterColor.revision = 2
        laterColor.calendar.categories[category]?.colorHex = "#FF0000"

        let application = try WorkspaceUndoReducer.apply(record, direction: .undo, to: laterColor, noteRevisionHighWatermarks: [:])

        #expect(application.candidate.calendar.categories[category]?.name == "before")
        #expect(application.candidate.calendar.categories[category]?.colorHex == "#FF0000")
    }

    @Test func inspirationTextUndoPreservesALaterCategoryChange() throws {
        let firstCategory = UUID()
        let secondCategory = UUID()
        let inspirationID = InspirationID(UUID())
        var before = WorkspaceState.empty(calendar: .empty(uncategorizedID: firstCategory, now: .distantPast))
        before.calendar.categories[secondCategory] = .init(
            id: secondCategory, name: "other", colorHex: "#007AFF", sortIndex: 1,
            createdAt: .distantPast, updatedAt: .distantPast
        )
        before.inspirations[inspirationID] = .text(id: inspirationID, rawText: "before", categoryID: firstCategory, now: .distantPast)
        var afterText = before
        afterText.revision = 1
        afterText.inspirations[inspirationID]?.rawText = "after"
        let record = try #require(WorkspaceUndoReducer.record(before: before, after: afterText, label: "edit inspiration"))
        var laterCategory = afterText
        laterCategory.revision = 2
        laterCategory.inspirations[inspirationID]?.categoryID = secondCategory

        let application = try WorkspaceUndoReducer.apply(record, direction: .undo, to: laterCategory, noteRevisionHighWatermarks: [:])

        #expect(application.candidate.inspirations[inspirationID]?.rawText == "before")
        #expect(application.candidate.inspirations[inspirationID]?.categoryID == secondCategory)
    }

    @Test func seriesTitleUndoPreservesALaterNotesEdit() throws {
        let category = UUID()
        let seriesID = UUID()
        let start = try #require(CalendarDate(year: 2026, month: 8, day: 10))
        var before = WorkspaceState.empty(calendar: .empty(uncategorizedID: category, now: .distantPast))
        before.calendar.recurrence.series[seriesID] = try WeeklySeries(
            id: seriesID, kind: .task, title: "before", categoryID: category,
            ruleStartDate: start, recurrenceEndDate: nil, weekdays: [.monday], durationDays: 1,
            startTime: nil, endTime: nil, notes: "", createdAt: .distantPast, updatedAt: .distantPast
        )
        var afterTitle = before
        afterTitle.revision = 1
        afterTitle.calendar.recurrence.series[seriesID]?.title = "after"
        let record = try #require(WorkspaceUndoReducer.record(before: before, after: afterTitle, label: "series title"))
        var laterNotes = afterTitle
        laterNotes.revision = 2
        laterNotes.calendar.recurrence.series[seriesID]?.notes = "later notes"

        let application = try WorkspaceUndoReducer.apply(record, direction: .undo, to: laterNotes, noteRevisionHighWatermarks: [:])

        #expect(application.candidate.calendar.recurrence.series[seriesID]?.title == "before")
        #expect(application.candidate.calendar.recurrence.series[seriesID]?.notes == "later notes")
    }

    @Test func relationUndoRemovesOnlyItsTouchedReferenceEdge() throws {
        let category = UUID()
        let itemID = UUID()
        let firstNoteID = NoteID(UUID())
        let touchedNoteID = NoteID(UUID())
        let laterNoteID = NoteID(UUID())
        var before = WorkspaceState.empty(calendar: .empty(uncategorizedID: category, now: .distantPast))
        before.calendar.items[itemID] = try CalendarItem(
            id: itemID, kind: .task, title: "task", categoryID: category,
            schedule: .init(startDate: .init(year: 2026, month: 8, day: 10)!, endDate: .init(year: 2026, month: 8, day: 10)!, startTime: nil, endTime: nil),
            completedAt: nil, createdAt: .distantPast, updatedAt: .distantPast
        )
        for id in [firstNoteID, touchedNoteID, laterNoteID] {
            before.notes[id] = .empty(id: id, categoryID: category, now: .distantPast)
        }
        let owner = CalendarNoteOwnerID.item(itemID)
        before.calendarNoteRelations.baselines[owner] = .init(primaryNoteID: nil, referenceNoteIDs: [firstNoteID])
        var afterAdd = before
        afterAdd.revision = 1
        afterAdd.calendarNoteRelations.baselines[owner]?.referenceNoteIDs.insert(touchedNoteID)
        let record = try #require(WorkspaceUndoReducer.record(before: before, after: afterAdd, label: "add relation"))
        var laterAdd = afterAdd
        laterAdd.revision = 2
        laterAdd.calendarNoteRelations.baselines[owner]?.referenceNoteIDs.insert(laterNoteID)

        let application = try WorkspaceUndoReducer.apply(record, direction: .undo, to: laterAdd, noteRevisionHighWatermarks: [:])

        #expect(application.candidate.calendarNoteRelations.baselines[owner]?.referenceNoteIDs == [firstNoteID, laterNoteID])
    }

    @Test func occurrenceRelationUndoRemovesOnlyItsTouchedReferenceEdge() throws {
        let category = UUID()
        let seriesID = UUID()
        let firstNoteID = NoteID(UUID())
        let touchedNoteID = NoteID(UUID())
        let laterNoteID = NoteID(UUID())
        let day = try #require(CalendarDate(year: 2026, month: 8, day: 10))
        var before = WorkspaceState.empty(calendar: .empty(uncategorizedID: category, now: .distantPast))
        before.calendar.recurrence.series[seriesID] = try WeeklySeries(
            id: seriesID, kind: .task, title: "series", categoryID: category,
            ruleStartDate: day, recurrenceEndDate: nil, weekdays: [.monday], durationDays: 1,
            startTime: nil, endTime: nil, notes: "", createdAt: .distantPast, updatedAt: .distantPast
        )
        for id in [firstNoteID, touchedNoteID, laterNoteID] {
            before.notes[id] = .empty(id: id, categoryID: category, now: .distantPast)
        }
        let key = OccurrenceKey(seriesID: seriesID, originalDate: day)
        before.calendarNoteRelations.occurrenceOverrides[key] = .init(
            key: key, primary: .inherit, addedReferenceNoteIDs: [firstNoteID], removedReferenceNoteIDs: []
        )
        var afterAdd = before
        afterAdd.revision = 1
        afterAdd.calendarNoteRelations.occurrenceOverrides[key]?.addedReferenceNoteIDs.insert(touchedNoteID)
        let record = try #require(WorkspaceUndoReducer.record(before: before, after: afterAdd, label: "add occurrence relation"))
        var laterAdd = afterAdd
        laterAdd.revision = 2
        laterAdd.calendarNoteRelations.occurrenceOverrides[key]?.addedReferenceNoteIDs.insert(laterNoteID)

        let application = try WorkspaceUndoReducer.apply(record, direction: .undo, to: laterAdd, noteRevisionHighWatermarks: [:])

        #expect(application.candidate.calendarNoteRelations.occurrenceOverrides[key]?.addedReferenceNoteIDs == [firstNoteID, laterNoteID])
    }

    @Test func deleteUndoRedoUndoKeepsAllocatingMonotonicNoteIncarnations() throws {
        let category = UUID()
        let id = NoteID(UUID())
        var before = WorkspaceState.empty(calendar: .empty(uncategorizedID: category, now: .distantPast))
        var note = Note.empty(id: id, categoryID: category, now: .distantPast)
        note.revision = 1
        before.revision = 1
        before.notes[id] = note
        var deleted = before
        deleted.revision = 2
        deleted.notes.removeValue(forKey: id)
        let initialRecord = try #require(WorkspaceUndoReducer.record(before: before, after: deleted, label: "delete"))

        let undo = try WorkspaceUndoReducer.apply(initialRecord, direction: .undo, to: deleted, noteRevisionHighWatermarks: [id: 1])
        let redo = try WorkspaceUndoReducer.apply(undo.reverseRecord, direction: .redo, to: undo.candidate, noteRevisionHighWatermarks: undo.noteRevisionHighWatermarks)
        let secondUndo = try WorkspaceUndoReducer.apply(redo.reverseRecord, direction: .undo, to: redo.candidate, noteRevisionHighWatermarks: redo.noteRevisionHighWatermarks)

        #expect(undo.candidate.notes[id]?.revision == 2)
        #expect(redo.candidate.notes[id] == nil)
        #expect(secondUndo.candidate.notes[id]?.revision == 3)
        #expect(secondUndo.noteRevisionHighWatermarks[id] == 3)
    }

    @Test func workspaceRevisionOverflowRejectsTheUndoWithoutMutatingTheInputState() throws {
        let category = UUID()
        let itemID = UUID()
        let before = WorkspaceState.empty(calendar: .empty(uncategorizedID: category, now: .distantPast))
        var after = before
        after.calendar.items[itemID] = try CalendarItem(
            id: itemID, kind: .task, title: "created", categoryID: category,
            schedule: .init(startDate: .init(year: 2026, month: 8, day: 10)!, endDate: .init(year: 2026, month: 8, day: 10)!, startTime: nil, endTime: nil),
            completedAt: nil, createdAt: .distantPast, updatedAt: .distantPast
        )
        let record = try #require(WorkspaceUndoReducer.record(before: before, after: after, label: "create"))
        var overflowed = after
        overflowed.revision = .max
        let unchanged = overflowed

        #expect(throws: WorkspaceUndoReducerError.revisionOverflow) {
            _ = try WorkspaceUndoReducer.apply(record, direction: .undo, to: overflowed, noteRevisionHighWatermarks: [:])
        }
        #expect(overflowed == unchanged)
    }
}
