import AppKit
import CalendarDomain
import Combine
import Testing
@testable import CalendarApp

@Suite("CalendarUndoCommandRoutingTests")
@MainActor
struct CalendarUndoCommandRoutingTests {
    @Test func focusedUnavailableConsumesUndoWithoutWorkspaceFallback() async throws {
        let (store, _) = try await makeReadyStore(initialState: makeEmptyState())
        let registry = EditorFocusRegistry()
        let manager = UndoManager()
        registry.register(manager, ownerID: UUID())

        #expect(CalendarUndoCommandRouter.isDisabled(for: store, focusRegistry: registry))
        let route = try await CalendarUndoCommandRouter.undo(store: store, focusRegistry: registry)
        #expect(route == .focusedUnavailable)
    }

    @Test func focusedUndoAndRedoUseOnlyItsManager() async throws {
        let (store, _) = try await makeReadyStore(initialState: makeEmptyState())
        let registry = EditorFocusRegistry()
        let manager = UndoManager()
        let target = RouterUndoTarget(manager: manager)
        target.value = 1
        manager.registerUndo(withTarget: target) { $0.undo() }
        registry.register(manager, ownerID: UUID())

        #expect(CalendarUndoCommandRouter.isDisabled(for: store, focusRegistry: registry) == false)
        #expect(try await CalendarUndoCommandRouter.undo(store: store, focusRegistry: registry) == .focusedPerformed)
        #expect(target.value == 0)
        #expect(try await CalendarUndoCommandRouter.redo(store: store, focusRegistry: registry) == .focusedPerformed)
        #expect(target.value == 1)
    }

    @Test func staleClearOnlyReleasesItsOwnOwner() {
        let registry = EditorFocusRegistry()
        let first = UUID()
        let second = UUID()
        let firstManager = UndoManager()
        let secondManager = UndoManager()
        registry.register(firstManager, ownerID: first)
        registry.register(secondManager, ownerID: second)
        registry.clear(ownerID: first)

        #expect(registry.availability != .noFocusedOwner)
        registry.clear(ownerID: second)
        #expect(registry.availability == .noFocusedOwner)
    }

    @Test func noOwnerUsesWorkspaceAndFocusedAvailabilityIsSideSpecific() async throws {
        let (store, _) = try await makeReadyStore(initialState: makeEmptyState())
        let registry = EditorFocusRegistry()
        #expect(CalendarUndoCommandRouter.isDisabled(for: store, focusRegistry: registry))
        #expect(CalendarUndoCommandRouter.isRedoDisabled(for: store, focusRegistry: registry))

        let undoOnly = UndoManager()
        let target = RouterUndoTarget(manager: undoOnly)
        target.value = 1
        undoOnly.registerUndo(withTarget: target) { $0.undo() }
        registry.register(undoOnly, ownerID: UUID())
        #expect(CalendarUndoCommandRouter.isDisabled(for: store, focusRegistry: registry) == false)
        #expect(CalendarUndoCommandRouter.isRedoDisabled(for: store, focusRegistry: registry))
        #expect(try await CalendarUndoCommandRouter.undo(store: store, focusRegistry: registry) == .focusedPerformed)
        #expect(CalendarUndoCommandRouter.isRedoDisabled(for: store, focusRegistry: registry) == false)
    }

    @Test func noOwnerRoutesRealWorkspaceUndoAndRedoWithoutTouchingAnEditor() async throws {
        let original = makeEmptyState()
        let (store, _) = try await makeReadyStore(initialState: original)
        let item = try makeItem(categoryID: original.uncategorizedID)
        _ = try await store.sendCalendar(.createItem(item), undoLabel: "添加事项")
        let registry = EditorFocusRegistry()

        #expect(try await CalendarUndoCommandRouter.undo(store: store, focusRegistry: registry) == .noFocusedOwner)
        #expect(store.calendarState == original)
        #expect(store.canRedo)
        #expect(try await CalendarUndoCommandRouter.redo(store: store, focusRegistry: registry) == .noFocusedOwner)
        #expect(store.calendarState.items[item.id] != nil)
    }

    @Test func focusedUnavailableNeverFallsBackToWorkspaceOnEitherSide() async throws {
        let original = makeEmptyState()
        let (store, _) = try await makeReadyStore(initialState: original)
        let item = try makeItem(categoryID: original.uncategorizedID)
        _ = try await store.sendCalendar(.createItem(item), undoLabel: "添加事项")
        let registry = EditorFocusRegistry()
        let manager = UndoManager()
        let target = RouterUndoTarget(manager: manager)
        target.value = 1
        manager.registerUndo(withTarget: target) { $0.undo() }
        registry.register(manager, ownerID: UUID())

        #expect(try await CalendarUndoCommandRouter.redo(store: store, focusRegistry: registry) == .focusedUnavailable)
        #expect(store.calendarState.items[item.id] != nil)
        _ = registry.routeUndo()
        #expect(try await CalendarUndoCommandRouter.undo(store: store, focusRegistry: registry) == .focusedUnavailable)
        #expect(store.calendarState.items[item.id] != nil)
    }

    @Test func focusPublisherAndWeakManagerReleasePublishAvailabilityTransitions() async {
        let registry = EditorFocusRegistry()
        var seen: [(Bool, Bool)] = []
        let token = registry.availabilityPublisher.sink { seen.append($0) }
        defer { token.cancel() }
        var manager: UndoManager? = UndoManager()
        let target = RouterUndoTarget(manager: manager!)
        target.value = 1
        registry.register(manager!, ownerID: UUID())
        manager!.registerUndo(withTarget: target) { $0.undo() }
        NotificationCenter.default.post(name: .NSUndoManagerCheckpoint, object: manager!)
        await Task.yield()
        _ = registry.routeUndo()
        await Task.yield()
        manager = nil
        #expect(registry.availability == .noFocusedOwner)
        #expect(seen.contains { $0.0 && !$0.1 })
        #expect(seen.contains { !$0.0 && $0.1 })
    }

    @Test func commandsObserveTheExactFocusRegistryInstanceForMenuRecomputation() async throws {
        let (store, _) = try await makeReadyStore(initialState: makeEmptyState())
        let registry = EditorFocusRegistry()
        let commands = CalendarUndoCommands(store: store, focusRegistry: registry)
        #expect(commands.focusRegistry === registry)

        let manager = UndoManager()
        let target = RouterUndoTarget(manager: manager)
        target.value = 1
        manager.registerUndo(withTarget: target) { $0.undo() }
        registry.register(manager, ownerID: UUID())
        NotificationCenter.default.post(name: .NSUndoManagerCheckpoint, object: manager)
        await Task.yield()
        #expect(CalendarUndoCommandRouter.isDisabled(for: store, focusRegistry: commands.focusRegistry) == false)
    }
}

@MainActor
private final class RouterUndoTarget: NSObject {
    weak var manager: UndoManager?
    var value = 0

    init(manager: UndoManager) { self.manager = manager }

    func undo() {
        value -= 1
        manager?.registerUndo(withTarget: self) { $0.redo() }
    }

    func redo() {
        value += 1
        manager?.registerUndo(withTarget: self) { $0.undo() }
    }
}
