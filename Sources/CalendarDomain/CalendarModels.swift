import Foundation

public enum ItemKind: String, Codable, Equatable, Hashable, Sendable {
    case task
    case event
}

public enum DomainValidationError: Error, Equatable, Sendable {
    case invalidTimeRange
    case emptyTitle
    case eventCannotComplete
    case invalidTimeZoneIdentifier
    case emptyWeekdaySet
    case invalidRecurrenceEnd
    case noOccurrenceInRange
}

public struct CalendarCategory: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var colorHex: String
    public var sortIndex: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        name: String,
        colorHex: String,
        sortIndex: Int,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct CalendarItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var kind: ItemKind
    public var title: String
    public var categoryID: UUID
    public var date: CalendarDate
    public var timeRange: LocalTimeRange?
    public var creationTimeZoneIdentifier: String
    public var completedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        kind: ItemKind,
        title: String,
        categoryID: UUID,
        date: CalendarDate,
        timeRange: LocalTimeRange?,
        creationTimeZoneIdentifier: String = TimeZone.current.identifier,
        completedAt: Date?,
        createdAt: Date,
        updatedAt: Date
    ) throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw DomainValidationError.emptyTitle
        }
        guard TimeZone(identifier: creationTimeZoneIdentifier) != nil else {
            throw DomainValidationError.invalidTimeZoneIdentifier
        }
        guard kind != .event || completedAt == nil else {
            throw DomainValidationError.eventCannotComplete
        }

        self.id = id
        self.kind = kind
        self.title = trimmedTitle
        self.categoryID = categoryID
        self.date = date
        self.timeRange = timeRange
        self.creationTimeZoneIdentifier = creationTimeZoneIdentifier
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let kind = try container.decode(ItemKind.self, forKey: .kind)
        let title = try container.decode(String.self, forKey: .title)
        let categoryID = try container.decode(UUID.self, forKey: .categoryID)
        let date = try container.decode(CalendarDate.self, forKey: .date)
        let timeRange = try container.decodeIfPresent(LocalTimeRange.self, forKey: .timeRange)
        let creationTimeZoneIdentifier = try container.decode(String.self, forKey: .creationTimeZoneIdentifier)
        let completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let updatedAt = try container.decode(Date.self, forKey: .updatedAt)

        do {
            try self.init(
                id: id,
                kind: kind,
                title: title,
                categoryID: categoryID,
                date: date,
                timeRange: timeRange,
                creationTimeZoneIdentifier: creationTimeZoneIdentifier,
                completedAt: completedAt,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .title,
                in: container,
                debugDescription: "CalendarItem violates its persisted-domain invariants."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encode(categoryID, forKey: .categoryID)
        try container.encode(date, forKey: .date)
        try container.encodeIfPresent(timeRange, forKey: .timeRange)
        try container.encode(creationTimeZoneIdentifier, forKey: .creationTimeZoneIdentifier)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case categoryID
        case date
        case timeRange
        case creationTimeZoneIdentifier
        case completedAt
        case createdAt
        case updatedAt
    }
}
