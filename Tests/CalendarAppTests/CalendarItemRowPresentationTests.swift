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
        #expect(compact.categoryName == "工")
        #expect(compact.timeText == "09:00")
        #expect(compact.title == "产品同步会")
        #expect(compact.layout.categoryMinimumWidth == 16)
        #expect(compact.layout.categoryMaximumWidth == 16)
        #expect(compact.layout.categoryMinimumWidth == compact.layout.categoryMaximumWidth)
        #expect(compact.layout.categoryFixedWidth == 16)
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

        #expect(compact.categoryName == "重")
        #expect(compact.categoryName != "…")
        #expect(compact.categoryName?.contains("…") == false)
        #expect(compact.timeText == "09:00")
        #expect(compact.title == "需要被合理省略的长标题")
    }

    @Test func minimumWindowContentBoundaryKeepsCategoryTimeAndTitle() throws {
        let range = try LocalTimeRange(
            start: .init(hour: 9, minute: 0)!,
            end: .init(hour: 10, minute: 0)!
        )

        let boundary = CalendarItemRowPresentation.make(
            availableContentWidth: 120,
            categoryName: "工作",
            timeRange: range,
            title: "产品同步会"
        )

        #expect(boundary.categoryName == "工")
        #expect(boundary.timeText == "09:00")
        #expect(boundary.title == "产品同步会")
        #expect(boundary.layout.categoryMinimumWidth == 16)
        #expect(boundary.layout.categoryMaximumWidth == 16)
        #expect(boundary.layout.categoryMinimumWidth == boundary.layout.categoryMaximumWidth)
        #expect(boundary.layout.categoryFixedWidth == 16)
        #expect(boundary.layout.titleMinimumWidth == 20)
        #expect(boundary.layout.timeLayoutPriority > boundary.layout.categoryLayoutPriority)
        #expect(boundary.layout.categoryLayoutPriority > boundary.layout.titleLayoutPriority)
    }

    @Test func minimumWindowGeometryWidthUsesCompactLayoutThrough140Points() throws {
        let range = try LocalTimeRange(
            start: .init(hour: 9, minute: 0)!,
            end: .init(hour: 10, minute: 0)!
        )

        let compact = CalendarItemRowPresentation.make(
            availableContentWidth: 140,
            categoryName: "重点客户项目",
            timeRange: range,
            title: "产品同步会"
        )
        let standard = CalendarItemRowPresentation.make(
            availableContentWidth: 141,
            categoryName: "重点客户项目",
            timeRange: range,
            title: "产品同步会"
        )

        #expect(compact.categoryName == "重")
        #expect(compact.layout.categoryFixedWidth == 16)
        #expect(standard.categoryName == "重点客户项目")
        #expect(standard.layout.categoryFixedWidth == nil)
    }

    @Test func compactCategoryUsesOneCharacterTokenWhileStandardKeepsFullName() {
        let compact = CalendarItemRowPresentation.make(
            availableContentWidth: 140,
            categoryName: "工作",
            timeRange: nil,
            title: "事项"
        )
        let standard = CalendarItemRowPresentation.make(
            availableContentWidth: 141,
            categoryName: "工作",
            timeRange: nil,
            title: "事项"
        )

        #expect(compact.categoryName == "工")
        #expect(compact.categoryName?.contains("…") == false)
        #expect(compact.layout.categoryFixedWidth == 16)
        #expect(standard.categoryName == "工作")
        #expect(standard.layout.categoryFixedWidth == nil)
    }

    @Test func rowBodyAccessibilityLabelKeepsFullValuesInCompactAndStandardLayouts() throws {
        let range = try LocalTimeRange(
            start: .init(hour: 9, minute: 0)!,
            end: .init(hour: 10, minute: 0)!
        )

        let compact = CalendarItemRowPresentation.make(
            availableContentWidth: 140,
            categoryName: "工作",
            timeRange: range,
            title: "产品同步会"
        )
        let standard = CalendarItemRowPresentation.make(
            availableContentWidth: 141,
            categoryName: "工作",
            timeRange: range,
            title: "产品同步会"
        )

        #expect(compact.categoryName == "工")
        #expect(compact.accessibilityLabel == "工作, 09:00, 产品同步会")
        #expect(standard.accessibilityLabel == "工作, 09:00, 产品同步会")
    }

    @Test func rowBodyAccessibilityLabelOmitsTimeForUntimedItems() {
        let presentation = CalendarItemRowPresentation.make(
            availableContentWidth: 112,
            categoryName: "未分类",
            timeRange: nil,
            title: "收集灵感"
        )

        #expect(presentation.accessibilityLabel == "未分类, 收集灵感")
    }

    @Test func narrowUntimedRowAlsoKeepsReadableCategoryPrefixAndTitle() {
        let compact = CalendarItemRowPresentation.make(
            availableContentWidth: 112,
            categoryName: "重点客户项目",
            timeRange: nil,
            title: "需要被合理省略的长标题"
        )

        #expect(compact.categoryName == "重")
        #expect(compact.categoryName != "…")
        #expect(compact.categoryName?.contains("…") == false)
        #expect(compact.categoryName != nil)
        #expect(compact.timeText == nil)
        #expect(compact.title == "需要被合理省略的长标题")
        #expect(compact.layout.categoryMinimumWidth == 16)
        #expect(compact.layout.categoryMaximumWidth == 16)
        #expect(compact.layout.categoryMinimumWidth == compact.layout.categoryMaximumWidth)
        #expect(compact.layout.categoryLayoutPriority > compact.layout.titleLayoutPriority)
        #expect(compact.layout.titleMinimumWidth == 20)
    }
}
