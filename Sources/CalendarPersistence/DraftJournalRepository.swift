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
        try write(entry: entry, receipt: nil)
    }

    public func record(_ receipt: PersistedDraftReceipt) throws {
        guard let current = try readValidated(), matches(receipt, entry: current.entry) else { return }
        if let existing = current.savedReceipt, existing != receipt { return }
        try write(entry: current.entry, receipt: receipt)
    }

    public func clear(ifMatching receipt: PersistedDraftReceipt) throws {
        guard let current = try readValidated(),
              current.savedReceipt == receipt,
              matches(receipt, entry: current.entry)
        else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try writer.replaceAtomically(data: Data("null".utf8), at: fileURL)
        } catch {
            throw WorkspacePersistenceError.atomicWriteFailed
        }
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
                receipt: decoded.savedReceipt
              )),
              decoded.savedReceipt.map({ matches($0, entry: decoded.entry) }) ?? true
        else { throw WorkspacePersistenceError.invalidJournal }
        return decoded
    }

    private func write(entry: DraftJournalEntry, receipt: PersistedDraftReceipt?) throws {
        let record = StoredDraftJournalRecord(
            entry: entry,
            savedReceipt: receipt,
            recordChecksum: try DraftJournal.recordChecksum(entry: entry, receipt: receipt)
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

    private nonisolated func matches(_ receipt: PersistedDraftReceipt, entry: DraftJournalEntry) -> Bool {
        receipt.noteID == entry.noteID
            && receipt.draftGeneration == entry.draftGeneration
            && receipt.noteSnapshotChecksum == entry.noteSnapshotChecksum
            && receipt.persistedNoteRevision == entry.noteSnapshot.revision
    }
}
