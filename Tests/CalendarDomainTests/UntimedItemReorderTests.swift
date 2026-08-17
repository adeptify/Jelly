import Foundation
import Testing
@testable import CalendarDomain

@Suite("UntimedItemReorderTests")
struct UntimedItemReorderTests {
    @Test func onlyUntimedSingleDayItemsAreReorderable() throws {
        let day = CalendarDate(year: 2026, month: 8, day: 17)!
        let next = CalendarDate(year: 2026, month: 8, day: 18)!
        #expect(
            UntimedItemReorder.isReorderable(
                try CalendarSchedule(startDate: day, endDate: day, startTime: nil, endTime: nil)
            )
        )
        #expect(
            !UntimedItemReorder.isReorderable(
                try CalendarSchedule(
                    startDate: day,
                    endDate: day,
                    startTime: MinuteOfDay(hour: 9, minute: 0)!,
                    endTime: MinuteOfDay(hour: 10, minute: 0)!
                )
            )
        )
        #expect(
            !UntimedItemReorder.isReorderable(
                try CalendarSchedule(startDate: day, endDate: next, startTime: nil, endTime: nil)
            )
        )
    }

    @Test func movingInsertsBeforeTheTargetAndIgnoresNoOps() {
        let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let c = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let ids = [a, b, c]

        #expect(UntimedItemReorder.moving(a, before: c, in: ids) == [b, a, c])
        #expect(UntimedItemReorder.moving(c, before: a, in: ids) == [c, a, b])
        #expect(UntimedItemReorder.moving(a, before: b, in: ids) == nil)
        #expect(UntimedItemReorder.moving(a, before: a, in: ids) == nil)
        #expect(UntimedItemReorder.moving(a, to: .end, in: ids) == [b, c, a])
        #expect(UntimedItemReorder.moving(c, to: .end, in: ids) == nil)
        #expect(UntimedItemReorder.moving(a, byLanes: 1, in: ids) == [b, a, c])
        #expect(UntimedItemReorder.moving(a, byLanes: 2, in: ids) == [b, c, a])
        #expect(UntimedItemReorder.moving(c, byLanes: -1, in: ids) == [a, c, b])
        #expect(UntimedItemReorder.moving(a, byLanes: 0, in: ids) == nil)
        #expect(UntimedItemReorder.moving(a, byLanes: -3, in: ids) == nil)
    }

    @Test func laneHitSelectsBeforeTargetOrEnd() throws {
        let weekStart = CalendarDate(year: 2026, month: 8, day: 17)!
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000701")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000702")!
        let category = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
        func segment(id: UUID, title: String, lane: Int) throws -> WeekSegment {
            let item = try CalendarItem(
                id: id,
                kind: .task,
                title: title,
                categoryID: category,
                schedule: try CalendarSchedule(
                    startDate: weekStart,
                    endDate: weekStart,
                    startTime: nil,
                    endTime: nil
                ),
                completedAt: nil,
                createdAt: .distantPast,
                updatedAt: .distantPast
            )
            return WeekSegment(
                source: .item(id),
                entry: .item(item),
                weekStart: weekStart,
                startColumn: 0,
                endColumn: 0,
                lane: lane,
                showsLeadingHandle: true,
                showsTrailingHandle: true
            )
        }
        let segments = try [
            segment(id: first, title: "A", lane: 0),
            segment(id: second, title: "B", lane: 1)
        ]
        #expect(UntimedItemReorder.destination(lane: 0, column: 0, segments: segments) == .before(first))
        #expect(UntimedItemReorder.destination(lane: 1, column: 0, segments: segments) == .before(second))
        #expect(UntimedItemReorder.destination(lane: 3, column: 0, segments: segments) == .end)
    }

    @Test func midpointPastTheNextChipMovesAfterIt() throws {
        let weekStart = CalendarDate(year: 2026, month: 8, day: 17)!
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000711")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000712")!
        let category = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
        func segment(id: UUID, title: String, lane: Int) throws -> WeekSegment {
            let item = try CalendarItem(
                id: id,
                kind: .task,
                title: title,
                categoryID: category,
                schedule: try CalendarSchedule(
                    startDate: weekStart,
                    endDate: weekStart,
                    startTime: nil,
                    endTime: nil
                ),
                completedAt: nil,
                createdAt: .distantPast,
                updatedAt: .distantPast
            )
            return WeekSegment(
                source: .item(id),
                entry: .item(item),
                weekStart: weekStart,
                startColumn: 0,
                endColumn: 0,
                lane: lane,
                showsLeadingHandle: true,
                showsTrailingHandle: true
            )
        }
        let segments = try [
            segment(id: first, title: "A", lane: 0),
            segment(id: second, title: "B", lane: 1)
        ]
        let pitch = 20.0
        #expect(
            UntimedItemReorder.destination(
                yInLaneArea: 9,
                lanePitch: pitch,
                column: 0,
                segments: segments
            ) == .before(first)
        )
        #expect(
            UntimedItemReorder.destination(
                yInLaneArea: 20,
                lanePitch: pitch,
                column: 0,
                segments: segments
            ) == .before(second)
        )
        #expect(
            UntimedItemReorder.destination(
                yInLaneArea: 31,
                lanePitch: pitch,
                column: 0,
                segments: segments
            ) == .end
        )
    }

    @Test func dropOntoALaterRowInsertsAfterThatRow() {
        let a = UUID(uuidString: "00000000-0000-0000-0000-000000000801")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-000000000802")!
        let c = UUID(uuidString: "00000000-0000-0000-0000-000000000803")!
        let ids = [a, b, c]
        #expect(UntimedItemReorder.destination(moving: a, onto: b, in: ids) == .before(c))
        #expect(UntimedItemReorder.destination(moving: a, onto: c, in: ids) == .end)
        #expect(UntimedItemReorder.destination(moving: c, onto: b, in: ids) == .before(b))
        #expect(UntimedItemReorder.destination(moving: c, onto: a, in: ids) == .before(a))
        #expect(UntimedItemReorder.destination(moving: a, onto: a, in: ids) == nil)
    }

    @Test func reducerWritesRanksAndProjectionFollowsThem() throws {
        let category = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
        let day = CalendarDate(year: 2026, month: 8, day: 17)!
        func item(id: String, title: String, created: TimeInterval) throws -> CalendarItem {
            try CalendarItem(
                id: UUID(uuidString: id)!,
                kind: .task,
                title: title,
                categoryID: category,
                schedule: try CalendarSchedule(startDate: day, endDate: day, startTime: nil, endTime: nil),
                completedAt: nil,
                createdAt: Date(timeIntervalSince1970: created),
                updatedAt: Date(timeIntervalSince1970: created)
            )
        }
        let first = try item(id: "00000000-0000-0000-0000-000000000601", title: "先写的", created: 1)
        let second = try item(id: "00000000-0000-0000-0000-000000000602", title: "后写的", created: 2)
        var state = CalendarState.empty(uncategorizedID: category, now: Date(timeIntervalSince1970: 0))
        state.categories[category] = CalendarCategory(
            id: category, name: "未分类", colorHex: "#8E8E93", sortIndex: 0,
            createdAt: .distantPast, updatedAt: .distantPast
        )
        state.items[first.id] = first
        state.items[second.id] = second

        let before = TimelineProjection.make(
            in: CalendarDateRange(start: day, end: day),
            state: state,
            hiddenCategoryIDs: []
        ).entries.map(\.title)
        #expect(before == ["先写的", "后写的"])

        state = try CalendarReducer.reduce(
            state,
            command: .reorderUntimedItems(on: day, orderedIDs: [second.id, first.id]),
            now: Date(timeIntervalSince1970: 10)
        )
        #expect(state.items[second.id]?.untimedRank == 0)
        #expect(state.items[first.id]?.untimedRank == 1)

        let after = TimelineProjection.make(
            in: CalendarDateRange(start: day, end: day),
            state: state,
            hiddenCategoryIDs: []
        ).entries.map(\.title)
        #expect(after == ["后写的", "先写的"])
    }
}
