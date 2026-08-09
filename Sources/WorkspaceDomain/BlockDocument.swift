import Foundation

public enum BlockKind: String, Codable, Equatable, Sendable {
    case paragraph
    case heading1
    case heading2
    case heading3
    case bullet
    case ordered
    case task
    case quote
    case code
    case divider
    case link

    var supportsIndentation: Bool {
        switch self {
        case .bullet, .ordered, .task:
            true
        case .paragraph, .heading1, .heading2, .heading3, .quote, .code, .divider, .link:
            false
        }
    }
}

public enum InlineMark: String, Codable, Hashable, Sendable {
    case bold
    case italic
    case code
}

public struct InlineSpan: Codable, Equatable, Sendable {
    public var text: String
    public var marks: Set<InlineMark>
    public var linkURL: URL?

    public init(text: String, marks: Set<InlineMark> = [], linkURL: URL? = nil) {
        self.text = text
        self.marks = marks
        self.linkURL = linkURL
    }
}

public struct InlineContent: Codable, Equatable, Sendable {
    public var spans: [InlineSpan]

    public init(spans: [InlineSpan]) {
        self.spans = spans
    }

    public static func plain(_ text: String) -> InlineContent {
        InlineContent(spans: [.init(text: text)])
    }

    var isEmpty: Bool {
        spans.allSatisfy { $0.text.isEmpty && $0.linkURL == nil }
    }
}

public struct TaskBlockState: Codable, Equatable, Sendable {
    public var completedAt: Date?

    public init(completedAt: Date?) {
        self.completedAt = completedAt
    }
}

public struct DocumentBlock: Identifiable, Codable, Equatable, Sendable {
    public let id: BlockID
    public var kind: BlockKind
    public var inlineContent: InlineContent
    public var taskState: TaskBlockState?
    public var indentLevel: Int

    public init(
        id: BlockID,
        kind: BlockKind,
        inlineContent: InlineContent,
        taskState: TaskBlockState?,
        indentLevel: Int
    ) {
        self.id = id
        self.kind = kind
        self.inlineContent = inlineContent
        self.taskState = taskState
        self.indentLevel = indentLevel
    }

    public static func task(
        id: BlockID = BlockID(),
        text: String,
        indentLevel: Int = 0,
        completedAt: Date? = nil
    ) throws -> DocumentBlock {
        let block = DocumentBlock(
            id: id,
            kind: .task,
            inlineContent: .plain(text),
            taskState: .init(completedAt: completedAt),
            indentLevel: indentLevel
        )
        try BlockDocumentValidator.validate(.init(blocks: [block]))
        return block
    }
}

public struct BlockDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var blocks: [DocumentBlock]

    public init(schemaVersion: Int = currentSchemaVersion, blocks: [DocumentBlock]) {
        self.schemaVersion = schemaVersion
        self.blocks = blocks
    }

    public static func empty() -> BlockDocument {
        BlockDocument(blocks: [
            .init(
                id: BlockID(),
                kind: .paragraph,
                inlineContent: .plain(""),
                taskState: nil,
                indentLevel: 0
            )
        ])
    }
}
