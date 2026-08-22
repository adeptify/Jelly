import Foundation
import WorkspaceDomain

final class OpenAICompatibleMaterialSummarizer: MaterialSummarizing, @unchecked Sendable {
    static let contractVersion = "summary-contract-v1"
    private let settings: DigestSettingsStore
    private let credentials: any DigestCredentialStoring
    private let session: URLSession

    init(
        settings: DigestSettingsStore,
        credentials: any DigestCredentialStoring,
        configuration: URLSessionConfiguration = .ephemeral
    ) {
        self.settings = settings
        self.credentials = credentials
        let config = (configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 120
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        self.session = URLSession(configuration: config)
    }

    var isConfigured: Bool {
        DigestRuntimeConfiguration.isConfigured(
            endpoint: settings.endpoint,
            model: settings.model,
            secret: try? credentials.load()
        )
    }

    func summarize(
        _ transcript: TimestampedTranscript,
        source: MaterialSource
    ) async throws -> MaterialSummarizerOutput {
        guard let endpoint = DigestSettingsNormalization.endpoint(settings.endpoint),
              let model = DigestSettingsNormalization.model(settings.model),
              let secret = try credentials.load(),
              !secret.isEmpty
        else {
            throw MaterialDigestPipelineError.modelNotConfigured
        }
        guard let endpointURL = URL(string: endpoint),
              let host = endpointURL.host,
              let requestURL = URL(string: endpoint + "/chat/completions")
        else {
            throw MaterialDigestPipelineError.modelNotConfigured
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: Self.requestBody(model: model, transcript: transcript, source: source),
            options: [.sortedKeys]
        )
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MaterialDigestPipelineError.summarizationFailed
        }
        guard let http = response as? HTTPURLResponse else {
            throw MaterialDigestPipelineError.summarizationFailed
        }
        try Self.throwForStatus(http.statusCode, data: data)
        let summary = try Self.decodeSummary(from: data)
        try Self.validate(summary)
        return MaterialSummarizerOutput(
            summary: summary,
            endpointHost: host,
            model: model,
            summaryContractVersion: Self.contractVersion
        )
    }

    private static func throwForStatus(_ status: Int, data: Data) throws {
        if (200..<300).contains(status) { return }
        if status == 401 || status == 403 {
            throw MaterialDigestPipelineError.modelNotConfigured
        }
        if status == 413 || containsContextLengthError(data) {
            throw MaterialDigestPipelineError.contextTooLong
        }
        if status == 400, containsJSONSchemaRejection(data) {
            throw MaterialDigestPipelineError.jsonSchemaUnsupported
        }
        if status == 429 || (500...599).contains(status) {
            throw MaterialDigestPipelineError.summarizationFailed
        }
        throw MaterialDigestPipelineError.summarizationFailed
    }

    private static func containsContextLengthError(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self).lowercased()
        return text.contains("context_length") || text.contains("context length") || text.contains("maximum context")
    }

    private static func containsJSONSchemaRejection(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self).lowercased()
        return text.contains("json_schema") || text.contains("response_format")
    }

    private static func decodeSummary(from data: Data) throws -> InspirationSummary {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let choices = object?["choices"] as? [[String: Any]]
        guard let message = choices?.first?["message"] as? [String: Any] else {
            throw MaterialDigestPipelineError.invalidSummary
        }
        if message["refusal"] is String {
            throw MaterialDigestPipelineError.invalidSummary
        }
        guard let content = message["content"] as? String else {
            throw MaterialDigestPipelineError.invalidSummary
        }
        let jsonText = unwrapJSON(content)
        guard let jsonData = jsonText.data(using: .utf8) else {
            throw MaterialDigestPipelineError.invalidSummary
        }
        do {
            return try JSONDecoder().decode(InspirationSummary.self, from: jsonData)
        } catch {
            throw MaterialDigestPipelineError.invalidSummary
        }
    }

    private static func unwrapJSON(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if let fence = text.range(of: "```", options: .backwards) {
                text = String(text[..<fence.lowerBound])
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validate(_ summary: InspirationSummary) throws {
        guard !summary.thesis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MaterialDigestPipelineError.invalidSummary
        }
        let takeaways = summary.takeaways.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard (3...7).contains(takeaways.count), takeaways.allSatisfy({ !$0.isEmpty }) else {
            throw MaterialDigestPipelineError.invalidSummary
        }
        var previous = -Double.infinity
        for chapter in summary.chapters {
            guard chapter.startSeconds >= previous,
                  !chapter.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw MaterialDigestPipelineError.invalidSummary
            }
            previous = chapter.startSeconds
        }
    }

    private static func requestBody(
        model: String,
        transcript: TimestampedTranscript,
        source: MaterialSource
    ) -> [String: Any] {
        [
            "model": model,
            "temperature": 0.2,
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "inspiration_summary",
                    "strict": true,
                    "schema": jsonSchema()
                ]
            ],
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt(for: source)
                ],
                [
                    "role": "user",
                    "content": userPrompt(for: transcript)
                ]
            ]
        ]
    }

    private static func systemPrompt(for source: MaterialSource) -> String {
        var prompt = "你是 Jelly 的材料提炼器。只根据给定的带时间戳文稿输出符合 schema 的 JSON，不要编造文稿中没有的内容，也不要输出除 JSON 以外的文字。"
        if source.kind == .video {
            prompt += "这是视频材料：提炼核心论点和可执行观点，章节按时间排序。"
        }
        if source.kind == .audio {
            prompt += "这是音频单集：必须识别广告、片头片尾和赞助口播并写入 dropped；不得从原文稿中删除这些内容。"
        }
        return prompt
    }

    private static func userPrompt(for transcript: TimestampedTranscript) -> String {
        transcript.segments.map { segment in
            "[\(timestamp(segment.startSeconds))-\(timestamp(segment.endSeconds))] \(segment.text)"
        }.joined(separator: "\n")
    }

    private static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.towardZero)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func jsonSchema() -> [String: Any] { [
        "type": "object",
        "additionalProperties": false,
        "required": ["thesis", "takeaways", "chapters", "quotes", "dropped"],
        "properties": [
            "thesis": ["type": "string"],
            "takeaways": [
                "type": "array",
                "minItems": 3,
                "maxItems": 7,
                "items": ["type": "string"]
            ],
            "chapters": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["startSeconds", "title", "points"],
                    "properties": [
                        "startSeconds": ["type": "number"],
                        "title": ["type": "string"],
                        "points": [
                            "type": "array",
                            "items": ["type": "string"]
                        ]
                    ]
                ]
            ],
            "quotes": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["speaker", "startSeconds", "text"],
                    "properties": [
                        "speaker": ["type": ["string", "null"]],
                        "startSeconds": ["type": "number"],
                        "text": ["type": "string"]
                    ]
                ]
            ],
            "dropped": [
                "type": "array",
                "items": ["type": "string"]
            ]
        ]
    ] }
}
