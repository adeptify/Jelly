import SwiftUI
import WorkspaceDomain

struct MaterialDigestPresentation: Equatable {
    var isVisible: Bool
    var statusText: String
    var primaryActionTitle: String?
    var showsCancel: Bool
    var showsRetry: Bool
    var showsConfirmDownload: Bool
    var confirmDownloadTitle: String?
    var thesis: String?
    var takeaways: [String]
    var chapters: [DigestChapter]
    var quotes: [DigestQuote]
    var dropped: [String]
    var transcriptAvailable: Bool
    var transcriptCollapsedByDefault: Bool

    static let hidden = MaterialDigestPresentation(
        isVisible: false,
        statusText: "",
        primaryActionTitle: nil,
        showsCancel: false,
        showsRetry: false,
        showsConfirmDownload: false,
        confirmDownloadTitle: nil,
        thesis: nil,
        takeaways: [],
        chapters: [],
        quotes: [],
        dropped: [],
        transcriptAvailable: false,
        transcriptCollapsedByDefault: true
    )

    static func project(
        inspiration: Inspiration,
        digest: MaterialDigest?,
        operatorAvailable: Bool
    ) -> MaterialDigestPresentation {
        guard operatorAvailable,
              inspiration.inputKind == .url,
              inspiration.resolvedSourceKind == .video || inspiration.resolvedSourceKind == .audio
        else { return .hidden }

        var presentation = MaterialDigestPresentation.hidden
        presentation.isVisible = true
        if let result = digest?.result {
            presentation.thesis = result.summary.thesis
            presentation.takeaways = result.summary.takeaways
            presentation.chapters = result.summary.chapters
            presentation.quotes = result.summary.quotes
            presentation.dropped = result.summary.dropped
            presentation.transcriptAvailable = !result.transcript.segments.isEmpty
            presentation.transcriptCollapsedByDefault = true
        }
        if let run = digest?.currentRun {
            presentation.showsCancel = true
            presentation.primaryActionTitle = nil
            switch run.stage {
            case .fetchingSource:
                presentation.statusText = inspiration.resolvedSourceKind == .audio
                    ? "正在获取音频"
                    : "正在获取字幕"
            case .awaitingModelDownloadConsent:
                presentation.statusText = "首次需要下载约 626 MB 识别模型，有字幕的材料不会下载。"
                presentation.showsConfirmDownload = true
                presentation.confirmDownloadTitle = "下载并继续"
            case .downloadingModel:
                presentation.statusText = "正在下载识别模型"
            case .transcribing:
                presentation.statusText = "正在识别"
            case .summarizing:
                presentation.statusText = "正在生成摘要"
            }
            return presentation
        }
        if let failure = digest?.lastFailure {
            presentation.statusText = failure.userMessage
            presentation.showsRetry = true
            presentation.primaryActionTitle = "重试"
            return presentation
        }
        if digest?.result != nil {
            presentation.statusText = "提炼完成，可以审阅后写入笔记。"
            return presentation
        }
        presentation.statusText = "尚未提炼"
        presentation.primaryActionTitle = "提炼这个链接"
        return presentation
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
                Button(title) {
                    if presentation.showsRetry { onRetry() } else { onStart() }
                }
                .accessibilityLabel(title)
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
                Text("\(timestamp(chapter.startSeconds)) \(chapter.title)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(presentation.quotes.enumerated()), id: \.offset) { _, quote in
                Text(quote.text)
                    .font(.system(size: 12).italic())
            }
            if !presentation.dropped.isEmpty {
                Text("可能的广告或片头片尾：\(presentation.dropped.joined(separator: "、"))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if presentation.transcriptAvailable {
                DisclosureGroup("完整文稿", isExpanded: $transcriptExpanded) {
                    Text("文稿已保存在提炼结果中，不会默认写入笔记。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 4)
        .onAppear { transcriptExpanded = !presentation.transcriptCollapsedByDefault }
    }

    private func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.towardZero)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
