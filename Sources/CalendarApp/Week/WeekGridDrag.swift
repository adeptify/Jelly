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
