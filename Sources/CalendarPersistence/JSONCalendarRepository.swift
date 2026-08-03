import CalendarDomain
import Foundation

public actor JSONCalendarRepository: CalendarRepository {
    private let documentURL: URL
    private let seed: @Sendable () -> CalendarState
    private let writer: any AtomicFileWriting

    public init(
        documentURL: URL,
        seed: @escaping @Sendable () -> CalendarState,
        writer: any AtomicFileWriting = FoundationAtomicFileWriter()
    ) {
        self.documentURL = documentURL
        self.seed = seed
        self.writer = writer
    }

    public func load() async throws -> CalendarState {
        guard FileManager.default.fileExists(atPath: documentURL.path) else {
            let state = seed()
            try await save(state)
            return state
        }

        let data: Data
        do {
            data = try Data(contentsOf: documentURL)
        } catch {
            throw BackupError.invalidDocument
        }
        return try CalendarDocumentCodec.decode(data)
    }

    public func save(_ state: CalendarState) async throws {
        let data = try CalendarDocumentCodec.encode(state)
        do {
            try writer.replaceAtomically(data: data, at: documentURL)
        } catch {
            throw BackupError.atomicWriteFailed
        }
    }

    public func currentDocumentData() async throws -> Data {
        do {
            return try Data(contentsOf: documentURL)
        } catch {
            throw BackupError.atomicWriteFailed
        }
    }

    public func snapshotCurrentDocument(to destination: URL) async throws {
        let data = try await currentDocumentData()
        do {
            try writer.replaceAtomically(data: data, at: destination)
        } catch {
            throw BackupError.atomicWriteFailed
        }
    }
}
