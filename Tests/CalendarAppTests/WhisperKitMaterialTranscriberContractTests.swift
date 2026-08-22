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

    @Test func partialModelFolderIsNotReportedReady() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-whisper-partial-\(UUID().uuidString)", isDirectory: true)
        let model = directory.appendingPathComponent(
            "openai_whisper-large-v3-v20240930_626MB",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: model.appendingPathComponent("config.json"))
        let transcriber = WhisperKitMaterialTranscriber(
            modelDirectory: directory,
            engine: FakeWhisperKitEngine()
        )

        #expect(await transcriber.modelRequirement() == .downloadRequired(approximateBytes: 626_000_000))
    }

    @Test func prepareModelRequiresCompleteDownloadedArtifacts() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-whisper-incomplete-download-\(UUID().uuidString)", isDirectory: true)
        let engine = FakeWhisperKitEngine(installCompleteModel: false)
        let transcriber = WhisperKitMaterialTranscriber(modelDirectory: directory, engine: engine)

        do {
            try await transcriber.prepareModel { _ in }
            Issue.record("incomplete model download should not be reported as ready")
        } catch let error as MaterialDigestPipelineError {
            #expect(error == .modelDownloadFailed)
        }
        #expect(await transcriber.modelRequirement() == .downloadRequired(approximateBytes: 626_000_000))
    }

    @Test func recognizesWhisperKitRepositoryLayoutAfterDownloadAndRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-whisper-repository-layout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeWhisperKitEngine(usesRepositoryLayout: true)
        let transcriber = WhisperKitMaterialTranscriber(modelDirectory: directory, engine: engine)

        try await transcriber.prepareModel { _ in }
        #expect(await transcriber.modelRequirement() == .ready)

        let relaunched = WhisperKitMaterialTranscriber(
            modelDirectory: directory,
            engine: FakeWhisperKitEngine(usesRepositoryLayout: true)
        )
        #expect(await relaunched.modelRequirement() == .ready)
    }

    @Test func prepareModelCancellationDoesNotPublishReadyState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-whisper-cancel-download-\(UUID().uuidString)", isDirectory: true)
        let engine = FakeWhisperKitEngine(downloadDelayNanoseconds: 200_000_000)
        let transcriber = WhisperKitMaterialTranscriber(modelDirectory: directory, engine: engine)
        let task = Task { try await transcriber.prepareModel { _ in } }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        do {
            try await task.value
            Issue.record("cancelled model download should throw")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(await transcriber.modelRequirement() == .downloadRequired(approximateBytes: 626_000_000))
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

    @Test func stripsWhisperSpecialTokensFromShortSegments() async throws {
        let directory = try makeModelDirectory()
        let engine = FakeWhisperKitEngine(segments: [
            .init(
                startSeconds: 0,
                endSeconds: 0.8,
                text: "<|startoftranscript|><|zh|><|transcribe|><|0.00|>测试<|endoftext|>"
            ),
            .init(
                startSeconds: 0.8,
                endSeconds: 1.1,
                text: "<|startoftranscript|><|zh|><|transcribe|><|0.00|><|endoftext|>"
            )
        ])
        let transcriber = WhisperKitMaterialTranscriber(modelDirectory: directory, engine: engine)
        let result = try await transcriber.transcribe(URL(fileURLWithPath: "/tmp/source-audio.m4a")) { _ in }
        #expect(result.segments.map(\.text) == ["测试"])
        #expect(result.segments[0].endSeconds == 0.8)
    }

    @Test func dropsPunctuationNoiseAndKeepsSemanticSpeech() async throws {
        let directory = try makeModelDirectory()
        let engine = FakeWhisperKitEngine(segments: [
            .init(startSeconds: 0, endSeconds: 0.4, text: "\""),
            .init(startSeconds: 0.4, endSeconds: 2.0, text: "大家好"),
            .init(startSeconds: 2.0, endSeconds: 2.2, text: "。")
        ])
        let transcriber = WhisperKitMaterialTranscriber(modelDirectory: directory, engine: engine)
        let result = try await transcriber.transcribe(URL(fileURLWithPath: "/tmp/source-audio.m4a")) { _ in }
        #expect(result.segments.map(\.text) == ["大家好"])
    }

    @Test func punctuationOnlyWhisperOutputIsInsufficientContent() async throws {
        let directory = try makeModelDirectory()
        let engine = FakeWhisperKitEngine(segments: [
            .init(startSeconds: 0, endSeconds: 11.0799999, text: "\""),
            .init(
                startSeconds: 0,
                endSeconds: 1,
                text: "<|startoftranscript|><|endoftext|>"
            )
        ])
        let transcriber = WhisperKitMaterialTranscriber(modelDirectory: directory, engine: engine)
        do {
            _ = try await transcriber.transcribe(URL(fileURLWithPath: "/tmp/source-audio.m4a")) { _ in }
            Issue.record("punctuation-only whisper output should not become a transcript")
        } catch let error as MaterialDigestPipelineError {
            #expect(error == .insufficientContent)
        }
    }

    @Test func transcriptionDecodeOptionsSkipSpecialTokens() {
        #expect(WhisperKitMaterialTranscriber.transcriptionDecodeOptionsSkipSpecialTokens)
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
    for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
        let artifact = model.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        try Data("model".utf8).write(to: artifact.appendingPathComponent("coremldata.bin"))
    }
    return directory
}

private final class FakeWhisperKitEngine: WhisperKitEngine, @unchecked Sendable {
    var segments: [TranscriptSegment]
    var downloadDelayNanoseconds: UInt64
    var transcribeDelayNanoseconds: UInt64
    var installCompleteModel: Bool
    var usesRepositoryLayout: Bool
    var downloadStarted = false
    var markedReady = false
    var transcribeStarted = false
    var finishedTranscribe = false

    init(
        segments: [TranscriptSegment] = [
            .init(startSeconds: 0, endSeconds: 1, text: "hello")
        ],
        downloadDelayNanoseconds: UInt64 = 0,
        transcribeDelayNanoseconds: UInt64 = 0,
        installCompleteModel: Bool = true,
        usesRepositoryLayout: Bool = false
    ) {
        self.segments = segments
        self.downloadDelayNanoseconds = downloadDelayNanoseconds
        self.transcribeDelayNanoseconds = transcribeDelayNanoseconds
        self.installCompleteModel = installCompleteModel
        self.usesRepositoryLayout = usesRepositoryLayout
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
        let repository = usesRepositoryLayout
            ? downloadBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            : downloadBase
        let folder = repository.appendingPathComponent("openai_whisper-\(variant)", isDirectory: true)
        if installCompleteModel {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
                try FileManager.default.createDirectory(
                    at: folder.appendingPathComponent("\(name).mlmodelc", isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
        }
        markedReady = true
        progress(1)
        return folder
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
