import Foundation

public struct MonthProjection: Equatable, Sendable {
    public let days: [ProjectedDay]

    public static func make(
        monthContaining date: CalendarDate,
        state: CalendarState,
        hiddenCategoryIDs: Set<UUID>
    ) -> MonthProjection {
        let firstOfMonth = CalendarDate(year: date.year, month: date.month, day: 1)!
        let firstCell = firstOfMonth.addingDays(-(firstOfMonth.weekday.rawValue - 1))
        let cellDates = (0..<42).map { firstCell.addingDays($0) }
        let range = CalendarDateRange(start: firstCell, end: cellDates[cellDates.count - 1])
        var entriesByDate = Dictionary(uniqueKeysWithValues: cellDates.map { ($0, [ProjectedItem]()) })

        for entry in TimelineProjection.make(
            in: range,
            state: state,
            hiddenCategoryIDs: hiddenCategoryIDs
        ).entries {
            let displayDate = max(entry.schedule.startDate, range.start)
            entriesByDate[displayDate, default: []].append(entry.monthProjectedItem)
        }

        return MonthProjection(days: cellDates.map { cellDate in
            ProjectedDay(
                date: cellDate,
                items: entriesByDate[cellDate, default: []]
            )
        })
    }

    public func day(_ date: CalendarDate) -> ProjectedDay {
        days.first(where: { $0.date == date }) ?? ProjectedDay(date: date, items: [])
    }
}

public struct ProjectedDay: Equatable, Sendable {
    public let date: CalendarDate
    public let items: [ProjectedItem]

    public init(date: CalendarDate, items: [ProjectedItem]) {
        self.date = date
        self.items = items
    }
}

public enum ProjectedItem: Identifiable, Equatable, Sendable {
    case item(CalendarItem)
    case occurrence(CalendarOccurrence)

    public var id: String {
        switch self {
        case let .item(item):
            return "item:\(item.id.uuidString)"
        case let .occurrence(occurrence):
            return "occurrence:\(occurrence.key.seriesID.uuidString):\(monthStableDate(occurrence.key.originalDate))"
        }
    }

    public var displayedDate: CalendarDate {
        schedule.startDate
    }

    public var title: String {
        switch self {
        case let .item(item): item.title
        case let .occurrence(occurrence): occurrence.title
        }
    }

    public var kind: ItemKind {
        switch self {
        case let .item(item): item.kind
        case let .occurrence(occurrence): occurrence.kind
        }
    }

    public var categoryID: UUID {
        switch self {
        case let .item(item): item.categoryID
        case let .occurrence(occurrence): occurrence.categoryID
        }
    }

    public var timeRange: LocalTimeRange? {
        guard let startTime = schedule.startTime, let endTime = schedule.endTime else {
            return nil
        }
        return try? LocalTimeRange(start: startTime, end: endTime)
    }

    public var creationTimeZoneIdentifier: String {
        switch self {
        case let .item(item): item.creationTimeZoneIdentifier
        case let .occurrence(occurrence): occurrence.creationTimeZoneIdentifier
        }
    }

    public var completedAt: Date? {
        switch self {
        case let .item(item): item.completedAt
        case let .occurrence(occurrence): occurrence.completedAt
        }
    }

    public var createdAt: Date {
        switch self {
        case let .item(item): item.createdAt
        case let .occurrence(occurrence): occurrence.createdAt
        }
    }

    public var schedule: CalendarSchedule {
        switch self {
        case let .item(item): item.schedule
        case let .occurrence(occurrence): occurrence.schedule
        }
    }
}

private extension ProjectedEntry {
    var monthProjectedItem: ProjectedItem {
        switch self {
        case let .item(item): .item(item)
        case let .occurrence(occurrence): .occurrence(occurrence)
        }
    }
}

private func monthStableDate(_ date: CalendarDate) -> String {
    String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
}
