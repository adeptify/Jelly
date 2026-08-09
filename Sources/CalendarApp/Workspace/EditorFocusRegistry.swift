import Foundation

enum EditorUndoRouteResult: Equatable, Sendable { case noFocusedOwner, focusedPerformed, focusedUnavailable }

@MainActor
final class EditorFocusRegistry: ObservableObject {
    private weak var focusedManager: UndoManager?
    private var focusedOwnerID: UUID?

    var canUndo: Bool { availability(undo: true) }
    var canRedo: Bool { availability(undo: false) }

    func register(_ manager: UndoManager, ownerID: UUID) { focusedManager = manager; focusedOwnerID = ownerID }
    func clear(ownerID: UUID) {
        guard focusedOwnerID == ownerID else { return }
        focusedOwnerID = nil
        focusedManager = nil
    }
    func routeUndo() -> EditorUndoRouteResult { route(undo: true) }
    func routeRedo() -> EditorUndoRouteResult { route(undo: false) }

    private func availability(undo: Bool) -> Bool {
        guard focusedOwnerID != nil else { return false }
        guard let manager = focusedManager else {
            focusedOwnerID = nil
            return false
        }
        return undo ? manager.canUndo : manager.canRedo
    }

    private func route(undo: Bool) -> EditorUndoRouteResult {
        guard focusedOwnerID != nil else { return .noFocusedOwner }
        guard let manager = focusedManager else { focusedOwnerID = nil; return .noFocusedOwner }
        if undo ? manager.canUndo : manager.canRedo {
            if undo { manager.undo() } else { manager.redo() }
            return .focusedPerformed
        }
        return .focusedUnavailable
    }
}
