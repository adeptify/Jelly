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

    @Test func metadataFailureIsPersistedInsteadOfRemainingLoadingForever() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let resolver = SuspendedURLMetadataResolver()
        let model = InspirationViewModel(store: store, metadataResolver: resolver)
        let id = try await model.capture("https://example.com/failure")
        #expect(await waitUntil { resolver.startedURLs.count == 1 })

        resolver.fail(URLMetadataResolverError.httpFailure)

        #expect(await waitUntil {
            store.state.inspirations[id]?.resolvedMetadata?.fetchStatus == .failed
        })
        #expect(model.statusMessage == "链接元数据获取失败，原文已保存。")
    }

    @Test func failedMetadataCanBeRetriedAndRecovered() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let resolver = SuspendedURLMetadataResolver()
        let model = InspirationViewModel(store: store, metadataResolver: resolver)
        let id = try await model.capture("https://example.com/retry")
        #expect(await waitUntil { resolver.startedURLs.count == 1 })
        resolver.fail(URLMetadataResolverError.httpFailure)
        #expect(await waitUntil {
            store.state.inspirations[id]?.resolvedMetadata?.fetchStatus == .failed
        })

        model.select(id)
        await model.retrySelectedMetadata()
        #expect(await waitUntil { resolver.startedURLs.count == 2 })
        #expect(store.state.inspirations[id]?.resolvedMetadata?.fetchStatus == .loading)

        resolver.resume(with: .init(
            metadata: .init(
                title: "重试成功",
                siteName: "Example",
                domain: "example.com",
                thumbnailURL: nil,
                fetchStatus: .succeeded
            ),
            resolvedKind: .article
        ))
        #expect(await waitUntil {
            store.state.inspirations[id]?.resolvedMetadata?.fetchStatus == .succeeded
        })
        #expect(store.state.inspirations[id]?.resolvedMetadata?.title == "重试成功")
        #expect(model.statusMessage == nil)
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

    @Test func archivedInspirationCanBePreviewedAndPermanentlyDeleted() async throws {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let deletedAt = Date(timeIntervalSince1970: 1_700_002_000)
        let model = InspirationViewModel(store: store, clock: { deletedAt })
        let id = try await model.capture("准备删除的灵感")
        model.select(id)
        #expect(try await model.archiveSelected())

        let request = try model.permanentDeleteRequest(for: id)
        let authorization = PermanentDeleteAuthorization(
            subject: request.preview.subject,
            sourceWorkspaceRevision: request.preview.sourceWorkspaceRevision,
            impactChecksum: request.preview.checksum
        )
        #expect(try await model.permanentlyDelete(request, authorization: authorization))
        #expect(store.state.inspirations[id] == nil)
        #expect(model.selectedID == nil)
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
