import Foundation
import WorkspaceDomain

public actor DraftJournalRepository {
    private let fileURL: URL
    private let writer: any AtomicFileWriting

    public init(fileURL: URL, writer: any AtomicFileWriting = FoundationAtomicFileWriter()) {
        self.fileURL = fileURL
        self.writer = writer
    }

    public func current() throws -> DraftJournalEnvelope? {
        try withJournalLock {
            try readValidatedAndMigrateLegacyIfNeededUnlocked()
        }
    }

    public func persist(_ entry: DraftJournalEntry) throws {
        _ = try protect(entry)
    }

    /// Inserts a bare record, or replaces an older generation, while holding
    /// the cross-process lock.  A same-generation retry can reuse the exact
    /// bare record but cannot silently replace its captured snapshot.
    public func protect(_ entry: DraftJournalEntry) throws -> DraftJournalProtectionResult {
        guard isValid(entry) else { throw WorkspacePersistenceError.invalidJournal }
        return try withJournalLock {
            var envelope = try readValidatedAndMigrateLegacyIfNeededUnlocked() ?? emptyEnvelope()
            let identity = DraftJournalIdentity(noteID: entry.noteID, editSessionID: entry.editSessionID)
            if let index = envelope.records.firstIndex(where: { $0.identity == identity }) {
                let current = envelope.records[index]
                if current.entry.draftGeneration > entry.draftGeneration {
                    return .superseded(currentGeneration: current.entry.draftGeneration)
                }
                if current.entry.draftGeneration == entry.draftGeneration {
                    guard current.pendingReceipt == nil,
                          current.savedReceipt == nil,
                          current.recoveryCompletion == nil,
                          sameSubmissionRecord(current.entry, as: entry)
                    else {
                        return .superseded(currentGeneration: current.entry.draftGeneration)
                    }
                    return .protected(recoveryToken(for: current.entry))
                }
                guard current.pendingReceipt == nil,
                      current.savedReceipt == nil,
                      current.recoveryCompletion == nil
                else {
                    return .busy(currentGeneration: current.entry.draftGeneration)
                }
                envelope.records[index] = try makeRecord(entry: entry, pendingReceipt: nil, savedReceipt: nil)
            } else {
                envelope.records.append(try makeRecord(entry: entry, pendingReceipt: nil, savedReceipt: nil))
            }
            try writeUnlocked(envelope)
            return .protected(recoveryToken(for: entry))
        }
    }

    /// Removes only the exact, still-bare record named by a recovery token.
    /// A stale preview is an explicit `.staleOrMissing`, never a write to a
    /// newer generation or another identity.
    @discardableResult
    public func discardRecovery(_ token: DraftRecoveryToken) throws -> DraftJournalExactTransitionResult {
        try withJournalLock {
            var envelope = try requireEnvelopeUnlocked()
            guard let index = envelope.records.firstIndex(where: { recordMatchesBareRecoveryToken($0, token: token) }) else {
                return .staleOrMissing
            }
            envelope.records.remove(at: index)
            try writeUnlocked(envelope)
            return .applied
        }
    }

    /// Claim an exact bare recovery record before attempting its main-file
    /// write. The durable pending marker is the restart boundary for recovery
    /// saves, which intentionally do not masquerade as editor submissions.
    @discardableResult
    public func beginRecoveryCompletion(_ completion: DraftRecoveryCompletion) throws -> DraftJournalExactTransitionResult {
        guard completion.state == .pending else { throw WorkspacePersistenceError.invalidJournal }
        return try withJournalLock {
            var envelope = try requireEnvelopeUnlocked()
            guard let index = envelope.records.firstIndex(where: {
                recordMatchesBareRecoveryToken($0, token: completion.token)
            }) else { return .staleOrMissing }
            envelope.records[index] = try makeRecord(
                entry: envelope.records[index].entry,
                pendingReceipt: nil,
                savedReceipt: nil,
                recoveryCompletion: completion
            )
            try writeUnlocked(envelope)
            return .applied
        }
    }

    /// Persist the post-save state before trying to discard the recovery
    /// marker. Repeating this transition is idempotent.
    @discardableResult
    public func markRecoveryCompletionCommitted(_ completion: DraftRecoveryCompletion) throws -> DraftJournalExactTransitionResult {
        try withJournalLock {
            var envelope = try requireEnvelopeUnlocked()
            guard let index = envelope.records.firstIndex(where: {
                $0.recoveryCompletion?.withState(.pending) == completion.withState(.pending)
            }) else { return .staleOrMissing }
            let current = envelope.records[index]
            guard let stored = current.recoveryCompletion else { return .staleOrMissing }
            if stored.state == .committed { return .applied }
            envelope.records[index] = try makeRecord(
                entry: current.entry,
                pendingReceipt: nil,
                savedReceipt: nil,
                recoveryCompletion: stored.withState(.committed)
            )
            try writeUnlocked(envelope)
            return .applied
        }
    }

    /// Compare-and-discard only the exact committed completion. A bare token
    /// is never allowed to erase a marker for another action or result.
    @discardableResult
    public func discardRecoveryCompletion(_ completion: DraftRecoveryCompletion) throws -> DraftJournalExactTransitionResult {
        try withJournalLock {
            var envelope = try requireEnvelopeUnlocked()
            guard let index = envelope.records.firstIndex(where: {
                $0.recoveryCompletion == completion.withState(.committed)
            }) else { return .staleOrMissing }
            envelope.records.remove(at: index)
            try writeUnlocked(envelope)
            return .applied
        }
    }

    /// A definite non-commit may reopen the original bare record. Once the
    /// marker has reached committed, it is deliberately non-reversible.
    @discardableResult
    public func abandonRecoveryCompletion(_ completion: DraftRecoveryCompletion) throws -> DraftJournalExactTransitionResult {
        try withJournalLock {
            var envelope = try requireEnvelopeUnlocked()
            guard let index = envelope.records.firstIndex(where: {
                $0.recoveryCompletion == completion.withState(.pending)
            }) else { return .staleOrMissing }
            let current = envelope.records[index]
            envelope.records[index] = try makeRecord(
                entry: current.entry,
                pendingReceipt: nil,
                savedReceipt: nil,
                recoveryCompletion: nil
            )
            try writeUnlocked(envelope)
            return .applied
        }
    }

    /// Checks the same exact bare record predicate used by compare-discard.
    /// Store calls this before a recovery save, and `rebaseAndBind(expected:)`
    /// repeats the predicate inside the binding transaction to close races.
    public func isCurrentBare(_ token: DraftRecoveryToken) throws -> Bool {
        try withJournalLock {
            guard let envelope = try readValidatedAndMigrateLegacyIfNeededUnlocked() else { return false }
            return envelope.records.contains { recordMatchesBareRecoveryToken($0, token: token) }
        }
    }

    public func rebaseAndBind(
        expected: DraftJournalIdentityAndGeneration,
        finalCandidateNote: Note,
        receipt: PersistedDraftReceipt
    ) throws -> DraftJournalBindingResult {
        try rebaseAndBind(
            expected: expected,
            exactBareToken: nil,
            finalCandidateNote: finalCandidateNote,
            receipt: receipt
        )
    }

    /// Binds a Store-protected record only when the record is still the exact
    /// bare record named by its recovery token.  This closes the interval
    /// between issuing an in-memory capability and queueing its frozen save.
    public func rebaseAndBind(
        expected: DraftRecoveryToken,
        finalCandidateNote: Note,
        receipt: PersistedDraftReceipt
    ) throws -> DraftJournalBindingResult {
        try rebaseAndBind(
            expected: expected.identityAndGeneration,
            exactBareToken: expected,
            finalCandidateNote: finalCandidateNote,
            receipt: receipt
        )
    }

    private func rebaseAndBind(
        expected: DraftJournalIdentityAndGeneration,
        exactBareToken: DraftRecoveryToken?,
        finalCandidateNote: Note,
        receipt: PersistedDraftReceipt
    ) throws -> DraftJournalBindingResult {
        try withJournalLock {
            var envelope = try requireEnvelopeUnlocked()
            guard receipt.noteID == expected.identity.noteID,
                  receipt.editSessionID == expected.identity.editSessionID,
                  receipt.draftGeneration == expected.draftGeneration,
                  finalCandidateNote.id == expected.identity.noteID,
                  let index = envelope.records.firstIndex(where: { $0.identity == expected.identity })
            else { throw WorkspacePersistenceError.invalidJournal }
            let current = envelope.records[index]
            if current.entry.draftGeneration > expected.draftGeneration {
                return .supersededByNewerDraft
            }
            guard current.entry.draftGeneration == expected.draftGeneration,
                  current.pendingReceipt == nil,
                  current.savedReceipt == nil,
                  current.recoveryCompletion == nil,
                  exactBareToken.map({ token in
                      current.entry.noteSnapshotChecksum == token.noteSnapshotChecksum
                          && current.entry.journalChecksum == token.journalChecksum
                  }) ?? true,
                  receipt.persistedNoteRevision == finalCandidateNote.revision
            else { throw WorkspacePersistenceError.invalidJournal }
            let checksum = try WorkspaceChecksum.noteSnapshotChecksum(finalCandidateNote)
            guard receipt.noteSnapshotChecksum == checksum else { throw WorkspacePersistenceError.invalidJournal }
            let unsigned = DraftJournalEntry(
                noteID: current.entry.noteID,
                editSessionID: current.entry.editSessionID,
                baseWorkspaceRevision: current.entry.baseWorkspaceRevision,
                baseNoteRevision: current.entry.baseNoteRevision,
                draftGeneration: current.entry.draftGeneration,
                noteSnapshot: finalCandidateNote,
                updatedAt: current.entry.updatedAt,
                noteSnapshotChecksum: checksum,
                journalChecksum: ""
            )
            let rebound = DraftJournalEntry(
                noteID: unsigned.noteID,
                editSessionID: unsigned.editSessionID,
                baseWorkspaceRevision: unsigned.baseWorkspaceRevision,
                baseNoteRevision: unsigned.baseNoteRevision,
                draftGeneration: unsigned.draftGeneration,
                noteSnapshot: unsigned.noteSnapshot,
                updatedAt: unsigned.updatedAt,
                noteSnapshotChecksum: unsigned.noteSnapshotChecksum,
                journalChecksum: try DraftJournal.entryChecksum(for: unsigned)
            )
            envelope.records[index] = try makeRecord(entry: rebound, pendingReceipt: receipt, savedReceipt: nil)
            try writeUnlocked(envelope)
            return .bound
        }
    }

    @discardableResult
    public func record(_ receipt: PersistedDraftReceipt) throws -> DraftJournalExactTransitionResult {
        try withJournalLock {
            var envelope = try requireEnvelopeUnlocked()
            let identity = DraftJournalIdentity(noteID: receipt.noteID, editSessionID: receipt.editSessionID)
            guard let index = envelope.records.firstIndex(where: { $0.identity == identity }),
                  envelope.records[index].pendingReceipt == receipt,
                  envelope.records[index].savedReceipt == nil,
                  envelope.records[index].recoveryCompletion == nil
            else { return .staleOrMissing }
            envelope.records[index] = try makeRecord(
                entry: envelope.records[index].entry,
                pendingReceipt: nil,
                savedReceipt: receipt
            )
            try writeUnlocked(envelope)
            return .applied
        }
    }

    @discardableResult
    public func unbindPending(_ receipt: PersistedDraftReceipt) throws -> DraftJournalExactTransitionResult {
        try withJournalLock {
            var envelope = try requireEnvelopeUnlocked()
            let identity = DraftJournalIdentity(noteID: receipt.noteID, editSessionID: receipt.editSessionID)
            guard let index = envelope.records.firstIndex(where: { $0.identity == identity }),
                  envelope.records[index].pendingReceipt == receipt,
                  envelope.records[index].savedReceipt == nil,
                  envelope.records[index].recoveryCompletion == nil
            else { return .staleOrMissing }
            envelope.records[index] = try makeRecord(
                entry: envelope.records[index].entry,
                pendingReceipt: nil,
                savedReceipt: nil
            )
            try writeUnlocked(envelope)
            return .applied
        }
    }

    @discardableResult
    public func acknowledgeAlreadyPersisted(_ receipt: PersistedDraftReceipt) throws -> DraftJournalExactTransitionResult {
        try withJournalLock {
            var envelope = try requireEnvelopeUnlocked()
            let identity = DraftJournalIdentity(noteID: receipt.noteID, editSessionID: receipt.editSessionID)
            guard let index = envelope.records.firstIndex(where: { $0.identity == identity }),
                  envelope.records[index].pendingReceipt == nil,
                  envelope.records[index].savedReceipt == nil,
                  envelope.records[index].recoveryCompletion == nil,
                  isCompatible(receipt, with: envelope.records[index].entry)
            else { return .staleOrMissing }
            envelope.records[index] = try makeRecord(
                entry: envelope.records[index].entry,
                pendingReceipt: nil,
                savedReceipt: receipt
            )
            try writeUnlocked(envelope)
            return .applied
        }
    }

    @discardableResult
    public func clear(_ receipt: PersistedDraftReceipt) throws -> DraftJournalExactTransitionResult {
        try withJournalLock {
            var envelope = try requireEnvelopeUnlocked()
            let identity = DraftJournalIdentity(noteID: receipt.noteID, editSessionID: receipt.editSessionID)
            guard let index = envelope.records.firstIndex(where: { $0.identity == identity }),
                  envelope.records[index].savedReceipt == receipt,
                  envelope.records[index].pendingReceipt == nil,
                  envelope.records[index].recoveryCompletion == nil
            else { return .staleOrMissing }
            envelope.records.remove(at: index)
            try writeUnlocked(envelope)
            return .applied
        }
    }

    private func requireEnvelopeUnlocked() throws -> DraftJournalEnvelope {
        guard let envelope = try readValidatedAndMigrateLegacyIfNeededUnlocked() else {
            throw WorkspacePersistenceError.invalidJournal
        }
        return envelope
    }

    private func emptyEnvelope() -> DraftJournalEnvelope {
        DraftJournalEnvelope(
            schemaVersion: DraftJournalEnvelope.currentSchemaVersion,
            records: [],
            envelopeChecksum: ""
        )
    }

    private func readValidatedAndMigrateLegacyIfNeededUnlocked() throws -> DraftJournalEnvelope? {
        switch noFollowFileProbe(at: fileURL) {
        case .confirmedAbsent:
            return nil
        case .unreadableUnknown:
            throw WorkspacePersistenceError.invalidJournal
        case let .bytes(rawData):
            if let envelope = try? decodeEnvelope(rawData) { return envelope }
            let legacy = try decodeLegacy(rawData)
            let migrated = try legacy.map(migratedEnvelope(from:)) ?? emptyEnvelope()
            try writeUnlocked(migrated)
            return migrated
        }
    }

    private func decodeEnvelope(_ rawData: Data) throws -> DraftJournalEnvelope {
        let envelope: DraftJournalEnvelope
        do {
            envelope = try JSONDecoder.workspaceDeterministic.decode(DraftJournalEnvelope.self, from: rawData)
        } catch {
            throw WorkspacePersistenceError.invalidJournal
        }
        guard envelope.schemaVersion == DraftJournalEnvelope.currentSchemaVersion,
              envelope.records == DraftJournal.canonicalRecords(envelope.records),
              Set(envelope.records.map(\.identity)).count == envelope.records.count,
              envelope.records.allSatisfy(isValid),
              envelope.envelopeChecksum == (try? DraftJournal.envelopeChecksum(records: envelope.records))
        else { throw WorkspacePersistenceError.invalidJournal }
        return envelope
    }

    private func decodeLegacy(_ rawData: Data) throws -> LegacyRecord? {
        let record: LegacyRecord?
        do {
            record = try JSONDecoder.workspaceDeterministic.decode(LegacyRecord?.self, from: rawData)
        } catch {
            throw WorkspacePersistenceError.invalidJournal
        }
        guard let record else { return nil }
        guard record.entry.noteID == record.entry.noteSnapshot.id,
              (try? BlockDocumentValidator.validate(record.entry.noteSnapshot.document)) != nil,
              record.entry.noteSnapshotChecksum
                == (try? WorkspaceChecksum.noteSnapshotChecksum(record.entry.noteSnapshot)),
              record.entry.journalChecksum == (try? legacyEntryChecksum(record.entry)),
              record.recordChecksum == (try? legacyRecordChecksum(record)),
              record.pendingReceipt.map({ isCompatible($0, with: record.entry) }) ?? true,
              record.savedReceipt.map({ isCompatible($0, with: record.entry) }) ?? true,
              !(record.pendingReceipt != nil && record.savedReceipt != nil)
        else { throw WorkspacePersistenceError.invalidJournal }
        return record
    }

    private func migratedEnvelope(from legacy: LegacyRecord) throws -> DraftJournalEnvelope {
        let unsigned = DraftJournalEntry(
            noteID: legacy.entry.noteID,
            editSessionID: .legacyTask5,
            baseWorkspaceRevision: legacy.entry.baseWorkspaceRevision,
            baseNoteRevision: legacy.entry.baseNoteRevision,
            draftGeneration: legacy.entry.draftGeneration,
            noteSnapshot: legacy.entry.noteSnapshot,
            updatedAt: legacy.entry.updatedAt,
            noteSnapshotChecksum: legacy.entry.noteSnapshotChecksum,
            journalChecksum: ""
        )
        let entry = DraftJournalEntry(
            noteID: unsigned.noteID,
            editSessionID: unsigned.editSessionID,
            baseWorkspaceRevision: unsigned.baseWorkspaceRevision,
            baseNoteRevision: unsigned.baseNoteRevision,
            draftGeneration: unsigned.draftGeneration,
            noteSnapshot: unsigned.noteSnapshot,
            updatedAt: unsigned.updatedAt,
            noteSnapshotChecksum: unsigned.noteSnapshotChecksum,
            journalChecksum: try DraftJournal.entryChecksum(for: unsigned)
        )
        let pending = legacy.pendingReceipt.map { receipt in
            PersistedDraftReceipt(
                noteID: receipt.noteID,
                editSessionID: .legacyTask5,
                draftGeneration: receipt.draftGeneration,
                noteSnapshotChecksum: receipt.noteSnapshotChecksum,
                persistedNoteRevision: receipt.persistedNoteRevision
            )
        }
        let saved = legacy.savedReceipt.map { receipt in
            PersistedDraftReceipt(
                noteID: receipt.noteID,
                editSessionID: .legacyTask5,
                draftGeneration: receipt.draftGeneration,
                noteSnapshotChecksum: receipt.noteSnapshotChecksum,
                persistedNoteRevision: receipt.persistedNoteRevision
            )
        }
        let record = try makeRecord(entry: entry, pendingReceipt: pending, savedReceipt: saved)
        let records = DraftJournal.canonicalRecords([record])
        return DraftJournalEnvelope(
            schemaVersion: DraftJournalEnvelope.currentSchemaVersion,
            records: records,
            envelopeChecksum: try DraftJournal.envelopeChecksum(records: records)
        )
    }

    private func writeUnlocked(_ envelope: DraftJournalEnvelope) throws {
        let records = DraftJournal.canonicalRecords(envelope.records)
        let normalized = DraftJournalEnvelope(
            schemaVersion: DraftJournalEnvelope.currentSchemaVersion,
            records: records,
            envelopeChecksum: try DraftJournal.envelopeChecksum(records: records)
        )
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try writer.replaceAtomically(
                data: WorkspaceDocumentCodec.canonicalPersistentData(normalized),
                at: fileURL
            )
        } catch {
            throw WorkspacePersistenceError.atomicWriteFailed
        }
    }

    private func withJournalLock<Result>(_ body: () throws -> Result) throws -> Result {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return try withJellyAdvisoryLock(for: fileURL, body)
        } catch let error as WorkspacePersistenceError {
            throw error
        } catch {
            throw WorkspacePersistenceError.invalidJournal
        }
    }

    private func makeRecord(
        entry: DraftJournalEntry,
        pendingReceipt: PersistedDraftReceipt?,
        savedReceipt: PersistedDraftReceipt?,
        recoveryCompletion: DraftRecoveryCompletion? = nil
    ) throws -> StoredDraftJournalRecord {
        StoredDraftJournalRecord(
            entry: entry,
            pendingReceipt: pendingReceipt,
            savedReceipt: savedReceipt,
            recoveryCompletion: recoveryCompletion,
            recordChecksum: try DraftJournal.recordChecksum(
                entry: entry,
                pendingReceipt: pendingReceipt,
                savedReceipt: savedReceipt,
                recoveryCompletion: recoveryCompletion
            )
        )
    }

    private func isValid(_ record: StoredDraftJournalRecord) -> Bool {
        isValid(record.entry)
            && record.recordChecksum == (try? DraftJournal.recordChecksum(
                entry: record.entry,
                pendingReceipt: record.pendingReceipt,
                savedReceipt: record.savedReceipt,
                recoveryCompletion: record.recoveryCompletion
            ))
            && record.pendingReceipt.map({ isCompatible($0, with: record.entry) }) ?? true
            && record.savedReceipt.map({ isCompatible($0, with: record.entry) }) ?? true
            && record.recoveryCompletion.map({ isValidRecoveryCompletion($0, for: record.entry) }) ?? true
            && !(record.pendingReceipt != nil && record.savedReceipt != nil)
            && (record.recoveryCompletion == nil || (record.pendingReceipt == nil && record.savedReceipt == nil))
    }

    private func isValid(_ entry: DraftJournalEntry) -> Bool {
        entry.noteID == entry.noteSnapshot.id
            && (try? BlockDocumentValidator.validate(entry.noteSnapshot.document)) != nil
            && entry.noteSnapshotChecksum == (try? WorkspaceChecksum.noteSnapshotChecksum(entry.noteSnapshot))
            && entry.journalChecksum == (try? DraftJournal.entryChecksum(for: entry))
    }

    private nonisolated func recoveryToken(for entry: DraftJournalEntry) -> DraftRecoveryToken {
        .init(
            identityAndGeneration: .init(
                identity: .init(noteID: entry.noteID, editSessionID: entry.editSessionID),
                draftGeneration: entry.draftGeneration
            ),
            noteSnapshotChecksum: entry.noteSnapshotChecksum,
            journalChecksum: entry.journalChecksum
        )
    }

    private nonisolated func sameSubmissionRecord(
        _ current: DraftJournalEntry,
        as submitted: DraftJournalEntry
    ) -> Bool {
        current.noteID == submitted.noteID
            && current.editSessionID == submitted.editSessionID
            && current.baseWorkspaceRevision == submitted.baseWorkspaceRevision
            && current.baseNoteRevision == submitted.baseNoteRevision
            && current.draftGeneration == submitted.draftGeneration
            // A definite not-committed result unbinds the final reducer
            // candidate, whose revision/timestamps differ from the original
            // captured submission.  The retry is still the same draft when
            // its user-visible content is identical; token issuance must use
            // the exact current record rather than replacing it.
            && current.noteSnapshot.id == submitted.noteSnapshot.id
            && current.noteSnapshot.title == submitted.noteSnapshot.title
            && current.noteSnapshot.document == submitted.noteSnapshot.document
            && current.noteSnapshot.categoryID == submitted.noteSnapshot.categoryID
            && current.noteSnapshot.archivedAt == submitted.noteSnapshot.archivedAt
    }

    private nonisolated func recordMatchesBareRecoveryToken(
        _ record: StoredDraftJournalRecord,
        token: DraftRecoveryToken
    ) -> Bool {
        record.identity == token.identityAndGeneration.identity
            && record.entry.draftGeneration == token.identityAndGeneration.draftGeneration
            && record.entry.noteSnapshotChecksum == token.noteSnapshotChecksum
            && record.entry.journalChecksum == token.journalChecksum
            && record.pendingReceipt == nil
            && record.savedReceipt == nil
            && record.recoveryCompletion == nil
    }

    private nonisolated func isValidRecoveryCompletion(
        _ completion: DraftRecoveryCompletion,
        for entry: DraftJournalEntry
    ) -> Bool {
        completion.token.identityAndGeneration.identity == .init(noteID: entry.noteID, editSessionID: entry.editSessionID)
            && completion.token.identityAndGeneration.draftGeneration == entry.draftGeneration
            && completion.token.noteSnapshotChecksum == entry.noteSnapshotChecksum
            && completion.token.journalChecksum == entry.journalChecksum
            && completion.source.workspaceRevision >= 0
            && !completion.source.workspaceChecksum.isEmpty
            && completion.result.noteRevision >= 0
            && completion.result.workspaceRevision >= 0
    }

    private nonisolated func isCompatible(
        _ receipt: PersistedDraftReceipt,
        with entry: DraftJournalEntry
    ) -> Bool {
        receipt.noteID == entry.noteID
            && receipt.editSessionID == entry.editSessionID
            && receipt.draftGeneration == entry.draftGeneration
            && receipt.noteSnapshotChecksum == entry.noteSnapshotChecksum
            && receipt.persistedNoteRevision > entry.baseNoteRevision
    }

    private nonisolated func isCompatible(
        _ receipt: LegacyReceipt,
        with entry: LegacyEntry
    ) -> Bool {
        receipt.noteID == entry.noteID
            && receipt.draftGeneration == entry.draftGeneration
            && receipt.noteSnapshotChecksum == entry.noteSnapshotChecksum
            && receipt.persistedNoteRevision > entry.baseNoteRevision
    }

    private struct LegacyEntry: Codable {
        let noteID: NoteID
        let baseWorkspaceRevision: Int64
        let baseNoteRevision: Int64
        let draftGeneration: UInt64
        let noteSnapshot: Note
        let updatedAt: Date
        let noteSnapshotChecksum: String
        let journalChecksum: String
    }

    private struct LegacyReceipt: Codable {
        let noteID: NoteID
        let draftGeneration: UInt64
        let noteSnapshotChecksum: String
        let persistedNoteRevision: Int64
    }

    private struct LegacyRecord: Codable {
        let entry: LegacyEntry
        let pendingReceipt: LegacyReceipt?
        let savedReceipt: LegacyReceipt?
        let recordChecksum: String
    }

    private struct LegacyEntryChecksumInput: Codable {
        let noteID: NoteID
        let baseWorkspaceRevision: Int64
        let baseNoteRevision: Int64
        let draftGeneration: UInt64
        let noteSnapshot: Note
        let updatedAt: Date
        let noteSnapshotChecksum: String

        init(_ entry: LegacyEntry) {
            noteID = entry.noteID
            baseWorkspaceRevision = entry.baseWorkspaceRevision
            baseNoteRevision = entry.baseNoteRevision
            draftGeneration = entry.draftGeneration
            noteSnapshot = entry.noteSnapshot
            updatedAt = entry.updatedAt
            noteSnapshotChecksum = entry.noteSnapshotChecksum
        }
    }

    private struct LegacyRecordChecksumInput: Codable {
        let entry: LegacyEntry
        let pendingReceipt: LegacyReceipt?
        let savedReceipt: LegacyReceipt?

        init(_ record: LegacyRecord) {
            entry = record.entry
            pendingReceipt = record.pendingReceipt
            savedReceipt = record.savedReceipt
        }
    }

    private nonisolated func legacyEntryChecksum(_ entry: LegacyEntry) throws -> String {
        try persistenceSHA256(WorkspaceDocumentCodec.canonicalPersistentData(LegacyEntryChecksumInput(entry)))
    }

    private nonisolated func legacyRecordChecksum(_ record: LegacyRecord) throws -> String {
        try persistenceSHA256(WorkspaceDocumentCodec.canonicalPersistentData(LegacyRecordChecksumInput(record)))
    }
}
