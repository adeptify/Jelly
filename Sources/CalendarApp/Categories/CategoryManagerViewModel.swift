import CalendarDomain
import Combine
import Foundation
import WorkspaceDomain

enum CalendarAppearance: Hashable, Sendable {
    case light
    case dark
}

enum CategoryReorderMove {
    enum Direction {
        case up
        case down
    }

    static func reorderedIDs(
        _ ids: [UUID],
        selected: UUID?,
        direction: Direction
    ) -> [UUID]? {
        guard let selected, let currentIndex = ids.firstIndex(of: selected) else {
            return nil
        }
        let targetIndex = direction == .up ? currentIndex - 1 : currentIndex + 1
        guard ids.indices.contains(targetIndex) else { return nil }
        var result = ids
        result.swapAt(currentIndex, targetIndex)
        return result
    }
}

struct CategoryPreviewPalette: Sendable {
    let lightCanvasHex: String
    let lightTextHex: String
    let darkCanvasHex: String
    let darkTextHex: String
    let lightCategoryBackgroundOpacity: Double
    let darkCategoryBackgroundOpacity: Double

    static let production = CategoryPreviewPalette(
        lightCanvasHex: CalendarTheme.previewLightCanvasHex,
        lightTextHex: CalendarTheme.previewLightTextHex,
        darkCanvasHex: CalendarTheme.previewDarkCanvasHex,
        darkTextHex: CalendarTheme.previewDarkTextHex,
        lightCategoryBackgroundOpacity: CalendarTheme.categoryItemBackgroundOpacityLight,
        darkCategoryBackgroundOpacity: CalendarTheme.categoryItemBackgroundOpacityDark
    )

    func categoryBackgroundOpacity(for appearance: CalendarAppearance) -> Double {
        appearance == .light ? lightCategoryBackgroundOpacity : darkCategoryBackgroundOpacity
    }
}

enum CategoryManagerError: Error, Equatable {
    case emptyName
    case duplicateName
    case invalidColor
    case insufficientContrast
    case protectedCategory
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
        let category = try SRGBColor(hex: colorHex)
        let canvas = try SRGBColor(hex: canvasHex(for: appearance, palette: palette))
        let text = try SRGBColor(hex: textHex(for: appearance, palette: palette))
        let composite = category.composited(
            over: canvas,
            alpha: palette.categoryBackgroundOpacity(for: appearance)
        )
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

}

@MainActor
final class CategoryManagerViewModel: ObservableObject {
    static let defaultPalette = CategoryPalette.families[0].colors

    private let store: WorkspaceStore
    private let previewPalette: CategoryPreviewPalette
    private var editingBaseline: CategoryDraft?

    @Published var draftName = ""
    @Published var draftColorHex = "#4F7FFF"
    @Published private(set) var selectedFamilyID: CategoryColorFamilyID = .basic
    @Published var categoryToDelete: CalendarCategory?

    init(
        store: WorkspaceStore,
        previewPalette: CategoryPreviewPalette = .production
    ) {
        self.store = store
        self.previewPalette = previewPalette
    }

    func create() async throws -> WorkspaceMutationPresentation {
        try validateDraft(excluding: nil)
        let now = Date()
        let category = CalendarCategory(
            id: UUID(),
            name: draftName.trimmingCharacters(in: .whitespacesAndNewlines),
            colorHex: draftColorHex,
            sortIndex: store.calendarState.categories.count,
            createdAt: now,
            updatedAt: now
        )
        let presentation = try await send(.createCategory(category), undoLabel: "已添加分类")
        if presentation.allowsDismissal {
            beginCreating()
        }
        return presentation
    }

    func update(_ category: CalendarCategory) async throws -> WorkspaceMutationPresentation {
        guard category.id != store.calendarState.uncategorizedID else {
            throw CategoryManagerError.protectedCategory
        }
        try validateDraft(excluding: category.id)
        var updated = category
        updated.name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.colorHex = draftColorHex
        let presentation = try await send(.updateCategory(updated), undoLabel: "已更新分类")
        if presentation.allowsDismissal, let authoritative = store.calendarState.categories[category.id] {
            beginEditing(authoritative)
        }
        return presentation
    }

    func reorder(_ ids: [UUID]) async throws -> WorkspaceMutationPresentation {
        try await send(.reorderCategories(ids), undoLabel: "已调整分类顺序")
    }

    func deleteConfirmed() async throws -> WorkspaceMutationPresentation? {
        guard let category = categoryToDelete else {
            return nil
        }
        guard category.id != store.calendarState.uncategorizedID else {
            throw CategoryManagerError.protectedCategory
        }
        return try await deleteConfirmed(category: category)
    }

    func deleteConfirmed(category: CalendarCategory) async throws -> WorkspaceMutationPresentation {
        guard category.id != store.calendarState.uncategorizedID else {
            throw CategoryManagerError.protectedCategory
        }
        let presentation = try await send(
            .deleteCategory(category.id),
            undoLabel: "已删除分类并转入未分类"
        )
        if presentation.allowsDismissal {
            categoryToDelete = nil
        }
        return presentation
    }

    func beginEditing(_ category: CalendarCategory) {
        draftName = category.name
        draftColorHex = category.colorHex
        if let family = CategoryPalette.families.first(where: { $0.colors.contains(category.colorHex.uppercased()) }) {
            selectedFamilyID = family.id
        }
        editingBaseline = .init(category: category)
    }

    func beginCreating() {
        draftName = ""
        draftColorHex = Self.defaultPalette[0]
        selectedFamilyID = .basic
        editingBaseline = nil
    }

    func selectFamily(_ familyID: CategoryColorFamilyID) {
        selectedFamilyID = familyID
    }

    func selectPreset(_ colorHex: String) {
        guard let preset = CategoryPalette.preset(hex: colorHex) else { return }
        draftColorHex = preset.hex
    }

    func synchronizeDraftFromStore(_ category: CalendarCategory) {
        guard editingBaseline?.id == category.id, !hasUnsavedDraftChanges else { return }
        beginEditing(category)
    }

    private func validateDraft(excluding categoryID: UUID?) throws {
        let trimmedName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw CategoryManagerError.emptyName
        }
        let normalizedName = trimmedName.lowercased()
        guard !store.calendarState.categories.values.contains(where: {
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

    private var hasUnsavedDraftChanges: Bool {
        guard let editingBaseline else { return false }
        return draftName != editingBaseline.name || draftColorHex != editingBaseline.colorHex
    }

    private func send(_ command: WorkspaceCommand, undoLabel: String) async throws -> WorkspaceMutationPresentation {
        do {
            return WorkspaceMutationOutcomePresenter.presentation(
                for: try await store.sendWorkspace(command, undoLabel: undoLabel)
            )
        } catch let error as WorkspaceReducerError {
            guard case let .calendarFailure(calendarError) = error else { throw error }
            switch calendarError {
            case .duplicateCategoryName:
                throw CategoryManagerError.duplicateName
            case .invalidCategoryColor:
                throw CategoryManagerError.invalidColor
            case .protectedCategory:
                throw CategoryManagerError.protectedCategory
            default:
                throw calendarError
            }
        }
    }

    private struct CategoryDraft {
        let id: UUID
        let name: String
        let colorHex: String

        init(category: CalendarCategory) {
            id = category.id
            name = category.name
            colorHex = category.colorHex
        }
    }
}
