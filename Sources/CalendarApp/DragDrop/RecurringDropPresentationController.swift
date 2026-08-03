enum RecurringDropPresentationState: Equatable {
    case hidden
    case confirming
    case dismissingConfirmation
    case resolving
    case showingError
}

struct RecurringDropPresentationController {
    private(set) var state: RecurringDropPresentationState = .hidden

    var isConfirmationPresented: Bool {
        state == .confirming
    }

    var isErrorPresented: Bool {
        state == .showingError
    }

    mutating func pendingDropDidChange(hasPendingDrop: Bool) {
        guard hasPendingDrop else {
            state = .hidden
            return
        }
        guard state == .hidden else { return }
        state = .confirming
    }

    mutating func requestConfirmationDismissal() -> Bool {
        guard state == .confirming else { return false }
        state = .dismissingConfirmation
        return true
    }

    mutating func settleConfirmationDismissal() -> Bool {
        guard state == .dismissingConfirmation else { return false }
        state = .hidden
        return true
    }

    mutating func cancelConfirmation() -> Bool {
        guard state == .confirming || state == .dismissingConfirmation else { return false }
        state = .hidden
        return true
    }

    mutating func beginScopeSelection() -> Bool {
        guard state == .confirming || state == .dismissingConfirmation else { return false }
        state = .resolving
        return true
    }

    mutating func resolutionSucceeded() {
        guard state == .resolving else { return }
        state = .hidden
    }

    mutating func resolutionFailed() {
        guard state == .resolving else { return }
        state = .showingError
    }

    mutating func acknowledgeError(hasPendingDrop: Bool) -> Bool {
        guard state == .showingError else { return false }
        state = hasPendingDrop ? .confirming : .hidden
        return true
    }
}
