import CalendarDomain
import Foundation
import Testing
import WorkspaceDomain

@Suite("WorkspaceModelTests")
struct WorkspaceModelTests {
    @Test func workspaceRoundTripPreservesCalendarStableIDsAndLifecyclePayloads() throws {
        let calendar = CalendarState.empty(
            uncategorizedID: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            now: Date(timeIntervalSince1970: 1_786_220_000)
        )
        let noteID = NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000000102")!)
        let inspirationID = InspirationID(UUID(uuidString: "00000000-0000-0000-0000-000000000103")!)
        let blockID = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000104")!)
        let completedAt = Date(timeIntervalSince1970: 1_786_220_400)
        let note = Note(
            id: noteID,
            title: "归档笔记",
            document: BlockDocument(blocks: [
                DocumentBlock(
                    id: blockID,
                    kind: .task,
                    inlineContent: .plain("写方案"),
                    taskState: .init(completedAt: completedAt),
                    indentLevel: 0
                )
            ]),
            categoryID: calendar.uncategorizedID,
            archivedAt: Date(timeIntervalSince1970: 1_786_220_800),
            revision: 7,
            createdAt: Date(timeIntervalSince1970: 1_786_220_000),
            updatedAt: Date(timeIntervalSince1970: 1_786_221_000)
        )
        let inspiration = Inspiration(
            id: inspirationID,
            inputKind: .url,
            rawText: nil,
            rawURL: URL(string: "https://example.com/read")!,
            rawFile: nil,
            resolvedSourceKind: .article,
            resolvedMetadata: .init(
                title: "阅读材料",
                siteName: "Example",
                domain: "example.com",
                thumbnailURL: URL(string: "https://example.com/thumbnail.png"),
                fetchStatus: .succeeded
            ),
            categoryID: calendar.uncategorizedID,
            lifecycle: .archived,
            createdAt: Date(timeIntervalSince1970: 1_786_220_000),
            updatedAt: Date(timeIntervalSince1970: 1_786_221_000)
        )
        let workspace = WorkspaceState(
            revision: 11,
            calendar: calendar,
            notes: [noteID: note],
            inspirations: [inspirationID: inspiration],
            calendarNoteRelations: .empty,
            taskBlockLinks: [],
            inspirationNoteLinks: []
        )

        let data = try JSONEncoder.workspaceDeterministic.encode(workspace)
        let decoded = try JSONDecoder.workspaceDeterministic.decode(WorkspaceState.self, from: data)

        #expect(decoded == workspace)
        #expect(decoded.calendar == calendar)
        #expect(decoded.notes[noteID]?.document.blocks[0].taskState?.completedAt == completedAt)
        #expect(decoded.inspirations[inspirationID]?.inputKind == .url)
        #expect(decoded.inspirations[inspirationID]?.resolvedSourceKind == .article)
        #expect(decoded.inspirations[inspirationID]?.lifecycle == .archived)
    }

    @Test func checksumIgnoresNoteRevisionAndEncoderFormattingButIncludesProtectedContent() throws {
        let noteID = NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000000105")!)
        let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000106")!
        let block = DocumentBlock(
            id: BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000107")!),
            kind: .paragraph,
            inlineContent: .init(spans: [
                .init(text: "第一段", marks: [.italic, .bold], linkURL: nil),
                .init(text: "链接", marks: [], linkURL: URL(string: "https://example.com/a")!)
            ]),
            taskState: nil,
            indentLevel: 0
        )
        let original = Note(
            id: noteID,
            title: "标题",
            document: BlockDocument(blocks: [block]),
            categoryID: categoryID,
            archivedAt: nil,
            revision: 1,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        var revised = original
        revised.revision = 99
        revised.updatedAt = Date(timeIntervalSince1970: 1_786_222_000)
        var changed = original
        changed.title = "改后的标题"

        #expect(try WorkspaceChecksum.noteSnapshotChecksum(original) == WorkspaceChecksum.noteSnapshotChecksum(revised))
        #expect(try WorkspaceChecksum.noteSnapshotChecksum(original) != WorkspaceChecksum.noteSnapshotChecksum(changed))
        #expect(try WorkspaceChecksum.normalizedNoteSnapshotData(original) == WorkspaceChecksum.normalizedNoteSnapshotData(revised))
    }

    @Test func workspaceValidatorAcceptsLiveAndDeletedInspirationLinksWithoutCopyingSourceContent() throws {
        let calendar = CalendarState.empty(
            uncategorizedID: UUID(uuidString: "00000000-0000-0000-0000-000000000108")!,
            now: .distantPast
        )
        let noteID = NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000000109")!)
        let inspirationID = InspirationID(UUID(uuidString: "00000000-0000-0000-0000-000000000110")!)
        let note = Note.empty(
            id: noteID,
            categoryID: calendar.uncategorizedID,
            now: .distantPast
        )
        let inspiration = Inspiration.text(
            id: inspirationID,
            rawText: "保留原始输入",
            categoryID: calendar.uncategorizedID,
            now: .distantPast
        )
        let live = InspirationNoteLink(
            source: .live(inspirationID),
            noteID: noteID,
            createdAt: .distantPast
        )
        let deleted = InspirationNoteLink(
            source: .deleted(originalID: InspirationID(UUID(uuidString: "00000000-0000-0000-0000-000000000111")!), deletedAt: .distantPast),
            noteID: noteID,
            createdAt: .distantPast
        )
        let workspace = WorkspaceState(
            revision: 0,
            calendar: calendar,
            notes: [noteID: note],
            inspirations: [inspirationID: inspiration],
            calendarNoteRelations: .empty,
            taskBlockLinks: [],
            inspirationNoteLinks: [live, deleted]
        )

        try WorkspaceValidator.validate(workspace)
    }

    @Test func workspaceValidatorRejectsDanglingCalendarRelationOwner() throws {
        let workspace = try validWorkspace()
        let owner = CalendarNoteOwnerID.item(UUID(uuidString: "00000000-0000-0000-0000-000000000112")!)
        var invalid = workspace
        invalid.calendarNoteRelations.baselines[owner] = .init(
            primaryNoteID: invalid.notes.keys.first,
            referenceNoteIDs: []
        )

        #expect(throws: WorkspaceValidationError.danglingCalendarOwner(owner)) {
            try WorkspaceValidator.validate(invalid)
        }
    }

    @Test func workspaceValidatorRejectsPrimaryNoteDuplicatedAsReference() throws {
        let workspace = try validWorkspace()
        let itemID = try #require(workspace.calendar.items.keys.first)
        let noteID = try #require(workspace.notes.keys.first)
        let owner = CalendarNoteOwnerID.item(itemID)
        var invalid = workspace
        invalid.calendarNoteRelations.baselines[owner] = .init(
            primaryNoteID: noteID,
            referenceNoteIDs: [noteID]
        )

        #expect(throws: WorkspaceValidationError.primaryAlsoReference(owner, noteID)) {
            try WorkspaceValidator.validate(invalid)
        }
    }

    @Test func workspaceValidatorRejectsTaskBlockLinkWithoutMatchingPrimaryNote() throws {
        let workspace = try validWorkspace()
        let itemID = try #require(workspace.calendar.items.keys.first)
        let noteID = try #require(workspace.notes.keys.first)
        let blockID = try #require(workspace.notes[noteID]?.document.blocks.first?.id)
        var invalid = workspace
        invalid.taskBlockLinks = [.init(noteID: noteID, blockID: blockID, calendarItemID: itemID)]

        #expect(throws: WorkspaceValidationError.taskBlockMissingPrimaryNote(noteID, itemID)) {
            try WorkspaceValidator.validate(invalid)
        }
    }

    private func validWorkspace() throws -> WorkspaceState {
        let now = Date(timeIntervalSince1970: 1_786_220_000)
        let uncategorizedID = UUID(uuidString: "00000000-0000-0000-0000-000000000113")!
        let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000114")!
        let noteID = NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000000115")!)
        let blockID = BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000000116")!)
        var calendar = CalendarState.empty(uncategorizedID: uncategorizedID, now: now)
        calendar.items[itemID] = try CalendarItem(
            id: itemID,
            kind: .task,
            title: "有关系的事项",
            categoryID: uncategorizedID,
            schedule: try CalendarSchedule(
                startDate: .init(year: 2026, month: 8, day: 9)!,
                endDate: .init(year: 2026, month: 8, day: 9)!,
                startTime: nil,
                endTime: nil
            ),
            completedAt: nil,
            createdAt: now,
            updatedAt: now
        )
        return WorkspaceState(
            revision: 0,
            calendar: calendar,
            notes: [noteID: .init(
                id: noteID,
                title: "关联笔记",
                document: .init(blocks: [
                    .init(
                        id: blockID,
                        kind: .task,
                        inlineContent: .plain("关联待办"),
                        taskState: .init(completedAt: nil),
                        indentLevel: 0
                    )
                ]),
                categoryID: uncategorizedID,
                archivedAt: nil,
                revision: 0,
                createdAt: now,
                updatedAt: now
            )],
            inspirations: [:],
            calendarNoteRelations: .empty,
            taskBlockLinks: [],
            inspirationNoteLinks: []
        )
    }
}
