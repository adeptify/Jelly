import CalendarDomain
import CalendarPersistence
import Foundation
import WorkspaceDomain

@MainActor
struct AppEnvironment {
    let store: WorkspaceStore
    let dataURLs: AppDataURLs

    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> AppEnvironment {
        let dataURLs = try AppDataDirectoryResolver.resolve(
            environment: environment,
            fileManager: fileManager
        )
        let uncategorizedID = UUID()
        let calendar = CalendarState.empty(uncategorizedID: uncategorizedID, now: Date())
        let seed = WorkspaceState.empty(calendar: calendar)
        let repository = JSONWorkspaceRepository(
            documentURL: dataURLs.mainDocument,
            seed: { seed },
            snapshotDirectoryURL: dataURLs.migrationSnapshotDirectory,
            recoveryManifestURL: dataURLs.recoveryManifest
        )
        let journal = DraftJournalRepository(fileURL: dataURLs.draftJournal)
        return AppEnvironment(
            store: WorkspaceStore(initialState: seed, repository: repository, journal: journal),
            dataURLs: dataURLs
        )
    }

    /// Retained only as the App entry point's diagnostic boundary.  Every
    /// actual persistence dependency is composed above exactly once.
    static func liveOrTerminate() -> AppEnvironment {
        let fileManager = FileManager.default
        do {
            return try live(fileManager: fileManager)
        } catch {
            fatalError("无法创建 Jelly 数据目录：\(error.localizedDescription)")
        }
    }
}
