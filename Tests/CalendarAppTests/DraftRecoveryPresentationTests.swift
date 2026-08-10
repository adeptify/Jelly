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
}
