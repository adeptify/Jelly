import CalendarDomain
import Foundation
import Testing
import WorkspaceDomain

@Suite("MaterialDigestModelTests")
struct MaterialDigestModelTests {
    @Test func validatorRejectsDanglingOrMismatchedDigest() throws {
        var state = MaterialDigestFixture.workspace()
        let inspiration = try #require(state.inspirations.values.first)
        let digest = MaterialDigestFixture.succeeded(for: inspiration)
        state.materialDigests[InspirationID()] = digest
        #expect(throws: WorkspaceValidationError.self) {
            try WorkspaceValidator.validate(state)
        }
    }

    @Test func validatorRejectsDigestWhoseInspirationIDDoesNotMatchTheKey() throws {
        var state = MaterialDigestFixture.workspace()
        let inspiration = try #require(state.inspirations.values.first)
        var digest = MaterialDigestFixture.succeeded(for: inspiration)
        let foreignID = InspirationID()
        digest = MaterialDigest(
            id: digest.id,
            inspirationID: foreignID,
            sourceChecksum: digest.sourceChecksum,
            currentRun: digest.currentRun,
            result: digest.result,
            lastFailure: digest.lastFailure,
            createdAt: digest.createdAt,
            updatedAt: digest.updatedAt
        )
        state.materialDigests[inspiration.id] = digest
        #expect(throws: WorkspaceValidationError.self) {
            try WorkspaceValidator.validate(state)
        }
    }

    @Test func validatorAcceptsThreeToSevenTakeawaysAndOrderedSegments() throws {
        let three = MaterialDigestFixture.workspaceWithSucceededDigest(takeawayCount: 3)
        try WorkspaceValidator.validate(three)
        let seven = MaterialDigestFixture.workspaceWithSucceededDigest(takeawayCount: 7)
        try WorkspaceValidator.validate(seven)
    }

    @Test func validatorRejectsTwoOrEightTakeaways() throws {
        #expect(throws: WorkspaceValidationError.self) {
            try WorkspaceValidator.validate(
                MaterialDigestFixture.workspaceWithSucceededDigest(takeawayCount: 2)
            )
        }
        #expect(throws: WorkspaceValidationError.self) {
            try WorkspaceValidator.validate(
                MaterialDigestFixture.workspaceWithSucceededDigest(takeawayCount: 8)
            )
        }
    }

    @Test func validatorRejectsEmptyThesis() throws {
        var state = MaterialDigestFixture.workspaceWithSucceededDigest(takeawayCount: 3)
        let inspirationID = try #require(state.inspirations.keys.first)
        state.materialDigests[inspirationID]?.result?.summary.thesis = "   "
        #expect(throws: WorkspaceValidationError.self) {
            try WorkspaceValidator.validate(state)
        }
    }

    @Test func validatorRejectsNegativeTranscriptTime() throws {
        var state = MaterialDigestFixture.workspaceWithSucceededDigest(takeawayCount: 3)
        let inspirationID = try #require(state.inspirations.keys.first)
        state.materialDigests[inspirationID]?.result?.transcript.segments[0].startSeconds = -1
        #expect(throws: WorkspaceValidationError.self) {
            try WorkspaceValidator.validate(state)
        }
    }

    @Test func validatorRejectsSegmentThatEndsBeforeItStarts() throws {
        var state = MaterialDigestFixture.workspaceWithSucceededDigest(takeawayCount: 3)
        let inspirationID = try #require(state.inspirations.keys.first)
        state.materialDigests[inspirationID]?.result?.transcript.segments[0].startSeconds = 12
        state.materialDigests[inspirationID]?.result?.transcript.segments[0].endSeconds = 4
        #expect(throws: WorkspaceValidationError.self) {
            try WorkspaceValidator.validate(state)
        }
    }

    @Test func validatorRejectsOutOfOrderChapters() throws {
        var state = MaterialDigestFixture.workspaceWithSucceededDigest(takeawayCount: 3)
        let inspirationID = try #require(state.inspirations.keys.first)
        state.materialDigests[inspirationID]?.result?.summary.chapters = [
            DigestChapter(startSeconds: 90, title: "后段", points: ["b"]),
            DigestChapter(startSeconds: 10, title: "前段", points: ["a"])
        ]
        #expect(throws: WorkspaceValidationError.self) {
            try WorkspaceValidator.validate(state)
        }
    }

    @Test func validatorRejectsEmptyProvenanceOnSucceededResult() throws {
        var state = MaterialDigestFixture.workspaceWithSucceededDigest(takeawayCount: 3)
        let inspirationID = try #require(state.inspirations.keys.first)
        state.materialDigests[inspirationID]?.result?.provenance.modelIdentifier = ""
        state.materialDigests[inspirationID]?.result?.provenance.inputFingerprint = ""
        state.materialDigests[inspirationID]?.result?.provenance.summaryContractVersion = ""
        #expect(throws: WorkspaceValidationError.self) {
            try WorkspaceValidator.validate(state)
        }
    }

    @Test func validatorRejectsChecksumMismatch() throws {
        var state = MaterialDigestFixture.workspaceWithSucceededDigest(takeawayCount: 3)
        let inspiration = try #require(state.inspirations.values.first)
        let original = try #require(state.materialDigests[inspiration.id])
        state.materialDigests[inspiration.id] = MaterialDigest(
            id: original.id,
            inspirationID: original.inspirationID,
            sourceChecksum: "not-the-current-source",
            currentRun: original.currentRun,
            result: original.result,
            lastFailure: original.lastFailure,
            createdAt: original.createdAt,
            updatedAt: original.updatedAt
        )
        #expect(throws: WorkspaceValidationError.self) {
            try WorkspaceValidator.validate(state)
        }
    }

    @Test func validatorAllowsSucceededResultToCoexistWithANewRun() throws {
        var state = MaterialDigestFixture.workspaceWithSucceededDigest(takeawayCount: 3)
        let inspirationID = try #require(state.inspirations.keys.first)
        state.materialDigests[inspirationID]?.currentRun = MaterialDigestRun(
            id: MaterialDigestRunID(),
            stage: .fetchingSource,
            startedAt: MaterialDigestFixture.later,
            updatedAt: MaterialDigestFixture.later
        )
        try WorkspaceValidator.validate(state)
    }
}

enum MaterialDigestFixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let later = Date(timeIntervalSince1970: 1_800_000_100)
    static let uncategorizedID = UUID(uuidString: "00000000-0000-0000-0000-00000000d001")!
    static let inspirationID = InspirationID(UUID(uuidString: "00000000-0000-0000-0000-00000000d002")!)
    static let digestID = MaterialDigestID(UUID(uuidString: "00000000-0000-0000-0000-00000000d003")!)

    static func inspiration(
        id: InspirationID = inspirationID,
        kind: ResolvedSourceKind = .video,
        url: URL = URL(string: "https://www.bilibili.com/video/BV1xx411c7mD/")!
    ) -> Inspiration {
        Inspiration(
            id: id,
            inputKind: .url,
            rawText: nil,
            rawURL: url,
            rawFile: nil,
            resolvedSourceKind: kind,
            resolvedMetadata: nil,
            categoryID: uncategorizedID,
            lifecycle: .active,
            createdAt: now,
            updatedAt: now
        )
    }

    static func workspace() -> WorkspaceState {
        var state = WorkspaceState.empty(
            calendar: CalendarState.empty(uncategorizedID: uncategorizedID, now: now)
        )
        state.revision = 1
        let item = inspiration()
        state.inspirations[item.id] = item
        return state
    }

    static func succeeded(
        for inspiration: Inspiration,
        takeawayCount: Int = 3
    ) -> MaterialDigest {
        let takeaways = (1...max(takeawayCount, 0)).map { "观点\($0)" }
        return MaterialDigest(
            id: digestID,
            inspirationID: inspiration.id,
            sourceChecksum: WorkspaceChecksum.inspirationSourceChecksum(inspiration),
            currentRun: nil,
            result: MaterialDigestResult(
                transcript: TimestampedTranscript(segments: [
                    TranscriptSegment(startSeconds: 0, endSeconds: 8, text: "开场"),
                    TranscriptSegment(startSeconds: 8, endSeconds: 20, text: "主体")
                ]),
                summary: InspirationSummary(
                    thesis: "核心论点",
                    takeaways: takeaways,
                    chapters: [
                        DigestChapter(startSeconds: 0, title: "开场", points: ["引入"]),
                        DigestChapter(startSeconds: 8, title: "主体", points: ["展开"])
                    ],
                    quotes: [
                        DigestQuote(speaker: "讲者", startSeconds: 8, text: "一句原话")
                    ],
                    dropped: ["片头"]
                ),
                provenance: DigestProvenance(
                    modelIdentifier: "test-model",
                    generatedAt: later,
                    inputFingerprint: WorkspaceChecksum.inspirationSourceChecksum(inspiration),
                    summaryContractVersion: "summary-contract-v1"
                ),
                completedAt: later
            ),
            lastFailure: nil,
            createdAt: now,
            updatedAt: later
        )
    }

    static func workspaceWithSucceededDigest(takeawayCount: Int) -> WorkspaceState {
        var state = workspace()
        let inspiration = state.inspirations[inspirationID]!
        state.materialDigests[inspiration.id] = succeeded(for: inspiration, takeawayCount: takeawayCount)
        return state
    }
}
