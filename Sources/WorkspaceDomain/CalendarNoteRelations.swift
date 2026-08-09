import CalendarDomain
import Foundation

public enum CalendarNoteOwnerID: Hashable, Codable, Sendable {
    case item(UUID)
    case series(UUID)
}

public enum CalendarTargetID: Hashable, Codable, Sendable {
    case item(UUID)
    case series(UUID)
    case occurrence(OccurrenceKey)
}

public struct CalendarNoteSet: Codable, Equatable, Sendable {
    public var primaryNoteID: NoteID?
    public var referenceNoteIDs: Set<NoteID>

    public init(primaryNoteID: NoteID?, referenceNoteIDs: Set<NoteID>) {
        self.primaryNoteID = primaryNoteID
        self.referenceNoteIDs = referenceNoteIDs
    }
}

public enum OccurrencePrimaryOverride: Codable, Equatable, Sendable {
    case inherit
    case replace(NoteID)
    case clear
}

public struct OccurrenceNoteOverride: Codable, Equatable, Sendable {
    public let key: OccurrenceKey
    public var primary: OccurrencePrimaryOverride
    public var addedReferenceNoteIDs: Set<NoteID>
    public var removedReferenceNoteIDs: Set<NoteID>

    public init(
        key: OccurrenceKey,
        primary: OccurrencePrimaryOverride,
        addedReferenceNoteIDs: Set<NoteID>,
        removedReferenceNoteIDs: Set<NoteID>
    ) {
        self.key = key
        self.primary = primary
        self.addedReferenceNoteIDs = addedReferenceNoteIDs
        self.removedReferenceNoteIDs = removedReferenceNoteIDs
    }
}

public struct CalendarNoteRelationGraph: Codable, Equatable, Sendable {
    public var baselines: [CalendarNoteOwnerID: CalendarNoteSet]
    public var occurrenceOverrides: [OccurrenceKey: OccurrenceNoteOverride]

    public init(
        baselines: [CalendarNoteOwnerID: CalendarNoteSet],
        occurrenceOverrides: [OccurrenceKey: OccurrenceNoteOverride]
    ) {
        self.baselines = baselines
        self.occurrenceOverrides = occurrenceOverrides
    }

    public static let empty = CalendarNoteRelationGraph(baselines: [:], occurrenceOverrides: [:])
}

public struct ResolvedCalendarNoteRelation: Equatable, Sendable {
    public let noteSet: CalendarNoteSet
    public let isClickable: Bool

    public init(noteSet: CalendarNoteSet, isClickable: Bool) {
        self.noteSet = noteSet
        self.isClickable = isClickable
    }
}

public enum CalendarNoteRelationResolutionError: Error, Equatable, Sendable {
    case missingItem(UUID)
    case missingSeries(UUID)
    case invalidOccurrence(OccurrenceKey)
}

public enum CalendarNoteRelationResolver {
    public static func resolve(
        _ target: CalendarTargetID,
        calendar: CalendarState,
        relations: CalendarNoteRelationGraph
    ) throws -> ResolvedCalendarNoteRelation {
        switch target {
        case let .item(itemID):
            guard calendar.items[itemID] != nil else {
                throw CalendarNoteRelationResolutionError.missingItem(itemID)
            }
            return .init(
                noteSet: relations.baselines[.item(itemID)] ?? emptyNoteSet,
                isClickable: true
            )
        case let .series(seriesID):
            guard calendar.recurrence.series[seriesID] != nil else {
                throw CalendarNoteRelationResolutionError.missingSeries(seriesID)
            }
            return .init(
                noteSet: relations.baselines[.series(seriesID)] ?? emptyNoteSet,
                isClickable: true
            )
        case let .occurrence(key):
            guard let series = calendar.recurrence.series[key.seriesID] else {
                throw CalendarNoteRelationResolutionError.missingSeries(key.seriesID)
            }
            guard isLogicalInstance(key, in: calendar.recurrence) else {
                throw CalendarNoteRelationResolutionError.invalidOccurrence(key)
            }

            let baseline = relations.baselines[.series(series.id)] ?? emptyNoteSet
            guard let override = relations.occurrenceOverrides[key] else {
                return .init(
                    noteSet: baseline,
                    isClickable: !isSkipped(key, in: calendar.recurrence)
                )
            }
            let primary: NoteID?
            switch override.primary {
            case .inherit:
                primary = baseline.primaryNoteID
            case let .replace(noteID):
                primary = noteID
            case .clear:
                primary = nil
            }
            var references = baseline.referenceNoteIDs
            references.subtract(override.removedReferenceNoteIDs)
            references.formUnion(override.addedReferenceNoteIDs)
            if let primary {
                references.remove(primary)
            }
            return .init(
                noteSet: .init(primaryNoteID: primary, referenceNoteIDs: references),
                isClickable: !isSkipped(key, in: calendar.recurrence)
            )
        }
    }

    static func isLogicalInstance(_ key: OccurrenceKey, in graph: RecurrenceGraph) -> Bool {
        guard let series = graph.series[key.seriesID], isWithinBounds(key.originalDate, of: series) else {
            return false
        }
        if graph.exceptions[key] != nil {
            return true
        }
        return series.weekdays.contains(key.originalDate.weekday)
    }

    static func isSkipped(_ key: OccurrenceKey, in graph: RecurrenceGraph) -> Bool {
        if case .skipped = graph.exceptions[key] {
            return true
        }
        return false
    }

    private static let emptyNoteSet = CalendarNoteSet(primaryNoteID: nil, referenceNoteIDs: [])

    private static func isWithinBounds(_ date: CalendarDate, of series: WeeklySeries) -> Bool {
        date >= series.ruleStartDate && (series.recurrenceEndDate.map { date <= $0 } ?? true)
    }
}
