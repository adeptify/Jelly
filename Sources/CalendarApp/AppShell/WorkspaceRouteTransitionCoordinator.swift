import Foundation

/// Single async gate for rail, menu and Command-1/2/3 transitions. Leaving
/// Notes must flush the latest autosave generation first; only protected or
/// persisted evidence may activate the destination once.
@MainActor
final class WorkspaceRouteTransitionCoordinator: ObservableObject {
    private let routeState: WorkspaceRouteState
    private let features: WorkspaceFeatures
    private var notesCloseBridge: NoteCloseProtectionBridge?
    private var notesFinalizer: NoteNativeInputFinalizer?
    private var inFlight: Task<Bool, Never>?

    init(routeState: WorkspaceRouteState, features: WorkspaceFeatures) {
        self.routeState = routeState
        self.features = features
    }

    /// Notes module registers its bridge so leaving Notes reuses the exact
    /// 10B flush barrier rather than inventing a second lifecycle path.
    func attachNotesCloseBridge(
        _ bridge: NoteCloseProtectionBridge?,
        finalizer: NoteNativeInputFinalizer? = nil
    ) {
        notesCloseBridge = bridge
        notesFinalizer = finalizer
    }

    @discardableResult
    func requestActivation(_ requestedRoute: WorkspaceRoute) async -> Bool {
        if let inFlight {
            return await inFlight.value
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            defer { self.inFlight = nil }
            return await self.performActivation(requestedRoute)
        }
        inFlight = task
        return await task.value
    }

    private func performActivation(_ requestedRoute: WorkspaceRoute) async -> Bool {
        guard features.isEnabled(requestedRoute) else { return false }
        guard routeState.route != requestedRoute else { return true }

        if routeState.route == .notes {
            guard let bridge = notesCloseBridge else {
                // Notes host not mounted yet — refuse rather than drop drafts.
                return false
            }
            let decision = await bridge.decision(for: .route, finalizer: notesFinalizer)
            switch decision {
            case .allow:
                break
            case .keepOpen, .terminateLater:
                return false
            }
        }

        return routeState.activate(requestedRoute, features: features)
    }
}
