import SwiftUI

struct CalendarModuleView: View {
    let store: WorkspaceStore
    @ObservedObject var newItemRouter: WorkspaceNewItemRouter

    var body: some View {
        MonthView(
            store: store,
            newItemRequest: newItemRouter.pendingRequest,
            consumeNewItemRequest: { requestID, route in
                newItemRouter.consume(requestID, route: route)
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
