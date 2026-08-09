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
        try rejectExistingSymlinkAncestors(of: root, fileManager: fileManager)
        if fileManager.fileExists(atPath: root.path) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  root.resolvingSymlinksInPath().standardizedFileURL == root
            else { throw AppDataDirectoryResolverError.inaccessibleDirectory }
        } else {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }
        try rejectExistingSymlinkAncestors(of: root, fileManager: fileManager)
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

    /// Inspect every existing component before `createDirectory` is allowed to
    /// follow it.  This prevents a missing tail below an attacker-controlled
    /// symlink from being created outside the requested root.
    private static func rejectExistingSymlinkAncestors(of root: URL, fileManager: FileManager) throws {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in root.standardizedFileURL.pathComponents.dropFirst() {
            current.appendPathComponent(component, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: current.path, isDirectory: &isDirectory) else { break }
            // `/var` is the platform's canonical compatibility alias on
            // macOS. Foundation preserves it as the same sandbox root; all
            // caller-controlled components below it still receive no-follow
            // inspection.
            if current.path != "/var",
               (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw AppDataDirectoryResolverError.inaccessibleDirectory
            }
            guard isDirectory.boolValue || current.standardizedFileURL == root.standardizedFileURL else {
                throw AppDataDirectoryResolverError.inaccessibleDirectory
            }
        }
    }
}
