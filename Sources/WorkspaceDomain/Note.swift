import Foundation

public struct Note: Identifiable, Codable, Equatable, Sendable {
    public let id: NoteID
    public var title: String
    public var document: BlockDocument
    public var categoryID: UUID
    public var archivedAt: Date?
    public var revision: Int64
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: NoteID,
        title: String,
        document: BlockDocument,
        categoryID: UUID,
        archivedAt: Date?,
        revision: Int64,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.document = document
        self.categoryID = categoryID
        self.archivedAt = archivedAt
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func empty(id: NoteID = NoteID(), categoryID: UUID, now: Date) -> Note {
        Note(
            id: id,
            title: "",
            document: .empty(),
            categoryID: categoryID,
            archivedAt: nil,
            revision: 0,
            createdAt: now,
            updatedAt: now
        )
    }
}
