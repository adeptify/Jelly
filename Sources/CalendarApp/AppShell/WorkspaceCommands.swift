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
    @ObservedObject var transitionCoordinator: WorkspaceRouteTransitionCoordinator
    @ObservedObject var searchRouter: WorkspaceSearchRouter
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
                    features: features,
                    capturesTypingUntilReady: true
                )
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(routeState.commandNAction(features: features) == nil)
        }

        CommandMenu("查找") {
            Button("全局查找…") {
                searchRouter.present()
            }
            .keyboardShortcut("k", modifiers: .command)
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
            Task { _ = await transitionCoordinator.requestActivation(descriptor.route) }
        }
        .keyboardShortcut(KeyEquivalent(Character(descriptor.key)), modifiers: .command)
    }
}
