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

    @Test(arguments: [
        "import Foundation; import AppKit",
        "import Foundation\n@preconcurrency\nimport SwiftUI",
        "import Foundation\npublic\nstruct Leaked {}",
        "import Foundation\n@MainActor\nnonisolated public\nfunc leaked() {}",
        "import Foundation\npublic /* comment */ struct Leaked {}"
    ])
    func scannerRejectsLegalMultilineAndSemicolonBypasses(_ invalidSource: String) throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-purity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        for name in ["BlockInputReducer.swift", "BlockEditorSelection.swift", "BlockPasteParser.swift"] {
            try "import Foundation\nstruct Fixture {}\n".write(
                to: fixture.appendingPathComponent(name),
                atomically: true,
                encoding: .utf8
            )
        }
        try invalidSource.write(
            to: fixture.appendingPathComponent("BlockInputReducer.swift"),
            atomically: true,
            encoding: .utf8
        )

        let result = try runPurityScript(arguments: [fixture.path])
        #expect(result.status != 0, Comment(rawValue: "scanner accepted:\n\(invalidSource)\n\(result.output)"))
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
