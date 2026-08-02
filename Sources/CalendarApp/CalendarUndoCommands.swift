import SwiftUI

@MainActor
enum CalendarUndoCommandRouter {
    static func isDisabled(for store: CalendarStore) -> Bool {
        !store.canUndo || store.isMutating
    }

    static func undo(store: CalendarStore) async throws {
        try await store.undo()
    }
}

struct CalendarUndoCommands: Commands {
    let store: CalendarStore

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
