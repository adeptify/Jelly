import CalendarDomain
import Foundation
import Testing
import WorkspaceDomain

@Suite("MaterialDigestReducerTests")
struct MaterialDigestReducerTests {
    @Test func startCreatesFetchingRunForSupportedURLInspiration() throws {
        let fixture = MaterialDigestReducerFixture()
        let started = try fixture.reduce(.startMaterialDigest(fixture.startPayload))
        let digest = try #require(started.materialDigests[fixture.inspiration.id])
        #expect(digest.id == fixture.digestID)
        #expect(digest.inspirationID == fixture.inspiration.id)
        #expect(digest.sourceChecksum == fixture.sourceChecksum)
        #expect(digest.currentRun?.id == fixture.runID)
        #expect(digest.currentRun?.stage == .fetchingSource)
        #expect(digest.currentRun?.startedAt == fixture.now)
        #expect(digest.currentRun?.updatedAt == fixture.now)
        #expect(digest.result == nil)
        #expect(digest.lastFailure == nil)
        #expect(started.inspirations[fixture.inspiration.id] == fixture.inspiration)
    }

    @Test func completeRequiresExactRunAndSourceAndAtomicallyReplacesResult() throws {
        let fixture = MaterialDigestReducerFixture()
        let started = try fixture.reduce(.startMaterialDigest(fixture.startPayload))
        let summarizing = try fixture.reduce(
            .advanceMaterialDigestStage(fixture.advancePayload(to: .summarizing)),
            from: started
        )
        let completed = try fixture.reduce(
            .completeMaterialDigest(fixture.completePayload),
            from: summarizing
        )
        let digest = try #require(completed.materialDigests[fixture.inspiration.id])
        #expect(digest.currentRun == nil)
        #expect(digest.result == fixture.result)
        #expect(digest.lastFailure == nil)
        #expect(completed.inspirations[fixture.inspiration.id]?.rawURL == fixture.inspiration.rawURL)
    }

    @Test func allowedStageGraphFollowsCaptionAudioAndModelPaths() throws {
        let fixture = MaterialDigestReducerFixture()
        let started = try fixture.reduce(.startMaterialDigest(fixture.startPayload))

        let captionPath = try fixture.reduce(
            fixture.advance(to: .summarizing),
            from: started
        )
        #expect(captionPath.materialDigests[fixture.inspiration.id]?.currentRun?.stage == .summarizing)

        let awaiting = try fixture.reduce(
            fixture.advance(to: .awaitingModelDownloadConsent),
            from: started
        )
        #expect(awaiting.materialDigests[fixture.inspiration.id]?.currentRun?.stage == .awaitingModelDownloadConsent)
        let downloading = try fixture.reduce(
            fixture.advance(to: .downloadingModel),
            from: awaiting
        )
        #expect(downloading.materialDigests[fixture.inspiration.id]?.currentRun?.stage == .downloadingModel)
        let refetch = try fixture.reduce(
            fixture.advance(to: .fetchingSource),
            from: downloading
        )
        #expect(refetch.materialDigests[fixture.inspiration.id]?.currentRun?.stage == .fetchingSource)

        let transcribing = try fixture.reduce(
            fixture.advance(to: .transcribing),
            from: started
        )
        #expect(transcribing.materialDigests[fixture.inspiration.id]?.currentRun?.stage == .transcribing)
        let summarizing = try fixture.reduce(
            fixture.advance(to: .summarizing),
            from: transcribing
        )
        #expect(summarizing.materialDigests[fixture.inspiration.id]?.currentRun?.stage == .summarizing)
    }

    @Test func illegalStageJumpsAreRejectedWithoutChangingState() throws {
        let fixture = MaterialDigestReducerFixture()
        let started = try fixture.reduce(.startMaterialDigest(fixture.startPayload))
        #expect(throws: WorkspaceReducerError.invalidMaterialDigestStage) {
            _ = try fixture.reduce(fixture.advance(to: .downloadingModel), from: started)
        }
        #expect(throws: WorkspaceReducerError.invalidMaterialDigestStage) {
            _ = try fixture.reduce(fixture.advance(to: .fetchingSource), from: started)
        }
        let transcribing = try fixture.reduce(fixture.advance(to: .transcribing), from: started)
        #expect(throws: WorkspaceReducerError.invalidMaterialDigestStage) {
            _ = try fixture.reduce(fixture.advance(to: .awaitingModelDownloadConsent), from: transcribing)
        }
        #expect(started.revision == fixture.workspace.revision + 1)
    }

    @Test func startWhileRunningReturnsAlreadyRunning() throws {
        let fixture = MaterialDigestReducerFixture()
        let started = try fixture.reduce(.startMaterialDigest(fixture.startPayload))
        let again = try fixture.outcome(.startMaterialDigest(fixture.startPayload), from: started)
        #expect(again == .noChange(.materialDigestAlreadyRunning))
        #expect(started.materialDigests[fixture.inspiration.id]?.currentRun?.id == fixture.runID)
    }

    @Test func staleRunAndSourceCompleteAreRejected() throws {
        let fixture = MaterialDigestReducerFixture()
        let started = try fixture.reduce(.startMaterialDigest(fixture.startPayload))
        let summarizing = try fixture.reduce(fixture.advance(to: .summarizing), from: started)

        var staleRun = fixture.completePayload
        staleRun = CompleteMaterialDigestPayload(
            expectation: MaterialDigestRunExpectation(
                inspirationID: fixture.inspiration.id,
                runID: fixture.retryRunID,
                sourceChecksum: fixture.sourceChecksum
            ),
            transcript: fixture.transcript,
            summary: fixture.summary,
            provenance: fixture.provenance
        )
        #expect(try fixture.outcome(.completeMaterialDigest(staleRun), from: summarizing) == .noChange(.staleMaterialDigestRun))

        let staleSource = CompleteMaterialDigestPayload(
            expectation: MaterialDigestRunExpectation(
                inspirationID: fixture.inspiration.id,
                runID: fixture.runID,
                sourceChecksum: "stale-source"
            ),
            transcript: fixture.transcript,
            summary: fixture.summary,
            provenance: fixture.provenance
        )
        #expect(try fixture.outcome(.completeMaterialDigest(staleSource), from: summarizing) == .noChange(.staleMaterialDigestSource))
        #expect(summarizing.materialDigests[fixture.inspiration.id]?.result == nil)
    }

    @Test func cancelThenLateCompleteDoesNotWriteResult() throws {
        let fixture = MaterialDigestReducerFixture()
        let started = try fixture.reduce(.startMaterialDigest(fixture.startPayload))
        let summarizing = try fixture.reduce(fixture.advance(to: .summarizing), from: started)
        let cancelled = try fixture.reduce(.cancelMaterialDigest(fixture.expectation), from: summarizing)
        #expect(cancelled.materialDigests[fixture.inspiration.id]?.currentRun == nil)
        #expect(cancelled.materialDigests[fixture.inspiration.id]?.lastFailure?.code == .cancelled)
        #expect(try fixture.outcome(.completeMaterialDigest(fixture.completePayload), from: cancelled) == .noChange(.materialDigestNotRunning))
        #expect(cancelled.materialDigests[fixture.inspiration.id]?.result == nil)
        #expect(cancelled.inspirations[fixture.inspiration.id] == fixture.inspiration)
    }

    @Test func retryKeepsPreviousResultAndRejectsTheOldFailure() throws {
        let fixture = MaterialDigestReducerFixture()
        let started = try fixture.reduce(.startMaterialDigest(fixture.startPayload))
        let summarizing = try fixture.reduce(fixture.advance(to: .summarizing), from: started)
        let succeeded = try fixture.reduce(.completeMaterialDigest(fixture.completePayload), from: summarizing)
        let retryStart = StartMaterialDigestPayload(
            inspirationID: fixture.inspiration.id,
            digestID: MaterialDigestID(),
            runID: fixture.retryRunID,
            expectedSourceChecksum: fixture.sourceChecksum
        )
        let retrying = try fixture.reduce(.startMaterialDigest(retryStart), from: succeeded, now: fixture.later)
        let digest = try #require(retrying.materialDigests[fixture.inspiration.id])
        #expect(digest.id == fixture.digestID)
        #expect(digest.result == fixture.result)
        #expect(digest.currentRun?.id == fixture.retryRunID)
        #expect(digest.lastFailure == nil)

        let lateOldFailure = FailMaterialDigestPayload(
            expectation: fixture.expectation,
            code: .summarizationFailed,
            userMessage: "摘要失败，原始链接仍然保留。"
        )
        #expect(try fixture.outcome(.failMaterialDigest(lateOldFailure), from: retrying) == .noChange(.staleMaterialDigestRun))
        #expect(retrying.materialDigests[fixture.inspiration.id]?.result == fixture.result)
    }

    @Test func failureAndCancelPreservePreviousSuccessfulResult() throws {
        let fixture = MaterialDigestReducerFixture()
        let succeeded = try fixture.succeededState()
        let retrying = try fixture.reduce(
            .startMaterialDigest(StartMaterialDigestPayload(
                inspirationID: fixture.inspiration.id,
                digestID: fixture.digestID,
                runID: fixture.retryRunID,
                expectedSourceChecksum: fixture.sourceChecksum
            )),
            from: succeeded,
            now: fixture.later
        )
        let failed = try fixture.reduce(
            .failMaterialDigest(.init(
                expectation: MaterialDigestRunExpectation(
                    inspirationID: fixture.inspiration.id,
                    runID: fixture.retryRunID,
                    sourceChecksum: fixture.sourceChecksum
                ),
                code: .sourceUnavailable,
                userMessage: "暂时无法获取材料，原始链接仍然保留。"
            )),
            from: retrying,
            now: fixture.later
        )
        #expect(failed.materialDigests[fixture.inspiration.id]?.result == fixture.result)
        #expect(failed.materialDigests[fixture.inspiration.id]?.lastFailure?.code == .sourceUnavailable)
        #expect(failed.inspirations[fixture.inspiration.id] == fixture.inspiration)

        let retryingAgain = try fixture.reduce(
            .startMaterialDigest(StartMaterialDigestPayload(
                inspirationID: fixture.inspiration.id,
                digestID: fixture.digestID,
                runID: fixture.retryRunID,
                expectedSourceChecksum: fixture.sourceChecksum
            )),
            from: failed,
            now: fixture.later
        )
        let cancelled = try fixture.reduce(
            .cancelMaterialDigest(MaterialDigestRunExpectation(
                inspirationID: fixture.inspiration.id,
                runID: fixture.retryRunID,
                sourceChecksum: fixture.sourceChecksum
            )),
            from: retryingAgain,
            now: fixture.later
        )
        #expect(cancelled.materialDigests[fixture.inspiration.id]?.result == fixture.result)
        #expect(cancelled.materialDigests[fixture.inspiration.id]?.lastFailure?.code == .cancelled)
    }

    @Test func markInterruptedKeepsAwaitingConsentAndInterruptsOtherStages() throws {
        let fixture = MaterialDigestReducerFixture()
        let started = try fixture.reduce(.startMaterialDigest(fixture.startPayload))
        let awaiting = try fixture.reduce(
            fixture.advance(to: .awaitingModelDownloadConsent),
            from: started
        )
        let kept = try fixture.outcome(
            .markInterruptedMaterialDigest(fixture.expectation),
            from: awaiting
        )
        #expect(kept == .noChange(.identical))
        #expect(awaiting.materialDigests[fixture.inspiration.id]?.currentRun?.stage == .awaitingModelDownloadConsent)

        let fetchingInterrupted = try fixture.reduce(
            .markInterruptedMaterialDigest(fixture.expectation),
            from: started
        )
        #expect(fetchingInterrupted.materialDigests[fixture.inspiration.id]?.currentRun == nil)
        #expect(fetchingInterrupted.materialDigests[fixture.inspiration.id]?.lastFailure?.code == .interrupted)
        #expect(fetchingInterrupted.materialDigests[fixture.inspiration.id]?.result == nil)
    }
}

struct MaterialDigestReducerFixture {
    let now = Date(timeIntervalSince1970: 1_800_100_000)
    let later = Date(timeIntervalSince1970: 1_800_100_060)
    let digestID = MaterialDigestID(UUID(uuidString: "00000000-0000-0000-0000-00000000d101")!)
    let runID = MaterialDigestRunID(UUID(uuidString: "00000000-0000-0000-0000-00000000d102")!)
    let retryRunID = MaterialDigestRunID(UUID(uuidString: "00000000-0000-0000-0000-00000000d103")!)
    let inspiration: Inspiration
    let workspace: WorkspaceState

    init() {
        let uncategorizedID = UUID(uuidString: "00000000-0000-0000-0000-00000000d100")!
        inspiration = Inspiration(
            id: InspirationID(UUID(uuidString: "00000000-0000-0000-0000-00000000d110")!),
            inputKind: .url,
            rawText: nil,
            rawURL: URL(string: "https://www.bilibili.com/video/BV1xx411c7mD/")!,
            rawFile: nil,
            resolvedSourceKind: .video,
            resolvedMetadata: nil,
            categoryID: uncategorizedID,
            lifecycle: .active,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        var state = WorkspaceState.empty(
            calendar: CalendarState.empty(uncategorizedID: uncategorizedID, now: now)
        )
        state.revision = 4
        state.inspirations[inspiration.id] = inspiration
        workspace = state
    }

    var sourceChecksum: String {
        WorkspaceChecksum.inspirationSourceChecksum(inspiration)
    }

    var startPayload: StartMaterialDigestPayload {
        StartMaterialDigestPayload(
            inspirationID: inspiration.id,
            digestID: digestID,
            runID: runID,
            expectedSourceChecksum: sourceChecksum
        )
    }

    var expectation: MaterialDigestRunExpectation {
        MaterialDigestRunExpectation(
            inspirationID: inspiration.id,
            runID: runID,
            sourceChecksum: sourceChecksum
        )
    }

    var transcript: TimestampedTranscript {
        TimestampedTranscript(segments: [
            TranscriptSegment(startSeconds: 0, endSeconds: 8, text: "开场"),
            TranscriptSegment(startSeconds: 8, endSeconds: 20, text: "主体")
        ])
    }

    var summary: InspirationSummary {
        InspirationSummary(
            thesis: "核心论点",
            takeaways: ["观点1", "观点2", "观点3"],
            chapters: [
                DigestChapter(startSeconds: 0, title: "开场", points: ["引入"]),
                DigestChapter(startSeconds: 8, title: "主体", points: ["展开"])
            ],
            quotes: [DigestQuote(speaker: "讲者", startSeconds: 8, text: "一句原话")],
            dropped: ["片头"]
        )
    }

    var provenance: DigestProvenance {
        DigestProvenance(
            modelIdentifier: "test-model",
            generatedAt: Date(timeIntervalSince1970: 0),
            inputFingerprint: sourceChecksum,
            summaryContractVersion: "summary-contract-v1"
        )
    }

    var completePayload: CompleteMaterialDigestPayload {
        CompleteMaterialDigestPayload(
            expectation: expectation,
            transcript: transcript,
            summary: summary,
            provenance: provenance
        )
    }

    var result: MaterialDigestResult {
        var stamped = provenance
        stamped.generatedAt = now
        return MaterialDigestResult(
            transcript: transcript,
            summary: summary,
            provenance: stamped,
            completedAt: now
        )
    }

    func advancePayload(
        to stage: MaterialDigestStage,
        runID: MaterialDigestRunID? = nil,
        checksum: String? = nil
    ) -> AdvanceMaterialDigestStagePayload {
        AdvanceMaterialDigestStagePayload(
            expectation: MaterialDigestRunExpectation(
                inspirationID: inspiration.id,
                runID: runID ?? self.runID,
                sourceChecksum: checksum ?? sourceChecksum
            ),
            stage: stage
        )
    }

    func advance(
        to stage: MaterialDigestStage,
        runID: MaterialDigestRunID? = nil,
        checksum: String? = nil
    ) -> WorkspaceCommand {
        .advanceMaterialDigestStage(advancePayload(to: stage, runID: runID, checksum: checksum))
    }

    func reduce(
        _ command: WorkspaceCommand,
        from state: WorkspaceState? = nil,
        now clock: Date? = nil
    ) throws -> WorkspaceState {
        let outcome = try WorkspaceReducer.reduce(
            state ?? workspace,
            command: command,
            now: clock ?? now
        )
        return try #require(outcome.change).state
    }

    func outcome(
        _ command: WorkspaceCommand,
        from state: WorkspaceState? = nil,
        now clock: Date? = nil
    ) throws -> WorkspaceReductionResult {
        try WorkspaceReducer.reduce(state ?? workspace, command: command, now: clock ?? now)
    }

    func succeededState() throws -> WorkspaceState {
        let started = try reduce(.startMaterialDigest(startPayload))
        let summarizing = try reduce(advance(to: .summarizing), from: started)
        return try reduce(.completeMaterialDigest(completePayload), from: summarizing)
    }
}
