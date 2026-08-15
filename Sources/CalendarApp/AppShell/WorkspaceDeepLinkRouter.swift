import Combine
import CalendarDomain
import Foundation
import WorkspaceDomain

enum WorkspaceDeepLinkTarget: Equatable, Hashable, Sendable {
    case calendarItem(UUID)
    case calendarSeries(UUID)
    case calendarOccurrence(OccurrenceKey)
    case note(NoteID)
    case inspiration(InspirationID)

    var route: WorkspaceRoute {
        switch self {
        case .calendarItem, .calendarSeries, .calendarOccurrence: .calendar
        case .note: .notes
        case .inspiration: .inspiration
        }
    }
}

struct WorkspaceDeepLinkRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let target: WorkspaceDeepLinkTarget

    init(id: UUID = UUID(), target: WorkspaceDeepLinkTarget) {
        self.id = id
        self.target = target
    }
}

@MainActor
final class WorkspaceDeepLinkRouter: ObservableObject {
    @Published private(set) var pendingRequest: WorkspaceDeepLinkRequest?

    @discardableResult
    func request(_ target: WorkspaceDeepLinkTarget) -> WorkspaceDeepLinkRequest {
        let request = WorkspaceDeepLinkRequest(target: target)
        pendingRequest = request
        return request
    }

    func consume(
        _ id: UUID,
        target: WorkspaceDeepLinkTarget
    ) -> WorkspaceDeepLinkRequest? {
        guard let request = pendingRequest,
              request.id == id,
              request.target == target else { return nil }
        pendingRequest = nil
        return request
    }
}

enum CalendarDeepLinkTargetResolver {
    static func occurrence(
        for key: OccurrenceKey,
        calendar: CalendarState
    ) -> CalendarOccurrence? {
        guard let series = calendar.recurrence.series[key.seriesID] else { return nil }
        let naturalEnd = key.originalDate.addingDays(series.durationDays - 1)
        var rangeStart = key.originalDate
        var rangeEnd = naturalEnd
        if case let .modified(override) = calendar.recurrence.exceptions[key] {
            rangeStart = min(rangeStart, override.displayedSchedule.startDate)
            rangeEnd = max(rangeEnd, override.displayedSchedule.endDate)
        }
        return RecurrenceEngine.occurrences(
            of: series,
            in: .init(start: rangeStart, end: rangeEnd),
            exceptions: calendar.recurrence.exceptions,
            completions: calendar.recurrence.completions
        ).first { $0.key == key }
    }

    static func representativeOccurrence(
        for seriesID: UUID,
        calendar: CalendarState,
        today: CalendarDate
    ) -> CalendarOccurrence? {
        guard let series = calendar.recurrence.series[seriesID] else { return nil }
        let skippedCount = calendar.recurrence.exceptions.reduce(into: 0) { count, entry in
            guard entry.key.seriesID == seriesID, case .skipped = entry.value else { return }
            count += 1
        }
        let searchDays = max(14, (skippedCount + 2) * 7)
        let futureStart = max(today, series.ruleStartDate)
        let futureEnd = min(series.recurrenceEndDate ?? futureStart.addingDays(searchDays), futureStart.addingDays(searchDays))
        if futureEnd >= futureStart,
           let future = projectedOccurrences(of: series, calendar: calendar, from: futureStart, through: futureEnd).first {
            return future
        }

        guard let historicalEnd = series.recurrenceEndDate, historicalEnd < futureStart else { return nil }
        let historicalStart = max(series.ruleStartDate, historicalEnd.addingDays(-searchDays))
        return projectedOccurrences(
            of: series,
            calendar: calendar,
            from: historicalStart,
            through: historicalEnd
        ).last
    }

    private static func projectedOccurrences(
        of series: WeeklySeries,
        calendar: CalendarState,
        from start: CalendarDate,
        through end: CalendarDate
    ) -> [CalendarOccurrence] {
        RecurrenceEngine.occurrences(
            of: series,
            in: .init(start: start, end: end),
            exceptions: calendar.recurrence.exceptions,
            completions: calendar.recurrence.completions
        )
    }
}
