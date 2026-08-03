import AppKit
import SwiftUI

struct CalendarSemanticAppearance: Equatable, Sendable {
    let canvasHex: String
    let elevatedSurfaceHex: String
    let separatorHex: String
    let primaryTextHex: String
    let secondaryTextHex: String
    let todayFillHex: String
    let todayOutlineHex: String
    let selectionFillHex: String
    let selectionOutlineHex: String
    let rangePreviewFillHex: String
    let rangePreviewOutlineHex: String
    let dragPreviewFillHex: String
    let dragPreviewOutlineHex: String
    let subtleBorderHex: String
    let subtleShadowHex: String
    let controlAccentHex: String
    let errorHex: String

    var semanticHexValues: [String] {
        [
            canvasHex, elevatedSurfaceHex, separatorHex, primaryTextHex, secondaryTextHex,
            todayFillHex, todayOutlineHex, selectionFillHex, selectionOutlineHex,
            rangePreviewFillHex, rangePreviewOutlineHex, dragPreviewFillHex,
            dragPreviewOutlineHex, subtleBorderHex, subtleShadowHex, controlAccentHex, errorHex
        ]
    }

    var primaryTextContrast: Double {
        contrast(foreground: primaryTextHex, background: canvasHex)
    }

    var secondaryTextContrast: Double {
        contrast(foreground: secondaryTextHex, background: canvasHex)
    }

    var canvas: Color { CalendarTheme.categoryColor(canvasHex) }
    var elevatedSurface: Color { CalendarTheme.categoryColor(elevatedSurfaceHex) }
    var separator: Color { CalendarTheme.categoryColor(separatorHex) }
    var primaryText: Color { CalendarTheme.categoryColor(primaryTextHex) }
    var secondaryText: Color { CalendarTheme.categoryColor(secondaryTextHex) }
    var todayFill: Color { CalendarTheme.categoryColor(todayFillHex) }
    var todayOutline: Color { CalendarTheme.categoryColor(todayOutlineHex) }
    var selectionFill: Color { CalendarTheme.categoryColor(selectionFillHex) }
    var selectionOutline: Color { CalendarTheme.categoryColor(selectionOutlineHex) }
    var rangePreviewFill: Color { CalendarTheme.categoryColor(rangePreviewFillHex) }
    var rangePreviewOutline: Color { CalendarTheme.categoryColor(rangePreviewOutlineHex) }
    var dragPreviewFill: Color { CalendarTheme.categoryColor(dragPreviewFillHex) }
    var dragPreviewOutline: Color { CalendarTheme.categoryColor(dragPreviewOutlineHex) }
    var subtleBorder: Color { CalendarTheme.categoryColor(subtleBorderHex) }
    var subtleShadow: Color { CalendarTheme.categoryColor(subtleShadowHex) }
    var controlAccent: Color { CalendarTheme.categoryColor(controlAccentHex) }
    var error: Color { CalendarTheme.categoryColor(errorHex) }

    private func contrast(foreground: String, background: String) -> Double {
        guard let foregroundColor = try? SRGBColor(hex: foreground),
              let backgroundColor = try? SRGBColor(hex: background)
        else {
            return 0
        }
        return foregroundColor.contrastRatio(with: backgroundColor)
    }
}

struct CalendarMotionPolicy {
    let reduceMotion: Bool

    // Keep viewport observation paused until the standard centering animation has
    // produced a stable frame. Reduced Motion skips the interpolation entirely.
    var centeringSettleDelay: Duration? {
        reduceMotion ? nil : .milliseconds(180)
    }

    var snapAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.16)
    }

    var overlayAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.14)
    }

    // Reducing motion removes interpolation, never the resulting navigation or editor state.
    var shouldAlignToWeek: Bool { true }
    var shouldPresentOverlays: Bool { true }
}

enum CalendarTheme {
    static let light = CalendarSemanticAppearance(
        canvasHex: "#F7F1E7",
        elevatedSurfaceHex: "#FFF9F0",
        separatorHex: "#D8CEC1",
        primaryTextHex: "#2A2420",
        secondaryTextHex: "#6D625B",
        todayFillHex: "#E8C3A9",
        todayOutlineHex: "#A85F3D",
        selectionFillHex: "#DDE5E1",
        selectionOutlineHex: "#6B8177",
        rangePreviewFillHex: "#E8D8C4",
        rangePreviewOutlineHex: "#A97E5F",
        dragPreviewFillHex: "#D9E4E1",
        dragPreviewOutlineHex: "#4D7772",
        subtleBorderHex: "#CBBEAF",
        subtleShadowHex: "#3A3028",
        controlAccentHex: "#A55D3B",
        errorHex: "#A33E33"
    )

    static let dark = CalendarSemanticAppearance(
        canvasHex: "#211E1B",
        elevatedSurfaceHex: "#2B2723",
        separatorHex: "#4A433D",
        primaryTextHex: "#F4EDE4",
        secondaryTextHex: "#C5B9AD",
        todayFillHex: "#604536",
        todayOutlineHex: "#E1A27D",
        selectionFillHex: "#394640",
        selectionOutlineHex: "#98B0A3",
        rangePreviewFillHex: "#493C30",
        rangePreviewOutlineHex: "#C9966B",
        dragPreviewFillHex: "#324946",
        dragPreviewOutlineHex: "#72AAA1",
        subtleBorderHex: "#554C44",
        subtleShadowHex: "#120F0D",
        controlAccentHex: "#D68D68",
        errorHex: "#F0A097"
    )

    // Category rendering and its preview window share these exact semantic surfaces.
    static let previewLightCanvasHex = light.canvasHex
    static let previewLightTextHex = light.primaryTextHex
    static let previewDarkCanvasHex = dark.canvasHex
    static let previewDarkTextHex = dark.primaryTextHex
    static let categoryItemBackgroundOpacity = 0.14
    static let categoryTextMinimumContrast = 4.5
    static let categoryAccentMinimumContrast = 3.0

    static let toolbarHeight: CGFloat = 52
    static let weekdayHeaderHeight: CGFloat = 28
    static let cellPadding: CGFloat = 6
    static let itemRowHeight: CGFloat = 21
    static let itemSpacing: CGFloat = 3
    static let cornerRadius: CGFloat = 5
    static let monthTitleFont = Font.system(size: 17, weight: .semibold)
    static let dateFont = Font.system(size: 12)
    static let itemFont = Font.system(size: 12)

    static func appearance(for colorScheme: ColorScheme) -> CalendarSemanticAppearance {
        colorScheme == .dark ? dark : light
    }

    static func itemBackground(_ category: Color) -> Color {
        category.opacity(categoryItemBackgroundOpacity)
    }

    static func categoryColor(_ hex: String) -> Color {
        let text = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard text.count == 6, let value = UInt64(text, radix: 16) else {
            return appearance(for: .light).secondaryText
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

    static func categoryItemRoles(
        _ hex: String,
        isCompleted: Bool,
        appearance: CalendarAppearance
    ) -> CategoryRenderedColorRoles? {
        categoryRoles(hex, appearance: appearance)?.rendered(isCompleted: isCompleted)
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

    static func itemAccentNeedsOutline(
        _ hex: String,
        isCompletedTask: Bool,
        appearance: CalendarAppearance
    ) -> Bool {
        guard let roles = categoryItemRoles(
            hex,
            isCompleted: isCompletedTask,
            appearance: appearance
        ) else {
            return true
        }
        return roles.accentContrast < categoryAccentMinimumContrast
    }
}
