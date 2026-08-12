import Foundation
import WorkspaceDomain

enum BlockEditorBridgeError: Error, Equatable, Sendable {
    case missingBlock(BlockID)
    case negativeUTF16Offset
    case nsNotFound
    case integerOverflow
    case utf16OffsetOutOfRange
    case midGraphemeBoundary
    case crossBlockRange
}

struct BlockTextRange: Equatable, Sendable {
    let start: BlockTextPosition
    let end: BlockTextPosition
}

protocol BlockSelectionBridging {
    static func graphemePosition(
        blockID: BlockID,
        utf16Offset: Int,
        document: BlockDocument
    ) throws -> BlockTextPosition

    static func utf16Offset(
        position: BlockTextPosition,
        document: BlockDocument
    ) throws -> Int

    static func graphemeRange(
        blockID: BlockID,
        nsRange: NSRange,
        document: BlockDocument
    ) throws -> BlockTextRange

    static func nsRange(
        textRange: BlockTextRange,
        document: BlockDocument
    ) throws -> NSRange
}

enum BlockSelectionBridge: BlockSelectionBridging {
    static func graphemePosition(
        blockID: BlockID,
        utf16Offset: Int,
        document: BlockDocument
    ) throws -> BlockTextPosition {
        let block = try block(id: blockID, document: document)
        try validateUTF16Offset(utf16Offset)
        guard block.kind != .divider else {
            guard utf16Offset == 0 else { throw BlockEditorBridgeError.utf16OffsetOutOfRange }
            return .init(blockID: blockID, graphemeOffset: 0)
        }

        let text = plainText(block)
        guard utf16Offset <= text.utf16.count else { throw BlockEditorBridgeError.utf16OffsetOutOfRange }
        var currentUTF16 = 0
        if utf16Offset == 0 { return .init(blockID: blockID, graphemeOffset: 0) }
        for (offset, character) in text.enumerated() {
            currentUTF16 += String(character).utf16.count
            if currentUTF16 == utf16Offset {
                return .init(blockID: blockID, graphemeOffset: offset + 1)
            }
            if currentUTF16 > utf16Offset { throw BlockEditorBridgeError.midGraphemeBoundary }
        }
        // The range guard above ensures this is reachable only at the exact end.
        return .init(blockID: blockID, graphemeOffset: text.count)
    }

    static func utf16Offset(
        position: BlockTextPosition,
        document: BlockDocument
    ) throws -> Int {
        let block = try block(id: position.blockID, document: document)
        guard position.graphemeOffset >= 0 else { throw BlockEditorBridgeError.negativeUTF16Offset }
        guard block.kind != .divider else {
            guard position.graphemeOffset == 0 else { throw BlockEditorBridgeError.utf16OffsetOutOfRange }
            return 0
        }
        let text = plainText(block)
        guard position.graphemeOffset <= text.count else { throw BlockEditorBridgeError.utf16OffsetOutOfRange }
        return text.prefix(position.graphemeOffset).utf16.count
    }

    static func graphemeRange(
        blockID: BlockID,
        nsRange: NSRange,
        document: BlockDocument
    ) throws -> BlockTextRange {
        guard nsRange.location != NSNotFound, nsRange.length != NSNotFound else {
            throw BlockEditorBridgeError.nsNotFound
        }
        guard nsRange.location >= 0, nsRange.length >= 0 else {
            throw BlockEditorBridgeError.negativeUTF16Offset
        }
        let (end, overflow) = nsRange.location.addingReportingOverflow(nsRange.length)
        guard !overflow else { throw BlockEditorBridgeError.integerOverflow }
        let start = try graphemePosition(blockID: blockID, utf16Offset: nsRange.location, document: document)
        let finish = try graphemePosition(blockID: blockID, utf16Offset: end, document: document)
        return .init(start: start, end: finish)
    }

    static func nsRange(
        textRange: BlockTextRange,
        document: BlockDocument
    ) throws -> NSRange {
        guard textRange.start.blockID == textRange.end.blockID,
              textRange.start.graphemeOffset <= textRange.end.graphemeOffset else {
            throw BlockEditorBridgeError.crossBlockRange
        }
        let start = try utf16Offset(position: textRange.start, document: document)
        let end = try utf16Offset(position: textRange.end, document: document)
        return .init(location: start, length: end - start)
    }

    private static func block(id: BlockID, document: BlockDocument) throws -> DocumentBlock {
        guard let block = document.blocks.first(where: { $0.id == id }) else {
            throw BlockEditorBridgeError.missingBlock(id)
        }
        return block
    }

    private static func validateUTF16Offset(_ value: Int) throws {
        if value == NSNotFound { throw BlockEditorBridgeError.nsNotFound }
        if value < 0 { throw BlockEditorBridgeError.negativeUTF16Offset }
    }

    private static func plainText(_ block: DocumentBlock) -> String {
        block.inlineContent.spans.map(\.text).joined()
    }
}

@MainActor
final class BlockSelectionController {
    private(set) var selection: BlockEditorSelection

    init(selection: BlockEditorSelection) {
        self.selection = selection
    }

    func setSelection(_ newSelection: BlockEditorSelection) {
        selection = newSelection
    }

    func beginPointer(at position: BlockTextPosition, attributes: BlockTypingAttributes) {
        selection = .text(
            anchor: position,
            focus: position,
            preferredColumn: nil,
            typingAttributes: attributes
        )
    }

    func extendPointer(to position: BlockTextPosition) {
        guard case let .text(anchor, _, _, attributes) = selection else { return }
        selection = .text(
            anchor: anchor,
            focus: position,
            preferredColumn: nil,
            typingAttributes: attributes
        )
    }

    /// Shift extension intentionally keeps the original anchor. It is the same
    /// direction-preserving operation as a pointer drag after its first point.
    func extendWithShift(to position: BlockTextPosition) {
        extendPointer(to: position)
    }

    func beginBlockSelection(at blockID: BlockID) {
        selection = .blocks(anchor: blockID, focus: blockID)
    }

    func extendBlockSelection(to blockID: BlockID) {
        guard case let .blocks(anchor, _) = selection else {
            beginBlockSelection(at: blockID)
            return
        }
        selection = .blocks(anchor: anchor, focus: blockID)
    }

    func globalRange(in projection: BlockDocumentTextProjection) -> NSRange? {
        try? projection.nsRange(for: selection)
    }

    func adoptGlobalRange(
        _ range: NSRange,
        direction: SelectionDirection,
        projection: BlockDocumentTextProjection,
        typingAttributes: BlockTypingAttributes
    ) throws {
        selection = try projection.selection(
            for: range,
            preserving: direction,
            typingAttributes: typingAttributes
        )
    }

    /// AppKit gets only the part of a cross-host selection which belongs to its own host.
    /// The original anchor/focus direction remains in `selection` and is never replaced by
    /// a synthetic document-wide NSRange.
    func projectedRange(for blockID: BlockID, document: BlockDocument) -> NSRange? {
        if case let .blocks(anchor, focus) = selection {
            let order = document.blocks.map(\.id)
            guard let anchorIndex = order.firstIndex(of: anchor),
                  let focusIndex = order.firstIndex(of: focus),
                  let blockIndex = order.firstIndex(of: blockID),
                  min(anchorIndex, focusIndex) <= blockIndex,
                  blockIndex <= max(anchorIndex, focusIndex),
                  let block = document.blocks.first(where: { $0.id == blockID }) else { return nil }
            return .init(location: 0, length: block.kind == .divider ? 0 : Self.text(block).utf16.count)
        }
        guard case let .text(anchor, focus, _, _) = selection else { return nil }
        if anchor.blockID == blockID, focus.blockID == blockID {
            let normalized = BlockTextRange(
                start: anchor.graphemeOffset <= focus.graphemeOffset ? anchor : focus,
                end: anchor.graphemeOffset <= focus.graphemeOffset ? focus : anchor
            )
            return try? BlockSelectionBridge.nsRange(textRange: normalized, document: document)
        }
        let order = document.blocks.map(\.id)
        guard let anchorIndex = order.firstIndex(of: anchor.blockID),
              let focusIndex = order.firstIndex(of: focus.blockID),
              let blockIndex = order.firstIndex(of: blockID) else { return nil }
        let lower = min(anchorIndex, focusIndex)
        let upper = max(anchorIndex, focusIndex)
        guard lower <= blockIndex, blockIndex <= upper else { return nil }
        guard let block = document.blocks.first(where: { $0.id == blockID }) else { return nil }
        let count = block.kind == .divider ? 0 : Self.text(block).utf16.count
        let isForward = anchorIndex <= focusIndex
        let leading = isForward ? anchor : focus
        let trailing = isForward ? focus : anchor
        if blockID == leading.blockID {
            let anchorRange = try? BlockSelectionBridge.nsRange(
                textRange: .init(start: leading, end: .init(blockID: blockID, graphemeOffset: block.kind == .divider ? 0 : Self.text(block).count)),
                document: document
            )
            return anchorRange
        }
        if blockID == trailing.blockID {
            let focusRange = try? BlockSelectionBridge.nsRange(
                textRange: .init(start: .init(blockID: blockID, graphemeOffset: 0), end: trailing), document: document
            )
            return focusRange
        }
        return .init(location: 0, length: count)
    }

    private static func text(_ block: DocumentBlock) -> String {
        block.inlineContent.spans.map(\.text).joined()
    }
}
