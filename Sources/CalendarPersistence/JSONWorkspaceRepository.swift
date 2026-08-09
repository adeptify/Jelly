import Foundation
import WorkspaceDomain

public actor JSONWorkspaceRepository: WorkspaceRepository {
    private enum SourceBinding: Sendable {
        case absent
        case valid(rawData: Data, result: WorkspaceLoadResult)
        case opaqueInvalid(rawData: Data, identity: WorkspaceRawSourceIdentity)
    }

    private enum LoadedSource: Sendable {
        case unresolved
        case bound(SourceBinding)
        case unreadable(lastKnown: SourceBinding?)
    }

    private enum RestoreMainLockFailure: Error {
        case acquisitionFailed
    }

    private struct PendingWorkspaceCommit: Sendable {
        let previousSource: SourceBinding
        let candidateRawData: Data
        let operation: WorkspaceCommittedOperation
        let artifacts: WorkspacePendingCommitArtifacts
        let restoreCapabilityID: UUID?
    }

    private let documentURL: URL
    private let seed: @Sendable () -> WorkspaceState
    private let manifestStore: RecoveryManifestStore
    private let atomicWriter: any AtomicFileWriting
    private let rollbackWriter: any ExclusiveFileWriting
    private let mainFileWriter: any MainFileCompareAndReplaceWriting
    private var loadedSource: LoadedSource = .unresolved
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
        case .unreadable:
            throw WorkspacePersistenceError.invalidDocument
        case let .bound(.valid(_, result)):
            try rejectAndFreezeIfCurrentSourceIsUnreadable()
            return result
        case .bound(.opaqueInvalid):
            try rejectAndFreezeIfCurrentSourceIsUnreadable()
            throw WorkspacePersistenceError.invalidDocument
        case .bound(.absent):
            try rejectAndFreezeIfCurrentSourceIsUnreadable()
            return try seededLoadResult()
        case .unresolved:
            return try bindForInitialLoad()
        }
    }

    public func save(
        _ state: WorkspaceState,
        draft: PersistableDraftContext? = nil
    ) throws -> WorkspaceSaveReceipt {
        try rejectIfCommitUncertain()
        let source = try requireReadableSourceBinding()
        do {
            try WorkspaceValidator.validate(state)
        } catch {
            throw WorkspacePersistenceError.invalidWorkspace
        }
        let persistedDraft = try receipt(for: draft, in: state)
        let receipt = WorkspaceSaveReceipt(workspaceRevision: state.revision, persistedDraft: persistedDraft)
        try persist(
            candidate: try WorkspaceDocumentCodec.encode(state),
            operation: .save(receipt),
            artifacts: .init(),
            source: source
        )
        return receipt
    }

    public func verifyPersistedDraft(
        _ context: PersistableDraftContext
    ) throws -> WorkspaceDraftPersistenceVerification {
        try rejectIfCommitUncertain()
        if case .unreadable = loadedSource { return .unreadableUnknown }
        guard case let .bound(.valid(rawData, _)) = loadedSource else { return .notPersisted }
        let previous = lastKnownSourceBinding()
        do {
            return try withJellyAdvisoryLock(for: documentURL) {
                switch noFollowFileProbe(at: documentURL) {
                case .unreadableUnknown:
                    loadedSource = .unreadable(lastKnown: previous)
                    return .unreadableUnknown
                case .confirmedAbsent:
                    return .sourceChanged
                case let .bytes(current):
                    guard current == rawData else { return .sourceChanged }
                    let loaded: WorkspaceLoadResult
                    do {
                        loaded = try WorkspaceDocumentCodec.decode(current)
                    } catch {
                        return .notPersisted
                    }
                    guard let note = loaded.state.notes[context.noteID],
                          note.revision == context.persistedNoteRevision,
                          try WorkspaceChecksum.noteSnapshotChecksum(note) == context.noteSnapshotChecksum
                    else { return .notPersisted }
                    return .verified(PersistedDraftReceipt(
                        noteID: context.noteID,
                        editSessionID: context.editSessionID,
                        draftGeneration: context.draftGeneration,
                        noteSnapshotChecksum: context.noteSnapshotChecksum,
                        persistedNoteRevision: context.persistedNoteRevision
                    ))
                }
            }
        } catch {
            loadedSource = .unreadable(lastKnown: previous)
            return .unreadableUnknown
        }
    }

    public func currentDocumentData() throws -> Data {
        try rejectIfCommitUncertain()
        if case .unreadable = loadedSource {
            throw WorkspacePersistenceError.invalidDocument
        }
        guard case let .bound(.valid(rawData, _)) = loadedSource else {
            throw WorkspacePersistenceError.missingDocument
        }
        switch noFollowFileProbe(at: documentURL) {
        case let .bytes(current) where current == rawData:
            _ = try WorkspaceDocumentCodec.decode(current)
            return current
        case .unreadableUnknown:
            throw WorkspacePersistenceError.invalidDocument
        default:
            throw WorkspaceDirectCommitFailure.sourceChanged(.init())
        }
    }

    public func reloadCurrentSourceAfterExternalChange() throws -> WorkspaceReloadedSource {
        try rejectIfCommitUncertain()
        let previous = lastKnownSourceBinding()
        do {
            return try withJellyAdvisoryLock(for: documentURL) {
                switch noFollowFileProbe(at: documentURL) {
                case .confirmedAbsent:
                    loadedSource = .bound(.absent)
                    return .absent
                case .unreadableUnknown:
                    loadedSource = .unreadable(lastKnown: previous)
                    return .unreadableUnknown
                case let .bytes(rawData):
                    do {
                        let result = try WorkspaceDocumentCodec.decode(rawData)
                        loadedSource = .bound(.valid(rawData: rawData, result: result))
                        return .valid(result)
                    } catch {
                        let rawIdentity = identity(for: rawData)
                        loadedSource = .bound(.opaqueInvalid(rawData: rawData, identity: rawIdentity))
                        return .opaqueInvalid(rawIdentity)
                    }
                }
            }
        } catch {
            loadedSource = .unreadable(lastKnown: previous)
            return .unreadableUnknown
        }
    }

    public func currentRawRecoveryData() throws -> WorkspaceRawRecoveryArtifact {
        try rejectIfCommitUncertain()
        guard case let .bound(.opaqueInvalid(rawData, rawIdentity)) = loadedSource else {
            throw WorkspacePersistenceError.invalidDocument
        }
        return WorkspaceRawRecoveryArtifact(rawData: rawData, identity: rawIdentity)
    }

    public func prepareRestore(
        _ preview: WorkspaceRestorePreview,
        rollbackDirectoryURL: URL
    ) throws -> PreparedWorkspaceRestore {
        try rejectIfCommitUncertain()
        _ = try requireReadableSourceBinding()
        let decoded = try WorkspaceDocumentCodec.decode(preview.rawSourceData)
        let sourceIdentity = identity(for: preview.rawSourceData)
        let sourceNoteRevisions = decoded.state.notes.mapValues(\.revision)
        guard preview.sourceIdentity == sourceIdentity,
              preview.loadResult == decoded,
              preview.sourceNoteRevisions == sourceNoteRevisions
        else { throw WorkspacePersistenceError.restoreBindingMismatch }
        do {
            try WorkspaceValidator.validate(decoded.state)
        } catch {
            throw WorkspacePersistenceError.invalidWorkspace
        }
        let verifiedPreview = WorkspaceRestorePreview(
            sourceURL: preview.sourceURL,
            rawSourceData: preview.rawSourceData,
            sourceIdentity: sourceIdentity,
            loadResult: decoded,
            sourceNoteRevisions: sourceNoteRevisions
        )
        let capabilityID = UUID()
        let prepared = PreparedWorkspaceRestore(
            preview: verifiedPreview,
            rollbackURL: rollbackDirectoryURL.appendingPathComponent("workspace-rollback-\(UUID().uuidString).json"),
            capabilityID: capabilityID
        )
        pendingRestores[capabilityID] = prepared
        return prepared
    }

    public func discardPreparedRestore(_ prepared: PreparedWorkspaceRestore) -> Bool {
        guard let issued = pendingRestores[prepared.capabilityID], issued == prepared else { return false }
        pendingRestores[prepared.capabilityID] = nil
        return true
    }

    public func commitRestore(
        _ prepared: PreparedWorkspaceRestore,
        state: WorkspaceState
    ) throws -> WorkspaceRestoreOutcome {
        try rejectIfCommitUncertain()
        guard case .unreadable = loadedSource else {
            return try commitReadableRestore(prepared, state: state)
        }
        throw WorkspacePersistenceError.invalidDocument
    }

    private func commitReadableRestore(
        _ prepared: PreparedWorkspaceRestore,
        state: WorkspaceState
    ) throws -> WorkspaceRestoreOutcome {
        guard let issued = pendingRestores[prepared.capabilityID], issued == prepared else {
            throw WorkspacePersistenceError.invalidRestoreCapability
        }
        guard issued.provenance.sourceBytesSHA256 == persistenceSHA256(issued.rawSourceData),
              issued.provenance.sourceByteCount == issued.rawSourceData.count,
              Set(issued.sourceNoteRevisions.keys) == Set(issued.content.notes.keys),
              WorkspaceContentSnapshot(state: state) == issued.content
        else { throw WorkspacePersistenceError.restoreBindingMismatch }
        do {
            try WorkspaceValidator.validate(state)
        } catch {
            throw WorkspacePersistenceError.invalidWorkspace
        }
        do {
            return try withRestoreMainFileLock {
                let currentSource: SourceBinding
                switch noFollowFileProbe(at: documentURL) {
                case .unreadableUnknown:
                    loadedSource = .unreadable(lastKnown: lastKnownSourceBinding())
                    throw WorkspacePersistenceError.invalidDocument
                case .confirmedAbsent:
                    currentSource = .absent
                case let .bytes(rawData):
                    if let result = try? WorkspaceDocumentCodec.decode(rawData),
                       (try? WorkspaceValidator.validate(result.state)) != nil {
                        currentSource = .valid(rawData: rawData, result: result)
                    } else {
                        currentSource = .opaqueInvalid(rawData: rawData, identity: identity(for: rawData))
                    }
                }

                loadedSource = .bound(currentSource)
                pendingRestores[prepared.capabilityID] = nil
                let rollback = try writeRollbackUnlocked(for: currentSource, to: issued.rollbackURL)
                if case let .valid(rawData, result) = currentSource,
                   result.provenance.sourceSchema < WorkspaceDocument.currentSchemaVersion {
                    try registerMigrationSnapshot(rawData: rawData, provenance: result.provenance)
                }

                let receipt = WorkspaceSaveReceipt(workspaceRevision: state.revision, persistedDraft: nil)
                let outcome = WorkspaceRestoreOutcome(receipt: receipt, rollback: rollback)
                let candidate = try WorkspaceDocumentCodec.encode(state)
                let artifacts = WorkspacePendingCommitArtifacts(rollback: rollback)
                beginPendingCommit(
                    previousSource: currentSource,
                    candidate: candidate,
                    operation: .restore(outcome),
                    artifacts: artifacts,
                    restoreCapabilityID: prepared.capabilityID
                )
                let writeResult: MainFileCompareAndReplaceResult
                do {
                    switch currentSource {
                    case .absent:
                        writeResult = try createIfAbsentUnlocked(candidate: candidate)
                    case let .valid(_, result):
                        writeResult = try replaceIfSHA256MatchesUnlocked(
                            expectedSHA256: result.provenance.sourceBytesSHA256,
                            candidate: candidate
                        )
                    case let .opaqueInvalid(_, identity):
                        writeResult = try replaceIfSHA256MatchesUnlocked(
                            expectedSHA256: identity.sha256,
                            candidate: candidate
                        )
                    }
                } catch {
                    pendingCommit = nil
                    throw error
                }
                try finishMainReplacement(writeResult, candidate: candidate)
                return outcome
            }
        } catch {
            if case RestoreMainLockFailure.acquisitionFailed = error {
                loadedSource = .unreadable(lastKnown: lastKnownSourceBinding())
                throw WorkspacePersistenceError.invalidDocument
            }
            if (error as? WorkspacePersistenceError) != .commitUncertain,
               (error as? WorkspacePersistenceError) != .invalidDocument {
                pendingRestores[prepared.capabilityID] = nil
            }
            throw error
        }
    }

    public func reconcilePendingCommit() throws -> WorkspaceCommitReconciliation {
        guard let pending = pendingCommit else { return .notCommitted(.init()) }
        do {
            return try withJellyAdvisoryLock(for: documentURL) {
                let current: Data?
                switch noFollowFileProbe(at: documentURL) {
                case let .bytes(data):
                    current = data
                case .confirmedAbsent:
                    current = nil
                case .unreadableUnknown:
                    return .stillPending(pending.artifacts)
                }
                if current == pending.candidateRawData {
                    do {
                        try replaceLoadedSourceWithVerifiedRawData(
                            pending.candidateRawData,
                            expectedCandidate: pending.candidateRawData
                        )
                    } catch {
                        return .stillPending(pending.artifacts)
                    }
                    completePendingRestoreCapability(pending.restoreCapabilityID)
                    pendingCommit = nil
                    return .committed(pending.operation)
                }
                if matchesPreviousSource(current, pending.previousSource) {
                    loadedSource = .bound(pending.previousSource)
                    completePendingRestoreCapability(pending.restoreCapabilityID)
                    pendingCommit = nil
                    return .notCommitted(pending.artifacts)
                }
                completePendingRestoreCapability(pending.restoreCapabilityID)
                pendingCommit = nil
                return .sourceChanged(pending.artifacts)
            }
        } catch {
            return .stillPending(pending.artifacts)
        }
    }

    private func persist(
        candidate: Data,
        operation: WorkspaceCommittedOperation,
        artifacts: WorkspacePendingCommitArtifacts,
        source: SourceBinding,
        restoreCapabilityID: UUID? = nil
    ) throws {
        switch source {
        case let .opaqueInvalid(rawData, rawIdentity):
            guard case .restore = operation else {
                throw WorkspacePersistenceError.invalidDocument
            }
            beginPendingCommit(
                previousSource: .opaqueInvalid(rawData: rawData, identity: rawIdentity),
                candidate: candidate,
                operation: operation,
                artifacts: artifacts,
                restoreCapabilityID: restoreCapabilityID
            )
            let writeResult: MainFileCompareAndReplaceResult
            do {
                writeResult = try replaceIfSHA256Matches(
                    expectedSHA256: rawIdentity.sha256,
                    candidate: candidate
                )
            } catch {
                pendingCommit = nil
                throw error
            }
            try finishMainReplacement(writeResult, candidate: candidate)
        case .absent:
            beginPendingCommit(
                previousSource: .absent,
                candidate: candidate,
                operation: operation,
                artifacts: artifacts,
                restoreCapabilityID: restoreCapabilityID
            )
            let result: MainFileCompareAndReplaceResult
            do {
                result = try createIfAbsent(candidate: candidate)
            } catch {
                pendingCommit = nil
                throw error
            }
            try finishMainReplacement(result, candidate: candidate)
        case let .valid(rawData, result):
            if result.provenance.sourceSchema < WorkspaceDocument.currentSchemaVersion {
                guard case let .bytes(current) = noFollowFileProbe(at: documentURL), current == rawData else {
                    throw WorkspaceDirectCommitFailure.sourceChanged(artifacts)
                }
                try registerMigrationSnapshot(rawData: rawData, provenance: result.provenance)
            }
            beginPendingCommit(
                previousSource: .valid(rawData: rawData, result: result),
                candidate: candidate,
                operation: operation,
                artifacts: artifacts,
                restoreCapabilityID: restoreCapabilityID
            )
            let writeResult: MainFileCompareAndReplaceResult
            do {
                writeResult = try replaceIfSHA256Matches(
                    expectedSHA256: result.provenance.sourceBytesSHA256,
                    candidate: candidate
                )
            } catch {
                pendingCommit = nil
                throw error
            }
            try finishMainReplacement(writeResult, candidate: candidate)
        }
    }

    private func registerMigrationSnapshot(
        rawData: Data,
        provenance: WorkspaceLoadProvenance
    ) throws {
        guard provenance.sourceSchema == 1 || provenance.sourceSchema == 2 else {
            throw WorkspacePersistenceError.invalidDocument
        }
        do {
            _ = try manifestStore.registerVerifiedSnapshot(rawData: rawData, provenance: provenance)
        } catch let error as WorkspacePersistenceError {
            throw error
        } catch {
            throw WorkspacePersistenceError.atomicWriteFailed
        }
    }

    private func beginPendingCommit(
        previousSource: SourceBinding,
        candidate: Data,
        operation: WorkspaceCommittedOperation,
        artifacts: WorkspacePendingCommitArtifacts,
        restoreCapabilityID: UUID?
    ) {
        pendingCommit = .init(
            previousSource: previousSource,
            candidateRawData: candidate,
            operation: operation,
            artifacts: artifacts,
            restoreCapabilityID: restoreCapabilityID
        )
    }

    private func finishMainReplacement(
        _ result: MainFileCompareAndReplaceResult,
        candidate: Data
    ) throws {
        guard let pending = pendingCommit else { throw WorkspacePersistenceError.commitUncertain }
        switch result {
        case .sourceChanged:
            pendingCommit = nil
            completePendingRestoreCapability(pending.restoreCapabilityID)
            throw WorkspaceDirectCommitFailure.sourceChanged(pending.artifacts)
        case .commitUncertain:
            throw WorkspacePersistenceError.commitUncertain
        case let .replaced(verifiedRawData):
            do {
                try replaceLoadedSourceWithVerifiedRawData(verifiedRawData, expectedCandidate: candidate)
            } catch {
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
        let result = try WorkspaceDocumentCodec.decode(verifiedRawData)
        guard result.provenance.sourceSchema == WorkspaceDocument.currentSchemaVersion else {
            throw WorkspacePersistenceError.atomicWriteFailed
        }
        loadedSource = .bound(.valid(rawData: verifiedRawData, result: result))
    }

    private func matchesPreviousSource(_ current: Data?, _ source: SourceBinding) -> Bool {
        switch source {
        case .absent:
            current == nil
        case let .valid(rawData, _), let .opaqueInvalid(rawData, _):
            current == rawData
        }
    }

    private func writeRollbackUnlocked(
        for source: SourceBinding,
        to url: URL
    ) throws -> WorkspaceRollbackArtifact {
        switch source {
        case .absent:
            return .nonePreviousSourceAbsent
        case let .valid(rawData, _), let .opaqueInvalid(rawData, _):
            try writeVerifiedRollback(rawData, to: url)
            return .file(url, identity(for: rawData))
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

    private func createIfAbsentUnlocked(candidate: Data) throws -> MainFileCompareAndReplaceResult {
        do {
            return try mainFileWriter.createIfAbsentUnlocked(candidate: candidate, at: documentURL)
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

    private func replaceIfSHA256MatchesUnlocked(
        expectedSHA256: String,
        candidate: Data
    ) throws -> MainFileCompareAndReplaceResult {
        do {
            return try mainFileWriter.replaceIfSHA256MatchesUnlocked(
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

    private func bindForInitialLoad() throws -> WorkspaceLoadResult {
        do {
            return try withJellyAdvisoryLock(for: documentURL) {
                switch noFollowFileProbe(at: documentURL) {
                case .confirmedAbsent:
                    loadedSource = .bound(.absent)
                    return try seededLoadResult()
                case .unreadableUnknown:
                    loadedSource = .unreadable(lastKnown: nil)
                    throw WorkspacePersistenceError.invalidDocument
                case let .bytes(rawData):
                    do {
                        let result = try WorkspaceDocumentCodec.decode(rawData)
                        loadedSource = .bound(.valid(rawData: rawData, result: result))
                        return result
                    } catch {
                        loadedSource = .bound(.opaqueInvalid(
                            rawData: rawData,
                            identity: identity(for: rawData)
                        ))
                        throw error
                    }
                }
            }
        } catch let error as WorkspacePersistenceError {
            throw error
        } catch {
            loadedSource = .unreadable(lastKnown: nil)
            throw WorkspacePersistenceError.invalidDocument
        }
    }

    private func seededLoadResult() throws -> WorkspaceLoadResult {
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

    private func requireReadableSourceBinding() throws -> SourceBinding {
        switch loadedSource {
        case .unreadable:
            throw WorkspacePersistenceError.invalidDocument
        case let .bound(source):
            try rejectAndFreezeIfCurrentSourceIsUnreadable()
            return source
        case .unresolved:
            return try bindCurrentSourceForMutation()
        }
    }

    private func bindCurrentSourceForMutation() throws -> SourceBinding {
        do {
            return try withJellyAdvisoryLock(for: documentURL) {
                let source: SourceBinding
                switch noFollowFileProbe(at: documentURL) {
                case .confirmedAbsent:
                    source = .absent
                case .unreadableUnknown:
                    loadedSource = .unreadable(lastKnown: nil)
                    throw WorkspacePersistenceError.invalidDocument
                case let .bytes(rawData):
                    if let result = try? WorkspaceDocumentCodec.decode(rawData) {
                        source = .valid(rawData: rawData, result: result)
                    } else {
                        source = .opaqueInvalid(rawData: rawData, identity: identity(for: rawData))
                    }
                }
                loadedSource = .bound(source)
                return source
            }
        } catch let error as WorkspacePersistenceError {
            throw error
        } catch {
            loadedSource = .unreadable(lastKnown: nil)
            throw WorkspacePersistenceError.invalidDocument
        }
    }

    private func rejectAndFreezeIfCurrentSourceIsUnreadable() throws {
        let previous = lastKnownSourceBinding()
        do {
            try withJellyAdvisoryLock(for: documentURL) {
                if case .unreadableUnknown = noFollowFileProbe(at: documentURL) {
                    loadedSource = .unreadable(lastKnown: previous)
                    throw WorkspacePersistenceError.invalidDocument
                }
            }
        } catch let error as WorkspacePersistenceError {
            throw error
        } catch {
            loadedSource = .unreadable(lastKnown: previous)
            throw WorkspacePersistenceError.invalidDocument
        }
    }

    private func lastKnownSourceBinding() -> SourceBinding? {
        switch loadedSource {
        case let .bound(source): source
        case let .unreadable(lastKnown): lastKnown
        case .unresolved: nil
        }
    }

    private func isAdvisoryLockFailure(_ error: Error) -> Bool {
        let cocoa = error as NSError
        return cocoa.domain == NSCocoaErrorDomain && cocoa.code == CocoaError.fileLocking.rawValue
    }

    private func withRestoreMainFileLock<Result>(
        _ body: () throws -> Result
    ) throws -> Result {
        var enteredCriticalSection = false
        do {
            return try withJellyAdvisoryLock(for: documentURL) {
                enteredCriticalSection = true
                return try body()
            }
        } catch {
            if enteredCriticalSection == false, isAdvisoryLockFailure(error) {
                throw RestoreMainLockFailure.acquisitionFailed
            }
            throw error
        }
    }

    private func receipt(
        for draft: PersistableDraftContext?,
        in state: WorkspaceState
    ) throws -> PersistedDraftReceipt? {
        guard let draft else { return nil }
        guard let note = state.notes[draft.noteID],
              note.revision == draft.persistedNoteRevision,
              try WorkspaceChecksum.noteSnapshotChecksum(note) == draft.noteSnapshotChecksum
        else { throw WorkspacePersistenceError.invalidDraftContext }
        return PersistedDraftReceipt(
            noteID: draft.noteID,
            editSessionID: draft.editSessionID,
            draftGeneration: draft.draftGeneration,
            noteSnapshotChecksum: draft.noteSnapshotChecksum,
            persistedNoteRevision: draft.persistedNoteRevision
        )
    }

    private func identity(for rawData: Data) -> WorkspaceRawSourceIdentity {
        .init(sha256: persistenceSHA256(rawData), byteCount: rawData.count)
    }
}
