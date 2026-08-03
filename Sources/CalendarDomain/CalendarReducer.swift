import Foundation

public enum CalendarReducer {
    public static func reduce(
        _ state: CalendarState,
        command: CalendarCommand,
        now: Date
    ) throws -> CalendarState {
        try CalendarStateValidator.validate(state)
        var result = state

        switch command {
        case let .createItem(item):
            guard result.items[item.id] == nil else {
                throw ReducerError.invalidState
            }
            try requireKnownCategory(item.categoryID, in: result)
            result.items[item.id] = item

        case let .updateItem(item):
            guard let stored = result.items[item.id] else {
                throw ReducerError.missingItem
            }
            try requireKnownCategory(item.categoryID, in: result)
            var updated = item
            updated.createdAt = stored.createdAt
            updated.updatedAt = now
            if updated.kind == .event {
                updated.completedAt = nil
            }
            result.items[updated.id] = updated

        case let .deleteItem(id):
            guard result.items.removeValue(forKey: id) != nil else {
                throw ReducerError.missingItem
            }

        case let .moveItem(id, destination):
            guard var item = result.items[id] else {
                throw ReducerError.missingItem
            }
            let delta = item.schedule.startDate.days(until: destination)
            item.schedule = try item.schedule.shifted(byDays: delta)
            item.updatedAt = now
            result.items[id] = item

        case let .setTaskCompleted(id, completedAt):
            guard var item = result.items[id] else {
                throw ReducerError.missingItem
            }
            guard item.kind == .task else {
                throw ReducerError.eventCannotComplete
            }
            item.completedAt = completedAt
            item.updatedAt = now
            result.items[id] = item

        case let .setOccurrenceCompleted(key, completedAt):
            let kind = try completableKind(for: key, in: result.recurrence)
            guard kind == .task else {
                throw ReducerError.eventCannotComplete
            }
            if let completedAt {
                result.recurrence.completions[key] = .init(key: key, completedAt: completedAt)
            } else {
                result.recurrence.completions.removeValue(forKey: key)
            }

        case let .createSeries(series):
            guard result.recurrence.series[series.id] == nil else {
                throw ReducerError.invalidState
            }
            try requireKnownCategory(series.categoryID, in: result)
            result.recurrence.series[series.id] = series

        case let .mutateSeries(key, scope, edit, newSeriesID):
            guard result.recurrence.series[key.seriesID] != nil else {
                throw ReducerError.missingSeries
            }
            if case let .patch(patch) = edit, let categoryID = patch.categoryID {
                try requireKnownCategory(categoryID, in: result)
            }
            result.recurrence = try SeriesMutationEngine.apply(
                edit: edit,
                to: key,
                scope: scope,
                in: result.recurrence,
                newSeriesID: newSeriesID,
                now: now
            )

        case let .createCategory(category):
            guard result.categories[category.id] == nil else {
                throw ReducerError.invalidState
            }
            var created = category
            created.name = created.name.trimmingCharacters(in: .whitespacesAndNewlines)
            created.colorHex = created.colorHex.uppercased()
            try validateCategoryInput(created, in: result, excluding: nil)
            created.sortIndex = (result.categories.values.map(\.sortIndex).max() ?? -1) + 1
            result.categories[created.id] = created

        case let .updateCategory(category):
            guard let stored = result.categories[category.id] else {
                throw ReducerError.unknownCategory
            }
            var updated = category
            updated.name = updated.name.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.colorHex = updated.colorHex.uppercased()
            if updated.id == result.uncategorizedID,
               (updated.name != "未分类" || updated.colorHex != "#8E8E93") {
                throw ReducerError.protectedCategory
            }
            try validateCategoryInput(updated, in: result, excluding: updated.id)
            updated.sortIndex = stored.sortIndex
            updated.createdAt = stored.createdAt
            updated.updatedAt = now
            result.categories[updated.id] = updated

        case let .reorderCategories(ids):
            let currentIDs = Set(result.categories.keys)
            guard ids.count == currentIDs.count, Set(ids) == currentIDs else {
                throw ReducerError.invalidCategoryOrder
            }
            for (index, id) in ids.enumerated() {
                guard var category = result.categories[id] else {
                    throw ReducerError.invalidCategoryOrder
                }
                category.sortIndex = index
                category.updatedAt = now
                result.categories[id] = category
            }

        case let .deleteCategory(id, migrateTo):
            guard result.categories[id] != nil else {
                throw ReducerError.unknownCategory
            }
            guard id != result.uncategorizedID else {
                throw ReducerError.protectedCategory
            }
            guard migrateTo != id, result.categories[migrateTo] != nil else {
                throw ReducerError.invalidMigrationTarget
            }
            result.categories.removeValue(forKey: id)
            result.items = result.items.mapValues { item in
                var migrated = item
                if migrated.categoryID == id {
                    migrated.categoryID = migrateTo
                    migrated.updatedAt = now
                }
                return migrated
            }
            result.recurrence.series = result.recurrence.series.mapValues { series in
                var migrated = series
                if migrated.categoryID == id {
                    migrated.categoryID = migrateTo
                    migrated.updatedAt = now
                }
                return migrated
            }
            result.recurrence.exceptions = result.recurrence.exceptions.mapValues { exception in
                guard case var .modified(override) = exception else {
                    return exception
                }
                if override.categoryID == id {
                    override.categoryID = migrateTo
                }
                return .modified(override)
            }
            compactCategoryIndices(&result.categories, now: now)
        }

        try CalendarStateValidator.validate(result)
        return result
    }

    private static func requireKnownCategory(_ id: UUID, in state: CalendarState) throws {
        guard state.categories[id] != nil else {
            throw ReducerError.unknownCategory
        }
    }

    private static func validateCategoryInput(
        _ category: CalendarCategory,
        in state: CalendarState,
        excluding excludedID: UUID?
    ) throws {
        guard !category.name.isEmpty else {
            throw ReducerError.invalidState
        }
        guard isValidColor(category.colorHex) else {
            throw ReducerError.invalidCategoryColor
        }
        let candidate = normalizedCategoryName(category.name)
        guard !state.categories.values.contains(where: {
            $0.id != excludedID && normalizedCategoryName($0.name) == candidate
        }) else {
            throw ReducerError.duplicateCategoryName
        }
    }

    private static func completableKind(
        for key: OccurrenceKey,
        in graph: RecurrenceGraph
    ) throws -> ItemKind {
        guard let series = graph.series[key.seriesID] else {
            throw ReducerError.missingSeries
        }
        guard isWithinBounds(key.originalDate, of: series) else {
            throw ReducerError.invalidState
        }
        switch graph.exceptions[key] {
        case .skipped:
            throw ReducerError.invalidState
        case let .modified(override):
            return override.kind
        case nil:
            guard series.weekdays.contains(key.originalDate.weekday) else {
                throw ReducerError.invalidState
            }
            return series.kind
        }
    }

    private static func compactCategoryIndices(
        _ categories: inout [UUID: CalendarCategory],
        now: Date
    ) {
        let ordered = categories.values.sorted {
            $0.sortIndex == $1.sortIndex
                ? $0.id.uuidString < $1.id.uuidString
                : $0.sortIndex < $1.sortIndex
        }
        for (index, stored) in ordered.enumerated() {
            var category = stored
            category.sortIndex = index
            category.updatedAt = now
            categories[category.id] = category
        }
    }
}

public enum CalendarStateValidator {
    public static func validate(_ state: CalendarState) throws {
        guard let uncategorized = state.categories[state.uncategorizedID],
              uncategorized.id == state.uncategorizedID,
              uncategorized.name == "未分类",
              uncategorized.colorHex == "#8E8E93"
        else {
            throw ReducerError.invalidState
        }

        try validateCategories(state.categories)
        for (key, item) in state.items {
            guard key == item.id,
                  state.categories[item.categoryID] != nil,
                  isTrimmedNonEmpty(item.title),
                  TimeZone(identifier: item.creationTimeZoneIdentifier) != nil,
                  isValidSchedule(item.schedule),
                  item.kind != .event || item.completedAt == nil
            else {
                throw ReducerError.invalidState
            }
        }

        for (key, series) in state.recurrence.series {
            guard key == series.id,
                  state.categories[series.categoryID] != nil,
                  isTrimmedNonEmpty(series.title),
                  TimeZone(identifier: series.creationTimeZoneIdentifier) != nil,
                  !series.weekdays.isEmpty,
                  isValidSeriesSchedule(series),
                  isValidSeriesBounds(series)
            else {
                throw ReducerError.invalidState
            }
        }

        for (key, exception) in state.recurrence.exceptions {
            guard let series = state.recurrence.series[key.seriesID],
                  isWithinBounds(key.originalDate, of: series)
            else {
                throw ReducerError.invalidState
            }
            if case let .modified(override) = exception {
                guard state.categories[override.categoryID] != nil,
                      isTrimmedNonEmpty(override.title),
                      isValidSchedule(override.displayedSchedule)
                else {
                    throw ReducerError.invalidState
                }
            }
        }

        for (dictionaryKey, completion) in state.recurrence.completions {
            guard dictionaryKey == completion.key,
                  let series = state.recurrence.series[dictionaryKey.seriesID],
                  isWithinBounds(dictionaryKey.originalDate, of: series),
                  isTaskOccurrence(dictionaryKey, in: state.recurrence)
            else {
                throw ReducerError.invalidState
            }
        }
    }

    private static func validateCategories(_ categories: [UUID: CalendarCategory]) throws {
        var names = Set<String>()
        var indices = Set<Int>()
        for (key, category) in categories {
            guard key == category.id,
                  isTrimmedNonEmpty(category.name),
                  isValidColor(category.colorHex),
                  names.insert(normalizedCategoryName(category.name)).inserted,
                  indices.insert(category.sortIndex).inserted
            else {
                throw ReducerError.invalidState
            }
        }
        guard indices == Set(0..<categories.count) else {
            throw ReducerError.invalidState
        }
    }

    private static func isTaskOccurrence(_ key: OccurrenceKey, in graph: RecurrenceGraph) -> Bool {
        guard let series = graph.series[key.seriesID] else {
            return false
        }
        switch graph.exceptions[key] {
        case .skipped:
            return false
        case let .modified(override):
            return override.kind == .task
        case nil:
            return series.kind == .task && series.weekdays.contains(key.originalDate.weekday)
        }
    }
}

private func isTrimmedNonEmpty(_ value: String) -> Bool {
    !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func isValidSchedule(_ schedule: CalendarSchedule) -> Bool {
    (try? CalendarSchedule(
        startDate: schedule.startDate,
        endDate: schedule.endDate,
        startTime: schedule.startTime,
        endTime: schedule.endTime
    )) == schedule
}

private func normalizedCategoryName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

private func isValidColor(_ color: String) -> Bool {
    let scalars = color.unicodeScalars
    guard scalars.count == 7, scalars.first?.value == 35 else {
        return false
    }
    return scalars.dropFirst().allSatisfy { scalar in
        switch scalar.value {
        case 48...57, 65...70, 97...102:
            true
        default:
            false
        }
    }
}

private func isValidTimeRange(_ timeRange: LocalTimeRange?) -> Bool {
    guard let timeRange else {
        return true
    }
    return timeRange.end > timeRange.start
}

private func isValidSeriesBounds(_ series: WeeklySeries) -> Bool {
    guard let endDate = series.recurrenceEndDate else {
        return true
    }
    guard endDate >= series.ruleStartDate else {
        return false
    }
    var date = series.ruleStartDate
    while date <= endDate {
        if series.weekdays.contains(date.weekday) {
            return true
        }
        date = date.addingDays(1)
    }
    return false
}

private func isValidSeriesSchedule(_ series: WeeklySeries) -> Bool {
    guard series.durationDays >= 1 else {
        return false
    }
    return (try? CalendarSchedule(
        startDate: series.ruleStartDate,
        endDate: series.ruleStartDate.addingDays(series.durationDays - 1),
        startTime: series.startTime,
        endTime: series.endTime
    )) != nil
}

private func isWithinBounds(_ date: CalendarDate, of series: WeeklySeries) -> Bool {
    date >= series.ruleStartDate && (series.recurrenceEndDate.map { date <= $0 } ?? true)
}
