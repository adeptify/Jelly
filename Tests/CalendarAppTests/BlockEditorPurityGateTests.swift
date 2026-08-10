import Foundation
import Testing

@Suite("BlockEditorPurityGateTests")
struct BlockEditorPurityGateTests {
    @Test func purityScriptRejectsForbiddenSpellings() throws {
        let result = try runPurityScript(arguments: ["--self-test"])
        #expect(result.status == 0, Comment(rawValue: result.output))
    }

    @Test func productionSourcesPassPurityScan() throws {
        let root = packageRoot()
        let result = try runPurityScript(arguments: [
            root.appendingPathComponent("Sources/CalendarApp/Notes/BlockEditor").path
        ])
        #expect(result.status == 0, Comment(rawValue: result.output))
    }

    private func runPurityScript(arguments: [String]) throws -> (status: Int32, output: String) {
        let root = packageRoot()
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [root.appendingPathComponent("Scripts/verify-block-input-purity.sh").path] + arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
