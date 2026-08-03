import CalendarDomain
import Combine
import Foundation

@MainActor
final class MonthViewModel: ObservableObject {
    @Published private(set) var state: CalendarState
    @Published private(set) var hiddenCategoryIDs: Set<UUID>
    @Published private(set) var today: CalendarDate

    private(set) var weekStream: WeekStreamModel
    private(set) var loadedRange: CalendarDateRange

    private var timelineProjection = TimelineProjection(entries: [])
    private var itemLookup: [String: ProjectedItem] = [:]

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

    func item(withID id: String) -> ProjectedItem? {
        itemLookup[id]
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
        rebuildItemLookup()
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

    func goToPreviousMonth() {
        moveFocus(to: weekStream.jumpTargetForPreviousMonth(), preservingCivilDayIntent: true)
    }

    func goToNextMonth() {
        moveFocus(to: weekStream.jumpTargetForNextMonth(), preservingCivilDayIntent: true)
    }

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
        rebuildItemLookup()
    }

    private func rebuildItemLookup() {
        itemLookup = Dictionary(
            uniqueKeysWithValues: timelineProjection.entries.map {
                let item = ProjectedItem(entry: $0)
                return (item.id, item)
            }
        )
    }

    private static func range(for weekStarts: [CalendarDate]) -> CalendarDateRange {
        CalendarDateRange(
            start: weekStarts[0],
            end: weekStarts[weekStarts.count - 1].addingDays(6)
        )
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
