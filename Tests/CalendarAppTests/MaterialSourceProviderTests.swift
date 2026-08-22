import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("MaterialSourceProviderTests", .serialized)
struct MaterialSourceProviderTests {
    @Test func b23RedirectsThenPrefersChineseHumanSubtitles() async throws {
        MaterialSourceURLProtocol.reset()
        MaterialSourceURLProtocol.set(
            url: "https://b23.tv/jKx2Ab",
            status: 302,
            headers: ["Location": "https://www.bilibili.com/video/BV1xx411c7mD/"]
        )
        MaterialSourceURLProtocol.setHTML(
            url: "https://www.bilibili.com/video/BV1xx411c7mD/",
            html: bilibiliHTML()
        )
        MaterialSourceURLProtocol.setJSON(
            url: "https://api.bilibili.com/x/player/v2?bvid=BV1xx411c7mD&cid=170001",
            json: """
            {"code":0,"data":{"subtitle":{"subtitles":[
              {"lan":"ai-zh","subtitle_url":"https://subtitle.test/ai.json"},
              {"lan":"zh-CN","subtitle_url":"https://subtitle.test/zh.json"}
            ]}}}
            """
        )
        MaterialSourceURLProtocol.setData(
            url: "https://subtitle.test/zh.json",
            contentType: "application/json",
            data: qualifiedSubtitleData(prefix: "人工")
        )
        MaterialSourceURLProtocol.setData(
            url: "https://subtitle.test/ai.json",
            contentType: "application/json",
            data: qualifiedSubtitleData(prefix: "自动")
        )

        let acquirer = RoutedMaterialAcquirer(client: MaterialHTTPClient(configuration: protocolConfiguration()))
        let result = try await acquirer.acquire(videoSource(url: "https://b23.tv/jKx2Ab"))
        guard case let .transcript(transcript) = result else {
            Issue.record("expected transcript")
            return
        }
        #expect(transcript.segments.count >= 30)
        #expect(transcript.segments[0].text.contains("人工"))
        #expect(transcript.segments[0].startSeconds == 0)
        #expect(transcript.segments[0].endSeconds == 1)
    }

    @Test func bilibiliInitialStateToleratesUndefinedJSONLiterals() async throws {
        MaterialSourceURLProtocol.reset()
        MaterialSourceURLProtocol.setHTML(
            url: "https://www.bilibili.com/video/BV1xx411c7mD/",
            html: """
            <html><script>window.__INITIAL_STATE__={"bvid":"BV1xx411c7mD","cid":170001,"videoData":{"bvid":"BV1xx411c7mD","cid":170001,"title": undefined, "extra":[undefined,1]}};</script></html>
            """
        )
        MaterialSourceURLProtocol.setJSON(
            url: "https://api.bilibili.com/x/player/v2?bvid=BV1xx411c7mD&cid=170001",
            json: """
            {"code":0,"data":{"subtitle":{"subtitles":[{"lan":"zh-CN","subtitle_url":"https://subtitle.test/zh.json"}]}}}
            """
        )
        MaterialSourceURLProtocol.setData(
            url: "https://subtitle.test/zh.json",
            contentType: "application/json",
            data: qualifiedSubtitleData(prefix: "人工")
        )
        let acquirer = RoutedMaterialAcquirer(client: MaterialHTTPClient(configuration: protocolConfiguration()))
        let result = try await acquirer.acquire(videoSource())
        guard case let .transcript(transcript) = result else {
            Issue.record("expected transcript from undefined-tolerant INITIAL_STATE")
            return
        }
        #expect(transcript.segments[0].text.contains("人工"))
    }

    @Test func emptyPlayerSubtitlesFallBackToPlayurlDashAudio() async throws {
        MaterialSourceURLProtocol.reset()
        MaterialSourceURLProtocol.setHTML(
            url: "https://www.bilibili.com/video/BV1xx411c7mD/",
            html: bilibiliHTML()
        )
        MaterialSourceURLProtocol.setJSON(
            url: "https://api.bilibili.com/x/player/v2?bvid=BV1xx411c7mD&cid=170001",
            json: """
            {"code":0,"data":{"subtitle":{"subtitles":[]},"need_login_subtitle":true}}
            """
        )
        MaterialSourceURLProtocol.setJSON(
            url: "https://api.bilibili.com/x/player/playurl",
            json: """
            {"code":0,"data":{"dash":{"audio":[{"baseUrl":"https://upos.test/playurl-audio.m4s","size":4096}]}}}
            """
        )

        let acquirer = RoutedMaterialAcquirer(client: MaterialHTTPClient(configuration: protocolConfiguration()))
        let result = try await acquirer.acquire(videoSource())
        guard case let .remoteAudio(asset) = result else {
            Issue.record("expected playurl dash audio when player v2 has no captions or dash")
            return
        }
        #expect(asset.url == URL(string: "https://upos.test/playurl-audio.m4s"))
        #expect(asset.estimatedBytes == 4096)
        #expect(asset.requestHeaders["Referer"] == "https://www.bilibili.com/video/BV1xx411c7mD/")
        #expect(asset.requestHeaders["User-Agent"]?.isEmpty == false)
    }

    @Test func missingQualifiedSubtitlesFallBackToDashAudio() async throws {
        MaterialSourceURLProtocol.reset()
        MaterialSourceURLProtocol.setHTML(
            url: "https://www.bilibili.com/video/BV1xx411c7mD/",
            html: bilibiliHTML()
        )
        MaterialSourceURLProtocol.setJSON(
            url: "https://api.bilibili.com/x/player/v2?bvid=BV1xx411c7mD&cid=170001",
            json: """
            {"code":0,"data":{"subtitle":{"subtitles":[{"lan":"zh","subtitle_url":"https://subtitle.test/short.json"}]},"dash":{"audio":[{"baseUrl":"https://upos.test/audio.m4s","size":2048}]}}}
            """
        )
        MaterialSourceURLProtocol.setJSON(
            url: "https://subtitle.test/short.json",
            json: #"{"body":[{"from":0,"to":1,"content":"短"}]}"#
        )

        let acquirer = RoutedMaterialAcquirer(client: MaterialHTTPClient(configuration: protocolConfiguration()))
        let result = try await acquirer.acquire(videoSource())
        guard case let .remoteAudio(asset) = result else {
            Issue.record("expected remote audio")
            return
        }
        #expect(asset.url == URL(string: "https://upos.test/audio.m4s"))
        #expect(asset.estimatedBytes == 2048)
        #expect(asset.requestHeaders["Referer"] == "https://www.bilibili.com/video/BV1xx411c7mD/")
        #expect(asset.requestHeaders["User-Agent"]?.isEmpty == false)
    }

    @Test func bilibiliForbiddenPageMapsToRestricted() async throws {
        MaterialSourceURLProtocol.reset()
        MaterialSourceURLProtocol.set(
            url: "https://www.bilibili.com/video/BV1xx411c7mD/",
            status: 403,
            contentType: "text/html",
            data: Data("forbidden".utf8)
        )
        let acquirer = RoutedMaterialAcquirer(client: MaterialHTTPClient(configuration: protocolConfiguration()))
        do {
            _ = try await acquirer.acquire(videoSource())
            Issue.record("restricted video was acquired")
        } catch let error as MaterialDigestPipelineError {
            #expect(error == .restrictedSource)
        }
    }

    @Test func xiaoyuzhouReadsOgAudioJSONLDAndNextData() async throws {
        let episode = "https://www.xiaoyuzhoufm.com/episode/650a1b2ce1b3f16a04cb0f2e"
        MaterialSourceURLProtocol.reset()
        MaterialSourceURLProtocol.setHTML(
            url: episode,
            html: #"<meta property="og:audio" content="https://media.test/og.m4a">"#
        )
        let og = try await XiaoyuzhouMaterialAcquirer(
            client: MaterialHTTPClient(configuration: protocolConfiguration())
        ).acquire(audioSource(url: episode))
        guard case let .remoteAudio(ogAsset) = og else {
            Issue.record("og:audio missing")
            return
        }
        #expect(ogAsset.url == URL(string: "https://media.test/og.m4a"))

        MaterialSourceURLProtocol.reset()
        MaterialSourceURLProtocol.setHTML(
            url: episode,
            html: #"<script type="application/ld+json">{"@type":"AudioObject","contentUrl":"https://media.test/ld.m4a"}</script>"#
        )
        let ld = try await XiaoyuzhouMaterialAcquirer(
            client: MaterialHTTPClient(configuration: protocolConfiguration())
        ).acquire(audioSource(url: episode))
        guard case let .remoteAudio(ldAsset) = ld else {
            Issue.record("json-ld missing")
            return
        }
        #expect(ldAsset.url == URL(string: "https://media.test/ld.m4a"))

        MaterialSourceURLProtocol.reset()
        MaterialSourceURLProtocol.setHTML(
            url: episode,
            html: #"<script>window.__NEXT_DATA__={"props":{"pageProps":{"episode":{"enclosure":{"url":"https://media.test/next.m4a"}}}}}</script>"#
        )
        let next = try await XiaoyuzhouMaterialAcquirer(
            client: MaterialHTTPClient(configuration: protocolConfiguration())
        ).acquire(audioSource(url: episode))
        guard case let .remoteAudio(nextAsset) = next else {
            Issue.record("next data missing")
            return
        }
        #expect(nextAsset.url == URL(string: "https://media.test/next.m4a"))
    }

    @Test func xiaoyuzhouPodcastHomeAndMissingAudioAreRejected() async throws {
        let acquirer = RoutedMaterialAcquirer(client: MaterialHTTPClient(configuration: protocolConfiguration()))
        do {
            _ = try await acquirer.acquire(
                audioSource(url: "https://www.xiaoyuzhoufm.com/podcast/5e2c8f0be1b3f16a04cb0f2e")
            )
            Issue.record("podcast home was treated as an episode")
        } catch let error as MaterialDigestPipelineError {
            #expect(error == .unsupportedSource)
        }

        MaterialSourceURLProtocol.reset()
        MaterialSourceURLProtocol.setHTML(
            url: "https://www.xiaoyuzhoufm.com/episode/650a1b2ce1b3f16a04cb0f2e",
            html: "<html><title>无音频</title></html>"
        )
        do {
            _ = try await XiaoyuzhouMaterialAcquirer(
                client: MaterialHTTPClient(configuration: protocolConfiguration())
            ).acquire(audioSource())
            Issue.record("empty episode page succeeded")
        } catch let error as MaterialDigestPipelineError {
            #expect(error == .sourceUnavailable)
        }
    }

    @Test func downloaderWritesM4AAtomicallyAndCleanupRemovesTheRunDirectory() async throws {
        MaterialSourceURLProtocol.reset()
        MaterialSourceURLProtocol.setData(
            url: "https://cdn.test/audio.m4s",
            contentType: "audio/mp4",
            data: Data(repeating: 1, count: 64)
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-digest-audio-\(UUID().uuidString)", isDirectory: true)
        let downloader = TemporaryMaterialAudioDownloader(
            client: MaterialHTTPClient(configuration: protocolConfiguration()),
            rootDirectory: root
        )
        let runID = MaterialDigestRunID()
        let file = try await downloader.download(
            RemoteAudioAsset(
                url: URL(string: "https://cdn.test/audio.m4s")!,
                requestHeaders: [:],
                estimatedBytes: 64
            ),
            runID: runID,
            progress: { _ in }
        )
        #expect(file.pathExtension == "m4a")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(!file.lastPathComponent.contains(".partial"))
        downloader.cleanup(runID: runID)
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(runID.rawValue.uuidString).path
            ) == false
        )
    }

    @Test func oversizeDownloadFailsAndCancelRemovesPartialFiles() async throws {
        MaterialSourceURLProtocol.reset()
        MaterialSourceURLProtocol.setData(
            url: "https://cdn.test/huge.m4s",
            contentType: "audio/mp4",
            data: Data(repeating: 2, count: 32)
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jelly-digest-oversize-\(UUID().uuidString)", isDirectory: true)
        var limits = MaterialHTTPLimits()
        limits.maxAudioBytes = 8
        let downloader = TemporaryMaterialAudioDownloader(
            client: MaterialHTTPClient(configuration: protocolConfiguration()),
            rootDirectory: root,
            limits: limits
        )
        let runID = MaterialDigestRunID()
        do {
            _ = try await downloader.download(
                RemoteAudioAsset(
                    url: URL(string: "https://cdn.test/huge.m4s")!,
                    requestHeaders: [:],
                    estimatedBytes: 32
                ),
                runID: runID,
                progress: { _ in }
            )
            Issue.record("oversize download succeeded")
        } catch let error as MaterialDigestPipelineError {
            #expect(error == .sourceUnavailable)
        }
        downloader.cleanup(runID: runID)
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(runID.rawValue.uuidString).path
            ) == false
        )
    }
}

private func protocolConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MaterialSourceURLProtocol.self]
    return configuration
}

private func videoSource(
    url: String = "https://www.bilibili.com/video/BV1xx411c7mD/"
) -> MaterialSource {
    MaterialSource(
        inspirationID: InspirationID(),
        url: URL(string: url)!,
        kind: .video,
        sourceChecksum: "checksum"
    )
}

private func audioSource(
    url: String = "https://www.xiaoyuzhoufm.com/episode/650a1b2ce1b3f16a04cb0f2e"
) -> MaterialSource {
    MaterialSource(
        inspirationID: InspirationID(),
        url: URL(string: url)!,
        kind: .audio,
        sourceChecksum: "checksum"
    )
}

private func bilibiliHTML() -> String {
    """
    <html><script>window.__INITIAL_STATE__={"bvid":"BV1xx411c7mD","cid":170001,"videoData":{"bvid":"BV1xx411c7mD","cid":170001,"title":"测试"}};</script></html>
    """
}

private func qualifiedSubtitleData(prefix: String) -> Data {
    let items = (0..<30).map { index in
        #"{"from":\#(index),"to":\#(index + 1),"content":"\#(prefix)这是一段足够长的中文字幕内容用于覆盖率检查"}"#
    }
    return Data(#"{"body":[\#(items.joined(separator: ","))]}"#.utf8)
}

private final class MaterialSourceURLProtocol: URLProtocol, @unchecked Sendable {
    struct Fixture: Sendable {
        var status: Int
        var contentType: String
        var data: Data
        var headers: [String: String]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: Fixture] = [:]

    static func reset() {
        lock.lock()
        fixtures = [:]
        lock.unlock()
    }

    static func set(
        url: String,
        status: Int,
        contentType: String = "text/html",
        data: Data = Data(),
        headers: [String: String] = [:]
    ) {
        lock.lock()
        fixtures[normalized(url)] = Fixture(
            status: status,
            contentType: contentType,
            data: data,
            headers: headers
        )
        lock.unlock()
    }

    static func setHTML(url: String, html: String) {
        set(url: url, status: 200, contentType: "text/html; charset=utf-8", data: Data(html.utf8))
    }

    static func setJSON(url: String, json: String) {
        set(url: url, status: 200, contentType: "application/json", data: Data(json.utf8))
    }

    static func setData(url: String, contentType: String, data: Data) {
        set(url: url, status: 200, contentType: contentType, data: data)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let fixture = Self.fixture(for: url)
        if fixture.status == 302, let location = fixture.headers["Location"] {
            var redirected = request
            redirected.url = URL(string: location)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: fixture.headers
            )!
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            return
        }
        var headers = fixture.headers
        headers["Content-Type"] = fixture.contentType
        headers["Content-Length"] = String(fixture.data.count)
        let response = HTTPURLResponse(
            url: url,
            statusCode: fixture.status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func fixture(for url: URL) -> Fixture {
        lock.lock()
        defer { lock.unlock() }
        if let exact = fixtures[normalized(url.absoluteString)] { return exact }
        if let path = fixtures[normalized(url.absoluteString.split(separator: "?").first.map(String.init) ?? "")] {
            return path
        }
        return Fixture(status: 404, contentType: "text/plain", data: Data("missing".utf8), headers: [:])
    }

    private static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }
}
