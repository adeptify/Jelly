import Foundation

public enum WorkspaceObjectKind: String, Codable, Equatable, Sendable {
    case note
    case inspiration
}

public enum WorkspaceObjectID: Hashable, Codable, Sendable {
    case note(NoteID)
    case inspiration(InspirationID)
}

public struct WorkspaceSearchRecord: Codable, Equatable, Sendable {
    public let objectID: WorkspaceObjectID
    public let kind: WorkspaceObjectKind
    public let normalizedText: String
    public let categoryID: UUID?
    public let isArchived: Bool

    public init(
        objectID: WorkspaceObjectID,
        kind: WorkspaceObjectKind,
        normalizedText: String,
        categoryID: UUID?,
        isArchived: Bool
    ) {
        self.objectID = objectID
        self.kind = kind
        self.normalizedText = normalizedText
        self.categoryID = categoryID
        self.isArchived = isArchived
    }
}

public struct WorkspaceSearchProjection: Codable, Equatable, Sendable {
    public static let schemaVersion = 2
    public let schemaVersion: Int
    public let workspaceRevision: Int64
    public let records: [WorkspaceSearchRecord]

    public init(workspaceRevision: Int64, records: [WorkspaceSearchRecord]) {
        schemaVersion = Self.schemaVersion
        self.workspaceRevision = workspaceRevision
        self.records = records
    }

    public static func build(from state: WorkspaceState) -> WorkspaceSearchProjection {
        var records: [WorkspaceSearchRecord] = []
        for note in state.notes.values {
            let body = note.document.blocks
                .flatMap(\.inlineContent.spans)
                .flatMap { span in
                    [span.text, span.linkURL?.absoluteString].compactMap { $0 }
                }
                .joined(separator: "\n")
            let text = "\(note.title)\n\(body)".lowercased()
            records.append(.init(
                objectID: .note(note.id),
                kind: .note,
                normalizedText: text,
                categoryID: note.categoryID,
                isArchived: note.archivedAt != nil
            ))
        }
        for inspiration in state.inspirations.values {
            let raw = inspiration.rawText
                ?? inspiration.rawURL?.absoluteString
                ?? inspiration.resolvedMetadata?.title
                ?? ""
            records.append(.init(
                objectID: .inspiration(inspiration.id),
                kind: .inspiration,
                normalizedText: raw.lowercased(),
                categoryID: inspiration.categoryID,
                isArchived: inspiration.lifecycle == .archived
            ))
        }
        records.sort {
            switch ($0.objectID, $1.objectID) {
            case let (.note(a), .note(b)):
                return a.rawValue.uuidString < b.rawValue.uuidString
            case let (.inspiration(a), .inspiration(b)):
                return a.rawValue.uuidString < b.rawValue.uuidString
            case (.note, .inspiration):
                return true
            case (.inspiration, .note):
                return false
            }
        }
        return .init(workspaceRevision: state.revision, records: records)
    }

    public func search(
        query: String,
        kind: WorkspaceObjectKind?,
        includeArchived: Bool
    ) -> [WorkspaceSearchRecord] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return records.filter { record in
            if let kind, record.kind != kind { return false }
            if !includeArchived, record.isArchived { return false }
            if q.isEmpty { return true }
            return record.normalizedText.contains(q)
        }
    }
}
