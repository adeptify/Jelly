import CalendarDomain
import Combine
import Foundation

struct MonthCellModel: Identifiable, Equatable {
    let date: CalendarDate
    let isInDisplayedMonth: Bool
    let isToday: Bool
    let items: [ProjectedItem]

    var id: CalendarDate { date }
}

enum MonthLayout {
    static func itemCapacity(cellHeight: CGFloat) -> Int {
        max(1, Int(floor((cellHeight - 28 - 6) / 24)))
    }
}

@MainActor
final class MonthViewModel: ObservableObject {
    @Published private(set) var state: CalendarState
    @Published private(set) var hiddenCategoryIDs: Set<UUID>
    @Published private(set) var today: CalendarDate

    private(set) var weekStream: WeekStreamModel
    private(set) var loadedRange: CalendarDateRange

    private var timelineProjection = TimelineProjection(entries: [])
    private var compatibilityItemsByDate: [CalendarDate: [ProjectedItem]] = [:]
    private var compatibilityItemLookup: [String: ProjectedItem] = [:]

    /// Deprecated through Task 12. The old grid's selection surface delegates to the week stream.
    var selectedDate: CalendarDate? {
        get { weekStream.selectedDate }
        set {
            objectWillChange.send()
            weekStream.updateSelection(to: newValue)
        }
    }

    init(
        displayedMonth: CalendarDate,
        state: CalendarState,
        hiddenCategoryIDs: Set<UUID>,
        today: CalendarDate
    ) {
        let stream = WeekStreamModel(centeredOn: displayedMonth)
        weekStream = stream
        loadedRange = Self.range(for: stream.weekStarts)
        self.state = state
        self.hiddenCategoryIDs = hiddenCategoryIDs
        self.today = today
        rebuildProjection()
    }

    var weekStarts: [CalendarDate] {
        weekStream.weekStarts
    }

    /// Deprecated through Task 12. The old grid's displayed month follows the focus week.
    var displayedMonth: CalendarDate {
        Self.monthStart(weekStream.monthTitleDate)
    }

    var focusWeek: CalendarDate {
        weekStream.focusWeek
    }

    var monthTitleDate: CalendarDate {
        weekStream.monthTitleDate
    }

    var projectedEntries: [ProjectedEntry] {
        timelineProjection.entries
    }

    func cell(for date: CalendarDate) -> MonthCellModel {
        MonthCellModel(
            date: date,
            isInDisplayedMonth: date.year == displayedMonth.year && date.month == displayedMonth.month,
            isToday: date == today,
            items: compatibilityItemsByDate[date, default: []]
        )
    }

    func visibleItems(in cell: MonthCellModel, capacity: Int) -> [ProjectedItem] {
        let slots = max(1, capacity)
        guard cell.items.count > slots else {
            return Array(cell.items.prefix(slots))
        }
        return Array(cell.items.prefix(max(0, slots - 1)))
    }

    func overflowCount(in cell: MonthCellModel, capacity: Int) -> Int {
        max(0, cell.items.count - visibleItems(in: cell, capacity: capacity).count)
    }

    func item(withID id: String) -> ProjectedItem? {
        compatibilityItemLookup[id]
    }

    func weekLayouts(laneCapacity: Int) -> [WeekLayout] {
        WeekSegmentLayout.make(
            entries: projectedEntries,
            weekStarts: weekStarts,
            laneCapacity: laneCapacity
        )
    }

    func update(
        state: CalendarState,
        hiddenCategoryIDs: Set<UUID>,
        today: CalendarDate
    ) {
        self.state = state
        self.hiddenCategoryIDs = hiddenCategoryIDs
        self.today = today
        rebuildProjection()
    }

    func updateFocus(toWeekStarting week: CalendarDate) {
        objectWillChange.send()
        weekStream.updateFocus(toWeekStarting: week)
        rebuildCompatibilityFacade()
    }

    func extendEarlier(visibleWeek: CalendarDate, pixelOffset: CGFloat) -> WeekStreamAnchor {
        objectWillChange.send()
        let anchor = weekStream.extendEarlier(
            visibleWeek: visibleWeek,
            pixelOffset: pixelOffset
        )
        rebuildProjection()
        return anchor
    }

    func extendLater(visibleWeek: CalendarDate, pixelOffset: CGFloat) -> WeekStreamAnchor {
        objectWillChange.send()
        let anchor = weekStream.extendLater(
            visibleWeek: visibleWeek,
            pixelOffset: pixelOffset
        )
        rebuildProjection()
        return anchor
    }

    /// Deprecated through Task 12. It forwards month navigation to the focus-aware week stream.
    func goToPreviousMonth() {
        moveFocus(to: weekStream.jumpTargetForPreviousMonth(), preservingCivilDayIntent: true)
    }

    /// Deprecated through Task 12. It forwards month navigation to the focus-aware week stream.
    func goToNextMonth() {
        moveFocus(to: weekStream.jumpTargetForNextMonth(), preservingCivilDayIntent: true)
    }

    /// Deprecated through Task 12. It forwards Today to the focus-aware week stream.
    func goToToday(_ today: CalendarDate) {
        self.today = today
        selectedDate = today
        moveFocus(
            to: weekStream.todayTarget(today),
            preservingCivilDayIntent: false
        )
    }

    private func moveFocus(to date: CalendarDate, preservingCivilDayIntent: Bool) {
        objectWillChange.send()
        weekStream.moveFocus(to: date, preservingCivilDayIntent: preservingCivilDayIntent)
        ensureWeekIsLoaded(weekStream.focusWeek)
        rebuildProjection()
    }

    private func ensureWeekIsLoaded(_ weekStart: CalendarDate) {
        while weekStart < weekStarts[0] {
            let previousFirst = weekStarts[0]
            _ = weekStream.extendEarlier(visibleWeek: previousFirst, pixelOffset: 0)
            precondition(
                weekStarts[0] < previousFirst,
                "Earlier week-stream extension did not advance toward the target."
            )
        }
        while weekStart > weekStarts[weekStarts.count - 1] {
            let previousLast = weekStarts[weekStarts.count - 1]
            _ = weekStream.extendLater(visibleWeek: previousLast, pixelOffset: 0)
            precondition(
                weekStarts[weekStarts.count - 1] > previousLast,
                "Later week-stream extension did not advance toward the target."
            )
        }
    }

    private func rebuildProjection() {
        let range = Self.range(for: weekStarts)
        let projection = TimelineProjection.make(
            in: range,
            state: state,
            hiddenCategoryIDs: hiddenCategoryIDs
        )
        loadedRange = range
        timelineProjection = projection
        rebuildCompatibilityFacade()
    }

    private func rebuildCompatibilityFacade() {
        let legacyGridRange = Self.legacyGridRange(for: displayedMonth)
        var itemsByDate: [CalendarDate: [ProjectedItem]] = [:]
        var itemLookup: [String: ProjectedItem] = [:]

        for entry in timelineProjection.entries {
            guard entry.schedule.startDate <= legacyGridRange.end,
                  legacyGridRange.start <= entry.schedule.endDate
            else {
                continue
            }
            let item = ProjectedItem(entry: entry)
            let displayDate = max(entry.schedule.startDate, legacyGridRange.start)
            itemsByDate[displayDate, default: []].append(item)
            itemLookup[item.id] = item
        }

        compatibilityItemsByDate = itemsByDate
        compatibilityItemLookup = itemLookup
    }

    private static func range(for weekStarts: [CalendarDate]) -> CalendarDateRange {
        CalendarDateRange(
            start: weekStarts[0],
            end: weekStarts[weekStarts.count - 1].addingDays(6)
        )
    }

    private static func legacyGridRange(for displayedMonth: CalendarDate) -> CalendarDateRange {
        let firstOfMonth = monthStart(displayedMonth)
        let firstGridDate = firstOfMonth.addingDays(-(firstOfMonth.weekday.rawValue - 1))
        return CalendarDateRange(start: firstGridDate, end: firstGridDate.addingDays(41))
    }

    private static func monthStart(_ date: CalendarDate) -> CalendarDate {
        CalendarDate(year: date.year, month: date.month, day: 1)!
    }
}

private extension ProjectedItem {
    init(entry: ProjectedEntry) {
        switch entry {
        case let .item(item):
            self = .item(item)
        case let .occurrence(occurrence):
            self = .occurrence(occurrence)
        }
    }
}
