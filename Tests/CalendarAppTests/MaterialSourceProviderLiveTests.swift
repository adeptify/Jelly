import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("MaterialSourceProviderLiveTests")
struct MaterialSourceProviderLiveTests {
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["JELLY_RUN_LIVE_MATERIAL_PROBE"] == "1")
    )
    func liveBilibiliPublicVideoYieldsTranscriptOrAudio() async throws {
        let acquirer = RoutedMaterialAcquirer()
        let result = try await acquirer.acquire(
            MaterialSource(
                inspirationID: InspirationID(),
                url: URL(string: "https://www.bilibili.com/video/BV1xx411c7mD/")!,
                kind: .video,
                sourceChecksum: "live"
            )
        )
        switch result {
        case let .transcript(transcript):
            print("LIVE_PROBE_RAN kind=video branch=transcript segments=\(transcript.segments.count)")
            #expect(!transcript.segments.isEmpty)
        case let .remoteAudio(asset):
            print("LIVE_PROBE_RAN kind=video branch=remoteAudio estimatedBytes=\(asset.estimatedBytes ?? -1)")
            #expect(asset.url.scheme?.lowercased() == "https")
        }
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["JELLY_RUN_LIVE_MATERIAL_PROBE"] == "1")
    )
    func liveXiaoyuzhouPublicEpisodeYieldsAudio() async throws {
        let acquirer = RoutedMaterialAcquirer()
        let result = try await acquirer.acquire(
            MaterialSource(
                inspirationID: InspirationID(),
                url: URL(string: "https://www.xiaoyuzhoufm.com/episode/69b6c67ef8b8079bfa7b7260")!,
                kind: .audio,
                sourceChecksum: "live"
            )
        )
        guard case let .remoteAudio(asset) = result else {
            Issue.record("expected xiaoyuzhou remote audio")
            return
        }
        print("LIVE_PROBE_RAN kind=audio branch=remoteAudio estimatedBytes=\(asset.estimatedBytes ?? -1)")
        #expect(asset.url.scheme?.lowercased() == "https")
    }
}
