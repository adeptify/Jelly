import SwiftUI

struct CalendarModuleView: View {
    let store: WorkspaceStore
    @ObservedObject var newItemRouter: WorkspaceNewItemRouter
    @ObservedObject var deepLinkRouter: WorkspaceDeepLinkRouter
    @ObservedObject var transitionCoordinator: WorkspaceRouteTransitionCoordinator

    var body: some View {
        MonthView(
            store: store,
            newItemRequest: newItemRouter.pendingRequest,
            consumeNewItemRequest: { requestID, route in
                newItemRouter.consume(requestID, route: route)
            },
            deepLinkRequest: deepLinkRouter.pendingRequest,
            consumeDeepLinkRequest: { requestID, target in
                deepLinkRouter.consume(requestID, target: target)
            },
            onOpenNote: { noteID in
                Task { @MainActor in
                    guard await transitionCoordinator.requestActivation(.notes) else { return }
                    _ = deepLinkRouter.request(.note(noteID))
                }
            }
        )
        .frame(
            minWidth: WorkspaceWindowLayout.calendarContentMinimumWidth,
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }
}
