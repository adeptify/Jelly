import CalendarPersistence
import Foundation
import WorkspaceDomain

enum JournalCleanupStep: Equatable, Sendable { case record, acknowledge, unbind, clear }
enum JournalResolutionStatus: Equatable, Sendable { case clean, cleanupPending(identity: DraftJournalIdentity, step: JournalCleanupStep) }

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
    ) async -> JournalResolutionStatus {
        do {
            guard try await journal.record(receipt) else {
                if let newer = try await journal.current()?.records.first(where: {
                    $0.identity == .init(noteID: receipt.noteID, editSessionID: receipt.editSessionID)
                        && $0.entry.draftGeneration > receipt.draftGeneration
                }), newer.entry.draftGeneration > receipt.draftGeneration {
                    return .clean
                }
                return .cleanupPending(identity: .init(noteID: receipt.noteID, editSessionID: receipt.editSessionID), step: .record)
            }
        } catch {
            return .cleanupPending(identity: .init(noteID: receipt.noteID, editSessionID: receipt.editSessionID), step: .record)
        }
        do {
            guard try await journal.clear(receipt) else {
                return .cleanupPending(identity: .init(noteID: receipt.noteID, editSessionID: receipt.editSessionID), step: .clear)
            }
            return .clean
        } catch {
            return .cleanupPending(identity: .init(noteID: receipt.noteID, editSessionID: receipt.editSessionID), step: .clear)
        }
    }

    static func acknowledgeAndClear(
        _ receipt: PersistedDraftReceipt,
        journal: DraftJournalRepository
    ) async -> JournalResolutionStatus {
        do {
            guard try await journal.acknowledgeAlreadyPersisted(receipt) else {
                return .cleanupPending(identity: .init(noteID: receipt.noteID, editSessionID: receipt.editSessionID), step: .acknowledge)
            }
        } catch {
            return .cleanupPending(identity: .init(noteID: receipt.noteID, editSessionID: receipt.editSessionID), step: .acknowledge)
        }
        do {
            guard try await journal.clear(receipt) else {
                return .cleanupPending(identity: .init(noteID: receipt.noteID, editSessionID: receipt.editSessionID), step: .clear)
            }
            return .clean
        } catch {
            return .cleanupPending(identity: .init(noteID: receipt.noteID, editSessionID: receipt.editSessionID), step: .clear)
        }
    }

    static func retryCleanup(
        _ identity: DraftJournalIdentity,
        step: JournalCleanupStep,
        receipt: PersistedDraftReceipt?,
        journal: DraftJournalRepository
    ) async -> JournalResolutionStatus {
        do {
            guard let record = try await journal.current()?.records.first(where: { $0.identity == identity }) else { return .clean }
            switch step {
            case .record:
                guard let pending = record.pendingReceipt ?? receipt else {
                    return .cleanupPending(identity: identity, step: .record)
                }
                return await recordAndClear(pending, journal: journal)
            case .acknowledge:
                guard let receipt else { return .cleanupPending(identity: identity, step: .acknowledge) }
                return await acknowledgeAndClear(receipt, journal: journal)
            case .unbind:
                guard let receipt else { return .cleanupPending(identity: identity, step: .unbind) }
                do {
                    return try await journal.unbindPending(receipt)
                        ? .clean
                        : .cleanupPending(identity: identity, step: .unbind)
                } catch { return .cleanupPending(identity: identity, step: .unbind) }
            case .clear:
                guard let saved = record.savedReceipt ?? receipt else {
                    return .cleanupPending(identity: identity, step: .clear)
                }
                do {
                    return try await journal.clear(saved)
                        ? .clean
                        : .cleanupPending(identity: identity, step: .clear)
                } catch { return .cleanupPending(identity: identity, step: .clear) }
            }
        } catch { return .cleanupPending(identity: identity, step: step) }
    }
}
