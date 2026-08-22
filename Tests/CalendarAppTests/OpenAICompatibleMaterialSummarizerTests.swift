import Foundation
import Testing
import WorkspaceDomain
@testable import CalendarApp

@Suite("OpenAICompatibleMaterialSummarizerTests", .serialized)
struct OpenAICompatibleMaterialSummarizerTests {
    @Test func requestUsesHTTPSJSONSchemaAndDoesNotPutSecretsInBody() async throws {
        SummarizerURLProtocol.reset()
        SummarizerURLProtocol.response = .init(
            status: 200,
            json: completionJSON(validSummaryJSON())
        )
        let settings = try makeSettings()
        let credentials = InMemoryDigestCredentialStore()
        try credentials.save("sk-test-secret-value")
        let summarizer = OpenAICompatibleMaterialSummarizer(
            settings: settings,
            credentials: credentials,
            configuration: protocolConfiguration()
        )
        let output = try await summarizer.summarize(sampleTranscript, source: audioSource)
        #expect(output.endpointHost == "api.example.com")
        #expect(output.model == "gpt-test")
        #expect(output.summaryContractVersion == "summary-contract-v1")
        #expect(output.summary.takeaways.count == 3)

        let request = try #require(SummarizerURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-secret-value")
        let rawBody = try #require(SummarizerURLProtocol.lastBody)
        let object = try JSONSerialization.jsonObject(with: rawBody)
        let body = try #require(object as? [String: Any])
        #expect(body["model"] as? String == "gpt-test")
        #expect((body["temperature"] as? NSNumber)?.doubleValue == 0.2)
        let format = body["response_format"] as? [String: Any]
        #expect(format?["type"] as? String == "json_schema")
        let schema = format?["json_schema"] as? [String: Any]
        #expect(schema?["strict"] as? Bool == true)
        let bodyText = String(data: SummarizerURLProtocol.lastBody ?? Data(), encoding: .utf8) ?? ""
        #expect(!bodyText.contains("sk-test-secret-value"))
        #expect(!bodyText.contains("/tmp/"))
        let messages = try #require(body["messages"] as? [[String: Any]])
        let system = try #require(messages.first?["content"] as? String)
        #expect(system.contains("dropped"))
        #expect(system.contains("不得从原文稿中删除"))
        let user = try #require(messages.last?["content"] as? String)
        #expect(user.contains("[00:00-00:08]"))
        #expect(user.contains("开场"))
    }

    @Test func videoPromptDoesNotRequireDroppedAdsCopy() async throws {
        SummarizerURLProtocol.reset()
        SummarizerURLProtocol.response = .init(status: 200, json: completionJSON(validSummaryJSON()))
        let summarizer = OpenAICompatibleMaterialSummarizer(
            settings: try makeSettings(),
            credentials: try makeCredentials(),
            configuration: protocolConfiguration()
        )
        _ = try await summarizer.summarize(sampleTranscript, source: videoSource)
        let body = try #require(SummarizerURLProtocol.lastBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: Any]])
        let system = try #require(messages.first?["content"] as? String)
        #expect(system.contains("视频"))
        #expect(!system.contains("赞助口播"))
    }

    @Test func mapsUnauthorizedContextLengthAndServerErrors() async throws {
        let summarizer = OpenAICompatibleMaterialSummarizer(
            settings: try makeSettings(),
            credentials: try makeCredentials(),
            configuration: protocolConfiguration()
        )
        SummarizerURLProtocol.reset()
        SummarizerURLProtocol.response = .init(status: 401, json: #"{"error":{"message":"bad key sk-test-secret-value"}}"#)
        await expectPipeline(summarizer, .modelNotConfigured)

        SummarizerURLProtocol.response = .init(status: 413, json: #"{"error":{"message":"context_length exceeded"}}"#)
        await expectPipeline(summarizer, .contextTooLong)

        SummarizerURLProtocol.response = .init(status: 400, json: #"{"error":{"message":"response_format json_schema is not supported"}}"#)
        await expectPipeline(summarizer, .jsonSchemaUnsupported)

        SummarizerURLProtocol.response = .init(status: 429, json: #"{"error":{"message":"rate"}}"#)
        await expectPipeline(summarizer, .summarizationFailed)

        SummarizerURLProtocol.response = .init(status: 503, json: #"{"error":{"message":"down"}}"#)
        await expectPipeline(summarizer, .summarizationFailed)
    }

    @Test func rejectsInvalidOutputsWithoutLeakingSecretsOrBodies() async throws {
        let secret = "sk-test-secret-value"
        let summarizer = OpenAICompatibleMaterialSummarizer(
            settings: try makeSettings(),
            credentials: try makeCredentials(secret),
            configuration: protocolConfiguration()
        )
        let cases = [
            completionJSON("```json\n{\"thesis\":\"\"}\n```"),
            completionJSON(validSummaryJSON(thesis: "")),
            completionJSON(validSummaryJSON(takeaways: ["a", "b"])),
            completionJSON(validSummaryJSON(takeaways: (1...8).map { "观点\($0)" })),
            completionJSON(validSummaryJSON(chaptersReversed: true)),
            #"{"choices":[{"message":{"content":"not-json \(secret)"}}]}"#,
            #"{"choices":[{"message":{"refusal":"no"}}]}"#,
            #"{"choices":[]}"#
        ]
        for json in cases {
            SummarizerURLProtocol.reset()
            SummarizerURLProtocol.response = .init(status: 200, json: json)
            do {
                _ = try await summarizer.summarize(sampleTranscript, source: videoSource)
                Issue.record("invalid output was accepted")
            } catch let error as MaterialDigestPipelineError {
                #expect(error == .invalidSummary)
                #expect(!String(describing: error).contains(secret))
                #expect(!String(describing: error).contains("not-json"))
            } catch {
                Issue.record("unexpected \(error)")
            }
        }
    }
}

private func expectPipeline(
    _ summarizer: OpenAICompatibleMaterialSummarizer,
    _ expected: MaterialDigestPipelineError
) async {
    do {
        _ = try await summarizer.summarize(sampleTranscript, source: videoSource)
        Issue.record("expected \(expected)")
    } catch let error as MaterialDigestPipelineError {
        #expect(error == expected)
        #expect(!String(describing: error).contains("sk-test-secret-value"))
    } catch {
        Issue.record("unexpected \(error)")
    }
}

private func makeSettings() throws -> DigestSettingsStore {
    let suite = "jelly-summarizer-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let store = DigestSettingsStore(defaults: defaults)
    #expect(store.save(endpoint: "https://api.example.com/v1/", model: "gpt-test"))
    return store
}

private func makeCredentials(_ secret: String = "sk-test-secret-value") throws -> InMemoryDigestCredentialStore {
    let store = InMemoryDigestCredentialStore()
    try store.save(secret)
    return store
}

private func protocolConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SummarizerURLProtocol.self]
    return configuration
}

private let sampleTranscript = TimestampedTranscript(segments: [
    TranscriptSegment(startSeconds: 0, endSeconds: 8, text: "开场"),
    TranscriptSegment(startSeconds: 8, endSeconds: 20, text: "主体")
])

private let videoSource = MaterialSource(
    inspirationID: InspirationID(),
    url: URL(string: "https://www.bilibili.com/video/BV1xx411c7mD/")!,
    kind: .video,
    sourceChecksum: "checksum"
)

private let audioSource = MaterialSource(
    inspirationID: InspirationID(),
    url: URL(string: "https://www.xiaoyuzhoufm.com/episode/1")!,
    kind: .audio,
    sourceChecksum: "checksum"
)

private func validSummaryJSON(
    thesis: String = "核心论点",
    takeaways: [String] = ["观点1", "观点2", "观点3"],
    chaptersReversed: Bool = false
) -> String {
    let chapters = chaptersReversed
        ? #"[{"startSeconds":90,"title":"后","points":["b"]},{"startSeconds":10,"title":"前","points":["a"]}]"#
        : #"[{"startSeconds":0,"title":"开场","points":["引入"]},{"startSeconds":8,"title":"主体","points":["展开"]}]"#
    let takeawayJSON = takeaways.map { "\"\($0)\"" }.joined(separator: ",")
    return """
    {"thesis":"\(thesis)","takeaways":[\(takeawayJSON)],"chapters":\(chapters),"quotes":[{"speaker":"讲者","startSeconds":8,"text":"一句原话"}],"dropped":["片头"]}
    """
}

private func completionJSON(_ content: String) -> String {
    let encoded = content
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    return #"{"choices":[{"message":{"content":"\#(encoded)"}}]}"#
}

private final class SummarizerURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var status: Int
        var json: String
    }

    nonisolated(unsafe) static var response = Response(status: 500, json: "{}")
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    static func reset() {
        lastRequest = nil
        lastBody = nil
        response = Response(status: 500, json: "{}")
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? streamBody(request.httpBodyStream)
        let data = Data(Self.response.json.utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.response.status,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/json",
                "Content-Length": String(data.count)
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func streamBody(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: 4096)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
