import Foundation

struct WorkspaceFeatures: Equatable, Sendable {
    var notes: Bool
    var inspiration: Bool

    static let calendarOnly = Self(notes: false, inspiration: false)
    /// Notes (Task 10D) and Inspiration (Task 13) are both production-enabled.
    static let production = Self(notes: true, inspiration: true)

    func isEnabled(_ route: WorkspaceRoute) -> Bool {
        switch route {
        case .calendar:
            true
        case .notes:
            notes
        case .inspiration:
            inspiration
        }
    }
}

enum WorkspaceRoute: String, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case calendar
    case notes
    case inspiration

    var id: String { rawValue }

    static func visibleRoutes(_ features: WorkspaceFeatures) -> [WorkspaceRoute] {
        allCases.filter(features.isEnabled)
    }

    static func commandShortcut(_ key: String) -> WorkspaceRoute? {
        allCases.first { $0.commandShortcutKey == key }
    }

    var commandShortcutKey: String {
        switch self {
        case .calendar: "1"
        case .notes: "2"
        case .inspiration: "3"
        }
    }

    var railMetadata: WorkspaceRailMetadata {
        switch self {
        case .calendar:
            .init(name: "日历", symbolName: "calendar")
        case .notes:
            .init(name: "笔记", symbolName: "note.text")
        case .inspiration:
            .init(name: "灵感", symbolName: "lightbulb")
        }
    }
}

struct WorkspaceRailMetadata: Equatable, Sendable {
    let name: String
    let symbolName: String

    var help: String { name }
    var accessibilityLabel: String { name }
}

enum WorkspaceNewItemAction: Equatable, Sendable {
    case createCalendarItem
    case createNote
    case createInspiration

    init(route: WorkspaceRoute) {
        switch route {
        case .calendar: self = .createCalendarItem
        case .notes: self = .createNote
        case .inspiration: self = .createInspiration
        }
    }
}

struct WorkspaceRailAppearance: Equatable, Sendable {
    let backgroundHex: String
    let selectedTileFillHex: String
    let inactiveIconHex: String

    static let selectedAccessibilityValue = "当前页面"

    init(theme: CalendarAppearance) {
        let appearance = theme == .light ? CalendarTheme.light : CalendarTheme.dark
        backgroundHex = appearance.elevatedSurfaceHex
        selectedTileFillHex = appearance.rangePreviewFillHex
        inactiveIconHex = appearance.secondaryTextHex
    }
}
