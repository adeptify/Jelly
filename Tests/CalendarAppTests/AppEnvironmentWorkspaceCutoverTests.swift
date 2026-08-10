import Foundation
import Testing
@testable import CalendarApp

@Suite("AppEnvironmentWorkspaceCutoverTests")
@MainActor
struct AppEnvironmentWorkspaceCutoverTests {
    @Test func productionEnvironmentKeepsUnfinishedWorkspaceModulesDisabled() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-7-environment-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = try AppEnvironment.live(environment: [
            "JELLY_ACCEPTANCE_DATA_DIRECTORY": root.path
        ])

        #expect(environment.features == .production)
        #expect(environment.features == .calendarOnly)
    }

    @Test func liveEnvironmentComposesOneWorkspaceStoreFromTheResolvedDataDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-6c-environment-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let environment = try AppEnvironment.live(environment: [
            "JELLY_ACCEPTANCE_DATA_DIRECTORY": root.path
        ])

        #expect(environment.dataURLs.root == root.standardizedFileURL)
        await environment.store.load()
        #expect(environment.store.phase == .ready)
        #expect(environment.store.calendarState.uncategorizedID != UUID())
    }
}
