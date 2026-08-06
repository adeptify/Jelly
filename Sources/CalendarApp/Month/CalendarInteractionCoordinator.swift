import CalendarDomain
import Combine
import CoreGraphics
import Foundation

enum CalendarInteractionCoordinateSpace {
    static let root = "calendar-interaction-root"
}

enum CalendarInteractionHitTarget: Equatable {
    case completionButton
    case leadingHandle
    case trailingHandle
    case barBody
    case dateNumber
    case overflow
    case emptyCell

    var priority: Int {
        switch self {
        case .completionButton, .dateNumber, .overflow:
            4
        case .leadingHandle, .trailingHandle:
            3
        case .barBody:
            2
        case .emptyCell:
            1
        }
    }
}

enum CalendarInteractionState: Equatable {
    case idle
    case selectingRange(anchorDate: CalendarDate, currentDate: CalendarDate)
    case movingItem(source: ProjectedEntryID, previewSchedule: CalendarSchedule)
    case resizingLeading(source: ProjectedEntryID, previewSchedule: CalendarSchedule)
    case resizingTrailing(source: ProjectedEntryID, previewSchedule: CalendarSchedule)
    case pendingRecurrenceScope
    case editing(draft: CalendarDateRange, anchorDate: CalendarDate)
}

enum CalendarRangeMutationOperation: Equatable, Sendable {
    case move
    case resizeLeading
    case resizeTrailing
}

struct PendingCalendarMutation: Equatable, Sendable, Identifiable {
    let id: UUID
    let source: ProjectedEntry
    let operation: CalendarRangeMutationOperation
    let originalSchedule: CalendarSchedule
    let previewSchedule: CalendarSchedule
    let newSeriesID: UUID

    init(
        id: UUID = UUID(),
        source: ProjectedEntry,
        operation: CalendarRangeMutationOperation,
        originalSchedule: CalendarSchedule,
        previewSchedule: CalendarSchedule,
        newSeriesID: UUID = UUID()
    ) {
        self.id = id
        self.source = source
        self.operation = operation
        self.originalSchedule = originalSchedule
        self.previewSchedule = previewSchedule
        self.newSeriesID = newSeriesID
    }
}

enum CalendarInteractionAction: Equatable {
    case openCreate(CalendarDateRange, anchor: CalendarDate)
    case submitMutation(PendingCalendarMutation)
    case scrollEarlier
    case scrollLater
}

enum CalendarInteractionAutoScrollDirection: Equatable {
    case earlier
    case later

    var dayDelta: Int {
        switch self {
        case .earlier: -7
        case .later: 7
        }
    }
}

struct CalendarInteractionAutoScrollTick: Equatable {
    let sequence: Int
    let direction: CalendarInteractionAutoScrollDirection
}

@MainActor
protocol CalendarInteractionAutoScrollCancellation: AnyObject {
    func cancel()
}

@MainActor
protocol CalendarInteractionAutoScrollScheduler: AnyObject {
    func schedule(
        after delay: TimeInterval,
        action: @escaping () -> Void
    ) -> any CalendarInteractionAutoScrollCancellation
}

@MainActor
final class CalendarInteractionAutoScrollDriver: ObservableObject {
    private let scheduler: any CalendarInteractionAutoScrollScheduler
    private var cancellation: (any CalendarInteractionAutoScrollCancellation)?
    private var sequence = 0
    private var direction: CalendarInteractionAutoScrollDirection?

    @Published private(set) var latestTick: CalendarInteractionAutoScrollTick?

    init(scheduler: any CalendarInteractionAutoScrollScheduler = MainQueueAutoScrollScheduler()) {
        self.scheduler = scheduler
    }

    func update(direction: CalendarInteractionAutoScrollDirection?) {
        guard self.direction != direction else { return }
        cancellation?.cancel()
        cancellation = nil
        self.direction = direction
        guard let direction else { return }
        emit(direction)
        scheduleNext(direction)
    }

    func cancel() {
        update(direction: nil)
    }

    private func emit(_ direction: CalendarInteractionAutoScrollDirection) {
        sequence += 1
        latestTick = .init(sequence: sequence, direction: direction)
    }

    private func scheduleNext(_ direction: CalendarInteractionAutoScrollDirection) {
        cancellation = scheduler.schedule(after: CalendarInteractionCoordinator.autoScrollThrottle) {
            [weak self] in
            guard let self, self.direction == direction else { return }
            self.emit(direction)
            self.scheduleNext(direction)
        }
    }
}

@MainActor
private final class MainQueueAutoScrollScheduler: CalendarInteractionAutoScrollScheduler {
    private final class Cancellation: CalendarInteractionAutoScrollCancellation {
        let workItem: DispatchWorkItem

        init(workItem: DispatchWorkItem) {
            self.workItem = workItem
        }

        func cancel() {
            workItem.cancel()
        }
    }

    func schedule(
        after delay: TimeInterval,
        action: @escaping () -> Void
    ) -> any CalendarInteractionAutoScrollCancellation {
        let workItem = DispatchWorkItem {
            Task { @MainActor in action() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        return Cancellation(workItem: workItem)
    }
}

struct CalendarDateFrame: Equatable, Identifiable {
    let date: CalendarDate
    let frame: CGRect

    var id: CalendarDate { date }
}

struct CalendarDateFrameMap: Equatable {
    private let framesByDate: [CalendarDate: CGRect]

    init(frames: [CalendarDateFrame]) {
        framesByDate = Dictionary(uniqueKeysWithValues: frames.map { ($0.date, $0.frame) })
    }

    func frame(for date: CalendarDate) -> CGRect? {
        framesByDate[date]
    }

    func date(at point: CGPoint) -> CalendarDate? {
        framesByDate
            .filter { $0.value.contains(point) }
            .sorted { $0.key < $1.key }
            .first?
            .key
    }

    func nearestDate(to point: CGPoint) -> CalendarDate? {
        framesByDate.min { left, right in
            let leftDistance = left.value.squaredDistance(to: point)
            let rightDistance = right.value.squaredDistance(to: point)
            if leftDistance == rightDistance {
                return left.key < right.key
            }
            return leftDistance < rightDistance
        }?.key
    }

    var visibleDates: [CalendarDate] {
        framesByDate.keys.sorted()
    }
}

@MainActor
final class CalendarInteractionCoordinator: ObservableObject {
    static let dragThreshold: CGFloat = 7
    static let autoScrollEdgeThreshold: CGFloat = 28
    static let autoScrollThrottle: TimeInterval = 0.18

    @Published private(set) var state: CalendarInteractionState = .idle
    @Published private(set) var autoScrollDirection: CalendarInteractionAutoScrollDirection?

    private struct Press {
        let date: CalendarDate
        let point: CGPoint
        let target: CalendarInteractionHitTarget
        let source: ProjectedEntry?
    }

    private let now: () -> TimeInterval
    private var press: Press?
    private var latestPoint: CGPoint?
    private var latestDate: CalendarDate?
    private var lastAutoScrollAt: TimeInterval?

    init(now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.now = now
    }

    var previewRange: CalendarDateRange? {
        switch state {
        case let .selectingRange(anchorDate, currentDate):
            Self.normalizedRange(from: anchorDate, through: currentDate)
        case let .editing(draft, _):
            draft
        case let .movingItem(_, schedule),
             let .resizingLeading(_, schedule),
             let .resizingTrailing(_, schedule):
            CalendarDateRange(start: schedule.startDate, end: schedule.endDate)
        case .idle, .pendingRecurrenceScope:
            nil
        }
    }

    var previewSchedule: CalendarSchedule? {
        switch state {
        case let .movingItem(_, schedule),
             let .resizingLeading(_, schedule),
             let .resizingTrailing(_, schedule):
            schedule
        case .idle, .selectingRange, .pendingRecurrenceScope, .editing:
            nil
        }
    }

    var isSelectingRange: Bool {
        if case .selectingRange = state {
            true
        } else {
            false
        }
    }

    var isDragging: Bool {
        switch state {
        case .selectingRange, .movingItem, .resizingLeading, .resizingTrailing:
            true
        case .idle, .pendingRecurrenceScope, .editing:
            false
        }
    }

    var latestPointer: CGPoint? { latestPoint }

    var selectionCursorDate: CalendarDate? {
        switch state {
        case let .selectingRange(_, currentDate): currentDate
        case let .movingItem(_, schedule): schedule.startDate
        case let .resizingLeading(_, schedule): schedule.startDate
        case let .resizingTrailing(_, schedule): schedule.endDate
        case .idle, .pendingRecurrenceScope, .editing:
            nil
        }
    }

    func pointerDown(on date: CalendarDate, target: CalendarInteractionHitTarget, point: CGPoint) {
        guard target == .emptyCell else { return }
        // Recover from a stale create-editor lock (form closed without cancel) or a
        // leftover press so a second empty-cell click can open create again.
        recoverForNewEmptyPressIfNeeded()
        guard press == nil, state == .idle else { return }
        press = Press(date: date, point: point, target: target, source: nil)
        latestPoint = point
        latestDate = date
    }

    func pointerDown(
        on date: CalendarDate,
        target: CalendarInteractionHitTarget,
        source: ProjectedEntry,
        point: CGPoint
    ) {
        guard [.barBody, .leadingHandle, .trailingHandle].contains(target) else { return }
        recoverForNewEmptyPressIfNeeded()
        guard press == nil, state == .idle else { return }
        press = Press(date: date, point: point, target: target, source: source)
        latestPoint = point
        latestDate = date
    }

    /// `.editing` is only meaningful while the create form is open. If it lingers after
    /// dismiss, empty-cell presses would be ignored forever (`state == .idle` required).
    /// Do not clear `.pendingRecurrenceScope` — that blocks gestures until the user answers.
    private func recoverForNewEmptyPressIfNeeded() {
        switch state {
        case .editing:
            clearInteractionGesture()
            state = .idle
        case .idle:
            // Orphan press without an active drag (e.g. mouseUp never delivered).
            if press != nil {
                clearInteractionGesture()
            }
        case .selectingRange, .movingItem, .resizingLeading, .resizingTrailing, .pendingRecurrenceScope:
            break
        }
    }

    func beginRange(on date: CalendarDate, point: CGPoint) {
        pointerDown(on: date, target: .emptyCell, point: point)
    }

    @discardableResult
    func updatePointer(
        point: CGPoint,
        over date: CalendarDate?,
        viewportBounds: CGRect? = nil
    ) -> [CalendarInteractionAction] {
        guard let press else { return [] }
        latestPoint = point
        if let date {
            latestDate = date
        }
        guard point.distance(to: press.point) >= Self.dragThreshold else { return [] }

        let currentDate = date ?? latestDate ?? press.date
        updatePreview(for: press, over: currentDate)
        autoScrollDirection = edgeDirection(for: point, in: viewportBounds)
        return autoScrollActions(for: point, in: viewportBounds)
    }

    func refreshSelection(over date: CalendarDate?) {
        refreshInteraction(over: date)
    }

    func refreshInteraction(over date: CalendarDate?) {
        guard let date, let press else { return }
        latestDate = date
        updatePreview(for: press, over: date)
    }

    func pointerUp(at point: CGPoint, over date: CalendarDate?) -> CalendarInteractionAction? {
        defer { clearInteractionGesture() }
        guard let press else { return nil }

        latestPoint = point
        if let date {
            latestDate = date
        }
        let releaseDate = date ?? latestDate ?? press.date
        if point.distance(to: press.point) < Self.dragThreshold {
            guard press.target == .emptyCell else { return nil }
            return .openCreate(
                CalendarDateRange(start: press.date, end: press.date),
                anchor: press.date
            )
        }

        if let source = press.source,
           let operation = operation(for: press.target),
           let previewSchedule {
            return .submitMutation(.init(
                source: source,
                operation: operation,
                originalSchedule: source.schedule,
                previewSchedule: previewSchedule
            ))
        }
        guard press.source == nil else { return nil }
        return .openCreate(
            Self.normalizedRange(from: press.date, through: releaseDate),
            anchor: releaseDate
        )
    }

    func endInteraction() -> CalendarInteractionAction? {
        guard let point = latestPoint else { return nil }
        return pointerUp(at: point, over: latestDate)
    }

    func openEditor(for draft: CalendarDateRange, anchor: CalendarDate) {
        clearInteractionGesture()
        state = .editing(draft: draft, anchorDate: anchor)
    }

    func cancel() {
        clearInteractionGesture()
        state = .idle
    }

    func completeEditing() {
        cancel()
    }

    func beginPendingRecurrenceScope() {
        clearInteractionGesture()
        state = .pendingRecurrenceScope
    }

    func completePendingMutation() {
        guard case .pendingRecurrenceScope = state else { return }
        state = .idle
    }

    private func clearInteractionGesture() {
        press = nil
        latestPoint = nil
        latestDate = nil
        lastAutoScrollAt = nil
        autoScrollDirection = nil
        switch state {
        case .selectingRange, .movingItem, .resizingLeading, .resizingTrailing:
            state = .idle
        case .idle, .pendingRecurrenceScope, .editing:
            break
        }
    }

    private func updatePreview(for press: Press, over date: CalendarDate) {
        guard let source = press.source else {
            state = .selectingRange(anchorDate: press.date, currentDate: date)
            return
        }

        switch press.target {
        case .barBody:
            let delta = press.date.days(until: date)
            let schedule = makeValidatedPreviewSchedule(
                startDate: source.schedule.startDate.addingDays(delta),
                endDate: source.schedule.endDate.addingDays(delta),
                startTime: source.schedule.startTime,
                endTime: source.schedule.endTime
            )
            state = .movingItem(source: source.id, previewSchedule: schedule)
        case .leadingHandle:
            let minimumDurationDays = minimumDurationDays(for: source.schedule)
            let latestStart = source.schedule.endDate.addingDays(-(minimumDurationDays - 1))
            let start = min(date, latestStart)
            let schedule = makeValidatedPreviewSchedule(
                startDate: start,
                endDate: source.schedule.endDate,
                startTime: source.schedule.startTime,
                endTime: source.schedule.endTime
            )
            state = .resizingLeading(source: source.id, previewSchedule: schedule)
        case .trailingHandle:
            let minimumDurationDays = minimumDurationDays(for: source.schedule)
            let earliestEnd = source.schedule.startDate.addingDays(minimumDurationDays - 1)
            let end = max(date, earliestEnd)
            let schedule = makeValidatedPreviewSchedule(
                startDate: source.schedule.startDate,
                endDate: end,
                startTime: source.schedule.startTime,
                endTime: source.schedule.endTime
            )
            state = .resizingTrailing(source: source.id, previewSchedule: schedule)
        case .completionButton, .dateNumber, .overflow, .emptyCell:
            break
        }
    }

    private func operation(
        for target: CalendarInteractionHitTarget
    ) -> CalendarRangeMutationOperation? {
        switch target {
        case .barBody: .move
        case .leadingHandle: .resizeLeading
        case .trailingHandle: .resizeTrailing
        case .completionButton, .dateNumber, .overflow, .emptyCell: nil
        }
    }

    private func minimumDurationDays(for schedule: CalendarSchedule) -> Int {
        guard let startTime = schedule.startTime,
              let endTime = schedule.endTime
        else {
            return 1
        }
        return endTime > startTime ? 1 : 2
    }

    private func makeValidatedPreviewSchedule(
        startDate: CalendarDate,
        endDate: CalendarDate,
        startTime: MinuteOfDay?,
        endTime: MinuteOfDay?
    ) -> CalendarSchedule {
        do {
            return try CalendarSchedule(
                startDate: startDate,
                endDate: endDate,
                startTime: startTime,
                endTime: endTime
            )
        } catch {
            preconditionFailure("Deterministically clamped item preview must remain valid: \(error)")
        }
    }

    private func autoScrollActions(
        for point: CGPoint,
        in viewportBounds: CGRect?
    ) -> [CalendarInteractionAction] {
        guard let viewportBounds,
              viewportBounds.height > 0
        else {
            return []
        }
        let intent: CalendarInteractionAction? = edgeDirection(
            for: point,
            in: viewportBounds
        ).map { direction in
            switch direction {
            case .earlier: .scrollEarlier
            case .later: .scrollLater
            }
        }
        guard let intent else { return [] }

        let timestamp = now()
        if let lastAutoScrollAt, timestamp - lastAutoScrollAt < Self.autoScrollThrottle {
            return []
        }
        lastAutoScrollAt = timestamp
        return [intent]
    }

    private func edgeDirection(
        for point: CGPoint,
        in viewportBounds: CGRect?
    ) -> CalendarInteractionAutoScrollDirection? {
        guard let viewportBounds, viewportBounds.height > 0 else { return nil }
        if point.y <= viewportBounds.minY + Self.autoScrollEdgeThreshold {
            return .earlier
        }
        if point.y >= viewportBounds.maxY - Self.autoScrollEdgeThreshold {
            return .later
        }
        return nil
    }

    private static func normalizedRange(
        from anchorDate: CalendarDate,
        through currentDate: CalendarDate
    ) -> CalendarDateRange {
        CalendarDateRange(
            start: min(anchorDate, currentDate),
            end: max(anchorDate, currentDate)
        )
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}

private extension CGRect {
    func squaredDistance(to point: CGPoint) -> CGFloat {
        let horizontal = max(minX - point.x, 0, point.x - maxX)
        let vertical = max(minY - point.y, 0, point.y - maxY)
        return horizontal * horizontal + vertical * vertical
    }
}
