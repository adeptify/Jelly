import AppKit
import SwiftUI
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("NotesLifecycleWiringTests")
@MainActor
struct NotesLifecycleWiringTests {
    @Test func windowCloseWaitsForPersistenceThenReplaysTheCloseOnce() async {
        var closeCount = 0
        let coordinator = NotesWindowCloseCoordinator(
            decision: { .allow },
            closePerformer: { _ in closeCount += 1 }
        )
        let window = NSWindow()

        #expect(coordinator.windowShouldClose(window) == false)
        #expect(await waitUntil { closeCount == 1 })
        #expect(coordinator.windowShouldClose(window) == true)
        #expect(closeCount == 1)
    }

    @Test func windowCloseStaysVetoedWhenTheLatestDraftIsUnsafe() async {
        var closeCount = 0
        let coordinator = NotesWindowCloseCoordinator(
            decision: { .keepOpen },
            closePerformer: { _ in closeCount += 1 }
        )

        #expect(coordinator.windowShouldClose(NSWindow()) == false)
        await Task.yield()
        #expect(closeCount == 0)
    }

    @Test func applicationTerminationRepliesOnlyAfterThePersistenceDecision() async {
        var replies: [Bool] = []
        let coordinator = NotesApplicationTerminationCoordinator(
            decision: { .allow },
            reply: { replies.append($0) }
        )

        #expect(coordinator.applicationShouldTerminate(.shared) == .terminateLater)
        #expect(await waitUntil { replies == [true] })
    }

    @Test func unsafeTerminationIsCancelledInsteadOfDroppingTheDraft() async {
        var replies: [Bool] = []
        let coordinator = NotesApplicationTerminationCoordinator(
            decision: { .terminateLater },
            reply: { replies.append($0) }
        )

        #expect(coordinator.applicationShouldTerminate(.shared) == .terminateLater)
        #expect(await waitUntil { replies == [false] })
    }

    @Test func noteEditorPublishesItsLiveSessionToTheImportOwner() async {
        let calendar = makeEmptyState()
        let note = Note.empty(categoryID: calendar.uncategorizedID, now: .distantPast)
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        let autosave = NoteAutosaveCoordinator(store: store)
        var finalizer: NoteNativeInputFinalizer?
        var session: BlockEditorSession?
        let root = NoteEditorView(
            identity: .init(noteID: note.id, editSessionID: UUID()),
            note: note,
            focusRegistry: EditorFocusRegistry(),
            autosave: autosave,
            store: store,
            categories: Array(calendar.categories.values),
            onDocumentCommitted: { _ in },
            onTitleCommitted: { _ in },
            onCategoryChanged: { _ in },
            onRequestMarkdownImport: {},
            onRequestMarkdownExport: {},
            sessionSink: { session = $0 },
            nativeFinalizerHook: Binding(
                get: { finalizer },
                set: { finalizer = $0 }
            )
        )
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 600), styleMask: [], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        #expect(await waitUntil { session != nil })
    }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(1),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}
