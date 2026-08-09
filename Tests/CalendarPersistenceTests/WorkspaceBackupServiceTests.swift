import Foundation
import Testing
@testable import CalendarPersistence
@testable import WorkspaceDomain

@Suite("WorkspaceBackupServiceTests")
struct WorkspaceBackupServiceTests {
    @Test func exportingLoadedLegacyBytesCopiesTheExactPrimaryWithoutForcingV3Save() async throws {
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

    @Test func invalidRestorePreviewCannotCreateCapabilityOrRollback() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("main.json")
        let source = directory.file("invalid.json")
        let current = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        let currentData = try WorkspaceDocumentCodec.encode(current)
        try currentData.write(to: main)
        try Data("not-json".utf8).write(to: source)
        let repository = JSONWorkspaceRepository(documentURL: main, seed: { current })
        _ = try await repository.load()

        await #expect(throws: WorkspacePersistenceError.invalidDocument) {
            _ = try await BackupService().inspectRestoreSource(source)
        }
        #expect(try Data(contentsOf: main) == currentData)
    }

    @Test func sourceChangedAfterRestoreRollbackUsesTypedArtifactAndDoesNotOverwriteExternalMain() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("main.json")
        let source = directory.file("restore.json")
        let current = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var restored = current
        restored.revision = 2
        restored.notes[restored.notes.keys.first!]!.revision = 2
        restored.notes[restored.notes.keys.first!]!.title = "恢复"
        let currentData = try WorkspaceDocumentCodec.encode(current)
        try currentData.write(to: main)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let external = Data("external-main".utf8)
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { current },
            mainFileWriter: WorkspacePersistenceMutatingMainWriter {
                try FoundationAtomicFileWriter().replaceAtomically(data: external, at: main)
            }
        )
        _ = try await repository.load()
        let preview = try await BackupService().inspectRestoreSource(source)
        let prepared = try await repository.prepareRestore(preview, rollbackDirectoryURL: directory.url)

        do {
            _ = try await repository.commitRestore(prepared, state: restored)
            Issue.record("The cooperating external write must win the CAS")
        } catch let WorkspaceDirectCommitFailure.sourceChanged(artifacts) {
            guard case let .file(rollbackURL, identity)? = artifacts.rollback else {
                Issue.record("Restore source changes must return verified rollback evidence")
                return
            }
            #expect(try Data(contentsOf: rollbackURL) == currentData)
            #expect(identity.byteCount == currentData.count)
        }
        #expect(try Data(contentsOf: main) == external)
    }

    @Test func opaqueRestoreSourceChangedReturnsExactRawRollbackArtifact() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("main.json")
        let source = directory.file("restore.json")
        let opaque = Data("opaque-before-restore".utf8)
        let external = Data("third-party-after-rollback".utf8)
        let restored = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        try opaque.write(to: main)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { restored },
            mainFileWriter: WorkspacePersistenceMutatingMainWriter {
                try FoundationAtomicFileWriter().replaceAtomically(data: external, at: main)
            }
        )
        await #expect(throws: WorkspacePersistenceError.invalidDocument) { _ = try await repository.load() }
        let prepared = try await repository.prepareRestore(
            try await BackupService().inspectRestoreSource(source),
            rollbackDirectoryURL: directory.url
        )

        do {
            _ = try await repository.commitRestore(prepared, state: restored)
            Issue.record("A non-cooperating source change must fail the unlocked CAS")
        } catch let WorkspaceDirectCommitFailure.sourceChanged(artifacts) {
            guard case let .file(rollbackURL, identity)? = artifacts.rollback else {
                Issue.record("Opaque restore source changes must retain exact raw rollback evidence")
                return
            }
            #expect(try Data(contentsOf: rollbackURL) == opaque)
            #expect(identity == .init(
                sha256: WorkspacePersistenceFixtures.sha256(opaque),
                byteCount: opaque.count
            ))
        }
        #expect(try Data(contentsOf: main) == external)
    }

    @Test func absentCreateRaceRestoreReturnsNonePreviousSourceAbsentArtifact() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("main.json")
        let source = directory.file("restore.json")
        let restored = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let external = Data("created-by-peer".utf8)
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { restored },
            mainFileWriter: WorkspacePersistenceCreateRaceWriter { try external.write(to: main) }
        )
        _ = try await repository.load()
        let preview = try await BackupService().inspectRestoreSource(source)
        let prepared = try await repository.prepareRestore(preview, rollbackDirectoryURL: directory.url)

        await #expect(throws: WorkspaceDirectCommitFailure.sourceChanged(
            .init(rollback: .nonePreviousSourceAbsent)
        )) {
            _ = try await repository.commitRestore(prepared, state: restored)
        }
        #expect(try Data(contentsOf: main) == external)
    }

    @Test func prepareRestoreRejectsEveryCallerForgedDecodedFieldBeforeCapabilityOrRollback() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("main.json")
        let source = directory.file("restore.json")
        let current = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var restored = current
        restored.revision = 4
        restored.notes[restored.notes.keys.first!]!.revision = 3
        try WorkspaceDocumentCodec.encode(current).write(to: main)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let repository = JSONWorkspaceRepository(documentURL: main, seed: { current })
        _ = try await repository.load()
        let authentic = try await BackupService().inspectRestoreSource(source)

        var forgedWorkspaceRevision = authentic.loadResult.state
        forgedWorkspaceRevision.revision += 1
        var forgedNoteRevision = authentic.loadResult.state
        let noteID = try #require(forgedNoteRevision.notes.keys.first)
        forgedNoteRevision.notes[noteID]!.revision += 1
        let issue = WorkspaceConsistencyIssue(
            id: .init(rawValue: "forged"),
            locator: .calendarBaseline(.item(UUID())),
            defect: .missingCalendarOwner
        )
        let forged: [WorkspaceRestorePreview] = [
            .init(
                sourceURL: authentic.sourceURL,
                rawSourceData: authentic.rawSourceData,
                sourceIdentity: authentic.sourceIdentity,
                loadResult: .init(
                    state: forgedWorkspaceRevision,
                    provenance: authentic.loadResult.provenance,
                    consistencyIssues: authentic.loadResult.consistencyIssues
                ),
                sourceNoteRevisions: authentic.sourceNoteRevisions
            ),
            .init(
                sourceURL: authentic.sourceURL,
                rawSourceData: authentic.rawSourceData,
                sourceIdentity: authentic.sourceIdentity,
                loadResult: .init(
                    state: forgedNoteRevision,
                    provenance: authentic.loadResult.provenance,
                    consistencyIssues: authentic.loadResult.consistencyIssues
                ),
                sourceNoteRevisions: forgedNoteRevision.notes.mapValues(\.revision)
            ),
            .init(
                sourceURL: authentic.sourceURL,
                rawSourceData: authentic.rawSourceData,
                sourceIdentity: authentic.sourceIdentity,
                loadResult: .init(
                    state: authentic.loadResult.state,
                    provenance: .init(
                        sourceSchema: authentic.loadResult.provenance.sourceSchema - 1,
                        sourceBytesSHA256: authentic.loadResult.provenance.sourceBytesSHA256,
                        sourceByteCount: authentic.loadResult.provenance.sourceByteCount
                    ),
                    consistencyIssues: authentic.loadResult.consistencyIssues
                ),
                sourceNoteRevisions: authentic.sourceNoteRevisions
            ),
            .init(
                sourceURL: authentic.sourceURL,
                rawSourceData: authentic.rawSourceData,
                sourceIdentity: authentic.sourceIdentity,
                loadResult: .init(
                    state: authentic.loadResult.state,
                    provenance: authentic.loadResult.provenance,
                    consistencyIssues: [issue]
                ),
                sourceNoteRevisions: authentic.sourceNoteRevisions
            ),
            .init(
                sourceURL: authentic.sourceURL,
                rawSourceData: authentic.rawSourceData,
                sourceIdentity: authentic.sourceIdentity,
                loadResult: authentic.loadResult,
                sourceNoteRevisions: [:]
            ),
        ]

        for preview in forged {
            await #expect(throws: WorkspacePersistenceError.restoreBindingMismatch) {
                _ = try await repository.prepareRestore(preview, rollbackDirectoryURL: directory.url)
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(at: directory.url, includingPropertiesForKeys: nil)
            .allSatisfy { $0.lastPathComponent.hasPrefix("workspace-rollback-") == false })
    }

    @Test func peerPrechangeBeforeRestoreCommitRollsBackTheCommitTimeSourceAndThenRestores() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("main.json")
        let source = directory.file("restore.json")
        let original = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var peer = original
        peer.revision = 2
        peer.notes[peer.notes.keys.first!]!.revision = 2
        peer.notes[peer.notes.keys.first!]!.title = "peer B"
        var restored = peer
        restored.revision = 3
        restored.notes[restored.notes.keys.first!]!.revision = 3
        restored.notes[restored.notes.keys.first!]!.title = "restore C"
        try WorkspaceDocumentCodec.encode(original).write(to: main)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let repository = JSONWorkspaceRepository(documentURL: main, seed: { original })
        _ = try await repository.load()
        let prepared = try await repository.prepareRestore(
            try await BackupService().inspectRestoreSource(source),
            rollbackDirectoryURL: directory.url
        )
        let peerData = try WorkspaceDocumentCodec.encode(peer)
        try peerData.write(to: main)

        let outcome = try await repository.commitRestore(prepared, state: restored)

        guard case let .file(rollbackURL, identity) = outcome.rollback else {
            Issue.record("Commit-time present source must have rollback evidence")
            return
        }
        #expect(try Data(contentsOf: rollbackURL) == peerData)
        #expect(identity == .init(sha256: WorkspacePersistenceFixtures.sha256(peerData), byteCount: peerData.count))
        #expect(try Data(contentsOf: main) == WorkspaceDocumentCodec.encode(restored))
    }

    @Test func preparedRestoreIsRepositoryBoundSingleUseDiscardableAndPathSafe() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let firstMain = directory.file("first.json")
        let secondMain = directory.file("second.json")
        let source = directory.file("restore.json")
        let current = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var restored = current
        restored.revision = 2
        restored.notes[restored.notes.keys.first!]!.revision = 2
        try WorkspaceDocumentCodec.encode(current).write(to: firstMain)
        try WorkspaceDocumentCodec.encode(current).write(to: secondMain)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let first = JSONWorkspaceRepository(documentURL: firstMain, seed: { current })
        let second = JSONWorkspaceRepository(documentURL: secondMain, seed: { current })
        _ = try await first.load()
        _ = try await second.load()
        let prepared = try await first.prepareRestore(
            try await BackupService().inspectRestoreSource(source),
            rollbackDirectoryURL: directory.url
        )

        await #expect(throws: WorkspacePersistenceError.invalidRestoreCapability) {
            _ = try await second.commitRestore(prepared, state: restored)
        }
        #expect(await first.discardPreparedRestore(prepared))
        #expect(await first.discardPreparedRestore(prepared) == false)
        await #expect(throws: WorkspacePersistenceError.invalidRestoreCapability) {
            _ = try await first.commitRestore(prepared, state: restored)
        }
    }

    @Test func rollbackWriteAndReadbackFailuresNeverReplaceMainAndConsumeCapability() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let current = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var restored = current
        restored.revision = 2
        restored.notes[restored.notes.keys.first!]!.revision = 2
        let source = directory.file("restore.json")
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        for (name, writer) in [
            ("write", AnyExclusiveWriter(WorkspacePersistenceAlwaysFailingExclusiveWriter())),
            ("readback", AnyExclusiveWriter(WorkspacePersistenceCorruptingExclusiveWriter())),
        ] {
            let main = directory.file("\(name)-main.json")
            let initialData = try WorkspaceDocumentCodec.encode(current)
            try initialData.write(to: main)
            let repository = JSONWorkspaceRepository(documentURL: main, seed: { current }, rollbackWriter: writer)
            _ = try await repository.load()
            let prepared = try await repository.prepareRestore(
                try await BackupService().inspectRestoreSource(source),
                rollbackDirectoryURL: directory.url
            )
            await #expect(throws: WorkspacePersistenceError.rollbackWriteFailed) {
                _ = try await repository.commitRestore(prepared, state: restored)
            }
            #expect(try Data(contentsOf: main) == initialData)
            await #expect(throws: WorkspacePersistenceError.invalidRestoreCapability) {
                _ = try await repository.commitRestore(prepared, state: restored)
            }
        }
    }

    @Test func restoringOverV2RegistersExactSnapshotAndManifestBeforeMainReplacement() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("main.json")
        let source = directory.file("restore.json")
        let snapshots = directory.file("snapshots")
        let manifestURL = directory.file("manifest.json")
        let v2 = try WorkspacePersistenceFixtures.v2CalendarDocument()
        let restored = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        try v2.write(to: main)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { restored },
            snapshotDirectoryURL: snapshots,
            recoveryManifestURL: manifestURL
        )
        _ = try await repository.load()
        let prepared = try await repository.prepareRestore(
            try await BackupService().inspectRestoreSource(source),
            rollbackDirectoryURL: directory.url
        )

        _ = try await repository.commitRestore(prepared, state: restored)

        let manifest = try RecoveryManifestStore(
            manifestURL: manifestURL,
            snapshotDirectoryURL: snapshots
        ).load()
        let record = try #require(manifest.entries.first)
        #expect(record.sourceSHA256 == WorkspacePersistenceFixtures.sha256(v2))
        #expect(try Data(contentsOf: snapshots.appendingPathComponent(record.snapshotFileName)) == v2)
        #expect(try Data(contentsOf: prepared.rollbackURL) == v2)
    }

    @Test func existingRollbackPathAndDefiniteCASFailureConsumeCapabilitiesWithoutOverwritingEvidence() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let source = directory.file("restore.json")
        let current = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var restored = current
        restored.revision = 2
        restored.notes[restored.notes.keys.first!]!.revision = 2
        let currentData = try WorkspaceDocumentCodec.encode(current)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let preview = try await BackupService().inspectRestoreSource(source)

        let occupiedMain = directory.file("occupied-main.json")
        try currentData.write(to: occupiedMain)
        let occupied = JSONWorkspaceRepository(documentURL: occupiedMain, seed: { current })
        _ = try await occupied.load()
        let occupiedPrepared = try await occupied.prepareRestore(preview, rollbackDirectoryURL: directory.url)
        let victimBytes = Data("existing rollback evidence".utf8)
        try victimBytes.write(to: occupiedPrepared.rollbackURL)
        await #expect(throws: WorkspacePersistenceError.rollbackWriteFailed) {
            _ = try await occupied.commitRestore(occupiedPrepared, state: restored)
        }
        #expect(try Data(contentsOf: occupiedPrepared.rollbackURL) == victimBytes)
        #expect(try Data(contentsOf: occupiedMain) == currentData)
        await #expect(throws: WorkspacePersistenceError.invalidRestoreCapability) {
            _ = try await occupied.commitRestore(occupiedPrepared, state: restored)
        }

        let failedMain = directory.file("failed-main.json")
        try currentData.write(to: failedMain)
        let failed = JSONWorkspaceRepository(
            documentURL: failedMain,
            seed: { current },
            mainFileWriter: WorkspacePersistenceAlwaysFailingMainWriter()
        )
        _ = try await failed.load()
        let failedPrepared = try await failed.prepareRestore(preview, rollbackDirectoryURL: directory.url)
        await #expect(throws: WorkspacePersistenceError.atomicWriteFailed) {
            _ = try await failed.commitRestore(failedPrepared, state: restored)
        }
        #expect(try Data(contentsOf: failedPrepared.rollbackURL) == currentData)
        #expect(try Data(contentsOf: failedMain) == currentData)
        await #expect(throws: WorkspacePersistenceError.invalidRestoreCapability) {
            _ = try await failed.commitRestore(failedPrepared, state: restored)
        }
    }

    @Test func uncertainRestoreReconciliationReturnsRollbackArtifactsForEveryTerminalProbe() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let initial = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var restored = initial
        restored.revision = 2
        restored.notes[restored.notes.keys.first!]!.revision = 2
        let initialData = try WorkspaceDocumentCodec.encode(initial)
        let restoredData = try WorkspaceDocumentCodec.encode(restored)
        let source = directory.file("restore.json")
        try restoredData.write(to: source)

        for terminal in ["candidate", "old", "third", "absent", "unreadable"] {
            let main = directory.file("\(terminal)-main.json")
            try initialData.write(to: main)
            let writer = WorkspacePersistencePostRenameReadbackFailureWriter()
            let repository = JSONWorkspaceRepository(
                documentURL: main,
                seed: { initial },
                mainFileWriter: FoundationMainFileCompareAndReplaceWriter(writer: writer)
            )
            _ = try await repository.load()
            let prepared = try await repository.prepareRestore(
                try await BackupService().inspectRestoreSource(source),
                rollbackDirectoryURL: directory.url
            )
            await #expect(throws: WorkspacePersistenceError.commitUncertain) {
                _ = try await repository.commitRestore(prepared, state: restored)
            }
            let rollback = WorkspaceRollbackArtifact.file(
                prepared.rollbackURL,
                .init(sha256: WorkspacePersistenceFixtures.sha256(initialData), byteCount: initialData.count)
            )
            let artifacts = WorkspacePendingCommitArtifacts(rollback: rollback)
            switch terminal {
            case "candidate":
                writer.restoreReadability(at: main)
                #expect(try await repository.reconcilePendingCommit() == .committed(.restore(.init(
                    receipt: .init(workspaceRevision: restored.revision, persistedDraft: nil),
                    rollback: rollback
                ))))
            case "old":
                writer.restoreReadability(at: main)
                try initialData.write(to: main)
                #expect(try await repository.reconcilePendingCommit() == .notCommitted(artifacts))
            case "third":
                writer.restoreReadability(at: main)
                try Data("third".utf8).write(to: main)
                #expect(try await repository.reconcilePendingCommit() == .sourceChanged(artifacts))
            case "absent":
                writer.restoreReadability(at: main)
                try FileManager.default.removeItem(at: main)
                #expect(try await repository.reconcilePendingCommit() == .sourceChanged(artifacts))
            default:
                #expect(try await repository.reconcilePendingCommit() == .stillPending(artifacts))
                writer.restoreReadability(at: main)
            }
            #expect(try Data(contentsOf: prepared.rollbackURL) == initialData)
        }
    }
}

private struct AnyExclusiveWriter: ExclusiveFileWriting {
    private let body: @Sendable (Data, URL) throws -> Void

    init(_ base: some ExclusiveFileWriting) {
        body = base.createExclusively(data:at:)
    }

    func createExclusively(data: Data, at destination: URL) throws {
        try body(data, destination)
    }
}

private struct WorkspacePersistenceAlwaysFailingExclusiveWriter: ExclusiveFileWriting {
    func createExclusively(data: Data, at destination: URL) throws {
        throw WorkspacePersistenceInjectedFailure.requested
    }
}

private struct WorkspacePersistenceCorruptingExclusiveWriter: ExclusiveFileWriting {
    func createExclusively(data: Data, at destination: URL) throws {
        try FoundationExclusiveFileWriter().createExclusively(data: data, at: destination)
        try Data("corrupt".utf8).write(to: destination)
    }
}

struct WorkspacePersistenceCreateRaceWriter: MainFileCompareAndReplaceWriting {
    let createPeerFile: @Sendable () throws -> Void

    func createIfAbsent(candidate: Data, at destination: URL) throws -> MainFileCompareAndReplaceResult {
        try createPeerFile()
        return try FoundationMainFileCompareAndReplaceWriter().createIfAbsent(
            candidate: candidate,
            at: destination
        )
    }

    func replaceIfSHA256Matches(
        expectedSHA256: String,
        candidate: Data,
        at destination: URL
    ) throws -> MainFileCompareAndReplaceResult {
        try FoundationMainFileCompareAndReplaceWriter().replaceIfSHA256Matches(
            expectedSHA256: expectedSHA256,
            candidate: candidate,
            at: destination
        )
    }

    func createIfAbsentUnlocked(candidate: Data, at destination: URL) throws -> MainFileCompareAndReplaceResult {
        try createPeerFile()
        return try FoundationMainFileCompareAndReplaceWriter().createIfAbsentUnlocked(
            candidate: candidate,
            at: destination
        )
    }

    func replaceIfSHA256MatchesUnlocked(
        expectedSHA256: String,
        candidate: Data,
        at destination: URL
    ) throws -> MainFileCompareAndReplaceResult {
        try FoundationMainFileCompareAndReplaceWriter().replaceIfSHA256MatchesUnlocked(
            expectedSHA256: expectedSHA256,
            candidate: candidate,
            at: destination
        )
    }
}
