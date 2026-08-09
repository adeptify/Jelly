import Foundation
import Testing
import WorkspaceDomain

@Suite("NoteDraftSequenceRebasePlannerTests")
struct NoteDraftSequenceRebasePlannerTests {
    @Test func laterGenerationReplaysItsDeltaOnThePreviousAcceptedValue() throws {
        let id = NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000006001")!)
        let category = UUID(uuidString: "00000000-0000-0000-0000-000000006002")!
        let base = Note.empty(id: id, categoryID: category, now: .distantPast)
        var first = base
        first.title = "first"
        var second = base
        second.title = "second"
        var latest = base
        latest.title = "first"

        let result = try NoteDraftSequenceRebasePlanner.plan(
            previousAccepted: .init(base: base, accepted: first, modifiedFields: [.title]),
            next: submission(base: base, snapshot: second, generation: 2),
            latest: latest
        )

        #expect(result.rebasedSnapshot.title == "second")
        #expect(result.rebasedSnapshot.document == base.document)
    }

    @Test func thirdPartySameFieldChangeIsAConflict() throws {
        let id = NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000006003")!)
        let category = UUID(uuidString: "00000000-0000-0000-0000-000000006004")!
        let base = Note.empty(id: id, categoryID: category, now: .distantPast)
        var accepted = base
        accepted.title = "first"
        var next = base
        next.title = "second"
        var latest = base
        latest.title = "outside"

        #expect(throws: NoteDraftSequenceRebaseError.conflict([.title])) {
            try NoteDraftSequenceRebasePlanner.plan(
                previousAccepted: .init(base: base, accepted: accepted, modifiedFields: [.title]),
                next: submission(base: base, snapshot: next, generation: 2),
                latest: latest
            )
        }
    }

    @Test func disjointLaterGenerationKeepsTheEarlierAcceptedFieldAndReplaysOnlyItsOwnDelta() throws {
        let id = NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000006006")!)
        let firstCategory = UUID(uuidString: "00000000-0000-0000-0000-000000006007")!
        let secondCategory = UUID(uuidString: "00000000-0000-0000-0000-000000006008")!
        let base = Note.empty(id: id, categoryID: firstCategory, now: .distantPast)
        var accepted = base
        accepted.title = "first title"
        var next = base
        next.categoryID = secondCategory
        var latest = base
        latest.title = "first title"

        let result = try NoteDraftSequenceRebasePlanner.plan(
            previousAccepted: .init(base: base, accepted: accepted, modifiedFields: [.title]),
            next: NoteDraftSubmission(
                noteID: id,
                editSessionID: UUID(uuidString: "00000000-0000-0000-0000-000000006009")!,
                baseNoteRevision: base.revision,
                baseNoteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(base),
                baseSnapshot: base,
                baseLinkedTaskBlockLinks: [],
                draftGeneration: 2,
                snapshot: next,
                noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(next),
                modifiedFields: [.categoryID],
                linkedBlockDeletionDispositions: [:]
            ),
            latest: latest
        )

        #expect(result.rebasedBase.title == "first title")
        #expect(result.rebasedSnapshot.title == "first title")
        #expect(result.rebasedSnapshot.categoryID == secondCategory)
    }

    private func submission(base: Note, snapshot: Note, generation: UInt64) -> NoteDraftSubmission {
        NoteDraftSubmission(
            noteID: base.id,
            editSessionID: UUID(uuidString: "00000000-0000-0000-0000-000000006005")!,
            baseNoteRevision: base.revision,
            baseNoteSnapshotChecksum: (try? WorkspaceChecksum.noteSnapshotChecksum(base)) ?? "",
            baseSnapshot: base,
            baseLinkedTaskBlockLinks: [],
            draftGeneration: generation,
            snapshot: snapshot,
            noteSnapshotChecksum: (try? WorkspaceChecksum.noteSnapshotChecksum(snapshot)) ?? "",
            modifiedFields: [.title],
            linkedBlockDeletionDispositions: [:]
        )
    }
}
