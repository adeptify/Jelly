import Foundation

enum CalendarPrimaryViewMode: String, CaseIterable, Identifiable, Sendable {
    case month
    case week

    static let storageKey = "calendar.primaryViewMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .month: "月"
        case .week: "周"
        }
    }

    var help: String {
        switch self {
        case .month: "连续月历（周流）"
        case .week: "周视图（按小时看日程）"
        }
    }
}
