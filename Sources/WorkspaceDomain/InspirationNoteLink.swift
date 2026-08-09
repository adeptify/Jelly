import Foundation

public enum InspirationSourceReference: Hashable, Codable, Sendable {
    case live(InspirationID)
    case deleted(originalID: InspirationID, deletedAt: Date)
}

public struct InspirationNoteLink: Hashable, Codable, Sendable {
    public var source: InspirationSourceReference
    public let noteID: NoteID
    public let createdAt: Date

    public init(source: InspirationSourceReference, noteID: NoteID, createdAt: Date) {
        self.source = source
        self.noteID = noteID
        self.createdAt = createdAt
    }
}
