import AppKit
import Foundation
import WorkspaceDomain

@MainActor
final class BlockDragCoordinator {
    private let session: BlockEditorSession

    init(session: BlockEditorSession) {
        self.session = session
    }

    /// Inputs are stable IDs only. The Task 8 reducer normalizes roots, descendant
    /// closures, no-op drops, and the final `before:` position from its current document.
    @discardableResult
    func move(roots: [BlockID], before target: BlockID?) -> Bool {
        let roots = normalizedRoots(roots)
        guard !roots.isEmpty else { return false }
        return session.dispatchTextCommand(.moveBlockRoots(roots, before: target))
    }

    func moveUp(roots: [BlockID]) -> Bool {
        guard let first = normalizedRoots(roots).first,
              let index = session.document.blocks.firstIndex(where: { $0.id == first }) else { return false }
        guard index > 0 else { return true }
        let target = precedingRoot(before: index)
        return move(roots: roots, before: target)
    }

    func moveDown(roots: [BlockID]) -> Bool {
        guard let last = normalizedRoots(roots).last,
              let index = session.document.blocks.firstIndex(where: { $0.id == last }) else { return false }
        let nextRootStart = closureEnd(startingAt: index) + 1
        guard nextRootStart < session.document.blocks.count else { return true }
        let afterNextClosure = closureEnd(startingAt: nextRootStart) + 1
        let target = afterNextClosure < session.document.blocks.count ? session.document.blocks[afterNextClosure].id : nil
        return move(roots: roots, before: target)
    }

    private func normalizedRoots(_ requested: [BlockID]) -> [BlockID] {
        let blocks = session.document.blocks
        let indexed = requested.compactMap { id in blocks.firstIndex(where: { $0.id == id }).map { ($0, id) } }.sorted { $0.0 < $1.0 }
        var roots: [BlockID] = []
        var coveredThrough = -1
        for (index, id) in indexed where index > coveredThrough {
            roots.append(id)
            coveredThrough = closureEnd(startingAt: index)
        }
        return roots
    }

    private func closureEnd(startingAt start: Int) -> Int {
        let blocks = session.document.blocks
        let level = blocks[start].indentLevel
        var cursor = start + 1
        while cursor < blocks.count, blocks[cursor].indentLevel > level { cursor += 1 }
        return cursor - 1
    }

    private func precedingRoot(before index: Int) -> BlockID? {
        let blocks = session.document.blocks
        var candidate = index - 1
        let currentLevel = blocks[index].indentLevel
        while candidate > 0, blocks[candidate].indentLevel > currentLevel { candidate -= 1 }
        return blocks[candidate].id
    }
}

/// The only AppKit drag representation. It carries stable IDs and no document
/// snapshots, so a stale drag is always normalized against the live session.
@MainActor
final class BlockDragDropHandler {
    static let pasteboardType = "com.adeptify.jelly.block-drag.v1"

    private let session: BlockEditorSession

    init(session: BlockEditorSession) {
        self.session = session
    }

    func payloadData(for roots: [BlockID]) throws -> Data {
        try JSONEncoder().encode(BlockDragPayload(roots: roots.map(\.rawValue)))
    }

    func itemProvider(for roots: [BlockID]) -> NSItemProvider {
        let provider = NSItemProvider()
        guard let data = try? payloadData(for: roots) else { return provider }
        provider.registerDataRepresentation(forTypeIdentifier: Self.pasteboardType, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    func dragRoots(startingAt blockID: BlockID) -> [BlockID] {
        guard case let .blocks(anchor, focus) = session.selection,
              let anchorIndex = session.document.blocks.firstIndex(where: { $0.id == anchor }),
              let focusIndex = session.document.blocks.firstIndex(where: { $0.id == focus }) else {
            return [blockID]
        }
        let lower = min(anchorIndex, focusIndex)
        let upper = max(anchorIndex, focusIndex)
        guard session.document.blocks[lower...upper].contains(where: { $0.id == blockID }) else { return [blockID] }
        return session.document.blocks[lower...upper].map(\.id)
    }

    @discardableResult
    func performDrop(data: Data, before target: BlockID?) -> Bool {
        guard let payload = try? JSONDecoder().decode(BlockDragPayload.self, from: data),
              payload.version == BlockDragPayload.version,
              !payload.roots.isEmpty else { return false }
        return BlockDragCoordinator(session: session).move(
            roots: payload.roots.map(BlockID.init),
            before: target
        )
    }

    /// Returns acceptance synchronously; the actual reduction is marshalled
    /// back to the main actor once AppKit supplies the private payload bytes.
    @discardableResult
    func performDrop(provider: NSItemProvider, before target: BlockID?) -> Bool {
        guard provider.hasItemConformingToTypeIdentifier(Self.pasteboardType) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: Self.pasteboardType) { [weak self] data, _ in
            guard let data else { return }
            Task { @MainActor [weak self] in
                _ = self?.performDrop(data: data, before: target)
            }
        }
        return true
    }
}

private struct BlockDragPayload: Codable {
    static let version = 1
    let version: Int
    let roots: [UUID]

    init(roots: [UUID]) {
        version = Self.version
        self.roots = roots
    }
}
