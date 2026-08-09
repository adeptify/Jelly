import Foundation

public struct RecoveryManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var entries: [RecoverySnapshotRecord]

    public init(schemaVersion: Int = 1, entries: [RecoverySnapshotRecord] = []) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }
}

public struct RecoverySnapshotRecord: Codable, Equatable, Sendable {
    public let sourceSchema: Int
    public let sourceSHA256: String
    public let sourceByteCount: Int
    public let snapshotFileName: String
    public let registeredAt: Date

    public init(
        sourceSchema: Int,
        sourceSHA256: String,
        sourceByteCount: Int,
        snapshotFileName: String,
        registeredAt: Date
    ) {
        self.sourceSchema = sourceSchema
        self.sourceSHA256 = sourceSHA256
        self.sourceByteCount = sourceByteCount
        self.snapshotFileName = snapshotFileName
        self.registeredAt = registeredAt
    }
}

public final class RecoveryManifestStore: @unchecked Sendable {
    private let manifestURL: URL
    private let snapshots: MigrationSnapshotStore
    private let writer: any AtomicFileWriting

    public init(
        manifestURL: URL,
        snapshotDirectoryURL: URL,
        writer: any AtomicFileWriting = FoundationAtomicFileWriter()
    ) {
        self.manifestURL = manifestURL
        snapshots = MigrationSnapshotStore(directoryURL: snapshotDirectoryURL, writer: writer)
        self.writer = writer
    }

    public func load() throws -> RecoveryManifest {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return RecoveryManifest()
        }
        let manifest: RecoveryManifest
        do {
            manifest = try JSONDecoder.workspaceDeterministic.decode(
                RecoveryManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw WorkspacePersistenceError.invalidManifest
        }
        guard manifest.schemaVersion == 1,
              manifest.entries.allSatisfy(isStructurallySafe)
        else { throw WorkspacePersistenceError.invalidManifest }
        for record in manifest.entries {
            guard let url = snapshots.safeURL(for: record.snapshotFileName),
                  let data = try? Data(contentsOf: url),
                  data.count == record.sourceByteCount,
                  persistenceSHA256(data) == record.sourceSHA256
            else { throw WorkspacePersistenceError.invalidManifest }
        }
        return manifest
    }

    public func registerVerifiedSnapshot(
        rawData: Data,
        provenance: WorkspaceLoadProvenance,
        registeredAt: Date = Date()
    ) throws -> RecoverySnapshotRecord {
        var manifest = try load()
        if let existing = manifest.entries.first(where: {
            $0.sourceSchema == provenance.sourceSchema
                && $0.sourceSHA256 == provenance.sourceBytesSHA256
                && $0.sourceByteCount == provenance.sourceByteCount
        }) {
            guard try snapshots.verified(rawData: rawData, named: existing.snapshotFileName) else {
                throw WorkspacePersistenceError.invalidSnapshot
            }
            return existing
        }
        let name = try snapshots.writeAndVerify(rawData: rawData, provenance: provenance)
        let record = RecoverySnapshotRecord(
            sourceSchema: provenance.sourceSchema,
            sourceSHA256: provenance.sourceBytesSHA256,
            sourceByteCount: provenance.sourceByteCount,
            snapshotFileName: name,
            registeredAt: registeredAt
        )
        manifest.entries.append(record)
        let data: Data
        do {
            data = try JSONEncoder.workspaceDeterministic.encode(manifest)
            try FileManager.default.createDirectory(
                at: manifestURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try writer.replaceAtomically(data: data, at: manifestURL)
        } catch {
            throw WorkspacePersistenceError.atomicWriteFailed
        }
        return record
    }

    private func isStructurallySafe(_ record: RecoverySnapshotRecord) -> Bool {
        guard record.sourceSchema == 1 || record.sourceSchema == 2,
              record.sourceByteCount >= 0,
              record.sourceSHA256.count == 64,
              record.sourceSHA256.allSatisfy({ $0.isHexDigit }),
              snapshots.safeURL(for: record.snapshotFileName) != nil
        else { return false }
        return true
    }
}
