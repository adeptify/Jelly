import Foundation
import Observation
import WorkspaceDomain

enum NotesBrowserPartition: String, CaseIterable, Identifiable, Equatable, Sendable {
    case recent
    case all
    case archived

    var id: Self { self }

    var title: String {
        switch self {
        case .recent: "最近"
        case .all: "全部"
        case .archived: "归档"
        }
    }

    var emptyMessage: String {
        switch self {
        case .recent: "还没有最近编辑的笔记"
        case .all: "还没有笔记"
        case .archived: "归档为空"
        }
    }
}

/// Main-actor Notes state for the still-dormant Task 10 vertical slice.  It
/// derives every browser list from the Store's WorkspaceState; it owns no
/// repository and never mutates workspace collections directly.
@MainActor
@Observable final class NotesWorkspaceViewModel {
    private enum CommittedSelectionEffect {
        case create(NoteID)
        case archive(noteID: NoteID, previousIndex: Int?)
        case restore(noteID: NoteID, previousIndex: Int?)
        case permanentDelete(noteID: NoteID, previousIndex: Int?)
    }

    private struct PendingSelectionMutation {
        let transactionID: UUID
        let effect: CommittedSelectionEffect
    }

    private let store: WorkspaceStore
    private let autosave: NoteAutosaveCoordinator
    private let searchIndex: WorkspaceSearchIndex
    private let clock: @Sendable () -> Date
    private var pendingSelectionMutation: PendingSelectionMutation?

    var searchText = "" { didSet { refreshBrowser() } }
    var categoryFilterID: UUID? { didSet { refreshBrowser() } }
    private(set) var selectedNoteID: NoteID?
    private(set) var recentNotes: [Note] = []
    private(set) var allNotes: [Note] = []
    private(set) var archivedNotes: [Note] = []
    private(set) var isShowingEmptyState = true

    init(
        store: WorkspaceStore,
        autosave: NoteAutosaveCoordinator,
        searchIndex: WorkspaceSearchIndex = WorkspaceSearchIndex(),
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.autosave = autosave
        self.searchIndex = searchIndex
        self.clock = clock
        refreshBrowser()
        observeStorePublication()
    }

    var selectedNote: Note? {
        selectedNoteID.flatMap { store.state.notes[$0] }
    }

    @discardableResult
    func updateTitle(_ title: String) throws -> NoteDraftSubmission {
        try autosave.update(title: title)
    }

    func refreshBrowser() {
        let matching = searchableNotes().filter(matchesCategory(_:))
        let active = matching.filter { $0.archivedAt == nil }.sorted(by: Self.browserOrder(_:_:))
        recentNotes = active
        allNotes = active
        archivedNotes = matching.filter { $0.archivedAt != nil }.sorted(by: Self.browserOrder(_:_:))
        isShowingEmptyState = active.isEmpty && archivedNotes.isEmpty
    }

    /// The browser is derived from Store publication, rather than from one
    /// autosave callback. This covers direct commands, undo/redo, recovery,
    /// external adoption and category mutations as well as Notes autosave.
    private func observeStorePublication() {
        withObservationTracking {
            _ = store.statePublicationGeneration
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshBrowser()
                self.observeStorePublication()
            }
        }
    }

    @discardableResult
    func select(
        _ noteID: NoteID,
        editSessionID: UUID = UUID(),
        activeHostToken: UUID = UUID()
    ) async throws -> Bool {
        guard noteID != selectedNoteID else { return true }
        guard await flushSelectionPrecondition() else { return false }
        guard let note = store.state.notes[noteID] else { return false }
        try autosave.beginSession(
            note,
            linkedTaskBlockLinks: Set(store.state.taskBlockLinks.filter { $0.noteID == note.id }),
            editSessionID: editSessionID,
            activeHostToken: activeHostToken
        )
        selectedNoteID = noteID
        return true
    }

    @discardableResult
    func create(_ note: Note) async throws -> Bool {
        // Leaving the current editor must be proved safe before the new note
        // is committed. Doing this after `.createNote` can leave a real but
        // unselected blank note when the second lifecycle flush cannot reuse
        // the proof from the first one.
        guard await flushSelectionPrecondition() else { return false }
        let outcome = try await store.sendWorkspace(.createNote(.init(note: note)), undoLabel: "新建笔记")
        if capturePending(outcome, effect: .create(note.id)) { return false }
        guard didCommit(outcome) else { return false }
        return try await applyCommittedSelectionEffect(.create(note.id))
    }

    @discardableResult
    func archive(_ noteID: NoteID) async throws -> Bool {
        if selectedNoteID == noteID, await flushSelectionPrecondition() == false { return false }
        let previousIndex = displayedIndex(of: noteID, in: .all)
        let outcome = try await store.sendWorkspace(.archiveNote(noteID, at: clock()), undoLabel: "归档笔记")
        if capturePending(outcome, effect: .archive(noteID: noteID, previousIndex: previousIndex)) { return false }
        guard didCommit(outcome) else { return false }
        return try await applyCommittedSelectionEffect(.archive(noteID: noteID, previousIndex: previousIndex))
    }

    @discardableResult
    func restore(_ noteID: NoteID) async throws -> Bool {
        if selectedNoteID == noteID, await flushSelectionPrecondition() == false { return false }
        let previousIndex = displayedIndex(of: noteID, in: .archived)
        let outcome = try await store.sendWorkspace(.restoreNote(noteID, at: clock()), undoLabel: "恢复笔记")
        if capturePending(outcome, effect: .restore(noteID: noteID, previousIndex: previousIndex)) { return false }
        guard didCommit(outcome) else { return false }
        return try await applyCommittedSelectionEffect(.restore(noteID: noteID, previousIndex: previousIndex))
    }

    func permanentDeletePreview(for noteID: NoteID) throws -> PermanentDeletePreview {
        try PermanentDeletePlanner.preview(.note(noteID), in: store.state)
    }

    @discardableResult
    func permanentlyDelete(
        _ noteID: NoteID,
        authorization: PermanentDeleteAuthorization
    ) async throws -> Bool {
        if selectedNoteID == noteID, await flushSelectionPrecondition() == false { return false }
        let previousIndex = displayedIndex(of: noteID, in: .archived)
        let outcome = try await store.sendWorkspace(
            .permanentlyDeleteNote(noteID, authorization: authorization),
            undoLabel: "永久删除笔记"
        )
        if capturePending(outcome, effect: .permanentDelete(noteID: noteID, previousIndex: previousIndex)) { return false }
        guard didCommit(outcome) else { return false }
        return try await applyCommittedSelectionEffect(.permanentDelete(noteID: noteID, previousIndex: previousIndex))
    }

    /// A mutation which the Store parked as uncertain owns no selection side
    /// effect until that exact transaction has a committed reconciliation.
    @discardableResult
    func retryPendingMutation() async throws -> Bool {
        guard let pendingSelectionMutation else { return false }
        let outcome = try await store.retryPendingCommit(pendingSelectionMutation.transactionID)
        switch outcome {
        case .committed:
            self.pendingSelectionMutation = nil
            return try await applyCommittedSelectionEffect(pendingSelectionMutation.effect)
        case .stillPending:
            return false
        case .notCommitted, .sourceChanged:
            self.pendingSelectionMutation = nil
            return false
        }
    }

    private func capturePending(
        _ outcome: WorkspaceTransactionOutcome,
        effect: CommittedSelectionEffect
    ) -> Bool {
        guard case let .commitPending(transactionID, _) = outcome else { return false }
        pendingSelectionMutation = .init(transactionID: transactionID, effect: effect)
        return true
    }

    private func applyCommittedSelectionEffect(_ effect: CommittedSelectionEffect) async throws -> Bool {
        refreshBrowser()
        switch effect {
        case let .create(noteID):
            guard selectedNoteID != noteID else { return true }
            guard let note = store.state.notes[noteID] else { return false }
            try autosave.beginSession(
                note,
                linkedTaskBlockLinks: Set(store.state.taskBlockLinks.filter { $0.noteID == note.id }),
                editSessionID: UUID(),
                activeHostToken: UUID()
            )
            selectedNoteID = noteID
            return true
        case let .archive(noteID, previousIndex):
            try selectFallback(afterRemoving: noteID, previousIndex: previousIndex, partition: .all)
            return true
        case let .restore(noteID, previousIndex), let .permanentDelete(noteID, previousIndex):
            try selectFallback(afterRemoving: noteID, previousIndex: previousIndex, partition: .archived)
            return true
        }
    }

    private func flushSelectionPrecondition() async -> Bool {
        guard autosave.currentTriple != nil else { return true }
        if case .persisted = await autosave.flushLatest() { return true }
        return false
    }

    private func selectFallback(
        afterRemoving noteID: NoteID,
        previousIndex: Int?,
        partition: NotesBrowserPartition
    ) throws {
        guard selectedNoteID == noteID else { return }
        let notes = notes(in: partition)
        if let previousIndex, notes.indices.contains(previousIndex) {
            selectedNoteID = notes[previousIndex].id
        } else if let previousIndex, previousIndex > 0, notes.indices.contains(previousIndex - 1) {
            selectedNoteID = notes[previousIndex - 1].id
        } else {
            selectedNoteID = nil
        }
        if let selectedNote {
            try autosave.beginSession(
                selectedNote,
                linkedTaskBlockLinks: Set(store.state.taskBlockLinks.filter { $0.noteID == selectedNote.id }),
                editSessionID: UUID(),
                activeHostToken: UUID()
            )
        }
        isShowingEmptyState = selectedNoteID == nil && notes.isEmpty
    }

    private func displayedIndex(of noteID: NoteID, in partition: NotesBrowserPartition) -> Int? {
        notes(in: partition).firstIndex { $0.id == noteID }
    }

    private func notes(in partition: NotesBrowserPartition) -> [Note] {
        switch partition {
        case .recent: recentNotes
        case .all: allNotes
        case .archived: archivedNotes
        }
    }

    func displayedNotes(in partition: NotesBrowserPartition) -> [Note] {
        notes(in: partition)
    }

    private func matchesCategory(_ note: Note) -> Bool {
        categoryFilterID == nil || note.categoryID == categoryFilterID
    }

    private func searchableNotes() -> [Note] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Array(store.state.notes.values) }
        let records: [WorkspaceSearchRecord]
        do {
            records = try searchIndex.search(
                query: query,
                kind: .note,
                includeArchived: true,
                in: store.state
            )
        } catch {
            records = WorkspaceSearchProjection.build(from: store.state)
                .search(query: query, kind: .note, includeArchived: true)
        }
        let ids = Set(records.compactMap { record -> NoteID? in
            if case let .note(id) = record.objectID { return id }
            return nil
        })
        return store.state.notes.values.filter { ids.contains($0.id) }
    }

    private func didCommit(_ outcome: WorkspaceTransactionOutcome) -> Bool {
        switch outcome {
        case .committed, .draftAlreadyPersisted:
            true
        case .restored, .noChange, .conflict, .draftSuperseded, .commitPending,
             .notCommitted, .externalSourceChanged, .persistenceBlocked:
            false
        }
    }

    private static func browserOrder(_ lhs: Note, _ rhs: Note) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id.rawValue.uuidString.lowercased() < rhs.id.rawValue.uuidString.lowercased()
    }
}
