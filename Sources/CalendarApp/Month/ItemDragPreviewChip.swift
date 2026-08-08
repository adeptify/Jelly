import CalendarDomain
import SwiftUI

/// Floating chip shown under the pointer while moving/resizing a month-row item.
/// Mirrors the on-grid chip look so the user always “holds” a recognizable card.
struct ItemDragPreviewChip: View {
    let title: String
    let priority: ItemPriority
    let schedule: CalendarSchedule
    let categoryHex: String
    let isCompleted: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var appearance: CalendarAppearance {
        colorScheme == .dark ? .dark : .light
    }

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    private var roles: CategoryRenderedColorRoles? {
        CalendarTheme.categoryItemRoles(
            categoryHex,
            isCompleted: isCompleted,
            appearance: appearance
        )
    }

    private var background: Color {
        roles.map { CalendarTheme.categoryColor($0.background) }
            ?? CalendarTheme.itemBackground(
                CalendarTheme.categoryColor(categoryHex),
                appearance: appearance
            )
    }

    private var textColor: Color {
        roles.map { CalendarTheme.categoryColor($0.text) } ?? theme.primaryText
    }

    private var accent: Color {
        roles.map { CalendarTheme.categoryColor($0.accent) }
            ?? CalendarTheme.categoryColor(categoryHex)
    }

    private var timeText: String? {
        CalendarItemRowPresentation.displayTimeText(for: schedule)
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(accent.opacity(isCompleted ? 0.85 : 0.75))
                .frame(width: 16)

            ItemPriorityBadge(priority: priority)

            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Spacer(minLength: 2)

            if let timeText {
                Text(timeText)
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
                    .opacity(0.72)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(textColor)
        .padding(.horizontal, 6)
        .frame(height: CalendarTheme.itemRowHeight)
        .frame(minWidth: 120, maxWidth: 220, alignment: .leading)
        .opacity(isCompleted ? CalendarTheme.completedItemOpacity(for: appearance) : 1)
        .background(
            background,
            in: RoundedRectangle(cornerRadius: CalendarTheme.cornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: CalendarTheme.cornerRadius, style: .continuous)
                .stroke(accent.opacity(0.55), lineWidth: 1)
        }
        .shadow(color: theme.subtleShadow.opacity(0.35), radius: 6, y: 3)
        .accessibilityHidden(true)
    }

    static func make(entry: ProjectedEntry, category: CalendarCategory?) -> ItemDragPreviewChip {
        ItemDragPreviewChip(
            title: entry.title,
            priority: entry.priority,
            schedule: entry.schedule,
            categoryHex: category?.colorHex ?? "#8C8F96",
            isCompleted: entry.completedAt != nil
        )
    }
}
