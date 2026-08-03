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

    @Test func laterExtensionKeepsFocusAndOldFirstAnchorWhenTheyAlreadyFillTheWindow() {
        var model = WeekStreamModel(centeredOn: date(2026, 8, 6))
        let oldFirst = model.weekStarts.first!
        _ = model.extendLater(visibleWeek: model.weekStarts.last!, pixelOffset: 7)
        let focusAtLaterEdge = model.weekStarts.last!
        model.updateFocus(toWeekStarting: focusAtLaterEdge)

        let anchor = model.extendLater(visibleWeek: oldFirst, pixelOffset: 29)

        #expect(anchor == .init(weekStart: oldFirst, pixelOffset: 29))
        #expect(model.weekStarts.contains(anchor.weekStart))
        #expect(model.weekStarts.contains(focusAtLaterEdge))
        #expect(model.weekStarts.first == oldFirst)
        #expect(model.weekStarts.last == focusAtLaterEdge)
        #expect(model.weekStarts.count == 157)
        for (earlier, later) in zip(model.weekStarts, model.weekStarts.dropFirst()) {
            #expect(earlier.addingDays(7) == later)
        }
    }

    @Test func earlierExtensionKeepsFocusAndOldLastAnchorWhenTheyAlreadyFillTheWindow() {
        var model = WeekStreamModel(centeredOn: date(2026, 8, 6))
        let oldLast = model.weekStarts.last!
        _ = model.extendEarlier(visibleWeek: model.weekStarts.first!, pixelOffset: 7)
        let focusAtEarlierEdge = model.weekStarts.first!
        model.updateFocus(toWeekStarting: focusAtEarlierEdge)

        let anchor = model.extendEarlier(visibleWeek: oldLast, pixelOffset: 31)

        #expect(anchor == .init(weekStart: oldLast, pixelOffset: 31))
        #expect(model.weekStarts.contains(anchor.weekStart))
        #expect(model.weekStarts.contains(focusAtEarlierEdge))
        #expect(model.weekStarts.first == focusAtEarlierEdge)
        #expect(model.weekStarts.last == oldLast)
        #expect(model.weekStarts.count == 157)
        for (earlier, later) in zip(model.weekStarts, model.weekStarts.dropFirst()) {
            #expect(earlier.addingDays(7) == later)
        }
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

    @Test func applyingConsecutiveMonthTargetsPreservesThirtyFirstAcrossClampedMonths() {
        var commonYear = WeekStreamModel(centeredOn: date(2025, 1, 31))

        let commonFebruary = commonYear.jumpTargetForNextMonth()
        #expect(commonFebruary == date(2025, 2, 28))
        commonYear.moveFocus(to: commonFebruary, preservingCivilDayIntent: true)
        #expect(commonYear.monthTitleDate.month == 2)

        let commonMarch = commonYear.jumpTargetForNextMonth()
        #expect(commonMarch == date(2025, 3, 31))
        commonYear.moveFocus(to: commonMarch, preservingCivilDayIntent: true)
        #expect(commonYear.monthTitleDate.month == 3)

        let commonApril = commonYear.jumpTargetForNextMonth()
        #expect(commonApril == date(2025, 4, 30))
        commonYear.moveFocus(to: commonApril, preservingCivilDayIntent: true)
        #expect(commonYear.monthTitleDate.month == 4)

        var leapYear = WeekStreamModel(centeredOn: date(2020, 1, 31))
        let leapFebruary = leapYear.jumpTargetForNextMonth()
        #expect(leapFebruary == date(2020, 2, 29))
        leapYear.moveFocus(to: leapFebruary, preservingCivilDayIntent: true)
        #expect(leapYear.jumpTargetForNextMonth() == date(2020, 3, 31))
    }

    @Test func applyingCrossMonthWeekTargetMovesFocusIntoTheLogicalTargetMonth() {
        var model = WeekStreamModel(centeredOn: date(2026, 8, 31))
        let originalFocus = model.focusWeek

        let augustTarget = model.jumpTargetForPreviousMonth()
        #expect(augustTarget == date(2026, 8, 31))
        model.moveFocus(to: augustTarget, preservingCivilDayIntent: true)

        #expect(model.focusWeek == date(2026, 8, 24))
        #expect(model.focusWeek != originalFocus)
        #expect(model.monthTitleDate == date(2026, 8, 27))
        #expect(model.jumpTargetForPreviousMonth() == date(2026, 7, 31))
    }

    @Test func applyingFirstOfMonthTargetAdjustsForwardAndCrossYearNavigationStaysLogical() {
        var monthStart = WeekStreamModel(centeredOn: date(2026, 6, 1))
        let mayTarget = monthStart.jumpTargetForPreviousMonth()
        #expect(mayTarget == date(2026, 5, 1))
        monthStart.moveFocus(to: mayTarget, preservingCivilDayIntent: true)
        #expect(monthStart.focusWeek == date(2026, 5, 4))
        #expect(monthStart.monthTitleDate == date(2026, 5, 7))

        var crossYear = WeekStreamModel(centeredOn: date(2026, 1, 1))
        let decemberTarget = crossYear.jumpTargetForPreviousMonth()
        #expect(decemberTarget == date(2025, 12, 1))
        crossYear.moveFocus(to: decemberTarget, preservingCivilDayIntent: true)
        #expect(crossYear.monthTitleDate.year == 2025)
        #expect(crossYear.monthTitleDate.month == 12)
        #expect(crossYear.jumpTargetForNextMonth() == date(2026, 1, 1))
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> CalendarDate {
        CalendarDate(year: year, month: month, day: day)!
    }
}
