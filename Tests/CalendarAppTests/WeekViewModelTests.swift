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

@Suite("WeekGridCreateSelectionTests")
struct WeekGridCreateSelectionTests {
    @Test func clickWithoutDragDefaultsToOneHourBand() {
        let band = WeekGridCreateSelection.band(
            originDayIndex: 2,
            originMinute: 9 * 60 + 7,
            currentMinute: 9 * 60 + 7,
            isDragging: false
        )
        #expect(band.dayIndex == 2)
        #expect(band.startMinute == 9 * 60) // snapped
        #expect(band.endMinute == 10 * 60)
    }

    @Test func dragDownSelectsMultiHourBand() {
        let band = WeekGridCreateSelection.band(
            originDayIndex: 1,
            originMinute: 10 * 60,
            currentMinute: 12 * 60 + 20,
            isDragging: true
        )
        #expect(band.dayIndex == 1)
        #expect(band.startMinute == 10 * 60)
        #expect(band.endMinute == 12 * 60 + 15) // snap 15
    }

    @Test func dragUpInvertsRange() {
        let band = WeekGridCreateSelection.band(
            originDayIndex: 0,
            originMinute: 14 * 60,
            currentMinute: 11 * 60,
            isDragging: true
        )
        #expect(band.startMinute == 11 * 60)
        #expect(band.endMinute == 14 * 60)
    }

    @Test func intentBuildsTimedSchedule() throws {
        let monday = CalendarDate(year: 2026, month: 8, day: 3)!
        let days = (0..<7).map { monday.addingDays($0) }
        let band = WeekGridCreateSelection.Band(
            dayIndex: 2,
            startMinute: 9 * 60,
            endMinute: 10 * 60 + 30
        )
        let intent = try WeekGridCreateSelection.intent(dayStarts: days, band: band)
        #expect(intent.day == CalendarDate(year: 2026, month: 8, day: 5)!)
        #expect(intent.endDate == intent.day)
        #expect(intent.startTime.value == 9 * 60)
        #expect(intent.endTime.value == 10 * 60 + 30)
    }

    @Test func quickCreatePresentationKeepsDraggedEndTime() {
        let day = CalendarDate(year: 2026, month: 8, day: 5)!
        let presentation = QuickCreatePresentation.forDay(
            day,
            startTime: MinuteOfDay(hour: 13, minute: 0)!,
            endTime: MinuteOfDay(hour: 15, minute: 30)!,
            endDate: day
        )
        #expect(presentation.startTime?.value == 13 * 60)
        #expect(presentation.endTime?.value == 15 * 60 + 30)
        #expect(presentation.range.start == day)
        #expect(presentation.range.end == day)
    }
}

@Suite("ItemEditorTimePolicyTests")
@MainActor
struct ItemEditorTimePolicyTests {
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
        #expect(
            CalendarItemRowPresentation.displayTimeText(for: sameDay, style: .startOnly) == "09:30"
        )

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
