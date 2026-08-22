import Foundation

public enum MaterialDigestEvidence {
    public static let nearbyWindowSeconds: Double = 2.0

    public static func transcriptEnd(_ transcript: TimestampedTranscript) -> Double {
        transcript.segments.map(\.endSeconds).max() ?? 0
    }

    public static func foldedText(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    public static func nearbyTranscriptText(
        _ transcript: TimestampedTranscript,
        at startSeconds: Double
    ) -> String {
        transcript.segments
            .filter {
                $0.endSeconds >= startSeconds - nearbyWindowSeconds
                    && $0.startSeconds <= startSeconds + nearbyWindowSeconds
            }
            .map(\.text)
            .joined()
    }

    public static func textAppearsNearby(
        _ text: String,
        at startSeconds: Double,
        in transcript: TimestampedTranscript
    ) -> Bool {
        let needle = foldedText(text)
        guard !needle.isEmpty else { return false }
        return foldedText(nearbyTranscriptText(transcript, at: startSeconds)).contains(needle)
    }

    public static func speakerAppearsNearby(
        _ speaker: String,
        at startSeconds: Double,
        in transcript: TimestampedTranscript
    ) -> Bool {
        textAppearsNearby(speaker, at: startSeconds, in: transcript)
    }

    public static func sanitizedQuote(
        _ quote: DigestQuote,
        transcript: TimestampedTranscript,
        maximumSourceTime: Double
    ) -> DigestQuote? {
        let text = quote.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let speaker = quote.speaker?.trimmingCharacters(in: .whitespacesAndNewlines)
        let supportedSpeaker: String?
        if let speaker, !speaker.isEmpty, speakerAppearsNearby(speaker, at: quote.startSeconds, in: transcript) {
            supportedSpeaker = speaker
        } else {
            supportedSpeaker = nil
        }
        let kept = DigestQuote(
            speaker: supportedSpeaker,
            startSeconds: quote.startSeconds,
            text: text
        )
        if quote.startSeconds.isFinite,
           quote.startSeconds >= 0,
           quote.startSeconds <= maximumSourceTime,
           !textAppearsNearby(text, at: quote.startSeconds, in: transcript) {
            return nil
        }
        return kept
    }
}
