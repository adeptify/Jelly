import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("WhisperKitMaterialTranscriberContractTests")
struct WhisperKitMaterialTranscriberContractTests {
    @Test func modelRequirementReportsDownloadWhenFolderMissing() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-whisper-missing-\(UUID().uuidString)", isDirectory: true)
        let transcriber = WhisperKitMaterialTranscriber(
            modelDirectory: directory,
            engine: FakeWhisperKitEngine()
        )
        let requirement = await transcriber.modelRequirement()
        #expect(requirement == .downloadRequired(approximateBytes: 626_000_000))
    }

    @Test func modelRequirementReportsReadyWhenValidModelFolderExists() async throws {
        let directory = try makeModelDirectory()
        let transcriber = WhisperKitMaterialTranscriber(
            modelDirectory: directory,
            engine: FakeWhisperKitEngine()
        )
        let requirement = await transcriber.modelRequirement()
        #expect(requirement == .ready)
    }

    @Test func mapsSegmentsDropsBlanksAndKeepsMonotonicTimes() async throws {
        let directory = try makeModelDirectory()
        let engine = FakeWhisperKitEngine(segments: [
            .init(startSeconds: 1, endSeconds: 2, text: "  "),
            .init(startSeconds: 0, endSeconds: 1.5, text: "开场"),
            .init(startSeconds: 1.2, endSeconds: 3, text: "主体"),
            .init(startSeconds: 4, endSeconds: 3, text: "修正")
        ])
        let transcriber = WhisperKitMaterialTranscriber(modelDirectory: directory, engine: engine)
        let result = try await transcriber.transcribe(URL(fileURLWithPath: "/tmp/source-audio.m4a")) { _ in }
        #expect(result.segments.map(\.text) == ["开场", "主体", "修正"])
        #expect(result.segments[0].startSeconds == 0)
        #expect(result.segments[1].startSeconds >= result.segments[0].startSeconds)
        #expect(result.segments[2].endSeconds >= result.segments[2].startSeconds)
    }

    @Test func cancellationStopsPublishingAndLeavesInstalledModel() async throws {
        let directory = try makeModelDirectory()
        let engine = FakeWhisperKitEngine(transcribeDelayNanoseconds: 200_000_000)
        let transcriber = WhisperKitMaterialTranscriber(modelDirectory: directory, engine: engine)
        let task = Task {
            try await transcriber.transcribe(URL(fileURLWithPath: "/tmp/source-audio.m4a")) { _ in }
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("cancelled transcribe should throw")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(await transcriber.modelRequirement() == .ready)
        #expect(engine.transcribeStarted)
        #expect(engine.finishedTranscribe == false)
    }
}

private func makeModelDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("jelly-whisper-ready-\(UUID().uuidString)", isDirectory: true)
    let model = directory.appendingPathComponent(
        "openai_whisper-large-v3-v20240930_626MB",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
    try Data("model".utf8).write(to: model.appendingPathComponent("config.json"))
    return directory
}

private final class FakeWhisperKitEngine: WhisperKitEngine, @unchecked Sendable {
    var segments: [TranscriptSegment]
    var downloadDelayNanoseconds: UInt64
    var transcribeDelayNanoseconds: UInt64
    var downloadStarted = false
    var markedReady = false
    var transcribeStarted = false
    var finishedTranscribe = false

    init(
        segments: [TranscriptSegment] = [
            .init(startSeconds: 0, endSeconds: 1, text: "hello")
        ],
        downloadDelayNanoseconds: UInt64 = 0,
        transcribeDelayNanoseconds: UInt64 = 0
    ) {
        self.segments = segments
        self.downloadDelayNanoseconds = downloadDelayNanoseconds
        self.transcribeDelayNanoseconds = transcribeDelayNanoseconds
    }

    func download(
        variant: String,
        downloadBase: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        downloadStarted = true
        if downloadDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: downloadDelayNanoseconds)
        }
        try Task.checkCancellation()
        markedReady = true
        progress(1)
        return downloadBase.appendingPathComponent("openai_whisper-\(variant)", isDirectory: true)
    }

    func transcribe(
        modelFolder: URL,
        audioPath: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment] {
        transcribeStarted = true
        if transcribeDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: transcribeDelayNanoseconds)
        }
        try Task.checkCancellation()
        finishedTranscribe = true
        progress(1)
        return segments
    }
}
