import Foundation

public struct MigrationSnapshotStore: Sendable {
    public let directoryURL: URL
    private let writer: any AtomicFileWriting

    public init(
        directoryURL: URL,
        writer: any AtomicFileWriting = FoundationAtomicFileWriter()
    ) {
        self.directoryURL = directoryURL
        self.writer = writer
    }

    public func writeAndVerify(rawData: Data, provenance: WorkspaceLoadProvenance) throws -> String {
        guard provenance.sourceByteCount == rawData.count,
              provenance.sourceBytesSHA256 == persistenceSHA256(rawData)
        else { throw WorkspacePersistenceError.invalidSnapshot }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            throw WorkspacePersistenceError.atomicWriteFailed
        }
        let name = "calendar-v\(provenance.sourceSchema)-\(provenance.sourceBytesSHA256).json"
        let destination = directoryURL.appendingPathComponent(name)
        if fileManager.fileExists(atPath: destination.path) {
            guard try verified(rawData: rawData, at: destination) else {
                throw WorkspacePersistenceError.invalidSnapshot
            }
            return name
        }
        do {
            try writer.replaceAtomically(data: rawData, at: destination)
        } catch {
            throw WorkspacePersistenceError.atomicWriteFailed
        }
        guard try verified(rawData: rawData, at: destination) else {
            throw WorkspacePersistenceError.invalidSnapshot
        }
        return name
    }

    public func verified(rawData: Data, named fileName: String) throws -> Bool {
        guard let source = safeURL(for: fileName) else { return false }
        return try verified(rawData: rawData, at: source)
    }

    private func verified(rawData: Data, at url: URL) throws -> Bool {
        let readback: Data
        do {
            readback = try Data(contentsOf: url)
        } catch {
            throw WorkspacePersistenceError.invalidSnapshot
        }
        return readback.count == rawData.count && persistenceSHA256(readback) == persistenceSHA256(rawData)
    }

    func safeURL(for fileName: String) -> URL? {
        guard !fileName.isEmpty,
              !fileName.contains("/"),
              !fileName.contains("\\"),
              fileName != ".", fileName != "..",
              !fileName.contains("..")
        else { return nil }
        let directory = directoryURL.standardizedFileURL
        let candidate = directory.appendingPathComponent(fileName).standardizedFileURL
        guard candidate.deletingLastPathComponent() == directory,
              candidate.path.hasPrefix(directory.path + "/"),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path)) == nil
        else { return nil }
        return candidate
    }
}
