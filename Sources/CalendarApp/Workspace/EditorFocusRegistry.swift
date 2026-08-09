import Combine
import Foundation

enum EditorUndoRouteResult: Equatable, Sendable { case noFocusedOwner, focusedPerformed, focusedUnavailable }

@MainActor
final class EditorFocusRegistry: ObservableObject {
    private weak var focusedManager: UndoManager?
    private var focusedOwnerID: UUID?
    private var notificationTokens: [NSObjectProtocol] = []
    private let availabilitySubject = CurrentValueSubject<(Bool, Bool), Never>((false, false))
    private var lastAvailability: (Bool, Bool) = (false, false)

    var canUndo: Bool { refreshAvailability(); return lastAvailability.0 }
    var canRedo: Bool { refreshAvailability(); return lastAvailability.1 }
    var availabilityPublisher: AnyPublisher<(Bool, Bool), Never> { availabilitySubject.eraseToAnyPublisher() }

    func register(_ manager: UndoManager, ownerID: UUID) {
        unbindNotifications()
        focusedManager = manager
        focusedOwnerID = ownerID
        bindNotifications(to: manager)
        refreshAvailability()
    }
    func clear(ownerID: UUID) {
        guard focusedOwnerID == ownerID else { return }
        focusedOwnerID = nil
        focusedManager = nil
        unbindNotifications()
        refreshAvailability()
    }
    func routeUndo() -> EditorUndoRouteResult { route(undo: true) }
    func routeRedo() -> EditorUndoRouteResult { route(undo: false) }

    private func refreshAvailability() {
        guard focusedOwnerID != nil else {
            publishAvailability((false, false))
            return
        }
        guard let manager = focusedManager else {
            focusedOwnerID = nil
            unbindNotifications()
            publishAvailability((false, false))
            return
        }
        publishAvailability((manager.canUndo, manager.canRedo))
    }

    private func route(undo: Bool) -> EditorUndoRouteResult {
        guard focusedOwnerID != nil else { return .noFocusedOwner }
        guard let manager = focusedManager else {
            focusedOwnerID = nil
            unbindNotifications()
            refreshAvailability()
            return .noFocusedOwner
        }
        if undo ? manager.canUndo : manager.canRedo {
            if undo { manager.undo() } else { manager.redo() }
            refreshAvailability()
            return .focusedPerformed
        }
        refreshAvailability()
        return .focusedUnavailable
    }

    private func bindNotifications(to manager: UndoManager) {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange, .NSUndoManagerCheckpoint]
        for name in names {
            notificationTokens.append(center.addObserver(forName: name, object: manager, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshAvailability() }
            })
        }
    }

    private func unbindNotifications() {
        let center = NotificationCenter.default
        notificationTokens.forEach(center.removeObserver)
        notificationTokens.removeAll()
    }

    private func publishAvailability(_ availability: (Bool, Bool)) {
        guard availability != lastAvailability else { return }
        lastAvailability = availability
        availabilitySubject.send(availability)
    }
}
