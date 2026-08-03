import Testing
@testable import CalendarApp

@Suite("RecurringDropPresentationControllerTests")
@MainActor
struct RecurringDropPresentationControllerTests {
    @Test func systemDismissalSettlesToCancellationUnlessScopeSelectionWinsTheRace() {
        var systemDismissal = RecurringDropPresentationController()
        systemDismissal.pendingDropDidChange(hasPendingDrop: true)

        #expect(systemDismissal.state == .confirming)
        #expect(systemDismissal.isConfirmationPresented)
        #expect(!systemDismissal.isErrorPresented)
        let dismissalRequested = systemDismissal.requestConfirmationDismissal()
        #expect(dismissalRequested)
        #expect(systemDismissal.state == .dismissingConfirmation)
        #expect(!systemDismissal.isConfirmationPresented)
        #expect(!systemDismissal.isErrorPresented)
        let dismissalSettled = systemDismissal.settleConfirmationDismissal()
        #expect(dismissalSettled)
        #expect(systemDismissal.state == .hidden)

        var scopeSelection = RecurringDropPresentationController()
        scopeSelection.pendingDropDidChange(hasPendingDrop: true)
        let selectionDismissalRequested = scopeSelection.requestConfirmationDismissal()
        #expect(selectionDismissalRequested)
        let scopeSelectionStarted = scopeSelection.beginScopeSelection()
        #expect(scopeSelectionStarted)
        #expect(scopeSelection.state == .resolving)
        let selectionDismissalSettled = scopeSelection.settleConfirmationDismissal()
        #expect(!selectionDismissalSettled)
        #expect(!scopeSelection.isConfirmationPresented)
        #expect(!scopeSelection.isErrorPresented)

        var explicitCancellation = RecurringDropPresentationController()
        explicitCancellation.pendingDropDidChange(hasPendingDrop: true)
        let explicitlyCancelled = explicitCancellation.cancelConfirmation()
        #expect(explicitlyCancelled)
        #expect(explicitCancellation.state == .hidden)
    }

    @Test func failureShowsOnlyErrorThenAcknowledgementReopensConfirmationWhenPendingRemains() {
        var controller = RecurringDropPresentationController()
        controller.pendingDropDidChange(hasPendingDrop: true)
        let scopeSelectionStarted = controller.beginScopeSelection()
        #expect(scopeSelectionStarted)

        controller.resolutionFailed()

        #expect(controller.state == .showingError)
        #expect(!controller.isConfirmationPresented)
        #expect(controller.isErrorPresented)
        let errorAcknowledged = controller.acknowledgeError(hasPendingDrop: true)
        #expect(errorAcknowledged)
        #expect(controller.state == .confirming)
        #expect(controller.isConfirmationPresented)
        #expect(!controller.isErrorPresented)

        let retryStarted = controller.beginScopeSelection()
        #expect(retryStarted)
        controller.resolutionSucceeded()
        #expect(controller.state == .hidden)
        #expect(!controller.isConfirmationPresented)
        #expect(!controller.isErrorPresented)
    }

    @Test func scopeSelectionClosesConfirmationSynchronouslyAndCaptureFailureRecovers() {
        var withPending = RecurringDropPresentationController()
        withPending.pendingDropDidChange(hasPendingDrop: true)

        let withPendingStarted = withPending.beginScopeSelection()
        #expect(withPendingStarted)
        #expect(withPending.state == .resolving)
        #expect(!withPending.isConfirmationPresented)
        withPending.scopeSelectionCaptureFailed(hasPendingDrop: true)
        #expect(withPending.state == .confirming)

        var withoutPending = RecurringDropPresentationController()
        withoutPending.pendingDropDidChange(hasPendingDrop: true)
        let withoutPendingStarted = withoutPending.beginScopeSelection()
        #expect(withoutPendingStarted)
        withoutPending.scopeSelectionCaptureFailed(hasPendingDrop: false)
        #expect(withoutPending.state == .hidden)
    }
}
