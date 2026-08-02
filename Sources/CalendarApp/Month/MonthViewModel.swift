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
    @Published private(set) var displayedMonth: CalendarDate
    @Published var selectedDate: CalendarDate?
    @Published private(set) var state: CalendarState
    @Published private(set) var hiddenCategoryIDs: Set<UUID>
    @Published private(set) var today: CalendarDate

    private var projection: MonthProjection

    init(
        displayedMonth: CalendarDate,
        state: CalendarState,
        hiddenCategoryIDs: Set<UUID>,
        today: CalendarDate
    ) {
        let monthStart = Self.monthStart(displayedMonth)
        self.displayedMonth = monthStart
        self.state = state
        self.hiddenCategoryIDs = hiddenCategoryIDs
        self.today = today
        projection = MonthProjection.make(
            monthContaining: monthStart,
            state: state,
            hiddenCategoryIDs: hiddenCategoryIDs
        )
    }

    func cell(for date: CalendarDate) -> MonthCellModel {
        MonthCellModel(
            date: date,
            isInDisplayedMonth: date.year == displayedMonth.year && date.month == displayedMonth.month,
            isToday: date == today,
            items: projection.day(date).items
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

    func update(
        state: CalendarState,
        hiddenCategoryIDs: Set<UUID>,
        today: CalendarDate
    ) {
        self.state = state
        self.hiddenCategoryIDs = hiddenCategoryIDs
        self.today = today
        projection = MonthProjection.make(
            monthContaining: displayedMonth,
            state: state,
            hiddenCategoryIDs: hiddenCategoryIDs
        )
    }

    func goToPreviousMonth() {
        displayedMonth = Self.monthStart(displayedMonth.addingDays(-1))
        rebuildProjection()
    }

    func goToNextMonth() {
        displayedMonth = Self.monthStart(displayedMonth.addingDays(32))
        rebuildProjection()
    }

    func goToToday(_ today: CalendarDate) {
        self.today = today
        displayedMonth = Self.monthStart(today)
        selectedDate = today
        rebuildProjection()
    }

    private func rebuildProjection() {
        projection = MonthProjection.make(
            monthContaining: displayedMonth,
            state: state,
            hiddenCategoryIDs: hiddenCategoryIDs
        )
    }

    private static func monthStart(_ date: CalendarDate) -> CalendarDate {
        CalendarDate(year: date.year, month: date.month, day: 1)!
    }
}
