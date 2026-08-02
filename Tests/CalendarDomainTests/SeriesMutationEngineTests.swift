import Foundation
import Testing
@testable import CalendarDomain

@Suite("SeriesMutationEngineTests")
struct SeriesMutationEngineTests {
    @Test func onlyThisMoveCreatesOneModifiedException() throws {
        let series = try makeMondayWednesdaySeries(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
        )
        let key = OccurrenceKey(
            seriesID: series.id,
            originalDate: .init(year: 2026, month: 8, day: 3)!
        )
        let before = RecurrenceGraph(series: [series.id: series], exceptions: [:], completions: [:])

        let after = try SeriesMutationEngine.apply(
            edit: .patch(.init(displayedDate: .init(year: 2026, month: 8, day: 4)!)),
            to: key,
            scope: .onlyThis,
            in: before,
            newSeriesID: UUID(uuidString: "00000000-0000-0000-0000-000000000211")!,
            now: .now
        )

        #expect(after.series == before.series)
        #expect(after.exceptions.count == 1)
        #expect(after.exceptions[key] == .modified(.init(
            displayedDate: .init(year: 2026, month: 8, day: 4)!,
            title: series.title,
            kind: series.kind,
            categoryID: series.categoryID,
            timeRange: series.timeRange
        )))
    }

    @Test func onlyThisDeleteCreatesOneSkippedException() throws {
        let series = try makeMondayWednesdaySeries(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
        )
        let key = OccurrenceKey(
            seriesID: series.id,
            originalDate: .init(year: 2026, month: 8, day: 3)!
        )
        let completion = OccurrenceCompletion(
            key: key,
            completedAt: Date(timeIntervalSince1970: 100)
        )
        let before = RecurrenceGraph(
            series: [series.id: series],
            exceptions: [:],
            completions: [key: completion]
        )

        let after = try SeriesMutationEngine.apply(
            edit: .delete,
            to: key,
            scope: .onlyThis,
            in: before,
            newSeriesID: UUID(uuidString: "00000000-0000-0000-0000-000000000212")!,
            now: .now
        )

        #expect(after.series == before.series)
        #expect(after.exceptions == [key: .skipped])
        #expect(after.completions[key] == nil)
        #expect(before.completions[key] == completion)
    }

    @Test func onlyThisPatchBuildsOnExistingModifiedException() throws {
        let series = try makeMondayWednesdaySeries(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000203")!
        )
        let key = OccurrenceKey(
            seriesID: series.id,
            originalDate: .init(year: 2026, month: 8, day: 3)!
        )
        let alternativeCategory = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let oneHour = try LocalTimeRange(
            start: .init(hour: 9, minute: 0)!,
            end: .init(hour: 10, minute: 0)!
        )
        let existing = OccurrenceOverride(
            displayedDate: .init(year: 2026, month: 8, day: 4)!,
            title: "原有标题",
            kind: .task,
            categoryID: alternativeCategory,
            timeRange: oneHour
        )
        let before = RecurrenceGraph(
            series: [series.id: series],
            exceptions: [key: .modified(existing)],
            completions: [:]
        )

        let after = try SeriesMutationEngine.apply(
            edit: .patch(.init(title: "只改标题")),
            to: key,
            scope: .onlyThis,
            in: before,
            newSeriesID: UUID(uuidString: "00000000-0000-0000-0000-000000000213")!,
            now: .now
        )

        #expect(after.exceptions[key] == .modified(.init(
            displayedDate: existing.displayedDate,
            title: "只改标题",
            kind: existing.kind,
            categoryID: existing.categoryID,
            timeRange: existing.timeRange
        )))
    }

    @Test func onlyThisTaskToEventClearsSelectedCompletion() throws {
        let series = try makeMondayWednesdaySeries(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000204")!
        )
        let key = OccurrenceKey(
            seriesID: series.id,
            originalDate: .init(year: 2026, month: 8, day: 3)!
        )
        let before = RecurrenceGraph(
            series: [series.id: series],
            exceptions: [:],
            completions: [key: .init(key: key, completedAt: Date(timeIntervalSince1970: 100))]
        )

        let after = try SeriesMutationEngine.apply(
            edit: .patch(.init(kind: .event)),
            to: key,
            scope: .onlyThis,
            in: before,
            newSeriesID: UUID(uuidString: "00000000-0000-0000-0000-000000000214")!,
            now: .now
        )

        #expect(after.completions[key] == nil)
        #expect(after.exceptions[key] == .modified(.init(
            displayedDate: key.originalDate,
            title: series.title,
            kind: .event,
            categoryID: series.categoryID,
            timeRange: series.timeRange
        )))
    }

    @Test func onlyThisRejectsRulePatches() throws {
        let series = try makeMondayWednesdaySeries(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000205")!
        )
        let key = OccurrenceKey(seriesID: series.id, originalDate: series.startDate)
        let before = RecurrenceGraph(series: [series.id: series], exceptions: [:], completions: [:])

        #expect(throws: SeriesMutationError.invalidOnlyThisRulePatch) {
            try SeriesMutationEngine.apply(
                edit: .patch(.init(weekdays: [.friday])),
                to: key,
                scope: .onlyThis,
                in: before,
                newSeriesID: UUID(uuidString: "00000000-0000-0000-0000-000000000215")!,
                now: .now
            )
        }
        #expect(throws: SeriesMutationError.invalidOnlyThisRulePatch) {
            try SeriesMutationEngine.apply(
                edit: .patch(.init(endDate: .clear)),
                to: key,
                scope: .onlyThis,
                in: before,
                newSeriesID: UUID(uuidString: "00000000-0000-0000-0000-000000000215")!,
                now: .now
            )
        }
        #expect(before == RecurrenceGraph(series: [series.id: series], exceptions: [:], completions: [:]))
    }

    @Test func thisAndFutureMoveShiftsMondayWednesdayToTuesdayThursday() throws {
        let series = try makeMondayWednesdaySeries(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000206")!
        )
        let boundary = OccurrenceKey(
            seriesID: series.id,
            originalDate: .init(year: 2026, month: 8, day: 10)!
        )
        let before = RecurrenceGraph(
            series: [series.id: series],
            exceptions: [:],
            completions: [:]
        )
        let after = try SeriesMutationEngine.apply(
            edit: .patch(.init(
                displayedDate: .init(year: 2026, month: 8, day: 11)!
            )),
            to: boundary,
            scope: .thisAndFuture,
            in: before,
            newSeriesID: UUID(uuidString: "00000000-0000-0000-0000-000000000216")!,
            now: .now
        )

        let old = try #require(after.series[series.id])
        #expect(old.endDate == CalendarDate(year: 2026, month: 8, day: 9)!)
        let future = try #require(after.series.values.first { $0.id != series.id })
        #expect(future.startDate == CalendarDate(year: 2026, month: 8, day: 11)!)
        #expect(future.weekdays == [.tuesday, .thursday])
    }

    @Test func splittingPreservesPastAndMigratesFutureExceptions() throws {
        let series = try makeMondayWednesdaySeries(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000207")!
        )
        let pastKey = OccurrenceKey(
            seriesID: series.id,
            originalDate: .init(year: 2026, month: 8, day: 3)!
        )
        let boundaryKey = OccurrenceKey(
            seriesID: series.id,
            originalDate: .init(year: 2026, month: 8, day: 10)!
        )
        let futureKey = OccurrenceKey(
            seriesID: series.id,
            originalDate: .init(year: 2026, month: 8, day: 17)!
        )
        let modified = OccurrenceOverride(
            displayedDate: .init(year: 2026, month: 8, day: 18)!,
            title: "已明确改动",
            kind: .task,
            categoryID: series.categoryID,
            timeRange: nil
        )
        let completedAt = Date(timeIntervalSince1970: 100)
        let graph = RecurrenceGraph(
            series: [series.id: series],
            exceptions: [futureKey: .modified(modified)],
            completions: [pastKey: .init(key: pastKey, completedAt: completedAt)]
        )
        let after = try SeriesMutationEngine.apply(
            edit: .patch(.init(
                title: nil,
                kind: nil,
                categoryID: nil,
                timeRange: .unchanged,
                displayedDate: nil,
                weekdays: [.tuesday],
                endDate: .unchanged
            )),
            to: boundaryKey,
            scope: .thisAndFuture,
            in: graph,
            newSeriesID: UUID(uuidString: "00000000-0000-0000-0000-000000000217")!,
            now: Date(timeIntervalSince1970: 200)
        )

        #expect(after.completions[pastKey]?.completedAt == completedAt)
        let futureSeries = try #require(after.series.values.first { $0.id != series.id })
        let migratedKey = OccurrenceKey(
            seriesID: futureSeries.id,
            originalDate: futureKey.originalDate
        )
        #expect(after.exceptions[migratedKey] == .modified(modified))
        #expect(after.series[series.id]?.endDate ==
            CalendarDate(year: 2026, month: 8, day: 9)!)
    }

    @Test func thisAndFutureDeleteEndsOldSeriesAndRemovesFutureState() throws {
        let series = try makeMondayWednesdaySeries(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000208")!
        )
        let pastKey = OccurrenceKey(seriesID: series.id, originalDate: series.startDate)
        let boundary = OccurrenceKey(
            seriesID: series.id,
            originalDate: .init(year: 2026, month: 8, day: 10)!
        )
        let futureKey = OccurrenceKey(
            seriesID: series.id,
            originalDate: .init(year: 2026, month: 8, day: 17)!
        )
        let before = RecurrenceGraph(
            series: [series.id: series],
            exceptions: [
                pastKey: .modified(makeOverride(for: series, on: pastKey.originalDate)),
                futureKey: .skipped
            ],
            completions: [
                pastKey: .init(key: pastKey, completedAt: Date(timeIntervalSince1970: 100)),
                futureKey: .init(key: futureKey, completedAt: Date(timeIntervalSince1970: 200))
            ]
        )

        let after = try SeriesMutationEngine.apply(
            edit: .delete,
            to: boundary,
            scope: .thisAndFuture,
            in: before,
            newSeriesID: UUID(uuidString: "00000000-0000-0000-0000-000000000218")!,
            now: .now
        )

        #expect(after.series.count == 1)
        #expect(after.series[series.id]?.endDate == boundary.originalDate.previousDay)
        #expect(after.exceptions[pastKey] != nil)
        #expect(after.completions[pastKey] != nil)
        #expect(after.exceptions.keys.allSatisfy { $0.originalDate < boundary.originalDate })
        #expect(after.completions.keys.allSatisfy { $0.originalDate < boundary.originalDate })
    }

    @Test func changingTaskSeriesToEventRemovesFutureCompletions() throws {
        let series = try makeMondayWednesdaySeries(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000209")!
        )
        let pastKey = OccurrenceKey(seriesID: series.id, originalDate: series.startDate)
        let boundary = OccurrenceKey(
            seriesID: series.id,
            originalDate: .init(year: 2026, month: 8, day: 10)!
        )
        let futureKey = OccurrenceKey(
            seriesID: series.id,
            originalDate: .init(year: 2026, month: 8, day: 17)!
        )
        let before = RecurrenceGraph(
            series: [series.id: series],
            exceptions: [:],
            completions: [
                pastKey: .init(key: pastKey, completedAt: Date(timeIntervalSince1970: 100)),
                boundary: .init(key: boundary, completedAt: Date(timeIntervalSince1970: 200)),
                futureKey: .init(key: futureKey, completedAt: Date(timeIntervalSince1970: 300))
            ]
        )

        let after = try SeriesMutationEngine.apply(
            edit: .patch(.init(kind: .event)),
            to: boundary,
            scope: .thisAndFuture,
            in: before,
            newSeriesID: UUID(uuidString: "00000000-0000-0000-0000-000000000219")!,
            now: .now
        )

        let future = try #require(after.series.values.first { $0.id != series.id })
        #expect(future.kind == .event)
        #expect(after.completions == [pastKey: before.completions[pastKey]!])
    }

    @Test func futureMoveShiftsExplicitStateAndEmbeddedCompletionKey() throws {
        let series = try makeMondayWednesdaySeries(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000220")!
        )
        let boundary = OccurrenceKey(
            seriesID: series.id,
            originalDate: .init(year: 2026, month: 8, day: 10)!
        )
        let futureKey = OccurrenceKey(
            seriesID: series.id,
            originalDate: .init(year: 2026, month: 8, day: 17)!
        )
        let modified = makeOverride(
            for: series,
            on: .init(year: 2026, month: 8, day: 18)!,
            title: "未来显式改动"
        )
        let before = RecurrenceGraph(
            series: [series.id: series],
            exceptions: [futureKey: .modified(modified)],
            completions: [futureKey: .init(key: futureKey, completedAt: Date(timeIntervalSince1970: 100))]
        )
        let newSeriesID = UUID(uuidString: "00000000-0000-0000-0000-000000000230")!

        let after = try SeriesMutationEngine.apply(
            edit: .patch(.init(displayedDate: .init(year: 2026, month: 8, day: 11)!)),
            to: boundary,
            scope: .thisAndFuture,
            in: before,
            newSeriesID: newSeriesID,
            now: .now
        )

        let migratedKey = OccurrenceKey(
            seriesID: newSeriesID,
            originalDate: .init(year: 2026, month: 8, day: 18)!
        )
        #expect(after.exceptions[migratedKey] == .modified(.init(
            displayedDate: .init(year: 2026, month: 8, day: 19)!,
            title: modified.title,
            kind: modified.kind,
            categoryID: modified.categoryID,
            timeRange: modified.timeRange
        )))
        #expect(after.completions[migratedKey]?.key == migratedKey)
        #expect(after.completions[migratedKey]?.completedAt == Date(timeIntervalSince1970: 100))
        #expect(after.exceptions[futureKey] == nil)
        #expect(after.completions[futureKey] == nil)
    }

    @Test func splitAtFirstOccurrenceRemovesEmptyHistoricalSeries() throws {
        let series = try makeMondayWednesdaySeries(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000221")!
        )
        let boundary = OccurrenceKey(seriesID: series.id, originalDate: series.startDate)
        let newSeriesID = UUID(uuidString: "00000000-0000-0000-0000-000000000231")!
        let before = RecurrenceGraph(series: [series.id: series], exceptions: [:], completions: [:])

        let after = try SeriesMutationEngine.apply(
            edit: .patch(.init(title: "新的系列")),
            to: boundary,
            scope: .thisAndFuture,
            in: before,
            newSeriesID: newSeriesID,
            now: .now
        )

        #expect(after.series[series.id] == nil)
        #expect(after.series.count == 1)
        #expect(after.series[newSeriesID]?.startDate == series.startDate)
        #expect(after.series.values.allSatisfy {
            $0.endDate == nil || $0.endDate! >= $0.startDate
        })
    }

    @Test func titleOnlyFuturePatchOnMovedBoundaryDoesNotShiftWeekdays() throws {
        let series = try WeeklySeries(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000222")!,
            kind: .task,
            title: "周计划",
            categoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            startDate: .init(year: 2026, month: 8, day: 3)!,
            endDate: .init(year: 2026, month: 8, day: 31)!,
            weekdays: [.monday, .wednesday],
            timeRange: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let boundary = OccurrenceKey(
            seriesID: series.id,
            originalDate: .init(year: 2026, month: 8, day: 10)!
        )
        let moved = makeOverride(
            for: series,
            on: .init(year: 2026, month: 8, day: 12)!,
            title: "边界原有标题"
        )
        let before = RecurrenceGraph(
            series: [series.id: series],
            exceptions: [boundary: .modified(moved)],
            completions: [:]
        )
        let newSeriesID = UUID(uuidString: "00000000-0000-0000-0000-000000000232")!

        let after = try SeriesMutationEngine.apply(
            edit: .patch(.init(title: "未来标题")),
            to: boundary,
            scope: .thisAndFuture,
            in: before,
            newSeriesID: newSeriesID,
            now: .now
        )

        let future = try #require(after.series[newSeriesID])
        #expect(future.weekdays == series.weekdays)
        #expect(future.startDate == boundary.originalDate)
        #expect(future.endDate == series.endDate)
        #expect(future.title == "未来标题")
        #expect(after.exceptions[OccurrenceKey(seriesID: newSeriesID, originalDate: boundary.originalDate)] ==
            .modified(.init(
                displayedDate: moved.displayedDate,
                title: "未来标题",
                kind: moved.kind,
                categoryID: moved.categoryID,
                timeRange: moved.timeRange
            )))
    }

    @Test func weekdayPatchDropsOnlyNonexistentFutureCompletions() throws {
        let series = try makeMondayWednesdaySeries(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000223")!
        )
        let pastKey = OccurrenceKey(seriesID: series.id, originalDate: series.startDate)
        let boundary = OccurrenceKey(
            seriesID: series.id,
            originalDate: .init(year: 2026, month: 8, day: 10)!
        )
        let naturallyGeneratedKey = OccurrenceKey(
            seriesID: series.id,
            originalDate: .init(year: 2026, month: 8, day: 17)!
        )
        let modifiedTaskKey = OccurrenceKey(
            seriesID: series.id,
            originalDate: .init(year: 2026, month: 8, day: 12)!
        )
        let nonexistentKey = OccurrenceKey(
            seriesID: series.id,
            originalDate: .init(year: 2026, month: 8, day: 19)!
        )
        let before = RecurrenceGraph(
            series: [series.id: series],
            exceptions: [
                modifiedTaskKey: .modified(makeOverride(for: series, on: modifiedTaskKey.originalDate))
            ],
            completions: [
                pastKey: .init(key: pastKey, completedAt: Date(timeIntervalSince1970: 100)),
                naturallyGeneratedKey: .init(
                    key: naturallyGeneratedKey,
                    completedAt: Date(timeIntervalSince1970: 200)
                ),
                modifiedTaskKey: .init(
                    key: modifiedTaskKey,
                    completedAt: Date(timeIntervalSince1970: 300)
                ),
                nonexistentKey: .init(
                    key: nonexistentKey,
                    completedAt: Date(timeIntervalSince1970: 400)
                )
            ]
        )
        let newSeriesID = UUID(uuidString: "00000000-0000-0000-0000-000000000233")!

        let after = try SeriesMutationEngine.apply(
            edit: .patch(.init(weekdays: [.monday])),
            to: boundary,
            scope: .thisAndFuture,
            in: before,
            newSeriesID: newSeriesID,
            now: .now
        )

        let migratedNaturalKey = OccurrenceKey(
            seriesID: newSeriesID,
            originalDate: naturallyGeneratedKey.originalDate
        )
        let migratedModifiedKey = OccurrenceKey(
            seriesID: newSeriesID,
            originalDate: modifiedTaskKey.originalDate
        )
        #expect(after.completions[pastKey]?.key == pastKey)
        #expect(after.completions[migratedNaturalKey]?.key == migratedNaturalKey)
        #expect(after.completions[migratedModifiedKey]?.key == migratedModifiedKey)
        #expect(after.completions.values.map(\.key).contains(
            OccurrenceKey(seriesID: newSeriesID, originalDate: nonexistentKey.originalDate)
        ) == false)
        #expect(after.exceptions[migratedModifiedKey] != nil)
    }

    @Test func shorteningFutureSeriesDropsStateBeyondNewEnd() throws {
        let series = try WeeklySeries(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000224")!,
            kind: .task,
            title: "周计划",
            categoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            startDate: .init(year: 2026, month: 8, day: 3)!,
            endDate: .init(year: 2026, month: 8, day: 31)!,
            weekdays: [.monday, .wednesday],
            timeRange: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let pastKey = OccurrenceKey(seriesID: series.id, originalDate: series.startDate)
        let boundary = OccurrenceKey(
            seriesID: series.id,
            originalDate: .init(year: 2026, month: 8, day: 10)!
        )
        let retainedKey = OccurrenceKey(
            seriesID: series.id,
            originalDate: .init(year: 2026, month: 8, day: 17)!
        )
        let removedKey = OccurrenceKey(
            seriesID: series.id,
            originalDate: .init(year: 2026, month: 8, day: 24)!
        )
        let newSeriesID = UUID(uuidString: "00000000-0000-0000-0000-000000000234")!
        let before = RecurrenceGraph(
            series: [series.id: series],
            exceptions: [
                retainedKey: .modified(makeOverride(for: series, on: retainedKey.originalDate)),
                removedKey: .modified(makeOverride(for: series, on: removedKey.originalDate))
            ],
            completions: [
                pastKey: .init(key: pastKey, completedAt: Date(timeIntervalSince1970: 100)),
                retainedKey: .init(key: retainedKey, completedAt: Date(timeIntervalSince1970: 200)),
                removedKey: .init(key: removedKey, completedAt: Date(timeIntervalSince1970: 300))
            ]
        )
        let endDate = CalendarDate(year: 2026, month: 8, day: 19)!

        let after = try SeriesMutationEngine.apply(
            edit: .patch(.init(endDate: .set(endDate))),
            to: boundary,
            scope: .thisAndFuture,
            in: before,
            newSeriesID: newSeriesID,
            now: .now
        )

        let future = try #require(after.series[newSeriesID])
        let retainedMigratedKey = OccurrenceKey(seriesID: newSeriesID, originalDate: retainedKey.originalDate)
        let removedMigratedKey = OccurrenceKey(seriesID: newSeriesID, originalDate: removedKey.originalDate)
        #expect(future.endDate == endDate)
        #expect(after.exceptions[retainedMigratedKey] != nil)
        #expect(after.completions[retainedMigratedKey]?.key == retainedMigratedKey)
        #expect(after.exceptions[removedMigratedKey] == nil)
        #expect(after.completions[removedMigratedKey] == nil)
        let projected = RecurrenceEngine.occurrences(
            of: future,
            in: .init(start: future.startDate, end: .init(year: 2026, month: 8, day: 31)!),
            exceptions: after.exceptions,
            completions: after.completions
        )
        #expect(projected.allSatisfy { $0.key.originalDate <= endDate })
    }

    @Test func unknownBoundaryThrows() throws {
        let series = try makeMondayWednesdaySeries(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000225")!
        )
        let unknownKey = OccurrenceKey(
            seriesID: series.id,
            originalDate: .init(year: 2026, month: 8, day: 11)!
        )
        let before = RecurrenceGraph(series: [series.id: series], exceptions: [:], completions: [:])

        #expect(throws: SeriesMutationError.unknownOccurrence) {
            try SeriesMutationEngine.apply(
                edit: .delete,
                to: unknownKey,
                scope: .thisAndFuture,
                in: before,
                newSeriesID: UUID(uuidString: "00000000-0000-0000-0000-000000000235")!,
                now: .now
            )
        }
        #expect(before == RecurrenceGraph(series: [series.id: series], exceptions: [:], completions: [:]))
    }

    private func makeMondayWednesdaySeries(id: UUID) throws -> WeeklySeries {
        try WeeklySeries(
            id: id,
            kind: .task,
            title: "周计划",
            categoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            startDate: .init(year: 2026, month: 8, day: 3)!,
            endDate: nil,
            weekdays: [.monday, .wednesday],
            timeRange: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeOverride(
        for series: WeeklySeries,
        on displayedDate: CalendarDate,
        title: String? = nil
    ) -> OccurrenceOverride {
        OccurrenceOverride(
            displayedDate: displayedDate,
            title: title ?? series.title,
            kind: series.kind,
            categoryID: series.categoryID,
            timeRange: series.timeRange
        )
    }
}
