import CalendarDomain
import Foundation

/// Builds factual stats for progress summary from calendar state (no network).
enum ProgressSummaryEngine {
    static func stats(
        state: CalendarState,
        period: ProgressSummaryPeriod,
        today: CalendarDate,
        hiddenCategoryIDs: Set<UUID> = []
    ) -> ProgressSummaryStats {
        let range = ProgressSummaryRange.current(period: period, today: today)
        let timeline = TimelineProjection.make(
            in: CalendarDateRange(start: range.start, end: range.end),
            state: state,
            hiddenCategoryIDs: hiddenCategoryIDs
        )

        var seen = Set<ProjectedEntryID>()
        var total = 0
        var completed = 0
        var highPriorityOpen = 0
        var perCategory: [UUID: (name: String, hex: String, total: Int, completed: Int)] = [:]

        for entry in timeline.entries {
            guard seen.insert(entry.id).inserted else { continue }
            let projected = projectedItem(from: entry)
            total += 1
            let isDone = projected.completedAt != nil
            if isDone {
                completed += 1
            } else if projected.priority == .p0 || projected.priority == .p1 {
                highPriorityOpen += 1
            }

            let categoryID = projected.categoryID
            let category = state.categories[categoryID]
            let name = category?.name ?? "未分类"
            let hex = category?.colorHex ?? "#8C8F96"
            var bucket = perCategory[categoryID] ?? (name, hex, 0, 0)
            bucket.total += 1
            if isDone { bucket.completed += 1 }
            perCategory[categoryID] = bucket
        }

        let categoryStats = perCategory.map { id, value in
            ProgressCategoryStat(
                id: id,
                name: value.name,
                colorHex: value.hex,
                total: value.total,
                completed: value.completed
            )
        }
        .sorted {
            if $0.total != $1.total { return $0.total > $1.total }
            return $0.name < $1.name
        }

        return ProgressSummaryStats(
            range: range,
            totalItems: total,
            completedItems: completed,
            openItems: total - completed,
            highPriorityOpen: highPriorityOpen,
            categories: categoryStats
        )
    }

    private static func projectedItem(from entry: ProjectedEntry) -> ProjectedItem {
        switch entry {
        case let .item(item): .item(item)
        case let .occurrence(occurrence): .occurrence(occurrence)
        }
    }
}
