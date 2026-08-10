import Combine
import SwiftUI

@MainActor
final class WorkspaceModuleHost: @MainActor Identifiable {
    let route: WorkspaceRoute
    let content: AnyView
    let lifetimeToken: AnyObject

    var id: WorkspaceRoute { route }

    init(route: WorkspaceRoute, content: AnyView, lifetimeToken: AnyObject) {
        self.route = route
        self.content = content
        self.lifetimeToken = lifetimeToken
    }
}

enum WorkspaceModuleHostPresentation: Equatable {
    case active
    case inactive

    var allowsHitTesting: Bool {
        self == .active
    }

    var accessibilityHidden: Bool {
        self == .inactive
    }
}

/// Builds every enabled module exactly once. AppShell keeps this store alive so
/// switching routes only changes presentation and never resets module state.
@MainActor
final class WorkspaceModuleHostStore: ObservableObject {
    private let hostsByRoute: [WorkspaceRoute: WorkspaceModuleHost]
    let hosts: [WorkspaceModuleHost]

    init(
        features: WorkspaceFeatures,
        build: (WorkspaceRoute) -> WorkspaceModuleHost
    ) {
        let builtHosts = WorkspaceRoute.visibleRoutes(features).map(build)
        hosts = builtHosts
        hostsByRoute = Dictionary(uniqueKeysWithValues: builtHosts.map { ($0.route, $0) })
    }

    func host(for route: WorkspaceRoute) -> WorkspaceModuleHost? {
        hostsByRoute[route]
    }

    func presentation(
        for route: WorkspaceRoute,
        activeRoute: WorkspaceRoute
    ) -> WorkspaceModuleHostPresentation {
        route == activeRoute ? .active : .inactive
    }
}

private final class WorkspaceModuleLifetimeToken {}

struct AppShellView: View {
    let store: WorkspaceStore
    let features: WorkspaceFeatures
    let focusRegistry: EditorFocusRegistry
    @ObservedObject var routeState: WorkspaceRouteState
    @ObservedObject var newItemRouter: WorkspaceNewItemRouter
    @StateObject private var moduleHosts: WorkspaceModuleHostStore

    init(
        store: WorkspaceStore,
        features: WorkspaceFeatures,
        routeState: WorkspaceRouteState,
        newItemRouter: WorkspaceNewItemRouter,
        focusRegistry: EditorFocusRegistry = EditorFocusRegistry(),
        moduleHostBuilder: ((WorkspaceRoute) -> WorkspaceModuleHost)? = nil
    ) {
        self.store = store
        self.features = features
        self.focusRegistry = focusRegistry
        self.routeState = routeState
        self.newItemRouter = newItemRouter

        let builder = moduleHostBuilder ?? { route in
            switch route {
            case .calendar:
                WorkspaceModuleHost(
                    route: .calendar,
                    content: AnyView(CalendarModuleView(
                        store: store,
                        newItemRouter: newItemRouter
                    )),
                    lifetimeToken: WorkspaceModuleLifetimeToken()
                )
            case .notes:
                // Production notes remains feature-gated false until Task 10D.
                // The host is only built when features.notes is true.
                WorkspaceModuleHost(
                    route: .notes,
                    content: AnyView(NotesSplitView(
                        store: store,
                        focusRegistry: focusRegistry
                    )),
                    lifetimeToken: WorkspaceModuleLifetimeToken()
                )
            case .inspiration:
                fatalError("尚未完成的模块不能被生产外壳实例化")
            }
        }
        _moduleHosts = StateObject(wrappedValue: WorkspaceModuleHostStore(
            features: features,
            build: builder
        ))
    }

    var body: some View {
        HStack(spacing: 0) {
            WorkspaceNavigationRail(features: features, routeState: routeState)
            ZStack {
                ForEach(moduleHosts.hosts) { host in
                    let presentation = moduleHosts.presentation(
                        for: host.route,
                        activeRoute: routeState.route
                    )
                    host.content
                        .opacity(presentation == .active ? 1 : 0)
                        .allowsHitTesting(presentation.allowsHitTesting)
                        .accessibilityHidden(presentation.accessibilityHidden)
                        .accessibilityIdentifier("workspace-module-\(host.route.rawValue)")
                }
            }
            .frame(
                minWidth: WorkspaceWindowLayout.calendarContentMinimumWidth,
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading
            )
        }
        .frame(
            minWidth: WorkspaceWindowLayout.minimumWidth,
            minHeight: WorkspaceWindowLayout.minimumHeight,
            alignment: .topLeading
        )
    }
}
