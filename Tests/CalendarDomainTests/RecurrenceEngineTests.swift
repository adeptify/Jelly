import Foundation
import Testing
@testable import CalendarDomain

@Suite("RecurrenceEngineTests")
struct RecurrenceEngineTests {
    @Test func firstOccurrenceIsFirstSelectedWeekdayOnOrAfterStart() throws {
        let series = try WeeklySeries(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            kind: .task,
            title: "固定复盘",
            categoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            startDate: .init(year: 2026, month: 8, day: 4)!, // Tuesday
            endDate: .init(year: 2026, month: 8, day: 12)!,
            weekdays: [.monday, .wednesday],
            timeRange: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let result = RecurrenceEngine.occurrences(
            of: series,
            in: .init(
                start: .init(year: 2026, month: 8, day: 1)!,
                end: .init(year: 2026, month: 8, day: 31)!
            ),
            exceptions: [:],
            completions: [:]
        )
        #expect(result.map(\.key.originalDate) == [
            .init(year: 2026, month: 8, day: 5)!,
            .init(year: 2026, month: 8, day: 10)!,
            .init(year: 2026, month: 8, day: 12)!
        ])
        #expect(result.allSatisfy {
            $0.creationTimeZoneIdentifier == series.creationTimeZoneIdentifier &&
                $0.createdAt == series.createdAt
        })
    }

    @Test func movedExceptionSuppressesOriginalAndKeepsStableKey() throws {
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let series = try WeeklySeries(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
            kind: .task,
            title: "周计划",
            categoryID: categoryID,
            startDate: .init(year: 2026, month: 8, day: 3)!,
            endDate: nil,
            weekdays: [.monday, .wednesday],
            timeRange: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let monday = CalendarDate(year: 2026, month: 8, day: 3)!
        let key = OccurrenceKey(seriesID: series.id, originalDate: monday)
        let moved = OccurrenceOverride(
            displayedDate: .init(year: 2026, month: 8, day: 4)!,
            title: series.title,
            kind: series.kind,
            categoryID: series.categoryID,
            timeRange: series.timeRange
        )
        let result = RecurrenceEngine.occurrences(
            of: series,
            in: .init(
                start: .init(year: 2026, month: 8, day: 1)!,
                end: .init(year: 2026, month: 8, day: 31)!
            ),
            exceptions: [key: .modified(moved)],
            completions: [:]
        )
        let matchingKey = result.filter { $0.key == key }
        #expect(matchingKey.count == 1)
        #expect(matchingKey.first?.displayedDate == moved.displayedDate)
        #expect(result.filter { $0.displayedDate == monday }.isEmpty)
    }

    @Test func inclusiveEndDateProducesOccurrence() throws {
        let endDate = CalendarDate(year: 2026, month: 8, day: 10)!
        let series = try makeSeries(
            startDate: .init(year: 2026, month: 8, day: 3)!,
            endDate: endDate,
            weekdays: [.monday]
        )

        let result = RecurrenceEngine.occurrences(
            of: series,
            in: .init(
                start: .init(year: 2026, month: 8, day: 1)!,
                end: .init(year: 2026, month: 8, day: 31)!
            ),
            exceptions: [:],
            completions: [:]
        )

        #expect(result.map { $0.key.originalDate } == [
            .init(year: 2026, month: 8, day: 3)!,
            endDate
        ])
    }

    @Test func skippedExceptionRemovesOnlyItsStableKey() throws {
        let series = try makeSeries(weekdays: [.monday, .wednesday])
        let skippedDate = CalendarDate(year: 2026, month: 8, day: 3)!
        let skippedKey = OccurrenceKey(seriesID: series.id, originalDate: skippedDate)

        let result = RecurrenceEngine.occurrences(
            of: series,
            in: .init(
                start: .init(year: 2026, month: 8, day: 3)!,
                end: .init(year: 2026, month: 8, day: 5)!
            ),
            exceptions: [skippedKey: .skipped],
            completions: [:]
        )

        #expect(result.map(\.key) == [
            OccurrenceKey(
                seriesID: series.id,
                originalDate: .init(year: 2026, month: 8, day: 5)!
            )
        ])
    }

    @Test func eventDoesNotExposeCompletion() throws {
        let series = try makeSeries(kind: .event, weekdays: [.monday])
        let key = OccurrenceKey(
            seriesID: series.id,
            originalDate: .init(year: 2026, month: 8, day: 3)!
        )

        let result = RecurrenceEngine.occurrences(
            of: series,
            in: .init(start: key.originalDate, end: key.originalDate),
            exceptions: [:],
            completions: [
                key: .init(key: key, completedAt: Date(timeIntervalSince1970: 60))
            ]
        )

        #expect(result.count == 1)
        #expect(result[0].completedAt == nil)
    }

    @Test func completingOneTaskOccurrenceDoesNotCompleteNext() throws {
        let series = try makeSeries(endDate: .init(year: 2026, month: 8, day: 10)!, weekdays: [.monday])
        let firstKey = OccurrenceKey(
            seriesID: series.id,
            originalDate: .init(year: 2026, month: 8, day: 3)!
        )
        let completionDate = Date(timeIntervalSince1970: 60)

        let result = RecurrenceEngine.occurrences(
            of: series,
            in: .init(
                start: .init(year: 2026, month: 8, day: 3)!,
                end: .init(year: 2026, month: 8, day: 10)!
            ),
            exceptions: [:],
            completions: [firstKey: .init(key: firstKey, completedAt: completionDate)]
        )

        #expect(result.count == 2)
        #expect(result[0].completedAt == completionDate)
        #expect(result[1].completedAt == nil)
    }

    @Test func explicitExceptionSurvivesNonMatchingWeekdayAfterSplit() throws {
        let series = try makeSeries(weekdays: [.tuesday])
        let key = OccurrenceKey(
            seriesID: series.id,
            originalDate: .init(year: 2026, month: 8, day: 3)!
        )
        let movedDate = CalendarDate(year: 2026, month: 8, day: 5)!
        let moved = OccurrenceOverride(
            displayedDate: movedDate,
            title: "拆分后调整",
            kind: .task,
            categoryID: series.categoryID,
            timeRange: nil
        )

        let result = RecurrenceEngine.occurrences(
            of: series,
            in: .init(
                start: .init(year: 2026, month: 8, day: 3)!,
                end: movedDate
            ),
            exceptions: [key: .modified(moved)],
            completions: [:]
        )

        let matchingKey = result.filter { $0.key == key }
        #expect(matchingKey.count == 1)
        #expect(matchingKey[0].displayedDate == movedDate)
    }

    @Test func modifiedExceptionEntersQueryWhenOriginalDateIsOutsideRange() throws {
        let series = try makeSeries(weekdays: [.tuesday])
        let originalDate = CalendarDate(year: 2026, month: 8, day: 3)!
        let displayedDate = CalendarDate(year: 2026, month: 8, day: 5)!
        let key = OccurrenceKey(seriesID: series.id, originalDate: originalDate)
        let moved = OccurrenceOverride(
            displayedDate: displayedDate,
            title: series.title,
            kind: series.kind,
            categoryID: series.categoryID,
            timeRange: series.timeRange
        )

        let result = RecurrenceEngine.occurrences(
            of: series,
            in: .init(start: displayedDate, end: displayedDate),
            exceptions: [key: .modified(moved)],
            completions: [:]
        )

        #expect(result.map(\.key) == [key])
        #expect(result[0].displayedDate == displayedDate)
    }

    @Test func occurrencesSortByDisplayedDateUntimedThenStartTimeAndOriginalDate() throws {
        let twoPM = try LocalTimeRange(
            start: MinuteOfDay(hour: 14, minute: 0)!,
            end: MinuteOfDay(hour: 15, minute: 0)!
        )
        let nineAM = try LocalTimeRange(
            start: MinuteOfDay(hour: 9, minute: 0)!,
            end: MinuteOfDay(hour: 10, minute: 0)!
        )
        let series = try makeSeries(
            endDate: .init(year: 2026, month: 8, day: 7)!,
            weekdays: [.monday, .tuesday, .wednesday, .thursday, .friday],
            timeRange: twoPM
        )
        let monday = CalendarDate(year: 2026, month: 8, day: 3)!
        let tuesday = CalendarDate(year: 2026, month: 8, day: 4)!
        let wednesday = CalendarDate(year: 2026, month: 8, day: 5)!
        let thursday = CalendarDate(year: 2026, month: 8, day: 6)!
        let friday = CalendarDate(year: 2026, month: 8, day: 7)!
        let movedToFriday: (LocalTimeRange?) -> OccurrenceExceptionKind = { timeRange in
            OccurrenceExceptionKind.modified(
                OccurrenceOverride(
                    displayedDate: friday,
                    title: series.title,
                    kind: series.kind,
                    categoryID: series.categoryID,
                    timeRange: timeRange
                )
            )
        }

        let result = RecurrenceEngine.occurrences(
            of: series,
            in: .init(start: monday, end: friday),
            exceptions: [
                .init(seriesID: series.id, originalDate: monday): movedToFriday(nil),
                .init(seriesID: series.id, originalDate: tuesday): movedToFriday(nineAM),
                .init(seriesID: series.id, originalDate: wednesday): movedToFriday(twoPM),
                .init(seriesID: series.id, originalDate: thursday): movedToFriday(twoPM)
            ],
            completions: [:]
        )

        #expect(result.map { $0.key.originalDate } == [
            monday, tuesday, wednesday, thursday, friday
        ])
    }

    @Test func weeklySeriesTrimsAndValidatesTitleAndTimeZone() throws {
        let series = try makeSeries(title: "  每周复盘  ")
        #expect(series.title == "每周复盘")

        #expect(throws: DomainValidationError.emptyTitle) {
            try makeSeries(title: " \n\t ")
        }
        #expect(throws: DomainValidationError.invalidTimeZoneIdentifier) {
            try makeSeries(creationTimeZoneIdentifier: "Not/AReal_TimeZone")
        }
    }

    @Test func weeklySeriesRejectsEmptyAndUnschedulableBoundedRules() {
        #expect(throws: DomainValidationError.emptyWeekdaySet) {
            try makeSeries(weekdays: [])
        }
        #expect(throws: DomainValidationError.invalidRecurrenceEnd) {
            try makeSeries(
                startDate: .init(year: 2026, month: 8, day: 4)!,
                endDate: .init(year: 2026, month: 8, day: 3)!
            )
        }
        #expect(throws: DomainValidationError.noOccurrenceInRange) {
            try makeSeries(
                startDate: .init(year: 2026, month: 8, day: 4)!,
                endDate: .init(year: 2026, month: 8, day: 5)!,
                weekdays: [.monday]
            )
        }
    }

    @Test func eachSelectedWeekdayStartsAnIndependentOverlappingSpan() throws {
        let series = try makeV2Series(
            ruleStartDate: .init(year: 2026, month: 8, day: 3)!,
            weekdays: [.wednesday, .thursday],
            durationDays: 2
        )
        let result = RecurrenceEngine.occurrences(
            of: series,
            in: .init(
                start: .init(year: 2026, month: 8, day: 5)!,
                end: .init(year: 2026, month: 8, day: 7)!
            ),
            exceptions: [:],
            completions: [:]
        )
        let expected = [
            try CalendarSchedule(
                startDate: .init(year: 2026, month: 8, day: 5)!,
                endDate: .init(year: 2026, month: 8, day: 6)!,
                startTime: nil,
                endTime: nil
            ),
            try CalendarSchedule(
                startDate: .init(year: 2026, month: 8, day: 6)!,
                endDate: .init(year: 2026, month: 8, day: 7)!,
                startTime: nil,
                endTime: nil
            )
        ]

        #expect(result.map(\.schedule) == expected)
    }

    @Test func recurrenceEndLimitsStartButDoesNotClipFinalSpan() throws {
        let series = try makeV2Series(
            ruleStartDate: .init(year: 2026, month: 8, day: 3)!,
            recurrenceEndDate: .init(year: 2026, month: 8, day: 5)!,
            weekdays: [.wednesday],
            durationDays: 3
        )
        let result = RecurrenceEngine.occurrences(
            of: series,
            in: .init(
                start: .init(year: 2026, month: 8, day: 1)!,
                end: .init(year: 2026, month: 8, day: 10)!
            ),
            exceptions: [:],
            completions: [:]
        )

        #expect(try #require(result.first).schedule.endDate == CalendarDate(year: 2026, month: 8, day: 7)!)
    }

    @Test func naturalProjectionUsesOnlyTheLookbackNeededForAnIntersectingTail() throws {
        let series = try makeV2Series(
            ruleStartDate: .init(year: 2020, month: 1, day: 1)!,
            weekdays: [.wednesday],
            durationDays: 3
        )
        let range = CalendarDateRange(
            start: .init(year: 2026, month: 8, day: 7)!,
            end: .init(year: 2026, month: 8, day: 7)!
        )

        #expect(
            RecurrenceEngine.naturalProjectionStart(of: series, in: range) ==
                CalendarDate(year: 2026, month: 8, day: 5)!
        )

        let result = RecurrenceEngine.occurrences(
            of: series,
            in: range,
            exceptions: [:],
            completions: [:]
        )

        #expect(result.map(\.key.originalDate) == [
            CalendarDate(year: 2026, month: 8, day: 5)!
        ])
        #expect(try #require(result.first).schedule.endDate == range.end)
    }

    private func makeSeries(
        id: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
        kind: ItemKind = .task,
        title: String = "每周计划",
        categoryID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        startDate: CalendarDate = .init(year: 2026, month: 8, day: 3)!,
        endDate: CalendarDate? = nil,
        weekdays: Set<Weekday> = [.monday, .wednesday],
        timeRange: LocalTimeRange? = nil,
        creationTimeZoneIdentifier: String = "Asia/Shanghai"
    ) throws -> WeeklySeries {
        try WeeklySeries(
            id: id,
            kind: kind,
            title: title,
            categoryID: categoryID,
            startDate: startDate,
            endDate: endDate,
            weekdays: weekdays,
            timeRange: timeRange,
            creationTimeZoneIdentifier: creationTimeZoneIdentifier,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeV2Series(
        id: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
        ruleStartDate: CalendarDate,
        recurrenceEndDate: CalendarDate? = nil,
        weekdays: Set<Weekday>,
        durationDays: Int
    ) throws -> WeeklySeries {
        try WeeklySeries(
            id: id,
            kind: .task,
            title: "每周计划",
            categoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            ruleStartDate: ruleStartDate,
            recurrenceEndDate: recurrenceEndDate,
            weekdays: weekdays,
            durationDays: durationDays,
            startTime: nil,
            endTime: nil,
            creationTimeZoneIdentifier: "Asia/Shanghai",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
