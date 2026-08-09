import CalendarDomain
import Foundation
import WorkspaceDomain

public actor BackupService {
    private let writer: any AtomicFileWriting

    public init(writer: any AtomicFileWriting = FoundationAtomicFileWriter()) {
        self.writer = writer
    }

    public func export(state: CalendarState, to destination: URL) async throws {
        let data = try CalendarDocumentCodec.encode(state)
        do {
            try writer.replaceAtomically(data: data, at: destination)
        } catch {
            throw BackupError.atomicWriteFailed
        }
    }

    public func exportCurrent(
        from repository: any WorkspaceRepository,
        to destination: URL
    ) async throws {
        let rawData = try await repository.currentDocumentData()
        _ = try WorkspaceDocumentCodec.decode(rawData)
        do {
            try writer.replaceAtomically(data: rawData, at: destination)
            let readback = try Data(contentsOf: destination)
            guard readback.count == rawData.count,
                  persistenceSHA256(readback) == persistenceSHA256(rawData)
            else { throw WorkspacePersistenceError.atomicWriteFailed }
        } catch let error as WorkspacePersistenceError {
            throw error
        } catch {
            throw WorkspacePersistenceError.atomicWriteFailed
        }
    }

    public func validatedState(from source: URL) async throws -> CalendarState {
        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            throw BackupError.invalidDocument
        }
        return try CalendarDocumentCodec.decode(data)
    }

    public func restore(
        from source: URL,
        repository: any CalendarRepository,
        rollbackURL: URL
    ) async throws -> CalendarState {
        let restored = try await validatedState(from: source)
        let primaryBytes: Data
        do {
            primaryBytes = try await repository.currentDocumentData()
        } catch {
            throw BackupError.rollbackWriteFailed
        }
        let rollbackParent = rollbackURL.deletingLastPathComponent()

        do {
            if !FileManager.default.fileExists(atPath: rollbackParent.path) {
                try FileManager.default.createDirectory(
                    at: rollbackParent,
                    withIntermediateDirectories: true
                )
            }
            try writer.replaceAtomically(data: primaryBytes, at: rollbackURL)
        } catch {
            throw BackupError.rollbackWriteFailed
        }

        try await repository.save(restored)
        return restored
    }
}
