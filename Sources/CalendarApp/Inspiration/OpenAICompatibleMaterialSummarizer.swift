import Foundation
import WorkspaceDomain

final class OpenAICompatibleMaterialSummarizer: MaterialSummarizing, @unchecked Sendable {
    static let contractVersion = "summary-contract-v1"
    private static let maximumResponseBytes = 4_000_000
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
        let transcriptEnd = try Self.validateTranscript(transcript)
        guard let endpoint = DigestSettingsNormalization.endpoint(settings.endpoint),
              let model = DigestSettingsNormalization.model(settings.model),
              let secret = try credentials.load(),
              !secret.isEmpty
        else {
            throw MaterialDigestPipelineError.modelNotConfigured
        }
        guard let endpointURL = URL(string: endpoint),
              let host = endpointURL.host
        else {
            throw MaterialDigestPipelineError.modelNotConfigured
        }
        let requestURL = endpointURL
            .appendingPathComponent("chat", isDirectory: true)
            .appendingPathComponent("completions", isDirectory: false)
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
            let (bytes, receivedResponse) = try await session.bytes(for: request)
            if receivedResponse.expectedContentLength > Int64(Self.maximumResponseBytes) {
                throw MaterialDigestPipelineError.summarizationFailed
            }
            var bounded = Data()
            bounded.reserveCapacity(min(
                Self.maximumResponseBytes,
                max(0, Int(receivedResponse.expectedContentLength))
            ))
            for try await byte in bytes {
                try Task.checkCancellation()
                guard bounded.count < Self.maximumResponseBytes else {
                    throw MaterialDigestPipelineError.summarizationFailed
                }
                bounded.append(byte)
            }
            data = bounded
            response = receivedResponse
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MaterialDigestPipelineError.summarizationFailed
        }
        guard let http = response as? HTTPURLResponse else {
            throw MaterialDigestPipelineError.summarizationFailed
        }
        try Self.throwForStatus(http.statusCode, data: data)
        let summary = Self.normalized(
            try Self.decodeSummary(from: data),
            transcript: transcript,
            maximumSourceTime: transcriptEnd
        )
        try Self.validate(summary, maximumSourceTime: transcriptEnd)
        return MaterialSummarizerOutput(
            summary: summary,
            endpointHost: host,
            model: model,
            summaryContractVersion: Self.contractVersion
        )
    }

    private static func throwForStatus(_ status: Int, data: Data) throws {
        if (200..<300).contains(status) { return }
        if status == 401 { throw MaterialDigestPipelineError.authenticationFailed }
        if status == 403 { throw MaterialDigestPipelineError.accessDenied }
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
        if text.hasPrefix("<think>"),
           let closingTag = text.range(of: "</think>") {
            text = String(text[closingTag.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
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

    private static func validateTranscript(_ transcript: TimestampedTranscript) throws -> Double {
        guard !transcript.segments.isEmpty else {
            throw MaterialDigestPipelineError.sourceUnavailable
        }
        guard transcript.segments.count <= MaterialDigestContentLimits.maximumTranscriptSegments else {
            throw MaterialDigestPipelineError.contextTooLong
        }
        var previousStart = -Double.infinity
        var totalCharacters = 0
        var maximumEnd = 0.0
        for segment in transcript.segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            totalCharacters += text.count
            guard totalCharacters <= MaterialDigestContentLimits.maximumTranscriptCharacters else {
                throw MaterialDigestPipelineError.contextTooLong
            }
            guard segment.startSeconds.isFinite,
                  segment.endSeconds.isFinite,
                  segment.startSeconds >= 0,
                  segment.endSeconds >= segment.startSeconds,
                  segment.endSeconds <= MaterialDigestContentLimits.maximumTimestampSeconds,
                  segment.startSeconds >= previousStart,
                  !text.isEmpty,
                  text.count <= MaterialDigestContentLimits.maximumSegmentCharacters
            else {
                throw MaterialDigestPipelineError.sourceUnavailable
            }
            previousStart = segment.startSeconds
            maximumEnd = max(maximumEnd, segment.endSeconds)
        }
        guard MaterialTranscriptSemantics.hasSemanticContent(transcript) else {
            throw MaterialDigestPipelineError.insufficientContent
        }
        return maximumEnd
    }

    private static func normalized(
        _ summary: InspirationSummary,
        transcript: TimestampedTranscript,
        maximumSourceTime: Double
    ) -> InspirationSummary {
        InspirationSummary(
            thesis: summary.thesis.trimmingCharacters(in: .whitespacesAndNewlines),
            takeaways: summary.takeaways.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
            chapters: summary.chapters.compactMap { chapter in
                let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let points = chapter.points
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                guard !title.isEmpty, !points.isEmpty else { return nil }
                return DigestChapter(
                    startSeconds: chapter.startSeconds,
                    title: title,
                    points: points
                )
            },
            quotes: summary.quotes.compactMap { quote in
                MaterialDigestEvidence.sanitizedQuote(
                    quote,
                    transcript: transcript,
                    maximumSourceTime: maximumSourceTime
                )
            },
            dropped: summary.dropped
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private static func validate(
        _ summary: InspirationSummary,
        maximumSourceTime: Double
    ) throws {
        let thesis = summary.thesis.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !thesis.isEmpty,
              thesis.count <= MaterialDigestContentLimits.maximumThesisCharacters
        else {
            throw MaterialDigestPipelineError.invalidSummary
        }
        let takeaways = summary.takeaways.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard MaterialDigestContentLimits.takeawayCountRange.contains(takeaways.count),
              takeaways.allSatisfy({
                  !$0.isEmpty && $0.count <= MaterialDigestContentLimits.maximumTakeawayCharacters
              }),
              summary.chapters.count <= MaterialDigestContentLimits.maximumChapters,
              summary.quotes.count <= MaterialDigestContentLimits.maximumQuotes,
              summary.dropped.count <= MaterialDigestContentLimits.maximumDroppedItems
        else {
            throw MaterialDigestPipelineError.invalidSummary
        }
        var previous = -Double.infinity
        var totalCharacters = thesis.count + takeaways.reduce(0) { $0 + $1.count }
        for chapter in summary.chapters {
            let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let points = chapter.points.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            totalCharacters += title.count + points.reduce(0) { $0 + $1.count }
            guard chapter.startSeconds.isFinite,
                  chapter.startSeconds >= 0,
                  chapter.startSeconds <= MaterialDigestContentLimits.maximumTimestampSeconds,
                  chapter.startSeconds <= maximumSourceTime,
                  chapter.startSeconds >= previous,
                  !title.isEmpty,
                  title.count <= MaterialDigestContentLimits.maximumChapterTitleCharacters,
                  (1...MaterialDigestContentLimits.maximumChapterPoints).contains(points.count),
                  points.allSatisfy({
                      !$0.isEmpty && $0.count <= MaterialDigestContentLimits.maximumPointCharacters
                  }),
                  totalCharacters <= MaterialDigestContentLimits.maximumSummaryCharacters
            else {
                throw MaterialDigestPipelineError.invalidSummary
            }
            previous = chapter.startSeconds
        }
        for quote in summary.quotes {
            let text = quote.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let speaker = quote.speaker?.trimmingCharacters(in: .whitespacesAndNewlines)
            totalCharacters += text.count + (speaker?.count ?? 0)
            guard quote.startSeconds.isFinite,
                  quote.startSeconds >= 0,
                  quote.startSeconds <= MaterialDigestContentLimits.maximumTimestampSeconds,
                  quote.startSeconds <= maximumSourceTime,
                  !text.isEmpty,
                  text.count <= MaterialDigestContentLimits.maximumQuoteCharacters,
                  (speaker?.count ?? 0) <= MaterialDigestContentLimits.maximumSpeakerCharacters,
                  totalCharacters <= MaterialDigestContentLimits.maximumSummaryCharacters
            else {
                throw MaterialDigestPipelineError.invalidSummary
            }
        }
        for item in summary.dropped {
            let text = item.trimmingCharacters(in: .whitespacesAndNewlines)
            totalCharacters += text.count
            guard !text.isEmpty,
                  text.count <= MaterialDigestContentLimits.maximumDroppedItemCharacters,
                  totalCharacters <= MaterialDigestContentLimits.maximumSummaryCharacters
            else {
                throw MaterialDigestPipelineError.invalidSummary
            }
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
        var prompt = """
        你是 Jelly 的材料提炼器。只根据给定的带时间戳文稿输出符合 schema 的 JSON，不要编造文稿中没有的内容，也不要输出除 JSON 以外的文字。
        字段名和形状必须固定为：{"thesis":"字符串","takeaways":["字符串，1 到 7 项"],"chapters":[{"startSeconds":0,"title":"字符串","points":["字符串，至少 1 项"]}],"quotes":[{"speaker":"","startSeconds":0,"text":"字符串"}],"dropped":["字符串"]}。speaker 不确定时用空字符串，且必须出现在附近原文中才能填写；没有章节、引用或广告时 chapters、quotes、dropped 必须是空数组，不要输出 title、points 或 text 为空的占位对象。所有 startSeconds 必须是数字，来自文稿时间范围，且不超过最后一段结束时间，并按先后排序。
        """
        if source.kind == .video {
            prompt += "这是视频材料：提炼核心论点和可执行观点，章节按时间排序。"
        }
        if source.kind == .audio {
            prompt += "这是音频单集：必须识别广告、片头片尾和赞助口播并写入 dropped；没有这些内容时 dropped 用空数组，不要写空字符串；不得从原文稿中删除这些内容。"
        }
        return prompt
    }

    private static func userPrompt(for transcript: TimestampedTranscript) -> String {
        transcript.segments.map { segment in
            "[\(timestamp(segment.startSeconds))-\(timestamp(segment.endSeconds))] \(segment.text)"
        }.joined(separator: "\n")
    }

    private static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite,
              seconds >= 0,
              seconds <= MaterialDigestContentLimits.maximumTimestampSeconds
        else { return "--:--" }
        let tenths = Int((seconds * 10).rounded(.towardZero))
        return String(format: "%02d:%02d.%d", tenths / 600, (tenths % 600) / 10, tenths % 10)
    }

    private static func jsonSchema() -> [String: Any] { [
        "type": "object",
        "additionalProperties": false,
        "required": ["thesis", "takeaways", "chapters", "quotes", "dropped"],
        "properties": [
            "thesis": [
                "type": "string",
                "maxLength": MaterialDigestContentLimits.maximumThesisCharacters
            ],
            "takeaways": [
                "type": "array",
                "minItems": MaterialDigestContentLimits.minimumTakeaways,
                "maxItems": MaterialDigestContentLimits.maximumTakeaways,
                "items": [
                    "type": "string",
                    "maxLength": MaterialDigestContentLimits.maximumTakeawayCharacters
                ]
            ],
            "chapters": [
                "type": "array",
                "maxItems": MaterialDigestContentLimits.maximumChapters,
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["startSeconds", "title", "points"],
                    "properties": [
                        "startSeconds": [
                            "type": "number",
                            "minimum": 0,
                            "maximum": MaterialDigestContentLimits.maximumTimestampSeconds
                        ],
                        "title": [
                            "type": "string",
                            "maxLength": MaterialDigestContentLimits.maximumChapterTitleCharacters
                        ],
                        "points": [
                            "type": "array",
                            "minItems": 1,
                            "maxItems": MaterialDigestContentLimits.maximumChapterPoints,
                            "items": [
                                "type": "string",
                                "maxLength": MaterialDigestContentLimits.maximumPointCharacters
                            ]
                        ]
                    ]
                ]
            ],
            "quotes": [
                "type": "array",
                "maxItems": MaterialDigestContentLimits.maximumQuotes,
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["speaker", "startSeconds", "text"],
                    "properties": [
                        "speaker": [
                            "type": "string",
                            "maxLength": MaterialDigestContentLimits.maximumSpeakerCharacters
                        ],
                        "startSeconds": [
                            "type": "number",
                            "minimum": 0,
                            "maximum": MaterialDigestContentLimits.maximumTimestampSeconds
                        ],
                        "text": [
                            "type": "string",
                            "maxLength": MaterialDigestContentLimits.maximumQuoteCharacters
                        ]
                    ]
                ]
            ],
            "dropped": [
                "type": "array",
                "maxItems": MaterialDigestContentLimits.maximumDroppedItems,
                "items": [
                    "type": "string",
                    "maxLength": MaterialDigestContentLimits.maximumDroppedItemCharacters
                ]
            ]
        ]
    ] }
}
