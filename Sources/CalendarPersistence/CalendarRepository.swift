import CalendarDomain
import Foundation

public protocol CalendarRepository: Sendable {
    func load() async throws -> CalendarState
    func save(_ state: CalendarState) async throws
    func snapshotCurrentDocument(to destination: URL) async throws
}

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
            if createdTemporary {
                try? fileManager.removeItem(at: temporary)
            }
            throw error
        }
    }
}
