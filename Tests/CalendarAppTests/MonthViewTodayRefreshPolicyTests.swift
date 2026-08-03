import CalendarDomain
import Foundation
import SwiftUI
import Testing
@testable import CalendarApp

@Suite("MonthViewTodayRefreshPolicyTests")
@MainActor
struct MonthViewTodayRefreshPolicyTests {
    @Test func calendarDayChangeReReadsInjectedClockAndUpdatesTarget() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var now = calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 3, hour: 23, minute: 59
        ))!
        let policy = MonthViewTodayRefreshPolicy(now: { now }, calendar: calendar)
        let controller = MonthViewTodayRefreshController(policy: policy)
        let target = TodayUpdateTarget()

        #expect(MonthViewTodayRefreshPolicy.calendarDayChangedNotification == .NSCalendarDayChanged)

        now = calendar.date(byAdding: .minute, value: 2, to: now)!
        controller.handle(.calendarDayChanged, updateToday: target.update)

        #expect(target.updatedDates == [CalendarDate(year: 2026, month: 8, day: 4)!])
    }

    @Test func activeScenePhaseReReadsInjectedClockAndUpdatesTarget() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var now = calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 4, hour: 23, minute: 59
        ))!
        let policy = MonthViewTodayRefreshPolicy(now: { now }, calendar: calendar)
        let controller = MonthViewTodayRefreshController(policy: policy)
        let target = TodayUpdateTarget()

        now = calendar.date(byAdding: .minute, value: 2, to: now)!
        controller.handle(.scenePhaseChanged(.active), updateToday: target.update)

        #expect(target.updatedDates == [CalendarDate(year: 2026, month: 8, day: 5)!])
    }

    @Test func inactiveScenePhaseDoesNotUpdateTarget() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 4, hour: 0, minute: 1
        ))!
        let policy = MonthViewTodayRefreshPolicy(now: { now }, calendar: calendar)
        let controller = MonthViewTodayRefreshController(policy: policy)
        let target = TodayUpdateTarget()

        controller.handle(.scenePhaseChanged(.inactive), updateToday: target.update)

        #expect(target.updatedDates.isEmpty)
    }

    private final class TodayUpdateTarget {
        private(set) var updatedDates: [CalendarDate] = []

        func update(_ today: CalendarDate) {
            updatedDates.append(today)
        }
    }
}
