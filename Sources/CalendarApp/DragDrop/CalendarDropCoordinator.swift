import CalendarDomain
import Combine
import Foundation

struct PendingRecurringDrop: Equatable {
    let key: OccurrenceKey
    let destination: CalendarDate
    let newSeriesID: UUID
}

struct RecurringDropResolution: Equatable {
    let pendingDrop: PendingRecurringDrop
    let scope: SeriesScope
}

@MainActor
final class CalendarDropCoordinator: ObservableObject {
    private let store: CalendarStore
    @Published var pendingRecurringDrop: PendingRecurringDrop?
    @Published private(set) var dropTargetDate: CalendarDate?
    private(set) var isResolvingRecurringDrop = false
    private var activeResolution: RecurringDropResolution?

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

    func beginResolution(scope: SeriesScope) -> RecurringDropResolution? {
        guard let pendingRecurringDrop, !isResolvingRecurringDrop else { return nil }
        let resolution = RecurringDropResolution(
            pendingDrop: pendingRecurringDrop,
            scope: scope
        )
        activeResolution = resolution
        isResolvingRecurringDrop = true
        return resolution
    }

    func submit(_ resolution: RecurringDropResolution) async throws {
        guard activeResolution == resolution else { return }
        activeResolution = nil

        do {
            try await store.send(
                .mutateSeries(
                    resolution.pendingDrop.key,
                    scope: resolution.scope,
                    edit: .patch(.init(displayedDate: resolution.pendingDrop.destination)),
                    newSeriesID: resolution.pendingDrop.newSeriesID
                ),
                undoLabel: "移动重复事项"
            )
            pendingRecurringDrop = nil
            isResolvingRecurringDrop = false
        } catch {
            isResolvingRecurringDrop = false
            throw error
        }
    }

    func resolve(scope: SeriesScope) async throws {
        guard let resolution = beginResolution(scope: scope) else { return }
        try await submit(resolution)
    }

    func cancel() {
        guard !isResolvingRecurringDrop else { return }
        pendingRecurringDrop = nil
    }
}
