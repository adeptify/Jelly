import CalendarDomain
import Foundation

struct ItemDraft: Equatable {
    var kind: ItemKind
    var title: String
    var categoryID: UUID
    var date: CalendarDate
    var usesTime: Bool
    var start: MinuteOfDay
    var end: MinuteOfDay
    var repeatsWeekly: Bool
    var weekdays: Set<Weekday>
    var recurrenceEndDate: CalendarDate?
}

extension ItemDraft {
    init(item: CalendarItem) {
        self.init(
            kind: item.kind,
            title: item.title,
            categoryID: item.categoryID,
            date: item.date,
            usesTime: item.timeRange != nil,
            start: item.timeRange?.start ?? MinuteOfDay(hour: 9, minute: 0)!,
            end: item.timeRange?.end ?? MinuteOfDay(hour: 10, minute: 0)!,
            repeatsWeekly: false,
            weekdays: [],
            recurrenceEndDate: nil
        )
    }

    init(series: WeeklySeries, date: CalendarDate) {
        self.init(
            kind: series.kind,
            title: series.title,
            categoryID: series.categoryID,
            date: date,
            usesTime: series.timeRange != nil,
            start: series.timeRange?.start ?? MinuteOfDay(hour: 9, minute: 0)!,
            end: series.timeRange?.end ?? MinuteOfDay(hour: 10, minute: 0)!,
            repeatsWeekly: true,
            weekdays: series.weekdays,
            recurrenceEndDate: series.endDate
        )
    }

    init(occurrence: CalendarOccurrence, series: WeeklySeries) {
        self.init(
            kind: occurrence.kind,
            title: occurrence.title,
            categoryID: occurrence.categoryID,
            date: occurrence.displayedDate,
            usesTime: occurrence.timeRange != nil,
            start: occurrence.timeRange?.start ?? MinuteOfDay(hour: 9, minute: 0)!,
            end: occurrence.timeRange?.end ?? MinuteOfDay(hour: 10, minute: 0)!,
            repeatsWeekly: true,
            weekdays: series.weekdays,
            recurrenceEndDate: series.endDate
        )
    }

    static func newItem(on date: CalendarDate, categoryID: UUID) -> ItemDraft {
        ItemDraft(
            kind: .task,
            title: "",
            categoryID: categoryID,
            date: date,
            usesTime: false,
            start: MinuteOfDay(hour: 9, minute: 0)!,
            end: MinuteOfDay(hour: 10, minute: 0)!,
            repeatsWeekly: false,
            weekdays: [date.weekday],
            recurrenceEndDate: nil
        )
    }
}

extension CalendarDate {
    var editorDate: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    static func editorDate(containing date: Date) -> CalendarDate {
        CalendarDate.localDay(containing: date, in: .current)
    }
}

extension MinuteOfDay {
    var editorDate: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(
            year: 2001,
            month: 1,
            day: 1,
            hour: value / 60,
            minute: value % 60
        ))!
    }

    static func editorMinute(containing date: Date) -> MinuteOfDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return MinuteOfDay(hour: components.hour ?? 9, minute: components.minute ?? 0)!
    }
}
