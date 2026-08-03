import CalendarDomain
import Foundation
import Testing
@testable import CalendarApp

@Suite("WeekRowPresentationTests")
struct WeekRowPresentationTests {
    @Test func crossDaySegmentsKeepContinuousColumnsStableIdentityAndTrueOuterEdges() throws {
        let fixture = try makeCrossMonthFixture()
        let layouts = WeekSegmentLayout.make(
            entries: [.item(fixture.item)],
            weekStarts: [fixture.firstWeek, fixture.secondWeek],
            laneCapacity: 10
        )

        let first = try #require(layouts.first)
        let second = try #require(layouts.last)
        let firstSegment = try #require(WeekRowPresentation(layout: first).segment(.item(fixture.item.id)))
        let secondSegment = try #require(WeekRowPresentation(layout: second).segment(.item(fixture.item.id)))

        #expect(firstSegment.id == WeekSegmentID(sourceID: .item(fixture.item.id), weekStart: fixture.firstWeek))
        #expect(firstSegment.source == .item(fixture.item.id))
        #expect(firstSegment.startColumn == 5)
        #expect(firstSegment.endColumn == 6)
        #expect(firstSegment.continuesBefore == false)
        #expect(firstSegment.continuesAfter == true)
        #expect(firstSegment.showsLeadingHandle == true)
        #expect(firstSegment.showsTrailingHandle == false)

        #expect(secondSegment.id == WeekSegmentID(sourceID: .item(fixture.item.id), weekStart: fixture.secondWeek))
        #expect(secondSegment.startColumn == 0)
        #expect(secondSegment.endColumn == 2)
        #expect(secondSegment.continuesBefore == true)
        #expect(secondSegment.continuesAfter == false)
        #expect(secondSegment.showsLeadingHandle == false)
        #expect(secondSegment.showsTrailingHandle == true)
    }

    @Test func fullScreenWeekHeightExposesTenRowsBeforeOverflow() {
        #expect(WeekRowMetrics.itemCapacity(height: 252) == 10)
        #expect(WeekRowMetrics.itemCapacity(height: 210) < 10)
    }

    @Test func accessibilityReadsCompleteRangeAcrossSegments() throws {
        let fixture = try makeCrossMonthFixture()
        let layout = try #require(WeekSegmentLayout.make(
            entries: [.item(fixture.item)],
            weekStarts: [fixture.firstWeek],
            laneCapacity: 10
        ).first)

        let presentation = WeekRowPresentation(
            layout: layout,
            categories: [fixture.category.id: fixture.category]
        )

        #expect(presentation.accessibilityLabel == "待办，工作，产品发布，8月29日至9月2日，延续到下一周，未完成")
        #expect(presentation.segment(.item(fixture.item.id))?.accessibilityLabel
            == "待办，工作，产品发布，8月29日至9月2日，延续到下一周，未完成")
    }

    @Test func accessibilityReadsBothDatesAndTimesForAContinuationAcrossYears() throws {
        let category = CalendarCategory(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000705")!,
            name: "发布",
            colorHex: "#007AFF",
            sortIndex: 0,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let item = try CalendarItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000706")!,
            kind: .event,
            title: "跨年值守",
            categoryID: category.id,
            schedule: try CalendarSchedule(
                startDate: CalendarDate(year: 2026, month: 12, day: 31)!,
                endDate: CalendarDate(year: 2027, month: 1, day: 2)!,
                startTime: MinuteOfDay(hour: 23, minute: 0)!,
                endTime: MinuteOfDay(hour: 1, minute: 0)!
            ),
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let weekStart = CalendarDate(year: 2026, month: 12, day: 28)!
        let layout = try #require(WeekSegmentLayout.make(
            entries: [.item(item)],
            weekStarts: [weekStart],
            laneCapacity: 10
        ).first)

        let label = WeekRowPresentation(
            layout: layout,
            categories: [category.id: category]
        ).accessibilityLabel

        #expect(label == "日程，发布，跨年值守，2026年12月31日 23:00至2027年1月2日 01:00")
    }

    @Test func focusResolverChoosesTheWeekNearestToViewportCenter() {
        let previous = CalendarDate(year: 2026, month: 8, day: 3)!
        let current = CalendarDate(year: 2026, month: 8, day: 10)!
        let next = CalendarDate(year: 2026, month: 8, day: 17)!

        let focus = WeekStreamViewport.focusWeek(
            in: [
                .init(weekStart: previous, minY: -252, maxY: 0),
                .init(weekStart: current, minY: 0, maxY: 252),
                .init(weekStart: next, minY: 252, maxY: 504)
            ],
            viewportHeight: 600
        )

        #expect(focus == next)
    }

    @Test func nearLeadingWindowEdgeRequestsExtensionAndPreservesTheVisibleWeekAnchor() {
        let first = CalendarDate(year: 2026, month: 8, day: 3)!
        let second = CalendarDate(year: 2026, month: 8, day: 10)!
        let request = WeekStreamViewport.extensionRequest(
            in: [
                .init(weekStart: first, minY: -180, maxY: 72),
                .init(weekStart: second, minY: 72, maxY: 324)
            ],
            loadedWeekStarts: [first, second],
            viewportHeight: 500
        )

        #expect(request == .init(direction: .earlier, anchor: .init(weekStart: first, pixelOffset: 180)))
        #expect(WeekStreamViewport.restorationIntent(for: request!.anchor)
            == .init(weekStart: first, pixelOffset: 180))
    }

    @Test func aDropOverAnySegmentColumnResolvesToThatColumnDate() {
        let weekStart = CalendarDate(year: 2026, month: 8, day: 3)!

        #expect(WeekRowDropTarget.date(atX: 0, rowWidth: 700, weekStart: weekStart) == weekStart)
        #expect(WeekRowDropTarget.date(atX: 399, rowWidth: 700, weekStart: weekStart)
            == CalendarDate(year: 2026, month: 8, day: 6)!)
        #expect(WeekRowDropTarget.date(atX: 700, rowWidth: 700, weekStart: weekStart)
            == CalendarDate(year: 2026, month: 8, day: 9)!)
    }

    @Test @MainActor func dayDrawerKeepsAProjectedSpanOnEveryCoveredDate() throws {
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000703")!
        let coveredDate = CalendarDate(year: 2026, month: 9, day: 1)!
        let item = try CalendarItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000704")!,
            kind: .event,
            title: "跨月发布",
            categoryID: categoryID,
            schedule: try CalendarSchedule(
                startDate: CalendarDate(year: 2026, month: 8, day: 29)!,
                endDate: CalendarDate(year: 2026, month: 9, day: 2)!,
                startTime: nil,
                endTime: nil
            ),
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        var state = CalendarState.empty(uncategorizedID: categoryID, now: .distantPast)
        state.items[item.id] = item

        let drawer = DayDrawerViewModel(date: coveredDate, state: state, hiddenCategoryIDs: [])

        #expect(drawer.items.map(\.id) == ["item:\(item.id.uuidString)"])
    }

    private func makeCrossMonthFixture() throws -> (
        item: CalendarItem,
        category: CalendarCategory,
        firstWeek: CalendarDate,
        secondWeek: CalendarDate
    ) {
        let category = CalendarCategory(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000701")!,
            name: "工作",
            colorHex: "#007AFF",
            sortIndex: 0,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let item = try CalendarItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000702")!,
            kind: .task,
            title: "产品发布",
            categoryID: category.id,
            schedule: try CalendarSchedule(
                startDate: CalendarDate(year: 2026, month: 8, day: 29)!,
                endDate: CalendarDate(year: 2026, month: 9, day: 2)!,
                startTime: nil,
                endTime: nil
            ),
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        return (
            item,
            category,
            CalendarDate(year: 2026, month: 8, day: 24)!,
            CalendarDate(year: 2026, month: 8, day: 31)!
        )
    }
}
