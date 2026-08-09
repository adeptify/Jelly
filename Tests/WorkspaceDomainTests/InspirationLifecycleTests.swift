import CalendarDomain
import Foundation
import Testing
import WorkspaceDomain

@Suite("InspirationLifecycleTests")
struct InspirationLifecycleTests {
    @Test func createArchiveAndRestoreInspirationIncrementExactlyOnceEach() throws {
        var workspace = try Task4Fixture.workspace()
        let created = Task4Fixture.inspiration(
            id: Task4Fixture.otherInspirationID,
            rawText: "第二条灵感"
        )
        let create = try WorkspaceReducer.reduce(
            workspace,
            command: .createInspiration(.init(inspiration: created)),
            now: Task4Fixture.later
        )
        workspace = try #require(create.change).state
        #expect(workspace.revision == 6)
        #expect(workspace.inspirations[created.id] == created)

        let archive = try WorkspaceReducer.reduce(
            workspace,
            command: .archiveInspiration(created.id, at: Task4Fixture.archiveAt),
            now: Task4Fixture.archiveAt
        )
        workspace = try #require(archive.change).state
        #expect(workspace.revision == 7)
        #expect(workspace.inspirations[created.id]?.lifecycle == .archived)

        let restore = try WorkspaceReducer.reduce(
            workspace,
            command: .restoreInspiration(created.id, at: Task4Fixture.restoreAt),
            now: Task4Fixture.restoreAt
        )
        workspace = try #require(restore.change).state
        #expect(workspace.revision == 8)
        #expect(workspace.inspirations[created.id]?.lifecycle == .active)
    }

    @Test func sourceChecksumUsesExactRawInputAndExcludesMetadata() throws {
        let text = Task4Fixture.inspiration(rawText: " A\nB ")
        var textWithMetadata = text
        textWithMetadata.resolvedMetadata = .init(
            title: "元数据", siteName: nil, domain: nil, thumbnailURL: nil, fetchStatus: .succeeded
        )
        #expect(WorkspaceChecksum.inspirationSourceChecksum(text) == WorkspaceChecksum.inspirationSourceChecksum(textWithMetadata))
        var changedText = text
        changedText.rawText = "A\nB"
        #expect(WorkspaceChecksum.inspirationSourceChecksum(text) != WorkspaceChecksum.inspirationSourceChecksum(changedText))

        let url = Inspiration(
            id: Task4Fixture.inspirationID,
            inputKind: .url,
            rawText: nil,
            rawURL: URL(string: "https://example.com/A%20B?q=1")!,
            rawFile: nil,
            resolvedSourceKind: .unknown,
            resolvedMetadata: nil,
            categoryID: Task4Fixture.uncategorizedID,
            lifecycle: .active,
            createdAt: Task4Fixture.now,
            updatedAt: Task4Fixture.now
        )
        var changedURL = url
        changedURL.rawURL = URL(string: "https://example.com/a%20b?q=1")!
        #expect(WorkspaceChecksum.inspirationSourceChecksum(url) != WorkspaceChecksum.inspirationSourceChecksum(changedURL))

        let file = Inspiration(
            id: Task4Fixture.inspirationID,
            inputKind: .file,
            rawText: nil,
            rawURL: nil,
            rawFile: .init(bookmarkData: Data([0, 1, 2, 255]), displayName: "资料.pdf"),
            resolvedSourceKind: .document,
            resolvedMetadata: nil,
            categoryID: Task4Fixture.uncategorizedID,
            lifecycle: .active,
            createdAt: Task4Fixture.now,
            updatedAt: Task4Fixture.now
        )
        var renamed = file
        renamed.rawFile = .init(bookmarkData: Data([0, 1, 2, 255]), displayName: "资料 2.pdf")
        #expect(WorkspaceChecksum.inspirationSourceChecksum(file) != WorkspaceChecksum.inspirationSourceChecksum(renamed))
    }

    @Test func metadataUpdateRequiresExactSourceExpectationAndStaleIsTypedNoChange() throws {
        let workspace = try Task4Fixture.workspace()
        let inspiration = try #require(workspace.inspirations[Task4Fixture.inspirationID])
        let metadata = SourceMetadata(
            title: "抓取标题",
            siteName: "站点",
            domain: "example.com",
            thumbnailURL: nil,
            fetchStatus: .succeeded
        )
        let stale = try WorkspaceReducer.reduce(
            workspace,
            command: .updateInspirationMetadata(
                inspiration.id,
                expectedSource: .init(sourceChecksum: "stale"),
                metadata: metadata,
                resolvedKind: .article
            ),
            now: Task4Fixture.later
        )
        #expect(stale == .noChange(.staleMetadata))

        let result = try WorkspaceReducer.reduce(
            workspace,
            command: .updateInspirationMetadata(
                inspiration.id,
                expectedSource: .init(sourceChecksum: WorkspaceChecksum.inspirationSourceChecksum(inspiration)),
                metadata: metadata,
                resolvedKind: .article
            ),
            now: Task4Fixture.later
        )
        let state = try #require(result.change).state
        #expect(state.revision == 6)
        #expect(state.inspirations[inspiration.id]?.resolvedMetadata == metadata)
        #expect(state.inspirations[inspiration.id]?.resolvedSourceKind == .article)
        #expect(state.inspirations[inspiration.id]?.rawText == inspiration.rawText)
    }

    @Test func firstConversionConsumesCompleteProposedNoteAndRepeatedConversionReturnsExistingID() throws {
        let workspace = try Task4Fixture.workspace()
        let proposed = Task4Fixture.note(
            id: Task4Fixture.newNoteID,
            title: "由灵感生成",
            revision: 0,
            categoryID: Task4Fixture.workCategoryID,
            updatedAt: Task4Fixture.later
        )
        let first = try WorkspaceReducer.reduce(
            workspace,
            command: .convertInspirationToNote(.init(
                inspirationID: Task4Fixture.inspirationID,
                proposedNote: proposed
            )),
            now: Task4Fixture.later
        )
        let state = try #require(first.change).state
        #expect(state.revision == 6)
        #expect(state.notes[proposed.id]?.title == proposed.title)
        #expect(state.notes[proposed.id]?.categoryID == Task4Fixture.workCategoryID)
        #expect(state.notes[proposed.id]?.document == proposed.document)
        #expect(state.notes[proposed.id]?.revision == 1)
        #expect(state.inspirationNoteLinks == [.init(
            source: .live(Task4Fixture.inspirationID),
            noteID: proposed.id,
            createdAt: Task4Fixture.later
        )])

        let unusedProposal = Task4Fixture.note(
            id: Task4Fixture.otherNoteID,
            title: "不应使用",
            revision: 0
        )
        let repeated = try WorkspaceReducer.reduce(
            state,
            command: .convertInspirationToNote(.init(
                inspirationID: Task4Fixture.inspirationID,
                proposedNote: unusedProposal
            )),
            now: Task4Fixture.latest
        )
        #expect(repeated == .noChange(.inspirationAlreadyConverted(proposed.id)))
        #expect(state.notes[unusedProposal.id]?.title != "不应使用")
    }

    @Test func repeatedConversionSelectsCanonicalNoteIDAcrossMultipleLiveLinks() throws {
        var workspace = try Task4Fixture.workspace()
        let linkedNoteIDs = (940...947).map { NoteID(Task4Fixture.uuid($0)) }
        for (index, noteID) in linkedNoteIDs.enumerated() {
            workspace.notes[noteID] = Task4Fixture.note(
                id: noteID,
                title: "派生笔记 \(index)",
                revision: 1
            )
            workspace.inspirationNoteLinks.insert(.init(
                source: .live(Task4Fixture.inspirationID),
                noteID: noteID,
                createdAt: Task4Fixture.now
            ))
        }
        try WorkspaceValidator.validate(workspace)

        let result = try WorkspaceReducer.reduce(
            workspace,
            command: .convertInspirationToNote(.init(
                inspirationID: Task4Fixture.inspirationID,
                proposedNote: Task4Fixture.note(
                    id: Task4Fixture.newNoteID,
                    title: "不应创建",
                    revision: 0
                )
            )),
            now: Task4Fixture.later
        )

        #expect(result == .noChange(.inspirationAlreadyConverted(try #require(linkedNoteIDs.first))))
        #expect(workspace.notes[Task4Fixture.newNoteID] == nil)
        #expect(workspace.inspirationNoteLinks.count == linkedNoteIDs.count)
    }

    @Test func invalidProposedNoteFailsWithoutLinkOrPartialCreation() throws {
        let workspace = try Task4Fixture.workspace()
        var invalid = Task4Fixture.note(id: Task4Fixture.newNoteID, title: "非法", revision: 0)
        invalid.categoryID = Task4Fixture.missingCategoryID
        #expect(throws: WorkspaceReducerError.invalidNote) {
            try WorkspaceReducer.reduce(
                workspace,
                command: .convertInspirationToNote(.init(
                    inspirationID: Task4Fixture.inspirationID,
                    proposedNote: invalid
                )),
                now: Task4Fixture.later
            )
        }
        #expect(workspace.notes[invalid.id] == nil)
        #expect(workspace.inspirationNoteLinks.isEmpty)
        #expect(workspace.revision == 5)
    }

    @Test func permanentDeleteTombstonesEveryLiveLinkAndPreservesDerivedNotes() throws {
        var workspace = try Task4Fixture.workspace()
        workspace.inspirationNoteLinks = [
            .init(source: .live(Task4Fixture.inspirationID), noteID: Task4Fixture.noteID, createdAt: Task4Fixture.now),
            .init(source: .live(Task4Fixture.inspirationID), noteID: Task4Fixture.otherNoteID, createdAt: Task4Fixture.later)
        ]
        let subject = PermanentDeleteSubject.inspiration(Task4Fixture.inspirationID, deletedAt: Task4Fixture.archiveAt)
        let preview = try PermanentDeletePlanner.preview(subject, in: workspace)
        #expect(preview.effects.count == 2)
        #expect(preview.effects.contains(.tombstoneInspirationNoteLink(
            noteID: Task4Fixture.noteID,
            inspirationID: Task4Fixture.inspirationID
        )))
        let result = try WorkspaceReducer.reduce(
            workspace,
            command: .permanentlyDeleteInspiration(
                Task4Fixture.inspirationID,
                at: Task4Fixture.archiveAt,
                authorization: .init(
                    subject: preview.subject,
                    sourceWorkspaceRevision: preview.sourceWorkspaceRevision,
                    impactChecksum: preview.checksum
                )
            ),
            now: Task4Fixture.archiveAt
        )
        let state = try #require(result.change).state
        #expect(state.inspirations[Task4Fixture.inspirationID] == nil)
        #expect(state.notes[Task4Fixture.noteID] != nil)
        #expect(state.notes[Task4Fixture.otherNoteID] != nil)
        #expect(state.inspirationNoteLinks.count == 2)
        #expect(state.inspirationNoteLinks.allSatisfy { link in
            link.source == .deleted(
                originalID: Task4Fixture.inspirationID,
                deletedAt: Task4Fixture.archiveAt
            )
        })
        try WorkspaceValidator.validate(state)
    }
}
