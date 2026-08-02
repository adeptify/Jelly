import CalendarDomain
import SwiftUI

struct CalendarItemRow: View {
    let item: ProjectedItem
    let category: CalendarCategory?

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

            if item.kind == .task {
                Image(systemName: isCompletedTask ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isCompletedTask ? CalendarTheme.completedTaskAccent(categoryColor) : categoryColor)
            } else {
                Circle()
                    .fill(categoryColor)
                    .frame(width: 6, height: 6)
            }

            Text(category?.name ?? "未分类")
                .lineLimit(1)
                .foregroundStyle(isCompletedTask ? CalendarTheme.completedText : .primary)
            if let time = item.timeRange {
                Text(Self.timeString(time.start))
                    .monospacedDigit()
                    .foregroundStyle(isCompletedTask ? CalendarTheme.completedText : .secondary)
            }
            Text(item.title)
                .lineLimit(1)
                .foregroundStyle(isCompletedTask ? CalendarTheme.completedText : .primary)
                .layoutPriority(1)
            Spacer(minLength: 0)
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
    }

    private static func timeString(_ minute: MinuteOfDay) -> String {
        String(format: "%02d:%02d", minute.value / 60, minute.value % 60)
    }
}
