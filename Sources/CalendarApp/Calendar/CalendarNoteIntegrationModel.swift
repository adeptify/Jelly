import CalendarDomain
import Foundation
import WorkspaceDomain

enum CalendarNotePresentedSheet: Equatable, Sendable {
    case legacyNotesResolution(NoteID)
    case notePicker(isPrimary: Bool)
    case scheduleNote(NoteID)
}

/// Main-actor integration surface between calendar items and Notes relations.
@MainActor
@Observable final class CalendarNoteIntegrationModel {
    private let store: WorkspaceStore
    private let clock: @Sendable () -> Date
    let target: CalendarTargetID

    private(set) var resolved: ResolvedCalendarNoteRelation?
    private(set) var presentedSheet: CalendarNotePresentedSheet?
    private(set) var statusMessage: String?

    init(
        target: CalendarTargetID,
        store: WorkspaceStore,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.target = target
        self.store = store
        self.clock = clock
        refresh()
    }

    var primaryNote: Note? {
        resolved.flatMap { set in
            set.noteSet.primaryNoteID.flatMap { store.state.notes[$0] }
        }
    }

    var referenceNotes: [Note] {
        guard let set = resolved?.noteSet else { return [] }
        return set.referenceNoteIDs
            .compactMap { store.state.notes[$0] }
            .sorted {
                $0.updatedAt != $1.updatedAt
                    ? $0.updatedAt > $1.updatedAt
                    : $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
            }
    }

    var hasLegacyMarkdown: Bool {
        legacyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var legacyMarkdown: String {
        switch target {
        case let .item(id):
            return store.calendarState.items[id]?.notes ?? ""
        case let .series(id):
            return store.calendarState.recurrence.series[id]?.notes ?? ""
        case let .occurrence(key):
            return store.calendarState.recurrence.series[key.seriesID]?.notes ?? ""
        }
    }

    func refresh() {
        do {
            resolved = try CalendarNoteRelationResolver.resolve(
                target,
                calendar: store.calendarState,
                relations: store.state.calendarNoteRelations
            )
            statusMessage = nil
        } catch {
            resolved = nil
            statusMessage = "无法解析笔记关系。"
        }
    }

    func scopeForItemActions() -> CalendarRelationScope {
        switch target {
        case let .item(id): .item(id)
        case let .series(id): .series(id)
        case let .occurrence(key): .occurrenceOnly(key)
        }
    }

    @discardableResult
    func createPrimaryNote() async throws -> Bool {
        let now = clock()
        let note = Note.empty(
            id: NoteID(),
            categoryID: store.calendarState.uncategorizedID,
            now: now
        )
        if hasLegacyMarkdown {
            // Domain requires explicit legacy authorization for nonempty legacy
            // notes; without a preview authorization we refuse rather than drop text.
            presentedSheet = nil
            statusMessage = "存在旧随记，请先选择预览并合并或另建主笔记。"
            return false
        }
        let payload = CreatePrimaryNoteForCalendarPayload(
            scope: scopeForItemActions(),
            note: note,
            legacyImportAuthorization: nil
        )
        let outcome = try await store.sendWorkspace(
            .createPrimaryNoteForCalendar(payload),
            undoLabel: "新建主笔记"
        )
        refresh()
        return isCommitted(outcome)
    }

    @discardableResult
    func chooseExistingPrimary(_ noteID: NoteID) async throws -> Bool {
        if hasLegacyMarkdown {
            presentedSheet = .legacyNotesResolution(noteID)
            // Domain forbids attaching primary while legacy markdown remains.
            return false
        }
        return try await attachPrimary(noteID, legacyResolution: nil)
    }

    @discardableResult
    func attachPrimary(
        _ noteID: NoteID,
        legacyResolution: ExistingPrimaryLegacyResolution?
    ) async throws -> Bool {
        let payload = AttachPrimaryNotePayload(
            scope: scopeForItemActions(),
            noteID: noteID,
            legacyResolution: legacyResolution,
            replacing: resolved?.noteSet.primaryNoteID != nil ? .detachOldPrimary : nil,
            linkedTaskDisposition: nil
        )
        let outcome = try await store.sendWorkspace(
            .attachPrimaryNote(payload),
            undoLabel: "关联主笔记"
        )
        presentedSheet = nil
        refresh()
        return isCommitted(outcome)
    }

    @discardableResult
    func attachReference(_ noteID: NoteID) async throws -> Bool {
        let outcome = try await store.sendWorkspace(
            .attachReferenceNote(scopeForItemActions(), noteID),
            undoLabel: "添加参考笔记"
        )
        refresh()
        return isCommitted(outcome)
    }

    @discardableResult
    func detach(_ noteID: NoteID) async throws -> Bool {
        let outcome = try await store.sendWorkspace(
            .detachNote(scopeForItemActions(), noteID, linkedTaskDisposition: nil),
            undoLabel: "取消关联笔记"
        )
        refresh()
        return isCommitted(outcome)
    }

    @discardableResult
    func scheduleNoteOnCalendar(noteID: NoteID, item: CalendarItem) async throws -> Bool {
        let outcome = try await store.sendWorkspace(
            .scheduleNoteOnCalendar(.init(noteID: noteID, item: item)),
            undoLabel: "从笔记安排到日历"
        )
        refresh()
        return isCommitted(outcome)
    }

    func openNotePicker(isPrimary: Bool) {
        presentedSheet = .notePicker(isPrimary: isPrimary)
    }

    func dismissSheet() {
        presentedSheet = nil
    }

    private func isCommitted(_ outcome: WorkspaceTransactionOutcome) -> Bool {
        if case .committed = outcome { return true }
        return false
    }
}
