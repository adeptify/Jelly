import CalendarDomain
import Foundation

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
        let rollbackParent = rollbackURL.deletingLastPathComponent()

        do {
            if !FileManager.default.fileExists(atPath: rollbackParent.path) {
                try FileManager.default.createDirectory(
                    at: rollbackParent,
                    withIntermediateDirectories: true
                )
            }
            try await repository.snapshotCurrentDocument(to: rollbackURL)
        } catch {
            throw BackupError.rollbackWriteFailed
        }

        try await repository.save(restored)
        return restored
    }
}
