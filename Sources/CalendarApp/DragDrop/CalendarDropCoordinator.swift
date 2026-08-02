import CalendarDomain
import Combine
import Foundation

struct PendingRecurringDrop: Equatable {
    let key: OccurrenceKey
    let destination: CalendarDate
    let newSeriesID: UUID
}

@MainActor
final class CalendarDropCoordinator: ObservableObject {
    private let store: CalendarStore
    @Published var pendingRecurringDrop: PendingRecurringDrop?
    @Published private(set) var dropTargetDate: CalendarDate?

    init(store: CalendarStore) {
        self.store = store
    }

    func setTargeted(_ isTargeted: Bool, date: CalendarDate) {
        if isTargeted {
            dropTargetDate = date
        } else if dropTargetDate == date {
            dropTargetDate = nil
        }
    }

    func accept(_ payload: CalendarTransferPayload, on date: CalendarDate) async throws {
        try store.requireReadyForMutation()

        switch payload {
        case let .item(id):
            try await store.send(.moveItem(id, to: date), undoLabel: "移动事项")

        case let .occurrence(key):
            guard pendingRecurringDrop == nil else { return }
            pendingRecurringDrop = PendingRecurringDrop(
                key: key,
                destination: date,
                newSeriesID: UUID()
            )
        }
    }

    func resolve(scope: SeriesScope) async throws {
        guard let pendingRecurringDrop else { return }
        try await store.send(
            .mutateSeries(
                pendingRecurringDrop.key,
                scope: scope,
                edit: .patch(.init(displayedDate: pendingRecurringDrop.destination)),
                newSeriesID: pendingRecurringDrop.newSeriesID
            ),
            undoLabel: "移动重复事项"
        )
        self.pendingRecurringDrop = nil
    }

    func cancel() {
        pendingRecurringDrop = nil
    }
}
