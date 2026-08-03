import CalendarDomain
import Foundation

struct ItemDraft: Equatable {
    var kind: ItemKind
    var title: String
    var categoryID: UUID
    var startDate: CalendarDate
    var endDate: CalendarDate
    var usesTime: Bool
    var startTime: MinuteOfDay
    var endTime: MinuteOfDay
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
            startDate: item.schedule.startDate,
            endDate: item.schedule.endDate,
            usesTime: item.schedule.startTime != nil,
            startTime: item.schedule.startTime ?? MinuteOfDay(hour: 9, minute: 0)!,
            endTime: item.schedule.endTime ?? MinuteOfDay(hour: 10, minute: 0)!,
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
            startDate: date,
            endDate: date.addingDays(series.durationDays - 1),
            usesTime: series.startTime != nil,
            startTime: series.startTime ?? MinuteOfDay(hour: 9, minute: 0)!,
            endTime: series.endTime ?? MinuteOfDay(hour: 10, minute: 0)!,
            repeatsWeekly: true,
            weekdays: series.weekdays,
            recurrenceEndDate: series.recurrenceEndDate
        )
    }

    init(occurrence: CalendarOccurrence, series: WeeklySeries) {
        self.init(
            kind: occurrence.kind,
            title: occurrence.title,
            categoryID: occurrence.categoryID,
            startDate: occurrence.schedule.startDate,
            endDate: occurrence.schedule.endDate,
            usesTime: occurrence.schedule.startTime != nil,
            startTime: occurrence.schedule.startTime ?? MinuteOfDay(hour: 9, minute: 0)!,
            endTime: occurrence.schedule.endTime ?? MinuteOfDay(hour: 10, minute: 0)!,
            repeatsWeekly: true,
            weekdays: series.weekdays,
            recurrenceEndDate: series.recurrenceEndDate
        )
    }

    static func newItem(
        from startDate: CalendarDate,
        through endDate: CalendarDate,
        categoryID: UUID
    ) -> ItemDraft {
        ItemDraft(
            kind: .task,
            title: "",
            categoryID: categoryID,
            startDate: startDate,
            endDate: endDate,
            usesTime: false,
            startTime: MinuteOfDay(hour: 9, minute: 0)!,
            endTime: MinuteOfDay(hour: 10, minute: 0)!,
            repeatsWeekly: false,
            weekdays: [startDate.weekday],
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
