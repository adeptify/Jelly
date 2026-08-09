import CalendarDomain
import Foundation

public enum WorkspaceValidationError: Error, Equatable, Sendable {
    case invalidCalendar
    case inconsistentNoteKey(NoteID)
    case inconsistentInspirationKey(InspirationID)
    case unknownCategory(UUID)
    case invalidNoteDocument(NoteID)
    case invalidInspirationInput(InspirationID)
    case danglingCalendarOwner(CalendarNoteOwnerID)
    case danglingOccurrenceOverride(OccurrenceKey)
    case inconsistentOccurrenceOverrideKey(OccurrenceKey)
    case danglingNote(NoteID)
    case primaryAlsoReference(CalendarNoteOwnerID, NoteID)
    case overlappingOccurrenceReferences(OccurrenceKey, NoteID)
    case danglingCalendarItem(UUID)
    case taskBlockMissingTask(NoteID, BlockID)
    case taskBlockMissingPrimaryNote(NoteID, UUID)
    case duplicateTaskBlock(BlockID)
    case duplicateTaskCalendarItem(UUID)
    case danglingLiveInspiration(InspirationID)
}

public enum WorkspaceValidator {
    public static func validate(_ state: WorkspaceState) throws {
        do {
            try CalendarStateValidator.validate(state.calendar)
        } catch {
            throw WorkspaceValidationError.invalidCalendar
        }

        try validateNotes(state)
        try validateInspirations(state)
        try validateCalendarRelations(state)
        try validateTaskBlockLinks(state)
        try validateInspirationLinks(state)
    }

    private static func validateNotes(_ state: WorkspaceState) throws {
        for (key, note) in state.notes {
            guard key == note.id else {
                throw WorkspaceValidationError.inconsistentNoteKey(key)
            }
            guard state.calendar.categories[note.categoryID] != nil else {
                throw WorkspaceValidationError.unknownCategory(note.categoryID)
            }
            do {
                try BlockDocumentValidator.validate(note.document)
            } catch {
                throw WorkspaceValidationError.invalidNoteDocument(note.id)
            }
        }
    }

    private static func validateInspirations(_ state: WorkspaceState) throws {
        for (key, inspiration) in state.inspirations {
            guard key == inspiration.id else {
                throw WorkspaceValidationError.inconsistentInspirationKey(key)
            }
            guard state.calendar.categories[inspiration.categoryID] != nil else {
                throw WorkspaceValidationError.unknownCategory(inspiration.categoryID)
            }
            guard hasValidRawInput(inspiration) else {
                throw WorkspaceValidationError.invalidInspirationInput(inspiration.id)
            }
        }
    }

    private static func validateCalendarRelations(_ state: WorkspaceState) throws {
        for (owner, noteSet) in state.calendarNoteRelations.baselines {
            guard contains(owner, in: state.calendar) else {
                throw WorkspaceValidationError.danglingCalendarOwner(owner)
            }
            try validate(noteSet, for: owner, in: state.notes)
        }

        for (key, override) in state.calendarNoteRelations.occurrenceOverrides {
            guard key == override.key else {
                throw WorkspaceValidationError.inconsistentOccurrenceOverrideKey(key)
            }
            guard state.calendar.recurrence.series[key.seriesID] != nil else {
                throw WorkspaceValidationError.danglingOccurrenceOverride(key)
            }
            if case let .replace(noteID) = override.primary {
                try require(noteID, in: state.notes)
            }
            for noteID in override.addedReferenceNoteIDs {
                try require(noteID, in: state.notes)
            }
            for noteID in override.removedReferenceNoteIDs {
                try require(noteID, in: state.notes)
            }
            if let overlap = override.addedReferenceNoteIDs.intersection(override.removedReferenceNoteIDs).first {
                throw WorkspaceValidationError.overlappingOccurrenceReferences(key, overlap)
            }
        }
    }

    private static func validateTaskBlockLinks(_ state: WorkspaceState) throws {
        var linkedBlockIDs = Set<BlockID>()
        var linkedCalendarItemIDs = Set<UUID>()

        for link in state.taskBlockLinks {
            guard state.calendar.items[link.calendarItemID] != nil else {
                throw WorkspaceValidationError.danglingCalendarItem(link.calendarItemID)
            }
            guard let note = state.notes[link.noteID],
                  note.document.blocks.contains(where: { $0.id == link.blockID && $0.kind == .task })
            else {
                throw WorkspaceValidationError.taskBlockMissingTask(link.noteID, link.blockID)
            }
            guard linkedBlockIDs.insert(link.blockID).inserted else {
                throw WorkspaceValidationError.duplicateTaskBlock(link.blockID)
            }
            guard linkedCalendarItemIDs.insert(link.calendarItemID).inserted else {
                throw WorkspaceValidationError.duplicateTaskCalendarItem(link.calendarItemID)
            }
            let owner = CalendarNoteOwnerID.item(link.calendarItemID)
            guard state.calendarNoteRelations.baselines[owner]?.primaryNoteID == link.noteID else {
                throw WorkspaceValidationError.taskBlockMissingPrimaryNote(link.noteID, link.calendarItemID)
            }
        }
    }

    private static func validateInspirationLinks(_ state: WorkspaceState) throws {
        for link in state.inspirationNoteLinks {
            try require(link.noteID, in: state.notes)
            if case let .live(inspirationID) = link.source,
               state.inspirations[inspirationID] == nil {
                throw WorkspaceValidationError.danglingLiveInspiration(inspirationID)
            }
        }
    }

    private static func validate(
        _ noteSet: CalendarNoteSet,
        for owner: CalendarNoteOwnerID,
        in notes: [NoteID: Note]
    ) throws {
        if let primary = noteSet.primaryNoteID {
            try require(primary, in: notes)
            if noteSet.referenceNoteIDs.contains(primary) {
                throw WorkspaceValidationError.primaryAlsoReference(owner, primary)
            }
        }
        for noteID in noteSet.referenceNoteIDs {
            try require(noteID, in: notes)
        }
    }

    private static func require(_ noteID: NoteID, in notes: [NoteID: Note]) throws {
        guard notes[noteID] != nil else {
            throw WorkspaceValidationError.danglingNote(noteID)
        }
    }

    private static func contains(_ owner: CalendarNoteOwnerID, in calendar: CalendarState) -> Bool {
        switch owner {
        case let .item(id):
            calendar.items[id] != nil
        case let .series(id):
            calendar.recurrence.series[id] != nil
        }
    }

    private static func hasValidRawInput(_ inspiration: Inspiration) -> Bool {
        switch inspiration.inputKind {
        case .text:
            guard let rawText = inspiration.rawText else { return false }
            return !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && inspiration.rawURL == nil
                && inspiration.rawFile == nil
        case .url:
            guard let rawURL = inspiration.rawURL else { return false }
            return rawURL.scheme != nil
                && rawURL.host != nil
                && inspiration.rawText == nil
                && inspiration.rawFile == nil
        case .file:
            guard let rawFile = inspiration.rawFile else { return false }
            return !rawFile.bookmarkData.isEmpty
                && !rawFile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && inspiration.rawText == nil
                && inspiration.rawURL == nil
        }
    }
}
