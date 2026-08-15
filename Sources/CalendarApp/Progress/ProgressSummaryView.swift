import CalendarDomain
import SwiftUI

/// A compact, factual week/month review built entirely from local calendar data.
struct ProgressSummaryView: View {
    let store: WorkspaceStore
    let period: ProgressSummaryPeriod
    let today: CalendarDate
    let hiddenCategoryIDs: Set<UUID>
    let onOpenItem: (String) -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var phase: ProgressSummaryPhase = .idle
    @State private var selectedOverview: ProgressSummaryOverview = .open
    @State private var selectedForMigration = Set<UUID>()
    @State private var migrationNotice: (message: String, stateGeneration: UInt)?
    @State private var pendingMigrationPrompt: ProgressMigrationPrompt?

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
        .frame(width: 480)
        .frame(maxHeight: 600)
        .background(theme.elevatedSurface)
        .foregroundStyle(theme.primaryText)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.subtleBorder.opacity(0.65), lineWidth: 0.5)
        }
        .shadow(color: theme.subtleShadow.opacity(0.22), radius: 18, y: 8)
        .onAppear { generateIfNeeded() }
        .confirmationDialog(
            pendingMigrationPrompt?.title ?? "确认迁移？",
            isPresented: migrationConfirmationPresented,
            titleVisibility: .visible
        ) {
            if let prompt = pendingMigrationPrompt {
                Button(prompt.confirmationTitle) {
                    pendingMigrationPrompt = nil
                    Task { await migrateSelected() }
                }
            }
            Button("取消", role: .cancel) { pendingMigrationPrompt = nil }
        } message: {
            if let prompt = pendingMigrationPrompt {
                Text(prompt.message)
            }
        }
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

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle, .loading:
            loadingBody
        case let .ready(report):
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    overviewGrid(report.stats)
                    Text(report.factualSummary)
                        .font(.system(size: 13, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    selectedDetail(report.stats)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private func overviewGrid(_ stats: ProgressSummaryStats) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(ProgressSummaryOverview.allCases) { overview in
                overviewCard(overview, stats: stats)
            }
        }
    }

    private func overviewCard(_ overview: ProgressSummaryOverview, stats: ProgressSummaryStats) -> some View {
        Button {
            selectedOverview = overview
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(overview.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                    Text(overview.value(in: stats))
                        .font(.system(size: 17, weight: .semibold).monospacedDigit())
                        .foregroundStyle(theme.primaryText)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                selectedOverview == overview
                    ? theme.controlAccent.opacity(0.11)
                    : theme.subtleBorder.opacity(0.16),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        selectedOverview == overview ? theme.controlAccent.opacity(0.55) : .clear,
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(overview.title) \(overview.value(in: stats))")
        .accessibilityHint("查看对应明细")
    }

    @ViewBuilder
    private func selectedDetail(_ stats: ProgressSummaryStats) -> some View {
        switch selectedOverview {
        case .completed:
            itemBlock(title: "本期完成", items: selectedOverview.items(in: stats), emptyText: "暂无已完成事项")
        case .open:
            itemBlock(title: "仍在进行", items: selectedOverview.items(in: stats), emptyText: "没有待处理事项", allowsMigration: true)
            migrationActions(stats)
        case .overdue:
            itemBlock(title: "已延期", items: selectedOverview.items(in: stats), emptyText: "没有延期事项", allowsMigration: true)
            migrationActions(stats)
        case .categories:
            categoryBlock(stats)
        }
    }

    private func itemBlock(
        title: String,
        items: [ProgressItemFact],
        emptyText: String,
        allowsMigration: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            if items.isEmpty {
                Text(emptyText)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
            } else {
                ForEach(items) { item in
                    HStack(spacing: 8) {
                        if allowsMigration, let itemID = item.calendarItemID {
                            Button {
                                if selectedForMigration.contains(itemID) {
                                    selectedForMigration.remove(itemID)
                                } else {
                                    selectedForMigration.insert(itemID)
                                }
                            } label: {
                                Image(systemName: selectedForMigration.contains(itemID) ? "checkmark.circle.fill" : "circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(selectedForMigration.contains(itemID) ? theme.controlAccent : theme.secondaryText)
                            .accessibilityLabel(selectedForMigration.contains(itemID) ? "取消迁移 \(item.title)" : "选择迁移 \(item.title)")
                        } else {
                            Image(systemName: title == "本期完成" ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(title == "本期完成" ? theme.controlAccent : theme.secondaryText)
                        }
                        Button {
                            onOpenItem(item.id)
                        } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                    Text(dateCaption(item.date))
                                        .font(.system(size: 10))
                                        .foregroundStyle(theme.secondaryText)
                                }
                                Spacer(minLength: 8)
                                if item.isOverdue {
                                    Text("已延期")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(theme.error)
                                }
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(theme.secondaryText)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("打开事项 \(item.title)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            theme.subtleBorder.opacity(0.14),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    @ViewBuilder
    private func migrationActions(_ stats: ProgressSummaryStats) -> some View {
        if let notice = migrationNotice {
            HStack(spacing: 10) {
                Label(notice.message, systemImage: "checkmark.circle.fill")
                Spacer()
                Button("撤销") { Task { await undoMigration(notice) } }
            }
            .font(.system(size: 12, weight: .medium))
            .padding(12)
            .background(theme.controlAccent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        } else if stats.open.contains(where: { $0.calendarItemID != nil }) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("建议迁移到下期")
                        .font(.system(size: 12, weight: .semibold))
                    Text("只移动你勾选的一次性事项；重复事项保持不变。")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer()
                Button(migrationButtonTitle) {
                    pendingMigrationPrompt = ProgressMigrationPrompt(
                        period: period,
                        selectedCount: selectedForMigration.count
                    )
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(selectedForMigration.isEmpty)
            }
            .padding(12)
            .background(theme.subtleBorder.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var migrationButtonTitle: String {
        let target = period == .week ? "下周" : "下月"
        return selectedForMigration.isEmpty ? "选择事项" : "移到\(target) · \(selectedForMigration.count)"
    }

    private func migrateSelected() async {
        guard case let .ready(report) = phase else { return }
        let ids = report.stats.open.compactMap(\.calendarItemID).filter(selectedForMigration.contains)
        guard !ids.isEmpty else { return }
        do {
            _ = try await store.sendCalendar(
                .moveItems(ids, to: migrationDestination(for: report.stats.range)),
                undoLabel: period == .week ? "移到下周" : "移到下月"
            )
            selectedForMigration.removeAll()
            migrationNotice = (
                message: "已将 \(ids.count) 件事项移到\(period == .week ? "下周" : "下月")",
                stateGeneration: store.statePublicationGeneration
            )
            generateIfNeeded(force: true)
        } catch {
            phase = .failed("迁移没有完成，原日程保持不变。")
        }
    }

    private var migrationConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingMigrationPrompt != nil },
            set: { if !$0 { pendingMigrationPrompt = nil } }
        )
    }

    private func dateCaption(_ date: CalendarDate) -> String {
        "\(date.month)月\(date.day)日"
    }

    private func undoMigration(_ notice: (message: String, stateGeneration: UInt)) async {
        guard migrationNotice?.stateGeneration == notice.stateGeneration,
              store.statePublicationGeneration == notice.stateGeneration else {
            migrationNotice = nil
            return
        }
        do {
            _ = try await store.undo()
            migrationNotice = nil
            generateIfNeeded(force: true)
        } catch {
            migrationNotice = nil
        }
    }

    private func migrationDestination(for range: ProgressSummaryRange) -> CalendarDate {
        switch period {
        case .week:
            return range.start.addingDays(7)
        case .month:
            let nextMonth = range.start.month == 12 ? 1 : range.start.month + 1
            let nextYear = range.start.month == 12 ? range.start.year + 1 : range.start.year
            return CalendarDate(year: nextYear, month: nextMonth, day: 1) ?? range.end.addingDays(1)
        }
    }

    private func categoryBlock(_ stats: ProgressSummaryStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("分类分布")
                .font(.system(size: 12, weight: .semibold))

            if stats.categories.isEmpty {
                Text("暂无分类数据")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
            }
            ForEach(stats.categories) { category in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(CalendarTheme.categoryTagColor(category.colorHex, appearance: appearance))
                        .frame(width: 8, height: 8)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(category.name)
                            .font(.system(size: 12, weight: .semibold))
                        Text("共 \(category.total) 件 · 完成 \(category.completed) 件")
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

    private func generateIfNeeded(force: Bool = false) {
        if case .ready = phase, !force { return }
        if case .loading = phase { return }
        phase = .loading
        Task { @MainActor in
            await Task.yield()
            let stats = ProgressSummaryEngine.stats(
                state: store.calendarState,
                period: period,
                today: today,
                hiddenCategoryIDs: hiddenCategoryIDs
            )
            phase = .ready(ProgressSummaryEngine.report(from: stats))
        }
    }
}
