import CalendarDomain
import Foundation
import Testing
@testable import CalendarApp

@Suite("ItemEditorViewModelTests")
@MainActor
struct ItemEditorViewModelTests {
    @Test func dayDrawerRetargetsDateItemsAndQuickCreateWhenExternalDateChanges() throws {
        let dateA = CalendarDate(year: 2026, month: 8, day: 3)!
        let dateB = CalendarDate(year: 2026, month: 8, day: 4)!
        var state = makeEmptyState()
        let itemA = try makeItem(categoryID: state.uncategorizedID, title: "A 日事项", date: dateA)
        let itemB = try makeItem(categoryID: state.uncategorizedID, title: "B 日事项", date: dateB)
        state.items[itemA.id] = itemA
        state.items[itemB.id] = itemB

        let model = DayDrawerViewModel(date: dateA, state: state, hiddenCategoryIDs: [])
        #expect(model.date == dateA)
        #expect(model.items.map(\.title) == ["A 日事项"])
        #expect(model.quickCreateDate == dateA)

        model.retarget(date: dateB, state: state, hiddenCategoryIDs: [])

        #expect(model.date == dateB)
        #expect(model.items.map(\.title) == ["B 日事项"])
        #expect(model.quickCreateDate == dateB)
    }

    @Test func untimedDraftCreatesItemWithNoTimeRange() throws {
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000601")!
        let draft = ItemDraft(
            kind: .task,
            title: "整理桌面",
            categoryID: categoryID,
            startDate: .init(year: 2026, month: 8, day: 3)!,
            endDate: .init(year: 2026, month: 8, day: 3)!,
            usesTime: false,
            startTime: MinuteOfDay(hour: 9, minute: 0)!,
            endTime: MinuteOfDay(hour: 10, minute: 0)!,
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
        #expect(item.schedule.startTime == nil)
        #expect(item.schedule.endTime == nil)
        #expect(item.creationTimeZoneIdentifier == "Asia/Shanghai")
    }

    @Test func rangeDraftCreatesOneMultiDayItem() throws {
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000601")!
        let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000602")!
        var draft = ItemDraft.newItem(
            from: CalendarDate(year: 2026, month: 8, day: 6)!,
            through: CalendarDate(year: 2026, month: 8, day: 8)!,
            categoryID: categoryID
        )
        draft.title = "三日事项"

        let command = try ItemEditorViewModel(mode: .create, draft: draft).makeCommand(
            now: .distantPast,
            newItemID: itemID,
            newSeriesID: UUID(),
            timeZoneIdentifier: "Asia/Shanghai"
        )
        guard case let .createItem(item) = command else {
            Issue.record("Expected createItem")
            return
        }
        #expect(item.id == itemID)
        let expectedSchedule = try CalendarSchedule(
            startDate: CalendarDate(year: 2026, month: 8, day: 6)!,
            endDate: CalendarDate(year: 2026, month: 8, day: 8)!,
            startTime: nil,
            endTime: nil
        )
        #expect(item.schedule == expectedSchedule)
    }

    @Test func timedRangeDraftAllowsOvernightButRejectsReversedDatesWithoutClearingInput() throws {
        let overnightStart = CalendarDate(year: 2026, month: 8, day: 6)!
        let overnightEnd = CalendarDate(year: 2026, month: 8, day: 7)!
        var overnightDraft = ItemDraft.newItem(
            from: overnightStart,
            through: overnightEnd,
            categoryID: UUID()
        )
        overnightDraft.title = "跨夜事项"
        overnightDraft.usesTime = true
        overnightDraft.startTime = MinuteOfDay(hour: 23, minute: 0)!
        overnightDraft.endTime = MinuteOfDay(hour: 1, minute: 0)!
        let overnightCommand = try ItemEditorViewModel(mode: .create, draft: overnightDraft).makeCommand(
            now: .distantPast,
            newItemID: UUID(),
            newSeriesID: UUID(),
            timeZoneIdentifier: "Asia/Shanghai"
        )
        guard case let .createItem(overnightItem) = overnightCommand else {
            Issue.record("Expected createItem")
            return
        }
        #expect(overnightItem.schedule.startDate == overnightStart)
        #expect(overnightItem.schedule.endDate == overnightEnd)
        #expect(overnightItem.schedule.startTime == MinuteOfDay(hour: 23, minute: 0)!)
        #expect(overnightItem.schedule.endTime == MinuteOfDay(hour: 1, minute: 0)!)

        let startDate = CalendarDate(year: 2026, month: 8, day: 7)!
        let endDate = CalendarDate(year: 2026, month: 8, day: 6)!
        var draft = ItemDraft.newItem(from: startDate, through: endDate, categoryID: UUID())
        draft.title = "跨夜事项"
        draft.usesTime = true
        draft.startTime = MinuteOfDay(hour: 23, minute: 0)!
        draft.endTime = MinuteOfDay(hour: 1, minute: 0)!
        let vm = ItemEditorViewModel(mode: .create, draft: draft)

        #expect(throws: ItemEditorError.invalidDateRange) {
            try vm.makeCommand(
                now: Date(timeIntervalSince1970: 1_775_664_000),
                newItemID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
                newSeriesID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                timeZoneIdentifier: "Asia/Shanghai"
            )
        }
        #expect(vm.validationMessage == "结束日期不能早于开始日期")
        #expect(vm.draft.startDate == startDate)
        #expect(vm.draft.endDate == endDate)
    }

    @Test func editingOccurrencePatchesDisplayedRangeAndPairedTimes() throws {
        let series = try WeeklySeries(
            id: UUID(),
            kind: .event,
            title: "跨日例会",
            categoryID: makeEmptyState().uncategorizedID,
            ruleStartDate: CalendarDate(year: 2026, month: 8, day: 3)!,
            recurrenceEndDate: nil,
            weekdays: [.monday],
            durationDays: 2,
            startTime: MinuteOfDay(hour: 23, minute: 0)!,
            endTime: MinuteOfDay(hour: 1, minute: 0)!,
            creationTimeZoneIdentifier: "Asia/Shanghai",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let key = OccurrenceKey(seriesID: series.id, originalDate: series.ruleStartDate)
        let occurrence = CalendarOccurrence(
            key: key,
            schedule: try CalendarSchedule(
                startDate: CalendarDate(year: 2026, month: 8, day: 3)!,
                endDate: CalendarDate(year: 2026, month: 8, day: 4)!,
                startTime: MinuteOfDay(hour: 23, minute: 0)!,
                endTime: MinuteOfDay(hour: 1, minute: 0)!
            ),
            title: series.title,
            kind: series.kind,
            categoryID: series.categoryID,
            creationTimeZoneIdentifier: series.creationTimeZoneIdentifier,
            completedAt: nil,
            createdAt: series.createdAt
        )
        var draft = ItemDraft(occurrence: occurrence, series: series)
        let vm = ItemEditorViewModel(
            mode: .editOccurrence(series: series, key: key, scope: .onlyThis),
            draft: draft
        )
        draft.startDate = CalendarDate(year: 2026, month: 8, day: 4)!
        draft.endDate = CalendarDate(year: 2026, month: 8, day: 6)!
        draft.startTime = MinuteOfDay(hour: 22, minute: 0)!
        draft.endTime = MinuteOfDay(hour: 2, minute: 0)!
        vm.draft = draft

        let command = try vm.makeCommand(
            now: .now,
            newItemID: UUID(),
            newSeriesID: UUID(),
            timeZoneIdentifier: "Asia/Shanghai"
        )
        guard case let .mutateSeries(commandKey, scope, .patch(patch), _) = command else {
            Issue.record("Expected a recurring series patch")
            return
        }
        #expect(commandKey == key)
        #expect(scope == .onlyThis)
        #expect(patch.displayedStartDate == CalendarDate(year: 2026, month: 8, day: 4)!)
        #expect(patch.durationDays == 3)
        guard case let .set(startTime) = patch.startTime,
              case let .set(endTime) = patch.endTime
        else {
            Issue.record("Expected paired time patches")
            return
        }
        #expect(startTime == MinuteOfDay(hour: 22, minute: 0)!)
        #expect(endTime == MinuteOfDay(hour: 2, minute: 0)!)
    }

    @Test func editorRejectsReversedTimeWithoutClearingDraft() {
        let draft = ItemDraft(
            kind: .event,
            title: "评审",
            categoryID: UUID(),
            startDate: .init(year: 2026, month: 8, day: 4)!,
            endDate: .init(year: 2026, month: 8, day: 4)!,
            usesTime: true,
            startTime: MinuteOfDay(hour: 9, minute: 0)!,
            endTime: MinuteOfDay(hour: 8, minute: 0)!,
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
            startDate: .init(year: 2026, month: 8, day: 4)!,
            endDate: .init(year: 2026, month: 8, day: 4)!,
            usesTime: false,
            startTime: MinuteOfDay(hour: 9, minute: 0)!,
            endTime: MinuteOfDay(hour: 10, minute: 0)!,
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
            startDate: CalendarDate(year: 2026, month: 8, day: 3)!,
            endDate: CalendarDate(year: 2026, month: 8, day: 3)!,
            usesTime: true,
            startTime: MinuteOfDay(hour: 9, minute: 0)!,
            endTime: MinuteOfDay(hour: 10, minute: 0)!,
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
        #expect(series.recurrenceEndDate == end)
        #expect(series.creationTimeZoneIdentifier == "Asia/Shanghai")
        #expect(series.startTime == draft.startTime)
    }

    @Test func editingItemPreservesIdentityAndCreationMetadata() throws {
        let original = try CalendarItem(
            id: UUID(), kind: .task, title: "原事项", categoryID: UUID(),
            schedule: CalendarSchedule(
                startDate: CalendarDate(year: 2026, month: 8, day: 3)!,
                endDate: CalendarDate(year: 2026, month: 8, day: 3)!,
                startTime: nil,
                endTime: nil
            ),
            creationTimeZoneIdentifier: "America/Los_Angeles", completedAt: nil,
            createdAt: .distantPast, updatedAt: .distantPast
        )
        var draft = ItemDraft(item: original)
        draft.title = "新事项"
        draft.endDate = CalendarDate(year: 2026, month: 8, day: 5)!
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
        #expect(item.schedule.startDate == CalendarDate(year: 2026, month: 8, day: 3)!)
        #expect(item.schedule.endDate == CalendarDate(year: 2026, month: 8, day: 5)!)
        #expect(item.schedule.startTime != nil)
        #expect(item.schedule.endTime != nil)
    }

    @Test func editingCompletedTaskIntoEventClearsCompletion() throws {
        let original = try CalendarItem(
            id: UUID(), kind: .task, title: "已完成", categoryID: UUID(),
            schedule: CalendarSchedule(
                startDate: CalendarDate(year: 2026, month: 8, day: 3)!,
                endDate: CalendarDate(year: 2026, month: 8, day: 3)!,
                startTime: nil,
                endTime: nil
            ),
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
        let key = OccurrenceKey(seriesID: series.id, originalDate: series.ruleStartDate)
        let newSeriesID = UUID()
        let vm = ItemEditorViewModel(
            mode: .editOccurrence(series: series, key: key, scope: .thisAndFuture),
            draft: ItemDraft(series: series, date: series.ruleStartDate)
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

    @Test func editingMovedOccurrenceWithExplicitWeekdaysPersistsSelectedRulesAndUndo() async throws {
        var original = makeEmptyState()
        let series = try WeeklySeries(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000801")!,
            kind: .task,
            title: "周计划",
            categoryID: original.uncategorizedID,
            ruleStartDate: .init(year: 2026, month: 8, day: 3)!,
            recurrenceEndDate: nil,
            weekdays: [.monday, .wednesday],
            durationDays: 1,
            startTime: nil,
            endTime: nil,
            creationTimeZoneIdentifier: "Asia/Shanghai",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let boundary = OccurrenceKey(
            seriesID: series.id,
            originalDate: .init(year: 2026, month: 8, day: 10)!
        )
        original.recurrence.series[series.id] = series
        let newSeriesID = UUID(uuidString: "00000000-0000-0000-0000-000000000802")!
        let vm = ItemEditorViewModel(
            mode: .editOccurrence(series: series, key: boundary, scope: .thisAndFuture),
            draft: ItemDraft(series: series, date: boundary.originalDate)
        )
        vm.draft.startDate = .init(year: 2026, month: 8, day: 11)!
        vm.draft.endDate = .init(year: 2026, month: 8, day: 11)!
        vm.draft.weekdays = [.tuesday, .thursday]

        let command = try vm.makeCommand(
            now: .now,
            newItemID: UUID(),
            newSeriesID: newSeriesID,
            timeZoneIdentifier: "Asia/Shanghai"
        )
        guard case let .mutateSeries(_, _, .patch(patch), _) = command else {
            Issue.record("Expected a recurring series patch")
            return
        }
        #expect(patch.displayedStartDate == CalendarDate(year: 2026, month: 8, day: 11)!)
        #expect(patch.weekdays == [.tuesday, .thursday])

        let (store, repository) = try await makeReadyStore(initialState: original)
        try await store.send(command, undoLabel: "已更新事项")

        #expect(store.state.recurrence.series[newSeriesID]?.weekdays == [.tuesday, .thursday])
        #expect(await repository.persistedState == store.state)
        #expect(store.canUndo)

        try await store.undo()

        #expect(store.state == original)
        #expect(await repository.persistedState == original)
        #expect(store.canUndo == false)
    }

    @Test func editingMovedExceptionTitleDoesNotShiftFuturePattern() throws {
        let series = try makeSeries()
        let key = OccurrenceKey(seriesID: series.id, originalDate: series.ruleStartDate)
        let movedDate = series.ruleStartDate.addingDays(1)
        let movedOccurrence = CalendarOccurrence(
            key: key,
            schedule: try CalendarSchedule(
                startDate: movedDate,
                endDate: movedDate,
                startTime: series.startTime,
                endTime: series.endTime
            ),
            title: "改期周会",
            kind: series.kind,
            categoryID: series.categoryID,
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
        #expect(patch.displayedStartDate == nil)

        var state = makeEmptyState()
        state.recurrence.series[series.id] = series
        state.recurrence.exceptions[key] = .modified(.init(
            displayedSchedule: movedOccurrence.schedule,
            title: movedOccurrence.title,
            kind: movedOccurrence.kind,
            categoryID: movedOccurrence.categoryID
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
        let key = OccurrenceKey(seriesID: series.id, originalDate: series.ruleStartDate)
        let command = try ItemEditorViewModel(
            mode: .editOccurrence(series: series, key: key, scope: .onlyThis),
            draft: ItemDraft(series: series, date: series.ruleStartDate)
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
        let occurrenceKey = OccurrenceKey(seriesID: UUID(), originalDate: item.schedule.startDate)
        let occurrence = CalendarOccurrence(
            key: occurrenceKey,
            schedule: item.schedule,
            title: "重复事项",
            kind: .task,
            categoryID: item.categoryID,
            creationTimeZoneIdentifier: "Asia/Shanghai",
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
            key: occurrence.key,
            schedule: occurrence.schedule,
            title: occurrence.title,
            kind: occurrence.kind,
            categoryID: occurrence.categoryID,
            creationTimeZoneIdentifier: occurrence.creationTimeZoneIdentifier,
            completedAt: .distantPast,
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
        let key = OccurrenceKey(seriesID: series.id, originalDate: series.ruleStartDate)
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
            ruleStartDate: CalendarDate(year: 2026, month: 8, day: 3)!,
            recurrenceEndDate: nil,
            weekdays: [.monday],
            durationDays: 1,
            startTime: nil,
            endTime: nil,
            creationTimeZoneIdentifier: "Asia/Shanghai",
            createdAt: .distantPast, updatedAt: .distantPast
        )
    }
}
