import Foundation

public enum MaterialDigestStage: String, Codable, Equatable, Sendable {
    case fetchingSource
    case awaitingModelDownloadConsent
    case downloadingModel
    case transcribing
    case summarizing
}

public enum MaterialDigestContentLimits {
    public static let maximumTimestampSeconds: Double = 604_800
    public static let maximumTranscriptSegments = 50_000
    public static let maximumTranscriptCharacters = 2_000_000
    public static let maximumSegmentCharacters = 10_000
    public static let maximumThesisCharacters = 4_000
    public static let minimumTakeaways = 1
    public static let maximumTakeaways = 7
    public static let takeawayCountRange = minimumTakeaways...maximumTakeaways
    public static let maximumTakeawayCharacters = 2_000
    public static let maximumChapters = 100
    public static let maximumChapterPoints = 20
    public static let maximumChapterTitleCharacters = 500
    public static let maximumPointCharacters = 1_000
    public static let maximumQuotes = 100
    public static let maximumQuoteCharacters = 2_000
    public static let maximumSpeakerCharacters = 200
    public static let maximumDroppedItems = 100
    public static let maximumDroppedItemCharacters = 1_000
    public static let maximumSummaryCharacters = 200_000
}

public struct MaterialDigestRun: Codable, Equatable, Sendable {
    public let id: MaterialDigestRunID
    public var stage: MaterialDigestStage
    public let startedAt: Date
    public var updatedAt: Date
    public var modelDownloadApproximateBytes: Int64?

    public init(
        id: MaterialDigestRunID,
        stage: MaterialDigestStage,
        startedAt: Date,
        updatedAt: Date,
        modelDownloadApproximateBytes: Int64? = nil
    ) {
        self.id = id
        self.stage = stage
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.modelDownloadApproximateBytes = modelDownloadApproximateBytes
    }
}

public struct TranscriptSegment: Codable, Equatable, Sendable {
    public var startSeconds: Double
    public var endSeconds: Double
    public var text: String

    public init(startSeconds: Double, endSeconds: Double, text: String) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
    }
}

public struct TimestampedTranscript: Codable, Equatable, Sendable {
    public var segments: [TranscriptSegment]

    public init(segments: [TranscriptSegment]) {
        self.segments = segments
    }
}

public struct DigestChapter: Codable, Equatable, Sendable {
    public var startSeconds: Double
    public var title: String
    public var points: [String]

    public init(startSeconds: Double, title: String, points: [String]) {
        self.startSeconds = startSeconds
        self.title = title
        self.points = points
    }
}

public struct DigestQuote: Codable, Equatable, Sendable {
    public var speaker: String?
    public var startSeconds: Double
    public var text: String

    public init(speaker: String?, startSeconds: Double, text: String) {
        self.speaker = speaker
        self.startSeconds = startSeconds
        self.text = text
    }
}

public struct InspirationSummary: Codable, Equatable, Sendable {
    public var thesis: String
    public var takeaways: [String]
    public var chapters: [DigestChapter]
    public var quotes: [DigestQuote]
    public var dropped: [String]

    public init(
        thesis: String,
        takeaways: [String],
        chapters: [DigestChapter],
        quotes: [DigestQuote],
        dropped: [String]
    ) {
        self.thesis = thesis
        self.takeaways = takeaways
        self.chapters = chapters
        self.quotes = quotes
        self.dropped = dropped
    }
}

public struct DigestProvenance: Codable, Equatable, Sendable {
    public var modelIdentifier: String
    public var generatedAt: Date
    public var inputFingerprint: String
    public var summaryContractVersion: String

    public init(
        modelIdentifier: String,
        generatedAt: Date,
        inputFingerprint: String,
        summaryContractVersion: String
    ) {
        self.modelIdentifier = modelIdentifier
        self.generatedAt = generatedAt
        self.inputFingerprint = inputFingerprint
        self.summaryContractVersion = summaryContractVersion
    }
}

public struct MaterialDigestResult: Codable, Equatable, Sendable {
    public var transcript: TimestampedTranscript
    public var summary: InspirationSummary
    public var provenance: DigestProvenance
    public var completedAt: Date

    public init(
        transcript: TimestampedTranscript,
        summary: InspirationSummary,
        provenance: DigestProvenance,
        completedAt: Date
    ) {
        self.transcript = transcript
        self.summary = summary
        self.provenance = provenance
        self.completedAt = completedAt
    }
}

public struct MaterialDigestFailure: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Equatable, Sendable {
        case unsupportedSource
        case restrictedSource
        case sourceUnavailable
        case modelDownloadFailed
        case transcriptionFailed
        case modelNotConfigured
        case authenticationFailed
        case accessDenied
        case summarizationFailed
        case invalidSummary
        case insufficientContent
        case cancelled
        case interrupted
    }

    public var code: Code
    public var userMessage: String
    public var occurredAt: Date

    public init(code: Code, userMessage: String, occurredAt: Date) {
        self.code = code
        self.userMessage = userMessage
        self.occurredAt = occurredAt
    }
}

public struct MaterialDigestNoteWrite: Codable, Equatable, Sendable {
    public let noteID: NoteID
    public let resultFingerprint: String
    public let blockIDs: [BlockID]
    public let writtenAt: Date

    public init(noteID: NoteID, resultFingerprint: String, blockIDs: [BlockID], writtenAt: Date) {
        self.noteID = noteID
        self.resultFingerprint = resultFingerprint
        self.blockIDs = blockIDs
        self.writtenAt = writtenAt
    }
}

public struct MaterialDigest: Identifiable, Codable, Equatable, Sendable {
    public let id: MaterialDigestID
    public let inspirationID: InspirationID
    public let sourceChecksum: String
    public var currentRun: MaterialDigestRun?
    public var result: MaterialDigestResult?
    public var lastFailure: MaterialDigestFailure?
    public var noteWrite: MaterialDigestNoteWrite?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: MaterialDigestID,
        inspirationID: InspirationID,
        sourceChecksum: String,
        currentRun: MaterialDigestRun?,
        result: MaterialDigestResult?,
        lastFailure: MaterialDigestFailure?,
        noteWrite: MaterialDigestNoteWrite? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.inspirationID = inspirationID
        self.sourceChecksum = sourceChecksum
        self.currentRun = currentRun
        self.result = result
        self.lastFailure = lastFailure
        self.noteWrite = noteWrite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
