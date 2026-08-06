import CalendarDomain
import Foundation

/// Period for “进展总结”: natural week/month containing today, clipped to today.
enum ProgressSummaryPeriod: String, Equatable, Sendable {
    case week
    case month

    var title: String {
        switch self {
        case .week: "本周进展"
        case .month: "本月进展"
        }
    }

    var shortLabel: String {
        switch self {
        case .week: "本周"
        case .month: "本月"
        }
    }
}

struct ProgressSummaryRange: Equatable, Sendable {
    let period: ProgressSummaryPeriod
    let start: CalendarDate
    let end: CalendarDate
    let today: CalendarDate

    var dayCount: Int {
        max(1, start.days(until: end) + 1)
    }

    var rangeCaption: String {
        if start.year == end.year, start.month == end.month {
            return "\(start.year)年\(start.month)月\(start.day)日 – \(end.day)日"
        }
        if start.year == end.year {
            return "\(start.year)年\(start.month)月\(start.day)日 – \(end.month)月\(end.day)日"
        }
        return "\(start.year)年\(start.month)月\(start.day)日 – \(end.year)年\(end.month)月\(end.day)日"
    }

    /// From the first day of the natural week/month that contains `today`, through `today`.
    static func current(period: ProgressSummaryPeriod, today: CalendarDate) -> ProgressSummaryRange {
        switch period {
        case .week:
            let start = WeekStreamModel.weekStart(containing: today)
            return ProgressSummaryRange(period: .week, start: start, end: today, today: today)
        case .month:
            let start = CalendarDate(year: today.year, month: today.month, day: 1)
                ?? today
            return ProgressSummaryRange(period: .month, start: start, end: today, today: today)
        }
    }
}

struct ProgressCategoryStat: Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let colorHex: String
    let total: Int
    let completed: Int

    var completionRate: Double {
        total == 0 ? 0 : Double(completed) / Double(total)
    }
}

struct ProgressSummaryStats: Equatable, Sendable {
    let range: ProgressSummaryRange
    let totalItems: Int
    let completedItems: Int
    let openItems: Int
    let highPriorityOpen: Int
    let categories: [ProgressCategoryStat]

    var completionRate: Double {
        totalItems == 0 ? 0 : Double(completedItems) / Double(totalItems)
    }

    var completionPercent: Int {
        Int((completionRate * 100).rounded())
    }
}

struct ProgressCategoryNarrative: Equatable, Sendable, Identifiable {
    var id: String { name + colorHex }
    let name: String
    let colorHex: String
    let body: String
}

/// Structured report ready for UI (mock or real AI).
struct ProgressSummaryReport: Equatable, Sendable {
    let stats: ProgressSummaryStats
    let highlights: String
    let categorySections: [ProgressCategoryNarrative]
    let encouragement: String
    /// True when text is locally synthesized (prologue not wired yet).
    let isMockAI: Bool
    let generatedAt: Date
}

enum ProgressSummaryPhase: Equatable {
    case idle
    case loading
    case ready(ProgressSummaryReport)
    case failed(String)
}
