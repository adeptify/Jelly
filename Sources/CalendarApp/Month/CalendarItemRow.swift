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
    let categoryMinimumWidth: CGFloat?
    let categoryMaximumWidth: CGFloat?
    let titleMinimumWidth: CGFloat?
    let timeLayoutPriority: Double
    let categoryLayoutPriority: Double
    let titleLayoutPriority: Double
    let inlineSpacing: CGFloat
    let categoryFixedWidth: CGFloat?
    let textFontSize: CGFloat

    static let standard = CalendarItemRowLayout(
        categoryMinimumWidth: nil,
        categoryMaximumWidth: nil,
        titleMinimumWidth: nil,
        timeLayoutPriority: 2,
        categoryLayoutPriority: 0,
        titleLayoutPriority: 1,
        inlineSpacing: 4,
        categoryFixedWidth: nil,
        textFontSize: 12
    )

    static let compact = CalendarItemRowLayout(
        categoryMinimumWidth: 16,
        categoryMaximumWidth: 16,
        titleMinimumWidth: 20,
        timeLayoutPriority: 4,
        categoryLayoutPriority: 3,
        titleLayoutPriority: 1,
        inlineSpacing: 3,
        categoryFixedWidth: 16,
        textFontSize: 11
    )

}

struct CalendarItemRowPresentation: Equatable {
    let categoryName: String?
    let timeText: String?
    let title: String
    let accessibilityLabel: String
    let layout: CalendarItemRowLayout

    private static let compactRowContentWidth = 140.0
    private static let compactCategoryCharacterLimit = 1

    static func make(
        availableContentWidth: Double,
        categoryName: String,
        timeRange: LocalTimeRange?,
        title: String
    ) -> CalendarItemRowPresentation {
        make(
            availableContentWidth: availableContentWidth,
            categoryName: categoryName,
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
            categoryName: categoryName,
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
        categoryName: String,
        startTime: MinuteOfDay?,
        title: String,
        accessibilityLabel: String
    ) -> CalendarItemRowPresentation {
        let isCompactRow = availableContentWidth <= compactRowContentWidth
        return CalendarItemRowPresentation(
            categoryName: isCompactRow
                ? compactCategoryName(from: categoryName)
                : categoryName,
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

    private static func compactCategoryName(from categoryName: String) -> String {
        guard categoryName.count > compactCategoryCharacterLimit else {
            return categoryName
        }
        return String(categoryName.prefix(compactCategoryCharacterLimit))
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
    var continuesBefore = false
    var continuesAfter = false
    var showsLeadingHandle = false
    var showsTrailingHandle = false
    @Environment(\.colorScheme) private var colorScheme

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
            ?? .primary
    }

    private var categoryOutline: Color {
        itemColorRoles.map { CalendarTheme.categoryColor($0.outline) }
            ?? .primary
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
                handleMarker(label: "调整开始日期")
            }
            RoundedRectangle(cornerRadius: 1)
                .fill(categoryColor)
                .frame(width: 3)
                .overlay {
                    if accentNeedsOutline {
                        RoundedRectangle(cornerRadius: 1)
                            .stroke(categoryOutline, lineWidth: 1)
                    }
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
                    Image(systemName: isCompletedTask ? "checkmark.square.fill" : "square")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(categoryColor)
                }
                .buttonStyle(.plain)
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
                    HStack(spacing: presentation.layout.inlineSpacing) {
                        if let categoryName = presentation.categoryName {
                            if let fixedWidth = presentation.layout.categoryFixedWidth {
                                Text(categoryName)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .frame(width: fixedWidth, alignment: .leading)
                                    .layoutPriority(presentation.layout.categoryLayoutPriority)
                            } else {
                                Text(categoryName)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(
                                        minWidth: presentation.layout.categoryMinimumWidth,
                                        maxWidth: presentation.layout.categoryMaximumWidth,
                                        alignment: .leading
                                    )
                                    .layoutPriority(presentation.layout.categoryLayoutPriority)
                            }
                        }
                        if let timeText = presentation.timeText {
                            Text(timeText)
                                .monospacedDigit()
                                .fixedSize(horizontal: true, vertical: false)
                                .layoutPriority(presentation.layout.timeLayoutPriority)
                        }
                        Text(presentation.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(minWidth: presentation.layout.titleMinimumWidth, alignment: .leading)
                            .layoutPriority(presentation.layout.titleLayoutPriority)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: presentation.layout.textFontSize))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                .foregroundStyle(categoryText)
                .strikethrough(isCompletedTask, color: categoryText)
            }
            .accessibilityLabel(
                accessibilityLabelOverride ?? CalendarItemRowPresentation.rowBodyAccessibilityLabel(
                    categoryName: category?.name ?? "未分类",
                    schedule: item.schedule,
                    title: item.title
                )
            )
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsTrailingHandle {
                handleMarker(label: "调整结束日期")
            }
            if continuesAfter {
                continuationMarker(systemName: "arrow.right")
            }
        }
        .font(CalendarTheme.itemFont)
        .padding(.horizontal, 4)
        .frame(height: CalendarTheme.itemRowHeight)
        .background(
            categoryBackground,
            in: RoundedRectangle(cornerRadius: CalendarTheme.cornerRadius)
        )
        .draggable(transferPayload)
    }

    private var accentNeedsOutline: Bool {
        CalendarTheme.itemAccentNeedsOutline(
            categoryHex,
            isCompletedTask: isCompletedTask,
            appearance: colorScheme == .dark ? .dark : .light
        )
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
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func handleMarker(label: String) -> some View {
        Capsule()
            .fill(categoryColor)
            .frame(width: 3, height: 12)
            .accessibilityLabel(label)
            .help(label)
    }
}
