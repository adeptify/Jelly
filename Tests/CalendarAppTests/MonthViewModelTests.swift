import CalendarDomain
import Foundation
import Testing
@testable import CalendarApp

@Suite("MonthViewModelTests")
@MainActor
struct MonthViewModelTests {
    @Test func monthViewModelOrdersUntimedBeforeTimedInTimelineProjection() throws {
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
                categoryID: categoryID,
                schedule: try CalendarSchedule(
                    startDate: date,
                    endDate: date,
                    startTime: range?.start,
                    endTime: range?.end
                ),
                completedAt: nil,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
            state.items[item.id] = item
        }

        let model = MonthViewModel(
            centeredOn: date,
            state: state,
            hiddenCategoryIDs: [],
            today: date
        )
        #expect(model.projectedEntries.first?.schedule.startTime == nil)
        #expect(model.projectedEntries.count == 7)
    }

    @Test func monthNavigationAndTodaySelectionUseCivilMonthArithmetic() {
        let august = CalendarDate(year: 2026, month: 8, day: 17)!
        let today = CalendarDate(year: 2026, month: 9, day: 2)!
        let state = makeEmptyState()
        let model = MonthViewModel(
            centeredOn: august,
            state: state,
            hiddenCategoryIDs: [],
            today: august
        )

        model.moveWeekStreamFocus(to: .previousLogicalMonth)
        #expect(model.monthTitleDate.year == 2026)
        #expect(model.monthTitleDate.month == 7)
        model.moveWeekStreamFocus(to: .nextLogicalMonth)
        #expect(model.monthTitleDate.year == 2026)
        #expect(model.monthTitleDate.month == 8)
        model.moveWeekStreamFocus(to: .today(today))
        #expect(model.monthTitleDate.year == 2026)
        #expect(model.monthTitleDate.month == 9)
        #expect(model.selectedDate == today)
    }

    @Test func emptyStateHintAppearsOnlyForReadyTrulyEmptyCalendar() throws {
        let empty = makeEmptyState()

        for phase in [
            WorkspaceStorePhase.notLoaded,
            .loading,
            .mutating,
            .parkedCommitUncertain(UUID()),
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
            ruleStartDate: CalendarDate(year: 2026, month: 8, day: 3)!,
            recurrenceEndDate: nil,
            weekdays: [.monday],
            durationDays: 1,
            startTime: nil,
            endTime: nil,
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
            categoryID: categoryID,
            schedule: try CalendarSchedule(
                startDate: date,
                endDate: date,
                startTime: nil,
                endTime: nil
            ),
            completedAt: nil,
            createdAt: .distantPast, updatedAt: .distantPast
        )
        state.items[item.id] = item
        let model = MonthViewModel(
            centeredOn: date, state: state, hiddenCategoryIDs: [], today: date
        )

        var changed = state
        changed.items[item.id]?.completedAt = Date(timeIntervalSince1970: 1)
        changed.categories[categoryID]?.colorHex = "#FF0000"
        model.update(state: changed, hiddenCategoryIDs: [], today: date)
        let refreshed = try #require(model.projectedEntries.first)
        #expect(refreshed.completedAt == Date(timeIntervalSince1970: 1))
        #expect(changed.categories[refreshed.categoryID]?.colorHex == "#FF0000")

        model.update(state: changed, hiddenCategoryIDs: [categoryID], today: date)
        #expect(model.projectedEntries.isEmpty)
    }

    @Test func hiddenCategoriesAreExcludedFromFreshTimelineProjection() throws {
        let visibleCategory = UUID()
        let hiddenCategory = UUID()
        let date = CalendarDate(year: 2026, month: 8, day: 3)!
        var state = CalendarState.empty(uncategorizedID: visibleCategory, now: .distantPast)
        state.categories[hiddenCategory] = CalendarCategory(
            id: hiddenCategory, name: "隐藏", colorHex: "#FF3B30", sortIndex: 1,
            createdAt: .distantPast, updatedAt: .distantPast
        )
        let visible = try makeItem(categoryID: visibleCategory, title: "显示", date: date)
        let hidden = try makeItem(categoryID: hiddenCategory, title: "隐藏", date: date)
        state.items[visible.id] = visible
        state.items[hidden.id] = hidden
        let model = MonthViewModel(
            centeredOn: date, state: state, hiddenCategoryIDs: [hiddenCategory], today: date
        )
        #expect(model.projectedEntries.map(\.title) == ["显示"])
    }

    @Test func loadedWeekRangeDrivesProjectionAndLayout() throws {
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000502")!
        let center = CalendarDate(year: 2026, month: 8, day: 6)!
        let empty = CalendarState.empty(uncategorizedID: categoryID, now: .distantPast)
        let model = MonthViewModel(
            centeredOn: center, state: empty, hiddenCategoryIDs: [], today: center
        )
        let range = model.loadedRange
        let enteringItem = try CalendarItem(
            id: UUID(), kind: .task, title: "从窗口外延续",
            categoryID: categoryID,
            schedule: try CalendarSchedule(
                startDate: range.start.previousDay,
                endDate: range.start,
                startTime: nil,
                endTime: nil
            ),
            creationTimeZoneIdentifier: "Asia/Shanghai",
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        var state = empty
        state.items[enteringItem.id] = enteringItem

        model.update(state: state, hiddenCategoryIDs: [], today: center)

        #expect(model.weekStarts.first == range.start)
        #expect(model.weekStarts.last?.addingDays(6) == range.end)
        #expect(model.projectedEntries.map(\.id) == [.item(enteringItem.id)])
        let firstLayout = try #require(model.weekLayouts(laneCapacity: 1).first)
        #expect(firstLayout.segments.map(\.source) == [.item(enteringItem.id)])
    }

    @Test func weekStreamProjectedLookupOpensAnItemVisibleFarFromTheInitialFocus() throws {
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000506")!
        let center = CalendarDate(year: 2026, month: 8, day: 6)!
        var state = CalendarState.empty(uncategorizedID: categoryID, now: .distantPast)
        let model = MonthViewModel(
            centeredOn: center, state: state, hiddenCategoryIDs: [], today: center
        )
        let farVisibleDate = model.weekStarts[80]
        let item = try CalendarItem(
            id: UUID(),
            kind: .task,
            title: "远处周内事项",
            categoryID: categoryID,
            schedule: try CalendarSchedule(
                startDate: farVisibleDate,
                endDate: farVisibleDate,
                startTime: nil,
                endTime: nil
            ),
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        state.items[item.id] = item

        model.update(state: state, hiddenCategoryIDs: [], today: center)

        #expect(model.projectedItem(withID: "item:\(item.id.uuidString)")?.title == "远处周内事项")
    }

    @Test func changingTheWeekWindowReprojectsTheNewlyLoadedRangeWithoutChangingItemIdentity() throws {
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000503")!
        let center = CalendarDate(year: 2026, month: 8, day: 6)!
        let empty = CalendarState.empty(uncategorizedID: categoryID, now: .distantPast)
        let model = MonthViewModel(
            centeredOn: center, state: empty, hiddenCategoryIDs: [], today: center
        )
        let itemDate = model.loadedRange.end.addingDays(7)
        let item = try makeItem(categoryID: categoryID, title: "扩展后可见", date: itemDate)
        var state = empty
        state.items[item.id] = item
        model.update(state: state, hiddenCategoryIDs: [], today: center)

        #expect(model.projectedEntries.isEmpty)
        let anchor = model.extendLater(visibleWeek: model.weekStarts.last!, pixelOffset: 23)

        #expect(anchor == .init(weekStart: model.weekStarts[104], pixelOffset: 23))
        #expect(model.projectedEntries.map(\.id) == [.item(item.id)])
    }

    @Test func todayRefreshMovesOnlyTheTodayMarkerWithoutResettingTheFocusedMonth() {
        let august = CalendarDate(year: 2026, month: 8, day: 17)!
        let tomorrow = CalendarDate(year: 2026, month: 8, day: 18)!
        let model = MonthViewModel(
            centeredOn: august,
            state: makeEmptyState(),
            hiddenCategoryIDs: [],
            today: august
        )
        model.moveWeekStreamFocus(to: .previousLogicalMonth)
        let focusedWeek = model.focusWeek

        model.update(state: makeEmptyState(), hiddenCategoryIDs: [], today: tomorrow)

        #expect(model.focusWeek == focusedWeek)
        #expect(model.today == tomorrow)
    }

    @Test func todayDestinationRecentersDistantFutureAndPastWeeksWithFiftyTwoWeeksOnBothSides() {
        let center = CalendarDate(year: 2026, month: 8, day: 6)!
        let model = MonthViewModel(
            centeredOn: center,
            state: makeEmptyState(),
            hiddenCategoryIDs: [],
            today: center
        )

        let distantFuture = CalendarDate(year: 2031, month: 1, day: 31)!
        model.moveWeekStreamFocus(to: .today(distantFuture))
        #expect(model.focusWeek == CalendarDate(year: 2031, month: 1, day: 27)!)
        #expect(model.weekStarts.contains(model.focusWeek))
        #expect(model.weekStarts.count == 105)
        #expect(model.weekStarts.first == model.focusWeek.addingDays(-364))
        #expect(model.weekStarts.last == model.focusWeek.addingDays(364))
        for (earlier, later) in zip(model.weekStarts, model.weekStarts.dropFirst()) {
            #expect(earlier.addingDays(7) == later)
        }

        let distantPast = CalendarDate(year: 2020, month: 1, day: 1)!
        model.moveWeekStreamFocus(to: .today(distantPast))
        #expect(model.focusWeek == CalendarDate(year: 2019, month: 12, day: 30)!)
        #expect(model.weekStarts.contains(model.focusWeek))
        #expect(model.weekStarts.count == 105)
        #expect(model.weekStarts.first == model.focusWeek.addingDays(-364))
        #expect(model.weekStarts.last == model.focusWeek.addingDays(364))
        for (earlier, later) in zip(model.weekStarts, model.weekStarts.dropFirst()) {
            #expect(earlier.addingDays(7) == later)
        }
    }

    @Test func monthNavigationLoadsADistantLogicalFocusIntoTheBoundedWindow() {
        let center = CalendarDate(year: 2026, month: 8, day: 6)!
        let model = MonthViewModel(
            centeredOn: center,
            state: makeEmptyState(),
            hiddenCategoryIDs: [],
            today: center
        )
        model.updateFocus(toWeekStarting: CalendarDate(year: 2031, month: 1, day: 6)!)

        model.moveWeekStreamFocus(to: .nextLogicalMonth)

        #expect(model.monthTitleDate.year == 2031)
        #expect(model.monthTitleDate.month == 2)
        #expect(model.weekStarts.contains(model.focusWeek))
        #expect(model.weekStarts.count == 105)
        #expect(model.weekStarts.first == model.focusWeek.addingDays(-364))
        #expect(model.weekStarts.last == model.focusWeek.addingDays(364))
        for (earlier, later) in zip(model.weekStarts, model.weekStarts.dropFirst()) {
            #expect(earlier.addingDays(7) == later)
        }
    }

    @Test func updateFocusKeepsTimelineIdentityAndLookupAcrossTheLoadedWeekStream() throws {
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000505")!
        let august = CalendarDate(year: 2026, month: 8, day: 3)!
        let october = CalendarDate(year: 2026, month: 10, day: 5)!
        var state = CalendarState.empty(uncategorizedID: categoryID, now: .distantPast)
        var octoberItems: [CalendarItem] = []
        for index in 0..<3 {
            let item = try CalendarItem(
                id: UUID(), kind: .task, title: "十月事项 \(index)",
                categoryID: categoryID,
                schedule: try CalendarSchedule(
                    startDate: october,
                    endDate: october,
                    startTime: nil,
                    endTime: nil
                ),
                creationTimeZoneIdentifier: "Asia/Shanghai",
                completedAt: nil,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
            state.items[item.id] = item
            octoberItems.append(item)
        }
        let model = MonthViewModel(
            centeredOn: august,
            state: state,
            hiddenCategoryIDs: [],
            today: august
        )
        let projectedIDsBeforeFocusChange = model.projectedEntries.map(\.id)
        let lookupID = "item:\(octoberItems[0].id.uuidString)"

        #expect(model.projectedItem(withID: lookupID)?.id == lookupID)

        model.updateFocus(toWeekStarting: october)

        #expect(model.monthTitleDate.year == 2026)
        #expect(model.monthTitleDate.month == 10)
        #expect(model.projectedItem(withID: lookupID)?.id == lookupID)
        #expect(model.projectedEntries.map(\.id) == projectedIDsBeforeFocusChange)
    }
}
