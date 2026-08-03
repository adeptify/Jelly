import Foundation
import Testing
@testable import CalendarDomain

@Suite("CoreModelTests")
struct CoreModelTests {
    @Test func crossDayScheduleAllowsOvernightClockTimes() throws {
        let schedule = try CalendarSchedule(
            startDate: date(2026, 8, 6), endDate: date(2026, 8, 7),
            startTime: minute(23, 0), endTime: minute(1, 0)
        )
        #expect(schedule.durationDays == 2)
    }

    @Test func sameDayScheduleRejectsEqualOrReversedClockTimes() {
        #expect(throws: DomainValidationError.invalidTimeRange) {
            try CalendarSchedule(
                startDate: date(2026, 8, 6), endDate: date(2026, 8, 6),
                startTime: minute(9, 0), endTime: minute(9, 0)
            )
        }
    }

    @Test func scheduleRejectsReversedDatesAndPartialTimes() {
        #expect(throws: DomainValidationError.invalidDateRange) {
            try CalendarSchedule(
                startDate: date(2026, 8, 7), endDate: date(2026, 8, 6),
                startTime: nil, endTime: nil
            )
        }
        #expect(throws: DomainValidationError.invalidTimeRange) {
            try CalendarSchedule(
                startDate: date(2026, 8, 6), endDate: date(2026, 8, 7),
                startTime: minute(9, 0), endTime: nil
            )
        }
    }

    @Test func timeRangeRejectsReversedRange() throws {
        #expect(throws: DomainValidationError.invalidTimeRange) {
            try LocalTimeRange(
                start: MinuteOfDay(hour: 10, minute: 30)!,
                end: MinuteOfDay(hour: 9, minute: 30)!
            )
        }
    }

    @Test func eventCannotCarryCompletion() throws {
        let category = UUID()
        #expect(throws: DomainValidationError.eventCannotComplete) {
            try CalendarItem(
                id: UUID(),
                kind: .event,
                title: "评审",
                categoryID: category,
                date: CalendarDate(year: 2026, month: 8, day: 3)!,
                timeRange: nil,
                completedAt: .now,
                createdAt: .now,
                updatedAt: .now
            )
        }
    }

    @Test func calendarDateUsesLocalCalendarDays() {
        let date = CalendarDate(year: 2026, month: 8, day: 31)!
        #expect(date.addingDays(1) == CalendarDate(year: 2026, month: 9, day: 1)!)
        #expect(date.weekday == .monday)
    }

    @Test func invalidMinuteOfDayReturnsNil() {
        #expect(MinuteOfDay(hour: -1, minute: 0) == nil)
        #expect(MinuteOfDay(hour: 24, minute: 0) == nil)
    }

    @Test func partialTimeRangeJSONFailsDecode() throws {
        let data = Data(#"{"start":{"value":600}}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(LocalTimeRange.self, from: data)
        }
    }

    @Test func localDayUsesSuppliedSystemTimeZone() {
        let instant = ISO8601DateFormatter().date(from: "2026-08-02T16:30:00Z")!
        #expect(
            CalendarDate.localDay(containing: instant, in: TimeZone(identifier: "Asia/Shanghai")!)
                == CalendarDate(year: 2026, month: 8, day: 3)!
        )
        #expect(
            CalendarDate.localDay(containing: instant, in: TimeZone(identifier: "America/Los_Angeles")!)
                == CalendarDate(year: 2026, month: 8, day: 2)!
        )
    }

    @Test func timeRangeRejectsEqualEndpoints() throws {
        let minute = MinuteOfDay(hour: 10, minute: 30)!
        #expect(throws: DomainValidationError.invalidTimeRange) {
            try LocalTimeRange(start: minute, end: minute)
        }
    }

    @Test func invalidPersistedCalendarComponentsFailDecode() throws {
        let data = Data(#"{"year":2026,"month":13,"day":1}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CalendarDate.self, from: data)
        }
    }

    @Test func invalidPersistedMinuteOfDayFailsDecode() throws {
        let data = Data(#"{"value":1440}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MinuteOfDay.self, from: data)
        }
    }

    @Test func calendarDateSupportsPreviousDayComparisonAndDayDistance() {
        let augustFirst = CalendarDate(year: 2026, month: 8, day: 1)!
        let augustThird = CalendarDate(year: 2026, month: 8, day: 3)!
        #expect(augustThird.previousDay == CalendarDate(year: 2026, month: 8, day: 2)!)
        #expect(augustFirst < augustThird)
        #expect(augustFirst.days(until: augustThird) == 2)
    }

    @Test func calendarItemRejectsWhitespaceOnlyTitle() {
        #expect(throws: DomainValidationError.emptyTitle) {
            try makeItem(title: "  \n\t ")
        }
    }

    @Test func calendarItemRejectsUnknownTimeZone() {
        #expect(throws: DomainValidationError.invalidTimeZoneIdentifier) {
            try makeItem(creationTimeZoneIdentifier: "Not/AReal_TimeZone")
        }
    }

    private func makeItem(
        title: String = "会议准备",
        creationTimeZoneIdentifier: String = "Asia/Shanghai"
    ) throws -> CalendarItem {
        try CalendarItem(
            id: UUID(),
            kind: .task,
            title: title,
            categoryID: UUID(),
            date: CalendarDate(year: 2026, month: 8, day: 3)!,
            timeRange: nil,
            creationTimeZoneIdentifier: creationTimeZoneIdentifier,
            completedAt: nil,
            createdAt: .now,
            updatedAt: .now
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> CalendarDate {
        CalendarDate(year: year, month: month, day: day)!
    }

    private func minute(_ hour: Int, _ minute: Int) -> MinuteOfDay {
        MinuteOfDay(hour: hour, minute: minute)!
    }
}
