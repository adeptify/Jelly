import Foundation
import Testing
import WorkspaceDomain

@Suite("BlockDocumentValidatorTests")
struct BlockDocumentValidatorTests {
    @Test func validatorRejectsEveryUnsupportedBlockShapeWithItsStableIdentifier() throws {
        let duplicate = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000201")!)
        let orphan = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000202")!)
        let missingTaskState = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000203")!)
        let unexpectedTaskState = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000204")!)
        let divider = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000205")!)
        let link = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000206")!)

        #expect(throws: BlockDocumentValidationError.unsupportedSchema(2)) {
            try BlockDocumentValidator.validate(.init(schemaVersion: 2, blocks: []))
        }
        #expect(throws: BlockDocumentValidationError.duplicateBlockID(duplicate)) {
            try BlockDocumentValidator.validate(.init(blocks: [
                .init(id: duplicate, kind: .paragraph, inlineContent: .plain("一"), taskState: nil, indentLevel: 0),
                .init(id: duplicate, kind: .paragraph, inlineContent: .plain("二"), taskState: nil, indentLevel: 0)
            ]))
        }
        #expect(throws: BlockDocumentValidationError.invalidIndent(orphan, 4)) {
            try BlockDocumentValidator.validate(.init(blocks: [
                .init(id: orphan, kind: .bullet, inlineContent: .plain("太深"), taskState: nil, indentLevel: 4)
            ]))
        }
        #expect(throws: BlockDocumentValidationError.orphanedIndent(orphan, 1)) {
            try BlockDocumentValidator.validate(.init(blocks: [
                .init(id: orphan, kind: .bullet, inlineContent: .plain("没有父级"), taskState: nil, indentLevel: 1)
            ]))
        }
        #expect(throws: BlockDocumentValidationError.missingTaskState(missingTaskState)) {
            try BlockDocumentValidator.validate(.init(blocks: [
                .init(id: missingTaskState, kind: .task, inlineContent: .plain("缺少状态"), taskState: nil, indentLevel: 0)
            ]))
        }
        #expect(throws: BlockDocumentValidationError.unexpectedTaskState(unexpectedTaskState)) {
            try BlockDocumentValidator.validate(.init(blocks: [
                .init(id: unexpectedTaskState, kind: .paragraph, inlineContent: .plain("错误状态"), taskState: .init(completedAt: nil), indentLevel: 0)
            ]))
        }
        #expect(throws: BlockDocumentValidationError.dividerHasContent(divider)) {
            try BlockDocumentValidator.validate(.init(blocks: [
                .init(id: divider, kind: .divider, inlineContent: .plain("不应有文字"), taskState: nil, indentLevel: 0)
            ]))
        }
        #expect(throws: BlockDocumentValidationError.invalidLink(link)) {
            try BlockDocumentValidator.validate(.init(blocks: [
                .init(id: link, kind: .link, inlineContent: .plain("没有 URL"), taskState: nil, indentLevel: 0)
            ]))
        }
    }

    @Test func validatorAcceptsContinuousNestedListsAndTaskTimestamp() throws {
        let parent = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000207")!)
        let child = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000208")!)
        let task = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000209")!)
        let completedAt = Date(timeIntervalSince1970: 1_786_220_400)
        let document = BlockDocument(blocks: [
            .init(id: parent, kind: .bullet, inlineContent: .plain("父级"), taskState: nil, indentLevel: 0),
            .init(id: child, kind: .ordered, inlineContent: .plain("子级"), taskState: nil, indentLevel: 1),
            .init(id: task, kind: .task, inlineContent: .plain("待办"), taskState: .init(completedAt: completedAt), indentLevel: 2)
        ])

        try BlockDocumentValidator.validate(document)
        #expect(document.blocks[2].taskState?.completedAt == completedAt)
    }
}
