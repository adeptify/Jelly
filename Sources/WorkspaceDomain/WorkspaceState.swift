import CalendarDomain
import Foundation

public struct WorkspaceState: Codable, Equatable, Sendable {
    public var revision: Int64
    public var calendar: CalendarState
    public var notes: [NoteID: Note]
    public var inspirations: [InspirationID: Inspiration]
    public var calendarNoteRelations: CalendarNoteRelationGraph
    public var taskBlockLinks: Set<TaskBlockCalendarLink>
    public var inspirationNoteLinks: Set<InspirationNoteLink>

    public init(
        revision: Int64,
        calendar: CalendarState,
        notes: [NoteID: Note],
        inspirations: [InspirationID: Inspiration],
        calendarNoteRelations: CalendarNoteRelationGraph,
        taskBlockLinks: Set<TaskBlockCalendarLink>,
        inspirationNoteLinks: Set<InspirationNoteLink>
    ) {
        self.revision = revision
        self.calendar = calendar
        self.notes = notes
        self.inspirations = inspirations
        self.calendarNoteRelations = calendarNoteRelations
        self.taskBlockLinks = taskBlockLinks
        self.inspirationNoteLinks = inspirationNoteLinks
    }

    public static func empty(calendar: CalendarState) -> WorkspaceState {
        WorkspaceState(
            revision: 0,
            calendar: calendar,
            notes: [:],
            inspirations: [:],
            calendarNoteRelations: .empty,
            taskBlockLinks: [],
            inspirationNoteLinks: []
        )
    }
}
