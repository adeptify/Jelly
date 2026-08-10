import SwiftUI

struct WorkspaceNavigationCommandDescriptor: Equatable, Identifiable, Sendable {
    let route: WorkspaceRoute
    let title: String
    let key: String

    var id: WorkspaceRoute { route }
}

enum WorkspaceCommandComposition {
    static func navigationDescriptors(
        features: WorkspaceFeatures
    ) -> [WorkspaceNavigationCommandDescriptor] {
        WorkspaceRoute.visibleRoutes(features).map { route in
            WorkspaceNavigationCommandDescriptor(
                route: route,
                title: route.railMetadata.name,
                key: route.commandShortcutKey
            )
        }
    }
}

struct WorkspaceCommands: Commands {
    @ObservedObject var routeState: WorkspaceRouteState
    @ObservedObject var newItemRouter: WorkspaceNewItemRouter
    let features: WorkspaceFeatures

    var body: some Commands {
        CommandMenu("导航") {
            ForEach(WorkspaceCommandComposition.navigationDescriptors(features: features)) {
                descriptor in
                navigationCommand(descriptor)
            }
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
    private func navigationCommand(_ descriptor: WorkspaceNavigationCommandDescriptor) -> some View {
        Button(descriptor.title) {
            _ = routeState.activate(descriptor.route, features: features)
        }
        .keyboardShortcut(KeyEquivalent(Character(descriptor.key)), modifiers: .command)
    }
}
