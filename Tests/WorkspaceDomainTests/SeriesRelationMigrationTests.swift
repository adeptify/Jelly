import CalendarDomain
import Foundation
import Testing
import WorkspaceDomain

@Suite("SeriesRelationMigrationTests")
struct SeriesRelationMigrationTests {
    @Test func splitCopiesExplicitEmptyBaselineAndMapsRelationOverrideByCivilDayDelta() throws {
        let fixture = try MigrationFixture(dayDelta: 2, retained: true)
        let oldKey = fixture.oldKey
        let newKey = OccurrenceKey(
            seriesID: fixture.newSeries.id,
            originalDate: oldKey.originalDate.addingDays(2)
        )
        let relations = CalendarNoteRelationGraph(
            baselines: [.series(fixture.oldSeries.id): .init(primaryNoteID: nil, referenceNoteIDs: [])],
            occurrenceOverrides: [oldKey: .init(
                key: oldKey, primary: .replace(fixture.note),
                addedReferenceNoteIDs: [], removedReferenceNoteIDs: []
            )]
        )

        let migrated = try SeriesRelationMigration.apply(
            fixture.splitOutcome,
            resultingGraph: fixture.resultingGraph,
            to: relations
        )

        #expect(migrated.baselines[.series(fixture.newSeries.id)] == .init(primaryNoteID: nil, referenceNoteIDs: []))
        #expect(migrated.occurrenceOverrides[newKey]?.primary == .replace(fixture.note))
        #expect(migrated.occurrenceOverrides[oldKey] == nil)
        #expect(migrated.baselines[.series(fixture.oldSeries.id)] != nil)
    }

    @Test func splitDoesNotSynthesizeMissingOldBaseline() throws {
        let fixture = try MigrationFixture(dayDelta: -3, retained: true)
        let migrated = try SeriesRelationMigration.apply(
            fixture.splitOutcome,
            resultingGraph: fixture.resultingGraph,
            to: .empty
        )

        #expect(migrated.baselines[.series(fixture.newSeries.id)] == nil)
    }

    @Test func firstOccurrenceSplitRemovesOldBaselineAndEveryOldOverrideAfterValidation() throws {
        let fixture = try MigrationFixture(dayDelta: 0, retained: false)
        let pastKey = OccurrenceKey(seriesID: fixture.oldSeries.id, originalDate: fixture.boundary.previousDay)
        let relations = CalendarNoteRelationGraph(
            baselines: [.series(fixture.oldSeries.id): .init(primaryNoteID: fixture.note, referenceNoteIDs: [])],
            occurrenceOverrides: [
                fixture.oldKey: .init(key: fixture.oldKey, primary: .inherit, addedReferenceNoteIDs: [], removedReferenceNoteIDs: []),
                pastKey: .init(key: pastKey, primary: .inherit, addedReferenceNoteIDs: [], removedReferenceNoteIDs: [])
            ]
        )

        let migrated = try SeriesRelationMigration.apply(
            fixture.splitOutcome,
            resultingGraph: fixture.resultingGraph,
            to: relations
        )

        #expect(migrated.baselines[.series(fixture.oldSeries.id)] == nil)
        #expect(migrated.occurrenceOverrides.keys.contains { $0.seriesID == fixture.oldSeries.id } == false)
        #expect(migrated.baselines[.series(fixture.newSeries.id)]?.primaryNoteID == fixture.note)
    }

    @Test func splitRetainsOnlyDestinationLogicalInstancesIncludingModifiedAndSkipped() throws {
        let fixture = try MigrationFixture(dayDelta: 0, retained: true)
        let skipped = OccurrenceKey(seriesID: fixture.oldSeries.id, originalDate: fixture.boundary.addingDays(1))
        let modified = OccurrenceKey(seriesID: fixture.oldSeries.id, originalDate: fixture.boundary.addingDays(2))
        let completionOnly = OccurrenceKey(seriesID: fixture.oldSeries.id, originalDate: fixture.boundary.addingDays(3))
        var graph = fixture.resultingGraph
        let newSkipped = OccurrenceKey(seriesID: fixture.newSeries.id, originalDate: skipped.originalDate)
        let newModified = OccurrenceKey(seriesID: fixture.newSeries.id, originalDate: modified.originalDate)
        let newCompletionOnly = OccurrenceKey(seriesID: fixture.newSeries.id, originalDate: completionOnly.originalDate)
        graph.series[fixture.newSeries.id]?.weekdays.remove(.thursday)
        graph.exceptions[newSkipped] = .skipped
        graph.exceptions[newModified] = .modified(fixture.override(on: newModified.originalDate))
        graph.completions[newCompletionOnly] = .init(key: newCompletionOnly, completedAt: .distantPast)
        let relations = CalendarNoteRelationGraph(
            baselines: [:],
            occurrenceOverrides: [
                skipped: .init(key: skipped, primary: .replace(fixture.note), addedReferenceNoteIDs: [], removedReferenceNoteIDs: []),
                modified: .init(key: modified, primary: .replace(fixture.note), addedReferenceNoteIDs: [], removedReferenceNoteIDs: []),
                completionOnly: .init(key: completionOnly, primary: .replace(fixture.note), addedReferenceNoteIDs: [], removedReferenceNoteIDs: [])
            ]
        )

        let migrated = try SeriesRelationMigration.apply(fixture.splitOutcome, resultingGraph: graph, to: relations)

        #expect(migrated.occurrenceOverrides[newSkipped] != nil)
        #expect(migrated.occurrenceOverrides[newModified] != nil)
        #expect(migrated.occurrenceOverrides[newCompletionOnly] == nil)
    }

    @Test func deleteFutureRemovesFutureOverridesAndFirstOccurrenceDeleteRemovesOwnerStorage() throws {
        let retained = try MigrationFixture(dayDelta: 0, retained: true)
        let future = retained.oldKey
        let past = OccurrenceKey(seriesID: retained.oldSeries.id, originalDate: retained.boundary.previousDay)
        let relations = CalendarNoteRelationGraph(
            baselines: [.series(retained.oldSeries.id): .init(primaryNoteID: retained.note, referenceNoteIDs: [])],
            occurrenceOverrides: [
                past: .init(key: past, primary: .inherit, addedReferenceNoteIDs: [], removedReferenceNoteIDs: []),
                future: .init(key: future, primary: .inherit, addedReferenceNoteIDs: [], removedReferenceNoteIDs: [])
            ]
        )
        let retainedGraph = RecurrenceGraph(
            series: [retained.oldSeries.id: retained.historicalOldSeries], exceptions: [:], completions: [:]
        )
        let retainedResult = try SeriesRelationMigration.apply(
            .deleteFuture(seriesID: retained.oldSeries.id, boundary: retained.boundary, historicalOwnerRetained: true),
            resultingGraph: retainedGraph,
            to: relations
        )
        #expect(retainedResult.baselines[.series(retained.oldSeries.id)] != nil)
        #expect(retainedResult.occurrenceOverrides[past] != nil)
        #expect(retainedResult.occurrenceOverrides[future] == nil)

        let removed = try MigrationFixture(dayDelta: 0, retained: false)
        let removedResult = try SeriesRelationMigration.apply(
            .deleteFuture(seriesID: removed.oldSeries.id, boundary: removed.boundary, historicalOwnerRetained: false),
            resultingGraph: .init(series: [:], exceptions: [:], completions: [:]),
            to: CalendarNoteRelationGraph(
                baselines: [.series(removed.oldSeries.id): .init(primaryNoteID: removed.note, referenceNoteIDs: [])],
                occurrenceOverrides: [removed.oldKey: .init(key: removed.oldKey, primary: .inherit, addedReferenceNoteIDs: [], removedReferenceNoteIDs: [])]
            )
        )
        #expect(removedResult.baselines[.series(removed.oldSeries.id)] == nil)
        #expect(removedResult.occurrenceOverrides.isEmpty)
    }

    @Test func mismatchAndDestinationCollisionsThrowWithoutChangingInputRelations() throws {
        let fixture = try MigrationFixture(dayDelta: 1, retained: true)
        let oldRelations = CalendarNoteRelationGraph(
            baselines: [.series(fixture.oldSeries.id): .init(primaryNoteID: fixture.note, referenceNoteIDs: [])],
            occurrenceOverrides: [fixture.oldKey: .init(
                key: fixture.oldKey, primary: .inherit, addedReferenceNoteIDs: [], removedReferenceNoteIDs: []
            )]
        )
        var mismatch = fixture.resultingGraph
        mismatch.series.removeValue(forKey: fixture.newSeries.id)
        #expect(throws: SeriesRelationMigrationError.outcomeGraphMismatch) {
            try SeriesRelationMigration.apply(fixture.splitOutcome, resultingGraph: mismatch, to: oldRelations)
        }
        #expect(oldRelations == CalendarNoteRelationGraph(
            baselines: [.series(fixture.oldSeries.id): .init(primaryNoteID: fixture.note, referenceNoteIDs: [])],
            occurrenceOverrides: [fixture.oldKey: .init(key: fixture.oldKey, primary: .inherit, addedReferenceNoteIDs: [], removedReferenceNoteIDs: [])]
        ))

        var baselineCollision = oldRelations
        baselineCollision.baselines[.series(fixture.newSeries.id)] = .init(primaryNoteID: nil, referenceNoteIDs: [])
        #expect(throws: SeriesRelationMigrationError.destinationBaselineCollision(.series(fixture.newSeries.id))) {
            try SeriesRelationMigration.apply(fixture.splitOutcome, resultingGraph: fixture.resultingGraph, to: baselineCollision)
        }
        let newKey = OccurrenceKey(seriesID: fixture.newSeries.id, originalDate: fixture.oldKey.originalDate.addingDays(1))
        var overrideCollision = oldRelations
        overrideCollision.occurrenceOverrides[newKey] = .init(
            key: newKey, primary: .inherit, addedReferenceNoteIDs: [], removedReferenceNoteIDs: []
        )
        #expect(throws: SeriesRelationMigrationError.destinationOccurrenceCollision(newKey)) {
            try SeriesRelationMigration.apply(fixture.splitOutcome, resultingGraph: fixture.resultingGraph, to: overrideCollision)
        }
        #expect(overrideCollision.occurrenceOverrides[fixture.oldKey] != nil)
    }

    @Test func retainedSplitOutcomeRequiresHistoricalSeriesToBeClosedBeforeBoundary() throws {
        let fixture = try MigrationFixture(dayDelta: 0, retained: true)
        var mismatch = fixture.resultingGraph
        mismatch.series[fixture.oldSeries.id]?.recurrenceEndDate = nil

        #expect(throws: SeriesRelationMigrationError.outcomeGraphMismatch) {
            try SeriesRelationMigration.apply(
                fixture.splitOutcome,
                resultingGraph: mismatch,
                to: .empty
            )
        }
    }
}

private struct MigrationFixture {
    let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000601")!
    let note = NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000000602")!)
    let oldSeries: WeeklySeries
    let newSeries: WeeklySeries
    let historicalOldSeries: WeeklySeries
    let boundary: CalendarDate
    let oldKey: OccurrenceKey
    let resultingGraph: RecurrenceGraph
    let splitOutcome: SeriesFutureMutationOutcome

    init(dayDelta: Int, retained: Bool) throws {
        let oldID = UUID(uuidString: "00000000-0000-0000-0000-000000000603")!
        let newID = UUID(uuidString: "00000000-0000-0000-0000-000000000604")!
        self.boundary = CalendarDate(year: 2026, month: 8, day: 3)!
        self.oldKey = .init(seriesID: oldID, originalDate: boundary)
        self.oldSeries = try WeeklySeries(
            id: oldID, kind: .task, title: "旧系列", categoryID: categoryID,
            ruleStartDate: retained ? boundary.previousDay : boundary,
            recurrenceEndDate: nil, weekdays: [.monday, .tuesday, .wednesday],
            durationDays: 1, startTime: nil, endTime: nil, createdAt: .distantPast, updatedAt: .distantPast
        )
        self.newSeries = try WeeklySeries(
            id: newID, kind: .task, title: "新系列", categoryID: categoryID,
            ruleStartDate: boundary.addingDays(dayDelta), recurrenceEndDate: nil,
            weekdays: [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday],
            durationDays: 1, startTime: nil, endTime: nil, createdAt: .distantPast, updatedAt: .distantPast
        )
        var historical = oldSeries
        historical.recurrenceEndDate = boundary.previousDay
        self.historicalOldSeries = historical
        self.resultingGraph = .init(
            series: retained ? [oldID: historical, newID: newSeries] : [newID: newSeries],
            exceptions: [:], completions: [:]
        )
        self.splitOutcome = .split(
            oldSeriesID: oldID, newSeriesID: newID, boundary: boundary,
            dayDelta: dayDelta, historicalOwnerRetained: retained
        )
    }

    func override(on date: CalendarDate) -> OccurrenceOverride {
        .init(
            displayedSchedule: try! .init(startDate: date, endDate: date, startTime: nil, endTime: nil),
            title: newSeries.title, kind: .task, categoryID: categoryID
        )
    }
}
