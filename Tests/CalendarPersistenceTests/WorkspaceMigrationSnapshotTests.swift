import Foundation
import Testing
@testable import CalendarPersistence
@testable import WorkspaceDomain

@Suite("WorkspaceMigrationSnapshotTests")
struct WorkspaceMigrationSnapshotTests {
    @Test func firstV2SaveCreatesVerifiedRawSnapshotAndManifestBeforeV3Replacement() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let snapshots = directory.file("snapshots")
        let manifest = directory.file("recovery-manifest.json")
        let v2 = try WorkspacePersistenceFixtures.v2CalendarDocument()
        try v2.write(to: main)
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { .empty(calendar: WorkspacePersistenceFixtures.calendarState) },
            snapshotDirectoryURL: snapshots,
            recoveryManifestURL: manifest
        )
        _ = try await repository.load()

        _ = try await repository.save(try WorkspacePersistenceFixtures.workspaceWithOneNote())

        let recovery = try RecoveryManifestStore(manifestURL: manifest, snapshotDirectoryURL: snapshots).load()
        let record = try #require(recovery.entries.first)
        #expect(try Data(contentsOf: snapshots.appendingPathComponent(record.snapshotFileName)) == v2)
        #expect(record.sourceSHA256 == WorkspacePersistenceFixtures.sha256(v2))
        #expect(try WorkspaceDocumentCodec.decode(Data(contentsOf: main)).provenance.sourceSchema == 3)
    }

    @Test func failedSnapshotWriteLeavesV2MainByteForByteUntouched() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let v2 = try WorkspacePersistenceFixtures.v2CalendarDocument()
        try v2.write(to: main)
        let writer = WorkspacePersistenceFailingWriter { destination in
            destination.path.contains("snapshots")
        }
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { .empty(calendar: WorkspacePersistenceFixtures.calendarState) },
            snapshotDirectoryURL: directory.file("snapshots"),
            recoveryManifestURL: directory.file("manifest.json"),
            atomicWriter: writer
        )
        _ = try await repository.load()

        await #expect(throws: WorkspacePersistenceError.atomicWriteFailed) {
            try await repository.save(try WorkspacePersistenceFixtures.workspaceWithOneNote())
        }
        #expect(try Data(contentsOf: main) == v2)
    }

    @Test func sourceChangedBeforeSnapshotCreatesNeitherSnapshotNorManifest() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let loaded = try WorkspacePersistenceFixtures.v2CalendarDocument()
        let changed = Data("changed by cooperating process".utf8)
        try loaded.write(to: main)
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { .empty(calendar: WorkspacePersistenceFixtures.calendarState) },
            snapshotDirectoryURL: directory.file("snapshots"),
            recoveryManifestURL: directory.file("manifest.json")
        )
        _ = try await repository.load()
        try changed.write(to: main)

        await #expect(throws: WorkspacePersistenceError.sourceChanged) {
            try await repository.save(try WorkspacePersistenceFixtures.workspaceWithOneNote())
        }
        #expect(try Data(contentsOf: main) == changed)
        #expect(FileManager.default.fileExists(atPath: directory.file("manifest.json").path) == false)
        #expect(FileManager.default.fileExists(atPath: directory.file("snapshots").path) == false)
    }
}

struct WorkspacePersistenceTemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("JellyWorkspacePersistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
    func remove() { try? FileManager.default.removeItem(at: url) }
}

enum WorkspacePersistenceInjectedFailure: Error { case requested }

final class WorkspacePersistenceFailingWriter: AtomicFileWriting, @unchecked Sendable {
    private let predicate: @Sendable (URL) -> Bool

    init(predicate: @escaping @Sendable (URL) -> Bool) {
        self.predicate = predicate
    }

    func replaceAtomically(data: Data, at destination: URL) throws {
        if predicate(destination) { throw WorkspacePersistenceInjectedFailure.requested }
        try FoundationAtomicFileWriter().replaceAtomically(data: data, at: destination)
    }
}
