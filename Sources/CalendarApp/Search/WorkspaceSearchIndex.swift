import Foundation
import WorkspaceDomain

/// Rebuildable local search index. Atomic replace on rebuild; drops deleted IDs
/// by resolving through the current WorkspaceState at query time.
@MainActor
final class WorkspaceSearchIndex {
    private(set) var projection: WorkspaceSearchProjection
    private let fileURL: URL?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(WorkspaceSearchProjection.self, from: data),
           decoded.schemaVersion == WorkspaceSearchProjection.schemaVersion {
            projection = decoded
        } else {
            projection = .init(workspaceRevision: 0, records: [])
        }
    }

    func rebuild(from state: WorkspaceState) throws {
        let next = WorkspaceSearchProjection.build(from: state)
        if let fileURL {
            let data = try JSONEncoder().encode(next)
            let temp = fileURL.appendingPathExtension("tmp")
            try data.write(to: temp, options: .atomic)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: fileURL)
            }
        }
        projection = next
    }

    func ensureCurrent(with state: WorkspaceState) throws {
        if projection.workspaceRevision != state.revision
            || projection.schemaVersion != WorkspaceSearchProjection.schemaVersion {
            try rebuild(from: state)
        }
    }

    func search(
        query: String,
        kind: WorkspaceObjectKind?,
        includeArchived: Bool,
        in state: WorkspaceState
    ) throws -> [WorkspaceSearchRecord] {
        try ensureCurrent(with: state)
        return projection.search(query: query, kind: kind, includeArchived: includeArchived).filter { record in
            switch record.objectID {
            case let .note(id):
                return state.notes[id] != nil
            case let .inspiration(id):
                return state.inspirations[id] != nil
            }
        }
    }
}
