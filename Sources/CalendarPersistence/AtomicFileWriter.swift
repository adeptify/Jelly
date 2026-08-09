import CryptoKit
import Darwin
import Foundation

public protocol AtomicFileWriting: Sendable {
    func replaceAtomically(data: Data, at destination: URL) throws
}

public struct FoundationAtomicFileWriter: AtomicFileWriting {
    public init() {}

    public func replaceAtomically(data: Data, at destination: URL) throws {
        let fileManager = FileManager.default
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        var createdTemporary = false

        do {
            guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            createdTemporary = true
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            if createdTemporary { try? fileManager.removeItem(at: temporary) }
            throw error
        }
    }
}

public enum MainFileCompareAndReplaceResult: Equatable, Sendable {
    case replaced
    case sourceChanged
}

public protocol MainFileCompareAndReplaceWriting: Sendable {
    func createIfAbsent(candidate: Data, at destination: URL) throws -> MainFileCompareAndReplaceResult
    func replaceIfSHA256Matches(
        expectedSHA256: String,
        candidate: Data,
        at destination: URL
    ) throws -> MainFileCompareAndReplaceResult
}

public protocol ExclusiveFileWriting: Sendable {
    func createExclusively(data: Data, at destination: URL) throws
}

public struct FoundationExclusiveFileWriter: ExclusiveFileWriting {
    public init() {}

    public func createExclusively(data: Data, at destination: URL) throws {
        let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteFileExists) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        defer { _ = close(descriptor) }
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            throw error
        }
    }
}

/// This lock/CAS protocol coordinates Jelly processes and other writers that use this type.
/// It cannot make claims about a process that ignores both the advisory lock and file protocol.
public struct FoundationMainFileCompareAndReplaceWriter: MainFileCompareAndReplaceWriting {
    private let writer: any AtomicFileWriting

    public init(writer: any AtomicFileWriting = FoundationAtomicFileWriter()) {
        self.writer = writer
    }

    public func createIfAbsent(candidate: Data, at destination: URL) throws -> MainFileCompareAndReplaceResult {
        try withSharedJellyLock(for: destination) {
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                return .sourceChanged
            }
            try writer.replaceAtomically(data: candidate, at: destination)
            return .replaced
        }
    }

    public func replaceIfSHA256Matches(
        expectedSHA256: String,
        candidate: Data,
        at destination: URL
    ) throws -> MainFileCompareAndReplaceResult {
        try withSharedJellyLock(for: destination) {
            guard let current = try? Data(contentsOf: destination), persistenceSHA256(current) == expectedSHA256 else {
                return .sourceChanged
            }
            try writer.replaceAtomically(data: candidate, at: destination)
            return .replaced
        }
    }

    private func withSharedJellyLock<Result>(
        for destination: URL,
        _ body: () throws -> Result
    ) throws -> Result {
        try withJellyAdvisoryLock(for: destination, body)
    }
}

func persistenceSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func dataReadingNoFollow(at url: URL) throws -> Data {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
    defer { _ = close(descriptor) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    return try handle.readToEnd() ?? Data()
}

func withJellyAdvisoryLock<Result>(
    for protectedURL: URL,
    _ body: () throws -> Result
) throws -> Result {
    let localLock = JellyProcessLockRegistry.shared.lock(for: protectedURL)
    localLock.lock()
    defer { localLock.unlock() }
    let lockURL = protectedURL.deletingLastPathComponent()
        .appendingPathComponent(".\(protectedURL.lastPathComponent).jelly.lock")
    let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw CocoaError(.fileLocking) }
    defer { _ = close(descriptor) }
    guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileLocking) }
    defer { _ = flock(descriptor, LOCK_UN) }
    return try body()
}

private final class JellyProcessLockRegistry: @unchecked Sendable {
    static let shared = JellyProcessLockRegistry()

    private let registryLock = NSLock()
    private var locks: [String: NSLock] = [:]

    func lock(for url: URL) -> NSLock {
        registryLock.withLock {
            let key = url.standardizedFileURL.path
            if let existing = locks[key] { return existing }
            let created = NSLock()
            locks[key] = created
            return created
        }
    }
}
