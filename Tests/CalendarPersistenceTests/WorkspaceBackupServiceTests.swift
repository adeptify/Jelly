import Foundation
import Testing
@testable import CalendarPersistence
@testable import WorkspaceDomain

@Suite("WorkspaceBackupServiceTests")
struct WorkspaceBackupServiceTests {
    @Test func exportingLoadedV2CopiesExactRawBytesWithoutForcingV3Save() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let destination = directory.file("backup.json")
        let v2 = try WorkspacePersistenceFixtures.v2CalendarDocument()
        try v2.write(to: main)
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { .empty(calendar: WorkspacePersistenceFixtures.calendarState) }
        )
        _ = try await repository.load()

        try await BackupService().exportCurrent(from: repository, to: destination)

        #expect(try Data(contentsOf: destination) == v2)
        #expect(try Data(contentsOf: main) == v2)
    }

    @Test func exportingLoadedV1CopiesExactRawBytesWithoutForcingV3Save() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let destination = directory.file("backup.json")
        let v1 = WorkspacePersistenceFixtures.v1CalendarDocument()
        try v1.write(to: main)
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { .empty(calendar: WorkspacePersistenceFixtures.calendarState) }
        )
        _ = try await repository.load()

        try await BackupService().exportCurrent(from: repository, to: destination)

        #expect(try Data(contentsOf: destination) == v1)
        #expect(try Data(contentsOf: main) == v1)
    }

    @Test func prepareRestoreBindsSourceRevisionsToExactlyItsPreparedContent() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let source = directory.file("restore.json")
        let current = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 4)
        let restored = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 8)
        try WorkspaceDocumentCodec.encode(current).write(to: main)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { .empty(calendar: WorkspacePersistenceFixtures.calendarState) }
        )
        _ = try await repository.load()

        let prepared = try await repository.prepareRestore(.init(sourceURL: source, rollbackDirectoryURL: directory.url))

        #expect(prepared.content == WorkspaceContentSnapshot(state: restored))
        #expect(prepared.sourceNoteRevisions == restored.notes.mapValues(\.revision))
        #expect(Set(prepared.sourceNoteRevisions.keys) == Set(prepared.content.notes.keys))
    }

    @Test func restoreRejectsCandidateWithDifferentBusinessContentBeforeRollbackWrite() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let source = directory.file("restore.json")
        let current = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        let restored = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 2)
        try WorkspaceDocumentCodec.encode(current).write(to: main)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let repository = JSONWorkspaceRepository(documentURL: main, seed: { current })
        _ = try await repository.load()
        let prepared = try await repository.prepareRestore(.init(sourceURL: source, rollbackDirectoryURL: directory.url))
        var wrong = restored
        wrong.revision = 3
        wrong.notes[wrong.notes.keys.first!]!.title = "not the prepared content"

        await #expect(throws: WorkspacePersistenceError.restoreBindingMismatch) {
            _ = try await repository.commitRestore(prepared, state: wrong)
        }
        let persisted = try Data(contentsOf: main)
        let expected = try WorkspaceDocumentCodec.encode(current)
        #expect(persisted == expected)
    }

    @Test func preparedRestoreFromAnotherRepositoryCannotWriteItsMainOrRollback() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let firstMain = directory.file("first.json")
        let secondMain = directory.file("second.json")
        let source = directory.file("restore.json")
        let current = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var restored = current
        restored.revision = 2
        restored.notes[restored.notes.keys.first!]!.revision = 2
        restored.notes[restored.notes.keys.first!]!.title = "restored"
        try WorkspaceDocumentCodec.encode(current).write(to: firstMain)
        try WorkspaceDocumentCodec.encode(current).write(to: secondMain)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let first = JSONWorkspaceRepository(documentURL: firstMain, seed: { current })
        let second = JSONWorkspaceRepository(documentURL: secondMain, seed: { current })
        _ = try await first.load()
        _ = try await second.load()
        let prepared = try await first.prepareRestore(.init(sourceURL: source, rollbackDirectoryURL: directory.url))
        let beforeSecond = try Data(contentsOf: secondMain)

        await #expect(throws: WorkspacePersistenceError.invalidRestoreCapability) {
            _ = try await second.commitRestore(prepared, state: restored)
        }
        #expect(try Data(contentsOf: secondMain) == beforeSecond)
    }

    @Test func restoreRejectsExistingRollbackPathWithoutOverwritingVictim() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("main.json")
        let source = directory.file("restore.json")
        let current = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var restored = current
        restored.revision = 2
        restored.notes[restored.notes.keys.first!]!.revision = 2
        try WorkspaceDocumentCodec.encode(current).write(to: main)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let repository = JSONWorkspaceRepository(documentURL: main, seed: { current })
        _ = try await repository.load()
        let prepared = try await repository.prepareRestore(.init(sourceURL: source, rollbackDirectoryURL: directory.url))
        try Data("victim rollback bytes".utf8).write(to: prepared.rollbackURL)
        let beforeMain = try Data(contentsOf: main)

        await #expect(throws: WorkspacePersistenceError.rollbackWriteFailed) {
            _ = try await repository.commitRestore(prepared, state: restored)
        }
        #expect(try Data(contentsOf: prepared.rollbackURL) == Data("victim rollback bytes".utf8))
        #expect(try Data(contentsOf: main) == beforeMain)
    }

    @Test func corruptedRollbackReadbackFailsBeforeReplacingTheMainDocument() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("main.json")
        let source = directory.file("restore.json")
        let current = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var restored = current
        restored.revision = 2
        restored.notes[restored.notes.keys.first!]!.revision = 2
        try WorkspaceDocumentCodec.encode(current).write(to: main)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { current },
            rollbackWriter: WorkspacePersistenceCorruptingExclusiveWriter()
        )
        _ = try await repository.load()
        let prepared = try await repository.prepareRestore(.init(sourceURL: source, rollbackDirectoryURL: directory.url))
        let beforeMain = try Data(contentsOf: main)

        await #expect(throws: WorkspacePersistenceError.rollbackWriteFailed) {
            _ = try await repository.commitRestore(prepared, state: restored)
        }
        #expect(try Data(contentsOf: main) == beforeMain)
        #expect(try Data(contentsOf: prepared.rollbackURL) != beforeMain)
    }

    @Test func rollbackReadbackFailureConsumesTheCapabilityAndFreshPrepareCanContinue() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("main.json")
        let source = directory.file("restore.json")
        let current = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var restored = current
        restored.revision = 2
        restored.notes[restored.notes.keys.first!]!.revision = 2
        try WorkspaceDocumentCodec.encode(current).write(to: main)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { current },
            rollbackWriter: WorkspacePersistenceCorruptingOnceExclusiveWriter()
        )
        _ = try await repository.load()
        let prepared = try await repository.prepareRestore(.init(sourceURL: source, rollbackDirectoryURL: directory.url))

        await #expect(throws: WorkspacePersistenceError.rollbackWriteFailed) {
            _ = try await repository.commitRestore(prepared, state: restored)
        }
        await #expect(throws: WorkspacePersistenceError.invalidRestoreCapability) {
            _ = try await repository.commitRestore(prepared, state: restored)
        }

        let fresh = try await repository.prepareRestore(.init(sourceURL: source, rollbackDirectoryURL: directory.url))
        #expect(fresh.rollbackURL != prepared.rollbackURL)
        _ = try await repository.commitRestore(fresh, state: restored)
        #expect(try await repository.load().state == restored)
    }

    @Test func migrationSnapshotFailureAfterRollbackConsumesTheCapabilityAndFreshPrepareCanContinue() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("main.json")
        let source = directory.file("restore.json")
        let legacy = try WorkspacePersistenceFixtures.v2CalendarDocument()
        let restored = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        try legacy.write(to: main)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let sidecarWriter = WorkspacePersistenceFailOnceWriter()
        sidecarWriter.failNextWrite = true
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { .empty(calendar: WorkspacePersistenceFixtures.calendarState) },
            snapshotDirectoryURL: directory.file("snapshots"),
            recoveryManifestURL: directory.file("manifest.json"),
            atomicWriter: sidecarWriter
        )
        _ = try await repository.load()
        let prepared = try await repository.prepareRestore(.init(sourceURL: source, rollbackDirectoryURL: directory.url))

        await #expect(throws: WorkspacePersistenceError.atomicWriteFailed) {
            _ = try await repository.commitRestore(prepared, state: restored)
        }
        #expect(try Data(contentsOf: main) == legacy)
        await #expect(throws: WorkspacePersistenceError.invalidRestoreCapability) {
            _ = try await repository.commitRestore(prepared, state: restored)
        }

        let fresh = try await repository.prepareRestore(.init(sourceURL: source, rollbackDirectoryURL: directory.url))
        #expect(fresh.rollbackURL != prepared.rollbackURL)
        _ = try await repository.commitRestore(fresh, state: restored)
        #expect(try await repository.load().state == restored)
    }

    @Test func manifestFailureAfterRollbackConsumesTheCapabilityAndFreshPrepareCanContinue() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("main.json")
        let source = directory.file("restore.json")
        let manifest = directory.file("manifest.json")
        let legacy = try WorkspacePersistenceFixtures.v2CalendarDocument()
        let restored = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        try legacy.write(to: main)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let sidecarWriter = WorkspacePersistenceFailOnceDestinationWriter { $0 == manifest }
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { .empty(calendar: WorkspacePersistenceFixtures.calendarState) },
            snapshotDirectoryURL: directory.file("snapshots"),
            recoveryManifestURL: manifest,
            atomicWriter: sidecarWriter
        )
        _ = try await repository.load()
        let prepared = try await repository.prepareRestore(.init(sourceURL: source, rollbackDirectoryURL: directory.url))

        await #expect(throws: WorkspacePersistenceError.atomicWriteFailed) {
            _ = try await repository.commitRestore(prepared, state: restored)
        }
        #expect(try Data(contentsOf: main) == legacy)
        await #expect(throws: WorkspacePersistenceError.invalidRestoreCapability) {
            _ = try await repository.commitRestore(prepared, state: restored)
        }

        let fresh = try await repository.prepareRestore(.init(sourceURL: source, rollbackDirectoryURL: directory.url))
        #expect(fresh.rollbackURL != prepared.rollbackURL)
        _ = try await repository.commitRestore(fresh, state: restored)
        #expect(try await repository.load().state == restored)
    }

    @Test func forgedPreparedRestorePathCannotOverwriteItsVictim() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("main.json")
        let source = directory.file("restore.json")
        let victim = directory.file("victim.json")
        let current = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var restored = current
        restored.revision = 2
        restored.notes[restored.notes.keys.first!]!.revision = 2
        try WorkspaceDocumentCodec.encode(current).write(to: main)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        try Data("victim bytes".utf8).write(to: victim)
        let repository = JSONWorkspaceRepository(documentURL: main, seed: { current })
        _ = try await repository.load()
        let issued = try await repository.prepareRestore(.init(sourceURL: source, rollbackDirectoryURL: directory.url))
        let forged = PreparedWorkspaceRestore(
            rawSourceData: issued.rawSourceData,
            provenance: issued.provenance,
            content: issued.content,
            sourceRevisionHighWatermark: issued.sourceRevisionHighWatermark,
            sourceNoteRevisions: issued.sourceNoteRevisions,
            rollbackURL: victim,
            capabilityID: issued.capabilityID
        )
        let beforeMain = try Data(contentsOf: main)

        await #expect(throws: WorkspacePersistenceError.invalidRestoreCapability) {
            _ = try await repository.commitRestore(forged, state: restored)
        }
        #expect(try Data(contentsOf: victim) == Data("victim bytes".utf8))
        #expect(try Data(contentsOf: main) == beforeMain)
    }

    @Test func sourceChangedDuringRestoreCASKeepsTheCooperatingMainBytes() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("main.json")
        let source = directory.file("restore.json")
        let current = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var restored = current
        restored.revision = 2
        restored.notes[restored.notes.keys.first!]!.revision = 2
        try WorkspaceDocumentCodec.encode(current).write(to: main)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let beforeMain = try Data(contentsOf: main)
        let changed = Data("cooperating restore writer".utf8)
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { current },
            mainFileWriter: WorkspacePersistenceMutatingMainWriter {
                _ = try FoundationMainFileCompareAndReplaceWriter().replaceIfSHA256Matches(
                    expectedSHA256: WorkspacePersistenceFixtures.sha256(beforeMain),
                    candidate: changed,
                    at: main
                )
            }
        )
        _ = try await repository.load()
        let prepared = try await repository.prepareRestore(.init(sourceURL: source, rollbackDirectoryURL: directory.url))

        await #expect(throws: WorkspacePersistenceError.sourceChanged) {
            _ = try await repository.commitRestore(prepared, state: restored)
        }
        #expect(try Data(contentsOf: main) == changed)
        #expect(try Data(contentsOf: prepared.rollbackURL) == beforeMain)
        await #expect(throws: WorkspacePersistenceError.invalidRestoreCapability) {
            _ = try await repository.commitRestore(prepared, state: restored)
        }
    }

    @Test func writerThatReplacesThenThrowsStillCommitsRestore() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("main.json")
        let source = directory.file("restore.json")
        let current = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var restored = current
        restored.revision = 2
        restored.notes[restored.notes.keys.first!]!.revision = 2
        restored.notes[restored.notes.keys.first!]!.title = "restored despite writer throw"
        let restoredData = try WorkspaceDocumentCodec.encode(restored)
        try WorkspaceDocumentCodec.encode(current).write(to: main)
        try restoredData.write(to: source)
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { current },
            mainFileWriter: FoundationMainFileCompareAndReplaceWriter(
                writer: WorkspacePersistenceReplaceThenThrowWriter(outcome: .candidate)
            )
        )
        _ = try await repository.load()
        let prepared = try await repository.prepareRestore(.init(sourceURL: source, rollbackDirectoryURL: directory.url))

        #expect(try await repository.commitRestore(prepared, state: restored) == WorkspaceSaveReceipt(
            workspaceRevision: restored.revision,
            persistedDraft: nil
        ))
        #expect(try Data(contentsOf: main) == restoredData)
        await #expect(throws: WorkspacePersistenceError.invalidRestoreCapability) {
            _ = try await repository.commitRestore(prepared, state: restored)
        }
    }

    @Test func definiteCASFailureAfterRollbackConsumesTheCapabilityAndFreshPrepareCanContinue() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("main.json")
        let source = directory.file("restore.json")
        let current = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var restored = current
        restored.revision = 2
        restored.notes[restored.notes.keys.first!]!.revision = 2
        let initialData = try WorkspaceDocumentCodec.encode(current)
        try initialData.write(to: main)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { current },
            mainFileWriter: FoundationMainFileCompareAndReplaceWriter(
                writer: WorkspacePersistenceNoWriteThenThrowOnceWriter()
            )
        )
        _ = try await repository.load()
        let prepared = try await repository.prepareRestore(.init(sourceURL: source, rollbackDirectoryURL: directory.url))

        await #expect(throws: WorkspacePersistenceError.atomicWriteFailed) {
            _ = try await repository.commitRestore(prepared, state: restored)
        }
        #expect(try Data(contentsOf: main) == initialData)
        await #expect(throws: WorkspacePersistenceError.invalidRestoreCapability) {
            _ = try await repository.commitRestore(prepared, state: restored)
        }

        let fresh = try await repository.prepareRestore(.init(sourceURL: source, rollbackDirectoryURL: directory.url))
        #expect(fresh.rollbackURL != prepared.rollbackURL)
        _ = try await repository.commitRestore(fresh, state: restored)
        #expect(try await repository.load().state == restored)
    }

    @Test func successfulRestoreCapabilityIsSingleUse() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("main.json")
        let source = directory.file("restore.json")
        let current = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var restored = current
        restored.revision = 2
        restored.notes[restored.notes.keys.first!]!.revision = 2
        try WorkspaceDocumentCodec.encode(current).write(to: main)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let repository = JSONWorkspaceRepository(documentURL: main, seed: { current })
        _ = try await repository.load()
        let prepared = try await repository.prepareRestore(.init(sourceURL: source, rollbackDirectoryURL: directory.url))
        _ = try await repository.commitRestore(prepared, state: restored)
        let afterFirst = try Data(contentsOf: main)

        await #expect(throws: WorkspacePersistenceError.invalidRestoreCapability) {
            _ = try await repository.commitRestore(prepared, state: restored)
        }
        #expect(try Data(contentsOf: main) == afterFirst)
    }

    @Test func uncertainRestoreKeepsCapabilityPendingUntilCandidateReconciliation() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("main.json")
        let source = directory.file("restore.json")
        let initial = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var restored = initial
        restored.revision = 2
        restored.notes[restored.notes.keys.first!]!.revision = 2
        restored.notes[restored.notes.keys.first!]!.title = "uncertain restored candidate"
        try WorkspaceDocumentCodec.encode(initial).write(to: main)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let readbackFailure = WorkspacePersistencePostRenameReadbackFailureWriter()
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { initial },
            mainFileWriter: FoundationMainFileCompareAndReplaceWriter(writer: readbackFailure)
        )
        _ = try await repository.load()
        let prepared = try await repository.prepareRestore(.init(sourceURL: source, rollbackDirectoryURL: directory.url))

        await #expect(throws: WorkspacePersistenceError.commitUncertain) {
            _ = try await repository.commitRestore(prepared, state: restored)
        }
        defer { readbackFailure.restoreReadability(at: main) }
        await #expect(throws: WorkspacePersistenceError.commitUncertain) {
            _ = try await repository.reconcilePendingCommit()
        }
        await #expect(throws: WorkspacePersistenceError.commitUncertain) {
            _ = try await repository.load()
        }
        await #expect(throws: WorkspacePersistenceError.commitUncertain) {
            _ = try await repository.save(restored)
        }
        await #expect(throws: WorkspacePersistenceError.commitUncertain) {
            _ = try await repository.prepareRestore(.init(sourceURL: source, rollbackDirectoryURL: directory.url))
        }
        await #expect(throws: WorkspacePersistenceError.commitUncertain) {
            _ = try await repository.commitRestore(prepared, state: restored)
        }

        readbackFailure.restoreReadability(at: main)
        #expect(try await repository.reconcilePendingCommit() == .committed(
            WorkspaceSaveReceipt(workspaceRevision: restored.revision, persistedDraft: nil)
        ))
        #expect(try await repository.load().state == restored)
        await #expect(throws: WorkspacePersistenceError.invalidRestoreCapability) {
            _ = try await repository.commitRestore(prepared, state: restored)
        }
    }

    @Test func notCommittedRestoreReconciliationInvalidatesTheOldCapability() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("main.json")
        let source = directory.file("restore.json")
        let initial = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var restored = initial
        restored.revision = 2
        restored.notes[restored.notes.keys.first!]!.revision = 2
        try WorkspaceDocumentCodec.encode(initial).write(to: main)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let initialData = try Data(contentsOf: main)
        let readbackFailure = WorkspacePersistencePostRenameReadbackFailureWriter()
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { initial },
            mainFileWriter: FoundationMainFileCompareAndReplaceWriter(writer: readbackFailure)
        )
        _ = try await repository.load()
        let prepared = try await repository.prepareRestore(.init(sourceURL: source, rollbackDirectoryURL: directory.url))

        await #expect(throws: WorkspacePersistenceError.commitUncertain) {
            _ = try await repository.commitRestore(prepared, state: restored)
        }
        readbackFailure.restoreReadability(at: main)
        try initialData.write(to: main)
        #expect(try await repository.reconcilePendingCommit() == .notCommitted)
        await #expect(throws: WorkspacePersistenceError.invalidRestoreCapability) {
            _ = try await repository.commitRestore(prepared, state: restored)
        }
    }

    @Test func thirdValueReconciliationInvalidatesTheOldRestoreCapability() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("main.json")
        let source = directory.file("restore.json")
        let initial = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var restored = initial
        restored.revision = 2
        restored.notes[restored.notes.keys.first!]!.revision = 2
        try WorkspaceDocumentCodec.encode(initial).write(to: main)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let readbackFailure = WorkspacePersistencePostRenameReadbackFailureWriter()
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { initial },
            mainFileWriter: FoundationMainFileCompareAndReplaceWriter(writer: readbackFailure)
        )
        _ = try await repository.load()
        let prepared = try await repository.prepareRestore(.init(sourceURL: source, rollbackDirectoryURL: directory.url))

        await #expect(throws: WorkspacePersistenceError.commitUncertain) {
            _ = try await repository.commitRestore(prepared, state: restored)
        }
        readbackFailure.restoreReadability(at: main)
        try Data("third main bytes".utf8).write(to: main)
        #expect(try await repository.reconcilePendingCommit() == .sourceChanged)
        await #expect(throws: WorkspacePersistenceError.invalidRestoreCapability) {
            _ = try await repository.commitRestore(prepared, state: restored)
        }
    }
}

struct WorkspacePersistenceCorruptingExclusiveWriter: ExclusiveFileWriting {
    func createExclusively(data: Data, at destination: URL) throws {
        try FoundationExclusiveFileWriter().createExclusively(data: data, at: destination)
        try Data("corrupted rollback".utf8).write(to: destination)
    }
}

final class WorkspacePersistenceCorruptingOnceExclusiveWriter: ExclusiveFileWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var shouldCorrupt = true

    func createExclusively(data: Data, at destination: URL) throws {
        try FoundationExclusiveFileWriter().createExclusively(data: data, at: destination)
        let corrupt = lock.withLock {
            defer { shouldCorrupt = false }
            return shouldCorrupt
        }
        if corrupt { try Data("corrupted rollback".utf8).write(to: destination) }
    }
}

final class WorkspacePersistenceFailOnceDestinationWriter: AtomicFileWriting, @unchecked Sendable {
    private let predicate: @Sendable (URL) -> Bool
    private let lock = NSLock()
    private var didFail = false

    init(predicate: @escaping @Sendable (URL) -> Bool) {
        self.predicate = predicate
    }

    func replaceAtomically(data: Data, at destination: URL) throws {
        let shouldFail = lock.withLock {
            guard didFail == false, predicate(destination) else { return false }
            didFail = true
            return true
        }
        if shouldFail { throw WorkspacePersistenceInjectedFailure.requested }
        try FoundationAtomicFileWriter().replaceAtomically(data: data, at: destination)
    }
}

final class WorkspacePersistenceNoWriteThenThrowOnceWriter: AtomicFileWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var shouldThrow = true

    func replaceAtomically(data: Data, at destination: URL) throws {
        let throwsNow = lock.withLock {
            defer { shouldThrow = false }
            return shouldThrow
        }
        if throwsNow { throw WorkspacePersistenceInjectedFailure.requested }
        try FoundationAtomicFileWriter().replaceAtomically(data: data, at: destination)
    }
}
