import Foundation
import WhisperKit
import WorkspaceDomain

protocol WhisperKitEngine: Sendable {
    func download(
        variant: String,
        downloadBase: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL

    func transcribe(
        modelFolder: URL,
        audioPath: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment]
}

actor WhisperKitMaterialTranscriber: MaterialTranscribing {
    static let variant = "large-v3-v20240930_626MB"
    static let approximateBytes: Int64 = 626_000_000

    private let modelDirectory: URL
    private let engine: any WhisperKitEngine

    init(
        modelDirectory: URL,
        engine: any WhisperKitEngine = LiveWhisperKitEngine()
    ) {
        self.modelDirectory = modelDirectory
        self.engine = engine
    }

    func modelRequirement() async -> MaterialModelRequirement {
        if usableModelFolder() != nil {
            return .ready
        }
        return .downloadRequired(approximateBytes: Self.approximateBytes)
    }

    func prepareModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        if usableModelFolder() != nil { return }
        try Task.checkCancellation()
        do {
            _ = try await engine.download(
                variant: Self.variant,
                downloadBase: modelDirectory,
                progress: progress
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MaterialDigestPipelineError.modelDownloadFailed
        }
        try Task.checkCancellation()
    }

    func transcribe(
        _ fileURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TimestampedTranscript {
        try Task.checkCancellation()
        guard let folder = usableModelFolder() else {
            throw MaterialDigestPipelineError.transcriptionFailed
        }
        let segments: [TranscriptSegment]
        do {
            segments = try await engine.transcribe(
                modelFolder: folder,
                audioPath: fileURL.path,
                progress: progress
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MaterialDigestPipelineError {
            throw error
        } catch {
            throw MaterialDigestPipelineError.transcriptionFailed
        }
        try Task.checkCancellation()
        return TimestampedTranscript(segments: Self.normalized(segments))
    }

    private func usableModelFolder() -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: modelDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return contents.first { url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  url.lastPathComponent.contains(Self.variant)
            else { return false }
            let files = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            return !files.isEmpty
        }
    }

    private static func normalized(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let cleaned = segments
            .map {
                TranscriptSegment(
                    startSeconds: $0.startSeconds,
                    endSeconds: $0.endSeconds,
                    text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            .filter { !$0.text.isEmpty }
            .sorted { $0.startSeconds < $1.startSeconds }
        var previousStart = -Double.infinity
        return cleaned.map { segment in
            let start = max(0, max(segment.startSeconds, previousStart))
            let end = max(segment.endSeconds, start)
            previousStart = start
            return TranscriptSegment(startSeconds: start, endSeconds: end, text: segment.text)
        }
    }
}

struct LiveWhisperKitEngine: WhisperKitEngine {
    func download(
        variant: String,
        downloadBase: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: downloadBase, withIntermediateDirectories: true)
        let folder = try await WhisperKit.download(
            variant: variant,
            downloadBase: downloadBase,
            from: "argmaxinc/whisperkit-coreml",
            progressCallback: { downloadProgress in
                if !Task.isCancelled {
                    progress(downloadProgress.fractionCompleted)
                }
            }
        )
        try Task.checkCancellation()
        return folder
    }

    func transcribe(
        modelFolder: URL,
        audioPath: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TranscriptSegment] {
        let kit = try await WhisperKit(
            WhisperKitConfig(
                modelFolder: modelFolder.path,
                prewarm: true,
                load: true,
                download: false
            )
        )
        let results = try await kit.transcribe(
            audioPath: audioPath,
            decodeOptions: DecodingOptions(),
            callback: { _ in
                if Task.isCancelled { return false }
                progress(0.5)
                return nil
            }
        )
        try Task.checkCancellation()
        progress(1)
        return results.flatMap(\.segments).map { segment in
            TranscriptSegment(
                startSeconds: Double(segment.start),
                endSeconds: Double(segment.end),
                text: segment.text
            )
        }
    }
}
