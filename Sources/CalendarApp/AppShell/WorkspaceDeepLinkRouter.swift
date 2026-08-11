import Combine
import Foundation
import WorkspaceDomain

enum WorkspaceDeepLinkTarget: Equatable, Sendable {
    case calendarItem(UUID)
    case note(NoteID)

    var route: WorkspaceRoute {
        switch self {
        case .calendarItem: .calendar
        case .note: .notes
        }
    }
}

struct WorkspaceDeepLinkRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let target: WorkspaceDeepLinkTarget

    init(id: UUID = UUID(), target: WorkspaceDeepLinkTarget) {
        self.id = id
        self.target = target
    }
}

@MainActor
final class WorkspaceDeepLinkRouter: ObservableObject {
    @Published private(set) var pendingRequest: WorkspaceDeepLinkRequest?

    @discardableResult
    func request(_ target: WorkspaceDeepLinkTarget) -> WorkspaceDeepLinkRequest {
        let request = WorkspaceDeepLinkRequest(target: target)
        pendingRequest = request
        return request
    }

    func consume(
        _ id: UUID,
        target: WorkspaceDeepLinkTarget
    ) -> WorkspaceDeepLinkRequest? {
        guard let request = pendingRequest,
              request.id == id,
              request.target == target else { return nil }
        pendingRequest = nil
        return request
    }
}
