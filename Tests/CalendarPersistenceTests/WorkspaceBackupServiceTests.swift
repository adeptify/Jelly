import Foundation
import Testing
@testable import CalendarPersistence
@testable import WorkspaceDomain

@Suite("WorkspaceBackupServiceTests")
struct WorkspaceBackupServiceTests {
    @Test func exportingLoadedLegacyBytesCopiesTheExactPrimaryWithoutForcingV3Save() async throws {
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

    @Test func invalidRestorePreviewCannotCreateCapabilityOrRollback() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("main.json")
        let source = directory.file("invalid.json")
        let current = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        let currentData = try WorkspaceDocumentCodec.encode(current)
        try currentData.write(to: main)
        try Data("not-json".utf8).write(to: source)
        let repository = JSONWorkspaceRepository(documentURL: main, seed: { current })
        _ = try await repository.load()

        await #expect(throws: WorkspacePersistenceError.invalidDocument) {
            _ = try await BackupService().inspectRestoreSource(source)
        }
        #expect(try Data(contentsOf: main) == currentData)
    }

    @Test func sourceChangedAfterRestoreRollbackUsesTypedArtifactAndDoesNotOverwriteExternalMain() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("main.json")
        let source = directory.file("restore.json")
        let current = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var restored = current
        restored.revision = 2
        restored.notes[restored.notes.keys.first!]!.revision = 2
        restored.notes[restored.notes.keys.first!]!.title = "恢复"
        let currentData = try WorkspaceDocumentCodec.encode(current)
        try currentData.write(to: main)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let external = Data("external-main".utf8)
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { current },
            mainFileWriter: WorkspacePersistenceMutatingMainWriter {
                _ = try FoundationMainFileCompareAndReplaceWriter().replaceIfSHA256Matches(
                    expectedSHA256: WorkspacePersistenceFixtures.sha256(currentData),
                    candidate: external,
                    at: main
                )
            }
        )
        _ = try await repository.load()
        let preview = try await BackupService().inspectRestoreSource(source)
        let prepared = try await repository.prepareRestore(preview, rollbackDirectoryURL: directory.url)

        do {
            _ = try await repository.commitRestore(prepared, state: restored)
            Issue.record("The cooperating external write must win the CAS")
        } catch let WorkspaceDirectCommitFailure.sourceChanged(artifacts) {
            guard case let .file(rollbackURL, identity)? = artifacts.rollback else {
                Issue.record("Restore source changes must return verified rollback evidence")
                return
            }
            #expect(try Data(contentsOf: rollbackURL) == currentData)
            #expect(identity.byteCount == currentData.count)
        }
        #expect(try Data(contentsOf: main) == external)
    }

    @Test func absentCreateRaceRestoreReturnsNonePreviousSourceAbsentArtifact() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("main.json")
        let source = directory.file("restore.json")
        let restored = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let external = Data("created-by-peer".utf8)
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { restored },
            mainFileWriter: WorkspacePersistenceCreateRaceWriter { try external.write(to: main) }
        )
        _ = try await repository.load()
        let preview = try await BackupService().inspectRestoreSource(source)
        let prepared = try await repository.prepareRestore(preview, rollbackDirectoryURL: directory.url)

        await #expect(throws: WorkspaceDirectCommitFailure.sourceChanged(
            .init(rollback: .nonePreviousSourceAbsent)
        )) {
            _ = try await repository.commitRestore(prepared, state: restored)
        }
        #expect(try Data(contentsOf: main) == external)
    }
}

struct WorkspacePersistenceCreateRaceWriter: MainFileCompareAndReplaceWriting {
    let createPeerFile: @Sendable () throws -> Void

    func createIfAbsent(candidate: Data, at destination: URL) throws -> MainFileCompareAndReplaceResult {
        try createPeerFile()
        return try FoundationMainFileCompareAndReplaceWriter().createIfAbsent(
            candidate: candidate,
            at: destination
        )
    }

    func replaceIfSHA256Matches(
        expectedSHA256: String,
        candidate: Data,
        at destination: URL
    ) throws -> MainFileCompareAndReplaceResult {
        try FoundationMainFileCompareAndReplaceWriter().replaceIfSHA256Matches(
            expectedSHA256: expectedSHA256,
            candidate: candidate,
            at: destination
        )
    }
}
