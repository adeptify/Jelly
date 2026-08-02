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
}
