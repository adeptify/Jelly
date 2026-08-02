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

        for item in state.items.values where range.contains(item.date) {
            guard !hiddenCategoryIDs.contains(item.categoryID) else {
                continue
            }
            entriesByDate[item.date, default: []].append(.item(item))
        }

        for series in state.recurrence.series.values {
            let occurrences = RecurrenceEngine.occurrences(
                of: series,
                in: range,
                exceptions: state.recurrence.exceptions,
                completions: state.recurrence.completions
            )
            for occurrence in occurrences where !hiddenCategoryIDs.contains(occurrence.categoryID) {
                entriesByDate[occurrence.displayedDate, default: []].append(.occurrence(occurrence))
            }
        }

        return MonthProjection(days: cellDates.map { cellDate in
            ProjectedDay(
                date: cellDate,
                items: entriesByDate[cellDate, default: []].sorted(by: projectedItemPrecedes)
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
            return "occurrence:\(occurrence.key.seriesID.uuidString):\(stableDate(occurrence.key.originalDate))"
        }
    }

    public var displayedDate: CalendarDate {
        switch self {
        case let .item(item): item.date
        case let .occurrence(occurrence): occurrence.displayedDate
        }
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
        switch self {
        case let .item(item): item.timeRange
        case let .occurrence(occurrence): occurrence.timeRange
        }
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
}

private extension CalendarDateRange {
    func contains(_ date: CalendarDate) -> Bool {
        start <= date && date <= end
    }
}

private func projectedItemPrecedes(_ lhs: ProjectedItem, _ rhs: ProjectedItem) -> Bool {
    switch (lhs.timeRange, rhs.timeRange) {
    case (nil, .some):
        return true
    case (.some, nil):
        return false
    case let (.some(left), .some(right)) where left.start != right.start:
        return left.start < right.start
    default:
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id < rhs.id
    }
}

private func stableDate(_ date: CalendarDate) -> String {
    String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
}
