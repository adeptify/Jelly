import CalendarDomain
import SwiftUI

/// Right-click menu + left-swipe actions for a calendar item chip.
struct ItemRowActionChrome<Content: View>: View {
    let item: ProjectedItem
    let onEdit: () -> Void
    let onPriority: (ItemPriority) -> Void
    let onPin: () -> Void
    let onDelete: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var offset: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme

    private let actionWidth: CGFloat = 56
    private var revealWidth: CGFloat { actionWidth * 2 }

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Button {
                    onPin()
                    withAnimation(.easeOut(duration: 0.15)) { offset = 0 }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: item.isPinned ? "pin.slash.fill" : "pin.fill")
                        Text(item.isPinned ? "取消" : "置顶")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .frame(width: actionWidth)
                    .frame(maxHeight: .infinity)
                    .foregroundStyle(theme.primaryText)
                    .background(theme.todayFill)
                }
                .buttonStyle(.plain)
                Button(role: .destructive) {
                    onDelete()
                    withAnimation(.easeOut(duration: 0.15)) { offset = 0 }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "trash.fill")
                        Text("删除")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .frame(width: actionWidth)
                    .frame(maxHeight: .infinity)
                    .foregroundStyle(.white)
                    .background(theme.error)
                }
                .buttonStyle(.plain)
            }
            .frame(height: CalendarTheme.itemRowHeight)
            .clipShape(RoundedRectangle(cornerRadius: CalendarTheme.cornerRadius, style: .continuous))

            content()
                .offset(x: offset)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            let dx = value.translation.width
                            // Only reveal on left swipe (content moves left → negative offset).
                            offset = min(0, max(-revealWidth, dx))
                        }
                        .onEnded { value in
                            let shouldOpen = value.translation.width < -revealWidth * 0.35
                                || value.predictedEndTranslation.width < -revealWidth * 0.5
                            withAnimation(.easeOut(duration: 0.18)) {
                                offset = shouldOpen ? -revealWidth : 0
                            }
                        }
                )
                .contextMenu {
                    Button("编辑", action: onEdit)
                    Divider()
                    Button("P0") { onPriority(.p0) }
                    Button("P1") { onPriority(.p1) }
                    Button("P2") { onPriority(.p2) }
                    Button("清除优先级") { onPriority(.none) }
                    Divider()
                    Button(item.isPinned ? "取消置顶" : "置顶（P0）", action: onPin)
                    Divider()
                    Button("删除", role: .destructive, action: onDelete)
                }
        }
        .clipped()
    }
}

struct ItemPriorityBadge: View {
    let priority: ItemPriority
    let isPinned: Bool

    var body: some View {
        HStack(spacing: 2) {
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8, weight: .bold))
            }
            if priority != .none {
                Text(priority.title)
                    .font(.system(size: 9, weight: .bold))
            }
        }
        .foregroundStyle(badgeColor)
        .opacity(priority == .none && !isPinned ? 0 : 1)
    }

    private var badgeColor: Color {
        switch priority {
        case .p0: Color(red: 0.75, green: 0.25, blue: 0.2)
        case .p1: Color(red: 0.85, green: 0.5, blue: 0.15)
        case .p2: Color(red: 0.35, green: 0.5, blue: 0.75)
        case .none: .secondary
        }
    }
}
