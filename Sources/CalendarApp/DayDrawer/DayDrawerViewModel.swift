import CalendarDomain
import Combine
import Foundation

@MainActor
final class DayDrawerViewModel: ObservableObject {
    @Published private(set) var date: CalendarDate
    @Published private(set) var items: [ProjectedItem]

    var quickCreateDate: CalendarDate { date }

    init(date: CalendarDate, state: CalendarState, hiddenCategoryIDs: Set<UUID>) {
        self.date = date
        items = Self.project(date: date, state: state, hiddenCategoryIDs: hiddenCategoryIDs)
    }

    func refresh(state: CalendarState, hiddenCategoryIDs: Set<UUID>) {
        items = Self.project(date: date, state: state, hiddenCategoryIDs: hiddenCategoryIDs)
    }

    func retarget(
        date: CalendarDate,
        state: CalendarState,
        hiddenCategoryIDs: Set<UUID>
    ) {
        self.date = date
        items = Self.project(date: date, state: state, hiddenCategoryIDs: hiddenCategoryIDs)
    }

    private static func project(
        date: CalendarDate,
        state: CalendarState,
        hiddenCategoryIDs: Set<UUID>
    ) -> [ProjectedItem] {
        MonthProjection.make(
            monthContaining: date,
            state: state,
            hiddenCategoryIDs: hiddenCategoryIDs
        ).day(date).items
    }
}
