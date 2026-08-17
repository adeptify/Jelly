import CalendarDomain
import Combine
import Foundation

enum CalendarDropCoordinatorError: Error, Equatable, Sendable {
    case persistenceNotCommitted
}

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

struct RecentMutationIDCache {
    private let capacity: Int
    private var orderedIDs: [UUID] = []
    private var membership = Set<UUID>()

    init(capacity: Int) {
        precondition(capacity > 0, "Recent mutation cache capacity must be positive.")
        self.capacity = capacity
    }

    var count: Int { orderedIDs.count }

    func contains(_ id: UUID) -> Bool {
        membership.contains(id)
    }

    mutating func insert(_ id: UUID) {
        if membership.contains(id) {
            orderedIDs.removeAll(where: { $0 == id })
            orderedIDs.append(id)
            return
        }
        if orderedIDs.count == capacity, let evicted = orderedIDs.first {
            orderedIDs.removeFirst()
            membership.remove(evicted)
        }
        orderedIDs.append(id)
        membership.insert(id)
    }
}

@MainActor
final class CalendarDropCoordinator: ObservableObject {
    private static let recentMutationIDCapacity = 256
    private let store: WorkspaceStore
    @Published var pendingRecurringDrop: PendingRecurringDrop?
    @Published private(set) var pendingCalendarMutation: PendingCalendarMutation?
    @Published private(set) var dropTargetDate: CalendarDate?
    private(set) var isResolvingRecurringDrop = false
    private var activeResolution: RecurringDropResolution?
    private var submittingMutationIDs = Set<UUID>()
    private var committedMutationIDs = RecentMutationIDCache(
        capacity: recentMutationIDCapacity
    )

    init(store: WorkspaceStore) {
        self.store = store
    }

    func setTargeted(_ isTargeted: Bool, date: CalendarDate) {
        if isTargeted {
            dropTargetDate = date
        } else if dropTargetDate == date {
            dropTargetDate = nil
        }
    }

    /// Same-day reorder of untimed single-day items. Returns false so the
    /// caller can keep the existing date-move path. Same-day no-ops return
    /// true so they do not become a redundant schedule write.
    func acceptUntimedReorder(
        _ payload: CalendarTransferPayload,
        before targetID: UUID,
        on date: CalendarDate
    ) async throws -> Bool {
        try await acceptUntimedReorder(payload, to: .before(targetID), on: date)
    }

    func acceptUntimedReorder(
        _ payload: CalendarTransferPayload,
        to destination: UntimedItemReorder.Destination,
        on date: CalendarDate
    ) async throws -> Bool {
        guard case let .item(sourceID) = payload else { return false }
        guard store.phase == .ready else { throw WorkspaceStoreError.frozen }
        guard let source = store.calendarState.items[sourceID],
              UntimedItemReorder.isReorderable(source),
              source.schedule.startDate == date
        else { return false }
        if case let .before(targetID) = destination {
            guard let target = store.calendarState.items[targetID],
                  UntimedItemReorder.isReorderable(target),
                  target.schedule.startDate == date
            else { return false }
        }

        let displayIDs = UntimedItemReorder.reorderableIDs(on: date, in: store.calendarState)
        guard let ordered = UntimedItemReorder.moving(sourceID, to: destination, in: displayIDs) else {
            return true
        }
        let outcome = try await store.sendCalendar(
            .reorderUntimedItems(on: date, orderedIDs: ordered),
            undoLabel: "已调整事项顺序"
        )
        try requirePersistedCalendarOutcome(outcome)
        return true
    }

    func acceptUntimedReorder(
        _ payload: CalendarTransferPayload,
        orderedIDs: [UUID],
        on date: CalendarDate
    ) async throws -> Bool {
        guard case let .item(sourceID) = payload else { return false }
        guard store.phase == .ready else { throw WorkspaceStoreError.frozen }
        guard orderedIDs.contains(sourceID) else { return false }
        let current = UntimedItemReorder.reorderableIDs(on: date, in: store.calendarState)
        guard Set(current) == Set(orderedIDs) else { return false }
        if current == orderedIDs { return true }
        let outcome = try await store.sendCalendar(
            .reorderUntimedItems(on: date, orderedIDs: orderedIDs),
            undoLabel: "已调整事项顺序"
        )
        try requirePersistedCalendarOutcome(outcome)
        return true
    }

    /// Transferable drop onto another untimed row: move past the target
    /// instead of always inserting before it (which no-ops a downward drag).
    func acceptUntimedReorder(
        _ payload: CalendarTransferPayload,
        onto targetID: UUID,
        on date: CalendarDate
    ) async throws -> Bool {
        guard case let .item(sourceID) = payload else { return false }
        let displayIDs = UntimedItemReorder.reorderableIDs(on: date, in: store.calendarState)
        guard displayIDs.contains(sourceID) else { return false }
        guard let destination = UntimedItemReorder.destination(
            moving: sourceID,
            onto: targetID,
            in: displayIDs
        ) else { return true }
        return try await acceptUntimedReorder(payload, to: destination, on: date)
    }

    func accept(_ payload: CalendarTransferPayload, on date: CalendarDate) async throws {
        switch payload {
        case let .item(id):
            guard store.phase == .ready else { throw WorkspaceStoreError.frozen }
            guard let item = store.calendarState.items[id] else {
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
            guard store.phase == .ready else { throw WorkspaceStoreError.frozen }
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
        guard store.phase == .ready else { throw WorkspaceStoreError.frozen }

        switch mutation.source {
        case let .item(item):
            _ = submittingMutationIDs.insert(mutation.id)
            let command: CalendarCommand
            switch mutation.operation {
            case .move:
                // Prefer full schedule write so week-view timed moves (day + clock) stick;
                // day-only shifts also work because previewSchedule already has shifted dates.
                var updated = item
                updated.schedule = mutation.previewSchedule
                updated.updatedAt = Date()
                command = .updateItem(updated)
            case .resizeLeading, .resizeTrailing:
                var updated = item
                updated.schedule = mutation.previewSchedule
                updated.updatedAt = Date()
                command = .updateItem(updated)
            }
            do {
                let outcome = try await store.sendCalendar(command, undoLabel: mutation.undoLabel)
                try requirePersistedCalendarOutcome(outcome)
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
            let outcome = try await store.sendCalendar(
                .mutateSeries(
                    resolution.pendingDrop.key,
                    scope: resolution.scope,
                    edit: .patch(resolution.pendingMutation.seriesPatch),
                    newSeriesID: resolution.pendingDrop.newSeriesID
                ),
                undoLabel: resolution.pendingMutation.recurringUndoLabel
            )
            try requirePersistedCalendarOutcome(outcome)
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

    private func requirePersistedCalendarOutcome(_ outcome: WorkspaceTransactionOutcome) throws {
        guard WorkspaceMutationOutcomePresenter.presentation(for: outcome).allowsDismissal else {
            throw CalendarDropCoordinatorError.persistenceNotCommitted
        }
    }

    private func occurrence(for key: OccurrenceKey) throws -> CalendarOccurrence {
        guard let series = store.calendarState.recurrence.series[key.seriesID] else {
            throw ReducerError.missingSeries
        }
        let override: OccurrenceOverride?
        switch store.calendarState.recurrence.exceptions[key] {
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
            priority: override?.priority ?? series.priority,
            isPinned: override?.isPinned ?? series.isPinned,
            creationTimeZoneIdentifier: series.creationTimeZoneIdentifier,
            completedAt: store.calendarState.recurrence.completions[key]?.completedAt,
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
        let startTime: OptionalPatch<MinuteOfDay> = previewSchedule.startTime.map { .set($0) } ?? .unchanged
        let endTime: OptionalPatch<MinuteOfDay> = previewSchedule.endTime.map { .set($0) } ?? .unchanged
        switch operation {
        case .move:
            return SeriesPatch(
                displayedStartDate: previewSchedule.startDate,
                durationDays: previewSchedule.durationDays,
                startTime: startTime,
                endTime: endTime
            )
        case .resizeLeading:
            return SeriesPatch(
                displayedStartDate: previewSchedule.startDate,
                durationDays: previewSchedule.durationDays,
                startTime: startTime,
                endTime: endTime
            )
        case .resizeTrailing:
            return SeriesPatch(
                durationDays: previewSchedule.durationDays,
                startTime: startTime,
                endTime: endTime
            )
        }
    }
}
