import Foundation
import Testing
@testable import WorkspaceDomain

@Suite("WorkspaceExternalSourceAdoptionPlannerTests")
struct WorkspaceExternalSourceAdoptionPlannerTests {
    @Test func lowerRevisionIdenticalExternalContentKeepsCurrentAndLedgerHighWatermarks() throws {
        var current = try Task4Fixture.workspace()
        current.revision = 10
        current.notes[Task4Fixture.noteID]?.revision = 9
        var external = current
        external.revision = 7
        external.notes[Task4Fixture.noteID]?.revision = 4

        let adoption = try WorkspaceExternalSourceAdoptionPlanner.plan(
            current: current,
            external: external,
            sessionNoteHighWatermarks: [Task4Fixture.noteID: 8]
        )

        #expect(adoption.candidate.revision == 10)
        #expect(adoption.candidate.notes[Task4Fixture.noteID]?.revision == 9)
        #expect(adoption.noteRevisionHighWatermarks[Task4Fixture.noteID] == 9)
        #expect(adoption.requiresNormalization)
    }

    @Test func changedExternalBusinessContentAllocatesNewWorkspaceAndNoteRevisions() throws {
        let current = try Task4Fixture.workspace()
        var external = current
        external.revision = 8
        external.notes[Task4Fixture.noteID]?.revision = 6
        external.notes[Task4Fixture.noteID]?.title = "来自外部的修改"

        let adoption = try WorkspaceExternalSourceAdoptionPlanner.plan(
            current: current,
            external: external,
            sessionNoteHighWatermarks: [:]
        )

        #expect(adoption.candidate.revision == 9)
        #expect(adoption.candidate.notes[Task4Fixture.noteID]?.revision == 7)
        #expect(adoption.noteRevisionHighWatermarks[Task4Fixture.noteID] == 7)
        #expect(adoption.requiresNormalization)
    }

    @Test func externallyDeletedNoteRemainsInTheLedgerSoSameIDRecreationCannotRegress() throws {
        let current = try Task4Fixture.workspace()
        var external = current
        external.notes.removeValue(forKey: Task4Fixture.noteID)

        let adoption = try WorkspaceExternalSourceAdoptionPlanner.plan(
            current: current,
            external: external,
            sessionNoteHighWatermarks: [Task4Fixture.noteID: 11]
        )

        #expect(adoption.candidate.notes[Task4Fixture.noteID] == nil)
        #expect(adoption.noteRevisionHighWatermarks[Task4Fixture.noteID] == 11)
    }

    @Test func revisionOverflowIsTypedAndDoesNotFabricateAnAdoptionCandidate() throws {
        var current = try Task4Fixture.workspace()
        current.revision = .max
        var external = current
        external.notes[Task4Fixture.noteID]?.title = "不同"

        #expect(throws: WorkspaceExternalSourceAdoptionError.revisionOverflow) {
            try WorkspaceExternalSourceAdoptionPlanner.plan(
                current: current,
                external: external,
                sessionNoteHighWatermarks: [:]
            )
        }
    }

    @Test func changedNoteRevisionOverflowIsTypedEvenWhenWorkspaceRevisionCanAdvance() throws {
        var current = try Task4Fixture.workspace()
        current.revision = 10
        current.notes[Task4Fixture.noteID]?.revision = .max
        var external = current
        external.notes[Task4Fixture.noteID]?.title = "changed at note ceiling"

        #expect(throws: WorkspaceExternalSourceAdoptionError.revisionOverflow) {
            try WorkspaceExternalSourceAdoptionPlanner.plan(
                current: current,
                external: external,
                sessionNoteHighWatermarks: [:]
            )
        }
    }

    @Test func sessionNoteHighWatermarkOverflowIsTypedIndependentlyOfSourceRevision() throws {
        var current = try Task4Fixture.workspace()
        current.revision = 10
        current.notes[Task4Fixture.noteID]?.revision = 2
        var external = current
        external.notes[Task4Fixture.noteID]?.revision = 3
        external.notes[Task4Fixture.noteID]?.title = "changed after session ceiling"

        #expect(throws: WorkspaceExternalSourceAdoptionError.revisionOverflow) {
            try WorkspaceExternalSourceAdoptionPlanner.plan(
                current: current,
                external: external,
                sessionNoteHighWatermarks: [Task4Fixture.noteID: .max]
            )
        }
    }

    @Test func repairableExternalIssuesRemainVisibleAndRequireNormalization() throws {
        let current = try Task4Fixture.workspace()
        var external = current
        let missingOwner = CalendarNoteOwnerID.item(Task4Fixture.uuid(999))
        external.calendarNoteRelations.baselines[missingOwner] = .init(
            primaryNoteID: nil,
            referenceNoteIDs: [Task4Fixture.noteID]
        )

        let adoption = try WorkspaceExternalSourceAdoptionPlanner.plan(
            current: current,
            external: external,
            sessionNoteHighWatermarks: [:]
        )

        #expect(adoption.consistencyIssues.isEmpty == false)
        #expect(adoption.requiresNormalization)
    }

    @Test func disjointDraftMergeEmitsTheFinalCandidateChecksumRevisionAndEditorSession() throws {
        var current = try Task4Fixture.workspace()
        let base = try #require(current.notes[Task4Fixture.noteID])
        current.notes[Task4Fixture.noteID]?.categoryID = Task4Fixture.workCategoryID
        var submitted = base
        submitted.title = "编辑器标题"
        let submission = try Task4Fixture.submission(base: base, submitted: submitted)

        let result = try WorkspaceReducer.reduce(current, command: .updateNote(submission), now: Task4Fixture.later)
        guard case let .changed(change) = result,
              let context = change.draftContext,
              let final = change.state.notes[Task4Fixture.noteID]
        else {
            Issue.record("The disjoint merge must produce a draft persistence context")
            return
        }

        #expect(context.editSessionID == .editor(Task4Fixture.editSessionID))
        #expect(context.persistedNoteRevision == final.revision)
        let finalChecksum = try WorkspaceChecksum.noteSnapshotChecksum(final)
        #expect(context.noteSnapshotChecksum == finalChecksum)
    }
}
