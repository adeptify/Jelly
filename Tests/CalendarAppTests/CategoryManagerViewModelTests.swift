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
        #expect(store.calendarState == state)
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
        #expect(CalendarTheme.categoryItemBackgroundOpacityLight == 0.24)
        #expect(CalendarTheme.categoryItemBackgroundOpacityDark == 0.36)
        #expect(CalendarTheme.categoryItemCompletedBackgroundOpacityLight == 0.11)
        #expect(CalendarTheme.categoryItemCompletedBackgroundOpacityDark == 0.17)
        #expect(CalendarTheme.completedItemOpacityLight == 0.62)
        #expect(CalendarTheme.completedItemOpacityDark == 0.55)
        #expect(CalendarTheme.categoryItemBackgroundOpacity(for: .light) == 0.24)
        #expect(CalendarTheme.categoryItemBackgroundOpacity(for: .dark) == 0.36)
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
        _ = try await vm.create()
        #expect(store.calendarState.categories.values.contains { $0.name == "预设" && $0.colorHex == "#8FB8F4" })

        vm.draftName = "自定义"
        vm.draftColorHex = "#123456"
        _ = try await vm.create()
        #expect(store.calendarState.categories.values.contains { $0.name == "自定义" && $0.colorHex == "#123456" })
    }

    @Test func failedPersistenceKeepsTheCategoryDraftAndReturnsRecoverablePresentation() async throws {
        let (store, repository) = try await makeReadyStore(initialState: makeEmptyState())
        let vm = CategoryManagerViewModel(store: store)
        vm.draftName = "不应丢失的分类"
        vm.draftColorHex = "#4F7FFF"
        await repository.failNextSave()

        let presentation = try await vm.create()

        #expect(presentation.allowsDismissal == false)
        #expect(presentation.message == "没有保存到磁盘，已保留当前输入；请重试。")
        #expect(vm.draftName == "不应丢失的分类")
        #expect(store.calendarState.categories.values.contains { $0.name == "不应丢失的分类" } == false)
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
        await #expect(throws: CategoryManagerError.protectedCategory) {
            try await vm.deleteConfirmed()
        }

        _ = try await vm.reorder([work.id, uncategorized.id])
        #expect(store.calendarState.categories[work.id]?.sortIndex == 0)
        #expect(store.calendarState.categories[uncategorized.id]?.sortIndex == 1)
    }

    @Test func deleteUsesTheWorkspaceUncategorizedPolicyWithoutAMigrationChoice() async throws {
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
        let repository = InMemoryWorkspaceRepository(initialState: state)
        let store = WorkspaceStore(initialState: state, repository: repository)
        await store.load()
        let vm = CategoryManagerViewModel(store: store)
        vm.categoryToDelete = work
        _ = try await vm.deleteConfirmed()
        #expect(store.calendarState.categories[work.id] == nil)
        #expect(store.calendarState.categories[uncategorizedID] != nil)
    }

    @Test func deleteToUncategorizedAtomicallyMigratesAllReferencesAndUndoRestoresEverything() async throws {
        let fixture = try makeCategoryReferenceFixture()
        let original = fixture.state
        let (store, repository) = try await makeReadyStore(initialState: original)
        let vm = CategoryManagerViewModel(store: store)
        vm.categoryToDelete = original.categories[fixture.deletedCategoryID]!

        _ = try await vm.deleteConfirmed()

        #expect(store.calendarState.categories[fixture.deletedCategoryID] == nil)
        #expect(store.calendarState.items.values.allSatisfy { $0.categoryID != fixture.deletedCategoryID })
        #expect(store.calendarState.recurrence.series.values.allSatisfy { $0.categoryID != fixture.deletedCategoryID })
        #expect(store.calendarState.recurrence.exceptions.values.allSatisfy { exception in
            if case let .modified(override) = exception {
                return override.categoryID != fixture.deletedCategoryID
            }
            return true
        })
        #expect(store.calendarState.items.values.allSatisfy { $0.categoryID == original.uncategorizedID })
        #expect(await repository.persistedState == store.calendarState)

        _ = try await store.undo()
        #expect(store.calendarState == original)
        #expect(await repository.persistedState == original)
    }

    @Test func capturedDeleteConfirmationUsesTheWorkspaceUncategorizedPolicy() async throws {
        let fixture = try makeCategoryReferenceFixture()
        let (store, _) = try await makeReadyStore(initialState: fixture.state)
        let vm = CategoryManagerViewModel(store: store)
        let category = fixture.state.categories[fixture.deletedCategoryID]!

        vm.categoryToDelete = category
        vm.categoryToDelete = nil

        _ = try await vm.deleteConfirmed(category: category)

        #expect(store.calendarState.categories[category.id] == nil)
        #expect(store.calendarState.items.values.allSatisfy { $0.categoryID == fixture.state.uncategorizedID })
        #expect(store.calendarState.recurrence.series.values.allSatisfy { $0.categoryID == fixture.state.uncategorizedID })
        #expect(store.calendarState.recurrence.exceptions.values.allSatisfy { exception in
            if case let .modified(override) = exception {
                return override.categoryID == fixture.state.uncategorizedID
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
            lightCategoryBackgroundOpacity: 0.14,
            darkCategoryBackgroundOpacity: 0.14
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
        #expect(store.calendarState == state)
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
        _ = try await vm.update(work)
        _ = try await store.undo()
        let restored = try #require(store.calendarState.categories[work.id])

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
        _ = try await store.sendWorkspace(.updateCategory(external), undoLabel: "外部更新")
        let authoritative = try #require(store.calendarState.categories[work.id])

        vm.synchronizeDraftFromStore(authoritative)

        #expect(vm.draftName == "本地未保存名称")
        #expect(vm.draftColorHex == "#007AFF")
    }
}
