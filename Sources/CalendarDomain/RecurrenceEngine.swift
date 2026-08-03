import Foundation

public struct CalendarDateRange: Equatable, Sendable {
    public let start: CalendarDate
    public let end: CalendarDate

    public init(start: CalendarDate, end: CalendarDate) {
        precondition(end >= start, "CalendarDateRange end must not precede start.")
        self.start = start
        self.end = end
    }
}

public enum RecurrenceEngine {
    public static func occurrences(
        of series: WeeklySeries,
        in range: CalendarDateRange,
        exceptions: [OccurrenceKey: OccurrenceExceptionKind],
        completions: [OccurrenceKey: OccurrenceCompletion]
    ) -> [CalendarOccurrence] {
        let projectionStart = series.ruleStartDate
        let projectionEnd = min(series.recurrenceEndDate ?? range.end, range.end)
        var consumedKeys = Set<OccurrenceKey>()
        var occurrencesByKey = [OccurrenceKey: CalendarOccurrence]()

        if projectionStart <= projectionEnd {
            var date = projectionStart
            while date <= projectionEnd {
                guard series.weekdays.contains(date.weekday) else {
                    date = date.addingDays(1)
                    continue
                }

                let key = OccurrenceKey(seriesID: series.id, originalDate: date)
                consumedKeys.insert(key)
                switch exceptions[key] {
                case .skipped:
                    break
                case let .modified(override):
                    let occurrence = makeOccurrence(
                        key: key,
                        series: series,
                        override: override,
                        completions: completions
                    )
                    if range.intersects(occurrence.schedule) {
                        occurrencesByKey[key] = occurrence
                    }
                case nil:
                    let occurrence = makeOccurrence(
                        key: key,
                        series: series,
                        override: nil,
                        completions: completions
                    )
                    if range.intersects(occurrence.schedule) {
                        occurrencesByKey[key] = occurrence
                    }
                }

                date = date.addingDays(1)
            }
        }

        for (key, exception) in exceptions {
            guard key.seriesID == series.id,
                  !consumedKeys.contains(key),
                  case let .modified(override) = exception
            else {
                continue
            }
            let occurrence = makeOccurrence(
                key: key,
                series: series,
                override: override,
                completions: completions
            )
            guard range.intersects(occurrence.schedule) else {
                continue
            }
            occurrencesByKey[key] = occurrence
        }

        return occurrencesByKey.values.sorted(by: isOrderedBefore)
    }

    private static func makeOccurrence(
        key: OccurrenceKey,
        series: WeeklySeries,
        override: OccurrenceOverride?,
        completions: [OccurrenceKey: OccurrenceCompletion]
    ) -> CalendarOccurrence {
        let title = override?.title ?? series.title
        let kind = override?.kind ?? series.kind
        let categoryID = override?.categoryID ?? series.categoryID
        let schedule: CalendarSchedule
        if let override {
            schedule = override.displayedSchedule
        } else {
            schedule = try! CalendarSchedule(
                startDate: key.originalDate,
                endDate: key.originalDate.addingDays(series.durationDays - 1),
                startTime: series.startTime,
                endTime: series.endTime
            )
        }
        let completedAt = kind == .task ? completions[key]?.completedAt : nil

        return CalendarOccurrence(
            key: key,
            schedule: schedule,
            title: title,
            kind: kind,
            categoryID: categoryID,
            creationTimeZoneIdentifier: series.creationTimeZoneIdentifier,
            completedAt: completedAt,
            createdAt: series.createdAt
        )
    }

    private static func isOrderedBefore(
        _ lhs: CalendarOccurrence,
        _ rhs: CalendarOccurrence
    ) -> Bool {
        if lhs.schedule.startDate != rhs.schedule.startDate {
            return lhs.schedule.startDate < rhs.schedule.startDate
        }

        switch (lhs.schedule.startTime, rhs.schedule.startTime) {
        case (nil, .some):
            return true
        case (.some, nil):
            return false
        case let (.some(lhsStartTime), .some(rhsStartTime)) where lhsStartTime != rhsStartTime:
            return lhsStartTime < rhsStartTime
        default:
            return lhs.key.originalDate < rhs.key.originalDate
        }
    }
}

private extension CalendarDateRange {
    func intersects(_ schedule: CalendarSchedule) -> Bool {
        schedule.startDate <= end && start <= schedule.endDate
    }
}
