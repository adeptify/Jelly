import Foundation

public enum WorkspaceConsistencyIssue: Equatable, Sendable {
    case danglingCalendarOwner(CalendarNoteOwnerID)
    case danglingNote(NoteID)
    case danglingInspiration(InspirationID)
    case danglingTaskBlock(TaskBlockCalendarLink)
    case invalidBlockDocument(NoteID)
}
