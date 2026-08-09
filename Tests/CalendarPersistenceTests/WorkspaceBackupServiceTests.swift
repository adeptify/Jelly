import Foundation
import Testing
@testable import CalendarPersistence
@testable import WorkspaceDomain

@Suite("WorkspaceBackupServiceTests")
struct WorkspaceBackupServiceTests {
    @Test func exportingLoadedV2CopiesExactRawBytesWithoutForcingV3Save() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let destination = directory.file("backup.json")
        let v2 = try WorkspacePersistenceFixtures.v2CalendarDocument()
        try v2.write(to: main)
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { .empty(calendar: WorkspacePersistenceFixtures.calendarState) }
        )
        _ = try await repository.load()

        try await BackupService().exportCurrent(from: repository, to: destination)

        #expect(try Data(contentsOf: destination) == v2)
        #expect(try Data(contentsOf: main) == v2)
    }

    @Test func prepareRestoreBindsSourceRevisionsToExactlyItsPreparedContent() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let source = directory.file("restore.json")
        let current = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 4)
        let restored = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 8)
        try WorkspaceDocumentCodec.encode(current).write(to: main)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { .empty(calendar: WorkspacePersistenceFixtures.calendarState) }
        )
        _ = try await repository.load()

        let prepared = try await repository.prepareRestore(.init(sourceURL: source, rollbackDirectoryURL: directory.url))

        #expect(prepared.content == WorkspaceContentSnapshot(state: restored))
        #expect(prepared.sourceNoteRevisions == restored.notes.mapValues(\.revision))
        #expect(Set(prepared.sourceNoteRevisions.keys) == Set(prepared.content.notes.keys))
    }

    @Test func restoreRejectsCandidateWithDifferentBusinessContentBeforeRollbackWrite() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let source = directory.file("restore.json")
        let current = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        let restored = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 2)
        try WorkspaceDocumentCodec.encode(current).write(to: main)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let repository = JSONWorkspaceRepository(documentURL: main, seed: { current })
        _ = try await repository.load()
        let prepared = try await repository.prepareRestore(.init(sourceURL: source, rollbackDirectoryURL: directory.url))
        var wrong = restored
        wrong.revision = 3
        wrong.notes[wrong.notes.keys.first!]!.title = "not the prepared content"

        await #expect(throws: WorkspacePersistenceError.restoreBindingMismatch) {
            _ = try await repository.commitRestore(prepared, state: wrong)
        }
        let persisted = try Data(contentsOf: main)
        let expected = try WorkspaceDocumentCodec.encode(current)
        #expect(persisted == expected)
    }
}
