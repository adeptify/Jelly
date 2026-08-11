import SwiftUI
import WorkspaceDomain

struct WorkspaceNavigationRail: View {
    let store: WorkspaceStore
    let features: WorkspaceFeatures
    @ObservedObject var routeState: WorkspaceRouteState
    @ObservedObject var transitionCoordinator: WorkspaceRouteTransitionCoordinator
    @Environment(\.colorScheme) private var colorScheme

    private var theme: CalendarSemanticAppearance {
        CalendarTheme.appearance(for: colorScheme)
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(WorkspaceRoute.visibleRoutes(features)) { route in
                routeButton(route)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 14)
        .padding(.horizontal, 8)
        .frame(width: WorkspaceWindowLayout.railWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.elevatedSurface)
        // An overlay is inside the rail's fixed width; it must not change the
        // 64 + 980 window calculation.
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(theme.separator)
                .frame(width: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("工作空间导航")
    }

    private func routeButton(_ route: WorkspaceRoute) -> some View {
        let metadata = route.railMetadata
        let isSelected = routeState.route == route
        let pendingCount = route == .inspiration ? inspirationPendingCount : 0
        return Button {
            Task { _ = await transitionCoordinator.requestActivation(route) }
        } label: {
            Image(systemName: metadata.symbolName)
                .font(.system(size: 17, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? theme.primaryText : theme.secondaryText)
                .frame(width: 40, height: 40)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(theme.rangePreviewFill)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if pendingCount > 0 {
                        Text(pendingCount > 99 ? "99+" : "\(pendingCount)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(.orange, in: Capsule())
                            .offset(x: 5, y: -4)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(metadata.help)
        .accessibilityLabel(metadata.accessibilityLabel)
        .accessibilityValue(accessibilityValue(isSelected: isSelected, pendingCount: pendingCount))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("workspace-route-\(route.rawValue)")
    }

    private var inspirationPendingCount: Int {
        let linked = Set(store.state.inspirationNoteLinks.compactMap { link -> InspirationID? in
            if case let .live(id) = link.source { return id }
            return nil
        })
        return store.state.inspirations.values.filter {
            $0.lifecycle == .active && !linked.contains($0.id)
        }.count
    }

    private func accessibilityValue(isSelected: Bool, pendingCount: Int) -> String {
        var parts: [String] = []
        if isSelected { parts.append(WorkspaceRailAppearance.selectedAccessibilityValue) }
        if pendingCount > 0 { parts.append("\(pendingCount) 条待处理") }
        return parts.joined(separator: "，")
    }
}
