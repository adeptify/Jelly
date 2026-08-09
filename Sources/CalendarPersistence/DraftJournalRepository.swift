import Foundation
import WorkspaceDomain

public actor DraftJournalRepository {
    private let fileURL: URL
    private let writer: any AtomicFileWriting

    public init(fileURL: URL, writer: any AtomicFileWriting = FoundationAtomicFileWriter()) {
        self.fileURL = fileURL
        self.writer = writer
    }

    public func current() throws -> StoredDraftJournalRecord? {
        try readValidated()
    }

    public func persist(_ entry: DraftJournalEntry) throws {
        guard entry.noteID == entry.noteSnapshot.id,
              entry.noteSnapshotChecksum == (try? WorkspaceChecksum.noteSnapshotChecksum(entry.noteSnapshot)),
              entry.journalChecksum == (try? DraftJournal.entryChecksum(for: entry))
        else { throw WorkspacePersistenceError.invalidJournal }
        if let current = try readValidated(), current.entry.draftGeneration > entry.draftGeneration {
            return
        }
        try write(entry: entry, pendingReceipt: nil, savedReceipt: nil)
    }

    @discardableResult
    public func bindPending(_ receipt: PersistedDraftReceipt) throws -> Bool {
        guard let current = try readValidated(),
              current.savedReceipt == nil,
              current.pendingReceipt == nil,
              isCompatible(receipt, with: current.entry)
        else { return false }
        try write(entry: current.entry, pendingReceipt: receipt, savedReceipt: nil)
        return true
    }

    @discardableResult
    public func record(_ receipt: PersistedDraftReceipt) throws -> Bool {
        guard let current = try readValidated(), current.pendingReceipt == receipt else { return false }
        try write(entry: current.entry, pendingReceipt: nil, savedReceipt: receipt)
        return true
    }

    @discardableResult
    public func clear(ifMatching receipt: PersistedDraftReceipt) throws -> Bool {
        guard let current = try readValidated(),
              current.savedReceipt == receipt
        else { return false }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try writer.replaceAtomically(data: Data("null".utf8), at: fileURL)
        } catch {
            throw WorkspacePersistenceError.atomicWriteFailed
        }
        return true
    }

    private func readValidated() throws -> StoredDraftJournalRecord? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let decoded: StoredDraftJournalRecord?
        do {
            decoded = try JSONDecoder.workspaceDeterministic.decode(
                StoredDraftJournalRecord?.self,
                from: Data(contentsOf: fileURL)
            )
        } catch {
            throw WorkspacePersistenceError.invalidJournal
        }
        guard let decoded else { return nil }
        guard decoded.entry.noteID == decoded.entry.noteSnapshot.id,
              decoded.entry.noteSnapshotChecksum
                == (try? WorkspaceChecksum.noteSnapshotChecksum(decoded.entry.noteSnapshot)),
              decoded.entry.journalChecksum == (try? DraftJournal.entryChecksum(for: decoded.entry)),
              decoded.recordChecksum == (try? DraftJournal.recordChecksum(
                entry: decoded.entry,
                pendingReceipt: decoded.pendingReceipt,
                savedReceipt: decoded.savedReceipt
              )),
              decoded.pendingReceipt.map({ isCompatible($0, with: decoded.entry) }) ?? true,
              decoded.savedReceipt.map({ isCompatible($0, with: decoded.entry) }) ?? true,
              !(decoded.pendingReceipt != nil && decoded.savedReceipt != nil)
        else { throw WorkspacePersistenceError.invalidJournal }
        return decoded
    }

    private func write(
        entry: DraftJournalEntry,
        pendingReceipt: PersistedDraftReceipt?,
        savedReceipt: PersistedDraftReceipt?
    ) throws {
        let record = StoredDraftJournalRecord(
            entry: entry,
            pendingReceipt: pendingReceipt,
            savedReceipt: savedReceipt,
            recordChecksum: try DraftJournal.recordChecksum(
                entry: entry,
                pendingReceipt: pendingReceipt,
                savedReceipt: savedReceipt
            )
        )
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try writer.replaceAtomically(
                data: WorkspaceDocumentCodec.canonicalPersistentData(record),
                at: fileURL
            )
        } catch {
            throw WorkspacePersistenceError.atomicWriteFailed
        }
    }

    private nonisolated func isCompatible(
        _ receipt: PersistedDraftReceipt,
        with entry: DraftJournalEntry
    ) -> Bool {
        receipt.noteID == entry.noteID
            && receipt.draftGeneration == entry.draftGeneration
            && receipt.noteSnapshotChecksum == entry.noteSnapshotChecksum
            && receipt.persistedNoteRevision > entry.baseNoteRevision
    }
}
