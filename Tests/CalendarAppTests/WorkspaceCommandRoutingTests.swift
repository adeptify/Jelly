import AppKit
import CalendarDomain
import Testing
@testable import CalendarApp

@Suite("WorkspaceCommandRoutingTests")
@MainActor
struct WorkspaceCommandRoutingTests {
    private let today = CalendarDate(year: 2026, month: 8, day: 10)!
    private let selectedDate = CalendarDate(year: 2026, month: 8, day: 11)!
    private let drawerDate = CalendarDate(year: 2026, month: 8, day: 12)!

    @Test func commandNumberShortcutsMapToStableRoutes() {
        #expect(WorkspaceRoute.commandShortcut("1") == .calendar)
        #expect(WorkspaceRoute.commandShortcut("2") == .notes)
        #expect(WorkspaceRoute.commandShortcut("3") == .inspiration)
        #expect(WorkspaceRoute.commandShortcut("4") == nil)
    }

    @Test func navigationCommandCompositionConstructsEnabledRoutesOnly() {
        let calendarOnly = WorkspaceCommandComposition.navigationDescriptors(
            features: .calendarOnly
        )
        #expect(calendarOnly.map(\.route) == [.calendar])
        #expect(calendarOnly.map(\.title) == ["日历"])
        #expect(calendarOnly.map(\.key) == ["1"])

        let calendarAndNotes = WorkspaceCommandComposition.navigationDescriptors(
            features: .init(notes: true, inspiration: false)
        )
        #expect(calendarAndNotes.map(\.route) == [.calendar, .notes])
        #expect(calendarAndNotes.map(\.title) == ["日历", "笔记"])
        #expect(calendarAndNotes.map(\.key) == ["1", "2"])

        let completeWorkspace = WorkspaceCommandComposition.navigationDescriptors(
            features: .init(notes: true, inspiration: true)
        )
        #expect(completeWorkspace.map(\.route) == [.calendar, .notes, .inspiration])
        #expect(completeWorkspace.map(\.title) == ["日历", "笔记", "灵感"])
        #expect(completeWorkspace.map(\.key) == ["1", "2", "3"])
    }

    @Test func disabledRoutesAreNotActivatableAndCommandNStaysCalendarScoped() {
        let preferences = SpyWorkspaceRoutePreferenceStore(initial: "calendar")
        let state = WorkspaceRouteState(features: .calendarOnly, preferences: preferences)

        #expect(state.handleCommandShortcut("2", features: .calendarOnly) == false)
        #expect(state.route == .calendar)
        #expect(state.commandNAction(features: .calendarOnly) == .createCalendarItem)
        #expect(preferences.writes.isEmpty)
    }

    @Test func calendarNewItemRequestIsConsumedOnceByItsMatchingRoute() {
        let router = WorkspaceNewItemRouter()
        let request = try! #require(router.requestNewItem(route: .calendar, features: .calendarOnly))

        #expect(router.consume(request.id, route: .notes) == nil)
        #expect(router.consume(request.id, route: .calendar) == request)
        #expect(router.consume(request.id, route: .calendar) == nil)
    }

    @Test func disabledRouteCannotCreateANewItemRequest() {
        let router = WorkspaceNewItemRouter()

        #expect(router.requestNewItem(route: .notes, features: .calendarOnly) == nil)
        #expect(router.pendingRequest == nil)
    }

    @Test func blockedNewNoteCanDiscardCapturedTypingWithoutReplayingIntoTheOldEditor() async throws {
        _ = NSApplication.shared
        let router = WorkspaceNewItemRouter()
        let receiver = NewItemKeyEventProbe(frame: .init(x: 0, y: 0, width: 100, height: 40))
        let window = NSWindow(
            contentRect: receiver.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = receiver
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        #expect(window.makeFirstResponder(receiver))
        let request = try #require(router.requestNewItem(
            route: .notes,
            features: .production,
            capturesTypingUntilReady: true,
            sourceWindowNumber: window.windowNumber
        ))
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "不应回放",
            charactersIgnoringModifiers: "不应回放",
            isARepeat: false,
            keyCode: 0
        ))
        NSApplication.shared.sendEvent(event)
        #expect(receiver.values.isEmpty)

        router.discardCapturedTyping(for: request.id)
        await Task.yield()

        #expect(receiver.values.isEmpty)
    }

    @Test func calendarNewItemDateUsesDrawerThenSelectionThenToday() {
        #expect(CalendarNewItemRequestPolicy.resolve(
            dayDrawerDate: drawerDate,
            selectedDate: selectedDate,
            today: today,
            isQuickCreatePresented: false,
            isItemEditorPresented: false
        ) == drawerDate)
        #expect(CalendarNewItemRequestPolicy.resolve(
            dayDrawerDate: nil,
            selectedDate: selectedDate,
            today: today,
            isQuickCreatePresented: false,
            isItemEditorPresented: false
        ) == selectedDate)
        #expect(CalendarNewItemRequestPolicy.resolve(
            dayDrawerDate: nil,
            selectedDate: nil,
            today: today,
            isQuickCreatePresented: false,
            isItemEditorPresented: false
        ) == today)
    }

    @Test func calendarNewItemRequestIsBlockedWhenAnEditorIsAlreadyOpen() {
        #expect(CalendarNewItemRequestPolicy.resolve(
            dayDrawerDate: drawerDate,
            selectedDate: selectedDate,
            today: today,
            isQuickCreatePresented: true,
            isItemEditorPresented: false
        ) == nil)
        #expect(CalendarNewItemRequestPolicy.resolve(
            dayDrawerDate: drawerDate,
            selectedDate: selectedDate,
            today: today,
            isQuickCreatePresented: false,
            isItemEditorPresented: true
        ) == nil)
    }
}

@MainActor
private final class NewItemKeyEventProbe: NSView {
    private(set) var values: [String] = []

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        values.append(event.characters ?? "")
    }
}
