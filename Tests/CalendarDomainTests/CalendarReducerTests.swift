import Foundation
import Testing
@testable import CalendarDomain

@Suite("CalendarReducerTests")
struct CalendarReducerTests {
    @Test func movingMultiDayItemPreservesInclusiveDurationAndTimes() throws {
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000370")!
        let original = try makeItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000371")!,
            categoryID: categoryID,
            schedule: try CalendarSchedule(
                startDate: CalendarDate(year: 2026, month: 8, day: 6)!,
                endDate: CalendarDate(year: 2026, month: 8, day: 8)!,
                startTime: MinuteOfDay(hour: 23, minute: 0)!,
                endTime: MinuteOfDay(hour: 1, minute: 0)!
            )
        )
        let expectedSchedule = try CalendarSchedule(
            startDate: CalendarDate(year: 2026, month: 8, day: 10)!,
            endDate: CalendarDate(year: 2026, month: 8, day: 12)!,
            startTime: MinuteOfDay(hour: 23, minute: 0)!,
            endTime: MinuteOfDay(hour: 1, minute: 0)!
        )

        let result = try CalendarReducer.reduce(
            state(containing: original),
            command: .moveItem(
                original.id,
                to: CalendarDate(year: 2026, month: 8, day: 10)!
            ),
            now: .now
        )

        #expect(result.items[original.id]?.schedule == expectedSchedule)
    }

    @Test func completingMultiDayTaskUpdatesTheSingleSourceItem() throws {
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000372")!
        let taskID = UUID(uuidString: "00000000-0000-0000-0000-000000000373")!
        let completedAt = Date(timeIntervalSince1970: 1_754_352_000)
        let task = try makeItem(
            id: taskID,
            categoryID: categoryID,
            schedule: try CalendarSchedule(
                startDate: CalendarDate(year: 2026, month: 8, day: 6)!,
                endDate: CalendarDate(year: 2026, month: 8, day: 8)!,
                startTime: MinuteOfDay(hour: 23, minute: 0)!,
                endTime: MinuteOfDay(hour: 1, minute: 0)!
            )
        )

        let result = try CalendarReducer.reduce(
            state(containing: task),
            command: .setTaskCompleted(taskID, completedAt),
            now: .now
        )

        #expect(result.items[taskID]?.completedAt == completedAt)
        #expect(result.items.count == 1)
    }

    @Test func deletingCategoryMigratesEveryReferenceAtomically() throws {
        let fixture = try makeCategoryReferenceFixture()
        let result = try CalendarReducer.reduce(
            fixture.state,
            command: .deleteCategory(
                fixture.deletedCategoryID,
                migrateTo: fixture.targetCategoryID
            ),
            now: .now
        )
        #expect(result.categories[fixture.deletedCategoryID] == nil)
        #expect(result.items.values.allSatisfy { $0.categoryID != fixture.deletedCategoryID })
        #expect(result.recurrence.series.values.allSatisfy {
            $0.categoryID != fixture.deletedCategoryID
        })
        #expect(result.recurrence.exceptions.values.allSatisfy {
            switch $0 {
            case .skipped:
                return true
            case .modified(let override):
                return override.categoryID != fixture.deletedCategoryID
            }
        })
    }

    @Test func hiddenCategoriesDoNotCountTowardOverflow() throws {
        let fixture = try makeCategoryReferenceFixture()
        var state = fixture.state
        let date = CalendarDate(year: 2026, month: 8, day: 3)!
        for index in 0..<6 {
            let categoryID = index < 3 ? fixture.deletedCategoryID : fixture.targetCategoryID
            let item = try CalendarItem(
                id: UUID(), kind: .task, title: "事项 \(index)",
                categoryID: categoryID, date: date, timeRange: nil,
                completedAt: nil,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
            state.items[item.id] = item
        }
        let projection = MonthProjection.make(
            monthContaining: .init(year: 2026, month: 8, day: 1)!,
            state: state,
            hiddenCategoryIDs: [fixture.deletedCategoryID]
        )
        #expect(projection.day(date).items.count == 3)
    }

    @Test func completingEventThrows() throws {
        let fixture = try makeCategoryReferenceFixture()
        let event = try makeItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000310")!,
            kind: .event,
            categoryID: fixture.targetCategoryID
        )
        var state = fixture.state
        state.items[event.id] = event
        let before = state

        #expect(throws: ReducerError.eventCannotComplete) {
            try CalendarReducer.reduce(
                state,
                command: .setTaskCompleted(event.id, Date(timeIntervalSince1970: 1)),
                now: .now
            )
        }
        #expect(state == before)
    }

    @Test func deletingUncategorizedThrows() throws {
        let fixture = try makeCategoryReferenceFixture()
        #expect(throws: ReducerError.protectedCategory) {
            try CalendarReducer.reduce(
                fixture.state,
                command: .deleteCategory(
                    fixture.state.uncategorizedID,
                    migrateTo: fixture.targetCategoryID
                ),
                now: .now
            )
        }
    }

    @Test func renamingOrRecoloringUncategorizedThrows() throws {
        let fixture = try makeCategoryReferenceFixture()
        let uncategorized = try #require(fixture.state.categories[fixture.state.uncategorizedID])
        var renamed = uncategorized
        renamed.name = "其它"
        #expect(throws: ReducerError.protectedCategory) {
            try CalendarReducer.reduce(
                fixture.state,
                command: .updateCategory(renamed),
                now: .now
            )
        }

        var recolored = uncategorized
        recolored.colorHex = "#000000"
        #expect(throws: ReducerError.protectedCategory) {
            try CalendarReducer.reduce(
                fixture.state,
                command: .updateCategory(recolored),
                now: .now
            )
        }

        let reordered = try CalendarReducer.reduce(
            fixture.state,
            command: .reorderCategories([
                fixture.targetCategoryID,
                fixture.deletedCategoryID,
                fixture.state.uncategorizedID
            ]),
            now: .now
        )
        #expect(reordered.categories[fixture.state.uncategorizedID]?.name == "未分类")
        #expect(reordered.categories[fixture.state.uncategorizedID]?.colorHex == "#8E8E93")
    }

    @Test func movingTimedItemPreservesTimeRange() throws {
        let fixture = try makeCategoryReferenceFixture()
        let itemID = try #require(fixture.state.items.keys.first)
        let range = try LocalTimeRange(
            start: .init(hour: 9, minute: 0)!,
            end: .init(hour: 10, minute: 0)!
        )
        var state = fixture.state
        let existing = try #require(state.items[itemID])
        state.items[itemID] = try CalendarItem(
            id: existing.id,
            kind: existing.kind,
            title: existing.title,
            categoryID: existing.categoryID,
            schedule: CalendarSchedule(
                startDate: existing.schedule.startDate,
                endDate: existing.schedule.startDate,
                startTime: range.start,
                endTime: range.end
            ),
            creationTimeZoneIdentifier: existing.creationTimeZoneIdentifier,
            completedAt: existing.completedAt,
            createdAt: existing.createdAt,
            updatedAt: existing.updatedAt
        )
        let destination = CalendarDate(year: 2026, month: 8, day: 20)!

        let result = try CalendarReducer.reduce(
            state,
            command: .moveItem(itemID, to: destination),
            now: .now
        )
        #expect(result.items[itemID]?.schedule.startDate == destination)
        #expect(result.items[itemID]?.schedule.startTime == range.start)
        #expect(result.items[itemID]?.schedule.endTime == range.end)
    }

    @Test func completingOneRecurringTaskDoesNotCompleteNext() throws {
        let state = try makeRecurringTaskState()
        let series = try #require(state.recurrence.series.values.first)
        let completedKey = OccurrenceKey(
            seriesID: series.id,
            originalDate: CalendarDate(year: 2026, month: 8, day: 3)!
        )
        let nextKey = OccurrenceKey(
            seriesID: series.id,
            originalDate: CalendarDate(year: 2026, month: 8, day: 10)!
        )
        let result = try CalendarReducer.reduce(
            state,
            command: .setOccurrenceCompleted(completedKey, Date(timeIntervalSince1970: 100)),
            now: .now
        )
        #expect(Set(result.recurrence.completions.keys) == [completedKey])
        let projected = MonthProjection.make(
            monthContaining: CalendarDate(year: 2026, month: 8, day: 1)!,
            state: result,
            hiddenCategoryIDs: []
        )
        let next = try #require(projected.day(nextKey.originalDate).items.first {
            $0.id == "occurrence:\(series.id.uuidString):2026-08-10"
        })
        #expect(next.completedAt == nil)
    }

    @Test func completingRecurringEventThrows() throws {
        let fixture = try makeCategoryReferenceFixture()
        let state = fixture.state
        let key = OccurrenceKey(
            seriesID: try #require(state.recurrence.series.keys.first),
            originalDate: CalendarDate(year: 2026, month: 8, day: 3)!
        )
        let before = state
        #expect(throws: ReducerError.eventCannotComplete) {
            try CalendarReducer.reduce(
                state,
                command: .setOccurrenceCompleted(key, Date(timeIntervalSince1970: 1)),
                now: .now
            )
        }
        #expect(state == before)
    }

    @Test func updatingCompletedTaskToEventClearsCompletion() throws {
        let fixture = try makeCategoryReferenceFixture()
        let item = try #require(fixture.state.items.values.first)
        var state = fixture.state
        state.items[item.id]?.completedAt = Date(timeIntervalSince1970: 20)
        var event = try #require(state.items[item.id])
        event.kind = .event
        let result = try CalendarReducer.reduce(
            state,
            command: .updateItem(event),
            now: Date(timeIntervalSince1970: 30)
        )
        let updated = try #require(result.items[item.id])
        #expect(updated.kind == .event)
        #expect(updated.completedAt == nil)
        #expect(updated.id == item.id)
        #expect(updated.createdAt == item.createdAt)
        try CalendarStateValidator.validate(result)
    }

    @Test func projectionSortsUntimedBeforeTimed() throws {
        let fixture = try makeCategoryReferenceFixture()
        let date = CalendarDate(year: 2026, month: 8, day: 3)!
        let untimedID = UUID(uuidString: "00000000-0000-0000-0000-000000000320")!
        let earlyTimedID = UUID(uuidString: "00000000-0000-0000-0000-000000000321")!
        let lateTimedID = UUID(uuidString: "00000000-0000-0000-0000-000000000322")!
        var state = fixture.state
        state.recurrence = .init(series: [:], exceptions: [:], completions: [:])
        state.items = [
            untimedID: try makeItem(id: untimedID, categoryID: fixture.targetCategoryID, date: date),
            earlyTimedID: try makeItem(
                id: earlyTimedID,
                categoryID: fixture.targetCategoryID,
                date: date,
                timeRange: try makeTimeRange(hour: 8)
            ),
            lateTimedID: try makeItem(
                id: lateTimedID,
                categoryID: fixture.targetCategoryID,
                date: date,
                timeRange: try makeTimeRange(hour: 10)
            )
        ]
        let projection = MonthProjection.make(
            monthContaining: date,
            state: state,
            hiddenCategoryIDs: []
        )
        #expect(projection.day(date).items.map(\.id) == [
            "item:\(untimedID.uuidString)",
            "item:\(earlyTimedID.uuidString)",
            "item:\(lateTimedID.uuidString)"
        ])
    }

    @Test func equalTimeProjectionUsesCreationThenStableID() throws {
        let fixture = try makeCategoryReferenceFixture()
        let date = CalendarDate(year: 2026, month: 8, day: 3)!
        let earlierID = UUID(uuidString: "00000000-0000-0000-0000-000000000330")!
        let stableFirstID = UUID(uuidString: "00000000-0000-0000-0000-000000000331")!
        let stableSecondID = UUID(uuidString: "00000000-0000-0000-0000-000000000332")!
        let range = try makeTimeRange(hour: 9)
        var state = fixture.state
        state.recurrence = .init(series: [:], exceptions: [:], completions: [:])
        state.items = [
            stableSecondID: try makeItem(
                id: stableSecondID, categoryID: fixture.targetCategoryID, date: date,
                timeRange: range, createdAt: Date(timeIntervalSince1970: 10)
            ),
            stableFirstID: try makeItem(
                id: stableFirstID, categoryID: fixture.targetCategoryID, date: date,
                timeRange: range, createdAt: Date(timeIntervalSince1970: 10)
            ),
            earlierID: try makeItem(
                id: earlierID, categoryID: fixture.targetCategoryID, date: date,
                timeRange: range, createdAt: Date(timeIntervalSince1970: 1)
            )
        ]
        let projection = MonthProjection.make(
            monthContaining: date,
            state: state,
            hiddenCategoryIDs: []
        )
        #expect(projection.day(date).items.map(\.id) == [
            "item:\(earlierID.uuidString)",
            "item:\(stableFirstID.uuidString)",
            "item:\(stableSecondID.uuidString)"
        ])
    }

    @Test func validatorAcceptsFirstOccurrenceSplitWithoutOldShell() throws {
        let state = try makeRecurringTaskState()
        let old = try #require(state.recurrence.series.values.first)
        let newID = UUID(uuidString: "00000000-0000-0000-0000-000000000340")!
        let graph = try SeriesMutationEngine.apply(
            edit: .patch(.init(title: "新的系列")),
            to: .init(seriesID: old.id, originalDate: old.startDate),
            scope: .thisAndFuture,
            in: state.recurrence,
            newSeriesID: newID,
            now: .now
        )
        var split = state
        split.recurrence = graph
        try CalendarStateValidator.validate(split)
        #expect(split.recurrence.series[old.id] == nil)
        #expect(split.recurrence.series.values.allSatisfy {
            $0.endDate == nil || $0.endDate! >= $0.startDate
        })
    }

    @Test func validatorAcceptsFilteredFutureCompletionMigration() throws {
        let state = try makeRecurringTaskState(endDate: CalendarDate(year: 2026, month: 8, day: 31)!)
        let old = try #require(state.recurrence.series.values.first)
        let pastKey = OccurrenceKey(seriesID: old.id, originalDate: old.startDate)
        let boundary = OccurrenceKey(
            seriesID: old.id,
            originalDate: CalendarDate(year: 2026, month: 8, day: 10)!
        )
        let naturalKey = OccurrenceKey(
            seriesID: old.id,
            originalDate: CalendarDate(year: 2026, month: 8, day: 17)!
        )
        let modifiedKey = OccurrenceKey(
            seriesID: old.id,
            originalDate: CalendarDate(year: 2026, month: 8, day: 19)!
        )
        let newID = UUID(uuidString: "00000000-0000-0000-0000-000000000341")!
        var graph = state.recurrence
        graph.exceptions[modifiedKey] = .modified(.init(
            displayedDate: modifiedKey.originalDate,
            title: old.title,
            kind: .task,
            categoryID: old.categoryID,
            timeRange: old.timeRange
        ))
        for (index, key) in [pastKey, naturalKey, modifiedKey].enumerated() {
            graph.completions[key] = .init(
                key: key,
                completedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        let migrated = try SeriesMutationEngine.apply(
            edit: .patch(.init(weekdays: [.monday])),
            to: boundary,
            scope: .thisAndFuture,
            in: graph,
            newSeriesID: newID,
            now: .now
        )
        var valid = state
        valid.recurrence = migrated
        try CalendarStateValidator.validate(valid)

        let skippedKey = OccurrenceKey(
            seriesID: newID,
            originalDate: CalendarDate(year: 2026, month: 8, day: 24)!
        )
        var skipped = valid
        skipped.recurrence.exceptions[skippedKey] = .skipped
        skipped.recurrence.completions[skippedKey] = .init(key: skippedKey, completedAt: .now)
        #expect(throws: ReducerError.invalidState) {
            try CalendarStateValidator.validate(skipped)
        }

        let nonexistentKey = OccurrenceKey(
            seriesID: newID,
            originalDate: CalendarDate(year: 2026, month: 8, day: 25)!
        )
        var nonexistent = valid
        nonexistent.recurrence.completions[nonexistentKey] = .init(
            key: nonexistentKey,
            completedAt: .now
        )
        #expect(throws: ReducerError.invalidState) {
            try CalendarStateValidator.validate(nonexistent)
        }

        let eventKey = OccurrenceKey(
            seriesID: newID,
            originalDate: CalendarDate(year: 2026, month: 8, day: 19)!
        )
        var event = valid
        event.recurrence.exceptions[eventKey] = .modified(.init(
            displayedDate: eventKey.originalDate,
            title: "例会",
            kind: .event,
            categoryID: old.categoryID,
            timeRange: nil
        ))
        event.recurrence.completions[eventKey] = .init(key: eventKey, completedAt: .now)
        #expect(throws: ReducerError.invalidState) {
            try CalendarStateValidator.validate(event)
        }
    }

    @Test func validatorRejectsMismatchedDictionaryKeysAndDanglingReferences() throws {
        let fixture = try makeCategoryReferenceFixture()
        let category = try #require(fixture.state.categories[fixture.state.uncategorizedID])
        var mismatchedCategory = fixture.state
        mismatchedCategory.categories = [UUID(): category]
        #expect(throws: ReducerError.invalidState) {
            try CalendarStateValidator.validate(mismatchedCategory)
        }

        var dangling = fixture.state
        let itemID = try #require(dangling.items.keys.first)
        dangling.items[itemID]?.categoryID = UUID()
        #expect(throws: ReducerError.invalidState) {
            try CalendarStateValidator.validate(dangling)
        }
    }

    @Test func creatingCategoryTrimsNameAndNormalizesColor() throws {
        let fixture = try makeCategoryReferenceFixture()
        let category = CalendarCategory(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000360")!,
            name: "  健康  ",
            colorHex: "#a1b2c3",
            sortIndex: 99,
            createdAt: .init(timeIntervalSince1970: 0),
            updatedAt: .init(timeIntervalSince1970: 0)
        )
        let result = try CalendarReducer.reduce(
            fixture.state,
            command: .createCategory(category),
            now: .now
        )
        #expect(result.categories[category.id]?.name == "健康")
        #expect(result.categories[category.id]?.colorHex == "#A1B2C3")
        #expect(result.categories[category.id]?.sortIndex == 3)
    }

    @Test func creatingCategoryRejectsFullWidthHexDigits() throws {
        let fixture = try makeCategoryReferenceFixture()
        let category = CalendarCategory(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000361")!,
            name: "健康",
            colorHex: "#ＡＢＣＤＥＦ",
            sortIndex: 0,
            createdAt: .init(timeIntervalSince1970: 0),
            updatedAt: .init(timeIntervalSince1970: 0)
        )
        #expect(throws: ReducerError.invalidCategoryColor) {
            try CalendarReducer.reduce(
                fixture.state,
                command: .createCategory(category),
                now: .now
            )
        }
    }

    @Test func categoryNamesIgnoreCaseButKeepDiacriticDifferences() throws {
        let uncategorizedID = UUID(uuidString: "00000000-0000-0000-0000-000000000362")!
        let state = CalendarState.empty(uncategorizedID: uncategorizedID, now: .now)
        let resume = CalendarCategory(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000363")!,
            name: "Resume",
            colorHex: "#4F7FFF",
            sortIndex: 0,
            createdAt: .now,
            updatedAt: .now
        )
        let withResume = try CalendarReducer.reduce(
            state,
            command: .createCategory(resume),
            now: .now
        )
        let caseVariant = CalendarCategory(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000364")!,
            name: "resume",
            colorHex: "#53A66F",
            sortIndex: 0,
            createdAt: .now,
            updatedAt: .now
        )
        #expect(throws: ReducerError.duplicateCategoryName) {
            try CalendarReducer.reduce(
                withResume,
                command: .createCategory(caseVariant),
                now: .now
            )
        }

        let accented = CalendarCategory(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000365")!,
            name: "résumé",
            colorHex: "#D65E73",
            sortIndex: 0,
            createdAt: .now,
            updatedAt: .now
        )
        let result = try CalendarReducer.reduce(
            withResume,
            command: .createCategory(accented),
            now: .now
        )
        #expect(result.categories[accented.id]?.name == "résumé")
    }

    private func makeRecurringTaskState(endDate: CalendarDate? = nil) throws -> CalendarState {
        let uncategorizedID = UUID(uuidString: "00000000-0000-0000-0000-000000000350")!
        let state = CalendarState.empty(uncategorizedID: uncategorizedID, now: .init(timeIntervalSince1970: 0))
        let series = try WeeklySeries(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000351")!,
            kind: .task,
            title: "周计划",
            categoryID: uncategorizedID,
            startDate: CalendarDate(year: 2026, month: 8, day: 3)!,
            endDate: endDate,
            weekdays: [.monday],
            timeRange: nil,
            createdAt: .init(timeIntervalSince1970: 0),
            updatedAt: .init(timeIntervalSince1970: 0)
        )
        var withSeries = state
        withSeries.recurrence.series[series.id] = series
        return withSeries
    }

    private func makeItem(
        id: UUID,
        kind: ItemKind = .task,
        categoryID: UUID,
        date: CalendarDate = CalendarDate(year: 2026, month: 8, day: 3)!,
        timeRange: LocalTimeRange? = nil,
        schedule: CalendarSchedule? = nil,
        createdAt: Date = .init(timeIntervalSince1970: 0)
    ) throws -> CalendarItem {
        let itemSchedule: CalendarSchedule
        if let schedule {
            itemSchedule = schedule
        } else {
            itemSchedule = try CalendarSchedule(
                startDate: date,
                endDate: date,
                startTime: timeRange?.start,
                endTime: timeRange?.end
            )
        }
        return try CalendarItem(
            id: id,
            kind: kind,
            title: "事项",
            categoryID: categoryID,
            schedule: itemSchedule,
            completedAt: nil,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    private func state(containing item: CalendarItem) -> CalendarState {
        var state = CalendarState.empty(uncategorizedID: item.categoryID, now: .distantPast)
        state.items[item.id] = item
        return state
    }

    private func makeTimeRange(hour: Int) throws -> LocalTimeRange {
        try .init(
            start: .init(hour: hour, minute: 0)!,
            end: .init(hour: hour + 1, minute: 0)!
        )
    }
}

private struct CategoryReferenceFixture {
    let state: CalendarState
    let deletedCategoryID: UUID
    let targetCategoryID: UUID
}

private func makeCategoryReferenceFixture() throws -> CategoryReferenceFixture {
    let deleted = CalendarCategory(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
        name: "工作",
        colorHex: "#4F7FFF",
        sortIndex: 1,
        createdAt: .init(timeIntervalSince1970: 0),
        updatedAt: .init(timeIntervalSince1970: 0)
    )
    let target = CalendarCategory(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000302")!,
        name: "生活",
        colorHex: "#53A66F",
        sortIndex: 2,
        createdAt: .init(timeIntervalSince1970: 0),
        updatedAt: .init(timeIntervalSince1970: 0)
    )
    let uncategorized = CalendarCategory(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000300")!,
        name: "未分类",
        colorHex: "#8E8E93",
        sortIndex: 0,
        createdAt: .init(timeIntervalSince1970: 0),
        updatedAt: .init(timeIntervalSince1970: 0)
    )
    let item = try CalendarItem(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000303")!,
        kind: .task,
        title: "写方案",
        categoryID: deleted.id,
        date: .init(year: 2026, month: 8, day: 3)!,
        timeRange: nil,
        completedAt: nil,
        createdAt: .init(timeIntervalSince1970: 0),
        updatedAt: .init(timeIntervalSince1970: 0)
    )
    let series = try WeeklySeries(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000304")!,
        kind: .event,
        title: "例会",
        categoryID: deleted.id,
        startDate: .init(year: 2026, month: 8, day: 3)!,
        endDate: nil,
        weekdays: [.monday],
        timeRange: nil,
        createdAt: .init(timeIntervalSince1970: 0),
        updatedAt: .init(timeIntervalSince1970: 0)
    )
    let exceptionKey = OccurrenceKey(
        seriesID: series.id,
        originalDate: .init(year: 2026, month: 8, day: 10)!
    )
    let exception = OccurrenceOverride(
        displayedDate: exceptionKey.originalDate,
        title: "改期例会",
        kind: .event,
        categoryID: deleted.id,
        timeRange: nil
    )
    return .init(
        state: .init(
            categories: [
                uncategorized.id: uncategorized,
                deleted.id: deleted,
                target.id: target
            ],
            items: [item.id: item],
            recurrence: .init(
                series: [series.id: series],
                exceptions: [exceptionKey: .modified(exception)],
                completions: [:]
            ),
            uncategorizedID: uncategorized.id
        ),
        deletedCategoryID: deleted.id,
        targetCategoryID: target.id
    )
}
