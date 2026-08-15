import CalendarPersistence
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("WorkspaceRouteTransitionTests")
@MainActor
struct WorkspaceRouteTransitionTests {
    @Test func productionEnablesNotesAndInspiration() {
        #expect(WorkspaceFeatures.production.notes == true)
        #expect(WorkspaceFeatures.production.inspiration == true)
        #expect(WorkspaceRoute.visibleRoutes(.production) == [.calendar, .notes, .inspiration])
    }

    @Test func protectedOnlyDraftCanLeaveTheStillMountedNotesModule() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-10d-route-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let calendar = makeEmptyState()
        let note = Note.empty(id: NoteID(), categoryID: calendar.uncategorizedID, now: Date(timeIntervalSince1970: 1))
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let journal = DraftJournalRepository(fileURL: directory.appendingPathComponent("draft.json"))
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: repository,
            journal: journal
        )
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let autosave = NoteAutosaveCoordinator(store: store, scheduler: RouteTestImmediateScheduler())
        try autosave.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        _ = try autosave.update(title: "主文件失败但草稿受保护")
        await repository.failNextSave()
        let bridge = NoteCloseProtectionBridge(coordinator: autosave)

        let preferences = SpyWorkspaceRoutePreferenceStore(initial: "notes")
        let features = WorkspaceFeatures(notes: true, inspiration: false)
        let routeState = WorkspaceRouteState(features: features, preferences: preferences)
        #expect(routeState.route == .notes)
        let coordinator = WorkspaceRouteTransitionCoordinator(routeState: routeState, features: features)
        coordinator.attachNotesCloseBridge(bridge)

        #expect(await coordinator.requestActivation(.calendar))
        #expect(routeState.route == .calendar)
        #expect(await bridge.decision(for: NoteCloseProtectionReason.route) == .keepOpen)
    }

    @Test func disabledRouteCannotActivate() async {
        let features = WorkspaceFeatures(notes: true, inspiration: false)
        let routeState = WorkspaceRouteState(
            features: features,
            preferences: SpyWorkspaceRoutePreferenceStore(initial: "calendar")
        )
        let coordinator = WorkspaceRouteTransitionCoordinator(routeState: routeState, features: features)
        #expect(await coordinator.requestActivation(.inspiration) == false)
        #expect(routeState.route == .calendar)
    }

    @Test func cleanNotesSessionAllowsRouteActivation() async throws {
        let calendar = makeEmptyState()
        let note = Note.empty(id: NoteID(), categoryID: calendar.uncategorizedID, now: Date(timeIntervalSince1970: 1))
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let autosave = NoteAutosaveCoordinator(store: store, scheduler: RouteTestImmediateScheduler())
        try autosave.beginSession(note, linkedTaskBlockLinks: [], editSessionID: UUID(), activeHostToken: UUID())
        // No edits → flushLatest returns clean → route allow.
        let bridge = NoteCloseProtectionBridge(coordinator: autosave)
        let features = WorkspaceFeatures(notes: true, inspiration: false)
        let routeState = WorkspaceRouteState(
            features: features,
            preferences: SpyWorkspaceRoutePreferenceStore(initial: "notes")
        )
        let coordinator = WorkspaceRouteTransitionCoordinator(routeState: routeState, features: features)
        coordinator.attachNotesCloseBridge(bridge)
        #expect(await coordinator.requestActivation(.calendar) == true)
        #expect(routeState.route == .calendar)
    }

    @Test func editedNotesRouteActivatesBeforeThePendingDiskSaveFinishes() async throws {
        let calendar = makeEmptyState()
        let note = Note.empty(
            id: NoteID(),
            categoryID: calendar.uncategorizedID,
            now: Date(timeIntervalSince1970: 1)
        )
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: repository
        )
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let autosave = NoteAutosaveCoordinator(store: store, scheduler: RouteTestImmediateScheduler())
        try autosave.beginSession(
            note,
            linkedTaskBlockLinks: [],
            editSessionID: UUID(),
            activeHostToken: UUID()
        )
        await repository.suspendNextSave()
        _ = try autosave.update(title: "切页不能等磁盘")
        let bridge = NoteCloseProtectionBridge(coordinator: autosave)
        let features = WorkspaceFeatures(notes: true, inspiration: true)
        let routeState = WorkspaceRouteState(
            features: features,
            preferences: SpyWorkspaceRoutePreferenceStore(initial: "notes")
        )
        let coordinator = WorkspaceRouteTransitionCoordinator(routeState: routeState, features: features)
        coordinator.attachNotesCloseBridge(bridge)

        let activation = Task { await coordinator.requestActivation(.inspiration) }
        await repository.waitForSaveToStart()
        await Task.yield()

        #expect(routeState.route == .inspiration)
        await repository.resumeSave()
        #expect(await activation.value)
    }

    @Test func latestClickWinsWhileANotesTransitionIsSettling() async throws {
        let calendar = makeEmptyState()
        let note = Note.empty(
            id: NoteID(),
            categoryID: calendar.uncategorizedID,
            now: Date(timeIntervalSince1970: 1)
        )
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let autosave = NoteAutosaveCoordinator(store: store, scheduler: RouteTestImmediateScheduler())
        try autosave.beginSession(
            note,
            linkedTaskBlockLinks: [],
            editSessionID: UUID(),
            activeHostToken: UUID()
        )
        let bridge = NoteCloseProtectionBridge(coordinator: autosave)
        let features = WorkspaceFeatures.production
        let routeState = WorkspaceRouteState(
            features: features,
            preferences: SpyWorkspaceRoutePreferenceStore(initial: "notes")
        )
        let coordinator = WorkspaceRouteTransitionCoordinator(routeState: routeState, features: features)
        let gate = RouteFinalizerGate()
        coordinator.attachNotesCloseBridge(bridge, finalizer: gate.finalize)

        let first = Task { await coordinator.requestActivation(.calendar) }
        await gate.waitUntilStarted()
        #expect(coordinator.pendingRoute == .calendar)

        let second = Task { await coordinator.requestActivation(.inspiration) }
        await Task.yield()
        gate.resume()

        #expect(await first.value == false)
        #expect(await second.value == true)
        #expect(routeState.route == .inspiration)
        #expect(coordinator.pendingRoute == nil)
    }
}

@MainActor
private final class RouteTestImmediateScheduler: NoteAutosaveScheduling {
    func sleep(milliseconds: UInt64) async throws {}
}

@MainActor
private final class RouteFinalizerGate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    lazy var finalize: NoteNativeInputFinalizer = { [weak self] _, _ in
        guard let self else { return false }
        self.started = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return true
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
