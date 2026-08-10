import Foundation
import WorkspaceDomain

@MainActor
@Observable final class InspirationViewModel {
    private let store: WorkspaceStore
    private let clock: @Sendable () -> Date
    private let metadataResolver: any URLMetadataResolving

    var captureText = ""
    private(set) var pending: [Inspiration] = []
    private(set) var converted: [Inspiration] = []
    private(set) var archived: [Inspiration] = []
    private(set) var selectedID: InspirationID?
    private(set) var statusMessage: String?

    init(
        store: WorkspaceStore,
        metadataResolver: any URLMetadataResolving = URLMetadataResolver(),
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.metadataResolver = metadataResolver
        self.clock = clock
        refresh()
    }

    var selected: Inspiration? {
        selectedID.flatMap { store.state.inspirations[$0] }
    }

    var pendingCount: Int { pending.count }

    func refresh() {
        let all = Array(store.state.inspirations.values)
        let linked = Set(store.state.inspirationNoteLinks.compactMap { link -> InspirationID? in
            if case let .live(id) = link.source { return id }
            return nil
        })
        pending = all.filter { $0.lifecycle == .active && !linked.contains($0.id) }
            .sorted { $0.createdAt > $1.createdAt }
        converted = all.filter { $0.lifecycle == .active && linked.contains($0.id) }
            .sorted { $0.createdAt > $1.createdAt }
        archived = all.filter { $0.lifecycle == .archived }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func select(_ id: InspirationID?) {
        selectedID = id
    }

    @discardableResult
    func capture(_ raw: String) async throws -> InspirationID {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw InspirationCaptureError.empty }
        let now = clock()
        let id = InspirationID()
        let inspiration: Inspiration
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            inspiration = Inspiration(
                id: id,
                inputKind: .url,
                rawText: nil,
                rawURL: url,
                rawFile: nil,
                resolvedSourceKind: .unknown,
                resolvedMetadata: SourceMetadata(
                    title: nil, siteName: nil, domain: url.host, thumbnailURL: nil, fetchStatus: .loading
                ),
                categoryID: store.calendarState.uncategorizedID,
                lifecycle: .active,
                createdAt: now,
                updatedAt: now
            )
        } else {
            inspiration = Inspiration.text(
                id: id,
                rawText: trimmed,
                categoryID: store.calendarState.uncategorizedID,
                now: now
            )
        }
        let outcome = try await store.sendWorkspace(
            .createInspiration(.init(inspiration: inspiration)),
            undoLabel: "捕获灵感"
        )
        guard case .committed = outcome else { throw InspirationCaptureError.notCommitted }
        captureText = ""
        selectedID = id
        refresh()
        if inspiration.inputKind == .url, let url = inspiration.rawURL {
            Task { await enrichURL(id: id, url: url) }
        }
        return id
    }

    @discardableResult
    func convertSelectedToNote() async throws -> NoteID? {
        guard let inspiration = selected else { return nil }
        if let existing = store.state.inspirationNoteLinks.first(where: {
            if case let .live(id) = $0.source { return id == inspiration.id }
            return false
        }) {
            return existing.noteID
        }
        let now = clock()
        var note = Note.empty(id: NoteID(), categoryID: inspiration.categoryID, now: now)
        note.title = suggestedTitle(for: inspiration)
        note.document = document(for: inspiration)
        let outcome = try await store.sendWorkspace(
            .convertInspirationToNote(.init(inspirationID: inspiration.id, proposedNote: note)),
            undoLabel: "转成笔记"
        )
        refresh()
        switch outcome {
        case .committed:
            return note.id
        case let .noChange(reason, _):
            if case let .inspirationAlreadyConverted(noteID) = reason { return noteID }
            return nil
        default:
            return nil
        }
    }

    @discardableResult
    func archiveSelected() async throws -> Bool {
        guard let id = selectedID else { return false }
        let outcome = try await store.sendWorkspace(.archiveInspiration(id, at: clock()), undoLabel: "归档灵感")
        refresh()
        if case .committed = outcome { return true }
        return false
    }

    @discardableResult
    func restoreSelected() async throws -> Bool {
        guard let id = selectedID else { return false }
        let outcome = try await store.sendWorkspace(.restoreInspiration(id, at: clock()), undoLabel: "恢复灵感")
        refresh()
        if case .committed = outcome { return true }
        return false
    }

    private func enrichURL(id: InspirationID, url: URL) async {
        guard let current = store.state.inspirations[id] else { return }
        do {
            let result = try await metadataResolver.resolve(url)
            let checksum = WorkspaceChecksum.inspirationSourceChecksum(current)
            _ = try await store.sendWorkspace(
                .updateInspirationMetadata(
                    id,
                    expectedSource: .init(sourceChecksum: checksum),
                    metadata: result.metadata,
                    resolvedKind: result.resolvedKind
                )
            )
            refresh()
        } catch {
            statusMessage = "链接元数据获取失败，原文已保存。"
            refresh()
        }
    }

    private func suggestedTitle(for inspiration: Inspiration) -> String {
        if let title = inspiration.resolvedMetadata?.title, !title.isEmpty { return title }
        if let text = inspiration.rawText { return String(text.prefix(40)) }
        return inspiration.rawURL?.host ?? "灵感笔记"
    }

    private func document(for inspiration: Inspiration) -> BlockDocument {
        if let url = inspiration.rawURL {
            let title = inspiration.resolvedMetadata?.title ?? url.absoluteString
            return .init(blocks: [
                .init(
                    id: BlockID(),
                    kind: .link,
                    inlineContent: .init(spans: [.init(text: title, marks: [], linkURL: url)]),
                    taskState: nil,
                    indentLevel: 0
                )
            ])
        }
        return .init(blocks: [
            .init(
                id: BlockID(),
                kind: .paragraph,
                inlineContent: .plain(inspiration.rawText ?? ""),
                taskState: nil,
                indentLevel: 0
            )
        ])
    }
}

enum InspirationCaptureError: Error, Equatable {
    case empty
    case notCommitted
}

struct URLMetadataResolveResult: Sendable {
    let metadata: SourceMetadata
    let resolvedKind: ResolvedSourceKind
}

protocol URLMetadataResolving: AnyObject, Sendable {
    func resolve(_ url: URL) async throws -> URLMetadataResolveResult
}
