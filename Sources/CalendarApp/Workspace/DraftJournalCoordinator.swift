import CalendarPersistence
import Foundation
import WorkspaceDomain

enum JournalCleanupStep: Equatable, Sendable {
    case record, acknowledge, unbind, clear
    case discardRecovery(DraftRecoveryToken)
    case markRecoveryCompletion(DraftRecoveryCompletion)
    case discardRecoveryCompletion(DraftRecoveryCompletion)
    case abandonRecoveryCompletion(DraftRecoveryCompletion)
}
enum JournalResolutionStatus: Equatable, Sendable { case clean, cleanupPending(identity: DraftJournalIdentity, step: JournalCleanupStep) }
enum DraftRecoveryJournalResolution: Equatable, Sendable {
    case clean
    case staleOrMissing
    case cleanupPending(identity: DraftJournalIdentity, step: JournalCleanupStep)

    var journalStatus: JournalResolutionStatus {
        switch self {
        case .clean, .staleOrMissing: .clean
        case let .cleanupPending(identity, step): .cleanupPending(identity: identity, step: step)
        }
    }
}

@MainActor
enum DraftJournalCoordinator {
    static func entry(submission: NoteDraftSubmission, workspaceRevision: Int64, clock: @Sendable () -> Date) throws -> DraftJournalEntry {
        let timestamp = clock()
        let session = DraftJournalSessionID.editor(submission.editSessionID)
        let unsigned = DraftJournalEntry(
            noteID: submission.noteID, editSessionID: session, baseWorkspaceRevision: workspaceRevision,
            baseNoteRevision: submission.baseNoteRevision, draftGeneration: submission.draftGeneration,
            noteSnapshot: submission.snapshot, updatedAt: timestamp,
            noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(submission.snapshot), journalChecksum: ""
        )
        return .init(
            noteID: unsigned.noteID, editSessionID: unsigned.editSessionID,
            baseWorkspaceRevision: unsigned.baseWorkspaceRevision, baseNoteRevision: unsigned.baseNoteRevision,
            draftGeneration: unsigned.draftGeneration, noteSnapshot: unsigned.noteSnapshot,
            updatedAt: unsigned.updatedAt, noteSnapshotChecksum: unsigned.noteSnapshotChecksum,
            journalChecksum: try DraftJournal.entryChecksum(for: unsigned)
        )
    }

    static func recordAndClear(
        _ receipt: PersistedDraftReceipt,
        journal: DraftJournalRepository
    ) async -> DraftRecoveryJournalResolution {
        do {
            switch try await journal.record(receipt) {
            case .applied: break
            case .staleOrMissing: return .staleOrMissing
            }
        } catch {
            return .cleanupPending(identity: .init(noteID: receipt.noteID, editSessionID: receipt.editSessionID), step: .record)
        }
        do {
            switch try await journal.clear(receipt) {
            case .applied: return .clean
            case .staleOrMissing: return .staleOrMissing
            }
        } catch {
            return .cleanupPending(identity: .init(noteID: receipt.noteID, editSessionID: receipt.editSessionID), step: .clear)
        }
    }

    static func acknowledgeAndClear(
        _ receipt: PersistedDraftReceipt,
        journal: DraftJournalRepository
    ) async -> DraftRecoveryJournalResolution {
        do {
            switch try await journal.acknowledgeAlreadyPersisted(receipt) {
            case .applied: break
            case .staleOrMissing: return .staleOrMissing
            }
        } catch {
            return .cleanupPending(identity: .init(noteID: receipt.noteID, editSessionID: receipt.editSessionID), step: .acknowledge)
        }
        do {
            switch try await journal.clear(receipt) {
            case .applied: return .clean
            case .staleOrMissing: return .staleOrMissing
            }
        } catch {
            return .cleanupPending(identity: .init(noteID: receipt.noteID, editSessionID: receipt.editSessionID), step: .clear)
        }
    }

    static func discardRecovery(
        _ token: DraftRecoveryToken,
        journal: DraftJournalRepository
    ) async -> DraftRecoveryJournalResolution {
        do {
            switch try await journal.discardRecovery(token) {
            case .applied:
                return .clean
            case .staleOrMissing:
                return .staleOrMissing
            }
        } catch {
            return .cleanupPending(
                identity: token.identityAndGeneration.identity,
                step: .discardRecovery(token)
            )
        }
    }

    /// Main state has committed. Persist that fact first, then discard only
    /// the exact completion marker. Either write may be retried independently.
    static func completeRecovery(
        _ completion: DraftRecoveryCompletion,
        journal: DraftJournalRepository
    ) async -> DraftRecoveryJournalResolution {
        do {
            switch try await journal.markRecoveryCompletionCommitted(completion) {
            case .applied: break
            case .staleOrMissing: return .staleOrMissing
            }
        } catch {
            return .cleanupPending(
                identity: completion.token.identityAndGeneration.identity,
                step: .markRecoveryCompletion(completion)
            )
        }
        do {
            switch try await journal.discardRecoveryCompletion(completion) {
            case .applied: return .clean
            case .staleOrMissing: return .staleOrMissing
            }
        } catch {
            return .cleanupPending(
                identity: completion.token.identityAndGeneration.identity,
                step: .discardRecoveryCompletion(completion)
            )
        }
    }

    /// A repository-confirmed non-commit reopens the exact original record;
    /// failure stays read-only because the next process must reconcile it.
    static func abandonRecovery(
        _ completion: DraftRecoveryCompletion,
        journal: DraftJournalRepository
    ) async -> DraftRecoveryJournalResolution {
        do {
            switch try await journal.abandonRecoveryCompletion(completion) {
            case .applied: return .clean
            case .staleOrMissing: return .staleOrMissing
            }
        } catch {
            return .cleanupPending(
                identity: completion.token.identityAndGeneration.identity,
                step: .abandonRecoveryCompletion(completion)
            )
        }
    }

    static func retryCleanup(
        _ identity: DraftJournalIdentity,
        step: JournalCleanupStep,
        receipt: PersistedDraftReceipt?,
        journal: DraftJournalRepository
    ) async -> DraftRecoveryJournalResolution {
        do {
            guard let record = try await journal.current()?.records.first(where: { $0.identity == identity }) else {
                return .staleOrMissing
            }
            switch step {
            case .record:
                guard let pending = record.pendingReceipt ?? receipt else {
                    return .staleOrMissing
                }
                return await recordAndClear(pending, journal: journal)
            case .acknowledge:
                guard let receipt else { return .staleOrMissing }
                return await acknowledgeAndClear(receipt, journal: journal)
            case .unbind:
                guard let receipt else { return .staleOrMissing }
                do {
                    switch try await journal.unbindPending(receipt) {
                    case .applied: return .clean
                    case .staleOrMissing: return .staleOrMissing
                    }
                } catch { return .cleanupPending(identity: identity, step: .unbind) }
            case .clear:
                guard let saved = record.savedReceipt ?? receipt else {
                    return .staleOrMissing
                }
                do {
                    switch try await journal.clear(saved) {
                    case .applied: return .clean
                    case .staleOrMissing: return .staleOrMissing
                    }
                } catch { return .cleanupPending(identity: identity, step: .clear) }
            case let .discardRecovery(token):
                guard token.identityAndGeneration.identity == identity else {
                    return .cleanupPending(identity: identity, step: step)
                }
                return await discardRecovery(token, journal: journal)
            case let .markRecoveryCompletion(completion):
                guard completion.token.identityAndGeneration.identity == identity else {
                    return .cleanupPending(identity: identity, step: step)
                }
                return await completeRecovery(completion, journal: journal)
            case let .discardRecoveryCompletion(completion):
                guard completion.token.identityAndGeneration.identity == identity else {
                    return .cleanupPending(identity: identity, step: step)
                }
                do {
                    switch try await journal.discardRecoveryCompletion(completion) {
                    case .applied: return .clean
                    case .staleOrMissing: return .staleOrMissing
                    }
                } catch { return .cleanupPending(identity: identity, step: step) }
            case let .abandonRecoveryCompletion(completion):
                guard completion.token.identityAndGeneration.identity == identity else {
                    return .cleanupPending(identity: identity, step: step)
                }
                return await abandonRecovery(completion, journal: journal)
            }
        } catch { return .cleanupPending(identity: identity, step: step) }
    }
}
