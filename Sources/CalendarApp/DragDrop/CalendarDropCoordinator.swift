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
    let pendingMutation: PendingCalendarMutation
    let scope: SeriesScope
}

@MainActor
final class CalendarDropCoordinator: ObservableObject {
    private let store: CalendarStore
    @Published var pendingRecurringDrop: PendingRecurringDrop?
    @Published private(set) var pendingCalendarMutation: PendingCalendarMutation?
    @Published private(set) var dropTargetDate: CalendarDate?
    private(set) var isResolvingRecurringDrop = false
    private var activeResolution: RecurringDropResolution?
    private var submittingMutationIDs = Set<UUID>()
    private var committedMutationIDs = Set<UUID>()

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
        switch payload {
        case let .item(id):
            try store.requireReadyForMutation()
            guard let item = store.state.items[id] else {
                throw ReducerError.missingItem
            }
            try await accept(.init(
                source: .item(item),
                operation: .move,
                originalSchedule: item.schedule,
                previewSchedule: try item.schedule.shifted(
                    byDays: item.schedule.startDate.days(until: date)
                )
            ))

        case let .occurrence(key):
            try store.requireReadyForMutation()
            let occurrence = try occurrence(for: key)
            try await accept(.init(
                source: .occurrence(occurrence),
                operation: .move,
                originalSchedule: occurrence.schedule,
                previewSchedule: try occurrence.schedule.shifted(
                    byDays: occurrence.schedule.startDate.days(until: date)
                )
            ))
        }
    }

    func accept(_ mutation: PendingCalendarMutation) async throws {
        guard !committedMutationIDs.contains(mutation.id),
              !submittingMutationIDs.contains(mutation.id)
        else { return }
        try store.requireReadyForMutation()

        switch mutation.source {
        case let .item(item):
            _ = submittingMutationIDs.insert(mutation.id)
            let command: CalendarCommand
            switch mutation.operation {
            case .move:
                command = .moveItem(item.id, to: mutation.previewSchedule.startDate)
            case .resizeLeading, .resizeTrailing:
                var updated = item
                updated.schedule = mutation.previewSchedule
                command = .updateItem(updated)
            }
            do {
                try await store.send(command, undoLabel: mutation.undoLabel)
                submittingMutationIDs.remove(mutation.id)
                committedMutationIDs.insert(mutation.id)
            } catch {
                submittingMutationIDs.remove(mutation.id)
                throw error
            }

        case let .occurrence(occurrence):
            guard pendingCalendarMutation == nil,
                  pendingRecurringDrop == nil,
                  !isResolvingRecurringDrop
            else {
                return
            }
            pendingCalendarMutation = mutation
            pendingRecurringDrop = PendingRecurringDrop(
                key: occurrence.key,
                destination: mutation.previewSchedule.startDate,
                newSeriesID: mutation.newSeriesID
            )
        }
    }

    func beginResolution(scope: SeriesScope) -> RecurringDropResolution? {
        guard let pendingRecurringDrop,
              let pendingCalendarMutation,
              !isResolvingRecurringDrop
        else { return nil }
        let resolution = RecurringDropResolution(
            pendingDrop: pendingRecurringDrop,
            pendingMutation: pendingCalendarMutation,
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
                    edit: .patch(resolution.pendingMutation.seriesPatch),
                    newSeriesID: resolution.pendingDrop.newSeriesID
                ),
                undoLabel: resolution.pendingMutation.recurringUndoLabel
            )
            pendingRecurringDrop = nil
            pendingCalendarMutation = nil
            committedMutationIDs.insert(resolution.pendingMutation.id)
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
        pendingCalendarMutation = nil
    }

    private func occurrence(for key: OccurrenceKey) throws -> CalendarOccurrence {
        guard let series = store.state.recurrence.series[key.seriesID] else {
            throw ReducerError.missingSeries
        }
        let override: OccurrenceOverride?
        switch store.state.recurrence.exceptions[key] {
        case .skipped:
            throw SeriesMutationError.unknownOccurrence
        case let .modified(value):
            override = value
        case nil:
            override = nil
        }
        let kind = override?.kind ?? series.kind
        let schedule: CalendarSchedule
        if let override {
            schedule = override.displayedSchedule
        } else {
            schedule = try CalendarSchedule(
                startDate: key.originalDate,
                endDate: key.originalDate.addingDays(series.durationDays - 1),
                startTime: series.startTime,
                endTime: series.endTime
            )
        }
        return CalendarOccurrence(
            key: key,
            schedule: schedule,
            title: override?.title ?? series.title,
            kind: kind,
            categoryID: override?.categoryID ?? series.categoryID,
            creationTimeZoneIdentifier: series.creationTimeZoneIdentifier,
            completedAt: kind == .task
                ? store.state.recurrence.completions[key]?.completedAt
                : nil,
            createdAt: series.createdAt
        )
    }
}

private extension PendingCalendarMutation {
    var undoLabel: String {
        switch operation {
        case .move: "移动事项"
        case .resizeLeading, .resizeTrailing: "调整事项日期"
        }
    }

    var recurringUndoLabel: String {
        switch operation {
        case .move: "移动重复事项"
        case .resizeLeading, .resizeTrailing: "调整重复事项日期"
        }
    }

    var seriesPatch: SeriesPatch {
        switch operation {
        case .move:
            SeriesPatch(displayedStartDate: previewSchedule.startDate)
        case .resizeLeading:
            SeriesPatch(
                displayedStartDate: previewSchedule.startDate,
                durationDays: previewSchedule.durationDays
            )
        case .resizeTrailing:
            SeriesPatch(durationDays: previewSchedule.durationDays)
        }
    }
}
