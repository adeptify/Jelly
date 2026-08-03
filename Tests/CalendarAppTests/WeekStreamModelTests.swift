import CalendarDomain
import Foundation
import Testing
@testable import CalendarApp

@Suite("WeekStreamModelTests")
struct WeekStreamModelTests {
    @Test func initialWindowNormalizesEveryWeekToMondayAroundTheCenteredWeek() {
        let model = WeekStreamModel(centeredOn: date(2026, 8, 6))

        #expect(model.weekStarts.count == 105)
        #expect(model.weekStarts[52] == date(2026, 8, 3))
        #expect(model.weekStarts.allSatisfy { $0.weekday == .monday })
        for (earlier, later) in zip(model.weekStarts, model.weekStarts.dropFirst()) {
            #expect(earlier.addingDays(7) == later)
        }
    }

    @Test func earlierExtensionAddsExactlyFiftyTwoWeeksAndReturnsTheNormalizedAnchor() {
        var model = WeekStreamModel(centeredOn: date(2026, 8, 6))
        let first = model.weekStarts.first!

        let anchor = model.extendEarlier(
            visibleWeek: date(2025, 8, 6),
            pixelOffset: 37
        )

        #expect(model.weekStarts.count == 157)
        #expect(model.weekStarts.first == first.addingDays(-364))
        #expect(anchor == .init(weekStart: date(2025, 8, 4), pixelOffset: 37))
    }

    @Test func repeatedLaterExtensionTrimsTheFarSideWithoutMovingAnEdgeAnchor() {
        var model = WeekStreamModel(centeredOn: date(2026, 8, 6))
        let center = date(2026, 8, 3)

        _ = model.extendLater(visibleWeek: model.weekStarts.last!, pixelOffset: 19)
        let visibleWeek = model.weekStarts.last!
        model.updateFocus(toWeekStarting: visibleWeek)
        let anchor = model.extendLater(visibleWeek: visibleWeek, pixelOffset: 19)

        #expect(model.weekStarts.count == 157)
        #expect(model.weekStarts.first == center)
        #expect(model.weekStarts.last == center.addingDays(1_092))
        #expect(anchor == .init(weekStart: visibleWeek, pixelOffset: 19))
        #expect(model.weekStarts.contains(visibleWeek))
    }

    @Test func repeatedEarlierExtensionTrimsTheLaterFarSideWithoutMovingAnEdgeAnchor() {
        var model = WeekStreamModel(centeredOn: date(2026, 8, 6))
        let center = date(2026, 8, 3)

        _ = model.extendEarlier(visibleWeek: model.weekStarts.first!, pixelOffset: 11)
        let visibleWeek = model.weekStarts.first!
        model.updateFocus(toWeekStarting: visibleWeek)
        let anchor = model.extendEarlier(visibleWeek: visibleWeek, pixelOffset: 11)

        #expect(model.weekStarts.count == 157)
        #expect(model.weekStarts.first == center.addingDays(-1_092))
        #expect(model.weekStarts.last == center)
        #expect(anchor == .init(weekStart: visibleWeek, pixelOffset: 11))
        #expect(model.weekStarts.contains(visibleWeek))
    }

    @Test func selectionDoesNotChangeWhenFocusMovesAndFocusDoesNotChangeWhenSelectionClears() {
        var model = WeekStreamModel(centeredOn: date(2026, 8, 6))
        let selected = date(2026, 8, 5)

        model.updateSelection(to: selected)
        model.updateFocus(toWeekStarting: date(2026, 8, 14))
        #expect(model.focusWeek == date(2026, 8, 10))
        #expect(model.selectedDate == selected)

        model.updateSelection(to: nil)
        #expect(model.focusWeek == date(2026, 8, 10))
        #expect(model.selectedDate == nil)
    }

    @Test func focusMonthUsesThursdayAndMonthArrowsUseTheFocusMonth() {
        var model = WeekStreamModel(centeredOn: date(2026, 8, 31))
        model.updateFocus(toWeekStarting: date(2026, 8, 31))

        #expect(model.monthTitleDate == date(2026, 9, 3))
        #expect(model.jumpTargetForPreviousMonth() == date(2026, 8, 31))
        #expect(model.jumpTargetForNextMonth() == date(2026, 10, 31))
    }

    @Test func monthTargetsClampJanuaryThirtyFirstAcrossCommonLeapAndYearBoundaries() {
        let commonYear = WeekStreamModel(centeredOn: date(2025, 1, 31))
        let leapYear = WeekStreamModel(centeredOn: date(2020, 1, 31))
        let crossYear = WeekStreamModel(centeredOn: date(2026, 1, 31))

        #expect(commonYear.jumpTargetForNextMonth() == date(2025, 2, 28))
        #expect(leapYear.jumpTargetForNextMonth() == date(2020, 2, 29))
        #expect(crossYear.jumpTargetForPreviousMonth() == date(2025, 12, 31))
        #expect(crossYear.todayTarget(date(2026, 2, 28)) == date(2026, 2, 28))
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> CalendarDate {
        CalendarDate(year: year, month: month, day: day)!
    }
}
