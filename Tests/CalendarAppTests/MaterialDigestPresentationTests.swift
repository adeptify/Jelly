import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("MaterialDigestPresentationTests")
struct MaterialDigestPresentationTests {
    @Test func unsupportedSourcesDoNotShowDigestSection() {
        let article = inspiration(kind: .article, url: URL(string: "https://example.com/post")!)
        #expect(MaterialDigestPresentation.project(
            inspiration: article,
            digest: nil,
            operatorAvailable: true
        ).isVisible == false)

        let podcastHome = inspiration(
            kind: .unknown,
            url: URL(string: "https://www.xiaoyuzhoufm.com/podcast/1")!
        )
        #expect(MaterialDigestPresentation.project(
            inspiration: podcastHome,
            digest: nil,
            operatorAvailable: true
        ).isVisible == false)
    }

    @Test func idleSupportedSourceShowsStartAction() {
        let presentation = MaterialDigestPresentation.project(
            inspiration: videoInspiration(),
            digest: nil,
            operatorAvailable: true
        )
        #expect(presentation.isVisible)
        #expect(presentation.statusText == "尚未提炼")
        #expect(presentation.primaryActionTitle == "提炼这个链接")
        #expect(presentation.showsCancel == false)
        #expect(presentation.showsRetry == false)
        #expect(presentation.showsConfirmDownload == false)
        #expect(presentation.showsOpenSettings == false)
    }

    @Test func unconfiguredModelOpensSettingsInsteadOfStarting() {
        let presentation = MaterialDigestPresentation.project(
            inspiration: videoInspiration(),
            digest: nil,
            operatorAvailable: true,
            modelConfigured: false
        )
        #expect(presentation.isVisible)
        #expect(presentation.statusText == "尚未配置摘要模型，请先在设置中填写。")
        #expect(presentation.primaryActionTitle == "打开设置")
        #expect(presentation.showsOpenSettings)
        #expect(presentation.showsRetry == false)
        #expect(presentation.showsCancel == false)
    }

    @Test func hiddenWhenOperatorIsUnavailable() {
        let presentation = MaterialDigestPresentation.project(
            inspiration: videoInspiration(),
            digest: nil,
            operatorAvailable: false
        )
        #expect(presentation.isVisible == false)
        #expect(presentation.primaryActionTitle == nil)
    }

    @Test func eachStageHasExactChineseStatus() {
        let cases: [(MaterialDigestStage, String)] = [
            (.fetchingSource, "正在获取字幕"),
            (.downloadingModel, "正在下载识别模型"),
            (.transcribing, "正在识别"),
            (.summarizing, "正在生成摘要")
        ]
        for (stage, expected) in cases {
            let presentation = MaterialDigestPresentation.project(
                inspiration: videoInspiration(),
                digest: runningDigest(stage: stage),
                operatorAvailable: true
            )
            #expect(presentation.statusText == expected)
            #expect(presentation.showsCancel)
            #expect(presentation.primaryActionTitle == nil)
        }

        let audioFetching = MaterialDigestPresentation.project(
            inspiration: audioInspiration(),
            digest: runningDigest(stage: .fetchingSource),
            operatorAvailable: true
        )
        #expect(audioFetching.statusText == "正在获取音频")
    }

    @Test func awaitingConsentShowsDownloadSizeAndContinue() {
        let presentation = MaterialDigestPresentation.project(
            inspiration: videoInspiration(),
            digest: runningDigest(stage: .awaitingModelDownloadConsent),
            operatorAvailable: true
        )
        #expect(presentation.statusText.contains("首次需要下载约 626 MB"))
        #expect(presentation.showsConfirmDownload)
        #expect(presentation.confirmDownloadTitle == "下载并继续")
        #expect(presentation.showsCancel)
    }

    @Test func longRunningStagesExposeProgressAsText() {
        let presentation = MaterialDigestPresentation.project(
            inspiration: videoInspiration(),
            digest: runningDigest(stage: .downloadingModel),
            operatorAvailable: true,
            progressFraction: 0.34
        )
        #expect(presentation.progressFraction == 0.34)
        #expect(presentation.statusText == "正在下载识别模型 34%")
    }

    @Test func retryKeepsPreviousResultVisibleWithNewProgress() {
        let digest = runningDigest(stage: .summarizing, result: succeededResult())
        let presentation = MaterialDigestPresentation.project(
            inspiration: videoInspiration(),
            digest: digest,
            operatorAvailable: true
        )
        #expect(presentation.statusText == "正在生成摘要")
        #expect(presentation.thesis == "核心论点")
        #expect(presentation.takeaways.count == 3)
        #expect(presentation.showsCancel)
    }

    @Test func failureShowsRetryWithoutClaimingSuccess() {
        var digest = runningDigest(stage: .fetchingSource)
        digest.currentRun = nil
        digest.lastFailure = MaterialDigestFailure(
            code: .restrictedSource,
            userMessage: "来源受限，无法获取字幕或音频。",
            occurredAt: MaterialDigestPresentationFixture.now
        )
        let presentation = MaterialDigestPresentation.project(
            inspiration: videoInspiration(),
            digest: digest,
            operatorAvailable: true
        )
        #expect(presentation.statusText == "来源受限，无法获取字幕或音频。")
        #expect(presentation.showsRetry)
        #expect(presentation.primaryActionTitle == "重试")
        #expect(presentation.thesis == nil)
    }

    @Test func successShowsStructuredReviewFields() {
        let presentation = MaterialDigestPresentation.project(
            inspiration: videoInspiration(),
            digest: succeededDigest(),
            operatorAvailable: true
        )
        #expect(presentation.thesis == "核心论点")
        #expect(presentation.takeaways == ["观点1", "观点2", "观点3"])
        #expect(presentation.chapters.map(\.title) == ["开场", "主体"])
        #expect(presentation.quotes.map(\.text) == ["一句原话"])
        #expect(presentation.dropped == ["片头"])
        #expect(presentation.transcriptAvailable)
        #expect(presentation.transcriptSegments.map(\.text) == ["开场", "主体"])
        #expect(presentation.transcriptCollapsedByDefault)
        #expect(presentation.showsCancel == false)
    }

    @Test func archivedSourceNeverShowsActionsThatSilentlyDoNothing() {
        var archived = videoInspiration()
        archived.lifecycle = .archived

        let withoutResult = MaterialDigestPresentation.project(
            inspiration: archived,
            digest: nil,
            operatorAvailable: true
        )
        #expect(withoutResult.isVisible == false)

        let withResult = MaterialDigestPresentation.project(
            inspiration: archived,
            digest: succeededDigest(),
            operatorAvailable: true
        )
        #expect(withResult.isVisible)
        #expect(withResult.thesis == "核心论点")
        #expect(withResult.primaryActionTitle == nil)
        #expect(withResult.showsRetry == false)
        #expect(withResult.showsConfirmDownload == false)
        #expect(withResult.showsCancel == false)
    }
}

private enum MaterialDigestPresentationFixture {
    static let now = Date(timeIntervalSince1970: 1_800_400_000)
}

private func videoInspiration() -> Inspiration {
    inspiration(kind: .video, url: URL(string: "https://www.bilibili.com/video/BV1xx411c7mD/")!)
}

private func audioInspiration() -> Inspiration {
    inspiration(kind: .audio, url: URL(string: "https://www.xiaoyuzhoufm.com/episode/1")!)
}

private func inspiration(kind: ResolvedSourceKind, url: URL) -> Inspiration {
    Inspiration(
        id: InspirationID(UUID(uuidString: "00000000-0000-0000-0000-00000000e001")!),
        inputKind: .url,
        rawText: nil,
        rawURL: url,
        rawFile: nil,
        resolvedSourceKind: kind,
        resolvedMetadata: nil,
        categoryID: UUID(uuidString: "00000000-0000-0000-0000-00000000e000")!,
        lifecycle: .active,
        createdAt: MaterialDigestPresentationFixture.now,
        updatedAt: MaterialDigestPresentationFixture.now
    )
}

private func runningDigest(
    stage: MaterialDigestStage,
    result: MaterialDigestResult? = nil
) -> MaterialDigest {
    let item = videoInspiration()
    return MaterialDigest(
        id: MaterialDigestID(),
        inspirationID: item.id,
        sourceChecksum: WorkspaceChecksum.inspirationSourceChecksum(item),
        currentRun: MaterialDigestRun(
            id: MaterialDigestRunID(),
            stage: stage,
            startedAt: MaterialDigestPresentationFixture.now,
            updatedAt: MaterialDigestPresentationFixture.now
        ),
        result: result,
        lastFailure: nil,
        createdAt: MaterialDigestPresentationFixture.now,
        updatedAt: MaterialDigestPresentationFixture.now
    )
}

private func succeededDigest() -> MaterialDigest {
    let item = videoInspiration()
    return MaterialDigest(
        id: MaterialDigestID(),
        inspirationID: item.id,
        sourceChecksum: WorkspaceChecksum.inspirationSourceChecksum(item),
        currentRun: nil,
        result: succeededResult(),
        lastFailure: nil,
        createdAt: MaterialDigestPresentationFixture.now,
        updatedAt: MaterialDigestPresentationFixture.now
    )
}

private func succeededResult() -> MaterialDigestResult {
    MaterialDigestResult(
        transcript: TimestampedTranscript(segments: [
            TranscriptSegment(startSeconds: 0, endSeconds: 8, text: "开场"),
            TranscriptSegment(startSeconds: 8, endSeconds: 20, text: "主体")
        ]),
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
        provenance: DigestProvenance(
            modelIdentifier: "api.example.com/test-model",
            generatedAt: MaterialDigestPresentationFixture.now,
            inputFingerprint: "checksum",
            summaryContractVersion: "summary-contract-v1"
        ),
        completedAt: MaterialDigestPresentationFixture.now
    )
}
