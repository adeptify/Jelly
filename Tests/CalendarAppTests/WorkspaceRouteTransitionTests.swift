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

    @Test func protectedOnlyNotesDraftBlocksRouteActivation() async throws {
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

        #expect(await coordinator.requestActivation(.calendar) == false)
        #expect(routeState.route == .notes)
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
}

@MainActor
private final class RouteTestImmediateScheduler: NoteAutosaveScheduling {
    func sleep(milliseconds: UInt64) async throws {}
}
