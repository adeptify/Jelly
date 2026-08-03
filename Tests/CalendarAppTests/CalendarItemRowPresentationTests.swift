import CalendarDomain
import Testing
@testable import CalendarApp

@Suite("CalendarItemRowPresentationTests")
@MainActor
struct CalendarItemRowPresentationTests {
    @Test func compactTimedRowKeepsFullStartTimeReadableCategoryAndTitle() throws {
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
        #expect(compact.categoryName == "工作")
        #expect(compact.timeText == "09:00")
        #expect(compact.title == "产品同步会")
        #expect(compact.layout.categoryMinimumWidth == 24)
        #expect(compact.layout.categoryMaximumWidth == 36)
        #expect(compact.layout.titleMinimumWidth == 20)
        #expect(compact.layout.timeLayoutPriority > compact.layout.categoryLayoutPriority)
        #expect(compact.layout.categoryLayoutPriority > compact.layout.titleLayoutPriority)

        let regular = CalendarItemRowPresentation.make(
            availableContentWidth: 142,
            categoryName: "工作",
            timeRange: range,
            title: "产品同步会"
        )
        #expect(regular.categoryName == "工作")
        #expect(regular.timeText == "09:00")
    }

    @Test func compactTimedRowUsesReadableCategoryPrefixInsteadOfMeaninglessEllipsis() throws {
        let range = try LocalTimeRange(
            start: .init(hour: 9, minute: 0)!,
            end: .init(hour: 10, minute: 0)!
        )

        let compact = CalendarItemRowPresentation.make(
            availableContentWidth: 112,
            categoryName: "重点客户项目",
            timeRange: range,
            title: "需要被合理省略的长标题"
        )

        #expect(compact.categoryName == "重点…")
        #expect(compact.categoryName != "…")
        #expect(compact.timeText == "09:00")
        #expect(compact.title == "需要被合理省略的长标题")
    }

    @Test func narrowUntimedRowAlsoKeepsReadableCategoryPrefixAndTitle() {
        let compact = CalendarItemRowPresentation.make(
            availableContentWidth: 112,
            categoryName: "重点客户项目",
            timeRange: nil,
            title: "需要被合理省略的长标题"
        )

        #expect(compact.categoryName == "重点…")
        #expect(compact.categoryName != "…")
        #expect(compact.categoryName != nil)
        #expect(compact.timeText == nil)
        #expect(compact.title == "需要被合理省略的长标题")
        #expect(compact.layout.categoryMinimumWidth == 24)
        #expect(compact.layout.categoryMaximumWidth == 36)
        #expect(compact.layout.categoryLayoutPriority > compact.layout.titleLayoutPriority)
        #expect(compact.layout.titleMinimumWidth == 20)
    }
}
