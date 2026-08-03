import CalendarDomain
import AppKit
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

    @Test func hostedMonthStartsCenteredOnInjectedTodayAndKeepsWeeksScrollableAboveAndBelow() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 4, hour: 9
        ))!
        let policy = MonthViewTodayRefreshPolicy(now: { now }, calendar: calendar)
        let injectedToday = policy.today
        let initialWeekStream = MonthViewInitialWeekStream(today: injectedToday)
        let targetWeek = CalendarDate(year: 2026, month: 8, day: 3)!

        #expect(initialWeekStream.today == injectedToday)
        #expect(initialWeekStream.focusWeek == targetWeek)
        #expect(initialWeekStream.monthTitleDate == CalendarDate(year: 2026, month: 8, day: 6)!)
        #expect(initialWeekStream.weekStarts.count == 105)
        #expect(initialWeekStream.weekStarts[52] == targetWeek)
        #expect(initialWeekStream.windowRevision == .init(weekStarts: initialWeekStream.weekStarts))

        let state = makeEmptyState()
        let initialModel = MonthViewModel(
            centeredOn: initialWeekStream.today,
            state: state,
            hiddenCategoryIDs: [],
            today: initialWeekStream.today
        )
        #expect(initialModel.focusWeek == initialWeekStream.focusWeek)
        #expect(initialModel.monthTitleDate == initialWeekStream.monthTitleDate)
        #expect(initialModel.weekStarts[52] == initialWeekStream.focusWeek)
        #expect(WeekStreamWindowRevision(weekStarts: initialModel.weekStarts)
            == initialWeekStream.windowRevision)
        let store = CalendarStore(
            initialState: state,
            repository: InMemoryCalendarRepository(initialState: state)
        )
        let host = NSHostingView(rootView: MonthView(
            store: store,
            todayRefreshPolicy: policy
        ))
        host.frame = NSRect(x: 0, y: 0, width: 1_106, height: 768)
        let window = NSWindow(
            contentRect: host.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil as Any?)
            window.contentView = nil
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))

        let stream = try #require(descendants(of: host, as: NSScrollView.self).first)
        let maxOriginY = max(0, stream.documentView!.bounds.height - stream.contentView.bounds.height)
        let originalOriginY = stream.contentView.bounds.origin.y
        let targetDocumentCenterY = CGFloat(
            try #require(initialWeekStream.weekStarts.firstIndex(of: targetWeek))
        ) * WeekRowMetrics.defaultHeight + WeekRowMetrics.defaultHeight / 2
        let targetViewportCenterY = targetDocumentCenterY - originalOriginY

        #expect(originalOriginY > 252)
        #expect(originalOriginY < maxOriginY - 252)
        #expect(abs(targetViewportCenterY - stream.contentView.bounds.height / 2) <= 1)

        stream.contentView.scroll(to: NSPoint(x: 0, y: originalOriginY - 252))
        let earlierOriginY = stream.contentView.bounds.origin.y
        stream.contentView.scroll(to: NSPoint(x: 0, y: originalOriginY + 252))
        let laterOriginY = stream.contentView.bounds.origin.y
        #expect(earlierOriginY < originalOriginY)
        #expect(laterOriginY > originalOriginY)
    }

    private final class TodayUpdateTarget {
        private(set) var updatedDates: [CalendarDate] = []

        func update(_ today: CalendarDate) {
            updatedDates.append(today)
        }
    }

    private func descendants<View: NSView>(of root: NSView, as _: View.Type) -> [View] {
        root.subviews.flatMap { child in
            let match = (child as? View).map { [$0] } ?? []
            return match + descendants(of: child, as: View.self)
        }
    }
}
