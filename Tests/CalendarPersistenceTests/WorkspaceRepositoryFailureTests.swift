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

    @Test func claimedReplacementWithoutCandidateReadbackKeepsV2MainAndLoadedSourceUnchanged() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let v2 = try WorkspacePersistenceFixtures.v2CalendarDocument()
        try v2.write(to: main)
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { .empty(calendar: WorkspacePersistenceFixtures.calendarState) },
            mainFileWriter: WorkspacePersistenceNoWriteMainWriter()
        )
        _ = try await repository.load()

        await #expect(throws: WorkspacePersistenceError.atomicWriteFailed) {
            _ = try await repository.save(try WorkspacePersistenceFixtures.workspaceWithOneNote())
        }
        #expect(try Data(contentsOf: main) == v2)
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

struct WorkspacePersistenceNoWriteMainWriter: MainFileCompareAndReplaceWriting {
    func createIfAbsent(candidate: Data, at destination: URL) throws -> MainFileCompareAndReplaceResult {
        .replaced
    }

    func replaceIfSHA256Matches(
        expectedSHA256: String,
        candidate: Data,
        at destination: URL
    ) throws -> MainFileCompareAndReplaceResult {
        .replaced
    }
}
