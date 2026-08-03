import AppKit
import SwiftUI

enum CalendarTheme {
    // Fixed sRGB values make category validation and previews deterministic.
    // The runtime views below continue to use the matching semantic system colors.
    static let previewLightCanvasHex = "#F7F1E7"
    static let previewLightTextHex = "#2A2420"
    static let previewDarkCanvasHex = "#1E1A18"
    static let previewDarkTextHex = "#F4EDE4"
    static let categoryItemBackgroundOpacity = 0.14
    static let categoryTextMinimumContrast = 4.5
    static let categoryAccentMinimumContrast = 3.0
    static let completedTaskAccentOpacity = 0.45

    static let toolbarHeight: CGFloat = 52
    static let weekdayHeaderHeight: CGFloat = 28
    static let cellPadding: CGFloat = 6
    static let itemRowHeight: CGFloat = 21
    static let itemSpacing: CGFloat = 3
    static let cornerRadius: CGFloat = 5
    static let monthTitleFont = Font.system(size: 17, weight: .semibold)
    static let dateFont = Font.system(size: 12)
    static let itemFont = Font.system(size: 12)
    static let gridStroke = Color(nsColor: .separatorColor).opacity(0.55)
    static let selectedDay = Color.accentColor.opacity(0.10)
    static let completedText = Color(nsColor: .secondaryLabelColor)

    static func itemBackground(_ category: Color) -> Color {
        category.opacity(categoryItemBackgroundOpacity)
    }
    static func completedTaskBackground(_ category: Color) -> Color { category.opacity(0.07) }
    static func completedTaskAccent(_ category: Color) -> Color {
        category.opacity(completedTaskAccentOpacity)
    }

    static func categoryColor(_ hex: String) -> Color {
        let text = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard text.count == 6, let value = UInt64(text, radix: 16) else {
            return Color(nsColor: .systemGray)
        }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    static func categoryColor(_ color: SRGBColor) -> Color {
        Color(red: color.red, green: color.green, blue: color.blue)
    }

    static func categoryRoles(_ hex: String, appearance: CalendarAppearance) -> CategoryColorRoles? {
        try? CategoryColorResolver.roles(for: hex, appearance: appearance)
    }

    static func categoryAccent(_ hex: String, appearance: CalendarAppearance) -> Color {
        guard let role = categoryRoles(hex, appearance: appearance)?.accent else {
            return categoryColor(hex)
        }
        return categoryColor(role)
    }

    static func categorySoftBackground(_ hex: String, appearance: CalendarAppearance) -> Color {
        guard let roles = categoryRoles(hex, appearance: appearance) else {
            return itemBackground(categoryColor(hex))
        }
        return categoryColor(roles.softBackground)
    }

    static func categoryText(_ hex: String, appearance: CalendarAppearance) -> Color {
        guard let role = categoryRoles(hex, appearance: appearance)?.text else {
            return categoryColor(appearance == .light ? previewLightTextHex : previewDarkTextHex)
        }
        return categoryColor(role)
    }

    static func categoryOutline(_ hex: String, appearance: CalendarAppearance) -> Color {
        guard let role = categoryRoles(hex, appearance: appearance)?.outline else {
            return categoryColor(hex)
        }
        return categoryColor(role)
    }

    static func accentNeedsOutline(_ hex: String, appearance: CalendarAppearance) -> Bool {
        itemAccentNeedsOutline(hex, isCompletedTask: false, appearance: appearance)
    }

    static func itemAccentNeedsOutline(
        _ hex: String,
        isCompletedTask: Bool,
        appearance: CalendarAppearance
    ) -> Bool {
        (try? CategoryColorValidator.accentNeedsOutline(
            colorHex: hex,
            appearance: appearance,
            renderingOpacity: isCompletedTask ? completedTaskAccentOpacity : 1
        )) ?? false
    }

    static let itemAccentOutline = Color.primary
}
