import Foundation

public enum UntimedItemReorder {
    public static func isReorderable(_ schedule: CalendarSchedule) -> Bool {
        schedule.startTime == nil && schedule.durationDays == 1
    }

    public static func isReorderable(_ item: CalendarItem) -> Bool {
        isReorderable(item.schedule)
    }

    public static func reorderableIDs(
        on date: CalendarDate,
        in state: CalendarState,
        hiddenCategoryIDs: Set<UUID> = []
    ) -> [UUID] {
        TimelineProjection.make(
            in: CalendarDateRange(start: date, end: date),
            state: state,
            hiddenCategoryIDs: hiddenCategoryIDs
        ).entries.compactMap { entry in
            guard case let .item(item) = entry, isReorderable(item) else { return nil }
            return item.id
        }
    }

    public enum Destination: Equatable, Sendable {
        case before(UUID)
        case end
    }

    public static func moving(
        _ source: UUID,
        before target: UUID,
        in ordered: [UUID]
    ) -> [UUID]? {
        moving(source, to: .before(target), in: ordered)
    }

    public static func moving(
        _ source: UUID,
        to destination: Destination,
        in ordered: [UUID]
    ) -> [UUID]? {
        guard let from = ordered.firstIndex(of: source) else { return nil }
        var ids = ordered
        switch destination {
        case let .before(target):
            guard source != target, let to = ordered.firstIndex(of: target) else { return nil }
            ids.remove(at: from)
            let insertion = from < to ? to - 1 : to
            ids.insert(source, at: insertion)
        case .end:
            ids.remove(at: from)
            ids.append(source)
        }
        return ids == ordered ? nil : ids
    }

    /// Shift `source` by a whole number of visual lanes. Used by the month
    /// cell drag, which has a reliable start/end delta but not a drop target.
    public static func moving(
        _ source: UUID,
        byLanes shift: Int,
        in ordered: [UUID]
    ) -> [UUID]? {
        guard let from = ordered.firstIndex(of: source), shift != 0 else { return nil }
        let to = min(max(from + shift, 0), ordered.count - 1)
        guard to != from else { return nil }
        var ids = ordered
        ids.remove(at: from)
        ids.insert(source, at: to)
        return ids
    }

    /// Drop-on-item for Transferable rows: dragging downward past a target
    /// inserts after it; dragging upward inserts before it.
    public static func destination(
        moving source: UUID,
        onto target: UUID,
        in ordered: [UUID]
    ) -> Destination? {
        guard source != target,
              let from = ordered.firstIndex(of: source),
              let to = ordered.firstIndex(of: target)
        else { return nil }
        if from < to {
            let after = to + 1
            return after < ordered.count ? .before(ordered[after]) : .end
        }
        return .before(target)
    }

    /// Which untimed item a lane hit should land on, among visible segments
    /// covering `column`. Timed / multi-day / recurring chips are skipped.
    public static func destination(
        lane: Int,
        column: Int,
        segments: [WeekSegment]
    ) -> Destination? {
        let covering = segments
            .filter { $0.startColumn <= column && column <= $0.endColumn }
            .sorted { $0.lane < $1.lane }
        let reorderable = covering.compactMap { segment -> (lane: Int, id: UUID)? in
            guard case let .item(item) = segment.entry, isReorderable(item) else { return nil }
            return (segment.lane, item.id)
        }
        guard !reorderable.isEmpty else { return nil }
        if let hit = reorderable.first(where: { $0.lane == lane }) {
            return .before(hit.id)
        }
        if let first = reorderable.first, lane < first.lane {
            return .before(first.id)
        }
        if let last = reorderable.last, lane > last.lane {
            return .end
        }
        return nil
    }

    /// Midpoint insertion: pointer above an item's mid → before it;
    /// below the last item's mid → end. Dragging onto the next chip's
    /// lower half therefore moves past it instead of no-opping.
    public static func destination(
        yInLaneArea: Double,
        lanePitch: Double,
        column: Int,
        segments: [WeekSegment]
    ) -> Destination? {
        let covering = segments
            .filter { $0.startColumn <= column && column <= $0.endColumn }
            .sorted { $0.lane < $1.lane }
        let reorderable = covering.compactMap { segment -> (lane: Int, id: UUID)? in
            guard case let .item(item) = segment.entry, isReorderable(item) else { return nil }
            return (segment.lane, item.id)
        }
        guard !reorderable.isEmpty, lanePitch > 0 else { return nil }
        for item in reorderable {
            let midpoint = (Double(item.lane) + 0.5) * lanePitch
            if yInLaneArea < midpoint {
                return .before(item.id)
            }
        }
        return .end
    }
}
