import CalendarDomain
import Foundation
import Testing
@testable import CalendarApp
import WorkspaceDomain

@Suite("NotesWorkspaceViewModelTests")
@MainActor
struct NotesWorkspaceViewModelTests {
    @Test func browserSearchesChineseTitleAndBlockTextWithinSharedCategory() async throws {
        let now = Date(timeIntervalSince1970: 1_754_000_000)
        var calendar = makeEmptyState()
        let work = makeCategory(name: "工作")
        calendar.categories[work.id] = work
        let note = makeNotesTestNote(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001001")!,
            title: "会议准备",
            body: "整理客户需求",
            categoryID: work.id,
            updatedAt: now
        )
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))

        let autosave = NoteAutosaveCoordinator(
            store: store,
            scheduler: NotesImmediateAutosaveScheduler()
        )
        let searchIndex = WorkspaceSearchIndex()
        let viewModel = NotesWorkspaceViewModel(
            store: store,
            autosave: autosave,
            searchIndex: searchIndex,
            clock: { now }
        )

        viewModel.searchText = "客户"
        viewModel.categoryFilterID = work.id
        viewModel.refreshBrowser()

        #expect(viewModel.recentNotes.map(\.id) == [note.id])
        #expect(viewModel.allNotes.map(\.id) == [note.id])
        #expect(viewModel.archivedNotes.isEmpty)
        #expect(searchIndex.projection.workspaceRevision == store.state.revision)
    }

    @Test func autosaveCommitPublishesTheLatestTitleToBrowserSearchWithoutManualRefresh() async throws {
        let calendar = makeEmptyState()
        let note = makeNotesTestNote(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001005")!,
            title: "旧标题", body: "旧内容", categoryID: calendar.uncategorizedID, updatedAt: .distantPast
        )
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let autosave = NoteAutosaveCoordinator(store: store, scheduler: NotesImmediateAutosaveScheduler())
        let viewModel = NotesWorkspaceViewModel(store: store, autosave: autosave)
        #expect(try await viewModel.select(note.id))

        viewModel.searchText = "新标题"
        #expect(viewModel.allNotes.isEmpty)
        _ = try viewModel.updateTitle("新标题")
        #expect(await autosave.flushLatest() == .persisted(try #require(autosave.currentTriple)))

        #expect(viewModel.allNotes.map(\.id) == [note.id])
        #expect(viewModel.recentNotes.first?.title == "新标题")
    }

    @Test func browserObservesDirectStoreArchiveUndoAndExternalPublicationWithoutAutosaveCallback() async throws {
        let calendar = makeEmptyState()
        let first = makeNotesTestNote(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001006")!,
            title: "first", body: "body", categoryID: calendar.uncategorizedID, updatedAt: .distantPast
        )
        let second = makeNotesTestNote(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001007")!,
            title: "second", body: "body", categoryID: calendar.uncategorizedID, updatedAt: .distantPast.addingTimeInterval(-1)
        )
        let initial = WorkspaceState.empty(calendar: calendar)
        let repository = WorkspaceStoreTestRepository(initial: initial)
        let store = WorkspaceStore(initialState: initial, repository: repository)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: first)))
        _ = try await store.sendWorkspace(.createNote(.init(note: second)))
        let autosave = NoteAutosaveCoordinator(store: store, scheduler: NotesImmediateAutosaveScheduler())
        let viewModel = NotesWorkspaceViewModel(store: store, autosave: autosave)
        #expect(viewModel.allNotes.map(\.id) == [first.id, second.id])

        _ = try await store.sendWorkspace(.archiveNote(first.id, at: .distantFuture), undoLabel: "direct archive")
        await Task.yield()
        #expect(viewModel.allNotes.map(\.id) == [second.id])
        #expect(viewModel.archivedNotes.map(\.id) == [first.id])

        _ = try await store.undo()
        await Task.yield()
        #expect(viewModel.allNotes.map(\.id) == [first.id, second.id])

        viewModel.searchText = "external title"
        #expect(viewModel.allNotes.isEmpty)
        var external = store.state
        external.revision += 1
        external.notes[first.id]?.title = "external title"
        external.notes[first.id]?.updatedAt = .distantFuture
        external.notes[first.id]?.revision += 1
        await repository.setReloaded(.valid(.init(
            state: external,
            provenance: .init(sourceSchema: 3, sourceBytesSHA256: "external", sourceByteCount: 1),
            consistencyIssues: []
        )))
        _ = try await store.reloadExternalSource()
        await Task.yield()
        #expect(viewModel.allNotes.map(\.id) == [first.id])
        #expect(viewModel.recentNotes.first?.title == "external title")
    }

    @Test func archiveSelectsTheDisplayedSuccessorAndRebindsTheDraftSessionExactlyOnce() async throws {
        let now = Date(timeIntervalSince1970: 1_754_000_100)
        let calendar = makeEmptyState()
        let first = makeNotesTestNote(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001010")!,
            title: "先归档",
            body: "A",
            categoryID: calendar.uncategorizedID,
            updatedAt: now
        )
        let second = makeNotesTestNote(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001011")!,
            title: "后保留",
            body: "B",
            categoryID: calendar.uncategorizedID,
            updatedAt: now.addingTimeInterval(-1)
        )
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: first)))
        _ = try await store.sendWorkspace(.createNote(.init(note: second)))
        let autosave = NoteAutosaveCoordinator(store: store, scheduler: NotesImmediateAutosaveScheduler())
        let viewModel = NotesWorkspaceViewModel(store: store, autosave: autosave, clock: { now })
        #expect(try await viewModel.select(first.id))

        #expect(try await viewModel.archive(first.id))
        let submission = try viewModel.updateTitle("后保留，继续编辑")

        #expect(viewModel.selectedNoteID == second.id)
        #expect(submission.noteID == second.id)
        #expect(store.state.notes[first.id]?.archivedAt == now)
    }

    @Test func stalePermanentDeleteAuthorizationLeavesTheSelectedNoteAndBrowserUntouched() async throws {
        let calendar = makeEmptyState()
        let note = makeNotesTestNote(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001020")!,
            title: "归档候选",
            body: "不得提前移除",
            categoryID: calendar.uncategorizedID,
            archivedAt: .distantPast,
            updatedAt: .distantPast
        )
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let autosave = NoteAutosaveCoordinator(store: store, scheduler: NotesImmediateAutosaveScheduler())
        let viewModel = NotesWorkspaceViewModel(store: store, autosave: autosave)
        let stale = PermanentDeleteAuthorization(
            subject: .note(note.id),
            sourceWorkspaceRevision: -1,
            impactChecksum: "stale"
        )

        #expect(try await viewModel.permanentlyDelete(note.id, authorization: stale) == false)

        #expect(viewModel.selectedNoteID == nil)
        #expect(viewModel.archivedNotes.map(\.id) == [note.id])
        #expect(store.state.notes[note.id] != nil)
    }

    @Test func browserUsesUpdatedAtThenLowercasedUUIDAndKeepsArchiveOutOfActivePartitions() async throws {
        let now = Date(timeIntervalSince1970: 1_754_000_200)
        let calendar = makeEmptyState()
        let newest = makeNotesTestNote(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001031")!,
            title: "最新", body: "A", categoryID: calendar.uncategorizedID, updatedAt: now
        )
        let tiedLater = makeNotesTestNote(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001033")!,
            title: "同一时间后", body: "B", categoryID: calendar.uncategorizedID,
            updatedAt: now.addingTimeInterval(-1)
        )
        let tiedEarlier = makeNotesTestNote(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001032")!,
            title: "同一时间前", body: "C", categoryID: calendar.uncategorizedID,
            updatedAt: now.addingTimeInterval(-1)
        )
        let archived = makeNotesTestNote(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001034")!,
            title: "归档", body: "D", categoryID: calendar.uncategorizedID,
            archivedAt: now, updatedAt: now.addingTimeInterval(1)
        )
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        for note in [tiedLater, archived, newest, tiedEarlier] {
            _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        }
        let autosave = NoteAutosaveCoordinator(store: store, scheduler: NotesImmediateAutosaveScheduler())
        let viewModel = NotesWorkspaceViewModel(store: store, autosave: autosave)

        #expect(viewModel.recentNotes.map(\.id) == [newest.id, tiedEarlier.id, tiedLater.id])
        #expect(viewModel.allNotes.map(\.id) == [newest.id, tiedEarlier.id, tiedLater.id])
        #expect(viewModel.archivedNotes.map(\.id) == [archived.id])
    }

    @Test func createPendingThenExactRetrySelectsTheNewNoteOnlyAfterTheStoreCommits() async throws {
        let now = Date(timeIntervalSince1970: 1_754_000_300)
        let calendar = makeEmptyState()
        let selected = makeNotesTestNote(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001040")!,
            title: "原选择", body: "A", categoryID: calendar.uncategorizedID, updatedAt: now
        )
        let created = makeNotesTestNote(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001041")!,
            title: "等待确认", body: "B", categoryID: calendar.uncategorizedID, updatedAt: now
        )
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: selected)))
        let autosave = NoteAutosaveCoordinator(store: store, scheduler: NotesImmediateAutosaveScheduler())
        let viewModel = NotesWorkspaceViewModel(store: store, autosave: autosave)
        #expect(try await viewModel.select(selected.id))

        await repository.makeNextSaveUncertain()
        await repository.setReconciliation(.stillPending(.init()))
        #expect(try await viewModel.create(created) == false)
        #expect(viewModel.selectedNoteID == selected.id)
        #expect(store.state.notes[created.id] == nil)

        await repository.setReconciliation(.committed(.save(.init(workspaceRevision: 2, persistedDraft: nil))))
        #expect(try await viewModel.retryPendingMutation())
        #expect(viewModel.selectedNoteID == created.id)
        #expect(store.state.notes[created.id] != nil)
    }

    @Test func restoreAndPermanentDeleteUseTheDisplayedSuccessorThenPreviousThenEmptyFallback() async throws {
        let now = Date(timeIntervalSince1970: 1_754_000_400)
        let calendar = makeEmptyState()
        let first = makeNotesTestNote(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001050")!,
            title: "归档一", body: "A", categoryID: calendar.uncategorizedID,
            archivedAt: now, updatedAt: now
        )
        let second = makeNotesTestNote(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001051")!,
            title: "归档二", body: "B", categoryID: calendar.uncategorizedID,
            archivedAt: now, updatedAt: now.addingTimeInterval(-1)
        )
        let third = makeNotesTestNote(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001052")!,
            title: "归档三", body: "C", categoryID: calendar.uncategorizedID,
            archivedAt: now, updatedAt: now.addingTimeInterval(-2)
        )
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        for note in [first, second, third] {
            _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        }
        let autosave = NoteAutosaveCoordinator(store: store, scheduler: NotesImmediateAutosaveScheduler())
        let viewModel = NotesWorkspaceViewModel(store: store, autosave: autosave, clock: { now })

        #expect(try await viewModel.select(second.id))
        #expect(try await viewModel.restore(second.id))
        #expect(viewModel.selectedNoteID == third.id)

        #expect(try await viewModel.select(first.id))
        let firstPreview = try viewModel.permanentDeletePreview(for: first.id)
        let firstAuthorization = PermanentDeleteAuthorization(
            subject: firstPreview.subject,
            sourceWorkspaceRevision: firstPreview.sourceWorkspaceRevision,
            impactChecksum: firstPreview.checksum
        )
        #expect(try await viewModel.permanentlyDelete(first.id, authorization: firstAuthorization))
        #expect(viewModel.selectedNoteID == third.id)

        let thirdPreview = try viewModel.permanentDeletePreview(for: third.id)
        let thirdAuthorization = PermanentDeleteAuthorization(
            subject: thirdPreview.subject,
            sourceWorkspaceRevision: thirdPreview.sourceWorkspaceRevision,
            impactChecksum: thirdPreview.checksum
        )
        #expect(try await viewModel.permanentlyDelete(third.id, authorization: thirdAuthorization))
        #expect(viewModel.selectedNoteID == nil)
    }

    @Test func pendingArchiveLeavesSelectionStableThenItsExactCommittedRetryAppliesTheFallbackOnce() async throws {
        let now = Date(timeIntervalSince1970: 1_754_000_500)
        let calendar = makeEmptyState()
        let first = makeNotesTestNote(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001060")!,
            title: "将归档", body: "A", categoryID: calendar.uncategorizedID, updatedAt: now
        )
        let second = makeNotesTestNote(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001061")!,
            title: "回退目标", body: "B", categoryID: calendar.uncategorizedID,
            updatedAt: now.addingTimeInterval(-1)
        )
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: first)))
        _ = try await store.sendWorkspace(.createNote(.init(note: second)))
        let autosave = NoteAutosaveCoordinator(store: store, scheduler: NotesImmediateAutosaveScheduler())
        let viewModel = NotesWorkspaceViewModel(store: store, autosave: autosave, clock: { now })
        #expect(try await viewModel.select(first.id))

        await repository.makeNextSaveUncertain()
        await repository.setReconciliation(.stillPending(.init()))
        #expect(try await viewModel.archive(first.id) == false)
        #expect(viewModel.selectedNoteID == first.id)
        #expect(store.state.notes[first.id]?.archivedAt == nil)

        await repository.setReconciliation(.committed(.save(.init(workspaceRevision: 3, persistedDraft: nil))))
        #expect(try await viewModel.retryPendingMutation())
        #expect(store.state.notes[first.id]?.archivedAt == now)
        #expect(viewModel.selectedNoteID == second.id)
    }

    @Test func pendingRestoreStaysSelectedThroughStillPendingThenUsesItsDisplayedSuccessorOnceOnCommit() async throws {
        let now = Date(timeIntervalSince1970: 1_754_000_600)
        let calendar = makeEmptyState()
        let first = makeNotesTestNote(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001070")!,
            title: "归档一", body: "A", categoryID: calendar.uncategorizedID,
            archivedAt: now, updatedAt: now
        )
        let second = makeNotesTestNote(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001071")!,
            title: "归档二", body: "B", categoryID: calendar.uncategorizedID,
            archivedAt: now, updatedAt: now.addingTimeInterval(-1)
        )
        let third = makeNotesTestNote(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001072")!,
            title: "归档三", body: "C", categoryID: calendar.uncategorizedID,
            archivedAt: now, updatedAt: now.addingTimeInterval(-2)
        )
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        for note in [first, second, third] {
            _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        }
        let autosave = NoteAutosaveCoordinator(store: store, scheduler: NotesImmediateAutosaveScheduler())
        let viewModel = NotesWorkspaceViewModel(store: store, autosave: autosave, clock: { now })
        #expect(try await viewModel.select(second.id))

        await repository.makeNextSaveUncertain()
        await repository.setReconciliation(.stillPending(.init()))
        #expect(try await viewModel.restore(second.id) == false)
        #expect(viewModel.selectedNoteID == second.id)
        #expect(try await viewModel.retryPendingMutation() == false)
        #expect(viewModel.selectedNoteID == second.id)

        await repository.setReconciliation(.committed(.save(.init(workspaceRevision: 4, persistedDraft: nil))))
        #expect(try await viewModel.retryPendingMutation())
        #expect(store.state.notes[second.id]?.archivedAt == nil)
        #expect(viewModel.selectedNoteID == third.id)
        #expect(try await viewModel.retryPendingMutation() == false)
        #expect(viewModel.selectedNoteID == third.id)
    }

    @Test func pendingPermanentDeleteStaysSelectedThroughStillPendingThenUsesPreviousFallbackOnceOnCommit() async throws {
        let now = Date(timeIntervalSince1970: 1_754_000_700)
        let calendar = makeEmptyState()
        let first = makeNotesTestNote(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001080")!,
            title: "保留", body: "A", categoryID: calendar.uncategorizedID,
            archivedAt: now, updatedAt: now
        )
        let second = makeNotesTestNote(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001081")!,
            title: "删除", body: "B", categoryID: calendar.uncategorizedID,
            archivedAt: now, updatedAt: now.addingTimeInterval(-1)
        )
        let repository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: first)))
        _ = try await store.sendWorkspace(.createNote(.init(note: second)))
        let autosave = NoteAutosaveCoordinator(store: store, scheduler: NotesImmediateAutosaveScheduler())
        let viewModel = NotesWorkspaceViewModel(store: store, autosave: autosave, clock: { now })
        #expect(try await viewModel.select(second.id))
        let preview = try viewModel.permanentDeletePreview(for: second.id)
        let authorization = PermanentDeleteAuthorization(
            subject: preview.subject,
            sourceWorkspaceRevision: preview.sourceWorkspaceRevision,
            impactChecksum: preview.checksum
        )

        await repository.makeNextSaveUncertain()
        await repository.setReconciliation(.stillPending(.init()))
        #expect(try await viewModel.permanentlyDelete(second.id, authorization: authorization) == false)
        #expect(viewModel.selectedNoteID == second.id)
        #expect(try await viewModel.retryPendingMutation() == false)
        #expect(viewModel.selectedNoteID == second.id)

        await repository.setReconciliation(.committed(.save(.init(workspaceRevision: 3, persistedDraft: nil))))
        #expect(try await viewModel.retryPendingMutation())
        #expect(store.state.notes[second.id] == nil)
        #expect(viewModel.selectedNoteID == first.id)
        #expect(try await viewModel.retryPendingMutation() == false)
        #expect(viewModel.selectedNoteID == first.id)
    }

    @Test func failedArchiveRestoreAndPermanentDeleteLeaveTheCurrentSelectionUntouched() async throws {
        let now = Date(timeIntervalSince1970: 1_754_000_800)
        let calendar = makeEmptyState()

        let active = makeNotesTestNote(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001090")!,
            title: "active", body: "A", categoryID: calendar.uncategorizedID, updatedAt: now
        )
        let archiveRepository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        let archiveStore = WorkspaceStore(initialState: .empty(calendar: calendar), repository: archiveRepository)
        await archiveStore.load()
        _ = try await archiveStore.sendWorkspace(.createNote(.init(note: active)))
        let archiveViewModel = NotesWorkspaceViewModel(
            store: archiveStore,
            autosave: NoteAutosaveCoordinator(store: archiveStore, scheduler: NotesImmediateAutosaveScheduler()),
            clock: { now }
        )
        #expect(try await archiveViewModel.select(active.id))
        await archiveRepository.failNextSave()
        #expect(try await archiveViewModel.archive(active.id) == false)
        #expect(archiveViewModel.selectedNoteID == active.id)

        let archived = makeNotesTestNote(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001091")!,
            title: "archived", body: "B", categoryID: calendar.uncategorizedID,
            archivedAt: now, updatedAt: now
        )
        let restoreRepository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        let restoreStore = WorkspaceStore(initialState: .empty(calendar: calendar), repository: restoreRepository)
        await restoreStore.load()
        _ = try await restoreStore.sendWorkspace(.createNote(.init(note: archived)))
        let restoreViewModel = NotesWorkspaceViewModel(
            store: restoreStore,
            autosave: NoteAutosaveCoordinator(store: restoreStore, scheduler: NotesImmediateAutosaveScheduler()),
            clock: { now }
        )
        #expect(try await restoreViewModel.select(archived.id))
        await restoreRepository.failNextSave()
        #expect(try await restoreViewModel.restore(archived.id) == false)
        #expect(restoreViewModel.selectedNoteID == archived.id)

        let deleteRepository = WorkspaceStoreTestRepository(initial: .empty(calendar: calendar))
        let deleteStore = WorkspaceStore(initialState: .empty(calendar: calendar), repository: deleteRepository)
        await deleteStore.load()
        _ = try await deleteStore.sendWorkspace(.createNote(.init(note: archived)))
        let deleteViewModel = NotesWorkspaceViewModel(
            store: deleteStore,
            autosave: NoteAutosaveCoordinator(store: deleteStore, scheduler: NotesImmediateAutosaveScheduler()),
            clock: { now }
        )
        #expect(try await deleteViewModel.select(archived.id))
        let preview = try deleteViewModel.permanentDeletePreview(for: archived.id)
        let authorization = PermanentDeleteAuthorization(
            subject: preview.subject,
            sourceWorkspaceRevision: preview.sourceWorkspaceRevision,
            impactChecksum: preview.checksum
        )
        await deleteRepository.failNextSave()
        #expect(try await deleteViewModel.permanentlyDelete(archived.id, authorization: authorization) == false)
        #expect(deleteViewModel.selectedNoteID == archived.id)
    }
}

@MainActor
private final class NotesImmediateAutosaveScheduler: NoteAutosaveScheduling {
    func sleep(milliseconds: UInt64) async throws {}
}

private func makeNotesTestNote(
    id: UUID,
    title: String,
    body: String,
    categoryID: UUID,
    archivedAt: Date? = nil,
    updatedAt: Date
) -> Note {
    Note(
        id: NoteID(id),
        title: title,
        document: .init(blocks: [
            .init(
                id: BlockID(UUID(uuidString: "00000000-0000-0000-0000-000000001100")!),
                kind: .paragraph,
                inlineContent: .plain(body),
                taskState: nil,
                indentLevel: 0
            )
        ]),
        categoryID: categoryID,
        archivedAt: archivedAt,
        revision: 1,
        createdAt: updatedAt,
        updatedAt: updatedAt
    )
}
