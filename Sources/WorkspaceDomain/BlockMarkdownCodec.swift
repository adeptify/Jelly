import Foundation

public enum BlockIDSource: Sendable {
    case random
    case fixed([BlockID])
}

public struct BlockMarkdownDiagnostic: Equatable, Sendable {
    public let lineNumber: Int
    public let message: String

    public init(lineNumber: Int, message: String) {
        self.lineNumber = lineNumber
        self.message = message
    }
}

public struct BlockMarkdownImportResult: Equatable, Sendable {
    public let document: BlockDocument
    public let diagnostics: [BlockMarkdownDiagnostic]

    public init(document: BlockDocument, diagnostics: [BlockMarkdownDiagnostic]) {
        self.document = document
        self.diagnostics = diagnostics
    }
}

public enum BlockMarkdownCodecError: Error, Equatable, Sendable {
    case insufficientBlockIDs
}

public enum BlockMarkdownCodec {
    public static func importMarkdown(
        _ markdown: String,
        idSource: BlockIDSource = .random,
        checkedTaskCompletedAt: Date
    ) throws -> BlockMarkdownImportResult {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        }

        var identifiers = MarkdownIdentifierGenerator(source: idSource)
        var blocks: [DocumentBlock] = []
        var diagnostics: [BlockMarkdownDiagnostic] = []
        var activeListLevels = Set<Int>()
        var index = 0

        func addBlock(
            _ kind: BlockKind,
            content: InlineContent,
            taskState: TaskBlockState? = nil,
            indentLevel: Int = 0,
            codeInfoString: String? = nil
        ) throws {
            blocks.append(.init(
                id: try identifiers.next(),
                kind: kind,
                inlineContent: content,
                taskState: taskState,
                indentLevel: indentLevel,
                codeInfoString: codeInfoString
            ))
        }

        while index < lines.count {
            let line = lines[index]
            if line.isEmpty {
                activeListLevels.removeAll()
                index += 1
                continue
            }

            if let fence = markdownFenceOpening(in: line) {
                if let message = unsupportedFenceMessage(for: fence) {
                    let closing = markdownFenceClosingIndex(in: lines, after: index, opening: fence)
                    let finalIndex = closing ?? lines.index(before: lines.endIndex)
                    diagnostics.append(.init(lineNumber: index + 1, message: message))
                    activeListLevels.removeAll()
                    try addBlock(.paragraph, content: .plain(lines[index...finalIndex].joined(separator: "\n")))
                    index = finalIndex + 1
                    continue
                }
                guard let closing = markdownFenceClosingIndex(in: lines, after: index, opening: fence) else {
                    diagnostics.append(.init(lineNumber: index + 1, message: "未闭合的代码围栏已保留为正文"))
                    activeListLevels.removeAll()
                    try addBlock(.paragraph, content: .plain(lines[index...].joined(separator: "\n")))
                    break
                }
                try addBlock(
                    .code,
                    content: .plain(lines[(index + 1)..<closing].joined(separator: "\n")),
                    codeInfoString: fence.infoString
                )
                activeListLevels.removeAll()
                index = closing + 1
                continue
            }

            if line.hasPrefix("|") {
                let firstLine = index
                var table: [String] = []
                while index < lines.count, !lines[index].isEmpty {
                    table.append(lines[index])
                    index += 1
                }
                diagnostics.append(.init(lineNumber: firstLine + 1, message: "不支持的 Markdown 表格已保留为正文"))
                activeListLevels.removeAll()
                try addBlock(.paragraph, content: .plain(table.joined(separator: "\n")))
                continue
            }

            if line.hasPrefix(MarkdownInlineLexer.linkBlockMarker) {
                let first = String(line.dropFirst(MarkdownInlineLexer.linkBlockMarker.count))
                let scanned = consumeMarkedPhysicalLines(
                    startingWith: first,
                    in: lines,
                    after: index + 1,
                    firstLineNumber: index + 1,
                    diagnostics: &diagnostics
                )
                activeListLevels.removeAll()
                try addBlock(.link, content: MarkdownInlineLexer.decode(scanned.text, firstLineNumber: index + 1, diagnostics: &diagnostics))
                index = scanned.nextIndex
                continue
            }

            if line.hasPrefix(">") {
                let scanned = consumeQuotePhysicalLines(in: lines, startingAt: index, diagnostics: &diagnostics)
                activeListLevels.removeAll()
                try addBlock(.quote, content: MarkdownInlineLexer.decode(scanned.text, firstLineNumber: index + 1, diagnostics: &diagnostics))
                index = scanned.nextIndex
                continue
            }

            if let heading = markdownHeading(in: line) {
                let scanned = consumeMarkedPhysicalLines(
                    startingWith: heading.text,
                    in: lines,
                    after: index + 1,
                    firstLineNumber: index + 1,
                    diagnostics: &diagnostics
                )
                activeListLevels.removeAll()
                try addBlock(heading.kind, content: MarkdownInlineLexer.decode(scanned.text, firstLineNumber: index + 1, diagnostics: &diagnostics))
                index = scanned.nextIndex
                continue
            }

            if line == "---" {
                activeListLevels.removeAll()
                try addBlock(.divider, content: .plain(""))
                index += 1
                continue
            }

            if let item = markdownListItem(in: line) {
                guard item.indentLevel == 0 || activeListLevels.contains(item.indentLevel - 1) else {
                    diagnostics.append(.init(lineNumber: index + 1, message: "孤立的列表缩进已保留为正文"))
                    activeListLevels.removeAll()
                    try addBlock(.paragraph, content: .plain(line))
                    index += 1
                    continue
                }
                let scanned = consumeMarkedPhysicalLines(
                    startingWith: item.text,
                    in: lines,
                    after: index + 1,
                    firstLineNumber: index + 1,
                    diagnostics: &diagnostics
                )
                let taskState = item.kind == .task
                    ? TaskBlockState(completedAt: item.checked ? checkedTaskCompletedAt : nil)
                    : nil
                try addBlock(
                    item.kind,
                    content: MarkdownInlineLexer.decode(scanned.text, firstLineNumber: index + 1, diagnostics: &diagnostics),
                    taskState: taskState,
                    indentLevel: item.indentLevel
                )
                activeListLevels = Set(activeListLevels.filter { $0 <= item.indentLevel })
                activeListLevels.insert(item.indentLevel)
                index = scanned.nextIndex
                continue
            }

            if let link = markdownStandaloneLink(in: lines, at: index, diagnostics: &diagnostics) {
                activeListLevels.removeAll()
                var content = MarkdownInlineLexer.decode(link.text, firstLineNumber: index + 1, diagnostics: &diagnostics)
                for spanIndex in content.spans.indices {
                    content.spans[spanIndex].linkURL = link.url
                }
                content = markdownCoalescingFallbackSpans(content)
                try addBlock(.link, content: content)
                index = link.nextIndex
                continue
            }

            let paragraph = consumeParagraphPhysicalLines(in: lines, startingAt: index, diagnostics: &diagnostics)
            activeListLevels.removeAll()
            try addBlock(.paragraph, content: MarkdownInlineLexer.decode(paragraph.text, firstLineNumber: index + 1, diagnostics: &diagnostics))
            index = paragraph.nextIndex
        }

        let document = BlockDocument(blocks: blocks)
        try BlockDocumentValidator.validate(document)
        return .init(document: document, diagnostics: diagnostics)
    }

    public static func exportMarkdown(_ document: BlockDocument) throws -> String {
        try BlockDocumentValidator.validate(document)

        var chunks: [String] = []
        var previousWasList = false
        var orderedCounters: [Int: Int] = [:]

        for block in document.blocks {
            let isList = block.kind == .bullet || block.kind == .ordered || block.kind == .task
            let inline = MarkdownInlineSerializer.encode(block.inlineContent)
            let rendered: String
            switch block.kind {
            case .paragraph:
                rendered = escapeParagraphBlockStart(inline)
            case .heading1:
                rendered = "# \(inline)"
            case .heading2:
                rendered = "## \(inline)"
            case .heading3:
                rendered = "### \(inline)"
            case .bullet:
                rendered = "\(markdownListIndent(block.indentLevel))- \(inline)"
            case .ordered:
                let number = (orderedCounters[block.indentLevel] ?? 0) + 1
                orderedCounters[block.indentLevel] = number
                orderedCounters = orderedCounters.filter { $0.key <= block.indentLevel }
                rendered = "\(markdownListIndent(block.indentLevel))\(number). \(inline)"
            case .task:
                let checkbox = block.taskState?.completedAt == nil ? "[ ]" : "[x]"
                rendered = "\(markdownListIndent(block.indentLevel))- \(checkbox) \(inline)"
            case .quote:
                rendered = inline.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n")
            case .code:
                rendered = encodeCodeFence(block)
            case .divider:
                rendered = "---"
            case .link:
                rendered = MarkdownInlineLexer.linkBlockMarker + inline
            }

            if !chunks.isEmpty {
                chunks.append(previousWasList && isList ? "\n" : "\n\n")
            }
            chunks.append(rendered)
            previousWasList = isList
            if !isList {
                orderedCounters.removeAll()
            }
        }
        return chunks.joined()
    }
}

private struct MarkdownIdentifierGenerator {
    private let source: BlockIDSource
    private var fixed: ArraySlice<BlockID>

    init(source: BlockIDSource) {
        self.source = source
        switch source {
        case .random: fixed = []
        case let .fixed(ids): fixed = ArraySlice(ids)
        }
    }

    mutating func next() throws -> BlockID {
        switch source {
        case .random: return BlockID()
        case .fixed:
            guard let id = fixed.popFirst() else { throw BlockMarkdownCodecError.insufficientBlockIDs }
            return id
        }
    }
}

private enum LogicalLineBoundary: CaseIterable {
    case soft
    case hard

    var token: String {
        switch self {
        case .soft: "<!--jelly:continue-soft:v1-->"
        case .hard: "<!--jelly:continue-hard:v1-->"
        }
    }

    var modelSuffix: String {
        switch self {
        case .soft: "\n"
        case .hard: "  \n"
        }
    }
}

private struct MarkdownFenceOpening {
    let character: Character
    let length: Int
    let infoString: String?
}

private struct MarkdownHeading {
    let kind: BlockKind
    let text: String
}

private struct MarkdownListItem {
    let kind: BlockKind
    let text: String
    let indentLevel: Int
    let checked: Bool
}

private struct MarkdownPhysicalScan {
    let text: String
    let nextIndex: Int
}

private struct MarkdownStandaloneLinkScan {
    let text: String
    let nextIndex: Int
    let url: URL
}

private func markdownFenceOpening(in line: String) -> MarkdownFenceOpening? {
    let characters = Array(line)
    guard let character = characters.first, character == "`" || character == "~" else { return nil }
    let length = markdownRunLength(in: characters, at: 0, matching: character)
    guard length >= 3 else { return nil }
    return .init(
        character: character,
        length: length,
        infoString: DocumentBlock.canonicalCodeInfoString(String(characters.dropFirst(length)))
    )
}

private func unsupportedFenceMessage(for opening: MarkdownFenceOpening) -> String? {
    guard let info = opening.infoString else { return nil }
    if info.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 }) {
        return "无效的代码围栏信息已保留为正文"
    }
    if opening.character == "`", info.contains("`") {
        return "不支持的代码围栏信息已保留为正文"
    }
    return nil
}

private func markdownFenceClosingIndex(
    in lines: [String],
    after index: Int,
    opening: MarkdownFenceOpening
) -> Int? {
    for candidate in (index + 1)..<lines.count where markdownIsFenceClosing(lines[candidate], for: opening) {
        return candidate
    }
    return nil
}

private func markdownIsFenceClosing(_ line: String, for opening: MarkdownFenceOpening) -> Bool {
    let characters = Array(line)
    let length = markdownRunLength(in: characters, at: 0, matching: opening.character)
    return length >= opening.length && characters.dropFirst(length).allSatisfy { $0 == " " || $0 == "\t" }
}

private func markdownHeading(in line: String) -> MarkdownHeading? {
    for level in 1...3 {
        let prefix = String(repeating: "#", count: level) + " "
        guard line.hasPrefix(prefix) else { continue }
        let kind: BlockKind = switch level {
        case 1: .heading1
        case 2: .heading2
        default: .heading3
        }
        return .init(kind: kind, text: String(line.dropFirst(prefix.count)))
    }
    return nil
}

private func markdownListItem(in line: String) -> MarkdownListItem? {
    let leadingSpaces = line.prefix { $0 == " " }.count
    let indent = min(leadingSpaces / 4, 3)
    let overflow = String(repeating: " ", count: max(0, leadingSpaces - indent * 4))
    let body = String(line.dropFirst(leadingSpaces))
    if body.hasPrefix("- [ ] ") {
        return .init(kind: .task, text: overflow + String(body.dropFirst(6)), indentLevel: indent, checked: false)
    }
    if body.hasPrefix("- [x] ") || body.hasPrefix("- [X] ") {
        return .init(kind: .task, text: overflow + String(body.dropFirst(6)), indentLevel: indent, checked: true)
    }
    if body.hasPrefix("- ") || body.hasPrefix("* ") {
        return .init(kind: .bullet, text: overflow + String(body.dropFirst(2)), indentLevel: indent, checked: false)
    }
    let characters = Array(body)
    var digits = 0
    while digits < characters.count, characters[digits].isASCII, characters[digits].isNumber { digits += 1 }
    guard digits > 0, digits + 1 < characters.count, characters[digits] == ".", characters[digits + 1] == " " else {
        return nil
    }
    return .init(kind: .ordered, text: overflow + String(characters.dropFirst(digits + 2)), indentLevel: indent, checked: false)
}

private func consumeMarkedPhysicalLines(
    startingWith first: String,
    in lines: [String],
    after start: Int,
    firstLineNumber: Int,
    diagnostics: inout [BlockMarkdownDiagnostic]
) -> MarkdownPhysicalScan {
    var text = first
    var current = first
    var currentLineNumber = firstLineNumber
    var next = start
    while true {
        MarkdownInlineLexer.diagnoseMalformedControls(in: current, lineNumber: currentLineNumber, diagnostics: &diagnostics)
        guard MarkdownInlineLexer.activeBoundary(in: current) != nil, next < lines.count else {
            return .init(text: text, nextIndex: next)
        }
        current = lines[next]
        text += "\n" + current
        currentLineNumber = next + 1
        next += 1
    }
}

private func consumeParagraphPhysicalLines(
    in lines: [String],
    startingAt start: Int,
    diagnostics: inout [BlockMarkdownDiagnostic]
) -> MarkdownPhysicalScan {
    var text = ""
    var index = start
    while index < lines.count {
        let current = lines[index]
        MarkdownInlineLexer.diagnoseMalformedControls(in: current, lineNumber: index + 1, diagnostics: &diagnostics)
        text += current
        index += 1
        if MarkdownInlineLexer.activeBoundary(in: current) != nil, index < lines.count {
            text += "\n"
            continue
        }
        guard index < lines.count,
              !lines[index].isEmpty,
              !markdownStartsBlock(lines[index]),
              !markdownCouldStartExternalLink(in: lines, at: index) else {
            return .init(text: text, nextIndex: index)
        }
        text += "\n"
    }
    return .init(text: text, nextIndex: index)
}

private func consumeQuotePhysicalLines(
    in lines: [String],
    startingAt start: Int,
    diagnostics: inout [BlockMarkdownDiagnostic]
) -> MarkdownPhysicalScan {
    var current = markdownQuoteContent(lines[start])
    var text = ""
    var lineNumber = start + 1
    var next = start + 1
    while true {
        MarkdownInlineLexer.diagnoseMalformedControls(in: current, lineNumber: lineNumber, diagnostics: &diagnostics)
        text += current
        if MarkdownInlineLexer.activeBoundary(in: current) != nil, next < lines.count {
            text += "\n"
            current = lines[next].hasPrefix(">") ? markdownQuoteContent(lines[next]) : lines[next]
            lineNumber = next + 1
            next += 1
            continue
        }
        if current.isEmpty {
            return .init(text: text, nextIndex: next)
        }
        guard next < lines.count, lines[next].hasPrefix(">") else {
            return .init(text: text, nextIndex: next)
        }
        text += "\n"
        current = markdownQuoteContent(lines[next])
        lineNumber = next + 1
        next += 1
    }
}

private func markdownQuoteContent(_ line: String) -> String {
    line.hasPrefix("> ") ? String(line.dropFirst(2)) : String(line.dropFirst())
}

private func markdownStandaloneLink(
    in lines: [String],
    at start: Int,
    diagnostics: inout [BlockMarkdownDiagnostic]
) -> MarkdownStandaloneLinkScan? {
    guard !MarkdownInlineLexer.hasActiveSpanManifest(in: lines[start]) else { return nil }
    var text = lines[start]
    var current = lines[start]
    var next = start + 1
    while true {
        let candidate = markdownRemovingTerminalBoundary(from: text)
        if let external = markdownWholeExternalLink(current: candidate) {
            let continued = consumeMarkedPhysicalLines(
                startingWith: text,
                in: lines,
                after: next,
                firstLineNumber: start + 1,
                diagnostics: &diagnostics
            )
            return .init(text: continued.text, nextIndex: continued.nextIndex, url: external.url)
        }
        if markdownHasUnclosedLinkLabel(text), next < lines.count, lines[next].isEmpty {
            diagnostics.append(.init(lineNumber: start + 1, message: "未闭合的跨行链接已保留为正文"))
        }
        guard markdownHasUnclosedLinkLabel(text), next < lines.count, !lines[next].isEmpty else {
            return nil
        }
        current = lines[next]
        text += "\n" + current
        next += 1
    }
}

private func markdownRemovingTerminalBoundary(from line: String) -> String {
    for boundary in LogicalLineBoundary.allCases where line.hasSuffix(boundary.token) {
        let start = line.index(line.endIndex, offsetBy: -boundary.token.count)
        if line[..<start].reversed().prefix(while: { $0 == "\\" }).count.isMultiple(of: 2) {
            return String(line[..<start])
        }
    }
    return line
}

private func markdownCouldStartExternalLink(in lines: [String], at index: Int) -> Bool {
    var ignored: [BlockMarkdownDiagnostic] = []
    return markdownStandaloneLink(in: lines, at: index, diagnostics: &ignored) != nil
}

private func markdownHasUnclosedLinkLabel(_ source: String) -> Bool {
    let chars = Array(source)
    return chars.first == "[" && markdownUnescapedIndex(of: "]", in: chars, startingAt: 1) == nil
}

private func markdownStartsBlock(_ line: String) -> Bool {
    line.hasPrefix(MarkdownInlineLexer.linkBlockMarker) ||
        markdownFenceOpening(in: line) != nil ||
        line.hasPrefix("|") ||
        line.hasPrefix(">") ||
        markdownHeading(in: line) != nil ||
        line == "---" ||
        markdownListItem(in: line) != nil ||
        markdownWholeExternalLink(current: line) != nil
}

private func markdownWholeExternalLink(current source: String) -> (label: String, url: URL)? {
    let characters = Array(source)
    guard characters.first == "[",
          let labelEnd = markdownUnescapedIndex(of: "]", in: characters, startingAt: 1),
          labelEnd + 1 < characters.count,
          characters[labelEnd + 1] == "(",
          let urlEnd = markdownUnescapedIndex(of: ")", in: characters, startingAt: labelEnd + 2),
          urlEnd + 1 == characters.count else {
        return nil
    }
    let rawURL = String(characters[(labelEnd + 2)..<urlEnd])
    guard let url = URL(string: rawURL), markdownValidURL(url) else { return nil }
    return (String(characters[1..<labelEnd]), url)
}

private func markdownUnescapedIndex(of delimiter: Character, in characters: [Character], startingAt start: Int) -> Int? {
    var index = start
    while index < characters.count {
        if characters[index] == "\\" {
            index += 2
        } else if characters[index] == delimiter {
            return index
        } else {
            index += 1
        }
    }
    return nil
}

private enum MarkdownInlineSerializer {
    static func encode(_ content: InlineContent) -> String {
        guard !content.spans.isEmpty else { return MarkdownInlineLexer.emptySpanSentinel }
        return content.spans.enumerated().map { index, span in
            encodeSpan(span, hasFollowingSpan: index < content.spans.index(before: content.spans.endIndex))
        }.joined()
    }

    private static func encodeSpan(_ span: InlineSpan, hasFollowingSpan: Bool) -> String {
        guard !span.text.isEmpty else { return MarkdownInlineLexer.manifest(for: span) }
        let payload = encodePayload(
            span.text,
            rawCode: span.marks.contains(.code),
            emitPhysicalLineAfterTerminalBoundary: false
        )
        var visible = payload
        if span.marks.contains(.code) {
            let length = max(1, markdownLongestRun(of: "`", in: span.text) + 1)
            let delimiter = String(repeating: "`", count: length)
            visible = delimiter + visible + delimiter
        }
        if span.marks.contains(.bold), span.marks.contains(.italic) {
            visible = "***\(visible)***"
        } else if span.marks.contains(.bold) {
            visible = "**\(visible)**"
        } else if span.marks.contains(.italic) {
            visible = "*\(visible)*"
        }
        if let url = span.linkURL {
            visible = "[\(visible)](\(url.absoluteString))"
        }
        let rendered = visible + MarkdownInlineLexer.manifest(for: span)
        return hasFollowingSpan && span.text.hasSuffix("\n") ? rendered + "\n" : rendered
    }

    private static func encodePayload(
        _ text: String,
        rawCode: Bool,
        emitPhysicalLineAfterTerminalBoundary: Bool
    ) -> String {
        let parts = text.components(separatedBy: "\n")
        guard parts.count > 1 else { return escapePayloadFragment(text, rawCode: rawCode) }
        var rendered = ""
        for index in parts.indices {
            let isLast = index == parts.index(before: parts.endIndex)
            if isLast {
                rendered += escapePayloadFragment(parts[index], rawCode: rawCode)
                continue
            }
            let isTerminalBoundary = index + 1 == parts.index(before: parts.endIndex) && parts.last == ""
            let line = parts[index]
            let hard = line.hasSuffix("  ")
            let preserved = hard ? String(line.dropLast(2)) : line
            rendered += escapePayloadFragment(preserved, rawCode: rawCode)
            rendered += (hard ? LogicalLineBoundary.hard : .soft).token
            if !isTerminalBoundary || emitPhysicalLineAfterTerminalBoundary {
                rendered += "\n"
            }
        }
        return rendered
    }

    private static func escapePayloadFragment(_ text: String, rawCode: Bool) -> String {
        let characters = Array(text)
        var output = ""
        var index = 0
        while index < characters.count {
            if characters[index] == "\\" {
                let start = index
                while index < characters.count, characters[index] == "\\" { index += 1 }
                let count = index - start
                if MarkdownInlineLexer.reservedPrefixStarts(in: characters, at: index) {
                    output += String(repeating: "\\", count: count * 2 + 1)
                    output.append(contentsOf: String(characters[index...]))
                    break
                }
                if rawCode {
                    output += String(repeating: "\\", count: count)
                } else {
                    output += String(repeating: "\\", count: count * 2)
                }
                continue
            }
            if MarkdownInlineLexer.reservedPrefixStarts(in: characters, at: index) {
                output += "\\"
                output.append(contentsOf: String(characters[index...]))
                break
            }
            let character = characters[index]
            if !rawCode && "*[]()`".contains(character) {
                output += "\\"
            }
            output.append(character)
            index += 1
        }
        return output
    }
}

private enum MarkdownInlineLexer {
    static let linkBlockMarker = "<!--jelly:block:link:v1-->"
    static let emptySpanSentinel = "<!--jelly:spans:v1;n=0-->"
    static let spanPrefix = "<!--jelly:span:v1;"
    static let reservedPrefix = "<!--jelly:"

    private struct SpanManifest {
        let marks: Set<InlineMark>
        let url: URL?
        let range: Range<String.Index>
        let raw: String
    }

    private struct DecodedVisibleSpan {
        var span: InlineSpan
        let endedWithBoundary: Bool
    }

    static func manifest(for span: InlineSpan) -> String {
        "<!--jelly:span:v1;m=\(manifestMarks(span.marks));u=\(encodedURL(span.linkURL))-->"
    }

    static func decode(
        _ source: String,
        firstLineNumber: Int,
        diagnostics: inout [BlockMarkdownDiagnostic]
    ) -> InlineContent {
        if source == emptySpanSentinel {
            return .init(spans: [])
        }
        if hasActiveSpanManifest(in: source) {
            return decodeManifested(source, firstLineNumber: firstLineNumber, diagnostics: &diagnostics)
        }
        let preservesRawMarkdown = hasActiveMalformedReservedPrefix(in: source)
        let payload = decodePayload(source, rawCode: true, firstLineNumber: firstLineNumber, diagnostics: &diagnostics)
        return preservesRawMarkdown ? .plain(payload.text) : MarkdownFallbackInlineDecoder.decode(payload.text)
    }

    static func hasActiveSpanManifest(in source: String) -> Bool {
        nextManifest(in: source, from: source.startIndex) != nil
    }

    static func activeBoundary(in line: String) -> LogicalLineBoundary? {
        for boundary in LogicalLineBoundary.allCases {
            var search = line.startIndex..<line.endIndex
            while let range = line.range(of: boundary.token, range: search) {
                if isEscaped(line, at: range.lowerBound) {
                    search = range.upperBound..<line.endIndex
                    continue
                }
                let suffix = String(line[range.upperBound...])
                if suffix.isEmpty || suffix.hasPrefix("\n") ||
                    (suffix.hasSuffix("-->") && suffix.contains(spanPrefix)) {
                    return boundary
                }
                search = range.upperBound..<line.endIndex
            }
        }
        return nil
    }

    static func diagnoseMalformedControls(
        in line: String,
        lineNumber: Int,
        diagnostics: inout [BlockMarkdownDiagnostic]
    ) {
        var search = line.startIndex..<line.endIndex
        while let range = line.range(of: reservedPrefix, range: search) {
            defer { search = range.upperBound..<line.endIndex }
            guard !isEscaped(line, at: range.lowerBound) else { continue }
            if LogicalLineBoundary.allCases.contains(where: { line[range.lowerBound...].hasPrefix($0.token) }),
               activeBoundary(in: line) != nil {
                continue
            }
            if nextManifest(in: line, from: range.lowerBound)?.range.lowerBound == range.lowerBound {
                continue
            }
            if line[range.lowerBound...].hasPrefix(linkBlockMarker), range.lowerBound == line.startIndex {
                continue
            }
            if line[range.lowerBound...].hasPrefix(emptySpanSentinel), line == emptySpanSentinel {
                continue
            }
            addDiagnostic("无效的 Jelly 控制标记已保留为正文", lineNumber: lineNumber, diagnostics: &diagnostics)
            return
        }
    }

    static func reservedPrefixStarts(in characters: [Character], at index: Int) -> Bool {
        guard index < characters.count else { return false }
        return String(characters[index...]).hasPrefix(reservedPrefix)
    }

    private static func decodeManifested(
        _ source: String,
        firstLineNumber: Int,
        diagnostics: inout [BlockMarkdownDiagnostic]
    ) -> InlineContent {
        var spans: [InlineSpan] = []
        var cursor = source.startIndex
        var lineNumber = firstLineNumber
        while let manifest = nextManifest(in: source, from: cursor) {
            let raw = String(source[cursor..<manifest.range.lowerBound])
            guard var decoded = decodeVisibleSpan(raw, firstLineNumber: lineNumber, diagnostics: &diagnostics) else {
                diagnostics.append(.init(lineNumber: lineNumber, message: "span 标记与可见 Markdown 不一致，已保留为正文"))
                return .plain(source)
            }
            if !raw.isEmpty, (decoded.span.marks != manifest.marks || decoded.span.linkURL != manifest.url) {
                diagnostics.append(.init(lineNumber: lineNumber, message: "span 标记与可见 Markdown 不一致，已保留为正文"))
                return .plain(source)
            }
            if raw.isEmpty {
                decoded.span.marks = manifest.marks
                decoded.span.linkURL = manifest.url
            }
            var next = manifest.range.upperBound
            if decoded.endedWithBoundary {
                if next == source.endIndex {
                    spans.append(decoded.span)
                    cursor = next
                    continue
                }
                guard source[next] == "\n" else {
                    diagnostics.append(.init(lineNumber: lineNumber, message: "span 续接标记缺少物理换行，已保留为正文"))
                    return .plain(source)
                }
                next = source.index(after: next)
                lineNumber += 1
            }
            spans.append(decoded.span)
            cursor = next
        }
        guard cursor == source.endIndex else {
            diagnostics.append(.init(lineNumber: lineNumber, message: "无效的 span 标记已保留为正文"))
            return .plain(source)
        }
        return .init(spans: spans)
    }

    private static func decodeVisibleSpan(
        _ raw: String,
        firstLineNumber: Int,
        diagnostics: inout [BlockMarkdownDiagnostic]
    ) -> DecodedVisibleSpan? {
        guard !raw.isEmpty else { return .init(span: .init(text: ""), endedWithBoundary: false) }
        var visible = raw
        var marks = Set<InlineMark>()
        var url: URL?

        if let link = unwrapWholeLink(visible) {
            visible = link.label
            url = link.url
        }
        if visible.hasPrefix("***"), visible.hasSuffix("***"), visible.count >= 6 {
            visible = String(visible.dropFirst(3).dropLast(3))
            marks.formUnion([.bold, .italic])
        } else if visible.hasPrefix("**"), visible.hasSuffix("**"), visible.count >= 4 {
            visible = String(visible.dropFirst(2).dropLast(2))
            marks.insert(.bold)
        } else if visible.hasPrefix("*"), visible.hasSuffix("*"), visible.count >= 2 {
            visible = String(visible.dropFirst().dropLast())
            marks.insert(.italic)
        }
        let characters = Array(visible)
        if let first = characters.first, first == "`" {
            let length = markdownRunLength(in: characters, at: 0, matching: "`")
            guard characters.count >= length * 2,
                  markdownRunLength(in: characters, at: characters.count - length, matching: "`") >= length else {
                return nil
            }
            visible = String(characters[length..<(characters.count - length)])
            marks.insert(.code)
        }
        let payload = decodePayload(visible, rawCode: marks.contains(.code), firstLineNumber: firstLineNumber, diagnostics: &diagnostics)
        return .init(span: .init(text: payload.text, marks: marks, linkURL: url), endedWithBoundary: payload.endedWithBoundary)
    }

    private static func decodePayload(
        _ source: String,
        rawCode: Bool,
        firstLineNumber: Int,
        diagnostics: inout [BlockMarkdownDiagnostic]
    ) -> (text: String, endedWithBoundary: Bool) {
        let characters = Array(source)
        var output = ""
        var index = 0
        while index < characters.count {
            if characters[index] == "\\" {
                let start = index
                while index < characters.count, characters[index] == "\\" { index += 1 }
                let count = index - start
                if reservedPrefixStarts(in: characters, at: index) {
                    let rest = String(characters[index...])
                    if count.isMultiple(of: 2), let boundary = boundaryPrefix(in: rest) {
                        output += String(repeating: "\\", count: count / 2)
                        return consumeBoundary(boundary, characters: characters, after: index + boundary.token.count, output: output, rawCode: rawCode, lineNumber: firstLineNumber, diagnostics: &diagnostics)
                    }
                    output += String(repeating: "\\", count: (count - 1) / 2)
                    output += rest
                    return (output, false)
                }
                if rawCode {
                    output += String(repeating: "\\", count: count)
                } else {
                    output += String(repeating: "\\", count: count / 2)
                    if count % 2 == 1, index < characters.count, markdownEscapable(characters[index]) {
                        output.append(characters[index])
                        index += 1
                    } else if count % 2 == 1 {
                        output += "\\"
                    }
                }
                continue
            }
            let rest = String(characters[index...])
            if let boundary = boundaryPrefix(in: rest) {
                return consumeBoundary(boundary, characters: characters, after: index + boundary.token.count, output: output, rawCode: rawCode, lineNumber: firstLineNumber, diagnostics: &diagnostics)
            }
            if rest.hasPrefix(reservedPrefix) {
                if let end = rest.range(of: "-->") {
                    let control = String(rest[..<end.upperBound])
                    output += control
                    index += control.count
                } else {
                    output.append(characters[index])
                    index += 1
                }
                continue
            }
            if !rawCode, characters[index] == "\\", index + 1 < characters.count, markdownEscapable(characters[index + 1]) {
                output.append(characters[index + 1])
                index += 2
            } else {
                output.append(characters[index])
                index += 1
            }
        }
        return (output, false)
    }

    private static func consumeBoundary(
        _ boundary: LogicalLineBoundary,
        characters: [Character],
        after index: Int,
        output: String,
        rawCode: Bool,
        lineNumber: Int,
        diagnostics: inout [BlockMarkdownDiagnostic]
    ) -> (text: String, endedWithBoundary: Bool) {
        if index == characters.count {
            return (output + boundary.modelSuffix, true)
        }
        guard characters[index] == "\n" else {
            return (output + boundary.token + String(characters[index...]), false)
        }
        var remainderDiagnostics = diagnostics
        let remainder = decodePayload(
            String(characters[(index + 1)...]),
            rawCode: rawCode,
            firstLineNumber: lineNumber + 1,
            diagnostics: &remainderDiagnostics
        )
        diagnostics = remainderDiagnostics
        return (output + boundary.modelSuffix + remainder.text, remainder.endedWithBoundary)
    }

    private static func unwrapWholeLink(_ source: String) -> (label: String, url: URL)? {
        let characters = Array(source)
        guard characters.first == "[",
              let labelEnd = markdownUnescapedIndex(of: "]", in: characters, startingAt: 1),
              labelEnd + 1 < characters.count,
              characters[labelEnd + 1] == "(",
              let urlEnd = markdownUnescapedIndex(of: ")", in: characters, startingAt: labelEnd + 2),
              urlEnd + 1 == characters.count else {
            return nil
        }
        let rawURL = String(characters[(labelEnd + 2)..<urlEnd])
        guard let url = URL(string: rawURL), markdownValidURL(url) else { return nil }
        return (String(characters[1..<labelEnd]), url)
    }

    private static func nextManifest(in source: String, from start: String.Index) -> SpanManifest? {
        var search = start..<source.endIndex
        while let prefix = source.range(of: spanPrefix, range: search) {
            defer { search = prefix.upperBound..<source.endIndex }
            guard !isEscaped(source, at: prefix.lowerBound),
                  let end = source.range(of: "-->", range: prefix.upperBound..<source.endIndex) else {
                continue
            }
            let body = String(source[prefix.upperBound..<end.lowerBound])
            guard let parsed = parseManifestBody(body) else { continue }
            let range = prefix.lowerBound..<end.upperBound
            return .init(marks: parsed.marks, url: parsed.url, range: range, raw: String(source[range]))
        }
        return nil
    }

    private static func parseManifestBody(_ body: String) -> (marks: Set<InlineMark>, url: URL?)? {
        guard body.hasPrefix("m="), let separator = body.range(of: ";u=") else { return nil }
        let rawMarks = String(body[body.index(body.startIndex, offsetBy: 2)..<separator.lowerBound])
        let rawURL = String(body[separator.upperBound...])
        guard let marks = parseManifestMarks(rawMarks), let url = decodedURL(rawURL) else { return nil }
        return (marks, url)
    }

    private static func parseManifestMarks(_ raw: String) -> Set<InlineMark>? {
        switch raw {
        case "~": []
        case "b": [.bold]
        case "c": [.code]
        case "i": [.italic]
        case "bc": [.bold, .code]
        case "bi": [.bold, .italic]
        case "ci": [.code, .italic]
        case "bci": [.bold, .code, .italic]
        default: nil
        }
    }

    private static func manifestMarks(_ marks: Set<InlineMark>) -> String {
        var value = ""
        if marks.contains(.bold) { value += "b" }
        if marks.contains(.code) { value += "c" }
        if marks.contains(.italic) { value += "i" }
        return value.isEmpty ? "~" : value
    }

    private static func encodedURL(_ url: URL?) -> String {
        guard let url else { return "~" }
        return Data(url.absoluteString.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodedURL(_ raw: String) -> URL?? {
        if raw == "~" { return .some(nil) }
        guard raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        let padding = String(repeating: "=", count: (4 - raw.count % 4) % 4)
        let base64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + padding
        guard let data = Data(base64Encoded: base64),
              let value = String(data: data, encoding: .utf8),
              let url = URL(string: value),
              markdownValidURL(url),
              encodedURL(url) == raw else {
            return nil
        }
        return .some(url)
    }

    private static func boundaryPrefix(in text: String) -> LogicalLineBoundary? {
        LogicalLineBoundary.allCases.first { text.hasPrefix($0.token) }
    }

    private static func hasActiveMalformedReservedPrefix(in source: String) -> Bool {
        var search = source.startIndex..<source.endIndex
        while let range = source.range(of: reservedPrefix, range: search) {
            defer { search = range.upperBound..<source.endIndex }
            guard !isEscaped(source, at: range.lowerBound) else { continue }
            let rest = String(source[range.lowerBound...])
            if boundaryPrefix(in: rest) != nil, activeBoundary(in: source) != nil {
                continue
            }
            return true
        }
        return false
    }

    private static func isEscaped(_ source: String, at index: String.Index) -> Bool {
        source[..<index].reversed().prefix { $0 == "\\" }.count % 2 == 1
    }

    private static func addDiagnostic(
        _ message: String,
        lineNumber: Int,
        diagnostics: inout [BlockMarkdownDiagnostic]
    ) {
        let diagnostic = BlockMarkdownDiagnostic(lineNumber: lineNumber, message: message)
        if !diagnostics.contains(diagnostic) {
            diagnostics.append(diagnostic)
        }
    }
}

private enum MarkdownFallbackInlineDecoder {
    static func decode(_ source: String) -> InlineContent {
        let characters = Array(source)
        var spans: [InlineSpan] = []
        var plain = ""
        var index = 0

        func flushPlain() {
            guard !plain.isEmpty else { return }
            if spans.last?.marks.isEmpty == true, spans.last?.linkURL == nil {
                spans[spans.count - 1].text += plain
            } else {
                spans.append(.init(text: plain))
            }
            plain = ""
        }
        func appendMarked(_ text: String, marks: Set<InlineMark>, url: URL? = nil) {
            flushPlain()
            spans.append(.init(text: text, marks: marks, linkURL: url))
        }
        func appendNested(_ text: String, marks: Set<InlineMark>, url: URL? = nil) {
            flushPlain()
            let nested = decode(text)
            if nested.spans.isEmpty {
                spans.append(.init(text: "", marks: marks, linkURL: url))
            } else {
                for var span in nested.spans {
                    span.marks.formUnion(marks)
                    if let url { span.linkURL = url }
                    spans.append(span)
                }
            }
        }

        while index < characters.count {
            if characters[index] == "\\", index + 1 < characters.count, markdownFallbackEscapable(characters[index + 1]) {
                plain.append(characters[index + 1])
                index += 2
                continue
            }
            if characters[index] == "[", let link = markdownExternalLinkAt(characters, start: index) {
                appendNested(link.label, marks: [], url: link.url)
                index = link.end
                continue
            }
            if characters[index] == "`" {
                let length = markdownRunLength(in: characters, at: index, matching: "`")
                if let close = markdownClosingRun(in: characters, after: index + length, character: "`", length: length) {
                    appendMarked(String(characters[(index + length)..<close]), marks: [.code])
                    index = close + length
                    continue
                }
            }
            if characters[index] == "*" {
                let run = markdownRunLength(in: characters, at: index, matching: "*")
                let length = run >= 3 ? 3 : (run >= 2 ? 2 : 1)
                if let close = markdownClosingRun(in: characters, after: index + length, character: "*", length: length) {
                    let marks: Set<InlineMark> = switch length {
                    case 1: [.italic]
                    case 2: [.bold]
                    default: [.bold, .italic]
                    }
                    appendNested(String(characters[(index + length)..<close]), marks: marks)
                    index = close + length
                    continue
                }
            }
            plain.append(characters[index])
            index += 1
        }
        flushPlain()
        return .init(spans: spans)
    }
}

private func markdownExternalLinkAt(_ characters: [Character], start: Int) -> (label: String, url: URL, end: Int)? {
    guard let labelEnd = markdownUnescapedIndex(of: "]", in: characters, startingAt: start + 1),
          labelEnd + 1 < characters.count,
          characters[labelEnd + 1] == "(",
          let urlEnd = markdownUnescapedIndex(of: ")", in: characters, startingAt: labelEnd + 2) else {
        return nil
    }
    let rawURL = String(characters[(labelEnd + 2)..<urlEnd])
    guard let url = URL(string: rawURL), markdownValidURL(url) else { return nil }
    return (String(characters[(start + 1)..<labelEnd]), url, urlEnd + 1)
}

private func encodeCodeFence(_ block: DocumentBlock) -> String {
    let info = block.codeInfoString ?? ""
    let character: Character = info.contains("`") ? "~" : "`"
    let text = block.inlineContent.spans[0].text
    let length = max(3, max(markdownLongestRun(of: character, in: info), markdownLongestRun(of: character, in: text)) + 1)
    let fence = String(repeating: String(character), count: length)
    return "\(fence)\(info)\n\(text)\n\(fence)"
}

private func escapeParagraphBlockStart(_ markdown: String) -> String {
    markdownStartsBlock(markdown) ? "\\" + markdown : markdown
}

private func markdownEscapable(_ character: Character) -> Bool {
    character == " " || character.isNumber || "\\*[]()`#->|~<".contains(character)
}

private func markdownFallbackEscapable(_ character: Character) -> Bool {
    character == " " || character.isNumber || "\\*[]()`#->|~".contains(character)
}

private func markdownListIndent(_ level: Int) -> String {
    String(repeating: "    ", count: level)
}

private func markdownRunLength(in characters: [Character], at index: Int, matching character: Character) -> Int {
    guard index < characters.count else { return 0 }
    var length = 0
    while index + length < characters.count, characters[index + length] == character { length += 1 }
    return length
}

private func markdownClosingRun(in characters: [Character], after start: Int, character: Character, length: Int) -> Int? {
    var index = start
    while index + length <= characters.count {
        if markdownRunLength(in: characters, at: index, matching: character) >= length { return index }
        index += 1
    }
    return nil
}

private func markdownLongestRun(of character: Character, in text: String) -> Int {
    let characters = Array(text)
    var longest = 0
    var index = 0
    while index < characters.count {
        let length = markdownRunLength(in: characters, at: index, matching: character)
        longest = max(longest, length)
        index += max(length, 1)
    }
    return longest
}

private func markdownValidURL(_ url: URL) -> Bool {
    url.scheme != nil && url.host != nil
}

private func markdownCoalescingFallbackSpans(_ content: InlineContent) -> InlineContent {
    var spans: [InlineSpan] = []
    for span in content.spans {
        if let last = spans.last,
           last.marks == span.marks,
           last.linkURL == span.linkURL {
            spans[spans.count - 1].text += span.text
        } else {
            spans.append(span)
        }
    }
    return .init(spans: spans)
}
