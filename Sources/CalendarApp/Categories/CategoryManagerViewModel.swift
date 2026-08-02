import CalendarDomain
import Combine
import Foundation

enum CalendarAppearance: Sendable {
    case light
    case dark
}

struct CategoryPreviewPalette: Sendable {
    let lightCanvasHex: String
    let lightTextHex: String
    let darkCanvasHex: String
    let darkTextHex: String
    let categoryBackgroundOpacity: Double

    static let production = CategoryPreviewPalette(
        lightCanvasHex: CalendarTheme.previewLightCanvasHex,
        lightTextHex: CalendarTheme.previewLightTextHex,
        darkCanvasHex: CalendarTheme.previewDarkCanvasHex,
        darkTextHex: CalendarTheme.previewDarkTextHex,
        categoryBackgroundOpacity: CalendarTheme.categoryItemBackgroundOpacity
    )
}

enum CategoryManagerError: Error, Equatable {
    case emptyName
    case duplicateName
    case invalidColor
    case insufficientContrast
    case protectedCategory
    case migrationRequired
    case invalidMigrationTarget
}

enum CategoryColorValidator {
    static func normalizedHex(_ input: String) throws -> String {
        let scalars = input.unicodeScalars
        guard scalars.count == 7, scalars.first?.value == 35 else {
            throw CategoryManagerError.invalidColor
        }
        guard scalars.dropFirst().allSatisfy({ scalar in
            switch scalar.value {
            case 48...57, 65...70, 97...102:
                true
            default:
                false
            }
        }) else {
            throw CategoryManagerError.invalidColor
        }
        return input.uppercased()
    }

    static func itemContrastRatio(
        colorHex: String,
        appearance: CalendarAppearance,
        palette: CategoryPreviewPalette = .production
    ) throws -> Double {
        let category = try color(for: colorHex)
        let canvas = try color(for: canvasHex(for: appearance, palette: palette))
        let text = try color(for: textHex(for: appearance, palette: palette))
        let composite = category.composited(over: canvas, alpha: palette.categoryBackgroundOpacity)
        return composite.contrastRatio(with: text)
    }

    static func validateReadableInBothAppearances(
        _ colorHex: String,
        palette: CategoryPreviewPalette = .production
    ) throws {
        _ = try normalizedHex(colorHex)
        guard try itemContrastRatio(colorHex: colorHex, appearance: .light, palette: palette)
                >= CalendarTheme.categoryTextMinimumContrast,
              try itemContrastRatio(colorHex: colorHex, appearance: .dark, palette: palette)
                >= CalendarTheme.categoryTextMinimumContrast
        else {
            throw CategoryManagerError.insufficientContrast
        }
    }

    static func accentNeedsOutline(
        colorHex: String,
        appearance: CalendarAppearance,
        palette: CategoryPreviewPalette = .production,
        renderingOpacity: Double = 1
    ) throws -> Bool {
        let category = try color(for: colorHex)
        let canvas = try color(for: canvasHex(for: appearance, palette: palette))
        let renderedAccent = category.composited(over: canvas, alpha: renderingOpacity)
        return renderedAccent.contrastRatio(with: canvas) < CalendarTheme.categoryAccentMinimumContrast
    }

    private static func canvasHex(
        for appearance: CalendarAppearance,
        palette: CategoryPreviewPalette
    ) -> String {
        appearance == .light ? palette.lightCanvasHex : palette.darkCanvasHex
    }

    private static func textHex(
        for appearance: CalendarAppearance,
        palette: CategoryPreviewPalette
    ) -> String {
        appearance == .light ? palette.lightTextHex : palette.darkTextHex
    }

    private static func color(for hex: String) throws -> SRGBColor {
        let normalized = try normalizedHex(hex)
        let value = UInt64(normalized.dropFirst(), radix: 16)!
        return SRGBColor(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    private struct SRGBColor {
        let red: Double
        let green: Double
        let blue: Double

        func composited(over canvas: SRGBColor, alpha: Double) -> SRGBColor {
            let clampedAlpha = min(max(alpha, 0), 1)
            return SRGBColor(
                red: red * clampedAlpha + canvas.red * (1 - clampedAlpha),
                green: green * clampedAlpha + canvas.green * (1 - clampedAlpha),
                blue: blue * clampedAlpha + canvas.blue * (1 - clampedAlpha)
            )
        }

        func contrastRatio(with other: SRGBColor) -> Double {
            let first = relativeLuminance
            let second = other.relativeLuminance
            return (max(first, second) + 0.05) / (min(first, second) + 0.05)
        }

        private var relativeLuminance: Double {
            0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        private func linear(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
    }
}

@MainActor
final class CategoryManagerViewModel: ObservableObject {
    static let defaultPalette = [
        "#4F7FFF", "#7A67D8", "#D65E73", "#D9893D",
        "#53A66F", "#2E9DA7", "#8A6A4A", "#8E8E93"
    ]

    private let store: CalendarStore
    private let previewPalette: CategoryPreviewPalette

    @Published var draftName = ""
    @Published var draftColorHex = "#4F7FFF"
    @Published var categoryToDelete: CalendarCategory?
    @Published var migrationTargetID: UUID?

    init(
        store: CalendarStore,
        previewPalette: CategoryPreviewPalette = .production
    ) {
        self.store = store
        self.previewPalette = previewPalette
    }

    func create() async throws {
        try validateDraft(excluding: nil)
        let now = Date()
        let category = CalendarCategory(
            id: UUID(),
            name: draftName.trimmingCharacters(in: .whitespacesAndNewlines),
            colorHex: draftColorHex,
            sortIndex: store.state.categories.count,
            createdAt: now,
            updatedAt: now
        )
        try await send(.createCategory(category), undoLabel: "已添加分类")
        draftName = ""
    }

    func update(_ category: CalendarCategory) async throws {
        guard category.id != store.state.uncategorizedID else {
            throw CategoryManagerError.protectedCategory
        }
        try validateDraft(excluding: category.id)
        var updated = category
        updated.name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.colorHex = draftColorHex
        try await send(.updateCategory(updated), undoLabel: "已更新分类")
    }

    func reorder(_ ids: [UUID]) async throws {
        try await send(.reorderCategories(ids), undoLabel: "已调整分类顺序")
    }

    func deleteConfirmed() async throws {
        guard let category = categoryToDelete else {
            throw CategoryManagerError.migrationRequired
        }
        guard category.id != store.state.uncategorizedID else {
            throw CategoryManagerError.protectedCategory
        }
        guard let migrationTargetID else {
            throw CategoryManagerError.migrationRequired
        }
        try await deleteConfirmed(category: category, migrationTargetID: migrationTargetID)
    }

    func deleteConfirmed(
        category: CalendarCategory,
        migrationTargetID: UUID
    ) async throws {
        guard category.id != store.state.uncategorizedID else {
            throw CategoryManagerError.protectedCategory
        }
        guard migrationTargetID != category.id,
              store.state.categories[migrationTargetID] != nil
        else {
            throw CategoryManagerError.invalidMigrationTarget
        }
        try await send(
            .deleteCategory(category.id, migrateTo: migrationTargetID),
            undoLabel: "已删除分类并迁移事项"
        )
        categoryToDelete = nil
        self.migrationTargetID = nil
    }

    private func validateDraft(excluding categoryID: UUID?) throws {
        let trimmedName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw CategoryManagerError.emptyName
        }
        let normalizedName = trimmedName.lowercased()
        guard !store.state.categories.values.contains(where: {
            $0.id != categoryID
                && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedName
        }) else {
            throw CategoryManagerError.duplicateName
        }
        let normalizedColor = try CategoryColorValidator.normalizedHex(draftColorHex)
        try CategoryColorValidator.validateReadableInBothAppearances(
            normalizedColor,
            palette: previewPalette
        )
        draftColorHex = normalizedColor
    }

    private func send(_ command: CalendarCommand, undoLabel: String) async throws {
        do {
            try await store.send(command, undoLabel: undoLabel)
        } catch let error as ReducerError {
            switch error {
            case .duplicateCategoryName:
                throw CategoryManagerError.duplicateName
            case .invalidCategoryColor:
                throw CategoryManagerError.invalidColor
            case .protectedCategory:
                throw CategoryManagerError.protectedCategory
            case .invalidMigrationTarget:
                throw CategoryManagerError.invalidMigrationTarget
            default:
                throw error
            }
        }
    }
}
