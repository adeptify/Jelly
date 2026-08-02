import CalendarDomain
import Combine
import Foundation

enum ItemEditorMode: Equatable {
    case create
    case editItem(CalendarItem)
    case editOccurrence(
        series: WeeklySeries,
        key: OccurrenceKey,
        scope: SeriesScope
    )
}

enum ItemEditorError: Error, Equatable {
    case emptyTitle
    case invalidTimeRange
    case emptyWeekdays
    case invalidRecurrenceEnd
    case noOccurrenceInRange
    case invalidEditorMode
}

@MainActor
final class ItemEditorViewModel: ObservableObject {
    let mode: ItemEditorMode
    private let originalDraft: ItemDraft
    @Published var draft: ItemDraft
    @Published private(set) var validationMessage: String?

    init(mode: ItemEditorMode, draft: ItemDraft) {
        self.mode = mode
        originalDraft = draft
        self.draft = draft
        validationMessage = nil
    }

    func makeCommand(
        now: Date,
        newItemID: UUID,
        newSeriesID: UUID,
        timeZoneIdentifier: String
    ) throws -> CalendarCommand {
        do {
            let normalizedTitle = try validatedTitle()
            let timeRange = try validatedTimeRange()

            switch mode {
            case .create:
                if draft.repeatsWeekly {
                    try validateWeeklyRule(starting: draft.date)
                    return .createSeries(try WeeklySeries(
                        id: newSeriesID,
                        kind: draft.kind,
                        title: normalizedTitle,
                        categoryID: draft.categoryID,
                        startDate: draft.date,
                        endDate: draft.recurrenceEndDate,
                        weekdays: draft.weekdays,
                        timeRange: timeRange,
                        creationTimeZoneIdentifier: timeZoneIdentifier,
                        createdAt: now,
                        updatedAt: now
                    ))
                }
                return .createItem(try CalendarItem(
                    id: newItemID,
                    kind: draft.kind,
                    title: normalizedTitle,
                    categoryID: draft.categoryID,
                    date: draft.date,
                    timeRange: timeRange,
                    creationTimeZoneIdentifier: timeZoneIdentifier,
                    completedAt: nil,
                    createdAt: now,
                    updatedAt: now
                ))

            case let .editItem(original):
                guard !draft.repeatsWeekly else {
                    throw ItemEditorError.invalidEditorMode
                }
                return .updateItem(try CalendarItem(
                    id: original.id,
                    kind: draft.kind,
                    title: normalizedTitle,
                    categoryID: draft.categoryID,
                    date: draft.date,
                    timeRange: timeRange,
                    creationTimeZoneIdentifier: original.creationTimeZoneIdentifier,
                    completedAt: draft.kind == .task ? original.completedAt : nil,
                    createdAt: original.createdAt,
                    updatedAt: now
                ))

            case let .editOccurrence(_, key, scope):
                if scope == .thisAndFuture,
                   draft.weekdays != originalDraft.weekdays ||
                   draft.recurrenceEndDate != originalDraft.recurrenceEndDate {
                    try validateWeeklyRule(starting: key.originalDate)
                }
                return .mutateSeries(
                    key,
                    scope: scope,
                    edit: .patch(makePatch(normalizedTitle: normalizedTitle, timeRange: timeRange, scope: scope)),
                    newSeriesID: newSeriesID
                )
            }
        } catch let error as ItemEditorError {
            validationMessage = error.message
            throw error
        } catch let error as DomainValidationError {
            let editorError = ItemEditorError(domainError: error)
            validationMessage = editorError.message
            throw editorError
        } catch {
            validationMessage = ItemEditorError.invalidEditorMode.message
            throw ItemEditorError.invalidEditorMode
        }
    }

    func makeDeleteCommand(newSeriesID: UUID) throws -> CalendarCommand {
        validationMessage = nil
        switch mode {
        case .create:
            validationMessage = ItemEditorError.invalidEditorMode.message
            throw ItemEditorError.invalidEditorMode
        case let .editItem(item):
            return .deleteItem(item.id)
        case let .editOccurrence(_, key, scope):
            return .mutateSeries(key, scope: scope, edit: .delete, newSeriesID: newSeriesID)
        }
    }

    private func validatedTitle() throws -> String {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw ItemEditorError.emptyTitle
        }
        return title
    }

    private func validatedTimeRange() throws -> LocalTimeRange? {
        guard draft.usesTime else {
            return nil
        }
        do {
            return try LocalTimeRange(start: draft.start, end: draft.end)
        } catch {
            throw ItemEditorError.invalidTimeRange
        }
    }

    private func validateWeeklyRule(starting start: CalendarDate) throws {
        guard !draft.weekdays.isEmpty else {
            throw ItemEditorError.emptyWeekdays
        }
        guard let end = draft.recurrenceEndDate else {
            return
        }
        guard end >= start else {
            throw ItemEditorError.invalidRecurrenceEnd
        }
        var candidate = start
        while candidate <= end {
            if draft.weekdays.contains(candidate.weekday) {
                return
            }
            candidate = candidate.addingDays(1)
        }
        throw ItemEditorError.noOccurrenceInRange
    }

    private func makePatch(
        normalizedTitle: String,
        timeRange: LocalTimeRange?,
        scope: SeriesScope
    ) -> SeriesPatch {
        let originalTitle = originalDraft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalRange = originalDraft.usesTime
            ? try? LocalTimeRange(start: originalDraft.start, end: originalDraft.end)
            : nil
        let updatedRange = timeRange
        let timePatch: OptionalPatch<LocalTimeRange>
        if originalRange == updatedRange {
            timePatch = .unchanged
        } else if let updatedRange {
            timePatch = .set(updatedRange)
        } else {
            timePatch = .clear
        }

        var patch = SeriesPatch(
            title: normalizedTitle == originalTitle ? nil : normalizedTitle,
            kind: draft.kind == originalDraft.kind ? nil : draft.kind,
            categoryID: draft.categoryID == originalDraft.categoryID ? nil : draft.categoryID,
            timeRange: timePatch,
            displayedDate: draft.date == originalDraft.date ? nil : draft.date
        )
        if scope == .thisAndFuture {
            patch.weekdays = draft.weekdays == originalDraft.weekdays ? nil : draft.weekdays
            switch (originalDraft.recurrenceEndDate, draft.recurrenceEndDate) {
            case (nil, nil):
                patch.endDate = .unchanged
            case let (.some(old), .some(new)) where old == new:
                patch.endDate = .unchanged
            case (_, .none):
                patch.endDate = .clear
            case let (_, .some(end)):
                patch.endDate = .set(end)
            }
        }
        return patch
    }
}

private extension ItemEditorError {
    init(domainError: DomainValidationError) {
        switch domainError {
        case .emptyTitle: self = .emptyTitle
        case .invalidTimeRange: self = .invalidTimeRange
        case .emptyWeekdaySet: self = .emptyWeekdays
        case .invalidRecurrenceEnd: self = .invalidRecurrenceEnd
        case .noOccurrenceInRange: self = .noOccurrenceInRange
        case .eventCannotComplete, .invalidTimeZoneIdentifier: self = .invalidEditorMode
        }
    }

    var message: String {
        switch self {
        case .emptyTitle: "请填写标题"
        case .invalidTimeRange: "结束时间必须晚于开始时间"
        case .emptyWeekdays: "请至少选择一个重复日"
        case .invalidRecurrenceEnd: "结束日期不能早于开始日期"
        case .noOccurrenceInRange: "重复范围内至少需要包含一次"
        case .invalidEditorMode: "当前事项不能这样编辑"
        }
    }
}
