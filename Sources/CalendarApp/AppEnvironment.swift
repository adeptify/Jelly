import CalendarDomain
import CalendarPersistence
import Foundation

@MainActor
struct AppEnvironment {
    let store: CalendarStore
    let backupService: BackupService

    static func live() -> AppEnvironment {
        let fileManager = FileManager.default
        let applicationSupport: URL
        do {
            applicationSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            fatalError("无法定位应用支持目录：\(error.localizedDescription)")
        }

        let applicationDirectory = applicationSupport
            .appendingPathComponent("PersonalCalendar", isDirectory: true)
        do {
            if !fileManager.fileExists(atPath: applicationDirectory.path) {
                try fileManager.createDirectory(
                    at: applicationDirectory,
                    withIntermediateDirectories: true
                )
            }
        } catch {
            fatalError("无法创建日历数据目录：\(error.localizedDescription)")
        }

        let uncategorizedID = UUID()
        let seed = CalendarState.empty(uncategorizedID: uncategorizedID, now: Date())
        let repository = JSONCalendarRepository(
            documentURL: applicationDirectory.appendingPathComponent("calendar-v1.json"),
            seed: { seed }
        )
        return AppEnvironment(
            store: CalendarStore(initialState: seed, repository: repository),
            backupService: BackupService()
        )
    }
}
