import CalendarDomain
import Foundation
import Testing
@testable import CalendarApp

@Suite("ItemEditorViewModelTests")
@MainActor
struct ItemEditorViewModelTests {
    @Test func untimedDraftCreatesItemWithNoTimeRange() throws {
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000601")!
        let draft = ItemDraft(
            kind: .task,
            title: "整理桌面",
            categoryID: categoryID,
            date: .init(year: 2026, month: 8, day: 3)!,
            usesTime: false,
            start: MinuteOfDay(hour: 9, minute: 0)!,
            end: MinuteOfDay(hour: 10, minute: 0)!,
            repeatsWeekly: false,
            weekdays: [],
            recurrenceEndDate: nil
        )
        let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000602")!
        let vm = ItemEditorViewModel(mode: .create, draft: draft)
        let command = try vm.makeCommand(
            now: Date(timeIntervalSince1970: 0),
            newItemID: itemID,
            newSeriesID: UUID(),
            timeZoneIdentifier: "Asia/Shanghai"
        )
        guard case .createItem(let item) = command else {
            Issue.record("Expected createItem")
            return
        }
        #expect(item.id == itemID)
        #expect(item.timeRange == nil)
        #expect(item.creationTimeZoneIdentifier == "Asia/Shanghai")
    }

    @Test func editorRejectsReversedTimeWithoutClearingDraft() {
        let draft = ItemDraft(
            kind: .event,
            title: "评审",
            categoryID: UUID(),
            date: .init(year: 2026, month: 8, day: 4)!,
            usesTime: true,
            start: MinuteOfDay(hour: 9, minute: 0)!,
            end: MinuteOfDay(hour: 8, minute: 0)!,
            repeatsWeekly: false,
            weekdays: [],
            recurrenceEndDate: nil
        )
        let vm = ItemEditorViewModel(mode: .create, draft: draft)
        #expect(throws: ItemEditorError.invalidTimeRange) {
            try vm.makeCommand(
                now: .now,
                newItemID: UUID(),
                newSeriesID: UUID(),
                timeZoneIdentifier: "Asia/Shanghai"
            )
        }
        #expect(vm.validationMessage == "结束时间必须晚于开始时间")
        #expect(vm.draft == draft)
    }

    @Test func recurrenceNeedsAtLeastOneInstanceBeforeInclusiveEnd() {
        let draft = ItemDraft(
            kind: .task,
            title: "周复盘",
            categoryID: UUID(),
            date: .init(year: 2026, month: 8, day: 4)!,
            usesTime: false,
            start: MinuteOfDay(hour: 9, minute: 0)!,
            end: MinuteOfDay(hour: 10, minute: 0)!,
            repeatsWeekly: true,
            weekdays: [.monday],
            recurrenceEndDate: .init(year: 2026, month: 8, day: 8)!
        )
        let vm = ItemEditorViewModel(mode: .create, draft: draft)
        #expect(throws: ItemEditorError.noOccurrenceInRange) {
            try vm.makeCommand(
                now: .now,
                newItemID: UUID(),
                newSeriesID: UUID(),
                timeZoneIdentifier: "Asia/Shanghai"
            )
        }
    }

    @Test func validWeeklyDraftCreatesSeriesNotItem() throws {
        let categoryID = UUID()
        let end = CalendarDate(year: 2026, month: 8, day: 31)!
        let draft = ItemDraft(
            kind: .event, title: "例会", categoryID: categoryID,
            date: CalendarDate(year: 2026, month: 8, day: 3)!, usesTime: true,
            start: MinuteOfDay(hour: 9, minute: 0)!, end: MinuteOfDay(hour: 10, minute: 0)!,
            repeatsWeekly: true, weekdays: [.monday, .wednesday], recurrenceEndDate: end
        )
        let seriesID = UUID()
        let command = try ItemEditorViewModel(mode: .create, draft: draft).makeCommand(
            now: .distantPast, newItemID: UUID(), newSeriesID: seriesID,
            timeZoneIdentifier: "Asia/Shanghai"
        )
        guard case let .createSeries(series) = command else {
            Issue.record("Expected createSeries")
            return
        }
        #expect(series.id == seriesID)
        #expect(series.weekdays == draft.weekdays)
        #expect(series.endDate == end)
        #expect(series.creationTimeZoneIdentifier == "Asia/Shanghai")
        #expect(series.timeRange?.start == draft.start)
    }

    @Test func editingItemPreservesIdentityAndCreationMetadata() throws {
        let original = try CalendarItem(
            id: UUID(), kind: .task, title: "原事项", categoryID: UUID(),
            date: CalendarDate(year: 2026, month: 8, day: 3)!, timeRange: nil,
            creationTimeZoneIdentifier: "America/Los_Angeles", completedAt: nil,
            createdAt: .distantPast, updatedAt: .distantPast
        )
        var draft = ItemDraft(item: original)
        draft.title = "新事项"
        draft.usesTime = true
        let vm = ItemEditorViewModel(mode: .editItem(original), draft: draft)
        let command = try vm.makeCommand(
            now: Date(timeIntervalSince1970: 1), newItemID: UUID(), newSeriesID: UUID(),
            timeZoneIdentifier: "Asia/Shanghai"
        )
        guard case let .updateItem(item) = command else {
            Issue.record("Expected updateItem")
            return
        }
        #expect(item.id == original.id)
        #expect(item.createdAt == original.createdAt)
        #expect(item.creationTimeZoneIdentifier == "America/Los_Angeles")
        #expect(item.title == "新事项")
        #expect(item.timeRange != nil)
    }

    @Test func editingCompletedTaskIntoEventClearsCompletion() throws {
        let original = try CalendarItem(
            id: UUID(), kind: .task, title: "已完成", categoryID: UUID(),
            date: CalendarDate(year: 2026, month: 8, day: 3)!, timeRange: nil,
            creationTimeZoneIdentifier: "Asia/Shanghai", completedAt: .distantPast,
            createdAt: .distantPast, updatedAt: .distantPast
        )
        var draft = ItemDraft(item: original)
        draft.kind = .event
        let command = try ItemEditorViewModel(mode: .editItem(original), draft: draft).makeCommand(
            now: .now, newItemID: UUID(), newSeriesID: UUID(), timeZoneIdentifier: "UTC"
        )
        guard case let .updateItem(item) = command else {
            Issue.record("Expected updateItem")
            return
        }
        #expect(item.id == original.id)
        #expect(item.createdAt == original.createdAt)
        #expect(item.creationTimeZoneIdentifier == original.creationTimeZoneIdentifier)
        #expect(item.completedAt == nil)
    }

    @Test func editingOccurrenceCarriesStableKeyAndChosenScope() throws {
        let series = try makeSeries()
        let key = OccurrenceKey(seriesID: series.id, originalDate: series.startDate)
        let newSeriesID = UUID()
        let vm = ItemEditorViewModel(
            mode: .editOccurrence(series: series, key: key, scope: .thisAndFuture),
            draft: ItemDraft(series: series, date: series.startDate)
        )
        vm.draft.title = "更新后的周会"
        let command = try vm.makeCommand(
            now: .now, newItemID: UUID(), newSeriesID: newSeriesID, timeZoneIdentifier: "UTC"
        )
        guard case let .mutateSeries(commandKey, scope, edit, commandSeriesID) = command,
              case let .patch(patch) = edit
        else {
            Issue.record("Expected patch mutation")
            return
        }
        #expect(commandKey == key)
        #expect(scope == .thisAndFuture)
        #expect(commandSeriesID == newSeriesID)
        #expect(patch.title == "更新后的周会")
    }

    @Test func editingMovedExceptionTitleDoesNotShiftFuturePattern() throws {
        let series = try makeSeries()
        let key = OccurrenceKey(seriesID: series.id, originalDate: series.startDate)
        let movedDate = series.startDate.addingDays(1)
        let movedOccurrence = CalendarOccurrence(
            key: key,
            displayedDate: movedDate,
            title: "改期周会",
            kind: series.kind,
            categoryID: series.categoryID,
            timeRange: series.timeRange,
            creationTimeZoneIdentifier: series.creationTimeZoneIdentifier,
            completedAt: nil,
            createdAt: series.createdAt
        )
        let vm = ItemEditorViewModel(
            mode: .editOccurrence(series: series, key: key, scope: .thisAndFuture),
            draft: ItemDraft(occurrence: movedOccurrence, series: series)
        )
        vm.draft.title = "仅改标题"
        let command = try vm.makeCommand(
            now: .now, newItemID: UUID(), newSeriesID: UUID(), timeZoneIdentifier: "UTC"
        )
        guard case let .mutateSeries(_, _, edit, newSeriesID) = command,
              case let .patch(patch) = edit
        else {
            Issue.record("Expected patch mutation")
            return
        }
        #expect(patch.displayedDate == nil)

        var state = makeEmptyState()
        state.recurrence.series[series.id] = series
        state.recurrence.exceptions[key] = .modified(.init(
            displayedDate: movedDate,
            title: movedOccurrence.title,
            kind: movedOccurrence.kind,
            categoryID: movedOccurrence.categoryID,
            timeRange: movedOccurrence.timeRange
        ))
        let reduced = try CalendarReducer.reduce(
            state,
            command: .mutateSeries(key, scope: .thisAndFuture, edit: .patch(patch), newSeriesID: newSeriesID),
            now: .now
        )
        #expect(reduced.recurrence.series[newSeriesID]?.weekdays == series.weekdays)
        #expect(reduced.recurrence.series[newSeriesID]?.title == "仅改标题")
    }

    @Test func deletingOneOffItemReturnsDeleteItem() async throws {
        var state = makeEmptyState()
        let item = try makeItem(categoryID: state.uncategorizedID)
        state.items[item.id] = item
        let command = try ItemEditorViewModel(
            mode: .editItem(item), draft: ItemDraft(item: item)
        ).makeDeleteCommand(newSeriesID: UUID())
        guard case let .deleteItem(id) = command else {
            Issue.record("Expected deleteItem")
            return
        }
        #expect(id == item.id)
        let (store, _) = try await makeReadyStore(initialState: state)
        try await store.send(command, undoLabel: "已删除事项")
        #expect(store.state.items[item.id] == nil)
        try await store.undo()
        #expect(store.state == state)
    }

    @Test func deletingOccurrenceUsesChosenScope() throws {
        let series = try makeSeries()
        let key = OccurrenceKey(seriesID: series.id, originalDate: series.startDate)
        let command = try ItemEditorViewModel(
            mode: .editOccurrence(series: series, key: key, scope: .onlyThis),
            draft: ItemDraft(series: series, date: series.startDate)
        ).makeDeleteCommand(newSeriesID: UUID())
        guard case let .mutateSeries(commandKey, scope, edit, _) = command,
              case .delete = edit
        else {
            Issue.record("Expected delete mutation")
            return
        }
        #expect(commandKey == key)
        #expect(scope == .onlyThis)
    }

    @Test func completionRouterUsesStableOccurrenceKey() throws {
        let item = try makeItem(categoryID: makeEmptyState().uncategorizedID)
        let occurrenceKey = OccurrenceKey(seriesID: UUID(), originalDate: item.date)
        let occurrence = CalendarOccurrence(
            key: occurrenceKey, displayedDate: item.date, title: "重复事项", kind: .task,
            categoryID: item.categoryID, timeRange: nil, creationTimeZoneIdentifier: "Asia/Shanghai",
            completedAt: nil, createdAt: .distantPast
        )
        let now = Date(timeIntervalSince1970: 7)
        guard case let .setTaskCompleted(itemID, date)? = ItemCompletionRouter.command(for: .item(item), now: now) else {
            Issue.record("Expected item completion")
            return
        }
        #expect(itemID == item.id)
        #expect(date == now)
        guard case let .setOccurrenceCompleted(key, date)? = ItemCompletionRouter.command(for: .occurrence(occurrence), now: now) else {
            Issue.record("Expected occurrence completion")
            return
        }
        #expect(key == occurrenceKey)
        #expect(date == now)

        var completedItem = item
        completedItem.completedAt = .distantPast
        var completedOccurrence = occurrence
        completedOccurrence = CalendarOccurrence(
            key: occurrence.key, displayedDate: occurrence.displayedDate, title: occurrence.title,
            kind: occurrence.kind, categoryID: occurrence.categoryID, timeRange: occurrence.timeRange,
            creationTimeZoneIdentifier: occurrence.creationTimeZoneIdentifier, completedAt: .distantPast,
            createdAt: occurrence.createdAt
        )
        guard case let .setTaskCompleted(completedID, nil)? = ItemCompletionRouter.command(for: .item(completedItem), now: now),
              case let .setOccurrenceCompleted(completedKey, nil)? = ItemCompletionRouter.command(for: .occurrence(completedOccurrence), now: now)
        else {
            Issue.record("Expected cancellation commands")
            return
        }
        #expect(completedID == item.id)
        #expect(completedKey == occurrenceKey)
        var event = item
        event.kind = .event
        #expect(ItemCompletionRouter.command(for: .item(event), now: now) == nil)
    }

    @Test func completingAndUncompletingRecurringTaskAreEachUndoable() async throws {
        let series = try makeSeries()
        let key = OccurrenceKey(seriesID: series.id, originalDate: series.startDate)
        var state = makeEmptyState()
        state.recurrence.series[series.id] = series
        let (store, repository) = try await makeReadyStore(initialState: state)
        let complete = CalendarCommand.setOccurrenceCompleted(key, Date(timeIntervalSince1970: 3))
        try await store.send(complete, undoLabel: "已完成事项")
        try await store.undo()
        #expect(store.state == state)
        #expect(await repository.persistedState == state)

        try await store.send(complete, undoLabel: "已完成事项")
        let completedState = store.state
        try await store.send(.setOccurrenceCompleted(key, nil), undoLabel: "已取消完成事项")
        try await store.undo()
        #expect(store.state == completedState)
        #expect(await repository.persistedState == completedState)
    }

    @Test func overflowAndDateNumberOpenDayWhileBlankCreates() {
        let date = CalendarDate(year: 2026, month: 8, day: 3)!
        #expect(DayCellInteractionRouter.action(for: .overflow, date: date) == .openDay(date))
        #expect(DayCellInteractionRouter.action(for: .dateNumber, date: date) == .openDay(date))
        #expect(DayCellInteractionRouter.action(for: .emptyArea, date: date) == .quickCreate(date))
        #expect(DayCellInteractionRouter.action(for: .item("item:1"), date: date) == .openItem("item:1"))
    }

    @Test func completionClickDoesNotOpenDetail() throws {
        let item = try makeItem(categoryID: makeEmptyState().uncategorizedID)
        let completion = CalendarItemRowInteractionRouter.route(
            target: .completion, item: .item(item), now: .distantPast
        )
        guard case let .setTaskCompleted(id, _)? = completion.completionCommand else {
            Issue.record("Expected completion command")
            return
        }
        #expect(id == item.id)
        #expect(completion.selectedDetailID == nil)
        let detail = CalendarItemRowInteractionRouter.route(
            target: .rowBody, item: .item(item), now: .distantPast
        )
        #expect(detail.completionCommand == nil)
        #expect(detail.selectedDetailID == ProjectedItem.item(item).id)
    }

    private func makeSeries() throws -> WeeklySeries {
        try WeeklySeries(
            id: UUID(), kind: .task, title: "周会", categoryID: makeEmptyState().uncategorizedID,
            startDate: CalendarDate(year: 2026, month: 8, day: 3)!, endDate: nil,
            weekdays: [.monday], timeRange: nil, creationTimeZoneIdentifier: "Asia/Shanghai",
            createdAt: .distantPast, updatedAt: .distantPast
        )
    }
}
