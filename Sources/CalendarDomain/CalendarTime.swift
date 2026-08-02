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
