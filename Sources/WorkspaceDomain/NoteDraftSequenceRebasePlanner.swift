import Foundation

public struct PreviousAcceptedDraft: Equatable, Sendable {
    public let base: Note
    public let accepted: Note
    public let modifiedFields: Set<NoteDraftField>

    public init(base: Note, accepted: Note, modifiedFields: Set<NoteDraftField>) {
        self.base = base
        self.accepted = accepted
        self.modifiedFields = modifiedFields
    }
}

public struct NoteDraftSequenceRebaseResult: Equatable, Sendable {
    public let rebasedBase: Note
    public let rebasedSnapshot: Note

    public init(rebasedBase: Note, rebasedSnapshot: Note) {
        self.rebasedBase = rebasedBase
        self.rebasedSnapshot = rebasedSnapshot
    }
}

public enum NoteDraftSequenceRebaseError: Error, Equatable, Sendable {
    case invalidSubmission
    case conflict(Set<NoteDraftField>)
}

/// Rebases a queued generation as a field delta. It deliberately never turns a
/// stale draft into a replacement Note, so unrelated work in `latest` survives.
public enum NoteDraftSequenceRebasePlanner {
    public static func plan(
        previousAccepted: PreviousAcceptedDraft,
        next: NoteDraftSubmission,
        latest: Note
    ) throws -> NoteDraftSequenceRebaseResult {
        guard previousAccepted.base.id == previousAccepted.accepted.id,
              next.noteID == next.baseSnapshot.id,
              next.noteID == next.snapshot.id,
              latest.id == next.noteID,
              previousAccepted.accepted.id == next.noteID
        else { throw NoteDraftSequenceRebaseError.invalidSubmission }

        var conflicts = Set<NoteDraftField>()
        for field in previousAccepted.modifiedFields where value(field, in: latest) != value(field, in: previousAccepted.accepted) {
            conflicts.insert(field)
        }
        guard conflicts.isEmpty else { throw NoteDraftSequenceRebaseError.conflict(conflicts) }

        var rebasedBase = next.baseSnapshot
        for field in previousAccepted.modifiedFields {
            set(field, value: value(field, in: previousAccepted.accepted), in: &rebasedBase)
        }
        var rebasedSnapshot = latest
        for field in next.modifiedFields {
            set(field, value: value(field, in: next.snapshot), in: &rebasedSnapshot)
        }
        return .init(rebasedBase: rebasedBase, rebasedSnapshot: rebasedSnapshot)
    }

    private static func value(_ field: NoteDraftField, in note: Note) -> NoteFieldValue {
        switch field {
        case .title: .title(note.title)
        case .document: .document(note.document)
        case .categoryID: .categoryID(note.categoryID)
        case .archivedAt: .archivedAt(note.archivedAt)
        }
    }

    private static func set(_ field: NoteDraftField, value: NoteFieldValue, in note: inout Note) {
        switch (field, value) {
        case let (.title, .title(value)): note.title = value
        case let (.document, .document(value)): note.document = value
        case let (.categoryID, .categoryID(value)): note.categoryID = value
        case let (.archivedAt, .archivedAt(value)): note.archivedAt = value
        default: preconditionFailure("A field projection must retain its field identity.")
        }
    }

    private enum NoteFieldValue: Equatable {
        case title(String)
        case document(BlockDocument)
        case categoryID(UUID)
        case archivedAt(Date?)
    }
}
