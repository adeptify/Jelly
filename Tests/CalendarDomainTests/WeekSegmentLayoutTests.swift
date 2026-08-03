import Foundation
import Testing
@testable import CalendarDomain

@Suite("WeekSegmentLayoutTests")
struct WeekSegmentLayoutTests {
    private let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!

    @Test func crossWeekEntryProducesOnlyTrueOuterHandles() throws {
        let layouts = WeekSegmentLayout.make(
            entries: [entry("2026-08-08", "2026-08-12", id: uuid("502"))],
            weekStarts: [date(2026, 8, 3), date(2026, 8, 10)],
            laneCapacity: 10
        )
        let first = try #require(layouts[0].segments.first)
        let second = try #require(layouts[1].segments.first)

        #expect(first.showsLeadingHandle)
        #expect(!first.showsTrailingHandle)
        #expect(!second.showsLeadingHandle)
        #expect(second.showsTrailingHandle)
    }

    @Test func overflowingMultiDaySegmentIsHiddenAtomicallyAndCountedOnEveryCoveredDate() throws {
        let entries = (0..<11).map { index in
            entry("2026-08-11", "2026-08-12", id: uuid(String(510 + index)))
        }
        let overflowingID = try #require(entries.last?.id)
        let layout = try #require(WeekSegmentLayout.make(
            entries: entries,
            weekStarts: [date(2026, 8, 10)],
            laneCapacity: 10
        ).first)

        #expect(!layout.visibleSegments.contains(where: { $0.source == overflowingID }))
        #expect(layout.overflowByDate[date(2026, 8, 11)] == 1)
        #expect(layout.overflowByDate[date(2026, 8, 12)] == 1)
    }

    @Test func sameWeekIntervalsUseTheFirstFreeLaneWithStrictlyEarlierEnds() throws {
        let first = entry("2026-08-10", "2026-08-11", id: uuid("530"))
        let second = entry("2026-08-11", "2026-08-12", id: uuid("531"))
        let third = entry("2026-08-12", "2026-08-12", id: uuid("532"))
        let layout = try #require(WeekSegmentLayout.make(
            entries: [third, second, first],
            weekStarts: [date(2026, 8, 10)],
            laneCapacity: 3
        ).first)
        let lanes = Dictionary(uniqueKeysWithValues: layout.visibleSegments.map { ($0.source, $0.lane) })

        #expect(lanes[first.id] == 0)
        #expect(lanes[second.id] == 1)
        #expect(lanes[third.id] == 0)
    }

    @Test func multiDaySegmentsTakePriorityOverSingleDaySegmentsWhenCapacityIsLimited() throws {
        let singleDay = entry("2026-08-10", "2026-08-10", id: uuid("540"))
        let multiDay = entry("2026-08-10", "2026-08-11", id: uuid("541"))
        let layout = try #require(WeekSegmentLayout.make(
            entries: [singleDay, multiDay],
            weekStarts: [date(2026, 8, 10)],
            laneCapacity: 1
        ).first)

        #expect(layout.visibleSegments.map(\.source) == [multiDay.id])
        #expect(layout.overflowByDate[date(2026, 8, 10)] == 1)
    }

    @Test func earlierSingleDayReusesLaneOccupiedByALaterNonOverlappingMultiDay() throws {
        let earlierSingleDay = entry("2026-08-10", "2026-08-10", id: uuid("542"))
        let laterMultiDay = entry("2026-08-14", "2026-08-15", id: uuid("543"))
        let layout = try #require(WeekSegmentLayout.make(
            entries: [earlierSingleDay, laterMultiDay],
            weekStarts: [date(2026, 8, 10)],
            laneCapacity: 1
        ).first)

        #expect(layout.visibleSegments.map(\.source) == [laterMultiDay.id, earlierSingleDay.id])
        #expect(layout.visibleSegments.allSatisfy { $0.lane == 0 })
        #expect(layout.overflowByDate.isEmpty)
    }

    @Test func duplicateSourceProducesOneSegmentWithoutOverflowAtAnyCapacity() throws {
        let duplicate = entry("2026-08-11", "2026-08-12", id: uuid("544"))

        for capacity in [1, 2] {
            let layout = try #require(WeekSegmentLayout.make(
                entries: [duplicate, duplicate],
                weekStarts: [date(2026, 8, 10)],
                laneCapacity: capacity
            ).first)

            #expect(layout.visibleSegments.count == 1)
            #expect(layout.visibleSegments.map(\.id) == [
                WeekSegmentID(sourceID: duplicate.id, weekStart: date(2026, 8, 10))
            ])
            #expect(layout.overflowByDate.isEmpty)
        }
    }

    private func entry(_ start: String, _ end: String, id: UUID) -> ProjectedEntry {
        .item(try! CalendarItem(
            id: id,
            kind: .task,
            title: "事项",
            categoryID: categoryID,
            schedule: try! CalendarSchedule(
                startDate: date(start),
                endDate: date(end),
                startTime: nil,
                endTime: nil
            ),
            creationTimeZoneIdentifier: "Asia/Shanghai",
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        ))
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> CalendarDate {
        CalendarDate(year: year, month: month, day: day)!
    }

    private func date(_ string: String) -> CalendarDate {
        let components = string.split(separator: "-").map { Int($0)! }
        return date(components[0], components[1], components[2])
    }

    private func uuid(_ suffix: String) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-000000000\(suffix)")!
    }
}
