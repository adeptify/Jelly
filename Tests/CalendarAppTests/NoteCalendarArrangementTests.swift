import CalendarDomain
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("NoteCalendarArrangementTests")
struct NoteCalendarArrangementTests {
    @Test func oneOffRelationAndTaskBlockLinkAreShownOnlyOnce() throws {
        var calendar = makeEmptyState()
        let item = try makeItem(categoryID: calendar.uncategorizedID, title: "一次性安排")
        calendar.items[item.id] = item
        let noteID = NoteID()
        let blockID = BlockID()
        var state = WorkspaceState.empty(calendar: calendar)
        state.calendarNoteRelations.baselines[.item(item.id)] = .init(
            primaryNoteID: noteID,
            referenceNoteIDs: []
        )
        state.taskBlockLinks.insert(.init(
            noteID: noteID,
            blockID: blockID,
            calendarItemID: item.id
        ))

        let rows = NoteCalendarArrangementProjection.make(noteID: noteID, state: state)

        #expect(rows.count == 1)
        #expect(rows.first?.target == .calendarItem(item.id))
        #expect(rows.first?.title == "一次性安排")
    }

    @Test func seriesAndOccurrenceOnlyRelationsBothRemainVisibleAndOpenTheirExactTargets() throws {
        var calendar = makeEmptyState()
        let monday = try #require(CalendarDate(year: 2026, month: 8, day: 17))
        let baselineSeries = try makeSeries(
            title: "每周复盘",
            categoryID: calendar.uncategorizedID,
            start: monday
        )
        let exceptionSeries = try makeSeries(
            title: "每周采购",
            categoryID: calendar.uncategorizedID,
            start: monday
        )
        calendar.recurrence.series[baselineSeries.id] = baselineSeries
        calendar.recurrence.series[exceptionSeries.id] = exceptionSeries
        let exceptionKey = OccurrenceKey(seriesID: exceptionSeries.id, originalDate: monday)
        let noteID = NoteID()
        var state = WorkspaceState.empty(calendar: calendar)
        state.calendarNoteRelations.baselines[.series(baselineSeries.id)] = .init(
            primaryNoteID: noteID,
            referenceNoteIDs: []
        )
        state.calendarNoteRelations.occurrenceOverrides[exceptionKey] = .init(
            key: exceptionKey,
            primary: .replace(noteID),
            addedReferenceNoteIDs: [],
            removedReferenceNoteIDs: []
        )

        let rows = NoteCalendarArrangementProjection.make(noteID: noteID, state: state)

        #expect(rows.count == 2)
        #expect(rows.contains { $0.target == .calendarSeries(baselineSeries.id) && $0.title == "每周复盘" })
        #expect(rows.contains { $0.target == .calendarOccurrence(exceptionKey) && $0.title == "每周采购" })
    }

    @Test func inheritedSeriesRelationDoesNotCreateADuplicateOccurrenceRow() throws {
        var calendar = makeEmptyState()
        let monday = try #require(CalendarDate(year: 2026, month: 8, day: 17))
        let series = try makeSeries(
            title: "每周整理",
            categoryID: calendar.uncategorizedID,
            start: monday
        )
        calendar.recurrence.series[series.id] = series
        let key = OccurrenceKey(seriesID: series.id, originalDate: monday)
        let noteID = NoteID()
        var state = WorkspaceState.empty(calendar: calendar)
        state.calendarNoteRelations.baselines[.series(series.id)] = .init(
            primaryNoteID: noteID,
            referenceNoteIDs: []
        )
        state.calendarNoteRelations.occurrenceOverrides[key] = .init(
            key: key,
            primary: .inherit,
            addedReferenceNoteIDs: [],
            removedReferenceNoteIDs: []
        )

        let rows = NoteCalendarArrangementProjection.make(noteID: noteID, state: state)

        #expect(rows.map(\.target) == [.calendarSeries(series.id)])
    }
}

private func makeSeries(
    title: String,
    categoryID: UUID,
    start: CalendarDate
) throws -> WeeklySeries {
    try WeeklySeries(
        id: UUID(),
        kind: .task,
        title: title,
        categoryID: categoryID,
        ruleStartDate: start,
        recurrenceEndDate: nil,
        weekdays: [start.weekday],
        durationDays: 1,
        startTime: nil,
        endTime: nil,
        createdAt: .distantPast,
        updatedAt: .distantPast
    )
}
