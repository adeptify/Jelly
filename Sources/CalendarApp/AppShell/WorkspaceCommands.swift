import SwiftUI

struct WorkspaceCommands: Commands {
    @ObservedObject var routeState: WorkspaceRouteState
    @ObservedObject var newItemRouter: WorkspaceNewItemRouter
    let features: WorkspaceFeatures

    var body: some Commands {
        CommandMenu("导航") {
            navigationCommand(.calendar, key: "1")
            navigationCommand(.notes, key: "2")
            navigationCommand(.inspiration, key: "3")
        }

        CommandGroup(replacing: .newItem) {
            Button(newItemTitle) {
                _ = newItemRouter.requestNewItem(
                    route: routeState.route,
                    features: features
                )
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(routeState.commandNAction(features: features) == nil)
        }
    }

    private var newItemTitle: String {
        switch routeState.commandNAction(features: features) {
        case .createCalendarItem:
            "新建事项"
        case .createNote:
            "新建笔记"
        case .createInspiration:
            "新建灵感"
        case nil:
            "新建"
        }
    }

    @ViewBuilder
    private func navigationCommand(_ route: WorkspaceRoute, key: String) -> some View {
        Button(route.railMetadata.name) {
            _ = routeState.activate(route, features: features)
        }
        .keyboardShortcut(KeyEquivalent(Character(key)), modifiers: .command)
        .disabled(!features.isEnabled(route))
    }
}
