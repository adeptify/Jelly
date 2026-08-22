import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("MaterialDigestCoordinatorTests")
@MainActor
struct MaterialDigestCoordinatorTests {
    @Test func captionPathSkipsDownloaderAndTranscriberThenCompletes() async throws {
        let harness = try await MaterialDigestCoordinatorHarness.caption()
        await harness.coordinator.start(inspirationID: harness.inspirationID)

        #expect(await waitUntil {
            harness.store.state.materialDigests[harness.inspirationID]?.result != nil
        })
        #expect(harness.downloader.downloadCount == 0)
        #expect(await harness.transcriber.transcribeCount == 0)
        let digest = try #require(harness.store.state.materialDigests[harness.inspirationID])
        #expect(digest.currentRun == nil)
        #expect(digest.result?.summary.thesis == "核心论点")
        #expect(digest.result?.provenance.summaryContractVersion == "summary-contract-v1")
        #expect(await waitUntil { harness.downloader.cleanedRunIDs.count == 1 })
    }

    @Test func audioPathDownloadsAndTranscribesWhenModelReady() async throws {
        let harness = try await MaterialDigestCoordinatorHarness.audio(modelReady: true)
        await harness.coordinator.start(inspirationID: harness.inspirationID)
        #expect(await waitUntil {
            harness.store.state.materialDigests[harness.inspirationID]?.result != nil
        })
        #expect(harness.downloader.downloadCount == 1)
        #expect(await harness.transcriber.transcribeCount == 1)
        #expect(await harness.transcriber.prepareCount == 0)
    }

    @Test func audioPathStopsAtAwaitingConsentWithoutDownloading() async throws {
        let harness = try await MaterialDigestCoordinatorHarness.audio(modelReady: false)
        await harness.coordinator.start(inspirationID: harness.inspirationID)

        #expect(await waitUntil {
            harness.store.state.materialDigests[harness.inspirationID]?.currentRun?.stage
                == .awaitingModelDownloadConsent
        })
        #expect(harness.downloader.downloadCount == 0)
        #expect(await harness.transcriber.prepareCount == 0)
        #expect(harness.store.state.materialDigests[harness.inspirationID]?.result == nil)
    }

    @Test func cancelPreventsLateSummaryFromWritingBack() async throws {
        let harness = try await MaterialDigestCoordinatorHarness.caption(summarizer: .suspended)
        await harness.coordinator.start(inspirationID: harness.inspirationID)
        #expect(await waitUntil { harness.summarizer.started })

        await harness.coordinator.cancel(inspirationID: harness.inspirationID)
        #expect(await waitUntil {
            harness.store.state.materialDigests[harness.inspirationID]?.lastFailure?.code == .cancelled
        })

        harness.summarizer.resume(with: MaterialDigestCoordinatorHarness.validOutput)
        try await Task.sleep(for: .milliseconds(40))
        #expect(harness.store.state.materialDigests[harness.inspirationID]?.result == nil)
        #expect(harness.store.state.materialDigests[harness.inspirationID]?.lastFailure?.code == .cancelled)
    }

    @Test func reconcileInterruptsActiveRunsButKeepsAwaitingConsent() async throws {
        let fetching = try await MaterialDigestCoordinatorHarness.caption(summarizer: .suspended)
        await fetching.coordinator.start(inspirationID: fetching.inspirationID)
        #expect(await waitUntil { fetching.summarizer.started })
        await fetching.coordinator.reconcileInterruptedRuns()
        #expect(await waitUntil {
            fetching.store.state.materialDigests[fetching.inspirationID]?.lastFailure?.code == .interrupted
        })

        let awaiting = try await MaterialDigestCoordinatorHarness.audio(modelReady: false)
        await awaiting.coordinator.start(inspirationID: awaiting.inspirationID)
        #expect(await waitUntil {
            awaiting.store.state.materialDigests[awaiting.inspirationID]?.currentRun?.stage
                == .awaitingModelDownloadConsent
        })
        await awaiting.coordinator.reconcileInterruptedRuns()
        #expect(
            awaiting.store.state.materialDigests[awaiting.inspirationID]?.currentRun?.stage
                == .awaitingModelDownloadConsent
        )
    }

    @Test func retryKeepsPreviousResult() async throws {
        let harness = try await MaterialDigestCoordinatorHarness.caption()
        await harness.coordinator.start(inspirationID: harness.inspirationID)
        #expect(await waitUntil {
            harness.store.state.materialDigests[harness.inspirationID]?.result != nil
        })
        let first = try #require(harness.store.state.materialDigests[harness.inspirationID]?.result)

        harness.acquirer.result = .remoteAudio(MaterialDigestCoordinatorHarness.audioAsset)
        await harness.transcriber.setRequirement(.downloadRequired(approximateBytes: 626_000_000))
        await harness.coordinator.start(inspirationID: harness.inspirationID)
        #expect(await waitUntil {
            harness.store.state.materialDigests[harness.inspirationID]?.currentRun?.stage
                == .awaitingModelDownloadConsent
        })
        #expect(harness.store.state.materialDigests[harness.inspirationID]?.result == first)
    }

    @Test func pipelineErrorsMapToSafeChineseMessages() async throws {
        let restricted = try await MaterialDigestCoordinatorHarness.caption()
        restricted.acquirer.error = MaterialDigestPipelineError.restrictedSource
        await restricted.coordinator.start(inspirationID: restricted.inspirationID)
        #expect(await waitUntil {
            restricted.store.state.materialDigests[restricted.inspirationID]?.lastFailure?.code
                == .restrictedSource
        })
        let restrictedMessage = try #require(
            restricted.store.state.materialDigests[restricted.inspirationID]?.lastFailure?.userMessage
        )
        #expect(restrictedMessage.contains("受限"))
        #expect(!restrictedMessage.contains("sk-"))
        #expect(!restrictedMessage.contains("Bearer "))

        let unconfigured = try await MaterialDigestCoordinatorHarness.caption()
        unconfigured.summarizer.error = MaterialDigestPipelineError.modelNotConfigured
        await unconfigured.coordinator.start(inspirationID: unconfigured.inspirationID)
        #expect(await waitUntil {
            unconfigured.store.state.materialDigests[unconfigured.inspirationID]?.lastFailure?.code
                == .modelNotConfigured
        })
        let unconfiguredMessage = try #require(
            unconfigured.store.state.materialDigests[unconfigured.inspirationID]?.lastFailure?.userMessage
        )
        #expect(unconfiguredMessage.contains("配置"))
        #expect(!unconfiguredMessage.lowercased().contains("sk-"))

        let invalid = try await MaterialDigestCoordinatorHarness.caption()
        invalid.summarizer.error = MaterialDigestPipelineError.invalidSummary
        await invalid.coordinator.start(inspirationID: invalid.inspirationID)
        #expect(await waitUntil {
            invalid.store.state.materialDigests[invalid.inspirationID]?.lastFailure?.code == .invalidSummary
        })
        #expect(
            invalid.store.state.materialDigests[invalid.inspirationID]?.lastFailure?.userMessage
                == "模型返回的摘要无法校验，没有写入占位内容。"
        )
    }
}

@MainActor
private struct MaterialDigestCoordinatorHarness {
    let store: WorkspaceStore
    let inspirationID: InspirationID
    let acquirer: FixtureMaterialAcquirer
    let downloader: RecordingMaterialAudioDownloader
    let transcriber: FakeMaterialTranscriber
    let summarizer: ControllableMaterialSummarizer
    let coordinator: MaterialDigestCoordinator

    static let audioAsset = RemoteAudioAsset(
        url: URL(string: "https://cdn.example.com/episode.m4a")!,
        requestHeaders: ["Referer": "https://www.xiaoyuzhoufm.com/episode/1"],
        estimatedBytes: 1_024
    )

    static let validOutput = MaterialSummarizerOutput(
        summary: InspirationSummary(
            thesis: "核心论点",
            takeaways: ["观点1", "观点2", "观点3"],
            chapters: [
                DigestChapter(startSeconds: 0, title: "开场", points: ["引入"]),
                DigestChapter(startSeconds: 8, title: "主体", points: ["展开"])
            ],
            quotes: [DigestQuote(speaker: "讲者", startSeconds: 8, text: "一句原话")],
            dropped: ["片头"]
        ),
        endpointHost: "api.example.com",
        model: "test-model",
        summaryContractVersion: "summary-contract-v1"
    )

    static let transcript = TimestampedTranscript(segments: [
        TranscriptSegment(startSeconds: 0, endSeconds: 8, text: "开场"),
        TranscriptSegment(startSeconds: 8, endSeconds: 20, text: "主体")
    ])

    enum SummarizerMode {
        case immediate
        case suspended
    }

    static func caption(summarizer mode: SummarizerMode = .immediate) async throws -> MaterialDigestCoordinatorHarness {
        try await make(
            acquisition: .transcript(transcript),
            modelReady: true,
            summarizer: mode
        )
    }

    static func audio(modelReady: Bool) async throws -> MaterialDigestCoordinatorHarness {
        try await make(
            acquisition: .remoteAudio(audioAsset),
            modelReady: modelReady,
            summarizer: .immediate
        )
    }

    private static func make(
        acquisition: MaterialAcquisition,
        modelReady: Bool,
        summarizer mode: SummarizerMode
    ) async throws -> MaterialDigestCoordinatorHarness {
        let calendar = makeEmptyState()
        let store = WorkspaceStore(
            initialState: .empty(calendar: calendar),
            repository: InMemoryWorkspaceRepository(initialState: calendar)
        )
        await store.load()
        let url = URL(string: "https://www.bilibili.com/video/BV1xx411c7mD/")!
        let now = Date(timeIntervalSince1970: 1_800_300_000)
        let inspiration = Inspiration(
            id: InspirationID(),
            inputKind: .url,
            rawText: nil,
            rawURL: url,
            rawFile: nil,
            resolvedSourceKind: .video,
            resolvedMetadata: nil,
            categoryID: calendar.uncategorizedID,
            lifecycle: .active,
            createdAt: now,
            updatedAt: now
        )
        _ = try await store.sendWorkspace(.createInspiration(.init(inspiration: inspiration)))
        let acquirer = FixtureMaterialAcquirer(result: acquisition)
        let downloader = RecordingMaterialAudioDownloader()
        let transcriber = FakeMaterialTranscriber(
            requirement: modelReady
                ? .ready
                : .downloadRequired(approximateBytes: 626_000_000),
            transcript: transcript
        )
        let summarizer = ControllableMaterialSummarizer(
            mode: mode == .suspended ? .suspended : .immediate,
            output: validOutput
        )
        let coordinator = MaterialDigestCoordinator(
            store: store,
            acquirer: acquirer,
            audioDownloader: downloader,
            transcriber: transcriber,
            summarizer: summarizer
        )
        return .init(
            store: store,
            inspirationID: inspiration.id,
            acquirer: acquirer,
            downloader: downloader,
            transcriber: transcriber,
            summarizer: summarizer,
            coordinator: coordinator
        )
    }
}

private final class FixtureMaterialAcquirer: MaterialAcquiring, @unchecked Sendable {
    var result: MaterialAcquisition
    var error: MaterialDigestPipelineError?

    init(result: MaterialAcquisition) {
        self.result = result
    }

    func acquire(_ source: MaterialSource) async throws -> MaterialAcquisition {
        if let error { throw error }
        return result
    }
}

private final class RecordingMaterialAudioDownloader: MaterialAudioDownloading, @unchecked Sendable {
    var downloadCount = 0
    var cleanedRunIDs: [MaterialDigestRunID] = []

    func download(
        _ asset: RemoteAudioAsset,
        runID: MaterialDigestRunID,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        downloadCount += 1
        progress(1)
        return URL(fileURLWithPath: "/tmp/jelly-fixture-audio.m4a")
    }

    func cleanup(runID: MaterialDigestRunID) {
        cleanedRunIDs.append(runID)
    }
}

private actor FakeMaterialTranscriber: MaterialTranscribing {
    var requirement: MaterialModelRequirement
    var prepareCount = 0
    var transcribeCount = 0
    let transcript: TimestampedTranscript

    init(requirement: MaterialModelRequirement, transcript: TimestampedTranscript) {
        self.requirement = requirement
        self.transcript = transcript
    }

    func modelRequirement() async -> MaterialModelRequirement { requirement }

    func setRequirement(_ value: MaterialModelRequirement) {
        requirement = value
    }

    func prepareModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        prepareCount += 1
        progress(1)
    }

    func transcribe(
        _ fileURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TimestampedTranscript {
        transcribeCount += 1
        progress(1)
        return transcript
    }
}

private final class ControllableMaterialSummarizer: MaterialSummarizing, @unchecked Sendable {
    enum Mode {
        case immediate
        case suspended
    }

    var started = false
    var error: MaterialDigestPipelineError?
    private let mode: Mode
    private let output: MaterialSummarizerOutput
    private var continuation: CheckedContinuation<MaterialSummarizerOutput, Error>?

    init(mode: Mode, output: MaterialSummarizerOutput) {
        self.mode = mode
        self.output = output
    }

    func summarize(
        _ transcript: TimestampedTranscript,
        source: MaterialSource
    ) async throws -> MaterialSummarizerOutput {
        started = true
        if let error { throw error }
        switch mode {
        case .immediate:
            return output
        case .suspended:
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                }
            } onCancel: {
                self.continuation?.resume(throwing: CancellationError())
                self.continuation = nil
            }
        }
    }

    func resume(with output: MaterialSummarizerOutput) {
        continuation?.resume(returning: output)
        continuation = nil
    }
}

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64 = 800_000_000,
    _ predicate: @MainActor () -> Bool
) async -> Bool {
    let start = DispatchTime.now().uptimeNanoseconds
    while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
        if predicate() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return predicate()
}
