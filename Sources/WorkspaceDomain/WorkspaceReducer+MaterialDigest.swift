import Foundation

extension WorkspaceReducer {
    static func startMaterialDigest(
        _ payload: StartMaterialDigestPayload,
        in candidate: inout WorkspaceState,
        now: Date
    ) throws -> WorkspaceCommandControl {
        guard let inspiration = candidate.inspirations[payload.inspirationID] else {
            throw WorkspaceReducerError.missingInspiration(payload.inspirationID)
        }
        guard inspiration.lifecycle == .active,
              inspiration.inputKind == .url,
              inspiration.resolvedSourceKind == .video || inspiration.resolvedSourceKind == .audio
        else {
            throw WorkspaceReducerError.invalidInspiration
        }
        let currentChecksum = WorkspaceChecksum.inspirationSourceChecksum(inspiration)
        guard currentChecksum == payload.expectedSourceChecksum else {
            return .result(.noChange(.staleMaterialDigestSource))
        }
        if let existing = candidate.materialDigests[payload.inspirationID], existing.currentRun != nil {
            return .result(.noChange(.materialDigestAlreadyRunning))
        }

        let run = MaterialDigestRun(
            id: payload.runID,
            stage: .fetchingSource,
            startedAt: now,
            updatedAt: now
        )
        if var existing = candidate.materialDigests[payload.inspirationID] {
            existing.currentRun = run
            existing.lastFailure = nil
            existing.updatedAt = now
            candidate.materialDigests[payload.inspirationID] = existing
        } else {
            candidate.materialDigests[payload.inspirationID] = MaterialDigest(
                id: payload.digestID,
                inspirationID: payload.inspirationID,
                sourceChecksum: payload.expectedSourceChecksum,
                currentRun: run,
                result: nil,
                lastFailure: nil,
                createdAt: now,
                updatedAt: now
            )
        }
        return .proceed
    }

    static func advanceMaterialDigestStage(
        _ payload: AdvanceMaterialDigestStagePayload,
        in candidate: inout WorkspaceState,
        now: Date
    ) throws -> WorkspaceCommandControl {
        switch try withCurrentRun(payload.expectation, in: candidate) {
        case let .noChange(reason):
            return .result(.noChange(reason))
        case let .matched(digest, run):
            guard isAllowedStageTransition(from: run.stage, to: payload.stage) else {
                throw WorkspaceReducerError.invalidMaterialDigestStage
            }
            var digest = digest
            var run = run
            run.stage = payload.stage
            run.updatedAt = now
            digest.currentRun = run
            digest.updatedAt = now
            candidate.materialDigests[digest.inspirationID] = digest
            return .proceed
        }
    }

    static func completeMaterialDigest(
        _ payload: CompleteMaterialDigestPayload,
        in candidate: inout WorkspaceState,
        now: Date
    ) throws -> WorkspaceCommandControl {
        switch try withCurrentRun(payload.expectation, in: candidate) {
        case let .noChange(reason):
            return .result(.noChange(reason))
        case let .matched(digest, run):
            guard run.stage == .summarizing else {
                throw WorkspaceReducerError.invalidMaterialDigestStage
            }
            var provenance = payload.provenance
            provenance.generatedAt = now
            var digest = digest
            digest.currentRun = nil
            digest.result = MaterialDigestResult(
                transcript: payload.transcript,
                summary: payload.summary,
                provenance: provenance,
                completedAt: now
            )
            digest.lastFailure = nil
            digest.updatedAt = now
            candidate.materialDigests[digest.inspirationID] = digest
            return .proceed
        }
    }

    static func failMaterialDigest(
        _ payload: FailMaterialDigestPayload,
        in candidate: inout WorkspaceState,
        now: Date
    ) throws -> WorkspaceCommandControl {
        switch try withCurrentRun(payload.expectation, in: candidate) {
        case let .noChange(reason):
            return .result(.noChange(reason))
        case let .matched(digest, _):
            var digest = digest
            digest.currentRun = nil
            digest.lastFailure = MaterialDigestFailure(
                code: payload.code,
                userMessage: payload.userMessage,
                occurredAt: now
            )
            digest.updatedAt = now
            candidate.materialDigests[digest.inspirationID] = digest
            return .proceed
        }
    }

    static func cancelMaterialDigest(
        _ expectation: MaterialDigestRunExpectation,
        in candidate: inout WorkspaceState,
        now: Date
    ) throws -> WorkspaceCommandControl {
        switch try withCurrentRun(expectation, in: candidate) {
        case let .noChange(reason):
            return .result(.noChange(reason))
        case let .matched(digest, _):
            var digest = digest
            digest.currentRun = nil
            digest.lastFailure = MaterialDigestFailure(
                code: .cancelled,
                userMessage: "已取消提炼，原始链接仍然保留。",
                occurredAt: now
            )
            digest.updatedAt = now
            candidate.materialDigests[digest.inspirationID] = digest
            return .proceed
        }
    }

    static func markInterruptedMaterialDigest(
        _ expectation: MaterialDigestRunExpectation,
        in candidate: inout WorkspaceState,
        now: Date
    ) throws -> WorkspaceCommandControl {
        switch try withCurrentRun(expectation, in: candidate) {
        case let .noChange(reason):
            return .result(.noChange(reason))
        case let .matched(digest, run):
            guard run.stage != .awaitingModelDownloadConsent else {
                return .result(.noChange(.identical))
            }
            var digest = digest
            digest.currentRun = nil
            digest.lastFailure = MaterialDigestFailure(
                code: .interrupted,
                userMessage: "上次处理被中断，可以重新提炼。",
                occurredAt: now
            )
            digest.updatedAt = now
            candidate.materialDigests[digest.inspirationID] = digest
            return .proceed
        }
    }

    private enum MaterialDigestRunMatch {
        case matched(MaterialDigest, MaterialDigestRun)
        case noChange(WorkspaceNoChangeReason)
    }

    private static func withCurrentRun(
        _ expectation: MaterialDigestRunExpectation,
        in candidate: WorkspaceState
    ) throws -> MaterialDigestRunMatch {
        guard let inspiration = candidate.inspirations[expectation.inspirationID] else {
            throw WorkspaceReducerError.missingInspiration(expectation.inspirationID)
        }
        guard let digest = candidate.materialDigests[expectation.inspirationID],
              let run = digest.currentRun
        else {
            return .noChange(.materialDigestNotRunning)
        }
        let currentChecksum = WorkspaceChecksum.inspirationSourceChecksum(inspiration)
        if digest.sourceChecksum != expectation.sourceChecksum
            || currentChecksum != expectation.sourceChecksum {
            return .noChange(.staleMaterialDigestSource)
        }
        if run.id != expectation.runID {
            return .noChange(.staleMaterialDigestRun)
        }
        return .matched(digest, run)
    }

    private static func isAllowedStageTransition(
        from: MaterialDigestStage,
        to: MaterialDigestStage
    ) -> Bool {
        switch (from, to) {
        case (.fetchingSource, .summarizing),
             (.fetchingSource, .awaitingModelDownloadConsent),
             (.fetchingSource, .transcribing),
             (.awaitingModelDownloadConsent, .downloadingModel),
             (.downloadingModel, .fetchingSource),
             (.transcribing, .summarizing):
            true
        default:
            false
        }
    }
}
