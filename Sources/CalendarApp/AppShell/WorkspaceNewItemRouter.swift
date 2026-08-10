import Combine
import Foundation

struct WorkspaceNewItemRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let route: WorkspaceRoute

    init(id: UUID = UUID(), route: WorkspaceRoute) {
        self.id = id
        self.route = route
    }
}

@MainActor
final class WorkspaceNewItemRouter: ObservableObject {
    @Published private(set) var pendingRequest: WorkspaceNewItemRequest?

    @discardableResult
    func requestNewItem(
        route: WorkspaceRoute,
        features: WorkspaceFeatures
    ) -> WorkspaceNewItemRequest? {
        guard features.isEnabled(route) else { return nil }
        let request = WorkspaceNewItemRequest(route: route)
        pendingRequest = request
        return request
    }

    func consume(_ id: UUID, route: WorkspaceRoute) -> WorkspaceNewItemRequest? {
        guard let request = pendingRequest,
              request.id == id,
              request.route == route
        else {
            return nil
        }
        pendingRequest = nil
        return request
    }
}
