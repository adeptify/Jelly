import Foundation

public enum CalendarCommand: Sendable {
    case createItem(CalendarItem)
    case updateItem(CalendarItem)
    case deleteItem(UUID)
    /// Shifts an item's entire schedule so that it starts on the destination day.
    case moveItem(UUID, to: CalendarDate)
    /// Atomically moves several one-off items to the same destination day.
    case moveItems([UUID], to: CalendarDate)
    case setTaskCompleted(UUID, Date?)
    case setOccurrenceCompleted(OccurrenceKey, Date?)
    case setItemPriority(UUID, ItemPriority)
    case setItemPinned(UUID, Bool)
    /// Sets `untimedRank` for untimed single-day items on one civil day.
    case reorderUntimedItems(on: CalendarDate, orderedIDs: [UUID])
    case createSeries(WeeklySeries)
    case mutateSeries(
        OccurrenceKey,
        scope: SeriesScope,
        edit: SeriesEdit,
        newSeriesID: UUID
    )
    case createCategory(CalendarCategory)
    case updateCategory(CalendarCategory)
    case reorderCategories([UUID])
    case deleteCategory(UUID, migrateTo: UUID)
}

public enum ReducerError: Error, Equatable, Sendable {
    case missingItem
    case missingSeries
    case unknownCategory
    case duplicateCategoryName
    case invalidCategoryColor
    case invalidCategoryOrder
    case protectedCategory
    case invalidMigrationTarget
    case eventCannotComplete
    case invalidState
}
