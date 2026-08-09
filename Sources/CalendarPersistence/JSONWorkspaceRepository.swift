import Foundation
import WorkspaceDomain

public actor JSONWorkspaceRepository: WorkspaceRepository {
    private enum LoadedSource: Sendable {
        case absent
        case bytes(rawData: Data, provenance: WorkspaceLoadProvenance)
    }

    private let documentURL: URL
    private let seed: @Sendable () -> WorkspaceState
    private let manifestStore: RecoveryManifestStore
    private let atomicWriter: any AtomicFileWriting
    private let mainFileWriter: any MainFileCompareAndReplaceWriting
    private var loadedSource: LoadedSource = .absent

    public init(
        documentURL: URL,
        seed: @escaping @Sendable () -> WorkspaceState,
        snapshotDirectoryURL: URL? = nil,
        recoveryManifestURL: URL? = nil,
        atomicWriter: any AtomicFileWriting = FoundationAtomicFileWriter(),
        mainFileWriter: any MainFileCompareAndReplaceWriting = FoundationMainFileCompareAndReplaceWriter()
    ) {
        self.documentURL = documentURL
        self.seed = seed
        self.atomicWriter = atomicWriter
        self.mainFileWriter = mainFileWriter
        let parent = documentURL.deletingLastPathComponent()
        manifestStore = RecoveryManifestStore(
            manifestURL: recoveryManifestURL ?? parent.appendingPathComponent("calendar-v1.recovery-manifest.json"),
            snapshotDirectoryURL: snapshotDirectoryURL ?? parent.appendingPathComponent("calendar-v1.recovery-snapshots", isDirectory: true),
            writer: atomicWriter
        )
    }

    public func load() throws -> WorkspaceLoadResult {
        switch loadedSource {
        case let .bytes(rawData, _):
            return try WorkspaceDocumentCodec.decode(rawData)
        case .absent:
            guard FileManager.default.fileExists(atPath: documentURL.path) else {
                let state = seed()
                do {
                    try WorkspaceValidator.validate(state)
                } catch {
                    throw WorkspacePersistenceError.invalidWorkspace
                }
                return WorkspaceLoadResult(
                    state: state,
                    provenance: .init(sourceSchema: 0, sourceBytesSHA256: "", sourceByteCount: 0),
                    consistencyIssues: []
                )
            }
            let rawData: Data
            do {
                rawData = try Data(contentsOf: documentURL)
            } catch {
                throw WorkspacePersistenceError.invalidDocument
            }
            let result = try WorkspaceDocumentCodec.decode(rawData)
            loadedSource = .bytes(rawData: rawData, provenance: result.provenance)
            return result
        }
    }

    public func save(
        _ state: WorkspaceState,
        draft: PersistableDraftContext? = nil
    ) throws -> WorkspaceSaveReceipt {
        do {
            try WorkspaceValidator.validate(state)
        } catch {
            throw WorkspacePersistenceError.invalidWorkspace
        }
        let receipt = try receipt(for: draft, in: state)
        let candidate = try WorkspaceDocumentCodec.encode(state)
        try persist(candidate: candidate, state: state)
        return WorkspaceSaveReceipt(workspaceRevision: state.revision, persistedDraft: receipt)
    }

    public func currentDocumentData() throws -> Data {
        guard case let .bytes(rawData, _) = loadedSource else {
            throw WorkspacePersistenceError.missingDocument
        }
        let current: Data
        do {
            current = try Data(contentsOf: documentURL)
        } catch {
            throw WorkspacePersistenceError.missingDocument
        }
        guard current == rawData else { throw WorkspacePersistenceError.sourceChanged }
        _ = try WorkspaceDocumentCodec.decode(current)
        return current
    }

    public func prepareRestore(_ request: WorkspaceRestoreRequest) throws -> PreparedWorkspaceRestore {
        let rawData: Data
        do {
            rawData = try Data(contentsOf: request.sourceURL)
        } catch {
            throw WorkspacePersistenceError.invalidDocument
        }
        let decoded = try WorkspaceDocumentCodec.decode(rawData)
        guard decoded.consistencyIssues.isEmpty else { throw WorkspacePersistenceError.invalidWorkspace }
        do {
            try WorkspaceValidator.validate(decoded.state)
        } catch {
            throw WorkspacePersistenceError.invalidWorkspace
        }
        let content = WorkspaceContentSnapshot(state: decoded.state)
        let revisions = decoded.state.notes.mapValues(\.revision)
        guard Set(revisions.keys) == Set(content.notes.keys) else {
            throw WorkspacePersistenceError.restoreBindingMismatch
        }
        return PreparedWorkspaceRestore(
            rawSourceData: rawData,
            provenance: decoded.provenance,
            content: content,
            sourceRevisionHighWatermark: decoded.state.revision,
            sourceNoteRevisions: revisions,
            rollbackURL: request.rollbackDirectoryURL.appendingPathComponent(
                "workspace-rollback-\(UUID().uuidString).json"
            )
        )
    }

    public func commitRestore(
        _ prepared: PreparedWorkspaceRestore,
        state: WorkspaceState
    ) throws -> WorkspaceSaveReceipt {
        guard prepared.provenance.sourceBytesSHA256 == persistenceSHA256(prepared.rawSourceData),
              prepared.provenance.sourceByteCount == prepared.rawSourceData.count,
              Set(prepared.sourceNoteRevisions.keys) == Set(prepared.content.notes.keys),
              WorkspaceContentSnapshot(state: state) == prepared.content
        else { throw WorkspacePersistenceError.restoreBindingMismatch }
        let verifiedPrepared = try WorkspaceDocumentCodec.decode(prepared.rawSourceData)
        guard verifiedPrepared.provenance == prepared.provenance,
              WorkspaceContentSnapshot(state: verifiedPrepared.state) == prepared.content,
              verifiedPrepared.state.revision == prepared.sourceRevisionHighWatermark,
              verifiedPrepared.state.notes.mapValues(\.revision) == prepared.sourceNoteRevisions
        else { throw WorkspacePersistenceError.restoreBindingMismatch }
        do {
            try WorkspaceValidator.validate(state)
        } catch {
            throw WorkspacePersistenceError.invalidWorkspace
        }
        let candidate = try WorkspaceDocumentCodec.encode(state)
        guard case let .bytes(rawData, provenance) = loadedSource else {
            throw WorkspacePersistenceError.missingDocument
        }
        guard let current = try? Data(contentsOf: documentURL), current == rawData else {
            throw WorkspacePersistenceError.sourceChanged
        }
        try writeVerifiedRollback(rawData, to: prepared.rollbackURL)
        if provenance.sourceSchema < WorkspaceDocument.currentSchemaVersion {
            try registerMigrationSnapshot(rawData: rawData, provenance: provenance)
        }
        switch try replaceIfSHA256Matches(
            expectedSHA256: provenance.sourceBytesSHA256,
            candidate: candidate
        ) {
        case .sourceChanged:
            throw WorkspacePersistenceError.sourceChanged
        case .replaced:
            try replaceLoadedSourceWithReadback(candidate)
        }
        return WorkspaceSaveReceipt(workspaceRevision: state.revision, persistedDraft: nil)
    }

    private func persist(candidate: Data, state: WorkspaceState) throws {
        switch loadedSource {
        case .absent:
            switch try createIfAbsent(candidate: candidate) {
            case .sourceChanged:
                throw WorkspacePersistenceError.sourceChanged
            case .replaced:
                try replaceLoadedSourceWithReadback(candidate)
            }
        case let .bytes(rawData, provenance):
            if provenance.sourceSchema < WorkspaceDocument.currentSchemaVersion {
                guard let current = try? Data(contentsOf: documentURL), current == rawData else {
                    throw WorkspacePersistenceError.sourceChanged
                }
                try registerMigrationSnapshot(rawData: rawData, provenance: provenance)
            }
            switch try replaceIfSHA256Matches(
                expectedSHA256: provenance.sourceBytesSHA256,
                candidate: candidate
            ) {
            case .sourceChanged:
                throw WorkspacePersistenceError.sourceChanged
            case .replaced:
                try replaceLoadedSourceWithReadback(candidate)
            }
        }
    }

    private func registerMigrationSnapshot(
        rawData: Data,
        provenance: WorkspaceLoadProvenance
    ) throws {
        guard provenance.sourceSchema == 1 || provenance.sourceSchema == 2 else {
            throw WorkspacePersistenceError.invalidDocument
        }
        _ = try manifestStore.registerVerifiedSnapshot(rawData: rawData, provenance: provenance)
    }

    private func replaceLoadedSourceWithReadback(_ candidate: Data) throws {
        let readback: Data
        do {
            readback = try Data(contentsOf: documentURL)
        } catch {
            throw WorkspacePersistenceError.atomicWriteFailed
        }
        guard readback == candidate else { throw WorkspacePersistenceError.atomicWriteFailed }
        let decoded = try WorkspaceDocumentCodec.decode(readback)
        guard decoded.provenance.sourceSchema == WorkspaceDocument.currentSchemaVersion else {
            throw WorkspacePersistenceError.atomicWriteFailed
        }
        loadedSource = .bytes(rawData: readback, provenance: decoded.provenance)
    }

    private func createIfAbsent(candidate: Data) throws -> MainFileCompareAndReplaceResult {
        do {
            return try mainFileWriter.createIfAbsent(candidate: candidate, at: documentURL)
        } catch {
            throw WorkspacePersistenceError.atomicWriteFailed
        }
    }

    private func replaceIfSHA256Matches(
        expectedSHA256: String,
        candidate: Data
    ) throws -> MainFileCompareAndReplaceResult {
        do {
            return try mainFileWriter.replaceIfSHA256Matches(
                expectedSHA256: expectedSHA256,
                candidate: candidate,
                at: documentURL
            )
        } catch {
            throw WorkspacePersistenceError.atomicWriteFailed
        }
    }

    private func writeVerifiedRollback(_ data: Data, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try atomicWriter.replaceAtomically(data: data, at: url)
            let readback = try Data(contentsOf: url)
            guard readback.count == data.count, persistenceSHA256(readback) == persistenceSHA256(data) else {
                throw WorkspacePersistenceError.rollbackWriteFailed
            }
        } catch let error as WorkspacePersistenceError {
            throw error
        } catch {
            throw WorkspacePersistenceError.rollbackWriteFailed
        }
    }

    private func receipt(
        for draft: PersistableDraftContext?,
        in state: WorkspaceState
    ) throws -> PersistedDraftReceipt? {
        guard let draft else { return nil }
        guard let note = state.notes[draft.noteID],
              (try? WorkspaceChecksum.noteSnapshotChecksum(note)) == draft.noteSnapshotChecksum
        else { throw WorkspacePersistenceError.invalidDraftContext }
        return PersistedDraftReceipt(
            noteID: draft.noteID,
            draftGeneration: draft.draftGeneration,
            noteSnapshotChecksum: draft.noteSnapshotChecksum,
            persistedNoteRevision: note.revision
        )
    }
}
