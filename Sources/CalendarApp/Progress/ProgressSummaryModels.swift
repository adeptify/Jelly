import CalendarDomain
import Foundation

/// Period for “进展总结”: natural week/month containing today, clipped to today.
enum ProgressSummaryPeriod: String, Equatable, Sendable {
    case week
    case month

    var title: String {
        switch self {
        case .week: "本周回顾"
        case .month: "本月回顾"
        }
    }

    var shortLabel: String {
        switch self {
        case .week: "本周"
        case .month: "本月"
        }
    }
}

/// The four factual entry points shown at the top of a review. Keeping this
/// order in the model prevents the UI from quietly drifting back to a vanity
/// metric such as completion rate.
enum ProgressSummaryOverview: String, CaseIterable, Equatable, Identifiable, Sendable {
    case completed
    case open
    case overdue
    case categories

    var id: String { rawValue }

    var title: String {
        switch self {
        case .completed: "已完成"
        case .open: "未完成"
        case .overdue: "已延期"
        case .categories: "分类分布"
        }
    }

    func value(in stats: ProgressSummaryStats) -> String {
        switch self {
        case .completed: "\(stats.completedItems)"
        case .open: "\(stats.openItems)"
        case .overdue: "\(stats.overdueItems)"
        case .categories: "\(stats.categories.count) 类"
        }
    }

    func items(in stats: ProgressSummaryStats) -> [ProgressItemFact] {
        switch self {
        case .completed:
            stats.completed
        case .open:
            stats.open
        case .overdue:
            stats.open.filter(\.isOverdue)
        case .categories:
            []
        }
    }
}

struct ProgressMigrationPrompt: Equatable, Sendable {
    let period: ProgressSummaryPeriod
    let selectedCount: Int

    private var destination: String {
        period == .week ? "下周" : "下月"
    }

    var title: String { "确认移到\(destination)？" }
    var message: String { "将选中的 \(selectedCount) 件一次性事项移到\(destination)。重复事项不会改变。" }
    var confirmationTitle: String { "确认移到\(destination)" }
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
    let overdueItems: Int
    let highPriorityOpen: Int
    let categories: [ProgressCategoryStat]
    let completed: [ProgressItemFact]
    let open: [ProgressItemFact]

    var completionRate: Double {
        totalItems == 0 ? 0 : Double(completedItems) / Double(totalItems)
    }

    var completionPercent: Int {
        Int((completionRate * 100).rounded())
    }
}

struct ProgressItemFact: Equatable, Sendable, Identifiable {
    let id: String
    let calendarItemID: UUID?
    let title: String
    let date: CalendarDate
    let isOverdue: Bool
}

/// A deterministic local report. Every sentence shown in the UI comes from
/// persisted calendar facts; no generated or simulated capability is implied.
struct ProgressSummaryReport: Equatable, Sendable {
    let stats: ProgressSummaryStats
    let factualSummary: String
}

enum ProgressSummaryPhase: Equatable {
    case idle
    case loading
    case ready(ProgressSummaryReport)
    case failed(String)
}
