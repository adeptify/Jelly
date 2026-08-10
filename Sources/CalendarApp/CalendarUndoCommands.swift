import SwiftUI

@MainActor
enum CalendarUndoCommandRouter {
    static func isDisabled(for store: WorkspaceStore) -> Bool {
        !store.canUndo || store.phase != .ready
    }

    static func undo(store: WorkspaceStore) async throws {
        _ = try await store.undo()
    }

    static func isDisabled(for store: WorkspaceStore, focusRegistry: EditorFocusRegistry) -> Bool {
        switch focusRegistry.availability {
        case .noFocusedOwner:
            isDisabled(for: store)
        case let .focused(canUndo, _):
            !canUndo
        }
    }

    static func isRedoDisabled(for store: WorkspaceStore, focusRegistry: EditorFocusRegistry) -> Bool {
        switch focusRegistry.availability {
        case .noFocusedOwner:
            !store.canRedo || store.phase != .ready
        case let .focused(_, canRedo):
            !canRedo
        }
    }

    @discardableResult
    static func undo(store: WorkspaceStore, focusRegistry: EditorFocusRegistry) async throws -> EditorUndoRouteResult {
        let route = focusRegistry.routeUndo()
        switch route {
        case .focusedPerformed, .focusedUnavailable:
            return route
        case .noFocusedOwner:
            _ = try await store.undo()
            return .noFocusedOwner
        }
    }

    @discardableResult
    static func redo(store: WorkspaceStore, focusRegistry: EditorFocusRegistry) async throws -> EditorUndoRouteResult {
        let route = focusRegistry.routeRedo()
        switch route {
        case .focusedPerformed, .focusedUnavailable:
            return route
        case .noFocusedOwner:
            _ = try await store.redo()
            return .noFocusedOwner
        }
    }
}

struct CalendarUndoCommands: Commands {
    let store: WorkspaceStore
    @ObservedObject var focusRegistry: EditorFocusRegistry

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("撤销") {
                Task {
                    try await CalendarUndoCommandRouter.undo(store: store, focusRegistry: focusRegistry)
                }
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(CalendarUndoCommandRouter.isDisabled(for: store, focusRegistry: focusRegistry))
            Button("重做") {
                Task {
                    try await CalendarUndoCommandRouter.redo(store: store, focusRegistry: focusRegistry)
                }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(CalendarUndoCommandRouter.isRedoDisabled(for: store, focusRegistry: focusRegistry))
        }
    }
}
