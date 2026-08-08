import CalendarDomain
import CoreGraphics
import Foundation

/// Pure helpers for week-grid drag (timed + all-day).
enum WeekGridDrag {
    static let edgeSlop: CGFloat = 10
    static let snapMinutes = 15
    static let minDurationMinutes = 15

    enum Kind: Equatable {
        case move
        case resizeStart
        case resizeEnd
    }

    static func kind(localY: CGFloat, blockHeight: CGFloat) -> Kind {
        if blockHeight >= edgeSlop * 2.5 {
            if localY <= edgeSlop { return .resizeStart }
            if localY >= blockHeight - edgeSlop { return .resizeEnd }
        }
        return .move
    }

    static func snap(_ minute: Int) -> Int {
        let clamped = min(24 * 60 - minDurationMinutes, max(0, minute))
        return (clamped / snapMinutes) * snapMinutes
    }

    static func minute(atY y: CGFloat, hourHeight: CGFloat = WeekTimeGridMetrics.hourHeight) -> Int {
        guard hourHeight > 0 else { return 0 }
        let raw = Int((y / hourHeight) * 60.0)
        return snap(raw)
    }

    static func dayIndex(
        atX x: CGFloat,
        gutterWidth: CGFloat = WeekTimeGridMetrics.gutterWidth,
        dayWidth: CGFloat
    ) -> Int {
        guard dayWidth > 0 else { return 0 }
        let rel = x - gutterWidth
        return min(6, max(0, Int(floor(rel / dayWidth))))
    }

    /// Build a same-day (or overnight) timed schedule from a day column + minute band.
    static func timedSchedule(
        day: CalendarDate,
        startMinute: Int,
        endMinute: Int
    ) throws -> CalendarSchedule {
        let start = snap(startMinute)
        var end = max(start + minDurationMinutes, snap(endMinute))
        if end > 24 * 60 {
            end = 24 * 60
        }
        if end <= start {
            end = min(24 * 60, start + minDurationMinutes)
        }
        if end >= 24 * 60, start < 24 * 60 {
            // Ends at midnight → end day next, 00:00
            return try CalendarSchedule(
                startDate: day,
                endDate: day.addingDays(1),
                startTime: MinuteOfDay(hour: start / 60, minute: start % 60)!,
                endTime: MinuteOfDay(hour: 0, minute: 0)!
            )
        }
        if end > 24 * 60 {
            let overflow = end - 24 * 60
            return try CalendarSchedule(
                startDate: day,
                endDate: day.addingDays(1),
                startTime: MinuteOfDay(hour: start / 60, minute: start % 60)!,
                endTime: MinuteOfDay(hour: overflow / 60, minute: overflow % 60)!
            )
        }
        return try CalendarSchedule(
            startDate: day,
            endDate: day,
            startTime: MinuteOfDay(hour: start / 60, minute: start % 60)!,
            endTime: MinuteOfDay(hour: end / 60, minute: end % 60)!
        )
    }

    static func previewTimed(
        original: CalendarSchedule,
        kind: Kind,
        day: CalendarDate,
        grabStartMinute: Int,
        pointerMinute: Int
    ) throws -> CalendarSchedule {
        let origStart = original.startTime?.value ?? 9 * 60
        let origEnd: Int = {
            if original.startDate == original.endDate {
                return original.endTime?.value ?? (origStart + 60)
            }
            // Overnight / multi-day timed: treat as start-day band for drag on first segment.
            if original.endTime?.value == 0 {
                return 24 * 60
            }
            return original.endTime.map { 24 * 60 + $0.value } ?? (origStart + 60)
        }()
        let duration = max(minDurationMinutes, origEnd - origStart)

        switch kind {
        case .move:
            let delta = pointerMinute - grabStartMinute
            let newStart = snap(origStart + delta)
            let newEnd = newStart + duration
            return try timedSchedule(day: day, startMinute: newStart, endMinute: newEnd)
        case .resizeStart:
            let newStart = min(pointerMinute, origEnd - minDurationMinutes)
            return try timedSchedule(day: day, startMinute: newStart, endMinute: origEnd)
        case .resizeEnd:
            let newEnd = max(pointerMinute, origStart + minDurationMinutes)
            return try timedSchedule(day: day, startMinute: origStart, endMinute: newEnd)
        }
    }

    static func previewAllDay(
        original: CalendarSchedule,
        dayDelta: Int
    ) throws -> CalendarSchedule {
        try original.shifted(byDays: dayDelta)
    }

    static func operation(for kind: Kind) -> CalendarRangeMutationOperation {
        switch kind {
        case .move: .move
        case .resizeStart: .resizeLeading
        case .resizeEnd: .resizeTrailing
        }
    }
}

// MARK: - Empty-grid create selection (drag a time band → quick create)

/// Pure helpers for “drag empty week-grid slots to create a timed item”.
enum WeekGridCreateSelection {
    static let dragThreshold: CGFloat = 6
    static let defaultDurationMinutes = 60

    struct Band: Equatable, Sendable {
        /// Day column 0...6 within the focused week.
        let dayIndex: Int
        /// Inclusive start, minutes from midnight (0...1425).
        let startMinute: Int
        /// Exclusive end, minutes from midnight (15...1440).
        let endMinute: Int

        var durationMinutes: Int { max(0, endMinute - startMinute) }
    }

    struct Intent: Equatable, Sendable {
        let day: CalendarDate
        let startTime: MinuteOfDay
        let endTime: MinuteOfDay
        let endDate: CalendarDate
    }

    /// Whether the pointer has moved enough to treat the gesture as a range drag.
    static func isRangeDrag(
        from origin: CGPoint,
        to current: CGPoint,
        threshold: CGFloat = dragThreshold
    ) -> Bool {
        hypot(current.x - origin.x, current.y - origin.y) >= threshold
    }

    /// Build a same-day create band from origin + current pointer minutes.
    ///
    /// - Single click / no drag: default 1-hour block from origin.
    /// - Drag: span between origin and current, snapped, min duration 15m.
    /// Day column is locked to the press origin (vertical multi-slot select).
    static func band(
        originDayIndex: Int,
        originMinute: Int,
        currentMinute: Int,
        isDragging: Bool,
        defaultDurationMinutes: Int = defaultDurationMinutes,
        minDurationMinutes: Int = WeekGridDrag.minDurationMinutes,
        snapMinutes: Int = WeekGridDrag.snapMinutes
    ) -> Band {
        let day = min(6, max(0, originDayIndex))
        let origin = WeekGridDrag.snap(originMinute)
        if !isDragging {
            let start = origin
            let end = min(24 * 60, start + max(minDurationMinutes, defaultDurationMinutes))
            // Near end of day: shrink rather than overflowing past midnight on click.
            let clampedStart = min(start, 24 * 60 - minDurationMinutes)
            return Band(
                dayIndex: day,
                startMinute: clampedStart,
                endMinute: max(clampedStart + minDurationMinutes, end)
            )
        }

        let current = WeekGridDrag.snap(currentMinute)
        let start = min(origin, current)
        var end = max(origin, current)
        // Dragging within the same snap cell still needs a visible duration.
        if end <= start {
            end = min(24 * 60, start + minDurationMinutes)
        }
        // Align to snap grid: if end == start after snap of a tiny drag upward,
        // the branch above already ensures min duration.
        _ = snapMinutes
        return Band(dayIndex: day, startMinute: start, endMinute: end)
    }

    static func intent(dayStarts: [CalendarDate], band: Band) throws -> Intent {
        guard dayStarts.indices.contains(band.dayIndex) else {
            throw WeekGridCreateSelectionError.invalidDayIndex
        }
        let day = dayStarts[band.dayIndex]
        let schedule = try WeekGridDrag.timedSchedule(
            day: day,
            startMinute: band.startMinute,
            endMinute: band.endMinute
        )
        guard let startTime = schedule.startTime, let endTime = schedule.endTime else {
            throw WeekGridCreateSelectionError.missingTimes
        }
        return Intent(
            day: day,
            startTime: startTime,
            endTime: endTime,
            endDate: schedule.endDate
        )
    }

    /// Frame of the selection band in grid-local coordinates (origin at top-leading of timed grid).
    static func bandFrame(
        band: Band,
        gutterWidth: CGFloat = WeekTimeGridMetrics.gutterWidth,
        dayWidth: CGFloat,
        hourHeight: CGFloat = WeekTimeGridMetrics.hourHeight
    ) -> CGRect {
        let x = gutterWidth + CGFloat(band.dayIndex) * dayWidth + 2
        let y = WeekTimeGridMetrics.yOffset(minute: band.startMinute)
        let height = WeekTimeGridMetrics.blockHeight(
            startMinute: band.startMinute,
            endMinute: band.endMinute
        )
        return CGRect(x: x, y: y, width: max(24, dayWidth - 4), height: height)
    }
}

enum WeekGridCreateSelectionError: Error {
    case invalidDayIndex
    case missingTimes
}
