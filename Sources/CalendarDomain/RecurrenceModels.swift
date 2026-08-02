import Foundation

public struct WeeklySeries: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var kind: ItemKind
    public var title: String
    public var categoryID: UUID
    public var startDate: CalendarDate
    public var endDate: CalendarDate?
    public var weekdays: Set<Weekday>
    public var timeRange: LocalTimeRange?
    public var creationTimeZoneIdentifier: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        kind: ItemKind,
        title: String,
        categoryID: UUID,
        startDate: CalendarDate,
        endDate: CalendarDate?,
        weekdays: Set<Weekday>,
        timeRange: LocalTimeRange?,
        creationTimeZoneIdentifier: String = TimeZone.current.identifier,
        createdAt: Date,
        updatedAt: Date
    ) throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw DomainValidationError.emptyTitle
        }
        guard !weekdays.isEmpty else {
            throw DomainValidationError.emptyWeekdaySet
        }
        guard TimeZone(identifier: creationTimeZoneIdentifier) != nil else {
            throw DomainValidationError.invalidTimeZoneIdentifier
        }
        if let endDate {
            guard endDate >= startDate else {
                throw DomainValidationError.invalidRecurrenceEnd
            }
            guard Self.hasMatchingWeekday(
                between: startDate,
                and: endDate,
                weekdays: weekdays
            ) else {
                throw DomainValidationError.noOccurrenceInRange
            }
        }

        self.id = id
        self.kind = kind
        self.title = trimmedTitle
        self.categoryID = categoryID
        self.startDate = startDate
        self.endDate = endDate
        self.weekdays = weekdays
        self.timeRange = timeRange
        self.creationTimeZoneIdentifier = creationTimeZoneIdentifier
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let kind = try container.decode(ItemKind.self, forKey: .kind)
        let title = try container.decode(String.self, forKey: .title)
        let categoryID = try container.decode(UUID.self, forKey: .categoryID)
        let startDate = try container.decode(CalendarDate.self, forKey: .startDate)
        let endDate = try container.decodeIfPresent(CalendarDate.self, forKey: .endDate)
        let weekdays = try container.decode(Set<Weekday>.self, forKey: .weekdays)
        let timeRange = try container.decodeIfPresent(LocalTimeRange.self, forKey: .timeRange)
        let creationTimeZoneIdentifier = try container.decode(String.self, forKey: .creationTimeZoneIdentifier)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let updatedAt = try container.decode(Date.self, forKey: .updatedAt)

        do {
            try self.init(
                id: id,
                kind: kind,
                title: title,
                categoryID: categoryID,
                startDate: startDate,
                endDate: endDate,
                weekdays: weekdays,
                timeRange: timeRange,
                creationTimeZoneIdentifier: creationTimeZoneIdentifier,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .title,
                in: container,
                debugDescription: "WeeklySeries violates its persisted-domain invariants."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encode(categoryID, forKey: .categoryID)
        try container.encode(startDate, forKey: .startDate)
        try container.encodeIfPresent(endDate, forKey: .endDate)
        try container.encode(weekdays, forKey: .weekdays)
        try container.encodeIfPresent(timeRange, forKey: .timeRange)
        try container.encode(creationTimeZoneIdentifier, forKey: .creationTimeZoneIdentifier)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    private static func hasMatchingWeekday(
        between startDate: CalendarDate,
        and endDate: CalendarDate,
        weekdays: Set<Weekday>
    ) -> Bool {
        var date = startDate
        while date <= endDate {
            if weekdays.contains(date.weekday) {
                return true
            }
            date = date.addingDays(1)
        }
        return false
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case categoryID
        case startDate
        case endDate
        case weekdays
        case timeRange
        case creationTimeZoneIdentifier
        case createdAt
        case updatedAt
    }
}

public struct OccurrenceKey: Codable, Hashable, Sendable {
    public let seriesID: UUID
    public let originalDate: CalendarDate

    public init(seriesID: UUID, originalDate: CalendarDate) {
        self.seriesID = seriesID
        self.originalDate = originalDate
    }
}

public enum OccurrenceExceptionKind: Codable, Equatable, Sendable {
    case skipped
    case modified(OccurrenceOverride)
}

public struct OccurrenceOverride: Codable, Equatable, Sendable {
    public var displayedDate: CalendarDate
    public var title: String
    public var kind: ItemKind
    public var categoryID: UUID
    public var timeRange: LocalTimeRange?

    public init(
        displayedDate: CalendarDate,
        title: String,
        kind: ItemKind,
        categoryID: UUID,
        timeRange: LocalTimeRange?
    ) {
        self.displayedDate = displayedDate
        self.title = title
        self.kind = kind
        self.categoryID = categoryID
        self.timeRange = timeRange
    }
}

public struct OccurrenceCompletion: Codable, Equatable, Sendable {
    public let key: OccurrenceKey
    public var completedAt: Date

    public init(key: OccurrenceKey, completedAt: Date) {
        self.key = key
        self.completedAt = completedAt
    }
}

public struct CalendarOccurrence: Identifiable, Equatable, Sendable {
    public let key: OccurrenceKey
    public let displayedDate: CalendarDate
    public let title: String
    public let kind: ItemKind
    public let categoryID: UUID
    public let timeRange: LocalTimeRange?
    public let creationTimeZoneIdentifier: String
    public let completedAt: Date?
    public let createdAt: Date

    public var id: OccurrenceKey { key }

    public init(
        key: OccurrenceKey,
        displayedDate: CalendarDate,
        title: String,
        kind: ItemKind,
        categoryID: UUID,
        timeRange: LocalTimeRange?,
        creationTimeZoneIdentifier: String,
        completedAt: Date?,
        createdAt: Date
    ) {
        self.key = key
        self.displayedDate = displayedDate
        self.title = title
        self.kind = kind
        self.categoryID = categoryID
        self.timeRange = timeRange
        self.creationTimeZoneIdentifier = creationTimeZoneIdentifier
        self.completedAt = completedAt
        self.createdAt = createdAt
    }
}
