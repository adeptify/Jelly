import CalendarDomain
import CalendarPersistence
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

/// Real repository vertical slice for Task 10D: V2 bytes → migrate → create note
/// → protect/commit → restart Store and reload exact note.
@Suite("NotesVerticalIntegrationTests")
@MainActor
struct NotesVerticalIntegrationTests {
    @Test func v2UpgradeCreateNoteProtectCommitAndRestartPreservesNoteAndCalendar() async throws {
        let directory = try NotesVerticalTempDirectory()
        defer { directory.remove() }

        let main = directory.file("calendar-v1.json")
        let snapshots = directory.file("snapshots")
        let manifest = directory.file("recovery-manifest.json")
        let journalURL = directory.file("draft-journal.json")
        let v2 = try NotesVerticalFixtures.v2CalendarDocument()
        try v2.write(to: main)

        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { .empty(calendar: NotesVerticalFixtures.calendarState) },
            snapshotDirectoryURL: snapshots,
            recoveryManifestURL: manifest
        )
        let journal = DraftJournalRepository(fileURL: journalURL)
        let store = WorkspaceStore(
            initialState: .empty(calendar: NotesVerticalFixtures.calendarState),
            repository: repository,
            journal: journal
        )
        await store.load()
        switch store.phase {
        case .ready, .needsDraftRecovery:
            break
        default:
            Issue.record("unexpected phase after V2 load: \(store.phase)")
        }

        let originalCalendar = store.calendarState
        let note = Note.empty(
            id: NoteID(UUID(uuidString: "00000000-0000-0000-0000-00000000A101")!),
            categoryID: originalCalendar.uncategorizedID,
            now: Date(timeIntervalSince1970: 1_754_100_000)
        )
        var authored = note
        authored.title = "竖切笔记"
        authored.document = BlockDocument(blocks: [
            .init(
                id: BlockID(UUID(uuidString: "00000000-0000-0000-0000-00000000A102")!),
                kind: .paragraph,
                inlineContent: .plain("第一段正文"),
                taskState: nil,
                indentLevel: 0
            ),
            try .task(
                id: BlockID(UUID(uuidString: "00000000-0000-0000-0000-00000000A103")!),
                text: "待办块"
            )
        ])

        let autosave = NoteAutosaveCoordinator(store: store, scheduler: VerticalImmediateScheduler())
        let viewModel = NotesWorkspaceViewModel(store: store, autosave: autosave)
        #expect(try await viewModel.create(authored))
        #expect(viewModel.selectedNoteID == authored.id)

        // Title + body edits through the production autosave path.
        _ = try autosave.update(title: "竖切笔记-已编辑")
        _ = try autosave.update(document: authored.document)
        let evidence = await autosave.flushLatest()
        #expect(evidence == .persisted(try #require(autosave.currentTriple)))

        // Main file must now be V3 and recovery snapshot of original V2 exists.
        let mainBytes = try Data(contentsOf: main)
        #expect(try WorkspaceDocumentCodec.decode(mainBytes).provenance.sourceSchema == 3)
        let recovery = try RecoveryManifestStore(manifestURL: manifest, snapshotDirectoryURL: snapshots).load()
        #expect(recovery.entries.isEmpty == false)

        // Fresh Store/repository/journal must reload the exact Note.
        let repository2 = JSONWorkspaceRepository(
            documentURL: main,
            seed: { .empty(calendar: NotesVerticalFixtures.calendarState) },
            snapshotDirectoryURL: snapshots,
            recoveryManifestURL: manifest
        )
        let journal2 = DraftJournalRepository(fileURL: journalURL)
        let store2 = WorkspaceStore(
            initialState: .empty(calendar: NotesVerticalFixtures.calendarState),
            repository: repository2,
            journal: journal2
        )
        await store2.load()
        let reloaded = try #require(store2.state.notes[authored.id])
        #expect(reloaded.title == "竖切笔记-已编辑")
        #expect(reloaded.document.blocks.count == 2)
        #expect(store2.calendarState.uncategorizedID == originalCalendar.uncategorizedID)
        #expect(store2.calendarState.categories.keys.sorted(by: { $0.uuidString < $1.uuidString })
            == originalCalendar.categories.keys.sorted(by: { $0.uuidString < $1.uuidString }))
    }

    @Test func productionAppShellBuildsNotesHostWithoutFatalPlaceholder() {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        let routeState = WorkspaceRouteState(
            features: .production,
            preferences: SpyWorkspaceRoutePreferenceStore(initial: "calendar")
        )
        let router = WorkspaceNewItemRouter()
        let focus = EditorFocusRegistry()
        let transition = WorkspaceRouteTransitionCoordinator(routeState: routeState, features: .production)
        let shell = AppShellView(
            store: store,
            features: .production,
            routeState: routeState,
            newItemRouter: router,
            focusRegistry: focus,
            transitionCoordinator: transition
        )
        // Host store is built in init; notes must be present, inspiration absent.
        #expect(WorkspaceRoute.visibleRoutes(.production) == [.calendar, .notes])
        _ = shell
    }
}

@MainActor
private final class VerticalImmediateScheduler: NoteAutosaveScheduling {
    func sleep(milliseconds: UInt64) async throws {}
}

private enum NotesVerticalFixtures {
    static let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
    static let calendarState = CalendarState.empty(uncategorizedID: categoryID, now: Date(timeIntervalSince1970: 0))

    static func v2CalendarDocument() throws -> Data {
        try JSONEncoder.workspaceDeterministic.encode(CalendarDocument(state: calendarState))
    }
}

private final class NotesVerticalTempDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-notes-vertical-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
