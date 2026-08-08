import CalendarDomain
import Foundation
import Testing

@Suite("ItemNotesPersistenceTests")
struct ItemNotesPersistenceTests {
    @Test func calendarItemDecodesMissingNotesAsEmpty() throws {
        let item = try CalendarItem(
            id: UUID(),
            kind: .task,
            title: "无随记",
            categoryID: UUID(),
            schedule: try CalendarSchedule(
                startDate: CalendarDate(year: 2026, month: 8, day: 8)!,
                endDate: CalendarDate(year: 2026, month: 8, day: 8)!,
                startTime: nil,
                endTime: nil
            ),
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        var encoded = try JSONEncoder().encode(item)
        // Drop notes key to simulate older documents.
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object.removeValue(forKey: "notes")
        encoded = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(CalendarItem.self, from: encoded)
        #expect(decoded.notes == "")
    }

    @Test func calendarItemRoundTripsNotes() throws {
        let notes = "## 准备\n- [ ] 议程\n1. 开场"
        let item = try CalendarItem(
            id: UUID(),
            kind: .task,
            title: "评审",
            categoryID: UUID(),
            schedule: try CalendarSchedule(
                startDate: CalendarDate(year: 2026, month: 8, day: 8)!,
                endDate: CalendarDate(year: 2026, month: 8, day: 8)!,
                startTime: MinuteOfDay(hour: 10, minute: 0)!,
                endTime: MinuteOfDay(hour: 11, minute: 0)!
            ),
            notes: notes,
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(CalendarItem.self, from: data)
        #expect(decoded.notes == notes)
    }

    @Test func weeklySeriesAndOverrideRoundTripNotes() throws {
        let series = try WeeklySeries(
            id: UUID(),
            kind: .task,
            title: "站会",
            categoryID: UUID(),
            ruleStartDate: CalendarDate(year: 2026, month: 8, day: 3)!,
            recurrenceEndDate: nil,
            weekdays: [.monday],
            durationDays: 1,
            startTime: MinuteOfDay(hour: 9, minute: 30)!,
            endTime: MinuteOfDay(hour: 9, minute: 45)!,
            notes: "系列随记",
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        let data = try JSONEncoder().encode(series)
        let decoded = try JSONDecoder().decode(WeeklySeries.self, from: data)
        #expect(decoded.notes == "系列随记")

        let override = OccurrenceOverride(
            displayedSchedule: try CalendarSchedule(
                startDate: CalendarDate(year: 2026, month: 8, day: 10)!,
                endDate: CalendarDate(year: 2026, month: 8, day: 10)!,
                startTime: nil,
                endTime: nil
            ),
            title: "站会",
            kind: .task,
            categoryID: series.categoryID,
            notes: "仅本次随记"
        )
        let oData = try JSONEncoder().encode(override)
        let oDecoded = try JSONDecoder().decode(OccurrenceOverride.self, from: oData)
        #expect(oDecoded.notes == "仅本次随记")
    }
}
