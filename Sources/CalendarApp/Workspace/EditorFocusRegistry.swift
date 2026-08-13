import Combine
import Foundation

enum EditorUndoRouteResult: Equatable, Sendable { case noFocusedOwner, focusedPerformed, focusedUnavailable }
enum EditorFocusAvailability: Equatable, Sendable {
    case noFocusedOwner
    case focused(canUndo: Bool, canRedo: Bool)
}

@MainActor
final class EditorFocusRegistry: ObservableObject {
    @Published private var publicationRevision = 0
    private weak var focusedManager: UndoManager?
    private var focusedOwnerID: UUID?
    private var notificationTokens: [NSObjectProtocol] = []
    private var isRefreshingAvailability = false
    private var notificationRefreshScheduled = false
    private let availabilitySubject = CurrentValueSubject<(Bool, Bool), Never>((false, false))
    private var lastAvailability: (Bool, Bool) = (false, false)

    var canUndo: Bool { refreshAvailability(); return lastAvailability.0 }
    var canRedo: Bool { refreshAvailability(); return lastAvailability.1 }
    var availability: EditorFocusAvailability {
        refreshAvailability()
        guard focusedOwnerID != nil else { return .noFocusedOwner }
        return .focused(canUndo: lastAvailability.0, canRedo: lastAvailability.1)
    }
    var availabilityPublisher: AnyPublisher<(Bool, Bool), Never> { availabilitySubject.eraseToAnyPublisher() }

    func register(_ manager: UndoManager, ownerID: UUID) {
        unbindNotifications()
        focusedManager = manager
        focusedOwnerID = ownerID
        bindNotifications(to: manager)
        refreshAvailability(forceNotification: true)
    }
    func clear(ownerID: UUID) {
        guard focusedOwnerID == ownerID else { return }
        focusedOwnerID = nil
        focusedManager = nil
        unbindNotifications()
        refreshAvailability(forceNotification: true)
    }
    func routeUndo() -> EditorUndoRouteResult { route(undo: true) }
    func routeRedo() -> EditorUndoRouteResult { route(undo: false) }

    private func refreshAvailability(forceNotification: Bool = false) {
        // `canRedo` posts a checkpoint synchronously. Keep that notification
        // from scheduling another refresh of the same query forever.
        guard !isRefreshingAvailability else { return }
        isRefreshingAvailability = true
        defer { isRefreshingAvailability = false }

        guard focusedOwnerID != nil else {
            publishAvailability((false, false), forceNotification: forceNotification)
            return
        }
        guard let manager = focusedManager else {
            focusedOwnerID = nil
            unbindNotifications()
            publishAvailability((false, false), forceNotification: true)
            return
        }
        publishAvailability((manager.canUndo, manager.canRedo), forceNotification: forceNotification)
    }

    private func route(undo: Bool) -> EditorUndoRouteResult {
        guard focusedOwnerID != nil else { return .noFocusedOwner }
        guard let manager = focusedManager else {
            focusedOwnerID = nil
            unbindNotifications()
            refreshAvailability(forceNotification: true)
            return .noFocusedOwner
        }
        if undo ? manager.canUndo : manager.canRedo {
            if undo { manager.undo() } else { manager.redo() }
            refreshAvailability(forceNotification: true)
            return .focusedPerformed
        }
        refreshAvailability(forceNotification: true)
        return .focusedUnavailable
    }

    private func bindNotifications(to manager: UndoManager) {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange, .NSUndoManagerCheckpoint]
        for name in names {
            notificationTokens.append(center.addObserver(forName: name, object: manager, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleNotificationRefresh()
                }
            })
        }
    }

    private func scheduleNotificationRefresh() {
        guard !isRefreshingAvailability, !notificationRefreshScheduled else { return }
        notificationRefreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.notificationRefreshScheduled = false
            self.refreshAvailability()
        }
    }

    private func unbindNotifications() {
        let center = NotificationCenter.default
        notificationTokens.forEach(center.removeObserver)
        notificationTokens.removeAll()
    }

    private func publishAvailability(_ availability: (Bool, Bool), forceNotification: Bool = false) {
        let changed = availability != lastAvailability
        guard changed || forceNotification else { return }
        lastAvailability = availability
        publicationRevision &+= 1
        if changed || forceNotification {
            availabilitySubject.send(availability)
        }
    }
}
