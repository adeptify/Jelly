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

    @Test func corruptedSnapshotReadbackFailsClosedBeforeReplacingV2Main() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let v2 = try WorkspacePersistenceFixtures.v2CalendarDocument()
        try v2.write(to: main)
        let writer = WorkspacePersistenceCorruptingWriter {
            $0.deletingLastPathComponent() == directory.file("snapshots")
        }
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { .empty(calendar: WorkspacePersistenceFixtures.calendarState) },
            snapshotDirectoryURL: directory.file("snapshots"),
            recoveryManifestURL: directory.file("manifest.json"),
            atomicWriter: writer
        )
        _ = try await repository.load()

        await #expect(throws: WorkspacePersistenceError.invalidSnapshot) {
            _ = try await repository.save(try WorkspacePersistenceFixtures.workspaceWithOneNote())
        }
        #expect(try Data(contentsOf: main) == v2)
    }

    @Test func manifestWriteFailureFailsClosedBeforeReplacingV2Main() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let manifest = directory.file("manifest.json")
        let v2 = try WorkspacePersistenceFixtures.v2CalendarDocument()
        try v2.write(to: main)
        let writer = WorkspacePersistenceFailingWriter { $0 == manifest }
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { .empty(calendar: WorkspacePersistenceFixtures.calendarState) },
            snapshotDirectoryURL: directory.file("snapshots"),
            recoveryManifestURL: manifest,
            atomicWriter: writer
        )
        _ = try await repository.load()

        await #expect(throws: WorkspacePersistenceError.atomicWriteFailed) {
            _ = try await repository.save(try WorkspacePersistenceFixtures.workspaceWithOneNote())
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

    @Test func preexistingSnapshotSymlinkFailsClosedWithoutReplacingV2Main() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let snapshots = directory.file("snapshots")
        let manifest = directory.file("manifest.json")
        let v2 = try WorkspacePersistenceFixtures.v2CalendarDocument()
        try v2.write(to: main)
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
        let expectedName = "calendar-v2-\(WorkspacePersistenceFixtures.sha256(v2)).json"
        let outside = directory.file("outside.json")
        try v2.write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: snapshots.appendingPathComponent(expectedName),
            withDestinationURL: outside
        )
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { .empty(calendar: WorkspacePersistenceFixtures.calendarState) },
            snapshotDirectoryURL: snapshots,
            recoveryManifestURL: manifest
        )
        _ = try await repository.load()

        await #expect(throws: WorkspacePersistenceError.invalidSnapshot) {
            _ = try await repository.save(try WorkspacePersistenceFixtures.workspaceWithOneNote())
        }
        #expect(try Data(contentsOf: main) == v2)
        #expect(FileManager.default.fileExists(atPath: manifest.path) == false)
    }

    @Test func manifestSnapshotPathEscapeFailsClosedWithoutReplacingV2Main() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let manifest = directory.file("manifest.json")
        let v2 = try WorkspacePersistenceFixtures.v2CalendarDocument()
        try v2.write(to: main)
        let escaped = RecoveryManifest(entries: [.init(
            sourceSchema: 2,
            sourceSHA256: WorkspacePersistenceFixtures.sha256(v2),
            sourceByteCount: v2.count,
            snapshotFileName: "../outside.json",
            registeredAt: Date(timeIntervalSince1970: 0)
        )])
        try JSONEncoder.workspaceDeterministic.encode(escaped).write(to: manifest)
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { .empty(calendar: WorkspacePersistenceFixtures.calendarState) },
            snapshotDirectoryURL: directory.file("snapshots"),
            recoveryManifestURL: manifest
        )
        _ = try await repository.load()

        await #expect(throws: WorkspacePersistenceError.invalidManifest) {
            _ = try await repository.save(try WorkspacePersistenceFixtures.workspaceWithOneNote())
        }
        #expect(try Data(contentsOf: main) == v2)
    }

    @Test func manifestWriteThatCannotReopenFailsBeforeV2Replacement() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let manifest = directory.file("manifest.json")
        let v2 = try WorkspacePersistenceFixtures.v2CalendarDocument()
        try v2.write(to: main)
        let writer = WorkspacePersistenceCorruptingWriter { $0 == manifest }
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { .empty(calendar: WorkspacePersistenceFixtures.calendarState) },
            snapshotDirectoryURL: directory.file("snapshots"),
            recoveryManifestURL: manifest,
            atomicWriter: writer
        )
        _ = try await repository.load()

        await #expect(throws: WorkspacePersistenceError.invalidManifest) {
            _ = try await repository.save(try WorkspacePersistenceFixtures.workspaceWithOneNote())
        }
        #expect(try Data(contentsOf: main) == v2)
    }

    @Test func manifestReuseAndDifferentSourceRegistrationRetainEveryVerifiedRecord() throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let snapshots = directory.file("snapshots")
        let store = RecoveryManifestStore(
            manifestURL: directory.file("manifest.json"),
            snapshotDirectoryURL: snapshots
        )
        let first = Data("first source".utf8)
        let second = Data("second source".utf8)
        let firstProvenance = WorkspaceLoadProvenance(
            sourceSchema: 2,
            sourceBytesSHA256: WorkspacePersistenceFixtures.sha256(first),
            sourceByteCount: first.count
        )
        let secondProvenance = WorkspaceLoadProvenance(
            sourceSchema: 2,
            sourceBytesSHA256: WorkspacePersistenceFixtures.sha256(second),
            sourceByteCount: second.count
        )

        let original = try store.registerVerifiedSnapshot(rawData: first, provenance: firstProvenance)
        let reused = try store.registerVerifiedSnapshot(rawData: first, provenance: firstProvenance)
        _ = try store.registerVerifiedSnapshot(rawData: second, provenance: secondProvenance)
        let manifest = try store.load()

        #expect(reused.sourceSchema == original.sourceSchema)
        #expect(reused.sourceSHA256 == original.sourceSHA256)
        #expect(reused.sourceByteCount == original.sourceByteCount)
        #expect(reused.snapshotFileName == original.snapshotFileName)
        #expect(manifest.entries.count == 2)
        #expect(manifest.entries.contains(where: {
            $0.sourceSchema == original.sourceSchema
                && $0.sourceSHA256 == original.sourceSHA256
                && $0.sourceByteCount == original.sourceByteCount
                && $0.snapshotFileName == original.snapshotFileName
        }))
    }

    @Test func concurrentManifestRegistrationsForDifferentHashesDoNotLoseEitherRecord() throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let manifest = directory.file("manifest.json")
        let writer = WorkspacePersistenceManifestBarrierWriter(manifestURL: manifest)
        let first = Data("concurrent first".utf8)
        let second = Data("concurrent second".utf8)
        let firstStore = RecoveryManifestStore(
            manifestURL: manifest,
            snapshotDirectoryURL: directory.file("snapshots"),
            writer: writer
        )
        let secondStore = RecoveryManifestStore(
            manifestURL: manifest,
            snapshotDirectoryURL: directory.file("snapshots"),
            writer: writer
        )
        let group = DispatchGroup()
        let errors = WorkspacePersistenceErrorBox()
        for (store, raw) in [(firstStore, first), (secondStore, second)] {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    _ = try store.registerVerifiedSnapshot(
                        rawData: raw,
                        provenance: .init(
                            sourceSchema: 2,
                            sourceBytesSHA256: WorkspacePersistenceFixtures.sha256(raw),
                            sourceByteCount: raw.count
                        )
                    )
                } catch {
                    errors.append(error)
                }
            }
        }
        group.wait()

        #expect(errors.values.isEmpty)
        #expect(try RecoveryManifestStore(
            manifestURL: manifest,
            snapshotDirectoryURL: directory.file("snapshots")
        ).load().entries.count == 2)
    }

    @Test func nestedMissingManifestParentIsCreatedBeforeThePathBoundLock() throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let manifest = directory.url
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("manifest", isDirectory: true)
            .appendingPathComponent("recovery.json")
        let snapshots = directory.url
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
        let raw = Data("nested manifest source".utf8)
        let provenance = WorkspaceLoadProvenance(
            sourceSchema: 2,
            sourceBytesSHA256: WorkspacePersistenceFixtures.sha256(raw),
            sourceByteCount: raw.count
        )
        let store = RecoveryManifestStore(manifestURL: manifest, snapshotDirectoryURL: snapshots)

        let record = try store.registerVerifiedSnapshot(rawData: raw, provenance: provenance)

        #expect(FileManager.default.fileExists(atPath: manifest.path))
        #expect(try store.load().entries.map(\.snapshotFileName) == [record.snapshotFileName])
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

final class WorkspacePersistenceCorruptingWriter: AtomicFileWriting, @unchecked Sendable {
    private let predicate: @Sendable (URL) -> Bool

    init(predicate: @escaping @Sendable (URL) -> Bool) { self.predicate = predicate }

    func replaceAtomically(data: Data, at destination: URL) throws {
        try FoundationAtomicFileWriter().replaceAtomically(data: data, at: destination)
        if predicate(destination) { try Data("corrupted".utf8).write(to: destination) }
    }
}

final class WorkspacePersistenceManifestBarrierWriter: AtomicFileWriting, @unchecked Sendable {
    private let manifestURL: URL
    private let condition = NSCondition()
    private var waiting = 0

    init(manifestURL: URL) { self.manifestURL = manifestURL }

    func replaceAtomically(data: Data, at destination: URL) throws {
        if destination == manifestURL {
            condition.lock()
            waiting += 1
            if waiting < 2 {
                _ = condition.wait(until: Date().addingTimeInterval(0.2))
            } else {
                condition.broadcast()
            }
            condition.unlock()
        }
        try FoundationAtomicFileWriter().replaceAtomically(data: data, at: destination)
    }
}

final class WorkspacePersistenceErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Error] = []
    var values: [Error] { lock.withLock { storage } }
    func append(_ error: Error) { lock.withLock { storage.append(error) } }
}
