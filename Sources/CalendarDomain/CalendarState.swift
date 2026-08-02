import Foundation

public struct CalendarState: Codable, Equatable, Sendable {
    public var categories: [UUID: CalendarCategory]
    public var items: [UUID: CalendarItem]
    public var recurrence: RecurrenceGraph
    public let uncategorizedID: UUID

    public init(
        categories: [UUID: CalendarCategory],
        items: [UUID: CalendarItem],
        recurrence: RecurrenceGraph,
        uncategorizedID: UUID
    ) {
        self.categories = categories
        self.items = items
        self.recurrence = recurrence
        self.uncategorizedID = uncategorizedID
    }

    public static func empty(uncategorizedID: UUID, now: Date) -> CalendarState {
        let uncategorized = CalendarCategory(
            id: uncategorizedID,
            name: "未分类",
            colorHex: "#8E8E93",
            sortIndex: 0,
            createdAt: now,
            updatedAt: now
        )
        return CalendarState(
            categories: [uncategorizedID: uncategorized],
            items: [:],
            recurrence: .init(series: [:], exceptions: [:], completions: [:]),
            uncategorizedID: uncategorizedID
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = CalendarState(
            categories: try container.decode([UUID: CalendarCategory].self, forKey: .categories),
            items: try container.decode([UUID: CalendarItem].self, forKey: .items),
            recurrence: try container.decode(RecurrenceGraph.self, forKey: .recurrence),
            uncategorizedID: try container.decode(UUID.self, forKey: .uncategorizedID)
        )
        do {
            try CalendarStateValidator.validate(state)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .categories,
                in: container,
                debugDescription: "CalendarState violates its persisted-domain invariants."
            )
        }
        self = state
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(categories, forKey: .categories)
        try container.encode(items, forKey: .items)
        try container.encode(recurrence, forKey: .recurrence)
        try container.encode(uncategorizedID, forKey: .uncategorizedID)
    }

    private enum CodingKeys: String, CodingKey {
        case categories
        case items
        case recurrence
        case uncategorizedID
    }
}
