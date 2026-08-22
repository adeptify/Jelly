import Foundation
import Observation
import WorkspaceDomain

@MainActor
@Observable
final class MaterialDigestCoordinator: MaterialDigestOperating {
    private enum TaskPurpose: Equatable {
        case pipeline
        case confirmedModelDownload
    }

    private struct TaskEntry {
        let token: UUID
        let runID: MaterialDigestRunID
        let purpose: TaskPurpose
        let task: Task<Void, Never>
    }

    @ObservationIgnored private let store: WorkspaceStore
    @ObservationIgnored private let acquirer: any MaterialAcquiring
    @ObservationIgnored private let audioDownloader: any MaterialAudioDownloading
    @ObservationIgnored private let transcriber: any MaterialTranscribing
    @ObservationIgnored private let summarizer: any MaterialSummarizing
    @ObservationIgnored private var tasks: [InspirationID: TaskEntry] = [:]
    private var progressValues: [InspirationID: Double] = [:]

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
        launch(
            inspirationID: inspirationID,
            runID: runID,
            checksum: source.sourceChecksum,
            purpose: .pipeline
        ) {
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
        if let existing = tasks[inspirationID],
           existing.runID == runID,
           existing.purpose == .confirmedModelDownload {
            return
        }
        launch(
            inspirationID: inspirationID,
            runID: runID,
            checksum: source.sourceChecksum,
            purpose: .confirmedModelDownload
        ) {
            try await self.runConfirmedDownload(source: source, runID: runID)
        }
    }

    func cancel(inspirationID: InspirationID) async {
        let runningTask = tasks[inspirationID]?.task
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
        runningTask?.cancel()
        progressValues.removeValue(forKey: inspirationID)
    }

    func stopExternalWork(inspirationID: InspirationID) async {
        tasks[inspirationID]?.task.cancel()
        progressValues.removeValue(forKey: inspirationID)
    }

    func progress(for inspirationID: InspirationID) -> Double? {
        progressValues[inspirationID]
    }

    func reconcileInterruptedRuns() async {
        let activeRunIDs = Set(store.state.materialDigests.values.compactMap { $0.currentRun?.id })
        audioDownloader.cleanupOrphans(keeping: activeRunIDs)
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
                tasks[inspirationID]?.task.cancel()
                audioDownloader.cleanup(runID: run.id)
                progressValues.removeValue(forKey: inspirationID)
            }
        }
    }

    private func launch(
        inspirationID: InspirationID,
        runID: MaterialDigestRunID,
        checksum: String,
        purpose: TaskPurpose,
        operation: @escaping () async throws -> Void
    ) {
        let token = UUID()
        tasks[inspirationID]?.task.cancel()
        progressValues.removeValue(forKey: inspirationID)
        let task = Task { [weak self] in
            defer {
                self?.finishTask(inspirationID: inspirationID, runID: runID, token: token)
            }
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try await operation()
            } catch is CancellationError {
                guard self.isTaskCurrent(inspirationID: inspirationID, token: token) else { return }
                await self.failIfCurrent(
                    inspirationID: inspirationID,
                    runID: runID,
                    checksum: checksum,
                    error: .cancelled
                )
            } catch let error as MaterialDigestPipelineError {
                guard self.isTaskCurrent(inspirationID: inspirationID, token: token) else { return }
                await self.failIfCurrent(
                    inspirationID: inspirationID,
                    runID: runID,
                    checksum: checksum,
                    error: error
                )
            } catch {
                guard self.isTaskCurrent(inspirationID: inspirationID, token: token) else { return }
                await self.failIfCurrent(
                    inspirationID: inspirationID,
                    runID: runID,
                    checksum: checksum,
                    error: nil
                )
            }
        }
        tasks[inspirationID] = TaskEntry(token: token, runID: runID, purpose: purpose, task: task)
    }

    private func isTaskCurrent(inspirationID: InspirationID, token: UUID) -> Bool {
        tasks[inspirationID]?.token == token
    }

    private func finishTask(
        inspirationID: InspirationID,
        runID: MaterialDigestRunID,
        token: UUID
    ) {
        guard let current = tasks[inspirationID] else {
            audioDownloader.cleanup(runID: runID)
            return
        }
        guard current.token == token else {
            if current.runID != runID { audioDownloader.cleanup(runID: runID) }
            return
        }
        tasks[inspirationID] = nil
        progressValues.removeValue(forKey: inspirationID)
        audioDownloader.cleanup(runID: runID)
    }

    private func runConfirmedDownload(
        source: MaterialSource,
        runID: MaterialDigestRunID
    ) async throws {
        try await advance(.downloadingModel, source: source, runID: runID)
        try await transcriber.prepareModel(progress: progressHandler(
            inspirationID: source.inspirationID,
            runID: runID
        ))
        try Task.checkCancellation()
        try await advance(.fetchingSource, source: source, runID: runID)
        try await runFromFetching(source: source, runID: runID)
    }

    private func runFromFetching(
        source: MaterialSource,
        runID: MaterialDigestRunID
    ) async throws {
        try Task.checkCancellation()
        guard summarizer.isConfigured else {
            throw MaterialDigestPipelineError.modelNotConfigured
        }
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
        case let .downloadRequired(approximateBytes):
            try await advance(
                .awaitingModelDownloadConsent,
                source: source,
                runID: runID,
                modelDownloadApproximateBytes: approximateBytes
            )
            return
        case .ready:
            let fileURL = try await audioDownloader.download(
                asset,
                runID: runID,
                progress: progressHandler(inspirationID: source.inspirationID, runID: runID)
            )
            try Task.checkCancellation()
            guard isCurrent(inspirationID: source.inspirationID, runID: runID, checksum: source.sourceChecksum) else {
                return
            }
            try await advance(.transcribing, source: source, runID: runID)
            let transcript: TimestampedTranscript
            do {
                transcript = try await transcriber.transcribe(
                    fileURL,
                    progress: progressHandler(inspirationID: source.inspirationID, runID: runID)
                )
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
        runID: MaterialDigestRunID,
        modelDownloadApproximateBytes: Int64? = nil
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
                    stage: stage,
                    modelDownloadApproximateBytes: modelDownloadApproximateBytes
                )
            )
        )
        guard case .committed = outcome else {
            throw CancellationError()
        }
        progressValues.removeValue(forKey: source.inspirationID)
    }

    private func progressHandler(
        inspirationID: InspirationID,
        runID: MaterialDigestRunID
    ) -> @Sendable (Double) -> Void {
        { [weak self] fraction in
            Task { @MainActor [weak self] in
                self?.publishProgress(fraction, inspirationID: inspirationID, runID: runID)
            }
        }
    }

    private func publishProgress(
        _ fraction: Double,
        inspirationID: InspirationID,
        runID: MaterialDigestRunID
    ) {
        guard fraction.isFinite,
              tasks[inspirationID]?.runID == runID,
              store.state.materialDigests[inspirationID]?.currentRun?.id == runID
        else { return }
        let clamped = min(1, max(0, fraction))
        let quantized = Double(Int((clamped * 100).rounded(.down))) / 100
        guard progressValues[inspirationID] != quantized else { return }
        progressValues[inspirationID] = quantized
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
        case .authenticationFailed:
            (.authenticationFailed, "摘要接口拒绝了密钥，请在设置中检查后重试。")
        case .accessDenied:
            (.accessDenied, "当前密钥没有该模型的访问权限，请检查模型或权限。")
        case .summarizationFailed:
            (.summarizationFailed, "摘要请求失败，可以稍后重试。")
        case .contextTooLong:
            (.summarizationFailed, "材料超过当前模型可处理长度")
        case .jsonSchemaUnsupported:
            (.summarizationFailed, "当前接口不支持可校验的 JSON 摘要，请更换兼容端点。")
        case .invalidSummary:
            (.invalidSummary, "模型返回的摘要无法校验，没有写入占位内容。")
        case .insufficientContent:
            (.insufficientContent, "没有识别到可提炼的内容，原始链接仍然保留。")
        case .cancelled, .none:
            (.summarizationFailed, "提炼未完成，原始链接仍然保留。")
        }
    }
}
