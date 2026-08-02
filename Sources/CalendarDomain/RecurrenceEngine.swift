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
        let projectionStart = max(series.startDate, range.start)
        let projectionEnd = min(series.endDate ?? range.end, range.end)
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
                    if range.contains(occurrence.displayedDate) {
                        occurrencesByKey[key] = occurrence
                    }
                case nil:
                    let occurrence = makeOccurrence(
                        key: key,
                        series: series,
                        override: nil,
                        completions: completions
                    )
                    if range.contains(occurrence.displayedDate) {
                        occurrencesByKey[key] = occurrence
                    }
                }

                date = date.addingDays(1)
            }
        }

        for (key, exception) in exceptions {
            guard key.seriesID == series.id,
                  !consumedKeys.contains(key),
                  case let .modified(override) = exception,
                  range.contains(override.displayedDate)
            else {
                continue
            }
            occurrencesByKey[key] = makeOccurrence(
                key: key,
                series: series,
                override: override,
                completions: completions
            )
        }

        return occurrencesByKey.values.sorted(by: isOrderedBefore)
    }

    private static func makeOccurrence(
        key: OccurrenceKey,
        series: WeeklySeries,
        override: OccurrenceOverride?,
        completions: [OccurrenceKey: OccurrenceCompletion]
    ) -> CalendarOccurrence {
        let displayedDate = override?.displayedDate ?? key.originalDate
        let title = override?.title ?? series.title
        let kind = override?.kind ?? series.kind
        let categoryID = override?.categoryID ?? series.categoryID
        let timeRange: LocalTimeRange?
        if let override {
            timeRange = override.timeRange
        } else {
            timeRange = series.timeRange
        }
        let completedAt = kind == .task ? completions[key]?.completedAt : nil

        return CalendarOccurrence(
            key: key,
            displayedDate: displayedDate,
            title: title,
            kind: kind,
            categoryID: categoryID,
            timeRange: timeRange,
            creationTimeZoneIdentifier: series.creationTimeZoneIdentifier,
            completedAt: completedAt,
            createdAt: series.createdAt
        )
    }

    private static func isOrderedBefore(
        _ lhs: CalendarOccurrence,
        _ rhs: CalendarOccurrence
    ) -> Bool {
        if lhs.displayedDate != rhs.displayedDate {
            return lhs.displayedDate < rhs.displayedDate
        }

        switch (lhs.timeRange, rhs.timeRange) {
        case (nil, .some):
            return true
        case (.some, nil):
            return false
        case let (.some(lhsTimeRange), .some(rhsTimeRange)) where lhsTimeRange.start != rhsTimeRange.start:
            return lhsTimeRange.start < rhsTimeRange.start
        default:
            return lhs.key.originalDate < rhs.key.originalDate
        }
    }
}

private extension CalendarDateRange {
    func contains(_ date: CalendarDate) -> Bool {
        start <= date && date <= end
    }
}
