import CalendarDomain
import CalendarPersistence
import Foundation
import Observation
import WorkspaceDomain

enum WorkspaceStorePhase: Equatable, Sendable {
    case notLoaded, loading, ready, mutating
    case parkedCommitUncertain(UUID)
    case parkedJournalCleanup(DraftJournalIdentity, JournalCleanupStep)
    case needsRelationshipRepair
    case externalSourceChanged(WorkspaceExternalSourceChangeReason)
    case opaquePrimaryLoadFailed, unreadablePrimaryLoadFailed, loadFailed
}

enum WorkspaceExternalSourceChangeReason: Equatable, Sendable {
    case externalBytesChanged
    case publishedDraftNotPersisted
}

enum WorkspaceTransactionOutcome: Equatable, Sendable {
    case committed(WorkspaceSaveReceipt, journal: JournalResolutionStatus)
    case restored(WorkspaceRestoreOutcome)
    case noChange(WorkspaceNoChangeReason, journal: JournalResolutionStatus)
    case conflict(WorkspaceConflict)
    case draftSuperseded
    case commitPending(transactionID: UUID, artifacts: WorkspacePendingCommitArtifacts)
    case notCommitted(transactionID: UUID, journal: JournalResolutionStatus, artifacts: WorkspacePendingCommitArtifacts)
    case externalSourceChanged(transactionID: UUID?, reason: WorkspaceExternalSourceChangeReason, journal: JournalResolutionStatus, artifacts: WorkspacePendingCommitArtifacts)
    case persistenceBlocked(transactionID: UUID?, reason: WorkspacePersistenceBlockReason, journal: JournalResolutionStatus)
}

enum PendingCommitRetryOutcome: Equatable, Sendable {
    case committed(WorkspaceCommittedOperation, journal: JournalResolutionStatus)
    case notCommitted(transactionID: UUID, journal: JournalResolutionStatus, artifacts: WorkspacePendingCommitArtifacts)
    case sourceChanged(transactionID: UUID, journal: JournalResolutionStatus, artifacts: WorkspacePendingCommitArtifacts)
    case stillPending(transactionID: UUID, artifacts: WorkspacePendingCommitArtifacts)
}

enum WorkspaceExternalReloadOutcome: Equatable, Sendable {
    case source(WorkspaceReloadedSource)
    case transaction(WorkspaceTransactionOutcome)
}

enum WorkspacePersistenceBlockReason: Equatable, Sendable { case unreadablePrimary, opaqueInvalidPrimary, loadFailed }
enum WorkspaceStoreError: Error, Equatable, Sendable { case frozen, nothingToUndo, nothingToRedo }

@MainActor
@Observable final class WorkspaceStore {
    private(set) var state: WorkspaceState { didSet { statePublicationGeneration &+= 1 } }
    var calendarState: CalendarState { state.calendar }
    private(set) var statePublicationGeneration: UInt = 0
    private(set) var phase: WorkspaceStorePhase = .notLoaded
    private(set) var canUndo = false
    private(set) var canRedo = false

    private let repository: any WorkspaceRepository
    private let journal: DraftJournalRepository?
    private let clock: @Sendable () -> Date
    private let queue = WorkspaceTransactionQueue()
    private var undoStack: [WorkspaceStoreUndoRecord] = []
    private var redoStack: [WorkspaceStoreUndoRecord] = []
    private var noteRevisionHighWatermarks: [NoteID: Int64] = [:]
    private var journalCleanupReceipts: [DraftJournalIdentity: PersistedDraftReceipt] = [:]
    private var journalCleanupTerminalPhases: [DraftJournalIdentity: WorkspaceStorePhase] = [:]
    private var acceptedDraftGenerations: [DraftJournalIdentity: AcceptedDraftGeneration] = [:]
    private var parkedSave: ParkedSave?
    private var parkedRestore: ParkedRestore?
    private var pendingExternalRepairState: WorkspaceState?

    private struct ParkedSave {
        let transactionID: UUID
        let candidate: WorkspaceState
        let draftReceipt: PersistedDraftReceipt?
        let completion: SaveCompletion
    }
    private enum SaveCompletion {
        case forward(undoRecord: WorkspaceStoreUndoRecord?, acceptedDraft: AcceptedDraftGeneration?)
        case undo(undo: Bool, reverseRecord: WorkspaceStoreUndoRecord, ledger: [NoteID: Int64])
        case externalAdoption(ledger: [NoteID: Int64])
        case externalRepair(ledger: [NoteID: Int64])

        var notCommittedTerminalPhase: WorkspaceStorePhase {
            switch self {
            case .externalRepair:
                .needsRelationshipRepair
            case .externalAdoption:
                .externalSourceChanged(.externalBytesChanged)
            case .forward, .undo:
                .ready
            }
        }

        var resumesQueueAfterNotCommitted: Bool {
            switch self {
            case .forward, .undo:
                true
            case .externalAdoption, .externalRepair:
                false
            }
        }

        var sourceChangedTerminalPhase: WorkspaceStorePhase {
            // A direct or reconciled source change invalidates every saved
            // candidate, including a repair candidate held only in memory.
            .externalSourceChanged(.externalBytesChanged)
        }
    }
    private struct ParkedRestore {
        let transactionID: UUID
        let candidate: WorkspaceState
        let prepared: PreparedWorkspaceRestore
    }
    private struct AcceptedDraftGeneration {
        let identity: DraftJournalIdentity
        let generation: UInt64
        let accepted: PreviousAcceptedDraft
    }

    init(
        initialState: WorkspaceState,
        repository: any WorkspaceRepository,
        journal: DraftJournalRepository? = nil,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.state = initialState
        self.repository = repository
        self.journal = journal
        self.clock = clock
        self.noteRevisionHighWatermarks = initialState.notes.mapValues(\.revision)
    }

    func load() async {
        guard phase == .notLoaded || phase == .ready else { return }
        phase = .loading
        do {
            let loaded = try await repository.load()
            state = loaded.state
            noteRevisionHighWatermarks = loaded.state.notes.mapValues(\.revision)
            phase = loaded.consistencyIssues.isEmpty ? .ready : .needsRelationshipRepair
            pendingExternalRepairState = loaded.consistencyIssues.isEmpty ? nil : loaded.state
            if loaded.consistencyIssues.isEmpty {
                await recoverJournalAtStartup()
            }
        } catch {
            let projection = try? await repository.reloadCurrentSourceAfterExternalChange()
            switch projection {
            case .opaqueInvalid:
                phase = .opaquePrimaryLoadFailed
            case .unreadableUnknown:
                phase = .unreadablePrimaryLoadFailed
            default:
                phase = .loadFailed
            }
        }
    }

    func sendWorkspace(_ command: WorkspaceCommand, undoLabel: String? = nil) async throws -> WorkspaceTransactionOutcome {
        if phase == .unreadablePrimaryLoadFailed {
            return .persistenceBlocked(transactionID: nil, reason: .unreadablePrimary, journal: .clean)
        }
        if case let .repairConsistency(payload) = command,
           phase == .needsRelationshipRepair,
           pendingExternalRepairState != nil {
            return try await enqueueTransaction { [weak self] id in
                guard let self else { throw CancellationError() }
                return try await self.performExternalRepair(payload: payload, transactionID: id)
            }
        }
        try ensureOrdinaryMutationAllowed()
        return try await enqueueTransaction { [weak self] id in
            guard let self else { throw CancellationError() }
            return try await self.perform(command: command, undoLabel: undoLabel, transactionID: id)
        }
    }

    func sendCalendar(_ command: CalendarCommand, undoLabel: String? = nil) async throws -> WorkspaceTransactionOutcome {
        try await sendWorkspace(.calendar(command), undoLabel: undoLabel)
    }

    func submitDraft(_ submission: NoteDraftSubmission) async throws -> WorkspaceTransactionOutcome {
        try ensureOrdinaryMutationAllowed()
        if let journal {
            let entry = try DraftJournalCoordinator.entry(submission: submission, workspaceRevision: state.revision, clock: clock)
            try await journal.persist(entry)
        }
        return try await sendWorkspace(.updateNote(submission), undoLabel: "编辑笔记")
    }

    func undo() async throws -> WorkspaceTransactionOutcome {
        try ensureOrdinaryMutationAllowed()
        guard let record = undoStack.last else { throw WorkspaceStoreError.nothingToUndo }
        return try await enqueueTransaction { [weak self] id in
            guard let self else { throw CancellationError() }
            return try await self.performUndo(record: record, transactionID: id, undo: true)
        }
    }

    func redo() async throws -> WorkspaceTransactionOutcome {
        try ensureOrdinaryMutationAllowed()
        guard let record = redoStack.last else { throw WorkspaceStoreError.nothingToRedo }
        return try await enqueueTransaction { [weak self] id in
            guard let self else { throw CancellationError() }
            return try await self.performUndo(record: record, transactionID: id, undo: false)
        }
    }

    func restore(
        _ preview: WorkspaceRestorePreview,
        rollbackDirectoryURL: URL
    ) async throws -> WorkspaceTransactionOutcome {
        guard phase == .ready
            || phase.isExternalSourceChanged
            || phase == .opaquePrimaryLoadFailed
            || phase == .needsRelationshipRepair
        else {
            throw WorkspaceStoreError.frozen
        }
        return try await enqueueTransaction { [weak self] id in
            guard let self else { throw CancellationError() }
            return try await self.performRestore(
                preview: preview, rollbackDirectoryURL: rollbackDirectoryURL, transactionID: id
            )
        }
    }

    func currentDocumentData() async throws -> Data { try await repository.currentDocumentData() }
    func rawRecoveryData() async throws -> WorkspaceRawRecoveryArtifact { try await repository.currentRawRecoveryData() }
    func exportBackup(to destination: URL) async throws {
        try await BackupService().exportCurrent(from: repository, to: destination)
    }
    func inspectRestoreSource(at source: URL) async throws -> WorkspaceRestorePreview {
        try await BackupService().inspectRestoreSource(source)
    }
    func exportRawRecoveryCopy(to destination: URL) async throws -> WorkspaceRawRecoveryArtifact {
        let artifact = try await repository.currentRawRecoveryData()
        do {
            try FoundationAtomicFileWriter().replaceAtomically(data: artifact.rawData, at: destination)
            guard try Data(contentsOf: destination) == artifact.rawData else {
                throw WorkspacePersistenceError.atomicWriteFailed
            }
            return artifact
        } catch let error as WorkspacePersistenceError {
            throw error
        } catch {
            throw WorkspacePersistenceError.atomicWriteFailed
        }
    }

    @discardableResult
    func reloadExternalSource() async throws -> WorkspaceExternalReloadOutcome {
        guard phase.allowsExternalReload else { throw WorkspaceStoreError.frozen }
        let reloaded = try await repository.reloadCurrentSourceAfterExternalChange()
        switch reloaded {
        case let .valid(external):
            let adoption = try WorkspaceExternalSourceAdoptionPlanner.plan(
                current: state, external: external.state, sessionNoteHighWatermarks: noteRevisionHighWatermarks
            )
            guard adoption.consistencyIssues.isEmpty else {
                pendingExternalRepairState = external.state
                phase = .needsRelationshipRepair
                return .source(reloaded)
            }
            let direct = external.provenance.sourceSchema == WorkspaceDocument.currentSchemaVersion
                && adoption.candidate == external.state && !adoption.requiresNormalization
            if direct {
                state = adoption.candidate
                noteRevisionHighWatermarks = adoption.noteRevisionHighWatermarks
            } else {
                let outcome = try await enqueueTransaction { [weak self] id in
                    guard let self else { throw CancellationError() }
                    return try await self.performExternalAdoption(
                        candidate: adoption.candidate, ledger: adoption.noteRevisionHighWatermarks, transactionID: id
                    )
                }
                return .transaction(outcome)
            }
            pendingExternalRepairState = nil
            phase = .ready
        case .opaqueInvalid:
            pendingExternalRepairState = nil
            phase = .opaquePrimaryLoadFailed
        case .unreadableUnknown:
            pendingExternalRepairState = nil
            phase = .unreadablePrimaryLoadFailed
        case .absent:
            pendingExternalRepairState = nil
            phase = .externalSourceChanged(.externalBytesChanged)
        }
        return .source(reloaded)
    }


    func retryPendingCommit(_ transactionID: UUID) async throws -> PendingCommitRetryOutcome {
        guard case let .parkedCommitUncertain(parked) = phase, parked == transactionID else {
            throw WorkspaceStoreError.frozen
        }
        switch try await repository.reconcilePendingCommit() {
        case let .committed(operation):
            switch operation {
            case let .save(receipt):
                guard let parked = parkedSave, parked.transactionID == transactionID else { throw WorkspaceStoreError.frozen }
                let journalStatus = await finishCommittedSave(
                    candidate: parked.candidate, completion: parked.completion, draftReceipt: parked.draftReceipt
                )
                parkedSave = nil
                if phase == .parkedCommitUncertain(transactionID) { phase = .ready }
                if case .cleanupPending = journalStatus { parkJournalCleanup(journalStatus, receipt: parked.draftReceipt) } else { queue.resume() }
                return .committed(.save(receipt), journal: journalStatus)
            case let .restore(outcome):
                guard let parked = parkedRestore, parked.transactionID == transactionID else { throw WorkspaceStoreError.frozen }
                state = parked.candidate
                undoStack.removeAll(); redoStack.removeAll(); updateUndoAvailability()
                mergeSessionNoteLedger(with: parked.candidate)
                pendingExternalRepairState = nil
                parkedRestore = nil
                phase = .ready
                queue.resume()
                return .committed(.restore(outcome), journal: .clean)
            }
        case let .notCommitted(artifacts):
            guard (parkedSave?.transactionID == transactionID) || (parkedRestore?.transactionID == transactionID) else { throw WorkspaceStoreError.frozen }
            let parked = parkedSave
            let restore = parkedRestore
            let draftReceipt = parked?.draftReceipt
            if let restore, restore.transactionID == transactionID {
                _ = await repository.discardPreparedRestore(restore.prepared)
            }
            let journalStatus: JournalResolutionStatus
            if let parked, parked.transactionID == transactionID {
                journalStatus = await finishNotCommittedSave(
                    completion: parked.completion, draftReceipt: draftReceipt, artifacts: artifacts
                )
            } else {
                journalStatus = await unbindIfNeeded(draftReceipt)
            }
            parkedSave = nil
            parkedRestore = nil
            if restore?.transactionID == transactionID {
                phase = .ready
            }
            if case .cleanupPending = journalStatus {
                if parked == nil { parkJournalCleanup(journalStatus, receipt: draftReceipt) }
            } else if parked?.completion.resumesQueueAfterNotCommitted ?? true {
                queue.resume()
            }
            return .notCommitted(transactionID: transactionID, journal: journalStatus, artifacts: artifacts)
        case let .sourceChanged(artifacts):
            let parked = parkedSave
            let draftReceipt = parked?.draftReceipt
            if let parked = parkedRestore, parked.transactionID == transactionID {
                _ = await repository.discardPreparedRestore(parked.prepared)
            }
            let journalStatus: JournalResolutionStatus
            if let parked, parked.transactionID == transactionID {
                journalStatus = await finishSourceChangedSave(
                    completion: parked.completion, draftReceipt: draftReceipt, artifacts: artifacts
                )
            } else {
                journalStatus = await finishSourceChangedRestore(artifacts: artifacts)
            }
            parkedSave = nil
            parkedRestore = nil
            return .sourceChanged(transactionID: transactionID, journal: journalStatus, artifacts: artifacts)
        case let .stillPending(artifacts):
            return .stillPending(transactionID: transactionID, artifacts: artifacts)
        }
    }

    func retryJournalCleanup(_ identity: DraftJournalIdentity) async -> JournalResolutionStatus {
        guard case let .parkedJournalCleanup(parked, step) = phase, parked == identity, let journal else {
            return .clean
        }
        let status = await DraftJournalCoordinator.retryCleanup(
            identity, step: step, receipt: journalCleanupReceipts[identity], journal: journal
        )
        if case .clean = status {
            journalCleanupReceipts.removeValue(forKey: identity)
            let terminalPhase = journalCleanupTerminalPhases.removeValue(forKey: identity) ?? .ready
            phase = terminalPhase
            if terminalPhase == .ready { queue.resume() }
        }
        return status
    }

    private func perform(
        command originalCommand: WorkspaceCommand,
        undoLabel: String?,
        transactionID: UUID
    ) async throws -> WorkspaceTransactionOutcome {
        phase = .mutating
        defer { if phase == .mutating { phase = .ready } }
        let now = clock()
        let command = try rebasedDraftCommand(normalized(command: originalCommand))
        let reduction = try WorkspaceReducer.reduce(state, command: command, now: now)
        switch reduction {
        case let .noChange(reason):
            return try await resolveNoChange(reason: reason, command: command, transactionID: transactionID)
        case let .conflict(conflict):
            return .conflict(conflict)
        case let .changed(unrevisedChange):
            let change = try applyingSessionNoteRevisions(to: unrevisedChange)
            let draftReceipt: PersistedDraftReceipt?
            if let context = change.draftContext {
                let receipt = PersistedDraftReceipt(
                    noteID: context.noteID, editSessionID: context.editSessionID,
                    draftGeneration: context.draftGeneration,
                    noteSnapshotChecksum: context.noteSnapshotChecksum,
                    persistedNoteRevision: context.persistedNoteRevision
                )
                if let journal {
                    guard let candidateNote = change.state.notes[receipt.noteID] else {
                        throw WorkspaceStoreError.frozen
                    }
                    switch try await journal.rebaseAndBind(
                        expected: .init(identity: .init(noteID: receipt.noteID, editSessionID: receipt.editSessionID), draftGeneration: receipt.draftGeneration),
                        finalCandidateNote: candidateNote, receipt: receipt
                    ) {
                    case .bound: break
                    case .supersededByNewerDraft: return .draftSuperseded
                    }
                }
                draftReceipt = receipt
            } else {
                draftReceipt = nil
            }
            return try await persistSave(
                candidate: change.state,
                draftContext: change.draftContext,
                draftReceipt: draftReceipt,
                completion: .forward(
                    undoRecord: WorkspaceUndoReducer.record(before: state, after: change.state, label: undoLabel),
                    acceptedDraft: acceptedDraft(command: command, candidate: change.state)
                ),
                transactionID: transactionID
            )
        }
    }

    private func resolveNoChange(
        reason: WorkspaceNoChangeReason,
        command: WorkspaceCommand,
        transactionID: UUID
    ) async throws -> WorkspaceTransactionOutcome {
        guard case let .updateNote(submission) = command, let journal,
              let note = state.notes[submission.noteID]
        else { return .noChange(reason, journal: .clean) }
        let receipt = PersistedDraftReceipt(
            noteID: note.id, editSessionID: .editor(submission.editSessionID),
            draftGeneration: submission.draftGeneration,
            noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(note),
            persistedNoteRevision: note.revision
        )
        switch try await repository.verifyPersistedDraft(.init(
            noteID: receipt.noteID, editSessionID: receipt.editSessionID,
            draftGeneration: receipt.draftGeneration, noteSnapshotChecksum: receipt.noteSnapshotChecksum,
            persistedNoteRevision: receipt.persistedNoteRevision
        )) {
        case .verified:
            let status = await DraftJournalCoordinator.acknowledgeAndClear(receipt, journal: journal)
            if case .cleanupPending = status { parkJournalCleanup(status, receipt: receipt) }
            return .noChange(reason, journal: status)
        case .sourceChanged:
            phase = .externalSourceChanged(.externalBytesChanged)
            terminateQueuedForExternal(reason: .externalBytesChanged, artifacts: .init())
            return .externalSourceChanged(transactionID: transactionID, reason: .externalBytesChanged, journal: .clean, artifacts: .init())
        case .notPersisted:
            phase = .externalSourceChanged(.publishedDraftNotPersisted)
            terminateQueuedForExternal(reason: .publishedDraftNotPersisted, artifacts: .init())
            return .externalSourceChanged(transactionID: transactionID, reason: .publishedDraftNotPersisted, journal: .clean, artifacts: .init())
        case .unreadableUnknown:
            phase = .unreadablePrimaryLoadFailed
            terminateQueuedForPersistenceBlock(reason: .unreadablePrimary)
            return .persistenceBlocked(transactionID: transactionID, reason: .unreadablePrimary, journal: .clean)
        }
    }

    private func unbindIfNeeded(_ receipt: PersistedDraftReceipt?) async -> JournalResolutionStatus {
        guard let receipt, let journal else { return .clean }
        do {
            guard try await journal.unbindPending(receipt) else {
                return .cleanupPending(identity: .init(noteID: receipt.noteID, editSessionID: receipt.editSessionID), step: .unbind)
            }
            return .clean
        } catch {
            return .cleanupPending(identity: .init(noteID: receipt.noteID, editSessionID: receipt.editSessionID), step: .unbind)
        }
    }

    private func parkJournalCleanup(
        _ status: JournalResolutionStatus,
        receipt: PersistedDraftReceipt?,
        terminalPhase: WorkspaceStorePhase = .ready
    ) {
        guard case let .cleanupPending(identity, step) = status else { return }
        if let receipt { journalCleanupReceipts[identity] = receipt }
        journalCleanupTerminalPhases[identity] = terminalPhase
        phase = .parkedJournalCleanup(identity, step)
    }

    private func recoverJournalAtStartup() async {
        guard let journal else { return }
        do {
            guard let envelope = try await journal.current() else { return }
            for record in envelope.records {
                let identity = record.identity
                if let saved = record.savedReceipt {
                    let status = await DraftJournalCoordinator.retryCleanup(
                        identity, step: .clear, receipt: saved, journal: journal
                    )
                    if case .cleanupPending = status {
                        parkJournalCleanup(status, receipt: saved)
                        return
                    }
                    continue
                }
                if let pending = record.pendingReceipt {
                    let verification = try await repository.verifyPersistedDraft(.init(
                        noteID: pending.noteID, editSessionID: pending.editSessionID,
                        draftGeneration: pending.draftGeneration, noteSnapshotChecksum: pending.noteSnapshotChecksum,
                        persistedNoteRevision: pending.persistedNoteRevision
                    ))
                    switch verification {
                    case let .verified(receipt) where receipt == pending:
                        let status = await DraftJournalCoordinator.recordAndClear(pending, journal: journal)
                        if case .cleanupPending = status {
                            parkJournalCleanup(status, receipt: pending)
                            return
                        }
                    case .notPersisted:
                        let status = await unbindIfNeeded(pending)
                        if case .cleanupPending = status {
                            parkJournalCleanup(status, receipt: pending)
                            return
                        }
                        continue
                    case .sourceChanged:
                        phase = .externalSourceChanged(.externalBytesChanged)
                        return
                    case .unreadableUnknown, .verified:
                        phase = .unreadablePrimaryLoadFailed
                        return
                    }
                    continue
                }
                guard let note = state.notes[record.entry.noteID] else {
                    phase = .externalSourceChanged(.publishedDraftNotPersisted)
                    return
                }
                let context = PersistableDraftContext(
                    noteID: note.id, editSessionID: record.entry.editSessionID,
                    draftGeneration: record.entry.draftGeneration,
                    noteSnapshotChecksum: record.entry.noteSnapshotChecksum,
                    persistedNoteRevision: note.revision
                )
                switch try await repository.verifyPersistedDraft(context) {
                case let .verified(receipt):
                    let status = await DraftJournalCoordinator.acknowledgeAndClear(receipt, journal: journal)
                    if case .cleanupPending = status {
                        parkJournalCleanup(status, receipt: receipt)
                        return
                    }
                case .notPersisted:
                    phase = .externalSourceChanged(.publishedDraftNotPersisted)
                    return
                case .sourceChanged:
                    phase = .externalSourceChanged(.externalBytesChanged)
                    return
                case .unreadableUnknown:
                    phase = .unreadablePrimaryLoadFailed
                    return
                }
            }
        } catch {
            phase = .unreadablePrimaryLoadFailed
        }
    }

    /// All ordinary, undo/redo, external-normalization and repair saves go
    /// through this single driver.  The parked record owns the post-save
    /// transition, so a later FIFO head can never publish the earlier save.
    private func persistSave(
        candidate: WorkspaceState,
        draftContext: PersistableDraftContext?,
        draftReceipt: PersistedDraftReceipt?,
        completion: SaveCompletion,
        transactionID: UUID
    ) async throws -> WorkspaceTransactionOutcome {
        do {
            let receipt = try await repository.save(candidate, draft: draftContext)
            let journalStatus = await finishCommittedSave(candidate: candidate, completion: completion, draftReceipt: draftReceipt)
            return .committed(receipt, journal: journalStatus)
        } catch let failure as WorkspaceDirectCommitFailure {
            let artifacts: WorkspacePendingCommitArtifacts
            switch failure { case let .sourceChanged(value): artifacts = value }
            let cleanup = await finishSourceChangedSave(
                completion: completion, draftReceipt: draftReceipt, artifacts: artifacts
            )
            return .externalSourceChanged(
                transactionID: transactionID, reason: .externalBytesChanged, journal: cleanup, artifacts: artifacts
            )
        } catch WorkspacePersistenceError.commitUncertain {
            return try await reconcileImmediately(
                transactionID: transactionID, candidate: candidate, draftReceipt: draftReceipt, completion: completion
            )
        } catch WorkspacePersistenceError.atomicWriteFailed {
            let journalStatus = await finishNotCommittedSave(
                completion: completion, draftReceipt: draftReceipt, artifacts: .init()
            )
            return .notCommitted(transactionID: transactionID, journal: journalStatus, artifacts: .init())
        } catch WorkspacePersistenceError.invalidDocument {
            guard await repositoryReportsUnreadablePrimary() else {
                throw WorkspacePersistenceError.invalidDocument
            }
            let journalStatus = await finishUnreadablePrimarySave(draftReceipt)
            return .persistenceBlocked(
                transactionID: transactionID, reason: .unreadablePrimary, journal: journalStatus
            )
        } catch let error as WorkspacePersistenceError {
            throw error
        } catch {
            throw error
        }
    }

    private func finishCommittedSave(
        candidate: WorkspaceState,
        completion: SaveCompletion,
        draftReceipt: PersistedDraftReceipt?
    ) async -> JournalResolutionStatus {
        switch completion {
        case let .forward(undoRecord, acceptedDraft):
            publish(candidate, undoRecord: undoRecord)
            remember(acceptedDraft)
        case let .undo(undo, reverseRecord, ledger):
            state = candidate
            noteRevisionHighWatermarks = ledger
            if undo { _ = undoStack.popLast(); redoStack.append(reverseRecord) }
            else { _ = redoStack.popLast(); undoStack.append(reverseRecord) }
            updateUndoAvailability()
        case let .externalAdoption(ledger), let .externalRepair(ledger):
            state = candidate
            noteRevisionHighWatermarks = ledger
            pendingExternalRepairState = nil
            updateUndoAvailability()
        }
        let journalStatus = if case .forward = completion, let journal, let draftReceipt {
            await DraftJournalCoordinator.recordAndClear(draftReceipt, journal: journal)
        } else { JournalResolutionStatus.clean }
        if case .cleanupPending = journalStatus { parkJournalCleanup(journalStatus, receipt: draftReceipt) }
        return journalStatus
    }

    /// A definite failure cannot leave callers guessing.  External adoption
    /// and repair have deliberately different terminal ownership: repair
    /// keeps its inspected candidate for another repair attempt, while an
    /// adoption requires the source to be read again before any ordinary
    /// command may proceed.
    private func finishNotCommittedSave(
        completion: SaveCompletion,
        draftReceipt: PersistedDraftReceipt?,
        artifacts: WorkspacePendingCommitArtifacts
    ) async -> JournalResolutionStatus {
        let journalStatus = await unbindIfNeeded(draftReceipt)
        if case .cleanupPending = journalStatus {
            parkJournalCleanup(
                journalStatus, receipt: draftReceipt, terminalPhase: completion.notCommittedTerminalPhase
            )
            return journalStatus
        }
        applyNotCommittedTerminal(completion: completion, artifacts: artifacts)
        return .clean
    }

    private func applyNotCommittedTerminal(
        completion: SaveCompletion,
        artifacts: WorkspacePendingCommitArtifacts
    ) {
        switch completion {
        case .externalRepair:
            phase = .needsRelationshipRepair
            queue.terminateQueued { transactionID in
                .notCommitted(transactionID: transactionID, journal: .clean, artifacts: artifacts)
            }
        case .externalAdoption:
            phase = .externalSourceChanged(.externalBytesChanged)
            terminateQueuedForExternal(reason: .externalBytesChanged, artifacts: artifacts)
        case .forward, .undo:
            phase = .ready
        }
    }

    private func repositoryReportsUnreadablePrimary() async -> Bool {
        do {
            if case .unreadableUnknown = try await repository.reloadCurrentSourceAfterExternalChange() {
                return true
            }
        } catch {
            // The original save error is the authoritative result when the
            // verification probe itself cannot establish unreadability.
        }
        return false
    }

    private func finishUnreadablePrimarySave(
        _ draftReceipt: PersistedDraftReceipt?
    ) async -> JournalResolutionStatus {
        let journalStatus = await unbindIfNeeded(draftReceipt)
        let terminalPhase = WorkspaceStorePhase.unreadablePrimaryLoadFailed
        if case .cleanupPending = journalStatus {
            parkJournalCleanup(journalStatus, receipt: draftReceipt, terminalPhase: terminalPhase)
        } else {
            phase = terminalPhase
        }
        terminateQueuedForPersistenceBlock(reason: .unreadablePrimary)
        return journalStatus
    }

    private func finishSourceChangedSave(
        completion: SaveCompletion,
        draftReceipt: PersistedDraftReceipt?,
        artifacts: WorkspacePendingCommitArtifacts
    ) async -> JournalResolutionStatus {
        let journalStatus = await unbindIfNeeded(draftReceipt)
        let terminalPhase = completion.sourceChangedTerminalPhase
        if case .cleanupPending = journalStatus {
            parkJournalCleanup(journalStatus, receipt: draftReceipt, terminalPhase: terminalPhase)
        } else {
            phase = terminalPhase
        }
        terminateQueuedForExternal(reason: .externalBytesChanged, artifacts: artifacts)
        return journalStatus
    }

    private func finishSourceChangedRestore(
        artifacts: WorkspacePendingCommitArtifacts
    ) async -> JournalResolutionStatus {
        let terminalPhase = WorkspaceStorePhase.externalSourceChanged(.externalBytesChanged)
        phase = terminalPhase
        terminateQueuedForExternal(reason: .externalBytesChanged, artifacts: artifacts)
        return .clean
    }

    private func reconcileImmediately(
        transactionID: UUID,
        candidate: WorkspaceState,
        draftReceipt: PersistedDraftReceipt?,
        completion: SaveCompletion
    ) async throws -> WorkspaceTransactionOutcome {
        switch try await repository.reconcilePendingCommit() {
        case let .committed(.save(receipt)):
            let journalStatus = await finishCommittedSave(
                candidate: candidate, completion: completion, draftReceipt: draftReceipt
            )
            return .committed(receipt, journal: journalStatus)
        case .committed(.restore):
            throw WorkspaceStoreError.frozen
        case let .notCommitted(artifacts):
            let journalStatus = await finishNotCommittedSave(
                completion: completion, draftReceipt: draftReceipt, artifacts: artifacts
            )
            return .notCommitted(transactionID: transactionID, journal: journalStatus, artifacts: artifacts)
        case let .sourceChanged(artifacts):
            let cleanup = await finishSourceChangedSave(
                completion: completion, draftReceipt: draftReceipt, artifacts: artifacts
            )
            return .externalSourceChanged(transactionID: transactionID, reason: .externalBytesChanged, journal: cleanup, artifacts: artifacts)
        case let .stillPending(artifacts):
            parkedSave = .init(
                transactionID: transactionID, candidate: candidate, draftReceipt: draftReceipt, completion: completion
            )
            phase = .parkedCommitUncertain(transactionID)
            return .commitPending(transactionID: transactionID, artifacts: artifacts)
        }
    }

    private func performUndo(
        record: WorkspaceStoreUndoRecord,
        transactionID: UUID,
        undo: Bool
    ) async throws -> WorkspaceTransactionOutcome {
        phase = .mutating
        defer { if phase == .mutating { phase = .ready } }
        let application = try WorkspaceUndoReducer.apply(
            record, direction: undo ? .undo : .redo, to: state,
            noteRevisionHighWatermarks: noteRevisionHighWatermarks
        )
        return try await persistSave(
            candidate: application.candidate,
            draftContext: nil,
            draftReceipt: nil,
            completion: .undo(
                undo: undo, reverseRecord: application.reverseRecord, ledger: application.noteRevisionHighWatermarks
            ),
            transactionID: transactionID
        )
    }

    private func performExternalRepair(
        payload: WorkspaceConsistencyRepairPayload,
        transactionID: UUID
    ) async throws -> WorkspaceTransactionOutcome {
        guard let external = pendingExternalRepairState else { throw WorkspaceStoreError.frozen }
        phase = .mutating
        defer {
            if phase == .mutating {
                phase = .needsRelationshipRepair
            }
        }
        _ = clock()
        let reduction = try WorkspaceReducer.reduce(external, command: .repairConsistency(payload), now: .distantPast)
        switch reduction {
        case let .noChange(reason):
            return .noChange(reason, journal: .clean)
        case let .conflict(conflict):
            return .conflict(conflict)
        case let .changed(change):
            let adoption = try WorkspaceExternalSourceAdoptionPlanner.plan(
                current: state,
                external: change.state,
                sessionNoteHighWatermarks: noteRevisionHighWatermarks
            )
            guard adoption.consistencyIssues.isEmpty else { throw WorkspaceStoreError.frozen }
            let outcome = try await persistSave(
                candidate: adoption.candidate,
                draftContext: nil,
                draftReceipt: nil,
                completion: .externalRepair(ledger: adoption.noteRevisionHighWatermarks),
                transactionID: transactionID
            )
            if case .committed = outcome { phase = .ready }
            return outcome
        }
    }

    private func performExternalAdoption(
        candidate: WorkspaceState,
        ledger: [NoteID: Int64],
        transactionID: UUID
    ) async throws -> WorkspaceTransactionOutcome {
        phase = .mutating
        defer { if phase == .mutating { phase = .ready } }
        _ = clock()
        let outcome = try await persistSave(
            candidate: candidate,
            draftContext: nil,
            draftReceipt: nil,
            completion: .externalAdoption(ledger: ledger),
            transactionID: transactionID
        )
        if case .committed = outcome { phase = .ready }
        return outcome
    }

    private func performRestore(
        preview: WorkspaceRestorePreview,
        rollbackDirectoryURL: URL,
        transactionID: UUID
    ) async throws -> WorkspaceTransactionOutcome {
        phase = .mutating
        defer { if phase == .mutating { phase = .ready } }
        let payload = WorkspaceRestoreContentPayload(
            content: .init(state: preview.loadResult.state),
            sourceRevisionHighWatermark: preview.loadResult.state.revision,
            sourceNoteRevisions: preview.sourceNoteRevisions
        )
        let reduction = try WorkspaceReducer.reduce(state, command: .restoreContent(payload), now: clock())
        switch reduction {
        case let .noChange(reason):
            return .noChange(reason, journal: .clean)
        case let .conflict(conflict):
            return .conflict(conflict)
        case let .changed(change):
            let prepared = try await repository.prepareRestore(preview, rollbackDirectoryURL: rollbackDirectoryURL)
            do {
                let outcome = try await repository.commitRestore(prepared, state: change.state)
                state = change.state
                undoStack.removeAll()
                redoStack.removeAll()
                mergeSessionNoteLedger(with: change.state)
                pendingExternalRepairState = nil
                updateUndoAvailability()
                return .restored(outcome)
            } catch let failure as WorkspaceDirectCommitFailure {
                _ = await repository.discardPreparedRestore(prepared)
                let artifacts: WorkspacePendingCommitArtifacts
                switch failure { case let .sourceChanged(value): artifacts = value }
                phase = .externalSourceChanged(.externalBytesChanged)
                terminateQueuedForExternal(reason: .externalBytesChanged, artifacts: artifacts)
                return .externalSourceChanged(transactionID: transactionID, reason: .externalBytesChanged, journal: .clean, artifacts: artifacts)
            } catch WorkspacePersistenceError.commitUncertain {
                switch try await repository.reconcilePendingCommit() {
                case let .committed(.restore(outcome)):
                    state = change.state
                    undoStack.removeAll(); redoStack.removeAll(); updateUndoAvailability()
                    mergeSessionNoteLedger(with: change.state)
                    pendingExternalRepairState = nil
                    return .restored(outcome)
                case let .notCommitted(artifacts):
                    _ = await repository.discardPreparedRestore(prepared)
                    return .notCommitted(transactionID: transactionID, journal: .clean, artifacts: artifacts)
                case let .sourceChanged(artifacts):
                    _ = await repository.discardPreparedRestore(prepared)
                    phase = .externalSourceChanged(.externalBytesChanged)
                    terminateQueuedForExternal(reason: .externalBytesChanged, artifacts: artifacts)
                    return .externalSourceChanged(transactionID: transactionID, reason: .externalBytesChanged, journal: .clean, artifacts: artifacts)
                case let .stillPending(artifacts):
                    parkedRestore = .init(transactionID: transactionID, candidate: change.state, prepared: prepared)
                    phase = .parkedCommitUncertain(transactionID)
                    return .commitPending(transactionID: transactionID, artifacts: artifacts)
                case .committed(.save):
                    throw WorkspaceStoreError.frozen
                }
            } catch {
                _ = await repository.discardPreparedRestore(prepared)
                throw error
            }
        }
    }

    private func normalized(command: WorkspaceCommand) -> WorkspaceCommand {
        guard case let .calendar(.updateItem(item)) = command,
              let current = state.calendar.items[item.id]
        else { return command }
        var latest = item
        latest.completedAt = current.completedAt
        return .calendar(.updateItem(latest))
    }

    private func applyingSessionNoteRevisions(to reduction: WorkspaceReduction) throws -> WorkspaceReduction {
        var candidate = reduction.state
        var draftContext = reduction.draftContext
        for id in reduction.changedNoteIDs {
            guard var note = candidate.notes[id] else { continue }
            let highWatermark = max(
                noteRevisionHighWatermarks[id] ?? 0,
                state.notes[id]?.revision ?? 0
            )
            guard highWatermark < Int64.max else { throw WorkspaceReducerError.revisionOverflow }
            let nextRevision = highWatermark + 1
            guard nextRevision <= candidate.revision else { throw WorkspaceReducerError.revisionOverflow }
            note.revision = nextRevision
            candidate.notes[id] = note
            if let context = draftContext, context.noteID == id {
                draftContext = .init(
                    noteID: note.id,
                    editSessionID: context.editSessionID,
                    draftGeneration: context.draftGeneration,
                    noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(note),
                    persistedNoteRevision: note.revision
                )
            }
        }
        return .init(
            state: candidate,
            changedNoteIDs: reduction.changedNoteIDs,
            draftContext: draftContext,
            seriesOutcome: reduction.seriesOutcome
        )
    }

    private func mergeSessionNoteLedger(with next: WorkspaceState) {
        for (id, note) in next.notes {
            noteRevisionHighWatermarks[id] = max(noteRevisionHighWatermarks[id] ?? 0, note.revision)
        }
    }

    private func rebasedDraftCommand(_ command: WorkspaceCommand) throws -> WorkspaceCommand {
        guard case let .updateNote(submission) = command else { return command }
        let identity = DraftJournalIdentity(noteID: submission.noteID, editSessionID: .editor(submission.editSessionID))
        guard let previous = acceptedDraftGenerations[identity],
              submission.draftGeneration > previous.generation,
              let latest = state.notes[submission.noteID]
        else { return command }
        do {
            let result = try NoteDraftSequenceRebasePlanner.plan(
                previousAccepted: previous.accepted, next: submission, latest: latest
            )
            let rebased = NoteDraftSubmission(
                noteID: submission.noteID,
                editSessionID: submission.editSessionID,
                baseNoteRevision: result.rebasedBase.revision,
                baseNoteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(result.rebasedBase),
                baseSnapshot: result.rebasedBase,
                baseLinkedTaskBlockLinks: submission.baseLinkedTaskBlockLinks,
                draftGeneration: submission.draftGeneration,
                snapshot: result.rebasedSnapshot,
                noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(result.rebasedSnapshot),
                modifiedFields: submission.modifiedFields,
                linkedBlockDeletionDispositions: submission.linkedBlockDeletionDispositions
            )
            return .updateNote(rebased)
        } catch NoteDraftSequenceRebaseError.conflict {
            return command
        }
    }

    private func acceptedDraft(command: WorkspaceCommand, candidate: WorkspaceState) -> AcceptedDraftGeneration? {
        guard case let .updateNote(submission) = command,
              let finalNote = candidate.notes[submission.noteID]
        else { return nil }
        return .init(
            identity: .init(noteID: submission.noteID, editSessionID: .editor(submission.editSessionID)),
            generation: submission.draftGeneration,
            accepted: .init(base: submission.baseSnapshot, accepted: finalNote, modifiedFields: submission.modifiedFields)
        )
    }

    private func remember(_ accepted: AcceptedDraftGeneration?) {
        guard let accepted else { return }
        if let current = acceptedDraftGenerations[accepted.identity], current.generation > accepted.generation { return }
        acceptedDraftGenerations[accepted.identity] = accepted
    }

    private func publish(_ next: WorkspaceState, undoRecord: WorkspaceStoreUndoRecord?) {
        state = next
        for (id, note) in next.notes { noteRevisionHighWatermarks[id] = max(noteRevisionHighWatermarks[id] ?? 0, note.revision) }
        if let undoRecord { undoStack.append(undoRecord); redoStack.removeAll() }
        updateUndoAvailability()
    }

    private func updateUndoAvailability() { canUndo = !undoStack.isEmpty; canRedo = !redoStack.isEmpty }

    private func enqueueTransaction(
        _ operation: @escaping WorkspaceTransactionQueue.Operation
    ) async throws -> WorkspaceTransactionOutcome {
        try await queue.enqueue(operation) { [weak self] in
            guard let self else { return true }
            return self.phase.blocksQueuedDrainAfterFailure
        }
    }

    private func terminateQueuedForExternal(
        reason: WorkspaceExternalSourceChangeReason,
        artifacts: WorkspacePendingCommitArtifacts
    ) {
        queue.terminateQueued { transactionID in
            .externalSourceChanged(
                transactionID: transactionID, reason: reason, journal: .clean, artifacts: artifacts
            )
        }
    }

    private func terminateQueuedForPersistenceBlock(reason: WorkspacePersistenceBlockReason) {
        queue.terminateQueued { transactionID in
            .persistenceBlocked(transactionID: transactionID, reason: reason, journal: .clean)
        }
    }

    private func ensureOrdinaryMutationAllowed() throws {
        switch phase {
        case .ready, .mutating:
            return
        default:
            throw WorkspaceStoreError.frozen
        }
    }
}

private extension WorkspaceStorePhase {
    var isExternalSourceChanged: Bool {
        if case .externalSourceChanged = self { return true }
        return false
    }

    var blocksQueuedDrainAfterFailure: Bool {
        switch self {
        case .ready:
            false
        case .mutating:
            true
        default:
            true
        }
    }

    var allowsExternalReload: Bool {
        switch self {
        case .ready, .needsRelationshipRepair, .opaquePrimaryLoadFailed, .externalSourceChanged:
            true
        case .notLoaded, .loading, .mutating, .parkedCommitUncertain, .parkedJournalCleanup,
             .unreadablePrimaryLoadFailed, .loadFailed:
            false
        }
    }
}
