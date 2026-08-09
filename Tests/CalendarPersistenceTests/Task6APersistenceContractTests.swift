import Foundation
import Testing
@testable import CalendarPersistence
@testable import WorkspaceDomain

@Suite("Task6APersistenceContractTests")
struct Task6APersistenceContractTests {
    @Test func draftPersistenceContextBindsNamespacedSessionAndFinalNoteRevision() throws {
        let noteID = NoteID(UUID(uuidString: "00000000-0000-0000-0000-000000006a01")!)
        let sessionID = DraftJournalSessionID.editor(
            UUID(uuidString: "00000000-0000-0000-0000-000000006a02")!
        )
        let context = PersistableDraftContext(
            noteID: noteID,
            editSessionID: sessionID,
            draftGeneration: 7,
            noteSnapshotChecksum: "final-candidate-checksum",
            persistedNoteRevision: 13
        )

        #expect(context.noteID == noteID)
        #expect(context.editSessionID == sessionID)
        #expect(context.persistedNoteRevision == 13)
        #expect(DraftJournalSessionID.legacyTask5 != sessionID)
    }

    @Test func externalAdoptionKeepsIdenticalBusinessContentAtTheHighestRevision() throws {
        let current = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 4)
        var external = current
        external.revision = 9
        let noteID = try #require(external.notes.keys.first)
        external.notes[noteID]?.revision = 8

        let adoption = try WorkspaceExternalSourceAdoptionPlanner.plan(
            current: current,
            external: external,
            sessionNoteHighWatermarks: [noteID: 7]
        )

        #expect(adoption.candidate.revision == 9)
        #expect(adoption.candidate.notes[noteID]?.revision == 8)
        #expect(adoption.noteRevisionHighWatermarks[noteID] == 8)
        #expect(adoption.requiresNormalization == false)
    }
}
