import CalendarDomain
import Foundation
import Testing

@Suite("ItemPrioritySortTests")
struct ItemPrioritySortTests {
    @Test func projectionOrdersPinnedThenPriorityThenScheduleTimeThenCreatedAt() throws {
        let category = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
        let day = CalendarDate(year: 2026, month: 8, day: 10)!
        func item(
            id: String,
            title: String,
            start: MinuteOfDay?,
            priority: ItemPriority,
            pinned: Bool,
            created: TimeInterval
        ) throws -> CalendarItem {
            try CalendarItem(
                id: UUID(uuidString: id)!,
                kind: .task,
                title: title,
                categoryID: category,
                schedule: try CalendarSchedule(
                    startDate: day,
                    endDate: day,
                    startTime: start,
                    endTime: start.map { MinuteOfDay(hour: ($0.value / 60), minute: min(59, $0.value % 60 + 30))! }
                        ?? nil
                ),
                priority: priority,
                isPinned: pinned,
                completedAt: nil,
                createdAt: Date(timeIntervalSince1970: created),
                updatedAt: Date(timeIntervalSince1970: created)
            )
        }

        // Fix end times properly for timed items
        let pinned = try CalendarItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000510")!,
            kind: .task,
            title: "置顶",
            categoryID: category,
            schedule: try CalendarSchedule(
                startDate: day, endDate: day,
                startTime: MinuteOfDay(hour: 15, minute: 0)!,
                endTime: MinuteOfDay(hour: 16, minute: 0)!
            ),
            priority: .p0,
            isPinned: true,
            completedAt: nil,
            createdAt: Date(timeIntervalSince1970: 9),
            updatedAt: Date(timeIntervalSince1970: 9)
        )
        let p0 = try CalendarItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000511")!,
            kind: .task,
            title: "P0",
            categoryID: category,
            schedule: try CalendarSchedule(
                startDate: day, endDate: day,
                startTime: MinuteOfDay(hour: 14, minute: 0)!,
                endTime: MinuteOfDay(hour: 15, minute: 0)!
            ),
            priority: .p0,
            isPinned: false,
            completedAt: nil,
            createdAt: Date(timeIntervalSince1970: 8),
            updatedAt: Date(timeIntervalSince1970: 8)
        )
        let morning = try CalendarItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000512")!,
            kind: .task,
            title: "早会",
            categoryID: category,
            schedule: try CalendarSchedule(
                startDate: day, endDate: day,
                startTime: MinuteOfDay(hour: 9, minute: 0)!,
                endTime: MinuteOfDay(hour: 10, minute: 0)!
            ),
            priority: .none,
            isPinned: false,
            completedAt: nil,
            createdAt: Date(timeIntervalSince1970: 5),
            updatedAt: Date(timeIntervalSince1970: 5)
        )
        let untimedOld = try CalendarItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000513")!,
            kind: .task,
            title: "旧全天",
            categoryID: category,
            schedule: try CalendarSchedule(startDate: day, endDate: day, startTime: nil, endTime: nil),
            priority: .none,
            isPinned: false,
            completedAt: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let untimedNew = try CalendarItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000514")!,
            kind: .task,
            title: "新全天",
            categoryID: category,
            schedule: try CalendarSchedule(startDate: day, endDate: day, startTime: nil, endTime: nil),
            priority: .none,
            isPinned: false,
            completedAt: nil,
            createdAt: Date(timeIntervalSince1970: 3),
            updatedAt: Date(timeIntervalSince1970: 3)
        )

        var state = CalendarState.empty(
            uncategorizedID: category,
            now: Date(timeIntervalSince1970: 0)
        )
        state.categories[category] = CalendarCategory(
            id: category, name: "未分类", colorHex: "#8E8E93", sortIndex: 0,
            createdAt: .distantPast, updatedAt: .distantPast
        )
        for entry in [pinned, p0, morning, untimedOld, untimedNew] {
            state.items[entry.id] = entry
        }

        let projection = TimelineProjection.make(
            in: CalendarDateRange(start: day, end: day),
            state: state,
            hiddenCategoryIDs: []
        )
        let titles = projection.entries.map(\.title)
        // pin → priority → untimed (by createdAt) → timed (by clock)
        #expect(titles == ["置顶", "P0", "旧全天", "新全天", "早会"])
    }
}
