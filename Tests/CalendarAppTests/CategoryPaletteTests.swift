import Foundation
import Testing
@testable import CalendarApp

@Suite("CategoryPaletteTests")
struct CategoryPaletteTests {
    @Test func paletteMatchesTheExactFiveByEightDesignTable() {
        #expect(CategoryPalette.families.map(\.name) == ["基础", "马卡龙", "莫兰迪", "自然", "鲜亮"])
        #expect(CategoryPalette.families.map(\.colors) == [
            ["#4F7FFF", "#735DD0", "#D65772", "#E58B39", "#4EAC73", "#2E9EB0", "#9A7650", "#8C8F96"],
            ["#8FB8F4", "#A9A2E8", "#D7A0C5", "#F0A59A", "#F4C58C", "#E4D87D", "#9ED8C0", "#B9D69B"],
            ["#8296A8", "#B28F9B", "#B6816D", "#B6A184", "#8F9878", "#7F9B8B", "#5F889F", "#8B7867"],
            ["#4D83A6", "#3E705A", "#6F8652", "#4D8D89", "#C18A3D", "#B86549", "#81566F", "#73716B"],
            ["#3D63E9", "#7548D8", "#D43282", "#EF5E55", "#F28A24", "#83B928", "#19A86B", "#149DB4"]
        ])
        #expect(CategoryPalette.families.allSatisfy { $0.colors.count == 8 })
        #expect(Set(CategoryPalette.families.flatMap(\.colors)).count == 40)
    }

    @Test func everyFamilyAndPresetHasAChineseAccessibilityName() {
        #expect(CategoryPalette.families.allSatisfy { family in
            family.name.unicodeScalars.contains(where: { $0.properties.isIdeographic })
                && family.presets.count == 8
                && family.presets.allSatisfy { preset in
                    !preset.accessibilityName.isEmpty
                        && preset.accessibilityName != preset.hex
                        && preset.accessibilityName.unicodeScalars.contains(where: { $0.properties.isIdeographic })
                }
        })
    }

    @Test func everyPresetAndCustomExtremeProducesRealReadableRoles() throws {
        let colors = CategoryPalette.families.flatMap(\.colors) + ["#FFFFFF", "#000000"]
        for hex in colors {
            for appearance in [CalendarAppearance.light, .dark] {
                let roles = try CategoryColorResolver.roles(for: hex, appearance: appearance)
                #expect(roles.accent.contrastRatio(with: roles.softBackground) >= 3.0)
                #expect(roles.outline.contrastRatio(with: roles.softBackground) >= 3.0)
                #expect(roles.text.contrastRatio(with: roles.softBackground) >= 4.5)
                #expect(roles.accentContrast >= 3.0)
                #expect(roles.textContrast >= 4.5)
            }
        }
    }

    @Test func resolverIsDeterministicAndRejectsInvalidHex() throws {
        for appearance in [CalendarAppearance.light, .dark] {
            let first = try CategoryColorResolver.roles(for: "#F4C58C", appearance: appearance)
            let second = try CategoryColorResolver.roles(for: "#f4c58c", appearance: appearance)
            #expect(first == second)
        }
        #expect(throws: CategoryManagerError.invalidColor) {
            try CategoryColorResolver.roles(for: "F4C58C", appearance: .light)
        }
    }

    @Test func machadoFullSeverityLinearRGBSimulationMatchesIndependentReferenceVectors() throws {
        // Machado, Oliveira & Fernandes (2009), precomputed 2010 matrices,
        // severity 1.0. Expected values below were independently calculated as:
        // sRGB decode -> matrix in linear RGB -> gamut clamp -> sRGB encode.
        let samples: [(String, ColorVisionSimulation, (Double, Double, Double))] = [
            ("#FF0000", .protanopia, (0.4266084717, 0.3726542774, 0.0)),
            ("#00FF00", .protanopia, (1.0, 0.8994280662, 0.0)),
            ("#0000FF", .protanopia, (0.0, 0.3478668262, 1.0)),
            ("#FF0000", .deuteranopia, (0.6400595552, 0.5658069412, 0.0)),
            ("#00FF00", .deuteranopia, (0.9360510456, 0.8392477354, 0.2291918656)),
            ("#0000FF", .deuteranopia, (0.0, 0.2411713588, 0.9861943658))
        ]
        for (hex, simulation, expected) in samples {
            let actual = try SRGBColor(hex: hex).simulated(simulation)
            #expect(abs(actual.red - expected.0) < 0.000_001)
            #expect(abs(actual.green - expected.1) < 0.000_001)
            #expect(abs(actual.blue - expected.2) < 0.000_001)
        }
        for simulation in [ColorVisionSimulation.protanopia, .deuteranopia] {
            #expect(SRGBColor.black.simulated(simulation) == .black)
            let white = SRGBColor.white.simulated(simulation)
            #expect(abs(white.red - 1) < 0.000_001)
            #expect(abs(white.green - 1) < 0.000_001)
            #expect(abs(white.blue - 1) < 0.000_001)
        }
    }

    @Test func completedItemsUseExplicitFinalRolesThatPassOnTheirActualSurface() throws {
        let colors = CategoryPalette.families.flatMap(\.colors) + ["#FFFFFF", "#000000"]
        for hex in colors {
            for appearance in [CalendarAppearance.light, .dark] {
                let completed = try CategoryColorResolver
                    .roles(for: hex, appearance: appearance)
                    .rendered(isCompleted: true)
                #expect(completed.accent.contrastRatio(with: completed.background) >= 3.0)
                #expect(completed.outline.contrastRatio(with: completed.background) >= 3.0)
                #expect(completed.text.contrastRatio(with: completed.background) >= 4.5)
            }
        }
    }

    @Test func eachFamilyRemainsDistinguishableUnderCommonRedGreenDeficiencySimulation() throws {
        for family in CategoryPalette.families {
            for appearance in [CalendarAppearance.light, .dark] {
                let protanopia = try family.minimumRenderedAccentDeltaE(
                    appearance: appearance,
                    simulation: .protanopia
                )
                let deuteranopia = try family.minimumRenderedAccentDeltaE(
                    appearance: appearance,
                    simulation: .deuteranopia
                )
                #expect(protanopia >= 3.0)
                #expect(deuteranopia >= 3.0)
            }
        }
    }

    @Test func familyCalibrationStaysInsideTheDeclaredIdentityDriftBudget() throws {
        for hex in CategoryPalette.families.flatMap(\.colors) {
            for appearance in [CalendarAppearance.light, .dark] {
                let drift = try CategoryColorResolver.calibrationDrift(
                    for: hex,
                    appearance: appearance
                )
                #expect(drift.hueDegrees <= 3.000_001)
                #expect(drift.lightness <= 0.030_001)
                #expect(drift.chroma <= 0.050_001)
            }
        }
    }
}
