import CalendarDomain

/// Deprecated compatibility for the V1 test surface; MonthView renders WeekRowView instead.
@available(*, deprecated, message: "WeekStream replaces the 42-cell grid; remove this compatibility helper in Task 12.")
enum MonthGridBuilder {
    static func cells(containing month: CalendarDate) -> [CalendarDate] {
        let firstOfMonth = CalendarDate(year: month.year, month: month.month, day: 1)!
        let mondayBeforeOrOnFirst = firstOfMonth.addingDays(-(firstOfMonth.weekday.rawValue - 1))
        return (0..<42).map { mondayBeforeOrOnFirst.addingDays($0) }
    }
}
