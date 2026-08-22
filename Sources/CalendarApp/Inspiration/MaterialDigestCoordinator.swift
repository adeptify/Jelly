import Foundation
import WorkspaceDomain

@MainActor
final class MaterialDigestCoordinator: MaterialDigestOperating {
    private let store: WorkspaceStore
    private let acquirer: any MaterialAcquiring
    private let audioDownloader: any MaterialAudioDownloading
    private let transcriber: any MaterialTranscribing
    private let summarizer: any MaterialSummarizing
    private var tasks: [InspirationID: Task<Void, Never>] = [:]

    init(
        store: WorkspaceStore,
        acquirer: any MaterialAcquiring,
        audioDownloader: any MaterialAudioDownloading,
        transcriber: any MaterialTranscribing,
        summarizer: any MaterialSummarizing
    ) {
        self.store = store
        self.acquirer = acquirer
        self.audioDownloader = audioDownloader
        self.transcriber = transcriber
        self.summarizer = summarizer
    }

    func start(inspirationID: InspirationID) async {
        guard let source = materialSource(for: inspirationID) else { return }
        let digestID = store.state.materialDigests[inspirationID]?.id ?? MaterialDigestID()
        let runID = MaterialDigestRunID()
        let outcome = try? await store.sendWorkspace(
            .startMaterialDigest(
                .init(
                    inspirationID: inspirationID,
                    digestID: digestID,
                    runID: runID,
                    expectedSourceChecksum: source.sourceChecksum
                )
            )
        )
        guard case .committed = outcome else { return }
        launch(inspirationID: inspirationID, runID: runID, checksum: source.sourceChecksum) {
            try await self.runFromFetching(source: source, runID: runID)
        }
    }

    func confirmModelDownload(inspirationID: InspirationID) async {
        guard let digest = store.state.materialDigests[inspirationID],
              let run = digest.currentRun,
              run.stage == .awaitingModelDownloadConsent,
              let source = materialSource(for: inspirationID),
              source.sourceChecksum == digest.sourceChecksum
        else { return }
        let runID = run.id
        launch(inspirationID: inspirationID, runID: runID, checksum: source.sourceChecksum) {
            try await self.runConfirmedDownload(source: source, runID: runID)
        }
    }

    func cancel(inspirationID: InspirationID) async {
        if let digest = store.state.materialDigests[inspirationID],
           let run = digest.currentRun {
            _ = try? await store.sendWorkspace(
                .cancelMaterialDigest(
                    .init(
                        inspirationID: inspirationID,
                        runID: run.id,
                        sourceChecksum: digest.sourceChecksum
                    )
                )
            )
        }
        tasks[inspirationID]?.cancel()
        tasks[inspirationID] = nil
    }

    func reconcileInterruptedRuns() async {
        for (inspirationID, digest) in store.state.materialDigests {
            guard let run = digest.currentRun else { continue }
            _ = try? await store.sendWorkspace(
                .markInterruptedMaterialDigest(
                    .init(
                        inspirationID: inspirationID,
                        runID: run.id,
                        sourceChecksum: digest.sourceChecksum
                    )
                )
            )
            if run.stage != .awaitingModelDownloadConsent {
                tasks[inspirationID]?.cancel()
                tasks[inspirationID] = nil
            }
        }
    }

    private func launch(
        inspirationID: InspirationID,
        runID: MaterialDigestRunID,
        checksum: String,
        operation: @escaping () async throws -> Void
    ) {
        tasks[inspirationID]?.cancel()
        tasks[inspirationID] = Task { [weak self] in
            defer {
                self?.tasks[inspirationID] = nil
                self?.audioDownloader.cleanup(runID: runID)
            }
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try await operation()
            } catch is CancellationError {
                await self.failIfCurrent(
                    inspirationID: inspirationID,
                    runID: runID,
                    checksum: checksum,
                    error: .cancelled
                )
            } catch let error as MaterialDigestPipelineError {
                await self.failIfCurrent(
                    inspirationID: inspirationID,
                    runID: runID,
                    checksum: checksum,
                    error: error
                )
            } catch {
                await self.failIfCurrent(
                    inspirationID: inspirationID,
                    runID: runID,
                    checksum: checksum,
                    error: nil
                )
            }
        }
    }

    private func runConfirmedDownload(
        source: MaterialSource,
        runID: MaterialDigestRunID
    ) async throws {
        try await advance(.downloadingModel, source: source, runID: runID)
        try await transcriber.prepareModel { _ in }
        try Task.checkCancellation()
        try await advance(.fetchingSource, source: source, runID: runID)
        try await runFromFetching(source: source, runID: runID)
    }

    private func runFromFetching(
        source: MaterialSource,
        runID: MaterialDigestRunID
    ) async throws {
        try Task.checkCancellation()
        let acquisition: MaterialAcquisition
        do {
            acquisition = try await acquirer.acquire(source)
        } catch let error as MaterialDigestPipelineError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MaterialDigestPipelineError.sourceUnavailable
        }
        guard isCurrent(inspirationID: source.inspirationID, runID: runID, checksum: source.sourceChecksum) else {
            return
        }
        switch acquisition {
        case let .transcript(transcript):
            try await summarize(transcript, source: source, runID: runID)
        case let .remoteAudio(asset):
            try await runAudio(asset, source: source, runID: runID)
        }
    }

    private func runAudio(
        _ asset: RemoteAudioAsset,
        source: MaterialSource,
        runID: MaterialDigestRunID
    ) async throws {
        let requirement = await transcriber.modelRequirement()
        guard isCurrent(inspirationID: source.inspirationID, runID: runID, checksum: source.sourceChecksum) else {
            return
        }
        switch requirement {
        case .downloadRequired:
            try await advance(.awaitingModelDownloadConsent, source: source, runID: runID)
            return
        case .ready:
            let fileURL = try await audioDownloader.download(asset, runID: runID) { _ in }
            try Task.checkCancellation()
            guard isCurrent(inspirationID: source.inspirationID, runID: runID, checksum: source.sourceChecksum) else {
                return
            }
            try await advance(.transcribing, source: source, runID: runID)
            let transcript: TimestampedTranscript
            do {
                transcript = try await transcriber.transcribe(fileURL) { _ in }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as MaterialDigestPipelineError {
                throw error
            } catch {
                throw MaterialDigestPipelineError.transcriptionFailed
            }
            try await summarize(transcript, source: source, runID: runID)
        }
    }

    private func summarize(
        _ transcript: TimestampedTranscript,
        source: MaterialSource,
        runID: MaterialDigestRunID
    ) async throws {
        try await advance(.summarizing, source: source, runID: runID)
        let output: MaterialSummarizerOutput
        do {
            output = try await summarizer.summarize(transcript, source: source)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MaterialDigestPipelineError {
            throw error
        } catch {
            throw MaterialDigestPipelineError.summarizationFailed
        }
        try Task.checkCancellation()
        guard isCurrent(inspirationID: source.inspirationID, runID: runID, checksum: source.sourceChecksum) else {
            return
        }
        _ = try await store.sendWorkspace(
            .completeMaterialDigest(
                .init(
                    expectation: .init(
                        inspirationID: source.inspirationID,
                        runID: runID,
                        sourceChecksum: source.sourceChecksum
                    ),
                    transcript: transcript,
                    summary: output.summary,
                    provenance: DigestProvenance(
                        modelIdentifier: "\(output.endpointHost)/\(output.model)",
                        generatedAt: Date.distantPast,
                        inputFingerprint: source.sourceChecksum,
                        summaryContractVersion: output.summaryContractVersion
                    )
                )
            )
        )
    }

    private func advance(
        _ stage: MaterialDigestStage,
        source: MaterialSource,
        runID: MaterialDigestRunID
    ) async throws {
        try Task.checkCancellation()
        guard isCurrent(inspirationID: source.inspirationID, runID: runID, checksum: source.sourceChecksum) else {
            throw CancellationError()
        }
        let outcome = try await store.sendWorkspace(
            .advanceMaterialDigestStage(
                .init(
                    expectation: .init(
                        inspirationID: source.inspirationID,
                        runID: runID,
                        sourceChecksum: source.sourceChecksum
                    ),
                    stage: stage
                )
            )
        )
        guard case .committed = outcome else {
            throw CancellationError()
        }
    }

    private func failIfCurrent(
        inspirationID: InspirationID,
        runID: MaterialDigestRunID,
        checksum: String,
        error: MaterialDigestPipelineError?
    ) async {
        guard isCurrent(inspirationID: inspirationID, runID: runID, checksum: checksum) else { return }
        if error == .cancelled {
            _ = try? await store.sendWorkspace(
                .cancelMaterialDigest(
                    .init(inspirationID: inspirationID, runID: runID, sourceChecksum: checksum)
                )
            )
            return
        }
        let mapped = Self.mappedFailure(error)
        _ = try? await store.sendWorkspace(
            .failMaterialDigest(
                .init(
                    expectation: .init(
                        inspirationID: inspirationID,
                        runID: runID,
                        sourceChecksum: checksum
                    ),
                    code: mapped.code,
                    userMessage: mapped.message
                )
            )
        )
    }

    private func isCurrent(
        inspirationID: InspirationID,
        runID: MaterialDigestRunID,
        checksum: String
    ) -> Bool {
        guard let digest = store.state.materialDigests[inspirationID],
              let run = digest.currentRun
        else { return false }
        return run.id == runID && digest.sourceChecksum == checksum
    }

    private func materialSource(for inspirationID: InspirationID) -> MaterialSource? {
        guard let inspiration = store.state.inspirations[inspirationID],
              inspiration.lifecycle == .active,
              let url = inspiration.rawURL,
              inspiration.inputKind == .url,
              inspiration.resolvedSourceKind == .video || inspiration.resolvedSourceKind == .audio
        else { return nil }
        return MaterialSource(
            inspirationID: inspirationID,
            url: url,
            kind: inspiration.resolvedSourceKind,
            sourceChecksum: WorkspaceChecksum.inspirationSourceChecksum(inspiration)
        )
    }

    private static func mappedFailure(
        _ error: MaterialDigestPipelineError?
    ) -> (code: MaterialDigestFailure.Code, message: String) {
        switch error {
        case .unsupportedSource:
            (.unsupportedSource, "这个链接还不能提炼。")
        case .restrictedSource:
            (.restrictedSource, "来源受限，无法获取字幕或音频。")
        case .sourceUnavailable:
            (.sourceUnavailable, "暂时无法获取材料，原始链接仍然保留。")
        case .modelDownloadFailed:
            (.modelDownloadFailed, "模型下载失败，可以稍后重试。")
        case .transcriptionFailed:
            (.transcriptionFailed, "本机识别失败，原始链接仍然保留。")
        case .modelNotConfigured:
            (.modelNotConfigured, "尚未配置摘要模型，请先在设置中填写。")
        case .summarizationFailed:
            (.summarizationFailed, "摘要请求失败，可以稍后重试。")
        case .invalidSummary:
            (.invalidSummary, "模型返回的摘要无法校验，没有写入占位内容。")
        case .cancelled, .none:
            (.summarizationFailed, "提炼未完成，原始链接仍然保留。")
        }
    }
}
