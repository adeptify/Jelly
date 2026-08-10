import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("BlockEditorBridgeTests")
struct BlockEditorBridgeTests {
    @Test func utf16AndGraphemePositionsRoundTripWithoutFlooring() throws {
        let id = bridgeBlockID(1)
        let samples = ["ASCII", "中文", "e\u{301}", "🇨🇳", "👍🏽", "👨‍👩‍👧‍👦"]

        for sample in samples {
            let document = bridgeDocument(id: id, text: sample)
            var utf16Offset = 0
            for (graphemeOffset, character) in sample.enumerated() {
                let position = try BlockSelectionBridge.graphemePosition(
                    blockID: id, utf16Offset: utf16Offset, document: document
                )
                #expect(position == .init(blockID: id, graphemeOffset: graphemeOffset))
                #expect(try BlockSelectionBridge.utf16Offset(position: position, document: document) == utf16Offset)
                utf16Offset += String(character).utf16.count
            }
            let end = BlockTextPosition(blockID: id, graphemeOffset: sample.count)
            #expect(try BlockSelectionBridge.utf16Offset(position: end, document: document) == utf16Offset)
            #expect(try BlockSelectionBridge.graphemePosition(
                blockID: id, utf16Offset: utf16Offset, document: document
            ) == end)
        }
    }

    @Test func bridgeRejectsMissingNegativeNotFoundOverflowPastEndAndMidGrapheme() throws {
        let id = bridgeBlockID(2)
        let missing = bridgeBlockID(3)
        let document = bridgeDocument(id: id, text: "e\u{301}")

        #expect(throws: BlockEditorBridgeError.missingBlock(missing)) {
            try BlockSelectionBridge.graphemePosition(blockID: missing, utf16Offset: 0, document: document)
        }
        #expect(throws: BlockEditorBridgeError.negativeUTF16Offset) {
            try BlockSelectionBridge.graphemePosition(blockID: id, utf16Offset: -1, document: document)
        }
        #expect(throws: BlockEditorBridgeError.nsNotFound) {
            try BlockSelectionBridge.graphemePosition(blockID: id, utf16Offset: NSNotFound, document: document)
        }
        #expect(throws: BlockEditorBridgeError.utf16OffsetOutOfRange) {
            try BlockSelectionBridge.graphemePosition(blockID: id, utf16Offset: 3, document: document)
        }
        #expect(throws: BlockEditorBridgeError.midGraphemeBoundary) {
            try BlockSelectionBridge.graphemePosition(blockID: id, utf16Offset: 1, document: document)
        }
        #expect(throws: BlockEditorBridgeError.integerOverflow) {
            try BlockSelectionBridge.graphemeRange(
                blockID: id, nsRange: .init(location: Int.max - 1, length: 2), document: document
            )
        }
    }

    @Test func sameBlockRangeRoundTripsAndSyntheticCrossBlockRangeIsRejected() throws {
        let first = bridgeBlockID(4)
        let second = bridgeBlockID(5)
        let document = BlockDocument(blocks: [
            bridgeBlock(id: first, text: "甲👍🏽"),
            bridgeBlock(id: second, text: "乙")
        ])
        let textRange = try BlockSelectionBridge.graphemeRange(
            blockID: first, nsRange: .init(location: 1, length: 4), document: document
        )
        #expect(textRange == .init(
            start: .init(blockID: first, graphemeOffset: 1),
            end: .init(blockID: first, graphemeOffset: 2)
        ))
        #expect(try BlockSelectionBridge.nsRange(textRange: textRange, document: document) == .init(location: 1, length: 4))

        let crossBlock = BlockTextRange(
            start: .init(blockID: first, graphemeOffset: 0),
            end: .init(blockID: second, graphemeOffset: 0)
        )
        #expect(throws: BlockEditorBridgeError.crossBlockRange) {
            try BlockSelectionBridge.nsRange(textRange: crossBlock, document: document)
        }
    }

    @Test func dividerAcceptsOnlyOffsetZero() throws {
        let id = bridgeBlockID(6)
        let document = BlockDocument(blocks: [.init(
            id: id, kind: .divider, inlineContent: .plain(""), taskState: nil, indentLevel: 0
        )])
        #expect(try BlockSelectionBridge.graphemePosition(blockID: id, utf16Offset: 0, document: document)
            == .init(blockID: id, graphemeOffset: 0))
        #expect(throws: BlockEditorBridgeError.utf16OffsetOutOfRange) {
            try BlockSelectionBridge.graphemePosition(blockID: id, utf16Offset: 1, document: document)
        }
    }

    @Test @MainActor func forwardAndReverseCrossHostProjectionUseDocumentEndpointsNotAnchorNames() {
        let first = bridgeBlockID(7)
        let second = bridgeBlockID(8)
        let document = BlockDocument(blocks: [
            bridgeBlock(id: first, text: "甲👍🏽"),
            bridgeBlock(id: second, text: "乙文")
        ])
        let forward = BlockEditorSelection.text(
            anchor: .init(blockID: first, graphemeOffset: 1),
            focus: .init(blockID: second, graphemeOffset: 1),
            preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil)
        )
        let reverse = BlockEditorSelection.text(
            anchor: .init(blockID: second, graphemeOffset: 1),
            focus: .init(blockID: first, graphemeOffset: 1),
            preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil)
        )

        #expect(BlockSelectionController(selection: forward).projectedRange(for: first, document: document) == .init(location: 1, length: 4))
        #expect(BlockSelectionController(selection: forward).projectedRange(for: second, document: document) == .init(location: 0, length: 1))
        #expect(BlockSelectionController(selection: reverse).projectedRange(for: first, document: document) == .init(location: 1, length: 4))
        #expect(BlockSelectionController(selection: reverse).projectedRange(for: second, document: document) == .init(location: 0, length: 1))
    }

    @Test @MainActor func everyGraphemeRangeRoundTripsAndRejectsEitherComplexEndpointMidpoint() throws {
        let samples = ["A", "中", "e\u{301}", "🇨🇳", "👍🏽", "👨‍👩‍👧‍👦"]
        for (index, sample) in samples.enumerated() {
            let id = bridgeBlockID(20 + index)
            let text = sample + sample
            let document = bridgeDocument(id: id, text: text)
            let fullRange = NSRange(location: 0, length: text.utf16.count)
            let bridged = try BlockSelectionBridge.graphemeRange(blockID: id, nsRange: fullRange, document: document)
            #expect(bridged == .init(
                start: .init(blockID: id, graphemeOffset: 0),
                end: .init(blockID: id, graphemeOffset: 2)
            ))
            #expect(try BlockSelectionBridge.nsRange(textRange: bridged, document: document) == fullRange)

            let firstWidth = sample.utf16.count
            if firstWidth > 1 {
                #expect(throws: BlockEditorBridgeError.midGraphemeBoundary) {
                    try BlockSelectionBridge.graphemeRange(
                        blockID: id,
                        nsRange: .init(location: 1, length: text.utf16.count - 1),
                        document: document
                    )
                }
                #expect(throws: BlockEditorBridgeError.midGraphemeBoundary) {
                    try BlockSelectionBridge.graphemeRange(
                        blockID: id,
                        nsRange: .init(location: 0, length: text.utf16.count - 1),
                        document: document
                    )
                }
            }

            let forward = BlockEditorSelection.text(
                anchor: .init(blockID: id, graphemeOffset: 0),
                focus: .init(blockID: id, graphemeOffset: 2),
                preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil)
            )
            let reverse = BlockEditorSelection.text(
                anchor: .init(blockID: id, graphemeOffset: 2),
                focus: .init(blockID: id, graphemeOffset: 0),
                preferredColumn: nil, typingAttributes: .init(marks: [], linkURL: nil)
            )
            let controller = BlockSelectionController(selection: reverse)
            #expect(controller.selection == reverse)
            #expect(controller.projectedRange(for: id, document: document) == fullRange)
            #expect(BlockSelectionController(selection: forward).projectedRange(for: id, document: document) == fullRange)
        }
    }
}

private func bridgeBlockID(_ value: Int) -> BlockID {
    BlockID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!)
}

private func bridgeBlock(id: BlockID, text: String) -> DocumentBlock {
    .init(id: id, kind: .paragraph, inlineContent: .plain(text), taskState: nil, indentLevel: 0)
}

private func bridgeDocument(id: BlockID, text: String) -> BlockDocument {
    .init(blocks: [bridgeBlock(id: id, text: text)])
}
