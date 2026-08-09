import Foundation
import Testing
@testable import CalendarPersistence
@testable import WorkspaceDomain

@Suite("WorkspaceRepositoryFailureTests")
struct WorkspaceRepositoryFailureTests {
    @Test func draftContextMustNameExactFinalCandidateNoteRevisionAndChecksum() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let state = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 4)
        let note = try #require(state.notes.values.first)
        let repository = JSONWorkspaceRepository(documentURL: directory.file("calendar-v1.json"), seed: { state })
        _ = try await repository.load()
        let session = DraftJournalSessionID.editor(UUID(uuidString: "00000000-0000-0000-0000-000000006f01")!)
        let context = PersistableDraftContext(
            noteID: note.id,
            editSessionID: session,
            draftGeneration: 12,
            noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(note),
            persistedNoteRevision: note.revision
        )

        let receipt = try await repository.save(state, draft: context)

        #expect(receipt.persistedDraft == PersistedDraftReceipt(
            noteID: note.id,
            editSessionID: session,
            draftGeneration: 12,
            noteSnapshotChecksum: context.noteSnapshotChecksum,
            persistedNoteRevision: note.revision
        ))
        #expect(try await repository.verifyPersistedDraft(context) == .verified(receipt.persistedDraft!))
    }

    @Test func invalidDraftContextCannotCreateOrReplaceTheMainDocument() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let state = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        let repository = JSONWorkspaceRepository(documentURL: main, seed: { state })
        _ = try await repository.load()
        let note = try #require(state.notes.values.first)
        let invalid = PersistableDraftContext(
            noteID: note.id,
            editSessionID: .editor(UUID()),
            draftGeneration: 1,
            noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(note),
            persistedNoteRevision: note.revision + 1
        )

        await #expect(throws: WorkspacePersistenceError.invalidDraftContext) {
            _ = try await repository.save(state, draft: invalid)
        }
        #expect(FileManager.default.fileExists(atPath: main.path) == false)
    }

    @Test func readableExternalBytesDuringDraftVerificationReturnSourceChanged() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let state = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        let note = try #require(state.notes.values.first)
        let repository = JSONWorkspaceRepository(documentURL: main, seed: { state })
        _ = try await repository.load()
        let context = PersistableDraftContext(
            noteID: note.id,
            editSessionID: .editor(UUID()),
            draftGeneration: 1,
            noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(note),
            persistedNoteRevision: note.revision
        )
        _ = try await repository.save(state, draft: context)
        try Data("external readable bytes".utf8).write(to: main)

        #expect(try await repository.verifyPersistedDraft(context) == .sourceChanged)
    }

    @Test func directCASSourceChangeReturnsTypedArtifactsAndKeepsThirdPartyBytes() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let initial = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var candidate = initial
        candidate.revision = 2
        candidate.notes[candidate.notes.keys.first!]!.revision = 2
        candidate.notes[candidate.notes.keys.first!]!.title = "候选"
        let initialData = try WorkspaceDocumentCodec.encode(initial)
        try initialData.write(to: main)
        let external = Data("cooperating-main-bytes".utf8)
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { initial },
            mainFileWriter: WorkspacePersistenceMutatingMainWriter {
                try FoundationAtomicFileWriter().replaceAtomically(data: external, at: main)
            }
        )
        _ = try await repository.load()

        await #expect(throws: WorkspaceDirectCommitFailure.sourceChanged(.init())) {
            _ = try await repository.save(candidate)
        }
        #expect(try Data(contentsOf: main) == external)
    }

    @Test func actorAtomicFailureDoesNotReplaceExistingMainBytes() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let initial = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var candidate = initial
        candidate.revision = 2
        candidate.notes[candidate.notes.keys.first!]!.revision = 2
        candidate.notes[candidate.notes.keys.first!]!.title = "不会保存"
        let initialData = try WorkspaceDocumentCodec.encode(initial)
        try initialData.write(to: main)
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { initial },
            mainFileWriter: WorkspacePersistenceAlwaysFailingMainWriter()
        )
        _ = try await repository.load()

        await #expect(throws: WorkspacePersistenceError.atomicWriteFailed) {
            _ = try await repository.save(candidate)
        }
        #expect(try Data(contentsOf: main) == initialData)
    }

    @Test func unresolvedReadbackReturnsStillPendingWithDurableSaveArtifacts() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let initial = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var candidate = initial
        candidate.revision = 2
        candidate.notes[candidate.notes.keys.first!]!.revision = 2
        let writer = WorkspacePersistencePostRenameReadbackFailureWriter()
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { initial },
            mainFileWriter: FoundationMainFileCompareAndReplaceWriter(writer: writer)
        )
        _ = try await repository.load()

        await #expect(throws: WorkspacePersistenceError.commitUncertain) {
            _ = try await repository.save(candidate)
        }
        #expect(try await repository.reconcilePendingCommit() == .stillPending(.init()))
        writer.restoreReadability(at: main)
        #expect(try await repository.reconcilePendingCommit() == .committed(.save(
            WorkspaceSaveReceipt(workspaceRevision: candidate.revision, persistedDraft: nil)
        )))
    }

    @Test func draftVerificationDistinguishesNotPersistedAbsentUnreadableAndExactProof() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let state = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        let note = try #require(state.notes.values.first)
        let context = PersistableDraftContext(
            noteID: note.id,
            editSessionID: .editor(UUID()),
            draftGeneration: 1,
            noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(note),
            persistedNoteRevision: note.revision
        )
        let repository = JSONWorkspaceRepository(documentURL: main, seed: { state })
        _ = try await repository.load()
        #expect(try await repository.verifyPersistedDraft(context) == .notPersisted)
        _ = try await repository.save(state)
        #expect(try await repository.verifyPersistedDraft(context) == .verified(.init(
            noteID: note.id,
            editSessionID: context.editSessionID,
            draftGeneration: context.draftGeneration,
            noteSnapshotChecksum: context.noteSnapshotChecksum,
            persistedNoteRevision: context.persistedNoteRevision
        )))
        try FileManager.default.removeItem(at: main)
        #expect(try await repository.verifyPersistedDraft(context) == .sourceChanged)
        try WorkspaceDocumentCodec.encode(state).write(to: main)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: main.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: main.path) }
        #expect(try await repository.verifyPersistedDraft(context) == .unreadableUnknown)
    }

    @Test func v1LoadThenTwoSavesReopensWithTheSecondV3State() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        try WorkspacePersistenceFixtures.v1CalendarDocument().write(to: main)
        let first = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var second = first
        second.revision = 2
        second.notes[second.notes.keys.first!]!.revision = 2
        second.notes[second.notes.keys.first!]!.title = "second"
        let repository = JSONWorkspaceRepository(documentURL: main, seed: { first })
        _ = try await repository.load()
        _ = try await repository.save(first)
        _ = try await repository.save(second)
        #expect(try await JSONWorkspaceRepository(documentURL: main, seed: { first }).load().state == second)
    }

    @Test func replaceThenThrowClassifiesCandidateOldThirdAndUnreadableWithoutGuessing() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let initial = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var candidate = initial
        candidate.revision = 2
        candidate.notes[candidate.notes.keys.first!]!.revision = 2
        let initialData = try WorkspaceDocumentCodec.encode(initial)
        let candidateData = try WorkspaceDocumentCodec.encode(candidate)

        let committedMain = directory.file("candidate.json")
        try initialData.write(to: committedMain)
        let committed = JSONWorkspaceRepository(
            documentURL: committedMain,
            seed: { initial },
            mainFileWriter: FoundationMainFileCompareAndReplaceWriter(
                writer: WorkspacePersistenceReplaceThenThrowWriter(outcome: .candidate)
            )
        )
        _ = try await committed.load()
        #expect(try await committed.save(candidate).workspaceRevision == candidate.revision)
        #expect(try Data(contentsOf: committedMain) == candidateData)

        let oldMain = directory.file("old.json")
        try initialData.write(to: oldMain)
        let old = JSONWorkspaceRepository(
            documentURL: oldMain,
            seed: { initial },
            mainFileWriter: FoundationMainFileCompareAndReplaceWriter(
                writer: WorkspacePersistenceReplaceThenThrowWriter(outcome: .noReplacement)
            )
        )
        _ = try await old.load()
        await #expect(throws: WorkspacePersistenceError.atomicWriteFailed) { _ = try await old.save(candidate) }
        #expect(try Data(contentsOf: oldMain) == initialData)

        for (name, outcome) in [
            ("third", WorkspacePersistenceReplaceThenThrowWriter.Outcome.third(Data("third".utf8))),
            ("unreadable", WorkspacePersistenceReplaceThenThrowWriter.Outcome.unreadable),
        ] {
            let main = directory.file("\(name).json")
            try initialData.write(to: main)
            let writer = WorkspacePersistenceReplaceThenThrowWriter(outcome: outcome)
            let repository = JSONWorkspaceRepository(
                documentURL: main,
                seed: { initial },
                mainFileWriter: FoundationMainFileCompareAndReplaceWriter(writer: writer)
            )
            _ = try await repository.load()
            await #expect(throws: WorkspacePersistenceError.commitUncertain) { _ = try await repository.save(candidate) }
            if name == "third" {
                #expect(try await repository.reconcilePendingCommit() == .sourceChanged(.init()))
            } else {
                #expect(try await repository.reconcilePendingCommit() == .stillPending(.init()))
            }
            writer.restoreReadability(at: main)
        }
    }

    @Test func absentCommitUncertaintyReconcilesCandidateAbsentThirdAndUnreadableExactly() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let state = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        let candidateData = try WorkspaceDocumentCodec.encode(state)

        let candidateMain = directory.file("candidate-absent.json")
        let candidateWriter = WorkspacePersistenceReplaceThenThrowWriter(outcome: .candidate)
        let candidateRepository = JSONWorkspaceRepository(
            documentURL: candidateMain,
            seed: { state },
            mainFileWriter: FoundationMainFileCompareAndReplaceWriter(writer: candidateWriter)
        )
        _ = try await candidateRepository.load()
        #expect(try await candidateRepository.save(state).workspaceRevision == state.revision)
        #expect(try Data(contentsOf: candidateMain) == candidateData)

        let thirdMain = directory.file("third-absent.json")
        let thirdWriter = WorkspacePersistenceReplaceThenThrowWriter(outcome: .third(Data("third".utf8)))
        let third = JSONWorkspaceRepository(
            documentURL: thirdMain,
            seed: { state },
            mainFileWriter: FoundationMainFileCompareAndReplaceWriter(writer: thirdWriter)
        )
        _ = try await third.load()
        await #expect(throws: WorkspacePersistenceError.commitUncertain) { _ = try await third.save(state) }
        #expect(try await third.reconcilePendingCommit() == .sourceChanged(.init()))

        let unreadableMain = directory.file("unreadable-absent.json")
        let unreadableWriter = WorkspacePersistenceReplaceThenThrowWriter(outcome: .unreadable)
        let unreadable = JSONWorkspaceRepository(
            documentURL: unreadableMain,
            seed: { state },
            mainFileWriter: FoundationMainFileCompareAndReplaceWriter(writer: unreadableWriter)
        )
        _ = try await unreadable.load()
        await #expect(throws: WorkspacePersistenceError.commitUncertain) { _ = try await unreadable.save(state) }
        #expect(try await unreadable.reconcilePendingCommit() == .stillPending(.init()))
        unreadableWriter.restoreReadability(at: unreadableMain)
        try FileManager.default.removeItem(at: unreadableMain)
        #expect(try await unreadable.reconcilePendingCommit() == .notCommitted(.init()))
    }

    @Test func invalidVerifiedCASResultRemainsPendingUntilPreviousBytesReconcile() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let v2 = try WorkspacePersistenceFixtures.v2CalendarDocument()
        try v2.write(to: main)
        let state = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { state },
            mainFileWriter: WorkspacePersistenceInvalidVerifiedMainWriter()
        )
        _ = try await repository.load()
        await #expect(throws: WorkspacePersistenceError.commitUncertain) { _ = try await repository.save(state) }
        #expect(try Data(contentsOf: main) == v2)
        #expect(try await repository.reconcilePendingCommit() == .notCommitted(.init()))
        #expect(try await repository.currentDocumentData() == v2)
    }
}

final class WorkspacePersistencePostRenameReadbackFailureWriter: AtomicFileWriting, @unchecked Sendable {
    func replaceAtomically(data: Data, at destination: URL) throws {
        try FoundationAtomicFileWriter().replaceAtomically(data: data, at: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: destination.path)
    }

    func restoreReadability(at destination: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}

struct WorkspacePersistenceMutatingMainWriter: MainFileCompareAndReplaceWriting {
    let mutateBeforeCompare: @Sendable () throws -> Void

    func createIfAbsent(candidate: Data, at destination: URL) throws -> MainFileCompareAndReplaceResult {
        try FoundationMainFileCompareAndReplaceWriter().createIfAbsent(candidate: candidate, at: destination)
    }

    func replaceIfSHA256Matches(
        expectedSHA256: String,
        candidate: Data,
        at destination: URL
    ) throws -> MainFileCompareAndReplaceResult {
        try mutateBeforeCompare()
        return try FoundationMainFileCompareAndReplaceWriter().replaceIfSHA256Matches(
            expectedSHA256: expectedSHA256,
            candidate: candidate,
            at: destination
        )
    }

    func createIfAbsentUnlocked(candidate: Data, at destination: URL) throws -> MainFileCompareAndReplaceResult {
        try FoundationMainFileCompareAndReplaceWriter().createIfAbsentUnlocked(
            candidate: candidate,
            at: destination
        )
    }

    func replaceIfSHA256MatchesUnlocked(
        expectedSHA256: String,
        candidate: Data,
        at destination: URL
    ) throws -> MainFileCompareAndReplaceResult {
        try mutateBeforeCompare()
        return try FoundationMainFileCompareAndReplaceWriter().replaceIfSHA256MatchesUnlocked(
            expectedSHA256: expectedSHA256,
            candidate: candidate,
            at: destination
        )
    }
}

struct WorkspacePersistenceAlwaysFailingMainWriter: MainFileCompareAndReplaceWriting {
    func createIfAbsent(candidate: Data, at destination: URL) throws -> MainFileCompareAndReplaceResult {
        throw WorkspacePersistenceInjectedFailure.requested
    }

    func replaceIfSHA256Matches(
        expectedSHA256: String,
        candidate: Data,
        at destination: URL
    ) throws -> MainFileCompareAndReplaceResult {
        throw WorkspacePersistenceInjectedFailure.requested
    }

    func createIfAbsentUnlocked(candidate: Data, at destination: URL) throws -> MainFileCompareAndReplaceResult {
        throw WorkspacePersistenceInjectedFailure.requested
    }

    func replaceIfSHA256MatchesUnlocked(
        expectedSHA256: String,
        candidate: Data,
        at destination: URL
    ) throws -> MainFileCompareAndReplaceResult {
        throw WorkspacePersistenceInjectedFailure.requested
    }
}

final class WorkspacePersistenceReplaceThenThrowWriter: AtomicFileWriting, @unchecked Sendable {
    enum Outcome: Sendable {
        case candidate
        case noReplacement
        case third(Data)
        case unreadable
    }

    private let outcome: Outcome

    init(outcome: Outcome) { self.outcome = outcome }

    func replaceAtomically(data: Data, at destination: URL) throws {
        switch outcome {
        case .candidate:
            try FoundationAtomicFileWriter().replaceAtomically(data: data, at: destination)
        case .noReplacement:
            break
        case let .third(bytes):
            try FoundationAtomicFileWriter().replaceAtomically(data: bytes, at: destination)
        case .unreadable:
            try FoundationAtomicFileWriter().replaceAtomically(data: data, at: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: destination.path)
        }
        throw WorkspacePersistenceInjectedFailure.requested
    }

    func restoreReadability(at destination: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}

struct WorkspacePersistenceInvalidVerifiedMainWriter: MainFileCompareAndReplaceWriting {
    func createIfAbsent(candidate: Data, at destination: URL) throws -> MainFileCompareAndReplaceResult {
        .replaced(verifiedRawData: Data())
    }

    func replaceIfSHA256Matches(
        expectedSHA256: String,
        candidate: Data,
        at destination: URL
    ) throws -> MainFileCompareAndReplaceResult {
        .replaced(verifiedRawData: Data())
    }

    func createIfAbsentUnlocked(candidate: Data, at destination: URL) throws -> MainFileCompareAndReplaceResult {
        .replaced(verifiedRawData: Data())
    }

    func replaceIfSHA256MatchesUnlocked(
        expectedSHA256: String,
        candidate: Data,
        at destination: URL
    ) throws -> MainFileCompareAndReplaceResult {
        .replaced(verifiedRawData: Data())
    }
}
