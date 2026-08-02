import CalendarDomain
import Testing
@testable import CalendarApp

@Suite("MonthGridBuilderTests")
struct MonthGridBuilderTests {
    @Test func august2026ProducesMondayFirstFortyTwoCellGrid() {
        let cells = MonthGridBuilder.cells(
            containing: .init(year: 2026, month: 8, day: 1)!
        )

        #expect(cells.count == 42)
        #expect(cells.first == CalendarDate(year: 2026, month: 7, day: 27)!)
        #expect(cells.last == CalendarDate(year: 2026, month: 9, day: 6)!)
    }
}
