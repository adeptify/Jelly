import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CalendarApp

@Suite("CalendarThemeTests")
struct CalendarThemeTests {
    @Test func lightAndDarkThemesUseExactWarmSemanticRolesWithReadableText() throws {
        #expect(CalendarTheme.light.canvasHex == "#F7F1E7")
        #expect(CalendarTheme.dark.canvasHex == "#211E1B")
        #expect(CalendarTheme.previewLightCanvasHex == CalendarTheme.light.canvasHex)
        #expect(CalendarTheme.previewDarkCanvasHex == CalendarTheme.dark.canvasHex)
        #expect(CalendarTheme.previewLightTextHex == CalendarTheme.light.primaryTextHex)
        #expect(CalendarTheme.previewDarkTextHex == CalendarTheme.dark.primaryTextHex)

        #expect(CalendarTheme.light.elevatedSurfaceHex == "#FFF9F0")
        #expect(CalendarTheme.dark.elevatedSurfaceHex == "#2B2723")
        #expect(CalendarTheme.light.separatorHex == "#D8CEC1")
        #expect(CalendarTheme.dark.separatorHex == "#4A433D")
        #expect(CalendarTheme.light.primaryTextHex == "#2A2420")
        #expect(CalendarTheme.dark.primaryTextHex == "#F4EDE4")
        #expect(CalendarTheme.light.secondaryTextHex == "#6D625B")
        #expect(CalendarTheme.dark.secondaryTextHex == "#C5B9AD")
        #expect(CalendarTheme.light.todayFillHex == "#E8C3A9")
        #expect(CalendarTheme.dark.todayFillHex == "#604536")
        #expect(CalendarTheme.light.selectionFillHex == "#DDE5E1")
        #expect(CalendarTheme.dark.selectionFillHex == "#394640")
        #expect(CalendarTheme.light.rangePreviewFillHex == "#E8D8C4")
        #expect(CalendarTheme.dark.rangePreviewFillHex == "#493C30")
        #expect(CalendarTheme.light.dragPreviewFillHex == "#D9E4E1")
        #expect(CalendarTheme.dark.dragPreviewFillHex == "#324946")

        for appearance in [CalendarTheme.light, CalendarTheme.dark] {
            #expect(appearance.primaryTextContrast >= 4.5)
            #expect(appearance.secondaryTextContrast >= 4.5)
            #expect(appearance.semanticHexValues.allSatisfy { $0.hasPrefix("#") && $0.count == 7 })
            #expect(!appearance.semanticHexValues.contains("#FFFFFF"))
            #expect(!appearance.semanticHexValues.contains("#000000"))
        }
    }

    @Test func reducedMotionRemovesAnimationWithoutRemovingWeekAlignmentOrOverlayStateChanges() {
        let reduced = CalendarMotionPolicy(reduceMotion: true)
        #expect(reduced.snapAnimation == nil)
        #expect(reduced.overlayAnimation == nil)
        #expect(reduced.centeringSettleDelay == nil)
        #expect(reduced.shouldAlignToWeek)
        #expect(reduced.shouldPresentOverlays)

        let standard = CalendarMotionPolicy(reduceMotion: false)
        #expect(standard.snapAnimation != nil)
        #expect(standard.overlayAnimation != nil)
        #expect(standard.centeringSettleDelay == .milliseconds(180))
        #expect(standard.shouldAlignToWeek)
        #expect(standard.shouldPresentOverlays)
    }

    @Test func productionSurfacesConsumeSemanticTokensAndWireReducedMotionEnvironment() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let relativeSources = [
            "Sources/CalendarApp/Month/MonthView.swift",
            "Sources/CalendarApp/Month/WeekRowView.swift",
            "Sources/CalendarApp/Month/CalendarItemRow.swift",
            "Sources/CalendarApp/Editing/QuickCreatePopover.swift",
            "Sources/CalendarApp/Editing/ItemDetailPopover.swift",
            "Sources/CalendarApp/Categories/CategoryManagerView.swift"
        ]
        let forbiddenSurfaceLiterals = [
            "Color.accentColor", ".windowBackgroundColor", ".controlBackgroundColor",
            ".regularMaterial", "#FFFFFF", "#000000", "#1E1A18"
        ]

        for relativeSource in relativeSources {
            let source = try String(contentsOf: root.appending(path: relativeSource), encoding: .utf8)
            #expect(source.contains("CalendarTheme"))
            for forbidden in forbiddenSurfaceLiterals {
                #expect(!source.contains(forbidden), "\(relativeSource) contains \(forbidden)")
            }
        }

        let monthView = try String(
            contentsOf: root.appending(path: relativeSources[0]),
            encoding: .utf8
        )
        #expect(monthView.contains("@Environment(\\.accessibilityReduceMotion)"))
        #expect(monthView.contains("CalendarMotionPolicy(reduceMotion: accessibilityReduceMotion)"))
        #expect(monthView.contains("let animation = motionPolicy.snapAnimation"))
        #expect(monthView.contains("withAnimation(animation)"))
        #expect(monthView.contains("withAnimation(motionPolicy.overlayAnimation)"))
        #expect(monthView.contains("transaction.disablesAnimations = true"))
        #expect(monthView.contains("appearance-preference-toggle"))
        #expect(monthView.contains("CalendarAppearancePreference.storageKey"))
    }

    @Test func appearancePreferenceMapsToColorSchemeAndApplicationAppearance() {
        #expect(CalendarAppearancePreference.system.preferredColorScheme == nil)
        #expect(CalendarAppearancePreference.light.preferredColorScheme == .light)
        #expect(CalendarAppearancePreference.dark.preferredColorScheme == .dark)

        #expect(CalendarAppearancePreference.system.nsAppearance == nil)
        #expect(CalendarAppearancePreference.light.nsAppearance?.name == .aqua)
        #expect(CalendarAppearancePreference.dark.nsAppearance?.name == .darkAqua)

        #expect(CalendarAppearancePreference.system.title == "跟随系统")
        #expect(CalendarAppearancePreference.light.title == "浅色")
        #expect(CalendarAppearancePreference.dark.title == "深色")
        #expect(CalendarAppearancePreference.storageKey == "calendar.appearancePreference")
        #expect(CalendarAppearancePreference.allCases.map(\.rawValue) == ["system", "light", "dark"])

        #expect(CalendarAppearancePreference.light.toggled(renderedAs: .light) == .dark)
        #expect(CalendarAppearancePreference.dark.toggled(renderedAs: .dark) == .light)
        #expect(CalendarAppearancePreference.system.toggled(renderedAs: .dark) == .light)
        #expect(CalendarAppearancePreference.system.toggled(renderedAs: .light) == .dark)
        #expect(CalendarAppearancePreference.light.toggleSymbolName == "moon")
        #expect(CalendarAppearancePreference.dark.toggleSymbolName == "sun.max")
    }
}
