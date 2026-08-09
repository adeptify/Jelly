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
    case replaced(verifiedRawData: Data)
    case commitUncertain
    case sourceChanged
}

public protocol MainFileCompareAndReplaceWriting: Sendable {
    func createIfAbsent(candidate: Data, at destination: URL) throws -> MainFileCompareAndReplaceResult
    func replaceIfSHA256Matches(
        expectedSHA256: String,
        candidate: Data,
        at destination: URL
    ) throws -> MainFileCompareAndReplaceResult
    /// The caller must already hold Jelly's advisory lock for `destination`.
    func createIfAbsentUnlocked(candidate: Data, at destination: URL) throws -> MainFileCompareAndReplaceResult
    /// The caller must already hold Jelly's advisory lock for `destination`.
    func replaceIfSHA256MatchesUnlocked(
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
            try createIfAbsentUnlocked(candidate: candidate, at: destination)
        }
    }

    public func replaceIfSHA256Matches(
        expectedSHA256: String,
        candidate: Data,
        at destination: URL
    ) throws -> MainFileCompareAndReplaceResult {
        try withSharedJellyLock(for: destination) {
            try replaceIfSHA256MatchesUnlocked(
                expectedSHA256: expectedSHA256,
                candidate: candidate,
                at: destination
            )
        }
    }

    public func createIfAbsentUnlocked(
        candidate: Data,
        at destination: URL
    ) throws -> MainFileCompareAndReplaceResult {
        switch noFollowFileProbe(at: destination) {
        case .confirmedAbsent:
            break
        case .bytes:
            return .sourceChanged
        case .unreadableUnknown:
            return .commitUncertain
        }
        do {
            try writer.replaceAtomically(data: candidate, at: destination)
        } catch {
            return try classifyDestinationAfterWriterFailure(
                candidate: candidate,
                previous: nil,
                at: destination,
                originalError: error
            )
        }
        return verifiedReplacement(candidate: candidate, at: destination)
    }

    public func replaceIfSHA256MatchesUnlocked(
        expectedSHA256: String,
        candidate: Data,
        at destination: URL
    ) throws -> MainFileCompareAndReplaceResult {
        let previous: Data
        switch noFollowFileProbe(at: destination) {
        case let .bytes(data):
            previous = data
        case .confirmedAbsent:
            return .sourceChanged
        case .unreadableUnknown:
            return .commitUncertain
        }
        guard persistenceSHA256(previous) == expectedSHA256 else { return .sourceChanged }
        do {
            try writer.replaceAtomically(data: candidate, at: destination)
        } catch {
            return try classifyDestinationAfterWriterFailure(
                candidate: candidate,
                previous: previous,
                at: destination,
                originalError: error
            )
        }
        return verifiedReplacement(candidate: candidate, at: destination)
    }

    private func classifyDestinationAfterWriterFailure(
        candidate: Data,
        previous: Data?,
        at destination: URL,
        originalError: Error
    ) throws -> MainFileCompareAndReplaceResult {
        switch noFollowFileProbe(at: destination) {
        case let .bytes(current):
            if current == candidate { return .replaced(verifiedRawData: candidate) }
            if current == previous { throw originalError }
            return .commitUncertain
        case .confirmedAbsent:
            if previous == nil { throw originalError }
            return .commitUncertain
        case .unreadableUnknown:
            return .commitUncertain
        }
    }

    private func verifiedReplacement(candidate: Data, at destination: URL) -> MainFileCompareAndReplaceResult {
        guard let readback = try? dataReadingNoFollow(at: destination), readback == candidate else {
            return .commitUncertain
        }
        return .replaced(verifiedRawData: readback)
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

enum NoFollowFileProbe: Equatable, Sendable {
    case bytes(Data)
    case confirmedAbsent
    case unreadableUnknown
}

func noFollowFileProbe(at url: URL) -> NoFollowFileProbe {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else {
        return errno == ENOENT ? .confirmedAbsent : .unreadableUnknown
    }
    defer { _ = close(descriptor) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    do {
        return .bytes(try handle.readToEnd() ?? Data())
    } catch {
        return .unreadableUnknown
    }
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
