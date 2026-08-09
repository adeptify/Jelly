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

    @Test func directCASSourceChangeReturnsTypedArtifactsAndKeepsCooperatingBytes() async throws {
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
                _ = try FoundationMainFileCompareAndReplaceWriter().replaceIfSHA256Matches(
                    expectedSHA256: WorkspacePersistenceFixtures.sha256(initialData),
                    candidate: external,
                    at: main
                )
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
}
