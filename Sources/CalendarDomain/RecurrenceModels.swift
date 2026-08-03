import Foundation

public struct WeeklySeries: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var kind: ItemKind
    public var title: String
    public var categoryID: UUID
    public var ruleStartDate: CalendarDate
    public var recurrenceEndDate: CalendarDate?
    public var weekdays: Set<Weekday>
    public var durationDays: Int
    public var startTime: MinuteOfDay?
    public var endTime: MinuteOfDay?
    public var creationTimeZoneIdentifier: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        kind: ItemKind,
        title: String,
        categoryID: UUID,
        ruleStartDate: CalendarDate,
        recurrenceEndDate: CalendarDate?,
        weekdays: Set<Weekday>,
        durationDays: Int,
        startTime: MinuteOfDay?,
        endTime: MinuteOfDay?,
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
        guard durationDays >= 1 else {
            throw DomainValidationError.invalidDateRange
        }
        guard TimeZone(identifier: creationTimeZoneIdentifier) != nil else {
            throw DomainValidationError.invalidTimeZoneIdentifier
        }
        if let recurrenceEndDate {
            guard recurrenceEndDate >= ruleStartDate else {
                throw DomainValidationError.invalidRecurrenceEnd
            }
            guard Self.hasMatchingWeekday(
                between: ruleStartDate,
                and: recurrenceEndDate,
                weekdays: weekdays
            ) else {
                throw DomainValidationError.noOccurrenceInRange
            }
        }
        _ = try CalendarSchedule(
            startDate: ruleStartDate,
            endDate: ruleStartDate.addingDays(durationDays - 1),
            startTime: startTime,
            endTime: endTime
        )

        self.id = id
        self.kind = kind
        self.title = trimmedTitle
        self.categoryID = categoryID
        self.ruleStartDate = ruleStartDate
        self.recurrenceEndDate = recurrenceEndDate
        self.weekdays = weekdays
        self.durationDays = durationDays
        self.startTime = startTime
        self.endTime = endTime
        self.creationTimeZoneIdentifier = creationTimeZoneIdentifier
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    @available(*, deprecated, message: "Use the V2 schedule fields instead.")
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
        try self.init(
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

    @available(*, deprecated, message: "Use ruleStartDate instead.")
    public var startDate: CalendarDate { ruleStartDate }

    @available(*, deprecated, message: "Use recurrenceEndDate instead.")
    public var endDate: CalendarDate? { recurrenceEndDate }

    @available(*, deprecated, message: "Use startTime and endTime instead.")
    public var timeRange: LocalTimeRange? {
        guard let startTime, let endTime else {
            return nil
        }
        return try? LocalTimeRange(start: startTime, end: endTime)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let kind = try container.decode(ItemKind.self, forKey: .kind)
        let title = try container.decode(String.self, forKey: .title)
        let categoryID = try container.decode(UUID.self, forKey: .categoryID)
        guard ![CodingKeys.startDate, .endDate, .timeRange].contains(where: container.contains) else {
            throw DecodingError.dataCorruptedError(
                forKey: .ruleStartDate,
                in: container,
                debugDescription: "WeeklySeries schema 2 cannot contain schema 1 schedule fields."
            )
        }
        let ruleStartDate = try container.decode(CalendarDate.self, forKey: .ruleStartDate)
        let recurrenceEndDate = try container.decodeIfPresent(CalendarDate.self, forKey: .recurrenceEndDate)
        let durationDays = try container.decode(Int.self, forKey: .durationDays)
        let startTime = try container.decodeIfPresent(MinuteOfDay.self, forKey: .startTime)
        let endTime = try container.decodeIfPresent(MinuteOfDay.self, forKey: .endTime)
        let weekdays = try container.decode(Set<Weekday>.self, forKey: .weekdays)
        let creationTimeZoneIdentifier = try container.decode(String.self, forKey: .creationTimeZoneIdentifier)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let updatedAt = try container.decode(Date.self, forKey: .updatedAt)

        do {
            try self.init(
                id: id,
                kind: kind,
                title: title,
                categoryID: categoryID,
                ruleStartDate: ruleStartDate,
                recurrenceEndDate: recurrenceEndDate,
                weekdays: weekdays,
                durationDays: durationDays,
                startTime: startTime,
                endTime: endTime,
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
        try container.encode(ruleStartDate, forKey: .ruleStartDate)
        try container.encodeIfPresent(recurrenceEndDate, forKey: .recurrenceEndDate)
        try container.encode(weekdays, forKey: .weekdays)
        try container.encode(durationDays, forKey: .durationDays)
        try container.encodeIfPresent(startTime, forKey: .startTime)
        try container.encodeIfPresent(endTime, forKey: .endTime)
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
        case ruleStartDate
        case recurrenceEndDate
        case weekdays
        case durationDays
        case startTime
        case endTime
        case creationTimeZoneIdentifier
        case createdAt
        case updatedAt
        case startDate
        case endDate
        case timeRange
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
    public var displayedSchedule: CalendarSchedule
    public var title: String
    public var kind: ItemKind
    public var categoryID: UUID

    public init(
        displayedSchedule: CalendarSchedule,
        title: String,
        kind: ItemKind,
        categoryID: UUID
    ) {
        self.displayedSchedule = displayedSchedule
        self.title = title
        self.kind = kind
        self.categoryID = categoryID
    }

    @available(*, deprecated, message: "Use displayedSchedule instead.")
    public init(
        displayedDate: CalendarDate,
        title: String,
        kind: ItemKind,
        categoryID: UUID,
        timeRange: LocalTimeRange?
    ) {
        self.init(
            displayedSchedule: try! CalendarSchedule(
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

    @available(*, deprecated, message: "Use displayedSchedule.startDate instead.")
    public var displayedDate: CalendarDate { displayedSchedule.startDate }

    @available(*, deprecated, message: "Use displayedSchedule.startTime and displayedSchedule.endTime instead.")
    public var timeRange: LocalTimeRange? {
        guard let startTime = displayedSchedule.startTime,
              let endTime = displayedSchedule.endTime else {
            return nil
        }
        return try? LocalTimeRange(start: startTime, end: endTime)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let title = try container.decode(String.self, forKey: .title)
        let kind = try container.decode(ItemKind.self, forKey: .kind)
        let categoryID = try container.decode(UUID.self, forKey: .categoryID)
        guard ![CodingKeys.displayedDate, .timeRange].contains(where: container.contains) else {
            throw DecodingError.dataCorruptedError(
                forKey: .displayedSchedule,
                in: container,
                debugDescription: "OccurrenceOverride schema 2 cannot contain schema 1 schedule fields."
            )
        }
        let displayedSchedule = try container.decode(CalendarSchedule.self, forKey: .displayedSchedule)
        self.init(
            displayedSchedule: displayedSchedule,
            title: title,
            kind: kind,
            categoryID: categoryID
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(displayedSchedule, forKey: .displayedSchedule)
        try container.encode(title, forKey: .title)
        try container.encode(kind, forKey: .kind)
        try container.encode(categoryID, forKey: .categoryID)
    }

    private enum CodingKeys: String, CodingKey {
        case displayedSchedule
        case title
        case kind
        case categoryID
        case displayedDate
        case timeRange
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
    public let schedule: CalendarSchedule
    public let title: String
    public let kind: ItemKind
    public let categoryID: UUID
    public let creationTimeZoneIdentifier: String
    public let completedAt: Date?
    public let createdAt: Date

    public var id: OccurrenceKey { key }

    public init(
        key: OccurrenceKey,
        schedule: CalendarSchedule,
        title: String,
        kind: ItemKind,
        categoryID: UUID,
        creationTimeZoneIdentifier: String,
        completedAt: Date?,
        createdAt: Date
    ) {
        self.key = key
        self.schedule = schedule
        self.title = title
        self.kind = kind
        self.categoryID = categoryID
        self.creationTimeZoneIdentifier = creationTimeZoneIdentifier
        self.completedAt = completedAt
        self.createdAt = createdAt
    }

    @available(*, deprecated, message: "Use the schedule initializer instead.")
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
        self.init(
            key: key,
            schedule: try! CalendarSchedule(
                startDate: displayedDate,
                endDate: displayedDate,
                startTime: timeRange?.start,
                endTime: timeRange?.end
            ),
            title: title,
            kind: kind,
            categoryID: categoryID,
            creationTimeZoneIdentifier: creationTimeZoneIdentifier,
            completedAt: completedAt,
            createdAt: createdAt
        )
    }

    @available(*, deprecated, message: "Use schedule.startDate instead.")
    public var displayedDate: CalendarDate { schedule.startDate }

    @available(*, deprecated, message: "Use schedule.startTime and schedule.endTime instead.")
    public var timeRange: LocalTimeRange? {
        guard let startTime = schedule.startTime,
              let endTime = schedule.endTime else {
            return nil
        }
        return try? LocalTimeRange(start: startTime, end: endTime)
    }
}
