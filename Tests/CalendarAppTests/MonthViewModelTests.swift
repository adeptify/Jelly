import CalendarDomain
import Foundation
import Testing
@testable import CalendarApp

@Suite("MonthViewModelTests")
@MainActor
struct MonthViewModelTests {
    @Test func monthViewModelOrdersUntimedBeforeTimedAndComputesOverflow() throws {
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000500")!
        var state = CalendarState.empty(
            uncategorizedID: categoryID,
            now: Date(timeIntervalSince1970: 0)
        )
        let date = CalendarDate(year: 2026, month: 8, day: 3)!
        for index in 0..<7 {
            let range = index == 0 ? nil : try LocalTimeRange(
                start: MinuteOfDay(hour: 8 + index, minute: 0)!,
                end: MinuteOfDay(hour: 9 + index, minute: 0)!
            )
            let item = try CalendarItem(
                id: UUID(), kind: .task, title: "事项 \(index)",
                categoryID: categoryID, date: date, timeRange: range,
                completedAt: nil,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
            state.items[item.id] = item
        }

        let model = MonthViewModel(
            displayedMonth: date,
            state: state,
            hiddenCategoryIDs: [],
            today: date
        )
        let cell = model.cell(for: date)

        #expect(cell.items.first?.timeRange == nil)
        #expect(model.visibleItems(in: cell, capacity: 4).count == 3)
        #expect(model.overflowCount(in: cell, capacity: 4) == 4)
    }

    @Test func monthNavigationAndTodaySelectionUseCivilMonthArithmetic() {
        let august = CalendarDate(year: 2026, month: 8, day: 17)!
        let today = CalendarDate(year: 2026, month: 9, day: 2)!
        let state = makeEmptyState()
        let model = MonthViewModel(
            displayedMonth: august,
            state: state,
            hiddenCategoryIDs: [],
            today: august
        )

        model.goToPreviousMonth()
        #expect(model.displayedMonth == CalendarDate(year: 2026, month: 7, day: 1)!)
        model.goToNextMonth()
        #expect(model.displayedMonth == CalendarDate(year: 2026, month: 8, day: 1)!)
        model.goToToday(today)
        #expect(model.displayedMonth == CalendarDate(year: 2026, month: 9, day: 1)!)
        #expect(model.selectedDate == today)
    }

    @Test func itemCapacityPreservesOneOverflowRow() {
        #expect(MonthLayout.itemCapacity(cellHeight: 91) == 2)
        #expect(MonthLayout.itemCapacity(cellHeight: 116) == 3)
    }

    @Test func emptyStateHintAppearsOnlyForReadyTrulyEmptyCalendar() throws {
        let empty = makeEmptyState()

        for phase in [
            StorePhase.notLoaded,
            .loading,
            .mutating,
            .restoring,
            .loadFailed
        ] {
            #expect(MonthEmptyStateHintPolicy.shouldShow(phase: phase, state: empty) == false)
        }
        #expect(MonthEmptyStateHintPolicy.shouldShow(phase: .ready, state: empty))

        var withItem = empty
        let item = try makeItem(categoryID: empty.uncategorizedID)
        withItem.items[item.id] = item
        #expect(MonthEmptyStateHintPolicy.shouldShow(phase: .ready, state: withItem) == false)

        var withSeries = empty
        let series = try WeeklySeries(
            id: UUID(),
            kind: .task,
            title: "重复事项",
            categoryID: empty.uncategorizedID,
            startDate: CalendarDate(year: 2026, month: 8, day: 3)!,
            endDate: nil,
            weekdays: [.monday],
            timeRange: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        withSeries.recurrence.series[series.id] = series
        #expect(MonthEmptyStateHintPolicy.shouldShow(phase: .ready, state: withSeries) == false)
    }

    @Test func stateUpdateRefreshesProjectedRowsAndColors() throws {
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
        let date = CalendarDate(year: 2026, month: 8, day: 3)!
        var state = CalendarState.empty(uncategorizedID: categoryID, now: .distantPast)
        let item = try CalendarItem(
            id: UUID(), kind: .task, title: "需要刷新",
            categoryID: categoryID, date: date, timeRange: nil, completedAt: nil,
            createdAt: .distantPast, updatedAt: .distantPast
        )
        state.items[item.id] = item
        let model = MonthViewModel(
            displayedMonth: date, state: state, hiddenCategoryIDs: [], today: date
        )

        var changed = state
        changed.items[item.id]?.completedAt = Date(timeIntervalSince1970: 1)
        changed.categories[categoryID]?.colorHex = "#FF0000"
        model.update(state: changed, hiddenCategoryIDs: [], today: date)
        let refreshed = model.cell(for: date)
        #expect(refreshed.items.first?.completedAt == Date(timeIntervalSince1970: 1))
        #expect(changed.categories[refreshed.items.first!.categoryID]?.colorHex == "#FF0000")

        model.update(state: changed, hiddenCategoryIDs: [categoryID], today: date)
        let hidden = model.cell(for: date)
        #expect(hidden.items.isEmpty)
        #expect(model.overflowCount(in: hidden, capacity: 1) == 0)
    }
}
