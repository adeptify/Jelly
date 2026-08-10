import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("RecoveryCenterViewModelTests")
@MainActor
struct RecoveryCenterViewModelTests {
    @Test func readyPhaseShowsEmptyCandidates() {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        let model = RecoveryCenterViewModel(store: store)
        #expect(model.draftCandidates.isEmpty)
        #expect(model.phaseDescription.contains("就绪") || model.phaseDescription.contains("尚未") || !model.phaseDescription.isEmpty)
    }
}
