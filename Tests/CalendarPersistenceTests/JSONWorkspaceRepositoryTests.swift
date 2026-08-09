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

    @Test func secondSaveCannotEnterCASUntilTheFirstLoadedSourceReadbackFinishes() async throws {
        let directory = try WorkspacePersistenceTemporaryDirectory()
        defer { directory.remove() }
        let main = directory.file("calendar-v1.json")
        let initial = try WorkspacePersistenceFixtures.workspaceWithOneNote(revision: 1)
        var first = initial
        first.revision = 2
        first.notes[first.notes.keys.first!]!.revision = 2
        first.notes[first.notes.keys.first!]!.title = "first queued save"
        var second = first
        second.revision = 3
        second.notes[second.notes.keys.first!]!.revision = 3
        second.notes[second.notes.keys.first!]!.title = "second queued save"
        let secondForSave = second
        let expectedSecondData = try WorkspaceDocumentCodec.encode(second)
        try WorkspaceDocumentCodec.encode(initial).write(to: main)
        let writer = WorkspacePersistenceSaveStageWriter()
        let repository = JSONWorkspaceRepository(
            documentURL: main,
            seed: { initial },
            mainFileWriter: writer
        )
        _ = try await repository.load()

        let firstSave = Task { try await repository.save(first) }
        #expect(writer.waitForFirstReplace(timeout: 1))
        let secondSave = Task { try await repository.save(secondForSave) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(writer.replaceCallCount == 1)

        writer.releaseFirstReplace()
        _ = try await firstSave.value
        _ = try await secondSave.value

        #expect(writer.replaceCallCount == 2)
        #expect(try Data(contentsOf: main) == expectedSecondData)
    }
}

final class WorkspacePersistenceSaveStageWriter: MainFileCompareAndReplaceWriting, @unchecked Sendable {
    private let condition = NSCondition()
    private var calls = 0
    private var firstReplaceEntered = false
    private var firstReplaceReleased = false

    var replaceCallCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return calls
    }

    func createIfAbsent(candidate: Data, at destination: URL) throws -> MainFileCompareAndReplaceResult {
        try FoundationMainFileCompareAndReplaceWriter().createIfAbsent(candidate: candidate, at: destination)
    }

    func replaceIfSHA256Matches(
        expectedSHA256: String,
        candidate: Data,
        at destination: URL
    ) throws -> MainFileCompareAndReplaceResult {
        condition.lock()
        calls += 1
        if calls == 1 {
            firstReplaceEntered = true
            condition.broadcast()
            while !firstReplaceReleased { condition.wait() }
        }
        condition.unlock()
        return try FoundationMainFileCompareAndReplaceWriter().replaceIfSHA256Matches(
            expectedSHA256: expectedSHA256,
            candidate: candidate,
            at: destination
        )
    }

    func waitForFirstReplace(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !firstReplaceEntered {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func releaseFirstReplace() {
        condition.lock()
        firstReplaceReleased = true
        condition.broadcast()
        condition.unlock()
    }
}
