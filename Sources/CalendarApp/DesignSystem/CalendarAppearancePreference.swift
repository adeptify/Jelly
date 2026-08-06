import AppKit
import SwiftUI

/// Explicit light/dark for the app. `.system` is retained only to decode older AppStorage values.
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

    /// Icon invites the *next* action: moon → go dark, sun → go light.
    var toggleSymbolName: String {
        switch self {
        case .dark: "sun.max"
        case .light, .system: "moon"
        }
    }

    var symbolName: String { toggleSymbolName }

    /// `nil` means follow the system color scheme (legacy only).
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

    /// One-click light ↔ dark. Legacy `.system` resolves from the currently rendered scheme.
    func toggled(renderedAs colorScheme: ColorScheme) -> CalendarAppearancePreference {
        switch self {
        case .light: .dark
        case .dark: .light
        case .system: colorScheme == .dark ? .light : .dark
        }
    }

    @MainActor
    static func applyToApplication(_ preference: CalendarAppearancePreference) {
        NSApp.appearance = preference.nsAppearance
    }
}
