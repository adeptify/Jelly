import Foundation
import Observation
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
    case authenticationFailed
    case accessDenied
    case summarizationFailed
    case contextTooLong
    case jsonSchemaUnsupported
    case invalidSummary
    case insufficientContent
    case cancelled
}

enum MaterialTranscriptSemantics {
    static func hasSemanticContent(_ transcript: TimestampedTranscript) -> Bool {
        transcript.segments.contains { hasSemanticContent($0.text) }
    }

    static func hasSemanticContent(_ text: String) -> Bool {
        strippingWhisperSpecialTokens(text).unicodeScalars.contains {
            CharacterSet.alphanumerics.contains($0)
        }
    }

    static func strippingWhisperSpecialTokens(_ text: String) -> String {
        var result = text
        var searchStart = result.startIndex
        while searchStart < result.endIndex,
              let start = result.range(of: "<|", range: searchStart..<result.endIndex) {
            guard let end = result.range(of: "|>", range: start.upperBound..<result.endIndex) else {
                break
            }
            let inner = String(result[start.upperBound..<end.lowerBound])
            if isAllowlistedWhisperControlToken(inner) {
                result.removeSubrange(start.lowerBound..<end.upperBound)
                searchStart = start.lowerBound
            } else {
                searchStart = end.upperBound
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isAllowlistedWhisperControlToken(_ inner: String) -> Bool {
        if namedWhisperControlTokens.contains(inner) { return true }
        if isWhisperLanguageToken(inner) { return true }
        return isWhisperTimestampToken(inner)
    }

    private static let namedWhisperControlTokens: Set<String> = [
        "startoftranscript",
        "endoftext",
        "transcribe",
        "translate",
        "nospeech",
        "notimestamps",
        "startofprev",
        "startoflm"
    ]

    private static func isWhisperLanguageToken(_ inner: String) -> Bool {
        (2...3).contains(inner.count)
            && inner.unicodeScalars.allSatisfy { CharacterSet.lowercaseLetters.contains($0) }
    }

    private static func isWhisperTimestampToken(_ inner: String) -> Bool {
        let parts = inner.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts[0].count <= 3
        else { return false }
        return parts.count == 1 || parts[1].count <= 3
    }
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
    func cleanupOrphans(keeping activeRunIDs: Set<MaterialDigestRunID>)
}

extension MaterialAudioDownloading {
    func cleanupOrphans(keeping activeRunIDs: Set<MaterialDigestRunID>) {}
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
    var isConfigured: Bool { get }
    func summarize(
        _ transcript: TimestampedTranscript,
        source: MaterialSource
    ) async throws -> MaterialSummarizerOutput
}

@MainActor
protocol MaterialDigestOperating: AnyObject, Observable {
    func start(inspirationID: InspirationID) async
    func confirmModelDownload(inspirationID: InspirationID) async
    func cancel(inspirationID: InspirationID) async
    func stopExternalWork(inspirationID: InspirationID) async
    func reconcileInterruptedRuns() async
    func progress(for inspirationID: InspirationID) -> Double?
}
