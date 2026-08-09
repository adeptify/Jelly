import Foundation
import Testing
@testable import CalendarPersistence
@testable import WorkspaceDomain

@Suite("JSONWorkspaceRepositoryTests")
struct JSONWorkspaceRepositoryTests {
    @Test func successfulSaveReadbackReplacesCompleteLoadedSourceForTheNextSave() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let first = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var second = first
        second.revision = 2
        second.notes[second.notes.keys.first!]!.revision = 2
        second.notes[second.notes.keys.first!]!.title = "第二次保存"
        let repository = JSONWorkspaceRepository(documentURL: main, seed: { first })
        _ = try await repository.load()

        _ = try await repository.save(first)
        _ = try await repository.save(second)

        let data = try await repository.currentDocumentData()
        #expect(try WorkspaceDocumentCodec.decode(data).state == second)
        #expect(try await JSONWorkspaceRepository(documentURL: main, seed: { first }).load().state == second)
    }

    @Test func inspectRestoreSourceIsPureAndPrepareIssuesTheSingleUseCapability() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let source = directory.file("restore.json")
        let current = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var restored = current
        restored.revision = 2
        restored.notes[restored.notes.keys.first!]!.revision = 2
        restored.notes[restored.notes.keys.first!]!.title = "恢复候选"
        let currentData = try WorkspaceDocumentCodec.encode(current)
        try currentData.write(to: main)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let repository = JSONWorkspaceRepository(documentURL: main, seed: { current })
        _ = try await repository.load()

        let preview = try await BackupService().inspectRestoreSource(source)
        #expect(try Data(contentsOf: main) == currentData)
        let prepared = try await repository.prepareRestore(preview, rollbackDirectoryURL: directory.url)
        #expect(prepared.content == WorkspaceContentSnapshot(state: restored))
        #expect(await repository.discardPreparedRestore(prepared))
        await #expect(throws: WorkspacePersistenceError.invalidRestoreCapability) {
            _ = try await repository.commitRestore(prepared, state: restored)
        }
    }

    @Test func restoreValidPrimaryReturnsVerifiedRollbackArtifact() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let source = directory.file("restore.json")
        let current = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var restored = current
        restored.revision = 2
        restored.notes[restored.notes.keys.first!]!.revision = 2
        restored.notes[restored.notes.keys.first!]!.title = "恢复完成"
        let currentData = try WorkspaceDocumentCodec.encode(current)
        try currentData.write(to: main)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let repository = JSONWorkspaceRepository(documentURL: main, seed: { current })
        _ = try await repository.load()

        let preview = try await BackupService().inspectRestoreSource(source)
        let prepared = try await repository.prepareRestore(preview, rollbackDirectoryURL: directory.url)
        let outcome = try await repository.commitRestore(prepared, state: restored)

        #expect(outcome.receipt == WorkspaceSaveReceipt(workspaceRevision: 2, persistedDraft: nil))
        guard case let .file(rollbackURL, identity) = outcome.rollback else {
            Issue.record("A present primary must create a rollback file")
            return
        }
        #expect(try Data(contentsOf: rollbackURL) == currentData)
        #expect(identity == .init(sha256: WorkspacePersistenceFixtures.sha256(currentData), byteCount: currentData.count))
        #expect(try await repository.load().state == restored)
        await #expect(throws: WorkspacePersistenceError.invalidRestoreCapability) {
            _ = try await repository.commitRestore(prepared, state: restored)
        }
    }

    @Test func absentPrimaryRestoreCreatesWithoutFabricatingRollbackFile() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let source = directory.file("restore.json")
        let restored = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let repository = JSONWorkspaceRepository(documentURL: main, seed: { restored })
        _ = try await repository.load()

        let preview = try await BackupService().inspectRestoreSource(source)
        let prepared = try await repository.prepareRestore(preview, rollbackDirectoryURL: directory.url)
        let outcome = try await repository.commitRestore(prepared, state: restored)

        #expect(outcome.rollback == .nonePreviousSourceAbsent)
        #expect(try await repository.load().state == restored)
    }

    @Test func opaquePrimaryIsRetainedForRawRecoveryAndCanBeRestoredWithRollback() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let source = directory.file("restore.json")
        let opaque = Data("opaque-invalid-primary".utf8)
        let restored = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        try opaque.write(to: main)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let repository = JSONWorkspaceRepository(documentURL: main, seed: { restored })

        await #expect(throws: WorkspacePersistenceError.invalidDocument) { _ = try await repository.load() }
        #expect(try await repository.currentRawRecoveryData() == WorkspaceRawRecoveryArtifact(
            rawData: opaque,
            identity: .init(sha256: WorkspacePersistenceFixtures.sha256(opaque), byteCount: opaque.count)
        ))
        let preview = try await BackupService().inspectRestoreSource(source)
        let prepared = try await repository.prepareRestore(preview, rollbackDirectoryURL: directory.url)
        let outcome = try await repository.commitRestore(prepared, state: restored)
        guard case let .file(rollbackURL, _) = outcome.rollback else {
            Issue.record("An opaque present primary still needs raw rollback evidence")
            return
        }
        #expect(try Data(contentsOf: rollbackURL) == opaque)
        #expect(try await repository.load().state == restored)
    }

    @Test func reloadCurrentSourceRebindsValidOpaqueAndAbsentWithoutTreatingOpaqueAsBackup() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let state = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        let validData = try WorkspaceDocumentCodec.encode(state)
        try validData.write(to: main)
        let repository = JSONWorkspaceRepository(documentURL: main, seed: { state })

        let valid = try await repository.reloadCurrentSourceAfterExternalChange()
        #expect(valid == .valid(try WorkspaceDocumentCodec.decode(validData)))
        let opaque = Data("not-a-workspace-document".utf8)
        try opaque.write(to: main)
        #expect(try await repository.reloadCurrentSourceAfterExternalChange() == .opaqueInvalid(
            .init(sha256: WorkspacePersistenceFixtures.sha256(opaque), byteCount: opaque.count)
        ))
        #expect(try await repository.currentRawRecoveryData().rawData == opaque)
        try FileManager.default.removeItem(at: main)
        #expect(try await repository.reloadCurrentSourceAfterExternalChange() == .absent)
    }

    @Test func unreadableReloadFailsClosedWithoutReplacingTheLastKnownBinding() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let state = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        let data = try WorkspaceDocumentCodec.encode(state)
        try data.write(to: main)
        let repository = JSONWorkspaceRepository(documentURL: main, seed: { state })
        let loaded = try WorkspaceDocumentCodec.decode(data)
        #expect(try await repository.reloadCurrentSourceAfterExternalChange() == .valid(loaded))

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: main.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: main.path) }
        #expect(try await repository.reloadCurrentSourceAfterExternalChange() == .unreadableUnknown)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: main.path)
        await #expect(throws: WorkspacePersistenceError.invalidDocument) {
            _ = try await repository.currentDocumentData()
        }
        #expect(try await repository.reloadCurrentSourceAfterExternalChange() == .valid(loaded))
        #expect(try await repository.currentDocumentData() == data)
    }

    @Test func firstUnreadableSourceIsBoundSeparatelyFromAbsentUntilExplicitReload() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let source = directory.file("restore.json")
        let initial = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var restored = initial
        restored.revision = 2
        restored.notes[restored.notes.keys.first!]!.revision = 2
        let initialData = try WorkspaceDocumentCodec.encode(initial)
        try initialData.write(to: main)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let preview = try await BackupService().inspectRestoreSource(source)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: main.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: main.path) }
        let repository = JSONWorkspaceRepository(documentURL: main, seed: { initial })

        await #expect(throws: WorkspacePersistenceError.invalidDocument) { _ = try await repository.load() }
        await #expect(throws: WorkspacePersistenceError.invalidDocument) { _ = try await repository.save(restored) }
        await #expect(throws: WorkspacePersistenceError.invalidDocument) {
            _ = try await repository.prepareRestore(preview, rollbackDirectoryURL: directory.url)
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: main.path)
        await #expect(throws: WorkspacePersistenceError.invalidDocument) { _ = try await repository.load() }
        #expect(try await repository.reloadCurrentSourceAfterExternalChange() == .valid(
            try WorkspaceDocumentCodec.decode(initialData)
        ))
        _ = try await repository.prepareRestore(preview, rollbackDirectoryURL: directory.url)
        #expect(try Data(contentsOf: main) == initialData)
    }

    @Test func transientUnreadableValidSourceBlocksSaveAndCommitUntilExplicitReload() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let source = directory.file("restore.json")
        let initial = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var restored = initial
        restored.revision = 2
        restored.notes[restored.notes.keys.first!]!.revision = 2
        restored.notes[restored.notes.keys.first!]!.title = "restored"
        let initialData = try WorkspaceDocumentCodec.encode(initial)
        try initialData.write(to: main)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let repository = JSONWorkspaceRepository(documentURL: main, seed: { initial })
        _ = try await repository.load()
        let prepared = try await repository.prepareRestore(
            try await BackupService().inspectRestoreSource(source),
            rollbackDirectoryURL: directory.url
        )
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: main.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: main.path) }

        await #expect(throws: WorkspacePersistenceError.invalidDocument) {
            _ = try await repository.commitRestore(prepared, state: restored)
        }
        #expect(FileManager.default.fileExists(atPath: prepared.rollbackURL.path) == false)
        await #expect(throws: WorkspacePersistenceError.invalidDocument) { _ = try await repository.save(restored) }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: main.path)
        await #expect(throws: WorkspacePersistenceError.invalidDocument) { _ = try await repository.load() }
        await #expect(throws: WorkspacePersistenceError.invalidDocument) {
            _ = try await repository.commitRestore(prepared, state: restored)
        }
        _ = try await repository.reloadCurrentSourceAfterExternalChange()
        let outcome = try await repository.commitRestore(prepared, state: restored)
        guard case let .file(rollbackURL, _) = outcome.rollback else {
            Issue.record("A readable valid source must produce an exact rollback")
            return
        }
        #expect(try Data(contentsOf: rollbackURL) == initialData)
    }

    @Test func transientUnreadableOpaqueAndAbsentBindingsCannotRestoreUntilReload() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let source = directory.file("restore.json")
        let restored = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let preview = try await BackupService().inspectRestoreSource(source)

        let opaqueMain = directory.file("opaque.json")
        let opaqueBytes = Data("opaque-primary".utf8)
        try opaqueBytes.write(to: opaqueMain)
        let opaque = JSONWorkspaceRepository(documentURL: opaqueMain, seed: { restored })
        await #expect(throws: WorkspacePersistenceError.invalidDocument) { _ = try await opaque.load() }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: opaqueMain.path)
        #expect(try await opaque.reloadCurrentSourceAfterExternalChange() == .unreadableUnknown)
        await #expect(throws: WorkspacePersistenceError.invalidDocument) {
            _ = try await opaque.prepareRestore(preview, rollbackDirectoryURL: directory.url)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: opaqueMain.path)
        await #expect(throws: WorkspacePersistenceError.invalidDocument) {
            _ = try await opaque.prepareRestore(preview, rollbackDirectoryURL: directory.url)
        }
        #expect(try await opaque.reloadCurrentSourceAfterExternalChange() == .opaqueInvalid(
            .init(sha256: WorkspacePersistenceFixtures.sha256(opaqueBytes), byteCount: opaqueBytes.count)
        ))
        _ = try await opaque.prepareRestore(preview, rollbackDirectoryURL: directory.url)

        let absentParent = directory.file("absent-parent")
        try FileManager.default.createDirectory(at: absentParent, withIntermediateDirectories: false)
        let absentMain = absentParent.appendingPathComponent("main.json")
        let absent = JSONWorkspaceRepository(documentURL: absentMain, seed: { restored })
        _ = try await absent.load()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: absentParent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: absentParent.path) }
        #expect(try await absent.reloadCurrentSourceAfterExternalChange() == .unreadableUnknown)
        await #expect(throws: WorkspacePersistenceError.invalidDocument) {
            _ = try await absent.prepareRestore(preview, rollbackDirectoryURL: directory.url)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: absentParent.path)
        await #expect(throws: WorkspacePersistenceError.invalidDocument) {
            _ = try await absent.prepareRestore(preview, rollbackDirectoryURL: directory.url)
        }
        #expect(try await absent.reloadCurrentSourceAfterExternalChange() == .absent)
        _ = try await absent.prepareRestore(preview, rollbackDirectoryURL: directory.url)
    }

    @Test func restoreLockAcquisitionFailureFreezesKnownBindingAndRetainsCapabilityUntilReload() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("main.json")
        let source = directory.file("restore.json")
        let current = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var restored = current
        restored.revision = 2
        restored.notes[restored.notes.keys.first!]!.revision = 2
        let currentData = try WorkspaceDocumentCodec.encode(current)
        try currentData.write(to: main)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let repository = JSONWorkspaceRepository(documentURL: main, seed: { current })
        _ = try await repository.load()
        let prepared = try await repository.prepareRestore(
            try await BackupService().inspectRestoreSource(source),
            rollbackDirectoryURL: directory.url
        )
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.url.path) }

        await #expect(throws: WorkspacePersistenceError.invalidDocument) {
            _ = try await repository.commitRestore(prepared, state: restored)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.url.path)
        #expect(FileManager.default.fileExists(atPath: prepared.rollbackURL.path) == false)
        #expect(try Data(contentsOf: main) == currentData)
        #expect(try await repository.reconcilePendingCommit() == .notCommitted(.init()))
        await #expect(throws: WorkspacePersistenceError.invalidDocument) { _ = try await repository.load() }
        await #expect(throws: WorkspacePersistenceError.invalidDocument) {
            _ = try await repository.commitRestore(prepared, state: restored)
        }
        _ = try await repository.reloadCurrentSourceAfterExternalChange()
        _ = try await repository.commitRestore(prepared, state: restored)
    }
}
