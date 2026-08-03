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

enum CalendarInteractionAction: Equatable {
    case openCreate(CalendarDateRange, anchor: CalendarDate)
    case scrollEarlier
    case scrollLater
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

    private struct Press {
        let date: CalendarDate
        let point: CGPoint
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
        case .idle, .movingItem, .resizingLeading, .resizingTrailing, .pendingRecurrenceScope:
            nil
        }
    }

    func pointerDown(on date: CalendarDate, target: CalendarInteractionHitTarget, point: CGPoint) {
        guard target == .emptyCell,
              press == nil,
              state == .idle
        else {
            return
        }
        press = Press(date: date, point: point)
        latestPoint = point
        latestDate = date
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
        state = .selectingRange(anchorDate: press.date, currentDate: currentDate)
        return autoScrollActions(for: point, in: viewportBounds)
    }

    func pointerUp(at point: CGPoint, over date: CalendarDate?) -> CalendarInteractionAction? {
        defer { clearSelectionGesture() }
        guard let press else { return nil }

        latestPoint = point
        if let date {
            latestDate = date
        }
        let releaseDate = date ?? latestDate ?? press.date
        if point.distance(to: press.point) < Self.dragThreshold {
            return .openCreate(
                CalendarDateRange(start: press.date, end: press.date),
                anchor: press.date
            )
        }
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
        clearSelectionGesture()
        state = .editing(draft: draft, anchorDate: anchor)
    }

    func cancel() {
        clearSelectionGesture()
        state = .idle
    }

    func completeEditing() {
        cancel()
    }

    private func clearSelectionGesture() {
        press = nil
        latestPoint = nil
        latestDate = nil
        lastAutoScrollAt = nil
        if case .selectingRange = state {
            state = .idle
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
        let intent: CalendarInteractionAction?
        if point.y <= viewportBounds.minY + Self.autoScrollEdgeThreshold {
            intent = .scrollEarlier
        } else if point.y >= viewportBounds.maxY - Self.autoScrollEdgeThreshold {
            intent = .scrollLater
        } else {
            intent = nil
        }
        guard let intent else { return [] }

        let timestamp = now()
        if let lastAutoScrollAt, timestamp - lastAutoScrollAt < Self.autoScrollThrottle {
            return []
        }
        lastAutoScrollAt = timestamp
        return [intent]
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
