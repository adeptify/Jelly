import CalendarDomain
import CalendarPersistence
import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

/// Automated end-to-end slice covering V2 upgrade, note, relation, inspiration
/// and restart — Task 15 automated gate (isolated temp data only).
@Suite("WorkspaceEndToEndTests")
@MainActor
struct WorkspaceEndToEndTests {
    @Test func v2UpgradeNotesRelationsInspirationAndRestart() async throws {
        let directory = try E2ETempDirectory()
        defer { directory.remove() }

        let main = directory.file("calendar-v1.json")
        let snapshots = directory.file("snapshots")
        let manifest = directory.file("recovery-manifest.json")
        let journalURL = directory.file("draft-journal.json")
        let v2 = try JSONEncoder.workspaceDeterministic.encode(
            CalendarDocument(state: E2EFixtures.calendarState)
        )
        try v2.write(to: main)

        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { .empty(calendar: E2EFixtures.calendarState) },
            snapshotDirectoryURL: snapshots,
            recoveryManifestURL: manifest
        )
        let journal = DraftJournalRepository(fileURL: journalURL)
        let store = WorkspaceStore(
            initialState: .empty(calendar: E2EFixtures.calendarState),
            repository: repository,
            journal: journal
        )
        await store.load()
        let originalUncategorized = store.calendarState.uncategorizedID

        // Note
        let note = Note.empty(id: NoteID(), categoryID: originalUncategorized, now: .distantPast)
        var authored = note
        authored.title = "E2E 笔记"
        _ = try await store.sendWorkspace(.createNote(.init(note: authored)))
        let autosave = NoteAutosaveCoordinator(store: store, scheduler: E2EImmediateScheduler())
        try autosave.beginSession(
            store.state.notes[authored.id]!,
            linkedTaskBlockLinks: [],
            editSessionID: UUID(),
            activeHostToken: UUID()
        )
        _ = try autosave.update(title: "E2E 笔记-已存")
        #expect(await autosave.flushLatest() == .persisted(try #require(autosave.currentTriple)))

        // Calendar item + primary relation
        let day = CalendarDate(year: 2026, month: 8, day: 20)!
        let item = try CalendarItem(
            id: UUID(), kind: .task, title: "E2E 事项", categoryID: originalUncategorized,
            schedule: try CalendarSchedule(startDate: day, endDate: day, startTime: nil, endTime: nil),
            completedAt: nil, createdAt: .distantPast, updatedAt: .distantPast
        )
        _ = try await store.sendWorkspace(.calendar(.createItem(item)))
        let relation = CalendarNoteIntegrationModel(target: .item(item.id), store: store)
        #expect(try await relation.chooseExistingPrimary(authored.id))

        // Inspiration → note
        let inspirationModel = InspirationViewModel(store: store)
        let inspirationID = try await inspirationModel.capture("E2E 灵感原文")
        inspirationModel.select(inspirationID)
        let convertedNoteID = try await inspirationModel.convertSelectedToNote()
        #expect(convertedNoteID != nil)

        // Restart
        let repository2 = JSONWorkspaceRepository(
            documentURL: main,
            seed: { .empty(calendar: E2EFixtures.calendarState) },
            snapshotDirectoryURL: snapshots,
            recoveryManifestURL: manifest
        )
        let store2 = WorkspaceStore(
            initialState: .empty(calendar: E2EFixtures.calendarState),
            repository: repository2,
            journal: DraftJournalRepository(fileURL: journalURL)
        )
        await store2.load()
        #expect(store2.state.notes[authored.id]?.title == "E2E 笔记-已存")
        #expect(store2.calendarState.items[item.id] != nil)
        #expect(store2.state.calendarNoteRelations.baselines[.item(item.id)]?.primaryNoteID == authored.id)
        #expect(store2.state.inspirations[inspirationID] != nil)
        #expect(convertedNoteID.map { store2.state.notes[$0] != nil } == true)
        #expect(try WorkspaceDocumentCodec.decode(Data(contentsOf: main)).provenance.sourceSchema == 3)
        let recovery = try RecoveryManifestStore(manifestURL: manifest, snapshotDirectoryURL: snapshots).load()
        #expect(!recovery.entries.isEmpty)
    }
}

@MainActor
private final class E2EImmediateScheduler: NoteAutosaveScheduling {
    func sleep(milliseconds: UInt64) async throws {}
}

private enum E2EFixtures {
    static let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
    static let calendarState = CalendarState.empty(uncategorizedID: categoryID, now: Date(timeIntervalSince1970: 0))
}

private final class E2ETempDirectory {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
    func remove() { try? FileManager.default.removeItem(at: url) }
}
