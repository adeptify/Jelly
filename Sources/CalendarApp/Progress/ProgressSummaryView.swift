import CalendarDomain
import SwiftUI

/// Sheet UI for week/month progress summary. AI text is mocked until prologue is wired.
struct ProgressSummaryView: View {
    let store: WorkspaceStore
    let period: ProgressSummaryPeriod
    let today: CalendarDate
    let hiddenCategoryIDs: Set<UUID>
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var phase: ProgressSummaryPhase = .idle

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    private var appearance: CalendarAppearance {
        colorScheme == .dark ? .dark : .light
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.separator.opacity(0.55))
            content
        }
        .frame(width: 420)
        .frame(maxHeight: 560)
        .background(theme.elevatedSurface)
        .foregroundStyle(theme.primaryText)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.subtleBorder.opacity(0.65), lineWidth: 0.5)
        }
        .shadow(color: theme.subtleShadow.opacity(0.22), radius: 18, y: 8)
        .onAppear { generateIfNeeded() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(period.title)
                    .font(.system(size: 15, weight: .semibold))
                if case let .ready(report) = phase {
                    Text(report.stats.range.rangeCaption)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                } else {
                    Text("从\(period.shortLabel)第一天到今天")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            Spacer(minLength: 8)
            if case .ready = phase {
                mockBadge
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 22, height: 22)
                    .background(theme.subtleBorder.opacity(0.35), in: Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var mockBadge: some View {
        Text("模拟 AI")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(theme.controlAccent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                theme.controlAccent.opacity(0.14),
                in: Capsule()
            )
            .help("当前为本地模拟文案，后续将接入 prologue")
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle, .loading:
            loadingBody
        case let .ready(report):
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statsStrip(report.stats)
                    sectionCard(title: "一、整体亮点", body: report.highlights)
                    categoryBlock(report)
                    sectionCard(title: "三、夸夸时刻", body: report.encouragement)
                    footerNote
                }
                .padding(16)
            }
        case let .failed(message):
            VStack(spacing: 12) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.error)
                    .multilineTextAlignment(.center)
                Button("重试") { generateIfNeeded(force: true) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        }
    }

    private var loadingBody: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.small)
            Text("正在整理\(period.shortLabel)进展…")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
            Text("（模拟 AI，稍后接入 prologue）")
                .font(.system(size: 10))
                .foregroundStyle(theme.secondaryText.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private func statsStrip(_ stats: ProgressSummaryStats) -> some View {
        HStack(spacing: 10) {
            statPill(title: "事项", value: "\(stats.totalItems)")
            statPill(title: "已完成", value: "\(stats.completedItems)")
            statPill(title: "完成率", value: stats.totalItems == 0 ? "—" : "\(stats.completionPercent)%")
            statPill(title: "进行中", value: "\(stats.openItems)")
        }
    }

    private func statPill(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            theme.subtleBorder.opacity(0.16),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private func sectionCard(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.controlAccent)
            Text(body.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 12.5))
                .foregroundStyle(theme.primaryText)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            theme.subtleBorder.opacity(0.14),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private func categoryBlock(_ report: ProgressSummaryReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("二、分类进展")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.controlAccent)

            ForEach(report.categorySections) { section in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(CalendarTheme.categoryTagColor(section.colorHex, appearance: appearance))
                        .frame(width: 8, height: 8)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(section.name)
                            .font(.system(size: 12, weight: .semibold))
                        Text(section.body)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            theme.subtleBorder.opacity(0.14),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private var footerNote: some View {
        Text("文案由本地规则模拟生成，后续将通过 prologue 调用真实 AI。")
            .font(.system(size: 10))
            .foregroundStyle(theme.secondaryText.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func generateIfNeeded(force: Bool = false) {
        if case .ready = phase, !force { return }
        if case .loading = phase { return }
        phase = .loading
        // Short delay so the loading state is perceptible; stands in for network AI.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(480))
            let stats = ProgressSummaryEngine.stats(
                state: store.calendarState,
                period: period,
                today: today,
                hiddenCategoryIDs: hiddenCategoryIDs
            )
            phase = .ready(ProgressSummaryMockAI.generate(from: stats))
        }
    }
}
