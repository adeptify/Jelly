import Foundation

public enum ProjectedItem: Identifiable, Equatable, Sendable {
    case item(CalendarItem)
    case occurrence(CalendarOccurrence)

    public var id: String {
        switch self {
        case let .item(item):
            "item:\(item.id.uuidString)"
        case let .occurrence(occurrence):
            "occurrence:\(occurrence.key.seriesID.uuidString):\(stableDate(occurrence.key.originalDate))"
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

    public var priority: ItemPriority {
        switch self {
        case let .item(item): item.priority
        case let .occurrence(occurrence): occurrence.priority
        }
    }

    public var isPinned: Bool {
        switch self {
        case let .item(item): item.isPinned
        case let .occurrence(occurrence): occurrence.isPinned
        }
    }
}

private func stableDate(_ date: CalendarDate) -> String {
    String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
}
