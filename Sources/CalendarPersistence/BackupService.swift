import Foundation
import WorkspaceDomain

public actor BackupService {
    private let writer: any AtomicFileWriting

    public init(writer: any AtomicFileWriting = FoundationAtomicFileWriter()) {
        self.writer = writer
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

    public func inspectRestoreSource(_ sourceURL: URL) async throws -> WorkspaceRestorePreview {
        let rawSourceData: Data
        do {
            rawSourceData = try dataReadingNoFollow(at: sourceURL)
        } catch {
            throw WorkspacePersistenceError.invalidDocument
        }
        let loadResult = try WorkspaceDocumentCodec.decode(rawSourceData)
        let sourceNoteRevisions = loadResult.state.notes.mapValues(\.revision)
        guard Set(sourceNoteRevisions.keys) == Set(loadResult.state.notes.keys) else {
            throw WorkspacePersistenceError.restoreBindingMismatch
        }
        return WorkspaceRestorePreview(
            sourceURL: sourceURL,
            rawSourceData: rawSourceData,
            sourceIdentity: .init(
                sha256: persistenceSHA256(rawSourceData),
                byteCount: rawSourceData.count
            ),
            loadResult: loadResult,
            sourceNoteRevisions: sourceNoteRevisions
        )
    }

}
