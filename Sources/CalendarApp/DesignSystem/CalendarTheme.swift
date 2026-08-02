import AppKit
import SwiftUI

enum CalendarTheme {
    // Fixed sRGB values make category validation and previews deterministic.
    // The runtime views below continue to use the matching semantic system colors.
    static let previewLightCanvasHex = "#FFFFFF"
    static let previewLightTextHex = "#1D1D1F"
    static let previewDarkCanvasHex = "#1C1C1E"
    static let previewDarkTextHex = "#F5F5F7"
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
