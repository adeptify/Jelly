import Foundation

public struct CalendarDate: Codable, Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        let components = DateComponents(year: year, month: month, day: day, hour: 12)
        let calendar = Self.utcGregorianCalendar
        guard let date = calendar.date(from: components) else {
            return nil
        }

        let normalized = calendar.dateComponents([.year, .month, .day], from: date)
        guard normalized.year == year, normalized.month == month, normalized.day == day else {
            return nil
        }

        self.year = year
        self.month = month
        self.day = day
    }

    public static func localDay(containing instant: Date, in timeZone: TimeZone) -> CalendarDate {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: instant)
        return CalendarDate(
            year: components.year!,
            month: components.month!,
            day: components.day!
        )!
    }

    public func addingDays(_ count: Int) -> CalendarDate {
        let date = Self.utcGregorianCalendar.date(from: dateComponents)!
        let adjustedDate = Self.utcGregorianCalendar.date(byAdding: .day, value: count, to: date)!
        return Self.make(from: adjustedDate)
    }

    public func days(until other: CalendarDate) -> Int {
        let start = Self.utcGregorianCalendar.date(from: dateComponents)!
        let end = Self.utcGregorianCalendar.date(from: other.dateComponents)!
        return Self.utcGregorianCalendar.dateComponents([.day], from: start, to: end).day!
    }

    public var previousDay: CalendarDate {
        addingDays(-1)
    }

    public var weekday: Weekday {
        let date = Self.utcGregorianCalendar.date(from: dateComponents)!
        let gregorianWeekday = Self.utcGregorianCalendar.component(.weekday, from: date)
        return Weekday(rawValue: ((gregorianWeekday + 5) % 7) + 1)!
    }

    public static func < (lhs: CalendarDate, rhs: CalendarDate) -> Bool {
        if lhs.year != rhs.year {
            return lhs.year < rhs.year
        }
        if lhs.month != rhs.month {
            return lhs.month < rhs.month
        }
        return lhs.day < rhs.day
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let year = try container.decode(Int.self, forKey: .year)
        let month = try container.decode(Int.self, forKey: .month)
        let day = try container.decode(Int.self, forKey: .day)
        guard let date = Self(year: year, month: month, day: day) else {
            throw DecodingError.dataCorruptedError(
                forKey: .day,
                in: container,
                debugDescription: "CalendarDate contains invalid civil-day components."
            )
        }
        self = date
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(year, forKey: .year)
        try container.encode(month, forKey: .month)
        try container.encode(day, forKey: .day)
    }

    private enum CodingKeys: String, CodingKey {
        case year
        case month
        case day
    }

    private static var utcGregorianCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var dateComponents: DateComponents {
        DateComponents(year: year, month: month, day: day, hour: 12)
    }

    private static func make(from date: Date) -> CalendarDate {
        let components = utcGregorianCalendar.dateComponents([.year, .month, .day], from: date)
        return CalendarDate(
            year: components.year!,
            month: components.month!,
            day: components.day!
        )!
    }
}

public enum Weekday: Int, Codable, CaseIterable, Hashable, Sendable {
    case monday = 1
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday
    case sunday
}
