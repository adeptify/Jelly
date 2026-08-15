import Foundation

public struct Note: Identifiable, Codable, Equatable, Sendable {
    public let id: NoteID
    public var title: String
    public var document: BlockDocument
    public var categoryID: UUID
    public var archivedAt: Date?
    public var isPinned: Bool
    public var revision: Int64
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: NoteID,
        title: String,
        document: BlockDocument,
        categoryID: UUID,
        archivedAt: Date?,
        isPinned: Bool = false,
        revision: Int64,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.document = document
        self.categoryID = categoryID
        self.archivedAt = archivedAt
        self.isPinned = isPinned
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, document, categoryID, archivedAt, isPinned, revision, createdAt, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(NoteID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        document = try container.decode(BlockDocument.self, forKey: .document)
        categoryID = try container.decode(UUID.self, forKey: .categoryID)
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        revision = try container.decode(Int64.self, forKey: .revision)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(document, forKey: .document)
        try container.encode(categoryID, forKey: .categoryID)
        try container.encodeIfPresent(archivedAt, forKey: .archivedAt)
        if isPinned { try container.encode(true, forKey: .isPinned) }
        try container.encode(revision, forKey: .revision)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
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
