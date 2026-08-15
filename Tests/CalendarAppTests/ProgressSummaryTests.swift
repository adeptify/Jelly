import CalendarDomain
import Foundation
import Testing
@testable import CalendarApp

@Suite struct ProgressSummaryTests {
    @Test func overviewUsesTheFourProductFactsInAStableOrder() {
        #expect(ProgressSummaryOverview.allCases == [.completed, .open, .overdue, .categories])
        #expect(ProgressSummaryOverview.completed.title == "已完成")
        #expect(ProgressSummaryOverview.open.title == "未完成")
        #expect(ProgressSummaryOverview.overdue.title == "已延期")
        #expect(ProgressSummaryOverview.categories.title == "分类分布")
    }

    @Test func overviewDrillsIntoEveryMatchingItemWithoutTruncation() throws {
        let today = try #require(CalendarDate(year: 2026, month: 8, day: 14))
        let completed = ProgressItemFact(
            id: "completed",
            calendarItemID: UUID(),
            title: "已经完成",
            date: today,
            isOverdue: false
        )
        let overdue = ProgressItemFact(
            id: "overdue",
            calendarItemID: UUID(),
            title: "已经延期",
            date: today,
            isOverdue: true
        )
        let upcoming = ProgressItemFact(
            id: "upcoming",
            calendarItemID: UUID(),
            title: "仍在进行",
            date: today,
            isOverdue: false
        )
        let stats = ProgressSummaryStats(
            range: .current(period: .week, today: today),
            totalItems: 3,
            completedItems: 1,
            openItems: 2,
            overdueItems: 1,
            highPriorityOpen: 0,
            categories: [],
            completed: [completed],
            open: [overdue, upcoming]
        )

        #expect(ProgressSummaryOverview.completed.items(in: stats) == [completed])
        #expect(ProgressSummaryOverview.open.items(in: stats) == [overdue, upcoming])
        #expect(ProgressSummaryOverview.overdue.items(in: stats) == [overdue])
    }

    @Test func migrationPromptRequiresAnExplicitConfirmation() {
        let prompt = ProgressMigrationPrompt(period: .week, selectedCount: 2)

        #expect(prompt.title == "确认移到下周？")
        #expect(prompt.message == "将选中的 2 件一次性事项移到下周。重复事项不会改变。")
        #expect(prompt.confirmationTitle == "确认移到下周")
    }

    @Test func periodTitlesDescribeAFactualReview() {
        #expect(ProgressSummaryPeriod.week.title == "本周回顾")
        #expect(ProgressSummaryPeriod.month.title == "本月回顾")
    }

    @Test func reportUsesOnlyDeterministicCalendarFacts() throws {
        let today = try #require(CalendarDate(year: 2026, month: 8, day: 14))
        let stats = ProgressSummaryStats(
            range: .current(period: .week, today: today),
            totalItems: 4,
            completedItems: 1,
            openItems: 3,
            overdueItems: 2,
            highPriorityOpen: 1,
            categories: [],
            completed: [],
            open: []
        )

        let first = ProgressSummaryEngine.report(from: stats)
        let second = ProgressSummaryEngine.report(from: stats)

        #expect(first == second)
        #expect(first.factualSummary == "已完成 1 件，仍有 3 件，其中 2 件已延期。")
    }

    @Test func emptyReviewDoesNotInventEncouragement() throws {
        let today = try #require(CalendarDate(year: 2026, month: 8, day: 14))
        let stats = ProgressSummaryStats(
            range: .current(period: .month, today: today),
            totalItems: 0,
            completedItems: 0,
            openItems: 0,
            overdueItems: 0,
            highPriorityOpen: 0,
            categories: [],
            completed: [],
            open: []
        )

        #expect(ProgressSummaryEngine.report(from: stats).factualSummary == "这一时段还没有事项。")
    }
}
