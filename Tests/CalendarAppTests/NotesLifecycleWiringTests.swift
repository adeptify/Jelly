import AppKit
import CalendarDomain
import CalendarPersistence
import SwiftUI
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("NotesLifecycleWiringTests")
@MainActor
struct NotesLifecycleWiringTests {
    @Test func returningFromCalendarRefreshesAnExternallyCompletedTaskBlock() async throws {
        _ = NSApplication.shared
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let blockID = BlockID()
        var note = Note.empty(categoryID: calendar.uncategorizedID, now: .distantPast)
        note.title = "跨页面完成同步"
        note.document = .init(blocks: [try .task(id: blockID, text: "从日历完成")])
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let item = try CalendarItem(
            id: UUID(),
            kind: .task,
            title: "从日历完成",
            categoryID: calendar.uncategorizedID,
            schedule: try .init(
                startDate: CalendarDate(year: 2026, month: 8, day: 13)!,
                endDate: CalendarDate(year: 2026, month: 8, day: 13)!,
                startTime: nil,
                endTime: nil
            ),
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        _ = try await store.sendWorkspace(.scheduleTaskBlock(.init(
            noteID: note.id,
            blockID: blockID,
            item: item
        )))
        let features = WorkspaceFeatures.production
        let routeState = WorkspaceRouteState(
            features: features,
            preferences: NotesTestRoutePreferenceStore(initial: "notes")
        )
        let transition = WorkspaceRouteTransitionCoordinator(routeState: routeState, features: features)
        let router = WorkspaceDeepLinkRouter()
        let newItemRouter = WorkspaceNewItemRouter()
        let root = NotesSplitView(
            store: store,
            focusRegistry: EditorFocusRegistry(),
            transitionCoordinator: transition,
            deepLinkRouter: router,
            newItemRouter: newItemRouter,
            searchIndex: WorkspaceSearchIndex()
        )
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 900, height: 600),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        _ = router.request(.note(note.id))

        #expect(await waitUntil {
            hosting.layoutSubtreeIfNeeded()
            return notesDescendants(of: hosting, as: NSButton.self).contains {
                $0.accessibilityIdentifier() == "task-block-checkbox-\(blockID.rawValue.uuidString)"
                    && $0.state == .off
            }
        })
        #expect(await transition.requestActivation(.calendar))
        let completedAt = Date(timeIntervalSince1970: 1_786_551_000)

        _ = try await TaskBlockCalendarIntegration.completeFromCalendar(
            store: store,
            itemID: item.id,
            at: completedAt
        )

        #expect(await waitUntil {
            hosting.layoutSubtreeIfNeeded()
            return notesDescendants(of: hosting, as: NSButton.self).contains {
                $0.accessibilityIdentifier() == "task-block-checkbox-\(blockID.rawValue.uuidString)"
                    && $0.state == .on
            }
        })
    }

    @Test func reopeningLinkedTaskThenCreatingNoteShowsTheNewEditor() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-notes-linked-create-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let calendar = makeEmptyState()
        let seed = WorkspaceState.empty(calendar: calendar)
        let repository = JSONWorkspaceRepository(
            documentURL: directory.appendingPathComponent("calendar-v1.json"),
            seed: { seed }
        )
        let journal = DraftJournalRepository(
            fileURL: directory.appendingPathComponent("calendar-v1.draft-journal.json")
        )
        let store = WorkspaceStore(initialState: seed, repository: repository, journal: journal)
        await store.load()
        let blockID = BlockID()
        var note = Note.empty(categoryID: calendar.uncategorizedID, now: .distantPast)
        note.title = "跨页面后继续新建"
        note.document = .init(blocks: [try .task(id: blockID, text: "任务")])
        _ = try await store.sendWorkspace(.createNote(.init(note: note)))
        let item = try CalendarItem(
            id: UUID(),
            kind: .task,
            title: "任务",
            categoryID: calendar.uncategorizedID,
            schedule: try .init(
                startDate: CalendarDate(year: 2026, month: 8, day: 13)!,
                endDate: CalendarDate(year: 2026, month: 8, day: 13)!,
                startTime: nil,
                endTime: nil
            ),
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        _ = try await store.sendWorkspace(.scheduleTaskBlock(.init(
            noteID: note.id,
            blockID: blockID,
            item: item
        )))
        let features = WorkspaceFeatures.production
        let routeState = WorkspaceRouteState(
            features: features,
            preferences: NotesTestRoutePreferenceStore(initial: "notes")
        )
        let transition = WorkspaceRouteTransitionCoordinator(routeState: routeState, features: features)
        let router = WorkspaceDeepLinkRouter()
        let newItemRouter = WorkspaceNewItemRouter()
        let root = NotesSplitView(
            store: store,
            focusRegistry: EditorFocusRegistry(),
            transitionCoordinator: transition,
            deepLinkRouter: router,
            newItemRouter: newItemRouter,
            searchIndex: WorkspaceSearchIndex()
        )
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 900, height: 600),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        _ = router.request(.note(note.id))
        #expect(await waitUntil {
            hosting.layoutSubtreeIfNeeded()
            return notesDescendants(of: hosting, as: NSButton.self).contains {
                $0.accessibilityIdentifier() == "task-block-checkbox-\(blockID.rawValue.uuidString)"
            }
        })
        #expect(await transition.requestActivation(.calendar))
        _ = try await TaskBlockCalendarIntegration.completeFromCalendar(
            store: store,
            itemID: item.id,
            at: Date(timeIntervalSince1970: 1_786_551_000)
        )
        #expect(await transition.requestActivation(.notes))
        let checkbox = try #require(notesDescendants(of: hosting, as: NSButton.self).first {
            $0.accessibilityIdentifier() == "task-block-checkbox-\(blockID.rawValue.uuidString)"
        })
        checkbox.performClick(checkbox)
        #expect(await waitUntil {
            store.state.notes[note.id]?.document.blocks.first?.taskState?.completedAt == nil
        })
        _ = newItemRouter.requestNewItem(route: .notes, features: .production)

        #expect(await waitUntil { store.state.notes.count == 2 })
        #expect(await waitUntil {
            hosting.layoutSubtreeIfNeeded()
            return notesDescendants(of: hosting, as: NSTextField.self).contains {
                $0.placeholderString == "标题" && $0.stringValue.isEmpty
            }
        })
    }

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

    @Test func mountedNotesHostConsumesADeepLinkRequestedAfterItsInitialAppearance() async throws {
        let calendar = makeEmptyState()
        var first = Note.empty(categoryID: calendar.uncategorizedID, now: .distantPast)
        first.title = "已有笔记"
        var target = Note.empty(categoryID: calendar.uncategorizedID, now: .distantPast)
        target.title = "灵感转成的笔记"
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: first)))
        _ = try await store.sendWorkspace(.createNote(.init(note: target)))
        let router = WorkspaceDeepLinkRouter()
        let root = NotesSplitView(
            store: store,
            focusRegistry: EditorFocusRegistry(),
            deepLinkRouter: router,
            newItemRouter: WorkspaceNewItemRouter(),
            searchIndex: WorkspaceSearchIndex()
        )
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 900, height: 600),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        await Task.yield()
        await Task.yield()

        let request = router.request(.note(target.id))

        #expect(await waitUntil { router.pendingRequest?.id != request.id })
        #expect(await waitUntil {
            hosting.layoutSubtreeIfNeeded()
            return notesDescendants(of: hosting, as: NSTextField.self).contains {
                $0.stringValue == "灵感转成的笔记"
            }
        })
        #expect(await waitUntil {
            hosting.layoutSubtreeIfNeeded()
            return window.firstResponder is ContinuousBlockEditorTextView
        })
        window.orderOut(nil)
    }

    @Test func activeNoteDeepLinkReturnsTheBrowserFromArchiveToRecent() async throws {
        let calendar = makeEmptyState()
        var archived = Note.empty(categoryID: calendar.uncategorizedID, now: .distantPast)
        archived.title = "归档笔记"
        archived.archivedAt = .distantPast
        var converted = Note.empty(categoryID: calendar.uncategorizedID, now: .distantPast)
        converted.title = "灵感转成的笔记"
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: archived)))
        _ = try await store.sendWorkspace(.createNote(.init(note: converted)))
        let router = WorkspaceDeepLinkRouter()
        let root = NotesSplitView(
            store: store,
            focusRegistry: EditorFocusRegistry(),
            deepLinkRouter: router,
            newItemRouter: WorkspaceNewItemRouter(),
            searchIndex: WorkspaceSearchIndex()
        )
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 900, height: 600),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        let scope = try #require(notesDescendants(of: hosting, as: NSSegmentedControl.self).first {
            $0.segmentCount == NotesBrowserPartition.allCases.count
        })
        scope.selectedSegment = 2
        scope.sendAction(scope.action, to: scope.target)
        #expect(await waitUntil { scope.selectedSegment == 2 })

        _ = router.request(.note(converted.id))

        #expect(await waitUntil {
            hosting.layoutSubtreeIfNeeded()
            return scope.selectedSegment == 0
        })
        #expect(notesDescendants(of: hosting, as: NSTextField.self).contains {
            $0.stringValue == "灵感转成的笔记"
        })
    }

    @Test func creatingANoteRebuildsTheTitleFieldForTheNewEditorIdentity() async throws {
        let calendar = makeEmptyState()
        var existing = Note.empty(categoryID: calendar.uncategorizedID, now: .distantPast)
        existing.title = "上一条笔记"
        let repository = InMemoryWorkspaceRepository(initialState: calendar)
        let store = WorkspaceStore(initialState: .empty(calendar: calendar), repository: repository)
        await store.load()
        _ = try await store.sendWorkspace(.createNote(.init(note: existing)))
        let deepLinkRouter = WorkspaceDeepLinkRouter()
        let newItemRouter = WorkspaceNewItemRouter()
        let root = NotesSplitView(
            store: store,
            focusRegistry: EditorFocusRegistry(),
            deepLinkRouter: deepLinkRouter,
            newItemRouter: newItemRouter,
            searchIndex: WorkspaceSearchIndex()
        )
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 900, height: 600),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        _ = deepLinkRouter.request(.note(existing.id))
        #expect(await waitUntil {
            hosting.layoutSubtreeIfNeeded()
            return notesDescendants(of: hosting, as: NSTextField.self).contains {
                $0.placeholderString == "标题" && $0.stringValue == "上一条笔记"
            }
        })

        _ = newItemRouter.requestNewItem(route: .notes, features: .production)

        #expect(await waitUntil { store.state.notes.count == 2 })
        #expect(await waitUntil {
            hosting.layoutSubtreeIfNeeded()
            return notesDescendants(of: hosting, as: NSTextField.self).contains {
                $0.placeholderString == "标题" && $0.stringValue.isEmpty
            }
        })
        let title = try #require(notesDescendants(of: hosting, as: NSTextField.self).first {
            $0.placeholderString == "标题" && $0.stringValue.isEmpty
        })
        #expect(await waitUntil {
            window.firstResponder === title || window.firstResponder === title.currentEditor()
        })
        let coordinator = try #require(title.delegate as? NoteTitleTextField.Coordinator)
        let fieldEditor = (title.currentEditor() as? NSTextView) ?? NSTextView()
        #expect(coordinator.control(
            title,
            textView: fieldEditor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))
        #expect(await waitUntil { window.firstResponder is ContinuousBlockEditorTextView })
        let body = try #require(notesDescendants(of: hosting, as: ContinuousBlockEditorTextView.self).first)
        #expect(body.isPresentingEmptyDocumentPlaceholder)
        #expect(body.string.isEmpty)
        let created = try #require(store.state.notes.values.first { $0.id != existing.id })
        #expect(created.document.blocks.flatMap(\.inlineContent.spans).map(\.text).joined().isEmpty)
        window.orderOut(nil)
    }

    @Test func mountedNotesHostCompletesAsyncStartupLoadForAnAlreadyPersistedDraft() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-notes-startup-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("workspace.json")
        let journalURL = directory.appendingPathComponent("workspace.draft-journal.json")
        let initial = WorkspaceState.empty(calendar: makeEmptyState())
        let writerRepository = JSONWorkspaceRepository(documentURL: documentURL, seed: { initial })
        let writer = WorkspaceStore(initialState: initial, repository: writerRepository)
        await writer.load()
        var note = Note.empty(categoryID: initial.calendar.uncategorizedID, now: .distantPast)
        note.title = "启动恢复验收"
        _ = try await writer.sendWorkspace(.createNote(.init(note: note)))
        let persisted = try #require(writer.state.notes[note.id])
        let journal = DraftJournalRepository(fileURL: journalURL)
        try await journal.persist(try identicalRecoveryEntry(
            note: persisted,
            workspaceRevision: writer.state.revision
        ))

        let readerRepository = JSONWorkspaceRepository(documentURL: documentURL, seed: { initial })
        let reader = WorkspaceStore(initialState: initial, repository: readerRepository, journal: journal)
        let root = NotesSplitView(
            store: reader,
            focusRegistry: EditorFocusRegistry(),
            newItemRouter: WorkspaceNewItemRouter(),
            searchIndex: WorkspaceSearchIndex()
        )
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer {
            for sheet in window.sheets {
                window.endSheet(sheet)
                sheet.orderOut(nil)
            }
            window.orderOut(nil)
        }
        hosting.layoutSubtreeIfNeeded()

        await reader.load()

        #expect(reader.phase == .ready)
        #expect(try await journal.current()?.records.isEmpty == true)
        #expect(window.sheets.isEmpty)
    }
}

@MainActor
private final class NotesTestRoutePreferenceStore: WorkspaceRoutePreferenceStore {
    private var value: String?

    init(initial: String?) {
        value = initial
    }

    var selectedRouteRawValue: String? { value }

    func writeSelectedRouteRawValue(_ rawValue: String) {
        value = rawValue
    }
}

private func identicalRecoveryEntry(note: Note, workspaceRevision: Int64) throws -> DraftJournalEntry {
    let snapshotChecksum = try WorkspaceChecksum.noteSnapshotChecksum(note)
    let unsigned = DraftJournalEntry(
        noteID: note.id,
        editSessionID: .editor(UUID()),
        baseWorkspaceRevision: workspaceRevision,
        baseNoteRevision: note.revision,
        draftGeneration: 1,
        noteSnapshot: note,
        updatedAt: .distantPast,
        noteSnapshotChecksum: snapshotChecksum,
        journalChecksum: ""
    )
    return DraftJournalEntry(
        noteID: unsigned.noteID,
        editSessionID: unsigned.editSessionID,
        baseWorkspaceRevision: unsigned.baseWorkspaceRevision,
        baseNoteRevision: unsigned.baseNoteRevision,
        draftGeneration: unsigned.draftGeneration,
        noteSnapshot: unsigned.noteSnapshot,
        updatedAt: unsigned.updatedAt,
        noteSnapshotChecksum: unsigned.noteSnapshotChecksum,
        journalChecksum: try DraftJournal.entryChecksum(for: unsigned)
    )
}

@MainActor
private func notesDescendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
    var result = view as? T == nil ? [] : [view as! T]
    for child in view.subviews {
        result.append(contentsOf: notesDescendants(of: child, as: type))
    }
    return result
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
