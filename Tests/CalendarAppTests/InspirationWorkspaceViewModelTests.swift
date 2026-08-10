import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("InspirationWorkspaceViewModelTests")
@MainActor
struct InspirationWorkspaceViewModelTests {
    @Test func textCaptureIsDurableBeforeAnyMetadataWork() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let resolver = SuspendedURLMetadataResolver()
        let model = InspirationViewModel(store: store, metadataResolver: resolver)
        let id = try await model.capture("一段原始灵感文字")
        #expect(store.state.inspirations[id]?.rawText == "一段原始灵感文字")
        #expect(resolver.startedURLs.isEmpty)
        #expect(model.pending.map(\.id).contains(id))
    }

    @Test func urlIsDurableBeforeMetadataStarts() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let resolver = SuspendedURLMetadataResolver()
        let model = InspirationViewModel(store: store, metadataResolver: resolver)
        let id = try await model.capture("https://example.com/article")
        #expect(store.state.inspirations[id]?.rawURL == URL(string: "https://example.com/article"))
        #expect(await waitUntil { resolver.startedURLs.count == 1 })
        #expect(resolver.startedURLs.count == 1)
    }

    @Test func convertToNoteIsIdempotentAndOpensExisting() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let model = InspirationViewModel(store: store)
        let id = try await model.capture("转成笔记的内容")
        model.select(id)
        let first = try await model.convertSelectedToNote()
        let second = try await model.convertSelectedToNote()
        #expect(first != nil)
        #expect(first == second)
        #expect(store.state.notes[first!] != nil)
        #expect(model.converted.map(\.id).contains(id))
    }

    @Test func archiveAndRestorePartitionLifecycle() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let model = InspirationViewModel(store: store)
        let id = try await model.capture("待归档")
        model.select(id)
        #expect(try await model.archiveSelected())
        #expect(model.archived.map(\.id).contains(id))
        #expect(try await model.restoreSelected())
        #expect(model.pending.map(\.id).contains(id))
    }
}

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64 = 200_000_000,
    _ predicate: @MainActor () -> Bool
) async -> Bool {
    let start = DispatchTime.now().uptimeNanoseconds
    while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
        if predicate() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return predicate()
}
