import Combine
import Foundation

@MainActor
protocol WorkspaceRoutePreferenceStore: AnyObject {
    var selectedRouteRawValue: String? { get }
    func writeSelectedRouteRawValue(_ rawValue: String)
}

@MainActor
final class UserDefaultsWorkspaceRoutePreferenceStore: WorkspaceRoutePreferenceStore {
    static let storageKey = "workspace.selectedRoute"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var selectedRouteRawValue: String? {
        defaults.string(forKey: Self.storageKey)
    }

    func writeSelectedRouteRawValue(_ rawValue: String) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }
}

@MainActor
final class WorkspaceRouteState: ObservableObject {
    @Published private(set) var route: WorkspaceRoute
    private let preferences: any WorkspaceRoutePreferenceStore

    init(
        features: WorkspaceFeatures,
        preferences: any WorkspaceRoutePreferenceStore = UserDefaultsWorkspaceRoutePreferenceStore()
    ) {
        self.preferences = preferences

        if let rawValue = preferences.selectedRouteRawValue,
           let persistedRoute = WorkspaceRoute(rawValue: rawValue),
           features.isEnabled(persistedRoute)
        {
            route = persistedRoute
        } else {
            route = .calendar
            preferences.writeSelectedRouteRawValue(WorkspaceRoute.calendar.rawValue)
        }
    }

    @discardableResult
    func activate(_ requestedRoute: WorkspaceRoute, features: WorkspaceFeatures) -> Bool {
        guard features.isEnabled(requestedRoute) else { return false }
        guard route != requestedRoute else { return true }
        route = requestedRoute
        preferences.writeSelectedRouteRawValue(requestedRoute.rawValue)
        return true
    }

    @discardableResult
    func handleCommandShortcut(_ key: String, features: WorkspaceFeatures) -> Bool {
        guard let requestedRoute = WorkspaceRoute.commandShortcut(key) else { return false }
        return activate(requestedRoute, features: features)
    }

    func commandNAction(features: WorkspaceFeatures) -> WorkspaceNewItemAction? {
        guard features.isEnabled(route) else { return nil }
        return WorkspaceNewItemAction(route: route)
    }
}
