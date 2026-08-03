import CalendarDomain
import Foundation

struct V1CalendarDocument: Decodable {
    let schemaVersion: Int
    let state: V1CalendarStateDTO

    func migratedState() throws -> CalendarState {
        let categories = Dictionary(
            uniqueKeysWithValues: state.categories.map { key, category in
                (key, category.migrated())
            }
        )
        let items = try Dictionary(
            uniqueKeysWithValues: state.items.map { key, item in
                (key, try item.migrated())
            }
        )
        let series = try Dictionary(
            uniqueKeysWithValues: state.recurrence.series.map { key, value in
                (key, try value.migrated())
            }
        )
        let exceptions = try Dictionary(
            uniqueKeysWithValues: state.recurrence.exceptions.map { key, value in
                (key.migrated(), try value.migrated())
            }
        )
        let completions = Dictionary(
            uniqueKeysWithValues: state.recurrence.completions.map { key, value in
                (key.migrated(), value.migrated())
            }
        )
        return CalendarState(
            categories: categories,
            items: items,
            recurrence: RecurrenceGraph(
                series: series,
                exceptions: exceptions,
                completions: completions
            ),
            uncategorizedID: state.uncategorizedID
        )
    }
}

struct V1CalendarStateDTO: Decodable {
    let categories: [UUID: V1CalendarCategoryDTO]
    let items: [UUID: V1CalendarItemDTO]
    let recurrence: V1RecurrenceGraphDTO
    let uncategorizedID: UUID
}

struct V1CalendarCategoryDTO: Decodable {
    let id: UUID
    let name: String
    let colorHex: String
    let sortIndex: Int
    let createdAt: Date
    let updatedAt: Date

    func migrated() -> CalendarCategory {
        CalendarCategory(
            id: id,
            name: name,
            colorHex: colorHex,
            sortIndex: sortIndex,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

struct V1CalendarItemDTO: Decodable {
    let id: UUID
    let kind: ItemKind
    let title: String
    let categoryID: UUID
    let date: CalendarDate
    let timeRange: LocalTimeRange?
    let creationTimeZoneIdentifier: String
    let completedAt: Date?
    let createdAt: Date
    let updatedAt: Date

    func migrated() throws -> CalendarItem {
        try CalendarItem(
            id: id,
            kind: kind,
            title: title,
            categoryID: categoryID,
            schedule: CalendarSchedule(
                startDate: date,
                endDate: date,
                startTime: timeRange?.start,
                endTime: timeRange?.end
            ),
            creationTimeZoneIdentifier: creationTimeZoneIdentifier,
            completedAt: completedAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

struct V1RecurrenceGraphDTO: Decodable {
    let series: [UUID: V1WeeklySeriesDTO]
    let exceptions: [V1OccurrenceKeyDTO: V1OccurrenceExceptionKindDTO]
    let completions: [V1OccurrenceKeyDTO: V1OccurrenceCompletionDTO]
}

struct V1WeeklySeriesDTO: Decodable {
    let id: UUID
    let kind: ItemKind
    let title: String
    let categoryID: UUID
    let startDate: CalendarDate
    let endDate: CalendarDate?
    let weekdays: Set<Weekday>
    let timeRange: LocalTimeRange?
    let creationTimeZoneIdentifier: String
    let createdAt: Date
    let updatedAt: Date

    func migrated() throws -> WeeklySeries {
        try WeeklySeries(
            id: id,
            kind: kind,
            title: title,
            categoryID: categoryID,
            ruleStartDate: startDate,
            recurrenceEndDate: endDate,
            weekdays: weekdays,
            durationDays: 1,
            startTime: timeRange?.start,
            endTime: timeRange?.end,
            creationTimeZoneIdentifier: creationTimeZoneIdentifier,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

struct V1OccurrenceKeyDTO: Decodable, Hashable {
    let seriesID: UUID
    let originalDate: CalendarDate

    func migrated() -> OccurrenceKey {
        OccurrenceKey(seriesID: seriesID, originalDate: originalDate)
    }
}

enum V1OccurrenceExceptionKindDTO: Decodable {
    case skipped
    case modified(V1OccurrenceOverrideDTO)

    func migrated() throws -> OccurrenceExceptionKind {
        switch self {
        case .skipped:
            .skipped
        case let .modified(override):
            .modified(try override.migrated())
        }
    }
}

struct V1OccurrenceOverrideDTO: Decodable {
    let displayedDate: CalendarDate
    let title: String
    let kind: ItemKind
    let categoryID: UUID
    let timeRange: LocalTimeRange?

    func migrated() throws -> OccurrenceOverride {
        OccurrenceOverride(
            displayedSchedule: try CalendarSchedule(
                startDate: displayedDate,
                endDate: displayedDate,
                startTime: timeRange?.start,
                endTime: timeRange?.end
            ),
            title: title,
            kind: kind,
            categoryID: categoryID
        )
    }
}

struct V1OccurrenceCompletionDTO: Decodable {
    let key: V1OccurrenceKeyDTO
    let completedAt: Date

    func migrated() -> OccurrenceCompletion {
        OccurrenceCompletion(key: key.migrated(), completedAt: completedAt)
    }
}
