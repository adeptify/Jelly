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
        let normalizedMarkdown = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalizedMarkdown.components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        }

        var identifierGenerator = IdentifierGenerator(source: idSource)
        var blocks: [DocumentBlock] = []
        var diagnostics: [BlockMarkdownDiagnostic] = []
        var activeListIndentLevels = Set<Int>()
        var index = 0

        func appendBlock(
            kind: BlockKind,
            inlineContent: InlineContent,
            taskState: TaskBlockState? = nil,
            indentLevel: Int = 0,
            codeInfoString: String? = nil
        ) throws {
            blocks.append(.init(
                id: try identifierGenerator.next(),
                kind: kind,
                inlineContent: inlineContent,
                taskState: taskState,
                indentLevel: indentLevel,
                codeInfoString: codeInfoString
            ))
        }

        while index < lines.count {
            let line = lines[index]
            if line.isEmpty {
                activeListIndentLevels.removeAll()
                index += 1
                continue
            }

            if let openingFence = fenceOpening(in: line) {
                if let diagnosticMessage = unsupportedFenceDiagnostic(for: openingFence) {
                    let closingIndex = closingFenceIndex(in: lines, after: index, openingFence: openingFence)
                    let lastIndex = closingIndex ?? lines.index(before: lines.endIndex)
                    diagnostics.append(.init(lineNumber: index + 1, message: diagnosticMessage))
                    activeListIndentLevels.removeAll()
                    try appendBlock(
                        kind: .paragraph,
                        inlineContent: .plain(lines[index...lastIndex].joined(separator: "\n"))
                    )
                    index = lastIndex + 1
                    continue
                }
                var closingIndex = index + 1
                while closingIndex < lines.count,
                      !isFenceClosing(lines[closingIndex], for: openingFence) {
                    closingIndex += 1
                }
                guard closingIndex < lines.count else {
                    diagnostics.append(.init(
                        lineNumber: index + 1,
                        message: "未闭合的代码围栏已保留为正文"
                    ))
                    activeListIndentLevels.removeAll()
                    try appendBlock(
                        kind: .paragraph,
                        inlineContent: .plain(lines[index...].joined(separator: "\n"))
                    )
                    break
                }
                try appendBlock(
                    kind: .code,
                    inlineContent: .plain(lines[(index + 1)..<closingIndex].joined(separator: "\n")),
                    codeInfoString: openingFence.infoString
                )
                activeListIndentLevels.removeAll()
                index = closingIndex + 1
                continue
            }

            if line.hasPrefix("|") {
                let firstLine = index
                var tableLines: [String] = []
                while index < lines.count, !lines[index].isEmpty {
                    tableLines.append(lines[index])
                    index += 1
                }
                diagnostics.append(.init(
                    lineNumber: firstLine + 1,
                    message: "不支持的 Markdown 表格已保留为正文"
                ))
                activeListIndentLevels.removeAll()
                try appendBlock(kind: .paragraph, inlineContent: .plain(tableLines.joined(separator: "\n")))
                continue
            }

            if line.hasPrefix(">") {
                let quote = consumeQuote(
                    in: lines,
                    startingAt: index,
                    diagnostics: &diagnostics
                )
                activeListIndentLevels.removeAll()
                try appendBlock(kind: .quote, inlineContent: parseInlineMarkdown(quote.text))
                index = quote.nextIndex
                continue
            }

            if let heading = heading(in: line) {
                activeListIndentLevels.removeAll()
                let continuation = consumeExplicitContinuation(
                    startingWith: heading.text,
                    in: lines,
                    after: index + 1,
                    lineNumber: index + 1,
                    diagnostics: &diagnostics
                )
                try appendBlock(kind: heading.kind, inlineContent: parseInlineMarkdown(continuation.text))
                index = continuation.nextIndex
                continue
            }

            if line == "---" {
                activeListIndentLevels.removeAll()
                try appendBlock(kind: .divider, inlineContent: .plain(""))
                index += 1
                continue
            }

            if let list = listItem(in: line) {
                guard list.indentLevel == 0 || activeListIndentLevels.contains(list.indentLevel - 1) else {
                    diagnostics.append(.init(
                        lineNumber: index + 1,
                        message: "孤立的列表缩进已保留为正文"
                    ))
                    activeListIndentLevels.removeAll()
                    try appendBlock(kind: .paragraph, inlineContent: .plain(line))
                    index += 1
                    continue
                }
                let taskState: TaskBlockState?
                if list.kind == .task {
                    taskState = .init(completedAt: list.isChecked ? checkedTaskCompletedAt : nil)
                } else {
                    taskState = nil
                }
                let continuation = consumeExplicitContinuation(
                    startingWith: list.text,
                    in: lines,
                    after: index + 1,
                    lineNumber: index + 1,
                    diagnostics: &diagnostics
                )
                try appendBlock(
                    kind: list.kind,
                    inlineContent: parseInlineMarkdown(continuation.text),
                    taskState: taskState,
                    indentLevel: list.indentLevel
                )
                activeListIndentLevels = Set(activeListIndentLevels.filter { $0 <= list.indentLevel })
                activeListIndentLevels.insert(list.indentLevel)
                index = continuation.nextIndex
                continue
            }

            if let standaloneLink = standaloneLink(in: lines, at: index, diagnostics: &diagnostics) {
                activeListIndentLevels.removeAll()
                var content = inlineLinkContent(label: standaloneLink.link.label, url: standaloneLink.link.url)
                if let terminalBoundary = standaloneLink.terminalBoundary {
                    append(terminalBoundary.modelText, to: &content)
                }
                try appendBlock(
                    kind: .link,
                    inlineContent: content
                )
                index = standaloneLink.nextIndex
                continue
            }

            let paragraph = consumeParagraph(
                in: lines,
                startingAt: index,
                diagnostics: &diagnostics
            )
            activeListIndentLevels.removeAll()
            try appendBlock(kind: .paragraph, inlineContent: parseInlineMarkdown(paragraph.text))
            index = paragraph.nextIndex
        }

        let document = BlockDocument(blocks: blocks)
        try BlockDocumentValidator.validate(document)
        return .init(document: document, diagnostics: diagnostics)
    }

    public static func exportMarkdown(_ document: BlockDocument) throws -> String {
        try BlockDocumentValidator.validate(document)

        var renderedBlocks: [String] = []
        var previousWasList = false
        var orderedCounters: [Int: Int] = [:]

        for block in document.blocks {
            let isList = block.kind == .bullet || block.kind == .ordered || block.kind == .task
            var rendered: String
            switch block.kind {
            case .paragraph:
                rendered = exportParagraph(block.inlineContent)
            case .heading1:
                rendered = "# \(exportMultilineBlockContent(block.inlineContent))"
            case .heading2:
                rendered = "## \(exportMultilineBlockContent(block.inlineContent))"
            case .heading3:
                rendered = "### \(exportMultilineBlockContent(block.inlineContent))"
            case .bullet:
                rendered = "\(listIndent(block.indentLevel))- \(exportMultilineBlockContent(block.inlineContent))"
            case .ordered:
                let next = (orderedCounters[block.indentLevel] ?? 0) + 1
                orderedCounters[block.indentLevel] = next
                orderedCounters = orderedCounters.filter { $0.key <= block.indentLevel }
                rendered = "\(listIndent(block.indentLevel))\(next). \(exportMultilineBlockContent(block.inlineContent))"
            case .task:
                let checkbox = block.taskState?.completedAt == nil ? "[ ]" : "[x]"
                rendered = "\(listIndent(block.indentLevel))- \(checkbox) \(exportMultilineBlockContent(block.inlineContent))"
            case .quote:
                rendered = exportQuote(block.inlineContent)
            case .code:
                rendered = exportCode(block)
            case .divider:
                rendered = "---"
            case .link:
                rendered = exportLink(block.inlineContent)
            }
            if block.kind != .code {
                rendered = canonicalizeProseTrailingWhitespace(rendered)
            }

            if !renderedBlocks.isEmpty {
                renderedBlocks.append(previousWasList && isList ? "\n" : "\n\n")
            }
            renderedBlocks.append(rendered)
            previousWasList = isList
            if !isList {
                orderedCounters.removeAll()
            }
        }

        return renderedBlocks.joined()
    }
}

private struct IdentifierGenerator {
    private let source: BlockIDSource
    private var fixedIdentifiers: ArraySlice<BlockID>

    init(source: BlockIDSource) {
        self.source = source
        switch source {
        case .random:
            fixedIdentifiers = []
        case let .fixed(identifiers):
            fixedIdentifiers = ArraySlice(identifiers)
        }
    }

    mutating func next() throws -> BlockID {
        switch source {
        case .random:
            return BlockID()
        case .fixed:
            guard let identifier = fixedIdentifiers.popFirst() else {
                throw BlockMarkdownCodecError.insufficientBlockIDs
            }
            return identifier
        }
    }
}

private struct FenceOpening {
    let character: Character
    let length: Int
    let infoString: String?
}

private struct Heading {
    let kind: BlockKind
    let text: String
}

private struct ListItem {
    let kind: BlockKind
    let text: String
    let indentLevel: Int
    let isChecked: Bool
}

private struct StandaloneLink {
    let label: String
    let url: URL
}

private enum ContinuationBoundary: CaseIterable {
    case soft
    case hard

    static let reservedPrefix = "<!--jelly:continue-"

    var token: String {
        switch self {
        case .soft: "<!--jelly:continue-soft:v1-->"
        case .hard: "<!--jelly:continue-hard:v1-->"
        }
    }

    var modelText: String {
        switch self {
        case .soft: "\n"
        case .hard: "  \n"
        }
    }
}

private struct ScannedStandaloneLink {
    let link: StandaloneLink
    let terminalBoundary: ContinuationBoundary?
    let nextIndex: Int
}

private func fenceOpening(in line: String) -> FenceOpening? {
    let characters = Array(line)
    guard let character = characters.first, character == "`" || character == "~" else {
        return nil
    }
    let length = runLength(in: characters, at: 0, matching: character)
    guard length >= 3 else { return nil }
    let infoString = DocumentBlock.canonicalCodeInfoString(String(characters.dropFirst(length)))
    return .init(character: character, length: length, infoString: infoString)
}

private func unsupportedFenceDiagnostic(for openingFence: FenceOpening) -> String? {
    guard let infoString = openingFence.infoString else { return nil }
    if infoString.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 }) {
        return "无效的代码围栏信息已保留为正文"
    }
    if openingFence.character == "`", infoString.contains("`") {
        return "不支持的代码围栏信息已保留为正文"
    }
    return nil
}

private func closingFenceIndex(in lines: [String], after index: Int, openingFence: FenceOpening) -> Int? {
    var closingIndex = index + 1
    while closingIndex < lines.count {
        if isFenceClosing(lines[closingIndex], for: openingFence) {
            return closingIndex
        }
        closingIndex += 1
    }
    return nil
}

private func isFenceClosing(_ line: String, for opening: FenceOpening) -> Bool {
    let characters = Array(line)
    let length = runLength(in: characters, at: 0, matching: opening.character)
    guard length >= opening.length else { return false }
    return characters.dropFirst(length).allSatisfy { $0 == " " || $0 == "\t" }
}

private func heading(in line: String) -> Heading? {
    for level in 1...3 {
        let prefix = String(repeating: "#", count: level) + " "
        if line.hasPrefix(prefix) {
            let kind: BlockKind
            switch level {
            case 1: kind = .heading1
            case 2: kind = .heading2
            default: kind = .heading3
            }
            return .init(kind: kind, text: String(line.dropFirst(prefix.count)))
        }
    }
    return nil
}

private func listItem(in line: String) -> ListItem? {
    let leadingSpaces = line.prefix { $0 == " " }.count
    let indentation = min(leadingSpaces / 4, 3)
    let overflowSpaces = max(0, leadingSpaces - indentation * 4)
    let content = String(line.dropFirst(leadingSpaces))
    let overflow = String(repeating: " ", count: overflowSpaces)

    if content.hasPrefix("- [ ] ") {
        return .init(kind: .task, text: overflow + String(content.dropFirst(6)), indentLevel: indentation, isChecked: false)
    }
    if content.hasPrefix("- [x] ") || content.hasPrefix("- [X] ") {
        return .init(kind: .task, text: overflow + String(content.dropFirst(6)), indentLevel: indentation, isChecked: true)
    }
    if content.hasPrefix("- ") || content.hasPrefix("* ") {
        return .init(kind: .bullet, text: overflow + String(content.dropFirst(2)), indentLevel: indentation, isChecked: false)
    }

    let characters = Array(content)
    var digitCount = 0
    while digitCount < characters.count, characters[digitCount].isASCII, characters[digitCount].isNumber {
        digitCount += 1
    }
    guard digitCount > 0,
          digitCount + 1 < characters.count,
          characters[digitCount] == ".",
          characters[digitCount + 1] == " " else {
        return nil
    }
    return .init(
        kind: .ordered,
        text: overflow + String(characters.dropFirst(digitCount + 2)),
        indentLevel: indentation,
        isChecked: false
    )
}

private func standaloneLink(in line: String) -> StandaloneLink? {
    let characters = Array(line)
    guard characters.first == "[",
          let link = inlineLink(in: characters, at: 0),
          link.endIndex == characters.count else {
        return nil
    }
    return .init(label: link.label, url: link.url)
}

private func standaloneLink(
    in lines: [String],
    at index: Int,
    diagnostics: inout [BlockMarkdownDiagnostic]
) -> ScannedStandaloneLink? {
    var candidate = lines[index]
    var nextIndex = index + 1

    while true {
        let terminalBoundary = trailingContinuationBoundary(in: candidate)
        let candidateWithoutBoundary = terminalBoundary.map { removeTrailingContinuationBoundary($0, from: candidate) } ?? candidate
        if let link = standaloneLink(in: candidateWithoutBoundary) {
            let decodedLabel = decodeContinuationBoundaries(
                in: link.label,
                firstLineNumber: index + 1,
                diagnostics: &diagnostics
            )
            return .init(
                link: .init(label: decodedLabel, url: link.url),
                terminalBoundary: terminalBoundary,
                nextIndex: nextIndex
            )
        }
        guard hasUnclosedStandaloneLinkLabel(in: candidate), nextIndex < lines.count else {
            return nil
        }
        candidate += "\n" + lines[nextIndex]
        nextIndex += 1
    }
}

private func hasUnclosedStandaloneLinkLabel(in candidate: String) -> Bool {
    let characters = Array(candidate)
    return characters.first == "[" && unescapedDelimiterIndex("]", in: characters, startingAt: 1) == nil
}

private func consumeExplicitContinuation(
    startingWith firstLine: String,
    in lines: [String],
    after index: Int,
    lineNumber: Int,
    diagnostics: inout [BlockMarkdownDiagnostic]
) -> (text: String, nextIndex: Int) {
    var text = ""
    var currentLine = firstLine
    var currentLineNumber = lineNumber
    var nextIndex = index

    while true {
        appendMalformedContinuationDiagnostic(
            for: currentLine,
            lineNumber: currentLineNumber,
            diagnostics: &diagnostics
        )
        guard let boundary = trailingContinuationBoundary(in: currentLine) else {
            return (text + currentLine, nextIndex)
        }
        text += removeTrailingContinuationBoundary(boundary, from: currentLine) + boundary.modelText
        guard nextIndex < lines.count else {
            return (text, nextIndex)
        }
        currentLine = lines[nextIndex]
        currentLineNumber = nextIndex + 1
        nextIndex += 1
    }
}

private func consumeParagraph(
    in lines: [String],
    startingAt index: Int,
    diagnostics: inout [BlockMarkdownDiagnostic]
) -> (text: String, nextIndex: Int) {
    var text = ""
    var currentIndex = index

    while currentIndex < lines.count {
        let line = lines[currentIndex]
        appendMalformedContinuationDiagnostic(for: line, lineNumber: currentIndex + 1, diagnostics: &diagnostics)
        if let boundary = trailingContinuationBoundary(in: line) {
            text += removeTrailingContinuationBoundary(boundary, from: line) + boundary.modelText
            currentIndex += 1
            continue
        }

        text += line
        currentIndex += 1
        guard currentIndex < lines.count,
              !lines[currentIndex].isEmpty,
              !isBlockStart(lines[currentIndex]),
              !couldStartMultilineStandaloneLink(in: lines, at: currentIndex) else {
            return (text, currentIndex)
        }
        text += "\n"
    }
    return (text, currentIndex)
}

private func consumeQuote(
    in lines: [String],
    startingAt index: Int,
    diagnostics: inout [BlockMarkdownDiagnostic]
) -> (text: String, nextIndex: Int) {
    var text = ""
    var currentLine = quoteContent(in: lines[index])
    var currentLineNumber = index + 1
    var nextIndex = index + 1

    while true {
        appendMalformedContinuationDiagnostic(
            for: currentLine,
            lineNumber: currentLineNumber,
            diagnostics: &diagnostics
        )
        if let boundary = trailingContinuationBoundary(in: currentLine) {
            text += removeTrailingContinuationBoundary(boundary, from: currentLine) + boundary.modelText
            guard nextIndex < lines.count else {
                return (text, nextIndex)
            }
            currentLine = lines[nextIndex].hasPrefix(">")
                ? quoteContent(in: lines[nextIndex])
                : lines[nextIndex]
            currentLineNumber = nextIndex + 1
            nextIndex += 1
            continue
        }

        text += currentLine
        guard nextIndex < lines.count, lines[nextIndex].hasPrefix(">") else {
            return (text, nextIndex)
        }
        text += "\n"
        currentLine = quoteContent(in: lines[nextIndex])
        currentLineNumber = nextIndex + 1
        nextIndex += 1
    }
}

private func quoteContent(in line: String) -> String {
    guard line.hasPrefix(">") else { return line }
    return line.hasPrefix("> ") ? String(line.dropFirst(2)) : String(line.dropFirst())
}

private func couldStartMultilineStandaloneLink(in lines: [String], at index: Int) -> Bool {
    var ignoredDiagnostics: [BlockMarkdownDiagnostic] = []
    return standaloneLink(in: lines, at: index, diagnostics: &ignoredDiagnostics) != nil
}

private func decodeContinuationBoundaries(
    in text: String,
    firstLineNumber: Int,
    diagnostics: inout [BlockMarkdownDiagnostic]
) -> String {
    let lines = text.components(separatedBy: "\n")
    var decoded = ""
    for (offset, line) in lines.enumerated() {
        appendMalformedContinuationDiagnostic(
            for: line,
            lineNumber: firstLineNumber + offset,
            diagnostics: &diagnostics
        )
        if let boundary = trailingContinuationBoundary(in: line) {
            decoded += removeTrailingContinuationBoundary(boundary, from: line) + boundary.modelText
        } else {
            decoded += line
            if offset < lines.count - 1 {
                decoded += "\n"
            }
        }
    }
    return decoded
}

private func trailingContinuationBoundary(in line: String) -> ContinuationBoundary? {
    for boundary in ContinuationBoundary.allCases where line.hasSuffix(boundary.token) {
        let tokenStart = line.index(line.endIndex, offsetBy: -boundary.token.count)
        let precedingBackslashes = line[..<tokenStart].reversed().prefix { $0 == "\\" }.count
        if precedingBackslashes.isMultiple(of: 2) {
            return boundary
        }
    }
    return nil
}

private func removeTrailingContinuationBoundary(_ boundary: ContinuationBoundary, from line: String) -> String {
    String(line.dropLast(boundary.token.count))
}

private func appendMalformedContinuationDiagnostic(
    for line: String,
    lineNumber: Int,
    diagnostics: inout [BlockMarkdownDiagnostic]
) {
    let activeBoundary = trailingContinuationBoundary(in: line)
    let activeTokenStart = activeBoundary.map { line.index(line.endIndex, offsetBy: -$0.token.count) }
    var searchRange = line.startIndex..<line.endIndex

    while let prefixRange = line.range(of: ContinuationBoundary.reservedPrefix, range: searchRange) {
        let precedingBackslashes = line[..<prefixRange.lowerBound].reversed().prefix { $0 == "\\" }.count
        let isActiveToken = prefixRange.lowerBound == activeTokenStart
        if precedingBackslashes.isMultiple(of: 2), !isActiveToken {
            diagnostics.append(.init(lineNumber: lineNumber, message: "无效的续接标记已保留为正文"))
            return
        }
        guard prefixRange.upperBound < line.endIndex else { return }
        searchRange = prefixRange.upperBound..<line.endIndex
    }
}

private func append(_ text: String, to content: inout InlineContent) {
    guard !text.isEmpty else { return }
    if content.spans.isEmpty {
        content.spans = [.init(text: text)]
    } else {
        content.spans[content.spans.count - 1].text += text
    }
}

private func isBlockStart(_ line: String) -> Bool {
    fenceOpening(in: line) != nil ||
        line.hasPrefix("|") ||
        line.hasPrefix(">") ||
        heading(in: line) != nil ||
        line == "---" ||
        listItem(in: line) != nil ||
        standaloneLink(in: line) != nil
}

private func parseInline(_ text: String) -> InlineContent {
    let characters = Array(text)
    var spans: [InlineSpan] = []
    var plainText = ""
    var index = 0

    func appendPlain() {
        guard !plainText.isEmpty else { return }
        if spans.last?.marks.isEmpty == true, spans.last?.linkURL == nil {
            spans[spans.count - 1].text += plainText
        } else {
            spans.append(.init(text: plainText))
        }
        plainText = ""
    }

    func appendMarked(_ content: String, marks: Set<InlineMark> = [], linkURL: URL? = nil) {
        appendPlain()
        spans.append(.init(text: content, marks: marks, linkURL: linkURL))
    }

    func appendLink(_ label: String, url: URL) {
        appendPlain()
        spans.append(contentsOf: inlineLinkContent(label: label, url: url).spans)
    }

    func appendEmphasized(_ content: String, marks: Set<InlineMark>) {
        appendPlain()
        let nested = parseInline(content)
        if nested.spans.isEmpty {
            spans.append(.init(text: "", marks: marks))
        } else {
            for var span in nested.spans {
                span.marks.formUnion(marks)
                spans.append(span)
            }
        }
    }

    while index < characters.count {
        let character = characters[index]
        if character == "\\", index + 1 < characters.count,
           characters[index + 1] == "[",
           let link = inlineLink(in: characters, at: index + 1) {
            appendLink(link.label, url: link.url)
            index = link.endIndex
            continue
        }
        if character == "\\", index + 1 < characters.count,
           isEscapableMarkdownCharacter(characters[index + 1]) {
            plainText.append(characters[index + 1])
            index += 2
            continue
        }
        if character == "[", let link = inlineLink(in: characters, at: index) {
            appendLink(link.label, url: link.url)
            index = link.endIndex
            continue
        }
        if character == "`" {
            let length = runLength(in: characters, at: index, matching: character)
            if let close = closingRun(in: characters, after: index + length, character: character, length: length) {
                appendMarked(String(characters[(index + length)..<close]), marks: [.code])
                index = close + length
                continue
            }
        }
        if character == "*" {
            let length = runLength(in: characters, at: index, matching: character)
            let markerLength = length >= 3 ? 3 : (length >= 2 ? 2 : 1)
            if let close = closingRun(in: characters, after: index + markerLength, character: character, length: markerLength) {
                let marks: Set<InlineMark>
                switch markerLength {
                case 1: marks = [.italic]
                case 2: marks = [.bold]
                default: marks = [.bold, .italic]
                }
                appendEmphasized(String(characters[(index + markerLength)..<close]), marks: marks)
                index = close + markerLength
                continue
            }
        }
        plainText.append(character)
        index += 1
    }
    appendPlain()
    return .init(spans: spans)
}

private func parseInlineMarkdown(_ markdown: String) -> InlineContent {
    let lines = markdown.components(separatedBy: "\n")
    let normalizedLines = lines.enumerated().map { offset, line -> String in
        let isHardBreak = offset < lines.count - 1 && hasOddTrailingBackslash(line)
        if isHardBreak {
            return String(line.dropLast()) + "  "
        }
        return line
    }
    return parseInline(normalizedLines.joined(separator: "\n"))
}

private func parseInlineLinkLabel(_ label: String) -> InlineContent {
    let lines = label.components(separatedBy: "\n")
    let normalizedLines = lines.enumerated().map { offset, line -> String in
        guard offset < lines.count - 1, hasOddTrailingBackslash(line) else { return line }
        return String(line.dropLast()) + "  "
    }
    return parseInline(normalizedLines.joined(separator: "\n"))
}

private func inlineLink(in characters: [Character], at index: Int) -> (label: String, url: URL, endIndex: Int)? {
    guard let closingLabel = unescapedDelimiterIndex("]", in: characters, startingAt: index + 1),
          closingLabel + 1 < characters.count,
          characters[closingLabel + 1] == "(" else {
        return nil
    }
    guard let closingURL = unescapedDelimiterIndex(")", in: characters, startingAt: closingLabel + 2) else {
        return nil
    }
    let rawURL = String(characters[(closingLabel + 2)..<closingURL])
    guard let url = URL(string: rawURL), isValidLinkURL(url) else { return nil }
    return (
        label: String(characters[(index + 1)..<closingLabel]),
        url: url,
        endIndex: closingURL + 1
    )
}

private func unescapedDelimiterIndex(
    _ delimiter: Character,
    in characters: [Character],
    startingAt index: Int
) -> Int? {
    var candidate = index
    while candidate < characters.count {
        if characters[candidate] == "\\" {
            candidate += 2
        } else if characters[candidate] == delimiter {
            return candidate
        } else {
            candidate += 1
        }
    }
    return nil
}

private func exportInline(_ content: InlineContent) -> String {
    content.spans.map { span in
        var rendered = escapePlainText(span.text)
        if span.marks.contains(.code) {
            let length = max(1, longestRun(of: "`", in: span.text) + 1)
            let delimiter = String(repeating: "`", count: length)
            rendered = "\(delimiter)\(span.text)\(delimiter)"
        }
        if span.marks.contains(.bold), span.marks.contains(.italic) {
            rendered = "***\(rendered)***"
        } else if span.marks.contains(.bold) {
            rendered = "**\(rendered)**"
        } else if span.marks.contains(.italic) {
            rendered = "*\(rendered)*"
        }
        if let linkURL = span.linkURL {
            rendered = "[\(rendered)](\(linkURL.absoluteString))"
        }
        return rendered
    }.joined()
}

private func exportParagraph(_ content: InlineContent) -> String {
    exportInline(content)
        .components(separatedBy: "\n")
        .enumerated()
        .map { offset, line in offset == 0 ? escapeBlockStart(line) : line }
        .joined(separator: "\n")
}

private func exportMultilineBlockContent(_ content: InlineContent) -> String {
    exportInline(content)
}

private func exportLink(_ content: InlineContent) -> String {
    guard let terminalBoundary = terminalContinuationBoundary(in: content) else {
        return exportMultilineBlockContent(content)
    }
    return exportMultilineBlockContent(removingTerminalContinuationBoundary(terminalBoundary, from: content)) + terminalBoundary.token
}

private func exportQuote(_ content: InlineContent) -> String {
    guard !content.spans.isEmpty else { return ">" }
    let terminalBoundary = terminalContinuationBoundary(in: content)
    let contentWithoutTerminalBoundary = terminalBoundary.map {
        removingTerminalContinuationBoundary($0, from: content)
    } ?? content
    let quoted = exportInline(contentWithoutTerminalBoundary)
        .components(separatedBy: "\n")
        .map { "> \($0)" }
        .joined(separator: "\n")
    return terminalBoundary.map { quoted + $0.token } ?? quoted
}

private func terminalContinuationBoundary(in content: InlineContent) -> ContinuationBoundary? {
    guard let lastSpan = content.spans.last, lastSpan.text.hasSuffix("\n") else {
        return nil
    }
    let textBeforeNewline = String(lastSpan.text.dropLast())
    return textBeforeNewline.trailingWhitespaceCount >= 2 ? .hard : .soft
}

private func removingTerminalContinuationBoundary(
    _ boundary: ContinuationBoundary,
    from content: InlineContent
) -> InlineContent {
    var result = content
    guard !result.spans.isEmpty else { return result }
    result.spans[result.spans.count - 1].text.removeLast()
    if boundary == .hard {
        result.spans[result.spans.count - 1].text = result.spans[result.spans.count - 1].text.trimmingTrailingWhitespace()
    }
    return result
}

private func inlineLinkContent(label: String, url: URL) -> InlineContent {
    var content = parseInlineLinkLabel(label)
    if content.spans.isEmpty {
        content.spans = [.init(text: "", linkURL: url)]
    } else {
        for index in content.spans.indices {
            content.spans[index].linkURL = url
        }
    }
    return content
}

private func exportCode(_ block: DocumentBlock) -> String {
    let infoString = block.codeInfoString ?? ""
    let fenceCharacter: Character = infoString.contains("`") ? "~" : "`"
    let fenceLength = max(
        3,
        max(longestRun(of: fenceCharacter, in: infoString), longestRun(of: fenceCharacter, in: inlinePlainText(block.inlineContent))) + 1
    )
    let fence = String(repeating: String(fenceCharacter), count: fenceLength)
    return "\(fence)\(infoString)\n\(inlinePlainText(block.inlineContent))\n\(fence)"
}

private func inlinePlainText(_ content: InlineContent) -> String {
    content.spans.map(\.text).joined()
}

private func escapePlainText(_ text: String) -> String {
    let escapedMarkdown = String(text.flatMap { character -> [Character] in
        if "\\*[]()`".contains(character) {
            return ["\\", character]
        }
        return [character]
    })
    return ContinuationBoundary.allCases.reduce(escapedMarkdown) { partialResult, boundary in
        partialResult.replacingOccurrences(of: boundary.token, with: "\\" + boundary.token)
    }
}

private func canonicalizeProseTrailingWhitespace(_ text: String) -> String {
    var lines = text.components(separatedBy: "\n")
    let endsWithNewline = lines.last == ""
    if endsWithNewline {
        lines.removeLast()
    }
    return lines.enumerated().map { offset, line in
        let trimmed = line.trimmingTrailingWhitespace()
        let hasContinuation = offset < lines.count - 1 || endsWithNewline
        guard hasContinuation else { return trimmed }
        if line.trailingWhitespaceCount >= 2 {
            return trimmed + ContinuationBoundary.hard.token
        }
        return trimmed + ContinuationBoundary.soft.token
    }.joined(separator: "\n")
}

private func escapeBlockStart(_ line: String) -> String {
    isBlockStart(line) ? "\\" + line : line
}

private func isEscapableMarkdownCharacter(_ character: Character) -> Bool {
    character == " " || character.isNumber || "\\*[]()`#->|~<".contains(character)
}

private func hasOddTrailingBackslash(_ line: String) -> Bool {
    line.reversed().prefix { $0 == "\\" }.count % 2 == 1
}

private extension String {
    var trailingWhitespaceCount: Int {
        reversed().prefix { $0 == " " || $0 == "\t" }.count
    }

    func trimmingTrailingWhitespace() -> String {
        String(dropLast(trailingWhitespaceCount))
    }
}

private func listIndent(_ level: Int) -> String {
    String(repeating: "    ", count: level)
}

private func runLength(in characters: [Character], at index: Int, matching character: Character) -> Int {
    guard index < characters.count else { return 0 }
    var length = 0
    while index + length < characters.count, characters[index + length] == character {
        length += 1
    }
    return length
}

private func closingRun(in characters: [Character], after index: Int, character: Character, length: Int) -> Int? {
    var candidate = index
    while candidate + length <= characters.count {
        if runLength(in: characters, at: candidate, matching: character) >= length {
            return candidate
        }
        candidate += 1
    }
    return nil
}

private func longestRun(of character: Character, in text: String) -> Int {
    let characters = Array(text)
    var longest = 0
    var index = 0
    while index < characters.count {
        let length = runLength(in: characters, at: index, matching: character)
        longest = max(longest, length)
        index += max(length, 1)
    }
    return longest
}

private func isValidLinkURL(_ url: URL) -> Bool {
    url.scheme != nil && url.host != nil
}
