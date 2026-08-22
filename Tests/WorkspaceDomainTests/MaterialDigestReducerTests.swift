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

    @Test func writingAndUpdatingDigestPreservesUserBlocksAndIsIdempotent() throws {
        let fixture = MaterialDigestReducerFixture()
        let succeeded = try fixture.succeededState()
        let noteID = NoteID()
        let userBlock = DocumentBlock(
            id: BlockID(),
            kind: .paragraph,
            inlineContent: .plain("这是用户自己写的内容"),
            taskState: nil,
            indentLevel: 0
        )
        var note = Note.empty(id: noteID, categoryID: fixture.inspiration.categoryID, now: fixture.now)
        note.title = "材料笔记"
        note.document = BlockDocument(blocks: [userBlock])
        let converted = try fixture.reduce(
            .convertInspirationToNote(.init(
                inspirationID: fixture.inspiration.id,
                proposedNote: note
            )),
            from: succeeded
        )

        let firstResult = try #require(converted.materialDigests[fixture.inspiration.id]?.result)
        let firstFingerprint = try WorkspaceChecksum.materialDigestResultFingerprint(firstResult)
        let firstDigestBlock = DocumentBlock(
            id: BlockID(),
            kind: .paragraph,
            inlineContent: .plain("第一版摘要"),
            taskState: nil,
            indentLevel: 0
        )
        let firstWrite = try fixture.reduce(
            .writeMaterialDigestToNote(.init(
                inspirationID: fixture.inspiration.id,
                noteID: noteID,
                expectedNoteRevision: try #require(converted.notes[noteID]?.revision),
                resultFingerprint: firstFingerprint,
                proposedBlocks: [firstDigestBlock]
            )),
            from: converted
        )
        #expect(firstWrite.notes[noteID]?.document.blocks == [userBlock, firstDigestBlock])
        #expect(try fixture.outcome(
            .writeMaterialDigestToNote(.init(
                inspirationID: fixture.inspiration.id,
                noteID: noteID,
                expectedNoteRevision: try #require(firstWrite.notes[noteID]?.revision),
                resultFingerprint: firstFingerprint,
                proposedBlocks: [DocumentBlock(
                    id: BlockID(),
                    kind: .paragraph,
                    inlineContent: .plain("不该重复写入"),
                    taskState: nil,
                    indentLevel: 0
                )]
            )),
            from: firstWrite
        ) == .noChange(.materialDigestAlreadyWritten(noteID)))

        var retried = firstWrite
        retried.materialDigests[fixture.inspiration.id]?.result?.summary.thesis = "更新后的核心论点"
        let updatedResult = try #require(retried.materialDigests[fixture.inspiration.id]?.result)
        let updatedFingerprint = try WorkspaceChecksum.materialDigestResultFingerprint(updatedResult)
        let updatedDigestBlock = DocumentBlock(
            id: BlockID(),
            kind: .paragraph,
            inlineContent: .plain("第二版摘要"),
            taskState: nil,
            indentLevel: 0
        )
        let updated = try fixture.reduce(
            .writeMaterialDigestToNote(.init(
                inspirationID: fixture.inspiration.id,
                noteID: noteID,
                expectedNoteRevision: try #require(retried.notes[noteID]?.revision),
                resultFingerprint: updatedFingerprint,
                proposedBlocks: [updatedDigestBlock]
            )),
            from: retried
        )
        #expect(updated.notes[noteID]?.document.blocks == [userBlock, updatedDigestBlock])
        #expect(updated.notes[noteID]?.document.blocks.contains(firstDigestBlock) == false)
        #expect(updated.materialDigests[fixture.inspiration.id]?.noteWrite?.blockIDs == [updatedDigestBlock.id])
    }

    @Test func deletingManagedDigestBlocksClearsNoteWriteAndSavesTheNote() throws {
        let fixture = MaterialDigestReducerFixture()
        let written = try fixture.noteWithWrittenDigest()
        let noteID = written.noteID
        let digestBlockID = written.digestBlock.id
        let userBlock = written.userBlock
        let base = try #require(written.state.notes[noteID])
        var submitted = base
        submitted.document.blocks.removeAll { $0.id == digestBlockID }
        submitted.updatedAt = fixture.later

        let saved = try fixture.reduce(
            .updateNote(try fixture.noteSubmission(base: base, submitted: submitted)),
            from: written.state,
            now: fixture.later
        )
        #expect(saved.notes[noteID]?.document.blocks == [userBlock])
        #expect(saved.materialDigests[fixture.inspiration.id]?.noteWrite == nil)
        #expect(saved.materialDigests[fixture.inspiration.id]?.result != nil)
    }

    @Test func rewritingDigestDoesNotDeleteUserModifiedFormerDigestBlocks() throws {
        let fixture = MaterialDigestReducerFixture()
        let written = try fixture.noteWithWrittenDigest()
        let noteID = written.noteID
        let base = try #require(written.state.notes[noteID])
        var submitted = base
        submitted.document.blocks = submitted.document.blocks.map { block in
            guard block.id == written.digestBlock.id else { return block }
            var edited = block
            edited.inlineContent = .plain("用户改过的摘要段落")
            return edited
        }
        submitted.updatedAt = fixture.later
        let edited = try fixture.reduce(
            .updateNote(try fixture.noteSubmission(base: base, submitted: submitted)),
            from: written.state,
            now: fixture.later
        )
        #expect(edited.materialDigests[fixture.inspiration.id]?.noteWrite == nil)
        #expect(
            edited.notes[noteID]?.document.blocks.map { $0.inlineContent.spans.map(\.text).joined() }
                == ["这是用户自己写的内容", "用户改过的摘要段落"]
        )

        var retried = edited
        retried.materialDigests[fixture.inspiration.id]?.result?.summary.thesis = "新一轮核心论点"
        let updatedResult = try #require(retried.materialDigests[fixture.inspiration.id]?.result)
        let newDigestBlock = DocumentBlock(
            id: BlockID(),
            kind: .paragraph,
            inlineContent: .plain("新一轮摘要"),
            taskState: nil,
            indentLevel: 0
        )
        let rewritten = try fixture.reduce(
            .writeMaterialDigestToNote(.init(
                inspirationID: fixture.inspiration.id,
                noteID: noteID,
                expectedNoteRevision: try #require(retried.notes[noteID]?.revision),
                resultFingerprint: try WorkspaceChecksum.materialDigestResultFingerprint(updatedResult),
                proposedBlocks: [newDigestBlock]
            )),
            from: retried
        )
        #expect(
            rewritten.notes[noteID]?.document.blocks.map { $0.inlineContent.spans.map(\.text).joined() }
                == ["这是用户自己写的内容", "用户改过的摘要段落", "新一轮摘要"]
        )
        #expect(rewritten.materialDigests[fixture.inspiration.id]?.noteWrite?.blockIDs == [newDigestBlock.id])
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

    struct WrittenDigestNote {
        var state: WorkspaceState
        var noteID: NoteID
        var userBlock: DocumentBlock
        var digestBlock: DocumentBlock
    }

    func noteWithWrittenDigest() throws -> WrittenDigestNote {
        let succeeded = try succeededState()
        let noteID = NoteID()
        let userBlock = DocumentBlock(
            id: BlockID(),
            kind: .paragraph,
            inlineContent: .plain("这是用户自己写的内容"),
            taskState: nil,
            indentLevel: 0
        )
        var note = Note.empty(id: noteID, categoryID: inspiration.categoryID, now: now)
        note.title = "材料笔记"
        note.document = BlockDocument(blocks: [userBlock])
        let converted = try reduce(
            .convertInspirationToNote(.init(
                inspirationID: inspiration.id,
                proposedNote: note
            )),
            from: succeeded
        )
        let digestBlock = DocumentBlock(
            id: BlockID(),
            kind: .paragraph,
            inlineContent: .plain("第一版摘要"),
            taskState: nil,
            indentLevel: 0
        )
        let result = try #require(converted.materialDigests[inspiration.id]?.result)
        let written = try reduce(
            .writeMaterialDigestToNote(.init(
                inspirationID: inspiration.id,
                noteID: noteID,
                expectedNoteRevision: try #require(converted.notes[noteID]?.revision),
                resultFingerprint: try WorkspaceChecksum.materialDigestResultFingerprint(result),
                proposedBlocks: [digestBlock]
            )),
            from: converted
        )
        return WrittenDigestNote(
            state: written,
            noteID: noteID,
            userBlock: userBlock,
            digestBlock: digestBlock
        )
    }

    func noteSubmission(base: Note, submitted: Note) throws -> NoteDraftSubmission {
        var fields = Set<NoteDraftField>()
        if base.title != submitted.title { fields.insert(.title) }
        if base.document != submitted.document { fields.insert(.document) }
        if base.categoryID != submitted.categoryID { fields.insert(.categoryID) }
        if base.archivedAt != submitted.archivedAt { fields.insert(.archivedAt) }
        return NoteDraftSubmission(
            noteID: base.id,
            editSessionID: UUID(uuidString: "00000000-0000-0000-0000-00000000d120")!,
            baseNoteRevision: base.revision,
            baseNoteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(base),
            baseSnapshot: base,
            baseLinkedTaskBlockLinks: [],
            draftGeneration: 1,
            snapshot: submitted,
            noteSnapshotChecksum: try WorkspaceChecksum.noteSnapshotChecksum(submitted),
            modifiedFields: fields,
            linkedBlockDeletionDispositions: [:]
        )
    }
}
