import Foundation

public struct TimelineProjection: Equatable, Sendable {
    public let entries: [ProjectedEntry]

    public init(entries: [ProjectedEntry]) {
        self.entries = entries
    }

    public static func make(
        in range: CalendarDateRange,
        state: CalendarState,
        hiddenCategoryIDs: Set<UUID>
    ) -> TimelineProjection {
        let itemEntries = state.items.values.compactMap { item -> ProjectedEntry? in
            guard range.intersects(item.schedule), !hiddenCategoryIDs.contains(item.categoryID) else {
                return nil
            }
            return .item(item)
        }

        let occurrenceEntries = state.recurrence.series.values.flatMap { series in
            RecurrenceEngine.occurrences(
                of: series,
                in: range,
                exceptions: state.recurrence.exceptions,
                completions: state.recurrence.completions
            )
            .filter { !hiddenCategoryIDs.contains($0.categoryID) }
            .map(ProjectedEntry.occurrence)
        }

        return TimelineProjection(entries: (itemEntries + occurrenceEntries).sorted(by: projectedEntryPrecedes))
    }
}

public enum ProjectedEntryID: Hashable, Sendable {
    case item(UUID)
    case occurrence(OccurrenceKey)
}

public enum ProjectedEntry: Identifiable, Equatable, Sendable {
    case item(CalendarItem)
    case occurrence(CalendarOccurrence)

    public var id: ProjectedEntryID {
        switch self {
        case let .item(item): .item(item.id)
        case let .occurrence(occurrence): .occurrence(occurrence.key)
        }
    }

    public var schedule: CalendarSchedule {
        switch self {
        case let .item(item): item.schedule
        case let .occurrence(occurrence): occurrence.schedule
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

    public var notes: String {
        switch self {
        case let .item(item): item.notes
        case let .occurrence(occurrence): occurrence.notes
        }
    }
}

private extension CalendarDateRange {
    func intersects(_ schedule: CalendarSchedule) -> Bool {
        schedule.startDate <= end && start <= schedule.endDate
    }
}

private func projectedEntryPrecedes(_ lhs: ProjectedEntry, _ rhs: ProjectedEntry) -> Bool {
    // Pin first, then priority (P0 → none), then schedule time, else creation time.
    if lhs.isPinned != rhs.isPinned {
        return lhs.isPinned && !rhs.isPinned
    }
    if lhs.priority != rhs.priority {
        return lhs.priority < rhs.priority
    }

    let leftIsMultiDay = lhs.schedule.durationDays > 1
    let rightIsMultiDay = rhs.schedule.durationDays > 1
    if leftIsMultiDay != rightIsMultiDay {
        return leftIsMultiDay
    }

    switch (lhs.schedule.startTime, rhs.schedule.startTime) {
    case (nil, .some):
        // All-day / untimed stay above timed blocks (month density reading).
        return true
    case (.some, nil):
        return false
    case let (.some(left), .some(right)) where left != right:
        return left < right
    default:
        break
    }

    if lhs.createdAt != rhs.createdAt {
        return lhs.createdAt < rhs.createdAt
    }
    return stableProjectedEntryID(lhs.id) < stableProjectedEntryID(rhs.id)
}

private func stableProjectedEntryID(_ id: ProjectedEntryID) -> String {
    switch id {
    case let .item(itemID):
        return "item:\(itemID.uuidString)"
    case let .occurrence(key):
        return "occurrence:\(key.seriesID.uuidString):\(stableDate(key.originalDate))"
    }
}

private func stableDate(_ date: CalendarDate) -> String {
    String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
}
