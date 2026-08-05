import AppKit
import SwiftUI

/// User-selectable appearance for the whole app (independent of system setting).
enum CalendarAppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    static let storageKey = "calendar.appearancePreference"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var symbolName: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    /// `nil` means follow the system color scheme.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    static func applyToApplication(_ preference: CalendarAppearancePreference) {
        NSApp.appearance = preference.nsAppearance
    }
}
