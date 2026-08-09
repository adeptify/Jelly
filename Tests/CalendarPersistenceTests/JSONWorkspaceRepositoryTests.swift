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

    @Test func concurrentSaveAndRestoreSerializeWithoutWritingAnUnpreparedCandidate() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let source = directory.file("restore.json")
        let initial = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var changed = initial
        changed.revision = 2
        changed.notes[changed.notes.keys.first!]!.revision = 2
        changed.notes[changed.notes.keys.first!]!.title = "保存候选"
        var restored = initial
        restored.revision = 3
        restored.notes[restored.notes.keys.first!]!.revision = 3
        restored.notes[restored.notes.keys.first!]!.title = "恢复候选"
        try WorkspaceDocumentCodec.encode(initial).write(to: main)
        try WorkspaceDocumentCodec.encode(restored).write(to: source)
        let repository = JSONWorkspaceRepository(documentURL: main, seed: { initial })
        _ = try await repository.load()
        let prepared = try await repository.prepareRestore(.init(sourceURL: source, rollbackDirectoryURL: directory.url))

        let allowedRevisions = Set([changed.revision, restored.revision])
        async let save: WorkspaceSaveReceipt = repository.save(changed)
        async let restore: WorkspaceSaveReceipt = repository.commitRestore(prepared, state: restored)
        _ = try await (save, restore)

        let final = try WorkspaceDocumentCodec.decode(try await repository.currentDocumentData()).state
        #expect(allowedRevisions.contains(final.revision))
    }
}
