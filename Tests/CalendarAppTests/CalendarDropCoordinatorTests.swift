import CalendarDomain
import CalendarPersistence
import Foundation
import Testing
@testable import CalendarApp

@Suite("CalendarDropCoordinatorTests")
@MainActor
struct CalendarDropCoordinatorTests {
    @Test func oneOffDropPreservesTimeAndRegistersOneUndo() async throws {
        let uncategorizedID = UUID(uuidString: "00000000-0000-0000-0000-000000000801")!
        var original = CalendarState.empty(
            uncategorizedID: uncategorizedID,
            now: Date(timeIntervalSince1970: 0)
        )
        let originalRange = try LocalTimeRange(
            start: MinuteOfDay(hour: 9, minute: 0)!,
            end: MinuteOfDay(hour: 10, minute: 0)!
        )
        let item = try CalendarItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000802")!,
            kind: .task,
            title: "专注时段",
            categoryID: uncategorizedID,
            date: .init(year: 2026, month: 8, day: 3)!,
            timeRange: originalRange,
            creationTimeZoneIdentifier: "Asia/Shanghai",
            completedAt: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        original.items[item.id] = item
        let repository = InMemoryCalendarRepository(initialState: original)
        let store = CalendarStore(initialState: original, repository: repository)
        await store.load()
        let coordinator = CalendarDropCoordinator(store: store)

        try await coordinator.accept(
            .item(item.id),
            on: .init(year: 2026, month: 8, day: 8)!
        )

        #expect(store.state.items[item.id]?.date == CalendarDate(year: 2026, month: 8, day: 8)!)
        #expect(store.state.items[item.id]?.timeRange == originalRange)
        #expect(store.state.items[item.id]?.creationTimeZoneIdentifier == "Asia/Shanghai")
        #expect(store.canUndo)
        #expect(await repository.saveCount == 1)

        try await store.undo()

        #expect(store.state == original)
        #expect(await repository.persistedState == original)
        #expect(await repository.saveCount == 2)
        #expect(store.canUndo == false)
    }

    @Test func recurringDropWaitsForScopeAndShiftsFuturePattern() async throws {
        let harness = try makeMondayWednesdayDropHarness()
        let repository = InMemoryCalendarRepository(initialState: harness.originalState)
        let store = CalendarStore(
            initialState: harness.originalState,
            repository: repository
        )
        await store.load()
        let coordinator = CalendarDropCoordinator(store: store)

        try await coordinator.accept(
            .occurrence(harness.boundaryMonday),
            on: harness.destinationTuesday
        )

        let pending = try #require(coordinator.pendingRecurringDrop)
        #expect(store.state == harness.originalState)
        #expect(await repository.saveCount == 0)

        try await coordinator.resolve(scope: .thisAndFuture)

        let future = try #require(store.state.recurrence.series[pending.newSeriesID])
        #expect(future.weekdays == [.tuesday, .thursday])
        let shiftedExceptionKey = OccurrenceKey(
            seriesID: pending.newSeriesID,
            originalDate: harness.futureExceptionKey.originalDate.addingDays(1)
        )
        guard case .some(.modified(let shiftedOverride)) =
            store.state.recurrence.exceptions[shiftedExceptionKey]
        else {
            Issue.record("Expected shifted modified exception")
            return
        }
        #expect(shiftedOverride.displayedDate == harness.futureExceptionDisplayedDate.addingDays(1))
        let shiftedCompletionKey = OccurrenceKey(
            seriesID: pending.newSeriesID,
            originalDate: harness.futureCompletionKey.originalDate.addingDays(1)
        )
        #expect(store.state.recurrence.completions[shiftedCompletionKey]?.key == shiftedCompletionKey)
        #expect(store.state.recurrence.completions[shiftedCompletionKey]?.completedAt == harness.futureCompletedAt)
        #expect(store.state.recurrence.exceptions[harness.futureExceptionKey] == nil)
        #expect(store.state.recurrence.completions[harness.futureCompletionKey] == nil)
        #expect(store.state.recurrence.exceptions[harness.pastExceptionKey] ==
            harness.originalState.recurrence.exceptions[harness.pastExceptionKey])
        #expect(store.state.recurrence.completions[harness.pastCompletionKey] ==
            harness.originalState.recurrence.completions[harness.pastCompletionKey])
        #expect(coordinator.pendingRecurringDrop == nil)
        #expect(await repository.saveCount == 1)

        try await store.undo()

        #expect(store.state == harness.originalState)
        #expect(await repository.persistedState == harness.originalState)
        #expect(await repository.saveCount == 2)
        #expect(store.canUndo == false)
    }

    @Test func recurringDropOnlyThisCreatesOneMovedException() async throws {
        let harness = try makeMondayWednesdayDropHarness()
        let repository = InMemoryCalendarRepository(initialState: harness.originalState)
        let store = CalendarStore(initialState: harness.originalState, repository: repository)
        await store.load()
        let coordinator = CalendarDropCoordinator(store: store)

        try await coordinator.accept(.occurrence(harness.boundaryMonday), on: harness.destinationTuesday)
        try await coordinator.resolve(scope: .onlyThis)

        #expect(store.state.recurrence.series[harness.boundaryMonday.seriesID]?.weekdays == [.monday, .wednesday])
        #expect(store.state.recurrence.exceptions[harness.boundaryMonday] == .modified(.init(
            displayedDate: harness.destinationTuesday,
            title: "重复专注",
            kind: .task,
            categoryID: harness.originalState.uncategorizedID,
            timeRange: nil
        )))
        #expect(await repository.saveCount == 1)

        try await store.undo()
        #expect(store.state == harness.originalState)
        #expect(await repository.persistedState == harness.originalState)
        #expect(store.canUndo == false)
    }

    @Test func cancellingRecurringDropLeavesStoreAndRepositoryUntouched() async throws {
        let harness = try makeMondayWednesdayDropHarness()
        let repository = InMemoryCalendarRepository(initialState: harness.originalState)
        let store = CalendarStore(initialState: harness.originalState, repository: repository)
        await store.load()
        let coordinator = CalendarDropCoordinator(store: store)

        try await coordinator.accept(.occurrence(harness.boundaryMonday), on: harness.destinationTuesday)
        coordinator.cancel()

        #expect(coordinator.pendingRecurringDrop == nil)
        #expect(store.state == harness.originalState)
        #expect(await repository.persistedState == harness.originalState)
        #expect(await repository.saveCount == 0)
    }

    @Test func hoverTargetShowsFeedbackWithoutMutation() async throws {
        let original = makeEmptyState()
        let repository = InMemoryCalendarRepository(initialState: original)
        let store = CalendarStore(initialState: original, repository: repository)
        await store.load()
        let coordinator = CalendarDropCoordinator(store: store)
        let target = CalendarDate(year: 2026, month: 8, day: 11)!

        coordinator.setTargeted(true, date: target)
        coordinator.setTargeted(true, date: target)
        #expect(coordinator.dropTargetDate == target)
        #expect(store.state == original)
        #expect(await repository.saveCount == 0)

        coordinator.setTargeted(false, date: target)
        #expect(coordinator.dropTargetDate == nil)
        #expect(store.state == original)
        #expect(await repository.saveCount == 0)
    }
}

private struct DropHarness {
    let originalState: CalendarState
    let boundaryMonday: OccurrenceKey
    let destinationTuesday: CalendarDate
    let futureExceptionKey: OccurrenceKey
    let futureExceptionDisplayedDate: CalendarDate
    let futureCompletionKey: OccurrenceKey
    let futureCompletedAt: Date
    let pastExceptionKey: OccurrenceKey
    let pastCompletionKey: OccurrenceKey
}

private func makeMondayWednesdayDropHarness() throws -> DropHarness {
    let uncategorizedID = UUID(uuidString: "00000000-0000-0000-0000-000000000810")!
    let seriesID = UUID(uuidString: "00000000-0000-0000-0000-000000000811")!
    let startMonday = CalendarDate(year: 2026, month: 8, day: 3)!
    let boundaryMonday = OccurrenceKey(
        seriesID: seriesID,
        originalDate: CalendarDate(year: 2026, month: 8, day: 10)!
    )
    let destinationTuesday = CalendarDate(year: 2026, month: 8, day: 11)!
    let futureExceptionKey = OccurrenceKey(
        seriesID: seriesID,
        originalDate: CalendarDate(year: 2026, month: 8, day: 17)!
    )
    let futureExceptionDisplayedDate = CalendarDate(year: 2026, month: 8, day: 18)!
    let futureCompletionKey = OccurrenceKey(
        seriesID: seriesID,
        originalDate: CalendarDate(year: 2026, month: 8, day: 19)!
    )
    let pastExceptionKey = OccurrenceKey(
        seriesID: seriesID,
        originalDate: CalendarDate(year: 2026, month: 8, day: 5)!
    )
    let pastCompletionKey = OccurrenceKey(seriesID: seriesID, originalDate: startMonday)
    let futureCompletedAt = Date(timeIntervalSince1970: 500)

    var originalState = CalendarState.empty(
        uncategorizedID: uncategorizedID,
        now: Date(timeIntervalSince1970: 0)
    )
    let series = try WeeklySeries(
        id: seriesID,
        kind: .task,
        title: "重复专注",
        categoryID: uncategorizedID,
        startDate: startMonday,
        endDate: nil,
        weekdays: [.monday, .wednesday],
        timeRange: nil,
        creationTimeZoneIdentifier: "Asia/Shanghai",
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
    )
    originalState.recurrence.series[series.id] = series
    originalState.recurrence.exceptions[futureExceptionKey] = .modified(.init(
        displayedDate: futureExceptionDisplayedDate,
        title: "未来改期",
        kind: .task,
        categoryID: uncategorizedID,
        timeRange: nil
    ))
    originalState.recurrence.exceptions[pastExceptionKey] = .modified(.init(
        displayedDate: pastExceptionKey.originalDate,
        title: "过去改期",
        kind: .task,
        categoryID: uncategorizedID,
        timeRange: nil
    ))
    originalState.recurrence.completions[futureCompletionKey] = .init(
        key: futureCompletionKey,
        completedAt: futureCompletedAt
    )
    originalState.recurrence.completions[pastCompletionKey] = .init(
        key: pastCompletionKey,
        completedAt: Date(timeIntervalSince1970: 400)
    )

    return DropHarness(
        originalState: originalState,
        boundaryMonday: boundaryMonday,
        destinationTuesday: destinationTuesday,
        futureExceptionKey: futureExceptionKey,
        futureExceptionDisplayedDate: futureExceptionDisplayedDate,
        futureCompletionKey: futureCompletionKey,
        futureCompletedAt: futureCompletedAt,
        pastExceptionKey: pastExceptionKey,
        pastCompletionKey: pastCompletionKey
    )
}
