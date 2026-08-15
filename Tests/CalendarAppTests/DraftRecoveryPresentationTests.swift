import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("DraftRecoveryPresentationTests")
@MainActor
struct DraftRecoveryPresentationTests {
    @Test func candidatesOnlySurfaceInNeedsDraftRecoveryPhase() {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        #expect(DraftRecoveryPresentation.candidates(from: store).isEmpty)
        #expect(DraftRecoveryPresentation.statusMessage(for: store) == nil)
    }

    @Test func recoverySheetModelExposesAllThreeContractActions() {
        let calendar = makeEmptyState()
        let draft = Note.empty(
            id: NoteID(),
            categoryID: calendar.uncategorizedID,
            now: Date(timeIntervalSince1970: 10)
        )
        var draftWithTitle = draft
        draftWithTitle.title = "草稿标题"
        let candidate = DraftRecoveryCandidate(
            token: DraftRecoveryToken(
                identityAndGeneration: .init(
                    identity: .init(noteID: draft.id, editSessionID: .editor(UUID())),
                    draftGeneration: 1
                ),
                noteSnapshotChecksum: "checksum",
                journalChecksum: "journal"
            ),
            draft: draftWithTitle,
            persisted: nil,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        #expect(candidate.id == candidate.token)
        #expect(candidate.draft.title == "草稿标题")
        #expect(candidate.persisted == nil)
    }

    @Test func comparisonExplainsOnlyTheFieldsThatWouldChange() throws {
        let calendar = makeEmptyState()
        var persisted = Note.empty(
            id: NoteID(),
            categoryID: calendar.uncategorizedID,
            now: Date(timeIntervalSince1970: 10)
        )
        persisted.title = "上次保存"
        var draft = persisted
        draft.title = "退出前标题"
        draft.document = .init(blocks: [
            .init(
                id: BlockID(),
                kind: .paragraph,
                inlineContent: .plain("退出前正文"),
                taskState: nil,
                indentLevel: 0
            )
        ])
        draft.revision += 1
        draft.updatedAt = Date(timeIntervalSince1970: 20)
        let candidate = DraftRecoveryCandidate(
            token: DraftRecoveryToken(
                identityAndGeneration: .init(
                    identity: .init(noteID: draft.id, editSessionID: .editor(UUID())),
                    draftGeneration: 1
                ),
                noteSnapshotChecksum: "checksum",
                journalChecksum: "journal"
            ),
            draft: draft,
            persisted: persisted,
            updatedAt: draft.updatedAt
        )

        let comparison = DraftRecoveryPresentation.comparison(for: candidate)

        #expect(comparison.changedFields == ["标题", "正文"])
        #expect(comparison.summary == "标题、正文不同")
    }

    @Test func comparisonExplainsWhenTheExitVersionOnlyAddsContent() throws {
        let calendar = makeEmptyState()
        var persisted = Note.empty(
            id: NoteID(),
            categoryID: calendar.uncategorizedID,
            now: Date(timeIntervalSince1970: 10)
        )
        let retainedID = BlockID()
        persisted.document = .init(blocks: [
            .init(id: retainedID, kind: .paragraph, inlineContent: .plain("已经保存"), taskState: nil, indentLevel: 0)
        ])
        var draft = persisted
        draft.document.blocks.append(
            .init(id: BlockID(), kind: .bullet, inlineContent: .plain("退出前新增"), taskState: nil, indentLevel: 0)
        )
        draft.updatedAt = Date(timeIntervalSince1970: 20)
        let candidate = recoveryCandidate(persisted: persisted, draft: draft)

        let comparison = DraftRecoveryPresentation.comparison(for: candidate)

        #expect(comparison.summary == "退出前版本包含当前笔记全部内容，并新增 1 段")
        #expect(comparison.bodyRows.map(\.change) == [.unchanged, .onlyInExitVersion])
        #expect(comparison.bodyRows[1].exitVersion?.kind == .bullet)
        #expect(comparison.bodyRows[1].exitVersion?.inlineContent.spans.map(\.text).joined() == "退出前新增")
    }

    @Test func comparisonCountsModifiedAndVersionOnlyBlocksWithoutCallingEitherVersionBetter() throws {
        let calendar = makeEmptyState()
        let sharedID = BlockID()
        var persisted = Note.empty(
            id: NoteID(),
            categoryID: calendar.uncategorizedID,
            now: Date(timeIntervalSince1970: 10)
        )
        persisted.document = .init(blocks: [
            .init(id: sharedID, kind: .paragraph, inlineContent: .plain("原句"), taskState: nil, indentLevel: 0),
            .init(id: BlockID(), kind: .bullet, inlineContent: .plain("只在当前笔记"), taskState: nil, indentLevel: 0)
        ])
        var draft = persisted
        draft.document = .init(blocks: [
            .init(id: sharedID, kind: .paragraph, inlineContent: .plain("修改后的句子"), taskState: nil, indentLevel: 0),
            .init(id: BlockID(), kind: .task, inlineContent: .plain("只在退出前版本"), taskState: .init(completedAt: nil), indentLevel: 0)
        ])
        let candidate = recoveryCandidate(persisted: persisted, draft: draft)

        let comparison = DraftRecoveryPresentation.comparison(for: candidate)

        #expect(comparison.summary == "正文有 3 处不同")
        #expect(comparison.bodyRows.map(\.change) == [
            .modified,
            .onlyInCurrentNote,
            .onlyInExitVersion
        ])
        #expect(comparison.bodyRows[0].currentNote?.inlineContent.spans.map(\.text).joined() == "原句")
        #expect(comparison.bodyRows[0].exitVersion?.inlineContent.spans.map(\.text).joined() == "修改后的句子")
    }

    @Test func comparisonRecognizesContentThatDoesNotNeedAUserChoice() throws {
        let calendar = makeEmptyState()
        var persisted = Note.empty(
            id: NoteID(),
            categoryID: calendar.uncategorizedID,
            now: Date(timeIntervalSince1970: 10)
        )
        persisted.title = "同一篇笔记"
        var draft = persisted
        draft.revision += 1
        draft.updatedAt = Date(timeIntervalSince1970: 20)

        let comparison = DraftRecoveryPresentation.comparison(
            for: recoveryCandidate(persisted: persisted, draft: draft)
        )

        #expect(comparison.summary == "两个版本内容相同")
    }

    @Test func saveAsNewAllocatesDifferentBlockIDsForEveryRecoveredBlock() {
        let source = BlockDocument(blocks: [
            .init(id: BlockID(), kind: .paragraph, inlineContent: .plain("一"), taskState: nil, indentLevel: 0),
            .init(id: BlockID(), kind: .bullet, inlineContent: .plain("二"), taskState: nil, indentLevel: 0)
        ])

        let replacements = DraftRecoveryPresentation.replacementBlockIDs(for: source)

        #expect(replacements.count == source.blocks.count)
        #expect(Set(replacements).count == replacements.count)
        #expect(Set(replacements).isDisjoint(with: Set(source.blocks.map(\.id))))
    }
}

private func recoveryCandidate(persisted: Note?, draft: Note) -> DraftRecoveryCandidate {
    DraftRecoveryCandidate(
        token: DraftRecoveryToken(
            identityAndGeneration: .init(
                identity: .init(noteID: draft.id, editSessionID: .editor(UUID())),
                draftGeneration: 1
            ),
            noteSnapshotChecksum: "checksum",
            journalChecksum: "journal"
        ),
        draft: draft,
        persisted: persisted,
        updatedAt: draft.updatedAt
    )
}
