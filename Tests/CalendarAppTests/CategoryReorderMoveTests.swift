import CalendarDomain
import Foundation
import Testing
@testable import CalendarApp

@Suite("CategoryReorderMoveTests")
@MainActor
struct CategoryReorderMoveTests {
    @Test func moveUpAndDownReorderTheSelectedIDWithoutSpecialCasingUncategorized() {
        let uncategorized = UUID()
        let work = UUID()
        let life = UUID()
        let ids = [uncategorized, work, life]

        #expect(
            CategoryReorderMove.reorderedIDs(ids, selected: uncategorized, direction: .down)
                == [work, uncategorized, life]
        )
        #expect(
            CategoryReorderMove.reorderedIDs(ids, selected: life, direction: .up)
                == [uncategorized, life, work]
        )
    }

    @Test func boundaryOrMissingSelectionCannotProduceAReorderCommand() {
        let first = UUID()
        let last = UUID()
        let ids = [first, last]

        #expect(CategoryReorderMove.reorderedIDs(ids, selected: first, direction: .up) == nil)
        #expect(CategoryReorderMove.reorderedIDs(ids, selected: last, direction: .down) == nil)
        #expect(CategoryReorderMove.reorderedIDs(ids, selected: UUID(), direction: .up) == nil)
    }

    @Test func managerListHidesUncategorizedAndKeepsItInPersistedOrder() {
        let uncategorizedID = UUID()
        let work = CalendarCategory(
            id: UUID(),
            name: "工作",
            colorHex: "#4F7FFF",
            sortIndex: 1,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let life = CalendarCategory(
            id: UUID(),
            name: "生活",
            colorHex: "#D9893D",
            sortIndex: 2,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let uncategorized = CalendarCategory(
            id: uncategorizedID,
            name: "未分类",
            colorHex: "#8E8E93",
            sortIndex: 0,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )

        let visible = CategoryReorderMove.visibleCategories(
            [uncategorized, work, life],
            uncategorizedID: uncategorizedID
        )
        #expect(visible.map(\.id) == [work.id, life.id])

        let persisted = CategoryReorderMove.persistedOrder(
            visibleIDs: [life.id, work.id],
            uncategorizedID: uncategorizedID,
            currentlyOrderedIDs: [uncategorizedID, work.id, life.id]
        )
        #expect(persisted == [uncategorizedID, life.id, work.id])
    }

    @Test func selectedRowPreviewUsesDraftUntilSave() {
        #expect(
            CategoryRowPreview.name(stored: "AI Video", draft: "AI Film", isLive: true) == "AI Film"
        )
        #expect(
            CategoryRowPreview.name(stored: "AI Video", draft: "   ", isLive: true)
                == CategoryRowPreview.emptyNamePlaceholder
        )
        #expect(
            CategoryRowPreview.name(stored: "AI Video", draft: "AI Film", isLive: false) == "AI Video"
        )
        #expect(
            CategoryRowPreview.colorHex(stored: "#4F7FFF", draft: "#E4D87D", isLive: true) == "#E4D87D"
        )
        #expect(
            CategoryRowPreview.colorHex(stored: "#4F7FFF", draft: "#E4D87D", isLive: false) == "#4F7FFF"
        )
    }
}
