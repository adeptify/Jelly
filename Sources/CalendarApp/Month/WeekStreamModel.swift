import CalendarDomain
import Foundation

struct WeekStreamAnchor: Equatable, Sendable {
    let weekStart: CalendarDate
    let pixelOffset: CGFloat
}

struct WeekStreamModel: Equatable, Sendable {
    private static let initialHalfWindowWeeks = 52
    private static let extensionWeeks = 52
    private static let maximumWindowWeeks = 157

    private(set) var weekStarts: [CalendarDate]
    private(set) var focusWeek: CalendarDate
    private(set) var selectedDate: CalendarDate?
    private var civilDayIntent: Int

    init(centeredOn date: CalendarDate) {
        let centerWeek = Self.weekStart(containing: date)
        focusWeek = centerWeek
        selectedDate = nil
        civilDayIntent = date.day
        weekStarts = (-Self.initialHalfWindowWeeks...Self.initialHalfWindowWeeks).map {
            centerWeek.addingDays($0 * 7)
        }
    }

    var monthTitleDate: CalendarDate {
        focusWeek.addingDays(3)
    }

    static func weekStart(containing date: CalendarDate) -> CalendarDate {
        date.addingDays(-(date.weekday.rawValue - 1))
    }

    mutating func updateFocus(toWeekStarting week: CalendarDate) {
        focusWeek = Self.weekStart(containing: week)
    }

    mutating func updateSelection(to date: CalendarDate?) {
        selectedDate = date
    }

    mutating func moveFocus(to date: CalendarDate, preservingCivilDayIntent: Bool) {
        focusWeek = Self.weekStart(containing: date)
        if !preservingCivilDayIntent {
            civilDayIntent = date.day
        }
    }

    func jumpTargetForPreviousMonth() -> CalendarDate {
        monthTarget(offset: -1)
    }

    func jumpTargetForNextMonth() -> CalendarDate {
        monthTarget(offset: 1)
    }

    func todayTarget(_ today: CalendarDate) -> CalendarDate {
        today
    }

    mutating func extendEarlier(
        visibleWeek: CalendarDate,
        pixelOffset: CGFloat
    ) -> WeekStreamAnchor {
        let anchor = WeekStreamAnchor(
            weekStart: Self.weekStart(containing: visibleWeek),
            pixelOffset: pixelOffset
        )
        let first = weekStarts[0]
        let newWeeks = (1...Self.extensionWeeks).reversed().map {
            first.addingDays(-$0 * 7)
        }
        weekStarts.insert(contentsOf: newWeeks, at: 0)
        trimToMaximum(afterExtending: .earlier)
        return anchor
    }

    mutating func extendLater(
        visibleWeek: CalendarDate,
        pixelOffset: CGFloat
    ) -> WeekStreamAnchor {
        let anchor = WeekStreamAnchor(
            weekStart: Self.weekStart(containing: visibleWeek),
            pixelOffset: pixelOffset
        )
        let last = weekStarts[weekStarts.count - 1]
        weekStarts.append(contentsOf: (1...Self.extensionWeeks).map {
            last.addingDays($0 * 7)
        })
        trimToMaximum(afterExtending: .later)
        return anchor
    }

    private enum ExtensionDirection {
        case earlier
        case later
    }

    private mutating func trimToMaximum(afterExtending direction: ExtensionDirection) {
        guard weekStarts.count > Self.maximumWindowWeeks else { return }

        let firstDistance = abs(focusWeek.days(until: weekStarts[0]))
        let lastDistance = abs(focusWeek.days(until: weekStarts[weekStarts.count - 1]))
        let shouldTrimEarlier: Bool
        if firstDistance == lastDistance {
            // A tie has no farther side. Preserve the edge that triggered loading.
            shouldTrimEarlier = direction == .later
        } else {
            shouldTrimEarlier = firstDistance > lastDistance
        }

        if shouldTrimEarlier {
            weekStarts.removeFirst(Self.extensionWeeks)
        } else {
            weekStarts.removeLast(Self.extensionWeeks)
        }
    }

    private func monthTarget(offset: Int) -> CalendarDate {
        let titleMonth = monthTitleDate
        let targetMonth = Self.offsetMonth(
            year: titleMonth.year,
            month: titleMonth.month,
            by: offset
        )
        let lastDay = Self.lastDay(ofYear: targetMonth.year, month: targetMonth.month)
        return CalendarDate(
            year: targetMonth.year,
            month: targetMonth.month,
            day: min(civilDayIntent, lastDay)
        )!
    }

    private static func offsetMonth(year: Int, month: Int, by offset: Int) -> (year: Int, month: Int) {
        let zeroBasedMonth = year * 12 + month - 1 + offset
        return (zeroBasedMonth / 12, zeroBasedMonth % 12 + 1)
    }

    private static func lastDay(ofYear year: Int, month: Int) -> Int {
        let nextMonth = offsetMonth(year: year, month: month, by: 1)
        return CalendarDate(year: nextMonth.year, month: nextMonth.month, day: 1)!
            .previousDay
            .day
    }
}
