import CalendarDomain
import Foundation

public protocol CalendarRepository: Sendable {
    func load() async throws -> CalendarState
    func save(_ state: CalendarState) async throws
    func currentDocumentData() async throws -> Data
    func snapshotCurrentDocument(to destination: URL) async throws
}
