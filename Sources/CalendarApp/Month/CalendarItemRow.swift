import CalendarDomain
import SwiftUI

enum ItemCompletionRouter {
    static func command(for item: ProjectedItem, now: Date) -> CalendarCommand? {
        guard item.kind == .task else {
            return nil
        }
        switch item {
        case let .item(item):
            return .setTaskCompleted(item.id, item.completedAt == nil ? now : nil)
        case let .occurrence(occurrence):
            return .setOccurrenceCompleted(
                occurrence.key,
                occurrence.completedAt == nil ? now : nil
            )
        }
    }
}

enum CalendarItemRowHitTarget {
    case completion
    case rowBody
}

struct CalendarItemAccessibility: Equatable {
    let label: String
    let value: String

    static func make(item: ProjectedItem, categoryName: String) -> CalendarItemAccessibility {
        let kind = item.kind == .task ? "待办" : "日程"
        var components = [kind, categoryName, item.title, dateTimeRangeText(for: item.schedule)]
        if item.kind == .task {
            components.append(item.completedAt == nil ? "未完成" : "已完成")
        }
        return CalendarItemAccessibility(
            label: components.joined(separator: "，"),
            value: sourceValue(for: item)
        )
    }

    static func sourceValue(for item: ProjectedItem) -> String {
        "来源事项 \(sourceIdentifier(for: item))"
    }

    static func completionLabel(isCompleted: Bool) -> String {
        isCompleted ? "标记为未完成" : "标记为已完成"
    }

    static func sourceIdentifier(for item: ProjectedItem) -> String {
        switch item {
        case let .item(item):
            "item:\(item.id.uuidString)"
        case let .occurrence(occurrence):
            "occurrence:\(occurrence.key.seriesID.uuidString):\(dateIdentifier(occurrence.key.originalDate))"
        }
    }

    static func dateTimeRangeText(for schedule: CalendarSchedule) -> String {
        let includesYear = schedule.startDate.year != schedule.endDate.year
        let startDate = dateText(schedule.startDate, includesYear: includesYear)
        let endDate = dateText(schedule.endDate, includesYear: includesYear)
        guard let startTime = schedule.startTime, let endTime = schedule.endTime else {
            return schedule.startDate == schedule.endDate
                ? startDate
                : "\(startDate)至\(endDate)"
        }
        if schedule.startDate == schedule.endDate {
            return "\(startDate) \(timeText(startTime))至\(timeText(endTime))"
        }
        return "\(startDate) \(timeText(startTime))至\(endDate) \(timeText(endTime))"
    }

    static func fullDateText(_ date: CalendarDate) -> String {
        dateText(date, includesYear: true)
    }

    private static func dateText(_ date: CalendarDate, includesYear: Bool) -> String {
        includesYear
            ? "\(date.year)年\(date.month)月\(date.day)日"
            : "\(date.month)月\(date.day)日"
    }

    private static func timeText(_ time: MinuteOfDay) -> String {
        String(format: "%02d:%02d", time.value / 60, time.value % 60)
    }

    private static func dateIdentifier(_ date: CalendarDate) -> String {
        String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
    }
}

struct CalendarItemRowInteraction {
    let completionCommand: CalendarCommand?
    let selectedDetailID: String?
}

enum CalendarItemRowInteractionRouter {
    static func route(
        target: CalendarItemRowHitTarget,
        item: ProjectedItem,
        now: Date
    ) -> CalendarItemRowInteraction {
        switch target {
        case .completion:
            return .init(
                completionCommand: ItemCompletionRouter.command(for: item, now: now),
                selectedDetailID: nil
            )
        case .rowBody:
            return .init(completionCommand: nil, selectedDetailID: item.id)
        }
    }
}

struct CalendarItemRowLayout: Equatable {
    let titleMinimumWidth: CGFloat?
    let timeLayoutPriority: Double
    let titleLayoutPriority: Double
    let inlineSpacing: CGFloat
    let textFontSize: CGFloat

    static let standard = CalendarItemRowLayout(
        titleMinimumWidth: 24,
        timeLayoutPriority: 3,
        titleLayoutPriority: 1,
        inlineSpacing: 4,
        textFontSize: 12
    )

    static let compact = CalendarItemRowLayout(
        titleMinimumWidth: 20,
        timeLayoutPriority: 4,
        titleLayoutPriority: 1,
        inlineSpacing: 3,
        textFontSize: 11
    )
}

struct CalendarItemRowPresentation: Equatable {
    /// Always nil on-screen: category is color-only (TickTick-style). Kept in accessibility labels.
    let categoryName: String?
    let timeText: String?
    let title: String
    let accessibilityLabel: String
    let layout: CalendarItemRowLayout

    private static let compactRowContentWidth = 140.0

    static func make(
        availableContentWidth: Double,
        categoryName: String,
        timeRange: LocalTimeRange?,
        title: String
    ) -> CalendarItemRowPresentation {
        make(
            availableContentWidth: availableContentWidth,
            startTime: timeRange?.start,
            title: title,
            accessibilityLabel: rowBodyAccessibilityLabel(
                categoryName: categoryName,
                timeRange: timeRange,
                title: title
            )
        )
    }

    static func make(
        availableContentWidth: Double,
        categoryName: String,
        schedule: CalendarSchedule,
        title: String
    ) -> CalendarItemRowPresentation {
        make(
            availableContentWidth: availableContentWidth,
            startTime: schedule.startTime,
            title: title,
            accessibilityLabel: rowBodyAccessibilityLabel(
                categoryName: categoryName,
                schedule: schedule,
                title: title
            )
        )
    }

    private static func make(
        availableContentWidth: Double,
        startTime: MinuteOfDay?,
        title: String,
        accessibilityLabel: String
    ) -> CalendarItemRowPresentation {
        let isCompactRow = availableContentWidth <= compactRowContentWidth
        return CalendarItemRowPresentation(
            categoryName: nil,
            timeText: startTime.map(timeString),
            title: title,
            accessibilityLabel: accessibilityLabel,
            layout: isCompactRow ? .compact : .standard
        )
    }

    static func rowBodyAccessibilityLabel(
        categoryName: String,
        timeRange: LocalTimeRange?,
        title: String
    ) -> String {
        var components = [categoryName]
        if let timeRange {
            components.append(timeString(timeRange.start))
        }
        components.append(title)
        return components.joined(separator: ", ")
    }

    static func rowBodyAccessibilityLabel(
        categoryName: String,
        schedule: CalendarSchedule,
        title: String
    ) -> String {
        var components = [categoryName]
        if let startTime = schedule.startTime {
            components.append(timeString(startTime))
        }
        components.append(title)
        return components.joined(separator: ", ")
    }

    private static func timeString(_ minute: MinuteOfDay) -> String {
        String(format: "%02d:%02d", minute.value / 60, minute.value % 60)
    }
}

struct CalendarItemRow: View {
    let item: ProjectedItem
    let category: CalendarCategory?
    var onCompletion: ((CalendarCommand) -> Void)?
    var onOpenDetail: ((ProjectedItem) -> Void)?
    var accessibilityLabelOverride: String?
    var accessibilityValueOverride: String?
    var continuesBefore = false
    var continuesAfter = false
    var showsLeadingHandle = false
    var showsTrailingHandle = false
    var leadingHandleAccessibility: CalendarResizeHandleAccessibility?
    var trailingHandleAccessibility: CalendarResizeHandleAccessibility?
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    private var appearance: CalendarAppearance {
        colorScheme == .dark ? .dark : .light
    }

    private var categoryHex: String {
        category?.colorHex ?? "#8C8F96"
    }

    private var itemColorRoles: CategoryRenderedColorRoles? {
        CalendarTheme.categoryItemRoles(
            categoryHex,
            isCompleted: isCompletedTask,
            appearance: appearance
        )
    }

    private var categoryColor: Color {
        itemColorRoles.map { CalendarTheme.categoryColor($0.accent) }
            ?? CalendarTheme.categoryColor(categoryHex)
    }

    private var categoryBackground: Color {
        itemColorRoles.map { CalendarTheme.categoryColor($0.background) }
            ?? CalendarTheme.itemBackground(CalendarTheme.categoryColor(categoryHex))
    }

    private var categoryText: Color {
        itemColorRoles.map { CalendarTheme.categoryColor($0.text) }
            ?? theme.primaryText
    }

    private var isCompletedTask: Bool {
        item.kind == .task && item.completedAt != nil
    }

    var body: some View {
        HStack(spacing: 4) {
            if continuesBefore {
                continuationMarker(systemName: "arrow.left")
            }
            if showsLeadingHandle {
                handleMarker(
                    leadingHandleAccessibility
                        ?? .init(label: "调整开始日期", value: CalendarItemAccessibility.fullDateText(item.schedule.startDate))
                )
            }

            if item.kind == .task {
                Button {
                    let interaction = CalendarItemRowInteractionRouter.route(
                        target: .completion,
                        item: item,
                        now: Date()
                    )
                    if let command = interaction.completionCommand {
                        onCompletion?(command)
                    }
                } label: {
                    Image(systemName: isCompletedTask ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(categoryColor.opacity(isCompletedTask ? 0.85 : 0.75))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(CalendarItemAccessibility.completionLabel(isCompleted: isCompletedTask))
                .accessibilityValue(isCompletedTask ? "已完成" : "未完成")
            }

            Button {
                let interaction = CalendarItemRowInteractionRouter.route(
                    target: .rowBody,
                    item: item,
                    now: Date()
                )
                if interaction.selectedDetailID != nil {
                    onOpenDetail?(item)
                }
            } label: {
                GeometryReader { proxy in
                    let presentation = CalendarItemRowPresentation.make(
                        availableContentWidth: proxy.size.width,
                        categoryName: category?.name ?? "未分类",
                        schedule: item.schedule,
                        title: item.title
                    )
                    // TickTick layout: title first, optional time trailing. Category is color-only.
                    HStack(spacing: presentation.layout.inlineSpacing) {
                        Text(presentation.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(minWidth: presentation.layout.titleMinimumWidth, alignment: .leading)
                            .layoutPriority(presentation.layout.titleLayoutPriority)
                        Spacer(minLength: 2)
                        if let timeText = presentation.timeText {
                            Text(timeText)
                                .monospacedDigit()
                                .fixedSize(horizontal: true, vertical: false)
                                .layoutPriority(presentation.layout.timeLayoutPriority)
                                .opacity(0.72)
                        }
                    }
                    .font(.system(size: presentation.layout.textFontSize))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                .foregroundStyle(categoryText)
            }
            .accessibilityLabel(
                accessibilityLabelOverride
                    ?? CalendarItemAccessibility.make(
                        item: item,
                        categoryName: category?.name ?? "未分类"
                    ).label
            )
            .accessibilityValue(
                accessibilityValueOverride
                    ?? CalendarItemAccessibility.make(
                        item: item,
                        categoryName: category?.name ?? "未分类"
                    ).value
            )
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsTrailingHandle {
                handleMarker(
                    trailingHandleAccessibility
                        ?? .init(label: "调整结束日期", value: CalendarItemAccessibility.fullDateText(item.schedule.endDate))
                )
            }
            if continuesAfter {
                continuationMarker(systemName: "arrow.right")
            }
        }
        .font(CalendarTheme.itemFont)
        .padding(.horizontal, 6)
        .frame(height: CalendarTheme.itemRowHeight)
        .background(
            categoryBackground,
            in: RoundedRectangle(cornerRadius: CalendarTheme.cornerRadius, style: .continuous)
        )
        .opacity(isCompletedTask ? CalendarTheme.completedItemOpacity : 1)
        .draggable(transferPayload)
    }

    private var transferPayload: CalendarTransferPayload {
        switch item {
        case let .item(item):
            .item(item.id)
        case let .occurrence(occurrence):
            .occurrence(occurrence.key)
        }
    }

    @ViewBuilder
    private func continuationMarker(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(theme.secondaryText)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func handleMarker(_ accessibility: CalendarResizeHandleAccessibility) -> some View {
        Capsule()
            .fill(categoryColor)
            .frame(width: 3, height: 12)
            .accessibilityLabel(accessibility.label)
            .accessibilityValue(accessibility.value)
            .help("\(accessibility.label)，\(accessibility.value)")
    }
}
