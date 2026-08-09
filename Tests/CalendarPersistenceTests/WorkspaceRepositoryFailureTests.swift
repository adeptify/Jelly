import Foundation
import Testing
@testable import CalendarPersistence
@testable import WorkspaceDomain

@Suite("WorkspaceRepositoryFailureTests")
struct WorkspaceRepositoryFailureTests {
    @Test func cooperatingSourceMutationAfterManifestBeforeCASLeavesChangedMainUntouched() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let v2 = try WorkspacePersistenceFixtures.v2CalendarDocument()
        let changed = Data("cooperating writer's newer document".utf8)
        try v2.write(to: main)
        let mainWriter = WorkspacePersistenceMutatingMainWriter {
            _ = try FoundationMainFileCompareAndReplaceWriter().replaceIfSHA256Matches(
                expectedSHA256: WorkspacePersistenceFixtures.sha256(v2),
                candidate: changed,
                at: main
            )
        }
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { .empty(calendar: WorkspacePersistenceFixtures.calendarState) },
            snapshotDirectoryURL: directory.file("snapshots"),
            recoveryManifestURL: directory.file("manifest.json"),
            mainFileWriter: mainWriter
        )
        _ = try await repository.load()

        await #expect(throws: WorkspacePersistenceError.sourceChanged) {
            try await repository.save(try WorkspacePersistenceFixtures.workspaceWithOneNote())
        }
        #expect(try Data(contentsOf: main) == changed)
    }

    @Test func createIfAbsentFailureKeepsRepositoryAbsentAndDoesNotFabricateProvenance() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { .empty(calendar: WorkspacePersistenceFixtures.calendarState) },
            mainFileWriter: WorkspacePersistenceAlwaysFailingMainWriter()
        )
        _ = try await repository.load()

        await #expect(throws: WorkspacePersistenceError.atomicWriteFailed) {
            try await repository.save(try WorkspacePersistenceFixtures.workspaceWithOneNote())
        }
        #expect(FileManager.default.fileExists(atPath: main.path) == false)
        await #expect(throws: WorkspacePersistenceError.missingDocument) {
            _ = try await repository.currentDocumentData()
        }
    }

    @Test func draftContextMustNameExistingNoteWithExactNormalizedChecksum() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let state = try WorkspacePersistenceFixtures.workspaceWithOneNote()
        let repository = JSONWorkspaceRepository(documentURL: main, seed: { state })
        _ = try await repository.load()
        let missing = PersistableDraftContext(noteID: NoteID(), draftGeneration: 1, noteSnapshotChecksum: "none")

        await #expect(throws: WorkspacePersistenceError.invalidDraftContext) {
            try await repository.save(state, draft: missing)
        }
        #expect(FileManager.default.fileExists(atPath: main.path) == false)
    }

    @Test func draftChecksumMismatchDoesNotCreateOrReplaceMain() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let state = try WorkspacePersistenceFixtures.workspaceWithOneNote()
        let repository = JSONWorkspaceRepository(documentURL: main, seed: { state })
        _ = try await repository.load()
        let noteID = try #require(state.notes.keys.first)
        let mismatch = PersistableDraftContext(
            noteID: noteID,
            draftGeneration: 1,
            noteSnapshotChecksum: "wrong-checksum"
        )

        await #expect(throws: WorkspacePersistenceError.invalidDraftContext) {
            _ = try await repository.save(state, draft: mismatch)
        }
        #expect(FileManager.default.fileExists(atPath: main.path) == false)
    }

    @Test func matchingDraftContextReturnsTheExactCandidateNoteRevisionReceipt() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let state = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 4)
        let note = try #require(state.notes.values.first)
        let context = PersistableDraftContext(
            noteID: note.id,
            draftGeneration: 12,
            noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(note)
        )
        let repository = JSONWorkspaceRepository(documentURL: directory.file("calendar-v1.json"), seed: { state })
        _ = try await repository.load()

        let receipt = try await repository.save(state, draft: context)

        #expect(receipt.persistedDraft == PersistedDraftReceipt(
            noteID: note.id,
            draftGeneration: 12,
            noteSnapshotChecksum: context.noteSnapshotChecksum,
            persistedNoteRevision: note.revision
        ))
    }

    @Test func v1LoadThenTwoSavesReopensWithSecondV3State() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        try WorkspacePersistenceFixtures.v1CalendarDocument().write(to: main)
        let first = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var second = first
        second.revision = 2
        second.notes[second.notes.keys.first!]!.revision = 2
        second.notes[second.notes.keys.first!]!.title = "second after v1"
        let repository = JSONWorkspaceRepository(documentURL: main, seed: { first })
        _ = try await repository.load()

        _ = try await repository.save(first)
        _ = try await repository.save(second)

        #expect(try await JSONWorkspaceRepository(documentURL: main, seed: { first }).load().state == second)
    }

    @Test func writerThatReplacesThenThrowsStillCommitsAnExistingSave() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let initial = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var candidate = initial
        candidate.revision = 2
        candidate.notes[candidate.notes.keys.first!]!.revision = 2
        candidate.notes[candidate.notes.keys.first!]!.title = "verified despite writer throw"
        let candidateData = try WorkspaceDocumentCodec.encode(candidate)
        try WorkspaceDocumentCodec.encode(initial).write(to: main)
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { initial },
            mainFileWriter: FoundationMainFileCompareAndReplaceWriter(
                writer: WorkspacePersistenceReplaceThenThrowWriter(outcome: .candidate)
            )
        )
        _ = try await repository.load()

        #expect(try await repository.save(candidate) == WorkspaceSaveReceipt(
            workspaceRevision: candidate.revision,
            persistedDraft: nil
        ))
        #expect(try Data(contentsOf: main) == candidateData)
        #expect(try await repository.currentDocumentData() == candidateData)
    }

    @Test func writerThatReplacesThenThrowsStillCommitsAnAbsentSeed() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let state = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        let candidateData = try WorkspaceDocumentCodec.encode(state)
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { state },
            mainFileWriter: FoundationMainFileCompareAndReplaceWriter(
                writer: WorkspacePersistenceReplaceThenThrowWriter(outcome: .candidate)
            )
        )
        _ = try await repository.load()

        #expect(try await repository.save(state) == WorkspaceSaveReceipt(
            workspaceRevision: state.revision,
            persistedDraft: nil
        ))
        #expect(try Data(contentsOf: main) == candidateData)
        #expect(try await repository.currentDocumentData() == candidateData)
    }

    @Test func writerThrowWithoutReplacementRemainsADefiniteSaveFailure() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let initial = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var candidate = initial
        candidate.revision = 2
        candidate.notes[candidate.notes.keys.first!]!.revision = 2
        let initialData = try WorkspaceDocumentCodec.encode(initial)
        try initialData.write(to: main)
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { initial },
            mainFileWriter: FoundationMainFileCompareAndReplaceWriter(
                writer: WorkspacePersistenceReplaceThenThrowWriter(outcome: .noReplacement)
            )
        )
        _ = try await repository.load()

        await #expect(throws: WorkspacePersistenceError.atomicWriteFailed) {
            _ = try await repository.save(candidate)
        }
        #expect(try Data(contentsOf: main) == initialData)
        #expect(try await repository.currentDocumentData() == initialData)
    }

    @Test func writerThrowWithThirdOrUnreadableDestinationIsCommitUncertain() throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let initial = Data("initial".utf8)
        let candidate = Data("candidate".utf8)
        try initial.write(to: main)
        let thirdWriter = WorkspacePersistenceReplaceThenThrowWriter(outcome: .third(Data("third".utf8)))
        let thirdCAS = FoundationMainFileCompareAndReplaceWriter(writer: thirdWriter)

        #expect(try thirdCAS.replaceIfSHA256Matches(
            expectedSHA256: WorkspacePersistenceFixtures.sha256(initial),
            candidate: candidate,
            at: main
        ) == .commitUncertain)

        try initial.write(to: main)
        let unreadableWriter = WorkspacePersistenceReplaceThenThrowWriter(outcome: .unreadable)
        defer { unreadableWriter.restoreReadability(at: main) }
        let unreadableCAS = FoundationMainFileCompareAndReplaceWriter(writer: unreadableWriter)
        #expect(try unreadableCAS.replaceIfSHA256Matches(
            expectedSHA256: WorkspacePersistenceFixtures.sha256(initial),
            candidate: candidate,
            at: main
        ) == .commitUncertain)
    }

    @Test func invalidVerifiedCASResultStaysPendingUntilTheOldV2BytesReconcile() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let v2 = try WorkspacePersistenceFixtures.v2CalendarDocument()
        try v2.write(to: main)
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { .empty(calendar: WorkspacePersistenceFixtures.calendarState) },
            mainFileWriter: WorkspacePersistenceInvalidVerifiedMainWriter()
        )
        _ = try await repository.load()

        await #expect(throws: WorkspacePersistenceError.commitUncertain) {
            _ = try await repository.save(try WorkspacePersistenceFixtures.workspaceWithOneNote())
        }
        #expect(try Data(contentsOf: main) == v2)
        await #expect(throws: WorkspacePersistenceError.commitUncertain) {
            _ = try await repository.currentDocumentData()
        }
        #expect(try await repository.reconcilePendingCommit() == .notCommitted)
        #expect(try await repository.currentDocumentData() == v2)
    }

    @Test func mainCASWriteFailureAfterVerifiedMigrationKeepsV2MainByteForByteUntouched() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let v2 = try WorkspacePersistenceFixtures.v2CalendarDocument()
        try v2.write(to: main)
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { .empty(calendar: WorkspacePersistenceFixtures.calendarState) },
            snapshotDirectoryURL: directory.file("snapshots"),
            recoveryManifestURL: directory.file("manifest.json"),
            mainFileWriter: WorkspacePersistenceAlwaysFailingMainWriter()
        )
        _ = try await repository.load()

        await #expect(throws: WorkspacePersistenceError.atomicWriteFailed) {
            _ = try await repository.save(try WorkspacePersistenceFixtures.workspaceWithOneNote())
        }
        #expect(try Data(contentsOf: main) == v2)
        #expect(try await repository.currentDocumentData() == v2)
    }

    @Test func postRenameReadbackFailureIsCommitUncertainAndCandidateReconcilesExactly() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let initial = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var candidate = initial
        candidate.revision = 2
        candidate.notes[candidate.notes.keys.first!]!.revision = 2
        candidate.notes[candidate.notes.keys.first!]!.title = "commit uncertain candidate"
        let initialData = try WorkspaceDocumentCodec.encode(initial)
        let candidateData = try WorkspaceDocumentCodec.encode(candidate)
        try initialData.write(to: main)
        let readbackFailure = WorkspacePersistencePostRenameReadbackFailureWriter()
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { initial },
            mainFileWriter: FoundationMainFileCompareAndReplaceWriter(writer: readbackFailure)
        )
        _ = try await repository.load()

        await #expect(throws: WorkspacePersistenceError.commitUncertain) {
            _ = try await repository.save(candidate)
        }
        defer { readbackFailure.restoreReadability(at: main) }
        await #expect(throws: WorkspacePersistenceError.commitUncertain) {
            _ = try await repository.currentDocumentData()
        }
        await #expect(throws: WorkspacePersistenceError.commitUncertain) {
            _ = try await repository.save(candidate)
        }

        readbackFailure.restoreReadability(at: main)
        #expect(try Data(contentsOf: main) == candidateData)
        #expect(try await JSONWorkspaceRepository(documentURL: main, seed: { initial }).load().state == candidate)
        #expect(try await repository.reconcilePendingCommit() == .committed(
            WorkspaceSaveReceipt(workspaceRevision: candidate.revision, persistedDraft: nil)
        ))
        #expect(try await repository.currentDocumentData() == candidateData)
    }

    @Test func unreadableExistingCandidateDuringAbsentCommitReconciliationFailsClosed() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let state = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        let candidate = try WorkspaceDocumentCodec.encode(state)
        let readbackFailure = WorkspacePersistencePostRenameReadbackFailureWriter()
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { state },
            mainFileWriter: FoundationMainFileCompareAndReplaceWriter(writer: readbackFailure)
        )
        _ = try await repository.load()

        await #expect(throws: WorkspacePersistenceError.commitUncertain) {
            _ = try await repository.save(state)
        }
        defer { readbackFailure.restoreReadability(at: main) }

        #expect(try await repository.reconcilePendingCommit() == .sourceChanged)
        readbackFailure.restoreReadability(at: main)
        #expect(try Data(contentsOf: main) == candidate)
    }

    @Test func uncertainCommitReconcilesOldAndThirdMainBytesWithoutFabricatingSuccess() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let initial = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var candidate = initial
        candidate.revision = 2
        candidate.notes[candidate.notes.keys.first!]!.revision = 2
        let initialData = try WorkspaceDocumentCodec.encode(initial)
        try initialData.write(to: main)
        let failure = WorkspacePersistencePostRenameReadbackFailureWriter()
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { initial },
            mainFileWriter: FoundationMainFileCompareAndReplaceWriter(writer: failure)
        )
        _ = try await repository.load()
        await #expect(throws: WorkspacePersistenceError.commitUncertain) {
            _ = try await repository.save(candidate)
        }
        failure.restoreReadability(at: main)
        try initialData.write(to: main)
        #expect(try await repository.reconcilePendingCommit() == .notCommitted)
        #expect(try await repository.currentDocumentData() == initialData)

        let thirdFailure = WorkspacePersistencePostRenameReadbackFailureWriter()
        let thirdRepository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { initial },
            mainFileWriter: FoundationMainFileCompareAndReplaceWriter(writer: thirdFailure)
        )
        _ = try await thirdRepository.load()
        await #expect(throws: WorkspacePersistenceError.commitUncertain) {
            _ = try await thirdRepository.save(candidate)
        }
        thirdFailure.restoreReadability(at: main)
        try Data("third cooperating bytes".utf8).write(to: main)
        #expect(try await thirdRepository.reconcilePendingCommit() == .sourceChanged)
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

final class WorkspacePersistenceReplaceThenThrowWriter: AtomicFileWriting, @unchecked Sendable {
    enum Outcome: Sendable {
        case candidate
        case noReplacement
        case third(Data)
        case unreadable
    }

    private let outcome: Outcome

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    func replaceAtomically(data: Data, at destination: URL) throws {
        switch outcome {
        case .noReplacement:
            throw WorkspacePersistenceInjectedFailure.requested
        case .candidate:
            try FoundationAtomicFileWriter().replaceAtomically(data: data, at: destination)
        case let .third(third):
            try FoundationAtomicFileWriter().replaceAtomically(data: data, at: destination)
            try third.write(to: destination)
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
}
