import AppKit
import Foundation
import WorkspaceDomain

@MainActor
final class BlockPasteboardAdapter {
    static let privateType = NSPasteboard.PasteboardType("com.adeptify.jelly.block-clipboard.v1")

    private let pasteboard: NSPasteboard
    private let plainTextWriter: (NSPasteboard, String) -> Bool
    private let customDataWriter: (NSPasteboard, Data) -> Bool

    init(
        pasteboard: NSPasteboard = .general,
        plainTextWriter: @escaping (NSPasteboard, String) -> Bool = { pasteboard, text in
            pasteboard.setString(text, forType: .string)
        },
        customDataWriter: @escaping (NSPasteboard, Data) -> Bool = { pasteboard, data in
            pasteboard.setData(data, forType: NSPasteboard.PasteboardType("com.adeptify.jelly.block-clipboard.v1"))
        }
    ) {
        self.pasteboard = pasteboard
        self.plainTextWriter = plainTextWriter
        self.customDataWriter = customDataWriter
    }

    /// Plain text is written first and is the required interoperable representation.
    /// A custom-data failure deliberately does not destroy that fallback.
    @discardableResult
    func write(payload: BlockClipboardPayload) -> Bool {
        pasteboard.clearContents()
        guard plainTextWriter(pasteboard, payload.plainText) else { return false }
        guard let data = try? JSONEncoder().encode(Envelope(payload: payload)) else { return true }
        _ = customDataWriter(pasteboard, data)
        return true
    }

    func write(attributedString: NSAttributedString) throws {
        let payload = BlockClipboardPayload(
            plainText: attributedString.string,
            richBlocks: Self.pasteBlocks(from: attributedString)
        )
        guard write(payload: payload) else { throw BlockEditorIntegrationError.clipboardWriteFailed }
    }

    func readPayload() -> BlockPastePayload? {
        if let data = pasteboard.data(forType: Self.privateType) {
            if let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
               envelope.version == Envelope.version,
               let payload = envelope.payload,
               (try? BlockPasteParser.parse(payload)) != nil {
                return payload
            }
            return pasteboard.string(forType: .string).map(BlockPastePayload.plainText)
        }
        if let rtf = pasteboard.data(forType: .rtf),
           let attributed = try? NSAttributedString(
               data: rtf,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil
           ) {
            return .richText(
                blocks: Self.pasteBlocks(from: attributed),
                fallbackPlainText: attributed.string
            )
        }
        return pasteboard.string(forType: .string).map(BlockPastePayload.plainText)
    }

    private static func pasteBlocks(from attributed: NSAttributedString) -> [BlockPasteBlock] {
        var lines: [[InlineSpan]] = [[]]
        var previousWasCarriageReturn = false
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
            let text = attributed.attributedSubstring(from: range).string
            let style = inlineStyle(attributes)
            for scalar in text.unicodeScalars {
                if scalar.value == 10 {
                    if previousWasCarriageReturn { previousWasCarriageReturn = false; continue }
                    lines.append([])
                    continue
                }
                if scalar.value == 13 {
                    lines.append([])
                    previousWasCarriageReturn = true
                    continue
                }
                previousWasCarriageReturn = false
                append(String(scalar), style: style, to: &lines)
            }
        }
        return lines.map { spans in
            .init(
                kind: .paragraph,
                inlineContent: .init(spans: spans.isEmpty ? [.init(text: "")] : spans),
                indentLevel: 0,
                codeInfoString: nil
            )
        }
    }

    private static func inlineStyle(_ attributes: [NSAttributedString.Key: Any]) -> InlineSpan {
        var marks: Set<InlineMark> = []
        if let font = attributes[.font] as? NSFont {
            let traits = font.fontDescriptor.symbolicTraits
            if traits.contains(.bold) { marks.insert(.bold) }
            if traits.contains(.italic) { marks.insert(.italic) }
        }
        if (attributes[NSAttributedString.Key("com.adeptify.jelly.inline-code")] as? Bool) == true {
            marks.insert(.code)
        }
        let link = normalizedURL(attributes[.link]).flatMap { BlockURLValidator.isValid($0) ? $0 : nil }
        return .init(text: "", marks: marks, linkURL: link)
    }

    private static func normalizedURL(_ value: Any?) -> URL? {
        switch value {
        case let url as URL:
            return url
        case let url as NSURL:
            return url as URL
        case let value as String:
            return URL(string: value)
        case let value as NSString:
            return URL(string: value as String)
        default:
            return nil
        }
    }

    private static func append(_ text: String, style: InlineSpan, to lines: inout [[InlineSpan]]) {
        guard !text.isEmpty else { return }
        if let last = lines[lines.count - 1].last,
           last.marks == style.marks, last.linkURL == style.linkURL {
            lines[lines.count - 1][lines[lines.count - 1].count - 1].text += text
        } else {
            lines[lines.count - 1].append(.init(text: text, marks: style.marks, linkURL: style.linkURL))
        }
    }
}

extension BlockPastePayload {
    var fallbackPlainText: String {
        switch self {
        case let .plainText(text): text
        case let .richText(_, fallbackPlainText): fallbackPlainText
        }
    }
}

private struct Envelope: Codable {
    static let version = 1
    let version: Int
    let plainText: String
    let blocks: [BlockDTO]

    init(payload: BlockClipboardPayload) {
        version = Self.version
        plainText = payload.plainText
        blocks = payload.richBlocks.map(BlockDTO.init)
    }

    var payload: BlockPastePayload? {
        guard blocks.allSatisfy(\.isStructurallyValid) else { return nil }
        return .richText(blocks: blocks.map(\.block), fallbackPlainText: plainText)
    }
}

private struct BlockDTO: Codable {
    let kind: BlockKind
    let spans: [InlineSpan]
    let indentLevel: Int
    let codeInfoString: String?

    init(_ block: BlockPasteBlock) {
        kind = block.kind
        spans = block.inlineContent.spans
        indentLevel = block.indentLevel
        codeInfoString = block.codeInfoString
    }

    var block: BlockPasteBlock {
        .init(kind: kind, inlineContent: .init(spans: spans), indentLevel: indentLevel, codeInfoString: codeInfoString)
    }

    var isStructurallyValid: Bool {
        indentLevel >= 0 && indentLevel <= 3
    }
}
