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
