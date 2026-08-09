import CalendarDomain
import Foundation

public enum SeriesRelationMigrationError: Error, Equatable, Sendable {
    case outcomeGraphMismatch
    case destinationBaselineCollision(CalendarNoteOwnerID)
    case destinationOccurrenceCollision(OccurrenceKey)
}

public enum SeriesRelationMigration {
    public static func apply(
        _ outcome: SeriesFutureMutationOutcome,
        resultingGraph: RecurrenceGraph,
        to relations: CalendarNoteRelationGraph
    ) throws -> CalendarNoteRelationGraph {
        switch outcome {
        case let .split(oldSeriesID, newSeriesID, boundary, dayDelta, historicalOwnerRetained):
            try validateSplitOutcome(
                oldSeriesID: oldSeriesID,
                newSeriesID: newSeriesID,
                boundary: boundary,
                dayDelta: dayDelta,
                historicalOwnerRetained: historicalOwnerRetained,
                graph: resultingGraph
            )
            return try applySplit(
                oldSeriesID: oldSeriesID,
                newSeriesID: newSeriesID,
                boundary: boundary,
                dayDelta: dayDelta,
                historicalOwnerRetained: historicalOwnerRetained,
                graph: resultingGraph,
                relations: relations
            )
        case let .deleteFuture(seriesID, boundary, historicalOwnerRetained):
            try validateDeleteOutcome(
                seriesID: seriesID,
                boundary: boundary,
                historicalOwnerRetained: historicalOwnerRetained,
                graph: resultingGraph
            )
            var candidate = relations
            candidate.occurrenceOverrides = candidate.occurrenceOverrides.filter { key, _ in
                key.seriesID != seriesID || key.originalDate < boundary
            }
            if !historicalOwnerRetained {
                candidate.baselines.removeValue(forKey: .series(seriesID))
                candidate.occurrenceOverrides = candidate.occurrenceOverrides.filter { $0.key.seriesID != seriesID }
            }
            return candidate
        }
    }

    private static func applySplit(
        oldSeriesID: UUID,
        newSeriesID: UUID,
        boundary: CalendarDate,
        dayDelta: Int,
        historicalOwnerRetained: Bool,
        graph: RecurrenceGraph,
        relations: CalendarNoteRelationGraph
    ) throws -> CalendarNoteRelationGraph {
        let oldOwner = CalendarNoteOwnerID.series(oldSeriesID)
        let newOwner = CalendarNoteOwnerID.series(newSeriesID)
        let oldBaseline = relations.baselines[oldOwner]
        if oldBaseline != nil, relations.baselines[newOwner] != nil {
            throw SeriesRelationMigrationError.destinationBaselineCollision(newOwner)
        }

        let futureOverrides = relations.occurrenceOverrides.values.filter {
            $0.key.seriesID == oldSeriesID && $0.key.originalDate >= boundary
        }
        var mappedOverrides = [OccurrenceKey: OccurrenceNoteOverride]()
        for override in futureOverrides {
            let destinationKey = OccurrenceKey(
                seriesID: newSeriesID,
                originalDate: override.key.originalDate.addingDays(dayDelta)
            )
            guard CalendarNoteRelationResolver.isLogicalInstance(destinationKey, in: graph) else {
                continue
            }
            if relations.occurrenceOverrides[destinationKey] != nil || mappedOverrides[destinationKey] != nil {
                throw SeriesRelationMigrationError.destinationOccurrenceCollision(destinationKey)
            }
            mappedOverrides[destinationKey] = .init(
                key: destinationKey,
                primary: override.primary,
                addedReferenceNoteIDs: override.addedReferenceNoteIDs,
                removedReferenceNoteIDs: override.removedReferenceNoteIDs
            )
        }

        var candidate = relations
        if let oldBaseline {
            candidate.baselines[newOwner] = oldBaseline
        }
        candidate.occurrenceOverrides = candidate.occurrenceOverrides.filter { key, _ in
            key.seriesID != oldSeriesID || key.originalDate < boundary
        }
        for (key, override) in mappedOverrides {
            candidate.occurrenceOverrides[key] = override
        }
        if !historicalOwnerRetained {
            candidate.baselines.removeValue(forKey: oldOwner)
            candidate.occurrenceOverrides = candidate.occurrenceOverrides.filter { $0.key.seriesID != oldSeriesID }
        }
        return candidate
    }

    private static func validateSplitOutcome(
        oldSeriesID: UUID,
        newSeriesID: UUID,
        boundary: CalendarDate,
        dayDelta: Int,
        historicalOwnerRetained: Bool,
        graph: RecurrenceGraph
    ) throws {
        guard oldSeriesID != newSeriesID,
              let newSeries = graph.series[newSeriesID],
              newSeries.ruleStartDate == boundary.addingDays(dayDelta),
              historicalOwnerRetained == (graph.series[oldSeriesID] != nil)
        else {
            throw SeriesRelationMigrationError.outcomeGraphMismatch
        }
        if let historicalSeries = graph.series[oldSeriesID],
           !(historicalSeries.recurrenceEndDate.map { $0 < boundary } ?? false) {
            throw SeriesRelationMigrationError.outcomeGraphMismatch
        }
    }

    private static func validateDeleteOutcome(
        seriesID: UUID,
        boundary: CalendarDate,
        historicalOwnerRetained: Bool,
        graph: RecurrenceGraph
    ) throws {
        guard historicalOwnerRetained == (graph.series[seriesID] != nil) else {
            throw SeriesRelationMigrationError.outcomeGraphMismatch
        }
        if let series = graph.series[seriesID],
           !(series.recurrenceEndDate.map { $0 < boundary } ?? false) {
            throw SeriesRelationMigrationError.outcomeGraphMismatch
        }
    }
}
