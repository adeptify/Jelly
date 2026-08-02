import CalendarDomain
import Testing
@testable import CalendarApp

@Suite("CalendarItemRowPresentationTests")
@MainActor
struct CalendarItemRowPresentationTests {
    @Test func compactTimedRowKeepsFullStartTimeAndPrioritizesTitleOverCategory() throws {
        let range = try LocalTimeRange(
            start: .init(hour: 9, minute: 0)!,
            end: .init(hour: 10, minute: 0)!
        )

        let compact = CalendarItemRowPresentation.make(
            availableContentWidth: 112,
            categoryName: "工作",
            timeRange: range,
            title: "产品同步会"
        )
        #expect(compact.categoryName == nil)
        #expect(compact.timeText == "09:00")
        #expect(compact.title == "产品同步会")

        let regular = CalendarItemRowPresentation.make(
            availableContentWidth: 142,
            categoryName: "工作",
            timeRange: range,
            title: "产品同步会"
        )
        #expect(regular.categoryName == "工作")
        #expect(regular.timeText == "09:00")
    }
}
