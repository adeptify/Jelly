import CalendarDomain
import Foundation
import Testing
@testable import CalendarApp

@Suite("CategoryManagerViewModelTests")
@MainActor
struct CategoryManagerViewModelTests {
    @Test func emptyAndDuplicateNamesAreRejectedCaseInsensitively() async throws {
        var state = makeEmptyState()
        let work = makeCategory(name: "工作")
        state.categories[work.id] = work
        let (store, _) = try await makeReadyStore(initialState: state)
        let vm = CategoryManagerViewModel(store: store)

        vm.draftName = "   \n"
        await #expect(throws: CategoryManagerError.emptyName) {
            try await vm.create()
        }

        vm.draftName = " 工作 "
        await #expect(throws: CategoryManagerError.duplicateName) {
            try await vm.create()
        }
        #expect(store.state == state)
    }

    @Test func colorHexAcceptsOnlyASCIIHashRRGGBBAndNormalizesUppercase() throws {
        #expect(try CategoryColorValidator.normalizedHex("#7f53ac") == "#7F53AC")
        for value in ["7F53AC", "#7F53A", "#7F53AC0", " #7F53AC", "#7F53AＧ"] {
            #expect(throws: CategoryManagerError.invalidColor) {
                try CategoryColorValidator.normalizedHex(value)
            }
        }
    }

    @Test func readabilityForCustomColorMatchesRenderedTheme() throws {
        let color = try CategoryColorValidator.normalizedHex("#7f53ac")
        let light = try CategoryColorValidator.itemContrastRatio(colorHex: color, appearance: .light)
        let dark = try CategoryColorValidator.itemContrastRatio(colorHex: color, appearance: .dark)

        #expect(light >= 4.5)
        #expect(dark >= 4.5)
        #expect(CalendarTheme.categoryItemBackgroundOpacity == 0.24)
        #expect(CalendarTheme.categoryItemCompletedBackgroundOpacity == 0.11)
        #expect(CalendarTheme.completedItemOpacity == 0.62)
        #expect(CalendarTheme.previewLightCanvasHex == "#F7F1E7")
        #expect(CalendarTheme.previewLightTextHex == "#2A2420")
        #expect(CalendarTheme.previewDarkCanvasHex == "#211E1B")
        #expect(CalendarTheme.previewDarkTextHex == "#F4EDE4")
    }

    @Test func completedTaskOutlineDecisionUsesFinalAccentAndActualSurface() throws {
        for appearance in [CalendarAppearance.light, .dark] {
            let roles = try CategoryColorResolver
                .roles(for: "#4F7FFF", appearance: appearance)
                .rendered(isCompleted: true)
            #expect(roles.accentContrast >= 3.0)
            #expect(CalendarTheme.itemAccentNeedsOutline(
                "#4F7FFF", isCompletedTask: true, appearance: appearance
            ) == false)
        }
    }

    @Test func defaultPaletteUsesTheSameReadabilityValidation() throws {
        #expect(CategoryManagerViewModel.defaultPalette == CategoryPalette.families[0].colors)
        for color in CategoryManagerViewModel.defaultPalette {
            try CategoryColorValidator.validateReadableInBothAppearances(color)
        }
    }

    @Test func changingFamilyDoesNotChangeDraftUntilAColorIsChosen() async throws {
        var state = makeEmptyState()
        let work = makeCategory(name: "工作")
        state.categories[work.id] = work
        let (store, _) = try await makeReadyStore(initialState: state)
        let vm = CategoryManagerViewModel(store: store)

        vm.beginEditing(work)
        vm.selectFamily(.macaron)
        #expect(vm.selectedFamilyID == .macaron)
        #expect(vm.draftColorHex == work.colorHex)

        vm.selectPreset("#8FB8F4")
        #expect(vm.draftColorHex == "#8FB8F4")
    }

    @Test func selectingFamilyPreservesExistingPresetAndCustomDrafts() async throws {
        let (store, _) = try await makeReadyStore(initialState: makeEmptyState())
        let vm = CategoryManagerViewModel(store: store)

        vm.draftColorHex = "#A9A2E8"
        vm.selectFamily(.nature)
        #expect(vm.draftColorHex == "#A9A2E8")

        vm.draftColorHex = "#123456"
        vm.selectFamily(.vivid)
        #expect(vm.draftColorHex == "#123456")
    }

    @Test func presetAndCustomColorsPersistOnlyTheirBaseHex() async throws {
        let (store, _) = try await makeReadyStore(initialState: makeEmptyState())
        let vm = CategoryManagerViewModel(store: store)

        vm.draftName = "预设"
        vm.selectPreset("#8FB8F4")
        try await vm.create()
        #expect(store.state.categories.values.contains { $0.name == "预设" && $0.colorHex == "#8FB8F4" })

        vm.draftName = "自定义"
        vm.draftColorHex = "#123456"
        try await vm.create()
        #expect(store.state.categories.values.contains { $0.name == "自定义" && $0.colorHex == "#123456" })
    }

    @Test func uncategorizedIsProtectedButCanUseTheSharedReorderAction() async throws {
        var state = makeEmptyState()
        let work = makeCategory(name: "工作")
        state.categories[work.id] = work
        let (store, _) = try await makeReadyStore(initialState: state)
        let vm = CategoryManagerViewModel(store: store)
        let uncategorized = try #require(state.categories[state.uncategorizedID])

        vm.draftName = "其他"
        vm.draftColorHex = "#4F7FFF"
        await #expect(throws: CategoryManagerError.protectedCategory) {
            try await vm.update(uncategorized)
        }
        vm.categoryToDelete = uncategorized
        vm.migrationTargetID = work.id
        await #expect(throws: CategoryManagerError.protectedCategory) {
            try await vm.deleteConfirmed()
        }

        try await vm.reorder([work.id, uncategorized.id])
        #expect(store.state.categories[work.id]?.sortIndex == 0)
        #expect(store.state.categories[uncategorized.id]?.sortIndex == 1)
    }

    @Test func deleteRequiresExplicitMigrationChoice() async throws {
        let uncategorizedID = UUID(uuidString: "00000000-0000-0000-0000-000000000701")!
        var state = CalendarState.empty(
            uncategorizedID: uncategorizedID,
            now: Date(timeIntervalSince1970: 0)
        )
        let work = CalendarCategory(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000702")!,
            name: "工作",
            colorHex: "#4F7FFF",
            sortIndex: 1,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        state.categories[work.id] = work
        let repository = InMemoryCalendarRepository(initialState: state)
        let store = CalendarStore(initialState: state, repository: repository)
        await store.load()
        let vm = CategoryManagerViewModel(store: store)
        vm.categoryToDelete = work
        vm.migrationTargetID = nil
        await #expect(throws: CategoryManagerError.migrationRequired) {
            try await vm.deleteConfirmed()
        }
        #expect(store.state == state)
    }

    @Test func deleteToUncategorizedAtomicallyMigratesAllReferencesAndUndoRestoresEverything() async throws {
        let fixture = try makeCategoryReferenceFixture()
        let original = fixture.state
        let (store, repository) = try await makeReadyStore(initialState: original)
        let vm = CategoryManagerViewModel(store: store)
        vm.categoryToDelete = original.categories[fixture.deletedCategoryID]!
        vm.migrationTargetID = original.uncategorizedID

        try await vm.deleteConfirmed()

        #expect(store.state.categories[fixture.deletedCategoryID] == nil)
        #expect(store.state.items.values.allSatisfy { $0.categoryID != fixture.deletedCategoryID })
        #expect(store.state.recurrence.series.values.allSatisfy { $0.categoryID != fixture.deletedCategoryID })
        #expect(store.state.recurrence.exceptions.values.allSatisfy { exception in
            if case let .modified(override) = exception {
                return override.categoryID != fixture.deletedCategoryID
            }
            return true
        })
        #expect(store.state.items.values.allSatisfy { $0.categoryID == original.uncategorizedID })
        #expect(await repository.persistedState == store.state)

        try await store.undo()
        #expect(store.state == original)
        #expect(await repository.persistedState == original)
    }

    @Test func capturedDeleteChoiceSurvivesDialogDismissal() async throws {
        let fixture = try makeCategoryReferenceFixture()
        let (store, _) = try await makeReadyStore(initialState: fixture.state)
        let vm = CategoryManagerViewModel(store: store)
        let category = fixture.state.categories[fixture.deletedCategoryID]!
        let migrationTargetID = fixture.targetCategoryID

        vm.categoryToDelete = category
        vm.migrationTargetID = migrationTargetID
        vm.categoryToDelete = nil
        vm.migrationTargetID = nil

        try await vm.deleteConfirmed(category: category, migrationTargetID: migrationTargetID)

        #expect(store.state.categories[category.id] == nil)
        #expect(store.state.items.values.allSatisfy { $0.categoryID == migrationTargetID })
        #expect(store.state.recurrence.series.values.allSatisfy { $0.categoryID == migrationTargetID })
        #expect(store.state.recurrence.exceptions.values.allSatisfy { exception in
            if case let .modified(override) = exception {
                return override.categoryID == migrationTargetID
            }
            return true
        })
    }

    @Test func unreadableColorDoesNotCommit() async throws {
        let state = makeEmptyState()
        let (store, repository) = try await makeReadyStore(initialState: state)
        let unreadablePalette = CategoryPreviewPalette(
            lightCanvasHex: "#FFFFFF",
            lightTextHex: "#FFFFFF",
            darkCanvasHex: "#1C1C1E",
            darkTextHex: "#1C1C1E",
            categoryBackgroundOpacity: 0.14
        )
        #expect(throws: CategoryManagerError.insufficientContrast) {
            try CategoryColorValidator.validateReadableInBothAppearances(
                "#4F7FFF",
                palette: unreadablePalette
            )
        }

        let vm = CategoryManagerViewModel(store: store, previewPalette: unreadablePalette)
        vm.draftName = "不可读"
        vm.draftColorHex = "#4F7FFF"
        await #expect(throws: CategoryManagerError.insufficientContrast) {
            try await vm.create()
        }
        #expect(store.state == state)
        #expect(await repository.saveCount == 0)
    }

    @Test func authoritativeUndoRefreshesCleanSelectedDraft() async throws {
        var state = makeEmptyState()
        let work = makeCategory(name: "工作")
        state.categories[work.id] = work
        let (store, _) = try await makeReadyStore(initialState: state)
        let vm = CategoryManagerViewModel(store: store)

        vm.beginEditing(work)
        vm.draftColorHex = "#7A67D8"
        try await vm.update(work)
        try await store.undo()
        let restored = try #require(store.state.categories[work.id])

        vm.synchronizeDraftFromStore(restored)

        #expect(vm.draftName == "工作")
        #expect(vm.draftColorHex == "#007AFF")
    }

    @Test func authoritativeUpdateDoesNotOverwriteUnsavedSelectedDraft() async throws {
        var state = makeEmptyState()
        let work = makeCategory(name: "工作")
        state.categories[work.id] = work
        let (store, _) = try await makeReadyStore(initialState: state)
        let vm = CategoryManagerViewModel(store: store)

        vm.beginEditing(work)
        vm.draftName = "本地未保存名称"
        var external = work
        external.colorHex = "#53A66F"
        try await store.send(.updateCategory(external), undoLabel: "外部更新")
        let authoritative = try #require(store.state.categories[work.id])

        vm.synchronizeDraftFromStore(authoritative)

        #expect(vm.draftName == "本地未保存名称")
        #expect(vm.draftColorHex == "#007AFF")
    }
}
