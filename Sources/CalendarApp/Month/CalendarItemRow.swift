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

struct CalendarItemRow: View {
    let item: ProjectedItem
    let category: CalendarCategory?
    var onCompletion: ((CalendarCommand) -> Void)?
    var onOpenDetail: ((ProjectedItem) -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    private var categoryColor: Color {
        CalendarTheme.categoryColor(category?.colorHex ?? "#8E8E93")
    }

    private var isCompletedTask: Bool {
        item.kind == .task && item.completedAt != nil
    }

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1)
                .fill(isCompletedTask ? CalendarTheme.completedTaskAccent(categoryColor) : categoryColor)
                .frame(width: 3)
                .overlay {
                    if accentNeedsOutline {
                        RoundedRectangle(cornerRadius: 1)
                            .stroke(CalendarTheme.itemAccentOutline, lineWidth: 1)
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
                        .foregroundStyle(
                            isCompletedTask ? CalendarTheme.completedTaskAccent(categoryColor) : categoryColor
                        )
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
                HStack(spacing: 4) {
                    Text(category?.name ?? "未分类")
                        .lineLimit(1)
                    if let time = item.timeRange {
                        Text(Self.timeString(time.start))
                            .monospacedDigit()
                    }
                    Text(item.title)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(isCompletedTask ? CalendarTheme.completedText : .primary)
            }
            .buttonStyle(.plain)
        }
        .font(CalendarTheme.itemFont)
        .padding(.horizontal, 4)
        .frame(height: CalendarTheme.itemRowHeight)
        .background(
            (isCompletedTask
                ? CalendarTheme.completedTaskBackground(categoryColor)
                : CalendarTheme.itemBackground(categoryColor)
            ),
            in: RoundedRectangle(cornerRadius: CalendarTheme.cornerRadius)
        )
        .draggable(transferPayload)
    }

    private static func timeString(_ minute: MinuteOfDay) -> String {
        String(format: "%02d:%02d", minute.value / 60, minute.value % 60)
    }

    private var accentNeedsOutline: Bool {
        CalendarTheme.itemAccentNeedsOutline(
            category?.colorHex ?? "#8E8E93",
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
}
