import Foundation
import Testing
@testable import CalendarDomain

@Suite("TimelineProjectionTests")
struct TimelineProjectionTests {
    private let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000401")!

    @Test func itemStartingBeforeViewportButEndingInsideIsProjectedOnce() throws {
        let item = try makeItem(schedule: schedule("2026-08-08", "2026-08-11"))

        let projection = TimelineProjection.make(
            in: range("2026-08-10", "2026-08-16"),
            state: state(item: item),
            hiddenCategoryIDs: []
        )

        #expect(projection.entries.map(\.schedule) == [item.schedule])
        #expect(projection.entries.map(\.id) == [.item(item.id)])
    }

    @Test func extendedRecurringOverrideEnteringViewportIsProjected() throws {
        let fixture = try stateWithOverrideEndingOnAugust10()

        let projection = TimelineProjection.make(
            in: range("2026-08-10", "2026-08-16"),
            state: fixture.state,
            hiddenCategoryIDs: []
        )

        #expect(projection.entries.map(\.id) == [.occurrence(fixture.overrideKey)])
        #expect(projection.entries.map(\.schedule) == [schedule("2026-08-03", "2026-08-10")])
    }

    @Test func modifiedExceptionsMovedIntoViewportFromEitherSideSuppressTheirOriginalPosition() throws {
        let fixture = try stateWithOriginalDatesBeforeAndAfterButDisplayedSchedulesInside()

        let projection = TimelineProjection.make(
            in: range("2026-08-10", "2026-08-16"),
            state: fixture.state,
            hiddenCategoryIDs: []
        )

        #expect(projection.entries.map(\.id) == [
            .occurrence(fixture.movedForwardKey),
            .occurrence(fixture.movedBackwardKey)
        ])
        #expect(projection.entries.allSatisfy {
            range("2026-08-10", "2026-08-16").intersects($0.schedule)
        })
    }

    @Test func skippedAndMovedExceptionsAreDeduplicatedByOccurrenceKey() throws {
        let fixture = try stateWithSkippedAndMovedKeys()

        let projection = TimelineProjection.make(
            in: range("2026-08-10", "2026-08-16"),
            state: fixture.state,
            hiddenCategoryIDs: []
        )

        #expect(projection.entries.filter { $0.id == .occurrence(fixture.movedKey) }.count == 1)
        #expect(!projection.entries.contains { $0.id == .occurrence(fixture.skippedKey) })
    }

    private func stateWithOverrideEndingOnAugust10() throws -> (state: CalendarState, overrideKey: OccurrenceKey) {
        let series = try makeSeries(id: uuid("402"))
        let overrideKey = OccurrenceKey(seriesID: series.id, originalDate: date("2026-08-03"))
        let override = OccurrenceOverride(
            displayedSchedule: schedule("2026-08-03", "2026-08-10"),
            title: series.title,
            kind: series.kind,
            categoryID: series.categoryID
        )
        let inRangeKey = OccurrenceKey(seriesID: series.id, originalDate: date("2026-08-10"))
        return (
            state: state(series: series, exceptions: [
                overrideKey: .modified(override),
                inRangeKey: .skipped
            ]),
            overrideKey: overrideKey
        )
    }

    private func stateWithOriginalDatesBeforeAndAfterButDisplayedSchedulesInside() throws -> (
        state: CalendarState,
        movedForwardKey: OccurrenceKey,
        movedBackwardKey: OccurrenceKey
    ) {
        let series = try makeSeries(id: uuid("403"))
        let movedForwardKey = OccurrenceKey(seriesID: series.id, originalDate: date("2026-08-03"))
        let movedBackwardKey = OccurrenceKey(seriesID: series.id, originalDate: date("2026-08-17"))
        let forward = OccurrenceOverride(
            displayedSchedule: schedule("2026-08-11", "2026-08-12"),
            title: "向后移动",
            kind: .task,
            categoryID: categoryID
        )
        let backward = OccurrenceOverride(
            displayedSchedule: schedule("2026-08-13", "2026-08-14"),
            title: "向前移动",
            kind: .task,
            categoryID: categoryID
        )
        let inRangeKey = OccurrenceKey(seriesID: series.id, originalDate: date("2026-08-10"))
        return (
            state: state(series: series, exceptions: [
                movedForwardKey: .modified(forward),
                movedBackwardKey: .modified(backward),
                inRangeKey: .skipped
            ]),
            movedForwardKey: movedForwardKey,
            movedBackwardKey: movedBackwardKey
        )
    }

    private func stateWithSkippedAndMovedKeys() throws -> (
        state: CalendarState,
        skippedKey: OccurrenceKey,
        movedKey: OccurrenceKey
    ) {
        let series = try makeSeries(id: uuid("404"))
        let skippedKey = OccurrenceKey(seriesID: series.id, originalDate: date("2026-08-10"))
        let movedKey = OccurrenceKey(seriesID: series.id, originalDate: date("2026-08-17"))
        let moved = OccurrenceOverride(
            displayedSchedule: schedule("2026-08-11", "2026-08-11"),
            title: "移入范围",
            kind: .task,
            categoryID: categoryID
        )
        return (
            state: state(series: series, exceptions: [
                skippedKey: .skipped,
                movedKey: .modified(moved)
            ]),
            skippedKey: skippedKey,
            movedKey: movedKey
        )
    }

    private func makeItem(
        id: UUID? = nil,
        schedule: CalendarSchedule,
        createdAt: Date = .distantPast
    ) throws -> CalendarItem {
        try CalendarItem(
            id: id ?? uuid("405"),
            kind: .task,
            title: "跨范围事项",
            categoryID: categoryID,
            schedule: schedule,
            creationTimeZoneIdentifier: "Asia/Shanghai",
            completedAt: nil,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    private func makeSeries(id: UUID) throws -> WeeklySeries {
        try WeeklySeries(
            id: id,
            kind: .task,
            title: "每周事项",
            categoryID: categoryID,
            ruleStartDate: date("2026-08-03"),
            recurrenceEndDate: nil,
            weekdays: [.monday],
            durationDays: 1,
            startTime: nil,
            endTime: nil,
            creationTimeZoneIdentifier: "Asia/Shanghai",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
    }

    private func state(item: CalendarItem) -> CalendarState {
        var result = CalendarState.empty(uncategorizedID: categoryID, now: .distantPast)
        result.items[item.id] = item
        return result
    }

    private func state(
        series: WeeklySeries,
        exceptions: [OccurrenceKey: OccurrenceExceptionKind]
    ) -> CalendarState {
        var result = CalendarState.empty(uncategorizedID: categoryID, now: .distantPast)
        result.recurrence = .init(series: [series.id: series], exceptions: exceptions, completions: [:])
        return result
    }

    private func range(_ start: String, _ end: String) -> CalendarDateRange {
        .init(start: date(start), end: date(end))
    }

    private func schedule(_ start: String, _ end: String) -> CalendarSchedule {
        try! .init(startDate: date(start), endDate: date(end), startTime: nil, endTime: nil)
    }

    private func date(_ string: String) -> CalendarDate {
        let components = string.split(separator: "-").map { Int($0)! }
        return CalendarDate(year: components[0], month: components[1], day: components[2])!
    }

    private func uuid(_ suffix: String) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-000000000\(suffix)")!
    }
}

private extension CalendarDateRange {
    func intersects(_ schedule: CalendarSchedule) -> Bool {
        schedule.startDate <= end && start <= schedule.endDate
    }
}
