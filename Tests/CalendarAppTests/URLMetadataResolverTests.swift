import Foundation
import Testing
@testable import CalendarApp

@Suite("URLMetadataResolverTests", .serialized)
struct URLMetadataResolverTests {
    @Test func rejectsNonHTMLResponsesInsteadOfInventingArticleMetadata() async throws {
        let resolver = makeResolver(
            contentType: "application/octet-stream",
            data: Data("not html".utf8),
            maxBytes: 64
        )

        do {
            _ = try await resolver.resolve(URL(string: "https://example.com/file")!)
            Issue.record("non-HTML response was accepted")
        } catch {}
    }

    @Test func rejectsAResponseThatExceedsTheConfiguredByteLimit() async throws {
        let resolver = makeResolver(
            contentType: "text/html; charset=utf-8",
            data: Data(repeating: 65, count: 65),
            maxBytes: 64
        )

        do {
            _ = try await resolver.resolve(URL(string: "https://example.com/large")!)
            Issue.record("oversized response was silently truncated and accepted")
        } catch {}
    }

    @Test func successfulBilibiliHTMLKeepsVideoKind() async throws {
        let resolver = makeHTMLResolver(title: "B站视频标题")
        let result = try await resolver.resolve(
            URL(string: "https://www.bilibili.com/video/BV1xx411c7mD/")!
        )
        #expect(result.resolvedKind == .video)
        #expect(result.metadata.title == "B站视频标题")
        #expect(result.metadata.fetchStatus == .succeeded)
    }

    @Test func successfulXiaoyuzhouHTMLKeepsAudioKind() async throws {
        let resolver = makeHTMLResolver(title: "小宇宙单集")
        let result = try await resolver.resolve(
            URL(string: "https://www.xiaoyuzhoufm.com/episode/650a1b2ce1b3f16a04cb0f2e")!
        )
        #expect(result.resolvedKind == .audio)
        #expect(result.metadata.title == "小宇宙单集")
        #expect(result.metadata.fetchStatus == .succeeded)
    }

    @Test func successfulOrdinaryHTMLRemainsArticle() async throws {
        let resolver = makeHTMLResolver(title: "普通文章")
        let result = try await resolver.resolve(URL(string: "https://example.com/post")!)
        #expect(result.resolvedKind == .article)
        #expect(result.metadata.title == "普通文章")
    }

    private func makeResolver(contentType: String, data: Data, maxBytes: Int) -> URLMetadataResolver {
        URLMetadataURLProtocol.fixture = .init(contentType: contentType, data: data)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLMetadataURLProtocol.self]
        return URLMetadataResolver(maxBytes: maxBytes, configuration: configuration)
    }

    private func makeHTMLResolver(title: String) -> URLMetadataResolver {
        makeResolver(
            contentType: "text/html; charset=utf-8",
            data: Data("<html><head><title>\(title)</title></head></html>".utf8),
            maxBytes: 256_000
        )
    }
}

private final class URLMetadataURLProtocol: URLProtocol, @unchecked Sendable {
    struct Fixture: Sendable {
        let contentType: String
        let data: Data
    }

    nonisolated(unsafe) static var fixture = Fixture(contentType: "text/html", data: Data())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let fixture = Self.fixture
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": fixture.contentType,
                "Content-Length": String(fixture.data.count)
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
