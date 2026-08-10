import Foundation
import Testing
@testable import CalendarPersistence
@testable import WorkspaceDomain

@Suite("DraftJournalRecoveryRepositoryTests")
struct DraftJournalRecoveryRepositoryTests {
    @Test func higherGenerationProtectCannotReplaceAnyOccupiedRecordAcrossActorAndProcessBoundary() async throws {
        let note = try #require(WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 4).notes.values.first)

        for state in OccupiedJournalState.allCases {
            let directory = try WorkspacePersistenceTemporaryDirectory()
            defer { directory.remove() }
            let payloadURL = directory.file("payload-\(state.rawValue).json")
            let targetURL = directory.file("target-\(state.rawValue).json")
            let signalURL = directory.file("locked-\(state.rawValue)")
            let session = DraftJournalSessionID.editor(UUID())
            let peer = DraftJournalRepository(fileURL: payloadURL)
            let entry = try recoveryEntry(note: note, session: session, generation: 1)
            let token: DraftRecoveryToken
            switch try await peer.protect(entry) {
            case let .protected(value): token = value
            case .superseded, .busy: Issue.record("The fixture must begin with a bare record"); return
            }
            let receipt = PersistedDraftReceipt(
                noteID: note.id,
                editSessionID: session,
                draftGeneration: 1,
                noteSnapshotChecksum: entry.noteSnapshotChecksum,
                persistedNoteRevision: note.revision
            )
            let completion = recoveryCompletion(token: token, note: note)
            switch state {
            case .pendingReceipt:
                #expect(try await peer.rebaseAndBind(
                    expected: token,
                    finalCandidateNote: note,
                    receipt: receipt
                ) == .bound)
            case .savedReceipt:
                #expect(try await peer.acknowledgeAlreadyPersisted(receipt) == .applied)
            case .recoveryPending:
                #expect(try await peer.beginRecoveryCompletion(completion) == .applied)
            case .recoveryCommitted:
                #expect(try await peer.beginRecoveryCompletion(completion) == .applied)
                #expect(try await peer.markRecoveryCompletionCommitted(completion) == .applied)
            }
            let occupiedBytes = try Data(contentsOf: payloadURL)
            let process = try launchLockedJournalCopy(
                payloadURL: payloadURL,
                targetURL: targetURL,
                signalURL: signalURL
            )
            #expect(waitForRecoveryJournalFile(signalURL))

            var newer = note
            newer.title = "must not overwrite \(state.rawValue)"
            let result = try await DraftJournalRepository(fileURL: targetURL).protect(
                try recoveryEntry(note: newer, session: session, generation: 2)
            )

            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            #expect(result == .busy(currentGeneration: 1))
            #expect(try Data(contentsOf: targetURL) == occupiedBytes)
            let current = try #require(try await DraftJournalRepository(fileURL: targetURL).current()?.records.first)
            #expect(current.entry.draftGeneration == 1)
            switch state {
            case .pendingReceipt: #expect(current.pendingReceipt == receipt)
            case .savedReceipt: #expect(current.savedReceipt == receipt)
            case .recoveryPending: #expect(current.recoveryCompletion == completion)
            case .recoveryCommitted: #expect(current.recoveryCompletion == completion.withState(.committed))
            }
        }
    }

    @Test func protectSupersedesAnOlderCapabilityAndOnlyTheExactTokenCanDiscard() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let note = try #require(WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 4).notes.values.first)
        let session = DraftJournalSessionID.editor(UUID(uuidString: "00000000-0000-0000-0000-00000000D10A")!)
        let journal = DraftJournalRepository(fileURL: directory.file("draft-journal.json"))

        let first = try recoveryEntry(note: note, session: session, generation: 1)
        let firstToken: DraftRecoveryToken
        switch try await journal.protect(first) {
        case let .protected(token): firstToken = token
        case .superseded, .busy: Issue.record("Initial journal generation must be protected"); return
        }

        var updated = note
        updated.title = "new generation"
        let second = try recoveryEntry(note: updated, session: session, generation: 2)
        let secondToken: DraftRecoveryToken
        switch try await journal.protect(second) {
        case let .protected(token): secondToken = token
        case .superseded, .busy: Issue.record("Newer generation must supersede the old record"); return
        }

        #expect(try await journal.discardRecovery(firstToken) == .staleOrMissing)
        #expect(try await journal.discardRecovery(secondToken) == .applied)
        #expect(try await journal.current()?.records.isEmpty == true)
    }

    @Test func recoveryCompletionIsExactAcrossPendingCommittedDiscardAndAbandonTransitions() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let note = try #require(WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 4).notes.values.first)
        let session = DraftJournalSessionID.editor(UUID())
        let journal = DraftJournalRepository(fileURL: directory.file("draft-journal.json"))
        let entry = try recoveryEntry(note: note, session: session, generation: 1)
        let token: DraftRecoveryToken
        switch try await journal.protect(entry) {
        case let .protected(value): token = value
        case .superseded, .busy: Issue.record("The fixture must create an exact bare token"); return
        }
        let completion = DraftRecoveryCompletion(
            token: token,
            action: .restoreAsCurrent,
            source: .init(workspaceRevision: 4, workspaceChecksum: "exact-pre-save-source"),
            result: .init(
                noteID: note.id,
                noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(note),
                noteRevision: 5,
                workspaceRevision: 5
            ),
            state: .pending
        )
        #expect(try await journal.beginRecoveryCompletion(completion) == .applied)
        #expect(try await journal.discardRecoveryCompletion(completion) == .staleOrMissing)
        #expect(try await journal.abandonRecoveryCompletion(completion) == .applied)
        #expect(try await journal.isCurrentBare(token))
        #expect(try await journal.beginRecoveryCompletion(completion) == .applied)
        #expect(try await journal.markRecoveryCompletionCommitted(completion) == .applied)
        #expect(try await journal.abandonRecoveryCompletion(completion) == .staleOrMissing)
        #expect(try await journal.discardRecoveryCompletion(completion) == .applied)
        #expect(try await journal.current()?.records.isEmpty == true)
    }

    @Test func failedRecoveryCompletionWritePreservesExactRawJournalBytes() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let writer = RecoveryCompletionFailingWriter()
        let file = directory.file("draft-journal.json")
        let journal = DraftJournalRepository(fileURL: file, writer: writer)
        let note = try #require(WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 4).notes.values.first)
        let entry = try recoveryEntry(note: note, session: .editor(UUID()), generation: 1)
        let token: DraftRecoveryToken
        switch try await journal.protect(entry) {
        case let .protected(value): token = value
        case .superseded, .busy: Issue.record("The fixture must create a bare token"); return
        }
        let rawBefore = try Data(contentsOf: file)
        let completion = DraftRecoveryCompletion(
            token: token,
            action: .saveAsNew,
            source: .init(workspaceRevision: 4, workspaceChecksum: "pre-save-source"),
            result: .init(
                noteID: NoteID(UUID()), noteSnapshotChecksum: "result", noteRevision: 5, workspaceRevision: 5
            ),
            state: .pending
        )
        writer.shouldFail = true
        await #expect(throws: WorkspacePersistenceError.atomicWriteFailed) {
            _ = try await journal.beginRecoveryCompletion(completion)
        }
        #expect(try Data(contentsOf: file) == rawBefore)
        #expect(try await journal.isCurrentBare(token))
    }

    @Test func everyRecoveryCompletionTransitionRejectsStaleIdentityAndPreservesRawBytesOnAtomicFailure() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let writer = RecoveryCompletionFailingWriter()
        let file = directory.file("draft-journal.json")
        let journal = DraftJournalRepository(fileURL: file, writer: writer)
        let note = try #require(WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 4).notes.values.first)
        let session = DraftJournalSessionID.editor(UUID())
        let entry = try recoveryEntry(note: note, session: session, generation: 1)
        let token: DraftRecoveryToken
        switch try await journal.protect(entry) {
        case let .protected(value): token = value
        case .superseded, .busy: Issue.record("The fixture must create a bare token"); return
        }
        let completion = DraftRecoveryCompletion(
            token: token, action: .restoreAsCurrent,
            source: .init(workspaceRevision: 4, workspaceChecksum: "source"),
            result: .init(noteID: note.id, noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(note), noteRevision: 5, workspaceRevision: 5),
            state: .pending
        )
        let stale = DraftRecoveryCompletion(
            token: token, action: .saveAsNew,
            source: completion.source,
            result: completion.result,
            state: .pending
        )
        #expect(try await journal.beginRecoveryCompletion(completion) == .applied)
        #expect(try await journal.markRecoveryCompletionCommitted(stale) == .staleOrMissing)

        let beforeMark = try Data(contentsOf: file)
        writer.shouldFail = true
        await #expect(throws: WorkspacePersistenceError.atomicWriteFailed) {
            _ = try await journal.markRecoveryCompletionCommitted(completion)
        }
        writer.shouldFail = false
        #expect(try Data(contentsOf: file) == beforeMark)
        #expect(try await journal.markRecoveryCompletionCommitted(completion) == .applied)

        let beforeDiscard = try Data(contentsOf: file)
        writer.shouldFail = true
        await #expect(throws: WorkspacePersistenceError.atomicWriteFailed) {
            _ = try await journal.discardRecoveryCompletion(completion)
        }
        writer.shouldFail = false
        #expect(try Data(contentsOf: file) == beforeDiscard)
        #expect(try await journal.discardRecoveryCompletion(completion) == .applied)

        let secondEntry = try recoveryEntry(note: note, session: session, generation: 2)
        let secondToken: DraftRecoveryToken
        switch try await journal.protect(secondEntry) {
        case let .protected(value): secondToken = value
        case .superseded, .busy: Issue.record("A later generation must be protected"); return
        }
        let pending = DraftRecoveryCompletion(
            token: secondToken, action: .restoreAsCurrent,
            source: completion.source, result: completion.result, state: .pending
        )
        #expect(try await journal.beginRecoveryCompletion(pending) == .applied)
        let beforeAbandon = try Data(contentsOf: file)
        writer.shouldFail = true
        await #expect(throws: WorkspacePersistenceError.atomicWriteFailed) {
            _ = try await journal.abandonRecoveryCompletion(pending)
        }
        writer.shouldFail = false
        #expect(try Data(contentsOf: file) == beforeAbandon)
        #expect(try await journal.abandonRecoveryCompletion(pending) == .applied)
        #expect(try await journal.isCurrentBare(secondToken))
    }
}

private enum OccupiedJournalState: String, CaseIterable {
    case pendingReceipt
    case savedReceipt
    case recoveryPending
    case recoveryCommitted
}

private func recoveryCompletion(token: DraftRecoveryToken, note: Note) -> DraftRecoveryCompletion {
    .init(
        token: token,
        action: .restoreAsCurrent,
        source: .init(workspaceRevision: 4, workspaceChecksum: "occupied-source"),
        result: .init(
            noteID: note.id,
            noteSnapshotChecksum: token.noteSnapshotChecksum,
            noteRevision: note.revision + 1,
            workspaceRevision: 5
        ),
        state: .pending
    )
}

private func launchLockedJournalCopy(
    payloadURL: URL,
    targetURL: URL,
    signalURL: URL
) throws -> Process {
    let lockURL = targetURL.deletingLastPathComponent()
        .appendingPathComponent(".\(targetURL.lastPathComponent).jelly.lock")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
        "-c",
        "import fcntl,os,sys,time; lock=open(sys.argv[1],'a+b'); fcntl.flock(lock,fcntl.LOCK_EX); open(sys.argv[2],'wb').close(); time.sleep(0.15); data=open(sys.argv[3],'rb').read(); tmp=sys.argv[4]+'.peer'; open(tmp,'wb').write(data); os.replace(tmp,sys.argv[4]); fcntl.flock(lock,fcntl.LOCK_UN)",
        lockURL.path,
        signalURL.path,
        payloadURL.path,
        targetURL.path,
    ]
    try process.run()
    return process
}

private func waitForRecoveryJournalFile(_ url: URL) -> Bool {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return false
}

private func recoveryEntry(
    note: Note,
    session: DraftJournalSessionID,
    generation: UInt64
) throws -> DraftJournalEntry {
    let checksum = try WorkspaceChecksum.noteSnapshotChecksum(note)
    let unsigned = DraftJournalEntry(
        noteID: note.id,
        editSessionID: session,
        baseWorkspaceRevision: max(0, note.revision - 1),
        baseNoteRevision: max(0, note.revision - 1),
        draftGeneration: generation,
        noteSnapshot: note,
        updatedAt: .distantPast,
        noteSnapshotChecksum: checksum,
        journalChecksum: ""
    )
    return .init(
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
}

private final class RecoveryCompletionFailingWriter: AtomicFileWriting, @unchecked Sendable {
    var shouldFail = false

    func replaceAtomically(data: Data, at destination: URL) throws {
        if shouldFail { throw WorkspacePersistenceError.atomicWriteFailed }
        try FoundationAtomicFileWriter().replaceAtomically(data: data, at: destination)
    }
}
