import SwiftUI
import WorkspaceDomain

struct MaterialDigestPresentation: Equatable {
    var isVisible: Bool
    var statusText: String
    var progressFraction: Double?
    var primaryActionTitle: String?
    var showsCancel: Bool
    var showsRetry: Bool
    var showsOpenSettings: Bool
    var showsConfirmDownload: Bool
    var confirmDownloadTitle: String?
    var thesis: String?
    var takeaways: [String]
    var chapters: [DigestChapter]
    var quotes: [DigestQuote]
    var dropped: [String]
    var transcriptAvailable: Bool
    var transcriptSegments: [TranscriptSegment]
    var transcriptCollapsedByDefault: Bool

    static let hidden = MaterialDigestPresentation(
        isVisible: false,
        statusText: "",
        progressFraction: nil,
        primaryActionTitle: nil,
        showsCancel: false,
        showsRetry: false,
        showsOpenSettings: false,
        showsConfirmDownload: false,
        confirmDownloadTitle: nil,
        thesis: nil,
        takeaways: [],
        chapters: [],
        quotes: [],
        dropped: [],
        transcriptAvailable: false,
        transcriptSegments: [],
        transcriptCollapsedByDefault: true
    )

    static func project(
        inspiration: Inspiration,
        digest: MaterialDigest?,
        operatorAvailable: Bool,
        modelConfigured: Bool = true,
        progressFraction: Double? = nil
    ) -> MaterialDigestPresentation {
        guard operatorAvailable,
              inspiration.inputKind == .url,
              inspiration.resolvedSourceKind == .video || inspiration.resolvedSourceKind == .audio
        else { return .hidden }

        var presentation = MaterialDigestPresentation.hidden
        presentation.isVisible = true
        presentation.progressFraction = progressFraction
        if let result = digest?.result {
            presentation.thesis = result.summary.thesis
            presentation.takeaways = result.summary.takeaways
            presentation.chapters = result.summary.chapters
            presentation.quotes = result.summary.quotes
            presentation.dropped = result.summary.dropped
            presentation.transcriptAvailable = !result.transcript.segments.isEmpty
            presentation.transcriptSegments = result.transcript.segments
            presentation.transcriptCollapsedByDefault = true
        }
        if inspiration.lifecycle != .active {
            guard digest?.result != nil else { return .hidden }
            presentation.statusText = "已归档，提炼结果仅供查看。"
            return presentation
        }
        if let run = digest?.currentRun {
            presentation.showsCancel = true
            presentation.primaryActionTitle = nil
            switch run.stage {
            case .fetchingSource:
                presentation.statusText = withProgress(inspiration.resolvedSourceKind == .audio
                    ? "正在获取音频"
                    : "正在获取字幕", fraction: progressFraction)
            case .awaitingModelDownloadConsent:
                presentation.statusText = modelDownloadConsentText(
                    approximateBytes: digest?.currentRun?.modelDownloadApproximateBytes
                )
                presentation.showsConfirmDownload = true
                presentation.confirmDownloadTitle = "下载并继续"
            case .downloadingModel:
                presentation.statusText = withProgress("正在下载识别模型", fraction: progressFraction)
            case .transcribing:
                presentation.statusText = withProgress("正在识别", fraction: progressFraction)
            case .summarizing:
                presentation.statusText = "正在生成摘要"
            }
            return presentation
        }
        if let failure = digest?.lastFailure {
            presentation.statusText = failure.userMessage
            if failure.code == .modelNotConfigured, modelConfigured {
                presentation.statusText = "设置已就绪，可以重试提炼。"
                presentation.showsRetry = true
                presentation.primaryActionTitle = "重试"
            } else if failure.code == .modelNotConfigured
                || failure.code == .authenticationFailed
                || failure.code == .accessDenied
                || !modelConfigured {
                presentation.showsOpenSettings = true
                presentation.primaryActionTitle = "打开设置"
            } else {
                presentation.showsRetry = true
                presentation.primaryActionTitle = "重试"
            }
            return presentation
        }
        if digest?.result != nil {
            presentation.statusText = "提炼完成，可以审阅后写入笔记。"
            return presentation
        }
        if !modelConfigured {
            presentation.statusText = "尚未配置摘要模型，请先在设置中填写。"
            presentation.showsOpenSettings = true
            presentation.primaryActionTitle = "打开设置"
            return presentation
        }
        presentation.statusText = "尚未提炼"
        presentation.primaryActionTitle = "提炼这个链接"
        return presentation
    }

    static func modelDownloadConsentText(approximateBytes: Int64?) -> String {
        let suffix = "识别模型，有字幕的材料不会下载。"
        guard let approximateBytes, approximateBytes > 0 else {
            return "首次需要下载\(suffix)"
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        let size = formatter.string(fromByteCount: approximateBytes)
        return "首次需要下载约 \(size) \(suffix)"
    }

    private static func withProgress(_ text: String, fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return text }
        let percent = min(100, max(0, Int((fraction * 100).rounded())))
        return "\(text) \(percent)%"
    }
}

struct MaterialDigestSection: View {
    let presentation: MaterialDigestPresentation
    var onStart: () -> Void
    var onCancel: () -> Void
    var onRetry: () -> Void
    var onConfirmDownload: () -> Void
    @State private var transcriptExpanded = false

    var body: some View {
        if presentation.isVisible {
            VStack(alignment: .leading, spacing: 10) {
                Text("材料提炼")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(presentation.statusText)
                    .font(.system(size: 13))
                    .accessibilityLabel(presentation.statusText)
                actionRow
                if let thesis = presentation.thesis {
                    review(thesis: thesis)
                }
            }
            .padding(.top, 16)
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 8) {
            if let title = presentation.primaryActionTitle {
                if presentation.showsOpenSettings {
                    SettingsLink {
                        Text(title)
                    }
                    .accessibilityLabel(title)
                } else {
                    Button(title) {
                        if presentation.showsRetry { onRetry() } else { onStart() }
                    }
                    .accessibilityLabel(title)
                }
            }
            if presentation.showsConfirmDownload, let title = presentation.confirmDownloadTitle {
                Button(title, action: onConfirmDownload)
                    .accessibilityLabel(title)
            }
            if presentation.showsCancel {
                Button("取消", action: onCancel)
                    .accessibilityLabel("取消")
            }
        }
    }

    @ViewBuilder
    private func review(thesis: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(thesis)
                .font(.system(size: 14, weight: .medium))
            ForEach(Array(presentation.takeaways.enumerated()), id: \.offset) { _, takeaway in
                Text("• \(takeaway)")
                    .font(.system(size: 13))
            }
            ForEach(Array(presentation.chapters.enumerated()), id: \.offset) { _, chapter in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(timestamp(chapter.startSeconds)) \(chapter.title)")
                        .font(.system(size: 12, weight: .medium))
                    ForEach(Array(chapter.points.enumerated()), id: \.offset) { _, point in
                        Text("• \(point)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(Array(presentation.quotes.enumerated()), id: \.offset) { _, quote in
                Text(quoteLine(quote))
                    .font(.system(size: 12).italic())
            }
            if !presentation.dropped.isEmpty {
                Text("可能的广告或片头片尾：\(presentation.dropped.joined(separator: "、"))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if presentation.transcriptAvailable {
                DisclosureGroup("完整文稿", isExpanded: $transcriptExpanded) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(presentation.transcriptSegments.enumerated()), id: \.offset) { _, segment in
                            Text("\(timestamp(segment.startSeconds))  \(segment.text)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .textSelection(.enabled)
                }
            }
        }
        .padding(.top, 4)
        .onAppear { transcriptExpanded = !presentation.transcriptCollapsedByDefault }
    }

    private func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite,
              seconds >= 0,
              seconds <= MaterialDigestContentLimits.maximumTimestampSeconds
        else { return "--:--" }
        let total = max(0, Int(seconds.rounded(.towardZero)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func quoteLine(_ quote: DigestQuote) -> String {
        let prefix = "\(timestamp(quote.startSeconds)) "
        guard let speaker = quote.speaker?.trimmingCharacters(in: .whitespacesAndNewlines),
              !speaker.isEmpty
        else { return prefix + quote.text }
        return "\(prefix)\(speaker)：\(quote.text)"
    }
}
