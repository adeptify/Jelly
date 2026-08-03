import Foundation

public struct MinuteOfDay: Codable, Hashable, Comparable, Sendable {
    public let value: Int

    public init?(hour: Int, minute: Int) {
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            return nil
        }
        value = hour * 60 + minute
    }

    public static func < (lhs: MinuteOfDay, rhs: MinuteOfDay) -> Bool {
        lhs.value < rhs.value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(Int.self, forKey: .value)
        guard (0..<(24 * 60)).contains(value) else {
            throw DecodingError.dataCorruptedError(
                forKey: .value,
                in: container,
                debugDescription: "MinuteOfDay value must be between 0 and 1439."
            )
        }
        self.value = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
    }

    private enum CodingKeys: String, CodingKey {
        case value
    }
}

public struct LocalTimeRange: Codable, Hashable, Sendable {
    public let start: MinuteOfDay
    public let end: MinuteOfDay

    public init(start: MinuteOfDay, end: MinuteOfDay) throws {
        guard end > start else {
            throw DomainValidationError.invalidTimeRange
        }
        self.start = start
        self.end = end
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let start = try container.decode(MinuteOfDay.self, forKey: .start)
        let end = try container.decode(MinuteOfDay.self, forKey: .end)
        do {
            try self.init(start: start, end: end)
        } catch DomainValidationError.invalidTimeRange {
            throw DecodingError.dataCorruptedError(
                forKey: .end,
                in: container,
                debugDescription: "LocalTimeRange end must be later than start."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
    }

    private enum CodingKeys: String, CodingKey {
        case start
        case end
    }
}

public struct CalendarSchedule: Codable, Equatable, Hashable, Sendable {
    public let startDate: CalendarDate
    public let endDate: CalendarDate
    public let startTime: MinuteOfDay?
    public let endTime: MinuteOfDay?

    public var durationDays: Int {
        startDate.days(until: endDate) + 1
    }

    public init(
        startDate: CalendarDate,
        endDate: CalendarDate,
        startTime: MinuteOfDay?,
        endTime: MinuteOfDay?
    ) throws {
        guard endDate >= startDate else {
            throw DomainValidationError.invalidDateRange
        }
        guard (startTime == nil) == (endTime == nil) else {
            throw DomainValidationError.invalidTimeRange
        }
        if startDate == endDate,
           let startTime,
           let endTime,
           endTime <= startTime {
            throw DomainValidationError.invalidTimeRange
        }
        self.startDate = startDate
        self.endDate = endDate
        self.startTime = startTime
        self.endTime = endTime
    }

    public func shifted(byDays delta: Int) throws -> CalendarSchedule {
        try CalendarSchedule(
            startDate: startDate.addingDays(delta),
            endDate: endDate.addingDays(delta),
            startTime: startTime,
            endTime: endTime
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let startDate = try container.decode(CalendarDate.self, forKey: .startDate)
        let endDate = try container.decode(CalendarDate.self, forKey: .endDate)
        let startTime = try container.decodeIfPresent(MinuteOfDay.self, forKey: .startTime)
        let endTime = try container.decodeIfPresent(MinuteOfDay.self, forKey: .endTime)
        do {
            try self.init(
                startDate: startDate,
                endDate: endDate,
                startTime: startTime,
                endTime: endTime
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .endDate,
                in: container,
                debugDescription: "CalendarSchedule violates its date or time-range invariants."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(startDate, forKey: .startDate)
        try container.encode(endDate, forKey: .endDate)
        try container.encodeIfPresent(startTime, forKey: .startTime)
        try container.encodeIfPresent(endTime, forKey: .endTime)
    }

    private enum CodingKeys: String, CodingKey {
        case startDate
        case endDate
        case startTime
        case endTime
    }
}
