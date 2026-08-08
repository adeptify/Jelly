import CalendarDomain
import SwiftUI

enum CalendarItemRowPlacement: Equatable {
    case monthGrid
    case dayDrawer

    var allowsSwipeToDelete: Bool {
        switch self {
        case .monthGrid: false
        case .dayDrawer: true
        }
    }
}

struct ItemRowActionChromePolicy: Equatable {
    let allowsSwipeToDelete: Bool

    var installsSwipeGesture: Bool { allowsSwipeToDelete }
    var showsDeleteAction: Bool { allowsSwipeToDelete }
}

/// Left-swipe delete chrome for a calendar item chip. Priority is edited in the detail form.
struct ItemRowActionChrome<Content: View>: View {
    let allowsSwipeToDelete: Bool
    let onDelete: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var offset: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme

    private let actionWidth: CGFloat = 64
    private var revealWidth: CGFloat { actionWidth }

    private var isRevealed: Bool { offset < -0.5 }

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    init(
        allowsSwipeToDelete: Bool = true,
        onDelete: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.allowsSwipeToDelete = allowsSwipeToDelete
        self.onDelete = onDelete
        self.content = content
    }

    @ViewBuilder
    var body: some View {
        let policy = ItemRowActionChromePolicy(allowsSwipeToDelete: allowsSwipeToDelete)
        if policy.installsSwipeGesture {
            swipeEnabledBody
        } else {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
        }
    }

    private var swipeEnabledBody: some View {
        ZStack(alignment: .trailing) {
            actionStrip
                .opacity(isRevealed ? 1 : 0)
                .allowsHitTesting(isRevealed)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(x: offset)
                .highPriorityGesture(swipeGesture)
        }
        .clipped()
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                let dx = value.translation.width
                offset = min(0, max(-revealWidth, dx))
            }
            .onEnded { value in
                let shouldOpen = value.translation.width < -revealWidth * 0.35
                    || value.predictedEndTranslation.width < -revealWidth * 0.5
                withAnimation(.easeOut(duration: 0.18)) {
                    offset = shouldOpen ? -revealWidth : 0
                }
            }
    }

    private var actionStrip: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
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
    }
}

/// Priority chip on item rows (P0–P2 only; pin removed as redundant with P0).
struct ItemPriorityBadge: View {
    let priority: ItemPriority

    var body: some View {
        Group {
            if priority != .none {
                Text(priority.title)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(badgeColor)
            }
        }
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
