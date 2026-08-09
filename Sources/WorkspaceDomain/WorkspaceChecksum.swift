import CryptoKit
import Foundation

public enum WorkspaceChecksum {
    public static func normalizedNoteSnapshotData(_ note: Note) throws -> Data {
        let encoder = JSONEncoder.workspaceDeterministic
        return try encoder.encode(NormalizedNoteSnapshot(note: note))
    }

    public static func noteSnapshotChecksum(_ note: Note) throws -> String {
        let data = try normalizedNoteSnapshotData(note)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public extension JSONEncoder {
    static var workspaceDeterministic: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
}

public extension JSONDecoder {
    static var workspaceDeterministic: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

private struct NormalizedNoteSnapshot: Codable {
    let noteID: UUID
    let title: String
    let document: NormalizedBlockDocument
    let categoryID: UUID
    let archivedAt: Date?

    init(note: Note) {
        noteID = note.id.rawValue
        title = note.title
        document = .init(document: note.document)
        categoryID = note.categoryID
        archivedAt = note.archivedAt
    }
}

private struct NormalizedBlockDocument: Codable {
    let schemaVersion: Int
    let blocks: [NormalizedDocumentBlock]

    init(document: BlockDocument) {
        schemaVersion = document.schemaVersion
        blocks = document.blocks.map(NormalizedDocumentBlock.init)
    }
}

private struct NormalizedDocumentBlock: Codable {
    let id: UUID
    let kind: BlockKind
    let spans: [NormalizedInlineSpan]
    let completedAt: Date?
    let indentLevel: Int

    init(block: DocumentBlock) {
        id = block.id.rawValue
        kind = block.kind
        spans = block.inlineContent.spans.map(NormalizedInlineSpan.init)
        completedAt = block.taskState?.completedAt
        indentLevel = block.indentLevel
    }
}

private struct NormalizedInlineSpan: Codable {
    let text: String
    let marks: [InlineMark]
    let linkURL: String?

    init(span: InlineSpan) {
        text = span.text
        marks = span.marks.sorted { $0.rawValue < $1.rawValue }
        linkURL = span.linkURL?.absoluteString
    }
}
