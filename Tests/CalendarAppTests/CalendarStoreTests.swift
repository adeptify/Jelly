import CalendarDomain
import CalendarPersistence
import Foundation
import Testing
@testable import CalendarApp

@Suite("CalendarStoreTests")
@MainActor
struct CalendarStoreTests {
    @Test func failedSaveDoesNotPublishOrRegisterUndo() async throws {
        let original = makeEmptyState()
        let (store, repository) = try await makeReadyStore(initialState: original)
        await repository.failNextSave()

        do {
            try await store.send(.createCategory(makeCategory(name: "工作")), undoLabel: "添加分类")
            Issue.record("A failed save must throw.")
        } catch let error as StoreError {
            #expect(error == .persistenceFailed)
        }

        #expect(store.state == original)
        #expect(store.canUndo == false)
        #expect(store.mutationError != nil)
        #expect(store.phase == .ready)
    }

    @Test func failedReductionReturnsReadyWithoutSaveOrUndo() async throws {
        let original = makeEmptyState()
        let (store, repository) = try await makeReadyStore(initialState: original)

        do {
            try await store.send(.deleteItem(UUID()), undoLabel: "删除")
            Issue.record("A missing item must be rejected by the reducer.")
        } catch is ReducerError {}

        #expect(store.phase == .ready)
        #expect(await repository.saveCount == 0)
        #expect(store.state == original)
        #expect(store.canUndo == false)
    }

    @Test func successfulSendPersistsBeforePublishing() async throws {
        let original = makeEmptyState()
        let (store, repository) = try await makeReadyStore(initialState: original)
        let item = try makeItem(categoryID: original.uncategorizedID)

        try await store.send(.createItem(item), undoLabel: "添加事项")

        let persisted = await repository.persistedState
        #expect(persisted == store.state)
        #expect(store.state.items[item.id] == item)
        #expect(store.canUndo)
        #expect(store.undoNotice == "添加事项")
    }

    @Test func undoRestoresWholeSnapshotAfterSuccessfulSave() async throws {
        let fixture = try makeCategoryReferenceFixture()
        let original = fixture.state
        let (store, repository) = try await makeReadyStore(initialState: original)

        try await store.send(
            .deleteCategory(fixture.deletedCategoryID, migrateTo: fixture.targetCategoryID),
            undoLabel: "删除分类"
        )
        #expect(store.state != original)

        try await store.undo()

        #expect(store.state == original)
        #expect(await repository.persistedState == original)
        #expect(store.canUndo == false)
    }

    @Test func concurrentMutationIsRejected() async throws {
        let original = makeEmptyState()
        let (store, repository) = try await makeReadyStore(initialState: original)
        await repository.suspendNextSave()
        let firstItem = try makeItem(categoryID: original.uncategorizedID, title: "第一项")
        let secondItem = try makeItem(categoryID: original.uncategorizedID, title: "第二项")
        let first = Task { @MainActor in
            try await store.send(.createItem(firstItem), undoLabel: "添加第一项")
        }
        await repository.waitForSaveToStart()

        do {
            try await store.send(.createItem(secondItem), undoLabel: "添加第二项")
            Issue.record("A mutation while saving must be rejected.")
        } catch let error as StoreError {
            #expect(error == .mutationInProgress)
        }
        await repository.resumeSave()
        try await first.value

        #expect(store.state.items[firstItem.id] != nil)
        #expect(store.state.items[secondItem.id] == nil)
        #expect(await repository.persistedState == store.state)
    }

    @Test func sendDuringLoadIsRejected() async throws {
        let disk = try makeStateWithOneItem()
        let repository = InMemoryCalendarRepository(initialState: disk)
        await repository.suspendNextLoad()
        let store = CalendarStore(initialState: makeEmptyState(), repository: repository)
        let loading = Task { @MainActor in await store.load() }
        await repository.waitForLoadToStart()
        #expect(store.phase == .loading)

        do {
            try await store.send(.deleteItem(UUID()), undoLabel: "删除")
            Issue.record("Commands during load must not reduce from the seed state.")
        } catch let error as StoreError {
            #expect(error == .notReady)
        }
        #expect(await repository.saveCount == 0)
        await repository.resumeLoad()
        await loading.value

        #expect(store.phase == .ready)
        #expect(store.state == disk)
    }

    @Test func restoreBlocksSendAndUndo() async throws {
        let original = makeEmptyState()
        let restored = try makeStateWithOneItem()
        let (store, repository) = try await makeReadyStore(initialState: original)
        let source = try makeBackupFile(for: restored)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let rollback = source.deletingLastPathComponent().appendingPathComponent("rollback.json")
        await repository.suspendNextSnapshot()
        let restoreTask = Task { @MainActor in
            try await store.restore(from: source, using: BackupService(), rollbackURL: rollback)
        }
        await repository.waitForSnapshotToStart()
        #expect(store.phase == .restoring)

        do {
            try await store.send(.deleteItem(UUID()), undoLabel: "删除")
            Issue.record("Commands during restore must be rejected.")
        } catch let error as StoreError {
            #expect(error == .mutationInProgress)
        }
        do {
            try await store.undo()
            Issue.record("Undo during restore must be rejected.")
        } catch let error as StoreError {
            #expect(error == .mutationInProgress)
        }

        await repository.resumeSnapshot()
        try await restoreTask.value
        #expect(store.phase == .ready)
        #expect(store.state == restored)
        #expect(await repository.persistedState == restored)
    }

    @Test func corruptPrimaryCanRestoreValidBackup() async throws {
        let seed = makeEmptyState()
        let restored = try makeStateWithOneItem()
        let repository = InMemoryCalendarRepository(initialState: seed)
        let corrupt = Data("corrupt primary bytes".utf8)
        await repository.replaceRawDocument(with: corrupt)
        let store = CalendarStore(initialState: seed, repository: repository)
        await store.load()
        #expect(store.phase == .loadFailed)
        #expect(store.loadError != nil)
        let source = try makeBackupFile(for: restored)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let rollback = source.deletingLastPathComponent().appendingPathComponent("rollback.json")

        try await store.restore(from: source, using: BackupService(), rollbackURL: rollback)

        #expect(try Data(contentsOf: rollback) == corrupt)
        #expect(store.phase == .ready)
        #expect(store.loadError == nil)
        #expect(store.state == restored)
        #expect(await repository.persistedState == restored)
    }
}
