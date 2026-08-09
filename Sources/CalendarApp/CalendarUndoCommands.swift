import SwiftUI

@MainActor
enum CalendarUndoCommandRouter {
    static func isDisabled(for store: WorkspaceStore) -> Bool {
        !store.canUndo || store.phase != .ready
    }

    static func undo(store: WorkspaceStore) async throws {
        _ = try await store.undo()
    }
}

struct CalendarUndoCommands: Commands {
    let store: WorkspaceStore

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("撤销") {
                Task {
                    try await CalendarUndoCommandRouter.undo(store: store)
                }
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(CalendarUndoCommandRouter.isDisabled(for: store))
        }
    }
}
