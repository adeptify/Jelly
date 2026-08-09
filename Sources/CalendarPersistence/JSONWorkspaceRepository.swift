import Foundation
import WorkspaceDomain

public actor JSONWorkspaceRepository: WorkspaceRepository {
    private enum LoadedSource: Sendable {
        case absent
        case bytes(rawData: Data, provenance: WorkspaceLoadProvenance)
    }

    private struct PendingWorkspaceCommit: Sendable {
        let previousSource: LoadedSource
        let candidateRawData: Data
        let candidateState: WorkspaceState
        let receipt: WorkspaceSaveReceipt
        let restoreCapabilityID: UUID?
    }

    private let documentURL: URL
    private let seed: @Sendable () -> WorkspaceState
    private let manifestStore: RecoveryManifestStore
    private let atomicWriter: any AtomicFileWriting
    private let rollbackWriter: any ExclusiveFileWriting
    private let mainFileWriter: any MainFileCompareAndReplaceWriting
    private var loadedSource: LoadedSource = .absent
    private var pendingRestores: [UUID: PreparedWorkspaceRestore] = [:]
    private var pendingCommit: PendingWorkspaceCommit?

    public init(
        documentURL: URL,
        seed: @escaping @Sendable () -> WorkspaceState,
        snapshotDirectoryURL: URL? = nil,
        recoveryManifestURL: URL? = nil,
        atomicWriter: any AtomicFileWriting = FoundationAtomicFileWriter(),
        mainFileWriter: any MainFileCompareAndReplaceWriting = FoundationMainFileCompareAndReplaceWriter(),
        rollbackWriter: any ExclusiveFileWriting = FoundationExclusiveFileWriter()
    ) {
        self.documentURL = documentURL
        self.seed = seed
        self.atomicWriter = atomicWriter
        self.mainFileWriter = mainFileWriter
        self.rollbackWriter = rollbackWriter
        let parent = documentURL.deletingLastPathComponent()
        manifestStore = RecoveryManifestStore(
            manifestURL: recoveryManifestURL ?? parent.appendingPathComponent("calendar-v1.recovery-manifest.json"),
            snapshotDirectoryURL: snapshotDirectoryURL ?? parent.appendingPathComponent("calendar-v1.recovery-snapshots", isDirectory: true),
            writer: atomicWriter
        )
    }

    public func load() throws -> WorkspaceLoadResult {
        try rejectIfCommitUncertain()
        switch loadedSource {
        case let .bytes(rawData, _):
            return try WorkspaceDocumentCodec.decode(rawData)
        case .absent:
            let rawData: Data
            switch noFollowFileProbe(at: documentURL) {
            case .confirmedAbsent:
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
            case let .bytes(data):
                rawData = data
            case .unreadableUnknown:
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
        try rejectIfCommitUncertain()
        do {
            try WorkspaceValidator.validate(state)
        } catch {
            throw WorkspacePersistenceError.invalidWorkspace
        }
        let persistedDraft = try receipt(for: draft, in: state)
        let receipt = WorkspaceSaveReceipt(workspaceRevision: state.revision, persistedDraft: persistedDraft)
        let candidate = try WorkspaceDocumentCodec.encode(state)
        try persist(candidate: candidate, state: state, receipt: receipt)
        return receipt
    }

    public func currentDocumentData() throws -> Data {
        try rejectIfCommitUncertain()
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
        try rejectIfCommitUncertain()
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
        let capabilityID = UUID()
        let prepared = PreparedWorkspaceRestore(
            rawSourceData: rawData,
            provenance: decoded.provenance,
            content: content,
            sourceRevisionHighWatermark: decoded.state.revision,
            sourceNoteRevisions: revisions,
            rollbackURL: request.rollbackDirectoryURL.appendingPathComponent(
                "workspace-rollback-\(UUID().uuidString).json"
            ),
            capabilityID: capabilityID
        )
        pendingRestores[capabilityID] = prepared
        return prepared
    }

    public func commitRestore(
        _ prepared: PreparedWorkspaceRestore,
        state: WorkspaceState
    ) throws -> WorkspaceSaveReceipt {
        try rejectIfCommitUncertain()
        guard let issued = pendingRestores[prepared.capabilityID], issued == prepared else {
            throw WorkspacePersistenceError.invalidRestoreCapability
        }
        guard issued.provenance.sourceBytesSHA256 == persistenceSHA256(issued.rawSourceData),
              issued.provenance.sourceByteCount == issued.rawSourceData.count,
              Set(issued.sourceNoteRevisions.keys) == Set(issued.content.notes.keys),
              WorkspaceContentSnapshot(state: state) == issued.content
        else { throw WorkspacePersistenceError.restoreBindingMismatch }
        let verifiedPrepared = try WorkspaceDocumentCodec.decode(issued.rawSourceData)
        guard verifiedPrepared.provenance == issued.provenance,
              WorkspaceContentSnapshot(state: verifiedPrepared.state) == issued.content,
              verifiedPrepared.state.revision == issued.sourceRevisionHighWatermark,
              verifiedPrepared.state.notes.mapValues(\.revision) == issued.sourceNoteRevisions
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
        pendingRestores[prepared.capabilityID] = nil
        try writeVerifiedRollback(rawData, to: issued.rollbackURL)
        if provenance.sourceSchema < WorkspaceDocument.currentSchemaVersion {
            try registerMigrationSnapshot(rawData: rawData, provenance: provenance)
        }
        let receipt = WorkspaceSaveReceipt(workspaceRevision: state.revision, persistedDraft: nil)
        beginPendingCommit(
            previousSource: .bytes(rawData: rawData, provenance: provenance),
            candidate: candidate,
            state: state,
            receipt: receipt,
            restoreCapabilityID: prepared.capabilityID
        )
        let result: MainFileCompareAndReplaceResult
        do {
            result = try replaceIfSHA256Matches(
                expectedSHA256: provenance.sourceBytesSHA256,
                candidate: candidate
            )
        } catch {
            pendingCommit = nil
            pendingRestores[prepared.capabilityID] = nil
            throw error
        }
        do {
            try finishMainReplacement(result, candidate: candidate)
        } catch {
            if (error as? WorkspacePersistenceError) != .commitUncertain {
                pendingRestores[prepared.capabilityID] = nil
            }
            throw error
        }
        return receipt
    }

    private func persist(
        candidate: Data,
        state: WorkspaceState,
        receipt: WorkspaceSaveReceipt
    ) throws {
        switch loadedSource {
        case .absent:
            beginPendingCommit(
                previousSource: .absent,
                candidate: candidate,
                state: state,
                receipt: receipt,
                restoreCapabilityID: nil
            )
            let result: MainFileCompareAndReplaceResult
            do {
                result = try createIfAbsent(candidate: candidate)
            } catch {
                pendingCommit = nil
                throw error
            }
            try finishMainReplacement(result, candidate: candidate)
        case let .bytes(rawData, provenance):
            if provenance.sourceSchema < WorkspaceDocument.currentSchemaVersion {
                guard let current = try? Data(contentsOf: documentURL), current == rawData else {
                    throw WorkspacePersistenceError.sourceChanged
                }
                try registerMigrationSnapshot(rawData: rawData, provenance: provenance)
            }
            beginPendingCommit(
                previousSource: .bytes(rawData: rawData, provenance: provenance),
                candidate: candidate,
                state: state,
                receipt: receipt,
                restoreCapabilityID: nil
            )
            let result: MainFileCompareAndReplaceResult
            do {
                result = try replaceIfSHA256Matches(
                    expectedSHA256: provenance.sourceBytesSHA256,
                    candidate: candidate
                )
            } catch {
                pendingCommit = nil
                throw error
            }
            try finishMainReplacement(result, candidate: candidate)
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

    public func reconcilePendingCommit() throws -> WorkspaceCommitReconciliation {
        guard let pending = pendingCommit else { return .notCommitted }
        do {
            return try withJellyAdvisoryLock(for: documentURL) {
                let current: Data?
                switch noFollowFileProbe(at: documentURL) {
                case let .bytes(data):
                    current = data
                case .confirmedAbsent:
                    current = nil
                case .unreadableUnknown:
                    throw WorkspacePersistenceError.commitUncertain
                }
                if current == pending.candidateRawData {
                    do {
                        try replaceLoadedSourceWithVerifiedRawData(
                            pending.candidateRawData,
                            expectedCandidate: pending.candidateRawData
                        )
                    } catch {
                        throw WorkspacePersistenceError.commitUncertain
                    }
                    completePendingRestoreCapability(pending.restoreCapabilityID)
                    pendingCommit = nil
                    return .committed(pending.receipt)
                }
                if matchesPreviousSource(current, pending.previousSource) {
                    loadedSource = pending.previousSource
                    completePendingRestoreCapability(pending.restoreCapabilityID)
                    pendingCommit = nil
                    return .notCommitted
                }
                completePendingRestoreCapability(pending.restoreCapabilityID)
                pendingCommit = nil
                return .sourceChanged
            }
        } catch let error as WorkspacePersistenceError where error == .commitUncertain {
            throw error
        } catch {
            throw WorkspacePersistenceError.commitUncertain
        }
    }

    private func beginPendingCommit(
        previousSource: LoadedSource,
        candidate: Data,
        state: WorkspaceState,
        receipt: WorkspaceSaveReceipt,
        restoreCapabilityID: UUID?
    ) {
        pendingCommit = .init(
            previousSource: previousSource,
            candidateRawData: candidate,
            candidateState: state,
            receipt: receipt,
            restoreCapabilityID: restoreCapabilityID
        )
    }

    private func finishMainReplacement(
        _ result: MainFileCompareAndReplaceResult,
        candidate: Data
    ) throws {
        switch result {
        case .sourceChanged:
            pendingCommit = nil
            throw WorkspacePersistenceError.sourceChanged
        case .commitUncertain:
            throw WorkspacePersistenceError.commitUncertain
        case let .replaced(verifiedRawData):
            do {
                try replaceLoadedSourceWithVerifiedRawData(verifiedRawData, expectedCandidate: candidate)
            } catch {
                throw WorkspacePersistenceError.commitUncertain
            }
            guard let pending = pendingCommit else {
                throw WorkspacePersistenceError.commitUncertain
            }
            completePendingRestoreCapability(pending.restoreCapabilityID)
            pendingCommit = nil
        }
    }

    private func replaceLoadedSourceWithVerifiedRawData(
        _ verifiedRawData: Data,
        expectedCandidate: Data
    ) throws {
        guard verifiedRawData == expectedCandidate else { throw WorkspacePersistenceError.atomicWriteFailed }
        let decoded = try WorkspaceDocumentCodec.decode(verifiedRawData)
        guard decoded.provenance.sourceSchema == WorkspaceDocument.currentSchemaVersion else {
            throw WorkspacePersistenceError.atomicWriteFailed
        }
        loadedSource = .bytes(rawData: verifiedRawData, provenance: decoded.provenance)
    }

    private func matchesPreviousSource(_ current: Data?, _ source: LoadedSource) -> Bool {
        switch source {
        case .absent:
            current == nil
        case let .bytes(rawData, _):
            current == rawData
        }
    }

    private func completePendingRestoreCapability(_ capabilityID: UUID?) {
        guard let capabilityID else { return }
        pendingRestores[capabilityID] = nil
    }

    private func rejectIfCommitUncertain() throws {
        if pendingCommit != nil { throw WorkspacePersistenceError.commitUncertain }
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
            try rollbackWriter.createExclusively(data: data, at: url)
            let readback = try dataReadingNoFollow(at: url)
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
