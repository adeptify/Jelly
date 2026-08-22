import Foundation
import WorkspaceDomain

struct MaterialSource: Equatable, Sendable {
    let inspirationID: InspirationID
    let url: URL
    let kind: ResolvedSourceKind
    let sourceChecksum: String
}

enum MaterialAcquisition: Equatable, Sendable {
    case transcript(TimestampedTranscript)
    case remoteAudio(RemoteAudioAsset)
}

struct RemoteAudioAsset: Equatable, Sendable {
    let url: URL
    let requestHeaders: [String: String]
    let estimatedBytes: Int64?
}

struct MaterialSummarizerOutput: Equatable, Sendable {
    let summary: InspirationSummary
    let endpointHost: String
    let model: String
    let summaryContractVersion: String
}

struct MaterialDigestCandidate: Equatable, Sendable {
    let transcript: TimestampedTranscript
    let summarizerOutput: MaterialSummarizerOutput
}

enum MaterialModelRequirement: Equatable, Sendable {
    case ready
    case downloadRequired(approximateBytes: Int64)
}

enum MaterialDigestPipelineError: Error, Equatable, Sendable {
    case unsupportedSource
    case restrictedSource
    case sourceUnavailable
    case modelDownloadFailed
    case transcriptionFailed
    case modelNotConfigured
    case summarizationFailed
    case invalidSummary
    case cancelled
}

protocol MaterialAcquiring: Sendable {
    func acquire(_ source: MaterialSource) async throws -> MaterialAcquisition
}

protocol MaterialAudioDownloading: Sendable {
    func download(
        _ asset: RemoteAudioAsset,
        runID: MaterialDigestRunID,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL
    func cleanup(runID: MaterialDigestRunID)
}

protocol MaterialTranscribing: Sendable {
    func modelRequirement() async -> MaterialModelRequirement
    func prepareModel(progress: @escaping @Sendable (Double) -> Void) async throws
    func transcribe(
        _ fileURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TimestampedTranscript
}

protocol MaterialSummarizing: Sendable {
    func summarize(
        _ transcript: TimestampedTranscript,
        source: MaterialSource
    ) async throws -> MaterialSummarizerOutput
}

@MainActor
protocol MaterialDigestOperating: AnyObject {
    func start(inspirationID: InspirationID) async
    func confirmModelDownload(inspirationID: InspirationID) async
    func cancel(inspirationID: InspirationID) async
    func reconcileInterruptedRuns() async
}
