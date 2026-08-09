import Foundation

struct AppDataURLs: Equatable, Sendable {
    let root: URL
    let mainDocument: URL
    let migrationSnapshotDirectory: URL
    let recoveryManifest: URL
    let draftJournal: URL
    let rollbackDirectory: URL
    let automaticRecoveryDirectory: URL
}

enum AppDataDirectoryResolverError: Error, Equatable, Sendable { case invalidOverride, inaccessibleDirectory }

enum AppDataDirectoryResolver {
    static func resolve(
        environment: [String: String],
        fileManager: FileManager = .default,
        defaultApplicationSupportURL: URL? = nil
    ) throws -> AppDataURLs {
        let root: URL
        if let supplied = environment["JELLY_ACCEPTANCE_DATA_DIRECTORY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !supplied.isEmpty {
            guard !supplied.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
                throw AppDataDirectoryResolverError.invalidOverride
            }
            guard (supplied as NSString).isAbsolutePath else {
                throw AppDataDirectoryResolverError.invalidOverride
            }
            let requested = URL(fileURLWithPath: supplied, isDirectory: true)
            let url = requested.standardizedFileURL
            guard requested.path.hasPrefix("/"), url.path != "/" else {
                throw AppDataDirectoryResolverError.invalidOverride
            }
            root = url
        } else {
            guard let support = defaultApplicationSupportURL
                ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            else {
                throw AppDataDirectoryResolverError.inaccessibleDirectory
            }
            root = support.appendingPathComponent("PersonalCalendar", isDirectory: true).standardizedFileURL
        }
        guard root.path != "/" else { throw AppDataDirectoryResolverError.invalidOverride }
        if fileManager.fileExists(atPath: root.path) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  root.resolvingSymlinksInPath().standardizedFileURL == root
            else { throw AppDataDirectoryResolverError.inaccessibleDirectory }
        } else {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }
        guard root.resolvingSymlinksInPath().standardizedFileURL == root,
              fileManager.isWritableFile(atPath: root.path), fileManager.isReadableFile(atPath: root.path) else {
            throw AppDataDirectoryResolverError.inaccessibleDirectory
        }
        return .init(
            root: root,
            mainDocument: root.appendingPathComponent("calendar-v1.json"),
            migrationSnapshotDirectory: root.appendingPathComponent("calendar-v1.recovery-snapshots", isDirectory: true),
            recoveryManifest: root.appendingPathComponent("calendar-v1.recovery-manifest.json"),
            draftJournal: root.appendingPathComponent("calendar-v1.draft-journal.json"),
            rollbackDirectory: root.appendingPathComponent("restore-rollbacks", isDirectory: true),
            automaticRecoveryDirectory: root.appendingPathComponent("automatic-recovery", isDirectory: true)
        )
    }
}
