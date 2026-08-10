import Foundation
import Testing
@testable import CalendarApp
import CalendarPersistence
import WorkspaceDomain

@Suite("NoteCloseProtectionTests")
@MainActor
struct NoteCloseProtectionTests {
    @Test func closeFlushesTheCurrentTripleBeforeAllowingTheWindowToClose() async throws {
        let calendar = makeEmptyState()
        let note = Note.empty(categoryID: calendar.uncategorizedID, now: .distantPast)
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let coordinator = NoteAutosaveCoordinator(
            store: store,
            scheduler: ImmediateNoteAutosaveScheduler()
        )
        try coordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        _ = try coordinator.update(title: "尚未保存")
        let bridge = NoteCloseProtectionBridge(coordinator: coordinator)

        let decision = await bridge.decision(for: .windowClose)

        #expect(decision == .allow)
    }

    @Test func protectedOnlyDraftAllowsInactiveButVetoesSelectionAndArchive() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-10b-close-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let calendar = makeEmptyState()
        let note = Note.empty(categoryID: calendar.uncategorizedID, now: .distantPast)
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: repository,
            journal: journal
        )
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let coordinator = NoteAutosaveCoordinator(store: store, scheduler: HoldingNoteAutosaveScheduler())
        try coordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        _ = try coordinator.update(title: "主文件失败但草稿受保护")
        await repository.failNextSave()
        let bridge = NoteCloseProtectionBridge(coordinator: coordinator)

        #expect(await bridge.decision(for: .appInactive) == .allow)
        #expect(await bridge.decision(for: .selection) == .keepOpen)
        #expect(await bridge.decision(for: .archive) == .keepOpen)
        #expect(coordinator.autosaveState == .mainSaveFailedProtected(try #require(coordinator.currentTriple)))
        #expect(coordinator.statusMessage == "保存失败—草稿已保护")
    }

    @Test func failedOrStaleCopyExportCannotReleaseANewerUnprotectedGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-10b-copy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let calendar = makeEmptyState()
        let note = Note.empty(categoryID: calendar.uncategorizedID, now: .distantPast)
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository, journal: journal)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let coordinator = NoteAutosaveCoordinator(store: store, scheduler: HoldingNoteAutosaveScheduler())
        try coordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        _ = try coordinator.update(title: "N")
        await repository.failNextSave()
        #expect(await coordinator.flushLatest() == .protectedOnly(try #require(coordinator.currentTriple)))

        let failedCopyBridge = NoteCloseProtectionBridge(coordinator: coordinator) { _, _ in nil }
        #expect(await failedCopyBridge.copyOrExportThenDecide(for: .windowClose) == .keepOpen)

        let exactCopyBridge = NoteCloseProtectionBridge(coordinator: coordinator) { triple, checksum in
            .init(triple: triple, snapshotChecksum: checksum)
        }
        #expect(await exactCopyBridge.copyOrExportThenDecide(for: .windowClose) == .allow)
        #expect(await exactCopyBridge.copyOrExportThenDecide(for: .selection) == .keepOpen)

        let copyGate = CopyExportGate()
        let staleCopyBridge = NoteCloseProtectionBridge(coordinator: coordinator) { triple, checksum in
            await copyGate.requestAndWait()
            return .init(triple: triple, snapshotChecksum: checksum)
        }
        let copiedDecision = Task { @MainActor in
            await staleCopyBridge.copyOrExportThenDecide(for: .windowClose)
        }
        await copyGate.waitForRequest()
        _ = try coordinator.update(title: "N+1")
        copyGate.release()

        #expect(await copiedDecision.value == .keepOpen)
        #expect(coordinator.currentTriple?.identityAndGeneration.draftGeneration == 2)
    }

    @Test func failedNativeFinalizerVetoesEvenAnExactCopyUntilItIsExplicitlyCancelled() async throws {
        let calendar = makeEmptyState()
        let note = Note.empty(categoryID: calendar.uncategorizedID, now: .distantPast)
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let coordinator = NoteAutosaveCoordinator(store: store, scheduler: HoldingNoteAutosaveScheduler())
        try coordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        _ = try coordinator.update(title: "尚未完成原生输入")
        let bridge = NoteCloseProtectionBridge(coordinator: coordinator) { triple, checksum in
            .init(triple: triple, snapshotChecksum: checksum)
        }

        #expect(await bridge.decision(for: .windowClose, finalizer: { _, _ in false }) == .keepOpen)
        #expect(coordinator.autosaveState == .nativeInputUnresolved(try #require(coordinator.currentTriple)))
        #expect(await bridge.copyOrExportThenDecide(for: .windowClose) == .keepOpen)
        #expect(coordinator.cancelUnresolvedNativeInput())
        #expect(await bridge.copyOrExportThenDecide(for: .windowClose) == .allow)
    }

    @Test func unsafeLatestUnprotectedKeepsTheWindowOpenAndTerminatesLater() async throws {
        let calendar = makeEmptyState()
        let note = Note.empty(categoryID: calendar.uncategorizedID, now: .distantPast)
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let coordinator = NoteAutosaveCoordinator(store: store, scheduler: HoldingNoteAutosaveScheduler())
        try coordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        _ = try coordinator.update(title: "无法保护")
        await repository.failNextSave()
        let bridge = NoteCloseProtectionBridge(coordinator: coordinator)

        #expect(await bridge.decision(for: .windowClose) == .keepOpen)
        #expect(await bridge.decision(for: .termination) == .terminateLater)
    }

    @Test func concurrentLifecycleCallersShareTheSameFailedBarrierButApplyTheirOwnEligibility() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-10b-concurrent-close-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let calendar = makeEmptyState()
        let note = Note.empty(categoryID: calendar.uncategorizedID, now: .distantPast)
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository, journal: journal)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        await repository.suspendNextSave()
        await repository.failNextSave()
        let coordinator = NoteAutosaveCoordinator(store: store, scheduler: HoldingNoteAutosaveScheduler())
        try coordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        _ = try coordinator.update(title: "并发 lifecycle")
        let bridge = NoteCloseProtectionBridge(coordinator: coordinator)

        let inactive = Task { @MainActor in await bridge.decision(for: .appInactive) }
        await repository.waitForSaveToStart()
        let close = Task { @MainActor in await bridge.decision(for: .windowClose) }
        let route = Task { @MainActor in await bridge.decision(for: .route) }
        let selection = Task { @MainActor in await bridge.decision(for: .selection) }
        await Task.yield()
        await repository.resumeSave()

        #expect(await inactive.value == .allow)
        #expect(await close.value == .allow)
        #expect(await route.value == .keepOpen)
        #expect(await selection.value == .keepOpen)
        #expect(coordinator.autosaveState == .mainSaveFailedProtected(try #require(coordinator.currentTriple)))
    }

    @Test func anOlderPersistedBarrierCannotReleaseRouteUntilTheNewerGenerationAlsoPersists() async throws {
        let calendar = makeEmptyState()
        let note = Note.empty(categoryID: calendar.uncategorizedID, now: .distantPast)
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        await repository.suspendNextSave()
        let coordinator = NoteAutosaveCoordinator(store: store, scheduler: HoldingNoteAutosaveScheduler())
        try coordinator.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        _ = try coordinator.update(title: "N")
        let bridge = NoteCloseProtectionBridge(coordinator: coordinator)
        let route = Task { @MainActor in await bridge.decision(for: .route) }
        await repository.waitForSaveToStart()

        _ = try coordinator.update(title: "N+1")
        await repository.resumeSave()

        #expect(await route.value == .allow)
        #expect(store.state.notes[note.id]?.title == "N+1")
    }
}

@MainActor
private final class ImmediateNoteAutosaveScheduler: NoteAutosaveScheduling {
    func sleep(milliseconds: UInt64) async throws {}
}

@MainActor
private final class HoldingNoteAutosaveScheduler: NoteAutosaveScheduling {
    func sleep(milliseconds: UInt64) async throws {
        try await Task.sleep(for: .seconds(3600))
    }
}

@MainActor
private final class CopyExportGate {
    private var requested = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForRequest() async {
        if requested { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    func release() {
        let waiters = resumeWaiters
        resumeWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func requestAndWait() async {
        requested = true
        let waiters = requestWaiters
        requestWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { resumeWaiters.append($0) }
    }
}
