import CalendarDomain
import Foundation
import Testing
@testable import CalendarApp

@Suite("WeekViewModelTests")
struct WeekViewModelTests {
    @Test func timedBlocksSplitCrossDayEventsAcrossColumns() throws {
        let weekStart = CalendarDate(year: 2026, month: 8, day: 3)! // Monday
        let item = try CalendarItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000701")!,
            kind: .event,
            title: "跨夜发布",
            categoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            schedule: try CalendarSchedule(
                startDate: CalendarDate(year: 2026, month: 8, day: 4)!,
                endDate: CalendarDate(year: 2026, month: 8, day: 5)!,
                startTime: MinuteOfDay(hour: 22, minute: 0)!,
                endTime: MinuteOfDay(hour: 1, minute: 30)!
            ),
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let blocks = WeekViewModel.timedBlocks(
            entries: [.item(item)],
            weekStart: weekStart
        )
        #expect(blocks.count == 2)
        #expect(blocks[0].dayIndex == 1)
        #expect(blocks[0].startMinute == 22 * 60)
        #expect(blocks[0].endMinute == 24 * 60)
        #expect(blocks[1].dayIndex == 2)
        #expect(blocks[1].startMinute == 0)
        #expect(blocks[1].endMinute == 90)
    }

    @Test func sameDayTimedBlockKeepsMinutePrecisionIncludingMidnightStart() throws {
        let weekStart = CalendarDate(year: 2026, month: 8, day: 3)!
        let item = try CalendarItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000702")!,
            kind: .event,
            title: "夜跑",
            categoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            schedule: try CalendarSchedule(
                startDate: CalendarDate(year: 2026, month: 8, day: 5)!,
                endDate: CalendarDate(year: 2026, month: 8, day: 5)!,
                startTime: MinuteOfDay(hour: 0, minute: 0)!,
                endTime: MinuteOfDay(hour: 0, minute: 45)!
            ),
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let blocks = WeekViewModel.timedBlocks(
            entries: [.item(item)],
            weekStart: weekStart
        )
        #expect(blocks.count == 1)
        #expect(blocks[0].startMinute == 0)
        #expect(blocks[0].endMinute == 45)
    }

    @Test func untimedItemsAreExcludedFromTimedBlocks() throws {
        let weekStart = CalendarDate(year: 2026, month: 8, day: 3)!
        let item = try CalendarItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000703")!,
            kind: .task,
            title: "买菜",
            categoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            schedule: try CalendarSchedule(
                startDate: CalendarDate(year: 2026, month: 8, day: 4)!,
                endDate: CalendarDate(year: 2026, month: 8, day: 4)!,
                startTime: nil,
                endTime: nil
            ),
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let blocks = WeekViewModel.timedBlocks(
            entries: [.item(item)],
            weekStart: weekStart
        )
        #expect(blocks.isEmpty)
    }
}

@Suite("ItemEditorTimePolicyTests")
@MainActor
struct ItemEditorTimePolicyTests {
    @Test func selectingEventEnablesMinutePrecisionTime() {
        let draft = ItemDraft.newItem(
            from: CalendarDate(year: 2026, month: 8, day: 4)!,
            through: CalendarDate(year: 2026, month: 8, day: 4)!,
            categoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        #expect(draft.usesTime == false)
        let model = ItemEditorViewModel(mode: .create, draft: draft)
        model.draft.kind = .event
        model.kindDidChange(from: .task)
        #expect(model.draft.usesTime == true)
        #expect(model.draft.startTime == MinuteOfDay(hour: 9, minute: 0)!)
    }

    @Test func enablingTimeNormalizesInvertedSameDayRange() {
        var draft = ItemDraft.newItem(
            from: CalendarDate(year: 2026, month: 8, day: 4)!,
            through: CalendarDate(year: 2026, month: 8, day: 4)!,
            categoryID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        draft.usesTime = true
        draft.startTime = MinuteOfDay(hour: 10, minute: 0)!
        draft.endTime = MinuteOfDay(hour: 9, minute: 0)!
        let model = ItemEditorViewModel(mode: .create, draft: draft)
        model.usesTimeDidChange()
        #expect(model.draft.endTime > model.draft.startTime)
    }
}

@Suite("CalendarItemTimeDisplayTests")
struct CalendarItemTimeDisplayTests {
    @Test func displayTimeTextShowsRangeOnSameDayAndStartOnlyAcrossDays() throws {
        let sameDay = try CalendarSchedule(
            startDate: CalendarDate(year: 2026, month: 8, day: 4)!,
            endDate: CalendarDate(year: 2026, month: 8, day: 4)!,
            startTime: MinuteOfDay(hour: 9, minute: 30)!,
            endTime: MinuteOfDay(hour: 10, minute: 15)!
        )
        #expect(CalendarItemRowPresentation.displayTimeText(for: sameDay) == "09:30–10:15")

        let midnight = try CalendarSchedule(
            startDate: CalendarDate(year: 2026, month: 8, day: 4)!,
            endDate: CalendarDate(year: 2026, month: 8, day: 4)!,
            startTime: MinuteOfDay(hour: 0, minute: 0)!,
            endTime: MinuteOfDay(hour: 0, minute: 30)!
        )
        #expect(CalendarItemRowPresentation.displayTimeText(for: midnight) == "00:00–00:30")

        let multi = try CalendarSchedule(
            startDate: CalendarDate(year: 2026, month: 8, day: 4)!,
            endDate: CalendarDate(year: 2026, month: 8, day: 5)!,
            startTime: MinuteOfDay(hour: 22, minute: 0)!,
            endTime: MinuteOfDay(hour: 1, minute: 0)!
        )
        #expect(CalendarItemRowPresentation.displayTimeText(for: multi) == "22:00")
    }
}
