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
        "public import WorkspaceDomain",
        "package import WorkspaceDomain",
        "internal import WorkspaceDomain",
        "fileprivate import WorkspaceDomain",
        "private import WorkspaceDomain",
        "@_exported import WorkspaceDomain",
        "@testable import WorkspaceDomain",
        "@_implementationOnly import WorkspaceDomain",
        "@preconcurrency import WorkspaceDomain",
        "  import Foundation",
        "import /* gap */ Foundation",
        "@preconcurrency // keep\nimport WorkspaceDomain",
        "@_exported\n// keep\nimport WorkspaceDomain",
        "public\n// keep\nimport WorkspaceDomain",
        "@preconcurrency\n\nimport WorkspaceDomain",
        "@_spi(FixtureSPI) import WorkspaceDomain",
        "@_weakLinked import WorkspaceDomain"
    ])
    func scannerRejectsHeaderSpellingAttacks(_ invalidSource: String) throws {
        let result = try scanFixture(reducerSource: invalidSource)
        #expect(result.status != 0, Comment(rawValue: "scanner accepted:\n\(invalidSource)\n\(result.output)"))
        #expect(result.output.contains("exact two-import header"))
    }

    @Test(arguments: [
        "import AppKit",
        "@preconcurrency import AppKit",
        "import Foundation; import AppKit",
        "#if os(macOS)\nimport AppKit\n#endif"
    ])
    func scannerRejectsExtraImportsFromRecursiveAST(_ extraImport: String) throws {
        let source = """
        import Foundation
        import WorkspaceDomain

        \(extraImport)
        struct Fixture {}
        """
        let result = try scanFixture(reducerSource: source)
        #expect(result.status != 0, Comment(rawValue: "scanner accepted:\n\(extraImport)\n\(result.output)"))
        #expect(result.output.contains("imports must be exactly Foundation then WorkspaceDomain"))
    }

    @Test(arguments: [
        "public struct Leaked {}",
        "open class Leaked {}",
        "@MainActor\npublic\nfunc leaked() {}",
        "public /* comment */ struct Leaked {}"
    ])
    func scannerRejectsPublicDeclarationsFromAST(_ declaration: String) throws {
        let source = """
        import Foundation
        import WorkspaceDomain

        \(declaration)
        struct Fixture {}
        """
        let result = try scanFixture(reducerSource: source)
        #expect(result.status != 0, Comment(rawValue: "scanner accepted:\n\(declaration)\n\(result.output)"))
        #expect(result.output.contains("Public declaration"))
    }

    private func scanFixture(reducerSource: String) throws -> (status: Int32, output: String) {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-purity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let exactHeader = "import Foundation\nimport WorkspaceDomain\n\n"
        try (exactHeader + "struct BlockEditorSelectionFixture {}\n").write(
            to: fixture.appendingPathComponent("BlockEditorSelection.swift"),
            atomically: true,
            encoding: .utf8
        )
        try (exactHeader + "struct BlockPasteParserFixture {}\n").write(
            to: fixture.appendingPathComponent("BlockPasteParser.swift"),
            atomically: true,
            encoding: .utf8
        )
        try reducerSource.write(
            to: fixture.appendingPathComponent("BlockInputReducer.swift"),
            atomically: true,
            encoding: .utf8
        )

        return try runPurityScript(arguments: [fixture.path])
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
